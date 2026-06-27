import Foundation

/// 本地 skill 接入 agent 循环:把「固化专家技能(设计系统/交付模板/评审清单 + 自带生成器脚本)」
/// 暴露给统一 agent 主会话/子任务/自主运行,而不只接外部 MCP。
///
/// 设计取向(与组合注册表 LingShuCompositeExpertRegistry 同源,不重复匹配逻辑):
/// - 取用由模型编排(apply_skill 工具),命中真 skill 时回合开头自动提示其存在(可发现性)。
/// - skill 自带生成器(已过安全门)物化到工作目录,模型 run_command 直接跑它,不从零硬写。
@MainActor
extension LingShuState {

    /// P4:把扩展面板的启停同步进专家注册表——**停用的 skill 不再被匹配/应用**(real enforcement)。
    /// 启动 + reloadUserSkills + 面板切换后调。
    func syncExtensionEnablement() {
        (expertProfileRegistry as? LingShuCompositeExpertRegistry)?.setDisabledSkillIDs(LingShuExtensionRegistry.shared.disabledIDs)
    }

    /// 把 skill 自带且已过安全门控的生成器脚本物化到目录,返回脚本绝对路径(无脚本/写失败返回 nil)。
    /// 旧协同管线与 agent apply_skill 共用此唯一落地点。
    @discardableResult
    func materializeBundledScript(for profile: LingShuExpertProfile, into directory: String) -> String? {
        guard let script = profile.bundledScript, let name = profile.bundledScriptName else { return nil }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        // P3:记录"物化脚本路径 → 该 skill 声明的权限",供 run_command 跑它时经 sandbox-exec confine(无声明=最小权限)。
        let perms = (expertProfileRegistry as? LingShuCompositeExpertRegistry)?.permissions(forProfileID: profile.id) ?? LingShuPluginPermissions()
        materializedSkillScripts[url.path] = perms
        // 自发现高风险 skill:其脚本被隔离时,把"路径→风险点"登记到运行期隔离表,
        // 首次 run_command 跑它会强制弹审批(把 LLM 风险点摆给用户裁决),即便会话已"完全授权"。
        if let notes = LingShuSkillAcquisition.quarantinedRiskNotes(forSkillID: profile.id) {
            quarantinedScriptPaths[url.path] = (skillID: profile.id, notes: notes)
        }
        return url.path
    }

    // MARK: - P2 动态工具:skill 的 provides 接成 live agent 工具

    /// P2:把**启用**的用户 skill 声明的 `provides:` 工具接成真 `LingShuAgentTool`——每个工具调用时把入参 JSON
    /// 经 stdin 灌进该 skill 的 runner 脚本(`<解释器> <脚本> <工具名>`),读 stdout 当结果,脚本经 P3 沙箱按声明权限跑。
    /// 这才让"插件提供工具"真正生效(此前 `provides` 只被解析、从不成为可调用工具)。
    /// 在主 agent 会话工具装配处并入;停用的 skill(P4)由 `providedToolSkills()` 自动排除。
    func userSkillProvidedTools() -> [LingShuAgentTool] {
        guard let registry = expertProfileRegistry as? LingShuCompositeExpertRegistry else { return [] }
        var tools: [LingShuAgentTool] = []
        for skill in registry.providedToolSkills() {
            guard let script = skill.profile.bundledScript,
                  let scriptName = skill.profile.bundledScriptName,
                  let runnerPath = materializeRunner(script: script, name: scriptName, skillID: skill.profile.id)
            else { continue }
            let interpreter = Self.runnerInterpreter(forScriptNamed: scriptName)
            // 自编/自发现组件的隔离状态:被隔离的(高风险/权限偏高)→ 工具仍可见,但首次运行强制人工审批。
            let quarantineNotes = LingShuSkillAcquisition.quarantinedRiskNotes(forSkillID: skill.profile.id)
            // 描述用组件自述职责(mission)优先,让模型知道这条四肢是干什么的、怎么传参。
            let role = skill.profile.mission.isEmpty ? "由插件提供的工具" : skill.profile.mission
            let specs = skill.manifest.providedTools.map { name in
                LingShuPluginToolProvider.ToolSpec(
                    name: name,
                    description: "\(role)(由外围组件「\(skill.profile.title)」提供;入参以 JSON 经 stdin 传入,返回脚本 stdout 输出)"
                )
            }
            let made = LingShuPluginToolProvider.makeTools(
                manifest: skill.manifest, specs: specs,
                runnerExecutable: interpreter, runnerArguments: [runnerPath], sandbox: true
            )
            // M4:执行器型(frontmatter 带 actuator_risk)→ physical 每次执行确认;reversible 同工具型(隔离则首次审批)。
            let actuatorRisk = skill.frontmatter["actuator_risk"].map { LingShuActuatorSafety.Risk.from($0) }
            let actuatorTarget = skill.frontmatter["actuator_target"] ?? ""
            tools += made.map { base in
                if actuatorRisk == .physical {
                    return actuatorGatedTool(base, name: skill.profile.title, target: actuatorTarget)
                }
                if let notes = quarantineNotes {
                    // **安全红线**:隔离组件的 runner 绝不静默执行——首次调用强制走人工审批(复用 run_command 隔离闸)。
                    return quarantineGatedTool(base, runnerPath: runnerPath, skillID: skill.profile.id, notes: notes)
                }
                return base
            }
        }
        return tools
    }

