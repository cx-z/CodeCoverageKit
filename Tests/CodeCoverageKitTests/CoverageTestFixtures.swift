import CryptoKit
import Foundation
@testable import CodeCoverageKit

enum CoverageTestFixtures {
    static let cycleID = "11111111-1111-4111-8111-111111111111"
    static let buildID = "22222222-2222-4222-8222-222222222222"
    static let runID = "33333333-3333-4333-8333-333333333333"
    static let token = "restricted-test-token"

    /// 生成不含宿主品牌的有效 Build metadata JSON，供普通协议测试复用。
    static func metadataData(
        project: String = "ExampleProject",
        buildID: String = buildID,
        serverURL: String = "http://192.168.1.20:8765"
    ) throws -> Data {
        let t_payload: [String: Any] = [
            "schema_version": 1,
            "project": project,
            "cycle_id": cycleID,
            "build_id": buildID,
            "git_sha": String(repeating: "a", count: 40),
            "target_sha_at_build": String(repeating: "b", count: 40),
            "merge_base_sha": String(repeating: "c", count: 40),
            "bundle_id": "com.example.coverage",
            "app_version": "1.0",
            "bundle_version": "1",
            "xcode_version": "test-version",
            "coverage_server_url": serverURL,
            "run_upload_token": token
        ]
        return try JSONSerialization.data(withJSONObject: t_payload, options: [.sortedKeys])
    }

    /// 解码一份通用 Build metadata，确保测试使用生产校验路径。
    static func metadata() throws -> CoverageBuildMetadata {
        try CoverageBuildMetadata.decode(try metadataData())
    }

    /// 创建一个绑定固定 Cycle/Build 身份的待上传 Run 记录。
    static func record(profile: Data) -> CoverageSnapshotRecord {
        CoverageSnapshotRecord(
            schemaVersion: 1,
            runID: runID,
            cycleID: cycleID,
            buildID: buildID,
            deviceID: "44444444-4444-4444-8444-444444444444",
            processID: 42,
            launchID: "55555555-5555-4555-8555-555555555555",
            capturedAt: "2026-09-03T00:00:00Z",
            appState: "active",
            triggerReason: "user_upload",
            profileRelativePath: "snapshots/\(buildID)/\(runID).profraw",
            size: profile.count,
            sha256: sha256Hex(profile),
            uploadStatus: .pending,
            retryCount: 0,
            lastError: nil,
            serverReceivedAt: nil,
            analyzable: nil
        )
    }

    /// 创建一个使用受限测试凭证的私网服务配置。
    static func configuration(host: String) throws -> CoverageServerConfiguration {
        try CoverageServerConfiguration.make(
            serverURLText: "http://\(host):8765",
            runUploadToken: token
        )
    }

    /// 返回协议要求的小写十六进制 SHA-256。
    static func sha256Hex(_ data: Data) -> String {
        CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
