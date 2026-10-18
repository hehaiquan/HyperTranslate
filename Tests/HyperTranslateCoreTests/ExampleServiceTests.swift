import Foundation
@testable import HyperTranslateCore
import XCTest

final class ExampleServiceTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!

    /// 为每个测试创建独立缓存和可控制的 HTTP 会话。
    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HyperTranslateTests-" + UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        StubURLProtocol.reset()
    }

    /// 释放网络任务并删除测试缓存。
    override func tearDown() {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// 验证去重、条数限制、来源许可保留及可选字段缺失。
    func testDecodeDeduplicationAndAttribution() throws {
        let values = try ExampleService.decode(StubURLProtocol.fixture)
        XCTAssertEqual(values.map(\.english), ["Hello, world!", "She said hello."])
        XCTAssertEqual(values[0].licenseName, "CC BY-SA 3.0")
        XCTAssertEqual(values[0].sourceURLs, ["https://en.wiktionary.org/wiki/hello"])
        XCTAssertNil(values[0].chinese)
        let empty = Data("[{\"meanings\":[{\"definitions\":[{\"definition\":\"No example\"}]}]}]".utf8)
        XCTAssertTrue(try ExampleService.decode(empty).isEmpty)
    }

    /// 请求地址只包含单词，已翻译缓存可在后续离线查询中复用。
    func testNetworkAndTranslatedCache() async throws {
        let service = ExampleService(session: session, cacheDirectory: directory)
        var examples = try await service.examples(for: "hello")
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.path, "/api/v2/entries/en/hello")
        examples[0].chinese = "你好，世界！"
        try await service.save(examples, for: "hello")
        let count = StubURLProtocol.requests.count
        StubURLProtocol.offline = true
        let cached = try await service.examples(for: "HELLO")
        XCTAssertEqual(cached[0].chinese, "你好，世界！")
        XCTAssertEqual(StubURLProtocol.requests.count, count)
    }

    /// 对无收录返回空例句，服务器错误与格式变化不能伪装成正常结果。
    func testNotFoundAndFailures() async throws {
        let service = ExampleService(session: session, cacheDirectory: directory)
        let missing = try await service.examples(for: "missing")
        XCTAssertTrue(missing.isEmpty)
        for word in ["failure", "broken"] {
            do { _ = try await service.examples(for: word); XCTFail("应当报告接口异常") }
            catch { XCTAssertFalse(error is CancellationError) }
        }
    }

    /// 拒绝句子和路径字符串，确保不会向接口发送段落或写入越界路径。
    func testRejectsPassagesAndPaths() async {
        let service = ExampleService(session: session, cacheDirectory: directory)
        for input in ["A private sentence.", "../../hello", String(repeating: "a", count: 101)] {
            do { _ = try await service.examples(for: input); XCTFail("应当拒绝非单词输入") }
            catch {}
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// 取消请求必须继续报告取消，不能拿缓存掩盖取消状态。
    func testCancelledRequestDoesNotPublishExamples() async {
        let service = ExampleService(session: session, cacheDirectory: directory)
        let task = Task { try await service.examples(for: "hello") }
        task.cancel()
        do { _ = try await task.value; XCTFail("取消后不应返回例句") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }

    /// 即使已有缓存，取消的调用也不能绕过取消检查返回旧例句。
    func testCancelledRequestDoesNotReturnCachedExamples() async throws {
        let service = ExampleService(session: session, cacheDirectory: directory)
        _ = try await service.examples(for: "hello")
        let task = Task { try await service.examples(for: "hello") }
        task.cancel()
        do { _ = try await task.value; XCTFail("已取消的缓存查询不应返回内容") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    /// 缓存目录无法写入时，已成功取得的在线例句仍应显示。
    func testCacheWriteFailureDoesNotDiscardNetworkResult() async throws {
        try Data("not a directory".utf8).write(to: directory)
        let service = ExampleService(session: session, cacheDirectory: directory)
        let examples = try await service.examples(for: "hello")
        XCTAssertEqual(examples.count, 2)
    }
}

private final class StubURLProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var offline = false
    static let fixture = Data(#"[{"meanings":[{"definitions":[{"example":"Hello, world!"},{"example":"Hello, world!"},{"example":"She said hello."},{"example":"Another sentence."}]}],"sourceUrls":["https://en.wiktionary.org/wiki/hello"],"license":{"name":"CC BY-SA 3.0","url":"https://creativecommons.org/licenses/by-sa/3.0"}}]"#.utf8)

    /// 重置测试网络状态。
    static func reset() { requests = []; offline = false }
    /// 处理测试会话的所有请求。
    override class func canInit(with request: URLRequest) -> Bool { true }
    /// 保持原始请求，便于断言查询地址。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    /// 返回可预测的成功、无收录、错误或离线响应。
    override func startLoading() {
        Self.requests.append(request)
        if Self.offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let word = request.url!.lastPathComponent
        let status = word == "missing" ? 404 : word == "failure" ? 503 : 200
        let data = word == "broken" ? Data("invalid JSON".utf8) : Self.fixture
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    /// Stub 不持有异步网络操作，无需额外取消工作。
    override func stopLoading() {}
}
