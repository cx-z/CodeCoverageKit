#if CODE_COVERAGE_KIT_ENABLED
import Foundation

struct CoverageSnapshotRecord: Codable, Equatable, Sendable {
    enum UploadStatus: String, Codable, Sendable {
        case pending
        case uploading
        case uploaded
        case failedRetryable = "failed_retryable"
        case failedPermanent = "failed_permanent"
    }

    let schemaVersion: Int
    let runID: String
    let cycleID: String
    let buildID: String
    let deviceID: String
    let processID: Int32
    let launchID: String
    let capturedAt: String
    let appState: String
    let triggerReason: String
    let profileRelativePath: String
    let size: Int
    let sha256: String
    var uploadStatus: UploadStatus
    var retryCount: Int
    var lastError: String?
    var serverReceivedAt: String?
    var analyzable: Bool?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case cycleID = "cycle_id"
        case buildID = "build_id"
        case deviceID = "device_id"
        case processID = "process_id"
        case launchID = "launch_id"
        case capturedAt = "captured_at"
        case appState = "app_state"
        case triggerReason = "trigger_reason"
        case profileRelativePath = "profile_relative_path"
        case size
        case sha256
        case uploadStatus = "upload_status"
        case retryCount = "retry_count"
        case lastError = "last_error"
        case serverReceivedAt = "server_received_at"
        case analyzable
    }

    /// 返回 Run API 所需且与该快照自身 Build 身份绑定的稳定 metadata 数据。
    func makeRunMetadataData() throws -> Data {
        let t_payload: [String: Any] = [
            "schema_version": schemaVersion,
            "run_id": runID,
            "cycle_id": cycleID,
            "build_id": buildID,
            "device_id": deviceID,
            "process_id": processID,
            "launch_id": launchID,
            "captured_at": capturedAt,
            "app_state": appState,
            "trigger_reason": triggerReason
        ]
        return try JSONSerialization.data(withJSONObject: t_payload, options: [.sortedKeys])
    }
}
#endif
