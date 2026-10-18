import AppKit
import ApplicationServices
import HyperTranslateCore

struct SelectionSnapshot {
    let text: String
    let anchor: NSPoint
    let processID: pid_t
}

actor SelectionReader {
    /// 在后台串行读取当前应用选区，限制树遍历规模及辅助功能调用超时。
    func capture(processID: pid_t, mouse: NSPoint, primaryTop: CGFloat) -> SelectionSnapshot? {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.12)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.12)
        let focused = elementAttribute(application, kAXFocusedUIElementAttribute)
            ?? elementAttribute(system, kAXFocusedUIElementAttribute)
        var hit: AXUIElement?
        AXUIElementCopyElementAtPosition(system, Float(mouse.x), Float(primaryTop - mouse.y), &hit)
        // 优先鼠标所在元素，避免某些网页焦点仍留在上一次编辑的输入框。
        var roots: [AXUIElement] = []
        if let hit { roots.append(hit) }
        if let focused { roots.append(focused) }
        for root in roots {
            var candidate: AXUIElement? = root
            for _ in 0..<6 {
                if Task.isCancelled { return nil }
                guard let current = candidate else { break }
                if isSecure(current) { break }
                if let result = selected(current, processID: processID, mouse: mouse, primaryTop: primaryTop) {
                    return result
                }
                candidate = elementAttribute(current, kAXParentAttribute)
            }
        }
        // Preview 的 PDF 选区可能位于焦点组的子元素，有限遍历以免阻塞。
        if let focused, !isSecure(focused) {
            var queue: [(AXUIElement, Int)] = [(focused, 0)]
            var visited = 0
            while !queue.isEmpty && visited < 45 {
                if Task.isCancelled { return nil }
                let (element, depth) = queue.removeFirst()
                visited += 1
                if isSecure(element) { continue }
                if let result = selected(element, processID: processID, mouse: mouse, primaryTop: primaryTop) {
                    return result
                }
                if depth < 3, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                    queue.append(contentsOf: children.prefix(15).map { ($0, depth + 1) })
                }
            }
        }
        return nil
    }

    /// 读取已选文本和选区矩形，转换为 AppKit 全局坐标。
    private func selected(_ element: AXUIElement, processID: pid_t,
                          mouse: NSPoint, primaryTop: CGFloat) -> SelectionSnapshot? {
        var actualPID: pid_t = 0
        AXUIElementGetPid(element, &actualPID)
        guard actualPID == processID,
              let text = attribute(element, kAXSelectedTextAttribute) as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.range(of: "[A-Za-z]", options: .regularExpression) != nil else { return nil }
        var anchor = NSPoint(x: mouse.x + 12, y: mouse.y - 12)
        if let range = attribute(element, kAXSelectedTextRangeAttribute) {
            var bounds: CFTypeRef?
            let status = AXUIElementCopyParameterizedAttributeValue(element,
                kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds)
            if status == .success, let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() {
                let value = bounds as! AXValue
                var rect = CGRect.zero
                if AXValueGetType(value) == .cgRect, AXValueGetValue(value, .cgRect, &rect),
                   rect.width > 0, rect.height > 0, rect.origin.x.isFinite, rect.origin.y.isFinite {
                    // 在拖选结束处显示，避免长选区图标出现在很远的开头。
                    let converted = NSRect(x: rect.minX, y: primaryTop - rect.maxY,
                                           width: rect.width, height: rect.height)
                    // 点击旧选区以外的位置时，不把残留的选中状态当成新划词。
                    guard converted.insetBy(dx: -30, dy: -30).contains(mouse) else { return nil }
                    if converted.insetBy(dx: -30, dy: -30).contains(mouse) {
                        anchor = NSPoint(x: mouse.x + 12, y: converted.minY - 5)
                    }
                }
            }
        }
        return SelectionSnapshot(text: text, anchor: anchor, processID: processID)
    }

    /// 读取辅助功能属性，不使用私有 AX 属性或修改目标应用状态。
    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    /// 将 AX 属性安全转换为界面元素。
    private func elementAttribute(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(element, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// 排除系统标注的安全输入框。
    private func isSecure(_ element: AXUIElement) -> Bool {
        (attribute(element, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole
    }
}

@MainActor
final class SelectionService {
    private let reader = SelectionReader()
    private weak var state: AppState?
    private var monitors: [Any] = []
    private var workspaceObserver: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    private var generation = RequestGeneration()
    var onSelection: ((SelectionSnapshot) -> Void)?
    var onDismiss: (() -> Void)?

    /// 保存状态引用；实际监听在应用启动后启用。
    init(state: AppState) { self.state = state }

    /// 监听鼠标选区结束、外部点击和应用切换，不拦截用户事件。
    func start() {
        let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.invalidate()
            self?.onDismiss?()
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.scheduleCapture()
        }
        let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.invalidate(); self?.onDismiss?() }
            else if event.modifierFlags.contains(.shift) {
                self?.scheduleCapture()
            } else {
                self?.invalidate()
                self?.onDismiss?()
            }
        }
        monitors = [down, up, keys].compactMap { $0 }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated {
                self?.invalidate()
                self?.onDismiss?()
            }
        }
    }

    /// 选区稳定后读取；晚到结果必须与当前应用及查询代次一致。
    private func scheduleCapture() {
        invalidate()
        guard let state, !state.paused, AXIsProcessTrusted(),
              let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let identifier = generation.advance()
        let pid = application.processIdentifier
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let snapshot = await self.reader.capture(processID: pid, mouse: mouse, primaryTop: top)
            guard !Task.isCancelled, self.generation.contains(identifier), self.state?.paused == false,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let snapshot else { return }
            self.onSelection?(snapshot)
        }
    }

    /// 撤销尚未完成的选区读取，防止切换应用后出现旧图标。
    func invalidate() {
        generation.advance()
        pending?.cancel()
        pending = nil
    }

    /// 移除系统监听，避免退出时遗留观察者。
    func stop() {
        invalidate()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
    }
}
