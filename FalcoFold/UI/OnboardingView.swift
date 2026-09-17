import Combine
import SwiftUI

/// First-launch guide: checks the lid sensor and walks through Screen Recording permission.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var hasScreenRecording = CGPreflightScreenCaptureAccess()
    @State private var didRequest = false
    private let recheck = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 40))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to FalcoFold")
                        .font(.title2.bold())
                    Text("As you lower the lid, your desktop tilts, blurs and dims. Open it again and it snaps back.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Step(state: model.sensorAvailable ? .done : .failed, title: "Lid angle sensor") {
                if model.sensorAvailable {
                    Text("Found. The lid is at \(model.sensorAngle.map { "\(Int($0))°" } ?? "…").")
                } else {
                    Text("Not found. FalcoFold needs an Apple silicon MacBook with a lid angle sensor.")
                }
            }

            Step(state: hasScreenRecording ? .done : .todo, title: "Screen Recording") {
                if hasScreenRecording {
                    Text("Allowed. Frames are only shown on screen; nothing is saved or sent.")
                } else {
                    Text("FalcoFold draws a live copy of your desktop, so it needs Screen Recording permission. Frames are only shown on screen; nothing is saved or sent.")
                    HStack {
                        Button("Allow Screen Recording…", action: requestScreenRecording)
                        if didRequest {
                            Button("Relaunch FalcoFold") { model.relaunch() }
                        }
                    }
                    if didRequest {
                        Text("Turn on FalcoFold in System Settings, then relaunch.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Step(state: .info, title: "Try it") {
                Text("Slowly lower the lid. Press Esc while the effect is showing to dismiss it. Styles and settings are in the menu bar.")
            }

            HStack {
                Spacer()
                Button("Done") { model.finishOnboarding() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onReceive(recheck) { _ in hasScreenRecording = CGPreflightScreenCaptureAccess() }
    }

    private func requestScreenRecording() {
        didRequest = true
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct Step<Detail: View>: View {
    enum Status { case done, todo, failed, info }

    let state: Status
    let title: String
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .font(.title2)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                detail
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .todo: Image(systemName: "circle.dashed").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .info: Image(systemName: "hand.point.right.fill").foregroundStyle(.secondary)
        }
    }
}
