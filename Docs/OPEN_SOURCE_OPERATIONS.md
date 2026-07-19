# 灵枢开源发布与持续运营手册

> 目标不是制造一次性的 Star 峰值，而是让陌生开发者能够看懂、安装、复现、提出问题并愿意留下。

## 当前进度（2026-07-19）

已完成：中英文 README、真实界面截图、GitHub 社交预览图源文件、首发演示脚本与中英文发布文案、Apache-2.0、社区与安全文档、Issue/PR 模板、CI、仓库双语描述、16 个 Topics、贡献区域标签、GitHub Discussions、当前文件与可达历史的高置信度密钥扫描，以及超过 1,500 项 Swift 测试。当前 HEAD 已移除不应公开的运行时验证产物，并增加守卫测试防止再次误提交。动态运行图、通用人机协作、验收三态与断点续验已进入同一运行时协议；模型凭据由 macOS Keychain 保存并支持旧配置安全迁移。App 内已集成一问一答式 `lingshu` CLI，外部飞书/Webhook 连接器可以复用同一主会话、授权与人机交互断点。本机还已跑通过 Universal DMG、Developer ID 签名、Apple 公证、票据装订与 SHA-256 校验。

官方中英双语网站已上线：<https://royzhao1991.github.io/LingShu/>。首屏使用隔离数据的真实产品界面，集中提供签名 DMG、Homebrew、源码、三分钟首个任务路径、安全边界和旗舰汇报交付说明；GitHub Pages 由 `main` 自动部署，仓库 Homepage 已指向官网。上线提交 `8e11fdf` 的 Pages 部署与完整 Swift CI 均通过，桌面和手机视口、双语切换、安装命令复制、公开资源与下载链接已完成验收。

已完成首个可下载的真实公开样例：虚构 Project Aurora 任务通过灵枢内置 CLI 生成四页 PPTX 与单页 DOCX，并在独立渲染发现问题后完成多轮修订、Office 结构规范化和逐页视觉复核。仓库与官网同时提供 PDF 在线查看、可编辑 PPTX、DOCX 和完整修订记录。

已完成 71.2 秒端到端公开演示：真实 Project Helios 任务使用合成数据生成四页可编辑 PPTX 与单页 DOCX，等待段明确标注为 12 倍加速，实际产物逐页展示，结尾补充 GoalSpec、5/5 计划、独立 checker 与产物登记。演示明确披露结尾账本画面来自第二次已验证的合成数据任务；MP4、README 循环 GIF 和海报均已完成逐帧隐私检查。

当前发布状态：仓库已经公开；`v0.1.0-alpha.6` 从提交 `af829f1` 的干净源码生成。Build 9 增加可复现的 Project Aurora PPTX/DOCX/PDF 公开样例，修复浅色授权可读性与英文子线程角色分类，并完成 Universal DMG、Developer ID 签名、App 与 DMG 两次 Apple 公证、票据装订、包内源码版本校验和四类 SHA-256 登记；私密漏洞报告已开启。71.2 秒公开演示已经完成，干净 Mac 安装与更多外部用户反馈继续作为首发后的高优先级增强，不虚构为已经完成。

首发时点的公开指标记录在 [`OPEN_SOURCE_BASELINE.md`](./OPEN_SOURCE_BASELINE.md)，后续周检只基于可核验数据做同比，不把下载次数直接等同于成功安装。

## 一、当前判断

灵枢已经具备进入执行型 Agent 赛道的产品基础。正确参照物是 Codex 与 Claude Code，而不是聊天工具。差异不在“会不会写代码”，而在完整原生 App 与 Agent 运行时采用 Apache-2.0、模型层可替换，以及代码、Office 文件、媒体和授权后的 Mac 工作流共用同一套可验收执行链。风险不在“代码量不够”，而在陌生开发者能否在几十秒内理解这个差异，并在几分钟内完成安装与首次成功。

高 Star 不能被承诺，只能通过产品价值、安装成功率、演示传播力和持续维护共同提高概率。禁止购买 Star、互刷、批量私信或用无法复现的演示换取关注。

## 二、公开前发布闸门

