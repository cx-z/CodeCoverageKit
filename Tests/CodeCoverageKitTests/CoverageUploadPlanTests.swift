import Foundation
import XCTest
@testable import CodeCoverageKit

final class CoverageUploadPlanTests: XCTestCase {
    /// 创建可独立调节身份、顺序和状态的持久化记录，使用真实 Codable 兼容路径。
    private func p_record(_ sequence: Int?, status: String = "pending", changes: [String: Any] = [:]) throws -> CoverageSnapshotRecord {
        let t_base = CoverageTestFixtures.record(profile: Data("profile".utf8))
        var t_json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(t_base)) as? [String: Any])
        t_json["run_id"] = UUID().uuidString.lowercased()
        t_json["capture_sequence"] = sequence
        t_json["upload_status"] = status
        for (t_key, t_value) in changes { t_json[t_key] = t_value }
        return try JSONDecoder().decode(CoverageSnapshotRecord.self, from: JSONSerialization.data(withJSONObject: t_json))
    }

    /// 创建所有文件已校验的派生计划；生产文件校验仍由 Store 独占完成。
    private func p_plan(_ records: [CoverageSnapshotRecord]) -> CoverageUploadPlan {
        CoverageUploadPlan(records: records, validRunIDs: Set(records.map(\.runID)), coalescingEnabled: true)
    }

    /// 代表失败后仍代表旧快照，成功后抑制旧待传但不伪造其 uploaded 状态。
    func testRepresentativePendingFailedAndAccepted() throws {
        let t_old = try p_record(1)
        for t_status in ["pending", "failed_retryable", "uploaded"] {
            let t_latest = try p_record(2, status: t_status)
            let t_plan = p_plan([t_old, t_latest])
            XCTAssertEqual(t_plan.suppressedRunIDs, [t_old.runID])
            XCTAssertEqual(t_plan.records.map(\.runID), [t_latest.runID])
            XCTAssertEqual(t_old.uploadStatus, .pending)
        }
    }

    /// launch、device、Build、Cycle 或 process 任一身份不同都不能替代。
    func testGroupIdentityBoundaries() throws {
        let t_old = try p_record(1)
        for t_field in ["launch_id", "device_id", "build_id", "cycle_id", "process_id"] {
            let t_value: Any = t_field == "process_id" ? 99 : UUID().uuidString
            let t_latest = try p_record(2, changes: [t_field: t_value])
            XCTAssertTrue(p_plan([t_old, t_latest]).suppressedRunIDs.isEmpty)
        }
    }

    /// 缺序号、重复序号、非法序号和校验失败均不能凭时间或 UUID 猜测替代。
    func testLegacyAmbiguousOrInvalidGroupsStayVisible() throws {
        for t_sequence in [nil, 1, 0, -1] as [Int?] {
            XCTAssertTrue(p_plan([try p_record(1), try p_record(t_sequence)]).suppressedRunIDs.isEmpty)
        }
        let t_records = [try p_record(1), try p_record(2)]
        let t_plan = CoverageUploadPlan(records: t_records, validRunIDs: [t_records[0].runID], coalescingEnabled: true)
        XCTAssertTrue(t_plan.suppressedRunIDs.isEmpty)
    }

    /// 永久失败可见且不能作为代表；在途旧请求也不能被生命周期新快照隐藏。
    func testPermanentErrorsAndActiveRequestsStayVisible() throws {
        let t_old = try p_record(1)
        let t_failed = try p_record(2, status: "failed_permanent")
        XCTAssertTrue(p_plan([t_old, t_failed]).suppressedRunIDs.isEmpty)
        XCTAssertEqual(CoverageUploadPlan(records: [t_failed], validRunIDs: [t_failed.runID], deliveredRunIDs: [t_failed.runID]).records.map(\.runID), [t_failed.runID])
        let t_latest = try p_record(3)
        let t_plan = CoverageUploadPlan(records: [t_old, t_failed, t_latest],
                                        validRunIDs: [t_old.runID, t_failed.runID, t_latest.runID],
                                        protectedRunIDs: [t_old.runID], coalescingEnabled: true)
        XCTAssertTrue(t_plan.suppressedRunIDs.isEmpty)
    }

    /// Concurrent sampling has no general latest-only hit guarantee; production defaults keep every raw input.
    func testDefaultDoesNotSubstituteSameLaunchSnapshots() throws {
        let t_records = [try p_record(1), try p_record(2)]
        let t_plan = CoverageUploadPlan(records: t_records, validRunIDs: Set(t_records.map(\.runID)))
        XCTAssertTrue(t_plan.suppressedRunIDs.isEmpty)
        XCTAssertEqual(t_plan.records.count, 2)
    }

    /// 墙钟回退不改变同启动内由持久化序号确定的代表。
    func testSequenceWinsOverWallClock() throws {
        let t_old = try p_record(1, changes: ["captured_at": "2026-11-22T10:00:00Z"])
        let t_latest = try p_record(2, changes: ["captured_at": "2026-11-22T09:00:00Z"])
        XCTAssertEqual(p_plan([t_old, t_latest]).suppressedRunIDs, [t_old.runID])
    }
}
