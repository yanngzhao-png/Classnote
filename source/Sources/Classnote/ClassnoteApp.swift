import SwiftUI
import AppKit

@main enum ClassnoteApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel!
    var mainWindow: NSWindow!
    var panels: PanelController!
    var statusItem: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        guard ClassnoteAttribution.acknowledgeFirstLaunch() else { NSApp.terminate(nil); return }
        model = AppModel()
        makeMenu()
        mainWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        mainWindow.title = "Classnote"; mainWindow.titleVisibility = .hidden; mainWindow.titlebarAppearsTransparent = true
        mainWindow.minSize = NSSize(width: 940, height: 640); mainWindow.isReleasedWhenClosed = false; mainWindow.delegate = self
        mainWindow.contentView = NSHostingView(rootView: MainView(model: model)); mainWindow.center(); mainWindow.setFrameAutosaveName("ClassnoteMain")
        mainWindow.appearance = NSAppearance(named: .darkAqua)
        panels = PanelController(model: model)
        model.showMini = { [weak self] in self?.panels.show(); self?.mainWindow.orderOut(nil) }
        model.showMain = { [weak self] in self?.restore() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Classnote")
        let tray = NSMenu()
        tray.addItem(withTitle: "打开 Classnote", action: #selector(restore), keyEquivalent: "")
        tray.addItem(withTitle: "边缘播放器", action: #selector(mini), keyEquivalent: "")
        tray.addItem(withTitle: "暂停 / 继续", action: #selector(pause), keyEquivalent: "")
        tray.addItem(.separator()); tray.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        for item in tray.items { item.target = self }; statusItem.menu = tray
        restore()
    }
    @objc func restore() { guard let mainWindow else { return }; panels?.hide(); mainWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func mini() { panels.show(); mainWindow.orderOut(nil) }
    @objc func pause() { model.togglePause() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func preferences() { restore(); model.showSettings = true }
    @objc func newLecture() { restore(); model.prepareLecture() }
    @objc func schedules() { restore(); model.openSchedulePreferences() }
    @objc func toggleSidebar() { model.sidebarCollapsed.toggle() }
    @objc func freeSharingNotice() { ClassnoteAttribution.showNotice() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { mini(); return false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { restore(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if !model.exportingCourseIDs.isEmpty || model.isEmptyingTrash { return .terminateCancel }
        if model.activeID != nil || !model.busyNotes.isEmpty || !model.busyCombinedNotes.isEmpty || !model.importingCourseware.isEmpty {
            let alert = NSAlert(); alert.messageText = "退出 Classnote？"; alert.informativeText = "当前课堂将停止，已完成的原稿和音频会保存在本机。未完成的转录或笔记可以重新生成。"
            alert.addButton(withTitle: "保存并退出"); alert.addButton(withTitle: "继续使用")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        model.shutdown(); return .terminateNow
    }
    private func makeMenu() {
        let menu = NSMenu(); let app = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Classnote", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "免费声明与作者…", action: #selector(freeSharingNotice), keyEquivalent: "").target = self
        let settings = appMenu.addItem(withTitle: "偏好设置…", action: #selector(preferences), keyEquivalent: ","); settings.target = self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "隐藏 Classnote", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 Classnote", action: #selector(quit), keyEquivalent: "q").target = self; app.submenu = appMenu; menu.addItem(app)
        let edit = NSMenuItem(); let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu; menu.addItem(edit)
        let window = NSMenuItem(); let wm = NSMenu(title: "窗口")
        wm.addItem(withTitle: "新课堂", action: #selector(newLecture), keyEquivalent: "n").target = self
        wm.addItem(withTitle: "课表与导入…", action: #selector(schedules), keyEquivalent: "").target = self
        wm.addItem(withTitle: "显示主窗口", action: #selector(restore), keyEquivalent: "0").target = self
        let sidebar = wm.addItem(withTitle: "收起 / 展开侧栏", action: #selector(toggleSidebar), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]; sidebar.target = self
        wm.addItem(withTitle: "边缘播放器", action: #selector(mini), keyEquivalent: "m").target = self
        wm.addItem(withTitle: "暂停 / 继续", action: #selector(pause), keyEquivalent: "p").target = self
        window.submenu = wm; menu.addItem(window); NSApp.mainMenu = menu
    }
}
