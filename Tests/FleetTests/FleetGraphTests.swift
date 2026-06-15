import XCTest

@testable import FleetCore
@testable import FleetGraph

final class FleetGraphTests: XCTestCase {

    func testOperationTemplates() {
        let critique = NodeOperation.make(.critique).messages(for: "the sky is green", history: [])
        XCTAssertEqual(critique.count, 1)
        XCTAssertTrue(critique.first?.text.contains("Critique the following") ?? false)

        let custom = NodeOperation.make(.custom, custom: "Translate to French: {input}")
            .messages(for: "hello", history: [])
        XCTAssertEqual(custom.first?.text, "Translate to French: hello")
    }

    func testPolymorphicGraphCodableRoundTrip() throws {
        let input = InputNode(position: .init(x: 0, y: 0))
        let lora = LoRANode(position: .init(x: 1, y: 0), adapterId: UUID(), operationKind: .critique)
        let router = RouterNode(
            position: .init(x: 2, y: 0), gateKind: .embedding, topK: 2, combineKind: .synthesize)
        let output = OutputNode(position: .init(x: 3, y: 0))
        let graph = EnsembleGraph(
            name: "t", nodes: [input, lora, router, output],
            edges: [.init(from: input.id, to: lora.id), .init(from: lora.id, to: router.id)])

        let data = try JSONEncoder().encode(graph)
        let decoded = try JSONDecoder().decode(EnsembleGraph.self, from: data)

        XCTAssertTrue(decoded.nodes[0] is InputNode)
        XCTAssertTrue(decoded.nodes[1] is LoRANode)
        XCTAssertTrue(decoded.nodes[2] is RouterNode)
        XCTAssertTrue(decoded.nodes[3] is OutputNode)
        let r = decoded.nodes[2] as? RouterNode
        XCTAssertEqual(r?.gateKind, .embedding)
        XCTAssertEqual(r?.topK, 2)
        XCTAssertEqual(r?.combineKind, .synthesize)
    }

    func testTopologicalOrderAndCycleGuard() {
        let input = InputNode(position: .init(x: 0, y: 0))
        let a = LoRANode(position: .init(x: 1, y: 0))
        let b = LoRANode(position: .init(x: 2, y: 0))
        // Array order scrambled to prove topo follows edges.
        let graph = EnsembleGraph(
            nodes: [b, a, input],
            edges: [.init(from: input.id, to: a.id), .init(from: a.id, to: b.id)])
        XCTAssertEqual(graph.topologicalOrder().map(\.id), [input.id, a.id, b.id])
        XCTAssertTrue(graph.wouldCreateCycle(from: b.id, to: input.id))
        XCTAssertFalse(graph.wouldCreateCycle(from: input.id, to: b.id))
    }

    func testConcurrentFanInToRouter() async throws {
        let input = InputNode(position: .init(x: 0, y: 0))
        let a = LoRANode(position: .init(x: 1, y: 0), operationKind: .answer)
        let b = LoRANode(position: .init(x: 1, y: 1), operationKind: .answer)
        let router = RouterNode(position: .init(x: 2, y: 0), gateKind: .none, combineKind: .merge)
        let output = OutputNode(position: .init(x: 3, y: 0))
        let graph = EnsembleGraph(
            nodes: [input, a, b, router, output],
            edges: [
                .init(from: input.id, to: a.id), .init(from: input.id, to: b.id),
                .init(from: a.id, to: router.id), .init(from: b.id, to: router.id),
                .init(from: router.id, to: output.id),
            ])

        let runner = GraphRunner(graph: graph, executor: EchoExecutor())
        var finished: Set<UUID> = []
        var finalText = ""
        for try await event in runner.run(prompt: "seed") {
            switch event {
            case .finished(let id, _): finished.insert(id)
            case .final(let text): finalText = text
            default: break
            }
        }
        XCTAssertTrue(finished.contains(a.id))  // both members ran
        XCTAssertTrue(finished.contains(b.id))
        XCTAssertTrue(finalText.contains("[echo]seed"))  // merged member outputs
    }

    func testRouterTopKWithGate() async throws {
        let input = InputNode(position: .init(x: 0, y: 0))
        let a = LoRANode(position: .init(x: 1, y: 0), operationKind: .answer)
        let b = LoRANode(position: .init(x: 1, y: 1), operationKind: .answer)
        let router = RouterNode(position: .init(x: 2, y: 0), gateKind: .embedding, topK: 1, combineKind: .merge)
        let output = OutputNode(position: .init(x: 3, y: 0))
        let graph = EnsembleGraph(
            nodes: [input, a, b, router, output],
            edges: [
                .init(from: input.id, to: a.id), .init(from: input.id, to: b.id),
                .init(from: a.id, to: router.id), .init(from: b.id, to: router.id),
                .init(from: router.id, to: output.id),
            ])

        let runner = GraphRunner(
            graph: graph, executor: EchoExecutor(), gate: RankGate(winner: "B"),
            describe: { $0?.id == b.id ? "B" : "A" })

        var finalText = ""
        var routerWeights: [UUID: Double] = [:]
        for try await event in runner.run(prompt: "seed") {
            switch event {
            case .gated(let id, let weights) where id == router.id: routerWeights = weights
            case .final(let text): finalText = text
            default: break
            }
        }
        XCTAssertEqual(routerWeights[b.id], 1.0)
        XCTAssertEqual(routerWeights[a.id], 0.0)
        XCTAssertTrue(finalText.contains("— B"))  // top-1 kept the higher-weighted expert
        XCTAssertFalse(finalText.contains("— A"))
    }
}

/// Deterministic fake: yields `[echo]` + the last user message text.
private struct EchoExecutor: StageExecuting {
    func run(adapterDirectory: URL?, history: [ChatTurn], maxTokens: Int)
        -> AsyncThrowingStream<String, Error>
    {
        let last = history.last(where: { $0.role == .user })?.text ?? ""
        return AsyncThrowingStream { continuation in
            continuation.yield("[echo]")
            continuation.yield(last)
            continuation.finish()
        }
    }
}

/// Fake gate: weight 1 for the winning descriptor, 0 otherwise.
private struct RankGate: GateScoring {
    let winner: String
    func score(query: String, experts: [String]) async throws -> [Double] {
        experts.map { $0 == winner ? 1.0 : 0.0 }
    }
}
