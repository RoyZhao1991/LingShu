import Foundation

/// 统一外设接线:把所有来源(串口/USB/蓝牙/电源/传感器/自编组件 + 网络 mDNS + 本机)汇成**一个已连接外设列表**,
/// 并让**大脑在连接时自动分类/分组**(不在壳里硬编码)。面板见 LingShuPeripheralsView。
@MainActor
extension LingShuState {

    /// 刷新外设列表:壳侧汇集非网络外设 → 灌进中枢 + 启动 mDNS 扫描 → 触发大脑自动归类。
    /// **增量填充**:快来源(串口/电源/传感器/组件)先出,慢来源(USB/蓝牙 system_profiler)随后补——列表不卡"发现中"。
    func refreshPeripherals(autoClassify: Bool = true) async {
        peripheralHub.startScan()   // mDNS 后台先跑

        // 快来源:串口 / 电源 / 已接入感知源 / 已自编组件(立刻可出)。
        var fast: [LingShuPeripheral] = []
        for d in LingShuDeviceDiscovery.parseSerialPorts(Self.listDevCuPaths()) { fast.append(peripheral(d, transport: .serial)) }
        for d in await Self.detectPowerControllers() { fast.append(peripheral(d, transport: .power)) }
        for s in externalSensory.availableSources {
            fast.append(LingShuPeripheral(id: "sensor/\(s.id)", name: s.displayName, transport: .sensor,
                raw: "感知源 通道=\(s.channel.rawValue) \(s.summary)", statusLine: externalSensory.status(for: s.id).label,
                builtinActions: [], classification: nil))
        }
        if let reg = expertProfileRegistry as? LingShuCompositeExpertRegistry {
            for skill in reg.providedToolSkills() {
                let isActuator = skill.frontmatter["actuator_risk"] != nil
                fast.append(LingShuPeripheral(id: "component/\(skill.profile.id)", name: skill.profile.title,
                    transport: .component, raw: "自编\(isActuator ? "执行器" : "工具")组件 provides=\(skill.manifest.providedTools.joined(separator: ","))",
                    statusLine: skill.profile.mission, builtinActions: [], classification: nil))
            }
        }
        peripheralHub.setExternalPeripherals(fast)   // ① 先出快来源

        // 慢来源:USB / 蓝牙(system_profiler 较慢),补进列表。
        var slow = fast
        let usbJSON = await Self.runReadCommand("/usr/sbin/system_profiler", ["SPUSBDataType", "-json"], timeout: 15)
        for d in LingShuDeviceDiscovery.parseUSB(Data(usbJSON.utf8)) { slow.append(peripheral(d, transport: .usb)) }
        let btJSON = await Self.runReadCommand("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 15)
        for d in LingShuDeviceDiscovery.parseBluetooth(Data(btJSON.utf8)) { slow.append(peripheral(d, transport: .bluetooth)) }
        peripheralHub.setExternalPeripherals(slow)   // ② 补慢来源

        if autoClassify {
            try? await Task.sleep(nanoseconds: 3_000_000_000)   // 给 mDNS 收一会儿
            await classifyConnectedPeripherals()
        }
    }

    /// 打开 macOS「本地网络」隐私设置页(一键直达——实际开关受 Apple 安全限制只能用户点)。
    func openLocalNetworkSettings() {
        LingShuPeripheralHub.openLocalNetworkSettings()
    }

    private func peripheral(_ d: LingShuDeviceDiscovery.Device, transport: LingShuPeripheralTransport) -> LingShuPeripheral {
        LingShuPeripheral(id: "\(transport.rawValue)/\(d.id)", name: d.name, transport: transport,
            raw: "\(transport.rawValue) \(d.id) \(d.detail)", statusLine: d.detail.isEmpty ? d.name : d.detail,
            builtinActions: [], classification: nil)
    }

    /// **大脑自动识别/归类**:把待识别外设(原始事实)交大脑,一次性判出 canonical(归一去重)/alias(语义别名)/
    /// 用途/设备类型/能力清单/接入路/能否接入,**以及是否已被某驱动接管(integrated)**。
    /// **灵枢是 AI**:它要看懂"这到底是什么 / 是不是已经接进来了",而非靠子串匹配贴死徽章(撤定制,§4 #4)。
    func classifyConnectedPeripherals() async {
        let pending = peripheralHub.unclassified
        guard !pending.isEmpty else { return }
        let listing = pending.map { "- id=\($0.id) | 名称=\($0.name) | 传输=\($0.transport.rawValue) | 原始=\($0.raw)" }.joined(separator: "\n")
        // 已有驱动组件接管的目标(交大脑判每台是否已被接管,而不是壳里子串匹配)。
        let driverTargets = installedActuatorTargets()
        let driverContext = driverTargets.isEmpty
            ? "当前还没有任何自编驱动组件(故所有设备 integrated 都应为 false)。"
            : "已上线的驱动组件分别控制这些目标:\(driverTargets.joined(separator: " / "))。**对每台设备判 integrated**:若它就是上述某个驱动控制的那台物理设备(可对话控制了)→ true,否则 false。"
        let prompt = """
        下面是当前发现到的外设(名称多为产品代号)。请你**看懂每台到底是什么**,给出:
        - canonical:**归一键**。同一台物理设备若以多个条目出现(如一个音箱同时有 _airplay、_raop、蓝牙;或同名灯有 _hap),给它们**相同的 canonical**(合并成一台);独立设备给各自不同的 canonical。
        - alias:**语义别名**(这是什么,如"床头灯""客厅音箱""罗技鼠标"),取代产品代号。
        - what:一句话用途。
        - deviceType:设备类型分组(灯/音箱/鼠标/键盘/手柄/电脑/手机/平板/传感器/网络服务…)。
        - capabilities:能力清单数组(如 ["开关","亮度","色温"] 或 ["音频输出","音频输入"])——同一设备的多通道折这里,别拆成多台。
        - access:只能填 open_local(开放本地协议可自写驱动)/airplay/homekit/matter/needs_code(需配对码或token)/unknown。
        - integratable:true/false,灵枢能否接入(让它能控/能读)。
        - integrated:true/false,**这台是否已被某驱动组件接管、现在就能对话控制**。\(driverContext)
        - note:一句话怎么接/能否自写驱动。
        **只输出 JSON 数组**,每项 {"id","canonical","alias","what","deviceType","capabilities","access","integratable","integrated","note"},不要解释、不要代码块标记。
        外设:
        \(listing)
        """
        let session = LingShuAgentSession(
            id: "periph-classify-\(UUID().uuidString.prefix(6))",
            system: "你是灵枢的外设识别器:看懂每台外设到底是什么、起语义别名、把同一物理设备的多通道归一、列能力、判能否接入、判是否已被驱动接管。access 取给定词表之一。只输出 JSON 数组。",
            tools: [], model: makeAgentModelAdapter(), maxTurns: 1)
        guard case .completed(let text) = await session.send(prompt) else { return }
        let clean = LingShuReasoningText.stripThinkTags(text)
        let map = Self.parsePeripheralClassifications(clean)
        guard !map.isEmpty else { return }
        peripheralHub.applyClassifications(map)
        let integratedIDs = Self.parseIntegratedPeripheralIDs(clean)   // 大脑判的"已接入",取代子串匹配
        if !integratedIDs.isEmpty { peripheralHub.setIntegrated(integratedIDs) }
        appendTrace(kind: .result, actor: "外设", title: "大脑识别", detail: "已识别/归一 \(map.count) 台外设\(integratedIDs.isEmpty ? "" :",已接入 \(integratedIDs.count) 台")")
    }

    /// 已上线驱动组件(执行器型)各自控制的目标列表(从组件 frontmatter 的 actuator_target 取)。供大脑判"哪台已被接管"。
    func installedActuatorTargets() -> [String] {
        guard let reg = expertProfileRegistry as? LingShuCompositeExpertRegistry else { return [] }
        return reg.providedToolSkills().compactMap { $0.frontmatter["actuator_target"]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated static func parsePeripheralClassifications(_ text: String) -> [String: LingShuPeripheralClassification] {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") { body = body.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "") }
        guard let s = body.firstIndex(of: "["), let e = body.lastIndex(of: "]"), s < e,
              let data = String(body[s...e]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var out: [String: LingShuPeripheralClassification] = [:]
        for o in arr {
            guard let id = o["id"] as? String, !id.isEmpty else { continue }
            let caps = (o["capabilities"] as? [String]) ?? ((o["capabilities"] as? String).map { [$0] } ?? [])
            let integ = (o["integratable"] as? Bool) ?? ((o["integratable"] as? String)?.lowercased() == "true")
            out[id] = LingShuPeripheralClassification(
                canonical: (o["canonical"] as? String) ?? "",
                alias: (o["alias"] as? String) ?? "",
                what: (o["what"] as? String) ?? "",
                deviceType: (o["deviceType"] as? String) ?? "",
                capabilities: caps,
                access: (o["access"] as? String) ?? "unknown",
                integratable: integ,
                note: (o["note"] as? String) ?? "")
        }
        return out
    }

    /// 从大脑分类输出解析"已接入"外设 id(`integrated:true`)。纯逻辑可单测——取代壳里 actuator_target↔名称子串匹配。
    nonisolated static func parseIntegratedPeripheralIDs(_ text: String) -> Set<String> {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") { body = body.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "") }
        guard let s = body.firstIndex(of: "["), let e = body.lastIndex(of: "]"), s < e,
              let data = String(body[s...e]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var out: Set<String> = []
        for o in arr {
            guard let id = o["id"] as? String, !id.isEmpty else { continue }
            let integrated = (o["integrated"] as? Bool) ?? ((o["integrated"] as? String)?.lowercased() == "true")
            if integrated { out.insert(id) }
        }
        return out
    }

    /// 大脑「看一眼连了什么外设」工具(含 id,供 label_peripheral 写回 / author_component 接入引用)。
    func peripheralsTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "peripherals",
            description: "列出当前发现到的所有外设(网络/串口/USB/蓝牙/电源/传感器/本机),含每台的 id、别名、设备类型、能力、接入路、是否已接入。**用户要你接入某设备时,先调它(+discover_devices)探测、自己把能探到的目标列出来对上号,只就探不到的信息问用户,再给手动接入路线——别一上来就让用户报品牌/型号/协议。**",
            parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
        ) { [weak self] _ in
            guard let self else { return "执行环境不可用。" }
            return await MainActor.run { self.peripheralsSummary() }
        }
    }

    func peripheralsSummary() -> String {
        let ps = peripheralHub.peripherals
        guard !ps.isEmpty else { return "外设列表为空(刚开机可先刷新;mDNS 需「本地网络」授权)。" }
        // 按归一键合并(同一物理设备的多通道折一台),再按设备类型分组。
        let byCanon = Dictionary(grouping: ps) { $0.canonicalKey }
        var devices: [LingShuPeripheral] = byCanon.values.map { group in
            var rep = group.first { $0.classification != nil } ?? group[0]
            let caps = Set(group.flatMap { $0.classification?.capabilities ?? [] })
            if !caps.isEmpty, rep.classification != nil { rep.classification!.capabilities = Array(caps).sorted() }
            if group.contains(where: { $0.integrated }) { rep.integrated = true }
            return rep
        }
        devices.sort { $0.displayGroup == $1.displayGroup ? $0.displayName < $1.displayName : $0.displayGroup < $1.displayGroup }
        let byGroup = Dictionary(grouping: devices) { $0.displayGroup }
        var lines: [String] = []
        for g in byGroup.keys.sorted() {
            lines.append("【\(g)】")
            for p in byGroup[g]! {
                let status = p.isControllable ? "已接入·可对话控制" : (p.classification == nil ? "待探测" : (p.classification!.integratable ? "可接入" : "暂不可接入"))
                let caps = (p.classification?.capabilities ?? []).joined(separator: "/")
                lines.append("  · [\(status)] \(p.displayName)\(p.displayName == p.name ? "" : "(\(p.name))")\(caps.isEmpty ? "" : " 能力:\(caps)") | id=\(p.id) — \(p.classification?.what ?? p.statusLine)")
            }
        }
        return "已连接外设:\n" + lines.joined(separator: "\n") + (peripheralHub.hint.isEmpty ? "" : "\n注:\(peripheralHub.hint)")
    }

    /// 大脑「探测清楚后写回外设身份」工具:把别名/用途/类型/能力/接入路/能否接入写回某台外设(id 见 peripherals)。
    func labelPeripheralTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "label_peripheral",
            description: "探测清楚一台外设后,把判定写回让列表显示语义名:它是什么(alias 别名,取代产品代号)、用途(what)、设备类型(device_type)、能力(capabilities 数组)、接入路(access:open_local/airplay/homekit/matter/needs_code/unknown)、能否接入(integratable)。id 见 peripherals 工具。",
            parametersJSON: """
            {"type":"object","properties":{
            "id":{"type":"string","description":"外设 id(peripherals 工具里给的)"},
            "alias":{"type":"string","description":"语义别名,如 床头灯/客厅音箱"},
            "what":{"type":"string","description":"一句话用途"},
            "device_type":{"type":"string","description":"设备类型分组,如 灯/音箱/鼠标"},
            "capabilities":{"type":"string","description":"能力,逗号分隔,如 开关,亮度,色温"},
            "access":{"type":"string","description":"接入路","enum":["open_local","airplay","homekit","matter","needs_code","unknown"]},
            "integratable":{"type":"boolean","description":"灵枢能否接入"},
            "canonical":{"type":"string","description":"(可选)归一键,合并同一物理设备的多条目"},
            "note":{"type":"string","description":"一句话怎么接"}
            },"required":["id","alias"]}
            """
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用。" }
            return await MainActor.run { self.applyPeripheralLabel(argsJSON) }
        }
    }

    private func applyPeripheralLabel(_ argsJSON: String) -> String {
        guard let id = Self.jsonField(argsJSON, "id"), !id.isEmpty else { return "缺少 id。" }
        func nonEmpty(_ s: String?) -> String? { let t = s?.trimmingCharacters(in: .whitespacesAndNewlines); return (t?.isEmpty == false) ? t : nil }
        let existing = peripheralHub.peripherals.first { $0.id == id }?.classification
        let caps = Self.commaList(Self.jsonField(argsJSON, "capabilities"))
        let cls = LingShuPeripheralClassification(
            canonical: nonEmpty(Self.jsonField(argsJSON, "canonical")) ?? existing?.canonical ?? "",
            alias: Self.jsonField(argsJSON, "alias") ?? existing?.alias ?? "",
            what: Self.jsonField(argsJSON, "what") ?? existing?.what ?? "",
            deviceType: Self.jsonField(argsJSON, "device_type") ?? existing?.deviceType ?? "",
            capabilities: caps.isEmpty ? (existing?.capabilities ?? []) : caps,
            access: nonEmpty(Self.jsonField(argsJSON, "access")) ?? existing?.access ?? "unknown",
            integratable: Self.jsonBool(argsJSON, "integratable") ?? existing?.integratable ?? false,
            note: Self.jsonField(argsJSON, "note") ?? existing?.note ?? "")
        peripheralHub.applyClassifications([id: cls])
        appendTrace(kind: .result, actor: "外设", title: "探测写回", detail: "\(cls.alias)(\(cls.deviceType))")
        return "已记下:【\(cls.alias)】\(cls.what)。能力:\(cls.capabilities.joined(separator: "/"))。\(cls.integratable ? "可接入(\(cls.access))" : "暂不可接入")。"
    }

    nonisolated static func jsonBool(_ json: String, _ key: String) -> Bool? {
        guard let data = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let b = o[key] as? Bool { return b }
        if let s = o[key] as? String { return s.lowercased() == "true" }
        return nil
    }

    /// 一台外设此刻的事实快照(交给大脑驱动 LOOP,大脑据此自己判断怎么做,壳不写死路径)。
    private func peripheralFacts(_ p: LingShuPeripheral) -> String {
        var f = "外设【\(p.displayName)】(id=\(p.id);原始事实:\(p.name) / \(p.raw))"
        if let c = p.classification {
            f += ";你之前的判断:这是\(c.alias.isEmpty ? "" : c.alias)(\(c.deviceType)),用途:\(c.what),能力:\(c.capabilities.joined(separator: "/")),接入路:\(c.access),可接入:\(c.integratable ? "是" : "否")"
        }
        if p.integrated { f += ";已接入,可对话控制" }
        return f
    }

    /// 接入 LOOP 共用的引导原则(AI 自驱动,壳只给意图+原则,不写死分支)。
    private static let adoptLoopPrinciple = """
    这是一个由你自驱动的接入 LOOP,目标:把这台外设接到我能用(能控/能读)。你自己跑 探测→判断能否接入→(接入前先问我确认)→完成接入→告诉我怎么用对话控它:
    - 你自己决定怎么探(web_search 查它协议/产品、在沙箱里连它试、读它返回)。搞清它是什么/什么用途/什么能力后,调 label_peripheral 写回(让列表显示语义名)。
    - 能自写驱动的(开放局域网协议/AirPlay 等)→ author_component(component_kind=actuator/sensor)自写驱动 + 沙箱测通 + 上线。
    - **遇到任何需要我配合的就一步步引导我,别自己卡住或瞎假设**:**要我选择/确认时用 `ask_choice` 弹可点击选项**(如"要不要接入?[接入]/[暂不]"、"走哪条方案?[A]/[B]"),别用自由问句让我打字;**只有要我提供信息时(配对码/token、把某设备移出某生态怎么做)才用 `ask_user`**,把怎么做讲清楚。
    - 接入前先用 `ask_choice` 跟我确认"要不要把它接进来"。接入后用一句话告诉我以后怎么对话控制它(如"对我说『开床头灯』")。
    遇到拿不准就问我,而不是放弃。
    """

    /// 面板「探测」:启动一个**只识别、不接入**的轻 LOOP(大脑自己查清这是什么 + 写回别名/能力/能否接入)。
    func probePeripheral(_ p: LingShuPeripheral) {
        selectedSurface = .chat   // 跳主对话,推进可见(选设备→带设备信息进对话)
        _ = submitTextWithAttachments(
            "探测这台外设、搞清它到底是什么(先别接入)。\(peripheralFacts(p))\n你自己决定怎么查(web_search/沙箱连它/读返回),搞清后调 label_peripheral 写回(id=\(p.id):alias 语义别名/what 用途/device_type/capabilities/access/integratable)。拿不准就 ask_user 问我。",
            source: .typed)
    }

    /// 面板「交给灵枢接入」:启动**完整接入 LOOP**——大脑自驱动 探测→判断→确认→接入→引导,壳不写死任何分支。
    /// 推进时跳主对话、带着设备信息发对话,接入/管理在主界面里推进(选设备→进对话)。
    func adoptPeripheral(_ p: LingShuPeripheral) {
        selectedSurface = .chat
        _ = submitTextWithAttachments("\(peripheralFacts(p))\n\n\(Self.adoptLoopPrinciple)", source: .typed)
    }
}
