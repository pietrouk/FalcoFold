import Foundation

/// How strongly each part of the effect shows at full progress. Every value is 0…1.
struct EffectStyle: Equatable {
    var perspective: Double
    var blur: Double
    var shadow: Double
}

enum StylePreset: String, CaseIterable, Identifiable {
    case silk, shade, frost

    var id: String { rawValue }

    var name: String {
        switch self {
        case .silk: "Silk"
        case .shade: "Shade"
        case .frost: "Frost"
        }
    }

    var style: EffectStyle {
        switch self {
        case .silk: EffectStyle(perspective: 1.0, blur: 0.1, shadow: 0.3)
        case .shade: EffectStyle(perspective: 0.5, blur: 0.1, shadow: 0.9)
        case .frost: EffectStyle(perspective: 0.4, blur: 1.0, shadow: 0.25)
        }
    }
}

/// Everything the renderer needs besides the lid angle.
struct EffectParameters: Equatable {
    var style: EffectStyle
    /// The effect is fully clear at or above this angle.
    var clearAngle: Double
    /// The effect is at full strength at or below this angle.
    var closedAngle: Double
    /// Tilt the image back by as much as the lid came forward, so it holds its place from where you sit.
    var counterRotate: Bool

    func progress(at angle: Double) -> Double {
        min(max((clearAngle - angle) / (clearAngle - closedAngle), 0), 1)
    }
}

/// UserDefaults keys. The menu binds them with `@AppStorage`; `AppModel` observes them.
enum SettingsKey {
    static let manualMode = "manualMode"
    static let manualAngle = "manualAngle"
    static let preset = "preset"
    static let perspective = "perspective"
    static let blur = "blur"
    static let shadow = "shadow"
    static let clearAngle = "clearAngle"
    static let counterRotate = "counterRotate"
    static let paused = "paused"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"

    /// Keys that change what the effect does right now.
    static let all = [manualMode, manualAngle, preset, perspective, blur, shadow, clearAngle, counterRotate, paused]

    static func registerDefaults(in defaults: UserDefaults) {
        let style = StylePreset.silk.style
        defaults.register(defaults: [
            manualMode: false,
            manualAngle: 130.0,
            preset: StylePreset.silk.rawValue,
            perspective: style.perspective,
            blur: style.blur,
            shadow: style.shadow,
            clearAngle: 100.0,
            counterRotate: false,
            paused: false,
            hasCompletedOnboarding: false,
        ])
    }
}

/// Calls `onChange` on the main queue when any of `keys` changes, including changes made
/// from outside the app with `defaults write`.
final class DefaultsObserver: NSObject {
    private let defaults: UserDefaults
    private let keys: [String]
    private let onChange: () -> Void

    init(_ defaults: UserDefaults, keys: [String], onChange: @escaping () -> Void) {
        self.defaults = defaults
        self.keys = keys
        self.onChange = onChange
        super.init()
        for key in keys { defaults.addObserver(self, forKeyPath: key, options: [], context: nil) }
    }

    deinit {
        for key in keys { defaults.removeObserver(self, forKeyPath: key) }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async(execute: onChange)
    }
}
