import AVFoundation
import Combine

@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var message: String?
    private let synthesizer: AVSpeechSynthesizer
    private var activeUtterance: AVSpeechUtterance?

    /// 保持语音合成器存活，并订阅朗读完成回调。
    init(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        super.init()
        synthesizer.delegate = self
    }

    /// 按设置的英语口音朗读；连续点击会停止上一段。
    func speak(_ text: String, accent: String) {
        stop()
        guard let voice = AVSpeechSynthesisVoice(language: accent) else {
            message = "没有可用的英语语音，请在系统设置中下载英语声音。"
            return
        }
        message = nil
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.88
        activeUtterance = utterance
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// 停止当前朗读并清除播放状态。
    func stop() {
        activeUtterance = nil
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// 只结束当前语句，不依赖合成器状态刷新，并忽略旧语句的延迟回调。
    private func finish(_ utterance: AVSpeechUtterance) {
        guard activeUtterance === utterance else { return }
        activeUtterance = nil
        isSpeaking = false
    }

    /// 朗读结束后同步按钮状态。
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish(utterance) }
    }

    /// 系统取消朗读后同步按钮状态。
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish(utterance) }
    }
}
