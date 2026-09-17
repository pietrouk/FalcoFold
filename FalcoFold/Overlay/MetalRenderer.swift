import MetalKit
import MetalPerformanceShaders
import os

/// Draws the captured desktop tilted about its bottom edge, blurred and shaded by lid progress.
/// The displayed angle follows `targetAngle` on a spring, so whole-degree sensor steps look smooth.
final class MetalRenderer: NSObject, MTKViewDelegate {
    var parameters: EffectParameters
    var targetAngle: Double
    var frameSource: () -> CaptureController.Frame? = { nil }
    /// Called on the main queue once a snap-back started with `beginClearing()` has settled.
    var onCleared: (() -> Void)?

    private(set) var hasDrawn = false
    private(set) var isClearing = false

    /// Tilt at full progress with perspective at 1, in radians.
    private let maxTilt = 70 * Double.pi / 180
    /// Lid movement that counter-rotation follows at most. Must stay below atan(viewerDistance).
    private let maxCounterTilt = 70 * Double.pi / 180
    /// Viewer distance from the screen, in half-screen-heights (about 50 cm from a laptop screen).
    private let viewerDistance = 4.0
    /// Blur sigma at full progress with blur at 1, in capture pixels.
    private let maxBlurSigma = 48.0
    private let followStiffness = 18.0
    private let snapStiffness = 34.0

    private var angle: Double
    private var velocity = 0.0
    private var lastDrawTime: CFTimeInterval?
    private let createdAt = ContinuousClock.now
    private var clearingStartedAt: ContinuousClock.Instant?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let downscale: MPSImageBilinearScale
    private var blurKernels: [Int: MPSImageGaussianBlur] = [:]
    private var scratchTextures: [String: MTLTexture] = [:]
    private let log = Logger(subsystem: "io.github.pietrouk.FalcoFold", category: "Renderer")

    private struct VertexUniforms {
        var tilt: Float
        var eyeY: Float
        var eyeZ: Float
    }

    private struct FragmentUniforms {
        var shade: Float
    }

    init(device: MTLDevice, pixelFormat: MTLPixelFormat, parameters: EffectParameters, targetAngle: Double) throws {
        guard let queue = device.makeCommandQueue(), let library = device.makeDefaultLibrary() else {
            throw RendererError.setupFailed
        }
        self.device = device
        self.parameters = parameters
        self.targetAngle = targetAngle
        // Start flat and ease into the current angle.
        angle = parameters.clearAngle
        commandQueue = queue

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "tiltVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "tiltFragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { throw RendererError.setupFailed }
        self.sampler = sampler
        downscale = MPSImageBilinearScale(device: device)
    }

    /// Springs back to flat, then calls `onCleared`.
    func beginClearing() {
        guard !isClearing else { return }
        isClearing = true
        clearingStartedAt = .now
    }

    func cancelClearing() {
        isClearing = false
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // Draw nothing until the first frame arrives, so the overlay stays transparent instead of black.
        guard let frame = frameSource() else { return }

        let now = CACurrentMediaTime()
        advanceSpring(by: min(now - (lastDrawTime ?? now), 1.0 / 30))
        lastDrawTime = now

        let p = parameters
        let progress = p.progress(at: angle)
        var vertexUniforms = VertexUniforms(tilt: 0, eyeY: 0, eyeZ: Float(viewerDistance))
        if p.counterRotate {
            // The screen came toward the viewer by `lidDelta`. Lean the image back by the same amount and
            // move the eye to where the viewer now is relative to the screen, so the image stays put.
            let lidDelta = min(max(p.clearAngle - angle, 0) * .pi / 180, maxCounterTilt)
            vertexUniforms.tilt = Float(lidDelta * p.style.perspective)
            vertexUniforms.eyeY = Float(cos(lidDelta) + viewerDistance * sin(lidDelta) - 1)
            vertexUniforms.eyeZ = Float(viewerDistance * cos(lidDelta) - sin(lidDelta))
        } else {
            vertexUniforms.tilt = Float(progress * p.style.perspective * maxTilt)
        }
        var fragmentUniforms = FragmentUniforms(shade: Float(progress * p.style.shadow))

        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }
        let texture = blurred(frame.texture, sigma: progress * p.style.blur * maxBlurSigma, commandBuffer: commandBuffer)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&vertexUniforms, length: MemoryLayout<VertexUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&fragmentUniforms, length: MemoryLayout<FragmentUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        if !hasDrawn {
            hasDrawn = true
            log.info("First frame drawn \(self.createdAt.duration(to: .now), privacy: .public) after arming")
        }
        if isClearing, abs(angle - p.clearAngle) < 0.25, abs(velocity) < 5 {
            isClearing = false
            if let clearingStartedAt {
                log.info("Snapped back in \(clearingStartedAt.duration(to: .now), privacy: .public)")
            }
            DispatchQueue.main.async { [weak self] in self?.onCleared?() }
        }
    }

    /// Critically damped spring toward the target (or toward the clear angle while snapping back).
    private func advanceSpring(by dt: Double) {
        let target = isClearing ? parameters.clearAngle : targetAngle
        let omega = isClearing ? snapStiffness : followStiffness
        // Small fixed substeps keep semi-implicit Euler stable at any frame rate.
        var remaining = dt
        while remaining > 0 {
            let step = min(remaining, 1.0 / 240)
            velocity += (omega * omega * (target - angle) - 2 * omega * velocity) * step
            angle += velocity * step
            remaining -= step
        }
    }

    // MARK: Blur

    /// Gaussian blur with MPS. Strong blurs run on a half- or quarter-size copy, which looks the same and costs far less.
    private func blurred(_ texture: MTLTexture, sigma: Double, commandBuffer: MTLCommandBuffer) -> MTLTexture {
        guard sigma >= 0.5 else { return texture }
        let factor = sigma >= 8 ? 4 : sigma >= 1.5 ? 2 : 1
        let width = texture.width / factor
        let height = texture.height / factor
        guard let output = scratchTexture("blur\(factor)", width: width, height: height, like: texture) else { return texture }

        var source = texture
        if factor > 1 {
            guard let scaled = scratchTexture("scaled\(factor)", width: width, height: height, like: texture) else { return texture }
            downscale.encode(commandBuffer: commandBuffer, sourceTexture: texture, destinationTexture: scaled)
            source = scaled
        }
        blurKernel(sigma: sigma / Double(factor)).encode(commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: output)
        return output
    }

    private func blurKernel(sigma: Double) -> MPSImageGaussianBlur {
        let key = Int((sigma * 4).rounded())   // quarter-pixel steps are invisible and keep the cache small
        if let kernel = blurKernels[key] { return kernel }
        if blurKernels.count > 128 { blurKernels.removeAll() }
        let kernel = MPSImageGaussianBlur(device: device, sigma: Float(max(key, 1)) / 4)
        kernel.edgeMode = .clamp
        blurKernels[key] = kernel
        return kernel
    }

    private func scratchTexture(_ name: String, width: Int, height: Int, like texture: MTLTexture) -> MTLTexture? {
        if let existing = scratchTextures[name], existing.width == width, existing.height == height { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let created = device.makeTexture(descriptor: descriptor)
        scratchTextures[name] = created
        return created
    }

    enum RendererError: Error { case setupFailed }
}
