import Foundation

/// A parsed JSON document.
///
/// Fleet models JSON itself rather than leaning on `JSONSerialization` because the
/// gate needs three things `Any`-based parsing throws away: the source order of
/// object keys (so validation errors can point at the offending key), the exact
/// number lexeme (so `1.50` and `1.5` can be told apart before canonicalization),
/// and a value tree that is `Equatable` and `Sendable` end to end.
public indirect enum JSONValue: Sendable, Equatable {
    case object([Member])
    case array([JSONValue])
    case string(String)
    /// The raw lexeme exactly as it appeared in the source; normalized by
    /// ``JSONCanonical``.
    case number(String)
    case bool(Bool)
    case null

    /// One `"key": value` entry, keeping source order.
    public struct Member: Sendable, Equatable {
        public var key: String
        public var value: JSONValue

        public init(key: String, value: JSONValue) {
            self.key = key
            self.value = value
        }
    }
}

extension JSONValue {

    /// The JSON type name, for validation messages.
    public var typeName: String {
        switch self {
        case .object: return "object"
        case .array: return "array"
        case .string: return "string"
        case .number: return "number"
        case .bool: return "boolean"
        case .null: return "null"
        }
    }

    public var members: [Member]? {
        if case .object(let m) = self { return m }
        return nil
    }

    public var elements: [JSONValue]? {
        if case .array(let e) = self { return e }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let lexeme) = self { return Double(lexeme) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        members?.first { $0.key == key }?.value
    }

    // MARK: - Convenience constructors

    public static func object(_ pairs: [(String, JSONValue)]) -> JSONValue {
        .object(pairs.map { Member(key: $0.0, value: $0.1) })
    }

    public static func number(_ value: Int) -> JSONValue {
        .number(String(value))
    }

    public static func number(_ value: Double) -> JSONValue {
        .number(JSONCanonical.numberLexeme(value))
    }
}

// MARK: - Codable

/// Encodes/decodes through the canonical text form so a `JSONValue` nested in a
/// `Codable` model (a dataset pair, an adapter snapshot) round-trips exactly.
extension JSONValue: Codable {

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        do {
            self = try JSONParser.parse(text)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "not valid JSON: \(error)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(JSONCanonical.serialize(self))
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String { JSONCanonical.serialize(self) }
}
