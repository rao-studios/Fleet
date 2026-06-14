import XCTest

@testable import FleetCore
@testable import FleetGraph

final class FleetGraphTests: XCTestCase {

    func testOperationTemplates() {
        let critique = NodeOperation.make(.critique).messages(for: "the sky is green", history: [])
        XCTAssertEqual(critique.count, 1)
        XCTAssertTrue(critique.first?.text.contains("Critique the following") ?? false)
        XCTAssertTrue(critique.first?.text.contains("the sky is green") ?? false)

        // Answer threads conversation history.
        let history = [ChatTurn(role: .user, text: "hi"), ChatTurn(role: .assistant, text: "hello")]
        let answer = NodeOperation.make(.answer).messages(for: "what's up", history: history)
        XCTAssertEqual(answer.count, 3)
        XCTAssertEqual(answer.last?.text, "what's up")

        // Custom uses the {input} placeholder.
        let custom = NodeOperation.make(.custom, custom: "Translate to French: {input}")
            .messages(for: "hello", history: [])
        XCTAssertEqual(custom.first?.text, "Translate to French: hello")
    }

    func testPolymorphicGraphCodableRoundTrip() throws {
        let input = InputNode(position: .init(x: 0, y: 0))
        let lora = LoRANode(
            position: .init(x: 100, y: 0), adapterId: UUID(),
            operationKind: .critique)
        let output = OutputNode(position: .init(x: 200, y: 0))
        let graph = EnsembleGraph(
            name: "test",
            nodes: [input, lora, output],
            edges: [.init(from: input.id, to: lora.id), .init(from: lora.id, to: output.id)])

        let data = try JSONEncoder().encode(graph)
        let decoded = try JSONDecoder().decode(EnsembleGraph.self, from: data)

        XCTAssertEqual(decoded.nodes.count, 3)
        XCTAssertTrue(decoded.nodes[0] is InputNode)
        XCTAssertTrue(decoded.nodes[1] is LoRANode)
        XCTAssertTrue(decoded.nodes[2] is OutputNode)
        XCTAssertEqual((decoded.nodes[1] as? LoRANode)?.operationKind, .critique)
        XCTAssertEqual((decoded.nodes[1] as? LoRANode)?.adapterId, lora.adapterId)
        XCTAssertEqual(decoded.edges.count, 2)
    }

    func testExecutionOrderFollowsEdges() {
        let input = InputNode(position: .init(x: 0, y: 0))
        let a = LoRANode(position: .init(x: 1, y: 0))
        let b = LoRANode(position: .init(x: 2, y: 0))
        let output = OutputNode(position: .init(x: 3, y: 0))
        // Wire out of order to prove order follows edges, not array order.
        let graph = EnsembleGraph(
            nodes: [output, b, a, input],
            edges: [
                .init(from: input.id, to: a.id),
                .init(from: a.id, to: b.id),
                .init(from: b.id, to: output.id),
            ])
        XCTAssertEqual(graph.executionOrder().map(\.id), [input.id, a.id, b.id, output.id])
    }

    func testRunnerThreadsOutputThroughStages() async throws {
        // Fake executor: appends the stage's marker so we can see threading.
        let input = InputNode(position: .init(x: 0, y: 0))
        let a = LoRANode(position: .init(x: 1, y: 0), operationKind: .answer)
        let output = OutputNode(position: .init(x: 2, y: 0))
        let graph = EnsembleGraph(
            nodes: [input, a, output],
            edges: [.init(from: input.id, to: a.id), .init(from: a.id, to: output.id)])

        let runner = GraphRunner(graph: graph, executor: EchoExecutor()) { _ in nil }

        var finalText = ""
        var stageOutputs: [String] = []
        for try await event in runner.run(prompt: "seed") {
            switch event {
            case .finished(_, let output): stageOutputs.append(output)
            case .final(let text): finalText = text
            default: break
            }
        }
        // Input passes "seed"; LoRA stage echoes its messages' last user text -> "seed"; output passes through.
        XCTAssertEqual(finalText, "[echo]seed")
        XCTAssertEqual(stageOutputs.first, "seed")  // input node
        XCTAssertEqual(stageOutputs.last, "[echo]seed")  // output node passthrough of lora output
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
