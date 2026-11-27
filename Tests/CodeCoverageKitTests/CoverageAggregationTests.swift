import Foundation
import XCTest
@testable import CodeCoverageKit

final class CoverageAggregationTests: XCTestCase {
    /// Matches Python canonical JSON including slash, Unicode, controls, integer limits, arrays and absent optional fields.
    func testCanonicalMetadataGolden() throws {
        let t_value: [String: Any] = ["z": ["中/😀\u{2028}\n\"\\\u{1}", 9223372036854775807] as [Any], "a": ["process_id": 42]]
        let t_data = try CoverageCanonicalJSON.encode(t_value)
        XCTAssertEqual(String(decoding: t_data, as: UTF8.self), "{\"a\":{\"process_id\":42},\"z\":[\"中/😀\u{2028}\\n\\\"\\\\\\u0001\",9223372036854775807]}")
        XCTAssertEqual(CoverageCanonicalJSON.sha256(t_data), "b32b2a1a11b2dd6b5e3997ccdd2e1aea933804e3cc089b0469337d00c5ead9a3")
    }

    /// Every write/sync/rename/flush boundary fails visibly, and a successful payload/manifest pair survives a fresh Store.
    func testDurableSnapshotFaultBoundaries() throws {
        for t_boundary in CoverageDurableFile.Boundary.allCases {
            let t_root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: t_root) }
            let t_store = try CoverageSnapshotStore(rootURL: t_root, durability: CoverageDurableFile { t_step in
                if t_step == t_boundary { throw CocoaError(.fileWriteUnknown) }
            })
            XCTAssertThrowsError(try t_store.createSnapshot(profileData: Data("profile".utf8), metadata: CoverageTestFixtures.metadata(),
                deviceID: UUID().uuidString, launchID: UUID().uuidString, appState: "active", triggerReason: "manual_snapshot"))
            let t_recovered = try CoverageSnapshotStore(rootURL: t_root).loadRecords()
            XCTAssertTrue(t_recovered.isEmpty) // The fault is injected in the profile, before any manifest publication.
        }
    }

    /// Failure during original manifest publication cannot leave a manifest pointing to an uncommitted payload.
    func testManifestAndAggregateCommitFaultBoundaries() throws {
        for t_boundary in CoverageDurableFile.Boundary.allCases {
            let t_root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: t_root) }
            var t_writes = 0 // This Store and injection closure are confined to this test thread.
            let t_fault = CoverageDurableFile { t_step in
                if t_step == .beforeWrite { t_writes += 1 }
                if t_writes == 2 && t_step == t_boundary { throw CocoaError(.fileWriteUnknown) }
            }
            let t_store = try CoverageSnapshotStore(rootURL: t_root, durability: t_fault)
            XCTAssertThrowsError(try t_store.createSnapshot(profileData: Data("durable source".utf8), metadata: CoverageTestFixtures.metadata(),
                deviceID: UUID().uuidString, launchID: UUID().uuidString, appState: "active", triggerReason: "manual_snapshot"))
            let t_records = try CoverageSnapshotStore(rootURL: t_root).loadRecords()
            for t_record in t_records { try CoverageSnapshotStore(rootURL: t_root).validateProfile(record: t_record) }

            let (t_sourceRoot, t_sourceStore, t_sources) = try p_sources()
            defer { try? FileManager.default.removeItem(at: t_sourceRoot) }
            var t_aggregateWrites = 0
            let t_aggregateStore = try CoverageSnapshotStore(rootURL: t_sourceRoot, durability: CoverageDurableFile { t_step in
                if t_step == .beforeWrite { t_aggregateWrites += 1 }
                if t_aggregateWrites == 2 && t_step == t_boundary { throw CocoaError(.fileWriteUnknown) }
            })
            let t_record = try CoverageAggregateRecord(records: t_sources, payload: p_payload(), launchID: UUID().uuidString)
            XCTAssertThrowsError(try t_aggregateStore.saveAggregate(t_record, payload: p_payload()))
            XCTAssertTrue(t_sourceStore.deliveredSourceIDs(records: t_sources).isEmpty)
            XCTAssertEqual(try t_sourceStore.loadRecords().count, t_sources.count)
        }
    }

    /// Indexed success requires both new echoes in addition to all legacy identity fields, for each accepted status code.
    func testIndexedTransportRequiresStrictMetadataEcho() async throws {
        let (t_root, _, t_records) = try p_sources()
        defer { try? FileManager.default.removeItem(at: t_root) }
        let t_aggregate = try CoverageAggregateRecord(records: t_records, payload: p_payload(), launchID: UUID().uuidString)
        let t_host = "192.168.1.105", t_client = CoverageUploadClient(session: CoverageURLProtocolStub.makeSession())
        defer { CoverageURLProtocolStub.unregister(host: t_host) }
        let t_descriptor = CoverageUploadDescriptor(aggregate: t_aggregate)
        let t_prepared = try t_client.prepareUpload(descriptor: t_descriptor, profile: p_payload(), configuration: CoverageTestFixtures.configuration(host: t_host))
        for t_status in [200, 201, 202] {
            for t_valid in [true, false] {
                CoverageURLProtocolStub.register(host: t_host) { _ in
                    var t_value: [String: Any] = ["status": "accepted", "run_id": t_aggregate.runID, "cycle_id": t_aggregate.cycleID,
                        "build_id": t_aggregate.buildID, "sha256": t_aggregate.sha256, "size": t_aggregate.size,
                        "received_at": "2026-01-01T00:00:00Z", "analyzable": t_status != 202, "profile_format": "indexed"]
                    if t_valid { t_value["metadata_sha256"] = t_aggregate.metadataSHA256 }
                    return CoverageURLProtocolStub.StubResponse(statusCode: t_status, body: try! JSONSerialization.data(withJSONObject: t_value))
                }
                let t_result = await withCheckedContinuation { t_continuation in
                    t_client.send(prepared: t_prepared, descriptor: t_descriptor) { t_continuation.resume(returning: $0) }
                }
                if t_valid { guard case .success = t_result else { XCTFail("exact echo must succeed"); continue } }
                else { guard case .failure(.invalidResponse) = t_result else { XCTFail("missing metadata SHA must fail"); continue } }
            }
        }
    }

    /// A strict durable receipt completes exact representatives and their older same-launch snapshots, without changing raw statuses.
    func testReceiptRecoveryAndDisabledPlan() throws {
        let (t_root, t_store, t_records) = try p_sources()
        defer { try? FileManager.default.removeItem(at: t_root) }
        let t_payload = p_payload()
        let t_aggregate = try CoverageAggregateRecord(records: t_records, payload: t_payload, launchID: UUID().uuidString)
        _ = try t_store.saveAggregate(t_aggregate, payload: t_payload)
        XCTAssertThrowsError(try t_store.saveAggregate(t_aggregate, payload: t_payload))
        XCTAssertTrue(t_store.deliveredSourceIDs(records: t_records).isEmpty)
        let t_receipt = CoverageAggregateReceipt(aggregate: t_aggregate, accepted: p_accepted(t_aggregate))
        try t_store.saveReceipt(t_receipt)
        let t_restored = try CoverageSnapshotStore(rootURL: t_root)
        let t_raw = try t_restored.loadRecords()
        XCTAssertTrue(t_raw.allSatisfy { $0.uploadStatus == .pending })
        let t_delivered = t_restored.deliveredSourceIDs(records: t_raw)
        XCTAssertEqual(t_delivered, Set(t_records.map(\.runID)))
        let t_plan = CoverageUploadPlan(records: t_raw, validRunIDs: Set(t_raw.map(\.runID)), deliveredRunIDs: t_delivered)
        XCTAssertTrue(t_plan.records.isEmpty) // Receipt-derived obligations still apply with cross-launch preparation disabled.
        XCTAssertTrue(t_restored.deliveredSourceIDs(records: Array(t_raw.prefix(1))).isEmpty)
        XCTAssertTrue(t_restored.deliveredSourceIDs(records: t_raw + t_raw).isEmpty)
        var t_changed = t_raw
        t_changed[0].captureSequence = 2
        XCTAssertTrue(t_restored.deliveredSourceIDs(records: t_changed).isEmpty)

        try Data("corrupt receipt".utf8).write(to: t_root.appendingPathComponent("receipts/\(t_aggregate.runID).json"))
        XCTAssertTrue(t_restored.deliveredSourceIDs(records: t_raw).isEmpty)
    }

    /// A receipt publication fault must not complete obligations in the caller; recovery requires revalidating its full binding.
    func testReceiptFaultsAndStrictEchoes() throws {
        for t_boundary in CoverageDurableFile.Boundary.allCases {
            let (t_root, t_store, t_records) = try p_sources()
            defer { try? FileManager.default.removeItem(at: t_root) }
            let t_payload = p_payload()
            let t_aggregate = try CoverageAggregateRecord(records: t_records, payload: t_payload, launchID: UUID().uuidString)
            _ = try t_store.saveAggregate(t_aggregate, payload: t_payload)
            let t_faultStore = try CoverageSnapshotStore(rootURL: t_root, durability: CoverageDurableFile { t_step in
                if t_step == t_boundary { throw CocoaError(.fileWriteUnknown) }
            })
            XCTAssertThrowsError(try t_faultStore.saveReceipt(CoverageAggregateReceipt(aggregate: t_aggregate, accepted: p_accepted(t_aggregate))))
            let t_ids = t_store.deliveredSourceIDs(records: t_records)
            XCTAssertTrue(t_ids.isEmpty || t_ids == Set(t_records.map(\.runID)))
            // A post-rename receipt may be re-synced on recovery; a partial receipt can never deliver a subset.
            var t_wrong = p_accepted(t_aggregate)
            t_wrong.metadataSHA256 = String(repeating: "0", count: 64)
            XCTAssertThrowsError(try t_store.saveReceipt(CoverageAggregateReceipt(aggregate: t_aggregate, accepted: t_wrong)))
        }
    }

    /// Duplicate/mislocated original manifests are explicit restore errors, never a dictionary trap or silently omitted evidence.
    func testMislocatedManifestIsRejectedWithoutChangingOriginals() throws {
        let (t_root, t_store, t_records) = try p_sources()
        defer { try? FileManager.default.removeItem(at: t_root) }
        let t_record = t_records[0]
        let t_directory = t_root.appendingPathComponent("snapshots/\(t_record.buildID)")
        let t_manifest = t_directory.appendingPathComponent(t_record.runID + ".json")
        let t_before = try Data(contentsOf: t_manifest)
        try t_before.write(to: t_directory.appendingPathComponent("copied.json"))
        XCTAssertThrowsError(try t_store.loadRecords())
        XCTAssertEqual(try Data(contentsOf: t_manifest), t_before)
        try t_store.validateProfile(record: t_record)
    }

    /// New source content or membership always creates a fresh upload object; mixed Build/device identities are rejected.
    func testNewObjectIdentityAndGroupIsolation() throws {
        let (t_root, _, t_records) = try p_sources()
        defer { try? FileManager.default.removeItem(at: t_root) }
        let t_first = try CoverageAggregateRecord(records: t_records, payload: p_payload(), launchID: UUID().uuidString)
        let t_next = try CoverageAggregateRecord(records: t_records, payload: p_payload(), launchID: UUID().uuidString)
        XCTAssertNotEqual(t_first.runID, t_next.runID)
        XCTAssertNotEqual(t_first.metadataSHA256, t_next.metadataSHA256)
        XCTAssertThrowsError(try CoverageAggregateRecord(records: [t_records[0], t_records[0]], payload: p_payload(), launchID: UUID().uuidString))
        let t_groups = CoverageMergePreparation.groups(t_records, limits: nil)
        XCTAssertEqual(t_groups.count, 1)
        for t_field in ["cycle_id", "build_id", "device_id"] {
            var t_value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(t_records[1])) as! [String: Any]
            t_value[t_field] = UUID().uuidString.lowercased()
            let t_changed = try JSONDecoder().decode(CoverageSnapshotRecord.self, from: JSONSerialization.data(withJSONObject: t_value))
            XCTAssertThrowsError(try CoverageAggregateRecord(records: [t_records[0], t_changed], payload: p_payload(), launchID: UUID().uuidString))
            XCTAssertEqual(CoverageMergePreparation.groups([t_records[0], t_changed], limits: nil).count, 2)
        }

    }

    /// Supplies preserved raw sources for state-machine tests; it does not claim synthetic bytes prove LLVM equivalence.
    private func p_sources() throws -> (URL, CoverageSnapshotStore, [CoverageSnapshotRecord]) {
        let t_root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let t_store = try CoverageSnapshotStore(rootURL: t_root)
        let t_device = try t_store.loadOrCreateDeviceID()
        let t_metadata = try CoverageTestFixtures.metadata()
        let t_records = try (0..<2).map { t_index in
            try t_store.createSnapshot(profileData: Data(repeating: UInt8(t_index), count: 1024), metadata: t_metadata,
                deviceID: t_device, launchID: UUID().uuidString.lowercased(), appState: "active", triggerReason: "manual_snapshot", captureSequence: 1)
        }
        return (t_root, t_store, t_records)
    }

    /// Returns an explicitly synthetic indexed header only for receipt/state tests; production merging uses the LLVM bridge.
    private func p_payload() -> Data { Data([0xff, 0x6c, 0x70, 0x72, 0x6f, 0x66, 0x69, 0x81, 12, 0, 0, 0, 0, 0, 0, 0]) }

    /// Creates an exact fake server receipt, separating local persistence verification from real LLVM acceptance tests.
    private func p_accepted(_ record: CoverageAggregateRecord) -> CoverageUploadClient.AcceptedRun {
        CoverageUploadClient.AcceptedRun(profileFormat: "indexed", metadataSHA256: record.metadataSHA256,
            runID: record.runID, cycleID: record.cycleID, buildID: record.buildID, sha256: record.sha256, size: record.size,
            receivedAt: "2026-01-01T00:00:00Z", analyzable: true, statusCode: 201, compressedBodySize: 100, uncompressedBodySize: 200)
    }
}
