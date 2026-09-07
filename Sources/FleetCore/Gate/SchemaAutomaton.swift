import Foundation

/// The character-level state machine a gated decode walks.
///
/// A schema compiles into a list of segments: `literal` runs (braces, quoted keys,
/// colons, commas — everything the schema fixes), `slot` runs (the value positions
/// the model fills, constrained to the JSON type observed in training), and array
/// branch points (where the model chooses how many elements to emit). Decoding is
/// then "advance this machine one character at a time"; a token is admissible
/// exactly when every character it decodes to is admissible, which is what lets a
/// token like `",` cross a value→structure boundary without special cases.
public struct SchemaAutomaton: Sendable {

    /// A value position the model fills in. `null` needs no slot — it is emitted
    /// as a literal — so it never appears here.
    public enum SlotKind: String, Sendable, Equatable {
        case string
        case number
        case bool
    }

    public enum Segment: Sendable, Equatable {
        case literal(String)
        case slot(kind: SlotKind, path: String)
        /// Sits right after `[`: either the array closes immediately, or the first
        /// element begins (the character is delegated to `elementStart`).
        case arrayStart(elementStart: Int, exit: Int, path: String)
        /// Sits right after an element: `,` starts another, `]` closes the array.
        case arrayNext(elementStart: Int, exit: Int, path: String)
    }

    /// Position inside the machine. `Hashable` so logit masks can be cached per
    /// distinct state rather than recomputed every step.
    public struct State: Sendable, Equatable, Hashable {
        public var segment: Int
        /// Characters already emitted inside the current literal.
        public var literalOffset: Int
        /// Sub-state within the current slot.
        public var slot: SlotState

        public init(segment: Int, literalOffset: Int = 0, slot: SlotState = .none) {
            self.segment = segment
            self.literalOffset = literalOffset
            self.slot = slot
        }
    }

    public enum SlotState: Sendable, Equatable, Hashable {
        case none
        // string
        case stringBody
        case stringEscape
        case stringUnicode(Int)  // hex digits consumed so far, 0..<4
        // number
        case numberAfterSign
        /// A leading `0`, which JSON forbids following with more digits.
        case numberLeadingZero
        case numberInt
        case numberAfterDot
        case numberFraction
        case numberExponentStart
        case numberExponentSign
        case numberExponent
        // bool
        case boolPrefix(String)
    }

    public let segments: [Segment]

    public init(schema: SchemaTemplate) {
        var builder = Builder()
        builder.emit(node: schema.root, path: "$")
        builder.flushLiteral()
        self.segments = builder.segments
    }

    public var initialState: State { State(segment: 0) }

    /// The machine accepts once it has run off the end of the segment list.
    public func isAccepting(_ state: State) -> Bool {
        state.segment >= segments.count
    }

    /// The location description shown in the debugger trace.
    public func path(of state: State) -> String {
        guard state.segment < segments.count else { return "$ (complete)" }
        switch segments[state.segment] {
        case .literal(let text):
            let remaining = String(text.dropFirst(state.literalOffset))
            return "structure \(JSONCanonical.quoted(remaining))"
        case .slot(let kind, let path):
            return "\(path) (\(kind.rawValue))"
        case .arrayStart(_, _, let path):
            return "\(path) (first element or close)"
        case .arrayNext(_, _, let path):
            return "\(path) (next element or close)"
        }
    }

    // MARK: - Transition

    /// Advance one character. Returns `nil` when the character is not admissible.
    public func advance(_ state: State, _ scalar: Unicode.Scalar) -> State? {
        guard state.segment < segments.count else { return nil }
        switch segments[state.segment] {
        case .literal(let text):
            let scalars = Array(text.unicodeScalars)
            guard state.literalOffset < scalars.count,
                scalars[state.literalOffset] == scalar
            else { return nil }
            let offset = state.literalOffset + 1
            if offset == scalars.count {
                return State(segment: state.segment + 1)
            }
            return State(segment: state.segment, literalOffset: offset)

        case .slot(let kind, _):
            return advanceSlot(state, kind: kind, scalar: scalar)

        case .arrayStart(let elementStart, let exit, _):
            if scalar == "]" { return State(segment: exit) }
            return advance(State(segment: elementStart), scalar)

        case .arrayNext(let elementStart, let exit, _):
            if scalar == "," { return State(segment: elementStart) }
            if scalar == "]" { return State(segment: exit) }
            return nil
        }
    }

