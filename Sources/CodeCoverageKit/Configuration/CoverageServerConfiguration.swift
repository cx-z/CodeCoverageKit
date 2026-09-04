#if CODE_COVERAGE_KIT_ENABLED
import Foundation

struct CoverageServerConfiguration: Equatable, Sendable {
    enum ValidationError: LocalizedError {
        case emptyServerURL
        case invalidServerURL
        case unsupportedScheme
        case unsupportedHost
        case unsupportedPath
        case invalidPort
        case missingRunUploadCredential

        var errorDescription: String? {
            switch self {
            case .emptyServerURL:
                return "请输入 Coverage 服务 URL。"
            case .invalidServerURL:
                return "服务 URL 格式无效，请使用完整的 http:// 或 https:// 地址。"
            case .unsupportedScheme:
                return "服务 URL 只支持 http 或 https。"
            case .unsupportedHost:
                return "只允许私有 IPv4 地址、链路本地 IPv4 或 .local 主机，不能上传到公网地址。"
            case .unsupportedPath:
                return "服务 URL 只能填写主机和端口，不能包含路径、查询参数或账号信息。"
            case .invalidPort:
                return "服务端口必须位于 1...65535。"
            case .missingRunUploadCredential:
                return "当前测试包缺少有效的受限上传凭证。"
            }
        }
    }

    let serverURL: URL
    let runUploadToken: String

    /// 校验地址和包内受限凭证，并生成一次网络操作使用的不可变配置快照。
    static func make(serverURLText: String, runUploadToken: String) throws -> CoverageServerConfiguration {
        let t_serverURL = try normalizedServerURL(from: serverURLText)
        let t_runUploadToken = runUploadToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t_runUploadToken.isEmpty else {
            throw ValidationError.missingRunUploadCredential
        }
        return CoverageServerConfiguration(
            serverURL: t_serverURL,
            runUploadToken: t_runUploadToken
        )
    }

    /// 规范化并校验局域网服务根地址，供 Bundle metadata 与用户覆盖地址共用同一安全边界。
    static func normalizedServerURL(from serverURLText: String) throws -> URL {
        let t_serverURLText = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t_serverURLText.isEmpty else {
            throw ValidationError.emptyServerURL
        }
        guard var t_components = URLComponents(string: t_serverURLText),
              let t_scheme = t_components.scheme?.lowercased(),
              let t_host = t_components.host?.lowercased() else {
            throw ValidationError.invalidServerURL
        }
        guard t_scheme == "http" || t_scheme == "https" else {
            throw ValidationError.unsupportedScheme
        }
        guard p_isAllowedLANHost(t_host) else {
            throw ValidationError.unsupportedHost
        }
        guard t_components.user == nil,
              t_components.password == nil,
              t_components.query == nil,
              t_components.fragment == nil,
              t_components.path.isEmpty || t_components.path == "/" else {
            throw ValidationError.unsupportedPath
        }
        if let t_port = t_components.port, !(1...65535).contains(t_port) {
            throw ValidationError.invalidPort
        }
        t_components.scheme = t_scheme
        t_components.host = t_host
        t_components.path = ""
        guard let t_serverURL = t_components.url else {
            throw ValidationError.invalidServerURL
        }
        return t_serverURL
    }

    /// 判断主机是否属于 SDK 允许的私有 IPv4、链路本地 IPv4 或 .local 地址。
    private static func p_isAllowedLANHost(_ host: String) -> Bool {
        if host.hasSuffix(".local") {
            return host.count > ".local".count
        }
        let t_octets = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard t_octets.count == 4 else { return false }
        switch (t_octets[0], t_octets[1]) {
        case (10, _):
            return true
        case (172, 16...31):
            return true
        case (192, 168):
            return true
        case (169, 254):
            return true
        default:
            return false
        }
    }
}
#endif
