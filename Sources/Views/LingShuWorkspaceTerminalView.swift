import SwiftUI

/// 「终端」模式:真·系统命令行(/bin/zsh)。在工作目录下敲命令、跑、看 stdout/stderr,`cd` 在多条命令间保持。
/// 这是**用户自己的终端**(用户在自己机器上敲命令),不走 agent 的 run_command 审批门。非交互式(无 PTY):一次性命令 OK,
/// vim/top 这类全屏交互程序不支持(到 120s 上限会被终止)。`clear` 清屏。
struct LingShuWorkspaceTerminalView: View {
    let initialDir: URL
    @State private var lines: [TermLine] = []
    @State private var input = ""
    @State private var cwd: URL
    @State private var running = false
    @State private var history: [String] = []
    @State private var historyIndex: Int?
    @FocusState private var focused: Bool

    init(initialDir: URL) {
        self.initialDir = initialDir
        _cwd = State(initialValue: initialDir)
    }

    private var promptString: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = cwd.path.hasPrefix(home) ? "~" + cwd.path.dropFirst(home.count) : cwd.path
        return p + " %"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(line.kind.color)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    promptRow
                    Color.clear.frame(height: 1).id("term-bottom")
                }
                .padding(12)
            }
            .onChange(of: lines.count) { _, _ in withAnimation { proxy.scrollTo("term-bottom", anchor: .bottom) } }
        }
        .background(Color.black.opacity(0.55))
        .onAppear { focused = true }
    }

    private var promptRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(promptString)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.lingHolo.opacity(0.9))
            if running {
                Text(LingShuLanguagePreferenceStore.localized("运行中…", "Running…"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.lingFg.opacity(0.4))
            } else {
                TextField("", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color.lingFg.opacity(0.92))
                    .focused($focused)
                    .onSubmit { run(input) }
                    .onKeyPress(.upArrow) { recallHistory(-1); return .handled }
                    .onKeyPress(.downArrow) { recallHistory(1); return .handled }
            }
        }
    }

    private func recallHistory(_ delta: Int) {
        guard !history.isEmpty else { return }
        let idx = (historyIndex ?? history.count) + delta
        if idx < 0 { historyIndex = 0 } else if idx >= history.count { historyIndex = nil; input = "" ; return }
        else { historyIndex = idx }
        if let historyIndex { input = history[historyIndex] }
    }

    private func run(_ raw: String) {
        let cmd = raw.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty, !running else { return }
        lines.append(TermLine(kind: .cmd, text: "\(promptString) \(cmd)"))
        history.append(cmd); historyIndex = nil
        input = ""
        if cmd == "clear" { lines.removeAll(); return }
        running = true
        let dir = cwd.path
        Task.detached {
            let (out, newPwd) = await LingShuTerminalShell.run(cmd: cmd, cwd: dir)
            await MainActor.run {
                for chunk in out.components(separatedBy: "\n") where !(chunk.isEmpty && out.hasSuffix("\n")) {
                    lines.append(TermLine(kind: .out, text: chunk))
                }
                if let newPwd, !newPwd.isEmpty { cwd = URL(fileURLWithPath: newPwd) }
                running = false
                focused = true
            }
        }
    }

}

struct TermLine: Identifiable {
    let id = UUID()
    let kind: Kind
    let text: String
    enum Kind {
        case cmd, out
        var color: Color { self == .cmd ? Color.lingHolo.opacity(0.95) : Color.lingFg.opacity(0.82) }
    }
}
