# Project Aurora: a real LingShu deliverable loop

This public sample uses fictional project data and contains no user history, credentials, private paths, or external account details.

## Brief

> Create a concise four-slide executive presentation and a one-page written brief for a fictional software release-quality initiative called Project Aurora. Use synthetic metrics, save editable PPTX and DOCX files, register the artifacts, preview the actual output, and have an independent checker verify the result.

LingShu received this brief through its bundled `lingshu` CLI, using a configured DeepSeek brain and the same serialized main conversation, tools, artifact ledger, and verification path as the macOS app.

## Final deliverables

- [View the four-slide PDF](./project-aurora-demo.pdf)
- [Download the editable PPTX](./project-aurora-demo.pptx)
- [Download the one-page DOCX](./project-aurora-demo.docx)

![Project Aurora result slide](../../Docs/media/project-aurora/slide-3.png)

## What the run proved

The first pass created both files and registered them in the task record. Independent rendering then found issues that the initial checker had missed, so the same task was revised and checked again:

1. The first render exposed an extra slide and a duplicate title.
2. The next pass fixed the physical slide count, then visual review found a text collision, low-contrast chart labels, and a fictional email that looked like a real call to action.
3. A later pass fixed those defects, but review still found that percentages and hours shared one misleading chart axis.
4. The final revision replaced the mixed-unit chart with separate KPI comparisons and removed the fake contact detail.
5. A final local Office normalization pass corrected non-standard internal shape IDs. The published PPTX then passed structural overflow checks, rendered as exactly four 16:9 slides, and was reviewed page by page.

This is the behavior LingShu is designed around: completion is not the model saying “done.” The real file is rendered, inspected, revised, and checked. The run also exposed a useful limitation: checker coverage still needs to improve so more of these defects are caught before an external visual QA pass.

---

# Project Aurora：灵枢真实交付闭环

本公开样例全部使用虚构项目与合成数据，不包含用户历史、凭据、私人路径或外部账号信息。

任务要求是：为虚构的软件发布质量改进项目 Project Aurora 生成一份四页管理汇报 PPT 和一页书面简报，交付可编辑的 PPTX 与 DOCX，登记真实产物、预览文件，并交给独立 checker 验收。

灵枢通过随 App 交付的 `lingshu` CLI 接收任务，复用了和 macOS App 相同的串行主会话、工具、产物账本与验收路径。初稿完成后，独立渲染依次发现了页数、文字重叠、低对比度、虚构联系方式和混合单位图表等问题；灵枢在同一任务目标下连续修订，最终产物通过结构检查并逐页完成视觉复核。

这个样例证明的不是“一次生成完美”，而是灵枢能够围绕真实文件完成生成、登记、发现问题、修订和再次验收的闭环。
