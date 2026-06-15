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

    // 目标=这件事要落地交付什么(用户原始诉求),**始终显示**;不显示"测试全绿"这类过程性结论(那归「任务摘要」)。
    private var goalText: String {
        let prompt = record.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { return prompt }
        return record.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasSummary: Bool {
        !record.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // 本轮 + 续接历史的产出物(去重,最新在前)。
    private var allArtifacts: [(artifact: LingShuTaskExecutionArtifact, fromHistory: Bool)] {
        let current = record.artifacts.map { (artifact: $0, fromHistory: false) }
        let historical = lineageRecords.flatMap(\.artifacts)
            .filter { artifact in !record.artifacts.contains(where: { $0.id == artifact.id }) }
            .map { (artifact: $0, fromHistory: true) }
        return (current + historical).sorted { $0.artifact.createdAt > $1.artifact.createdAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                goalSection
                if hasSummary {
                    Divider().overlay(Color.white.opacity(0.08))
                    summarySection
                }
                if !record.plan.isEmpty {
                    Divider().overlay(Color.white.opacity(0.08))
                    progressSection
                }
                Divider().overlay(Color.white.opacity(0.08))
                filesSection
            }
            .padding(14)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.28))
    }

    // MARK: - 底部文件区(开发=产出物/代码管理 两 tab;非开发=只产出物)

    @ViewBuilder
    private var filesSection: some View {
        if record.isDevelopmentTask {
            HStack(spacing: 6) {
                tabButton("产出物", systemImage: "shippingbox.fill", count: allArtifacts.count, active: fileTab == .artifacts) { fileTab = .artifacts }
                tabButton("代码管理", systemImage: "arrow.triangle.branch", count: record.codeChanges?.files.count ?? 0, active: fileTab == .code) { fileTab = .code }
                Spacer(minLength: 0)
            }
            if fileTab == .artifacts { artifactsCards } else { gitManageContent }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    sectionHeader("产出物", systemImage: "shippingbox.fill", tint: .lingHolo)
                    Text("\(allArtifacts.count)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.42))
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
            .foregroundStyle(active ? Color.lingHolo : .white.opacity(0.5))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(active ? Color.lingHolo.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var artifactsCards: some View {
        if allArtifacts.isEmpty {
            Text("本任务还没有登记产出文件")
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.38))
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
                Text("改动").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.72))
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
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1).truncationMode(.middle)
                }
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(code.files) { changeFileRow($0) }
                }
                commitButton(fileCount: code.files.count)
            } else {
                Text("尚未捕获 git 改动(任务收尾后扫描)。")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.36))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func changeFileRow(_ file: LingShuCodeChangeSummary.Change) -> some View {
        HStack(spacing: 7) {
            Text(file.label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(file.label == "删除" ? .red.opacity(0.85)
                                 : (file.label == "新增" || file.label == "未跟踪" ? Color.lingHolo : Color.lingHoloAlt))
                .frame(width: 30, alignment: .leading)
            Text((file.path as NSString).lastPathComponent)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1).truncationMode(.middle)
                .help(file.path)
            Spacer(minLength: 0)
        }
    }

    private func commitButton(fileCount: Int) -> some View {
        Button { showCommitConfirm = true } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 12, weight: .bold))
                Text("提交改动").font(.system(size: 11.5, weight: .bold))
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
        .confirmationDialog("提交本任务的 \(fileCount) 个改动到 \(record.codeChanges?.branch ?? "当前分支")?",
                            isPresented: $showCommitConfirm, titleVisibility: .visible) {
            Button("提交") { state.commitTaskCodeChanges(recordID: record.id) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅暂存并提交本任务改动的文件,可随时 git reset 还原。")
        }
    }

    // MARK: - 目标

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionHeader("目标", systemImage: "target", tint: .lingHolo)
                Spacer(minLength: 0)
                Text(statusIsComplete ? "已完成" : record.status.rawValue)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(statusIsComplete ? .green.opacity(0.92) : record.status.color)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background((statusIsComplete ? Color.green : record.status.color).opacity(0.16), in: Capsule())
            }
            Text(goalText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(6)
            HStack(spacing: 6) {
                if !record.plan.isEmpty {
                    statChip("\(doneSteps)/\(record.plan.count) 步", icon: "checklist")
                }
                statChip(elapsedText, icon: "clock")
                if record.participants.count > 1 {
                    statChip("\(record.participants.count) 参与方", icon: "person.2")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func statChip(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(.white.opacity(0.5))
    }

    // MARK: - 任务摘要(做完后的结论,与「目标」分开:目标=要交付什么,摘要=做完了什么)

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeader("任务摘要", systemImage: "text.alignleft", tint: .lingHolo)
            Text(record.summary)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 进度(复用执行计划卡)

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader("进度", systemImage: "list.bullet.clipboard", tint: .lingHolo)
            TaskPlanCard(steps: record.plan)
        }
    }

    // MARK: - 通用小节标题

    private func sectionHeader(_ title: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
            Text(title).font(.system(size: 12.5, weight: .bold)).foregroundStyle(.white.opacity(0.92))
        }
    }
}
