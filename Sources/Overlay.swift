import AppKit
import SwiftUI
import WebKit

enum OverlayMode: String, Codable, CaseIterable {
    case full, float
}

/// Full-screen break overlay on every screen, or one small floating card.
/// Time Out style: HTML theme in the middle + countdown + Done / Postpone / Skip.
@MainActor
final class OverlayController {
    static let shared = OverlayController()
    private var windows: [NSWindow] = []
    private var config: BreakConfig?
    private weak var scheduler: BreakScheduler?
    private var lang: AppLanguage = AppLanguage()

    /// Borderless windows must explicitly opt into key/main or they stay mute.
    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    static var mode: OverlayMode {
        get { OverlayMode(rawValue: UserDefaults.standard.string(forKey: "BreakTime.overlayMode") ?? "") ?? .full }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "BreakTime.overlayMode") }
    }

    func show(config: BreakConfig, scheduler: BreakScheduler, lang: AppLanguage) {
        hide()
        self.config = config
        self.scheduler = scheduler
        self.lang = lang
        NSSound(named: config.sound)?.play()
        if Self.mode == .float {
            showFloating(config: config, scheduler: scheduler, lang: lang)
        } else {
            for screen in NSScreen.screens {
                showOnScreen(screen, config: config, scheduler: scheduler, lang: lang,
                             rect: screen.frame, level: .screenSaver, movable: false)
            }
        }
        // A break that cannot be dismissed is a lock-out: force activation
        // so keyboard (Return/Escape) and first mouse click work immediately.
        NSApp.activate()
    }

    private func showOnScreen(_ screen: NSScreen?, config: BreakConfig, scheduler: BreakScheduler,
                              lang: AppLanguage, rect: NSRect, level: NSWindow.Level, movable: Bool) {
        let w = OverlayWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        w.level = level
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = false
        w.isMovableByWindowBackground = movable
        let view = BreakOverlayView(config: config, scheduler: scheduler, lang: lang, compact: level != .screenSaver)
        w.contentView = NSHostingView(rootView: view)
        w.orderFrontRegardless()
        w.makeKey()
        windows.append(w)
    }

    private func showFloating(config: BreakConfig, scheduler: BreakScheduler, lang: AppLanguage) {
        // Small card docked bottom-right of the main screen; movable, always visible.
        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: 400, height: 560)
        let origin = NSPoint(x: screen.visibleFrame.maxX - size.width - 24,
                             y: screen.visibleFrame.minY + 24)
        showOnScreen(screen, config: config, scheduler: scheduler, lang: lang,
                     rect: NSRect(origin: origin, size: size), level: .floating, movable: true)
    }

    func hide() {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
    }
}

struct BreakOverlayView: View {
    let config: BreakConfig
    @ObservedObject var scheduler: BreakScheduler
    @ObservedObject var lang: AppLanguage
    var compact = false
    @State private var appeared = false

    private var durationText: String {
        let s = Int(config.durationSeconds)
        if lang.lang == .zh {
            if s < 60 { return "\(s) 秒" }
            if s % 60 == 0 { return "\(s / 60) 分钟" }
            return "\(s / 60) 分 \(s % 60) 秒"
        }
        if s < 60 { return "\(s)s" }
        if s % 60 == 0 { return "\(s / 60) min" }
        return "\(s / 60)m \(s % 60)s"
    }

