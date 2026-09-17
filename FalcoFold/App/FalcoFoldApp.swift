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
    @AppStorage("manualMode") private var manualMode = false
    @AppStorage("manualAngle") private var manualAngle = 130.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Lid angle") {
                Text(model.sensorAvailable ? model.sensorAngle.map { "\(Int($0))°" } ?? "…" : "Unsupported hardware")
                    .monospacedDigit()
            }

            Toggle("Set angle by hand", isOn: $manualMode)
            HStack {
                Slider(value: $manualAngle, in: 0...130)
                Text("\(Int(manualAngle))°")
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            .disabled(!manualMode)

            LabeledContent("Tilt") {
                Text(model.progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }

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
        .frame(width: 260)
    }
}
