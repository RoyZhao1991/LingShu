import Foundation

/// 第三方 agent 暴露的一个**子能力**(Codex 插件 / Claude 技能·MCP / 任意 CLI agent 的子工具),
/// **归一成统一模型**——内核不关心它来自哪种 agent、用什么命令枚举出来的(适配器模式的"目标接口"侧)。
struct LingShuAgentCapability: Identifiable, Equatable, Sendable, Codable {
    let agentID: String     // 属于哪个 agent(codex / claude / …)
    let id: String          // 能力稳定 id(如 "picsart@openai-curated"、"film-visual-pipeline@personal")
    var name: String        // 展示名(如 "picsart")
    var summary: String     // 一句说明(没有就空)
    var category: String    // 分类/来源(如 marketplace 名),供分组展示
    var enabled: Bool       // 当前是否已启用
    var installed: Bool     // 是否已安装(未装的可按需安装——供应链红线:需确认)

    /// `@agent·能力` 形式的显式调用别名(供 @/+ 菜单扁平化用)。
    var invocationAlias: String { "\(agentID)·\(name)" }
}

/// agent 清单里声明的"**如何发现 / 启用 / 安装它的子能力**"——**纯数据**。
/// 内核据此通用走一套(适配器的"配置"侧):换 agent 只换这段 JSON +(若输出格式新)补一个解析器,内核零改动。
/// 缺省(nil)= 该 agent 没有可枚举的子能力,按现在直接跑 objective。
struct AgentCapabilitySpec: Codable, Equatable, Sendable {
    var discover: DiscoverSpec?   // 怎么列出能力
    var enable: [String]?         // 启用某个能力时**额外**拼进调用的参数,用 {{cap}} 占位(如 ["-c","plugins.\"{{cap}}\".enabled=true"])
    var install: [String]?        // 安装某个能力的子命令,用 {{cap}} 占位(如 ["plugin","add","{{cap}}"])——供应链红线:执行前必须人确认

    struct DiscoverSpec: Codable, Equatable, Sendable {
        var args: [String]?       // 命令源:发现命令参数(相对 executable,如 ["plugin","list","--json"])
        var skillsDir: String?    // 文件源:扫这个目录下的技能(每个子目录一个 SKILL.md,如 "~/.codex/skills")
        var registryFile: String? // **权威注册表源(防伪)**:读 agent 自己的"已装清单"文件(如 Claude 的 ~/.claude/plugins/installed_plugins.json),只认真正装好的能力——往任意目录塞假 SKILL.md 不再生效
        var format: String        // 解析器 id(如 "codex-plugin-list" / "skill-md" / "claude-installed-plugins")
    }

    /// 把 {{cap}} 填进 enable 模板。
    func enableArgs(for capabilityID: String) -> [String] {
        (enable ?? []).map { $0.replacingOccurrences(of: "{{cap}}", with: capabilityID) }
    }
    /// 把 {{cap}} 填进 install 子命令。
    func installArgs(for capabilityID: String) -> [String] {
        (install ?? []).map { $0.replacingOccurrences(of: "{{cap}}", with: capabilityID) }
    }
}
