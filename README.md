# 灵枢 (LingShu)

> 常驻在你 Mac 上的本地通用智能中枢 —— 你给目标，它自己判断、分派、推进到交付。

灵枢不是一问一答的聊天机器人，而是一个能独立做事的「数字人」:**大脑**是它自己的推理(分析、规划、决策、纠错)，**四肢**是各项能力工具，由大脑按需调用、自由组合。底层模型可随时替换，与灵枢的身份无关。

## 核心能力(四肢)

- **听 / 说**:语音输入(ASR)、TTS 发声;会议系统音频转写 + 实时应答(`meeting_converse`)。
- **读 / 写**:读写本地文件、网页、屏幕;交付物(PPT / 文档 / 代码 / 脚本)**真落盘**并给出绝对路径,不只是嘴上说"做好了"。
- **写代码 / 跑命令**:定位项目、读库、改代码、跑测试、提交 —— 自身即 AI 代码编辑器(代码任务验收门:**有测试且全绿**才算交付)。
- **联网查证**:`web_search` 核对时效信息,不凭记忆瞎答。
- **做产出物**:高质量 PPT 由自进化设计系统 **DesignKB** 驱动(多版式 + 配色库 + Lucide 图标 + 过程内审计 review_design)。
- **演示**:打开 PPT / PDF / Word / Excel 逐页讲解、翻页、滚动,中途实时答疑。
- **计算机操作**:授权后看屏(截图 / 取可点元素坐标)+ 操作(点击 / 输入 / 滚动)。
- **自主运行**:给定目标 + 素材,用统一 agent 循环自主推进到达成(可暂停 / 继续 / 接管,带独立 verifier 验收)。
- **记忆**:跨会话记住偏好、过往产出与未决事项;从任务窗口的纠正中蒸馏经验(dreaming)。
- **任务窗口**:codex 式执行流(命令 / 结果 / 文件 diff)。开发任务右侧分「产出物 / 代码管理」两页(改动统计、分支、提交);非代码任务只有产出物。
- **MCP 控制服务**:本机回环 `127.0.0.1:8917` HTTP JSON-RPC(`tools/list` / `tools/call`),可脚本化驱动与端到端取证(如 `lingshu_send_prompt` / `lingshu_clear_context` / `lingshu_task_detail`)。

## 隐私红线

感知数据(音频 / 视频 / 图片)**云端零留存** —— 实时感知只做即时解析,不落盘、不归档。详见 [Docs/PERCEPTION_AUDIT.md](Docs/PERCEPTION_AUDIT.md)。

## 构建与运行

需 macOS 14+、Xcode 命令行工具(Swift)。

```bash
# 构建并打成 .app(用本机签名身份,可持久化 TCC 授权)
bash Scripts/build-app.sh debug

# 运行 —— 必须以 .app 包运行(裸二进制会丢图标 + 麦克风/隐私授权)
open dist/灵枢.app
```

可选:提供 notarytool 凭据公证内置 HAL 虚拟麦驱动 ——
`LINGSHU_SIGN_IDENTITY="Developer ID Application: …" LINGSHU_NOTARY_PROFILE=<profile> bash Scripts/build-app.sh debug`。

> 注:会议「把灵枢的声音送回会议里让对方听见」依赖自建 HAL 虚拟麦克风,目前驱动实现层仍在调试(设备尚未稳定出现);本机听 + 应答闭环可用。

## 测试

```bash
swift test                 # 单元 / 集成(脱网确定性:脚本化模型 + 真 executor 真读写真跑命令)
bash Scripts/smoke-e2e.sh  # 真模型端到端冒烟(证明引擎从头跑通一个任务)
```

## 架构文档

- [Docs/架构速查手册.md](Docs/架构速查手册.md) —— **canonical 速查**:模块索引 + 关键决策 + 教训(开发前先查、改动后必更新)。
- [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) —— 总体架构。
- [Docs/ROADMAP.md](Docs/ROADMAP.md) —— 路线图。

---

由 **Roy Zhao** 独立开发。
