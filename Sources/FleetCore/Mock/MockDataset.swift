import Foundation

/// A seeded, reproducible random source.
///
/// `SystemRandomNumberGenerator` cannot be seeded, and mock datasets must be
/// byte-identical across runs: the same (domain, count, seed) has to produce the
/// same input set, or the CID would change and every regeneration would mint a
/// new LoRA instead of overwriting one.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in `0..<bound`.
    public mutating func int(below bound: Int) -> Int {
        precondition(bound > 0)
        return Int(next() % UInt64(bound))
    }

    public mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + int(below: range.count)
    }

    public mutating func pick<T>(_ options: [T]) -> T {
        options[int(below: options.count)]
    }

    public mutating func bool() -> Bool {
        next() % 2 == 0
    }

    /// A value rounded to two decimals, so canonical output stays short.
    public mutating func double(in range: ClosedRange<Double>) -> Double {
        let steps = Int(((range.upperBound - range.lowerBound) * 100).rounded()) + 1
        let value = range.lowerBound + Double(int(below: steps)) / 100
        return (value * 100).rounded() / 100
    }
}

/// The built-in domains the Mac app can generate a training set from.
///
/// Each is a deterministic rule mapping input to output, so a LoRA trained on one
/// has something real to learn, and the whole pipeline can be exercised end to
/// end without hand-writing JSON or calling a model.
public enum MockDomain: String, Sendable, CaseIterable, Codable {
    case weatherReport
    case orderTriage
    case deviceHealth

    public var title: String {
        switch self {
        case .weatherReport: return "Weather report"
        case .orderTriage: return "Order triage"
        case .deviceHealth: return "Device health"
        }
    }

    public var summary: String {
        switch self {
        case .weatherReport:
            return "Readings and wind speed become a summary, average, storm flag, and advisories."
        case .orderTriage:
            return "A customer message becomes an intent, priority, refund flag, and tags."
        case .deviceHealth:
            return "Uptime and error codes become a status, anomaly score, and service flag."
        }
    }
}

public enum MockDatasetGenerator {

    public static func generate(domain: MockDomain, count: Int, seed: UInt64) -> [JSONPair] {
        var rng = SplitMix64(seed: seed)
        let provenance = SourceProvenance.mock(domain: domain.rawValue)
        return (0 ..< max(0, count)).map { index in
            let input: JSONValue
            let output: JSONValue
            switch domain {
            case .weatherReport:
                (input, output) = weatherPair(&rng)
            case .orderTriage:
                (input, output) = orderPair(&rng)
            case .deviceHealth:
                (input, output) = devicePair(&rng)
            }
            // A deterministic id keeps regenerated datasets diff-clean.
            return JSONPair(
                id: deterministicID(domain: domain, seed: seed, index: index),
                input: input,
                output: output,
                provenance: provenance
            )
        }
    }

