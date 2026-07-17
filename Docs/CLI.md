# LingShu CLI and External Connectors

[English](#english) | [简体中文](#简体中文)

## English

`lingshu` is a thin command-line entrance to LingShu's existing main conversation. It is designed for Feishu bots, webhooks, macOS Shortcuts, shell automation, and other local adapters that need a predictable one-request/one-response contract.

It does **not** create a second brain or a privileged back door. Every request enters the same serialized main session and therefore shares the app's selected model, context, memory, task queue, authorization level, artifact ledger, and human-interaction protocol.

### Install

The signed Universal DMG bundles the CLI inside the app:

```bash
mkdir -p "$HOME/.local/bin"
ln -sf "/Applications/灵枢.app/Contents/MacOS/lingshu" "$HOME/.local/bin/lingshu"
export PATH="$HOME/.local/bin:$PATH"
```

Add the final `export` line to your shell profile if needed. Source builds place the executable at `.build/debug/lingshu` or `.build/release/lingshu`.

### Commands

```text
lingshu ask [--json] [--timeout SECONDS] "<message>"
echo "<message>" | lingshu ask
lingshu answer [--json] <message-id> "<result>"
lingshu status [--json]
lingshu stop [--json]
```

`ask` launches LingShu when necessary, submits one turn to the main conversation, and waits for a terminal reply, a typed human action, failure, or timeout. A timeout does not cancel the task; it continues in the app. `stop` uses the same stop path as the app.

### JSON contract

`lingshu ask --json` returns:

```json
{
  "status": "completed | needs_user_action | failed | timed_out",
  "reply": "user-facing result or current state",
  "recordID": "task record when one exists",
  "messageID": "exact main-conversation message",
  "interaction": null
}
```

For `needs_user_action`, `interaction` contains its type, prompt, options, and renderable materials. An adapter should present those fields to the user, collect the result, then call `lingshu answer <message-id> ...`. This resumes the exact paused checkpoint and clears the matching interaction in the app.

Exit codes: `0` completed, `1` failed or unavailable, `3` human action required, `4` timed out while still running, and `64` invalid CLI usage.

### Connector pattern

Keep connectors deliberately small:

1. Receive a Feishu, webhook, or local automation message.
2. Run `lingshu ask --json` with the user's text on stdin.
3. Render `reply` when completed.
4. For `needs_user_action`, render `interaction` and retain `messageID`.
5. Submit the user's result through `lingshu answer --json`.

The connector owns transport identity and delivery retries. LingShu owns reasoning, serialization, permissions, execution, memory, and resume semantics. Do not run several CLI turns concurrently against the main conversation; queue them at the connector, just as the app serializes main-session work.

### Local control boundary

The default endpoint is `http://127.0.0.1:8917/mcp`. It is loopback-only. Optional environment variables:

- `LINGSHU_MCP_URL`
- `LINGSHU_MCP_PORT`
- `LINGSHU_MCP_TOKEN`
- `LINGSHU_CLI_TIMEOUT`
- `LINGSHU_CLI_POLL_INTERVAL`
- `LINGSHU_CLI_NO_LAUNCH=1`

Do not expose this local control service directly to the public internet. Put authentication, rate limits, sender allowlists, and replay protection in the external connector.

## 简体中文

`lingshu` 是灵枢现有主会话的轻量命令行入口，适合飞书机器人、Webhook、macOS 快捷指令、脚本自动化和其他需要稳定“一问一答”协议的本地连接器。

它不会新建第二个大脑，也不是绕过权限的后门。每条请求都进入同一个串行主会话，共用 App 当前选择的模型、上下文、记忆、任务队列、授权等级、产物账本和人机交互协议。

### 安装

签名公证的 Universal DMG 已把 CLI 放在 App 内：

```bash
mkdir -p "$HOME/.local/bin"
ln -sf "/Applications/灵枢.app/Contents/MacOS/lingshu" "$HOME/.local/bin/lingshu"
export PATH="$HOME/.local/bin:$PATH"
```

按需把最后一行加入 Shell 配置。源码构建的可执行文件位于 `.build/debug/lingshu` 或 `.build/release/lingshu`。

### 命令与状态

```text
lingshu ask [--json] [--timeout SECONDS] "<消息>"
echo "<消息>" | lingshu ask
lingshu answer [--json] <message-id> "<操作结果>"
lingshu status [--json]
lingshu stop [--json]
```

`ask` 会按需启动灵枢，把一轮消息提交到主会话，并等待最终回复、结构化人工步骤、失败或超时。超时不会取消 App 内仍在运行的任务；`stop` 与 App 使用同一条停止路径。

JSON 的 `status` 取值为 `completed`、`needs_user_action`、`failed` 或 `timed_out`。需要人工参与时，`interaction` 会携带类型、提示、选项和可展示材料，连接器展示后保留 `messageID`，再通过 `lingshu answer` 续接精确断点。App 内对应交互卡也会同步结束。

退出码：`0` 完成，`1` 失败或服务不可用，`3` 等待人工操作，`4` 已超时但任务仍在运行，`64` 命令参数错误。

### 飞书与 Webhook 范式

连接器只做五件事：接收消息、排队、调用 `lingshu ask --json`、展示结果或交互材料、用 `lingshu answer --json` 回填用户结果。外部连接器负责身份验证、投递重试和消息平台协议；灵枢负责思考、串行化、授权、执行、记忆与断点恢复。

不要让多个外部请求同时抢占主会话。飞书或 Webhook 连接器应当排队逐个提交，这与 App 主会话的串行原则一致。

默认控制地址为 `http://127.0.0.1:8917/mcp`，只监听本机回环。不要把它直接暴露到公网；公网入口必须在连接器侧增加鉴权、限流、发送者白名单和防重放。
