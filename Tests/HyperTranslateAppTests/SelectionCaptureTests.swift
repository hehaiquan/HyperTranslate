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
}
