import AppKit
import os

/// Picks the angle source (sensor or manual slider), decides when the effect arms and clears,
/// and passes settings through to the effect.
@MainActor
final class AppModel: ObservableObject {
    static let closedAngle = 20.0
    /// The lid must open this far past the clear angle before the effect clears, so sensor jitter can't flicker it.
    static let hysteresis = 2.0
    /// Opening the lid this far above its lowest point and then stopping clears the effect, even below the clear angle.
    static let openingThreshold = 3.0
    static let settleDelay = Duration.milliseconds(300)

    @Published private(set) var sensorAngle: Double?
    @Published private(set) var sensorAvailable: Bool
    @Published private(set) var isArmed = false
    @Published private(set) var errorMessage: String?
    /// False in clamshell mode (lid closed with an external monitor), when the effect has nowhere to draw.
    @Published private(set) var builtInDisplayPresent = NSScreen.builtIn != nil

    private let defaults = UserDefaults.standard
    private let sensor = LidSensor()
    private let effect: TiltEffect?
    private let escapeHotKey = EscapeHotKey()
    private let windows = WindowPresenter()
    private var didPromptForScreenRecording = false
    private var observers: [Any] = []
    /// Lowest angle since the effect armed.
    private var lowestAngle: Double?
    /// Where the lid came to rest after opening. The effect stays clear until the lid closes past this again.
    private var restAngle: Double?
    private var settleAngle: Double?
    private var settleTask: Task<Void, Never>?
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

    var isPaused: Bool {
        get { defaults.bool(forKey: SettingsKey.paused) }
        set { defaults.set(newValue, forKey: SettingsKey.paused) }
    }

    var progress: Double {
        effectiveAngle.map { parameters.progress(at: $0) } ?? 0
    }

    init() {
        SettingsKey.registerDefaults(in: defaults)
        effect = TiltEffect()

        sensor.start()
        sensorAvailable = sensor.isAvailable
        sensor.onAngle = { [weak self] angle in
            MainActor.assumeIsolated {
                self?.sensorAngle = angle
                self?.update()
            }
        }

        sensor.onAvailabilityChange = { [weak self] available in
            MainActor.assumeIsolated {
                self?.sensorAvailable = available
                if !available { self?.sensorAngle = nil }
                self?.update()
            }
        }

        effect?.onError = { [weak self] error in
            self?.escapeHotKey.unregister()
            self?.errorMessage = error.localizedDescription
        }

        observers = [DefaultsObserver(defaults, keys: SettingsKey.all) { [weak self] in self?.update() }]
        observeSystemChanges()
        #if DEBUG
        observers.append(DebugSnapshot.observe(defaults))
        #endif
        if effect == nil { errorMessage = "Metal is not available on this Mac." }
        update()

        if !defaults.bool(forKey: SettingsKey.hasCompletedOnboarding) {
            // Wait for launch to finish, so the window can come to the front.
            DispatchQueue.main.async { self.showOnboarding() }
        }
    }

    // MARK: Windows

    func showSettings() {
        windows.show("settings", title: "FalcoFold Settings", kind: .floatingUtility) {
            SettingsView().environmentObject(self)
        }
    }

    func showOnboarding() {
        windows.show("onboarding", title: "Welcome to FalcoFold", kind: .regular) {
            OnboardingView().environmentObject(self)
        }
    }

    func finishOnboarding() {
        defaults.set(true, forKey: SettingsKey.hasCompletedOnboarding)
        windows.close("onboarding")
    }

    /// macOS only applies a new Screen Recording permission after the app restarts.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    self.errorMessage = "Couldn't relaunch: \(error.localizedDescription)"
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Display changes (external monitor, clamshell mode, resolution) and waking from sleep.
    private func observeSystemChanges() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log.info("Woke from sleep")
                self?.sensor.refresh()
                self?.screensChanged()
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
    }

    private func screensChanged() {
        let present = NSScreen.builtIn != nil
        if present != builtInDisplayPresent {
            log.notice("Built-in display \(present ? "is back" : "is off (clamshell mode?)", privacy: .public)")
            builtInDisplayPresent = present
        }
        effect?.screensChanged()
        update()
    }

    private func update() {
        objectWillChange.send()
        sensor.fastPollBelow = defaults.double(forKey: SettingsKey.clearAngle) + 15
        guard let effect else { return }

        guard let angle = effectiveAngle, !isPaused, builtInDisplayPresent else {
            setArmed(false)
            return
        }
        let parameters = parameters
        effect.parameters = parameters
        effect.targetAngle = angle
        if let rest = restAngle, angle <= rest - Self.openingThreshold || angle >= parameters.clearAngle {
            restAngle = nil
        }
        if !isArmed, angle < parameters.clearAngle, restAngle == nil {
            setArmed(true)
            lowestAngle = angle
        } else if isArmed, angle >= parameters.clearAngle + Self.hysteresis {
            setArmed(false)
        } else if isArmed {
            clearIfLidStopsOpening(at: angle)
        }
    }

    /// Once the lid is opening, clear as soon as it holds still, so the effect doesn't linger at a slightly lower angle.
    private func clearIfLidStopsOpening(at angle: Double) {
        let lowest = min(lowestAngle ?? angle, angle)
        lowestAngle = lowest
        guard angle >= lowest + Self.openingThreshold else {
            cancelSettle()
            return
        }
        // Restart the countdown only while the lid keeps opening; a one-degree wobble back doesn't count as movement.
        if let settleAngle, angle <= settleAngle { return }
        settleAngle = angle
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self, self.isArmed, let angle = self.effectiveAngle else { return }
            self.log.info("Lid stopped opening at \(angle, privacy: .public)°; clearing")
            self.restAngle = angle
            self.setArmed(false)
        }
    }

    private func cancelSettle() {
        settleTask?.cancel()
        settleTask = nil
        settleAngle = nil
    }

    /// A failed arm isn't retried until the lid clears again, so errors can't cause a restart loop.
    private func setArmed(_ armed: Bool) {
        guard armed != isArmed, let effect else { return }
        isArmed = armed
        lowestAngle = nil
        cancelSettle()
        guard armed else {
            escapeHotKey.unregister()
            effect.disarm()
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            log.notice("Screen Recording not granted")
            errorMessage = "FalcoFold needs Screen Recording permission."
            if !didPromptForScreenRecording {
                didPromptForScreenRecording = true
                showOnboarding()
            }
            return
        }
        errorMessage = nil
        effect.arm()
        guard effect.isArmed else { return }
        escapeHotKey.register { [weak self] in
            self?.log.info("Esc pressed; pausing")
            self?.isPaused = true
        }
    }
}
