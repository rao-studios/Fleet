import Foundation

/// The one canonical JSON text form in Fleet.
///
/// Three consumers depend on this being byte-for-byte stable: the CID hash of a
/// dataset's input set, the training text a LoRA learns to reproduce, and the
/// literal segments the decoding gate forces token by token. If any of the three
/// disagreed on spacing or key order, a LoRA would be trained on text the gate
/// then refuses to emit.
///
/// The rules:
/// - No whitespace anywhere: `{"a":1,"b":[true,"x"]}`.
/// - Object keys sorted by UTF-8 byte order.
/// - Strings escape only `"`, `\`, and control characters below U+0020; every
///   other scalar is emitted literally as UTF-8.
/// - Numbers normalized: integral magnitudes below 2^53 print as plain integers
///   (no `.0`, no exponent, `-0` becomes `0`); everything else uses Swift's
///   shortest round-trip `Double` form.
public enum JSONCanonical {

    public static func serialize(_ value: JSONValue) -> String {
        var out = String()
        write(value, into: &out)
        return out
    }

    public static func data(_ value: JSONValue) -> Data {
        Data(serialize(value).utf8)
    }

    private static func write(_ value: JSONValue, into out: inout String) {
        switch value {
        case .object(let members):
            out.append("{")
            // Sort by UTF-8 bytes, not by Swift's locale-independent-but-grapheme
            // based `<`, so ordering matches what a byte-level consumer would do.
            let sorted = members.sorted { lhs, rhs in
                Array(lhs.key.utf8).lexicographicallyPrecedes(Array(rhs.key.utf8))
            }
            for (index, member) in sorted.enumerated() {
                if index > 0 { out.append(",") }
                writeString(member.key, into: &out)
                out.append(":")
                write(member.value, into: &out)
            }
            out.append("}")

        case .array(let elements):
            out.append("[")
            for (index, element) in elements.enumerated() {
                if index > 0 { out.append(",") }
                write(element, into: &out)
            }
            out.append("]")

        case .string(let text):
            writeString(text, into: &out)

        case .number(let lexeme):
            out.append(normalizedNumber(lexeme))

        case .bool(let flag):
            out.append(flag ? "true" : "false")

        case .null:
            out.append("null")
        }
    }

    /// Escape and quote a string using the canonical (minimal) escape set.
    public static func quoted(_ text: String) -> String {
        var out = String()
        writeString(text, into: &out)
        return out
    }

    private static func writeString(_ text: String, into out: inout String) {
        out.append("\"")
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case Unicode.Scalar(0x08)!: out.append("\\b")
            case Unicode.Scalar(0x0C)!: out.append("\\f")
            default:
                if scalar.value < 0x20 {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append("\"")
    }

    /// Normalize a raw number lexeme to its canonical spelling.
    public static func normalizedNumber(_ lexeme: String) -> String {
        guard let value = Double(lexeme) else { return lexeme }
        return numberLexeme(value)
    }

    /// The canonical spelling of a numeric value.
    public static func numberLexeme(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == 0 { return "0" }  // also folds -0 into 0
        if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        return String(value)
    }
}
