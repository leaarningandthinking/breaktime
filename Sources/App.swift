import SwiftUI
import ServiceManagement
import AppKit

/// Dock click (reopen) → bring up the prefs window. A MenuBarExtra-first app
/// does not auto-open its WindowGroup, so we trigger the scene through its
/// `breaktime://prefs` deep link; AppKit delivers the Dock click through
/// window restoration, so we also react to activation.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Bundle identifier used by early development builds. Settings live in the
    /// bundle-id domain, so changing the id would silently reset everything.
    private static let legacyBundleID = "com.example.breaktime"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.migrateLegacySettings()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NSApp.activate(ignoringOtherApps: true)
        Self.openPrefsWindow()
        Self.dedupePrefsWindows()
    }

    /// Carry over breaks, rules, language and preferences from the old bundle
    /// identifier the first time this build runs. Existing values always win,
    /// so this never overwrites a user's current setup.
    private static func migrateLegacySettings() {
        guard let legacy = UserDefaults(suiteName: legacyBundleID),
              let domain = legacy.persistentDomain(forName: legacyBundleID)
        else { return }
        let current = UserDefaults.standard
        for (key, value) in domain where key.hasPrefix("BreakTime.") {
            if current.object(forKey: key) == nil {
                current.set(value, forKey: key)
            }
        }
    }

    @objc private func appBecameActive() {
        guard !Self.anyVisibleWindow() else { return }
        Self.openPrefsWindow()
    }

    /// Dock-icon click while the app is already frontmost: AppKit routes this
    /// through reopen, not activation.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.openPrefsWindow() }
        return true
    }

    /// The prefs window is the only titled window we own (the break overlay and
    /// menu-bar extras are borderless).
    static func prefsWindow() -> NSWindow? {
        NSApp.windows.first { $0.styleMask.contains(.titled) && $0.isVisible }
    }

    private static func anyVisibleWindow() -> Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeKey }
    }

    /// Front the prefs window if it exists, otherwise ask the scene to open it.
    static func openPrefsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = prefsWindow() {
            w.makeKeyAndOrderFront(nil)
            return
        }
        if let url = URL(string: "breaktime://prefs") {
            NSWorkspace.shared.open(url)
        }
        dedupePrefsWindows()
    }

    /// SwiftUI sometimes materialises the scene more than once (auto-open plus
    /// the deep link); keep a single prefs window.
    static func dedupePrefsWindows() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            let titled = NSApp.windows.filter { $0.styleMask.contains(.titled) && $0.isVisible }
            for w in titled.dropFirst() { w.close() }
        }
    }
}

