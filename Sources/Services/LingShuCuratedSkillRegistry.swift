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

    static let skills: [CuratedSkill] = [presentation, engineering].compactMap { $0 }

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
        - **每页选一个最合适的版式**(layout 字段),让全篇有节奏、不是一个模子:cover/agenda/section/bullets/bignumber/image-right/image-left/image-full/twocol/timeline/quote/chart/**compare**/closing。
        - **内容↔版式映射(别什么都堆 bullets——这是"丑"的根源)**:差异化/多方案对比 → **`compare`(对比表,columns+rows,第2列默认高亮=本方案)**;优缺点/价值与难点/前后对比 → `twocol`(左右两张卡);流程/路线/阶段 → `timeline`;有数据 → `chart`(原生图表);单个震撼指标 → `bignumber`;并列要点 → `bullets`(配 icons)。先想"这页内容最适合哪种呈现",再选 layout。
        - **审美红线(避免 AI 味)**:DesignKB 已去掉标题前的强调色条/侧边条,你也别在内容里堆同质 bullets;每页一个清晰焦点,留白要够。
        - 每页只讲一件事；**页标题写成结论(断言式)**，不是话题词("三年降本 40%"而非"成本情况")。页数 8–14。
        - **内容是讲给受众听的"产品/主题价值",绝不是讲工具本身**:严禁把"怎么做这份 PPT"的内部机制写进幻灯——不写设计系统/配色名(如 DesignKB、midnight)、"版式库/N 套配色"、生成器、工作目录或任何文件路径。观众只关心主题本身。`bignumber` 的数字必须是有意义的业务/产品指标,不是"版式数量"这类自指数字。
        - **配图极挑剔,宁缺毋滥**:**抽象主题**(AI/软件/服务/方法论/流程)**优先用 `icons`(Lucide 名如 check/zap/target/brain)+ `chart`(柱/折/饼)+ 色块做视觉,通常别配照片**——这类主题搜到的多是无关风景/通用人物/办公摆拍,放上去显得廉价。**只有主题是具体实物/真实场景**(产品硬件、门店、活动现场…)才用 `find_images`(具体英文关键词,如 "smart thermostat device"),且**搜回来的图必须肉眼切题才用,不切题就删掉 image 字段改用图标**。带水印/风景/无关人脸一律不用。
        - **收尾页 contact** 写真实联系方式(姓名/邮箱/网址)或**留空**,绝不写文件路径/目录。
        - **选 DesignKB 自带配色,别套联网模板**:DesignKB 的 palettes 本身就是打磨好的专业主题——商务/科技/汇报这类**默认选深色专业风**(`theme:"midnight"`/`"graphite"`/`"royal"`),浅色场合用 ivory/sand。**不要 `acquire_resource` 联网找通用 .pptx 模板来套**(实测套通用 Office 模板会把深色专业风变成寡淡白底、版式更乱,远不如直接用 DesignKB 配色)。**只有当用户明确提供了他自己的品牌模板 .pptx**,才把它填进 `template` 字段并设 `theme:"template"`(让全篇采用该品牌配色)。
        - 流程:① 选好 `theme`(默认深色)+ 逐页 layout,把内容(layout/theme/image/icons/chart)写成 `slides.json`(write_file);② 用 **apply_skill 给出的生成器路径** run_command 跑出 .pptx;③ **`review_design` 自审是硬步骤**:看返回的逐页问题——**只要有任一页 < 0.7 或被指出配图不切题/重叠/截断/纯文字,就改 slides.json 对应页(换 layout/删无关图换图标/精简文字)重新跑生成器,再 review_design,如此迭代直到每页都达标**,别一审完就交;④ `ls -la *.pptx && file *.pptx` 确认落盘。**绝不把脚本甩给用户自己跑。**

        ## 交付物模板
        slides.json(DesignKB generator 直接吃;每页 layout 决定排版):
        {
          "theme": "midnight",
          "template": "(仅当用户提供品牌模板时填其绝对路径,并把上面的 theme 设为 \\"template\\")",
          "title": "演示标题(页脚用)",
          "slides": [
            {"layout":"cover","title":"主标题","subtitle":"副标题","tagline":"一句话主旨"},
            {"layout":"agenda","title":"目录","items":["第一部分","第二部分","第三部分"]},
            {"layout":"section","index":"01","title":"章节名","subtitle":"小标题"},
            {"layout":"bullets","title":"结论式标题","bullets":["要点一","要点二","要点三"],"icons":["zap","target","users"]},
            {"layout":"bignumber","number":"40%","label":"关键指标","title":"一句说明"},
            {"layout":"image-right","title":"论点","bullets":["..."],"image":"assets/图.jpg","icons":["check"]},
            {"layout":"twocol","title":"对比","left":{"heading":"方案A","bullets":["..."]},"right":{"heading":"方案B","bullets":["..."]}},
            {"layout":"compare","title":"差异化对比","columns":["维度","本方案","对手A","对手B"],"rows":[["部署","本地","云端","云端"],["范围","全流程","单点","单点"]]},
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
        - **配图切题**:每张照片都贴主题;有无关风景/通用人物/办公摆拍/带水印 → 不合格(应删图改图标)
        - **无内部机制泄露**:幻灯里没有设计系统/配色名/版式库/生成器/文件路径/工作目录等"怎么做"的字样;contact 不是路径
        - 每页一个核心点，标题是结论式断言而非话题词；bignumber 是有意义的业务指标
        - 用了 DesignKB 生成器(版式/配色/图标统一)，不是从零拼朴素文本框
        - 配色统一克制、对齐到网格、无文字重叠/截断
        """
        guard let loaded = LingShuSkillLoader.parse(markdown, fallbackID: "curated-ppt") else { return nil }
        return CuratedSkill(loaded: loaded, domain: "presentation", qualityScore: 0.95)
    }()

    /// 自主软件开发专家:把"给我开发一个 X"做成**像资深工程师的完整闭环**——自己写代码 + 自己跑完整测试
    /// (build + 单测 + 真 e2e 冒烟)+ 红的自己修到全绿再交付,绝不假完成。配合验收门测试门 + Scripts/smoke-e2e.sh。
    private static let engineering: CuratedSkill? = {
        let markdown = """
        ---
        id: curated-engineering
        title: 自主软件开发专家（策展·完整测试闭环）
        mission: 像资深工程师那样自主开发软件,并自己跑完整测试(build + 单测 + 端到端冒烟)、红的自己修到全绿再交付,绝不口头"已完成"。
        triggers: 开发,develop,写代码,写一个程序,写个程序,做一个工具,做个工具,做一个应用,做个应用,实现一个,重构,修复bug,修bug,改bug,命令行工具,cli,sdk,后端服务,写脚本工具,工程化
        ---

        ## 专业要点（完整开发闭环,每步都做)
        - **先看清再动手**:`read_file`(带行号,大文件 offset/limit 分段读全)+ `run_command` grep/find/ls 摸清现状与依赖,别凭空写。多步任务**第一动作是 update_plan** 列 3–7 步。
        - **增量精确改**:改已有文件用 `edit_file`(局部替换,容忍小空白出入);新建/整重写才 `write_file`。大型多文件工程按"读→改→搜→测"逐文件推进。
        - **写代码必须配测试并跑绿(硬步骤,非可选)**:用 write_file 写测试(用例随复杂度增多)、run_command 跑测试框架(swift test / pytest / npm test / go test…)迭代到**全部通过**。测试文件也是产出物。**代码任务验收门会确定性检查"有测试且全绿",没测试/没跑通一律打回。**
        - **可运行的 app/服务/CLI:单测之外还要跑端到端冒烟**——真构建、真启动、真驱动它、按**真实行为/真落盘产物**断言,而不是只看单测。**本仓库的范式见 `Scripts/smoke-e2e.sh`**:构建 → 启动实例 → 经控制服务发真请求 → 按盘上真产出物断言 PASS/FAIL → 拆。开发别的可运行程序时照此搭一个最小冒烟(起进程→喂输入→断言输出/退出码→收尾)。
        - **红的自己修、迭代到全绿再交付**:编译错、测试红、冒烟失败,都是**喂回上下文的观测**,据此改方法继续,别交一个没跑通的东西,别把"你自己跑一下"甩给用户(假完成红线)。
        - **长耗时外部步骤(公证/下载/CI/部署)用 `watch_until` 挂后台守候**,满足即自动续跑,不阻塞、不傻等。
        - **交付时给硬证据**:文件绝对路径 + 怎么构建/运行 + 测试与冒烟的真实结果(通过数/输出),不空说"已完成"。

        ## 交付物模板
        - 源码文件(write_file/edit_file 真落盘)
        - 配套测试文件 + 一次**真实跑通**的测试输出(run_command,全绿)
        - 可运行程序:一个最小端到端冒烟(脚本或步骤)+ 跑过的 PASS 证据
        - 一句话交付说明:做了什么、文件在哪(绝对路径)、怎么跑、测试/冒烟结果

        ## 评审清单
        - 源码真实落盘(ls/file 可证),不是只在回复里贴
        - 能编译/构建通过(run_command 真跑过,不靠声明)
        - **有测试且全绿**(真跑过测试框架,通过数可见;没测试=不达标)
        - **程序真正运行起来不崩**(run_command 真跑过它本身,运行期不崩溃/不抛未处理异常;跑崩=不达标,必须修到跑通——验收门会确定性查"最近一次构建/运行不崩")
        - 可运行程序:**端到端冒烟真跑通**(真启动+真驱动+断言,不只单测)
        - 回复给了绝对路径 + 运行方式 + 真实测试/冒烟结果,无"你自己跑一下"式甩锅
        - 改动聚焦本任务,没引入无关破坏(必要时 grep/跑既有测试确认没回归)
        """
        guard let loaded = LingShuSkillLoader.parse(markdown, fallbackID: "curated-engineering") else { return nil }
        return CuratedSkill(loaded: loaded, domain: "engineering", qualityScore: 0.9)
    }()
}
