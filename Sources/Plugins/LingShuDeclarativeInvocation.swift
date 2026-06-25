import Foundation

/// **声明式调插件**(对标 Codex 输入框「+」):用户**显式声明用哪个插件/能力**→ 确定性直达该插件,
/// **跳过大脑分诊**。根治反复踩的坑——模型常绕开新插件/不去委托([[presentation-qa-plugin]] 记的「GLM绕开新工具」)。
/// 两种声明方式:① 文本里 `@演示`/`用演示插件`/`/present` 前缀;② 输入框「+」菜单选中(置 pinned)。
struct LingShuInvocablePlugin: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let aliases: [String]    // 触发别名(自动并入 displayName + id)
    let subtitle: String     // 「+」菜单里的一句说明
    let icon: String         // SF Symbol 名

    /// 全部可匹配的别名(去重、含 displayName/id)。
    var allAliases: [String] {
        var set = [displayName, id] + aliases
        set = set.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var seen = Set<String>(); return set.filter { seen.insert($0).inserted }
    }
}

enum LingShuDeclarativeInvocation {

    /// 识别输入是否**显式声明**调某插件;返回(插件 id, 去掉声明前缀后**余下的真实输入**)。无声明返回 nil。
    /// 支持前缀:`@别名`、`/别名`、`用别名[插件]`、`调[用]别名`、`切[换]到别名`。匹配**最长别名**(避免短别名误命中)。
    static func detect(_ input: String, plugins: [LingShuInvocablePlugin]) -> (id: String, rest: String)? {
        let t = input.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        // (插件 id, 别名),按别名长度降序——先试更具体的。
        let pairs: [(id: String, alias: String)] = plugins
            .flatMap { p in p.allAliases.map { (p.id, $0) } }
            .sorted { $0.alias.count > $1.alias.count }
        for (id, alias) in pairs {
            for prefix in markers(for: alias) {
                if t.hasPrefix(prefix) {
                    let rest = String(t.dropFirst(prefix.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: " :：,，、"))
                    return (id, rest)
                }
            }
        }
        return nil
    }

    /// 某别名的全部声明前缀写法。
    private static func markers(for alias: String) -> [String] {
        ["@\(alias)", "/\(alias)",
         "用\(alias)插件", "用\(alias)", "调用\(alias)", "调\(alias)",
         "切换到\(alias)", "切到\(alias)", "使用\(alias)"]
    }
}
