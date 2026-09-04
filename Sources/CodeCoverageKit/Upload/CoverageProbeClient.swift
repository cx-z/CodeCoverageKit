#if CODE_COVERAGE_KIT_ENABLED
import CryptoKit
import Darwin
import Foundation

actor CoverageProbeClient {
    struct PreparedProbe {
        let request: URLRequest
        let body: Data
        let payloadSize: Int
        let sha256: String
    }

    struct HealthResult {
        let serverVersion: String
        let instanceID: String
        let serverTime: String
        let elapsedMilliseconds: Int
    }

    struct UploadResult {
        let probeID: String
        let size: Int
        let sha256: String
        let receivedAt: String
        let elapsedMilliseconds: Int
    }

    enum ClientError: LocalizedError {
        case missingToken
        case cancelled
        case localNetworkPermissionDenied
        case atsBlocked
        case dnsFailure
        case connectionFailure(String)
        case timeout
        case authenticationFailed
        case requestTooLarge(Int?)
        case checksumMismatch
        case serverRejected(Int, String)
        case invalidResponse(String)
        case transport(Int, String)

        var categoryTitle: String {
            switch self {
            case .missingToken:
                return "配置错误"
            case .cancelled:
                return "已取消"
            case .localNetworkPermissionDenied:
                return "本地网络权限错误"
            case .atsBlocked:
                return "ATS 错误"
            case .dnsFailure:
                return "地址解析错误"
            case .connectionFailure:
                return "连接错误"
            case .timeout:
                return "超时错误"
            case .authenticationFailed:
                return "鉴权错误"
            case .requestTooLarge, .checksumMismatch, .invalidResponse:
                return "上传校验错误"
            case .serverRejected:
                return "服务端错误"
            case .transport:
                return "网络错误"
            }
        }

        var errorDescription: String? {
            switch self {
            case .missingToken:
                return "当前测试包缺少有效的受限上传凭证。"
            case .cancelled:
                return "请求已取消。"
            case .localNetworkPermissionDenied:
                return "系统拒绝了本地网络访问。请在系统设置中允许本地网络后重试，不要绕过系统授权。"
            case .atsBlocked:
                return "App Transport Security 阻止了当前地址，请检查 URL 和 Debug 构建的 ATS 配置。"
            case .dnsFailure:
                return "无法解析服务主机，请检查 IP 或 .local 主机名。"
            case .connectionFailure(let detail):
                return "无法连接 Coverage 服务。请检查服务状态、Wi-Fi、VPN、服务地址和 AP/VLAN。\n\(detail)"
            case .timeout:
                return "请求超时。请检查 Coverage 服务、设备 VPN、当前 Wi-Fi 和 AP/VLAN 互访。"
            case .authenticationFailed:
                return "当前测试包的上传凭证不属于该服务器。"
            case .requestTooLarge(let maximumBytes):
                if let maximumBytes {
                    return "测试文件超过服务端限制（最大 \(maximumBytes) 字节），不会自动重试。"
                }
                return "测试请求或文件超过服务端限制，不会自动重试。"
            case .checksumMismatch:
                return "服务端计算的 SHA-256 与客户端声明不一致，文件未被接受。"
            case .serverRejected(let statusCode, let reason):
                return "服务端拒绝请求（HTTP \(statusCode)，\(reason)）。"
            case .invalidResponse(let reason):
                return "服务端响应未通过客户端校验：\(reason)。"
            case .transport(let code, let detail):
                return "网络请求失败（错误码 \(code)）：\(detail)"
            }
        }
    }

    private struct HealthResponse: Decodable {
        let status: String
        let serverVersion: String
        let serverTime: String
        let instanceID: String

        enum CodingKeys: String, CodingKey {
            case status
            case serverVersion = "server_version"
            case serverTime = "server_time"
            case instanceID = "instance_id"
        }
    }

    private struct UploadResponse: Decodable {
        let status: String
        let probeID: String
        let size: Int
        let sha256: String
        let sha256Matches: Bool
        let receivedAt: String

        enum CodingKeys: String, CodingKey {
            case status
            case probeID = "probe_id"
            case size
            case sha256
            case sha256Matches = "sha256_matches"
            case receivedAt = "received_at"
        }
    }

    private struct ErrorResponse: Decodable {
        let error: String?
        let maxFileBytes: Int?

        enum CodingKeys: String, CodingKey {
            case error
            case maxFileBytes = "max_file_bytes"
        }
    }

    private let vSession: URLSession
    private let vDecoder = JSONDecoder()

    /// 创建独立于业务网络栈的临时会话，避免 Host、登录态、加密或缓存影响 Coverage 网络诊断。
    init(session: URLSession? = nil) {
        if let session {
            vSession = session
        } else {
            let t_configuration = URLSessionConfiguration.ephemeral
            t_configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            t_configuration.timeoutIntervalForRequest = 10
            t_configuration.timeoutIntervalForResource = 20
            t_configuration.waitsForConnectivity = false
            vSession = URLSession(configuration: t_configuration)
        }
    }

    /// 主动请求无鉴权的 `/health`，并严格校验服务身份字段和响应耗时。
    func checkHealth(configuration: CoverageServerConfiguration) async throws -> HealthResult {
        let t_url = try p_endpointURL(baseURL: configuration.serverURL, path: "/health")
        var t_request = URLRequest(url: t_url)
        t_request.httpMethod = "GET"
        t_request.timeoutInterval = 8
        t_request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let t_startedAt = CFAbsoluteTimeGetCurrent()
        let (t_data, t_response) = try await p_execute(t_request)
        guard t_response.statusCode == 200 else {
            throw p_serverError(statusCode: t_response.statusCode, data: t_data)
        }
        guard let t_payload = try? vDecoder.decode(HealthResponse.self, from: t_data),
              t_payload.status == "ok",
              !t_payload.instanceID.isEmpty,
              !t_payload.serverVersion.isEmpty else {
            throw ClientError.invalidResponse("/health 缺少 status、instance_id 或 server_version")
        }
        return HealthResult(
            serverVersion: t_payload.serverVersion,
            instanceID: t_payload.instanceID,
            serverTime: t_payload.serverTime,
            elapsedMilliseconds: p_elapsedMilliseconds(since: t_startedAt)
        )
    }

    /// 生成不含业务数据的小文件并主动上传到 `/api/v1/probes`，只接受完整回显校验通过的 201 响应。
    func uploadTestProbe(configuration: CoverageServerConfiguration) async throws -> UploadResult {
        let t_preparedProbe = try prepareTestProbe(configuration: configuration)
        let t_startedAt = CFAbsoluteTimeGetCurrent()
        let (t_data, t_response) = try await p_execute(t_preparedProbe.request)
        guard t_response.statusCode == 201 else {
            throw p_serverError(statusCode: t_response.statusCode, data: t_data)
        }
        guard let t_result = try? vDecoder.decode(UploadResponse.self, from: t_data) else {
            throw ClientError.invalidResponse("上传成功响应不是约定 JSON")
        }
        guard t_result.status == "accepted" else {
            throw ClientError.invalidResponse("status 不是 accepted")
        }
        guard t_result.sha256Matches,
              t_result.sha256.lowercased() == t_preparedProbe.sha256,
              t_result.size == t_preparedProbe.payloadSize,
              !t_result.probeID.isEmpty else {
            throw ClientError.invalidResponse("probe_id、size 或 SHA-256 回显不一致")
        }
        return UploadResult(
            probeID: t_result.probeID,
            size: t_result.size,
            sha256: t_result.sha256,
            receivedAt: t_result.receivedAt,
            elapsedMilliseconds: p_elapsedMilliseconds(since: t_startedAt)
        )
    }

    /// 构造可检查的探针请求与请求体，同时保留 payload 大小和摘要供响应校验使用。
    func prepareTestProbe(configuration: CoverageServerConfiguration) throws -> PreparedProbe {
        guard !configuration.runUploadToken.isEmpty else {
            throw ClientError.missingToken
        }
        let t_payload = try p_makeTestPayload()
        let t_sha256 = p_sha256Hex(t_payload)
        let t_boundary = "code-coverage-kit-probe-\(UUID().uuidString)"
        let t_body = p_makeMultipartBody(payload: t_payload, sha256: t_sha256, boundary: t_boundary)
        let t_url = try p_endpointURL(baseURL: configuration.serverURL, path: "/api/v1/probes")
        var t_request = URLRequest(url: t_url)
        t_request.httpMethod = "POST"
        t_request.timeoutInterval = 15
        t_request.setValue("Bearer \(configuration.runUploadToken)", forHTTPHeaderField: "Authorization")
        t_request.setValue("multipart/form-data; boundary=\(t_boundary)", forHTTPHeaderField: "Content-Type")
        t_request.setValue(String(t_body.count), forHTTPHeaderField: "Content-Length")
        t_request.httpBody = t_body
        return PreparedProbe(request: t_request, body: t_body, payloadSize: t_payload.count, sha256: t_sha256)
    }

    /// 执行单次 URLSession 请求，并把系统错误映射成可定位的稳定错误类别。
    private func p_execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (t_data, t_response) = try await vSession.data(for: request)
            guard let t_httpResponse = t_response as? HTTPURLResponse else {
                throw ClientError.invalidResponse("缺少 HTTP 状态码")
            }
            return (t_data, t_httpResponse)
        } catch let t_error as ClientError {
            throw t_error
        } catch {
            throw p_transportError(error)
        }
    }

    /// 在已校验根地址上构造平台约定的固定服务端路径。
    private func p_endpointURL(baseURL: URL, path: String) throws -> URL {
        guard var t_components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidResponse("无法构造请求地址")
        }
        t_components.path = path
        guard let t_url = t_components.url else {
            throw ClientError.invalidResponse("无法构造请求地址")
        }
        return t_url
    }

    /// 构造仅含协议标识、随机 nonce 和时间的测试 JSON，不读取任何业务或设备身份数据。
    private func p_makeTestPayload() throws -> Data {
        let t_payload: [String: Any] = [
            "schema_version": 1,
            "kind": "code-coverage-kit-network-probe",
            "nonce": UUID().uuidString,
            "created_at": ISO8601DateFormatter().string(from: Date())
        ]
        return try JSONSerialization.data(withJSONObject: t_payload, options: [.sortedKeys])
    }

    /// 按平台协议构造只包含 `sha256` 和 `file` 两个字段的 multipart 请求体。
    private func p_makeMultipartBody(payload: Data, sha256: String, boundary: String) -> Data {
        var t_body = Data()
        t_body.append(p_utf8Data("--\(boundary)\r\n"))
        t_body.append(p_utf8Data("Content-Disposition: form-data; name=\"sha256\"\r\n\r\n"))
        t_body.append(p_utf8Data("\(sha256)\r\n"))
        t_body.append(p_utf8Data("--\(boundary)\r\n"))
        t_body.append(p_utf8Data("Content-Disposition: form-data; name=\"file\"; filename=\"code-coverage-kit-network-probe.json\"\r\n"))
        t_body.append(p_utf8Data("Content-Type: application/json\r\n\r\n"))
        t_body.append(payload)
        t_body.append(p_utf8Data("\r\n--\(boundary)--\r\n"))
        return t_body
    }

    /// 计算服务端要求的小写十六进制 SHA-256。
    private func p_sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 将 HTTP 错误响应映射为鉴权、大小、校验或通用服务端错误。
    private func p_serverError(statusCode: Int, data: Data) -> ClientError {
        let t_payload = try? vDecoder.decode(ErrorResponse.self, from: data)
        let t_reason = t_payload?.error ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
        switch statusCode {
        case 401, 403:
            return .authenticationFailed
        case 413:
            return .requestTooLarge(t_payload?.maxFileBytes)
        case 422:
            return .checksumMismatch
        default:
            return .serverRejected(statusCode, t_reason)
        }
    }

    /// 将 URLSession 与底层 POSIX 错误归类，保留无法进一步识别时的原始错误码。
    private func p_transportError(_ error: Error) -> ClientError {
        if error is CancellationError {
            return .cancelled
        }
        let t_nsError = error as NSError
        if p_containsPermissionDenied(t_nsError) {
            return .localNetworkPermissionDenied
        }
        guard let t_urlError = error as? URLError else {
            return .transport(t_nsError.code, t_nsError.localizedDescription)
        }
        switch t_urlError.code {
        case .cancelled:
            return .cancelled
        case .appTransportSecurityRequiresSecureConnection:
            return .atsBlocked
        case .cannotFindHost, .dnsLookupFailed:
            return .dnsFailure
        case .timedOut:
            return .timeout
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable:
            return .connectionFailure(t_urlError.localizedDescription)
        default:
            return .transport(t_urlError.errorCode, t_urlError.localizedDescription)
        }
    }

    /// 沿公开的 underlying-error 链检查 EACCES/EPERM，避免把普通断网误报为权限拒绝。
    private func p_containsPermissionDenied(_ error: NSError) -> Bool {
        var t_currentError: NSError? = error
        for _ in 0..<6 {
            guard let t_error = t_currentError else { return false }
            if t_error.domain == NSPOSIXErrorDomain && (t_error.code == Int(EACCES) || t_error.code == Int(EPERM)) {
                return true
            }
            t_currentError = t_error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// 将字符串稳定转换为 UTF-8 数据供 multipart 边界拼接使用。
    private func p_utf8Data(_ string: String) -> Data {
        Data(string.utf8)
    }

    /// 将请求起点转换为便于 Debug 页面展示的整数毫秒耗时。
    private func p_elapsedMilliseconds(since startTime: CFAbsoluteTime) -> Int {
        max(0, Int((CFAbsoluteTimeGetCurrent() - startTime) * 1_000))
    }
}
#endif
