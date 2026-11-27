#if CODE_COVERAGE_KIT_ENABLED
import Foundation

extension CoverageSnapshotStore {
    /// Resolves only typed UUID-based SDK-owned paths; aggregate artifacts never enter the raw manifest enumerator.
    func aggregateDirectory(_ record: CoverageAggregateRecord) throws -> URL {
        guard UUID(uuidString: record.buildID) != nil, UUID(uuidString: record.runID) != nil else {
            throw StoreError.invalidRelativePath
        }
        return rootURL.appendingPathComponent("aggregates").appendingPathComponent(record.buildID).appendingPathComponent(record.runID)
    }

    /// Creates a new immutable object only, commits payload before its fixed manifest, and refuses to replace existing materials.
    func saveAggregate(_ record: CoverageAggregateRecord, payload: Data) throws -> URL {
        try record.validate()
        guard payload.count == record.size, CoverageCanonicalJSON.sha256(payload) == record.sha256 else {
            throw StoreError.profileMismatch(record.runID)
        }
        let t_directory = try aggregateDirectory(record)
        guard !FileManager.default.fileExists(atPath: t_directory.path) else { throw StoreError.aggregateAlreadyExists }
        let t_payload = t_directory.appendingPathComponent("payload.profdata")
        try durability.write(payload, to: t_payload, syncThrough: durabilityRootURL)
        try durability.write(JSONEncoder().encode(record), to: t_directory.appendingPathComponent("object.json"), syncThrough: durabilityRootURL)
        return t_payload
    }

    /// Restores mutable attempt state only after proving it still belongs to the fixed network object.
    func loadAggregate(_ expected: CoverageAggregateRecord) throws -> CoverageAggregateRecord {
        let t_url = try aggregateDirectory(expected).appendingPathComponent("object.json")
        let t_record = try JSONDecoder().decode(CoverageAggregateRecord.self, from: Data(contentsOf: t_url))
        try t_record.validate()
        guard t_record.hasSameIdentity(as: expected) else { throw StoreError.profileMismatch(expected.runID) }
        return t_record
    }

    /// Durably updates only attempt diagnostics; raw sources never acquire another object's uploaded state.
    func saveAggregateState(_ record: CoverageAggregateRecord) throws {
        _ = try loadAggregate(record)
        try durability.write(JSONEncoder().encode(record), to: aggregateDirectory(record).appendingPathComponent("object.json"), syncThrough: durabilityRootURL)
    }

    /// Publishes the strict receipt before the Collector can derive any completed source obligation.
    func saveReceipt(_ receipt: CoverageAggregateReceipt) throws {
        try receipt.validate()
        let t_url = rootURL.appendingPathComponent("receipts").appendingPathComponent(receipt.aggregate.runID + ".json")
        try durability.write(JSONEncoder().encode(receipt), to: t_url, syncThrough: durabilityRootURL)
    }

    /// Restores permanent aggregate rejections without relabelling sources or silently retrying them under fresh identities.
    func rejectedSourceIDs(records: [CoverageSnapshotRecord]) -> Set<String> {
        guard Set(records.map(\.runID)).count == records.count else { return [] }
        let t_records = Dictionary(uniqueKeysWithValues: records.map { ($0.runID, $0) })
        let t_root = rootURL.appendingPathComponent("aggregates")
        guard let t_enumerator = FileManager.default.enumerator(at: t_root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var t_rejected = Set<String>()
        for case let t_url as URL in t_enumerator where t_url.lastPathComponent == "object.json" {
            guard let t_data = try? Data(contentsOf: t_url),
                  let t_object = try? JSONDecoder().decode(CoverageAggregateRecord.self, from: t_data),
                  t_object.permanentError != nil, (try? t_object.validate()) != nil,
                  (try? aggregateDirectory(t_object)) == t_url.deletingLastPathComponent() else { continue }
            let t_matching = t_object.sources.allSatisfy { t_source in
                guard let t_record = t_records[t_source.runID], t_record.cycleID == t_object.cycleID,
                      t_record.buildID == t_object.buildID, t_record.deviceID == t_object.deviceID else { return false }
                return (try? CoverageAggregationSource(record: t_record)) == t_source
            }
            if t_matching { t_rejected.formUnion(t_object.sources.map(\.runID)) }
        }
        return t_rejected
    }

    /// Validates complete receipts against fixed aggregate artifacts and every still-preserved original source identity.
    func deliveredSourceIDs(records: [CoverageSnapshotRecord]) -> Set<String> {
        guard Set(records.map(\.runID)).count == records.count else { return [] }
        let t_records = Dictionary(uniqueKeysWithValues: records.map { ($0.runID, $0) })
        let t_directory = rootURL.appendingPathComponent("receipts")
        let t_urls = (try? FileManager.default.contentsOfDirectory(at: t_directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var t_delivered = Set<String>()
        for t_url in t_urls where t_url.pathExtension == "json" {
            do {
                let t_receipt = try JSONDecoder().decode(CoverageAggregateReceipt.self, from: Data(contentsOf: t_url))
                try t_receipt.validate()
                let t_aggregate = t_receipt.aggregate
                guard t_url.lastPathComponent == t_aggregate.runID + ".json" else { continue }
                let t_root = try aggregateDirectory(t_aggregate)
                let t_stored = try JSONDecoder().decode(CoverageAggregateRecord.self, from: Data(contentsOf: t_root.appendingPathComponent("object.json")))
                guard t_stored == t_aggregate else { continue }
                let t_payloadURL = t_root.appendingPathComponent("payload.profdata")
                let t_payload = try Data(contentsOf: t_payloadURL)
                guard t_payload.count == t_aggregate.size, CoverageCanonicalJSON.sha256(t_payload) == t_aggregate.sha256,
                      try t_aggregate.sources.allSatisfy({ t_source in
                          guard let t_record = t_records[t_source.runID], t_record.cycleID == t_aggregate.cycleID,
                                t_record.buildID == t_aggregate.buildID, t_record.deviceID == t_aggregate.deviceID else { return false }
                          return try CoverageAggregationSource(record: t_record) == t_source
                      }) else { continue }
                try durability.synchronizeExisting(t_payloadURL, syncThrough: durabilityRootURL)
                try durability.synchronizeExisting(t_root.appendingPathComponent("object.json"), syncThrough: durabilityRootURL)
                try durability.synchronizeExisting(t_url, syncThrough: durabilityRootURL)
                t_delivered.formUnion(t_aggregate.sources.map(\.runID))
            } catch { continue } // Unproven receipt means conservative retransmission, never guessed delivery.
        }
        return t_delivered
    }
}
#endif
