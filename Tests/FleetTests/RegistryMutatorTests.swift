import XCTest

@testable import FleetStore

/// The registry's write coalescing, driven the way a Life train request drives
/// it: many debounced `mutate`s back to back.
///
/// That burst is what aborted the server — each change cancelled a flush task
/// asleep in `Task.sleep(for:)`, and `swift_task_dealloc` fatal-errored a
/// second later. These pin the contract the replacement keeps: the file ends
/// at the last state, and an explicit flush mid-burst doesn't strand a write.
final class RegistryMutatorTests: StoreTestCase {

    private func stored() -> FleetRegistry? {
        FilePersistence(key: "registry").restore()
    }

    func testBurstOfWritesCoalescesToTheLastState() async throws {
        let db = FleetDB(registry: RegistryMutator(debounceSeconds: 0.05))
        for index in 0 ..< 300 {
            await db.createGroup(label: "g\(index)")
        }
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(stored()?.groups.count, 300)
    }

    func testFlushNowMidBurstStillConverges() async throws {
        let db = FleetDB(registry: RegistryMutator(debounceSeconds: 0.05))
        for index in 0 ..< 100 {
            await db.createGroup(label: "a\(index)")
        }
        await db.flush()
        XCTAssertEqual(stored()?.groups.count, 100)

        for index in 0 ..< 100 {
            await db.createGroup(label: "b\(index)")
        }
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(stored()?.groups.count, 200)
    }
}
