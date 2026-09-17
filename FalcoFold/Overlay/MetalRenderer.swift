import MetalKit
import os

/// Draws the captured desktop as a quad hinged at the bottom edge and tilted away from the viewer.
final class MetalRenderer: NSObject, MTKViewDelegate {
    /// 0 = flat (identical to the real desktop), 1 = fully tilted.
    var progress: Float = 0
    var frameSource: () -> CaptureController.Frame? = { nil }

    /// Tilt at full progress, in radians.
    var maxTilt: Float = 60 * .pi / 180
    /// Camera distance from the screen, in half-screen-heights. Smaller = stronger perspective.
    var viewerDistance: Float = 3

    private let createdAt = ContinuousClock.now
    private var drewFirstFrame = false
    private let log = Logger(subsystem: "io.github.pietrouk.FalcoFold", category: "Renderer")

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    private struct Uniforms {
        var tilt: Float
        var distance: Float
    }

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        guard let queue = device.makeCommandQueue() else { throw RendererError.setupFailed }
        commandQueue = queue

        guard let library = device.makeDefaultLibrary() else { throw RendererError.setupFailed }
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
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // Draw nothing until the first frame arrives, so the overlay stays transparent instead of black.
        guard let frame = frameSource(),
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        var uniforms = Uniforms(tilt: min(max(progress, 0), 1) * maxTilt, distance: viewerDistance)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(frame.texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        if !drewFirstFrame {
            drewFirstFrame = true
            log.info("First frame drawn \(self.createdAt.duration(to: .now), privacy: .public) after arming")
        }
    }

    enum RendererError: Error { case setupFailed }
}
