import AppKit
import MetalKit
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
    private let device: MTLDevice
    private let capture: CaptureController
    private var window: NSWindow?
    private var renderer: MetalRenderer?
    /// Start/stop requests run one after another, so a fast arm → disarm → arm can't overlap streams.
    private var captureTask: Task<Void, Never>?
    private var generation = 0
    private let log = Logger(subsystem: "io.github.pietrouk.FalcoFold", category: "TiltEffect")

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let capture = CaptureController(device: device) else { return nil }
        self.device = device
        self.capture = capture
        capture.onStop = { [weak self] error in
            MainActor.assumeIsolated { self?.fail(error) }
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
        guard let screen = NSScreen.builtIn, let displayID = screen.displayID else {
            fail(CaptureController.CaptureError.displayNotFound)
            return
        }
        isArmed = true
        generation += 1
        let armGeneration = generation

        do {
            try showOverlay(on: screen)
        } catch {
            fail(error)
            return
        }

        let previous = captureTask
        let scale = screen.backingScaleFactor
        let frameRate = max(screen.maximumFramesPerSecond, 60)
        captureTask = Task { [weak self, capture] in
            await previous?.value
            guard let self, armGeneration == self.generation else { return }
            do {
                try await capture.start(displayID: displayID, scale: scale, frameRate: frameRate)
                if armGeneration != self.generation { await capture.stop() }
            } catch {
                if armGeneration == self.generation { self.fail(error) }
            }
        }
    }

    /// Snaps the desktop back to flat, then hides the overlay and stops capture.
    func disarm() {
        guard isArmed else { return }
        isArmed = false
        guard let renderer, renderer.hasDrawn else {
            tearDown()
            return
        }
        renderer.beginClearing()
    }

    private func tearDown() {
        generation += 1
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

    static var builtIn: NSScreen? {
        screens.first { screen in screen.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false }
    }
}
