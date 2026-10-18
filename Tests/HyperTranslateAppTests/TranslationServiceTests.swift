import Foundation
@testable import HyperTranslate
import XCTest

@MainActor
final class TranslationServiceTests: XCTestCase {
    /// 取消等待中的翻译时释放 continuation，并推进配置以取消 SwiftUI 系统任务。
    func testCancellationInvalidatesSystemTaskConfiguration() async {
        let service = TranslationService()
        let task = Task { try await service.translate(["Hello, world."]) }
        await waitForRequest(service)
        let version = service.configuration?.version
        task.cancel()
        do { _ = try await task.value; XCTFail("已取消的翻译应当结束") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(service.isWorking)
        XCTAssertNotEqual(service.configuration?.version, version)
    }

    /// 连续查询会结束旧请求，并为新请求保留独立标识，避免宿主挂起。
    func testNewRequestReplacesPreviousContinuation() async {
        let service = TranslationService()
        let first = Task { try await service.translate(["First sentence."]) }
        await waitForRequest(service)
        let oldID = service.requestID
        let second = Task { try await service.translate(["Second sentence."]) }
        for _ in 0..<30 {
            if service.requestID != oldID { break }
            await Task.yield()
        }
        XCTAssertNotEqual(service.requestID, oldID)
        do { _ = try await first.value; XCTFail("旧请求应当取消") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(service.isWorking)
        second.cancel()
        _ = try? await second.value
        XCTAssertFalse(service.isWorking)
    }

    /// 空白段落直接返回，不创建任何系统翻译任务。
    func testWhitespaceDoesNotScheduleSystemWork() async throws {
        let service = TranslationService()
        let values = try await service.translate(["\n\n", "  "])
        XCTAssertEqual(values, ["\n\n", "  "])
        XCTAssertNil(service.configuration)
        XCTAssertFalse(service.isWorking)
    }

    /// 等待主 actor 上的请求入队，不依赖下载语言包或创建真实窗口。
    private func waitForRequest(_ service: TranslationService) async {
        for _ in 0..<30 {
            if service.isWorking { return }
            await Task.yield()
        }
        XCTFail("翻译请求未能入队")
    }
}
