import Foundation

/// A source of aligned context.
///
/// A folder on disk is the provider for this demo; a Totem node (over its
/// HTTP/gRPC API) is the intended future provider. Either way the harness only
/// sees ``ContextFragment`` values.
public protocol ContextProvider: Sendable {
    func fragments() async throws -> [ContextFragment]
}

/// Walks a directory tree and routes every regular file through a ``DecoderRegistry``.
public struct FolderContextProvider: ContextProvider {

    public let root: URL
    public let registry: DecoderRegistry

    public init(root: URL, registry: DecoderRegistry) {
        self.root = root
        self.registry = registry
    }

    public func fragments() async throws -> [ContextFragment] {
        let fm = FileManager.default

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw FleetCoreError.pathNotFound(root)
        }

        // A single file is allowed too: route it directly.
        guard isDirectory.boolValue else {
            return try await registry.decode(root)
        }

        guard
            let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            throw FleetCoreError.notEnumerable(root)
        }

        var collected: [ContextFragment] = []
        for case let url as URL in enumerator {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular else { continue }
            guard registry.canDecode(url) else { continue }
            // A single unreadable/odd file must not abort the whole scan.
            do {
                collected.append(contentsOf: try await registry.decode(url))
            } catch {
                continue
            }
        }
        return collected
    }
}

public enum FleetCoreError: Error, CustomStringConvertible {
    case pathNotFound(URL)
    case notEnumerable(URL)

    public var description: String {
        switch self {
        case .pathNotFound(let url): return "Path not found: \(url.path)"
        case .notEnumerable(let url): return "Could not enumerate directory: \(url.path)"
        }
    }
}
