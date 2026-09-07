import Foundation

/// Runtime state for one deployed job.
public enum JobStatus: String, Codable, Sendable, Equatable {
    case pending
    case running
    case succeeded
    case failed
    case blocked

    public var isTerminal: Bool {
        self == .succeeded || self == .failed || self == .blocked
    }
}

/// Observable runtime record for a job in a deployment.
public struct DeployedJob: Codable, Sendable, Equatable, Identifiable {
    public var id: String { job.id }
    public let job: AgentJob
    public fileprivate(set) var status: JobStatus
    public fileprivate(set) var workerID: String?
    public fileprivate(set) var assignmentID: UUID?
    public fileprivate(set) var attempt: Int
    public fileprivate(set) var output: String?
    public fileprivate(set) var failure: String?
    public fileprivate(set) var startedAt: Date?
    public fileprivate(set) var finishedAt: Date?

    fileprivate init(job: AgentJob) {
        self.job = job
        self.status = .pending
        self.workerID = nil
        self.assignmentID = nil
        self.attempt = 0
        self.output = nil
        self.failure = nil
        self.startedAt = nil
        self.finishedAt = nil
    }
}

/// A completed prerequisite supplied to the worker with its assignment.
public struct JobDependencyOutput: Codable, Sendable, Equatable {
    public let jobID: String
    public let output: String

    public init(jobID: String, output: String) {
        self.jobID = jobID
        self.output = output
    }
}

/// The self-contained envelope handed to a worker when it claims a ready job.
public struct JobAssignment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let deploymentID: UUID
    public let planID: UUID
    public let objective: String
    public let job: AgentJob
    public let dependencyOutputs: [JobDependencyOutput]
    public let attempt: Int
    public let workerID: String
    public let assignedAt: Date

    init(
        id: UUID = UUID(),
        deploymentID: UUID,
        planID: UUID,
        objective: String,
        job: AgentJob,
        dependencyOutputs: [JobDependencyOutput],
        attempt: Int,
        workerID: String,
        assignedAt: Date = .now
    ) {
        self.id = id
        self.deploymentID = deploymentID
        self.planID = planID
        self.objective = objective
        self.job = job
        self.dependencyOutputs = dependencyOutputs
        self.attempt = attempt
        self.workerID = workerID
        self.assignedAt = assignedAt
    }
}

public enum DeploymentStatus: String, Codable, Sendable, Equatable {
    case active
    case succeeded
    case failed
}

/// Immutable view of a deployment for a UI, store, or supervising agent.
public struct TaskDeploymentSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let planID: UUID
    public let status: DeploymentStatus
    public let jobs: [DeployedJob]
    public let readyJobIDs: [String]

    public init(
        id: UUID,
        planID: UUID,
        status: DeploymentStatus,
        jobs: [DeployedJob],
        readyJobIDs: [String]
    ) {
        self.id = id
        self.planID = planID
        self.status = status
        self.jobs = jobs
        self.readyJobIDs = readyJobIDs
    }
}

public enum TaskDeploymentError: Error, Sendable, Equatable {
    case emptyWorkerID
    case unknownJob(String)
    case foreignAssignment(expectedDeploymentID: UUID, actualDeploymentID: UUID)
    case assignmentMismatch(jobID: String)
    case invalidTransition(jobID: String, status: JobStatus)
    case workerMismatch(jobID: String, claimedBy: String, attemptedBy: String)
}

extension TaskDeploymentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyWorkerID:
            return "A worker needs a non-empty id before claiming jobs."
        case .unknownJob(let jobID):
            return "Deployment does not contain job '\(jobID)'."
        case .foreignAssignment(let expected, let actual):
            return "Assignment belongs to deployment '\(actual)', not '\(expected)'."
        case .assignmentMismatch(let jobID):
            return "Assignment is not the active claim for job '\(jobID)'."
        case .invalidTransition(let jobID, let status):
            return "Job '\(jobID)' cannot be completed or failed while it is \(status.rawValue)."
        case .workerMismatch(let jobID, let claimedBy, let attemptedBy):
            return "Job '\(jobID)' was claimed by '\(claimedBy)', not '\(attemptedBy)'."
        }
    }
}

