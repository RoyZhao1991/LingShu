import Foundation

/// 通用中枢 P2 真闭环·**能力需求**(纯类型 + 容错解析,可单测)。
///
/// 从 GoalSpec 推导「这个目标需要哪些**通用能力**」(零领域写死:external_system.read/write、local_file.scan、
/// document.generate、browser.operate、device.discover/control、api.call、human.confirm、compute…),
/// 再拿去查 [[LingShuCapabilityGraph]] 判命中/需授权/缺失。需求是**通用动词**,绝不为 Notion/PPT/PDF 写死。
enum LingShuCapabilityVerb: String, Codable, Sendable, Equatable, CaseIterable {
    case externalSystemRead  = "external_system.read"   // 读外部系统(第三方服务/SaaS 数据)
    case externalSystemWrite = "external_system.write"  // 写外部系统(同步/创建/更新到第三方)
    case localFileScan       = "local_file.scan"        // 扫/读本机文件
    case documentGenerate    = "document.generate"      // 生成文档/PPT/报告等产出物
    case browserOperate      = "browser.operate"        // 浏览器自动化(网页端操作)
    case deviceDiscover      = "device.discover"        // 发现硬件/外设
    case deviceControl       = "device.control"         // 控制设备/外设(物理效果)
    case apiCall             = "api.call"               // 调用某 API
    case humanConfirm        = "human.confirm"          // 需人确认/授权/提供凭据
    case compute             = "compute"                // 纯计算/数据处理(内核原语即可)
    case unknown             = "unknown"

    /// 内核原语就能满足(无需外部能力)——查图谱时默认命中。
    var satisfiedByKernel: Bool { self == .localFileScan || self == .documentGenerate || self == .compute }

    static func parse(_ raw: String?) -> LingShuCapabilityVerb {
        let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_")
        if let exact = LingShuCapabilityVerb(rawValue: s) { return exact }
        switch s {
        case "external_system", "externalsystem.read": return .externalSystemRead
        case "externalsystem.write", "external.write": return .externalSystemWrite
        case "local_file", "file.scan", "localfile.scan": return .localFileScan
        case "document", "doc.generate": return .documentGenerate
        case "browser", "web.operate": return .browserOperate
        case "device", "device.control ": return .deviceControl
        case "api", "api_call": return .apiCall
        case "human", "human_confirm", "humanconfirm": return .humanConfirm
        default: return .unknown
        }
    }

    /// 从能力提供方的 id/description/source 做**通用词汇**动词归一,让 CapabilityGraph 不再只是"记录清单"。
    /// 这里不写任何具体服务名或产物名,只识别 read/write/browser/device/api/document 等通用语义。
    static func infer(id: String, description: String, source: String) -> LingShuCapabilityVerb? {
        let text = "\(id) \(description) \(source)".lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { text.contains($0) } }
        if has(["browser", "navigate", "web.", "dom", "click", "screenshot", "网页", "浏览器"]) { return .browserOperate }
        if has(["device.discover", "discover_devices", "scan_devices", "hardware", "sensor", "peripheral", "外设", "硬件", "传感器"]) { return .deviceDiscover }
        if has(["device.control", "actuator", "peripheral_control", "控制设备", "执行器"]) { return .deviceControl }
        if has(["presentation", "slides", "deck", "document", "report", "markdown", "pdf", "docx", "pptx", "文档", "报告", "汇报", "演示"]) { return .documentGenerate }
        if has(["local_file", "read_file", "list_directory", "search_text", "filesystem", "本机文件", "全文搜索"]) { return .localFileScan }
        if has(["api", "http", "endpoint", "接口"]) { return .apiCall }
        if has(["create", "update", "write", "sync", "send", "post", "upload", "delete", "写入", "同步", "创建", "更新", "发送", "上传", "删除"]) {
            return .externalSystemWrite
        }
        if has(["read", "get", "list", "search", "fetch", "query", "download", "读取", "查询", "搜索", "获取", "下载"]) {
            return .externalSystemRead
        }
        return nil
    }
}

struct LingShuCapabilityRequirement: Codable, Sendable, Equatable {
    var verb: LingShuCapabilityVerb
    var target: String   // 作用对象(如「我的 Notion 工作区」「/tmp 目录」「床头灯」)——人读,不参与领域分支
    var detail: String   // 一句话说明

    init(verb: LingShuCapabilityVerb, target: String = "", detail: String = "") {
        self.verb = verb
        self.target = target
        self.detail = detail
    }
}

