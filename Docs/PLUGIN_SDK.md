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

To register generated files, return a JSON object containing a `path`, `paths`,
`artifact`, or `artifacts` field. Only existing files contained by the active
Workspace are accepted into the task artifact ledger.

## Permission Behavior

`fileRead` and `fileWrite` plugins may run in Sandbox mode. A plugin declaring
`network`, `shell`, or `systemSensitive` returns a structured
`needs_user_action` result until the session is switched to Full Access.
The manifest is an execution gate and a user-facing declaration; plugin authors
must still implement least-privilege behavior inside their runner.

## Built-in DesignKB

`lingshu.design-kb` is shipped with LingShu and cannot be removed. Its layouts,
palettes, typography, icon library, generation engine, and review rubric are
bundled into the Windows installer. The shared kernel exposes
`create_designed_presentation` to the model and registers the generated
PowerPoint in the same artifact ledger as every other task output.

## 中文摘要

Windows 版插件不是一个只展示列表的前端模块。插件由共享 Rust 内核读取
`plugin.json`，作为模型工具参与同一套权限判断、任务执行和产物登记。
插件通过标准输入接收 JSON，通过标准输出返回结果；需要联网、Shell 或系统
敏感权限时，在沙箱模式下会返回结构化的人机授权请求。内置 DesignKB 随安装包
提供完整素材和自包含生成器，不依赖用户另装 Python。
