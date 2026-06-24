import AVFoundation

/// Захватывает аудио с микрофона и приводит его к 16 кГц mono Float32 — формату, который ждёт whisper.cpp.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let lock = NSLock()
    private var _samples: [Float] = []
    private var _paused = false

    /// Колбэк с уровнем громкости (RMS, 0...1) для индикатора. Вызывается на главном потоке.
    var onLevel: ((Float) -> Void)?
    private(set) var isRecording = false

    init() {
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: 16_000,
                                     channels: 1,
                                     interleaved: false)!
    }

    // MARK: - Разрешение на микрофон

    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - Запись

    func start() throws {
        lock.lock(); _samples.removeAll(); _paused = false; lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, inputFormat: inputFormat)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Останавливает запись и возвращает накопленные сэмплы (16 кГц mono).
    func stop() -> [Float] {
        guard isRecording else { return currentSamples }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        return currentSamples
    }

    private var currentSamples: [Float] {
        lock.lock(); defer { lock.unlock() }
        return _samples
    }

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return _paused
    }

    func setPaused(_ paused: Bool) {
        lock.lock(); _paused = paused; lock.unlock()
        if paused {
            DispatchQueue.main.async { [weak self] in self?.onLevel?(0) }
        }
    }

    // MARK: - Конвертация

    private func process(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        if isPaused { return } // на паузе сэмплы не накапливаем
        guard let converter = converter else { return }
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if err != nil { return }

        guard let channel = out.floatChannelData, out.frameLength > 0 else { return }
        let n = Int(out.frameLength)
        let ptr = channel[0]

        var sumSq: Float = 0
        for i in 0..<n { sumSq += ptr[i] * ptr[i] }

        lock.lock()
        _samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: n))
        lock.unlock()

        let level = min(1.0, sqrt(sumSq / Float(n)) * 4.0) // лёгкое усиление для наглядности
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }
}
