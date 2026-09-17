import SwiftUI

@main
struct FalcoFoldApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("FalcoFold", systemImage: "laptopcomputer") {
            MenuView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(SettingsKey.manualMode) private var manualMode = false
    @AppStorage(SettingsKey.manualAngle) private var manualAngle = 130.0
    @AppStorage(SettingsKey.preset) private var preset = StylePreset.silk
    @AppStorage(SettingsKey.perspective) private var perspective = StylePreset.silk.style.perspective
    @AppStorage(SettingsKey.blur) private var blur = StylePreset.silk.style.blur
    @AppStorage(SettingsKey.shadow) private var shadow = StylePreset.silk.style.shadow
    @AppStorage(SettingsKey.clearAngle) private var clearAngle = 100.0
    @AppStorage(SettingsKey.counterRotate) private var counterRotate = false

    /// Choosing a preset loads its slider values; the sliders stay editable afterwards.
    private var presetSelection: Binding<StylePreset> {
        Binding(
            get: { preset },
            set: { newValue in
                preset = newValue
                perspective = newValue.style.perspective
                blur = newValue.style.blur
                shadow = newValue.style.shadow
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Lid angle") {
                Text(model.sensorAvailable ? model.sensorAngle.map { "\(Int($0))°" } ?? "…" : "Unsupported hardware")
                    .monospacedDigit()
            }

            Toggle("Set angle by hand", isOn: $manualMode)
            ValueSlider(value: $manualAngle, range: 0...130, label: "\(Int(manualAngle))°")
                .disabled(!manualMode)

            LabeledContent("Tilt") {
                Text(model.progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }

            Divider()

            Picker("Style", selection: presetSelection) {
                ForEach(StylePreset.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ValueSlider(title: "Perspective", value: $perspective, range: 0...1, label: percent(perspective))
            ValueSlider(title: "Blur", value: $blur, range: 0...1, label: percent(blur))
            ValueSlider(title: "Shadow", value: $shadow, range: 0...1, label: percent(shadow))
            ValueSlider(title: "Clears above", value: $clearAngle, range: 60...130, step: 1, label: "\(Int(clearAngle))°")
            Toggle("Hold its place from where you sit", isOn: $counterRotate)

            if let message = model.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Button("Quit FalcoFold") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 280)
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct ValueSlider: View {
    var title: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title { Text(title).font(.caption).foregroundStyle(.secondary) }
            HStack {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
                Text(label)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}
