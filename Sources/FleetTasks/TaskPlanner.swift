import Foundation

/// The JSON payload Fleet asks a planning model to produce.
public struct TaskPlanDraft: Codable, Sendable, Equatable {
    public var jobs: [AgentJob]

    public init(jobs: [AgentJob]) {
        self.jobs = jobs
    }
}

/// Converts one user objective into a validated job graph.
public protocol TaskPlanning: Sendable {
    func makePlan(for objective: String) async throws -> TaskPlan
}

/// Errors at the structured-output boundary between the planning model and Fleet.
public enum TaskPlanningError: Error, Sendable, Equatable {
    case invalidResponse(String)
}

extension TaskPlanningError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let reason):
            return "The planning model did not return a valid task plan: \(reason)"
        }
    }
}

/// The small, model-neutral planning contract used by the first iteration.
public enum TaskPlanningPrompt {
    public static let defaultMaximumJobs = TaskPlanLimits.maximumJobs

    public static func make(for objective: String, maximumJobs: Int = defaultMaximumJobs) -> String {
        """
        You are Fleet's task planner. Decompose the objective into the smallest useful directed acyclic graph of jobs.

        Return JSON only, with exactly this shape:
        {"jobs":[{"id":"stable-short-id","title":"Short title","instructions":"Self-contained work instructions","dependsOn":["earlier-job-id"]}]}

        Rules:
        - Return between 1 and \(max(1, maximumJobs)) jobs.
        - Use stable, unique ids matching [A-Za-z0-9][A-Za-z0-9._-]{0,63}.
        - Each job must have one concrete deliverable and enough instructions for a worker to act without re-planning the whole objective.
        - Add a dependency only when the job needs that earlier job's output.
        - Independent jobs should not depend on each other.
        - Dependencies must reference ids in this response and must not form cycles.
        - Include an integration job when several outputs must become one final result.
        - Do not use Markdown fences or add commentary outside the JSON.

        Objective:
        \(objective)
        """
    }
}

/// Decodes and validates the structured response from a planning model.
public struct TaskPlanDecoder: Sendable {
    public let maximumJobs: Int

    public init(maximumJobs: Int = TaskPlanningPrompt.defaultMaximumJobs) {
        self.maximumJobs = max(1, maximumJobs)
    }

    public func decode(_ response: String, objective: String) throws -> TaskPlan {
        guard !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskPlanValidationError.emptyObjective
        }
        let payload = unwrapJSONFence(response)
        let draft: TaskPlanDraft
        do {
            draft = try JSONDecoder().decode(TaskPlanDraft.self, from: Data(payload.utf8))
        } catch {
            throw TaskPlanningError.invalidResponse(error.localizedDescription)
        }

        let plan = TaskPlan(objective: objective, jobs: draft.jobs)
        try TaskPlanValidator.validate(plan, maximumJobs: maximumJobs)
        return plan
    }

    /// Models occasionally wrap otherwise valid JSON in a single Markdown fence.
    /// Accept that harmless variation while rejecting arbitrary prose.
    private func unwrapJSONFence(_ response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines)
        let opening = lines.first?.trimmingCharacters(in: .whitespaces)
        guard
            lines.count >= 3,
            opening == "```" || opening == "```json",
            lines.last?.trimmingCharacters(in: .whitespaces) == "```"
        else {
            return trimmed
        }
        return lines.dropFirst().dropLast().joined(separator: "\n")
    }
}

/// Planner adapter that keeps model inference outside `FleetTasks`.
///
/// The injected generator can be backed by Frigate today and by Bonnie's chosen
/// model later; this module owns only the prompt, JSON contract, and validation.
public struct JSONTaskPlanner: TaskPlanning {
    private let decoder: TaskPlanDecoder
    private let generate: @Sendable (String) async throws -> String

    public init(
        maximumJobs: Int = TaskPlanningPrompt.defaultMaximumJobs,
        generate: @escaping @Sendable (String) async throws -> String
    ) {
        self.decoder = TaskPlanDecoder(maximumJobs: maximumJobs)
        self.generate = generate
    }

    public func makePlan(for objective: String) async throws -> TaskPlan {
        guard !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskPlanValidationError.emptyObjective
        }
        let prompt = TaskPlanningPrompt.make(for: objective, maximumJobs: decoder.maximumJobs)
        let response = try await generate(prompt)
        return try decoder.decode(response, objective: objective)
    }
}

/// One-call facade for the first Fleet flow: objective → plan → deployment.
public struct TaskDeployer: Sendable {
    private let planner: any TaskPlanning
    private let maximumJobs: Int

    public init(
        planner: any TaskPlanning,
        maximumJobs: Int = TaskPlanLimits.maximumJobs
    ) {
        self.planner = planner
        self.maximumJobs = max(1, maximumJobs)
    }

    public func deploy(_ objective: String) async throws -> TaskDeployment {
        let plan = try await planner.makePlan(for: objective)
        return try TaskDeployment(plan: plan, maximumJobs: maximumJobs)
    }
}
