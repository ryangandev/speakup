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

    static func formatDate(_ date: Date) -> String {
        date.formatted(withFraction)
    }
}

enum IDs {
    /// Ids are lowercase version 4 UUIDs; `UUID().uuidString` is uppercase.
    static func make() -> String { UUID().uuidString.lowercased() }
}
