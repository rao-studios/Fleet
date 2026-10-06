import Foundation

/// A structural disagreement between two training outputs, addressed precisely
/// enough for the app to highlight the offending value.
public struct SchemaValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Index of the output JSON that disagreed with the reference.
    public let outputIndex: Int
    /// Index of the output that established the expectation (usually 0).
    public let referenceIndex: Int
    /// JSONPath-ish location, e.g. `$.warnings[2].code`.
    public let path: String
    public let expected: String
    public let found: String

    public init(
        outputIndex: Int,
        referenceIndex: Int,
        path: String,
        expected: String,
        found: String
    ) {
        self.outputIndex = outputIndex
        self.referenceIndex = referenceIndex
        self.path = path
        self.expected = expected
        self.found = found
    }

    public var description: String {
        "output[\(outputIndex)] \(path): expected \(expected) "
            + "(from output \(referenceIndex)), found \(found)"
    }
}

/// Errors that stop a schema being extracted at all.
public enum SchemaExtractionError: Error, Sendable, Equatable, CustomStringConvertible {
    case noOutputs
    case rootNotObject(outputIndex: Int, found: String)
    case duplicateKey(outputIndex: Int, path: String, key: String)
    case mismatches([SchemaValidationError])

    public var description: String {
        switch self {
        case .noOutputs:
            return "The dataset has no output documents to extract a schema from."
        case .rootNotObject(let index, let found):
            return "output[\(index)]: the top level must be a JSON object, found \(found)."
        case .duplicateKey(let index, let path, let key):
            return "output[\(index)] \(path): duplicate key \"\(key)\"."
        case .mismatches(let errors):
            let head = errors.prefix(5).map(\.description).joined(separator: "\n")
            let rest = errors.count > 5 ? "\n…and \(errors.count - 5) more." : ""
            return head + rest
        }
    }
}

/// Derives the semantic key template from a dataset's output documents.
///
/// Fleet is strict on purpose: every output must have the identical key structure
/// and value types. A LoRA gated on a union-with-optionals schema would need the
/// decoder to guess which keys are present this time, which defeats the point of
/// a fixed state machine. Array *lengths* are the one thing allowed to vary.
public enum SchemaExtractor {

    /// The shape of a single document, with keys sorted canonically.
    public static func node(of value: JSONValue) -> SchemaNode {
        switch value {
        case .object(let members):
            let sorted = members.sorted { lhs, rhs in
                Array(lhs.key.utf8).lexicographicallyPrecedes(Array(rhs.key.utf8))
            }
            return .object(sorted.map { .init(key: $0.key, node: node(of: $0.value)) })
        case .array(let elements):
            // An empty array gives us no element type; `.null` is the placeholder
            // and is reconciled against a later output that has elements.
            let element = elements.first.map { node(of: $0) } ?? .null
            return .array(element: element, minCount: elements.count, maxCount: elements.count)
        case .string: return .string
        case .number: return .number
        case .bool: return .bool
        case .null: return .null
        }
    }

    /// Extract one template from all outputs, or throw with every disagreement.
    public static func template(outputs: [JSONValue]) throws -> SchemaTemplate {
        guard let first = outputs.first else { throw SchemaExtractionError.noOutputs }
        guard case .object = first else {
            throw SchemaExtractionError.rootNotObject(outputIndex: 0, found: first.typeName)
        }
        for (index, output) in outputs.enumerated() {
            guard case .object = output else {
                throw SchemaExtractionError.rootNotObject(
                    outputIndex: index, found: output.typeName)
            }
            try assertNoDuplicateKeys(output, outputIndex: index, path: "$")
        }

        var reference = node(of: first)
        var errors: [SchemaValidationError] = []
        for index in outputs.indices.dropFirst() {
            let candidate = node(of: outputs[index])
            reference = reconcile(
                reference,
                candidate,
                outputIndex: index,
                path: "$",
                errors: &errors
            )
        }
        guard errors.isEmpty else { throw SchemaExtractionError.mismatches(errors) }
        return SchemaTemplate(root: reference)
    }

