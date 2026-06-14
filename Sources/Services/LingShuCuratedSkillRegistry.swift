import Foundation

/// 自进化 skill 模块 · Phase 1：**策展、纯提示、质量分排序**的内置 skill 库 + 自动引入。
///
/// 设计取向（按用户拍板）：
/// - skill 不该手搓一个个领域，而是做成"会自己长能力"的机制。Phase 1 先落地最安全的一档：
///   灵枢自有的**策展 registry**（纯提示型 = 只有专家知识文本、无可执行脚本 → 零执行风险，可自动引入）。
/// - 命中任务领域时按质量分选最优 skill，自动顶替通用内置专家（用户自有 skill 仍最优先）。
/// - 是否需要 skill、选哪个，最终由编排/模型判断；这里只提供"安全可自动引入的候选池"。
///
/// 不在 Phase 1 内（留给 Phase 2/3）：远程 registry / git 来源、自动更新、带可执行脚本的 skill
/// （那些必须过信任门 + 脚本授权弹窗，绝不自动执行未审来源代码——供应链红线）。
enum LingShuCuratedSkillRegistry {
    struct CuratedSkill {
        let loaded: LingShuSkillLoader.LoadedSkill
        let domain: String
        /// 领域排行用的质量分（0–1）。Phase 2 可换成实测通过率 / 采用次数等真实信号。
        let qualityScore: Double
    }

    static let skills: [CuratedSkill] = [presentation].compactMap { $0 }

    /// 给定任务文本，返回命中且**质量最高**的策展 skill（纯提示 → 可安全自动引入）。
    static func bestSkill(forTask task: String) -> LingShuSkillLoader.LoadedSkill? {
        let normalized = task.lowercased()
        return skills
            .filter { skill in skill.loaded.triggers.contains { normalized.contains($0.lowercased()) } }
            .max(by: { $0.qualityScore < $1.qualityScore })?
            .loaded
    }

    // MARK: - 策展 skill 内容（纯提示）

    /// 首个策展 skill：专业 PPT 设计 —— 由 DesignKB(设计系统 + 多版式生成器 + 图标 + 配图)驱动,
    /// 把"做 PPT"从"背景+文字"升级成有版式变化/图片/图标/图表的专业排版。生成器不内联在此(在 DesignKB),
    /// `apply_skill` 会把生成器绝对路径与跑法给模型(见 LingShuState+AgentSkills.applySkillTool)。
    private static let presentation: CuratedSkill? = {
        let markdown = """
        ---
        id: curated-ppt
        title: PPT 设计专家（策展·DesignKB 驱动）
        mission: 产出排版专业、有版式变化、带图片/图标/图表的 .pptx，而不是"背景 + 一堆文字"。
        triggers: ppt,演示,幻灯,slides,presentation,自我介绍,汇报材料,路演,述职,招商,产品介绍
        ---

        ## 专业要点
        - 先定受众 + 一句话核心讯息，排叙事弧：封面 → 目录 → 章节/定位 → 核心能力 → 数据/案例 → 对比/路线 → 价值愿景 → 收尾行动点。
        - **每页选一个最合适的版式**(layout 字段),让全篇有节奏、不是一个模子:cover/agenda/section/bullets/bignumber/image-right/image-left/image-full/twocol/timeline/quote/chart/closing。
        - 每页只讲一件事；**页标题写成结论(断言式)**，不是话题词("三年降本 40%"而非"成本情况")。页数 8–14。
        - **要有视觉,但配图必须切题**:`find_images` 用**具体英文关键词**(贴主题,如 "smart home sensors" 而非泛词);**找不到切题的好图就别硬塞**——不相关的会议照/通用照/带水印图会拉低质感,这种时候宁可用 `icons`(Lucide 名如 check/zap/target)+ 色块 + `chart`(柱/折/饼)做视觉,更专业。要点尽量配图标。
        - 选一个贴合主题气质的 `theme`(配色见 DesignKB palettes:midnight/graphite/ivory/sand/forest/royal)。
        - **先找资源再动手,别凭空硬造**:① 先 `acquire_resource(kind:"pptx-template", query:<品类,如 business/tech/report>)` 找模板——本地有直接用,没有它会联网找并入库;拿到模板路径就填进 slides.json 的 `template` 字段当底(继承专业母版/主题)。② 配图先 `find_images`(切题);需要图标集/字体也可 `acquire_resource`。
        - 流程:① 先 `acquire_resource` 找模板/素材;② 按模板把逐页内容(含 layout/theme/template/image/icons/chart)写成 `slides.json`(write_file);③ 用 **apply_skill 给出的生成器路径** run_command 跑出 .pptx;④ `review_design` 自审,不达标改了重跑;⑤ `ls -la *.pptx && file *.pptx` 确认落盘。**绝不把脚本甩给用户自己跑、绝不不找资源就空造。**

        ## 交付物模板
        slides.json(DesignKB generator 直接吃;每页 layout 决定排版):
        {
          "theme": "midnight",
          "template": "(可选)acquire_resource 拿到的 .pptx 模板绝对路径,做底继承专业母版",
          "title": "演示标题(页脚用)",
          "slides": [
            {"layout":"cover","title":"主标题","subtitle":"副标题","tagline":"一句话主旨","image":"assets/封面.jpg"},
            {"layout":"agenda","title":"目录","items":["第一部分","第二部分","第三部分"]},
            {"layout":"section","index":"01","title":"章节名","subtitle":"小标题"},
            {"layout":"bullets","title":"结论式标题","bullets":["要点一","要点二","要点三"],"icons":["zap","target","users"]},
            {"layout":"bignumber","number":"40%","label":"关键指标","title":"一句说明"},
            {"layout":"image-right","title":"论点","bullets":["..."],"image":"assets/图.jpg","icons":["check"]},
            {"layout":"twocol","title":"对比","left":{"heading":"方案A","bullets":["..."]},"right":{"heading":"方案B","bullets":["..."]}},
            {"layout":"timeline","title":"路线","steps":[{"label":"阶段1","desc":"说明"},{"label":"阶段2","desc":"说明"}]},
            {"layout":"chart","title":"数据结论","chart":{"type":"bar","categories":["Q1","Q2","Q3"],"series":[{"name":"营收","values":[10,20,35]}]}},
            {"layout":"quote","quote":"金句","attrib":"出处"},
            {"layout":"closing","title":"收尾标题","bullets":["行动点1","行动点2"],"contact":"联系方式"}
          ]
        }

        ## 评审清单
        - .pptx 真实落盘(file/ls 可证，体积 > 20KB)；页数 8–14(python-pptx 实测，不靠声明)
        - **版式有变化**:不是每页同一个模子;至少用到封面 + 章节/目录 + 要点 + 图文/数字/图表 + 收尾
        - **有视觉支撑**:有真实配图(image)或图标(icons)或图表(chart)，不是纯文字
        - 每页一个核心点，标题是结论式断言而非话题词
        - 用了 DesignKB 生成器(版式/配色/图标统一)，不是从零拼朴素文本框
        - 配色统一克制、对齐到网格、无文字重叠/截断
        """
        guard let loaded = LingShuSkillLoader.parse(markdown, fallbackID: "curated-ppt") else { return nil }
        return CuratedSkill(loaded: loaded, domain: "presentation", qualityScore: 0.95)
    }()
}
