import XCTest

@testable import FleetCore

// MARK: - Canonical JSON

final class JSONCanonicalTests: XCTestCase {

    func testKeysAreSortedAndWhitespaceRemoved() throws {
        let value = try JSONParser.parse(#"{ "b": 1, "a": { "d": 2, "c": 3 } }"#)
        XCTAssertEqual(JSONCanonical.serialize(value), #"{"a":{"c":3,"d":2},"b":1}"#)
    }

    func testNumberNormalization() {
        XCTAssertEqual(JSONCanonical.normalizedNumber("1.0"), "1")
        XCTAssertEqual(JSONCanonical.normalizedNumber("1.50"), "1.5")
        XCTAssertEqual(JSONCanonical.normalizedNumber("-0"), "0")
        XCTAssertEqual(JSONCanonical.normalizedNumber("1e2"), "100")
        XCTAssertEqual(JSONCanonical.normalizedNumber("0.25"), "0.25")
    }

    func testStringEscaping() {
        XCTAssertEqual(JSONCanonical.quoted("a\"b\\c"), #""a\"b\\c""#)
        XCTAssertEqual(JSONCanonical.quoted("line\nbreak"), #""line\nbreak""#)
        // Non-ASCII stays literal rather than being \u-escaped.
        XCTAssertEqual(JSONCanonical.quoted("café"), "\"café\"")
    }

    func testRoundTripThroughParser() throws {
        let source = #"{"a":[1,2.5,true,null,"x"],"b":{"c":"d"}}"#
        let parsed = try JSONParser.parse(source)
        XCTAssertEqual(JSONCanonical.serialize(parsed), source)
    }

    func testParseErrorCarriesPosition() {
        XCTAssertThrowsError(try JSONParser.parse("{\n  \"a\": ,\n}")) { error in
            guard let parseError = error as? JSONParseError else {
                return XCTFail("expected JSONParseError, got \(error)")
            }
            XCTAssertEqual(parseError.line, 2)
        }
    }

    func testRejectsTrailingContentAndDuplicatesAllowedByParser() throws {
        XCTAssertThrowsError(try JSONParser.parse("{} {}"))
        // The parser preserves duplicates; the schema extractor is what rejects them.
        let value = try JSONParser.parse(#"{"a":1,"a":2}"#)
        XCTAssertEqual(value.members?.count, 2)
    }

    func testUnicodeEscapesAndSurrogatePairs() throws {
        let value = try JSONParser.parse(#"{"a":"A😀"}"#)
        XCTAssertEqual(value["a"]?.stringValue, "A😀")
    }
}

// MARK: - Schema extraction

final class SchemaExtractionTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try JSONParser.parse(text)
    }

    func testExtractsKeysNestingAndTypes() throws {
        let outputs = [
            try json(#"{"name":"a","score":1,"ok":true,"tags":["x"]}"#),
            try json(#"{"name":"b","score":2.5,"ok":false,"tags":["y","z"]}"#),
        ]
        let template = try SchemaExtractor.template(outputs: outputs)
        XCTAssertEqual(
            template.description,
            #"{"name":string,"ok":boolean,"score":number,"tags":[string]}"#
        )
    }

    func testValuesAreIgnoredSoTemplateIsStable() throws {
        let a = try SchemaExtractor.template(outputs: [try json(#"{"k":"one"}"#)])
        let b = try SchemaExtractor.template(outputs: [try json(#"{"k":"totally different"}"#)])
        XCTAssertEqual(a.hashHex, b.hashHex)
    }

    func testTypeMismatchIsReportedWithIndexAndPath() throws {
        let outputs = [
            try json(#"{"a":{"b":1}}"#),
            try json(#"{"a":{"b":1}}"#),
            try json(#"{"a":{"b":"nope"}}"#),
        ]
        XCTAssertThrowsError(try SchemaExtractor.template(outputs: outputs)) { error in
            guard case SchemaExtractionError.mismatches(let errors) = error else {
                return XCTFail("expected mismatches, got \(error)")
            }
            XCTAssertEqual(errors.count, 1)
            XCTAssertEqual(errors[0].outputIndex, 2)
            XCTAssertEqual(errors[0].path, "$.a.b")
            XCTAssertEqual(errors[0].expected, "number")
            XCTAssertEqual(errors[0].found, "string")
        }
    }

    func testMissingAndExtraKeysAreReported() throws {
        let outputs = [
            try json(#"{"a":1,"b":2}"#),
            try json(#"{"a":1,"c":3}"#),
        ]
        XCTAssertThrowsError(try SchemaExtractor.template(outputs: outputs)) { error in
            guard case SchemaExtractionError.mismatches(let errors) = error else {
                return XCTFail("expected mismatches, got \(error)")
            }
            XCTAssertEqual(errors.count, 2)
            XCTAssertTrue(errors.contains { $0.path == "$.b" && $0.found.contains("missing") })
            XCTAssertTrue(errors.contains { $0.path == "$.c" && $0.found.contains("extra") })
        }
    }

    func testArrayLengthsMayVaryButElementTypesMayNot() throws {
        let ok = [
            try json(#"{"xs":[1]}"#),
            try json(#"{"xs":[1,2,3]}"#),
            try json(#"{"xs":[]}"#),
        ]
        let template = try SchemaExtractor.template(outputs: ok)
        XCTAssertEqual(template.description, #"{"xs":[number]}"#)

        let bad = [try json(#"{"xs":[1]}"#), try json(#"{"xs":["a"]}"#)]
        XCTAssertThrowsError(try SchemaExtractor.template(outputs: bad)) { error in
            guard case SchemaExtractionError.mismatches(let errors) = error else {
                return XCTFail("expected mismatches, got \(error)")
            }
            XCTAssertEqual(errors[0].path, "$.xs[]")
        }
    }

    func testEmptyArrayFirstStillLearnsElementType() throws {
        let outputs = [try json(#"{"xs":[]}"#), try json(#"{"xs":["a"]}"#)]
        let template = try SchemaExtractor.template(outputs: outputs)
        XCTAssertEqual(template.description, #"{"xs":[string]}"#)
    }

    func testNullIsAStrictTypeNotAnOptional() throws {
        let outputs = [try json(#"{"a":null}"#), try json(#"{"a":1}"#)]
        XCTAssertThrowsError(try SchemaExtractor.template(outputs: outputs))
    }

    func testRootMustBeAnObject() throws {
        XCTAssertThrowsError(try SchemaExtractor.template(outputs: [try json("[1,2]")])) { error in
            guard case SchemaExtractionError.rootNotObject = error else {
                return XCTFail("expected rootNotObject, got \(error)")
            }
        }
    }

    func testDuplicateKeysAreRejected() throws {
        XCTAssertThrowsError(
            try SchemaExtractor.template(outputs: [try json(#"{"a":1,"a":2}"#)])
        ) { error in
            guard case SchemaExtractionError.duplicateKey = error else {
                return XCTFail("expected duplicateKey, got \(error)")
            }
        }
    }
}

// MARK: - Content identity

final class ContentIDTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try JSONParser.parse(text)
    }

    func testSameInputsDifferentOutputsGiveTheSameCID() throws {
        let inputs = [try json(#"{"q":"a"}"#), try json(#"{"q":"b"}"#)]
        let first = ContentID.compute(inputs: inputs)
        let second = ContentID.compute(inputs: inputs)
        XCTAssertEqual(first, second)
        // The outputs are simply not part of the hash — that is the overwrite story.
        XCTAssertEqual(first.count, 64)
    }

    func testInputOrderDoesNotMatter() throws {
        let a = [try json(#"{"q":"a"}"#), try json(#"{"q":"b"}"#)]
        let b = [try json(#"{"q":"b"}"#), try json(#"{"q":"a"}"#)]
        XCTAssertEqual(ContentID.compute(inputs: a), ContentID.compute(inputs: b))
    }

    func testFormattingDoesNotMatter() throws {
        let a = [try json(#"{ "q" : "a" , "r" : 1.0 }"#)]
        let b = [try json(#"{"r":1,"q":"a"}"#)]
        XCTAssertEqual(ContentID.compute(inputs: a), ContentID.compute(inputs: b))
    }

    func testDifferentInputsGiveDifferentCIDs() throws {
        let a = [try json(#"{"q":"a"}"#)]
        let b = [try json(#"{"q":"c"}"#)]
        XCTAssertNotEqual(ContentID.compute(inputs: a), ContentID.compute(inputs: b))
    }

    func testStabilityVector() throws {
        // Pins the hash so an accidental change to canonicalization is caught.
        let cid = ContentID.compute(inputs: [try json(#"{"a":1}"#)])
        XCTAssertEqual(cid, ContentID.hashHex(of: Data(#"{"a":1}"#.utf8)))
        XCTAssertTrue(ContentID.isValid(cid))
    }
}

// MARK: - Mock data

final class MockDatasetTests: XCTestCase {

    func testGenerationIsDeterministic() {
        for domain in MockDomain.allCases {
            let first = MockDatasetGenerator.generate(domain: domain, count: 12, seed: 42)
            let second = MockDatasetGenerator.generate(domain: domain, count: 12, seed: 42)
            XCTAssertEqual(
                first.map { JSONCanonical.serialize($0.input) },
                second.map { JSONCanonical.serialize($0.input) },
                "\(domain) inputs drifted between runs"
            )
            XCTAssertEqual(
                first.map { JSONCanonical.serialize($0.output) },
                second.map { JSONCanonical.serialize($0.output) },
                "\(domain) outputs drifted between runs"
            )
            XCTAssertEqual(first.map(\.id), second.map(\.id))
        }
    }

    func testDifferentSeedsDiverge() {
        let a = MockDatasetGenerator.generate(domain: .orderTriage, count: 8, seed: 1)
        let b = MockDatasetGenerator.generate(domain: .orderTriage, count: 8, seed: 2)
        XCTAssertNotEqual(
            a.map { JSONCanonical.serialize($0.input) },
            b.map { JSONCanonical.serialize($0.input) }
        )
    }

    func testEveryDomainYieldsOneStrictSchema() throws {
        for domain in MockDomain.allCases {
            let pairs = MockDatasetGenerator.generate(domain: domain, count: 30, seed: 7)
            XCTAssertNoThrow(
                try SchemaExtractor.template(outputs: pairs.map(\.output)),
                "\(domain) produced outputs with inconsistent structure"
            )
        }
    }

    func testCIDIsStableAcrossRegeneration() {
        let a = MockDatasetGenerator.generate(domain: .deviceHealth, count: 10, seed: 99)
        let b = MockDatasetGenerator.generate(domain: .deviceHealth, count: 10, seed: 99)
        XCTAssertEqual(
            ContentID.compute(inputs: a.map(\.input)),
            ContentID.compute(inputs: b.map(\.input))
        )
    }
}

// MARK: - Prompt format

final class PromptBuilderTests: XCTestCase {

    func testInferencePromptIsAPrefixOfTrainingText() throws {
        let input = try JSONParser.parse(#"{"a":1}"#)
        let output = try JSONParser.parse(#"{"b":"x"}"#)
        let training = PromptBuilder.trainingText(input: input, output: output)
        let prompt = PromptBuilder.prompt(input: input)
        XCTAssertTrue(training.hasPrefix(prompt))
        XCTAssertEqual(String(training.dropFirst(prompt.count)), #"{"b":"x"}"#)
    }

    func testPromptEndsWhereGenerationStarts() throws {
        let prompt = PromptBuilder.prompt(input: try JSONParser.parse(#"{"a":1}"#))
        XCTAssertTrue(prompt.hasSuffix("OUTPUT:\n"))
    }
}
