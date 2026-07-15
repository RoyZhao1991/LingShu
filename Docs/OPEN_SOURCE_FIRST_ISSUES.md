# 首批公开 Issue 候选

这些候选用于仓库公开前建立真实、可贡献的工作入口。创建 Issue 前应再次核对现状，不把已经完成的内容重复发布。

## Good first issue

### 1. Add an English troubleshooting page for first-run macOS permissions

说明辅助功能、屏幕录制、麦克风、语音识别和摄像头权限的触发时机、失败表现与恢复方式。不得建议绕过系统权限。

标签：`documentation`, `good first issue`

### 2. Add a provider-neutral model configuration diagnostics export

导出端点可达性、协议类型、模型名和脱敏错误，不得包含 Token。输出需同时适用于 OpenAI 兼容和 Anthropic Messages 通道。

标签：`enhancement`, `good first issue`, `area: model-gateway`

### 3. Improve third-party notice discovery during release builds

增加确定性检查，确保新增资源目录中的 LICENSE/NOTICE 被收集或明确审阅；缺失声明时让 Release 检查失败。

标签：`documentation`, `good first issue`

## Help wanted

### 4. Create a privacy-safe demo profile and screenshot capture workflow

提供不读取真实聊天、任务、记忆或用户目录的演示数据模式，用于生成 README 截图和发布视频。演示数据必须明确标记为样例。

标签：`enhancement`, `help wanted`

### 5. Split CI into fast pull-request checks and the complete 1,525-test suite

快速门应覆盖架构守卫、模型协议、任务生命周期、权限与验收；全量套件在 main、定时或手动触发。两条路径都不能静默跳过失败。

标签：`enhancement`, `help wanted`

### 6. Add clean-machine installation smoke automation

验证从源码构建、首次启动、主脑引导、权限未授予状态和最小直答任务。不得依赖维护者个人目录或凭据。

标签：`enhancement`, `help wanted`

### 7. Add protocol contract fixtures for model providers

为 OpenAI Responses、Chat Completions、Anthropic Messages、流式、多模态尝试与降级建立脱网 fixture，禁止通过模型名称硬编码能力。

标签：`enhancement`, `help wanted`, `area: model-gateway`

### 8. Benchmark native Computer Use on a reproducible app set

设计可公开复现的 Finder、TextEdit、Safari 或测试宿主场景，记录语义定位成功率、动作验证率、回退次数和延迟。

标签：`enhancement`, `help wanted`, `area: computer-use`

## Maintainer-owned launch blockers

### 9. Publish the first signed and notarized Universal DMG

按发布脚本完成 Developer ID 签名、Apple 公证、DMG staple、SHA-256、安装与回滚验证。

标签：`alpha feedback`

### 10. Produce a 60-90 second end-to-end launch demo

用一条真实、可复现、无私人数据的目标展示：配置主脑、生成 GoalSpec、调用工具或 Computer Use、登记产物、独立验收和最终预览。

标签：`documentation`, `alpha feedback`
