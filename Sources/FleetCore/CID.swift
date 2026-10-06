import CryptoKit
import Foundation

/// Content-addressed identity for a LoRA.
///
/// A LoRA's CID is hashed from its training **input set only** — never the
/// outputs. That is deliberate: when the same questions get new answers because
/// the world moved on, retraining produces the same CID and overwrites the
/// previous adapter in place, which is what makes on-demand LoRAs addressable by
/// the inputs a caller already has.
///
/// The inputs are treated as a *set*: each is canonicalized, the canonical strings
/// are sorted, and the sorted join is hashed. Reordering the pairs in a dataset
/// therefore does not mint a new LoRA.
public enum ContentID {

    /// The CID of a training input set: lowercase SHA256 hex.
    public static func compute(inputs: [JSONValue]) -> String {
        let canonical = inputs.map { JSONCanonical.serialize($0) }.sorted()
        return hashHex(of: Data(canonical.joined(separator: "\n").utf8))
    }

    /// Lowercase SHA256 hex of arbitrary bytes.
    public static func hashHex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The short form shown in the UI and CLI listings.
    public static func short(_ cid: String) -> String {
        String(cid.prefix(8))
    }

    /// Whether a string looks like a CID this store would have minted.
    public static func isValid(_ cid: String) -> Bool {
        cid.count == 64 && cid.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
