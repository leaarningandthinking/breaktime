import AppKit
import SwiftUI

/// Gentle heads-up shortly before a break (Time Out warns before interrupting):
/// small floating card, bottom-right, auto-hides. "微休息还有1分钟" + Skip/Postpone.
@MainActor
final class ToastController {
    static let shared = ToastController()
    private var window: NSWindow?
    private var hideWork: DispatchWorkItem?
    private var shownKey: String?

    func showOnce(key: String, title: String, seconds: Int, lang: AppLanguage,
                  onSkip: @escaping () -> Void, onPostpone: @escaping () -> Void) {
        if shownKey == key { return }
        shownKey = key
        hide()
        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: 360, height: 132)
        let origin = NSPoint(x: screen.visibleFrame.maxX - size.width - 20,
                             y: screen.visibleFrame.minY + 20)
        let w = NSWindow(contentRect: NSRect(origin: origin, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.ignoresMouseEvents = false
        w.isMovableByWindowBackground = true
        let view = ToastView(title: title, seconds: seconds, lang: lang,
                             onSkip: { [weak self] in onSkip(); self?.hide() },
                             onPostpone: { [weak self] in onPostpone(); self?.hide() })
        w.contentView = NSHostingView(rootView: view)
        w.orderFrontRegardless()
        window = w
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    func reset() { shownKey = nil }

    func hide() {
        hideWork?.cancel(); hideWork = nil
        window?.orderOut(nil); window = nil
    }
}

struct ToastView: View {
    let title: String
    let seconds: Int
    @ObservedObject var lang: AppLanguage
    let onSkip: () -> Void
    let onPostpone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "cup.and.saucer.fill").foregroundColor(Color(red: 0.16, green: 0.62, blue: 0.52))
                Text(title).font(.headline)
                Spacer()
                Button { ToastController.shared.hide() } label: {
                    Image(systemName: "xmark").foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
            Text(lang.lang == .zh ? "还有\(seconds)秒开始" : "starts in \(seconds)s")
                .font(.callout).foregroundColor(.secondary)
            HStack {
                Spacer()
                Button(lang.t("ov.skip"), action: onSkip).buttonStyle(.bordered).controlSize(.small)
                Button("\(lang.t("ov.postpone")) 5 \(lang.t("unit.min"))", action: onPostpone).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(14)
        .background(Color(red: 0.13, green: 0.13, blue: 0.15).opacity(0.97))
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.5), radius: 16)
        .preferredColorScheme(.dark)
    }
}
