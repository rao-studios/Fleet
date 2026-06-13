import Foundation

/// Splits long text into training-sized chunks.
///
/// Frigate's `LoRABatchIterator` warns past ~2048 tokens, so decoders chunk on
/// paragraph boundaries with a character budget (a rough proxy for tokens) and
/// hard-split any single oversized paragraph.
public enum TextChunker {

    public static func chunk(_ text: String, maxChars: Int = 2000) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > maxChars else { return [trimmed] }

        var chunks: [String] = []
        var current = ""

        for rawParagraph in trimmed.components(separatedBy: "\n\n") {
            let paragraph = rawParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paragraph.isEmpty else { continue }

            if paragraph.count > maxChars {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                chunks.append(contentsOf: hardSplit(paragraph, maxChars: maxChars))
                continue
            }

            if current.isEmpty {
                current = paragraph
            } else if current.count + 2 + paragraph.count <= maxChars {
                current += "\n\n" + paragraph
            } else {
                chunks.append(current)
                current = paragraph
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private static func hardSplit(_ string: String, maxChars: Int) -> [String] {
        var result: [String] = []
        var index = string.startIndex
        while index < string.endIndex {
            let end = string.index(index, offsetBy: maxChars, limitedBy: string.endIndex) ?? string.endIndex
            result.append(String(string[index ..< end]))
            index = end
        }
        return result
    }
}
