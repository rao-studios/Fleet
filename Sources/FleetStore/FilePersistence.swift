import Foundation

/// `fleet-db` document-file read-write utility.
///
/// Ported from Totem's `FilePersistence`: `Codable` + `PropertyListEncoder` with
/// `.atomic` writes, rooted at `~/Documents/fleet-db`. One instance maps to one
/// logical file under a string `key` (e.g. `"datasets/<uuid>"`). Not thread-safe
/// on its own — wrap in ``PersistenceActor`` or use it inside an `actor` (as
/// ``FleetDB`` does) to serialize access.
public final class FilePersistence: @unchecked Sendable {

    public let key: String
    public let url: URL

    public init(key: String) {
        let rootPath = FilePersistence.getDefaultURL()
        self.key = key
        self.url = rootPath.appendingPathComponent(key)
        do {
            try FileManager.default.createDirectory(
                at: rootPath, withIntermediateDirectories: true)
        } catch {
            FilePersistence.log("create root failed: \(error.localizedDescription)")
        }
    }

    /// Root of the on-disk store: `~/Documents/fleet-db`.
    public static func getDefaultURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("fleet-db")
    }

    public func save<State: Codable>(state: State) {
        let encoder = PropertyListEncoder()
        do {
            let data = try encoder.encode(state)
            if !FileManager.default.fileExists(atPath: url.path()) {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                _ = FileManager.default.createFile(atPath: url.path(), contents: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            FilePersistence.log("\(key) save failed: \(error.localizedDescription)")
        }
    }

    public func restore<State: Codable>() -> State? {
        let decoder = PropertyListDecoder()
        guard FileManager.default.fileExists(atPath: url.path()) else { return nil }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            FilePersistence.log("\(key) failed to read data.")
            return nil
        }
        do {
            return try decoder.decode(State.self, from: data)
        } catch {
            FilePersistence.log("\(key) decode failed: \(error.localizedDescription)")
            return nil
        }
    }

    public func purge() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Lightweight error log to stderr (FleetStore carries no logging dependency).
    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[fleet-db] \(message)\n".utf8))
    }
}
