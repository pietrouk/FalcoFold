import AppKit
import os

/// Picks the angle source (sensor or manual slider), decides when the effect arms and clears,
/// and passes settings through to the effect.
@MainActor
final class AppModel: ObservableObject {
    static let closedAngle = 20.0
    /// The lid must open this far past the clear angle before the effect clears, so sensor jitter can't flicker it.
    static let hysteresis = 2.0

    @Published private(set) var sensorAngle: Double?
    @Published private(set) var sensorAvailable: Bool
    @Published private(set) var isArmed = false
    @Published private(set) var errorMessage: String?

    private let defaults = UserDefaults.standard
    private let sensor = LidSensor()
    private let effect = TiltEffect()
    private var observers: [NSObject] = []
    private let log = Logger(subsystem: "io.github.pietrouk.FalcoFold", category: "AppModel")

    var parameters: EffectParameters {
        EffectParameters(
            style: EffectStyle(
                perspective: defaults.double(forKey: SettingsKey.perspective),
                blur: defaults.double(forKey: SettingsKey.blur),
                shadow: defaults.double(forKey: SettingsKey.shadow)),
            clearAngle: defaults.double(forKey: SettingsKey.clearAngle),
            closedAngle: Self.closedAngle,
            counterRotate: defaults.bool(forKey: SettingsKey.counterRotate))
    }

    var effectiveAngle: Double? {
        defaults.bool(forKey: SettingsKey.manualMode) ? defaults.double(forKey: SettingsKey.manualAngle) : sensorAngle
    }

    var progress: Double {
        effectiveAngle.map { parameters.progress(at: $0) } ?? 0
    }

    init() {
        SettingsKey.registerDefaults(in: defaults)

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

        observers = [DefaultsObserver(defaults, keys: SettingsKey.all) { [weak self] in self?.update() }]
        #if DEBUG
        observers.append(DebugSnapshot.observe(defaults))
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
        let parameters = parameters
        effect.parameters = parameters
        effect.targetAngle = angle
        if !isArmed, angle < parameters.clearAngle {
            setArmed(true)
        } else if isArmed, angle >= parameters.clearAngle + Self.hysteresis {
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
