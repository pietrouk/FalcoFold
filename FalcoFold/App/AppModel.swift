import AppKit
import os

extension UserDefaults {
    // KVO-observable, so changes from the menu or from `defaults write` apply immediately.
    @objc dynamic var manualMode: Bool { bool(forKey: "manualMode") }
    @objc dynamic var manualAngle: Double { double(forKey: "manualAngle") }
}

/// Picks the angle source (sensor or manual slider), maps it to tilt progress, and arms or clears the effect.
@MainActor
final class AppModel: ObservableObject {
    // Fixed for M1; these become settings in M2.
    static let clearAngle = 100.0
    static let closedAngle = 20.0
    static let hysteresis = 2.0

    @Published private(set) var sensorAngle: Double?
    @Published private(set) var sensorAvailable: Bool
    @Published private(set) var isArmed = false
    @Published private(set) var errorMessage: String?

    private let defaults = UserDefaults.standard
    private let sensor = LidSensor()
    private let effect = TiltEffect()
    private var observations: [NSKeyValueObservation] = []
    private let log = Logger(subsystem: "io.github.pietrouk.FalcoFold", category: "AppModel")

    var effectiveAngle: Double? {
        defaults.manualMode ? defaults.manualAngle : sensorAngle
    }

    var progress: Double {
        guard let angle = effectiveAngle else { return 0 }
        let value = (Self.clearAngle - angle) / (Self.clearAngle - Self.closedAngle)
        return min(max(value, 0), 1)
    }

    init() {
        defaults.register(defaults: ["manualMode": false, "manualAngle": 130.0])

        sensor.start()
        sensorAvailable = sensor.isAvailable
        sensor.onAngle = { [weak self] angle in
            MainActor.assumeIsolated {
                self?.sensorAngle = angle
                self?.update()
            }
        }

        effect?.onError = { [weak self] error in
            self?.errorMessage = error.localizedDescription
        }

        observations = [
            defaults.observe(\.manualMode) { [weak self] _, _ in
                DispatchQueue.main.async { self?.update() }
            },
            defaults.observe(\.manualAngle) { [weak self] _, _ in
                DispatchQueue.main.async { self?.update() }
            },
        ]
        #if DEBUG
        observations.append(DebugSnapshot.observe(defaults))
        #endif
        if effect == nil { errorMessage = "Metal is not available on this Mac." }
        update()
    }

    private func update() {
        objectWillChange.send()
        guard let effect else { return }

        guard let angle = effectiveAngle else {
            setArmed(false)
            return
        }
        effect.progress = Float(progress)
        if !isArmed, angle < Self.clearAngle {
            setArmed(true)
        } else if isArmed, angle >= Self.clearAngle + Self.hysteresis {
            setArmed(false)
        }
    }

    /// A failed arm isn't retried until the lid clears again, so errors can't cause a restart loop.
    private func setArmed(_ armed: Bool) {
        guard armed != isArmed, let effect else { return }
        isArmed = armed
        guard armed else {
            effect.disarm()
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            log.notice("Screen Recording not granted; requesting")
            CGRequestScreenCaptureAccess()
            errorMessage = "Allow FalcoFold in System Settings → Privacy & Security → Screen Recording, then relaunch."
            return
        }
        errorMessage = nil
        effect.arm()
    }
}
