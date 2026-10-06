# Bonnie task deployment MVP

This is Fleet's first agentic coordination slice. Its purpose is narrow: turn one
large objective into a small, validated graph of jobs and make those jobs safe for
workers to claim.

```text
large objective
      │
      ▼
JSONTaskPlanner ── injected model call
      │            returns only the small JSON contract
      ▼
TaskPlanValidator
      │            rejects missing jobs, bad references, and cycles
      ▼
TaskDeployment actor
      │
      ├── claim independent ready jobs ──► workers
      │                                      │
      └── unlock dependents ◄── complete/fail┘
```

## Planning contract

The model does not generate Fleet's runtime objects or an `EnsembleGraph`. It
generates only stable job IDs, titles, instructions, and dependencies:

```json
{
  "jobs": [
    {
      "id": "inspect",
      "title": "Inspect the codebase",
      "instructions": "Find the smallest integration points and report constraints.",
      "dependsOn": []
    },
    {
      "id": "test-design",
      "title": "Design tests",
      "instructions": "Define deterministic acceptance tests for the requested change.",
      "dependsOn": []
    },
    {
      "id": "implement",
      "title": "Implement the slice",
      "instructions": "Implement the change using both prior reports.",
      "dependsOn": ["inspect", "test-design"]
    }
  ]
}
```

Planner output is untrusted data. `TaskPlanValidator` rejects blank fields,
noncanonical job-ID slugs, duplicate IDs or dependencies, unknown and self
dependencies, cyclic graphs, and plans over eight jobs by default. The same cap
is enforced again when a plan becomes a deployment, including for custom planners.

## Deployment contract

`TaskDeployment` owns all mutable lifecycle state. Workers call
`claimReadyJobs(limit:workerID:)`; an atomic claim moves jobs from `pending` to
`running`, preventing duplicate assignment. Each `JobAssignment` includes:

- the original objective;
- the job's focused instructions;
- direct dependency outputs in declared order;
- deployment, plan, attempt, and worker identity.

Workers report `complete(_:output:)` or `fail(_:reason:)` with the exact
`JobAssignment` they received. Fleet checks its deployment and random assignment
IDs, so a worker label alone cannot authorize completion. Only the active claim
can finish a job.
A failure blocks transitive dependents, while independent work remains claimable.

```text
pending ──claim──► running ──complete──► succeeded
                         └──fail───────► failed

pending ──failed dependency────────────► blocked
```

A deployment succeeds only when every job succeeds. It reports failure once all
remaining work is terminal (`succeeded`, `failed`, or `blocked`).

## Minimal integration

The model boundary is an injected closure, so FleetTasks remains Foundation-only:

```swift
let planner = JSONTaskPlanner { planningPrompt in
    try await bonnieModel.generate(planningPrompt)
}
let deployment = try await TaskDeployer(planner: planner).deploy(largePrompt)

let assignments = try await deployment.claimReadyJobs(limit: 2, workerID: "bonnie-local")
for assignment in assignments {
    // Spawn or invoke the worker selected by Bonnie.
}
```

FleetGraph remains the inference-pipeline layer. A future worker adapter may run a
job through `GraphRunner`, a local model, or a spawned coding agent; task planning
does not grant tools or permissions. The host remains responsible for deciding
which worker and capabilities are allowed.

## Deliberately deferred

- automatic worker execution and event streaming;
- retries, leases, timeouts, cancellation, priorities, and budgets;
- persistence and resume after process restart;
- capability-based routing and tool permissions;
- dynamic re-planning or jobs that create nested plans;
- UI visualization.

The next useful slice is a `JobExecuting` adapter plus a bounded coordinator that
claims ready jobs, executes them, and reports state changes without weakening this
state machine.
