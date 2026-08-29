import Foundation

/// One model-authored unit of work in a ``TaskPlan``.
///
/// IDs are stable strings rather than generated UUIDs so a planner can refer to
/// dependencies in the same JSON response (for example, `"synthesize"` can
/// depend on `"research"`).
public struct AgentJob: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var title: String
    public var instructions: String
    public var dependsOn: [String]

    public init(
        id: String,
        title: String,
        instructions: String,
        dependsOn: [String] = []
    ) {
        self.id = id
        self.title = title
        self.instructions = instructions
        self.dependsOn = dependsOn
    }
}

/// Shared safety limits applied at both planning and deployment boundaries.
public enum TaskPlanLimits {
    public static let maximumJobs = 8
    public static let maximumJobIDLength = 64
}

/// A large objective decomposed into a dependency graph of deployable jobs.
public struct TaskPlan: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let objective: String
    public let jobs: [AgentJob]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        objective: String,
        jobs: [AgentJob],
        createdAt: Date = .now
    ) {
        self.id = id
        self.objective = objective
        self.jobs = jobs
        self.createdAt = createdAt
    }

    /// Validate the graph and return this plan for convenient construction.
    @discardableResult
    public func validated(maximumJobs: Int = TaskPlanLimits.maximumJobs) throws -> TaskPlan {
        try TaskPlanValidator.validate(self, maximumJobs: maximumJobs)
        return self
    }
}

/// Structural problems that make a task plan unsafe to deploy.
public enum TaskPlanValidationError: Error, Sendable, Equatable {
    case emptyObjective
    case emptyPlan
    case tooManyJobs(maximum: Int, actual: Int)
    case emptyJobID(index: Int)
    case invalidJobID(String)
    case emptyJobTitle(jobID: String)
    case emptyJobInstructions(jobID: String)
    case duplicateJobID(String)
    case duplicateDependency(jobID: String, dependencyID: String)
    case missingDependency(jobID: String, dependencyID: String)
    case selfDependency(jobID: String)
    case cyclicDependencies(jobIDs: [String])
}

extension TaskPlanValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyObjective:
            return "A task plan needs a non-empty objective."
        case .emptyPlan:
            return "A task plan needs at least one job."
        case .tooManyJobs(let maximum, let actual):
            return "A task plan contains \(actual) jobs; a deployment allows at most \(maximum)."
        case .emptyJobID(let index):
            return "Job at index \(index) has an empty id."
        case .invalidJobID(let jobID):
            return "Job id '\(jobID)' must be a 1–\(TaskPlanLimits.maximumJobIDLength) character ASCII slug."
        case .emptyJobTitle(let jobID):
            return "Job '\(jobID)' has an empty title."
        case .emptyJobInstructions(let jobID):
            return "Job '\(jobID)' has empty instructions."
        case .duplicateJobID(let jobID):
            return "Job id '\(jobID)' appears more than once."
        case .duplicateDependency(let jobID, let dependencyID):
            return "Job '\(jobID)' lists dependency '\(dependencyID)' more than once."
        case .missingDependency(let jobID, let dependencyID):
            return "Job '\(jobID)' depends on unknown job '\(dependencyID)'."
        case .selfDependency(let jobID):
            return "Job '\(jobID)' cannot depend on itself."
        case .cyclicDependencies(let jobIDs):
            return "Task plan contains a dependency cycle involving: \(jobIDs.joined(separator: ", "))."
        }
    }
}

/// Validates the planner's output before workers can claim any jobs.
public enum TaskPlanValidator {

    public static func validate(
        _ plan: TaskPlan,
        maximumJobs: Int = TaskPlanLimits.maximumJobs
    ) throws {
        guard !plan.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskPlanValidationError.emptyObjective
        }
        guard !plan.jobs.isEmpty else {
            throw TaskPlanValidationError.emptyPlan
        }
        let maximumJobs = max(1, maximumJobs)
        guard plan.jobs.count <= maximumJobs else {
            throw TaskPlanValidationError.tooManyJobs(
                maximum: maximumJobs, actual: plan.jobs.count)
        }

