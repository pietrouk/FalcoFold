import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(SettingsKey.paused) private var paused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Lid angle") {
                Text(model.sensorAvailable ? model.sensorAngle.map { "\(Int($0))°" } ?? "…" : "Unsupported hardware")
                    .monospacedDigit()
            }

            Button {
                paused.toggle()
            } label: {
                Label(paused ? "Resume FalcoFold" : "Pause FalcoFold", systemImage: paused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            StylePicker()

            ManualAngleControls()

            if let message = model.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set Up…") { model.showOnboarding() }
            }

            Divider()
            HStack {
                Button("Settings…") { model.showSettings() }
                    .keyboardShortcut(",")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding()
        .frame(width: 280)
    }
}

/// Choosing a preset loads its slider values; the sliders stay editable afterwards.
struct StylePicker: View {
    @AppStorage(SettingsKey.preset) private var preset = StylePreset.silk
    @AppStorage(SettingsKey.perspective) private var perspective = StylePreset.silk.style.perspective
    @AppStorage(SettingsKey.blur) private var blur = StylePreset.silk.style.blur
    @AppStorage(SettingsKey.shadow) private var shadow = StylePreset.silk.style.shadow

    var body: some View {
        Picker("Style", selection: Binding(
            get: { preset },
            set: { newValue in
                preset = newValue
                perspective = newValue.style.perspective
                blur = newValue.style.blur
                shadow = newValue.style.shadow
            })
        ) {
            ForEach(StylePreset.allCases) { Text($0.name).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// Drives the effect from a slider instead of the sensor, to preview styles without moving the lid.
struct ManualAngleControls: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(SettingsKey.manualMode) private var manualMode = false
    @AppStorage(SettingsKey.manualAngle) private var manualAngle = 130.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Set angle by hand", isOn: $manualMode)
            ValueSlider(value: $manualAngle, range: 0...130, label: "\(Int(manualAngle))°")
                .disabled(!manualMode)
            LabeledContent("Effect strength") {
                Text(model.progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
        }
    }
}

struct ValueSlider: View {
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
