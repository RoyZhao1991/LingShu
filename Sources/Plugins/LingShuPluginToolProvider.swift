import Foundation

/// P2 插件动态注册真工具:让一个插件**贡献真正的 `LingShuAgentTool`**(不只注入提示)。
/// 约定:插件声明若干工具(名/描述/参数 schema)+ 一个**可执行 runner**(脚本/二进制);
/// 调用时把入参 JSON 从 stdin 灌进 runner,读 stdout 的结果(纯文本/JSON)。脚本经 P3 沙箱在声明的最小权限下跑。
/// 这样 MCP(外部进程提供工具)与 skill 脚本统一到"扩展提供工具"一个模型。
enum LingShuPluginToolProvider {

    /// 插件声明的一个工具。
    struct ToolSpec: Equatable, Sendable {
        var name: String
        var description: String
        var parametersJSON: String = "{\"type\":\"object\",\"properties\":{}}"
    }

    /// 把插件清单 + 工具声明 + runner 可执行,做成可挂进 agent 循环的 `LingShuAgentTool` 列表。
    /// runner 调用:`<exec> <args> <toolName>`,入参 JSON 走 stdin,结果取 stdout。脚本沙箱由 manifest 权限驱动。
    static func makeTools(
        manifest: LingShuPluginManifest,
        specs: [ToolSpec],
        runnerExecutable: String,
        runnerArguments: [String] = [],
        sandbox: Bool = true,
        timeout: TimeInterval = 30
    ) -> [LingShuAgentTool] {
        specs.map { spec in
            LingShuAgentTool(
                name: spec.name,
                description: spec.description + "(由插件「\(manifest.name)」提供)",
                parametersJSON: spec.parametersJSON
            ) { argumentsJSON in
                await runRunner(
                    manifest: manifest, toolName: spec.name, argumentsJSON: argumentsJSON,
                    executable: runnerExecutable, baseArguments: runnerArguments,
                    sandbox: sandbox, timeout: timeout
                )
            }
        }
    }

    /// 跑一次 runner(子进程,stdin 入参 / stdout 结果),沙箱按 manifest 权限。返回结果或错误说明(绝不抛,工具层要稳)。
    static func runRunner(
        manifest: LingShuPluginManifest,
        toolName: String,
        argumentsJSON: String,
        executable: String,
        baseArguments: [String],
        sandbox: Bool,
        timeout: TimeInterval
    ) async -> String {
        var exec = executable
        var args = baseArguments + [toolName]
        if sandbox, LingShuPluginSandbox.isAvailable {
            let wrapped = LingShuPluginSandbox.wrapped(executable: executable, arguments: args, permissions: manifest.permissions)
            exec = wrapped.executable; args = wrapped.arguments
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exec)
        process.arguments = args
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return "插件工具「\(toolName)」启动失败:\(error.localizedDescription)"
        }
        stdin.fileHandleForWriting.write(Data(argumentsJSON.utf8))
        try? stdin.fileHandleForWriting.close()

        // 软超时:到点杀进程,不让插件吊死 agent 回合。
        let timed = Task.detached { [process] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timed.cancel()

        let text = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? "插件工具「\(toolName)」非零退出(\(process.terminationStatus)):\(err.prefix(200))" : text
        }
        return text.isEmpty ? "(插件工具「\(toolName)」无输出)" : text
    }
}