    private func advanceSlot(_ state: State, kind: SlotKind, scalar: Unicode.Scalar) -> State? {
        func stay(_ slot: SlotState) -> State {
            State(segment: state.segment, slot: slot)
        }
        func exitSlot() -> State {
            State(segment: state.segment + 1)
        }

        switch kind {
        case .string:
            // The opening quote belongs to the preceding literal, so the slot
            // starts in the body; the closing quote ends it.
            switch state.slot {
            case .none, .stringBody:
                if scalar == "\"" { return exitSlot() }
                if scalar == "\\" { return stay(.stringEscape) }
                if scalar.value < 0x20 { return nil }
                return stay(.stringBody)
            case .stringEscape:
                switch scalar {
                case "\"", "\\", "/", "b", "f", "n", "r", "t": return stay(.stringBody)
                case "u": return stay(.stringUnicode(0))
                default: return nil
                }
            case .stringUnicode(let consumed):
                guard scalar.isHexDigitScalar else { return nil }
                return consumed == 3 ? stay(.stringBody) : stay(.stringUnicode(consumed + 1))
            default:
                return nil
            }

        case .number:
            // A number has no terminator of its own: it ends when the following
            // segment's first character arrives, so those transitions delegate.
            func terminate() -> State? {
                advance(State(segment: state.segment + 1), scalar)
            }
            let isDigit = scalar.isASCIIDigit
            switch state.slot {
            case .none:
                if scalar == "-" { return stay(.numberAfterSign) }
                if scalar == "0" { return stay(.numberLeadingZero) }
                return isDigit ? stay(.numberInt) : nil
            case .numberAfterSign:
                if scalar == "0" { return stay(.numberLeadingZero) }
                return isDigit ? stay(.numberInt) : nil
            case .numberLeadingZero:
                // `01` is not valid JSON, so a digit here is a dead end.
                if isDigit { return nil }
                if scalar == "." { return stay(.numberAfterDot) }
                if scalar == "e" || scalar == "E" { return stay(.numberExponentStart) }
                return terminate()
            case .numberInt:
                if isDigit { return stay(.numberInt) }
                if scalar == "." { return stay(.numberAfterDot) }
                if scalar == "e" || scalar == "E" { return stay(.numberExponentStart) }
                return terminate()
            case .numberAfterDot:
                return isDigit ? stay(.numberFraction) : nil
            case .numberFraction:
                if isDigit { return stay(.numberFraction) }
                if scalar == "e" || scalar == "E" { return stay(.numberExponentStart) }
                return terminate()
            case .numberExponentStart:
                if scalar == "+" || scalar == "-" { return stay(.numberExponentSign) }
                return isDigit ? stay(.numberExponent) : nil
            case .numberExponentSign:
                return isDigit ? stay(.numberExponent) : nil
            case .numberExponent:
                if isDigit { return stay(.numberExponent) }
                return terminate()
            default:
                return nil
            }

        case .bool:
            let prefix: String
            if case .boolPrefix(let existing) = state.slot { prefix = existing } else { prefix = "" }
            let candidate = prefix + String(scalar)
            guard "true".hasPrefix(candidate) || "false".hasPrefix(candidate) else { return nil }
            if candidate == "true" || candidate == "false" { return exitSlot() }
            return stay(.boolPrefix(candidate))
        }
    }

    // MARK: - Admissible characters (used to prune the token trie)

    public enum AdmissibleSet: Sendable {
        case none
        case only([Unicode.Scalar])
        /// Any scalar except controls, plus the listed terminators — a string body.
        case anyPrintable(terminators: [Unicode.Scalar])
    }

