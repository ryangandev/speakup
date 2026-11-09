import CryptoKit
import Foundation

/// Streams mono 16-bit PCM to a WAV file, the format the upload contract requires
/// (architecture.md#put-v1takestake_id).
///
/// The header's sizes are rewritten about once a second while recording, so a file cut
/// short by a crash or a killed app is still a valid WAV up to the last update.
final class WAVWriter {
    static let headerSize = 44

    let url: URL
    let sampleRate: Int
    private(set) var frameCount = 0
    private let handle: FileHandle
    private var framesSinceHeaderUpdate = 0
    private var isFinished = false

    init(url: URL, sampleRate: Int) throws {
        self.url = url
        self.sampleRate = sampleRate
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard manager.createFile(atPath: url.path, contents: Self.header(sampleRate: sampleRate, dataBytes: 0))
        else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit {
        if !isFinished { try? handle.close() }
    }

    var duration: Double { Double(frameCount) / Double(sampleRate) }

    func append(_ samples: UnsafeBufferPointer<Int16>) throws {
        guard !samples.isEmpty else { return }
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        try handle.write(contentsOf: data)
        frameCount += samples.count
        framesSinceHeaderUpdate += samples.count
        if framesSinceHeaderUpdate >= sampleRate {
            try updateHeader()
            try handle.seekToEnd()
            framesSinceHeaderUpdate = 0
        }
    }

    func append(_ samples: [Int16]) throws {
        try samples.withUnsafeBufferPointer { try append($0) }
    }

    /// Writes the final sizes and closes the file.
    ///
    /// `keepingFrames` drops every frame after that many first: driving mode cuts the
    /// spoken "done" off the end of a take this way. A count at or above `frameCount`
    /// keeps the whole file.
    func finish(keepingFrames keep: Int? = nil) throws {
        guard !isFinished else { return }
        isFinished = true
        if let keep, keep < frameCount {
            let kept = max(0, keep)
            try handle.truncate(atOffset: UInt64(Self.headerSize + kept * 2))
            frameCount = kept
        }
        try updateHeader()
        try handle.close()
    }

    private func updateHeader() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: frameCount * 2))
    }

    /// The 44-byte canonical header for mono 16-bit PCM.
    static func header(sampleRate: Int, dataBytes: Int) -> Data {
        var data = Data(capacity: headerSize)
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * bitsPerSample / 8
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)  // PCM
        append16(channels)
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate) * UInt32(blockAlign))
        append16(blockAlign)
        append16(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataBytes))
        return data
    }

    /// The lowercase hex SHA-256 of a file, read in chunks.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Pure sample conversions used by the recorder, kept separate so tests can check them.
enum AudioConversion {
    /// Averages channels into one.
    static func downmix(_ channels: [UnsafeBufferPointer<Float>], frames: Int) -> [Float] {
        guard let first = channels.first else { return [] }
        if channels.count == 1 { return Array(first.prefix(frames)) }
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels.count)
        for channel in channels {
            for index in 0..<frames { mono[index] += channel[index] * scale }
        }
        return mono
    }

    /// Converts float samples in -1...1 to 16-bit PCM, clipping anything outside.
    static func int16(_ samples: [Float]) -> [Int16] {
        samples.map { sample in
            let clipped = max(-1, min(1, sample))
            return Int16((clipped * Float(Int16.max)).rounded())
        }
    }

    /// The level shown while recording: RMS in dBFS mapped from -60...0 to 0...1.
    static func meterLevel(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        let rms = sqrt(Double(meanSquare))
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return max(0, min(1, (decibels + 60) / 60))
    }

    /// The upload contract accepts 16 to 48 kHz; anything outside is resampled to the nearest bound.
    static func outputSampleRate(forInput rate: Double) -> Int {
        Int(max(16_000, min(48_000, rate.rounded())))
    }
}