enum LingShuCapabilityRequirementPlanner {
    /// 从 GoalSpec 推能力需求的模型指令(GoalSpec 由 user 消息传入,system 静态)。
    static let systemPrompt = """
    你是能力需求分析器。把用户目标拆成需要的**通用能力**(只用下列通用动词,**绝不为具体服务/产物写死**)。**只输出 JSON 数组**(无解释、无围栏)。
    每项 {verb, target, detail}:
    - verb 取值之一:external_system.read / external_system.write / local_file.scan / document.generate / browser.operate / device.discover / device.control / api.call / human.confirm / compute
    - target:作用对象(人读即可,如「用户的 Notion 工作区」「/tmp 目录」「床头灯」)
    - detail:一句话说明这条需求
    铁律:用通用动词描述「需要什么能力」,不要判断有没有、也不要写补齐方案。同步到第三方服务=external_system.write;读第三方=external_system.read;扫本机文件=local_file.scan;生成文档/PPT=document.generate;需要账号授权/凭据/付款/物理动作确认/不可逆高风险确认=human.confirm。
    边界也要结构化输出,不能藏在 detail 文本里:
    - 目标需要读/写第三方账号、外部工作区、云端服务且用户尚未明确授权/凭据时,除 external_system.read/write 外,必须额外输出 human.confirm。
    - 写代码、跑测试、执行脚本、做本地计算/数据处理属于 compute;除非目标明确要求访问外部 HTTP/API 服务,不要输出 api.call。
    - 目标需要控制真实设备/外设/机器人时,通常需要 device.discover + device.control;控制真实设备前必须额外输出 human.confirm。
    - 目标包含不可逆、破坏性、对外发送、资金/付款、生产环境变更等高风险动作时,除对应能力外,必须额外输出 human.confirm。
    - 仅“把结果告诉用户/询问是否满意/交付路径”不是能力边界,不要输出 human.confirm。
    """

    /// 容错解析:剥围栏 + 取首个 [...] + 逐项;无效 → []。
    static func parse(_ raw: String) -> [LingShuCapabilityRequirement] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        let parsed: [LingShuCapabilityRequirement] = arr.compactMap { item in
            guard let obj = item as? [String: Any] else { return nil }
            let verb = LingShuCapabilityVerb.parse(obj["verb"] as? String)
            guard verb != .unknown else { return nil }
            return LingShuCapabilityRequirement(
                verb: verb,
                target: ((obj["target"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                detail: ((obj["detail"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return sanitized(parsed)
    }

    static func sanitized(_ requirements: [LingShuCapabilityRequirement]) -> [LingShuCapabilityRequirement] {
        requirements.filter { !isNonCapabilityHumanConfirmation($0) }
    }

    /// `human.confirm` 只应表达真正的授权/凭据/付款/高风险动作确认。
    /// "把结果告诉用户/用户确认方案"属于交互或交付,不是需要接入的能力,不能进入图谱形成 requiresAuth。
    static func isNonCapabilityHumanConfirmation(_ requirement: LingShuCapabilityRequirement) -> Bool {
        guard requirement.verb == .humanConfirm else { return false }
        let text = "\(requirement.target) \(requirement.detail)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        let lower = text.lowercased()

        if LingShuHumanBoundarySemantics.isBareHumanActorTarget(requirement.target),
           !LingShuHumanBoundarySemantics.containsConcreteProtectedBoundary(text) {
            return true
        }

        let trueBoundarySignals = [
            "授权", "凭据", "token", "api key", "apikey", "oauth", "登录", "账号", "账户",
            "密码", "支付", "付款", "扣款", "转账", "删除", "生产", "高风险", "危险",
            "物理", "设备控制", "开灯", "关灯", "机器人", "接管", "屏幕录制", "辅助功能"
        ]
        if trueBoundarySignals.contains(where: { lower.contains($0.lowercased()) }) {
            return false
        }

        let genericTargets = ["用户", "主人", "我", "结果", "最终结果", "文件路径", "产出物路径"]
        let deliverySignals = [
            "告知", "告诉", "回复", "回答", "汇报", "反馈", "交付", "最终说明",
            "方案确认", "步骤确认", "确认方案", "确认步骤", "满意", "验收",
            "tell", "reply", "inform", "final answer", "final response"
        ]
        if genericTargets.contains(where: { lower == $0.lowercased() || lower.contains($0.lowercased()) }),
           deliverySignals.contains(where: { lower.contains($0.lowercased()) }) || lower.count <= 8 {
            return true
        }
        return deliverySignals.contains(where: { lower.contains($0.lowercased()) })
    }
}
