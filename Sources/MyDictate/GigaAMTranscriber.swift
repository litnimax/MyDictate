import Foundation

/// Движок GigaAM-v3 RNNT (Conformer, MLX) — русская/английская речь с родной
/// пунктуацией. Модель питоновская (пакет gigaam-mlx), поэтому работает через
/// постоянный Python-воркер: приложение шлёт в stdin путь к WAV (16 кГц моно),
/// воркер отвечает JSON-строкой. Установка — scripts/setup-gigaam-mlx.sh
/// (venv + воркер в ~/Library/Application Support/MyDictate/gigaam-mlx).
actor GigaAMTranscriber {
    /// Идентификатор в списке моделей (ключ whisperKitModel в UserDefaults).
    static let modelID = "gigaam-v3-rnnt-mlx"

    static var installDir: URL {
        AppPaths.supportDir.appendingPathComponent("gigaam-mlx", isDirectory: true)
    }
    private static var pythonURL: URL { installDir.appendingPathComponent("venv/bin/python3") }
    private static var workerURL: URL { installDir.appendingPathComponent("worker.py") }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: pythonURL.path)
            && FileManager.default.fileExists(atPath: workerURL.path)
    }

    enum GError: LocalizedError {
        case notInstalled
        case workerDied(String)
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Движок GigaAM не установлен. Запустите из папки проекта: ./scripts/setup-gigaam-mlx.sh"
            case .workerDied(let tail):
                return "Воркер GigaAM завершился. \(tail.isEmpty ? "" : "Последний вывод: \(tail)")"
            case .failed(let m):
                return "GigaAM: \(m)"
            }
        }
    }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator?
    private var ready = false
    private var stderrTail = ""
    private var startTask: Task<Void, Error>?
    private var chain: Task<String, Error>? // сериализация запросов (актор реентерабелен)

    // MARK: - Публичный интерфейс

    nonisolated func preload() {
        Task { try? await ensureWorker() }
    }

    func transcribe(_ frames: [Float]) async throws -> String {
        let prev = chain
        let task = Task { () throws -> String in
            _ = try? await prev?.value
            return try await perform(frames)
        }
        chain = task
        return try await task.value
    }

    /// Останавливает воркер (освобождает ~1 ГБ памяти). Вызывается при
    /// переключении на WhisperKit; при незапущенном воркере — no-op.
    func shutdown() {
        guard let p = process else { return }
        p.terminationHandler = nil
        p.terminate()
        process = nil
        stdinHandle = nil
        lines = nil
        ready = false
    }

    // MARK: - Работа с воркером

    private func perform(_ frames: [Float]) async throws -> String {
        try await ensureWorker()

        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("gigaam-\(UUID().uuidString).wav")
        try AudioFile.writeWAV(frames, to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let request = try JSONSerialization.data(withJSONObject: ["path": wav.path])
        guard let stdinHandle, var it = lines else { throw GError.workerDied(stderrTail) }
        try stdinHandle.write(contentsOf: request + Data("\n".utf8))

        while let line = try await it.next() {
            guard let obj = Self.json(line) else { continue }
            if let text = obj["text"] as? String { lines = it; return text }
            if let err = obj["error"] as? String { lines = it; throw GError.failed(err) }
        }
        // stdout закрылся — воркер умер.
        shutdown()
        throw GError.workerDied(stderrTail)
    }

    private func ensureWorker() async throws {
        if let p = process, p.isRunning, ready { return }
        if let t = startTask {
            try? await t.value
            if let p = process, p.isRunning, ready { return }
        }
        let t = Task { try await launchAndAwaitReady() }
        startTask = t
        do {
            try await t.value
            startTask = nil
        } catch {
            startTask = nil
            shutdown()
            throw error
        }
    }

    private func launchAndAwaitReady() async throws {
        guard Self.isInstalled else { throw GError.notInstalled }

        let p = Process()
        p.executableURL = Self.pythonURL
        p.arguments = [Self.workerURL.path]

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        // stderr копим для диагностики (последний хвост). На EOF обработчик
        // обязательно снять, иначе он крутится вхолостую.
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            guard let s = String(data: data, encoding: .utf8) else { return }
            Task { await self?.appendStderr(s) }
        }

        try p.run()
        process = p
        stdinHandle = inPipe.fileHandleForWriting
        var iterator = outPipe.fileHandleForReading.bytes.lines.makeAsyncIterator()

        // Ждём {"ready": true} — загрузка модели ~5с (или дольше, если веса ещё качаются).
        while let line = try await iterator.next() {
            if Self.json(line)?["ready"] != nil {
                lines = iterator
                ready = true
                return
            }
        }
        throw GError.workerDied(stderrTail)
    }

    private func appendStderr(_ s: String) {
        stderrTail = String((stderrTail + s).suffix(800))
    }

    private static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
