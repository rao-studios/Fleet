import FleetCore
import Foundation

/// Plain text files.
public struct PlainTextDecoder: MediaDecoder {
    public let maxChars: Int
    public init(maxChars: Int = 2000) { self.maxChars = maxChars }

    public var supportedExtensions: Set<String> { ["txt", "text", "log", "rst", "org", "tex"] }

    public func decode(_ url: URL) async throws -> [ContextFragment] {
        let text = try readString(url)
        return TextChunker.chunk(text, maxChars: maxChars).enumerated().map { index, chunk in
            ContextFragment(id: fragmentID(url, index), source: url, mediaType: .text, text: chunk)
        }
    }
}

/// Markdown — split on headings, then by character budget.
public struct MarkdownDecoder: MediaDecoder {
    public let maxChars: Int
    public init(maxChars: Int = 2000) { self.maxChars = maxChars }

    public var supportedExtensions: Set<String> { ["md", "markdown", "mdown", "mkd", "mdx"] }

    public func decode(_ url: URL) async throws -> [ContextFragment] {
        let text = try readString(url)
        var fragments: [ContextFragment] = []
        var index = 0
        for section in Self.splitIntoSections(text) {
            for chunk in TextChunker.chunk(section, maxChars: maxChars) {
                fragments.append(
                    ContextFragment(id: fragmentID(url, index), source: url, mediaType: .text, text: chunk))
                index += 1
            }
        }
        return fragments
    }

    static func splitIntoSections(_ text: String) -> [String] {
        var sections: [String] = []
        var current: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("#") && !current.isEmpty {
                sections.append(current.joined(separator: "\n"))
                current = [line]
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { sections.append(current.joined(separator: "\n")) }
        return sections
    }
}

/// Source code — fenced with a language hint so the LLM sees structured code.
public struct CodeDecoder: MediaDecoder {
    public let maxChars: Int
    public init(maxChars: Int = 2000) { self.maxChars = maxChars }

    static let languages: [String: String] = [
        "swift": "swift", "py": "python", "js": "javascript", "ts": "typescript",
        "tsx": "tsx", "jsx": "jsx", "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp",
        "hpp": "cpp", "go": "go", "rs": "rust", "java": "java", "rb": "ruby",
        "sh": "bash", "bash": "bash", "zsh": "bash", "kt": "kotlin", "m": "objectivec",
        "mm": "objectivec", "cs": "csharp", "php": "php", "scala": "scala", "sql": "sql",
        "yaml": "yaml", "yml": "yaml", "toml": "toml",
    ]

    public var supportedExtensions: Set<String> { Set(Self.languages.keys) }

    public func decode(_ url: URL) async throws -> [ContextFragment] {
        let text = try readString(url)
        let language = Self.languages[url.pathExtension.lowercased()] ?? ""
        return TextChunker.chunk(text, maxChars: maxChars).enumerated().map { index, chunk in
            ContextFragment(
                id: fragmentID(url, index),
                source: url,
                mediaType: .code,
                text: "```\(language)\n\(chunk)\n```",
                metadata: ["language": language]
            )
        }
    }
}

/// JSON and JSON Lines.
public struct JSONFleetDecoder: MediaDecoder {
    public let maxChars: Int
    public init(maxChars: Int = 2000) { self.maxChars = maxChars }

    public var supportedExtensions: Set<String> { ["json", "jsonl", "ndjson"] }

    public func decode(_ url: URL) async throws -> [ContextFragment] {
        let text = try readString(url)
        let ext = url.pathExtension.lowercased()

        if ext == "jsonl" || ext == "ndjson" {
            return text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .enumerated()
                .map { index, line in
                    ContextFragment(id: fragmentID(url, index), source: url, mediaType: .text, text: line)
                }
        }

        let pretty = Self.prettyPrinted(text) ?? text
        return TextChunker.chunk(pretty, maxChars: maxChars).enumerated().map { index, chunk in
            ContextFragment(id: fragmentID(url, index), source: url, mediaType: .text, text: chunk)
        }
    }

    static func prettyPrinted(_ text: String) -> String? {
        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let out = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(decoding: out, as: UTF8.self)
    }
}

/// CSV / TSV — flatten each row into `column: value` text.
public struct CSVDecoder: MediaDecoder {
    public let maxChars: Int
    public init(maxChars: Int = 2000) { self.maxChars = maxChars }

    public var supportedExtensions: Set<String> { ["csv", "tsv"] }

    public func decode(_ url: URL) async throws -> [ContextFragment] {
        let separator: Character = url.pathExtension.lowercased() == "tsv" ? "\t" : ","
        let text = try readString(url)
        var rows = text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !rows.isEmpty else { return [] }

        let header = rows.removeFirst()
            .split(separator: separator, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let lines = rows.map { row -> String in
            let columns = row.split(separator: separator, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return zip(header, columns).map { "\($0): \($1)" }.joined(separator: ", ")
        }

        return TextChunker.chunk(lines.joined(separator: "\n"), maxChars: maxChars)
            .enumerated().map { index, chunk in
                ContextFragment(id: fragmentID(url, index), source: url, mediaType: .table, text: chunk)
            }
    }
}
