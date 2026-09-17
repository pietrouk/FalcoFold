import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            StyleSettings()
                .tabItem { Label("Style", systemImage: "paintbrush") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding()
        .frame(width: 420, height: 470)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(SettingsKey.paused) private var paused = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Toggle("Pause FalcoFold", isOn: $paused)
            Text("Press Esc while the effect is showing to dismiss it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            LabeledContent("Lid angle sensor") {
                Text(model.sensorAvailable ? model.sensorAngle.map { "\(Int($0))°" } ?? "…" : "Not found")
                    .monospacedDigit()
            }
            Button("Show Welcome Guide…") { model.showOnboarding() }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct StyleSettings: View {
    @AppStorage(SettingsKey.perspective) private var perspective = StylePreset.silk.style.perspective
    @AppStorage(SettingsKey.blur) private var blur = StylePreset.silk.style.blur
    @AppStorage(SettingsKey.shadow) private var shadow = StylePreset.silk.style.shadow
    @AppStorage(SettingsKey.clearAngle) private var clearAngle = 100.0
    @AppStorage(SettingsKey.counterRotate) private var counterRotate = false

    var body: some View {
        Form {
            Section {
                StylePicker()
                ValueSlider(title: "Perspective", value: $perspective, range: 0...1, label: percent(perspective))
                ValueSlider(title: "Blur", value: $blur, range: 0...1, label: percent(blur))
                ValueSlider(title: "Shadow", value: $shadow, range: 0...1, label: percent(shadow))
            }
            Section {
                ValueSlider(title: "Clears when the lid opens past", value: $clearAngle, range: 60...130, step: 1,
                            label: "\(Int(clearAngle))°")
                Toggle("Hold its place from where you sit", isOn: $counterRotate)
            }
            Section("Preview") {
                ManualAngleControls()
            }
        }
        .formStyle(.grouped)
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("FalcoFold")
                .font(.title2.bold())
            Text(version)
                .foregroundStyle(.secondary)
            Text("Free and open source under the MIT License.\nNo accounts, no tracking. Screen frames never leave your Mac.")
                .multilineTextAlignment(.center)
                .font(.callout)
            Link("github.com/pietrouk/FalcoFold", destination: URL(string: "https://github.com/pietrouk/FalcoFold")!)
            Text("Copyright © 2026 Pietro Falcone")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
