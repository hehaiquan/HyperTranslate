import AppKit
@testable import HyperTranslate
import XCTest

@MainActor
final class SelectionCaptureTests: XCTestCase {
    /// 松开后立刻移动鼠标，防抖读取仍使用松开时坐标，并保留有效选区。
    func testPointerMovementDuringDebounceDoesNotDiscardSelection() async {
        var mouse = NSPoint(x: 140, y: 790)
        let request = SelectionCaptureRequest(processID: 42, mouse: mouse,
            primaryTop: 1000, trigger: .pointer)
        let bounds = CGRect(x: 100, y: 200, width: 80, height: 20)
        let task = Task {
            await request.readAfterDebounce { captured in
                guard let anchor = captured.anchor(for: bounds) else { return nil }
                return SelectionSnapshot(text: "hello", anchor: anchor, processID: captured.processID)
            }
        }
        mouse = NSPoint(x: 700, y: 400)
        let previousBehavior = SelectionCaptureRequest(processID: 42, mouse: mouse,
            primaryTop: 1000, trigger: .pointer)
        XCTAssertNil(previousBehavior.anchor(for: bounds), "防抖后采样会错误丢弃这个选区")
        let snapshot = await task.value
        XCTAssertEqual(snapshot?.text, "hello")
        XCTAssertEqual(snapshot?.anchor, NSPoint(x: 152, y: 775))
        XCTAssertEqual(snapshot?.processID, 42)
    }

    /// 真正点击旧选区外的位置仍被过滤，不因修正时序而误触发残留选区。
    func testPointerOutsideSelectionRejectsStaleText() {
        let request = SelectionCaptureRequest(processID: 42, mouse: NSPoint(x: 700, y: 400),
            primaryTop: 1000, trigger: .pointer)
        XCTAssertNil(request.anchor(for: CGRect(x: 100, y: 200, width: 80, height: 20)))
    }

    /// 键盘选区不受远处鼠标影响，并将图标放到实际选区下方。
    func testKeyboardSelectionUsesBoundsInsteadOfMouseProximity() {
        let request = SelectionCaptureRequest(processID: 42, mouse: NSPoint(x: 700, y: 400),
            primaryTop: 1000, trigger: .keyboard)
        XCTAssertEqual(request.anchor(for: CGRect(x: 100, y: 200, width: 80, height: 20)),
                       NSPoint(x: 192, y: 775))
    }

    /// 没有有效矩形时使用触发处；副屏负坐标仍按主屏坐标系换算。
    func testMissingBoundsAndSecondaryDisplayCoordinates() {
        let request = SelectionCaptureRequest(processID: 42, mouse: NSPoint(x: -450, y: 1090),
            primaryTop: 1000, trigger: .pointer)
        XCTAssertEqual(request.anchor(for: nil), NSPoint(x: -438, y: 1078))
        XCTAssertEqual(request.anchor(for: .zero), NSPoint(x: -438, y: 1078))
        XCTAssertEqual(request.anchor(for: CGRect(x: -480, y: -100, width: 80, height: 20)),
                       NSPoint(x: -438, y: 1075))
    }

    /// 新选择取消等待时，不再读取旧选区或返回旧图标。
    func testCancelledDebounceNeverReadsSelection() async {
        let request = SelectionCaptureRequest(processID: 42, mouse: .zero,
            primaryTop: 1000, trigger: .pointer)
        var read = false
        let task = Task {
            await request.readAfterDebounce { _ in
                read = true
                return SelectionSnapshot(text: "stale", anchor: .zero, processID: 42)
            }
        }
        task.cancel()
        let snapshot = await task.value
        XCTAssertNil(snapshot)
        XCTAssertFalse(read)
    }

