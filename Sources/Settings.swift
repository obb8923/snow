import Foundation
import Combine

/// User-tunable values, persisted in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "enabled") } }
    /// near flakes per screen
    @Published var amount: Double { didSet { d.set(amount, forKey: "amount") } }
    @Published var speed: Double { didSet { d.set(speed, forKey: "speed") } }
    @Published var size: Double { didSet { d.set(size, forKey: "size") } }
    @Published var wind: Double { didSet { d.set(wind, forKey: "wind") } }
    /// 0...1, maps to angle of repose
    @Published var stick: Double { didSet { d.set(stick, forKey: "stick") } }
    @Published var melt: Double { didSet { d.set(melt, forKey: "melt") } }

    private init() {
        d.register(defaults: [
            "enabled": true, "amount": 75.0, "speed": 0.8, "size": 1.4,
            "wind": 0.0, "stick": 0.45, "melt": 0.0,
        ])
        enabled = d.bool(forKey: "enabled")
        amount = d.double(forKey: "amount")
        speed = d.double(forKey: "speed")
        size = d.double(forKey: "size")
        wind = d.double(forKey: "wind")
        stick = d.double(forKey: "stick")
        melt = d.double(forKey: "melt")
    }
}
