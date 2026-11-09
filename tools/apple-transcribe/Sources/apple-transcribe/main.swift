// Transcribes an audio file with Apple's on-device SpeechTranscriber and prints JSON:
// {"text": "...", "runs": [{"text": "...", "start": 0.0, "end": 0.4, "confidence": 0.9}]}
//
// Usage: apple-transcribe <audio-file> [locale]

import AVFoundation
import Foundation
import Speech

struct Run: Encodable {
    let text: String
    let start: Double
    let end: Double
    let confidence: Double?
}

struct Output: Encodable {
    let text: String
    let runs: [Run]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { fail("usage: apple-transcribe <audio-file> [locale]") }
let audioURL = URL(fileURLWithPath: arguments[1])
let requestedLocale = Locale(identifier: arguments.count > 2 ? arguments[2] : "en-US")

guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
    fail("SpeechTranscriber does not support \(requestedLocale.identifier)")
}

let transcriber = SpeechTranscriber(
    locale: locale,
    transcriptionOptions: [],
    reportingOptions: [],
    attributeOptions: [.audioTimeRange, .transcriptionConfidence]
)

do {
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await request.downloadAndInstall()
    }

    let collector = Task {
        var text = ""
        var runs: [Run] = []
        for try await result in transcriber.results {
            text += String(result.text.characters)
            for run in result.text.runs {
                guard let range = run.audioTimeRange else { continue }
                let piece = String(result.text[run.range].characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !piece.isEmpty else { continue }
                runs.append(Run(
                    text: piece,
                    start: range.start.seconds,
                    end: range.end.seconds,
                    confidence: run.transcriptionConfidence
                ))
            }
        }
        return Output(text: text.trimmingCharacters(in: .whitespacesAndNewlines), runs: runs)
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let file = try AVAudioFile(forReading: audioURL)
    if let lastSample = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: lastSample)
    } else {
        await analyzer.cancelAndFinishNow()
    }

    let output = try await collector.value
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(output))
} catch {
    fail("transcription failed: \(error)")
}
