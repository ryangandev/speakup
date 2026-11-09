import AVFoundation
import Foundation
import Testing
@testable import SpeakUp

/// The mono 16-bit WAV the upload contract requires, and the conversions feeding it.
struct WAVWriterTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "wav-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "take.wav")
    }

    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }

    private func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    @Test func headerIsCanonicalMono16BitPCM() {
        let header = WAVWriter.header(sampleRate: 48_000, dataBytes: 96_000)
        #expect(header.count == 44)
        #expect(String(decoding: header[0..<4], as: UTF8.self) == "RIFF")
        #expect(uint32(header, at: 4) == 36 + 96_000)
        #expect(String(decoding: header[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: header[12..<16], as: UTF8.self) == "fmt ")
        #expect(uint32(header, at: 16) == 16)
        #expect(uint16(header, at: 20) == 1)  // PCM
        #expect(uint16(header, at: 22) == 1)  // mono
        #expect(uint32(header, at: 24) == 48_000)
        #expect(uint32(header, at: 28) == 96_000)  // byte rate
        #expect(uint16(header, at: 32) == 2)  // block align
        #expect(uint16(header, at: 34) == 16)
        #expect(String(decoding: header[36..<40], as: UTF8.self) == "data")
        #expect(uint32(header, at: 40) == 96_000)
    }

    @Test func writesLittleEndianSamplesAndFinalSizes() throws {
        let url = temporaryURL()
        let writer = try WAVWriter(url: url, sampleRate: 16_000)
        try writer.append([0, 1, -1, Int16.max, Int16.min])
        try writer.append([Int16]())
        try writer.finish()

        let data = try Data(contentsOf: url)
        #expect(data.count == 44 + 10)
        #expect(uint32(data, at: 40) == 10)
        #expect(uint32(data, at: 4) == 46)
        #expect(Array(data[44...]) == [0x00, 0x00, 0x01, 0x00, 0xFF, 0xFF, 0xFF, 0x7F, 0x00, 0x80])
        #expect(writer.frameCount == 5)
        #expect(writer.duration == 5.0 / 16_000)
    }

    @Test func headerIsUpdatedWhileRecording() throws {
        let url = temporaryURL()
        let writer = try WAVWriter(url: url, sampleRate: 16_000)
        try writer.append([Int16](repeating: 7, count: 16_000))
        try writer.append([Int16](repeating: 7, count: 100))

        // Without finish(): a recording cut short is still valid up to the last update.
        let partial = try Data(contentsOf: url)
        #expect(partial.count == 44 + 16_100 * 2)
        #expect(uint32(partial, at: 40) == 32_000)

        try writer.finish()
        let final = try Data(contentsOf: url)
        #expect(uint32(final, at: 40) == 32_200)
    }

    @Test func avFoundationReadsTheFile() throws {
        let url = temporaryURL()
        let writer = try WAVWriter(url: url, sampleRate: 44_100)
        try writer.append((0..<44_100).map { Int16(sin(Double($0) / 10) * 10_000) })
        try writer.finish()

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.sampleRate == 44_100)
        #expect(file.length == 44_100)
        #expect(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
    }

    @Test func finishKeepingFramesTruncatesAndRewritesTheHeader() throws {
        let url = temporaryURL()
        let writer = try WAVWriter(url: url, sampleRate: 16_000)
        // Past one header update, so the header on disk is stale before the cut.
        try writer.append((0..<20_000).map { Int16(truncatingIfNeeded: $0) })
        try writer.finish(keepingFrames: 12_345)

        let data = try Data(contentsOf: url)
        #expect(data.count == 44 + 12_345 * 2)
        #expect(uint32(data, at: 4) == 36 + 12_345 * 2)
        #expect(uint32(data, at: 40) == 12_345 * 2)
        #expect(writer.frameCount == 12_345)
        // The kept frames are the first ones.
        #expect(uint16(data, at: 44 + 12_344 * 2) == UInt16(12_344))
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 12_345)
    }

    @Test func finishKeepingMoreFramesThanWrittenKeepsTheWholeFile() throws {
        let url = temporaryURL()
        let writer = try WAVWriter(url: url, sampleRate: 16_000)
        try writer.append([Int16](repeating: 3, count: 100))
        try writer.finish(keepingFrames: 1_000)
        #expect(try Data(contentsOf: url).count == 44 + 200)
        #expect(writer.frameCount == 100)
    }

    @Test func finishKeepingNoFramesLeavesAnEmptyValidFile() throws {
        let url = temporaryURL()
        let writer = try WAVWriter(url: url, sampleRate: 16_000)
        try writer.append([Int16](repeating: 3, count: 100))
        try writer.finish(keepingFrames: -5)
        let data = try Data(contentsOf: url)
        #expect(data.count == 44)
        #expect(uint32(data, at: 40) == 0)
        #expect(writer.frameCount == 0)
    }

    @Test func sha256IsLowercaseHexOfTheWholeFile() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: url)
        #expect(try WAVWriter.sha256(of: url)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func downmixAveragesChannels() {
        let left: [Float] = [1, 0.5, -1]
        let right: [Float] = [0, 0.5, 1]
        let mono = left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in AudioConversion.downmix([l, r], frames: 3) }
        }
        #expect(mono == [0.5, 0.5, 0])

        let single = left.withUnsafeBufferPointer { AudioConversion.downmix([$0], frames: 2) }
        #expect(single == [1, 0.5])
        #expect(AudioConversion.downmix([], frames: 3).isEmpty)
    }

    @Test func int16ClipsOutOfRangeSamples() {
        #expect(AudioConversion.int16([0, 1, -1, 2, -2, 0.5]) == [0, 32_767, -32_767, 32_767, -32_767, 16_384])
    }

    @Test func meterMapsMinusSixtyToZeroDecibels() {
        #expect(AudioConversion.meterLevel([]) == 0)
        #expect(AudioConversion.meterLevel([0, 0]) == 0)
        #expect(AudioConversion.meterLevel([1, -1]) == 1)
        #expect(abs(AudioConversion.meterLevel([0.001, -0.001]) - 0) < 0.0001)
        #expect(abs(AudioConversion.meterLevel([0.0316, -0.0316]) - 0.5) < 0.01)
    }

    @Test func outputSampleRateStaysInsideTheContractRange() {
        #expect(AudioConversion.outputSampleRate(forInput: 8_000) == 16_000)
        #expect(AudioConversion.outputSampleRate(forInput: 16_000) == 16_000)
        #expect(AudioConversion.outputSampleRate(forInput: 44_100) == 44_100)
        #expect(AudioConversion.outputSampleRate(forInput: 48_000) == 48_000)
        #expect(AudioConversion.outputSampleRate(forInput: 96_000) == 48_000)
    }
}
