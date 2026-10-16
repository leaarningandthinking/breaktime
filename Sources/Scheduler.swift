import AppKit
import Combine

/// Mirror of Time Out's scheduler: per-break countdown ("due in"), idle pause,
/// postpone / skip / done, persisted next-due dates.
@MainActor
final class BreakScheduler: ObservableObject {
    @Published var now = Date()
    @Published var activeBreak: ActiveBreak? = nil

    struct ActiveBreak: Identifiable {
        let id = UUID()
        var config: BreakConfig
        var endsAt: Date
        var remaining: TimeInterval { max(0, endsAt.timeIntervalSince(Date())) }
    }

    private let store: BreakStore
    private let rules: RuleStore
    /// Set by the App after init; used for overlay language.
    var lang: AppLanguage?
    private var timer: Timer?
    private let idlePauseSeconds = 60.0
    /// A break overdue longer than this is treated as missed (machine was
    /// off/asleep) and silently rescheduled — never ambush on launch.
    private let maxOverdueSeconds = 300.0

    init(store: BreakStore, rules: RuleStore) {
        self.store = store
        self.rules = rules
        NSLog("BreakTime: scheduler init, breaks=%d", store.breaks.count)
        // First launch: schedule from now (like a fresh install).
        for i in store.breaks.indices where store.breaks[i].nextDue == nil {
            store.breaks[i].nextDue = Date().addingTimeInterval(store.breaks[i].everyMinutes * 60)
        }
        // Timer fires on the main run loop, so we are already on the main actor
        // here — no hop needed. `[weak self]` keeps the timer from retaining the
        // scheduler (capturing the weak binding in a Task would be a data race).
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func nextDueText(lang: Lang) -> String {
        if let p = store.pausedUntil {
            let f = DateFormatter()
            f.dateFormat = lang == .zh ? "H:mm" : "h:mm a"
            let t = Strings.table[lang]?["menu.pausedUntil"] ?? ""
            return "\(t) \(f.string(from: p))"
        }
        return Self.nextDueText(breaks: store.breaks, lang: lang)
    }

    static func nextDueText(breaks: [BreakConfig], lang: Lang) -> String {
        let upcoming = breaks.filter(\.enabled).compactMap { b -> (BreakConfig, Date)? in
            guard let d = b.nextDue else { return nil }
            return (b, d)
        }.sorted { $0.1 < $1.1 }.first
        guard let (b, d) = upcoming else { return Strings.table[lang]?["menu.none"] ?? "—" }
        let s = max(0, Int(d.timeIntervalSinceNow))
        let name = b.displayName(lang)
        if lang == .zh {
            return "\(name)还剩\(s / 60)分\(s % 60)秒"
        }
        return "\(name) in \(s / 60)m \(s % 60)s"
    }

    private func tick() {
        now = Date()
        guard activeBreak == nil else { return }
        if store.pausedUntil != nil { return }  // user-paused ("休息一小时")
        if Self.idleSeconds() > idlePauseSeconds { return }  // pause while away
        for i in store.breaks.indices {
            var b = store.breaks[i]
            guard b.enabled else { continue }
            if b.nextDue == nil {
                b.nextDue = now.addingTimeInterval(b.everyMinutes * 60)
                store.update(b); continue
            }
            if now >= b.nextDue! {
                if now.timeIntervalSince(b.nextDue!) > maxOverdueSeconds {
                    b.nextDue = now.addingTimeInterval(b.everyMinutes * 60)
                    store.update(b)
                    NSLog("BreakTime: missed %@ (overdue), rescheduled", b.name)
                    continue
                }
                ToastController.shared.reset()
                if let rule = MeetingDetector.matchingRule(rules.rules) {
                    // Exclusion hit (e.g. in a meeting): skip or postpone instead of interrupting.
                    if rule.action == .postpone {
                        b.nextDue = now.addingTimeInterval(b.postponeMinutes * 60)
                        NSLog("BreakTime: postponed %@ by rule %@ (meeting)", b.name, rule.displayName)
                    } else {
                        b.nextDue = now.addingTimeInterval(b.everyMinutes * 60)
                        NSLog("BreakTime: skipped %@ by rule %@ (meeting)", b.name, rule.displayName)
                    }
                    store.update(b)
                    continue
                }
                NSLog("BreakTime: DUE %@ now=%f due=%f", b.name, now.timeIntervalSinceReferenceDate, b.nextDue!.timeIntervalSinceReferenceDate)
                startBreak(config: b)
                return
            }
        }
        // Pre-break heads-up (toast) when the nearest break is under a minute away.
        // Off by default; toggle in General prefs.
        if UserDefaults.standard.bool(forKey: "BreakTime.warnBefore") {
            if let (b, d) = store.breaks.filter(\.enabled).compactMap({ x -> (BreakConfig, Date)? in
                guard let dd = x.nextDue else { return nil }
                return (x, dd)
            }).sorted(by: { $0.1 < $1.1 }).first {
                let delta = d.timeIntervalSince(now)
                if delta > 0, delta <= 60 {
                    let key = "\(b.id)-\(Int(d.timeIntervalSinceReferenceDate))"
                    let title = b.displayName((lang ?? AppLanguage()).lang)
                    let secs = Int(delta)
                    let appLang = lang ?? AppLanguage()
                    ToastController.shared.showOnce(key: key, title: title, seconds: secs, lang: appLang, onSkip: { [weak self] in
                        guard let self else { return }
                        var bb = b
                        bb.nextDue = Date().addingTimeInterval(bb.everyMinutes * 60)
                        self.store.update(bb)
                    }, onPostpone: { [weak self] in
                        guard let self else { return }
                        var bb = b
                        bb.nextDue = Date().addingTimeInterval(bb.postponeMinutes * 60)
                        self.store.update(bb)
                    })
                }
            }
        }
    }

    func startBreak(config: BreakConfig) {
        NSLog("BreakTime: starting break %@ duration %.0f", config.name, config.durationSeconds)
        activeBreak = ActiveBreak(config: config, endsAt: Date().addingTimeInterval(config.durationSeconds))
        OverlayController.shared.show(config: config, scheduler: self, lang: lang ?? AppLanguage())
        ToastController.shared.hide()
    }

    /// Break finished naturally or Done pressed: full reset (mirrors "Solved expression" logging point).
    func finishBreak() {
        guard let a = activeBreak else { return }
        var b = a.config
        b.nextDue = Date().addingTimeInterval(b.everyMinutes * 60)
        b.lastDoneAt = Date()
        store.update(b)
        store.bumpDone(b.id)
        NSLog("BreakTime: finished %@: next due in %.0f seconds", b.name, b.everyMinutes * 60)
        activeBreak = nil
        OverlayController.shared.hide()
    }

    func postponeActive() {
        guard let a = activeBreak else { return }
        var b = a.config
        b.nextDue = Date().addingTimeInterval(b.postponeMinutes * 60)
        store.update(b)
        NSLog("BreakTime: postponed %@ by %.0f minutes", b.name, b.postponeMinutes)
        activeBreak = nil
        OverlayController.shared.hide()
    }

    func skipActive() {
        guard let a = activeBreak else { return }
        var b = a.config
        b.nextDue = Date().addingTimeInterval(b.everyMinutes * 60)
        store.update(b)
        NSLog("BreakTime: skipped %@", b.name)
        activeBreak = nil
        OverlayController.shared.hide()
    }
}
