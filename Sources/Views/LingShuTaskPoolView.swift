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
    private var ongoing: [LingShuTaskExecutionRecord] {
        pool.filter { [.queued, .running, .dispatched, .needsRevision, .blocked].contains($0.status) }
    }
    private var done: [LingShuTaskExecutionRecord] {
        pool.filter { [.completed, .answered].contains($0.status) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if pool.isEmpty {
                        emptyState
                    } else {
                        if !ongoing.isEmpty { section("进行中 / 待办", ongoing) }
                        if !done.isEmpty { section("已完成", done) }
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $state.isTaskRecordPresented) {
            if let record = state.selectedTaskRecord {
                TaskExecutionRecordSheet(record: record, lineageRecords: state.selectedTaskRecordLineage)
            } else {
                Text("任务记录不存在").frame(width: 520, height: 320)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Label("任务池", systemImage: "tray.full")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.lingHolo)
            Text("进行中 \(ongoing.count) · 已完成 \(done.count)")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            if !cold.isEmpty {
                Toggle(isOn: $includeArchived) {
                    Text(includeArchived ? "已含冷备 \(cold.count)" : "含冷备 \(cold.count)")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .toggleStyle(.button)
                .tint(Color.lingHolo)
                .help("纳入一个月前的冷备任务(更早的归档记录)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.white.opacity(0.03))
    }

    private func section(_ title: String, _ items: [LingShuTaskExecutionRecord]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            ForEach(items) { row($0) }
        }
    }

    private func row(_ record: LingShuTaskExecutionRecord) -> some View {
        Button {
            state.openTaskRecord(record.id)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor(record.status))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    HStack(spacing: 9) {
                        Text(record.status.rawValue)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(statusColor(record.status))
                        Text(record.updatedAt.taskRecordDisplayTime)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.38))
                        if !record.artifacts.isEmpty {
                            Label("\(record.artifacts.count)", systemImage: "doc.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.25))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.045)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.25))
            Text("还没有任务。下达目标后,这里会按时间归集进行中与已完成的任务。")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    private func statusColor(_ status: LingShuTaskExecutionStatus) -> Color {
        switch status {
        case .completed, .answered: return Color.lingHolo
        case .running, .dispatched: return Color.lingHoloAlt
        case .queued: return .white.opacity(0.4)
        case .needsRevision: return .orange
        case .blocked: return .red
        }
    }
}
