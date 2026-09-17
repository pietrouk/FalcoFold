import AppKit
import MetalKit
import ScreenCaptureKit
import os

/// Owns the click-through overlay on the built-in display, the Metal renderer and the capture stream.
/// Capture runs only while the effect is armed or snapping back.
@MainActor
final class TiltEffect {
    var parameters = EffectParameters(style: StylePreset.silk.style, clearAngle: 100, closedAngle: 20, counterRotate: false) {
        didSet { renderer?.parameters = parameters }
    }
    var targetAngle = 180.0 {
        didSet { renderer?.targetAngle = targetAngle }
    }
    /// Called when capture fails or stops unexpectedly. The effect has already disarmed itself.
    var onError: ((Error) -> Void)?

    private(set) var isArmed = false
    /// The system stopped capture, usually because the screen turned off as the lid got low.
    /// The overlay stays up and capture restarts when the screen comes back.
    private var isInterrupted = false
    private let device: MTLDevice
    private let capture: CaptureController
    private var window: NSWindow?
    private var renderer: MetalRenderer?
    /// Start/stop requests run one after another, so a fast arm → disarm → arm can't overlap streams.
    private var captureTask: Task<Void, Never>?
    private var generation = 0
    /// Pixel size of the display being captured, to tell whether a display change needs a new stream.
    private var capturedPixelSize: CGSize?
    private let log = Logger(subsystem: "io.github.pietrouk.FalcoFold", category: "TiltEffect")

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let capture = CaptureController(device: device) else { return nil }
        self.device = device
        self.capture = capture
        capture.onStop = { [weak self] error in
            MainActor.assumeIsolated { self?.captureStopped(error) }
        }
    }

    func arm() {
        guard !isArmed else { return }
        if let renderer {
            // Still snapping back from the last clear: follow the lid again with the same overlay and stream.
            isArmed = true
            renderer.cancelClearing()
            return
        }
        guard let screen = NSScreen.builtIn else {
            fail(CaptureController.CaptureError.displayNotFound)
            return
        }
        isArmed = true
        generation += 1

        do {
            try showOverlay(on: screen)
        } catch {
            fail(error)
            return
        }
        startCapture()
    }

    /// Starts capture after any pending start or stop. While interrupted, keeps retrying until the screen is back.
    private func startCapture() {
        let armGeneration = generation
        let previous = captureTask
        captureTask = Task { [weak self, capture] in
            await previous?.value
            while true {
                guard let self, armGeneration == self.generation else { return }
                do {
                    guard let screen = NSScreen.builtIn, let displayID = screen.displayID else {
                        throw CaptureController.CaptureError.displayNotFound
                    }
                    let pixelSize = screen.pixelSize
                    try await capture.start(displayID: displayID, scale: screen.backingScaleFactor,
                                            frameRate: max(screen.maximumFramesPerSecond, 60))
                    guard armGeneration == self.generation else {
                        await capture.stop()
                        return
                    }
                    self.capturedPixelSize = pixelSize
                    if self.isInterrupted {
                        self.isInterrupted = false
                        self.window?.setFrame(screen.frame, display: false)
                        self.log.info("Capture resumed")
                    }
                    return
                } catch {
                    guard self.isInterrupted else {
                        if armGeneration == self.generation { self.fail(error) }
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    private func captureStopped(_ error: Error) {
        guard renderer != nil else { return }
        let error = error as NSError
        // -3821 is SCStreamError.systemStoppedStream, which the SDK only names from macOS 15.
        let recoverable = [SCStreamError.Code.noCaptureSource.rawValue, -3821]
        guard error.domain == SCStreamErrorDomain, recoverable.contains(error.code) else {
            fail(error)
            return
        }
        guard isArmed else {
            // Was snapping back; without frames there's nothing left to animate.
            tearDown()
            return
        }
        log.notice("Capture interrupted at \(self.targetAngle, privacy: .public)° (screen off?); retrying until it's back")
        isInterrupted = true
        startCapture()
    }

    /// After a display change: moves the overlay to where the built-in display now is, restarts capture
    /// if the display's size changed, and hides everything at once if the display is gone (clamshell mode).
    func screensChanged() {
        guard let window else { return }
        guard let screen = NSScreen.builtIn else {
            log.notice("Built-in display is gone; hiding the overlay")
            isArmed = false
            tearDown()
            return
        }
        if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
        guard !isInterrupted, let capturedPixelSize, capturedPixelSize != screen.pixelSize else { return }
        log.info("Built-in display changed size; restarting capture")
        generation += 1
        let previous = captureTask
        captureTask = Task { [capture] in
            await previous?.value
            await capture.stop()
        }
        startCapture()
    }

    /// Snaps the desktop back to flat, then hides the overlay and stops capture.
    func disarm() {
        guard isArmed else { return }
        isArmed = false
        guard let renderer, renderer.hasDrawn, !isInterrupted else {
            tearDown()
            return
        }
        renderer.beginClearing()
    }

    private func tearDown() {
        generation += 1
        isInterrupted = false
        capturedPixelSize = nil
        hideOverlay()
        let previous = captureTask
        captureTask = Task { [capture] in
            await previous?.value
            await capture.stop()
        }
    }

    private func fail(_ error: Error) {
        log.error("Effect failed: \(error)")
        isArmed = false
        tearDown()
        onError?(error)
    }

    private func showOverlay(on screen: NSScreen) throws {
        let pixelFormat = MTLPixelFormat.bgra8Unorm
        let renderer = try MetalRenderer(device: device, pixelFormat: pixelFormat, parameters: parameters, targetAngle: targetAngle)
        renderer.frameSource = { [capture] in capture.latestFrame }
        renderer.onCleared = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isArmed else { return }
                self.tearDown()
            }
        }

        // A fresh view per arm, so no stale frame from the last time can flash on screen.
        let view = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: device)
        view.colorPixelFormat = pixelFormat
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = screen.maximumFramesPerSecond
        view.layer?.isOpaque = false
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        view.delegate = renderer

        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Just below pop-up menus: covers apps, the Dock and the menu bar, but our own menu stays usable.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = view
        window.orderFrontRegardless()

        self.renderer = renderer
        self.window = window
    }

    private func hideOverlay() {
        (window?.contentView as? MTKView)?.delegate = nil
        window?.close()
        window = nil
        renderer = nil
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    var pixelSize: CGSize {
        CGSize(width: frame.width * backingScaleFactor, height: frame.height * backingScaleFactor)
    }

    /// Nil while the built-in display is off, e.g. in clamshell mode with an external monitor.
    static var builtIn: NSScreen? {
        screens.first { screen in screen.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false }
    }
}