    /// M4:执行器物理/不可逆动作的**每次执行确认门**(比首次审批更强:每一次调用都让主人确认,即便会话完整授权)。
    /// 非交互(自主/无头)安全拒绝、绝不静默触发。复用 run_command 审批基础设施(`forceConfirm`)。
    private func actuatorGatedTool(_ base: LingShuAgentTool, name: String, target: String) -> LingShuAgentTool {
        LingShuAgentTool(
            name: base.name,
            description: base.description + "(⚠️ 物理/不可逆动作:每次执行都需主人确认)",
            parametersJSON: base.parametersJSON
        ) { [weak self] args in
            guard let self else { return "执行环境不可用。" }
            let wd = await MainActor.run { self.agentWorkingDirectory }
            let prompt = LingShuActuatorSafety.confirmationPrompt(actuatorName: name, target: target, command: args)
            let decision = await self.requestShellApproval(command: prompt, workingDirectory: wd, taskRecordID: nil, forceConfirm: true)
            guard decision != .deny else {
                return "⛔ 执行器「\(name)」的物理/对外动作未获主人确认,已拒绝执行(不可逆/对外动作每次都需确认)。"
            }
            return await base.handler(args)
        }
    }

    /// 把一个隔离组件的 live 工具包成"首次运行强制人工审批"的门(绝不静默执行未审/高风险 runner)。
    /// 复用既有隔离闸:把 runner 路径登记进 `quarantinedScriptPaths` 再请求审批 → 命中即便会话完整授权也强制弹窗;
    /// 用户首肯后 `resolveShellApproval` 自动解除隔离,此后该工具正常调用。非交互(自主/无头)按安全默认拒绝、不卡死。
    private func quarantineGatedTool(_ base: LingShuAgentTool, runnerPath: String, skillID: String, notes: [String]) -> LingShuAgentTool {
        LingShuAgentTool(
            name: base.name,
            description: base.description + "(⚠️ 隔离中:首次运行需主人审批)",
            parametersJSON: base.parametersJSON
        ) { [weak self] args in
            guard let self else { return "执行环境不可用。" }
            // 仍处隔离 → 先过审批门;已解除 → 直接跑。
            let stillQuarantined = LingShuSkillAcquisition.quarantinedRiskNotes(forSkillID: skillID) != nil
            if stillQuarantined {
                let wd = await MainActor.run { () -> String in
                    self.quarantinedScriptPaths[runnerPath] = (skillID: skillID, notes: notes)
                    return self.agentWorkingDirectory
                }
                let decision = await self.requestShellApproval(
                    command: "首次运行自编外围组件 runner:\(runnerPath)", workingDirectory: wd, taskRecordID: nil)
                guard decision != .deny else {
                    return "⛔ 外围组件「\(base.name)」处于隔离状态(风险点:\(notes.joined(separator: "; ")));首次运行未获授权,已拒绝执行。"
                }
            }
            return await base.handler(args)
        }
    }

