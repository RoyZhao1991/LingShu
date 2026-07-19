import Foundation

/// **自我编程外围组件**(M1):让大脑走完「需求 → 自写 runner + 清单 → 沙箱测试 → 安全门 → 热载上线 → 真用它」。
///
/// 复用现成地基(不另起炉灶):产物 = P2 插件 skill `.md`(`LingShuComponentAuthoring` 组装)→ `installDiscoveredSkill` 落盘热载
/// → `userSkillProvidedTools()` 接成 live `LingShuAgentTool`(runner 契约 + P3 沙箱)。安全模型沿用 skill 自进化那套。
///
/// **安全红线(绝不可破,见 [[skill-self-evolution]] / Docs/灵枢内核ABI.md §3)**:上线顺序严格 = 校验 →
/// ① 静态门 `LingShuSkillSafetyGate`(挡危险代码,**命中即拒绝上线、绝不试跑**)→ ② P3 沙箱试跑(confined 验证真能用)
/// → ③ LLM 风险审 → **明确无风险且声明权限不高才自动上线;有风险/权限偏高 → 装但隔离,首次运行其 runner 强制人工审批**。
@MainActor
extension LingShuState {

    /// author_component 四肢:大脑据需求自写一个外围组件(纯软件工具型)并安全上线。
    func authorComponentTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "author_component",
            description: """
            自己编写并安全上线一个**外围组件**(给灵枢自身扩能力)。两类:\
            ①**动作型**(component_kind=tool,默认):新增一条工具/四肢,runner 从 stdin 读 JSON 入参、把结果打到 stdout(如查某公开 API 并解析、做某种本地数据处理)。\
            ②**传感器型**(component_kind=sensor):新增一个感知源,系统会**周期性**跑 runner,把它 stdout 的读数 JSON(对象或数组,字段 headline 必填、可带 detail/salience(0-3)/metadata)汇入感知链——之后用 `perceive` 就能拉到。给 sensor_channel(smartHome/wearable/calendar/messages/phoneNotifications)和 poll_interval(秒)。\
            ③**执行器型**(component_kind=actuator):新增一条**控制真实设备的动作工具**(改音量/转舵机/开继电器/控智能插座…)。runner 从 stdin 读命令 JSON、effect 到设备、把结果/新状态打到 stdout。必须给 actuator_target(控制哪个设备,用 discover_devices 里的目标,如 system.volume / /dev/cu.usbserial-X / 192.168.x.x)和 actuator_risk:**reversible**(可逆,音量/亮度)或 **physical**(不可逆/对外,电机/锁/继电器——**每次执行都会强制主人确认**)。\
            你都要提供:组件名、标识名(小写下划线)、职责说明、runner 语言、runner 代码、最小权限(只声明真要碰的)、沙箱试跑用 test_input(执行器型请给安全/可逆的测试命令)。\
            系统会:静态安全门扫危险代码 → P3 沙箱里用 test_input 真跑一遍验证(传感器还验读数可解析)→ 风险审 → 无风险才自动上线(工具/执行器下回合可调;传感器立即注册进感知中枢并启用);有风险/权限偏高则隔离。执行器的 **physical 风险无论是否隔离,每次执行都需主人确认;非交互安全拒绝**。**绝不静默上线/触发未过门的代码或对外动作。**
            """,
            parametersJSON: """
            {"type":"object","properties":{
            "component_kind":{"type":"string","description":"组件类型:tool(工具型,默认)/ sensor(传感器型)/ actuator(执行器型)","enum":["tool","sensor","actuator"]},
            "name":{"type":"string","description":"组件人可读名,如「天气查询」「系统负载传感器」「系统音量控制」"},
            "tool_name":{"type":"string","description":"标识名,小写字母开头、仅小写字母/数字/下划线,如 query_weather / system_load_sensor / set_volume"},
            "description":{"type":"string","description":"职责 + 入参/产出说明"},
            "language":{"type":"string","description":"runner 语言:python / node / shell","enum":["python","node","shell"]},
            "runner_code":{"type":"string","description":"runner 脚本:从 stdin 读 JSON、把结果(工具/执行器)或读数JSON(传感器,含 headline)打印到 stdout。不能含三反引号。"},
            "parameters_schema":{"type":"string","description":"(可选,工具/执行器)该工具的 JSON Schema 字符串"},
            "sensor_channel":{"type":"string","description":"(传感器型)归属感知通道","enum":["smartHome","wearable","calendar","messages","phoneNotifications"]},
            "poll_interval":{"type":"number","description":"(传感器型)轮询拍(秒),默认 5"},
            "actuator_target":{"type":"string","description":"(执行器型,必填)控制的目标设备,用 discover_devices 里的目标,如 system.volume / /dev/cu.usbserial-X / 192.168.1.50"},
            "actuator_risk":{"type":"string","description":"(执行器型)reversible(可逆)或 physical(不可逆/对外,每次执行需确认)","enum":["reversible","physical"]},
            "perm_network":{"type":"string","description":"(可选)允许联网的域名,逗号分隔;不联网则留空"},
            "perm_read":{"type":"string","description":"(可选)允许读的路径/ glob,逗号分隔"},
            "perm_write":{"type":"string","description":"(可选)允许写的路径/ glob,逗号分隔"},
            "test_input":{"type":"string","description":"沙箱试跑用的 JSON 入参字符串,如 {\\"city\\":\\"北京\\"};传感器型用 {};执行器型给安全可逆的测试命令"},
            "expected_output_contains":{"type":"string","description":"(可选)试跑输出里应包含的子串"}
            },"required":["name","tool_name","description","runner_code"]}
            """
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用。" }
            return await self.authorComponent(argsJSON: argsJSON)
        }
    }

    /// 完整闭环编排。返回给模型一段每一关裁决都可见的报告(trace 同步)。
    func authorComponent(argsJSON: String) async -> String {
        // 解析需求。
        let langRaw = Self.jsonField(argsJSON, "language") ?? "python"
        let kind = LingShuComponentAuthoring.Kind.from(Self.jsonField(argsJSON, "component_kind") ?? "tool")
        let spec = LingShuComponentAuthoring.Spec(
            name: Self.jsonField(argsJSON, "name") ?? "",
            toolName: (Self.jsonField(argsJSON, "tool_name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            description: Self.jsonField(argsJSON, "description") ?? "",
            language: LingShuComponentAuthoring.RunnerLanguage.from(langRaw),
            runnerCode: Self.componentArg(argsJSON, "runner_code") ?? "",
            parametersJSON: Self.componentArg(argsJSON, "parameters_schema") ?? "",
            permRead: Self.commaList(Self.jsonField(argsJSON, "perm_read")),
            permWrite: Self.commaList(Self.jsonField(argsJSON, "perm_write")),
            permNetwork: Self.commaList(Self.jsonField(argsJSON, "perm_network")),
            permShell: false,
            testInputJSON: Self.componentArg(argsJSON, "test_input")?.nonEmptyOrNil ?? "{}",
            expectedOutputContains: Self.jsonField(argsJSON, "expected_output_contains")?.nonEmptyOrNil,
            kind: kind,
            sensorChannel: (Self.jsonField(argsJSON, "sensor_channel")?.nonEmptyOrNil) ?? "smartHome",
            pollIntervalSeconds: Self.jsonNumber(argsJSON, "poll_interval") ?? 5,
            actuatorTarget: Self.jsonField(argsJSON, "actuator_target")?.nonEmptyOrNil ?? "",
            actuatorRisk: (Self.jsonField(argsJSON, "actuator_risk")?.nonEmptyOrNil) ?? "reversible"
        )

        appendTrace(kind: .system, actor: "自编外围", title: "开始", detail: "组件「\(spec.name)」(\(kind.rawValue))→ \(spec.toolName)(\(spec.language.rawValue))")

        // 校验(保留名**自动派生**自实际内核工具目录:新增内核工具自动覆盖,不手维护清单——§4 #8)。
        let reserved = LingShuComponentAuthoring.kernelReservedNames(catalogNames: LingShuFunctionCallingCatalog.builtin.map(\.name))
        let issues = LingShuComponentAuthoring.validate(spec, reservedNames: reserved)
        guard issues.isEmpty else {
            appendTrace(kind: .warning, actor: "自编外围", title: "校验未过", detail: issues.joined(separator: ";"))
            return "❌ 组件需求有问题,未上线:\n- " + issues.joined(separator: "\n- ") + "\n请修正后重新调用 author_component。"
        }

        // ① 静态安全门(危险代码命中即拒绝,绝不试跑/上线)。
        let gate = LingShuSkillSafetyGate.scan(spec.runnerCode)
        guard gate.isSafe else {
            appendTrace(kind: .warning, actor: "自编外围", title: "静态门拦下", detail: gate.violations.joined(separator: "、"))
            return "❌ 静态安全门拦下了这个组件,**未试跑、未上线**(供应链红线:绝不静默执行危险代码)。命中:\(gate.violations.joined(separator: "、"))。请改掉危险操作后重试。"
        }
        appendTrace(kind: .result, actor: "自编外围", title: "静态门通过", detail: "未命中危险模式")

        // ② P3 沙箱试跑(confined,用 test_input 真跑一遍验证它能用)。
        let perms = LingShuComponentAuthoring.permissions(for: spec)
        let test = await sandboxTestRunner(spec: spec, permissions: perms)
        guard test.passed else {
            appendTrace(kind: .warning, actor: "自编外围", title: "沙箱试跑未过", detail: String(test.output.prefix(120)))
            return "⚠️ 沙箱试跑未通过,**未上线**(组件得先在沙箱里真能跑通才让它上线)。试跑输出:\n\(test.output.prefix(600))\n请修正 runner 后重试。"
        }
        // 传感器型:沙箱输出必须能解析成 ≥1 条归一读数,否则上线了也进不了感知链。
        if spec.kind == .sensor {
            let channel = LingShuExternalSensoryChannel(rawValue: spec.sensorChannel) ?? .smartHome
            let parsed = LingShuRunnerSensorySource.parseReadings(test.output, channel: channel, sourceID: "test")
            guard !parsed.isEmpty else {
                appendTrace(kind: .warning, actor: "自编外围", title: "读数不可解析", detail: String(test.output.prefix(120)))
                return "⚠️ 传感器 runner 跑通了,但 stdout 解析不出合法读数(需输出含 headline 的 JSON 对象或数组),**未上线**。实际输出:\(test.output.prefix(400))"
            }
            appendTrace(kind: .result, actor: "自编外围", title: "读数可解析", detail: "解析出 \(parsed.count) 条读数:\(parsed.first?.headline.prefix(40) ?? "")")
        }
        appendTrace(kind: .result, actor: "自编外围", title: "沙箱试跑通过", detail: String(test.output.prefix(120)))

        // ③ LLM 风险审(来源=刚自写的代码,仍按未审来源对待)。
        let verdict = await reviewScriptRisk(spec.runnerCode)

        // 声明权限风险级(权限偏高即使代码审 safe 也隔离)。
        let componentID = LingShuComponentAuthoring.componentID(for: spec)
        let manifest = LingShuPluginManifest(
            id: componentID, name: spec.name, version: "1.0",
            providedTools: [spec.toolName], permissions: perms, source: .user)
        let declaredRisk = LingShuPluginPermissionChecker.riskLevel(manifest)
        let scopeNote = "声明权限:\(manifest.permissionSummary)(风险 \(declaredRisk.rawValue))"

        // 落盘热载(复用 discover_skill 的安装路径:写 Skills/.md + reloadUserSkills + 同步启停 + 登记资源)。
        let markdown = LingShuComponentAuthoring.assembleMarkdown(spec, id: componentID)
        guard installDiscoveredSkill(markdown: markdown, fileSlug: componentID) else {
            appendTrace(kind: .warning, actor: "自编外围", title: "落盘失败", detail: componentID)
            return "⚠️ 组件已过门 + 沙箱试跑通过,但落盘失败,未上线。请重试。"
        }
        // 下回合让主/自主会话用新工具集重建(热载新四肢)。
        mainAgentSessionHolder = nil
        autonomousSessionHolder = nil

        let profileID = "skill-\(componentID)"
        let safeToActivate = { if case .safe = verdict, declaredRisk != .high { return true }; return false }()
        if !safeToActivate {
            // 有风险 / 权限偏高 → 隔离:绝不静默执行(动作型首次运行强制审批;传感器型不自动启用、不后台静默轮询)。
            let notes: [String]
            if case .risky(let points) = verdict { notes = points } else { notes = ["声明权限作用域偏高:\(manifest.permissionSummary)"] }
            LingShuSkillAcquisition.setQuarantine(skillID: profileID, riskNotes: notes)
            appendTrace(kind: .warning, actor: "自编外围", title: "已上线但隔离", detail: notes.joined(separator: ";"))
            if spec.kind == .sensor {
                return "⚠️ 传感器型外围「\(spec.name)」已安装并**隔离**(静态门 ✓ 沙箱试跑 ✓ 读数可解析 ✓,但风险审/权限偏高):**未自动启用、不会后台静默轮询**,需主人审核后再启用。\(scopeNote)。风险点:\(notes.joined(separator: "; "))。"
            }
            if spec.kind == .actuator {
                let phys = LingShuActuatorSafety.Risk.from(spec.actuatorRisk) == .physical
                let extra = phys ? "且为**物理/不可逆动作 → 每次执行都强制确认**" : "**首次执行强制审批**"
                return "⚠️ 执行器型外围「\(spec.name)」(控制【\(spec.actuatorTarget)】)已安装并**隔离**:工具 `\(spec.toolName)` 下回合可见,\(extra)(即便已完整授权)。\(scopeNote)。风险点:\(notes.joined(separator: "; "))。"
            }
            return "⚠️ 外围组件「\(spec.name)」已安装并**隔离**(静态门 ✓ 沙箱试跑 ✓,但风险审/权限偏高):工具 `\(spec.toolName)` 下回合可见,**首次运行它的 runner 会强制弹人工审批让主人裁决**(即便已完整授权)。\(scopeNote)。风险点:\(notes.joined(separator: "; "))。"
        }

        // 无风险且权限不高 → 上线。
        if spec.kind == .sensor {
            let channel = LingShuExternalSensoryChannel(rawValue: spec.sensorChannel) ?? .smartHome
            registerSensorSource(componentID: componentID, name: spec.name, channel: channel,
                                 scriptName: LingShuComponentAuthoring.scriptName(for: spec), runnerCode: spec.runnerCode,
                                 permissions: perms, pollInterval: spec.pollIntervalSeconds, autoEnable: true)
            appendTrace(kind: .result, actor: "自编外围", title: "传感器已上线", detail: "源 \(componentID) 已注册进感知中枢并启用(\(Int(spec.pollIntervalSeconds))s 轮询)")
            return "✅ 传感器型外围「\(spec.name)」已上线(静态门 ✓ 沙箱试跑 ✓ 读数可解析 ✓ 风险审无明显风险 ✓)。已**动态注册进感知中枢并启用**(每 \(Int(spec.pollIntervalSeconds))s 轮询),数据进感知链——用 `perceive` 即可拉到。\(scopeNote)。沙箱试跑读数:\(test.output.prefix(200))"
        }
        if spec.kind == .actuator {
            let phys = LingShuActuatorSafety.Risk.from(spec.actuatorRisk) == .physical
            let gate = phys ? "它是**物理/不可逆动作 → 每一次执行都会强制主人确认**(非交互时安全拒绝、绝不静默触发)" : "它是**可逆动作 → 可直接执行**(风险审无明显风险)"
            recordIntegrationKnowledge(target: spec.actuatorTarget, componentName: spec.name, toolName: spec.toolName)   // §5 台账:把"接入了什么"记进知识图谱(陈述性),问"接入了什么"靠召回作答、不靠扫描
            appendTrace(kind: .result, actor: "自编外围", title: "执行器已上线", detail: "工具 \(spec.toolName) 控制 \(spec.actuatorTarget)(\(phys ? "physical/每次确认" : "reversible"))")
            return "✅ 执行器型外围「\(spec.name)」已上线(静态门 ✓ 沙箱试跑 ✓ 风险审无明显风险 ✓)。**新工具 `\(spec.toolName)` 下一回合即可调用**,控制目标【\(spec.actuatorTarget)】。\(gate)。\(scopeNote)。沙箱试跑输出:\(test.output.prefix(200))"
        }
        appendTrace(kind: .result, actor: "自编外围", title: "已上线", detail: "工具 \(spec.toolName) 下回合可用")
        return "✅ 外围组件「\(spec.name)」已上线(静态门 ✓ 沙箱试跑 ✓ 风险审无明显风险 ✓)。\(scopeNote)。**新工具 `\(spec.toolName)` 下一回合即可调用**(本回合会话工具集已固定)。沙箱试跑输出:\(test.output.prefix(200))"
    }

    /// §5 接入台账(知识图谱):一台执行器上线 = 一台设备被接入,把这件**陈述性事实**记进知识图谱
    /// (不固定 schema 的设备台账——那又是框架;就是一条原子知识)。问"接入了什么"靠语义召回作答、不靠当场扫描。
    func recordIntegrationKnowledge(target: String, componentName: String, toolName: String) {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let candidate = LingShuMemoryGardener.Candidate(
            kind: .fact,
            title: "已接入设备:\(t)",
            aliases: [t, componentName].filter { !$0.isEmpty },
            body: "已接入设备「\(t)」:由灵枢自编执行器组件「\(componentName)」(工具 \(toolName))驱动,现在可对话控制。",
            source: .tool,
            confidence: 0.85)
        _ = knowledgeGraph.remember(candidate)
        appendTrace(kind: .result, actor: "记忆", title: "接入台账", detail: "已记「接入了 \(t)(组件 \(componentName))」进知识图谱")
    }

    /// 主人审核通过一个**隔离的执行器组件**后,它就可对话控制了 → 把这次接入也记进知识图谱台账(§5)。
    /// (隔离的执行器在 authorComponent 时没走 on-line 分支记台账;批准=接入生效,这里补记。)按组件 id 找回它的目标/名/工具。
    @discardableResult
    func recordIntegrationForApprovedComponent(componentID: String) -> Bool {
        guard let reg = expertProfileRegistry as? LingShuCompositeExpertRegistry,
              let skill = reg.providedToolSkills().first(where: { $0.profile.id == "skill-\(componentID)" || $0.profile.id == componentID }),
              let target = skill.frontmatter["actuator_target"]?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty
        else { return false }
        recordIntegrationKnowledge(target: target, componentName: skill.profile.title, toolName: skill.manifest.providedTools.first ?? "")
        return true
    }

    // MARK: - 传感器源注册 + 重启持久化加载

    /// 用已安装组件的 runner 造一个 `LingShuRunnerSensorySource` 并注册进感知中枢。
    func registerSensorSource(componentID: String, name: String, channel: LingShuExternalSensoryChannel,
                              scriptName: String, runnerCode: String, permissions: LingShuPluginPermissions,
                              pollInterval: Double, autoEnable: Bool) {
        guard let runnerPath = materializeRunner(script: runnerCode, name: scriptName, skillID: "skill-\(componentID)") else { return }
        let interpreter = Self.runnerInterpreter(forScriptNamed: scriptName)
        let descriptor = LingShuExternalSensoryDescriptor(
            id: componentID, displayName: name, englishName: name, channel: channel,
            requiresPairing: false, summary: "灵枢自编传感器型外围", englishSummary: "self-authored sensor")
        let manifest = LingShuPluginManifest(id: componentID, name: name, version: "1.0", providedTools: [], permissions: permissions, source: .user)
        let source = LingShuRunnerSensorySource(
            descriptor: descriptor, manifest: manifest, executable: interpreter,
            baseArguments: [runnerPath], channel: channel, sourceID: componentID, pollInterval: pollInterval)
        externalSensory.registerSource(source, autoEnable: autoEnable)
    }

    /// 启动时:扫描已安装 skill `.md`,把**传感器型外围**(带 `sensor_channel` + 安全 runner)重新注册进感知中枢
    /// (非隔离的自动启用)。让自编传感器跨重启持续可用。返回注册数。
    @discardableResult
    func loadAndRegisterSensorComponents() -> Int {
        let dir = LingShuSkillLoader.defaultDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return 0 }
        var count = 0
        for url in files where url.pathExtension.lowercased() == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let fm = LingShuComponentAuthoring.parseFrontmatter(text)
            guard let channel = LingShuComponentAuthoring.sensorChannel(fromFrontmatter: fm) else { continue }
            guard let loaded = LingShuSkillLoader.parse(text, fallbackID: url.deletingPathExtension().lastPathComponent),
                  let script = loaded.profile.bundledScript,   // 没过安全门的不会有 bundledScript → 不注册
                  let scriptName = loaded.profile.bundledScriptName else { continue }
            let componentID = url.deletingPathExtension().lastPathComponent
            if externalSensory.isRegistered(componentID) { continue }
            let quarantined = LingShuSkillAcquisition.quarantinedRiskNotes(forSkillID: loaded.profile.id) != nil
            let poll = Double(fm["sensor_poll"] ?? "") ?? 5
            registerSensorSource(componentID: componentID, name: loaded.profile.title, channel: channel,
                                 scriptName: scriptName, runnerCode: script, permissions: loaded.manifest.permissions,
                                 pollInterval: poll, autoEnable: !quarantined)   // 隔离的不自动启用(不静默后台跑)
            count += 1
        }
        if count > 0 { appendTrace(kind: .system, actor: "自编外围", title: "传感器恢复", detail: "重启后重新注册 \(count) 个自编传感器型外围") }
        return count
    }

    /// 主人审核通过隔离的传感器型外围后**启用**它(解除隔离 → 注册/启用 → 开始采集进感知链)。
    /// 这是隔离传感器的"人工审批"动作(等价 run_command 隔离闸的首肯);非交互/自动绝不替主人做。
    @discardableResult
    func approveAndEnableSensor(componentID: String) -> Bool {
        LingShuSkillAcquisition.clearQuarantine(skillID: "skill-\(componentID)")
        if externalSensory.isRegistered(componentID) {
            externalSensory.enableSource(componentID)
            appendTrace(kind: .result, actor: "自编外围", title: "传感器已启用", detail: "主人审核通过:\(componentID)")
            return true
        }
        // 本会话尚未注册(隔离时不注册)→ 解除隔离后加载即会自动启用。
        loadAndRegisterSensorComponents()
        let ok = externalSensory.isRegistered(componentID)
        if ok { appendTrace(kind: .result, actor: "自编外围", title: "传感器已启用", detail: "主人审核通过:\(componentID)") }
        return ok
    }

    /// P3 沙箱里把 runner 物化到临时目录、用 test_input 真跑一遍(confined,绝不在工作目录/不带宽松权限)。
    /// 返回是否通过 + 输出。通过 = 进程零退出有输出(且若指定 expected 子串则命中)。
    private func sandboxTestRunner(spec: LingShuComponentAuthoring.Spec, permissions: LingShuPluginPermissions) async -> (passed: Bool, output: String) {
        let dir = LingShuRuntimeEnvironment.temporaryDirectory
            .appendingPathComponent("lingshu-component-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scriptURL = dir.appendingPathComponent(LingShuComponentAuthoring.scriptName(for: spec))
        guard (try? spec.runnerCode.write(to: scriptURL, atomically: true, encoding: .utf8)) != nil else {
            return (false, "runner 写入临时目录失败")
        }
        let interpreter = Self.runnerInterpreter(forScriptNamed: scriptURL.lastPathComponent)
        let manifest = LingShuPluginManifest(id: "test", name: spec.name, version: "1.0", providedTools: [spec.toolName], permissions: permissions, source: .user)
        let output = await LingShuPluginToolProvider.runRunner(
            manifest: manifest, toolName: spec.toolName, argumentsJSON: spec.testInputJSON,
            executable: interpreter, baseArguments: [scriptURL.path], sandbox: true, timeout: 25)
        // 失败信号:启动失败 / 非零退出 / 无输出。
        let lower = output.lowercased()
        let looksError = output.contains("启动失败") || output.contains("非零退出") || output.contains("无输出")
            || lower.contains("traceback (most recent call last)")
        if looksError { return (false, output) }
        if let expect = spec.expectedOutputContains, !output.contains(expect) {
            return (false, "试跑能跑但输出未含期望子串「\(expect)」。实际:\(output.prefix(300))")
        }
        return (true, output)
    }

    // MARK: - 参数解析(容错:string 或 object 都接)

    /// 取一个可能是 string、也可能是 object/array 的参数,统一回成字符串(object/array → JSON 串)。
    nonisolated static func componentArg(_ json: String, _ key: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = obj[key] else { return nil }
        if let s = value as? String { return s }
        if JSONSerialization.isValidJSONObject(value),
           let d = try? JSONSerialization.data(withJSONObject: value),
           let s = String(data: d, encoding: .utf8) { return s }
        return String(describing: value)
    }

    nonisolated static func commaList(_ raw: String?) -> [String] {
        (raw ?? "").split(whereSeparator: { ",，、".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

private extension String {
    var nonEmptyOrNil: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
