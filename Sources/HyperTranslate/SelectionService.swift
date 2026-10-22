import AppKit
import ApplicationServices
import HyperTranslateCore

struct SelectionSnapshot {
    let text: String
    let anchor: NSPoint
    let processID: pid_t
}

struct SelectionCaptureRequest {
    enum Trigger { case pointer, keyboard }
    let processID: pid_t
    let mouse: NSPoint
    let primaryTop: CGFloat
    let trigger: Trigger

    /// 使用触发时的位置等待选区稳定；首次未读到时，等待浏览器辅助功能树刷新后重试一次。
    func readAfterDebounce(using reader: (Self) async -> SelectionSnapshot?) async -> SelectionSnapshot? {
        for _ in 0..<2 {
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return nil }
            guard !Task.isCancelled else { return nil }
            if let snapshot = await reader(self) {
                return Task.isCancelled ? nil : snapshot
            }
        }
        return nil
    }

    /// 鼠标取词校验松开处，键盘取词按选区定位，避免受无关鼠标位置影响。
    func anchor(for bounds: CGRect?) -> NSPoint? {
        let fallback = NSPoint(x: mouse.x + 12, y: mouse.y - 12)
        guard let bounds, bounds.width > 0, bounds.height > 0,
              bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.maxX.isFinite, bounds.maxY.isFinite else { return fallback }
        let converted = NSRect(x: bounds.minX, y: primaryTop - bounds.maxY,
                               width: bounds.width, height: bounds.height)
        if trigger == .pointer {
            // 排除点击其他位置后，目标应用仍暴露的旧选区。
            guard converted.insetBy(dx: -30, dy: -30).contains(mouse) else { return nil }
            return NSPoint(x: mouse.x + 12, y: converted.minY - 5)
        }
        return NSPoint(x: converted.maxX + 12, y: converted.minY - 5)
    }
}

enum SelectionText {
    /// 优先使用已选文本；应用只提供有效选区范围时，通过公开范围接口读取，排除空光标和非英文。
    static func read(direct: String?, range: CFRange?, readRange: () -> String?) -> String? {
        let text: String?
        if let direct, !direct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = direct
        } else if let range, range.location >= 0, range.length > 0,
                  range.location <= Int.max - range.length {
            text = readRange()
        } else {
            return nil
        }
        guard let text, text.range(of: "[A-Za-z]", options: .regularExpression) != nil else { return nil }
        return text
    }
}

actor SelectionReader {
    /// 在后台串行读取当前应用选区，限制树遍历规模及辅助功能调用超时。
    func capture(_ request: SelectionCaptureRequest) -> SelectionSnapshot? {
        let application = AXUIElementCreateApplication(request.processID)
        AXUIElementSetMessagingTimeout(application, 0.12)
        // Chromium 在客户端读取应用角色时按需启用辅助功能；随后一次重试等待网页树就绪。
        _ = attribute(application, kAXRoleAttribute)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.12)
        let focused = elementAttribute(application, kAXFocusedUIElementAttribute)
            ?? elementAttribute(system, kAXFocusedUIElementAttribute)
        var hit: AXUIElement?
        if request.trigger == .pointer {
            AXUIElementCopyElementAtPosition(system, Float(request.mouse.x),
                                            Float(request.primaryTop - request.mouse.y), &hit)
        }
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
                if let result = selected(current, request: request) {
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
                if let result = selected(element, request: request) {
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
    private func selected(_ element: AXUIElement, request: SelectionCaptureRequest) -> SelectionSnapshot? {
        var actualPID: pid_t = 0
        AXUIElementGetPid(element, &actualPID)
        guard actualPID == request.processID else { return nil }
        let direct = attribute(element, kAXSelectedTextAttribute) as? String
        let rangeValue = attribute(element, kAXSelectedTextRangeAttribute)
        var selectedRange: CFRange?
        if let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            let value = rangeValue as! AXValue
            var range = CFRange()
            if AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range) {
                selectedRange = range
            }
        }
        guard let text = SelectionText.read(direct: direct, range: selectedRange, readRange: {
            guard let rangeValue else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element,
                kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &value) == .success else { return nil }
            return value as? String
        }) else { return nil }
        var selectionBounds: CGRect?
        if selectedRange != nil, let range = rangeValue {
            var bounds: CFTypeRef?
            let status = AXUIElementCopyParameterizedAttributeValue(element,
                kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds)
            if status == .success, let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() {
                let value = bounds as! AXValue
                var rect = CGRect.zero
                if AXValueGetType(value) == .cgRect, AXValueGetValue(value, .cgRect, &rect),
                   rect.width > 0, rect.height > 0 {
                    selectionBounds = rect
                }
            }
        }
        guard let anchor = request.anchor(for: selectionBounds) else { return nil }
        return SelectionSnapshot(text: text, anchor: anchor, processID: request.processID)
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
        stop()
        let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.invalidate()
            self?.onDismiss?()
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.scheduleCapture(trigger: .pointer)
        }
        let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.invalidate(); self?.onDismiss?() }
            else if event.modifierFlags.contains(.shift) {
                self?.scheduleCapture(trigger: .keyboard)
            } else {
                self?.invalidate()
                self?.onDismiss?()
            }
        }
        monitors = [down, up, keys].compactMap { $0 }
        state?.selectionStatus = down != nil && up != nil ? "正在监听划词" : "取词监听未启动，请重新打开应用"
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
    private func scheduleCapture(trigger: SelectionCaptureRequest.Trigger) {
        invalidate()
        guard let state else { return }
        guard !state.paused else { state.selectionStatus = "划词已暂停"; return }
        guard AXIsProcessTrusted() else { state.selectionStatus = "缺少辅助功能授权"; return }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let name = application.localizedName ?? "当前应用"
        state.selectionStatus = "正在读取 \(name) 选区"
        let identifier = generation.advance()
        let pid = application.processIdentifier
        let request = SelectionCaptureRequest(processID: pid, mouse: NSEvent.mouseLocation,
            primaryTop: NSScreen.screens.first?.frame.maxY ?? 0, trigger: trigger)
        pending = Task { [weak self] in
            guard let self else { return }
            let snapshot = await request.readAfterDebounce { await self.reader.capture($0) }
            guard !Task.isCancelled, self.generation.contains(identifier), self.state?.paused == false,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            guard let snapshot else {
                self.state?.selectionStatus = "未读到 \(name) 的英文选区，请重新划词；或复制后使用「翻译剪贴板」"
                return
            }
            self.state?.selectionStatus = "已读取 \(name) 选区"
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
