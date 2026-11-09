import Foundation

/// A string enum from the server contract that keeps values it does not know.
///
/// The contract adds enum values without a version change and asks readers to show an
/// unknown value in the most neutral way (architecture.md#conventions). A Swift `enum`
/// would fail to decode the whole document instead, so each contract enum is a struct
/// with static constants: `switch` still matches the known cases, and anything else
/// falls through to `default`.
///
/// Decoding and encoding come from the standard library's `RawRepresentable` defaults,
/// which never fail here because `init(rawValue:)` accepts every string.
protocol OpenEnum: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible
where RawValue == String {
    init(rawValue: String)
}

extension OpenEnum {
    var description: String { rawValue }

    /// A readable fallback for unknown values: "needs_work" becomes "Needs work".
    var fallbackLabel: String {
        let spaced = rawValue.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

/// A free-form JSON value, used for the error `details` field, whose shape depends on the code.
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