    public func admissibleScalars(_ state: State) -> AdmissibleSet {
        guard state.segment < segments.count else { return .none }
        switch segments[state.segment] {
        case .literal(let text):
            let scalars = Array(text.unicodeScalars)
            guard state.literalOffset < scalars.count else { return .none }
            return .only([scalars[state.literalOffset]])

        case .slot(let kind, _):
            switch (kind, state.slot) {
            case (.string, .stringEscape):
                return .only(Array("\"\\/bfnrtu".unicodeScalars))
            case (.string, .stringUnicode):
                return .only(Array("0123456789abcdefABCDEF".unicodeScalars))
            case (.string, _):
                return .anyPrintable(terminators: ["\"", "\\"])
            case (.number, let slot):
                var scalars = Array("0123456789".unicodeScalars)
                switch slot {
                case .none:
                    scalars.append("-")
                case .numberLeadingZero:
                    // No more digits may follow a leading zero.
                    scalars = Array(".eE".unicodeScalars)
                    scalars.append(contentsOf: firstScalars(ofSegment: state.segment + 1))
                case .numberInt, .numberFraction, .numberExponent:
                    scalars.append(contentsOf: Array(".eE".unicodeScalars))
                    scalars.append(contentsOf: firstScalars(ofSegment: state.segment + 1))
                case .numberExponentStart:
                    scalars.append(contentsOf: Array("+-".unicodeScalars))
                default:
                    break
                }
                return .only(scalars)
            case (.bool, let slot):
                if case .boolPrefix(let prefix) = slot {
                    var next: [Unicode.Scalar] = []
                    for candidate in ["true", "false"] where candidate.hasPrefix(prefix) {
                        let index = candidate.index(candidate.startIndex, offsetBy: prefix.count)
                        if index < candidate.endIndex {
                            next.append(candidate.unicodeScalars[index])
                        }
                    }
                    return .only(next)
                }
                return .only(["t", "f"])
            }

        case .arrayStart(let elementStart, _, _):
            var scalars: [Unicode.Scalar] = ["]"]
            switch admissibleScalars(State(segment: elementStart)) {
            case .none:
                break
            case .only(let inner):
                scalars.append(contentsOf: inner)
            case .anyPrintable(let terminators):
                return .anyPrintable(terminators: terminators + scalars)
            }
            return .only(scalars)

        case .arrayNext:
            return .only([",", "]"])
        }
    }

    /// The characters that can start a given segment — needed to know how a
    /// number slot may be terminated.
    private func firstScalars(ofSegment index: Int) -> [Unicode.Scalar] {
        guard index < segments.count else { return [] }
        switch admissibleScalars(State(segment: index)) {
        case .none: return []
        case .only(let scalars): return scalars
        case .anyPrintable(let terminators): return terminators
        }
    }

    // MARK: - Compilation

    private struct Builder {
        var segments: [Segment] = []
        var pending = String()

        mutating func literal(_ text: String) { pending += text }

        mutating func flushLiteral() {
            guard !pending.isEmpty else { return }
            segments.append(.literal(pending))
            pending = ""
        }

        mutating func slot(_ kind: SlotKind, path: String) {
            flushLiteral()
            segments.append(.slot(kind: kind, path: path))
        }

        mutating func emit(node: SchemaNode, path: String) {
            switch node {
            case .object(let entries):
                literal("{")
                for (index, entry) in entries.enumerated() {
                    if index > 0 { literal(",") }
                    literal(JSONCanonical.quoted(entry.key))
                    literal(":")
                    emit(node: entry.node, path: "\(path).\(entry.key)")
                }
                literal("}")

            case .array(let element, _, _):
                let elementPath = "\(path)[]"
                literal("[")
                flushLiteral()
                let startIndex = segments.count
                segments.append(
                    .arrayStart(elementStart: startIndex + 1, exit: 0, path: elementPath))
                emit(node: element, path: elementPath)
                flushLiteral()
                let nextIndex = segments.count
                segments.append(
                    .arrayNext(
                        elementStart: startIndex + 1, exit: nextIndex + 1, path: elementPath))
                // Both branch points leave the array at the same place: the
                // segment following `arrayNext`, which is whatever the enclosing
                // structure emits next.
                segments[startIndex] = .arrayStart(
                    elementStart: startIndex + 1, exit: nextIndex + 1, path: elementPath)

            case .string:
                literal("\"")
                slot(.string, path: path)

            case .number:
                slot(.number, path: path)

            case .bool:
                slot(.bool, path: path)

            case .null:
                literal("null")
            }
        }
    }
}

extension Unicode.Scalar {
    fileprivate var isHexDigitScalar: Bool {
        (self >= "0" && self <= "9") || (self >= "a" && self <= "f")
            || (self >= "A" && self <= "F")
    }

    fileprivate var isASCIIDigit: Bool {
        self >= "0" && self <= "9"
    }
}
