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
        /// Counts up with every frame, so the renderer can tell a new frame from the one it already drew.
        let id: Int
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
    private let fingerprint: FrameFingerprint?
    private let queue = DispatchQueue(label: "io.github.pietrouk.FalcoFold.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    private var latest: Frame?
    private var frameCount = 0
    /// Frame statistics, touched only on the sample handler queue.
    private var stats = FrameStats()

    private struct FrameStats {
        var complete = 0
        var unchanged = 0
        var idle = 0
        var other = 0
        var dirtyFraction = 0.0
        var since: CFTimeInterval?
    }
    private let log = Logger(subsystem: "io.github.pietrouk.FalcoFold", category: "Capture")

    var latestFrame: Frame? { lock.withLock { latest } }

    init?(device: MTLDevice) {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
        textureCache = cache
        fingerprint = FrameFingerprint(device: device)
        super.init()
        if fingerprint == nil { log.warning("Frame fingerprinting unavailable; the overlay will redraw at the display rate") }
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
        fingerprint?.reset()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int
        else { return }
        let status = SCFrameStatus(rawValue: rawStatus)
        countFrame(status, info: info)
        guard status == .complete, let pixelBuffer = sampleBuffer.imageBuffer else { return }

        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture) == kCVReturnSuccess,
              let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture)
        else { return }
        if let fingerprint, fingerprint.matchesPrevious(texture) {
            stats.unchanged += 1   // usually the echo of our own last draw
            return
        }
        lock.withLock {
            frameCount += 1
            latest = Frame(id: frameCount, texture: texture, cvTexture: cvTexture)
        }
    }

    /// Every few seconds: how many frames arrived, how many had the same pixels as the one before, and how
    /// much of the display the system flagged as changed. Shows whether the desktop was still or busy.
    private func countFrame(_ status: SCFrameStatus?, info: [SCStreamFrameInfo: Any]) {
        switch status {
        case .complete:
            stats.complete += 1
            if let content = info[.contentRect] as? NSDictionary, let contentRect = CGRect(dictionaryRepresentation: content),
               let dirty = info[.dirtyRects] as? [NSDictionary], contentRect.width > 0, contentRect.height > 0 {
                let area = dirty.compactMap(CGRect.init(dictionaryRepresentation:)).reduce(0) { $0 + $1.width * $1.height }
                stats.dirtyFraction += min(area / (contentRect.width * contentRect.height), 1)
            }
        case .idle: stats.idle += 1
        default: stats.other += 1
        }
        let now = CACurrentMediaTime()
        guard let since = stats.since else { stats.since = now; return }
        guard now - since >= 5 else { return }
        let averageDirty = stats.complete > 0 ? stats.dirtyFraction / Double(stats.complete) * 100 : 0
        log.info("Frames in \(now - since, format: .fixed(precision: 1)) s: \(self.stats.complete) complete (\(self.stats.unchanged) unchanged, avg \(averageDirty, format: .fixed(precision: 1))% flagged), \(self.stats.idle) idle, \(self.stats.other) other")
        stats = FrameStats(since: now)
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
