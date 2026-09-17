#if DEBUG
import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import os

extension UserDefaults {
    @objc dynamic var debugSnapshotPath: String? { string(forKey: "debugSnapshotPath") }
}

/// Debug builds only. Saves what the built-in display shows, overlay included, as a PNG,
/// so visuals can be checked from a script without anyone looking at the screen:
///
///     defaults write io.github.pietrouk.FalcoFold debugSnapshotPath /path/to/shot.png
enum DebugSnapshot {
    private static let log = Logger(subsystem: "io.github.pietrouk.FalcoFold", category: "DebugSnapshot")

    static func observe(_ defaults: UserDefaults) -> NSKeyValueObservation {
        defaults.observe(\.debugSnapshotPath, options: [.initial, .new]) { defaults, _ in
            guard let path = defaults.debugSnapshotPath else { return }
            defaults.removeObject(forKey: "debugSnapshotPath")
            Task { await save(to: URL(fileURLWithPath: path)) }
        }
    }

    private static func save(to url: URL) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) else { return }
            let config = SCStreamConfiguration()
            config.width = display.width    // points, not pixels: small enough to look at
            config.height = display.height
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            log.info("Saved snapshot to \(url.path, privacy: .public)")
        } catch {
            log.error("Snapshot failed: \(error, privacy: .public)")
        }
    }
}
#endif