- [x] Git 历史通过密钥扫描；Token 形态命中均为脱敏测试夹具，未发现真实 API Token 或 Apple 凭据。
- [x] 当前 HEAD 不再跟踪运行时验证产物，并使用中性测试路径替代个人本机路径。
- [x] Swift Package 无外部依赖；已复核大体积跟踪文件、PDF 元数据和内置图标来源，当前仅 Lucide 需要第三方归属且已随包保留许可证。
- [x] 已审计历史中的旧验证产物、个人路径和作者身份元数据；未发现真实 Token、私钥或 Apple 凭据，并明确接受提交作者与旧开发路径会作为历史元数据公开，不重写既有主线。
- [x] Apache-2.0、第三方声明、贡献指南、安全策略和行为准则齐备。
- [x] README 中英文内容与当前代码一致，没有把实验能力写成稳定能力。
- [x] README 使用隔离演示数据的真实产品截图，不含用户历史、凭据或私人文件。
- [x] GitHub Discussions、双语描述、Topics、标签与贡献入口已配置。
- [x] 官方中英双语 GitHub Pages 已上线，首页、安装、下载、源码与安全入口均可达，并由 `main` 自动部署。
- [x] GitHub 社交预览图、60-90 秒演示镜头表与中英文首发文案已准备。
- [ ] 在一台干净 Mac 上按 README 从源码构建成功。
- [x] 从最终绿色提交产出 Universal DMG，完成 Developer ID 签名、Apple 公证、票据装订和 SHA-256 校验。
- [ ] 用全新用户目录完成首次主脑配置和最小任务闭环。
- [x] 准备 60-90 秒真实演示视频和 3-5 张不含私人数据的产品截图。
- [x] 发布一套不含私人数据、可直接下载并检查的 PPTX/DOCX/PDF 真实样例与逐页预览。
- [x] 更新并发布首个 Release 的最终安装包、版本说明、已知限制和回滚下载入口。
- [x] 确认 Private vulnerability reporting 已开启。

## 三、首发叙事

一句话定位：

> LingShu is an Apache-2.0, model-agnostic macOS execution agent in the Codex / Claude Code category. Bring your own model and deliver verified code, documents, slides, and authorized computer actions through one open runtime.

六个传播支柱：

1. **与 Codex / Claude Code 同赛道**：灵枢是执行型 Agent，不以聊天 App 作为竞品锚点。
2. **完整 App 与运行时开源**：Swift 原生 App、编排、工具、任务记录、产物账本、记忆与 Computer Use 采用 Apache-2.0。
3. **不被单一模型锁定**：OpenAI、Claude、DeepSeek、MiniMax 与自定义兼容端点共用能力层。
4. **代码不是交付边界**：同一执行链可以完成代码、PPTX、DOCX、PDF、媒体和授权后的 Mac 工作流。
5. **可检查的真实交付**：文件落盘、登记、预览、测试和验收状态都能追踪。
6. **可接入而不复制大脑**：内置 CLI 让飞书、Webhook、快捷指令等进入同一主会话，并保留权限与人机交互续接。

## 四、首个 30 天节奏

### 第 0 周：公开准备

- 完成安全扫描、干净安装、签名公证和 README 演示素材。
- 创建 8-12 个范围清晰的公开 Issue，其中至少 3 个标记 `good first issue`。
- 把实验性限制写入 Release Notes，不隐藏 HAL、云感知或外部服务依赖。

### 第 1 周：首发

- 发布 `v0.1.0-alpha`、DMG、SHA-256 和 60-90 秒演示。
- 同步发布中英文介绍，展示同一条真实任务从目标到产物验收的完整路径。
- 首发后 48 小时优先解决安装、启动、权限和 Token 配置问题。

### 第 2 周：证明可复现

- 发布三篇短案例：完整 PPT/文档汇报交付、原生 Computer Use、跨模型 maker/checker。
- 每个案例提供输入、环境、产物和已知限制，不只放结果截图。
- 整理高频问题并回写 README/FAQ，减少重复支持成本。

### 第 3 周：建立贡献入口

