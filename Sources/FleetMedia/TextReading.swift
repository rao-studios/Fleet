import Foundation

/// Best-effort text reader: prefer UTF-8, fall back to UTF-16, then Latin-1
/// (which decodes any byte sequence) so odd-but-textual files still load.
func readString(_ url: URL) throws -> String {
    if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }
    if let utf16 = try? String(contentsOf: url, encoding: .utf16) { return utf16 }
    return try String(contentsOf: url, encoding: .isoLatin1)
}

/// Build deterministic fragment ids of the form `"<file>#<index>"`.
func fragmentID(_ url: URL, _ index: Int) -> String {
    "\(url.lastPathComponent)#\(index)"
}
