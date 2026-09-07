import Foundation

/// A parse failure with a source position, so the app can put a caret on the
/// offending character in its JSON editor.
public struct JSONParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public let line: Int
    public let column: Int
    public let message: String

    public init(line: Int, column: Int, message: String) {
        self.line = line
        self.column = column
        self.message = message
    }

    public var description: String { "line \(line), column \(column): \(message)" }
}

/// A recursive-descent JSON parser producing ``JSONValue``.
public enum JSONParser {

    public static func parse(_ text: String) throws -> JSONValue {
        var scanner = Scanner(Array(text.unicodeScalars))
        scanner.skipWhitespace()
        let value = try scanner.parseValue()
        scanner.skipWhitespace()
        guard scanner.isAtEnd else {
            throw scanner.error("unexpected trailing content")
        }
        return value
    }

    public static func parse(contentsOf url: URL) throws -> JSONValue {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    // MARK: - Scanner

    private struct Scanner {
        private let scalars: [Unicode.Scalar]
        private var index: Int = 0
        private var line: Int = 1
        private var column: Int = 1
        /// Guards against stack exhaustion on adversarially nested input.
        private var depth: Int = 0
        private static let maximumDepth = 128

        init(_ scalars: [Unicode.Scalar]) {
            self.scalars = scalars
        }

        var isAtEnd: Bool { index >= scalars.count }

        func error(_ message: String) -> JSONParseError {
            JSONParseError(line: line, column: column, message: message)
        }

        private var current: Unicode.Scalar? {
            index < scalars.count ? scalars[index] : nil
        }

        private mutating func advance() {
            guard index < scalars.count else { return }
            if scalars[index] == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
            index += 1
        }

        mutating func skipWhitespace() {
            while let c = current, c == " " || c == "\t" || c == "\n" || c == "\r" {
                advance()
            }
        }

        private mutating func expect(_ scalar: Unicode.Scalar) throws {
            guard current == scalar else {
                throw error("expected '\(scalar)' but found \(describeCurrent())")
            }
            advance()
        }

        private func describeCurrent() -> String {
            guard let c = current else { return "end of input" }
            return "'\(String(c))'"
        }

        mutating func parseValue() throws -> JSONValue {
            guard let c = current else { throw error("unexpected end of input") }
            switch c {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"": return .string(try parseString())
            case "t", "f": return .bool(try parseBool())
            case "n":
                try parseLiteral("null")
                return .null
            default:
                if c == "-" || (c >= "0" && c <= "9") { return .number(try parseNumber()) }
                throw error("unexpected \(describeCurrent())")
            }
        }

        private mutating func enterContainer() throws {
            depth += 1
            guard depth <= Self.maximumDepth else {
                throw error("nesting deeper than \(Self.maximumDepth) levels")
            }
        }

        private mutating func parseObject() throws -> JSONValue {
            try enterContainer()
            defer { depth -= 1 }
            try expect("{")
            skipWhitespace()
            var members: [JSONValue.Member] = []
            if current == "}" {
                advance()
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard current == "\"" else {
                    throw error("expected a quoted key but found \(describeCurrent())")
                }
                let key = try parseString()
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                let value = try parseValue()
                members.append(.init(key: key, value: value))
                skipWhitespace()
                if current == "," {
                    advance()
                    continue
                }
                if current == "}" {
                    advance()
                    return .object(members)
                }
                throw error("expected ',' or '}' but found \(describeCurrent())")
            }
        }

        private mutating func parseArray() throws -> JSONValue {
            try enterContainer()
            defer { depth -= 1 }
            try expect("[")
            skipWhitespace()
            var elements: [JSONValue] = []
            if current == "]" {
                advance()
                return .array(elements)
            }
            while true {
                skipWhitespace()
                elements.append(try parseValue())
                skipWhitespace()
                if current == "," {
                    advance()
                    continue
                }
                if current == "]" {
                    advance()
                    return .array(elements)
                }
                throw error("expected ',' or ']' but found \(describeCurrent())")
            }
        }

        private mutating func parseString() throws -> String {
            try expect("\"")
            var result = String.UnicodeScalarView()
            while true {
                guard let c = current else { throw error("unterminated string") }
                if c == "\"" {
                    advance()
                    return String(result)
                }
                if c == "\\" {
                    advance()
                    result.append(try parseEscape())
                    continue
                }
                if c.value < 0x20 {
                    throw error("unescaped control character U+\(String(c.value, radix: 16))")
                }
                result.append(c)
                advance()
            }
        }

        private mutating func parseEscape() throws -> Unicode.Scalar {
            guard let c = current else { throw error("unterminated escape") }
            advance()
            switch c {
            case "\"": return "\""
            case "\\": return "\\"
            case "/": return "/"
            case "b": return Unicode.Scalar(0x08)!
            case "f": return Unicode.Scalar(0x0C)!
            case "n": return "\n"
            case "r": return "\r"
            case "t": return "\t"
            case "u": return try parseUnicodeEscape()
            default: throw error("invalid escape '\\\(String(c))'")
            }
        }

        private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
            let first = try parseHexQuad()
            // A high surrogate must be followed by \uDC00-\uDFFF to form one scalar.
            if first >= 0xD800 && first <= 0xDBFF {
                guard current == "\\" else { throw error("unpaired high surrogate") }
                advance()
                guard current == "u" else { throw error("unpaired high surrogate") }
                advance()
                let second = try parseHexQuad()
                guard second >= 0xDC00 && second <= 0xDFFF else {
                    throw error("invalid low surrogate")
                }
                let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                guard let scalar = Unicode.Scalar(combined) else {
                    throw error("invalid surrogate pair")
                }
                return scalar
            }
            guard let scalar = Unicode.Scalar(first) else {
                throw error("invalid unicode escape")
            }
            return scalar
        }

        private mutating func parseHexQuad() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0 ..< 4 {
                guard let c = current, let digit = c.hexDigitValue else {
                    throw error("expected four hex digits after \\u")
                }
                value = value << 4 | UInt32(digit)
                advance()
            }
            return value
        }

        private mutating func parseBool() throws -> Bool {
            if current == "t" {
                try parseLiteral("true")
                return true
            }
            try parseLiteral("false")
            return false
        }

        private mutating func parseLiteral(_ literal: String) throws {
            for scalar in literal.unicodeScalars {
                guard current == scalar else {
                    throw error("expected '\(literal)'")
                }
                advance()
            }
        }

        private mutating func parseNumber() throws -> String {
            var lexeme = String.UnicodeScalarView()

            func take() {
                lexeme.append(current!)
                advance()
            }

            func takeDigits() throws {
                guard let first = current, first >= "0" && first <= "9" else {
                    throw error("expected a digit but found \(describeCurrent())")
                }
                while let c = current, c >= "0" && c <= "9" { take() }
            }

            if current == "-" { take() }
            if current == "0" {
                take()
                if let c = current, c >= "0" && c <= "9" {
                    throw error("leading zeros are not allowed")
                }
            } else {
                try takeDigits()
            }
            if current == "." {
                take()
                try takeDigits()
            }
            if current == "e" || current == "E" {
                take()
                if current == "+" || current == "-" { take() }
                try takeDigits()
            }
            return String(lexeme)
        }
    }
}

extension Unicode.Scalar {
    fileprivate var hexDigitValue: UInt32? {
        switch self {
        case "0" ... "9": return value - 0x30
        case "a" ... "f": return value - 0x61 + 10
        case "A" ... "F": return value - 0x41 + 10
        default: return nil
        }
    }
}
