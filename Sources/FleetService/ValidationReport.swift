import FleetCore
import Foundation

/// Everything the app's dataset debugger needs to explain a training set.
public struct ValidationReport: Sendable {

    public struct FileProblem: Sendable, Identifiable {
        public var index: Int
        public var role: Role
        public var fileName: String
        public var message: String

        public enum Role: String, Sendable {
            case input
            case output
        }

        public var id: String { "\(role.rawValue)-\(index)" }
    }

    /// The extracted schema, when one could be derived.
    public var schema: SchemaTemplate?
    public var pairCount: Int
    /// Structural disagreements between outputs, addressed by index and path.
    public var schemaErrors: [SchemaValidationError]
    /// Files that could not be read or parsed.
    public var fileProblems: [FileProblem]
    /// Non-fatal notes, e.g. examples long enough to be truncated in training.
    public var warnings: [String]
    /// The CID a LoRA trained from this dataset would occupy.
    public var inputCID: String?
    /// Set when that CID already holds a LoRA, so the UI can warn about overwrite.
    public var existingGeneration: Int?

    public init(
        schema: SchemaTemplate? = nil,
        pairCount: Int = 0,
        schemaErrors: [SchemaValidationError] = [],
        fileProblems: [FileProblem] = [],
        warnings: [String] = [],
        inputCID: String? = nil,
        existingGeneration: Int? = nil
    ) {
        self.schema = schema
        self.pairCount = pairCount
        self.schemaErrors = schemaErrors
        self.fileProblems = fileProblems
        self.warnings = warnings
        self.inputCID = inputCID
        self.existingGeneration = existingGeneration
    }

    public var isTrainable: Bool {
        schema != nil && schemaErrors.isEmpty && fileProblems.isEmpty && pairCount > 0
    }

    public var summary: String {
        if let schema, isTrainable {
            return "\(pairCount) pairs · schema \(schema.description)"
        }
        let problems = schemaErrors.count + fileProblems.count
        return "\(problems) problem\(problems == 1 ? "" : "s") to fix"
    }
}

public enum FleetServiceError: Error, Sendable, CustomStringConvertible {
    case datasetNotFound(UUID)
    case loraNotFound(String)
    case schemaUnavailable(String)
    case countMismatch(inputs: Int, outputs: Int)
    case validationFailed(ValidationReport)
    case noPairs

    public var description: String {
        switch self {
        case .datasetNotFound(let id):
            return "No dataset with id \(id)."
        case .loraNotFound(let cid):
            return "No LoRA stored at \(ContentID.short(cid))."
        case .schemaUnavailable(let cid):
            return "The LoRA at \(ContentID.short(cid)) has no schema.json beside its weights."
        case .countMismatch(let inputs, let outputs):
            return "Inputs and outputs must pair up by index: got \(inputs) input file(s) "
                + "and \(outputs) output file(s)."
        case .validationFailed(let report):
            let details = report.schemaErrors.prefix(3).map(\.description).joined(separator: "; ")
            return "The dataset did not validate: \(details.isEmpty ? report.summary : details)"
        case .noPairs:
            return "A dataset needs at least one input/output pair."
        }
    }
}
