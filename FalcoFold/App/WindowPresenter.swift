import AppKit
import SwiftUI

/// Shows the app's regular windows (Settings, Welcome). A menu bar app has no Dock icon or main window,
/// so these are plain AppKit windows hosting SwiftUI, brought to the front on request.
@MainActor
final class WindowPresenter {
    enum Kind {
        /// Floats above the effect overlay, so styles can be tuned while the desktop is tilted.
        /// Hides when you switch to another app.
        case floatingUtility
        case regular
    }

    private var windows: [String: NSWindow] = [:]

    func show(_ id: String, title: String, kind: Kind, content: () -> some View) {
        let window = windows[id] ?? makeWindow(title: title, kind: kind, content: NSHostingView(rootView: content()))
        windows[id] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ id: String) {
        windows[id]?.close()
    }

    private func makeWindow(title: String, kind: Kind, content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: content.fittingSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = content
        window.isReleasedWhenClosed = false
        if kind == .floatingUtility {
            window.level = .popUpMenu
            window.hidesOnDeactivate = true
        }
        window.center()
        return window
    }
}
