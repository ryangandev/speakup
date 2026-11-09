import Foundation

/// Writes the `multipart/form-data` body of a take upload to a file, so a long take is
/// streamed from disk instead of held in memory.
enum MultipartTakeBody {
    static func contentType(boundary: String) -> String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// Writes the `metadata` JSON part and the `audio` WAV part to `destination`.
    static func write(
        metadata: Data, audioFile: URL, boundary: String, to destination: URL
    ) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        guard manager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var head = Data()
        head.append("--\(boundary)\r\n")
        head.append("Content-Disposition: form-data; name=\"metadata\"\r\n")
        head.append("Content-Type: application/json\r\n\r\n")
        head.append(metadata)
        head.append("\r\n--\(boundary)\r\n")
        head.append("Content-Disposition: form-data; name=\"audio\"; filename=\"take.wav\"\r\n")
        head.append("Content-Type: audio/wav\r\n\r\n")
        try output.write(contentsOf: head)

        let input = try FileHandle(forReadingFrom: audioFile)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }

        var tail = Data()
        tail.append("\r\n--\(boundary)--\r\n")
        try output.write(contentsOf: tail)
    }
}

extension Data {
    fileprivate mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
