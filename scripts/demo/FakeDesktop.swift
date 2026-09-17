// Draws a synthetic desktop in a borderless window that covers the built-in display,
// just below FalcoFold's overlay, so demo captures never show the real screen.
// Usage: FakeDesktop <seconds>
import AppKit

final class DesktopView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        NSGradient(colors: [
            NSColor(calibratedRed: 0.09, green: 0.13, blue: 0.34, alpha: 1),
            NSColor(calibratedRed: 0.45, green: 0.20, blue: 0.48, alpha: 1),
            NSColor(calibratedRed: 0.96, green: 0.56, blue: 0.32, alpha: 1),
        ])!.draw(in: b, angle: -55)

        // Menu bar
        NSColor(white: 1, alpha: 0.28).setFill()
        NSRect(x: 0, y: 0, width: b.width, height: 25).fill()
        text("", at: NSPoint(x: 18, y: 4), size: 14, bold: true, color: .white)
        text("Finder    File    Edit    View    Go    Window    Help", at: NSPoint(x: 44, y: 5), size: 13, bold: false, color: .white)
        text("Wed 17 Sep  12:15", at: NSPoint(x: b.width - 150, y: 5), size: 13, bold: false, color: .white)

        // Windows
        let w1 = NSRect(x: b.width * 0.08, y: b.height * 0.12, width: b.width * 0.52, height: b.height * 0.62)
        window(w1, title: "Notes", body: .white)
        var y = w1.minY + 60
        text("Lid angle sensor notes", at: NSPoint(x: w1.minX + 32, y: y), size: 26, bold: true, color: .black); y += 48
        for line in ["The hinge angle comes straight from the built-in sensor, in whole degrees.",
                     "Capture runs only while the effect is showing, so the app idles at about 0% CPU.",
                     "Perspective, blur and shadow each scale with how far the lid has come down.",
                     "Esc dismisses the effect until the lid next comes to rest.",
                     "", "Styles", "  • Silk: perspective-led", "  • Shade: shadow-led", "  • Frost: blur-led"] {
            text(line, at: NSPoint(x: w1.minX + 32, y: y), size: 16, bold: false, color: NSColor(white: 0.15, alpha: 1)); y += 27
        }

        let w2 = NSRect(x: b.width * 0.50, y: b.height * 0.30, width: b.width * 0.42, height: b.height * 0.50)
        window(w2, title: "Terminal", body: NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 1))
        y = w2.minY + 52
        for line in ["$ xcodegen generate", "⚙️  Generated project at FalcoFold.xcodeproj",
                     "$ xcodebuild -scheme FalcoFold -configuration Release build", "** BUILD SUCCEEDED **",
                     "$ open build/Build/Products/Release/FalcoFold.app", "$ █"] {
            mono(line, at: NSPoint(x: w2.minX + 20, y: y), color: NSColor(calibratedRed: 0.75, green: 0.95, blue: 0.7, alpha: 1)); y += 26
        }

        // Dock
        let dock = NSRect(x: b.width * 0.30, y: b.height - 78, width: b.width * 0.40, height: 66)
        NSColor(white: 1, alpha: 0.30).setFill()
        NSBezierPath(roundedRect: dock, xRadius: 18, yRadius: 18).fill()
        let colors: [NSColor] = [.systemBlue, .systemGray, .systemGreen, .systemOrange, .systemPurple, .systemTeal, .systemRed, .systemYellow, .systemIndigo]
        let step = dock.width / CGFloat(colors.count)
        for (i, c) in colors.enumerated() {
            c.setFill()
            NSBezierPath(roundedRect: NSRect(x: dock.minX + step * CGFloat(i) + (step - 48) / 2, y: dock.minY + 9, width: 48, height: 48), xRadius: 11, yRadius: 11).fill()
        }
    }

    private func window(_ r: NSRect, title: String, body: NSColor) {
        let shadow = NSShadow(); shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        body.setFill(); NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill()
        NSGraphicsContext.restoreGraphicsState()
        let bar = NSRect(x: r.minX, y: r.minY, width: r.width, height: 40)
        NSColor(white: body == .white ? 0.93 : 0.2, alpha: 1).setFill()
        let p = NSBezierPath(roundedRect: bar, xRadius: 12, yRadius: 12); p.appendRect(NSRect(x: r.minX, y: r.minY + 20, width: r.width, height: 20)); p.fill()
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill(); NSBezierPath(ovalIn: NSRect(x: r.minX + 14 + CGFloat(i) * 20, y: r.minY + 14, width: 12, height: 12)).fill()
        }
        text(title, at: NSPoint(x: r.midX - 30, y: r.minY + 11), size: 14, bold: true, color: body == .white ? .black : .white)
    }

    private func text(_ s: String, at p: NSPoint, size: CGFloat, bold: Bool, color: NSColor) {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: color]).draw(at: p)
    }
    private func mono(_ s: String, at p: NSPoint, color: NSColor) {
        NSAttributedString(string: s, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), .foregroundColor: color]).draw(at: p)
    }
}

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "30") ?? 30
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens.first { s in
    let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    return CGDisplayIsBuiltin(id) != 0
} ?? NSScreen.main!
let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 2)
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
window.ignoresMouseEvents = true
window.isOpaque = true
window.contentView = DesktopView(frame: NSRect(origin: .zero, size: screen.frame.size))
window.orderFrontRegardless()
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { app.terminate(nil) }
app.run()
