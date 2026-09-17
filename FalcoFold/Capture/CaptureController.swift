import AppKit
import CoreMedia
import CoreVideo
import Metal
import ScreenCaptureKit
import os

/// Streams one display with ScreenCaptureKit and keeps the newest frame as a Metal texture.
/// This app's own windows are left out, so the overlay never captures itself.
final class CaptureController: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Frame {
        let texture: MTLTexture
        /// Keeps the IOSurface behind `texture` alive while the renderer uses it.
        fileprivate let cvTexture: CVMetalTexture
    }

    enum CaptureError: LocalizedError {
        case displayNotFound
        var errorDescription: String? { "The built-in display is not available for capture." }
    }

    /// Called on the main thread when the system stops the stream (e.g. permission revoked).
    var onStop: ((Error) -> Void)?

    private let textureCache: CVMetalTextureCache
    private let queue = DispatchQueue(label: "io.github.pietrouk.FalcoFold.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    private var latest: Frame?
    private let log = Logger(subsystem: "io.github.pietrouk.FalcoFold", category: "Capture")

    var latestFrame: Frame? { lock.withLock { latest } }

    init?(device: MTLDevice) {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
        textureCache = cache
    }

    func start(displayID: CGDirectDisplayID, scale: CGFloat, frameRate: Int) async throws {
        guard stream == nil else { return }
        let startedAt = ContinuousClock.now

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        let pid = getpid()
        let ownApps = content.applications.filter { $0.processID == pid }
        let filter: SCContentFilter
        if ownApps.isEmpty {
            // Fallback: exclude the windows we already have (the overlay is created before capture starts).
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
            log.warning("Own app not in shareable content; excluding \(ownWindows.count) windows instead")
            filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        } else {
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.displayP3
        // The real cursor is drawn above the overlay, so a captured one would appear twice.
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.queueDepth = 4

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        log.info("Capture started \(config.width)x\(config.height)@\(frameRate) in \(startedAt.duration(to: .now), privacy: .public)")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        do { try await stream.stopCapture() } catch { log.error("stopCapture failed: \(error)") }
        lock.withLock { latest = nil }
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture) == kCVReturnSuccess,
              let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture)
        else { return }
        lock.withLock { latest = Frame(texture: texture, cvTexture: cvTexture) }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Stream stopped: \(error)")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.lock.withLock { self.latest = nil }
            self.onStop?(error)
        }
    }
}
