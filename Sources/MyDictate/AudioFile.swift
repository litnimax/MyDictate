import Foundation

/// Минимальный писатель WAV (16-бит PCM, моно). Используется для сохранения
/// записанной диктовки, чтобы её можно было распознать заново из истории.
enum AudioFile {
    static func writeWAV(_ samples: [Float], sampleRate: Int = 16_000, to url: URL) throws {
        let numChannels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * numChannels * bitsPerSample / 8
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize = samples.count * 2

        var data = Data()
        func ascii(_ s: String) { data.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }

        ascii("RIFF"); u32(UInt32(36 + dataSize)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(UInt16(numChannels))
        u32(UInt32(sampleRate)); u32(UInt32(byteRate))
        u16(UInt16(blockAlign)); u16(UInt16(bitsPerSample))
        ascii("data"); u32(UInt32(dataSize))

        data.reserveCapacity(data.count + dataSize)
        for f in samples {
            let c = max(-1, min(1, f))
            var x = Int16(c * 32767).littleEndian
            data.append(Data(bytes: &x, count: 2))
        }
        try data.write(to: url)
    }
}
