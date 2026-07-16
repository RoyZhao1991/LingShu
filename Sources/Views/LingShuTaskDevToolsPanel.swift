import SwiftUI
import AppKit

/// 任务窗口右侧统一侧栏:顶部「目标 / 任务摘要 / 进度」概览 + 底部文件区。
/// 底部文件区:**开发任务**分「产出物 / 代码管理」两个 tab(避免全堆一列太长、看着乱);
/// 非开发任务只有「产出物」。「代码管理」= Git 工具(改动 +/− · 分支/仓库 · 改动文件 · 提交),仅开发任务有。
/// 数据全部来自现有记录模型(plan / codeChanges / messages 的 fileEdit +/−),不新增持久化字段。
struct TaskDevToolsPanel: View {
    @ObservedObject var state: LingShuState
    let record: LingShuTaskExecutionRecord
    let lineageRecords: [LingShuTaskExecutionRecord]

    private enum FileTab { case artifacts, code }
    @State private var fileTab: FileTab = .artifacts
    @State private var showCommitConfirm = false

    // 聚合本轮 + 续接历史里每个文件「最后一次」编辑的 +/− 行 → 改动统计(与主栏 diff 卡口径一致)。
    private var diffStat: (added: Int, removed: Int, files: Int) {
        var perFile: [String: (added: Int, removed: Int)] = [:]
        for rec in [record] + lineageRecords {
            for message in rec.messages {
                if let detail = message.detail, case let .fileEdit(path, _, added, removed, _) = detail {
                    perFile[path] = (added, removed)
                }
            }
        }
        let added = perFile.values.reduce(0) { $0 + $1.added }
        let removed = perFile.values.reduce(0) { $0 + $1.removed }
        return (added, removed, perFile.count)
    }

    private var doneSteps: Int { record.plan.filter { $0.status == .completed }.count }
    private var statusIsComplete: Bool { record.status == .completed || record.status == .answered }

    private var elapsedText: String {
        let secs = max(0, Int(record.updatedAt.timeIntervalSince(record.createdAt)))
        if secs < 60 { return "\(secs)s" }
        let minutes = secs / 60, remainder = secs % 60
        return remainder == 0 ? "\(minutes)m" : "\(minutes)m\(remainder)s"
    }

