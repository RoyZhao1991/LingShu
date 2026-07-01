import Foundation

/// **声明式调插件**(对标 Codex 输入框「+」):用户**显式声明用哪个插件/能力**→ 确定性直达该插件,
/// **跳过大脑分诊**。根治反复踩的坑——模型常绕开新插件/不去委托([[presentation-qa-plugin]] 记的「GLM绕开新工具」)。
/// 声明入口只保留一种可见形式:`@别名`。输入框「+」菜单选中也应插入 `@别名`,避免隐藏关键词路由。
struct LingShuInvocablePlugin: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable { case plugin, agent, agentCapability }   // 插件(演示/录制) / 外部 agent(Codex/Claude) / agent 的子能力(@Codex·picsart)
    let id: String
    let displayName: String
    let aliases: [String]    // 触发别名(自动并入 displayName + id)
    let subtitle: String     // 「+」菜单里的一句说明
    let icon: String         // SF Symbol 名
    var kind: Kind = .plugin

    /// 全部可匹配的别名(去重、含 displayName/id)。
    var allAliases: [String] {
        var set = [displayName, id] + aliases
        set = set.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var seen = Set<String>(); return set.filter { seen.insert($0).inserted }
    }
}

enum LingShuDeclarativeInvocation {

    /// 识别输入是否**显式声明**调某插件;返回(插件 id, 去掉声明前缀后**余下的真实输入**)。无声明返回 nil。
    /// 只支持 `@别名`。自然语言里的「用/调用/切到」都回到 Triage,由大脑按语义判断,不在快路径里偷偷抢路由。
    /// 匹配**最长别名**(避免短别名误命中)。
    static func detect(_ input: String, plugins: [LingShuInvocablePlugin]) -> (id: String, rest: String)? {
        let t = input.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        // (插件 id, 别名),按别名长度降序——先试更具体的。
        let pairs: [(id: String, alias: String)] = plugins
            .flatMap { p in p.allAliases.map { (p.id, $0) } }
            .sorted { $0.alias.count > $1.alias.count }
        for (id, alias) in pairs {
            let prefix = "@\(alias)"
            if t.hasPrefix(prefix) {
                let rest = String(t.dropFirst(prefix.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " :：,，、"))
                return (id, rest)
            }
        }
        return nil
    }

    /// 解析输入里的**多个 `@调用`**(`@Codex 开发X @Claude 验收Y`)→ 有序 [(id, 该段任务文本)]。
    /// 只认 `@别名` 前缀(多 agent/插件组合最自然);无 `@` 命中返回空。每段=从该别名后到下一个 `@别名` 之前。
    static func detectChain(_ input: String, plugins: [LingShuInvocablePlugin]) -> [(id: String, segment: String)] {
        let t = input
        let aliasPairs = plugins.flatMap { p in p.allAliases.map { (id: p.id, alias: $0) } }
            .sorted { $0.alias.count > $1.alias.count }   // 最长别名优先
        struct Marker { let id: String; let at: String.Index; let contentStart: String.Index }
        var markers: [Marker] = []
        var idx = t.startIndex
        while idx < t.endIndex {
            guard let at = t[idx...].firstIndex(of: "@") else { break }
            let afterAt = t.index(after: at)
            if afterAt < t.endIndex, let pair = aliasPairs.first(where: { t[afterAt...].hasPrefix($0.alias) }) {
                let contentStart = t.index(afterAt, offsetBy: pair.alias.count)
                markers.append(Marker(id: pair.id, at: at, contentStart: contentStart))
                idx = contentStart
            } else {
                idx = afterAt
            }
        }
        guard !markers.isEmpty else { return [] }
        return markers.enumerated().map { i, m in
            let segEnd = (i + 1 < markers.count) ? markers[i + 1].at : t.endIndex
            let seg = String(t[m.contentStart..<segEnd]).trimmingCharacters(in: CharacterSet(charactersIn: " :：,，、\n"))
            return (m.id, seg)
        }
    }
}
