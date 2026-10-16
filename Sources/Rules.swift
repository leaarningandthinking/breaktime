import AppKit

/// One exclusion rule (mirrors Time Out's Rules tab):
/// "If [app] is [frontmost] [automatically skip]".
struct ExclusionRule: Codable, Identifiable, Equatable {
    enum Action: String, Codable, CaseIterable {
        case skip = "automatically skip"
        case postpone = "postpone 5 min"
    }
    enum Kind: String, Codable {
        case app
        case fullscreen
        case screensaver
    }
    var id: String = UUID().uuidString
    var enabled: Bool = true
    var kind: Kind = .app
    /// Bundle id for .app, display name otherwise.
    var target: String = "us.zoom.xos"
    var displayName: String = "zoom.us"
    var action: Action = .skip

    func localizedName(_ lang: Lang) -> String {
        if kind == .fullscreen { return lang == .zh ? "全屏应用在前台" : "Fullscreen app is active" }
        if kind == .screensaver { return lang == .zh ? "屏保运行中" : "Screensaver is active" }
        return displayName
    }

    static var defaults: [ExclusionRule] {
        [
            .init(target: "us.zoom.xos", displayName: "zoom.us"),
            .init(target: "com.apple.FaceTime", displayName: "FaceTime"),
            .init(target: "com.tencent.meeting", displayName: "Tencent Meeting"),
            .init(target: "com.alibaba.DingTalk", displayName: "DingTalk"),
            .init(target: "com.bytedance.lark", displayName: "Lark"),
            .init(target: "org.videolan.vlc", displayName: "VLC"),
            .init(target: "com.microsoft.teams2", displayName: "Teams"),
            .init(kind: .fullscreen, target: "", displayName: "Fullscreen app is active"),
            .init(kind: .screensaver, target: "", displayName: "Screensaver is active"),
        ]
    }
}

final class RuleStore: ObservableObject {
    @Published var rules: [ExclusionRule] {
        didSet { save() }
    }
    private let key = "BreakTime.rules.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let loaded = try? JSONDecoder().decode([ExclusionRule].self, from: data) {
            rules = loaded
        } else {
            rules = ExclusionRule.defaults
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Live environment checks used by the rule engine.
enum MeetingDetector {
    static func frontmostBundleId() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Frontmost app owns a window covering a whole display.
    static func isFullscreenFrontmost() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        var displays: [CGRect] = []
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        displays = ids.map { CGDisplayBounds($0) }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let h = b["Height"] else { continue }
            let r = CGRect(x: x, y: y, width: wd, height: h)
            // A window counts as fullscreen only if it (nearly) equals a
            // display bounds — mere containment matches every window.
            let tol: CGFloat = 3
            if displays.contains(where: {
                abs($0.origin.x - r.origin.x) <= tol &&
                abs($0.origin.y - r.origin.y) <= tol &&
                abs($0.width - r.width) <= tol &&
                abs($0.height - r.height) <= tol
            }) { return true }
        }
        return false
    }

    static func isScreensaverActive() -> Bool {
        // NOTE: never shell out synchronously here — a full `ps` listing can
        // exceed the pipe buffer and deadlock waitUntilExit on the main thread.
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.ScreenSaver.Engine"
        }
    }

    /// Returns the first matching enabled rule, if any.
    static func matchingRule(_ rules: [ExclusionRule]) -> ExclusionRule? {
        let front = frontmostBundleId()
        for r in rules where r.enabled {
            switch r.kind {
            case .app:
                if let f = front, f == r.target || f.hasSuffix("." + r.target) { return r }
            case .fullscreen:
                if isFullscreenFrontmost() { return r }
            case .screensaver:
                if isScreensaverActive() { return r }
            }
        }
        return nil
    }
}