    // 目标=**一句话总目标**(模型经 update_plan 蒸馏的 record.goal,如"构建一个清分结算系统")。
    // 模型没给(旧记录/简单任务)则回退 title(短),都没有才用 prompt。
    private var goalText: String {
        let goal = record.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goal.isEmpty { return goal }
        let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return record.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 本轮 + 续接历史的产出物(去重,最新在前)。
    private var allArtifacts: [(artifact: LingShuTaskExecutionArtifact, fromHistory: Bool)] {
        let current = record.artifacts.map { (artifact: $0, fromHistory: false) }
        let historical = lineageRecords.flatMap(\.artifacts)
            .filter { artifact in !record.artifacts.contains(where: { $0.id == artifact.id }) }
            .map { (artifact: $0, fromHistory: true) }
        return (current + historical).sorted { $0.artifact.displayTimestamp > $1.artifact.displayTimestamp }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                goalSection
                if !record.plan.isEmpty {
                    Divider().overlay(Color.lingFg.opacity(0.08))
                    progressSection
                }
                Divider().overlay(Color.lingFg.opacity(0.08))
                filesSection
            }
            .padding(14)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.lingFg.opacity(0.03))   // 浅=近白淡面板(原 black@0.28=灰暗块「太黑」)/ 深=极淡亮面
    }

    // MARK: - 底部文件区(开发=产出物/代码管理 两 tab;非开发=只产出物)

    @ViewBuilder
    private var filesSection: some View {
        if record.isDevelopmentTask {
            HStack(spacing: 6) {
                tabButton(state.loc("产出物", "Artifacts"), systemImage: "shippingbox.fill", count: allArtifacts.count, active: fileTab == .artifacts) { fileTab = .artifacts }
                tabButton(state.loc("代码管理", "Code"), systemImage: "arrow.triangle.branch", count: record.codeChanges?.files.count ?? 0, active: fileTab == .code) { fileTab = .code }
                Spacer(minLength: 0)
            }
            if fileTab == .artifacts { artifactsCards } else { gitManageContent }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    sectionHeader(state.loc("产出物", "Artifacts"), systemImage: "shippingbox.fill", tint: .lingHolo)
                    Text("\(allArtifacts.count)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(Color.lingFg.opacity(0.42))
                    Spacer(minLength: 0)
                }
                artifactsCards
            }
        }
    }

    private func tabButton(_ title: String, systemImage: String, count: Int, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .bold))
                Text(title).font(.system(size: 12, weight: .bold))
                Text("\(count)").font(.system(size: 10, weight: .bold, design: .monospaced)).opacity(0.6)
            }
            .foregroundStyle(active ? Color.lingHolo : Color.lingFg.opacity(0.5))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(active ? Color.lingHolo.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var artifactsCards: some View {
        if allArtifacts.isEmpty {
            Text(state.loc("本任务还没有登记产出文件", "No artifacts have been registered for this task"))
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.38))
                .padding(.vertical, 10)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(allArtifacts, id: \.artifact.id) { entry in
                    TaskArtifactFileCard(artifact: entry.artifact, fromHistory: entry.fromHistory)
                }
            }
        }
    }

    // MARK: - 代码管理 tab 内容(= Git 工具:改动 +/− · 分支/仓库 · 改动文件 · 提交)

    @ViewBuilder
    private var gitManageContent: some View {
        VStack(alignment: .leading, spacing: 11) {
            let stat = diffStat
            HStack(spacing: 8) {
                Image(systemName: "plusminus.circle.fill")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.lingHolo)
                Text(state.loc("改动", "Changes")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.72))
                Spacer(minLength: 0)
                Text("+\(stat.added)").font(.system(size: 11.5, weight: .bold, design: .monospaced)).foregroundStyle(.green.opacity(0.9))
                Text("-\(stat.removed)").font(.system(size: 11.5, weight: .bold, design: .monospaced)).foregroundStyle(.red.opacity(0.85))
            }
            if let code = record.codeChanges {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Color.lingHoloAlt)
                    Text(code.branch)
                        .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Color.lingHoloAlt)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(code.repoName)
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.42))
                        .lineLimit(1).truncationMode(.middle)
                }
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(code.files) { changeFileRow($0) }
                }
                commitButton(fileCount: code.files.count)
            } else {
                Text(state.loc("尚未捕获 Git 改动（任务收尾后扫描）。", "No Git changes captured yet; LingShu scans them at task completion."))
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.36))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func changeFileRow(_ file: LingShuCodeChangeSummary.Change) -> some View {
        HStack(spacing: 7) {
            Text(localizedFileLabel(file.label))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(file.label == "删除" ? .red.opacity(0.85)
                                 : (file.label == "新增" || file.label == "未跟踪" ? Color.lingHolo : Color.lingHoloAlt))
                .frame(width: 30, alignment: .leading)
            Text((file.path as NSString).lastPathComponent)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.lingFg.opacity(0.82))
                .lineLimit(1).truncationMode(.middle)
                .help(file.path)
            Spacer(minLength: 0)
        }
    }

    private func commitButton(fileCount: Int) -> some View {
        Button { showCommitConfirm = true } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 12, weight: .bold))
                Text(state.loc("提交改动", "Commit Changes")).font(.system(size: 11.5, weight: .bold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).opacity(0.6)
            }
            .foregroundStyle(Color.lingHolo)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.lingHolo.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.lingHolo.opacity(0.28)) }
        }
        .buttonStyle(.plain)
        .confirmationDialog(state.loc(
                                "提交本任务的 \(fileCount) 个改动到 \(record.codeChanges?.branch ?? "当前分支")？",
                                "Commit \(fileCount) task changes to \(record.codeChanges?.branch ?? "the current branch")?"
                            ),
                            isPresented: $showCommitConfirm, titleVisibility: .visible) {
            Button(state.loc("提交", "Commit")) { state.commitTaskCodeChanges(recordID: record.id) }
            Button(state.loc("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(state.loc(
                "仅暂存并提交本任务改动的文件，可随时使用 git reset 还原。",
                "Only files changed by this task are staged and committed; git reset can restore them."
            ))
        }
    }

    // MARK: - 目标

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionHeader(state.loc("目标", "Goal"), systemImage: "target", tint: .lingHolo)
                Spacer(minLength: 0)
                Text(statusIsComplete
                     ? state.loc("已完成", "Completed")
                     : state.loc(record.status.rawValue, record.status.englishName))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(statusIsComplete ? .green.opacity(0.92) : record.status.color)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background((statusIsComplete ? Color.green : record.status.color).opacity(0.16), in: Capsule())
            }
            // 目标正文:优先 GoalSpec 的 objective(模型重述的真实目标),否则 record.goal。**完整显示、可选中**,不再截断到 6 行。
            Text(goalObjectiveText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.lingFg.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            // **目标拆解(GoalSpec)**:之前 record.goalSpec 存了却没渲染——成功标准/约束/边界/风险/待澄清都补上。
            if let spec = record.goalSpec { goalSpecBreakdown(spec) }
            HStack(spacing: 6) {
                if !record.plan.isEmpty {
                    statChip(state.loc("\(doneSteps)/\(record.plan.count) 步", "\(doneSteps)/\(record.plan.count) steps"), icon: "checklist")
                }
                statChip(elapsedText, icon: "clock")
                if record.participants.count > 1 {
                    statChip(state.loc("\(record.participants.count) 参与方", "\(record.participants.count) participants"), icon: "person.2")
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// 目标正文:GoalSpec 的 objective(大脑重述的真目标)优先,否则回退 goalText。
    private var goalObjectiveText: String {
        if let o = record.goalSpec?.objective.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty { return o }
        return goalText
    }

    /// **目标拆解**:把 GoalSpec 的结构化理解逐组展开(成功标准=验收依据最重要)。空组不显示。
    @ViewBuilder private func goalSpecBreakdown(_ spec: LingShuGoalSpec) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            criteriaGroup(state.loc("成功标准（验收依据）", "Success Criteria"), spec.successCriteria, icon: "checkmark.seal.fill", tint: .green)
            criteriaGroup(state.loc("约束", "Constraints"), spec.constraints, icon: "ruler.fill", tint: .lingHolo)
            criteriaGroup(state.loc("边界 · 不做", "Boundaries · Out of Scope"), spec.boundaries, icon: "hand.raised.fill", tint: .orange)
            criteriaGroup(state.loc("风险", "Risks"), spec.risks, icon: "exclamationmark.triangle.fill", tint: .red)
            criteriaGroup(state.loc("待澄清", "Open Questions"), spec.openQuestions, icon: "questionmark.circle.fill", tint: .yellow)
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func criteriaGroup(_ title: String, _ items: [String], icon: String, tint: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: icon).font(.system(size: 9.5, weight: .bold)).foregroundStyle(tint)
                    Text(title).font(.system(size: 10.5, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.62))
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 5) {
                        Text("·").font(.system(size: 11, weight: .bold)).foregroundStyle(tint.opacity(0.85))
                        Text(item).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.74))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, 2)
        }
    }

    private func statChip(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(Color.lingFg.opacity(0.5))
    }

    // MARK: - 分步计划(抽象里程碑 + 完成打钩;复用执行计划卡。结果摘要不在右侧——具体执行/结论在左侧对话)

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader(state.loc("分步计划", "Step-by-Step Plan"), systemImage: "list.bullet.clipboard", tint: .lingHolo)
            TaskPlanCard(steps: record.plan)
        }
    }

    // MARK: - 通用小节标题

    private func sectionHeader(_ title: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
            Text(title).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.92))
        }
    }

    private func localizedFileLabel(_ label: String) -> String {
        switch label {
        case "删除": state.loc("删除", "Deleted")
        case "新增": state.loc("新增", "Added")
        case "未跟踪": state.loc("未跟踪", "Untracked")
        case "修改": state.loc("修改", "Modified")
        default: label
        }
    }
}