        var knownIDs: Set<String> = []
        for (index, job) in plan.jobs.enumerated() {
            guard !job.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TaskPlanValidationError.emptyJobID(index: index)
            }
            guard isValidJobID(job.id) else {
                throw TaskPlanValidationError.invalidJobID(job.id)
            }
            guard !job.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TaskPlanValidationError.emptyJobTitle(jobID: job.id)
            }
            guard !job.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TaskPlanValidationError.emptyJobInstructions(jobID: job.id)
            }
            guard knownIDs.insert(job.id).inserted else {
                throw TaskPlanValidationError.duplicateJobID(job.id)
            }
        }

        for job in plan.jobs {
            var dependencies: Set<String> = []
            for dependencyID in job.dependsOn {
                guard dependencyID != job.id else {
                    throw TaskPlanValidationError.selfDependency(jobID: job.id)
                }
                guard dependencies.insert(dependencyID).inserted else {
                    throw TaskPlanValidationError.duplicateDependency(
                        jobID: job.id, dependencyID: dependencyID)
                }
                guard knownIDs.contains(dependencyID) else {
                    throw TaskPlanValidationError.missingDependency(
                        jobID: job.id, dependencyID: dependencyID)
                }
            }
        }

        // Kahn's algorithm. Keeping queues in plan order makes validation errors
        // deterministic and preserves the planner's preferred deployment order.
        var indegree = Dictionary(uniqueKeysWithValues: plan.jobs.map { ($0.id, $0.dependsOn.count) })
        var successors: [String: [String]] = [:]
        for job in plan.jobs {
            for dependencyID in job.dependsOn {
                successors[dependencyID, default: []].append(job.id)
            }
        }

        var queue = plan.jobs.filter { indegree[$0.id] == 0 }.map(\.id)
        var visited = 0
        var cursor = 0
        while cursor < queue.count {
            let jobID = queue[cursor]
            cursor += 1
            visited += 1
            for successorID in successors[jobID, default: []] {
                indegree[successorID, default: 0] -= 1
                if indegree[successorID] == 0 {
                    queue.append(successorID)
                }
            }
        }

        guard visited == plan.jobs.count else {
            let jobsByID = Dictionary(uniqueKeysWithValues: plan.jobs.map { ($0.id, $0) })
            let cyclic = plan.jobs.compactMap { job in
                participatesInCycle(job.id, jobsByID: jobsByID) ? job.id : nil
            }
            throw TaskPlanValidationError.cyclicDependencies(jobIDs: cyclic)
        }
    }

    /// Whether following dependency edges from `start` can return to `start`.
    /// Kahn's unresolved set also contains jobs downstream of a cycle; this walk
    /// keeps the reported error limited to jobs that actually form the cycle.
    private static func participatesInCycle(
        _ start: String,
        jobsByID: [String: AgentJob]
    ) -> Bool {
        var stack = jobsByID[start]?.dependsOn ?? []
        var seen: Set<String> = []
        while let current = stack.popLast() {
            if current == start { return true }
            guard seen.insert(current).inserted else { continue }
            stack.append(contentsOf: jobsByID[current]?.dependsOn ?? [])
        }
        return false
    }

    /// Planner IDs cross JSON, worker APIs, persistence, and diagnostics. Keep
    /// them canonical instead of silently trimming or normalizing references.
    private static func isValidJobID(_ id: String) -> Bool {
        let scalars = id.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= TaskPlanLimits.maximumJobIDLength else {
            return false
        }
        let lettersAndNumbers = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard let first = scalars.first, lettersAndNumbers.contains(first) else {
            return false
        }
        return scalars.allSatisfy(allowed.contains)
    }
}
