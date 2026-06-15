import FleetGraph
import Foundation
import Frigate

/// The Router's embedding gate: scores experts by cosine similarity between the
/// query and each expert's domain descriptor, softmaxed into gate weights.
///
/// Uses Frigate's `FrigateEmbedder` (a small embedding model, loaded lazily on
/// first use). This is the query-level MoE gate.
public actor EmbeddingGate: GateScoring {

    private let embedder: FrigateEmbedder
    /// Sharpens the softmax over cosine similarities (which sit in a narrow band).
    private let temperature: Double

    public init(
        modelId: String = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
        temperature: Double = 8
    ) {
        self.embedder = FrigateEmbedder(modelId: modelId)
        self.temperature = temperature
    }

    public func score(query: String, experts: [String]) async throws -> [Double] {
        guard !experts.isEmpty else { return [] }
        let embeddings = try await embedder.embed([query] + experts)
        let queryVector = embeddings[0]
        let similarities = experts.indices.map { Self.cosine(queryVector, embeddings[$0 + 1]) }
        return Self.softmax(similarities, temperature: temperature)
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in 0 ..< min(a.count, b.count) {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y
            normA += x * x
            normB += y * y
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        return denom == 0 ? 0 : dot / denom
    }

    private static func softmax(_ values: [Double], temperature: Double) -> [Double] {
        guard let maxValue = values.max() else { return [] }
        let exps = values.map { exp(($0 - maxValue) * temperature) }
        let sum = exps.reduce(0, +)
        guard sum > 0 else { return Array(repeating: 1.0 / Double(values.count), count: values.count) }
        return exps.map { $0 / sum }
    }
}
