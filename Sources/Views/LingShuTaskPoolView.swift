import SwiftUI

/// 任务池:主界面的已完成 / 未完成任务清单。
/// 热数据 = 最近一个月(journal 按时间窗分热/冷,参考上下文冷备策略);可一键纳入「冷备(更早)」记录。
/// 点任意任务进其执行记录详情(复用对话页同一张 sheet)。
struct LingShuTaskPoolView: View {
    @ObservedObject var state: LingShuState
    @State private var includeArchived = false

    private var hot: [LingShuTaskExecutionRecord] { state.taskExecutionRecords }
    private var cold: [LingShuTaskExecutionRecord] {
        let hotIDs = Set(hot.map(\.id))
        return state.archivedTaskExecutionRecords.filter { !hotIDs.contains($0.id) }
    }
    private var pool: [LingShuTaskExecutionRecord] {
        (includeArchived ? hot + cold : hot).sorted { $0.updatedAt > $1.updatedAt }
    }
    private var groups: [LingShuTaskThreadHierarchyGroup] {
        LingShuTaskThreadHierarchy.groups(pool)
    }
    private var ongoing: [LingShuTaskThreadHierarchyGroup] {
        groups.filter { !$0.root.status.isTerminal }
    }
    private var done: [LingShuTaskThreadHierarchyGroup] {
        groups.filter { $0.root.status.isSuccessfulCompletion }
    }
    private var terminated: [LingShuTaskThreadHierarchyGroup] {
        groups.filter { $0.root.status == .terminated }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if pool.isEmpty {
                        emptyState
                    } else {
                        if !ongoing.isEmpty { section(state.loc("进行中 / 待处理", "In Progress / Needs Attention"), ongoing) }
                        if !terminated.isEmpty { section(state.loc("已终止", "Terminated"), terminated) }
                        if !done.isEmpty { section(state.loc("已完成", "Completed"), done) }
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $state.isTaskRecordPresented) {
            if state.selectedTaskRecord != nil {
                TaskExecutionRecordSheet(state: state)
            } else {
                Text(state.loc("任务记录不存在", "Task record not found")).frame(width: 520, height: 320)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Label(state.loc("线程", "Tasks"), systemImage: "bubble.left.and.bubble.right")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.lingHolo)
                .help(state.loc("主线程是全能中枢;每个任务是一条线程,派生的子线程像专项工作室——其上下文对该任务更聚焦、价值更高。", "The main thread is the general hub. Each task has a focused thread, and its child threads act as specialist workspaces."))
            Text(state.loc(
                "主任务：进行中 \(ongoing.count) · 已终止 \(terminated.count) · 已完成 \(done.count) · 子任务 \(max(0, pool.count - groups.count))",
                "Main tasks: in progress \(ongoing.count) · terminated \(terminated.count) · completed \(done.count) · child tasks \(max(0, pool.count - groups.count))"
            ))
                .font(.system(size: 12))
                .foregroundStyle(Color.lingFg.opacity(0.5))
            Spacer()
            if !cold.isEmpty {
                Toggle(isOn: $includeArchived) {
                    Text(includeArchived
                         ? state.loc("已含冷备 \(cold.count)", "Archive included \(cold.count)")
                         : state.loc("含冷备 \(cold.count)", "Include archive \(cold.count)"))
                        .font(.system(size: 11.5, weight: .medium))
                }
                .toggleStyle(.button)
                .tint(Color.lingHolo)
                .help(state.loc("纳入一个月前的冷备任务(更早的线程记录)", "Include archived tasks older than one month"))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.lingFg.opacity(0.03))
    }

    private func section(_ title: String, _ items: [LingShuTaskThreadHierarchyGroup]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.lingFg.opacity(0.55))
            ForEach(items) { group in
                row(
                    group.root,
                    depth: 0,
                    isRootTask: group.isRootTask,
                    childCount: group.descendants.count
                )
                ForEach(group.descendants) { item in
                    row(item.record, depth: item.depth, isRootTask: false, childCount: 0)
                }
            }
        }
    }

    private func row(
        _ record: LingShuTaskExecutionRecord,
        depth: Int,
        isRootTask: Bool,
        childCount: Int
    ) -> some View {
        let status = record.status.rootLifecycleStatus
        return Button {
            state.openTaskRecord(record.id)
        } label: {
            HStack(spacing: 12) {
                if depth > 0 {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.lingHolo.opacity(0.55))
                        .frame(width: 14)
                }
                ZStack(alignment: .topTrailing) {
                    Circle()
                        .fill(statusColor(status))
                        .frame(width: 8, height: 8)
                    if state.isTaskThreadUnread(record.id) {
                        Circle()
                            .fill(Color.red.opacity(0.94))
                            .frame(width: 6, height: 6)
                            .overlay(Circle().stroke(Color.lingVoid, lineWidth: 1))
                            .offset(x: 4, y: -4)
                    }
                }
                .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(isRootTask
                             ? state.loc("主任务", "Main")
                             : state.loc("子任务", "Child"))
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(isRootTask ? Color.lingHolo : Color.lingFg.opacity(0.5))
                        Text(record.title)
                            .font(.system(size: 13.5, weight: isRootTask ? .semibold : .medium))
                            .foregroundStyle(Color.lingFg.opacity(isRootTask ? 0.92 : 0.78))
                            .lineLimit(1)
                        if childCount > 0 {
                            Text(state.loc("\(childCount) 个子任务", "\(childCount) children"))
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(Color.lingFg.opacity(0.42))
                        }
                    }
                    HStack(spacing: 9) {
                        Text(state.language == .english ? status.englishName : status.rawValue)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(statusColor(status))
                        Text(record.updatedAt.taskRecordDisplayTime)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.lingFg.opacity(0.38))
                        if !record.artifacts.isEmpty {
                            Label("\(record.artifacts.count)", systemImage: "doc.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.lingFg.opacity(0.45))
                        }
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.lingFg.opacity(0.25))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.lingFg.opacity(isRootTask ? 0.05 : 0.025)))
            .padding(.leading, CGFloat(min(depth, 4)) * 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 34))
                .foregroundStyle(Color.lingFg.opacity(0.25))
            Text(state.loc("还没有任务。下达目标后,这里会按时间归集进行中与已完成的任务。", "No tasks yet. Once you give Nous a goal, active and completed tasks will be collected here."))
                .font(.system(size: 12.5))
                .foregroundStyle(Color.lingFg.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    private func statusColor(_ status: LingShuTaskExecutionStatus) -> Color {
        switch status {
        case .completed, .answered, .verified: return Color.lingHolo
        case .terminated: return Color.lingFg.opacity(0.52)
        case .running, .dispatched, .analyzing, .acquiringCapability, .ready: return Color.lingHoloAlt
        case .queued: return Color.lingFg.opacity(0.4)
        case .needsRevision, .partial: return .orange
        case .blocked: return .red
        case .failed: return .yellow
        case .suspended, .waitingForUser: return .yellow   // 暂停/待用户(可续),区别于红色异常
        }
    }
}
