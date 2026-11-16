import AppKit
import SwiftUI
import ClassnoteCore

final class CaptionPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}
final class PlayerHostingView<Content: View>: NSHostingView<Content> {
    var hover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hover?(true) }
    override func mouseExited(with event: NSEvent) { hover?(false) }
}
@MainActor final class PlayerState: ObservableObject {
    @Published var expanded = false
}

/// One movable window; only positions near a screen edge are docked.
@MainActor final class PanelController: NSObject, NSWindowDelegate {
    let model: AppModel
    let panel: CaptionPanel
    private let state = PlayerState()
    private var dockedEdge: PlayerDockEdge? = .right
    private var dragging = false
    private var resizing = false
    private var transitioning = false
    private var suppressHover = false
    private var positioning = false
    private var hideTask: Task<Void, Never>?
    private var snapTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    init(model: AppModel) {
        self.model = model
        panel = CaptionPanel(contentRect: NSRect(origin: .zero, size: PlayerGeometry.compactSize), styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Classnote 字幕播放器"
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua); panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.delegate = self; panel.isMovableByWindowBackground = true
        panel.minSize = PlayerGeometry.compactSize; panel.maxSize = PlayerGeometry.compactSize
        panel.onEscape = { [weak self] in self?.collapse() }
        let host = PlayerHostingView(rootView: UnifiedPlayerView(model: model, state: state,
            expand: { [weak self] in self?.model.pinned = true; self?.setExpanded(true); self?.panel.makeKey() },
            collapse: { [weak self] in self?.collapse() },
            pin: { [weak self] in guard let self else { return }; self.model.pinned.toggle(); self.scheduleHide() },
            dragBegan: { [weak self] in self?.beginDragging() },
            dragEnded: { [weak self] in self?.finishDragging() }))
        host.sizingOptions = []
        host.hover = { [weak self] in self?.hover($0) }
        panel.contentView = host
    }
    func show() {
        if !panel.isVisible {
            let saved = UserDefaults.standard.string(forKey: "player.compactFrame.v1").map(NSRectFromString)
            let savedScreen = saved.flatMap { rect in NSScreen.screens.first { $0.visibleFrame.intersects(rect) } }
            guard let screen = savedScreen ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
            let bounds = screen.visibleFrame.insetBy(dx: 14, dy: 14)
            state.expanded = false; model.pinned = false; suppressHover = false
            panel.minSize = PlayerGeometry.compactSize; panel.maxSize = PlayerGeometry.compactSize
            positioning = true
            let initial = saved ?? NSRect(x: bounds.maxX - 278, y: bounds.midY - 33, width: 278, height: 66)
            dockedEdge = PlayerGeometry.dockedEdge(for: initial, bounds: bounds)
            panel.setFrame(PlayerGeometry.frame(current: initial, size: PlayerGeometry.compactSize, bounds: bounds, dockedEdge: dockedEdge), display: true)
            positioning = false
        }
        panel.orderFrontRegardless()
    }
    func hide() { savePosition(); hideTask?.cancel(); snapTask?.cancel(); hoverTask?.cancel(); panel.orderOut(nil); suppressHover = false }
    private func hover(_ entered: Bool) {
        hoverTask?.cancel()
        if entered {
            hideTask?.cancel()
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled, let self, !self.suppressHover, !self.dragging, NSEvent.pressedMouseButtons == 0, self.panel.isVisible else { return }
                self.setExpanded(true)
            }
        } else { suppressHover = false; scheduleHide() }
    }
    private func collapse() { model.pinned = false; suppressHover = true; setExpanded(false) }
    private func setExpanded(_ expanded: Bool) {
        guard state.expanded != expanded, !resizing, !transitioning, !dragging, let screen = panel.screen ?? NSScreen.main else { return }
        hideTask?.cancel(); snapTask?.cancel()
        let bounds = screen.visibleFrame.insetBy(dx: 14, dy: 14)
        let size = expanded ? NSSize(width: max(360, model.settings.captionWidth), height: max(240, model.settings.captionHeight)) : PlayerGeometry.compactSize
        let target = PlayerGeometry.frame(current: panel.frame, size: size, bounds: bounds, dockedEdge: dockedEdge)
        // Relax constraints for the animation; lock compact size only after it completes.
        panel.minSize = PlayerGeometry.compactSize; panel.maxSize = bounds.size
        state.expanded = expanded; transitioning = true; positioning = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.positioning = false; self.transitioning = false
            if self.state.expanded { self.panel.minSize = NSSize(width: 360, height: 240) }
            else { self.panel.minSize = PlayerGeometry.compactSize; self.panel.maxSize = PlayerGeometry.compactSize }
            self.savePosition()
            self.scheduleHide()
        }
    }
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self, self.panel.isVisible, self.state.expanded, !self.model.pinned, !self.resizing, !self.transitioning, !self.dragging else { return }
            if NSEvent.pressedMouseButtons != 0 { self.scheduleHide(); return }
            if NSMouseInRect(NSEvent.mouseLocation, self.panel.frame, false) { return }
            self.setExpanded(false)
        }
    }
    func windowWillStartLiveResize(_ notification: Notification) { resizing = true; hideTask?.cancel(); snapTask?.cancel() }
    func windowDidEndLiveResize(_ notification: Notification) { resizing = false; saveSize() }
    private func saveSize() {
        guard state.expanded, !transitioning else { return }
        model.settings.captionWidth = panel.frame.width; model.settings.captionHeight = panel.frame.height; model.saveSettings()
        settlePosition(); scheduleHide()
    }
    private func settlePosition() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 14, dy: 14)
        dockedEdge = PlayerGeometry.dockedEdge(for: panel.frame, bounds: bounds)
        positioning = true
        panel.setFrame(PlayerGeometry.frame(current: panel.frame, size: panel.frame.size, bounds: bounds, dockedEdge: dockedEdge), display: true)
        positioning = false
        savePosition()
    }
    private func savePosition() {
        guard panel.isVisible, !transitioning, let screen = panel.screen ?? NSScreen.main else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 14, dy: 14)
        let compact = PlayerGeometry.frame(current: panel.frame, size: PlayerGeometry.compactSize, bounds: bounds, dockedEdge: dockedEdge)
        UserDefaults.standard.set(NSStringFromRect(compact), forKey: "player.compactFrame.v1")
    }
    private func beginDragging() {
        dragging = true; hideTask?.cancel(); hoverTask?.cancel(); snapTask?.cancel()
    }
    private func finishDragging() {
        dragging = false; suppressHover = true; settlePosition(); scheduleHide()
    }
    func windowDidMove(_ notification: Notification) {
        guard !positioning, !transitioning, !resizing, !dragging else { return }
        snapTask?.cancel()
        snapTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            while NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(100)); if Task.isCancelled { return }
            }
            self.settlePosition(); self.scheduleHide()
        }
    }
}
struct UnifiedPlayerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: PlayerState
    var expand: () -> Void; var collapse: () -> Void; var pin: () -> Void
    var dragBegan: () -> Void; var dragEnded: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    HStack(spacing: 2) {
                        ForEach(0..<5) { i in RoundedRectangle(cornerRadius: 1).fill(model.isRecording ? Palette.mint : .white.opacity(0.3)).frame(width: 2, height: 5 + Double(model.level) * Double([10, 22, 30, 18, 9][i])).animation(.easeOut(duration: 0.15), value: model.level) }
                    }.accessibilityHidden(true)
                    PlayerDragArea(began: dragBegan, ended: dragEnded)
                }.frame(width: 25, height: 42).help("拖动到任意位置；靠近边缘时吸附")
                ZStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.displayed.map(model.lectureTitle) ?? "Classnote").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text("\(model.elapsed)  ·  \(model.isRecording ? (model.active?.isDemo == true ? "DEMO" : "LIVE") : (model.activeID == nil ? "READY" : "PAUSED"))").font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.dim)
                        Text(ClassnoteAttribution.compact).font(.system(size: 9)).foregroundStyle(.white.opacity(0.60)).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    PlayerDragArea(clicked: expand, began: dragBegan, ended: dragEnded)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).help("拖动播放器；点击展开并固定字幕")
                Button { model.togglePause() } label: { Image(systemName: model.isRecording ? "pause.fill" : "play.fill").font(.system(size: 12)).frame(width: 28, height: 30) }
                    .disabled(model.activeID == nil || model.ending || model.isStarting).help("暂停 / 继续").accessibilityLabel("暂停 / 继续")
                Button { model.showMain?() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10)).frame(width: 23, height: 30) }.help("返回主窗口").accessibilityLabel("返回主窗口")
            }.buttonStyle(.plain).padding(.horizontal, 17).frame(height: 66)
                .background(PlayerDragArea(began: dragBegan, ended: dragEnded))
            if state.expanded {
                Rectangle().fill(Palette.line).frame(height: 1)
                HStack(spacing: 12) {
                    Text("LIVE CAPTIONS").font(.system(size: 9, weight: .medium)).tracking(1.2).foregroundStyle(Palette.dim)
                    Spacer()
                    Button("A−") { model.setFont(-1) }.help("缩小字幕字体")
                    Text("\(Int(model.settings.fontSize))").font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.dim).frame(width: 18)
                    Button("A＋") { model.setFont(1) }.help("放大字幕字体")
                    Button(action: pin) { Image(systemName: model.pinned ? "pin.fill" : "pin") }.foregroundStyle(model.pinned ? Palette.mint : .white.opacity(0.5)).help("固定字幕框").accessibilityLabel(model.pinned ? "取消固定" : "固定字幕框")
                    Button(action: collapse) { Image(systemName: "chevron.up") }.help("收起为播放器（Esc）").accessibilityLabel("收起为播放器")
                }.buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 18).padding(.vertical, 12)
                TranscriptView(segments: model.displayed?.orderedSegments ?? [], draft: model.draft, fontSize: model.settings.fontSize, bilingual: model.settings.bilingual, compact: true)
                HStack {
                    Text(model.displayed?.isDemo == true ? "DEMO · 演示数据" : "拖动窗口边框调整大小").font(.system(size: 8)).foregroundStyle(.white.opacity(0.25))
                    Spacer()
                }.padding(.horizontal, 8).padding(.bottom, 5)
                AttributionWatermark()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Palette.bg.opacity(0.98)).clipShape(RoundedRectangle(cornerRadius: 19))
            .overlay(RoundedRectangle(cornerRadius: 19).stroke(Color.white.opacity(0.16)).allowsHitTesting(false))
            .foregroundStyle(.white).preferredColorScheme(.dark)
    }
}

struct PlayerDragArea: NSViewRepresentable {
    var clicked: (() -> Void)?
    var began: () -> Void
    var ended: () -> Void
    func makeNSView(context: Context) -> DragHandle { let view = DragHandle(); updateNSView(view, context: context); return view }
    func updateNSView(_ view: DragHandle, context: Context) {
        view.clicked = clicked; view.began = began; view.ended = ended
        view.setAccessibilityElement(true); view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(clicked == nil ? "拖动播放器" : "拖动播放器，点击固定字幕")
    }
    final class DragHandle: NSView {
        var clicked: (() -> Void)?; var began: (() -> Void)?; var ended: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let initial = window.frame.origin
            began?(); window.performDrag(with: event); ended?()
            if hypot(window.frame.minX - initial.x, window.frame.minY - initial.y) < 3 { clicked?() }
        }
        override func accessibilityPerformPress() -> Bool { clicked?(); return clicked != nil }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}
