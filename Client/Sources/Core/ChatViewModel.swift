import Fleet
import Foundation

/// One prompt and the two answers it produced (base vs fine-tuned).
struct Exchange: Identifiable {
    let id = UUID()
    let prompt: String
    var baseReply: String = ""
    var tunedReply: String = ""
    var baseDone = false
    var tunedDone = false
}

/// Drives the A/B chat: the same prompt is streamed to the base model and the
/// LoRA fine-tuned model so the user can compare what the adapter learned.
@MainActor
final class ChatViewModel: ObservableObject {

    @Published var exchanges: [Exchange] = []
    @Published var input: String = ""
    @Published var isBusy = false

    let modelId: String
    let adapterId: UUID
    private let baseSession: ChatSession
    private let tunedSession: ChatSession

    init(modelId: String, adapterId: UUID, adapterDirectory: URL) {
        self.modelId = modelId
        self.adapterId = adapterId
        self.baseSession = ChatSession(modelId: modelId, adapterDirectory: nil)
        self.tunedSession = ChatSession(modelId: modelId, adapterDirectory: adapterDirectory)
    }

    private enum Column { case base, tuned }

    func send() async {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isBusy else { return }
        input = ""
        isBusy = true

        let index = exchanges.count
        exchanges.append(Exchange(prompt: prompt))

        let baseHistory = history(\.baseReply, newPrompt: prompt, upTo: index)
        let tunedHistory = history(\.tunedReply, newPrompt: prompt, upTo: index)

        async let base: Void = stream(baseSession, history: baseHistory, into: index, column: .base)
        async let tuned: Void = stream(tunedSession, history: tunedHistory, into: index, column: .tuned)
        _ = await (base, tuned)

        isBusy = false
    }

    private func history(
        _ keyPath: KeyPath<Exchange, String>, newPrompt: String, upTo index: Int
    ) -> [ChatTurn] {
        var turns: [ChatTurn] = []
        for exchange in exchanges[0 ..< index] {
            turns.append(ChatTurn(role: .user, text: exchange.prompt))
            turns.append(ChatTurn(role: .assistant, text: exchange[keyPath: keyPath]))
        }
        turns.append(ChatTurn(role: .user, text: newPrompt))
        return turns
    }

    private func stream(
        _ session: ChatSession, history: [ChatTurn], into index: Int, column: Column
    ) async {
        do {
            for try await chunk in await session.reply(history: history, maxTokens: 256) {
                guard index < exchanges.count else { return }
                switch column {
                case .base: exchanges[index].baseReply += chunk
                case .tuned: exchanges[index].tunedReply += chunk
                }
            }
        } catch {
            guard index < exchanges.count else { return }
            let message = "⚠️ \(error)"
            switch column {
            case .base: exchanges[index].baseReply += message
            case .tuned: exchanges[index].tunedReply += message
            }
        }
        guard index < exchanges.count else { return }
        switch column {
        case .base: exchanges[index].baseDone = true
        case .tuned: exchanges[index].tunedDone = true
        }
    }
}
