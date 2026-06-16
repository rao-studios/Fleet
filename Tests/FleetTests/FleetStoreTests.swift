import XCTest

@testable import FleetCore
@testable import FleetStore

final class FleetStoreTests: XCTestCase {

    func testDatasetCorpusBuildsTextExamples() {
        let dataset = TrainingDataset(
            name: "facts",
            records: [
                .note("Fleet is a Swift Agent Harness."),
                .qa(question: "Who built it?", answer: "Rao."),
            ])
        let examples = dataset.corpus.textExamples
        XCTAssertTrue(examples.contains("Fleet is a Swift Agent Harness."))
        XCTAssertTrue(examples.contains("Q: Who built it?\nA: Rao."))
        XCTAssertEqual(dataset.trainingExamples.count, 3)  // note + (qa line + bare answer)
    }

    func testPropertyListRoundTrip() throws {
        // Exercise the same PropertyList path FleetDB uses, in a temp location-independent way.
        let dataset = TrainingDataset(name: "roundtrip", records: [.note("hello")])
        let data = try PropertyListEncoder().encode(dataset)
        let decoded = try PropertyListDecoder().decode(TrainingDataset.self, from: data)
        XCTAssertEqual(decoded.id, dataset.id)
        XCTAssertEqual(decoded.name, "roundtrip")
        XCTAssertEqual(decoded.records.first?.note, "hello")
    }

    func testAdapterTiesToDatasetUUID() async {
        let db = FleetDB()
        let dataset = TrainingDataset(name: "linked", records: [.note("x")])
        await db.saveDataset(dataset)

        let adapter = TrainedAdapter(
            datasetId: dataset.id, name: "linked-lora",
            modelId: "mlx-community/Qwen3-0.6B-4bit",
            rank: 8, scale: 20, numLayers: 16, iterations: 100)
        await db.saveAdapter(adapter)

        // The LoRA's UUID is tied to the dataset's UUID via datasetId.
        let found = await db.adapters(forDataset: dataset.id)
        XCTAssertEqual(found.map(\.id), [adapter.id])
        XCTAssertEqual(found.first?.datasetId, dataset.id)

        // adapterDirectory is under fleet-db/loras/<adapterId>.
        let dir = db.adapterDirectory(for: adapter.id)
        XCTAssertEqual(dir.lastPathComponent, adapter.id.uuidString)
        XCTAssertEqual(dir.deletingLastPathComponent().lastPathComponent, "loras")

        // Clean up so the shared fleet-db doesn't accumulate test records.
        await db.deleteAdapter(id: adapter.id)
        await db.deleteDataset(id: dataset.id)
    }
}