- 合并首批小型社区 PR，公开感谢贡献者。
- 发布一次架构导读，明确哪些模块适合新贡献者、哪些属于高风险内核。
- 对无法立即实现的需求给出决策和路线，不让 Issue 无回应沉底。

### 第 4 周：数据复盘

- 对照访客、克隆、Release 下载、Star 转化、Issue 首响和安装失败原因。
- 只保留真正带来安装、复现或贡献的渠道和内容类型。
- 发布第一个月开发日志与下月三个明确里程碑。

## 五、运营看板

每周记录一次，避免被单日 Star 波动误导：

| 指标 | 含义 | 优先动作 |
| --- | --- | --- |
| README 访问到 Star 转化 | 定位和演示是否打动目标用户 | 调整首屏叙事与演示 |
| Release 下载到成功启动 | 分发和首次配置是否可靠 | 修安装、权限与引导 |
| Issue 首次响应时间 | 项目是否有人维护 | 24-48 小时内分类回应 |
| 可复现 Bug 比例 | 模板和诊断能力是否有效 | 改日志、诊断条与模板 |
| 外部 PR 数与合并周期 | 是否形成贡献生态 | 拆小 Issue、补开发文档 |
| 7/30 日回访 | 用户是否持续使用 | 追踪高价值工作流 |

阶段目标建议以真实用户行为定义：先获得 100 个愿意安装或关注的早期用户，再验证 500 Star 阶段的贡献入口，最后以稳定 Release、外部贡献者和复现案例推动 1,000+。任何数字都不是保证，达不到时优先修产品与分发，不做数据造假。

## 六、仓库元数据建议

Description：

> Apache-2.0, model-agnostic macOS agent in the Codex / Claude Code category—bring your own model to deliver verified code, docs, slides, and computer actions.

Topics：

`macos`, `swift`, `ai-agent`, `autonomous-agents`, `computer-use`, `multimodal`, `llm`, `mcp`, `agentic-ai`, `local-first`, `openai`, `anthropic`, `codex`, `claude-code`, `model-agnostic`, `open-source-ai`

## 七、每周维护纪律

- 周一：分类新 Issue，更新可复现状态和优先级。
- 周三：发布一个可验证的技术片段、案例或性能数据。
- 周五：合并已验证改动，更新变更日志和下周目标。
- 每个 Release：干净安装、权限、主脑配置、最小交付、更新与回滚全部复测。
- 每月：删除失效承诺，更新对比表、截图、架构图与已知限制。

首发演示镜头表、中英文发布文案和发布顺序见 [`LAUNCH_KIT.md`](./LAUNCH_KIT.md)。

## 八、从成熟 Agent 项目借鉴的运营范式

参考 [OpenClaw](https://github.com/openclaw/openclaw) 与 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 的公开路径，灵枢不复制功能清单，而是复用下面这套可持续范式：

1. **一句话品类清楚**：先明确“与 Codex / Claude Code 同类的执行型 Agent”，再用“完整运行时开源、模型无关、代码不是边界”解释差异，不同时争夺所有 Agent 标签。
2. **只保留一个推荐入口**：Homebrew/签名 DMG、首次语言选择、连接自有模型、运行一条小型交付任务；其余高级能力后置。
3. **让证据靠近首屏**：README 与官网同时提供 Project Aurora 可编辑文件、PDF 和修订记录，让陌生用户先检查结果。
4. **同一内核，多种入口**：App、CLI、Webhook 与未来消息连接器复用主会话、权限、人机协作和产物账本，避免每个入口形成一套不一致的 Agent。
5. **发布节奏可预测**：Alpha 先解决安装、首启、权限和可复现性；稳定后再区分 stable/beta/dev 通道，不用功能数量掩盖可靠性问题。
6. **增长来自贡献循环**：公开小而清晰的 Issue、快速回应安装障碍、感谢真实贡献者，并把每周案例或缺陷复盘沉淀回文档。

当前最优先缺口是全新用户目录的首次配置闭环、干净 Mac 安装反馈和首批外部贡献。每周只选择一个能改善“看懂 -> 安装 -> 首次成功 -> 反馈/贡献”的实验，记录结果后再决定是否保留。
