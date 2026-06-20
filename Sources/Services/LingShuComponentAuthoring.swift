import Foundation

/// 自我编程外围组件的**纯逻辑**(可单测,无 MainActor/无网络):把大脑给的组件需求(`Spec`)组装成
/// 一个 P2 插件 skill `.md`(frontmatter `provides`/`perm_*`/`script_name` + `## 生成脚本` runner 代码块),
/// 并做上线前校验。编排(静态门→沙箱试跑→风险审→热载)在 `LingShuState+ComponentAuthoring`。
///
/// 设计:**复用现成承载,不另起炉灶**——产物就是 `LingShuSkillLoader.parse` 认得的 skill `.md`,
/// 落盘热载即被 `userSkillProvidedTools()` 接成 live `LingShuAgentTool`(经 runner 契约 ③ + P3 沙箱)。
enum LingShuComponentAuthoring {

    /// runner 语言(决定脚本扩展名 + 代码块围栏标签;解释器选择复用 `LingShuState.runnerInterpreter`)。
    enum RunnerLanguage: String, Sendable, CaseIterable, Equatable {
        case python, node, shell
        var fileExtension: String {
            switch self { case .python: "py"; case .node: "js"; case .shell: "sh" }
        }
        var fenceTag: String {
            switch self { case .python: "python"; case .node: "javascript"; case .shell: "bash" }
        }
        /// 容错解析(大脑可能传 "python3"/"js"/"bash"/"sh"…)。
        static func from(_ raw: String) -> RunnerLanguage {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if s.hasPrefix("py") { return .python }
            if s == "js" || s.contains("node") || s.contains("javascript") { return .node }
            if s == "sh" || s.contains("bash") || s.contains("zsh") || s.contains("shell") { return .shell }
            return .python
        }
    }

    /// 外围组件类型:工具型(纯计算,暴露 `LingShuAgentTool`)/ 传感器型(产 `LingShuExternalSensoryReading` 进感知链)/
    /// 执行器型(作用于真实设备,暴露 `LingShuAgentTool` + 执行动作确认门)。
    enum Kind: String, Sendable, Equatable {
        case tool, sensor, actuator
        static func from(_ raw: String) -> Kind {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if s.hasPrefix("sensor") { return .sensor }
            if s.hasPrefix("actuat") { return .actuator }
            return .tool
        }
    }

    /// 合法感知通道(对应 `LingShuExternalSensoryChannel`)。自编传感器默认归到 `smartHome` 这个通用设备桶。
    static let validSensorChannels: Set<String> = ["phoneNotifications", "calendar", "messages", "wearable", "smartHome"]

    /// 大脑提交的外围组件需求(动作型 + 传感器型共用)。
    struct Spec: Equatable, Sendable {
        var name: String              // 人可读组件名
        var toolName: String          // 动作型=工具名(provides);传感器型=源标识基名
        var description: String       // 职责 + 入参/产出说明
        var language: RunnerLanguage
        var runnerCode: String        // runner 脚本(stdin 收 JSON 入参 / stdout 回结果或读数 JSON)
        var parametersJSON: String    // 工具参数 schema(可空,默认空对象;传感器型不用)
        var permRead: [String] = []
        var permWrite: [String] = []
        var permNetwork: [String] = []
        var permShell: Bool = false
        var testInputJSON: String = "{}"          // 沙箱试跑入参
        var expectedOutputContains: String? = nil // 试跑输出应包含(可选,更强的通过判据)
        // 传感器型(kind == .sensor)专用:
        var kind: Kind = .tool
        var sensorChannel: String = "smartHome"   // 归到哪个感知通道
        var pollIntervalSeconds: Double = 5       // 轮询拍(秒)
        // 执行器型(kind == .actuator)专用:
        var actuatorTarget: String = ""           // 控制的目标设备(discover_devices 里的某个,如 system.volume / /dev/cu.usbserial-X / 192.168.1.50)
        var actuatorRisk: String = "reversible"   // reversible(可逆)/ physical(不可逆/对外,每次执行需确认)
    }

