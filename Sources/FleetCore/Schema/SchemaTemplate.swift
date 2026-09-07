import Foundation

/// The shape of a JSON document with all values erased — the "semantic key
/// template" a LoRA is gated against.
public indirect enum SchemaNode: Sendable, Equatable, Codable {
    /// Object entries, always stored in canonical (UTF-8 byte sorted) key order.
    case object([Entry])
    /// A homogeneous array. The counts are the range observed across the training
    /// outputs; they are informational (the gate lets the model choose a length).
    case array(element: SchemaNode, minCount: Int, maxCount: Int)
    case string
    case number
    case bool
    case null

    public struct Entry: Sendable, Equatable, Codable {
        public var key: String
        public var node: SchemaNode

        public init(key: String, node: SchemaNode) {
            self.key = key
            self.node = node
        }
    }

    /// The name used in validation messages.
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
}

/// An extracted schema plus its stable identity.
public struct SchemaTemplate: Sendable, Equatable, Codable {
    public let root: SchemaNode
    /// SHA256 (hex) of the schema's canonical description — two datasets with the
    /// same key template share this, which is how the library groups LoRAs that
    /// are interchangeable at the call site.
    public let hashHex: String

    public init(root: SchemaNode) {
        self.root = root
        self.hashHex = ContentID.hashHex(of: Data(SchemaTemplate.describe(root).utf8))
    }

    /// A stable, human-readable rendering of the shape, e.g.
    /// `{"avg":number,"tags":[string]}`. Also the pre-image of ``hashHex``.
    public static func describe(_ node: SchemaNode) -> String {
        switch node {
        case .object(let entries):
            let body = entries
                .map { "\(JSONCanonical.quoted($0.key)):\(describe($0.node))" }
                .joined(separator: ",")
            return "{\(body)}"
        case .array(let element, _, _):
            return "[\(describe(element))]"
        case .string: return "string"
        case .number: return "number"
        case .bool: return "boolean"
        case .null: return "null"
        }
    }

    public var description: String { SchemaTemplate.describe(root) }
}
