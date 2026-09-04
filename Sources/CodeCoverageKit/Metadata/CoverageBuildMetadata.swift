#if CODE_COVERAGE_KIT_ENABLED
import Foundation

struct CoverageBuildMetadata: Codable, Equatable, Sendable {
    static let resourceName = "CodeCoverageBuildMetadata"

    enum MetadataError: LocalizedError {
        case missing
        case unreadable
        case unsupportedSchema(Int)
        case invalidIdentifier(String)
        case missingValue(String)
        case invalidValue(String)

        var errorDescription: String? {
            switch self {
            case .missing:
                return "当前 App 没有 Coverage Build 元数据；请使用完成 Build 注册和 metadata 注入的 Coverage Debug 构建。"
            case .unreadable:
                return "Coverage Build metadata 无法读取或解析。"
            case .unsupportedSchema(let version):
                return "不支持的 Coverage Build 元数据版本：\(version)。"
            case .invalidIdentifier(let field):
                return "Coverage Build 元数据中的 \(field) 不是有效 UUID。"
            case .missingValue(let field):
                return "Coverage Build 元数据缺少 \(field)。"
            case .invalidValue(let field):
                return "Coverage Build 元数据中的 \(field) 无效。"
            }
        }
    }

    let schemaVersion: Int
    let project: String
    let cycleID: String
    let buildID: String
    let gitSHA: String
    let targetSHAAtBuild: String
    let mergeBaseSHA: String
    let bundleID: String
    let appVersion: String
    let bundleVersion: String
    let xcodeVersion: String
    let coverageServerURL: URL
    let runUploadToken: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case project
        case cycleID = "cycle_id"
        case buildID = "build_id"
        case gitSHA = "git_sha"
        case targetSHAAtBuild = "target_sha_at_build"
        case mergeBaseSHA = "merge_base_sha"
        case bundleID = "bundle_id"
        case appVersion = "app_version"
        case bundleVersion = "bundle_version"
        case xcodeVersion = "xcode_version"
        case coverageServerURL = "coverage_server_url"
        case runUploadToken = "run_upload_token"
    }

    /// 从 App Bundle 读取中性 metadata 文件，并严格校验其中的 Build 身份。
    static func load(bundle: Bundle = .main) throws -> CoverageBuildMetadata {
        guard let t_url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw MetadataError.missing
        }
        guard let t_data = try? Data(contentsOf: t_url) else {
            throw MetadataError.unreadable
        }
        return try decode(t_data)
    }

    /// 解码并校验一份 metadata 数据，供 Bundle 加载和无宿主单元测试共用同一规则。
    static func decode(_ data: Data) throws -> CoverageBuildMetadata {
        let t_metadata: CoverageBuildMetadata
        do {
            t_metadata = try JSONDecoder().decode(CoverageBuildMetadata.self, from: data)
        } catch DecodingError.keyNotFound(let key, _) {
            throw MetadataError.missingValue(key.stringValue)
        } catch DecodingError.valueNotFound(_, let context),
                DecodingError.typeMismatch(_, let context),
                DecodingError.dataCorrupted(let context) {
            throw MetadataError.invalidValue(context.codingPath.last?.stringValue ?? "metadata")
        } catch {
            throw MetadataError.unreadable
        }
        try t_metadata.p_validate()
        return t_metadata
    }

    /// 校验协议版本、Build 身份、包内默认服务地址和受限上传凭证，且错误中不回显凭证。
    private func p_validate() throws {
        guard schemaVersion == 1 else {
            throw MetadataError.unsupportedSchema(schemaVersion)
        }
        guard UUID(uuidString: cycleID) != nil else {
            throw MetadataError.invalidIdentifier("cycle_id")
        }
        guard UUID(uuidString: buildID) != nil else {
            throw MetadataError.invalidIdentifier("build_id")
        }
        let t_values = [
            "project": project,
            "git_sha": gitSHA,
            "target_sha_at_build": targetSHAAtBuild,
            "merge_base_sha": mergeBaseSHA,
            "bundle_id": bundleID,
            "app_version": appVersion,
            "bundle_version": bundleVersion,
            "xcode_version": xcodeVersion,
            "coverage_server_url": coverageServerURL.absoluteString,
            "run_upload_token": runUploadToken.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        if let t_missing = t_values.first(where: { $0.value.isEmpty })?.key {
            throw MetadataError.missingValue(t_missing)
        }
        do {
            _ = try CoverageServerConfiguration.normalizedServerURL(from: coverageServerURL.absoluteString)
        } catch {
            throw MetadataError.invalidValue("coverage_server_url")
        }
    }
}
#endif
