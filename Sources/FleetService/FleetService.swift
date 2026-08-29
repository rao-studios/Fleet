import FleetCore
import FleetInference
import FleetStore
import FleetTraining
import Foundation

/// The single entry point to Fleet.
///
/// The app and the CLI both drive this, so orchestration lives in one place
/// instead of being re-implemented in a view model. The shape is deliberately
/// request/response with streaming progress, which is also what a future gRPC
/// service would need to expose.
public actor FleetService {

    public let db: FleetDB
    private var sessions: [String: StructuredSession] = [:]
    /// Loaded models are large, so only a couple of gated sessions stay resident.
    private var sessionOrder: [String] = []
    private let maximumSessions = 2

    public init(db: FleetDB = FleetDB()) {
        self.db = db
    }

    /// Clean up after a crash or an interrupted run. Call once at startup.
    @discardableResult
    public func start() async -> FleetDB.ReconciliationReport {
        await db.reconcile()
    }

    public func shutdown() async {
        await db.shutdown()
    }

    // MARK: - Datasets

    public func createDataset(name: String, pairs: [JSONPair]) async throws -> DatasetEntry {
        guard !pairs.isEmpty else { throw FleetServiceError.noPairs }
        let dataset: StateDataset
        do {
            dataset = try StateDataset(name: name, pairs: pairs)
        } catch {
            throw FleetServiceError.validationFailed(Self.report(for: pairs, error: error))
        }
        await db.saveDataset(dataset)
        return DatasetEntry(dataset: dataset)
    }

    /// Build a dataset from two folders' worth of files, paired by index.
    ///
    /// Both lists are sorted by name first, so `inputs/003.json` lines up with
    /// `outputs/003.json` regardless of the order the file picker handed them over.
    public func importDataset(
        name: String,
        inputFiles: [URL],
        outputFiles: [URL]
    ) async throws -> DatasetEntry {
        let inputs = inputFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let outputs = outputFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard inputs.count == outputs.count else {
            throw FleetServiceError.countMismatch(inputs: inputs.count, outputs: outputs.count)
        }
        guard !inputs.isEmpty else { throw FleetServiceError.noPairs }

        var problems: [ValidationReport.FileProblem] = []
        var pairs: [JSONPair] = []
        for index in inputs.indices {
            let inputURL = inputs[index]
            let outputURL = outputs[index]
            let parsedInput = Self.parse(inputURL, role: .input, index: index, into: &problems)
            let parsedOutput = Self.parse(outputURL, role: .output, index: index, into: &problems)
            guard let parsedInput, let parsedOutput else { continue }
            pairs.append(
                JSONPair(
                    input: parsedInput,
                    output: parsedOutput,
                    provenance: .file(named: inputURL.lastPathComponent)
                ))
        }

        guard problems.isEmpty else {
            throw FleetServiceError.validationFailed(
                ValidationReport(pairCount: pairs.count, fileProblems: problems))
        }
        return try await createDataset(name: name, pairs: pairs)
    }

    public func generateMockDataset(
        domain: MockDomain,
        count: Int,
        seed: UInt64,
        name: String? = nil
    ) async throws -> DatasetEntry {
        let pairs = MockDatasetGenerator.generate(domain: domain, count: count, seed: seed)
        let title = name ?? "\(domain.title) · \(count) pairs · seed \(seed)"
        return try await createDataset(name: title, pairs: pairs)
    }

    public func dataset(id: UUID) async -> StateDataset? {
        await db.loadDataset(id: id)
    }

    public func datasets(after cursor: String? = nil, limit: Int = 25) async -> Page<DatasetEntry> {
        await db.datasets(after: cursor, limit: limit)
    }

    public func allDatasets() async -> [DatasetEntry] {
        await db.allDatasets()
    }

    public func deleteDataset(id: UUID) async {
        await db.deleteDataset(id: id)
    }

    public func updateDataset(_ dataset: StateDataset) async throws -> DatasetEntry {
        var updated = dataset
        do {
            updated.schema = try SchemaExtractor.template(outputs: dataset.pairs.map(\.output))
        } catch {
            throw FleetServiceError.validationFailed(
                Self.report(for: dataset.pairs, error: error))
        }
        await db.saveDataset(updated)
        return DatasetEntry(dataset: updated)
    }

    /// The schema preview, problems, and overwrite warning for one dataset.
    public func validationReport(datasetId: UUID) async throws -> ValidationReport {
        guard let dataset = await db.loadDataset(id: datasetId) else {
            throw FleetServiceError.datasetNotFound(datasetId)
        }
        return await validationReport(pairs: dataset.pairs)
    }

    public func validationReport(pairs: [JSONPair]) async -> ValidationReport {
        var report: ValidationReport
        do {
            let schema = try SchemaExtractor.template(outputs: pairs.map(\.output))
            report = ValidationReport(schema: schema, pairCount: pairs.count)
        } catch {
            report = Self.report(for: pairs, error: error)
        }

        let cid = ContentID.compute(inputs: pairs.map(\.input))
        report.inputCID = cid
        report.existingGeneration = await db.lora(cid: cid)?.generation

        // Frigate's batch iterator warns past ~2048 tokens and long examples train
        // poorly, so flag them here using a cheap character proxy.
        let longest = pairs
            .map { PromptBuilder.trainingText(input: $0.input, output: $0.output).count }
            .max() ?? 0
        if longest > 6000 {
            report.warnings.append(
                "The longest example is about \(longest) characters, which may exceed the "
                    + "model's training window. Consider shorter documents.")
        }
        return report
    }

    /// The CID a LoRA trained from this dataset would occupy, so the UI can say
    /// what a training run is about to replace.
    public func predictedCID(datasetId: UUID) async -> String? {
        await db.loadDataset(id: datasetId)?.inputCID
    }

    // MARK: - Training

    /// Train a LoRA and publish it under its content id.
    ///
    /// Progress is forwarded from the trainer; the final `.finished` carries the
    /// published CID. If the run fails or is cancelled, the staging directory is
    /// removed and the library is untouched.
    public func train(
        datasetId: UUID,
        config: TrainingConfig = TrainingConfig()
    ) async throws -> AsyncThrowingStream<TrainingProgress, Error> {
        guard let dataset = await db.loadDataset(id: datasetId) else {
            throw FleetServiceError.datasetNotFound(datasetId)
        }
        guard !dataset.pairs.isEmpty else { throw FleetServiceError.noPairs }

        let staging = try db.makeStagingDirectory()
        let trainer = StateTrainer(config: config)
        let db = self.db

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await progress in trainer.run(
                        dataset: dataset, stagingDirectory: staging)
                    {
                        if case .finished(let cid, _) = progress {
                            // Publishing is what makes the run visible; only then
                            // does the caller hear that it finished.
                            let entry = try await db.publishLoRA(cid: cid, from: staging) {
                                previous in
                                LoRAEntry(
                                    cid: cid,
                                    label: previous?.label,
                                    modelId: config.modelId,
                                    datasetId: dataset.id,
                                    schemaHash: dataset.schema.hashHex,
                                    schemaDescription: dataset.schema.description,
                                    pairCount: dataset.pairs.count,
                                    rank: config.rank,
                                    scale: config.scale,
                                    numLayers: config.numLayers,
                                    iterations: config.iterations
                                )
                            }
                            await self.invalidateSession(cid: entry.cid)
                            continuation.yield(
                                .finished(
                                    cid: entry.cid,
                                    adapterDirectory: db.adapterDirectory(cid: entry.cid)))
                        } else {
                            continuation.yield(progress)
                        }
                    }
                    continuation.finish()
                } catch {
                    try? FileManager.default.removeItem(at: staging)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                task.cancel()
                if case .cancelled = reason {
                    try? FileManager.default.removeItem(at: staging)
                }
            }
        }
    }

    // MARK: - Testing

    /// Run one input through a stored LoRA under its own schema.
    public func test(
        cid: String,
        input: JSONValue,
        options: GateOptions = GateOptions()
    ) async throws -> AsyncThrowingStream<GateEvent, Error> {
        let (session, schema) = try await preparedSession(cid: cid)
        return await session.generate(input: input, schema: schema, options: options)
    }

    /// Non-streaming variant, used by the CLI and by batch evaluation.
    public func complete(
        cid: String,
        input: JSONValue,
        options: GateOptions = GateOptions()
    ) async throws -> GatedResult {
        let (session, schema) = try await preparedSession(cid: cid)
        return try await session.complete(input: input, schema: schema, options: options)
    }

    /// Check a LoRA against the pairs it was trained on: how often does the gated
    /// output match the expected output exactly?
    public func evaluate(
        cid: String,
        pairs: [JSONPair],
        options: GateOptions = GateOptions(captureTrace: false)
    ) async throws -> EvaluationSummary {
        let (session, schema) = try await preparedSession(cid: cid)
        var exact = 0
        var results: [EvaluationSummary.Case] = []
        for pair in pairs {
            let produced = try await session.complete(
                input: pair.input, schema: schema, options: options)
            let expected = JSONCanonical.serialize(pair.output)
            let actual = JSONCanonical.serialize(produced.json)
            if expected == actual { exact += 1 }
            results.append(
                .init(input: pair.input, expected: pair.output, actual: produced.json))
        }
        return EvaluationSummary(cases: results, exactMatches: exact)
    }

    public func warmup(cid: String) async throws {
        let (session, schema) = try await preparedSession(cid: cid)
        try await session.warmup(schema: schema)
    }

    private func preparedSession(cid: String) async throws -> (StructuredSession, SchemaTemplate) {
        guard let entry = await db.lora(cid: cid), db.hasWeights(cid: cid) else {
            throw FleetServiceError.loraNotFound(cid)
        }
        guard let schema = db.schema(cid: cid) else {
            throw FleetServiceError.schemaUnavailable(cid)
        }
        if let existing = sessions[cid] {
            touch(cid: cid)
            return (existing, schema)
        }
        let session = StructuredSession(
            modelId: entry.modelId,
            adapterDirectory: db.adapterDirectory(cid: cid)
        )
        sessions[cid] = session
        touch(cid: cid)
        evictIfNeeded()
        return (session, schema)
    }

    private func touch(cid: String) {
        sessionOrder.removeAll { $0 == cid }
        sessionOrder.append(cid)
    }

    private func evictIfNeeded() {
        while sessionOrder.count > maximumSessions {
            let oldest = sessionOrder.removeFirst()
            sessions.removeValue(forKey: oldest)
        }
    }

    /// Drop a cached session when its weights change underneath it.
    private func invalidateSession(cid: String) {
        sessions.removeValue(forKey: cid)
        sessionOrder.removeAll { $0 == cid }
    }

    // MARK: - Library

    public func loras(after cursor: String? = nil, limit: Int = 25) async -> Page<LoRAEntry> {
        await db.loras(after: cursor, limit: limit)
    }

    public func allLoRAs() async -> [LoRAEntry] {
        await db.allLoRAs()
    }

    public func lora(cid: String) async -> LoRAEntry? {
        await db.lora(cid: cid)
    }

    public func schema(cid: String) -> SchemaTemplate? {
        db.schema(cid: cid)
    }

    public func setLabel(cid: String, label: String?) async {
        await db.setLabel(cid: cid, label: label)
    }

    public func deleteLoRA(cid: String) async {
        invalidateSession(cid: cid)
        await db.deleteLoRA(cid: cid)
    }

    @discardableResult
    public func createGroup(label: String, metadata: [String: String] = [:]) async -> GroupEntry {
        await db.createGroup(label: label, metadata: metadata)
    }

    public func groups() async -> [GroupEntry] {
        await db.groups()
    }

    public func renameGroup(id: String, label: String) async {
        await db.renameGroup(id: id, label: label)
    }

    public func deleteGroup(id: String) async {
        await db.deleteGroup(id: id)
    }

    public func add(cid: String, toGroup groupId: String) async {
        await db.add(cid: cid, toGroup: groupId)
    }

    public func remove(cid: String, fromGroup groupId: String) async {
        await db.remove(cid: cid, fromGroup: groupId)
    }

    public func groups(forLoRA cid: String) async -> [GroupEntry] {
        await db.groups(forLoRA: cid)
    }

    public func loras(inGroup groupId: String, after cursor: String? = nil, limit: Int = 25)
        async -> Page<LoRAEntry>
    {
        await db.loras(inGroup: groupId, after: cursor, limit: limit)
    }

    // MARK: - Helpers

    private static func parse(
        _ url: URL,
        role: ValidationReport.FileProblem.Role,
        index: Int,
        into problems: inout [ValidationReport.FileProblem]
    ) -> JSONValue? {
        do {
            return try JSONParser.parse(contentsOf: url)
        } catch {
            problems.append(
                .init(
                    index: index,
                    role: role,
                    fileName: url.lastPathComponent,
                    message: "\(error)"
                ))
            return nil
        }
    }

    private static func report(for pairs: [JSONPair], error: Error) -> ValidationReport {
        var report = ValidationReport(pairCount: pairs.count)
        switch error {
        case SchemaExtractionError.mismatches(let errors):
            report.schemaErrors = errors
        case let extraction as SchemaExtractionError:
            report.warnings.append(extraction.description)
        default:
            report.warnings.append("\(error)")
        }
        return report
    }
}

/// How a LoRA performed against a set of pairs.
public struct EvaluationSummary: Sendable {
    public struct Case: Sendable {
        public var input: JSONValue
        public var expected: JSONValue
        public var actual: JSONValue

        public var matches: Bool {
            JSONCanonical.serialize(expected) == JSONCanonical.serialize(actual)
        }
    }

    public var cases: [Case]
    public var exactMatches: Int

    public var total: Int { cases.count }

    public var accuracy: Double {
        total > 0 ? Double(exactMatches) / Double(total) : 0
    }

    public var summaryLine: String {
        "\(exactMatches)/\(total) exact (\(Int((accuracy * 100).rounded()))%)"
    }
}
