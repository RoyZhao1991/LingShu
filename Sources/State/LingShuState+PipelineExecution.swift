import Foundation

/// 通用工具执行：5 个原语经 LingShuToolExecutor（带权限门控），外部 MCP 透传。
/// 统一 agent 循环的工具桥（agentBuiltinTools）经此执行；run_command 在需确认模式下弹中文授权框。
/// （旧的 plan→draft→review 协同管线与 pipeline* 系列调用已随启发式前置门退役，见架构速查手册 §5。）
@MainActor
extension LingShuState {
    /// 执行一次工具调用（MCP 透传 / 本机执行器），run_command 在需确认模式下弹授权框；统一记录到任务与轨迹。
    func runAgenticTool(
        tool: String,
        arguments: [String: String],
        stageActor: String,
        taskRecordID: String?,
        workingDirectory: String,
        mcpToolNames: Set<String>,
        baseAllowShell: Bool
    ) async -> LingShuToolResult {
        // 结构化录制(codex 式卡片):工具名 + 一句话摘要 + 完整参数(供展开),不再灌裸字符串。
        // 格式化走独立模块 LingShuTaskMessageFormatting(纯工具,可单测)。
        let callSummary = LingShuTaskMessageFormatting.toolCallSummary(tool: tool, arguments: arguments)
        appendTaskRecordMessage(
            taskRecordID, actor: "工具", role: stageActor, kind: .agent,
            text: callSummary,
            detail: .toolCall(tool: tool, summary: callSummary, arguments: LingShuTaskMessageFormatting.prettyArguments(arguments))
        )
        // 工具执行（brew install / 长命令）也是真实活动——执行前后各喂一次心跳，别让 180s 看门狗误判失联。
        recordModelHeartbeat(source: "工具", detail: "正在执行 \(tool)。")
        // 长命令（python-pptx 生成、LibreOffice 转 PDF、装依赖）可能跑几十秒到几分钟：
        // 执行期间每 25s 续一次心跳，否则命令跑到一半就被 180s 看门狗误杀（"疑似命令未跑完"的真因）。
        let heartbeatKeepalive = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard !Task.isCancelled else { break }
                self?.recordModelHeartbeat(source: "工具", detail: "\(tool) 仍在执行…")
            }
        }
        defer { heartbeatKeepalive.cancel() }
        // 执行前快照「目标文件是否已存在」——据此把产出物标为「新增」还是「修改」(对齐 codex 的文件操作区分)。
        let fileManager = FileManager.default
        let fileMutator = (tool == "write_file" || tool == "edit_file")   // 两种文件改动工具同等对待(diff 卡 + 产出物登记)
        let writeTargetExisted = fileMutator && fileManager.fileExists(atPath: arguments["path"] ?? "")
        // 执行前抓改前内容(write_file/edit_file)——供 diff 卡片做彩色 diff + 撤销(可逆)。
        let writeOldContent: String? = (fileMutator && writeTargetExisted)
            ? (try? String(contentsOfFile: arguments["path"] ?? "", encoding: .utf8))
            : nil
        // 命令执行前:快照"命令里提到、且已存在"的交付型文件的修改时间——事后据此区分"真改了" vs "只是读/列了"。
        let commandPreexistingMtime: [String: Date] = (tool == "run_command")
            ? Dictionary(Self.extractRunCommandArtifacts(arguments["command"] ?? "", workingDirectory: workingDirectory).compactMap { path -> (String, Date)? in
                guard let mtime = (try? fileManager.attributesOfItem(atPath: path)[.modificationDate]) as? Date else { return nil }
                return (path, mtime)
            }, uniquingKeysWith: { a, _ in a })
            : [:]
        // 命令开始时刻:事后只把**执行期间真被写出/改动**的文件登记成产出物。
        // 根治污染:`pwd && ls`/`cat` 等会把工作目录里**别的任务的旧文件**(如「灵枢自我介绍.pptx」)列进输出,
        // 旧逻辑从输出抽路径、又因这些路径不在「命令快照」里而当「新增」登记 → 串入本任务产出物。
        let commandStartedAt = Date()
        // 凭据注入(计划 §5):把 command/url 里的 {{cred:KEY}} 占位符在**执行层**换成加密库真值。
        // 记录里(上面已用 raw arguments 录了 toolCall)保留占位符;执行用 execArgs(含明文);
        // secrets 供执行后给输出打码,明文绝不进任务记录/模型上下文。
        var execArgs = arguments
        var injectedSecrets: [String] = []
        for field in ["command", "url"] {
            guard let raw = execArgs[field], raw.contains("{{cred:") else { continue }
            let (resolved, secrets) = resolveCredentialPlaceholders(in: raw)
            execArgs[field] = resolved
            injectedSecrets.append(contentsOf: secrets)
        }
        let mcpName = tool.hasPrefix("mcp:") ? String(tool.dropFirst(4)) : tool
        var result: LingShuToolResult
        if mcpToolNames.contains(mcpName), let client = connectorRegistry.client(forTool: mcpName) {
            // 外部 MCP 工具：原生 function-calling 用 arguments_json 信封承载真实参数
            // （描述符无 inputSchema）——在此唯一处解包成真实参数 dict 再透传，新旧路径共用。
            result = await client.callTool(name: mcpName, arguments: Self.unwrapMCPArguments(arguments))
        } else {
            // 高风险动作（run_command）在需人工确认模式下：弹中文授权框等用户裁决，
            // 用户点「本次允许 / 完全授权」才放行——不再直接拒绝、逼模型降级成"给你段脚本自己跑"。
            var effectiveAllowShell = baseAllowShell || sessionShellAlwaysAllowed
            if tool == "run_command" {
                let command = arguments["command"] ?? ""
                let systemSensitive = LingShuShellCommandPolicy.touchesSystemSensitivePath(command)
                if LingShuShellCommandPolicy.isReadOnly(command), !systemSensitive {
                    // 只读命令(grep/find/ls/cat…/git status)免审批直接放行——大脑定位不再每次弹框打断(计划 §3)。
                    effectiveAllowShell = true
                } else if !effectiveAllowShell || systemSensitive {
                    // 未授权 → 照常弹审批;已「完整授权」但命中**删/改系统级敏感文件** → 仍强制弹一次(计划 §1 红线)。
                    let decision = await requestShellApproval(
                        command: command,
                        workingDirectory: workingDirectory,
                        taskRecordID: taskRecordID,
                        forceConfirm: systemSensitive
                    )
                    effectiveAllowShell = (decision != .deny)
                }
            }
            // P3 沙箱接线:命令引用了 apply_skill 物化的 skill 脚本 → 按其声明权限(+工作目录写)经 sandbox-exec
            // 关进受限子进程跑(未审脚本视为不可信:只放声明的写路径+工作目录,网络声明才放,读放宽)。
            // 而非无沙箱裸跑。沙箱不可用(无 /usr/bin/sandbox-exec)则退回裸跑(诚实降级)。
            if tool == "run_command", effectiveAllowShell, LingShuPluginSandbox.isAvailable,
               let cmd = execArgs["command"],
               let hit = materializedSkillScripts.first(where: { cmd.contains(($0.key as NSString).lastPathComponent) }),
               let wrapped = Self.sandboxWrapCommand(cmd, permissions: hit.value, workingDirectory: workingDirectory) {
                execArgs["command"] = wrapped
                appendTrace(kind: .system, actor: "沙箱", title: "P3 受限执行",
                            detail: "skill 脚本经 sandbox-exec 按声明权限 confine:写限工作目录+声明路径、\(hit.value.network.isEmpty ? "断网" : "放行声明域")、读放宽。")
            }
            result = await toolExecutor.execute(
                .init(tool: tool, arguments: execArgs),
                workingDirectory: workingDirectory,
                allowShell: effectiveAllowShell
            )
        }
        // 注入过凭据 → 给输出打码,防命令回显的 token 进任务记录/模型上下文(明文零留存)。
        if !injectedSecrets.isEmpty {
            result = LingShuToolResult(tool: result.tool, success: result.success, output: Self.redactSecrets(result.output, secrets: injectedSecrets))
        }
        recordModelHeartbeat(source: "工具", detail: "\(result.tool) 执行完成。")
        if (result.tool == "write_file" || result.tool == "edit_file"), result.success, let path = arguments["path"] {
            // 文件改动 → diff 卡片(改前 vs 改后逐行 diff + 增删行数),不再只是一句"已写入"。
            // write_file 改后内容即入参 content;edit_file 是局部替换→读改后文件取新内容算 diff。
            let newContent = result.tool == "write_file"
                ? (arguments["content"] ?? "")
                : ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            let diff = LingShuLineDiff.compute(old: writeOldContent ?? "", new: newContent)
            let op: LingShuArtifactOperation = writeTargetExisted ? .modified : .created
            appendTaskRecordMessage(
                taskRecordID, actor: "工具", role: "文件改动", kind: .agent,
                text: "\(op.rawValue) \((path as NSString).lastPathComponent) (+\(diff.added) -\(diff.removed))",
                detail: .fileEdit(path: path, operation: op, added: diff.added, removed: diff.removed, diff: diff.unified)
            )
            appendTaskRecordArtifact(taskRecordID, title: (path as NSString).lastPathComponent, location: path, producer: "工具执行", operation: op)
        } else {
            // 其它工具/命令 → 结果卡片(成功与否 + 可折叠输出)。
            appendTaskRecordMessage(
                taskRecordID, actor: "工具", role: "执行结果", kind: .agent,
                text: result.success ? "\(result.tool) 完成" : "\(result.tool) 失败",
                detail: .toolResult(tool: result.tool, success: result.success, output: result.output)
            )
        }
        appendTrace(kind: .tool, actor: "工具", title: result.success ? "\(result.tool) 完成" : "\(result.tool) 失败", detail: String(result.output.prefix(180)))
        // run_command 产出的交付物(如 python 生成的 .pptx)不会被 write_file 自动登记——
        // 从命令与输出里抽出真实存在的交付型文件补登,让它出现在「任务产出文件」可预览/打开/定位(去重由 appendArtifact 负责)。
        // 执行前已存在 → 标「修改」,否则「新增」。
        if result.tool == "run_command", result.success {
            let haystack = (arguments["command"] ?? "") + "\n" + result.output
            for path in Self.extractRunCommandArtifacts(haystack, workingDirectory: workingDirectory)
            where fileManager.fileExists(atPath: path) {
                // 只登记**真产出/真改动**:执行前不存在→新增;执行前存在且 mtime 变了→修改;
                // 执行前存在且 mtime 没变=只是读/列(ls/cat/file…)→**不登记**(产出物面板别塞只读过的文件)。
                let nowMtime = (try? fileManager.attributesOfItem(atPath: path)[.modificationDate]) as? Date
                if let oldMtime = commandPreexistingMtime[path] {
                    guard let nowMtime, nowMtime > oldMtime else { continue }   // 未改动 → 跳过
                    appendTaskRecordArtifact(taskRecordID, title: (path as NSString).lastPathComponent, location: path, producer: "命令产出", operation: .modified)
                } else {
                    // 不在命令快照里(多半来自 ls/cat 输出):**只有执行期间真被写出**(mtime ≥ 命令开始)才算本任务产出;
                    // 否则是工作目录里别的任务的旧文件被列出来了 → **不登记**(根治产出物串台)。
                    guard let nowMtime, nowMtime >= commandStartedAt.addingTimeInterval(-1) else { continue }
                    appendTaskRecordArtifact(taskRecordID, title: (path as NSString).lastPathComponent, location: path, producer: "命令产出", operation: .created)
                }
            }
        }
        return result
    }

    /// 工具卡摘要 / 参数美化已拆为独立模块 → Sources/Support/LingShuTaskMessageFormatting.swift。

    /// P3:把一条 shell 命令包成 `sandbox-exec` 受限执行。profile = skill 声明权限 + **工作目录写**(生成器要能产出),
    /// 由 `LingShuPluginSandbox` 生成。SBPL 多行,内联进命令转义易错 → 写临时 profile 文件用 `-f` 引用;
    /// 原命令单引号转义后交内层 zsh 跑。返回包好的命令字符串;写 profile 失败返回 nil(调用方退回裸跑)。
    nonisolated static func sandboxWrapCommand(_ command: String, permissions: LingShuPluginPermissions, workingDirectory: String) -> String? {
        var perms = permissions
        perms.fileWrite.append(workingDirectory)   // 让 skill 生成器把产出写进工作目录(否则 deny-default 会挡住)
        let profile = LingShuPluginSandbox.profile(for: perms)
        let profileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lingshu-sbx-\(UUID().uuidString.prefix(8)).sb")
        guard (try? profile.write(to: profileURL, atomically: true, encoding: .utf8)) != nil else { return nil }
        let esc = command.replacingOccurrences(of: "'", with: "'\\''")   // 标准单引号转义
        return "/usr/bin/sandbox-exec -f '\(profileURL.path)' /bin/zsh -c '\(esc)'"
    }

    /// 解包 MCP 工具参数：原生 function-calling 把真实参数塞在 arguments_json 信封里，
    /// 这里解析回真实参数 dict 透传给外部 server；非信封形式（文本协议回退）原样返回。
    nonisolated static func unwrapMCPArguments(_ arguments: [String: String]) -> [String: Any] {
        if let envelope = arguments["arguments_json"],
           let data = envelope.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return arguments
    }
}
