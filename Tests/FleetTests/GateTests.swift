import XCTest

@testable import FleetCore

/// A small hand-built vocabulary standing in for a real tokenizer.
///
/// It deliberately includes multi-character tokens that straddle the boundary
/// between a value and the structure after it (`",`, `":`, `"}`), because those
/// are exactly the tokens a naive gate mishandles.
enum FakeVocab {

    static let texts: [String?] = {
        var texts: [String?] = []
        // 0: a special token the gate must never pick.
        texts.append(nil)
        // Single printable ASCII characters.
        for value in 0x20 ... 0x7E {
            texts.append(String(Unicode.Scalar(UInt32(value))!))
        }
        // Multi-character tokens, including boundary-crossing ones.
        texts.append(contentsOf: [
            "true", "false", "null",
            "\",", "\":", "\"}", "\"]", "\":\"", ",\"", "},", "}]",
            "hello", "world", "ok", "warm", "cold",
            "12", "34", "100", ".5", "-1",
        ])
        return texts
    }()

    static let vocabulary = ArrayTokenVocabulary(texts)

    static func id(of text: String) -> Int {
        texts.firstIndex(of: text) ?? -1
    }

    static func text(of id: Int) -> String {
        texts[id] ?? "<special>"
    }
}

final class SchemaAutomatonTests: XCTestCase {

    private func template(_ outputJSON: String) throws -> SchemaTemplate {
        try SchemaExtractor.template(outputs: [try JSONParser.parse(outputJSON)])
    }

    /// Walk the automaton over a literal string, character by character.
    private func walk(_ automaton: SchemaAutomaton, _ text: String) -> SchemaAutomaton.State? {
        var state = automaton.initialState
        for scalar in text.unicodeScalars {
            guard let next = automaton.advance(state, scalar) else { return nil }
            state = next
        }
        return state
    }