/// Dependency-aware, concurrency-safe deployment state for one task plan.
///
/// Workers pull assignments with ``claimReadyJobs(limit:workerID:)``. Claiming is
/// atomic because this type is an actor: two workers cannot receive the same job.
/// A success unlocks dependents; a failure blocks every transitive dependent.
public actor TaskDeployment {
    public nonisolated let id: UUID
    public nonisolated let plan: TaskPlan

    private var records: [String: DeployedJob]

    public init(
        id: UUID = UUID(),
        plan: TaskPlan,
        maximumJobs: Int = TaskPlanLimits.maximumJobs
    ) throws {
        try TaskPlanValidator.validate(plan, maximumJobs: maximumJobs)
        self.id = id
        self.plan = plan
        self.records = Dictionary(uniqueKeysWithValues: plan.jobs.map { ($0.id, DeployedJob(job: $0)) })
    }

    /// Atomically claim up to `limit` jobs whose prerequisites have succeeded.
    /// Jobs are returned in the planner's original order.
    public func claimReadyJobs(limit: Int = 1, workerID: String) throws -> [JobAssignment] {
        guard !workerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskDeploymentError.emptyWorkerID
        }
        guard limit > 0 else { return [] }
        refreshBlockedJobs()

        let ready = readyJobIDs().prefix(limit)
        let now = Date.now
        return ready.compactMap { jobID in
            guard var record = records[jobID] else { return nil }
            let assignmentID = UUID()
            record.status = .running
            record.workerID = workerID
            record.assignmentID = assignmentID
            record.attempt += 1
            record.startedAt = now
            records[jobID] = record

            let dependencyOutputs = record.job.dependsOn.compactMap { dependencyID -> JobDependencyOutput? in
                guard let output = records[dependencyID]?.output else { return nil }
                return JobDependencyOutput(jobID: dependencyID, output: output)
            }
            return JobAssignment(
                id: assignmentID,
                deploymentID: id,
                planID: plan.id,
                objective: plan.objective,
                job: record.job,
                dependencyOutputs: dependencyOutputs,
                attempt: record.attempt,
                workerID: workerID,
                assignedAt: now)
        }
    }

    /// Record a worker result and make newly satisfied dependents claimable.
    public func complete(_ assignment: JobAssignment, output: String) throws {
        var record = try activeRecord(for: assignment)
        record.status = .succeeded
        record.output = output
        record.failure = nil
        record.finishedAt = .now
        records[assignment.job.id] = record
    }

    /// Record a terminal failure and block jobs that require its output.
    public func fail(_ assignment: JobAssignment, reason: String) throws {
        var record = try activeRecord(for: assignment)
        record.status = .failed
        record.output = nil
        record.failure = reason
        record.finishedAt = .now
        records[assignment.job.id] = record
        refreshBlockedJobs()
    }

    public func snapshot() -> TaskDeploymentSnapshot {
        refreshBlockedJobs()
        let orderedRecords = plan.jobs.compactMap { records[$0.id] }
        let status: DeploymentStatus
        if orderedRecords.allSatisfy({ $0.status == .succeeded }) {
            status = .succeeded
        } else if orderedRecords.allSatisfy({ $0.status.isTerminal }) {
            status = .failed
        } else {
            status = .active
        }
        return TaskDeploymentSnapshot(
            id: id,
            planID: plan.id,
            status: status,
            jobs: orderedRecords,
            readyJobIDs: readyJobIDs())
    }

    private func readyJobIDs() -> [String] {
        plan.jobs.compactMap { job in
            guard records[job.id]?.status == .pending else { return nil }
            let dependenciesSucceeded = job.dependsOn.allSatisfy {
                records[$0]?.status == .succeeded
            }
            return dependenciesSucceeded ? job.id : nil
        }
    }

    private func activeRecord(for assignment: JobAssignment) throws -> DeployedJob {
        guard assignment.deploymentID == id else {
            throw TaskDeploymentError.foreignAssignment(
                expectedDeploymentID: id, actualDeploymentID: assignment.deploymentID)
        }
        let jobID = assignment.job.id
        guard let record = records[jobID] else {
            throw TaskDeploymentError.unknownJob(jobID)
        }
        guard record.status == .running else {
            throw TaskDeploymentError.invalidTransition(jobID: jobID, status: record.status)
        }
        guard record.assignmentID == assignment.id else {
            throw TaskDeploymentError.assignmentMismatch(jobID: jobID)
        }
        guard record.workerID == assignment.workerID else {
            throw TaskDeploymentError.workerMismatch(
                jobID: jobID, claimedBy: record.workerID ?? "", attemptedBy: assignment.workerID)
        }
        return record
    }

    /// Propagate failure through the graph. Repeating handles plans whose array
    /// order does not happen to be topological.
    private func refreshBlockedJobs() {
        var changed: Bool
        repeat {
            changed = false
            for job in plan.jobs {
                guard var record = records[job.id], record.status == .pending else { continue }
                let failedDependencies = job.dependsOn.filter {
                    guard let status = records[$0]?.status else { return false }
                    return status == .failed || status == .blocked
                }
                guard !failedDependencies.isEmpty else { continue }
                record.status = .blocked
                record.failure = "Blocked by failed dependencies: \(failedDependencies.joined(separator: ", "))"
                record.finishedAt = .now
                records[job.id] = record
                changed = true
            }
        } while changed
    }
}