    /// Check one document against an already-extracted template (used when adding
    /// pairs to an existing dataset, and by the CLI's `validate`).
    public static func validate(
        _ value: JSONValue,
        against template: SchemaTemplate,
        outputIndex: Int = 0
    ) -> [SchemaValidationError] {
        var errors: [SchemaValidationError] = []
        _ = reconcile(
            template.root,
            node(of: value),
            outputIndex: outputIndex,
            path: "$",
            errors: &errors
        )
        return errors
    }

    // MARK: - Internals

    /// Merge `candidate` into `reference`, recording every structural difference.
    ///
    /// Only two things merge silently: array count bounds widen, and a `.null`
    /// placeholder from an empty array is replaced by a concrete element type.
    private static func reconcile(
        _ reference: SchemaNode,
        _ candidate: SchemaNode,
        outputIndex: Int,
        path: String,
        errors: inout [SchemaValidationError]
    ) -> SchemaNode {
        switch (reference, candidate) {
        case (.object(let referenceEntries), .object(let candidateEntries)):
            let referenceKeys = referenceEntries.map(\.key)
            let candidateKeys = Set(candidateEntries.map(\.key))
            let candidateByKey = Dictionary(
                candidateEntries.map { ($0.key, $0.node) },
                uniquingKeysWith: { first, _ in first }
            )

            for key in referenceKeys where !candidateKeys.contains(key) {
                errors.append(
                    .init(
                        outputIndex: outputIndex,
                        referenceIndex: 0,
                        path: "\(path).\(key)",
                        expected: "key \"\(key)\" to be present",
                        found: "the key is missing"
                    ))
            }
            for key in candidateEntries.map(\.key) where !referenceKeys.contains(key) {
                errors.append(
                    .init(
                        outputIndex: outputIndex,
                        referenceIndex: 0,
                        path: "\(path).\(key)",
                        expected: "no key \"\(key)\"",
                        found: "an extra key"
                    ))
            }

            var merged: [SchemaNode.Entry] = []
            merged.reserveCapacity(referenceEntries.count)
            for entry in referenceEntries {
                guard let candidateNode = candidateByKey[entry.key] else {
                    merged.append(entry)
                    continue
                }
                let node = reconcile(
                    entry.node,
                    candidateNode,
                    outputIndex: outputIndex,
                    path: "\(path).\(entry.key)",
                    errors: &errors
                )
                merged.append(.init(key: entry.key, node: node))
            }
            return .object(merged)

        case (
            .array(let referenceElement, let referenceMin, let referenceMax),
            .array(let candidateElement, let candidateMin, let candidateMax)
        ):
            let element: SchemaNode
            if referenceElement == .null && candidateElement != .null {
                // The reference array was empty; adopt the first real element type.
                element = candidateElement
            } else if candidateElement == .null && candidateMax == 0 {
                // The candidate array is empty, which tells us nothing about type.
                element = referenceElement
            } else {
                element = reconcile(
                    referenceElement,
                    candidateElement,
                    outputIndex: outputIndex,
                    path: "\(path)[]",
                    errors: &errors
                )
            }
            return .array(
                element: element,
                minCount: min(referenceMin, candidateMin),
                maxCount: max(referenceMax, candidateMax)
            )

        default:
            if reference == candidate { return reference }
            errors.append(
                .init(
                    outputIndex: outputIndex,
                    referenceIndex: 0,
                    path: path,
                    expected: reference.typeName,
                    found: candidate.typeName
                ))
            return reference
        }
    }

    private static func assertNoDuplicateKeys(
        _ value: JSONValue,
        outputIndex: Int,
        path: String
    ) throws {
        switch value {
        case .object(let members):
            var seen = Set<String>()
            for member in members {
                guard seen.insert(member.key).inserted else {
                    throw SchemaExtractionError.duplicateKey(
                        outputIndex: outputIndex, path: path, key: member.key)
                }
                try assertNoDuplicateKeys(
                    member.value, outputIndex: outputIndex, path: "\(path).\(member.key)")
            }
        case .array(let elements):
            for (index, element) in elements.enumerated() {
                try assertNoDuplicateKeys(
                    element, outputIndex: outputIndex, path: "\(path)[\(index)]")
            }
        default:
            break
        }
    }
}
