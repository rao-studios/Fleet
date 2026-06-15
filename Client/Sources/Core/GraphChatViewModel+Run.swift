import Fleet
import Foundation

/// Executing the graph: build the runner, stream events into the UI.
extension GraphChatViewModel {

    func send() async {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isBusy else { return }
        input = ""
        isBusy = true

        for node in nodes { runStates[node.id] = NodeRunState() }
        gateWeights = [:]
        let exchangeIndex = transcript.count
        transcript.append(GraphExchange(prompt: prompt))

        let history = transcriptHistory(upTo: exchangeIndex)
        let descriptors = await buildDescriptors()
        let resolve: @Sendable (UUID) -> URL? = { [db] id in db.adapterDirectory(for: id) }
        let describe: @Sendable (GraphNode?) -> String = { node in
            guard let node else { return "" }
            return descriptors[node.id] ?? node.title
        }
        let runner = GraphRunner(
            graph: currentGraph(), executor: stageRunner, gate: gate,
            resolveAdapter: resolve, describe: describe)

        do {
            for try await event in runner.run(prompt: prompt, history: history) {
                apply(event, exchangeIndex: exchangeIndex)
            }
        } catch {
            finishExchange(exchangeIndex, output: "⚠️ \(error)")
        }
        isBusy = false
    }

    private func apply(_ event: StageEvent, exchangeIndex: Int) {
        switch event {
        case .started(let nodeId, let input):
            runStates[nodeId, default: NodeRunState()].input = input
            runStates[nodeId, default: NodeRunState()].status = .running
        case .chunk(let nodeId, let text):
            runStates[nodeId, default: NodeRunState()].output += text
        case .gated(_, let weights):
            for (memberId, weight) in weights { gateWeights[memberId] = weight }
        case .finished(let nodeId, let output):
            runStates[nodeId, default: NodeRunState()].output = output
            runStates[nodeId, default: NodeRunState()].status = .done
        case .final(let text):
            finishExchange(exchangeIndex, output: text)
        }
    }

    private func finishExchange(_ index: Int, output: String) {
        guard index < transcript.count else { return }
        transcript[index].output = output
        transcript[index].done = true
    }

    private func transcriptHistory(upTo index: Int) -> [ChatTurn] {
        var turns: [ChatTurn] = []
        for exchange in transcript[0 ..< index] where exchange.done {
            turns.append(ChatTurn(role: .user, text: exchange.prompt))
            turns.append(ChatTurn(role: .assistant, text: exchange.output))
        }
        return turns
    }

    /// Expert descriptors for the gate: a LoRA member → its adapter's name (its
    /// domain), or "base model".
    private func buildDescriptors() async -> [UUID: String] {
        var map: [UUID: String] = [:]
        for node in nodes {
            if let lora = node as? LoRANode {
                if let adapterId = lora.adapterId, let adapter = await db.loadAdapter(id: adapterId) {
                    map[node.id] = adapter.name
                } else {
                    map[node.id] = "base model"
                }
            } else {
                map[node.id] = node.title
            }
        }
        return map
    }
}
