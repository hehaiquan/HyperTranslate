import AppKit
import Combine
import SwiftUI

final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController {
    private let state: AppState
    private let panel: TranslationPanel
    private let indicator: NSPanel
    private var snapshot: SelectionSnapshot?
    private var escapeMonitor: Any?
    private var indicatorTimeout: Task<Void, Never>?
    private var pinSubscription: AnyCancellable?

    /// 创建唯一翻译宿主和独立取词按钮；允许注入宿主窗口验证生命周期行为。
    init(state: AppState, window: TranslationPanel? = nil) {
        self.state = state
        panel = window ?? TranslationPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        indicator = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 36, height: 36),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        for window in [panel, indicator] {
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            window.isReleasedWhenClosed = false
            window.title = "HyperTranslate"
        }
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: ShellView(state: state, translator: state.translator) { [weak self] in
            self?.hide()
        })
        indicator.contentView = NSHostingView(rootView: IndicatorView { [weak self] in self?.translateSelection() })
        state.showPanel = { [weak self] page, anchor in self?.show(page, anchor: anchor) }
        pinSubscription = state.$isPanelPinned.removeDuplicates().sink { [weak self] pinned in
            self?.panel.level = pinned ? .floating : .normal
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.state.isPreparing == false else { return event }
            self?.hide()
            return nil
        }
    }

    /// 将小图标显示在捕获位置；保留原文快照，不在点击时重新取词。
    func showIndicator(_ selection: SelectionSnapshot) {
        guard !state.isPreparing else { return }
        snapshot = selection
        let frame = clampedFrame(size: NSSize(width: 36, height: 36),
                                 anchor: selection.anchor, below: true)
        indicator.setFrame(frame, display: true)
        indicator.orderFrontRegardless()
        indicatorTimeout?.cancel()
        indicatorTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.hideIndicator()
        }
    }

    /// 打开结果、输入或设置页面，并约束到所在屏幕的可见区域。
    func show(_ page: AppState.Page, anchor: NSPoint? = nil) {
        guard !state.isPreparing || page == .setup else { return }
        if page != .result { state.cancelQuery(); state.speech.stop() }
        hideIndicator()
        state.page = page
        let size = NSSize(width: 560, height: page == .input ? 640 : 720)
        let screen = screenFor(anchor ?? NSEvent.mouseLocation)
        // 置顶期间沿用拖动后的位置；未置顶的新划词查询仍跟随选区。
        let currentOrigin = panel.isVisible && (state.isPanelPinned || anchor == nil)
            ? NSPoint(x: panel.frame.minX, y: panel.frame.maxY) : nil
        let point = currentOrigin ?? anchor ?? NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                                                       y: screen.visibleFrame.midY + size.height / 2)
        panel.setFrame(clampedFrame(size: size, anchor: point, below: true), display: true)
        if page == .result { panel.orderFrontRegardless() }
        else {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// 外部点击或应用切换时关闭临时结果；置顶或系统下载提示期间保留宿主。
    func dismissTransient() {
        hideIndicator()
        guard state.page == .result, !state.isPanelPinned, !state.isPreparing,
              !(state.translator.isWorking && state.translator.availability != .ready) else { return }
        hide()
    }

    /// 暂停时移除临时划词结果，保留用户置顶的窗口。
    func pauseChanged() { if state.paused { dismissTransient() } }

    /// 关闭浮窗并取消当前查询与朗读。
    func hide() {
        guard !state.isPreparing else { return }
        hideIndicator()
        state.cancelQuery()
        state.speech.stop()
        panel.orderOut(nil)
    }

    /// 单独关闭图标并释放选区快照。
    private func hideIndicator() {
        indicatorTimeout?.cancel()
        indicatorTimeout = nil
        indicator.orderOut(nil)
        snapshot = nil
    }

    /// 使用点击前保存的快照发起翻译，确认来源应用仍未切换。
    private func translateSelection() {
        guard let snapshot, NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.processID else {
            hideIndicator()
            return
        }
        let text = snapshot.text
        let anchor = snapshot.anchor
        hideIndicator()
        state.query(text, anchor: anchor)
    }

    /// 寻找鼠标或选区所在的显示器，支持显示器位于主屏左侧或上方。
    private func screenFor(_ point: NSPoint) -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// 将浮窗固定在指定屏幕内，避开菜单栏和 Dock。
    private func clampedFrame(size: NSSize, anchor: NSPoint, below: Bool) -> NSRect {
        let visible = screenFor(anchor).visibleFrame.insetBy(dx: 10, dy: 10)
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        let x = min(max(anchor.x, visible.minX), visible.maxX - width)
        let y = min(max(below ? anchor.y - height : anchor.y, visible.minY), visible.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// 退出时移除监听和隐藏窗口。
    func stop() {
        pinSubscription?.cancel()
        pinSubscription = nil
        hideIndicator()
        panel.orderOut(nil)
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}

private struct IndicatorView: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("译").font(.system(size: 17, weight: .semibold)).foregroundStyle(.blue)
                .frame(width: 34, height: 34)
                .background { TranslationGlassBackground(cornerRadius: 12) }
        }.buttonStyle(.plain).help("翻译选中的英文").accessibilityLabel("翻译选中的英文")
    }
}
