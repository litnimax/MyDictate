import AVFoundation
import AudioToolbox
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable {
    var id: String { uid }
    let uid: String
    let name: String
}

/// Захватывает аудио с выбранного Core Audio-устройства в 16 кГц mono Float32.
final class AudioRecorder {
    static let inputDeviceUIDKey = "audioInputDeviceUID"

    private let lock = NSLock()
    private var audioUnit: AudioUnit?
    private var renderBuffer: UnsafeMutablePointer<Float>?
    private let renderBufferCapacity: UInt32 = 16_384
    private var captureSampleRate: Double = 16_000
    private var _samples: [Float] = []
    private var _paused = false

    /// Колбэк с уровнем громкости (RMS, 0...1) для индикатора. Вызывается на главном потоке.
    var onLevel: ((Float) -> Void)?
    private(set) var isRecording = false

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

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw RecordingError.cannotCreateAudioUnit
        }

        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit))
        guard let unit else { throw RecordingError.cannotCreateAudioUnit }

        do {
            var enabled: UInt32 = 1
            try check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                &enabled, UInt32(MemoryLayout<UInt32>.size)
            ))
            var disabled: UInt32 = 0
            try check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                &disabled, UInt32(MemoryLayout<UInt32>.size)
            ))

            var deviceID = try configuredInputDeviceID()
            captureSampleRate = try Self.nominalSampleRate(for: deviceID)
            try check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
            ))

            var format = AudioStreamBasicDescription(
                mSampleRate: captureSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
                mChannelsPerFrame: 1,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            try check(AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ))

            var callback = AURenderCallbackStruct(
                inputProc: { refCon, flags, timestamp, _, frameCount, _ in
                    return Unmanaged<AudioRecorder>.fromOpaque(refCon).takeUnretainedValue()
                        .render(flags: flags, timestamp: timestamp, frameCount: frameCount)
                },
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ))

            renderBuffer = .allocate(capacity: Int(renderBufferCapacity))
            audioUnit = unit
            try check(AudioUnitInitialize(unit))
            try check(AudioOutputUnitStart(unit))
            isRecording = true
        } catch {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            renderBuffer?.deallocate()
            renderBuffer = nil
            audioUnit = nil
            throw error
        }
    }

    /// Останавливает запись и возвращает накопленные сэмплы (16 кГц mono).
    func stop() -> [Float] {
        guard isRecording else { return currentSamples }
        isRecording = false
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        audioUnit = nil
        renderBuffer?.deallocate()
        renderBuffer = nil
        return resampleTo16k(currentSamples)
    }

    // MARK: - Устройства

    static func availableInputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard hasInputStreams(id),
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: id),
                  let name = stringProperty(kAudioObjectPropertyName, for: id) else { return nil }
            return AudioInputDevice(uid: uid, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func configuredInputDeviceID() throws -> AudioDeviceID {
        let savedUID = UserDefaults.standard.string(forKey: Self.inputDeviceUIDKey) ?? ""
        if savedUID.isEmpty {
            guard let id = Self.defaultInputDeviceID() else { throw RecordingError.noInputDevice }
            return id
        }
        guard let id = Self.allDeviceIDs().first(where: {
            Self.stringProperty(kAudioDevicePropertyDeviceUID, for: $0) == savedUID
        }) else {
            throw RecordingError.selectedDeviceUnavailable
        }
        return id
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
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

    private static func nominalSampleRate(for id: AudioDeviceID) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &sampleRate) == noErr,
              sampleRate > 0 else { throw RecordingError.cannotReadDeviceFormat }
        return sampleRate
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

    // MARK: - Получение сэмплов

    private func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        guard let unit = audioUnit, let renderBuffer, frameCount <= renderBufferCapacity else {
            return kAudio_ParamError
        }

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: frameCount * UInt32(MemoryLayout<Float>.size),
                mData: renderBuffer
            )
        )
        let status = AudioUnitRender(unit, flags, timestamp, 1, frameCount, &bufferList)
        guard status == noErr else { return status }

        lock.lock()
        if _paused {
            lock.unlock()
            return noErr
        }
        _samples.append(contentsOf: UnsafeBufferPointer(start: renderBuffer, count: Int(frameCount)))
        lock.unlock()

        var sumSq: Float = 0
        for i in 0..<Int(frameCount) { sumSq += renderBuffer[i] * renderBuffer[i] }
        let level = min(1.0, sqrt(sumSq / Float(frameCount)) * 4.0)
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        return noErr
    }

    private var currentSamples: [Float] {
        lock.lock(); defer { lock.unlock() }
        return _samples
    }

    private func resampleTo16k(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty, abs(captureSampleRate - 16_000) >= 1,
              let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: captureSampleRate,
                channels: 1,
                interleaved: false
              ),
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
              ) else { return samples }

        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { source in
            input.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }

        let capacity = AVAudioFrameCount(Double(samples.count) * 16_000 / captureSampleRate + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return samples }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let channel = output.floatChannelData else { return samples }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
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

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw RecordingError.coreAudio(status) }
    }

    private enum RecordingError: LocalizedError {
        case noInputDevice
        case selectedDeviceUnavailable
        case cannotCreateAudioUnit
        case cannotReadDeviceFormat
        case coreAudio(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "Системное устройство записи не найдено."
            case .selectedDeviceUnavailable:
                return "Выбранное устройство записи недоступно. Подключите его или выберите другое в Настройках."
            case .cannotCreateAudioUnit:
                return "Не удалось создать аудиовход."
            case .cannotReadDeviceFormat:
                return "Не удалось определить частоту устройства записи."
            case .coreAudio(let status):
                return "Не удалось настроить устройство записи (ошибка Core Audio \(status))."
            }
        }
    }
}
