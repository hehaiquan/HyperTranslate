import AVFoundation
@testable import HyperTranslate
import XCTest

@MainActor
final class SpeechServiceTests: XCTestCase {
    /// 完成回调即代表当前语句结束，不应被合成器尚未刷新的忙碌状态阻挡。
    func testFinishRestoresIdleEvenWhenSynthesizerStillReportsSpeaking() async throws {
        let synthesizer = StubSpeechSynthesizer()
        let service = SpeechService(synthesizer: synthesizer)
        service.speak("problem", accent: "en-US")
        let utterance = try XCTUnwrap(synthesizer.utterances.last)
        XCTAssertTrue(service.isSpeaking)

        service.speechSynthesizer(synthesizer, didFinish: utterance)
        await drainCallbacks()

        XCTAssertTrue(synthesizer.isSpeaking)
        XCTAssertFalse(service.isSpeaking)
    }

    /// 系统取消当前语句后同样恢复朗读按钮，不依赖合成器状态刷新时机。
    func testCancellationRestoresIdle() async throws {
        let synthesizer = StubSpeechSynthesizer()
        let service = SpeechService(synthesizer: synthesizer)
        service.speak("problem", accent: "en-US")
        let utterance = try XCTUnwrap(synthesizer.utterances.last)

        service.speechSynthesizer(synthesizer, didCancel: utterance)
        await drainCallbacks()

        XCTAssertFalse(service.isSpeaking)
    }

    /// 单词被例句替换时，旧语句的完成和取消回调都不能结束新一轮朗读。
    func testStaleCallbacksDoNotFinishReplacementSpeech() async throws {
        let synthesizer = StubSpeechSynthesizer()
        let service = SpeechService(synthesizer: synthesizer)
        service.speak("problem", accent: "en-US")
        let previous = try XCTUnwrap(synthesizer.utterances.last)
        service.speechSynthesizer(synthesizer, didFinish: previous)
        service.speak("You got a problem with that?", accent: "en-US")
        let current = try XCTUnwrap(synthesizer.utterances.last)
        service.speechSynthesizer(synthesizer, didCancel: previous)
        await drainCallbacks()
        XCTAssertTrue(service.isSpeaking)

        service.speechSynthesizer(synthesizer, didFinish: current)
        await drainCallbacks()
        XCTAssertFalse(service.isSpeaking)
    }

    /// 主动停止应立即恢复按钮，旧回调到达后仍保持停止状态。
    func testStopRemainsIdleAfterLateCompletion() async throws {
        let synthesizer = StubSpeechSynthesizer()
        let service = SpeechService(synthesizer: synthesizer)
        service.speak("problem", accent: "en-US")
        let utterance = try XCTUnwrap(synthesizer.utterances.last)
        service.stop()
        XCTAssertFalse(service.isSpeaking)

        service.speechSynthesizer(synthesizer, didFinish: utterance)
        service.speechSynthesizer(synthesizer, didCancel: utterance)
        await drainCallbacks()
        XCTAssertFalse(service.isSpeaking)
    }

    /// 让已入队的主 actor 回调执行，不依赖真实音频播放或固定等待时间。
    private func drainCallbacks() async {
        for _ in 0..<10 { await Task.yield() }
    }
}

private final class StubSpeechSynthesizer: AVSpeechSynthesizer {
    var utterances: [AVSpeechUtterance] = []
    override var isSpeaking: Bool { true }

    /// 仅记录语句，不播放音频，以模拟完成回调与合成器状态不同步的场景。
    override func speak(_ utterance: AVSpeechUtterance) {
        utterances.append(utterance)
    }

    /// 测试中由用例控制回调时机，停止操作不主动发送系统事件。
    override func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }
}
