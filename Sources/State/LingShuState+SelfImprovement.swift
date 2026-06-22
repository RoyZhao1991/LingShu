import Foundation

/// 通用中枢 P6·**自我进化闭环**接线(有界、人批)(见 [[LingShuSelfImprovement]])。
/// 挖 P4 经验库的反复弱点 → 生成**待批准**改进提案(默认 pending,**不自动采纳**);
/// **人批准**后才把提案变成一条真任务去建(走既有 task 派发 → author_component/discover_skill/连接器,**沙箱+安全门+完成闸**),
/// 采纳的能力可禁用回滚。**绝不自改核心 Swift、绝不自动执行未审代码**。
@MainActor
extension LingShuState {

    private static let improvementProposalsKey = "lingshu.self.improvements"

    func improvementProposals() -> [LingShuImprovementProposal] {
        guard let data = UserDefaults.standard.data(forKey: Self.improvementProposalsKey),
              let list = try? JSONDecoder().decode([LingShuImprovementProposal].self, from: data) else { return [] }
        return list
    }

    private func persistImprovementProposals(_ list: [LingShuImprovementProposal]) {
        if let data = try? JSONEncoder().encode(Array(list.suffix(100))) {
            UserDefaults.standard.set(data, forKey: Self.improvementProposalsKey)
        }
    }

    /// 挖反复弱点(纯,从 P4 经验库)。
    func mineSelfImprovementPatterns() -> [LingShuImprovementPattern] {
        LingShuSelfImprovementMiner.detectPatterns(goalExperiences())
    }

    /// 生成自我改进提案:挖弱点 → 拟有界建议 → 存 **pending** + 落 trace + 一条提示气泡。**不自动采纳**。
    /// 去重:同 theme 已有非 rejected 提案则跳过。返回新增条数。
    @discardableResult
    func proposeSelfImprovements() -> Int {
        let patterns = mineSelfImprovementPatterns()
        guard !patterns.isEmpty else { return 0 }
        var list = improvementProposals()
        var added = 0
        for p in patterns where !list.contains(where: { $0.theme == p.theme && $0.status != .rejected }) {
            list.append(.init(theme: p.theme, occurrences: p.occurrences, suggestion: LingShuSelfImprovementMiner.suggestion(for: p)))
            added += 1
        }
        guard added > 0 else { return 0 }
        persistImprovementProposals(list)
        appendTrace(kind: .system, actor: "自我进化", title: "发现可改进点", detail: "新增 \(added) 条改进提案(待你批准,不自动采纳)")
        chatMessages.append(.init(speaker: "灵枢", text: "🔧 我自检发现 \(added) 个反复受挫的点,拟了改进提案(自写工具/装技能/接连接器,沙箱+安全门)。**你批准我才动手**,采纳后可回滚。", isUser: false))
        return added
    }

    /// **人批准**:把提案变成一条真任务去建(走既有 task 派发 → M1 沙箱+安全门+完成闸)。状态 → approved。
    func approveSelfImprovement(id: String) {
        var list = improvementProposals()
        guard let idx = list.firstIndex(where: { $0.id == id }), list[idx].status == .pending else { return }
        list[idx].status = .approved
        persistImprovementProposals(list)
        let prop = list[idx]
        appendTrace(kind: .result, actor: "自我进化", title: "已批准·派任务去建", detail: String(prop.theme.prefix(40)))
        let prompt = "自我改进:我在「\(prop.theme)」这类目标上反复受挫(\(prop.occurrences) 次)。请补齐对应能力——优先 author_component 自写工具 / discover_skill 装现成技能 / 接连接器(都经沙箱+安全门),建好用最小验证确认真可用。"
        _ = submitTextInput(prompt, source: .plugin("自我进化"))
    }

    /// 人否决:状态 → rejected(同 theme 不再反复提案)。
    func rejectSelfImprovement(id: String) {
        var list = improvementProposals()
        guard let idx = list.firstIndex(where: { $0.id == id }), list[idx].status == .pending else { return }
        list[idx].status = .rejected
        persistImprovementProposals(list)
        appendTrace(kind: .system, actor: "自我进化", title: "已否决", detail: String(list[idx].theme.prefix(40)))
    }
}
