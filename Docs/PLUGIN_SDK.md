# LingShu Runtime Plugin Contract

LingShu plugins are local capability packages loaded by the shared
`Runtime/LingShuCore` kernel. The Windows shell does not maintain a second
plugin implementation: installed tools enter the same model tool loop,
permission mode, task ledger, and artifact registry as built-in tools.

## Package Layout

```text
my-plugin/
├── plugin.json
├── runner.exe
└── optional-assets/
```

Install the package by selecting `plugin.json` on the **Plugins** page.
LingShu copies the package into its application-data plugin directory, rejects
symbolic links and unsafe IDs, and makes enabled tools available on the next
model turn.

## Manifest

```json
{
  "schemaVersion": 1,
  "id": "example.reporter",
  "name": "Example Reporter",
  "version": "1.0.0",
  "description": "Create a local report.",
  "descriptionZh": "生成本地报告。",
  "enabled": true,
  "permissions": {
    "fileRead": true,
    "fileWrite": true,
    "network": false,
    "shell": false,
    "systemSensitive": false
  },
  "entrypoint": {
    "command": "runner.exe",
    "arguments": ["{{tool}}"],
    "timeoutSeconds": 120
  },
  "tools": [
    {
      "name": "create_report",
      "description": "Create a report in LingShu's Workspace.",
      "descriptionZh": "在灵枢 Workspace 中生成报告。",
      "capabilities": ["artifact.report"],
      "priority": 50,
      "fallback": false,
      "parameters": {
        "type": "object",
        "properties": {
          "file": { "type": "string" },
          "content": { "type": "string" }
        },
        "required": ["file", "content"]
      }
    }
  ]
}
```

Plugin and tool IDs are stable API identifiers. A tool is exposed to the model
as `plugin__<plugin-id>__<tool-name>`, with non-alphanumeric ID characters
converted to underscores.

## Capability Routing

`capabilities` declares semantic operations independently from a plugin or tool
name. When a runtime-ready plugin provides the capability required by a task,
LingShu must use a plugin unless the user explicitly disables all plugins for
that request.

Provider selection is deterministic:

1. Enabled, available, runtime-ready providers only.
2. Non-fallback providers before fallback providers.
3. Higher `priority` before lower `priority`.
4. Stable plugin and tool IDs as the final tie-breaker.

The model sees only the preferred provider for each capability. The runtime
also enforces the same route at execution time, so an old prompt or model call
that names a lower-priority foundation tool cannot bypass a better plugin.
Provider errors or structured `{ "ok": false }` rejections advance to the next
provider. A structured `needs_user_action` result pauses for the user instead
of silently switching implementation.

Every capability-routed result includes `pluginRouting` metadata with the
policy, capability, selected provider, original tool request, fallback flag,
and attempted providers. This makes plugin usage observable without leaking
raw implementation output into the conversation.

## Capability Acquisition

Plugin routing and software installation are separate mechanisms. LingShu
automatically selects an already registered, enabled, runtime-ready plugin; it
does not download arbitrary plugins from the Internet because the current
runtime has no signed remote plugin catalog. A local plugin is installed only
after its `plugin.json` is selected on the **Plugins** page.

Host applications and command-line dependencies are not plugins. Microsoft
Word, WPS Office, LibreOffice, PowerPoint, OCR engines, and package managers
must be probed as host software. In Full Access mode, installing a reputable
dependency through the host package manager is already authorized. The agent
should perform that installation and continue without asking again merely for
installation permission. Login, licensing, payment, administrator/UAC
interaction, physical actions, and untrusted download sources still require
the user.

## Process Contract

The entrypoint is launched directly, never through an implicit shell.
Tool arguments are sent as one JSON object on standard input. The process must
return its result on standard output and exit with code `0`.

LingShu sets these environment variables:

- `LINGSHU_PLUGIN_ID`
- `LINGSHU_PLUGIN_TOOL`
- `LINGSHU_WORKSPACE`
- `LINGSHU_EXECUTION_PERMISSION_MODE` (`sandbox` or `full_access`)

Entrypoint argument templates support:

- `{{plugin_dir}}`
- `{{workspace}}`
- `{{tool}}`
- `{{input}}`
- `{{input.field}}`

To register generated files, return a JSON object containing a `path`,
`artifactPath`, `artifactPaths`, or `artifacts` field. Only existing files
contained by the active Workspace are accepted into the task artifact ledger.

## Permission Behavior

`fileRead` and `fileWrite` plugins may run in Sandbox mode. A plugin declaring
`network`, `shell`, or `systemSensitive` returns a structured
`needs_user_action` result until the session is switched to Full Access.
The manifest is an execution gate and a user-facing declaration; plugin authors
must still implement least-privilege behavior inside their runner.

## Built-in Providers

`lingshu.office-foundation` supplies dependency-free DOCX, XLSX, and basic PPTX
fallback capabilities on every platform. `lingshu.design-kb` is one bundled,
higher-priority PPTX provider. Both participate in the same generic capability
router as third-party plugins; neither is selected through a product-specific
branch in the model prompt.

## 中文摘要

Windows 版插件不是一个只展示列表的前端模块。插件由共享 Rust 内核读取
`plugin.json`，作为模型工具参与同一套权限判断、任务执行和产物登记。
插件通过标准输入接收 JSON，通过标准输出返回结果；需要联网、Shell 或系统
敏感权限时，在沙箱模式下会返回结构化的人机授权请求。插件通过 `capabilities`
声明能力；只要存在可用提供者，内核就强制使用插件，并按“非兜底优先、优先级
从高到低”选择。仅当用户在当前请求中明确要求禁用全部插件时才绕过。内置
Office Foundation、DesignKB 和第三方插件都遵循同一套路由规则。

插件路由只会自动选择“已登记且运行就绪”的插件；当前没有签名远程插件目录，
因此不会从互联网静默下载任意插件。本地插件仍需在插件页选择 `plugin.json`。
Word、WPS、LibreOffice、PowerPoint、OCR 引擎等属于宿主软件或命令行依赖，
不是灵枢插件。完整权限模式已经授权通过可信包管理器安装依赖，代理应先探测、
安装并继续执行；只有登录、许可证、付款、管理员/UAC、物理操作或不可信来源
才需要再次询问用户。
