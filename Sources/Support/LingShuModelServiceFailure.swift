import Foundation

/// 模型通道故障的通用分类。
///
/// 关键边界:
/// - 网络/5xx/限流:可能自行恢复,可以挂起后重试。
/// - 鉴权/额度/参数:不会因为“等一下”变好,必须停止自动重试并向用户暴露真实原因。
struct LingShuModelServiceFailure: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case network
        case timeout
        case rateLimited
        case auth
        case quota
        case multimodalUnsupported
        case requestInvalid
        case server
        case unknown
    }

    static let marker = "LINGSHU_MODEL_SERVICE_FAILURE::"

    var kind: Kind
    var statusCode: Int?
    var detail: String

    var shouldRetryRequest: Bool {
        switch kind {
        case .network, .timeout, .rateLimited, .server, .unknown:
            return true
        case .auth, .quota, .multimodalUnsupported, .requestInvalid:
            return false
        }
    }

    var shouldAutoResume: Bool {
        switch kind {
        case .network, .timeout, .rateLimited, .server:
            return true
        case .auth, .quota, .multimodalUnsupported, .requestInvalid, .unknown:
            return false
        }
    }

    var taskStatus: LingShuTaskExecutionStatus {
        switch kind {
        case .auth, .quota:
            return .waitingForUser
        case .multimodalUnsupported, .requestInvalid, .unknown:
            return .failed
        case .network, .timeout, .rateLimited, .server:
            return .suspended
        }
    }

    var userFacingMessage: String {
        let suffix = detail.isEmpty ? "" : "：\(detail)"
        switch kind {
        case .network:
            return "模型通道网络不可达\(suffix)。我已暂停这条任务，通道恢复后可以继续。"
        case .timeout:
            return "模型通道响应超时\(suffix)。我已暂停这条任务，通道恢复后可以继续。"
        case .rateLimited:
            return "模型服务限流\(suffix)。我已暂停这条任务，稍后可以继续。"
        case .auth:
            return "模型服务认证失败\(suffix)。请检查 API Key、登录状态或模型权限后再继续。"
        case .quota:
            return "模型服务额度异常\(suffix)。请充值、提升额度或切换可用模型后再继续。"
        case .multimodalUnsupported:
            return "当前模型通道拒绝原生多模态输入\(suffix)。我会把该模型标记为不支持原生多模态，并降级为图片解析后再发。"
        case .requestInvalid:
            return "模型请求被服务端拒绝\(suffix)。这更像是请求结构、参数或模型适配问题，不应按网络故障重试。"
        case .server:
            return "模型服务端异常\(suffix)。我已暂停这条任务，服务恢复后可以继续。"
        case .unknown:
            return "模型服务返回未知异常\(suffix)。我已停止自动重试，避免队列空转。"
        }
    }

    var retryingMessage: String {
        switch kind {
        case .network:
            return "模型通道网络不可达，已暂停任务，正在重试"
        case .timeout:
            return "模型通道响应超时，已暂停任务，正在重试"
        case .rateLimited:
            return "模型服务限流，已暂停任务，正在等待可用窗口"
        case .server:
            return "模型服务暂不可用，已暂停任务，正在重试"
        case .auth:
            return "模型服务认证失败，等待你处理模型配置"
        case .quota:
            return "模型服务额度异常，等待你处理额度或切换模型"
        case .multimodalUnsupported:
            return "当前模型不支持原生多模态，本轮将降级为图片解析"
        case .requestInvalid:
            return "模型请求被拒绝，等待适配修正"
        case .unknown:
            return "模型服务返回未知异常，已停止自动重试"
        }
    }

    var retryStillUnavailableMessage: String {
        switch kind {
        case .network:
            return "模型通道网络仍不可达"
        case .timeout:
            return "模型通道仍响应超时"
        case .rateLimited:
            return "模型服务仍在限流"
        case .server:
            return "模型服务仍暂不可用"
        case .auth:
            return "模型服务认证仍未恢复"
        case .quota:
            return "模型服务额度仍不可用"
        case .multimodalUnsupported:
            return "当前模型仍不支持原生多模态"
        case .requestInvalid:
            return "模型请求仍被拒绝"
        case .unknown:
            return "模型服务仍未知异常"
        }
    }

    var resumedMessage: String {
        switch kind {
        case .network:
            return "模型通道网络已恢复，正在接着把任务跑完。"
        case .timeout, .rateLimited, .server:
            return "模型通道已恢复，正在接着把任务跑完。"
        case .auth, .quota, .multimodalUnsupported, .requestInvalid, .unknown:
            return userFacingMessage
        }
    }

    static func retryingText(for reason: String, pendingCount: Int, attempt: Int) -> String {
        let base = decodeReason(reason)?.retryingMessage ?? "模型通道暂不可用，已暂停任务，正在重试"
        return "⏸ \(base)（\(pendingCount) 个任务，第 \(attempt) 次）…"
    }

    static func stillUnavailableText(for reason: String, attempt: Int, delay: Int) -> String {
        let base = decodeReason(reason)?.retryStillUnavailableMessage ?? "模型通道仍不可用"
        return "⏸ \(base)，已重试 \(attempt) 次，约 \(delay)s 后再试…"
    }

    static func resumedText(for reason: String?) -> String {
        guard let reason, let failure = decodeReason(reason) else {
            return "模型通道已恢复，正在接着把任务跑完。"
        }
        return failure.resumedMessage
    }

    static func suspendedSummary(for reason: String) -> String {
        if let failure = decodeReason(reason) {
            return failure.userFacingMessage
        }
        return reason.isEmpty ? "模型通道暂不可用，已暂停任务，通道恢复后可以继续。" : reason
    }

    var encodedReason: String {
        "\(Self.marker)\(kind.rawValue)::\(statusCode.map(String.init) ?? "-")::\(userFacingMessage)"
    }

    static func decodeReason(_ reason: String) -> LingShuModelServiceFailure? {
        guard reason.hasPrefix(marker) else { return nil }
        let rest = String(reason.dropFirst(marker.count))
        let parts = rest.components(separatedBy: "::")
        guard parts.count >= 3, let kind = Kind(rawValue: parts[0]) else { return nil }
        let code = parts[1] == "-" ? nil : Int(parts[1])
        let message = parts.dropFirst(2).joined(separator: "::")
        return LingShuModelServiceFailure(kind: kind, statusCode: code, detail: message)
    }

    static func isNonRecoverableReason(_ reason: String) -> Bool {
        guard let failure = decodeReason(reason) else { return false }
        return !failure.shouldAutoResume
    }

    static func userFacingReason(_ reason: String) -> String {
        decodeReason(reason)?.detail ?? reason
    }

    static func isNativeMultimodalUnsupportedReason(_ reason: String) -> Bool {
        decodeReason(reason)?.kind == .multimodalUnsupported
    }

    static func classify(_ error: Error) -> LingShuModelServiceFailure {
        if let gatewayError = error as? LingShuModelGatewayError {
            return classify(gatewayError)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return .init(kind: .timeout, statusCode: nil, detail: "请求超时")
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorInternationalRoamingOff,
                 NSURLErrorDataNotAllowed:
                return .init(kind: .network, statusCode: nil, detail: nsError.localizedDescription)
            default:
                return .init(kind: .unknown, statusCode: nil, detail: nsError.localizedDescription)
            }
        }

        let raw = String(describing: error)
        return classify(statusCode: nil, body: raw)
    }

    static func classify(_ error: LingShuModelGatewayError) -> LingShuModelServiceFailure {
        switch error {
        case .missingAPIKey:
            return .init(kind: .auth, statusCode: nil, detail: "未配置 API Key")
        case .hostAdapterRequired(let name):
            return .init(kind: .requestInvalid, statusCode: nil, detail: "缺少宿主适配器 \(name)")
        case .invalidEndpoint(let endpoint):
            return .init(kind: .requestInvalid, statusCode: nil, detail: "Endpoint 无效 \(endpoint)")
        case .requestFailed(let code, let body):
            return classify(statusCode: code, body: body)
        case .emptyResponse, .unsupportedResponse:
            return .init(kind: .server, statusCode: nil, detail: "服务端返回空响应或不支持的响应格式")
        }
    }

    static func classify(statusCode: Int?, body: String) -> LingShuModelServiceFailure {
        let detail = sanitizedDetail(body)
        let lower = body.lowercased()

        if containsAny(lower, [
            "欠费", "余额不足", "余额不够", "额度不足", "额度已用尽", "账户余额",
            "insufficient_quota", "insufficient quota", "quota exceeded", "out of quota",
            "insufficient balance", "balance insufficient", "billing", "payment required",
            "credit exhausted", "credits exhausted", "resource exhausted"
        ]) || statusCode == 402 {
            return .init(kind: .quota, statusCode: statusCode, detail: detail)
        }

        if containsAny(lower, [
            "unauthorized", "forbidden", "invalid api key", "invalid_api_key",
            "authentication", "permission denied", "access denied", "无权限", "认证失败",
            "鉴权失败", "token invalid", "invalid token"
        ]) || statusCode == 401 || statusCode == 403 {
            return .init(kind: .auth, statusCode: statusCode, detail: detail)
        }

        if containsAny(lower, ["rate limit", "too many requests", "限流", "请求过多"]) || statusCode == 429 {
            return .init(kind: .rateLimited, statusCode: statusCode, detail: detail)
        }

        if looksLikeNativeMultimodalUnsupported(lower, statusCode: statusCode) {
            return .init(kind: .multimodalUnsupported, statusCode: statusCode, detail: detail)
        }

        if let statusCode {
            if statusCode == -1 {
                return .init(kind: .network, statusCode: statusCode, detail: detail)
            }
            if statusCode == 408 {
                return .init(kind: .timeout, statusCode: statusCode, detail: detail)
            }
            if (400..<500).contains(statusCode) {
                return .init(kind: .requestInvalid, statusCode: statusCode, detail: detail)
            }
            if statusCode >= 500 {
                return .init(kind: .server, statusCode: statusCode, detail: detail)
            }
        }

        if containsAny(lower, ["timed out", "timeout", "超时"]) {
            return .init(kind: .timeout, statusCode: statusCode, detail: detail)
        }
        if containsAny(lower, ["network", "connection lost", "cannot connect", "not connected", "断开", "连接失败"]) {
            return .init(kind: .network, statusCode: statusCode, detail: detail)
        }
        return .init(kind: .unknown, statusCode: statusCode, detail: detail)
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0.lowercased()) }
    }

    private static func looksLikeNativeMultimodalUnsupported(_ lower: String, statusCode: Int?) -> Bool {
        guard statusCode == nil || (400..<500).contains(statusCode ?? 400) else { return false }
        if lower.contains("image_url") || lower.contains("input_image") || lower.contains("image input") {
            return containsAny(lower, [
                "not support", "unsupported", "invalid", "not allowed", "only text",
                "不支持", "暂不支持", "非法", "无效"
            ])
        }
        if lower.contains("multimodal") || lower.contains("multi-modal") || lower.contains("多模态") {
            return containsAny(lower, ["not support", "unsupported", "不支持", "暂不支持", "disabled", "disable"])
        }
        if lower.contains("content") && lower.contains("array")
            && containsAny(lower, ["not support", "unsupported", "invalid", "不支持", "无效"]) {
            return true
        }
        if lower.contains("image") && lower.contains("content")
            && containsAny(lower, ["not support", "unsupported", "invalid", "不支持", "无效"]) {
            return true
        }
        return false
    }

    private static func sanitizedDetail(_ body: String) -> String {
        var text = body.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        if text.count > 220 {
            return String(text.prefix(220)) + "..."
        }
        return text
    }
}