    func testAcceptsCanonicalOutputOfTheSameShape() throws {
        let schema = try template(#"{"a":"x","b":1,"c":true}"#)
        let automaton = SchemaAutomaton(schema: schema)
        let state = walk(automaton, #"{"a":"hello","b":42,"c":false}"#)
        XCTAssertNotNil(state)
        XCTAssertTrue(automaton.isAccepting(state!))
    }

    func testRejectsWrongKey() throws {
        let schema = try template(#"{"a":"x"}"#)
        let automaton = SchemaAutomaton(schema: schema)
        XCTAssertNil(walk(automaton, #"{"z":"hello"}"#))
    }

    func testRejectsWrongValueType() throws {
        let schema = try template(#"{"n":1}"#)
        let automaton = SchemaAutomaton(schema: schema)
        // A quote cannot start a number slot.
        XCTAssertNil(walk(automaton, #"{"n":"text"}"#))
    }

    func testKeysAreEmittedInCanonicalOrder() throws {
        let schema = try template(#"{"b":1,"a":2}"#)
        let automaton = SchemaAutomaton(schema: schema)
        XCTAssertNotNil(walk(automaton, #"{"a":9,"b":8}"#))
        XCTAssertNil(walk(automaton, #"{"b":8,"a":9}"#))
    }

    func testArrayLengthIsFreeButElementTypeIsNot() throws {
        let schema = try template(#"{"xs":["a"]}"#)
        let automaton = SchemaAutomaton(schema: schema)
        for candidate in [#"{"xs":[]}"#, #"{"xs":["p"]}"#, #"{"xs":["p","q","r"]}"#] {
            let state = walk(automaton, candidate)
            XCTAssertNotNil(state, "\(candidate) should be accepted")
            XCTAssertTrue(automaton.isAccepting(state!))
        }
        XCTAssertNil(walk(automaton, #"{"xs":[1]}"#))
    }

    func testNestedObjectsAndArrays() throws {
        let schema = try template(#"{"o":{"p":[{"q":1}]}}"#)
        let automaton = SchemaAutomaton(schema: schema)
        let state = walk(automaton, #"{"o":{"p":[{"q":1},{"q":2}]}}"#)
        XCTAssertNotNil(state)
        XCTAssertTrue(automaton.isAccepting(state!))
    }

    func testNumberGrammar() throws {
        let schema = try template(#"{"n":1}"#)
        let automaton = SchemaAutomaton(schema: schema)
        for good in ["-1", "0", "12", "1.5", "1e3", "-2.5E-4"] {
            XCTAssertNotNil(walk(automaton, #"{"n":\#(good)}"#), "\(good) should parse")
        }
        for bad in ["01", "1.", ".5", "+1", "1e", "--1"] {
            XCTAssertNil(walk(automaton, #"{"n":\#(bad)}"#), "\(bad) should be rejected")
        }
    }

    func testStringEscapesAreHandled() throws {
        let schema = try template(#"{"s":"x"}"#)
        let automaton = SchemaAutomaton(schema: schema)
        XCTAssertNotNil(walk(automaton, #"{"s":"a\"b"}"#))
        XCTAssertNotNil(walk(automaton, #"{"s":"aéb"}"#))
        XCTAssertNil(walk(automaton, #"{"s":"a\qb"}"#))
    }

    func testBooleanSlotOnlyAcceptsTrueOrFalse() throws {
        let schema = try template(#"{"b":true}"#)
        let automaton = SchemaAutomaton(schema: schema)
        XCTAssertNotNil(walk(automaton, #"{"b":true}"#))
        XCTAssertNotNil(walk(automaton, #"{"b":false}"#))
        XCTAssertNil(walk(automaton, #"{"b":tru}"#))
        XCTAssertNil(walk(automaton, #"{"b":yes}"#))
    }

    func testNullIsForcedStructureNotAFreeSlot() throws {
        let schema = try template(#"{"z":null}"#)
        let automaton = SchemaAutomaton(schema: schema)
        XCTAssertNotNil(walk(automaton, #"{"z":null}"#))
        XCTAssertNil(walk(automaton, #"{"z":1}"#))
    }
}

final class JSONGateTests: XCTestCase {

    private func gate(_ outputJSON: String) throws -> JSONGate {
        let schema = try SchemaExtractor.template(outputs: [try JSONParser.parse(outputJSON)])
        return JSONGate(schema: schema, vocabulary: FakeVocab.vocabulary)
    }

    func testStructureIsForcedAndValuesAreFree() throws {
        let gate = try gate(#"{"a":"x"}"#)
        // The very first decision is structural: nothing is sampled.
        guard case .forced(_, let text) = gate.decision(for: gate.initialState) else {
            return XCTFail("expected the opening brace to be forced")
        }
        XCTAssertTrue(#"{"a":""#.hasPrefix(text))
    }

    func testSpecialTokensAreNeverAdmissible() throws {
        let gate = try gate(#"{"a":"x"}"#)
        var state = gate.initialState
        var guardCount = 0
        while case .forced(_, let text) = gate.decision(for: state), guardCount < 20 {
            state = gate.consume(state, text: text)!
            guardCount += 1
        }
        guard case .free(let allowed) = gate.decision(for: state) else {
            return XCTFail("expected a free string slot")
        }
        XCTAssertFalse(allowed.contains(0), "the special token leaked into a mask")
        XCTAssertFalse(allowed.isEmpty)
    }

    func testBoundaryCrossingTokenIsAdmissible() throws {
        // `",` closes a string value and opens the next key in one token.
        let gate = try gate(#"{"a":"x","b":"y"}"#)
        var state = gate.initialState
        // Advance through the structure and one character of the first value.
        state = gate.consume(state, text: #"{"a":""#)!
        state = gate.consume(state, text: "o")!
        guard case .free(let allowed) = gate.decision(for: state) else {
            return XCTFail("expected a free slot inside the string")
        }
        XCTAssertTrue(
            allowed.contains(FakeVocab.id(of: "\",")),
            "a token spanning the value→structure boundary should be allowed"
        )
        let next = gate.consume(state, text: "\",")
        XCTAssertNotNil(next, "consuming the boundary token should advance the machine")
    }

    func testGreedyForcedRunUsesLongTokensWhereAvailable() throws {
        let gate = try gate(#"{"a":"x"}"#)
        var state = gate.initialState
        var emitted: [String] = []
        while case .forced(_, let text) = gate.decision(for: state) {
            emitted.append(text)
            state = gate.consume(state, text: text)!
        }
        // The opening structure was emitted, and multi-character tokens were used
        // where the vocabulary had them.
        XCTAssertEqual(emitted.joined(), #"{"a":""#)
        XCTAssertLessThan(emitted.count, #"{"a":""#.count)
    }

    func testFullRunProducesSchemaValidJSON() throws {
        let source = #"{"summary":"x","score":1,"ok":true,"tags":["a"]}"#
        let schema = try SchemaExtractor.template(outputs: [try JSONParser.parse(source)])
        let gate = JSONGate(schema: schema, vocabulary: FakeVocab.vocabulary)

        // A deterministic "model": always take the lowest admissible id that makes
        // progress, preferring to close strings and arrays so the run terminates.
        let result = try gate.run(maximumTokens: 400) { allowed, state in
            let closers = ["\"", "\"}", "\",", "\"]", "]"]
            for closer in closers {
                let id = FakeVocab.id(of: closer)
                if allowed.contains(id), gate.consume(state, text: closer) != nil { return id }
            }
            return allowed.min() ?? 0
        }

        let parsed = try JSONParser.parse(result.text)
        XCTAssertTrue(
            SchemaExtractor.validate(parsed, against: schema).isEmpty,
            "gated output \(result.text) did not match the schema"
        )
    }

    func testRunTerminatesAtAcceptance() throws {
        let gate = try gate(#"{"n":1}"#)
        let result = try gate.run(maximumTokens: 50) { allowed, state in
            // Close as soon as the number is complete; `}` is inadmissible until
            // at least one digit has been emitted, so this yields exactly one.
            for candidate in ["}", "7"] {
                let id = FakeVocab.id(of: candidate)
                if allowed.contains(id), gate.consume(state, text: candidate) != nil { return id }
            }
            return allowed.min() ?? 0
        }
        XCTAssertEqual(result.text, #"{"n":7}"#)
    }

    func testEveryMockDomainSchemaIsGateable() throws {
        for domain in MockDomain.allCases {
            let pairs = MockDatasetGenerator.generate(domain: domain, count: 20, seed: 5)
            let schema = try SchemaExtractor.template(outputs: pairs.map(\.output))
            let automaton = SchemaAutomaton(schema: schema)
            // Every real output of the domain must be walkable by its own gate.
            for pair in pairs {
                var state = automaton.initialState
                let text = JSONCanonical.serialize(pair.output)
                var ok = true
                for scalar in text.unicodeScalars {
                    guard let next = automaton.advance(state, scalar) else {
                        ok = false
                        break
                    }
                    state = next
                }
                XCTAssertTrue(
                    ok && automaton.isAccepting(state),
                    "\(domain): the gate rejected its own training output \(text)"
                )
            }
        }
    }
}
