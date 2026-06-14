import Foundation

/// 本地 skill 接入 agent 循环:把「固化专家技能(设计系统/交付模板/评审清单 + 自带生成器脚本)」
/// 暴露给统一 agent 主会话/子任务/自主运行,而不只接外部 MCP。
///
/// 设计取向(与组合注册表 LingShuCompositeExpertRegistry 同源,不重复匹配逻辑):
/// - 取用由模型编排(apply_skill 工具),命中真 skill 时回合开头自动提示其存在(可发现性)。
/// - skill 自带生成器(已过安全门)物化到工作目录,模型 run_command 直接跑它,不从零硬写。
@MainActor
extension LingShuState {

    /// 把 skill 自带且已过安全门控的生成器脚本物化到目录,返回脚本绝对路径(无脚本/写失败返回 nil)。
    /// 旧协同管线与 agent apply_skill 共用此唯一落地点。
    @discardableResult
    func materializeBundledScript(for profile: LingShuExpertProfile, into directory: String) -> String? {
        guard let script = profile.bundledScript, let name = profile.bundledScriptName else { return nil }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url.path
    }

    /// 当前输入确定性命中「真 skill」(用户/策展,排除内置兜底)时的回合提示语,供回合开头插入。
    /// 内置兜底专家(id 不带 skill- 前缀)不提示——只为固化/专门化 skill 做可发现性广播。
    func matchedSkillHint(for prompt: String) -> String? {
        let profile = expertProfileRegistry.profile(for: prompt)
        guard profile.id.hasPrefix("skill-") else { return nil }
        let hasGenerator = profile.bundledScriptName != nil
        return "【可用技能】本任务匹配到固化专家技能「\(profile.title)」\(hasGenerator ? "(含自带生成器脚本)" : "")。"
            + "先调用 apply_skill 取它的设计系统/交付模板/评审清单\(hasGenerator ? "并就绪自带生成器" : "")，按它推进，别从零硬写。"
    }

    /// apply_skill 工具:模型按任务调取匹配技能(组合注册表:用户 > 策展 > 内置),
    /// 返回其专家提示 + 评审清单,并把自带生成器物化到工作目录(给出路径)。
    func applySkillTool() -> LingShuAgentTool {
        let workingDir = codexWorkingDirectory
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
                return out
            }
        }
    }
}
