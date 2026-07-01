import Foundation

/// 各模型通道**账号余额查询**的按厂商适配。没有统一标准——每家余额 API 不同,有的厂商(如 Anthropic)压根不开放余额查询。
/// 像 [[LingShuPrefixCache]] 一样把"这家怎么查余额 / 怎么解析"集中到一处:UI 一个口子,**支持的厂商显示余额、不支持的不显示**。
/// 在这里加一家(endpointSpec + parse 分支)即扩展一家。纯逻辑、可单测(request 构造 + parse 解析,不依赖 UI/State)。
enum LingShuChannelBalance {

    /// 一次余额查询结果。
    struct Result: Equatable, Sendable {
        let display: String     // 给 UI 的短文本,如 "¥110.00" / "$9.50 剩余" / "无限额"
        let available: Bool     // 是否还有余额可用(>0 或无限额)——可用绿、不足橙
    }

    /// 这家是否支持用 API 查余额(决定 UI 显不显示「余额」口子)。
    static func isSupported(provider: String) -> Bool { spec(for: provider) != nil }

    /// 构造余额查询请求(GET + Bearer)。不支持/无 key 返回 nil。余额 API 的 host 与聊天 endpoint 无关,按厂商固定。
    static func request(provider: String, apiKey: String) -> URLRequest? {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let spec = spec(for: provider), let url = URL(string: spec.url) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        req.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    /// 解析响应(纯函数)。解析不出返回 nil。
    static func parse(provider: String, data: Data) -> Result? {
        guard let spec = spec(for: provider),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        switch spec.kind {
        case .deepseek:
            // {"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00",…}]}
            let avail = (obj["is_available"] as? Bool) ?? true
            guard let info = (obj["balance_infos"] as? [[String: Any]])?.first else { return nil }
            let cur = (info["currency"] as? String) ?? ""
            let bal = (info["total_balance"] as? String) ?? "—"
            let sym = (cur == "CNY") ? "¥" : (cur == "USD" ? "$" : (cur.isEmpty ? "" : cur + " "))
            return Result(display: "\(sym)\(bal)", available: avail && (Double(bal) ?? 0) > 0)
        case .openrouter:
            // {"data":{"usage":x,"limit":y|null,"limit_remaining":z|null,…}}
            guard let d = obj["data"] as? [String: Any] else { return nil }
            let usage = (d["usage"] as? Double) ?? 0
            if let remaining = d["limit_remaining"] as? Double {
                return Result(display: String(format: "$%.2f 剩余", remaining), available: remaining > 0)
            }
            if d["limit"] == nil || d["limit"] is NSNull {   // 无限额
                return Result(display: String(format: "已用 $%.2f · 无限额", usage), available: true)
            }
            let limit = (d["limit"] as? Double) ?? 0
            return Result(display: String(format: "$%.2f / $%.2f", max(0, limit - usage), limit), available: (limit - usage) > 0)
        }
    }

    // MARK: - 厂商规格(在这里加新厂商即扩展)

    private enum Kind { case deepseek, openrouter }
    private struct Spec { let url: String; let kind: Kind }

    private static func spec(for provider: String) -> Spec? {
        let p = provider.lowercased()
        if p.contains("deepseek") { return Spec(url: "https://api.deepseek.com/user/balance", kind: .deepseek) }
        if p.contains("openrouter") { return Spec(url: "https://openrouter.ai/api/v1/auth/key", kind: .openrouter) }
        // 待扩(确认各家余额 API 后加):智谱 / 通义 / MiniMax …;Anthropic/OpenAI 当前不开放余额查询 → 不支持。
        return nil
    }
}
