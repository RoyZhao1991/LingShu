import SwiftUI

struct LingShuHistorySearchSheet: View {
    @ObservedObject var state: LingShuState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @State private var scope: LingShuHistorySearchScope = .all

    private var results: [LingShuHistorySearchHit] {
        state.searchConversationHistory(keyword: query, scope: scope)
    }

    private var isDark: Bool { colorScheme == .dark }
    private var panelSurface: Color {
        isDark ? Color(red: 0.035, green: 0.050, blue: 0.052) : Color.lingPanel
    }
    private var fieldSurface: Color {
        isDark ? Color.white.opacity(0.065) : Color.lingFg.opacity(0.055)
    }
    private var chipSurface: Color {
        isDark ? Color.white.opacity(0.07) : Color.lingFg.opacity(0.055)
    }
    private var primaryText: Color {
        isDark ? Color.white.opacity(0.93) : Color.lingFg.opacity(0.92)
    }
    private var secondaryText: Color {
        isDark ? Color.white.opacity(0.58) : Color.lingFg.opacity(0.54)
    }
    private var tertiaryText: Color {
        isDark ? Color.white.opacity(0.36) : Color.lingFg.opacity(0.42)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.lingHolo)
                Text(state.loc("历史检索", "History Search"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(primaryText)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(secondaryText)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                TextField(state.loc("搜索热记录和冷备记录中的关键字", "Search recent and archived records"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(primaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(fieldSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.lingHolo.opacity(0.22), lineWidth: 1))

                scopeSelector
            }

            HStack {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? state.loc("输入关键字开始检索", "Enter keywords to search")
                     : state.loc("命中 \(results.count) 条", "\(results.count) matches"))
                Spacer()
                Text(state.loc("热对话 / 冷备对话 / 热任务 / 冷备任务", "Recent chat / Archived chat / Recent tasks / Archived tasks"))
            }
            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(tertiaryText)

            Divider().overlay(Color.lingHolo.opacity(0.18))

            ScrollView {
                LazyVStack(spacing: 10) {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        historyEmptyState(state.loc("输入一个关键词，我会同时查当前对话、冷备对话和任务执行记录。", "Enter a keyword to search current chats, archived chats, and task records."))
                    } else if results.isEmpty {
                        historyEmptyState(state.loc("没有找到匹配记录。", "No matching records found."))
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
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(panelSurface.opacity(0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.lingHolo.opacity(isDark ? 0.30 : 0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isDark ? 0.45 : 0.18), radius: 26, y: 14)
    }

    private var scopeSelector: some View {
        HStack(spacing: 6) {
            ForEach(LingShuHistorySearchScope.allCases) { item in
                let selected = item == scope
                Button {
                    scope = item
                } label: {
                    Text(state.language == .english ? item.englishName : item.label)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(selected ? Color.lingVoid : secondaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    selected ? Color.lingHolo : chipSurface,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
            }
        }
        .frame(width: 230)
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
                .foregroundStyle(secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

private struct LingShuHistorySearchResultRow: View {
    let hit: LingShuHistorySearchHit
    let open: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }
    private var primaryText: Color {
        isDark ? Color.white.opacity(0.92) : Color.lingFg.opacity(0.92)
    }
    private var secondaryText: Color {
        isDark ? Color.white.opacity(0.66) : Color.lingFg.opacity(0.68)
    }
    private var tertiaryText: Color {
        isDark ? Color.white.opacity(0.44) : Color.lingFg.opacity(0.42)
    }
    private var rowSurface: Color {
        isDark ? Color.white.opacity(0.060) : Color.lingFg.opacity(0.055)
    }

    var body: some View {
        Button(action: {
            if hit.source.isTask {
                open()
            }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(LingShuLanguagePreferenceStore.localized(hit.source.label, hit.source.englishName))
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundStyle(sourceLabelText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(sourceColor.opacity(0.9), in: Capsule())
                    Text(hit.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                    Spacer()
                    Text(Self.dateFormatter.string(from: hit.timestamp))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tertiaryText)
                    if hit.source.isTask {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.lingHolo.opacity(0.82))
                    }
                }

                Text(hit.snippet.isEmpty ? LingShuLanguagePreferenceStore.localized("（无文本摘要）", "(No text summary)") : hit.snippet)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(secondaryText)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(rowSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.lingHolo.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(hit.source.isTask
              ? LingShuLanguagePreferenceStore.localized("打开任务执行记录", "Open Task Record")
              : LingShuLanguagePreferenceStore.localized("聊天命中记录", "Chat Search Result"))
    }

    private var sourceColor: Color {
        switch hit.source {
        case .hotChat: return Color.lingHolo
        case .coldChat: return .cyan
        case .hotTask: return .orange
        case .coldTask: return .purple
        }
    }

    private var sourceLabelText: Color {
        switch hit.source {
        case .coldTask: return .white.opacity(0.92)
        default: return .black.opacity(0.82)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
