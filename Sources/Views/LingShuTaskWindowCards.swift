import SwiftUI
import AppKit

// MARK: - 执行计划卡(LOOP 标准:先 plan 再逐步执行,在窗口顶部以 todo 渲染,状态实时更新)

struct TaskPlanCard: View {
    let steps: [LingShuPlanStep]

    private var doneCount: Int { steps.filter { $0.status == .completed }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.lingHolo)
                Text("执行计划")
                    .font(.system(size: 12.5, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.92))
                Text("\(doneCount)/\(steps.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Color.lingFg.opacity(0.45))
                Spacer(minLength: 0)
            }
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: icon(step.status))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(color(step.status))
                        .frame(width: 18)
                    Text(step.title)
                        .font(.system(size: 12.5, weight: step.status == .inProgress ? .bold : .medium))
                        .foregroundStyle(textColor(step.status))
                        .strikethrough(step.status == .completed, color: Color.lingFg.opacity(0.3))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lingFg.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.lingHolo.opacity(0.18)) }
    }

    private func icon(_ s: LingShuPlanStep.Status) -> String {
        switch s {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }
    private func color(_ s: LingShuPlanStep.Status) -> Color {
        switch s {
        case .pending: return Color.lingFg.opacity(0.35)
        case .inProgress: return Color.lingHolo
        case .completed: return .green.opacity(0.85)
        case .failed: return .orange.opacity(0.9)
        }
    }
    private func textColor(_ s: LingShuPlanStep.Status) -> Color {
        switch s {
        case .completed: return Color.lingFg.opacity(0.5)
        case .inProgress: return Color.lingFg.opacity(0.95)
        case .pending: return Color.lingFg.opacity(0.78)
        case .failed: return Color.lingFg.opacity(0.82)
        }
    }
}

// MARK: - 工具/命令调用卡(对齐 codex:命令一行 + 可折叠完整参数)

struct TaskToolCallCard: View {
    let tool: String
    let summary: String
    let arguments: String
    @State private var expanded = false

    private var hasMore: Bool {
        let a = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        return !a.isEmpty && a != "{}" && a != summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: tool == "run_command" ? "terminal.fill" : "wrench.adjustable.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.orange)
                Text(LingShuState.toolDisplayName(tool))
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.orange.opacity(0.95))
                Spacer(minLength: 0)
                if hasMore {
                    Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.lingFg.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(summary)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.lingFg.opacity(0.86))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if expanded, hasMore {
                Text(arguments)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.lingFg.opacity(0.62))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.lingFg.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.orange.opacity(0.2)) }
    }
}

// MARK: - 工具/命令结果卡(✓/✗ + 可折叠输出)

struct TaskToolResultCard: View {
    let tool: String
    let success: Bool
    let output: String
    @State private var expanded = false

    private var trimmedOutput: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var firstLine: String { trimmedOutput.components(separatedBy: "\n").first ?? "" }
    private var hasMore: Bool { trimmedOutput.contains("\n") || trimmedOutput.count > 80 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(success ? .green : .red)
                Text("\(LingShuState.toolDisplayName(tool)) \(success ? "完成" : "失败")")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle((success ? Color.green : Color.red).opacity(0.95))
                Spacer(minLength: 0)
                if hasMore {
                    Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                        Text(expanded ? "收起" : "查看输出")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Color.lingFg.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }
            }
            if !trimmedOutput.isEmpty {
                Text(expanded ? trimmedOutput : firstLine)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.lingFg.opacity(0.6))
                    .textSelection(.enabled)
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: expanded)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(expanded ? 8 : 0)
                    .background(expanded ? Color.black.opacity(0.32) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke((success ? Color.green : Color.red).opacity(0.16)) }
    }
}

// MARK: - 文件 diff 卡(对齐 codex 编辑卡:新增/修改 + +N/-N + 审核展开彩色 diff + 撤销)

struct TaskFileDiffCard: View {
    let path: String
    let operation: LingShuArtifactOperation
    let added: Int
    let removed: Int
    let diff: String
    let undone: Bool
    /// nil = 历史/只读(不显示撤销)。
    var onUndo: (() -> Void)?
    @State private var expanded = false

    private var fileName: String { (path as NSString).lastPathComponent }
    private var canUndo: Bool { onUndo != nil && !undone && (operation == .created || !LingShuLineDiff.isTruncated(diff)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(operation == .modified ? Color.lingHoloAlt : Color.lingHolo)
                Text(operation.rawValue)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(operation == .modified ? Color.lingHoloAlt : Color.lingHolo)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background((operation == .modified ? Color.lingHoloAlt : Color.lingHolo).opacity(0.16), in: Capsule())
                Text(fileName)
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.lingFg.opacity(undone ? 0.4 : 0.88))
                    .strikethrough(undone)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text("+\(added)").font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(.green.opacity(0.9))
                Text("-\(removed)").font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(.red.opacity(0.85))
            }

            HStack(spacing: 8) {
                Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                    Label(expanded ? "收起" : "审核", systemImage: expanded ? "eye.slash" : "eye")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.lingHolo.opacity(0.92))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Color.lingHolo.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)

                if undone {
                    Label("已撤销", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.45))
                } else if canUndo, let onUndo {
                    Button(action: onUndo) {
                        Label("撤销", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.orange.opacity(0.95))
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else if onUndo != nil, LingShuLineDiff.isTruncated(diff) {
                    Text("改动过大不可撤销")
                        .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.36))
                }
                Spacer(minLength: 0)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(diff.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(diffLineColor(line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.lingFg.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lingFg.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.lingHolo.opacity(undone ? 0.08 : 0.2)) }
    }

    private func diffLineColor(_ line: String) -> Color {
        if line.hasPrefix("+ ") { return .green.opacity(0.92) }
        if line.hasPrefix("- ") { return .red.opacity(0.82) }
        if line.hasPrefix("… ") { return .orange.opacity(0.8) }
        return Color.lingFg.opacity(0.5)
    }
}

// 窗口底部条(模型选择 + 反馈 + 追问输入)已拆为独立组件 → LingShuTaskWindowFooter.swift。
