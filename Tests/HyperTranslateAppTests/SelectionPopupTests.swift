import AppKit
@testable import HyperTranslate
import XCTest

@MainActor
final class SelectionPopupTests: XCTestCase {
    private let selection = SelectionSnapshot(text: "hello", anchor: NSPoint(x: 220, y: 500), processID: 42)

    /// 默认延续原有手动流程，只传递选区快照，不打开结果或发起翻译。
    func testDefaultManualModeOnlyPresentsIndicator() async {
        withPreferences { preferences in
            let state = AppState(preferences: preferences)
            var captured: SelectionSnapshot?
            var openedResult = false
            state.showPanel = { _, _ in openedResult = true }
            state.presentSelection(selection) { captured = $0 }
            XCTAssertEqual(state.selectionPopupMode, .manual)
            XCTAssertEqual(captured?.text, selection.text)
            XCTAssertEqual(captured?.anchor, selection.anchor)
            XCTAssertEqual(captured?.processID, selection.processID)
            XCTAssertFalse(openedResult)
            XCTAssertNil(state.input)
            state.shutdown()
        }
    }

    /// 自动模式直接使用同一份原文及坐标打开查询，不经过图标点击。
    func testAutomaticModeQueriesCapturedTextAtSelectionAnchor() async {
        withPreferences { preferences in
            let state = AppState(preferences: preferences)
            state.selectionPopupMode = .automatic
            var openedPage: AppState.Page?
            var openedAnchor: NSPoint?
            state.showPanel = { openedPage = $0; openedAnchor = $1 }
            state.presentSelection(selection) { _ in XCTFail("自动模式不应显示图标") }
            XCTAssertEqual(openedPage, .result)
            XCTAssertEqual(openedAnchor, selection.anchor)
            XCTAssertEqual(state.input?.text, selection.text)
            XCTAssertTrue(state.isTranslating)
            state.shutdown()
        }
    }

    /// 暂停和准备语言包期间，两种模式都不能展示图标或触发新查询。
    func testPauseAndLanguagePreparationSuppressBothModes() async {
        withPreferences { preferences in
            let state = AppState(preferences: preferences)
            state.showPanel = { _, _ in XCTFail("受阻状态不应打开结果") }
            for mode in SelectionPopupMode.allCases {
                state.selectionPopupMode = mode
                state.paused = true
                state.presentSelection(selection) { _ in XCTFail("暂停时不应显示图标") }
                state.paused = false
                state.isPreparing = true
                state.presentSelection(selection) { _ in XCTFail("准备语言包时不应显示图标") }
                state.isPreparing = false
            }
            XCTAssertNil(state.input)
            XCTAssertFalse(state.isTranslating)
            state.shutdown()
        }
    }

    /// 切换弹出方式后重新创建应用状态，必须恢复上次设置。
    func testModeSurvivesRestartInBothDirections() async {
        withPreferences { preferences in
            let first = AppState(preferences: preferences)
            first.selectionPopupMode = .automatic
            let restarted = AppState(preferences: preferences)
            XCTAssertEqual(restarted.selectionPopupMode, .automatic)
            restarted.selectionPopupMode = .manual
            let last = AppState(preferences: preferences)
            XCTAssertEqual(last.selectionPopupMode, .manual)
            first.shutdown()
            restarted.shutdown()
            last.shutdown()
        }
    }

    /// 未知或失效的设置值安全回到手动模式，避免升级后突然自动弹窗。
    func testUnknownPreferenceFallsBackToManual() async {
        withPreferences { preferences in
            preferences.set("invalid-mode", forKey: "selectionPopupMode")
            let state = AppState(preferences: preferences)
            XCTAssertEqual(state.selectionPopupMode, .manual)
            state.shutdown()
        }
    }

    /// 使用独立偏好域验证持久化，并在结束后清理，不修改用户实际设置。
    private func withPreferences(_ body: (UserDefaults) -> Void) {
        let domain = "HyperTranslateTests.Popup.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        body(preferences)
    }
}