    /// 浏览器首次尚未暴露选区时重试，仍沿用松开时的来源与坐标。
    func testDelayedBrowserSelectionRetriesWithOriginalRequest() async {
        let request = SelectionCaptureRequest(processID: 42, mouse: NSPoint(x: 140, y: 790),
            primaryTop: 1000, trigger: .pointer)
        var attempts = 0
        let snapshot = await request.readAfterDebounce { captured in
            attempts += 1
            XCTAssertEqual(captured.processID, 42)
            XCTAssertEqual(captured.mouse, request.mouse)
            XCTAssertEqual(captured.primaryTop, 1000)
            XCTAssertEqual(captured.trigger, .pointer)
            guard attempts == 2 else { return nil }
            return SelectionSnapshot(text: "prioritize", anchor: captured.mouse, processID: captured.processID)
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(snapshot?.text, "prioritize")
    }

    /// 应用持续没有选区时只读两次，避免无限重试或不断触发界面。
    func testMissingSelectionStopsAfterOneRetry() async {
        let request = SelectionCaptureRequest(processID: 42, mouse: .zero,
            primaryTop: 1000, trigger: .keyboard)
        var attempts = 0
        let snapshot = await request.readAfterDebounce { _ in attempts += 1; return nil }
        XCTAssertNil(snapshot)
        XCTAssertEqual(attempts, 2)
    }

    /// 第一轮失败后发生新选择或切换应用取消任务，不再读取第二轮旧选区。
    func testCancellationAfterFirstAttemptPreventsRetry() async {
        let request = SelectionCaptureRequest(processID: 42, mouse: .zero,
            primaryTop: 1000, trigger: .pointer)
        var attempts = 0
        let task = Task {
            await request.readAfterDebounce { _ in
                attempts += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return nil
            }
        }
        let snapshot = await task.value
        XCTAssertNil(snapshot)
        XCTAssertEqual(attempts, 1)
    }

    /// AX 读取期间任务被取消，即使读到了文本也不能交给浮窗。
    func testCancellationDuringReadDiscardsReturnedSelection() async {
        let request = SelectionCaptureRequest(processID: 42, mouse: .zero,
            primaryTop: 1000, trigger: .pointer)
        let task = Task {
            await request.readAfterDebounce { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return SelectionSnapshot(text: "stale", anchor: .zero, processID: 42)
            }
        }
        let snapshot = await task.value
        XCTAssertNil(snapshot)
    }

    /// 已有选中文字时不访问范围接口，保留原文的空白和标点。
    func testDirectSelectedTextDoesNotReadRange() {
        XCTAssertEqual(SelectionText.read(direct: " prioritize ", range: nil) {
            XCTFail("已有文本不应重复读取范围")
            return nil
        }, " prioritize ")
    }

    /// 只暴露选区范围的应用通过范围接口取词，空白直读结果也能降级。
    func testSelectedRangeFallbackWhenDirectTextIsMissing() {
        for direct: String? in [nil, "", " \n"] {
            XCTAssertEqual(SelectionText.read(direct: direct, range: CFRange(location: 7, length: 10)) {
                "prioritize"
            }, "prioritize")
        }
    }

    /// 缺少范围、空光标、负位置和溢出范围不得读成整段或整页文字。
    func testInvalidOrEmptyRangeNeverReadsText() {
        let ranges: [CFRange?] = [nil, CFRange(location: 0, length: 0),
            CFRange(location: -1, length: 10), CFRange(location: 0, length: -1),
            CFRange(location: Int.max, length: 2)]
        for range in ranges {
            XCTAssertNil(SelectionText.read(direct: nil, range: range) {
                XCTFail("无效范围不应读取文字")
                return "entire page"
            })
        }
    }

    /// 范围接口失败或只返回非英文时，不产生虚假有效选区。
    func testRangeFallbackRejectsMissingOrNonEnglishText() {
        for text: String? in [nil, "", "  ", "中文"] {
            XCTAssertNil(SelectionText.read(direct: nil, range: CFRange(location: 0, length: 2)) { text })
        }
    }
}
