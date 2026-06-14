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

    /// 首个策展 skill：专业 PPT 设计 —— 把"做 PPT"从通用专家升级成有设计系统 + 真实生成路线 +
    /// 可达验收标准（不依赖 LibreOffice/OCR 那套重工具链）。
    private static let presentation: CuratedSkill? = {
        let markdown = """
        ---
        id: curated-ppt
        title: PPT 设计专家（策展）
        mission: 产出真实可打开、设计专业的 .pptx 演示文件，而不是给用户一段脚本让他自己跑。
        triggers: ppt,演示,幻灯,slides,presentation,自我介绍,汇报材料,路演
        script_name: generator.py
        ---

        ## 专业要点
        - 先定受众 + 一句话核心讯息，再排叙事弧：封面 → 我是谁/定位 → 核心能力 → 案例或亮点 → 价值/愿景 → 收尾行动点。
        - 每页只讲一件事；**页标题写成结论（断言式）**，不是话题词（"三年降本 40%"而非"成本情况"）。
        - 页数 8–12 页之间；单页正文要点 3–5 条、每条一行。
        - **工作目录已备好本 skill 自带的生成器 `generator.py`（设计系统、配色 #0B1220/#25F4E4、字号层级、版式网格已内置且打磨过）。你不要从零写生成代码。**
        - 流程：① 按下面模板把逐页内容写成 `slides.json`（write_file）；② run_command 跑 `python3 generator.py slides.json 自我介绍.pptx` 生成真文件（python-pptx 通常已装，缺了先 `pip3 install python-pptx`）；③ 自检：generator 会打印页数，再 `ls -la 自我介绍.pptx && file 自我介绍.pptx` 确认落盘。
        - **绝不把脚本甩给用户让他自己跑**——你自己用 run_command 跑。

        ## 交付物模板
        把逐页内容写成 slides.json，结构如下（generator.py 直接吃它）：
        {
          "slides": [
            {"title": "结论式标题", "subtitle": "副标题(可选)", "bullets": ["要点一", "要点二", "要点三"]}
          ]
        }
        要点：8–12 页；首页封面、末页行动点；每页 title 是结论、bullets 3–5 条。

        ## 生成脚本
        ```python
        import sys, json
        from pptx import Presentation
        from pptx.util import Inches, Pt
        from pptx.dml.color import RGBColor
        from pptx.enum.text import PP_ALIGN

        BG = RGBColor(0x0B, 0x12, 0x20)
        ACCENT = RGBColor(0x25, 0xF4, 0xE4)
        INK = RGBColor(0xF2, 0xFF, 0xFD)
        MUTED = RGBColor(0x9F, 0xB8, 0xB4)

        src = sys.argv[1] if len(sys.argv) > 1 else 'slides.json'
        out = sys.argv[2] if len(sys.argv) > 2 else '演示.pptx'
        data = json.load(open(src, encoding='utf-8'))
        slides = data.get('slides', data if isinstance(data, list) else [])

        prs = Presentation()
        prs.slide_width = Inches(13.333)
        prs.slide_height = Inches(7.5)
        blank = prs.slide_layouts[6]

        def text_box(slide, left, top, width, height, text, size, color, bold=False, align=PP_ALIGN.LEFT):
            box = slide.shapes.add_textbox(Inches(left), Inches(top), Inches(width), Inches(height))
            tf = box.text_frame
            tf.word_wrap = True
            p = tf.paragraphs[0]
            p.alignment = align
            run = p.add_run()
            run.text = str(text)
            run.font.size = Pt(size)
            run.font.bold = bold
            run.font.color.rgb = color
            run.font.name = 'PingFang SC'
            return box

        CONTENT_W = 11.8   # 内容区宽(留左右安全边),标题字号据此自适应避免右边缘截断
        for i, s in enumerate(slides, 1):
            slide = prs.slides.add_slide(blank)
            fill = slide.background.fill
            fill.solid()
            fill.fore_color.rgb = BG
            text_box(slide, 0.9, 0.7, 2.0, 0.5, '%02d' % i, 18, ACCENT, bold=True)
            # 标题字号按长度自适应(防止长标题溢出/被右边缘截断),并据估算行数动态下推副标题/正文——
            # 杜绝"标题换两行就和副标题重叠"的版式崩。
            title = str(s.get('title', ''))
            tsize = 40 if len(title) <= 14 else (34 if len(title) <= 20 else 28)
            chars_per_line = max(1, int(CONTENT_W * 72 / tsize))
            tlines = max(1, (len(title) + chars_per_line - 1) // chars_per_line)
            title_h = tlines * (tsize / 72.0) * 1.32
            text_box(slide, 0.9, 1.2, CONTENT_W, title_h + 0.15, title, tsize, INK, bold=True)
            y = 1.2 + title_h + 0.38
            if s.get('subtitle'):
                text_box(slide, 0.9, y, CONTENT_W, 0.7, str(s.get('subtitle')), 20, ACCENT, bold=True)
                y += 0.95
            y = max(y, 3.9)   # 正文起始不高于此,留出呼吸感
            bullets = s.get('bullets', [])
            if bullets:
                box = slide.shapes.add_textbox(Inches(0.9), Inches(y), Inches(CONTENT_W), Inches(max(1.5, 7.2 - y)))
                tf = box.text_frame
                tf.word_wrap = True
                for j, b in enumerate(bullets):
                    p = tf.paragraphs[0] if j == 0 else tf.add_paragraph()
                    run = p.add_run()
                    run.text = '•  ' + str(b)
                    run.font.size = Pt(18)
                    run.font.color.rgb = MUTED
                    run.font.name = 'PingFang SC'
                    p.space_after = Pt(10)

        print(len(prs.slides))
        prs.save(out)
        ```

        ## 评审清单
        - .pptx 文件真实落盘（file / ls 输出可证，且体积 > 10KB）
        - 页数在 8–12 之间（generator 打印的 len 或 python-pptx 实测，不靠声明）
        - 有封面页与收尾行动页，中间每页一个核心点
        - 每页标题是结论式断言，而非话题词
        - 用了自带 generator.py（设计系统统一），不是从零拼朴素板式
        - 叙事有起承转合，不是要点平铺
        """
        guard let loaded = LingShuSkillLoader.parse(markdown, fallbackID: "curated-ppt") else { return nil }
        return CuratedSkill(loaded: loaded, domain: "presentation", qualityScore: 0.9)
    }()
}
