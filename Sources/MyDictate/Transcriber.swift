import Foundation
import WhisperKit

/// Локальная транскрибация через WhisperKit (Core ML, GPU + Apple Neural Engine).
/// Модели скачиваются автоматически (уже скомпилированные .mlmodelc) с Hugging Face
/// в ~/Documents/huggingface, поэтому первый запуск модели требует интернета.
/// Альтернативный движок — GigaAM-v3 RNNT (MLX, Python-воркер): выбирается той же
/// настройкой модели и маршрутизируется сюда же, интерфейс не меняется.
final class Transcriber {
    private var pipe: WhisperKit?
    private var loadedModel: String?
    private var loadTask: Task<WhisperKit, Error>?
    private let gigaam = GigaAMTranscriber()

    static let defaultModel = "large-v3-v20240930_turbo"

    enum TError: LocalizedError {
        case loadFailed(String)
        var errorDescription: String? {
            switch self {
            case .loadFailed(let m): return "Не удалось загрузить модель распознавания: \(m)"
            }
        }
    }

    var modelName: String {
        UserDefaults.standard.string(forKey: "whisperKitModel").flatMap { $0.isEmpty ? nil : $0 }
            ?? Transcriber.defaultModel
    }

    private var language: String {
        UserDefaults.standard.string(forKey: "language") ?? "auto"
    }

    private var isGigaAM: Bool { modelName == GigaAMTranscriber.modelID }

    /// Прогревает модель в фоне (скачивание + загрузка в GPU/ANE), чтобы первая
    /// диктовка не ждала.
    func preload() {
        if isGigaAM {
            gigaam.preload()
        } else {
            Task { try? await ensure() }
        }
    }

    /// Гарантирует, что нужная модель загружена; переиспользует уже загруженную.
    @discardableResult
    private func ensure() async throws -> WhisperKit {
        let wanted = modelName
        if let pipe, loadedModel == wanted { return pipe }

        // Если уже идёт загрузка той же модели — дождёмся её.
        if let task = loadTask {
            if let p = try? await task.value, loadedModel == wanted { return p }
        }

        let task = Task { () throws -> WhisperKit in
            let config: WhisperKitConfig
            let tokenizerFolder = AppPaths.supportDir
                .appendingPathComponent("tokenizers", isDirectory: true)
            if let folder = AppPaths.localModelFolder(wanted) {
                // Локальная Core ML-модель (напр. podlodka-turbo) — без скачивания.
                config = WhisperKitConfig(
                    modelFolder: folder,
                    tokenizerFolder: tokenizerFolder,
                    download: false
                )
            } else {
                config = WhisperKitConfig(model: wanted, tokenizerFolder: tokenizerFolder)
            }
            return try await WhisperKit(config)
        }
        loadTask = task
        do {
            let p = try await task.value
            pipe = p
            loadedModel = wanted
            loadTask = nil
            return p
        } catch {
            loadTask = nil
            throw TError.loadFailed(error.localizedDescription)
        }
    }

    private func options(translateToEnglish: Bool = false) -> DecodingOptions {
        let lang = language
        if translateToEnglish {
            // Встроенный перевод Whisper в английский (используется, когда LLM выключен).
            return DecodingOptions(task: .translate, skipSpecialTokens: true,
                                   withoutTimestamps: true, chunkingStrategy: .vad)
        }
        return DecodingOptions(
            task: .transcribe,
            language: lang == "auto" ? nil : lang,
            detectLanguage: lang == "auto",
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad
        )
    }

    func transcribe(_ frames: [Float], translateToEnglish: Bool = false) async throws -> String {
        // GigaAM переводить не умеет (только распознавание рус/англ) —
        // при выборе этого движка translateToEnglish игнорируется.
        if isGigaAM {
            releaseWhisper()
            return try await gigaam.transcribe(frames)
        }
        Task { await gigaam.shutdown() } // воркер GigaAM больше не нужен
        let pipe = try await ensure()
        let results = try await pipe.transcribe(audioArray: frames, decodeOptions: options(translateToEnglish: translateToEnglish))
        return Self.join(results)
    }

    /// Транскрибация аудиофайла (WhisperKit сам загружает и конвертирует аудио).
    func transcribeFile(_ url: URL) async throws -> String {
        if isGigaAM {
            releaseWhisper()
            // Декодируем файл средствами WhisperKit (AVFoundation) в 16 кГц mono
            // Float32 — воркер GigaAM принимает только такой WAV, ffmpeg не нужен.
            let frames = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
            return try await gigaam.transcribe(frames)
        }
        Task { await gigaam.shutdown() }
        let pipe = try await ensure()
        let results = try await pipe.transcribe(audioPath: url.path, decodeOptions: options())
        return Self.join(results)
    }

    /// Освобождает Core ML-модель WhisperKit при работе через GigaAM.
    private func releaseWhisper() {
        pipe = nil
        loadedModel = nil
    }

    private static func join(_ results: [TranscriptionResult]) -> String {
        results.map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
