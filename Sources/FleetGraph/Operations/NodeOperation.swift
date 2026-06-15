import FleetCore
import Foundation

/// The conditioning "trait" assigned to a LoRA node — how it treats its input.
///
/// Persisted discriminator for the ``NodeOperation`` class chosen on a node.
public enum OperationKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case answer
    case augment
    case critique
    case clarify
    case sanitize
    case distill
    case custom

    public var id: String { rawValue }
}

/// Base class for an operation a LoRA node performs on its stage input.
///
/// Each concrete operation is its own class (the user's "choose it like a class"
/// model), so new behaviors (e.g. translate, route) are added by subclassing.
/// `messages(for:history:)` wraps the stage input in the operation's instruction
/// before the node's adapter generates.
open class NodeOperation: @unchecked Sendable {

    open class var kind: OperationKind { .answer }
    open class var displayName: String { "Answer" }
    open class var summary: String { "Answer the input directly (conversational)." }

    public var kind: OperationKind { Self.kind }
    public var displayName: String { Self.displayName }
    public var summary: String { Self.summary }

    public init() {}

    /// Build the conversation handed to the stage's model. Transform operations
    /// instruct on the input only; ``AnswerOperation`` threads the chat history.
    open func messages(for input: String, history: [ChatTurn]) -> [ChatTurn] {
        history + [ChatTurn(role: .user, text: input)]
    }

    /// Convenience for instruction-style operations.
    fileprivate func instruction(_ text: String, _ input: String) -> [ChatTurn] {
        [ChatTurn(role: .user, text: "\(text)\n\n\(input)")]
    }

    // MARK: - Registry

    public static let allKinds = OperationKind.allCases

    public static func make(_ kind: OperationKind, custom: String? = nil) -> NodeOperation {
        switch kind {
        case .answer: return AnswerOperation()
        case .augment: return AugmentOperation()
        case .critique: return CritiqueOperation()
        case .clarify: return ClarifyOperation()
        case .sanitize: return SanitizeOperation()
        case .distill: return DistillOperation()
        case .custom: return CustomOperation(template: custom ?? "{input}")
        }
    }

    public static func displayName(_ kind: OperationKind) -> String {
        make(kind).displayName
    }
}

public final class AnswerOperation: NodeOperation {
    public override class var kind: OperationKind { .answer }
    public override class var displayName: String { "Answer" }
    public override class var summary: String { "Answer the input directly (conversational)." }
}

public final class AugmentOperation: NodeOperation {
    public override class var kind: OperationKind { .augment }
    public override class var displayName: String { "Augment" }
    public override class var summary: String { "Expand and enrich, adding helpful detail." }
    public override func messages(for input: String, history: [ChatTurn]) -> [ChatTurn] {
        instruction(
            "Expand and enrich the following, adding helpful detail. Return only the improved text.",
            input)
    }
}

public final class CritiqueOperation: NodeOperation {
    public override class var kind: OperationKind { .critique }
    public override class var displayName: String { "Critique" }
    public override class var summary: String { "Evaluate the input and identify weaknesses." }
    public override func messages(for input: String, history: [ChatTurn]) -> [ChatTurn] {
        instruction(
            "Critique the following. Identify its weaknesses and how to improve it.", input)
    }
}

public final class ClarifyOperation: NodeOperation {
    public override class var kind: OperationKind { .clarify }
    public override class var displayName: String { "Clarify" }
    public override class var summary: String { "Rewrite to be clearer and more precise." }
    public override func messages(for input: String, history: [ChatTurn]) -> [ChatTurn] {
        instruction(
            "Rewrite the following to be clearer and more precise, preserving its meaning. Return only the rewritten text.",
            input)
    }
}

public final class SanitizeOperation: NodeOperation {
    public override class var kind: OperationKind { .sanitize }
    public override class var displayName: String { "Sanitize" }
    public override class var summary: String { "Remove unsafe or sensitive content." }
    public override func messages(for input: String, history: [ChatTurn]) -> [ChatTurn] {
        instruction(
            "Remove any unsafe, sensitive, or policy-violating content from the following, keeping everything else intact. Return only the cleaned text.",
            input)
    }
}

public final class DistillOperation: NodeOperation {
    public override class var kind: OperationKind { .distill }
    public override class var displayName: String { "Distill" }
    public override class var summary: String { "Summarize to the essential points." }
    public override func messages(for input: String, history: [ChatTurn]) -> [ChatTurn] {
        instruction("Summarize the essential points of the following concisely.", input)
    }
}

public final class CustomOperation: NodeOperation {
    public override class var kind: OperationKind { .custom }
    public override class var displayName: String { "Custom" }
    public override class var summary: String { "Your own instruction; use {input} as a placeholder." }

    public let template: String
    public init(template: String) {
        self.template = template
    }

    public override func messages(for input: String, history: [ChatTurn]) -> [ChatTurn] {
        let text =
            template.contains("{input}")
            ? template.replacingOccurrences(of: "{input}", with: input)
            : "\(template)\n\n\(input)"
        return [ChatTurn(role: .user, text: text)]
    }
}
