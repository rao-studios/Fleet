import Foundation

/// Projects a sealed `mary.behavior` episode JSON into Fleet's frozen
/// input/output pair. Lives in FleetCore so training does not import Mary.
public enum BehavioralPairProjector {

    public enum Error: Swift.Error, Sendable, Equatable {
        case notAnEpisode
        case emptyQuery
    }

    /// The lane Mary stamps on episodes she produced on her own initiative.
    public static let proactiveLane = "proactive"

    /// Whether a stored episode may become a training pair.
    ///
    /// Two rules, both load-bearing:
    ///
    /// - **Finished only.** A turn that was superseded or cancelled records
    ///   what was interrupted, not what the person wanted done.
    /// - **Not Mary's own.** Episodes on the `proactive` lane are the idle
    ///   engine's own predictions, filed in the same group and with the same
    ///   `completed` seal as a real turn. Training on them closes a loop:
    ///   each generation learns from the last one's output rather than from
    ///   the user, and the adapter drifts away from the behaviour it was
    ///   supposed to copy. Mary's side filters these too; this is the half
    ///   that holds when the corpus is read straight from Totem.
    public static func isTrainable(_ episode: JSONValue) -> Bool {
        let reason = episode["sealedReason"]?.stringValue ?? ""
        guard reason == "completed" else { return false }
        let lane = episode["provenance"]?["lane"]?.stringValue ?? ""
        guard lane != proactiveLane else { return false }
        let targets = episode["abilityTargets"]?.elements ?? []
        return !targets.isEmpty
    }

    public static func pair(
        from episodeJSON: String,
        documentId: String? = nil,
        groupId: String? = nil,
        totemId: String? = nil
    ) throws -> JSONPair {
        try pair(
            from: JSONParser.parse(episodeJSON),
            documentId: documentId,
            groupId: groupId,
            totemId: totemId)
    }

    public static func pair(
        from episode: JSONValue,
        documentId: String? = nil,
        groupId: String? = nil,
        totemId: String? = nil
    ) throws -> JSONPair {
        guard let input = episode["input"] else { throw Error.notAnEpisode }
        let query = input["query"]?.stringValue ?? ""
        guard !query.isEmpty else { throw Error.emptyQuery }
        let prior = input["priorEpisodeID"]?.stringValue ?? ""
        let ambient = input["ambient"]
        let mode = ambient?["mode"]?.stringValue ?? ""
        let lead = ambient?["lead"]?.stringValue ?? ""
        let factCount = ambient?["facts"]?.elements?.count ?? 0
        let summary = Self.summary(from: ambient)

        let records = episode["output"]?["actions"]?.elements ?? []
        let actions: [JSONValue] = records.map { record in
            let action = record["action"]
            let skill = action?["skill"]
            return .object([
                ("arguments_json", .string(action?["argumentsJSON"]?.stringValue ?? "{}")),
                ("disposition", .string(record["disposition"]?.stringValue ?? "")),
                ("intention", .string(action?["intention"]?.stringValue ?? "")),
                ("invocation_name", .string(skill?["invocationName"]?.stringValue ?? "")),
                ("skill_id", .string(skill?["skillID"]?.stringValue ?? "")),
                ("summary", .string(record["summary"]?.stringValue ?? "")),
            ])
        }

        let inputValue = JSONValue.object([
            ("ambient_lead", .string(lead)),
            ("ambient_mode", .string(mode)),
            ("ambient_summary", .string(summary)),
            ("fact_count", .number("\(factCount)")),
            ("prior_episode_id", .string(prior)),
            ("query", .string(query)),
        ])
        let outputValue = JSONValue.object([
            ("actions", .array(actions)),
        ])
        return JSONPair(
            input: inputValue,
            output: outputValue,
            provenance: SourceProvenance(
                origin: .totem,
                totemId: totemId,
                documentId: documentId,
                groupId: groupId))
    }

    private static func summary(from ambient: JSONValue?, limit: Int = 500) -> String {
        guard let ambient else { return "" }
        var parts: [String] = []
        if let lead = ambient["lead"]?.stringValue, !lead.isEmpty { parts.append(lead) }
        if let blocks = ambient["renderedBlocks"]?.elements {
            parts.append(contentsOf: blocks.compactMap(\.stringValue))
        }
        if let mentions = ambient["renderedMentions"]?.elements {
            parts.append(contentsOf: mentions.compactMap(\.stringValue))
        }
        let joined = parts.joined(separator: " ")
        guard joined.count > limit else { return joined }
        let end = joined.index(joined.startIndex, offsetBy: limit)
        return String(joined[..<end])
    }
}
