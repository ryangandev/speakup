import Foundation

/// JSON coders that follow the contract's conventions (architecture.md#conventions):
/// snake_case keys and RFC 3339 UTC timestamps with milliseconds.
enum JSONCoding {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle()

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Not an RFC 3339 timestamp: \(text)")
            }
            return date
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatDate(date))
        }
        return encoder
    }

    /// The server writes milliseconds and accepts input with or without them; so does the app.
    static func parseDate(_ text: String) -> Date? {
        (try? withFraction.parse(text)) ?? (try? withoutFraction.parse(text))
    }

    /// Rounds to the nearest millisecond. `ISO8601FormatStyle` truncates instead, so a time
    /// parsed from "…50.020Z" (stored as …50.01999…) would go back out as "…50.019Z".
    static func formatDate(_ date: Date) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        let seconds = (milliseconds / 1000).rounded(.down)
        let fraction = Int(milliseconds - seconds * 1000)
        let whole = Date(timeIntervalSince1970: seconds).formatted(withoutFraction)
        return "\(whole.dropLast()).\(String(format: "%03d", fraction))Z"
    }
}

enum IDs {
    /// Ids are lowercase version 4 UUIDs; `UUID().uuidString` is uppercase.
    static func make() -> String { UUID().uuidString.lowercased() }
}
