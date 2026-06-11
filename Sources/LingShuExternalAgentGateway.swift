import Foundation

enum LingShuExternalAgentGatewayError: Error, Equatable {
    case localAgentRequiresHostAdapter(String)
    case invalidEndpoint(String)
    case nonHTTPResponse
}

struct LingShuExternalAgentInvocationContract: Equatable {
    var url: URL
    var method: String
    var headers: [String: String]
    var body: Data
    var transport: LingShuExternalAgentTransport
}

struct LingShuExternalAgentGateway {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.encoder = encoder
        self.decoder = decoder
    }

    func makeInvocationContract(
        for plan: LingShuExternalAgentInvocationPlan
    ) throws -> LingShuExternalAgentInvocationContract {
        guard plan.requiresNetwork else {
            throw LingShuExternalAgentGatewayError.localAgentRequiresHostAdapter(plan.agent.id)
        }
        guard let url = URL(string: plan.agent.endpoint), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw LingShuExternalAgentGatewayError.invalidEndpoint(plan.agent.endpoint)
        }

        return .init(
            url: url,
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json",
                "X-LingShu-Agent-ID": plan.agent.id,
                "X-LingShu-Transport": plan.agent.transport.rawValue,
                "X-LingShu-Heartbeat-Interval": "\(plan.request.heartbeatIntervalSeconds)"
            ],
            body: try encoder.encode(plan.request),
            transport: plan.agent.transport
        )
    }

    func makeURLRequest(
        for contract: LingShuExternalAgentInvocationContract
    ) -> URLRequest {
        var request = URLRequest(url: contract.url)
        request.httpMethod = contract.method
        request.httpBody = contract.body
        request.timeoutInterval = max(30, TimeInterval(contract.headers["X-LingShu-Heartbeat-Interval"].flatMap(Int.init) ?? 15) * 4)
        for (key, value) in contract.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    func localAdapterResponse(
        for plan: LingShuExternalAgentInvocationPlan
    ) -> LingShuExternalAgentResponse {
        .init(
            requestID: plan.request.id,
            status: .accepted,
            summary: "本地外部 agent 已生成调用契约，等待宿主适配器接管执行。",
            artifacts: [],
            risk: nil
        )
    }

    func decodeResponse(
        data: Data,
        statusCode: Int,
        requestID: String
    ) -> LingShuExternalAgentResponse {
        if (200..<300).contains(statusCode),
           let decoded = try? decoder.decode(LingShuExternalAgentResponse.self, from: data) {
            return decoded
        }

        if statusCode == 202 || ((200..<300).contains(statusCode) && data.isEmpty) {
            return .init(
                requestID: requestID,
                status: .accepted,
                summary: "外部 agent 已接受任务，等待后续心跳或结果回传。",
                artifacts: [],
                risk: nil
            )
        }

        if statusCode == 401 || statusCode == 403 {
            return .init(
                requestID: requestID,
                status: .rejected,
                summary: "外部 agent 拒绝调用，请检查授权、权限边界或网关策略。",
                artifacts: [],
                risk: "授权或权限边界未通过"
            )
        }

        return .init(
            requestID: requestID,
            status: .failed,
            summary: "外部 agent 调用失败，HTTP 状态码：\(statusCode)。",
            artifacts: [],
            risk: "远程调用未形成可靠结果"
        )
    }

    func invoke(
        _ plan: LingShuExternalAgentInvocationPlan,
        session: URLSession = .shared
    ) async -> LingShuExternalAgentResponse {
        if !plan.requiresNetwork {
            return localAdapterResponse(for: plan)
        }

        do {
            let contract = try makeInvocationContract(for: plan)
            let request = makeURLRequest(for: contract)
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .init(
                    requestID: plan.request.id,
                    status: .failed,
                    summary: "外部 agent 返回了非 HTTP 响应。",
                    artifacts: [],
                    risk: "响应协议不匹配"
                )
            }
            return decodeResponse(data: data, statusCode: httpResponse.statusCode, requestID: plan.request.id)
        } catch let error as URLError where error.code == .timedOut {
            return .init(
                requestID: plan.request.id,
                status: .timedOut,
                summary: "外部 agent 心跳超时，灵枢已停止等待该分支。",
                artifacts: [],
                risk: "远程分支超时"
            )
        } catch {
            return .init(
                requestID: plan.request.id,
                status: .failed,
                summary: "外部 agent 调用异常：\(error.localizedDescription)",
                artifacts: [],
                risk: "远程分支异常"
            )
        }
    }
}
