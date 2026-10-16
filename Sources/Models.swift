import Foundation

struct BreakConfig: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var enabled: Bool = true
    var everyMinutes: Double = 60
    var durationSeconds: Double = 600
    var theme: String = "Calm"
    var sound: String = "Glass"
    var postponeMinutes: Double = 5
    /// Next fire date, persisted so relaunch keeps schedule ("Restored ... was due in ...")
    var nextDue: Date? = nil
    /// Last completed break (shown as "done X ago").
    var lastDoneAt: Date? = nil
    /// Stable kind for built-ins ("normal"/"micro"), nil for custom breaks.
    var preset: String? = nil

    /// Display name honoring the UI language; user renames are respected.
    func displayName(_ lang: Lang) -> String {
        guard let p = preset else { return name }
        let known = ["Normal Break", "标准休息", "Micro Break", "微休息"]
        if !known.contains(name) { return name }
        if p == "normal" { return lang == .zh ? "标准休息" : "Normal Break" }
        if p == "micro" { return lang == .zh ? "微休息" : "Micro Break" }
        return name
    }

    static var normal: BreakConfig {
        BreakConfig(name: "标准休息", everyMinutes: 60, durationSeconds: 600, preset: "normal")
    }
    static var micro: BreakConfig {
        BreakConfig(name: "微休息", everyMinutes: 30, durationSeconds: 30, theme: "Stretch", sound: "Pop", preset: "micro")
    }
}

final class BreakStore: ObservableObject {
    @Published var breaks: [BreakConfig] {
        didSet { save() }
    }
    /// Completed-break counts for today ("今日完成 X 次"), reset on day change.
    @Published private(set) var doneToday: [String: Int] = [:]
    private let key = "BreakTime.breaks.v1"
    private let doneKey = "BreakTime.done.v1"
    private let dayKey = "BreakTime.doneDay.v1"

    private static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    func bumpDone(_ id: String) {
        if UserDefaults.standard.string(forKey: dayKey) != Self.today() {
            UserDefaults.standard.set(Self.today(), forKey: dayKey)
            doneToday = [:]
        }
        doneToday[id, default: 0] += 1
        if let data = try? JSONEncoder().encode(doneToday) {
            UserDefaults.standard.set(data, forKey: doneKey)
        }
    }

    /// "休息一小时"：暂停到指定时间。nil = 未暂停。
    var pausedUntil: Date? {
        get {
            guard let t = UserDefaults.standard.object(forKey: "BreakTime.pausedUntil") as? Date else { return nil }
            return t > Date() ? t : nil
        }
        set { UserDefaults.standard.set(newValue, forKey: "BreakTime.pausedUntil") }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let loaded = try? JSONDecoder().decode([BreakConfig].self, from: data),
           !loaded.isEmpty {
            breaks = loaded
        } else {
            breaks = [.normal, .micro]
        }
        // One-time migration: tag the built-ins so names can follow UI language.
        var changed = false
        for i in breaks.indices {
            if breaks[i].preset == nil {
                if breaks[i].name == "Normal Break" { breaks[i].preset = "normal"; changed = true }
                else if breaks[i].name == "Micro Break" { breaks[i].preset = "micro"; changed = true }
            }
        }
        if changed { save() }
        if UserDefaults.standard.string(forKey: dayKey) == Self.today(),
           let data = UserDefaults.standard.data(forKey: doneKey),
           let counts = try? JSONDecoder().decode([String: Int].self, from: data) {
            doneToday = counts
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(breaks) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func update(_ b: BreakConfig) {
        if let i = breaks.firstIndex(where: { $0.id == b.id }) {
            breaks[i] = b
        }
    }
}
