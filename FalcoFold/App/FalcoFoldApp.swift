import SwiftUI

@main
struct FalcoFoldApp: App {
    @StateObject private var model = AppModel()
    @AppStorage(SettingsKey.paused) private var paused = false

    var body: some Scene {
        MenuBarExtra("FalcoFold", systemImage: paused ? "laptopcomputer.slash" : "laptopcomputer") {
            MenuView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