    private static func deterministicID(domain: MockDomain, seed: UInt64, index: Int) -> UUID {
        let digest = ContentID.hashHex(of: Data("\(domain.rawValue)|\(seed)|\(index)".utf8))
        let hex = String(digest.prefix(32))
        var bytes: [UInt8] = []
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let next = hex.index(cursor, offsetBy: 2)
            bytes.append(UInt8(hex[cursor ..< next], radix: 16) ?? 0)
            cursor = next
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Weather

    private static let cities = [
        "Reykjavik", "Lisbon", "Nairobi", "Osaka", "Quito", "Perth", "Tromso", "Valparaiso",
    ]

    private static func weatherPair(_ rng: inout SplitMix64) -> (JSONValue, JSONValue) {
        let city = rng.pick(cities)
        let readingCount = rng.int(in: 3 ... 6)
        let readings = (0 ..< readingCount).map { _ in rng.double(in: -18 ... 34) }
        let wind = rng.double(in: 0 ... 95)

        let average = ((readings.reduce(0, +) / Double(readings.count)) * 100).rounded() / 100
        let stormRisk = wind > 40 && average < 10

        let summary: String
        switch average {
        case ..<0: summary = "Freezing in \(city)"
        case 0 ..< 12: summary = "Cold in \(city)"
        case 12 ..< 24: summary = "Mild in \(city)"
        default: summary = "Hot in \(city)"
        }

        var advisories: [String] = []
        if wind > 60 { advisories.append("high wind") }
        if average < -5 { advisories.append("frost warning") }
        if average > 30 { advisories.append("heat warning") }

        let input = JSONValue.object([
            ("city", .string(city)),
            ("readings", .array(readings.map { .number($0) })),
            ("wind_kph", .number(wind)),
        ])
        let output = JSONValue.object([
            ("summary", .string(summary)),
            ("avg_temp_c", .number(average)),
            ("storm_risk", .bool(stormRisk)),
            ("advisories", .array(advisories.map { .string($0) })),
        ])
        return (input, output)
    }

    // MARK: - Order triage

    private static let messageBank: [(text: String, intent: String, tag: String)] = [
        ("This arrived cracked down the side", "damage", "damaged"),
        ("I want my money back please", "refund", "refund"),
        ("Where is my parcel, it is late", "shipping", "late"),
        ("Can I change the delivery address", "address", "change"),
        ("The size is wrong, I need a bigger one", "exchange", "sizing"),
        ("Great product, just saying thanks", "praise", "positive"),
        ("You charged me twice for this order", "billing", "duplicate"),
        ("It stopped working after two days", "defect", "faulty"),
    ]

    private static let products = ["lamp", "chair", "mug", "kettle", "rug", "shelf"]

    private static func orderPair(_ rng: inout SplitMix64) -> (JSONValue, JSONValue) {
        let orderId = "ORD-\(1000 + rng.int(below: 9000))"
        let itemCount = rng.int(in: 1 ... 3)
        let items = (0 ..< itemCount).map { _ in rng.pick(products) }
        let entry = rng.pick(messageBank)
        let daysWaiting = rng.int(in: 0 ... 21)

        let urgent = ["damage", "defect", "billing"].contains(entry.intent)
        let priority = min(5, max(1, (urgent ? 4 : 2) + (daysWaiting > 14 ? 1 : 0)))
        let refundEligible = ["damage", "refund", "defect", "billing"].contains(entry.intent)
            && daysWaiting <= 14

        var tags = [entry.tag]
        if daysWaiting > 14 { tags.append("aged") }
        if itemCount > 1 { tags.append("multi-item") }

        let input = JSONValue.object([
            ("order_id", .string(orderId)),
            ("items", .array(items.map { .string($0) })),
            ("message", .string(entry.text)),
            ("days_waiting", .number(daysWaiting)),
        ])
        let output = JSONValue.object([
            ("intent", .string(entry.intent)),
            ("priority", .number(priority)),
            ("refund_eligible", .bool(refundEligible)),
            ("tags", .array(tags.map { .string($0) })),
        ])
        return (input, output)
    }

    // MARK: - Device health

    private static let deviceNames = ["edge-01", "edge-02", "hub-a", "hub-b", "sensor-x", "relay-9"]
    private static let errorCodes = ["E100", "E204", "E301", "W050", "W071"]

    private static func devicePair(_ rng: inout SplitMix64) -> (JSONValue, JSONValue) {
        let device = rng.pick(deviceNames)
        let uptime = rng.double(in: 0 ... 8760)
        let codeCount = rng.int(in: 0 ... 3)
        let codes = (0 ..< codeCount).map { _ in rng.pick(errorCodes) }

        let errors = codes.filter { $0.hasPrefix("E") }.count
        let warnings = codes.count - errors
        let raw = Double(errors) * 0.3 + Double(warnings) * 0.1 + (uptime > 4000 ? 0.2 : 0)
        let anomalyScore = (min(1.0, raw) * 100).rounded() / 100
        let needsService = anomalyScore >= 0.5

        let status: String
        switch anomalyScore {
        case ..<0.2: status = "healthy"
        case 0.2 ..< 0.5: status = "watch"
        default: status = "degraded"
        }

        let note = errors > 0
            ? "\(errors) error code(s) reported by \(device)"
            : "no error codes on \(device)"

        let input = JSONValue.object([
            ("device", .string(device)),
            ("uptime_h", .number(uptime)),
            ("error_codes", .array(codes.map { .string($0) })),
        ])
        let output = JSONValue.object([
            ("status", .string(status)),
            ("anomaly_score", .number(anomalyScore)),
            ("needs_service", .bool(needsService)),
            ("note", .string(note)),
        ])
        return (input, output)
    }
}
