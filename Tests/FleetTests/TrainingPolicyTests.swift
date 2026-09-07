import FleetCore
import FleetStore
import FleetTraining
import XCTest

/// Knobs sized to the corpus, and the gate a published adapter must clear.
final class TrainingPolicyTests: XCTestCase {

    // MARK: - Sizing

    func testASmallCorpusStillGetsEnoughSteps() {
        let config = TrainingConfig.forCorpus(pairCount: 24)
        XCTAssertEqual(config.iterations, 40)
        XCTAssertEqual(config.learningRate, 1e-4)
    }

    /// The fixed 200 iterations were about thirty-six passes over a
    /// twenty-four pair corpus. Four is the target.
    func testIterationsTrackEpochsOverTheCorpus() {
        let config = TrainingConfig.forCorpus(pairCount: 200, batchSize: 4, epochs: 4)
        XCTAssertEqual(config.iterations, 200)
    }

    func testAVeryLargeCorpusIsCapped() {
        XCTAssertEqual(TrainingConfig.forCorpus(pairCount: 10_000).iterations, 400)
    }

    func testReportingCadenceScalesWithTheRun() {
        let config = TrainingConfig.forCorpus(pairCount: 400)
        XCTAssertGreaterThanOrEqual(config.stepsPerReport, 1)
        XCTAssertLessThanOrEqual(config.stepsPerReport, config.iterations)
        XCTAssertLessThanOrEqual(config.stepsPerEval, config.iterations)
    }

    func testTheModelIdIsCarriedThrough() {
        XCTAssertEqual(
            TrainingConfig.forCorpus(pairCount: 24, modelId: "some/model").modelId,
            "some/model")
    }

    // MARK: - The held-out split

    func testHeldOutPairsAreNotAlsoTrainedOn() {
        let pairs = (0..<20).map { index in
            JSONPair(
                input: try! JSONParser.parse("{\"i\":\(index)}"),
                output: try! JSONParser.parse("{\"o\":\(index)}"))
        }
        let split = StateTrainer.splitPairs(pairs, validationFraction: 0.15)
        XCTAssertFalse(split.valid.isEmpty)
        let trainIDs = Set(split.train.map(\.id))
        for held in split.valid {
            XCTAssertFalse(trainIDs.contains(held.id))
        }
    }

    func testASinglePairIsNotSplitAway() {
        let empty = try! JSONParser.parse("{}")
        let pairs = [JSONPair(input: empty, output: empty)]
        let split = StateTrainer.splitPairs(pairs, validationFraction: 0.5)
        XCTAssertEqual(split.train.count, 1)
        XCTAssertTrue(split.valid.isEmpty)
    }

    func testTheSplitIsDeterministic() {
        let pairs = (0..<20).map { index in
            JSONPair(
                input: try! JSONParser.parse("{\"i\":\(index)}"),
                output: try! JSONParser.parse("{\"o\":\(index)}"))
        }
        let first = StateTrainer.splitPairs(pairs, validationFraction: 0.15)
        let second = StateTrainer.splitPairs(pairs, validationFraction: 0.15)
        XCTAssertEqual(first.valid.map(\.id), second.valid.map(\.id))
    }

    // MARK: - The ready gate

    private func entry(exactMatch: Double?, cases: Int = 10) -> LoRAEntry {
        LoRAEntry(
            cid: String(repeating: "a", count: 64),
            modelId: "m", schemaHash: "h", schemaDescription: "d",
            pairCount: 24, rank: 8, scale: 20, numLayers: 16, iterations: 40,
            evalExactMatch: exactMatch, evalCases: cases)
    }

    func testAnAdapterThatLearnedNothingIsNotReady() {
        XCTAssertFalse(entry(exactMatch: 0.1).passesReadyGate)
    }

    func testAnAdapterThatReproducesHeldOutPairsIsReady() {
        XCTAssertTrue(entry(exactMatch: 0.9).passesReadyGate)
    }

    /// An entry written before scoring existed has no number. Refusing those
    /// would silently retire every adapter already in the library.
    func testAnUnscoredAdapterIsStillReady() {
        XCTAssertTrue(entry(exactMatch: nil, cases: 0).passesReadyGate)
    }

    func testTheScoreReadsAsASentence() {
        XCTAssertEqual(entry(exactMatch: 0.72, cases: 11).evalSummary, "72% of 11")
        XCTAssertNil(entry(exactMatch: nil).evalSummary)
    }
}
