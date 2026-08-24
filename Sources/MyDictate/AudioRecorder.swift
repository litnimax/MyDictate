import AVFoundation
import CoreAudio
import AudioToolbox

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Захватывает аудио с микрофона и приводит его к 16 кГц mono Float32 — формату, который ждёт whisper.cpp.
final class AudioRecorder {
    static let inputDeviceUIDKey = "audioInputDeviceUID"

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
        try selectConfiguredInputDevice(on: input)
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, inputFormat: inputFormat)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    static func availableInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }

        return ids.compactMap { id in
            guard hasInputStreams(id),
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: id),
                  let name = stringProperty(kAudioObjectPropertyName, for: id) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func selectConfiguredInputDevice(on input: AVAudioInputNode) throws {
        let savedUID = UserDefaults.standard.string(forKey: Self.inputDeviceUIDKey) ?? ""
        let deviceID: AudioDeviceID
        if savedUID.isEmpty {
            guard let defaultID = Self.defaultInputDeviceID() else {
                throw RecordingError.noInputDevice
            }
            deviceID = defaultID
        } else {
            guard let selected = Self.availableInputDevices().first(where: { $0.uid == savedUID }) else {
                throw RecordingError.selectedDeviceUnavailable
            }
            deviceID = selected.id
        }

        guard let audioUnit = input.audioUnit else { throw RecordingError.noAudioUnit }
        var mutableID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw RecordingError.cannotSelectDevice(status) }
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, for id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }

    private enum RecordingError: LocalizedError {
        case noInputDevice
        case selectedDeviceUnavailable
        case noAudioUnit
        case cannotSelectDevice(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "Системное устройство записи не найдено."
            case .selectedDeviceUnavailable:
                return "Выбранное устройство записи недоступно. Подключите его или выберите другое в Настройках."
            case .noAudioUnit:
                return "Не удалось инициализировать аудиовход."
            case .cannotSelectDevice(let status):
                return "Не удалось выбрать устройство записи (ошибка Core Audio \(status))."
            }
        }
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
