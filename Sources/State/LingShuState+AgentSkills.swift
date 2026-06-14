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
                // PPT 设计 skill:生成器在 DesignKB(多版式 + 配色 + 图标 + 配图,数据驱动),就地跑、自动读同目录素材。
                if profile.id == "skill-curated-ppt", let generator = LingShuDesignKB.generatorPath {
                    let layouts = LingShuDesignKB.layoutIDs().joined(separator: "/")
                    let palettes = LingShuDesignKB.paletteIDs().joined(separator: "/")
                    out += """

                    【DesignKB 高质量生成器(已就绪,就地跑别复制别从零写)】
                    0) **先找资源**:`acquire_resource(kind:"pptx-template", query:<品类,如 business/tech/report>)` 找模板——本地有直接用,没有它联网找并入库;拿到 .pptx 路径就填进 slides.json 的 `template` 字段做底。需要图标/字体也可 acquire_resource。
                    1) 把逐页内容按上面 slides.json 模板写到工作目录(每页选 layout、选 theme);需要配图先调 find_images 取本地图片路径填进 image 字段。
                    2) run_command 跑:python3 "\(generator)" slides.json 演示.pptx
                       (配色/版式/图标素材库在生成器同目录自动读取;缺依赖先 pip3 install python-pptx pillow)
                    3) ls -la 演示.pptx && file 演示.pptx 确认落盘。
                    4) **过程内自审(必做,别等最终验收)**:调 review_design(path=刚生成的 .pptx)拿设计质量分 + 逐页问题;**分 < 0.7 或有版式硬伤(重叠/截断/纯文字/失衡)就改对应页的 slides.json(换 layout/精简文字/补图标配图),重新跑生成器,再 review_design,直到 ≥0.7 再交付。**
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
