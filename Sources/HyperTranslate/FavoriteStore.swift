import Combine
import Foundation
import HyperTranslateCore

struct FavoriteWord: Codable, Equatable, Identifiable {
    let word: String
    let phonetic: String
    let definition: String
    let savedAt: Date

    var id: String { word.lowercased().replacingOccurrences(of: "’", with: "'") }
}

@MainActor
final class FavoriteStore: ObservableObject {
    @Published private(set) var words: [FavoriteWord] = []
    @Published private(set) var errorMessage: String?
    private let fileURL: URL
    private var canWrite = true

    /// 从用户应用支持目录读取收藏；测试可指定独立文件，不触碰真实收藏。
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? URL.applicationSupportDirectory
            .appendingPathComponent("com.hypertranslate.mac", isDirectory: true)
            .appendingPathComponent("Favorites.json")
        do {
            let data = try Data(contentsOf: self.fileURL)
            words = try JSONDecoder().decode([FavoriteWord].self, from: data)
                .sorted { $0.savedAt > $1.savedAt }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // 首次使用尚未创建收藏文件。
        } catch {
            canWrite = false
            errorMessage = "收藏读取失败，原文件已保留。请检查文件后重新启动。\n" + error.localizedDescription
        }
    }

    /// 按大小写无关的原选单词判断是否收藏，统一弯引号。
    func contains(_ word: String) -> Bool {
        let key = word.lowercased().replacingOccurrences(of: "’", with: "'")
        return words.contains { $0.id == key }
    }

    /// 收藏有释义的单词；相同单词不重复写入，保留变形词本身。
    func add(word: String, phonetic: String, definition: String) {
        guard let input = try? TranslationInput(word), input.kind == .word,
              !definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !contains(input.text) else { return }
        let favorite = FavoriteWord(word: input.text, phonetic: phonetic,
                                    definition: definition, savedAt: Date())
        persist([favorite] + words)
    }

    /// 移除指定单词；落盘成功后才更新列表，失败时保留原收藏。
    func remove(_ word: String) {
        let key = word.lowercased().replacingOccurrences(of: "’", with: "'")
        persist(words.filter { $0.id != key })
    }

    /// 原子写入收藏文件，避免写入中断损坏已有数据；读取异常时禁止覆盖。
    private func persist(_ updated: [FavoriteWord]) {
        guard canWrite else { return }
        do {
            let data = try JSONEncoder().encode(updated)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            words = updated
            errorMessage = nil
        } catch {
            errorMessage = "收藏未能保存，请检查目录权限和可用空间后重试。\n" + error.localizedDescription
        }
    }
}