@main
struct BreakTimeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store: BreakStore
    @StateObject private var ruleStore: RuleStore
    @StateObject private var scheduler: BreakScheduler
    @StateObject private var lang = AppLanguage()

    init() {
        let s = BreakStore()
        let r = RuleStore()
        let l = AppLanguage()
        let sch = BreakScheduler(store: s, rules: r)
        sch.lang = l
        _store = StateObject(wrappedValue: s)
        _ruleStore = StateObject(wrappedValue: r)
        _lang = StateObject(wrappedValue: l)
        _scheduler = StateObject(wrappedValue: sch)
    }

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 2) {
                Text(scheduler.nextDueText(lang: lang.lang)).font(.headline)
                if store.pausedUntil != nil {
                    Button(lang.t("menu.resume")) { store.pausedUntil = nil }
                } else {
                    Button(lang.t("menu.pause")) {
                        store.pausedUntil = Date().addingTimeInterval(3600)
                    }
                }
            }
            Divider()
            Button(lang.t("menu.start")) {
                if let b = store.breaks.first(where: \.enabled) { scheduler.startBreak(config: b) }
            }
            Button {
                AppDelegate.openPrefsWindow()
            } label: {
                Text(lang.t("menu.prefs"))
            }.keyboardShortcut(",")
            Divider()
            Button(lang.t("menu.quit")) { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Text(menuTitle()).font(.system(size: 12, design: .monospaced))
        }

        // Standard window scene: full traffic lights, Dock-click reopens it.
        // A MenuBarExtra-first app won't auto-open this scene, so the delegate
        // opens it via the breaktime://prefs deep link.
        WindowGroup(lang.t("menu.prefs"), id: "prefs") {
            PrefsWindow(store: store, ruleStore: ruleStore, scheduler: scheduler, lang: lang)
        }
        .handlesExternalEvents(matching: ["prefs"])
        .defaultSize(width: 820, height: 540)
        .windowResizability(.contentMinSize)
    }

    private func menuTitle() -> String {
        if scheduler.activeBreak != nil { return "☕" }
        if store.pausedUntil != nil { return "⏸" }
        return "⏾ " + shortCountdown()
    }

    private func shortCountdown() -> String {
        let next = store.breaks.filter(\.enabled).compactMap(\.nextDue).sorted().first
        guard let d = next else { return "--" }
        let s = max(0, Int(d.timeIntervalSinceNow))
        if s >= 3600 { return String(format: "%dh%02d", s / 3600, (s % 3600) / 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct PrefsWindow: View {
    @ObservedObject var store: BreakStore
    @ObservedObject var ruleStore: RuleStore
    @ObservedObject var scheduler: BreakScheduler
    @ObservedObject var lang: AppLanguage

    var body: some View {
        PrefsView(store: store, ruleStore: ruleStore, scheduler: scheduler, lang: lang)
            .navigationTitle("BreakTime")
            .toolbar { WindowToolbar(store: store, scheduler: scheduler) }
            .frame(minWidth: 780, minHeight: 520)
    }
}

/// App icon + 立刻休息 + 暂停/恢复, sitting in the window title bar.
struct WindowToolbar: View {
    @ObservedObject var store: BreakStore
    @ObservedObject var scheduler: BreakScheduler
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            AppMark()
            Text(scheduler.nextDueText(lang: AppLanguage().lang))
                .font(.headline)
                .foregroundColor(.secondary)
            Spacer()
            if store.pausedUntil != nil {
                Button { store.pausedUntil = nil } label: {
                    Label(LocalizedStrings.shared.resume, systemImage: "play.fill")
                }
            } else {
                Menu {
                    Button(LocalizedStrings.shared.pause1h) { store.pausedUntil = Date().addingTimeInterval(3600) }
                } label: {
                    Label(LocalizedStrings.shared.pause, systemImage: "pause.fill")
                }
            }
            Button {
                if let b = store.breaks.first(where: \.enabled) { scheduler.startBreak(config: b) }
            } label: {
                Label(LocalizedStrings.shared.start, systemImage: "cup.and.saucer.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(brand)
        }
    }
}

/// Small app-icon glyph (same design as the .icns), drawn in code.
struct AppMark: View {
    var size: CGFloat = 26

    var body: some View {
        let barH = size * 0.40
        let barW = size * 0.13
        let gap = size * 0.06
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.18, green: 0.66, blue: 0.55),
                                              Color(red: 0.05, green: 0.25, blue: 0.21)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .stroke(Color.white, lineWidth: size * 0.085)
                .padding(size * 0.155)
            HStack(spacing: gap) {
                RoundedRectangle(cornerRadius: size * 0.05)
                    .fill(Color.white)
                    .frame(width: barW, height: barH)
                RoundedRectangle(cornerRadius: size * 0.05)
                    .fill(Color.white)
                    .frame(width: barW, height: barH)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("BreakTime")
    }
}

/// Screen-reader + shared strings for the toolbar (current UI language).
/// Immutable after init, so it is safe to share across concurrency domains.
final class LocalizedStrings: Sendable {
    static let shared = LocalizedStrings()
    let lang: Lang
    init() { lang = UserDefaults.standard.string(forKey: "BreakTime.lang").flatMap(Lang.init) ?? .zh }
    var start: String { Strings.table[lang]?["menu.start"] ?? "立刻休息" }
    var pause: String { Strings.table[lang]?["menu.pause"] ?? "暂停" }
    var pause1h: String { Strings.table[lang]?["menu.pause"] ?? "暂停 1 小时" }
    var resume: String { Strings.table[lang]?["menu.resume"] ?? "恢复休息" }
}

enum PrefsTab: String, CaseIterable {
    case activity, rules, general
}

private let card = Color(nsColor: .controlBackgroundColor)
let brand = Color(red: 0.16, green: 0.62, blue: 0.52)

struct PrefsView: View {
    @ObservedObject var store: BreakStore
    @ObservedObject var ruleStore: RuleStore
    @ObservedObject var scheduler: BreakScheduler
    @ObservedObject var lang: AppLanguage
    @State private var tab: PrefsTab = .activity
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var newAppId = ""
    @State private var warnBefore = UserDefaults.standard.bool(forKey: "BreakTime.warnBefore")

    private func tabName(_ t: PrefsTab) -> String {
        switch t {
        case .activity: return lang.t("tab.activity")
        case .rules: return lang.t("tab.rules")
        case .general: return lang.t("tab.general")
        }
    }

    private func tabIcon(_ t: PrefsTab) -> String {
        switch t {
        case .activity: return "list.bullet.rectangle.fill"
        case .rules: return "slider.horizontal.3"
        case .general: return "gearshape.fill"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar （目录）.
            VStack(alignment: .leading, spacing: 4) {
                SideButton(icon: "activity", title: tabName(.activity), selected: tab == .activity) { tab = .activity }
                Text(lang.t("sec.breaks")).font(.caption).foregroundColor(.secondary).padding(.top, 8).padding(.leading, 8)
                ForEach(store.breaks) { b in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Circle().fill(b.enabled ? Color.green : Color.red)
                                .frame(width: 9, height: 9)
                                .shadow(color: (b.enabled ? Color.green : Color.red).opacity(0.6), radius: 4)
                            Text(b.displayName(lang.lang)).font(.callout).bold()
                            Spacer()
                            if let n = store.doneToday[b.id], n > 0 {
                                Text("\(n)").font(.caption).foregroundColor(.white)
                                    .padding(.horizontal, 7).padding(.vertical, 1)
                                    .background(brand).cornerRadius(8)
                            }
                        }
                        Text(statusLine(for: b)).font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                }
                Text(lang.t("sec.options")).font(.caption).foregroundColor(.secondary).padding(.top, 8).padding(.leading, 8)
                SideButton(icon: tabIcon(.rules), title: tabName(.rules), selected: tab == .rules) { tab = .rules }
                SideButton(icon: tabIcon(.general), title: tabName(.general), selected: tab == .general) { tab = .general }
                Spacer()
            }
            .padding(12).frame(width: 240)
            Divider()
            Group {
                switch tab {
                case .activity: activityDetail
                case .rules: rulesDetail
                case .general: generalDetail
                }
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .preferredColorScheme(.dark)
        .tint(brand)
    }

    private func statusLine(for b: BreakConfig) -> String {
        _ = scheduler.now  // refresh every tick
        var parts: [String] = []
        if let d = b.nextDue {
            parts.append("\(lang.t("status.due")) " + Self.relative(d, lang: lang.lang))
        }
        if let done = b.lastDoneAt {
            parts.append("\(lang.t("status.done")) " + Self.relativePast(done, lang: lang.lang) + lang.t("status.ago"))
        }
        let n = store.doneToday[b.id] ?? 0
        if n > 0 {
            parts.append(lang.lang == .zh ? "今日完成 \(n) 次" : "done today \(n) times")
        }
        parts.append(b.enabled ? lang.t("status.active") : lang.t("status.paused"))
        return parts.joined(separator: "\n")
    }

    static func relative(_ d: Date, lang: Lang) -> String {
        formatSpan(max(0, Int(d.timeIntervalSinceNow)), lang: lang)
    }

    static func relativePast(_ d: Date, lang: Lang) -> String {
        formatSpan(max(0, Int(Date().timeIntervalSince(d))), lang: lang)
    }

    static func formatSpan(_ s: Int, lang: Lang) -> String {
        let uS = Strings.table[lang]?["unit.sec"] ?? "s"
        let uM = Strings.table[lang]?["unit.min"] ?? "m"
        let uH = Strings.table[lang]?["unit.hour"] ?? "h"
        if lang == .zh {
            if s < 60 { return "\(s)\(uS)" }
            if s < 3600 { return "\(s / 60)\(uM)\(s % 60)\(uS)" }
            return "\(s / 3600)\(uH)\((s % 3600) / 60)\(uM)"
        }
        if s < 60 { return "in \(s) sec" }
        if s < 3600 { return "in \(s / 60) min, \(s % 60) sec" }
        return "in \(s / 3600)h \((s % 3600) / 60)m"
    }

    // MARK: - Activity (per-break schedule editor)
    private var activityDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach($store.breaks) { $b in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "cup.and.saucer.fill").foregroundColor(brand)
                            Toggle(b.displayName(lang.lang), isOn: $b.enabled).font(.headline)
                            Spacer()
                            Button(role: .destructive) {
                                store.breaks.removeAll { $0.id == b.id }
                            } label: {
                                Label(lang.t("ed.delete"), systemImage: "trash")
                            }.buttonStyle(.bordered).controlSize(.small)
                        }
                        Divider()
                        LabeledStepper(title: lang.t("ed.everyMin"), value: $b.everyMinutes, range: 1...480, step: 1)
                        LabeledStepper(title: lang.t("ed.durSec"), value: $b.durationSeconds, range: 5...3600, step: 5)
                        HStack {
                            Text(lang.t("ed.theme")).frame(width: 90, alignment: .leading)
                            TextField(lang.t("ed.themePh"), text: $b.theme).textFieldStyle(.roundedBorder)
                        }.font(.callout)
                        HStack {
                            Text(lang.t("ed.sound")).frame(width: 90, alignment: .leading)
                            TextField(lang.t("ed.soundPh"), text: $b.sound).textFieldStyle(.roundedBorder)
                        }.font(.callout)
                        LabeledStepper(title: lang.t("ed.snoozeMin"), value: $b.postponeMinutes, range: 1...60, step: 1)
                        HStack {
                            Text(lang.t("ed.name")).frame(width: 90, alignment: .leading)
                            TextField(b.displayName(lang.lang), text: Binding(
                                get: { b.preset == nil ? b.name : "" },
                                set: { b.name = $0; b.preset = $0.isEmpty ? b.preset : nil }
                            )).textFieldStyle(.roundedBorder)
                        }.font(.callout)
                    }
                    .padding(14)
                    .background(card)
                    .cornerRadius(12)
                }
                Button {
                    store.breaks.append(BreakConfig(name: lang.lang == .zh ? "自定义休息" : "Custom Break"))
                } label: {
                    Label(lang.t("ed.addBreak"), systemImage: "plus.circle.fill")
                }.buttonStyle(.borderedProminent)
                Text(lang.t("ed.soundsHint"))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Rules ("If [app] is [frontmost] [automatically skip]")
    private var rulesDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(lang.t("rules.title"), systemImage: "moon.zzz.fill").font(.headline)
            Text(lang.t("rules.sub"))
                .font(.callout).foregroundColor(.secondary)
            Divider()
            ForEach($ruleStore.rules) { $r in
                HStack(spacing: 8) {
                    Toggle("", isOn: $r.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    Image(systemName: r.kind == .app ? "app.fill" : "display").foregroundColor(brand)
                    Text(lang.t("rules.if"))
                    if r.kind == .app {
                        Text(r.displayName).frame(width: 150, alignment: .leading).bold()
                        Text(lang.t("rules.frontmost"))
                    } else {
                        Text(r.localizedName(lang.lang)).frame(width: 248, alignment: .leading).bold()
                    }
                    Picker("", selection: $r.action) {
                        Text(lang.t("rules.skip")).tag(ExclusionRule.Action.skip)
                        Text(lang.t("rules.postpone")).tag(ExclusionRule.Action.postpone)
                    }.frame(width: 180)
                    Spacer()
                    Button(role: .destructive) {
                        ruleStore.rules.removeAll { $0.id == r.id }
                    } label: { Image(systemName: "minus.circle.fill") }.buttonStyle(.plain).foregroundColor(.secondary)
                }
                .font(.callout)
                .padding(.vertical, 3)
                Divider()
            }
            HStack {
                TextField(lang.t("rules.hint"), text: $newAppId).textFieldStyle(.roundedBorder).frame(width: 300)
                Button(lang.t("rules.add")) {
                    let id = newAppId.trimmingCharacters(in: .whitespaces)
                    guard !id.isEmpty else { return }
                    ruleStore.rules.append(ExclusionRule(target: id, displayName: id))
                    newAppId = ""
                }.buttonStyle(.borderedProminent).controlSize(.small)
            }.font(.callout).padding(.top, 4)
            Spacer()
        }
    }

    // MARK: - General
    private var generalDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(lang.t("sec.options"), systemImage: "gearshape.fill").font(.headline)
            SettingRow(icon: "power", title: lang.t("gen.login")) {
                Toggle("", isOn: $launchAtLogin)
                    .labelsHidden().toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, v in
                        try? v ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
            }
            SettingRow(icon: "bell.badge.fill", title: lang.t("gen.warn")) {
                Toggle("", isOn: $warnBefore)
                    .labelsHidden().toggleStyle(.switch)
                    .onChange(of: warnBefore) { _, v in
                        UserDefaults.standard.set(v, forKey: "BreakTime.warnBefore")
                    }
            }
            SettingRow(icon: "rectangle.on.rectangle.fill", title: lang.t("gen.mode")) {
                Picker("", selection: Binding(
                    get: { OverlayController.mode },
                    set: { OverlayController.mode = $0 }
                )) {
                    Text(lang.t("gen.full")).tag(OverlayMode.full)
                    Text(lang.t("gen.float")).tag(OverlayMode.float)
                }.frame(width: 220)
            }
            SettingRow(icon: "globe", title: lang.t("gen.lang")) {
                Picker("", selection: $lang.lang) {
                    Text("中文").tag(Lang.zh)
                    Text("English").tag(Lang.en)
                }.frame(width: 180)
            }
            Text(lang.t("gen.idle"))
                .font(.callout).foregroundColor(.secondary).padding(.top, 4)
            Spacer()
        }
    }
}

struct SideButton: View {
    let icon: String
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundColor(selected ? .white : brand).frame(width: 20)
                Text(title).bold(selected).foregroundColor(selected ? .white : .primary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? brand : Color.clear)
            .cornerRadius(9)
        }.buttonStyle(.plain)
    }
}

struct SettingRow<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundColor(brand).frame(width: 22)
            Text(title).font(.callout)
            Spacer()
            content()
        }
        .padding(10)
        .background(card)
        .cornerRadius(10)
    }
}

struct LabeledStepper: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 70)
            Stepper("", value: $value, in: range, step: step).labelsHidden()
            Spacer()
        }.font(.callout)
    }
}
