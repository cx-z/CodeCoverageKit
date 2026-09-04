import Foundation
import XCTest
@testable import CodeCoverageKit

final class CoverageSnapshotStoreTests: XCTestCase {
    /// 验证所有宿主始终选择中性的 Application Support 根目录。
    func testUsesNeutralStorageRoot() throws {
        let t_applicationSupportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let t_neutralURL = CoverageSnapshotStore.rootURL(applicationSupportURL: t_applicationSupportURL)

        XCTAssertEqual(t_neutralURL.lastPathComponent, CoverageSnapshotStore.directoryName)
    }

    /// 验证 profile 与清单按 Build 原子持久化，并在重启恢复时保留原 Cycle/Build 身份。
    func testPersistsAndRestoresSnapshotIdentity() throws {
        let t_rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: t_rootURL) }
        let t_store = try CoverageSnapshotStore(rootURL: t_rootURL)
        let t_metadata = try CoverageTestFixtures.metadata()
        let t_profile = Data("real-profraw-shape-is-tested-by-runtime-bridge".utf8)

        var t_record = try t_store.createSnapshot(
            profileData: t_profile,
            metadata: t_metadata,
            deviceID: UUID().uuidString.lowercased(),
            launchID: UUID().uuidString.lowercased(),
            appState: "background",
            triggerReason: "app_background"
        )
        t_record.uploadStatus = .uploading
        try t_store.update(record: t_record)

        let t_restored = try XCTUnwrap(try CoverageSnapshotStore(rootURL: t_rootURL).loadRecords().first)
        XCTAssertEqual(t_restored.cycleID, t_metadata.cycleID)
        XCTAssertEqual(t_restored.buildID, t_metadata.buildID)
        XCTAssertEqual(t_restored.uploadStatus, .pending)
        XCTAssertEqual(try Data(contentsOf: t_store.profileURL(record: t_restored)), t_profile)
    }
}