    /// 不允许被外围工具覆盖的核心四肢名(防遮蔽内核工具)。**仅作安全floor/默认**——
    /// 真正上线时由编排层用 `kernelReservedNames(catalogNames:)` 把**实际内核工具目录**并进来(见 §4 #8 撤定制:
    /// 新增内核工具自动覆盖,不必手维护这张清单)。
    static let reservedToolNames: Set<String> = [
        "read_file", "write_file", "edit_file", "list_directory", "fetch_url", "run_command",
        "web_search", "spawn_task", "ask_user", "apply_skill", "discover_skill", "author_component",
        "speak", "perceive", "recall_memory", "update_plan", "set_digital_human"
    ]

    /// **自动派生保留名**(§4 #8):把实际内核工具目录(`LingShuFunctionCallingCatalog.builtin` 等的工具名)
    /// 并入安全 floor —— 新增一个内核工具,它的名字自动成为保留名,不必再手改 `reservedToolNames`。
    /// 编排层用真实工具名调它;纯逻辑可单测(给定目录含新名 → 结果含新名)。
    static func kernelReservedNames(catalogNames: [String]) -> Set<String> {
        reservedToolNames.union(catalogNames.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// 上线前校验:返回问题清单(空 = 通过)。任一问题都不上线,让大脑据此修。
    /// `reservedNames`:不可遮蔽的内核工具名集(编排层传**自动派生**的实际工具目录;默认用安全 floor `reservedToolNames`)。
    static func validate(_ spec: Spec, reservedNames: Set<String>? = nil) -> [String] {
        let reserved = reservedNames ?? reservedToolNames
        var issues: [String] = []
        if spec.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("组件名(name)不能为空") }
        let tn = spec.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if tn.isEmpty {
            issues.append(spec.kind == .sensor ? "传感器标识(tool_name)不能为空" : "工具名(tool_name)不能为空")
        } else if tn.range(of: "^[a-z][a-z0-9_]{1,39}$", options: .regularExpression) == nil {
            issues.append("标识「\(tn)」非法:需小写字母开头、仅含小写字母/数字/下划线、长度 2–40")
        } else if spec.kind != .sensor, reserved.contains(tn) {   // 工具型/执行器型都产出工具,不可遮蔽内核四肢
            issues.append("工具名「\(tn)」与内核四肢冲突,换一个名字(别遮蔽核心工具)")
        }
        if spec.runnerCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("runner 代码(runner_code)不能为空") }
        if spec.runnerCode.contains("```") { issues.append("runner 代码不能包含三反引号(会破坏 skill 代码块解析),请改写") }
        if !spec.parametersJSON.isEmpty, !isValidJSONObject(spec.parametersJSON) { issues.append("parameters_schema 不是合法 JSON 对象") }
        if !spec.testInputJSON.isEmpty, !isValidJSONObject(spec.testInputJSON) { issues.append("test_input 不是合法 JSON 对象") }
        if spec.kind == .sensor {
            if !validSensorChannels.contains(spec.sensorChannel) {
                issues.append("sensor_channel「\(spec.sensorChannel)」非法,应为:\(validSensorChannels.sorted().joined(separator: "/"))")
            }
            if spec.pollIntervalSeconds < 1 || spec.pollIntervalSeconds > 3600 { issues.append("poll_interval 应在 1–3600 秒") }
        }
        if spec.kind == .actuator {
            let r = spec.actuatorRisk.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !["reversible", "physical"].contains(r) {
                issues.append("actuator_risk「\(spec.actuatorRisk)」非法,应为 reversible(可逆)或 physical(不可逆/对外)")
            }
            if spec.actuatorTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("执行器须声明 actuator_target(它控制哪个设备,如 system.volume / /dev/cu.usbserial-X / 192.168.x.x)")
            }
        }
        return issues
    }

    /// 组件唯一 id(命名空间隔离,绝不覆盖内置/策展/已有 skill)。按类型前缀区分:工具 `authored-` / 传感器 `sensor-` / 执行器 `actuator-`。
    static func componentID(for spec: Spec) -> String {
        let prefix: String
        switch spec.kind { case .sensor: prefix = "sensor-"; case .actuator: prefix = "actuator-"; case .tool: prefix = "authored-" }
        return prefix + slugify(spec.toolName.isEmpty ? spec.name : spec.toolName)
    }

    static func scriptName(for spec: Spec) -> String {
        "runner.\(spec.language.fileExtension)"
    }

    /// 组装成最小权限的权限声明(只放大脑声明的)。
    static func permissions(for spec: Spec) -> LingShuPluginPermissions {
        LingShuPluginPermissions(
            fileRead: spec.permRead, fileWrite: spec.permWrite,
            network: spec.permNetwork, shell: spec.permShell, systemSensitive: false)
    }

    /// 把 `Spec` 组装成 skill `.md`(`LingShuSkillLoader.parse` 认得:frontmatter + `## 生成脚本`)。
    /// 动作型写 `provides:`(被接成 live 工具);传感器型写 `sensor_channel:`/`sensor_poll:`(被接成感知源)。
    static func assembleMarkdown(_ spec: Spec, id: String) -> String {
        let oneLineName = singleLine(spec.name)
        let oneLineDesc = singleLine(spec.description)
        var fm: [String] = [
            "id: \(id)",
            "title: \(oneLineName)",
            "version: 1.0",
            "mission: \(oneLineDesc)",
            "triggers: \(spec.toolName), \(oneLineName)",
            "script_name: \(scriptName(for: spec))"
        ]
        switch spec.kind {
        case .sensor:
            fm.append("sensor_channel: \(spec.sensorChannel)")
            fm.append("sensor_poll: \(Int(spec.pollIntervalSeconds))")
        case .actuator:
            fm.append("provides: \(spec.toolName)")               // 执行器也是一条工具(大脑调它下命令)
            fm.append("actuator_target: \(singleLine(spec.actuatorTarget))")
            fm.append("actuator_risk: \(spec.actuatorRisk.trimmingCharacters(in: .whitespaces).lowercased())")
        case .tool:
            fm.append("provides: \(spec.toolName)")
        }
        if !spec.permRead.isEmpty { fm.append("perm_read: \(spec.permRead.joined(separator: ", "))") }
        if !spec.permWrite.isEmpty { fm.append("perm_write: \(spec.permWrite.joined(separator: ", "))") }
        if !spec.permNetwork.isEmpty { fm.append("perm_network: \(spec.permNetwork.joined(separator: ", "))") }
        if spec.permShell { fm.append("perm_shell: true") }

        let code = spec.runnerCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let role: String
        switch spec.kind {
        case .sensor:   role = "传感器型外围:周期性跑 runner,把 stdout 的读数 JSON({headline,detail,salience,metadata})汇入感知链"
        case .actuator: role = "执行器型外围:工具 `\(spec.toolName)` 控制【\(singleLine(spec.actuatorTarget))】(风险 \(spec.actuatorRisk));入参=命令 JSON 经 stdin,runner effect 到设备、结果取 stdout"
        case .tool:     role = "工具型外围:提供工具 `\(spec.toolName)`,入参以 JSON 经 stdin 传给 runner、结果取 stdout"
        }
        return """
        ---
        \(fm.joined(separator: "\n"))
        ---

        ## 专业要点
        - 灵枢自编外围组件「\(oneLineName)」(\(spec.kind.rawValue)):\(oneLineDesc)
        - \(role)。

        ## 生成脚本
        ```\(spec.language.fenceTag)
        \(code)
        ```
        """
    }

    // MARK: - 加载侧:从 skill .md 识别传感器型外围

    /// 从已安装的 skill `.md` 解析 frontmatter 键值(纯,供加载器识别 sensor_channel/sensor_poll)。
    static func parseFrontmatter(_ markdown: String) -> [String: String] {
        guard markdown.hasPrefix("---") else { return [:] }
        let parts = markdown.components(separatedBy: "---")
        guard parts.count >= 3 else { return [:] }
        var fm: [String: String] = [:]
        for line in parts[1].components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { fm[key] = value }
        }
        return fm
    }

    /// 把 frontmatter 的 `sensor_channel` 文本映射成内核通道枚举(无/非法 → nil = 不是传感器组件)。
    static func sensorChannel(fromFrontmatter fm: [String: String]) -> LingShuExternalSensoryChannel? {
        guard let raw = fm["sensor_channel"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return LingShuExternalSensoryChannel(rawValue: raw)
    }

    // MARK: - 纯工具

    static func slugify(_ s: String) -> String {
        let cleaned = s.lowercased().unicodeScalars.map { sc -> Character in
            CharacterSet.alphanumerics.contains(sc) ? Character(sc) : "-"
        }
        let slug = String(cleaned).split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "component-\(UUID().uuidString.prefix(6))" : String(slug.prefix(40))
    }

    private static func singleLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValidJSONObject(_ json: String) -> Bool {
        let t = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let data = t.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil
    }
}
