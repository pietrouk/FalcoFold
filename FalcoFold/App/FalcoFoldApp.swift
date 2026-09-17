import SwiftUI

@main
struct FalcoFoldApp: App {
    var body: some Scene {
        MenuBarExtra("FalcoFold", systemImage: "laptopcomputer") {
            Text("FalcoFold")
            Divider()
            Button("Quit FalcoFold") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
