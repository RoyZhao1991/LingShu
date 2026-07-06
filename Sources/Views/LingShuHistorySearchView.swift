import SwiftUI

struct LingShuHistorySearchSheet: View {
    @ObservedObject var state: LingShuState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var scope: LingShuHistorySearchScope = .all

    private var results: [LingShuHistorySearchHit] {
        state.searchConversationHistory(keyword: query, scope: scope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.lingHolo)
                Text("历史检索")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.lingFg)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                TextField("搜索热记录和冷备记录中的关键字", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Color.lingFg.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.lingHolo.opacity(0.22), lineWidth: 1))

                Picker("", selection: $scope) {
                    ForEach(LingShuHistorySearchScope.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
            }

            HStack {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "输入关键字开始检索" : "命中 \(results.count) 条")
                Spacer()
                Text("热对话 / 冷备对话 / 热任务 / 冷备任务")
            }
            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.lingFg.opacity(0.48))

            Divider().overlay(Color.lingHolo.opacity(0.18))

            ScrollView {
                LazyVStack(spacing: 10) {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        historyEmptyState("输入一个关键词，我会同时查当前对话、冷备对话和任务执行记录。")
                    } else if results.isEmpty {
                        historyEmptyState("没有找到匹配记录。")
                    } else {
                        ForEach(results) { hit in
                            LingShuHistorySearchResultRow(hit: hit) {
                                openTaskRecord(from: hit)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(20)
        .frame(width: 760, height: 620)
        .background(Color.lingPanel.opacity(0.98))
    }

    private func openTaskRecord(from hit: LingShuHistorySearchHit) {
        guard let recordID = hit.recordID, hit.source.isTask else { return }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            state.openTaskRecord(recordID)
        }
    }

    private func historyEmptyState(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "archivebox")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.lingHolo.opacity(0.55))
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.lingFg.opacity(0.55))
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

private struct LingShuHistorySearchResultRow: View {
    let hit: LingShuHistorySearchHit
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(hit.source.label)
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.82))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(sourceColor.opacity(0.9), in: Capsule())
                    Text(hit.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.lingFg.opacity(0.92))
                        .lineLimit(1)
                    Spacer()
                    Text(Self.dateFormatter.string(from: hit.timestamp))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.lingFg.opacity(0.42))
                    if hit.source.isTask {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.lingHolo.opacity(0.82))
                    }
                }

                Text(hit.snippet.isEmpty ? "（无文本摘要）" : hit.snippet)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.lingFg.opacity(0.68))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color.lingFg.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.lingHolo.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!hit.source.isTask)
        .help(hit.source.isTask ? "打开任务执行记录" : "聊天命中记录")
    }

    private var sourceColor: Color {
        switch hit.source {
        case .hotChat: return Color.lingHolo
        case .coldChat: return .cyan
        case .hotTask: return .orange
        case .coldTask: return .purple
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
