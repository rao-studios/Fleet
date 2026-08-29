import FleetCore
import XCTest

@testable import FleetStore

/// Each test runs against its own temporary `fleet-db`.
///
/// The store root is process-global, so these tests share a serial queue by
/// virtue of XCTest running methods in a class sequentially; the root is repointed
/// in `setUp` and torn down after.
class StoreTestCase: XCTestCase {

    var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FilePersistence.setRoot(root)
    }

    override func tearDown() {
        FilePersistence.setRoot(nil)
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    /// A staging directory holding plausible artifacts.
    func makeStaging(_ db: FleetDB, weights: String = "weights") async throws -> URL {
        let staging = try db.makeStagingDirectory()
        try Data(weights.utf8).write(
            to: staging.appendingPathComponent(LoRAArtifact.weights))
        let schema = try SchemaExtractor.template(
            outputs: [try JSONParser.parse(#"{"a":"x"}"#)])
        try JSONEncoder().encode(schema).write(
            to: staging.appendingPathComponent(LoRAArtifact.schema))
        return staging
    }

    func makeEntry(cid: String, iterations: Int = 100) -> @Sendable (LoRAEntry?) -> LoRAEntry {
        { _ in
            LoRAEntry(
                cid: cid,
                modelId: "test-model",
                schemaHash: "schema-hash",
                schemaDescription: #"{"a":string}"#,
                pairCount: 3,
                rank: 8,
                scale: 20,
                numLayers: 16,
                iterations: iterations
            )
        }
    }
}

final class FleetDBLoRATests: StoreTestCase {

    func testPublishStoresWeightsUnderTheContentID() async throws {
        let db = FleetDB()
        let cid = String(repeating: "a", count: 64)
        let staging = try await makeStaging(db)

        let entry = try await db.publishLoRA(cid: cid, from: staging, makeEntry: makeEntry(cid: cid))

        XCTAssertEqual(entry.cid, cid)
        XCTAssertEqual(entry.generation, 1)
        XCTAssertTrue(db.hasWeights(cid: cid))
        XCTAssertEqual(db.adapterDirectory(cid: cid).lastPathComponent, cid)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staging.path),
            "the staging directory should have been consumed"
        )
    }

    func testRetrainingTheSameInputsOverwritesInPlace() async throws {
        let db = FleetDB()
        let cid = String(repeating: "b", count: 64)

        let first = try await db.publishLoRA(
            cid: cid, from: try await makeStaging(db, weights: "v1"),
            makeEntry: makeEntry(cid: cid))
        await db.setLabel(cid: cid, label: "Triage v1")
        let group = await db.createGroup(label: "Production")
        await db.add(cid: cid, toGroup: group.id)

        let second = try await db.publishLoRA(
            cid: cid, from: try await makeStaging(db, weights: "v2"),
            makeEntry: makeEntry(cid: cid, iterations: 500))

        // Same identity, new generation.
        XCTAssertEqual(second.cid, first.cid)
        XCTAssertEqual(second.generation, 2)
        XCTAssertEqual(second.iterations, 500)
        // The library position survives a retrain: label, birthday, groups.
        XCTAssertEqual(second.label, "Triage v1")
        XCTAssertEqual(second.createdAt, first.createdAt)
        let groups = await db.groups(forLoRA: cid)
        XCTAssertEqual(groups.map(\.id), [group.id])
        // And the weights are the new ones.
        let weights = try String(
            contentsOf: db.adapterDirectory(cid: cid)
                .appendingPathComponent(LoRAArtifact.weights), encoding: .utf8)
        XCTAssertEqual(weights, "v2")

        let all = await db.allLoRAs()
        XCTAssertEqual(all.count, 1, "a retrain must not create a second LoRA")
    }

    func testDeleteRemovesWeightsAndMemberships() async throws {
        let db = FleetDB()
        let cid = String(repeating: "c", count: 64)
        _ = try await db.publishLoRA(
            cid: cid, from: try await makeStaging(db), makeEntry: makeEntry(cid: cid))
        let group = await db.createGroup(label: "Temp")
        await db.add(cid: cid, toGroup: group.id)

        await db.deleteLoRA(cid: cid)

        XCTAssertFalse(db.hasWeights(cid: cid))
        let page = await db.loras(inGroup: group.id)
        XCTAssertTrue(page.items.isEmpty)
        let entry = await db.lora(cid: cid)
        XCTAssertNil(entry)
    }

    func testSchemaIsReadBackFromTheAdapterDirectory() async throws {
        let db = FleetDB()
        let cid = String(repeating: "d", count: 64)
        _ = try await db.publishLoRA(
            cid: cid, from: try await makeStaging(db), makeEntry: makeEntry(cid: cid))

        let schema = db.schema(cid: cid)
        XCTAssertEqual(schema?.description, #"{"a":string}"#)
    }
}

final class FleetDBDatasetTests: StoreTestCase {

    private func dataset(name: String = "Test") throws -> StateDataset {
        let pairs = MockDatasetGenerator.generate(domain: .weatherReport, count: 5, seed: 3)
        return try StateDataset(name: name, pairs: pairs)
    }

    func testSaveAndLoadRoundTrips() async throws {
        let db = FleetDB()
        let original = try dataset()
        await db.saveDataset(original)

        let loaded = await db.loadDataset(id: original.id)
        XCTAssertEqual(loaded?.pairs.count, original.pairs.count)
        XCTAssertEqual(loaded?.schema, original.schema)
        XCTAssertEqual(loaded?.inputCID, original.inputCID)

        let entry = await db.datasetEntry(id: original.id)
        XCTAssertEqual(entry?.pairCount, 5)
        XCTAssertEqual(entry?.inputCID, original.inputCID)
    }

    func testDeletingADatasetLeavesItsLoRAsIntact() async throws {
        let db = FleetDB()
        let stored = try dataset()
        await db.saveDataset(stored)
        let cid = stored.inputCID
        _ = try await db.publishLoRA(cid: cid, from: try await makeStaging(db)) { _ in
            LoRAEntry(
                cid: cid, modelId: "m", datasetId: stored.id, schemaHash: "h",
                schemaDescription: "d", pairCount: 5, rank: 8, scale: 20,
                numLayers: 16, iterations: 10)
        }

        await db.deleteDataset(id: stored.id)

        let entry = await db.lora(cid: cid)
        XCTAssertNotNil(entry, "the trained weights outlive their dataset")
        XCTAssertNil(entry?.datasetId, "but the dangling link is cleared")
        XCTAssertTrue(db.hasWeights(cid: cid))
    }
}

final class FleetDBPaginationTests: StoreTestCase {

    func testCursorPaginationWalksEveryEntryOnce() async throws {
        let db = FleetDB()
        var expected: [String] = []
        for index in 0 ..< 7 {
            let cid = String(format: "%064x", index)
            expected.append(cid)
            _ = try await db.publishLoRA(
                cid: cid, from: try await makeStaging(db), makeEntry: makeEntry(cid: cid))
        }

        var seen: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            let page = await db.loras(after: cursor, limit: 3)
            seen.append(contentsOf: page.items.map(\.cid))
            cursor = page.nextCursor
            pages += 1
            if !page.hasMore { break }
        } while pages < 10

        XCTAssertEqual(seen.sorted(), expected.sorted())
        XCTAssertEqual(Set(seen).count, seen.count, "an entry appeared on two pages")
    }

    func testGroupMembershipPaginates() async throws {
        let db = FleetDB()
        let group = await db.createGroup(label: "Batch")
        for index in 0 ..< 4 {
            let cid = String(format: "%064x", index)
            _ = try await db.publishLoRA(
                cid: cid, from: try await makeStaging(db), makeEntry: makeEntry(cid: cid))
            await db.add(cid: cid, toGroup: group.id)
        }

        let first = await db.loras(inGroup: group.id, limit: 3)
        XCTAssertEqual(first.items.count, 3)
        XCTAssertTrue(first.hasMore)
        let second = await db.loras(inGroup: group.id, after: first.nextCursor, limit: 3)
        XCTAssertEqual(second.items.count, 1)
        XCTAssertFalse(second.hasMore)
    }
}

final class FleetDBReconciliationTests: StoreTestCase {

    func testEntryWithoutWeightsIsDropped() async throws {
        let db = FleetDB()
        let cid = String(repeating: "e", count: 64)
        _ = try await db.publishLoRA(
            cid: cid, from: try await makeStaging(db), makeEntry: makeEntry(cid: cid))

        // Simulate a crash that lost the weights.
        try FileManager.default.removeItem(at: db.adapterDirectory(cid: cid))

        let report = await db.reconcile()
        XCTAssertEqual(report.removedEntries, 1)
        let entry = await db.lora(cid: cid)
        XCTAssertNil(entry)
    }

    func testStagingAndOrphanDirectoriesAreSweptAway() async throws {
        let db = FleetDB()
        let staging = try db.makeStagingDirectory()
        let orphan = root
            .appendingPathComponent("loras")
            .appendingPathComponent(String(repeating: "f", count: 64))
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        let report = await db.reconcile()

        XCTAssertEqual(report.removedDirectories, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testLegacyLayoutIsWiped() async throws {
        let manager = FileManager.default
        // The pre-rewrite store: UUID-named adapter dirs and index files.
        try Data("[]".utf8).write(to: root.appendingPathComponent("adapters-index"))
        try manager.createDirectory(
            at: root.appendingPathComponent("graphs"), withIntermediateDirectories: true)
        let legacyLoRA = root
            .appendingPathComponent("loras")
            .appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: legacyLoRA, withIntermediateDirectories: true)

        let db = FleetDB()
        let report = await db.reconcile()

        XCTAssertEqual(report.removedLegacyPaths, 3)
        XCTAssertFalse(manager.fileExists(atPath: legacyLoRA.path))
        XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent("graphs").path))
    }

    func testCleanStoreReportsNothingToDo() async throws {
        let db = FleetDB()
        let cid = String(repeating: "a", count: 64)
        _ = try await db.publishLoRA(
            cid: cid, from: try await makeStaging(db), makeEntry: makeEntry(cid: cid))

        let report = await db.reconcile()
        XCTAssertTrue(report.isClean, "\(report)")
    }
}

