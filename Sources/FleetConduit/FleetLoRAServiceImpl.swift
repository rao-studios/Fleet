import Conduit
import FleetCore
import FleetService
import FleetStore
import FleetTraining
import Foundation
import GRPCCore
import os

public final class FleetLoRAServiceImpl: Fleet_V1_FleetLoRA.SimpleServiceProtocol, Sendable {
    private let service: FleetService
    private let corpus: TotemCorpusClient
    private let training = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    public init(service: FleetService, corpus: TotemCorpusClient) {
        self.service = service
        self.corpus = corpus
    }

    public func listAdapters(
        request: Fleet_V1_ListAdaptersRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Fleet_V1_ListAdaptersResponse {
        let entries = await service.loras(totemId: request.totemID)
        var response = Fleet_V1_ListAdaptersResponse()
        response.slots = []
        for entry in entries {
            response.slots.append(await slot(from: entry))
        }
        return response
    }

    public func adapterStatus(
        request: Fleet_V1_AdapterStatusRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Fleet_V1_LoRASlot {
        if let entry = await service.lora(totemId: request.totemID, abilityId: request.abilityID) {
            return await slot(from: entry)
        }
        var empty = Fleet_V1_LoRASlot()
        empty.abilityID = request.abilityID
        empty.ready = false
        return empty
    }

    public func train(
        request: Fleet_V1_TrainRequest,
        response: GRPCCore.RPCWriter<Fleet_V1_TrainProgress>,
        context: GRPCCore.ServerContext
    ) async throws {
        let key = FleetDB.namedSlotKey(totemId: request.totemID, abilityId: request.abilityID)
        // ONE RUN PER SLOT. The insert's result is the claim: two concurrent
        // Train calls for the same ability would each load a base model and
        // then race to publish into the same directory. The loser's weights
        // and the winner's registry entry would disagree.
        let claimed = training.withLock { $0.insert(key).inserted }
        guard claimed else {
            try await response.write(
                progress(stage: "error", message: "already training \(request.abilityID)"))
            return
        }
        defer { training.withLock { _ = $0.remove(key) } }

        do {
            let pairs = try await collectPairs(request)
            guard !pairs.isEmpty else {
                try await response.write(progress(stage: "error", message: "no trainable pairs"))
                return
            }
            // The CLI refuses an unfit dataset before spending a GPU hour on
            // it; this path used to walk straight past the same report.
            let report = await service.validationReport(pairs: pairs)
            for warning in report.warnings {
                try await response.write(progress(stage: "preparing", message: warning))
            }
            guard report.isTrainable else {
                try await response.write(
                    progress(stage: "error", message: report.summary))
                return
            }
            let dataset = try await service.createDataset(
                name: "life · \(request.abilityID) · \(request.totemID)",
                pairs: pairs)
            let modelId = request.modelID.isEmpty
                ? TrainingConfig.defaultModelId : request.modelID
            let stream = try await service.trainNamed(
                datasetId: dataset.id,
                totemId: request.totemID,
                abilityId: request.abilityID,
                config: .forCorpus(pairCount: pairs.count, modelId: modelId))
            for try await event in stream {
                try await response.write(Self.proto(event))
            }
        } catch {
            try await response.write(
                progress(stage: "error", message: String(describing: error)))
        }
    }

    private func collectPairs(_ request: Fleet_V1_TrainRequest) async throws -> [JSONPair] {
        if !request.pairs.isEmpty {
            return try request.pairs.map { pair in
                JSONPair(
                    input: try JSONParser.parse(pair.inputJson),
                    output: try JSONParser.parse(pair.outputJson),
                    provenance: .init(origin: .totem, totemId: request.totemID))
            }
        }
        guard !request.ownerID.isEmpty else { return [] }
        let documents = try await corpus.exportAll(
            ownerID: request.ownerID,
            groupIDs: request.groupIds,
            documentIDPrefix: request.documentIDPrefix.isEmpty
                ? "mary-behavior-" : request.documentIDPrefix)
        var pairs: [JSONPair] = []
        for document in documents {
            let body = document.texts.joined(separator: "\n")
            guard let parsed = try? JSONParser.parse(body),
                  BehavioralPairProjector.isTrainable(parsed),
                  let pair = try? BehavioralPairProjector.pair(
                    from: parsed,
                    documentId: document.id,
                    groupId: document.groupID,
                    totemId: request.totemID)
            else { continue }
            pairs.append(pair)
        }
        return Self.preferActed(pairs)
    }

    /// The output schema needs at least one acted row; silent rows teach restraint
    /// once that schema exists.
    static func preferActed(_ pairs: [JSONPair]) -> [JSONPair] {
        let acted = pairs.filter { !($0.output["actions"]?.elements ?? []).isEmpty }
        guard !acted.isEmpty else { return [] }
        let silent = pairs.filter { ($0.output["actions"]?.elements ?? []).isEmpty }
        return acted + silent
    }

    private func slot(from entry: LoRAEntry) async -> Fleet_V1_LoRASlot {
        let key = FleetDB.namedSlotKey(
            totemId: entry.totemId ?? "", abilityId: entry.abilityId ?? "")
        let isTraining = training.withLock { $0.contains(key) }
        var slot = Fleet_V1_LoRASlot()
        slot.abilityID = entry.abilityId ?? ""
        slot.generation = Int32(entry.generation)
        slot.pairCount = Int32(entry.pairCount)
        slot.trainedAtUnix = Int64(entry.updatedAt.timeIntervalSince1970)
        // READY MEANS GOOD ENOUGH TO ACT THROUGH, not merely present.
        slot.ready = await service.hasWeights(cid: entry.cid)
            && !isTraining
            && entry.passesReadyGate
        slot.artifactPath = await service.adapterDirectory(for: entry).path
        slot.cid = entry.cid
        slot.modelID = entry.modelId
        slot.schemaJson = await service.schemaJSON(cid: entry.cid) ?? Data()
        slot.training = isTraining
        return slot
    }

    private func progress(stage: String, message: String) -> Fleet_V1_TrainProgress {
        var progress = Fleet_V1_TrainProgress()
        progress.stage = stage
        progress.message = message
        return progress
    }

    private static func proto(_ event: TrainingProgress) -> Fleet_V1_TrainProgress {
        var progress = Fleet_V1_TrainProgress()
        switch event {
        case .preparing(let pairs, let tokens):
            progress.stage = "preparing"
            progress.message = "\(pairs) pairs, longest \(tokens) tokens"
        case .loadingModel(let fraction, let status):
            progress.stage = "loading"
            progress.message = "\(Int(fraction * 100))% \(status)"
        case .step(let iteration, let loss, _, _):
            progress.stage = "step"
            progress.iteration = Int32(iteration)
            progress.loss = loss
        case .validation(let iteration, let loss, _):
            progress.stage = "validation"
            progress.iteration = Int32(iteration)
            progress.loss = loss
        case .checkpointed(let iteration):
            progress.stage = "checkpoint"
            progress.iteration = Int32(iteration)
        case .evaluated(let exactMatch, let cases):
            progress.stage = "evaluated"
            progress.message =
                "\(Int((exactMatch * 100).rounded()))% exact of \(cases) held out"
        case .finished(let cid, let directory):
            progress.stage = "finished"
            progress.message = cid
            var slot = Fleet_V1_LoRASlot()
            slot.cid = cid
            slot.artifactPath = directory.path
            slot.ready = true
            progress.slot = slot
        }
        return progress
    }
}