    var body: some View {
        ZStack {
            // Deep breathing backdrop: near-black teal with a soft brand glow.
            Color(red: 0.02, green: 0.05, blue: 0.05).opacity(compact ? 0.72 : 0.9).ignoresSafeArea()
            Circle()
                .fill(brand.opacity(0.16))
                .frame(width: compact ? 420 : 760, height: compact ? 420 : 760)
                .blur(radius: compact ? 70 : 120)
                .offset(y: compact ? -80 : -140)
                .ignoresSafeArea()
            VStack(spacing: compact ? 12 : 22) {
                // Eyebrow: kind + duration.
                HStack(spacing: 8) {
                    Circle().fill(brand).frame(width: 7, height: 7)
                        .shadow(color: brand.opacity(0.8), radius: 6)
                    Text("\(lang.t("ov.eyebrow")) · \(durationText)")
                        .font(.system(size: compact ? 12 : 14, weight: .semibold, design: .rounded))
                        .tracking(3)
                        .foregroundColor(brand)
                }
                Text(config.displayName(lang.lang))
                    .font(.system(size: compact ? 30 : 46, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                ThemeWebView(themeName: config.theme, lang: lang.lang)
                    .frame(width: compact ? 320 : 540, height: compact ? 190 : 320)
                    .cornerRadius(18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.55), radius: 20)
                if let a = scheduler.activeBreak {
                    CountdownRing(remaining: a.remaining, total: a.config.durationSeconds,
                                  caption: lang.t("ov.remaining"), compact: compact)
                }
                HStack(spacing: 14) {
                    Button(lang.t("ov.done")) { scheduler.finishBreak() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .tint(brand)
                    Button("\(lang.t("ov.postpone")) \(Int(config.postponeMinutes)) \(lang.t("unit.min"))") { scheduler.postponeActive() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.bordered).controlSize(.large)
                    Button(lang.t("ov.skip")) { scheduler.skipActive() }
                        .buttonStyle(.bordered).controlSize(.large)
                }
                Text(lang.t("ov.hint"))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
            }
            .padding(compact ? 22 : 44)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Color(white: 0.15), Color(white: 0.08)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.65), radius: 36)
            )
            .padding(compact ? 0 : 28)
            .scaleEffect(appeared ? 1 : 0.94)
            .opacity(appeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { appeared = true }
        }
    }
}

/// Ring countdown: time in the middle, progress ring around it.
struct CountdownRing: View {
    let remaining: TimeInterval
    let total: TimeInterval
    var caption: String = ""
    var compact = false

    var body: some View {
        let side: CGFloat = compact ? 112 : 158
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: compact ? 8 : 10)
                    .frame(width: side, height: side)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        LinearGradient(colors: [brand, Color(red: 0.35, green: 0.85, blue: 0.7)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: compact ? 8 : 10, lineCap: .round)
                    )
                    .frame(width: side, height: side)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1.0), value: remaining)
                Text(Self.format(remaining))
                    .font(.system(size: compact ? 26 : 40, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .tracking(2)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    private var progress: Double {
        guard total > 0 else { return 1 }
        return max(0, min(1, 1 - remaining / total))
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct ThemeWebView: NSViewRepresentable {
    let themeName: String
    var lang: Lang = .zh
    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.setValue(false, forKey: "drawsBackground")
        return wv
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator { var loaded: String? = nil }
    func updateNSView(_ wv: WKWebView, context: Context) {
        // Never reload the same theme+language (overlay refreshes every second).
        let key = "\(themeName)#\(lang.rawValue)"
        if context.coordinator.loaded == key, wv.url != nil { return }
        context.coordinator.loaded = key
        let res = Bundle.main.resourceURL?.appendingPathComponent("Themes/\(themeName).totheme")
        let preferred = res?.appendingPathComponent(lang == .zh ? "index.zh.html" : "index.html")
        let fallback = res?.appendingPathComponent("index.html")
        let fm = FileManager.default
        let url: URL?
        if let p = preferred, fm.fileExists(atPath: p.path) { url = p }
        else if let f = fallback, fm.fileExists(atPath: f.path) { url = f }
        else { url = nil }
        if let url {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            wv.loadHTMLString("<body style='background:#1c1c1e;color:#fff;font:-apple-system-body;display:flex;align-items:center;justify-content:center;height:100vh;margin:0'><h1>Take a break 🌿</h1></body>", baseURL: nil)
        }
    }
}
