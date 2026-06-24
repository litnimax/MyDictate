import Foundation

struct Transcript: Codable, Identifiable {
    enum Source: String, Codable { case dictation, file }
    var id = UUID()
    var text: String          // итоговый текст (после LLM/словаря) — он и вставляется
    var raw: String?          // оригинал от Whisper (до LLM) — для сравнения
    var date: Date
    var source: Source
    var fileName: String?
    var audioFile: String?    // путь к аудио (для повторного распознавания)
}

/// Хранит последние транскрипты (по умолчанию 10) с сохранением между запусками.
/// Аудио сохранённых диктовок чистится при вытеснении из истории.
final class TranscriptStore: ObservableObject {
    static let shared = TranscriptStore()

    @Published private(set) var items: [Transcript] = []
    private let maxItems = 10
    private let key = "transcripts"

    init() { load() }

    func add(_ text: String, raw: String? = nil, source: Transcript.Source,
             fileName: String? = nil, audioFile: String? = nil) {
        guard !text.isEmpty else { return }
        let item = Transcript(text: text, raw: raw, date: Date(), source: source,
                              fileName: fileName, audioFile: audioFile)
        items.insert(item, at: 0)
        trimAndClean()
        save()
    }

    /// Обновляет текст/оригинал записи (после повторного распознавания).
    func update(id: UUID, text: String, raw: String?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].text = text
        items[i].raw = raw
        items[i].date = Date()
        save()
    }

    private func trimAndClean() {
        guard items.count > maxItems else { return }
        let removed = items[maxItems...]
        for item in removed { deleteOwnedAudio(item) }
        items = Array(items.prefix(maxItems))
    }

    /// Удаляет аудиофайл, только если он лежит в нашей папке записей (не трогаем
    /// оригиналы пользователя, выбранные через «Транскрибировать файл…»).
    private func deleteOwnedAudio(_ item: Transcript) {
        guard let path = item.audioFile else { return }
        if path.hasPrefix(AppPaths.recordingsDir.path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Transcript].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
