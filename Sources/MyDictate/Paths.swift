import Foundation

enum AppPaths {
    /// ~/Library/Application Support/MyDictate
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MyDictate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Папка для локальных Core ML-моделей WhisperKit (сконвертированных вручную,
    /// напр. podlodka-turbo). Каждая модель — подпапка с *.mlmodelc.
    static var coremlModelsDir: URL {
        let dir = supportDir.appendingPathComponent("coreml-models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Путь к локальной модели по имени, если она реально установлена (есть AudioEncoder).
    static func localModelFolder(_ name: String) -> String? {
        let dir = coremlModelsDir.appendingPathComponent(name, isDirectory: true)
        let enc = dir.appendingPathComponent("AudioEncoder.mlmodelc")
        return FileManager.default.fileExists(atPath: enc.path) ? dir.path : nil
    }

    /// Имена установленных локальных моделей.
    static func availableLocalModels() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: coremlModelsDir.path)) ?? []
        return items.filter { localModelFolder($0) != nil }.sorted()
    }

    /// Папка для сохранённых записей диктовок (для повторного распознавания из истории).
    static var recordingsDir: URL {
        let dir = supportDir.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var modelsDir: URL {
        let dir = supportDir.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Текущая выбранная модель (по умолчанию ggml-base). Можно переопределить в настройках.
    static var modelURL: URL {
        let name = UserDefaults.standard.string(forKey: "modelFileName") ?? "ggml-base.bin"
        return modelsDir.appendingPathComponent(name)
    }

    static var modelExists: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    /// Список установленных моделей Whisper (ggml-*.bin) в папке моделей.
    static func availableModels() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path)) ?? []
        return items.filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }.sorted()
    }
}
