import Foundation

/// 信息类内置工具:当前时间(本地时区)、地理定位(Mac 精确 → IP 近似 → 时区兜底)。
/// 从 LingShuState+AgentBackbone 拆出,守住单文件聚焦(架构守卫:state 子域文件 ≤ 500 行)。
@MainActor
extension LingShuState {

    nonisolated static func timeTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "get_current_time",
            description: "返回当前**本地**日期时间(含星期与时区)。被问「现在几点/今天几号/星期几」时**必须调本工具为准**——绝不凭记忆、也不要顺着用户说的时间附和(用户可能在试探)。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
        ) { _ in
            // 必须用本地时区:ISO8601DateFormatter 默认输出 UTC(带 Z),会让模型把 UTC 当本地读错时间(实测北京 12:40 被报成别的)。
            let tz = TimeZone.current
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.timeZone = tz
            formatter.dateFormat = "yyyy年M月d日 HH:mm:ss EEEE"
            let offsetHours = tz.secondsFromGMT() / 3600
            return "\(formatter.string(from: Date()))（时区 \(tz.identifier)，UTC\(offsetHours >= 0 ? "+" : "")\(offsetHours)）"
        }
    }

    /// 地理定位(三级回退):① Mac 系统定位(CoreLocation,精确,首次弹一次系统授权)→ ② 公网 IP 城市级近似
    /// (无需权限,但会把公网 IP 发给第三方定位服务、挂 VPN/代理会偏)→ ③ 系统时区推断的大致区域。
    /// 仅在需要「在哪/本地天气/附近」时由模型按需调。
    nonisolated static func locationTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "get_location",
            description: "返回当前地理位置。优先用 **Mac 系统定位**(精确到城市/街区,首次会弹一次系统授权框,请允许);未授权/失败则回退**公网 IP** 城市级近似(挂 VPN/代理会偏);再不行回退系统时区推断的大致区域。需要知道「现在在哪/本地天气/附近」等场景时调用。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
        ) { _ in
            // ① Mac 系统精确定位(CoreLocation)
            if let precise = await LingShuLocationProvider.current() {
                return "当前位置(Mac 系统定位,精确):\(precise)。时区 \(TimeZone.current.identifier)。"
            }
            // ② 公网 IP 城市级近似
            func tzFallback() -> String {
                "未能取到精确/IP 定位(可能离线、未授权系统定位、被限流或挂代理)。按系统时区推断大致区域:\(TimeZone.current.identifier)。"
            }
            guard let url = URL(string: "https://ipapi.co/json/") else { return tzFallback() }
            var req = URLRequest(url: url)
            req.timeoutInterval = 6
            req.setValue("LingShu/1.0", forHTTPHeaderField: "User-Agent")   // ipapi.co 对空 UA 会拒
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["error"] == nil else { return tzFallback() }
            let city = obj["city"] as? String ?? ""
            let region = obj["region"] as? String ?? ""
            let country = (obj["country_name"] as? String) ?? (obj["country"] as? String) ?? ""
            let parts = [country, region, city].filter { !$0.isEmpty }
            guard !parts.isEmpty else { return tzFallback() }
            // ③ 回退:IP 城市级
            return "当前大致位置(公网 IP,城市级近似):\(parts.joined(separator: " · "))。时区 \(TimeZone.current.identifier)。"
        }
    }
}
