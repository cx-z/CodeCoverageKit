#if CODE_COVERAGE_KIT_ENABLED
import CryptoKit
import Foundation

final class CoverageSnapshotStore {
    static let directoryName = "CodeCoverageKit"

    enum StoreError: LocalizedError {
        case applicationSupportUnavailable
        case invalidRelativePath
        case profileMissing(String)
        case profileMismatch(String)

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                return "无法访问 Application Support，覆盖率快照不能持久化。"
            case .invalidRelativePath:
                return "覆盖率快照记录包含无效的相对路径。"
            case .profileMissing(let runID):
                return "Run \(runID) 的 .profraw 文件不存在。"
            case .profileMismatch(let runID):
                return "Run \(runID) 的 .profraw 大小或 SHA-256 与清单不一致。"
            }
        }
    }

    private struct DeviceIdentity: Codable {
        let schemaVersion: Int
        let deviceID: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case deviceID = "device_id"
        }
    }

    private let vFileManager: FileManager
    private let vRootURL: URL
    private let vEncoder: JSONEncoder
    private let vDecoder = JSONDecoder()

    /// 创建仅供 Collector 串行队列持有的快照存储，并固定 Application Support 根目录。
    init(fileManager: FileManager = .default, rootURL: URL? = nil) throws {
        vFileManager = fileManager
        if let rootURL {
            vRootURL = rootURL
        } else {
            guard let t_applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw StoreError.applicationSupportUnavailable
            }
            vRootURL = Self.rootURL(applicationSupportURL: t_applicationSupport)
        }
        vEncoder = JSONEncoder()
        vEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try p_createDirectory(vRootURL)
        try p_createDirectory(p_snapshotsRootURL())
    }

    /// 返回 SDK 在 Application Support 下独占使用的中性存储根目录。
    static func rootURL(applicationSupportURL: URL) -> URL {
        applicationSupportURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// 读取或首次生成模块专用匿名 device_id，并通过原子文件写保证重启和覆盖安装后稳定。
    func loadOrCreateDeviceID() throws -> String {
        let t_url = vRootURL.appendingPathComponent("device.json")
        if let t_data = try? Data(contentsOf: t_url),
           let t_identity = try? vDecoder.decode(DeviceIdentity.self, from: t_data),
           t_identity.schemaVersion == 1,
           UUID(uuidString: t_identity.deviceID) != nil {
            return t_identity.deviceID
        }
        let t_deviceID = UUID().uuidString.lowercased()
        let t_identity = DeviceIdentity(schemaVersion: 1, deviceID: t_deviceID)
        try p_writeAtomically(try vEncoder.encode(t_identity), to: t_url)
        return t_deviceID
    }

    /// 将一份 LLVM buffer 快照和其独立清单按 Build 分目录原子落盘，返回可排队上传的记录。
    func createSnapshot(
        profileData: Data,
        metadata: CoverageBuildMetadata,
        deviceID: String,
        launchID: String,
        appState: String,
        triggerReason: String
    ) throws -> CoverageSnapshotRecord {
        let t_runID = UUID().uuidString.lowercased()
        let t_buildDirectory = p_snapshotsRootURL().appendingPathComponent(metadata.buildID, isDirectory: true)
        try p_createDirectory(t_buildDirectory)
        let t_profileURL = t_buildDirectory.appendingPathComponent("\(t_runID).profraw")
        try p_writeAtomically(profileData, to: t_profileURL)
        let t_record = CoverageSnapshotRecord(
            schemaVersion: 1,
            runID: t_runID,
            cycleID: metadata.cycleID,
            buildID: metadata.buildID,
            deviceID: deviceID,
            processID: getpid(),
            launchID: launchID,
            capturedAt: Self.p_timestamp(Date()),
            appState: appState,
            triggerReason: triggerReason,
            profileRelativePath: "snapshots/\(metadata.buildID)/\(t_runID).profraw",
            size: profileData.count,
            sha256: Self.p_sha256Hex(profileData),
            uploadStatus: .pending,
            retryCount: 0,
            lastError: nil,
            serverReceivedAt: nil,
            analyzable: nil
        )
        try update(record: t_record)
        return t_record
    }

    /// 原子覆盖指定 Run 清单；profile 文件身份和路径保持不可变。
    func update(record: CoverageSnapshotRecord) throws {
        guard UUID(uuidString: record.runID) != nil, UUID(uuidString: record.buildID) != nil else {
            throw StoreError.invalidRelativePath
        }
        let t_directory = p_snapshotsRootURL().appendingPathComponent(record.buildID, isDirectory: true)
        try p_createDirectory(t_directory)
        let t_manifestURL = t_directory.appendingPathComponent("\(record.runID).json")
        try p_writeAtomically(try vEncoder.encode(record), to: t_manifestURL)
    }

    /// 恢复所有 Build 的快照清单，将进程中断遗留的 uploading 状态安全退回 pending。
    func loadRecords() throws -> [CoverageSnapshotRecord] {
        let t_buildDirectories = try vFileManager.contentsOfDirectory(
            at: p_snapshotsRootURL(),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var t_records: [CoverageSnapshotRecord] = []
        for t_directory in t_buildDirectories {
            let t_values = try t_directory.resourceValues(forKeys: [.isDirectoryKey])
            guard t_values.isDirectory == true else { continue }
            let t_manifestURLs = try vFileManager.contentsOfDirectory(
                at: t_directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
            for t_manifestURL in t_manifestURLs {
                var t_record = try vDecoder.decode(CoverageSnapshotRecord.self, from: Data(contentsOf: t_manifestURL))
                if t_record.uploadStatus == .uploading {
                    t_record.uploadStatus = .pending
                    t_record.lastError = "上次上传流程被进程退出中断，已恢复为待上传。"
                    try update(record: t_record)
                }
                try validateProfile(record: t_record)
                t_records.append(t_record)
            }
        }
        return t_records.sorted { $0.capturedAt < $1.capturedAt }
    }

    /// 解析并校验记录引用的 profile 路径，阻止绝对路径或目录穿越离开模块根目录。
    func profileURL(record: CoverageSnapshotRecord) throws -> URL {
        guard !record.profileRelativePath.hasPrefix("/"),
              !record.profileRelativePath.split(separator: "/").contains("..") else {
            throw StoreError.invalidRelativePath
        }
        let t_url = vRootURL.appendingPathComponent(record.profileRelativePath).standardizedFileURL
        let t_rootPath = vRootURL.standardizedFileURL.path + "/"
        guard t_url.path.hasPrefix(t_rootPath) else {
            throw StoreError.invalidRelativePath
        }
        return t_url
    }

    /// 重新读取文件并核对大小和 SHA-256，上传前确保磁盘内容仍与记录身份一致。
    func validateProfile(record: CoverageSnapshotRecord) throws {
        let t_url = try profileURL(record: record)
        guard vFileManager.fileExists(atPath: t_url.path) else {
            throw StoreError.profileMissing(record.runID)
        }
        let t_data = try Data(contentsOf: t_url, options: [.mappedIfSafe])
        guard t_data.count == record.size, Self.p_sha256Hex(t_data) == record.sha256 else {
            throw StoreError.profileMismatch(record.runID)
        }
    }

    /// 创建模块拥有的目录，并将其排除出设备备份以避免 Debug 数据进入云端。
    private func p_createDirectory(_ url: URL) throws {
        try vFileManager.createDirectory(at: url, withIntermediateDirectories: true)
        var t_url = url
        var t_values = URLResourceValues()
        t_values.isExcludedFromBackup = true
        try? t_url.setResourceValues(t_values)
    }

    /// 返回按 Build 分组的快照根目录，不访问或创建其他业务文件。
    private func p_snapshotsRootURL() -> URL {
        vRootURL.appendingPathComponent("snapshots", isDirectory: true)
    }

    /// 使用 Foundation 的同目录临时文件与原子替换语义提交完整文件。
    private func p_writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }

    /// 生成包含时区且能被服务端稳定解析的 ISO-8601 时间字符串。
    private static func p_timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// 计算协议要求的小写十六进制 SHA-256。
    private static func p_sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
