import XCTest

@testable import FleetTasks

final class FleetTasksTests: XCTestCase {

    func testPlannerTurnsObjectiveIntoValidatedJobs() async throws {
        let objective = "Research two approaches, compare them, and recommend one."
        let spy = PlanningPromptSpy()
        let response = #"""
            {
              "jobs": [
                {"id":"research-a","title":"Research A","instructions":"Investigate approach A.","dependsOn":[]},
                {"id":"research-b","title":"Research B","instructions":"Investigate approach B.","dependsOn":[]},
                {"id":"recommend","title":"Recommend","instructions":"Compare both findings and recommend one.","dependsOn":["research-a","research-b"]}
              ]
            }
            """#
        let planner = JSONTaskPlanner { prompt in
            await spy.record(prompt)
            return response
        }

        let plan = try await planner.makePlan(for: objective)

        XCTAssertEqual(plan.objective, objective)
        XCTAssertEqual(plan.jobs.map(\.id), ["research-a", "research-b", "recommend"])
        XCTAssertEqual(plan.jobs.last?.dependsOn, ["research-a", "research-b"])
        let generatedPrompt = await spy.prompt
        XCTAssertTrue(generatedPrompt?.contains(objective) == true)
        XCTAssertTrue(generatedPrompt?.contains("dependsOn") == true)
    }

    func testPlannerAcceptsSingleJSONFence() throws {
        let response = #"""
            ```json
            {"jobs":[{"id":"write","title":"Write","instructions":"Write the result.","dependsOn":[]}]}
            ```
            """#

        let plan = try TaskPlanDecoder().decode(response, objective: "Write something")

        XCTAssertEqual(plan.jobs.map(\.id), ["write"])

        let wrongFence = response.replacingOccurrences(of: "```json", with: "```swift")
        XCTAssertThrowsError(try TaskPlanDecoder().decode(wrongFence, objective: "Write something"))
    }

    func testPlannerRejectsProseAndJobExplosion() throws {
        let job = #"{"id":"a","title":"A","instructions":"Do A.","dependsOn":[]}"#
        let prose = "Here is the plan: {\"jobs\":[\(job)]}"
        XCTAssertThrowsError(try TaskPlanDecoder().decode(prose, objective: "Do work")) { error in
            XCTAssertTrue(error is TaskPlanningError)
        }

        let oversized = "{\"jobs\":[\(Array(repeating: job, count: 3).joined(separator: ","))]}"
        XCTAssertThrowsError(
            try TaskPlanDecoder(maximumJobs: 2).decode(oversized, objective: "Do work")
        ) { error in
            XCTAssertEqual(
                error as? TaskPlanValidationError,
                .tooManyJobs(maximum: 2, actual: 3))
        }
    }

    func testEmptyObjectiveDoesNotInvokeGenerator() async {
        let spy = PlanningPromptSpy()
        let planner = JSONTaskPlanner { prompt in
            await spy.record(prompt)
            return #"{"jobs":[]}"#
        }

        do {
            _ = try await planner.makePlan(for: "  \n")
            XCTFail("Expected empty objective validation to fail")
        } catch {
            XCTAssertEqual(error as? TaskPlanValidationError, .emptyObjective)
        }
        let generatedPrompt = await spy.prompt
        XCTAssertNil(generatedPrompt)
    }

    func testPlanValidationRejectsBrokenDependencyGraphs() {
        assertValidationError(jobs: [], equals: .emptyPlan)
        assertValidationError(
            jobs: [AgentJob(id: " ", title: "A", instructions: "Do A.")],
            equals: .emptyJobID(index: 0))
        assertValidationError(
            jobs: [AgentJob(id: " invalid id ", title: "A", instructions: "Do A.")],
            equals: .invalidJobID(" invalid id "))
        assertValidationError(
            jobs: [AgentJob(id: "a", title: " ", instructions: "Do A.")],
            equals: .emptyJobTitle(jobID: "a"))
        assertValidationError(
            jobs: [AgentJob(id: "a", title: "A", instructions: " \n")],
            equals: .emptyJobInstructions(jobID: "a"))
        assertValidationError(
            jobs: [job("a", dependsOn: ["missing"])],
            equals: .missingDependency(jobID: "a", dependencyID: "missing"))
        assertValidationError(
            jobs: [job("a", dependsOn: ["a"])],
            equals: .selfDependency(jobID: "a"))
        assertValidationError(
            jobs: [job("a", dependsOn: ["b"]), job("b", dependsOn: ["a"])],
            equals: .cyclicDependencies(jobIDs: ["a", "b"]))
        assertValidationError(
            jobs: [
                job("a", dependsOn: ["b"]),
                job("b", dependsOn: ["a"]),
                job("downstream", dependsOn: ["a"]),
            ],
            equals: .cyclicDependencies(jobIDs: ["a", "b"]))
        assertValidationError(
            jobs: [job("a"), job("a")],
            equals: .duplicateJobID("a"))
        assertValidationError(
            jobs: [job("a"), job("b", dependsOn: ["a", "a"])],
            equals: .duplicateDependency(jobID: "b", dependencyID: "a"))
    }

    func testPlanCodableRoundTrip() throws {
        let plan = TaskPlan(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            objective: "Ship a feature",
            jobs: [job("inspect"), job("ship", dependsOn: ["inspect"])],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))

        let decoded = try JSONDecoder().decode(TaskPlan.self, from: JSONEncoder().encode(plan))

        XCTAssertEqual(decoded, plan)
    }

    func testDeploymentClaimsRootsThenPassesOrderedDependencyOutputs() async throws {
        // Deliberately not topological: deployment order remains the authored
        // order while readiness is derived strictly from dependencies.
        let plan = try TaskPlan(
            objective: "Build and verify",
            jobs: [
                job("join", dependsOn: ["a", "b"]),
                job("b"),
                job("a"),
                job("tail", dependsOn: ["join"]),
            ]).validated()
        let deployment = try TaskDeployment(plan: plan)

        let initial = await deployment.snapshot()
        XCTAssertEqual(initial.jobs.map(\.status), [.pending, .pending, .pending, .pending])
        XCTAssertEqual(initial.readyJobIDs, ["b", "a"])

        let zeroClaim = try await deployment.claimReadyJobs(limit: 0, workerID: "worker")
        let negativeClaim = try await deployment.claimReadyJobs(limit: -1, workerID: "worker")
        XCTAssertTrue(zeroClaim.isEmpty)
        XCTAssertTrue(negativeClaim.isEmpty)

        let roots = try await deployment.claimReadyJobs(limit: 2, workerID: "worker")
        XCTAssertEqual(roots.map(\.job.id), ["b", "a"])
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.job.id, $0) })
        let duplicateClaim = try await deployment.claimReadyJobs(limit: 2, workerID: "other")
        XCTAssertTrue(duplicateClaim.isEmpty)

        try await deployment.complete(try XCTUnwrap(rootsByID["b"]), output: "output-b")
        let beforeFanIn = try await deployment.claimReadyJobs(limit: 1, workerID: "worker")
        XCTAssertTrue(beforeFanIn.isEmpty)

        try await deployment.complete(try XCTUnwrap(rootsByID["a"]), output: "output-a")
        let fanIn = try await deployment.claimReadyJobs(limit: 1, workerID: "worker")
        XCTAssertEqual(fanIn.map(\.job.id), ["join"])
        XCTAssertEqual(
            fanIn.first?.dependencyOutputs,
            [
                JobDependencyOutput(jobID: "a", output: "output-a"),
                JobDependencyOutput(jobID: "b", output: "output-b"),
            ])

        try await deployment.complete(try XCTUnwrap(fanIn.first), output: "joined")
        let tail = try await deployment.claimReadyJobs(workerID: "worker")
        XCTAssertEqual(tail.map(\.job.id), ["tail"])
        try await deployment.complete(try XCTUnwrap(tail.first), output: "done")

        let final = await deployment.snapshot()
        XCTAssertEqual(final.status, .succeeded)
        XCTAssertTrue(final.jobs.allSatisfy { $0.status == .succeeded })
        XCTAssertTrue(final.readyJobIDs.isEmpty)
    }

    func testFailureBlocksDescendantsButNotIndependentWork() async throws {
        let plan = try TaskPlan(
            objective: "Run branches",
            jobs: [
                job("root"),
                job("child", dependsOn: ["root"]),
                job("grandchild", dependsOn: ["child"]),
                job("independent"),
            ]).validated()
        let deployment = try TaskDeployment(plan: plan)
        let roots = try await deployment.claimReadyJobs(limit: 2, workerID: "worker")
        XCTAssertEqual(roots.map(\.job.id), ["root", "independent"])
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.job.id, $0) })

        try await deployment.fail(try XCTUnwrap(rootsByID["root"]), reason: "boom")
        let partial = await deployment.snapshot()
        XCTAssertEqual(partial.jobs.map(\.status), [.failed, .blocked, .blocked, .running])
        XCTAssertEqual(partial.status, .active)

        try await deployment.complete(
            try XCTUnwrap(rootsByID["independent"]), output: "still completed")
        let final = await deployment.snapshot()
        XCTAssertEqual(final.status, .failed)
        XCTAssertTrue(final.readyJobIDs.isEmpty)
    }

    func testDeploymentEnforcesWorkerOwnershipAndTransitions() async throws {
        let plan = try TaskPlan(objective: "One job", jobs: [job("only")]).validated()
        let deployment = try TaskDeployment(plan: plan)

        do {
            _ = try await deployment.claimReadyJobs(workerID: " \n")
            XCTFail("Expected blank worker id to fail")
        } catch {
            XCTAssertEqual(error as? TaskDeploymentError, .emptyWorkerID)
        }
        let afterBlankClaim = await deployment.snapshot()
        XCTAssertEqual(afterBlankClaim.readyJobIDs, ["only"])

        do {
            let unknown = JobAssignment(
                deploymentID: deployment.id,
                planID: plan.id,
                objective: plan.objective,
                job: job("missing"),
                dependencyOutputs: [],
                attempt: 1,
                workerID: "worker-a")
            try await deployment.complete(unknown, output: "nope")
            XCTFail("Expected unknown job to fail")
        } catch {
            XCTAssertEqual(error as? TaskDeploymentError, .unknownJob("missing"))
        }

        do {
            let unclaimed = JobAssignment(
                deploymentID: deployment.id,
                planID: plan.id,
                objective: plan.objective,
                job: job("only"),
                dependencyOutputs: [],
                attempt: 1,
                workerID: "worker-a")
            try await deployment.complete(unclaimed, output: "too soon")
            XCTFail("Expected unclaimed completion to fail")
        } catch {
            XCTAssertEqual(
                error as? TaskDeploymentError,
                .invalidTransition(jobID: "only", status: .pending))
        }

        let claimed = try await deployment.claimReadyJobs(workerID: "worker-a")
        let assignment = try XCTUnwrap(claimed.first)
        do {
            let wrongWorker = JobAssignment(
                id: assignment.id,
                deploymentID: assignment.deploymentID,
                planID: assignment.planID,
                objective: assignment.objective,
                job: assignment.job,
                dependencyOutputs: assignment.dependencyOutputs,
                attempt: assignment.attempt,
                workerID: "worker-b",
                assignedAt: assignment.assignedAt)
            try await deployment.complete(wrongWorker, output: "wrong owner")
            XCTFail("Expected ownership validation to fail")
        } catch {
            XCTAssertEqual(
                error as? TaskDeploymentError,
                .workerMismatch(jobID: "only", claimedBy: "worker-a", attemptedBy: "worker-b"))
        }

        try await deployment.complete(assignment, output: "done")
        do {
            try await deployment.fail(assignment, reason: "too late")
            XCTFail("Expected terminal transition to fail")
        } catch {
            XCTAssertEqual(
                error as? TaskDeploymentError,
                .invalidTransition(jobID: "only", status: .succeeded))
        }
    }

    func testConcurrentClaimsAreDisjoint() async throws {
        let plan = try TaskPlan(
            objective: "Parallel roots",
            jobs: [job("a"), job("b"), job("c"), job("d")]).validated()
        let deployment = try TaskDeployment(plan: plan)

        async let first = deployment.claimReadyJobs(limit: 2, workerID: "first")
        async let second = deployment.claimReadyJobs(limit: 2, workerID: "second")
        let (firstClaims, secondClaims) = try await (first, second)
        let claimed = (firstClaims + secondClaims).map(\.job.id)

        XCTAssertEqual(Set(claimed), Set(["a", "b", "c", "d"]))
        XCTAssertEqual(claimed.count, 4)
    }

    func testTaskDeployerConnectsPlanningToDeployment() async throws {
        let planner = JSONTaskPlanner { _ in
            #"{"jobs":[{"id":"first","title":"First","instructions":"Do the first job.","dependsOn":[]},{"id":"second","title":"Second","instructions":"Use the first result.","dependsOn":["first"]}]}"#
        }

        let deployment = try await TaskDeployer(planner: planner).deploy("Complete both jobs")
        let snapshot = await deployment.snapshot()

        XCTAssertEqual(snapshot.jobs.map(\.id), ["first", "second"])
        XCTAssertEqual(snapshot.readyJobIDs, ["first"])
    }

    func testTaskDeployerEnforcesLimitForCustomPlanner() async {
        let jobs = (0 ..< 9).map {
            AgentJob(id: "job-\($0)", title: "Job \($0)", instructions: "Do job \($0).")
        }
        let deployer = TaskDeployer(planner: FixedPlanner(plan: TaskPlan(objective: "Too large", jobs: jobs)))

        do {
            _ = try await deployer.deploy("Too large")
            XCTFail("Expected deployment boundary to enforce the job limit")
        } catch {
            XCTAssertEqual(
                error as? TaskPlanValidationError,
                .tooManyJobs(maximum: TaskPlanLimits.maximumJobs, actual: 9))
        }
    }

    private func assertValidationError(
        jobs: [AgentJob],
        equals expected: TaskPlanValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try TaskPlan(objective: "Test", jobs: jobs).validated(),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? TaskPlanValidationError, expected, file: file, line: line)
        }
    }

    private func job(_ id: String, dependsOn: [String] = []) -> AgentJob {
        AgentJob(id: id, title: "Job \(id)", instructions: "Do job \(id).", dependsOn: dependsOn)
    }
}

private actor PlanningPromptSpy {
    private(set) var prompt: String?

    func record(_ prompt: String) {
        self.prompt = prompt
    }
}

private struct FixedPlanner: TaskPlanning {
    let plan: TaskPlan

    func makePlan(for objective: String) async throws -> TaskPlan {
        plan
    }
}