final class FleetRegistryTests: XCTestCase {

    func testDecodingToleratesMissingFields() throws {
        // A registry written before `datasets` existed.
        let partial = #"{"loras":{},"groups":{}}"#
        let registry = try JSONDecoder().decode(FleetRegistry.self, from: Data(partial.utf8))
        XCTAssertTrue(registry.datasets.isEmpty)
        XCTAssertTrue(registry.groupMembers.isEmpty)
    }

    func testNormalizeDropsMembershipsForMissingLoRAs() {
        var registry = FleetRegistry()
        registry.groups["g"] = GroupEntry(id: "g", label: "Group")
        registry.groupMembers["g"] = ["nonexistent-cid"]
        registry.loraGroups["nonexistent-cid"] = ["g"]

        registry.normalize()

        XCTAssertEqual(registry.groupMembers["g"], [])
        XCTAssertNil(registry.loraGroups["nonexistent-cid"])
    }

    func testMembershipArraysStaySorted() {
        var registry = FleetRegistry()
        registry.groups["g"] = GroupEntry(id: "g", label: "Group")
        for cid in ["ccc", "aaa", "bbb"] {
            registry.loras[cid] = LoRAEntry(
                cid: cid, modelId: "m", schemaHash: "h", schemaDescription: "d",
                pairCount: 1, rank: 8, scale: 20, numLayers: 16, iterations: 1)
        }
        registry.groupMembers["g"] = ["ccc", "aaa", "bbb"]

        registry.normalize()

        XCTAssertEqual(registry.groupMembers["g"], ["aaa", "bbb", "ccc"])
    }
}