    /// 把 skill 的 runner 脚本物化到稳定目录(`~/Library/Application Support/LingShu/Skills/runners/<skillID>/`),
    /// 供 P2 动态工具在任意回合调用(独立于 apply_skill 的工作目录物化)。返回脚本绝对路径,写失败返回 nil。
    func materializeRunner(script: String, name: String, skillID: String) -> String? {
        let dir = LingShuSkillLoader.defaultDirectory
            .appendingPathComponent("runners", isDirectory: true)
            .appendingPathComponent(skillID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url.path
    }

    /// 按 runner 脚本扩展名选解释器(.py→python3 / .sh→zsh / .js→node);未知按 python3 兜底。
    nonisolated static func runnerInterpreter(forScriptNamed name: String) -> String {
        let lower = name.lowercased()
        if lower.hasSuffix(".sh") { return "/bin/zsh" }
        if lower.hasSuffix(".js") {
            for p in ["/usr/local/bin/node", "/opt/homebrew/bin/node"] where FileManager.default.isExecutableFile(atPath: p) { return p }
            return "/usr/bin/env"   // 兜底:env node(若 PATH 有)
        }
        return "/usr/bin/python3"
    }

    /// 当前输入确定性命中「真 skill」(用户/策展,排除内置兜底)时的回合提示语,供回合开头插入。
    /// 内置兜底专家(id 不带 skill- 前缀)不提示——只为固化/专门化 skill 做可发现性广播。
    func matchedSkillHint(for prompt: String) -> String? {
        let profile = expertProfileRegistry.profile(for: prompt)
        guard profile.id.hasPrefix("skill-") else { return nil }
        // **降低摩擦(2026-06-27):把方法直接摆出来,而不是只说"先去调 apply_skill"。**
        // 实测大脑(Kimi/DeepSeek 都有此病)看见"先 apply_skill"那一步嫌麻烦就跳过、改从零现编。把固化技能的
        // **完整方法内联**进呈现,大脑不必多走一步就能照做。仍是"呈现 + 让大脑自己判断用不用",不强制、不写死场景
        // (内联的是该 skill **自己声明的内容** promptBlock,通用机制非特判)。
        let method = profile.promptBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasGenerator = profile.bundledScriptName != nil
        var out = "【本任务有现成的固化方法】匹配到固化专家技能「\(profile.title)」。**下面是它的完整方法——照它做通常更快更稳、产出更一致(你若判断确实不合适,也可以不照它做):**\n\n"
        out += String(method.prefix(1800))
        if hasGenerator {
            out += "\n\n(它自带生成器脚本:调用 apply_skill 可把生成器就绪到工作目录再跑。)"
        }
        if !profile.reviewChecklist.isEmpty {
            out += "\n\n交付前自查:" + profile.reviewChecklist.prefix(3).joined(separator: " / ")
        }
        return out
    }

    /// apply_skill 工具:模型按任务调取匹配技能(组合注册表:用户 > 策展 > 内置),
    /// 返回其专家提示 + 评审清单,并把自带生成器物化到工作目录(给出路径)。
    func applySkillTool() -> LingShuAgentTool {
        let workingDir = agentWorkingDirectory
        return LingShuAgentTool(
            name: "apply_skill",
            description: "调取与任务匹配的固化专家技能(设计系统/交付模板/评审清单)，并把该技能自带的生成器脚本就绪到工作目录。做 PPT/汇报等有固化方案的交付前先调用，拿到方案与生成器后按它推进，别从零硬写。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"task\":{\"type\":\"string\",\"description\":\"要匹配技能的任务/领域描述\"}},\"required\":[\"task\"]}"
        ) { [weak self] argsJSON in
            let task = Self.jsonField(argsJSON, "task") ?? argsJSON
            return await MainActor.run { [weak self] in
                guard let self else { return "技能库不可用" }
                let profile = self.expertProfileRegistry.profile(for: task)
                var out = profile.promptBlock
                if !profile.reviewChecklist.isEmpty {
                    out += "\n评审清单(交付前自检):\n" + profile.reviewChecklist.map { "- \($0)" }.joined(separator: "\n")
                }
                if let path = self.materializeBundledScript(for: profile, into: workingDir) {
                    out += "\n自带生成器已就绪:\(path)(设计系统已内置、已过安全门)。按交付模板把内容写成数据文件后，用 run_command 跑它产出真交付物，不要从零另写生成代码。"
                }
                // PPT 设计 skill:生成器在 DesignKB(多版式 + 配色 + 图标 + 配图,数据驱动),就地跑、自动读同目录素材。
                if profile.id == "skill-curated-ppt", let generator = LingShuDesignKB.generatorPath {
                    let layouts = LingShuDesignKB.layoutIDs().joined(separator: "/")
                    let palettes = LingShuDesignKB.paletteIDs().joined(separator: "/")
                    out += """

                    【DesignKB 高质量生成器(已就绪,就地跑别复制别从零写)】
                    0) **配色用 DesignKB 自带主题,别联网套模板**:商务/科技/汇报默认 `theme:"midnight"`(或 graphite/royal 深色专业风),浅色用 ivory/sand。**不要 acquire_resource 联网找通用 .pptx 模板**——实测套通用 Office 模板会把深色专业风变成寡淡白底、更乱。只有用户**明确给了自己的品牌模板**才填 `template` 路径并设 `theme:"template"`。
                    1) 把逐页内容按上面 slides.json 模板写到工作目录(每页选 layout、定 theme)。**视觉默认用 icons(Lucide 名:check/zap/target/brain…)+ chart + bignumber + 色块**:做 AI/软件/服务/方法论这类**抽象主题就别配照片、别调 find_images、别填 image 字段**——免费图库对抽象词常返回无关风景/劣质图,你又看不到图无法判断切题 → 必翻车;**只有主题是具体实物/真实场景**(硬件、门店、现场)才调 find_images 且关键词具体。**内容只讲主题对受众的价值,绝不把设计系统/配色名(DesignKB/midnight)/版式库/生成器/工作目录或任何文件路径写进幻灯;收尾 contact 写真实联系方式或留空,不要填路径。**
                    2) run_command 跑:python3 "\(generator)" slides.json 演示.pptx
                       (配色/版式/图标素材库在生成器同目录自动读取;缺依赖先 pip3 install python-pptx pillow)
                    3) ls -la 演示.pptx && file 演示.pptx 确认落盘。
                    4) **过程内自审(必做,别等最终验收,别一审完就交)**:调 review_design(path=刚生成的 .pptx)拿设计质量分 + 逐页问题;**只要任一页 < 0.7、或被指出「配图不相关/重叠/截断/纯文字/失衡」,就改 slides.json 对应页(删无关图改 icons、换 layout、精简文字),重新跑生成器,再 review_design,如此迭代到每页都达标(逐页都 OK)再交付。**
                    **直接走以上四步,别去探测/启动任何 office 应用(wps/wpsoffice/LibreOffice/Keynote/PowerPoint)——生成与自审都用这个 python 生成器 + review_design,不需要它们(那些 GUI 程序会卡住命令)。**
                    可用版式:\(layouts.isEmpty ? "cover/agenda/section/bullets/bignumber/image-right/image-left/image-full/twocol/timeline/quote/chart/closing" : layouts)
                    可用配色:\(palettes.isEmpty ? "midnight/graphite/ivory/sand/forest/royal" : palettes)
                    """
                    // 自进化闭环:dreaming 从历史设计评分学到的经验,注入提示指导本次选版式/配色(热加载)。
                    if let insights = LingShuDesignKB.designInsights() {
                        out += "\n\n【自固化设计经验(dreaming 从历史评分学来,务必参考)】\n\(insights)"
                    }
                }
                return out
            }
        }
    }
}
