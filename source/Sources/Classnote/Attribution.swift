import AppKit
import SwiftUI

/// Compiled-in attribution for the distributed client, not a user preference.
/// This is a notice, not a guarantee against modified source or patched binaries.
enum ClassnoteAttribution {
    static let creator = "抖音小红书：阿瑞斯又"
    static let notice = "免费分享 · 付费就是被骗了"
    static let compact = "阿瑞斯又 · 免费分享"
    static let apiNotice = "本客户端免费分享，请勿付费购买。AI 转录、翻译和笔记需要使用你自己的 API Key；API 服务商可能收取调用费用，这与购买本客户端不同。"
    private static let acknowledgementKey = "distribution.freeNoticeAcknowledged.v1"

    @MainActor static func acknowledgeFirstLaunch() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: acknowledgementKey) else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = makeAlert()
        alert.addButton(withTitle: "我知道了，免费使用")
        alert.addButton(withTitle: "退出")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        defaults.set(true, forKey: acknowledgementKey)
        return true
    }

    @MainActor static func showNotice() {
        let alert = makeAlert()
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    @MainActor private static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Classnote · 免费分享"
        alert.informativeText = creator + "\n\n免费分享\n付费就是被骗了\n\n" + apiNotice
        return alert
    }
}

struct AttributionWatermark: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                Text(ClassnoteAttribution.creator)
                Text(ClassnoteAttribution.notice)
            }.fixedSize()
            VStack(spacing: 4) {
                Text(ClassnoteAttribution.creator)
                Text(ClassnoteAttribution.notice)
            }.fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.60))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Palette.bg)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }
}
