import SwiftUI
import AppKit

/// 把灵枢回复的纯文本解析成「子块」渲染：围栏代码块单独成卡片（等宽、深底、语言标签、复制按钮），
/// 其余正文按 Markdown 渲染（标题 / 列表 / 加粗 / 行内代码）。
///
/// 为什么要这套：之前回复整段塞进一个 `Text`，长代码、脚本全平铺成灰字，读不动也没法复制——
/// codex、豆包都是结构化分块。这里做的是「通配」解析：不挑模型、不挑语言，按 Markdown 围栏拆块即可。
struct LingShuMessageContentView: View {
    let text: String
    var textColor: Color = .white.opacity(0.88)

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(LingShuMessageBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let language, let code):
                    LingShuCodeBlockView(language: language, code: code)
                case .markdown(let content):
                    LingShuMarkdownText(content: content, color: textColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// 一条回复拆出的子块：要么是正文 Markdown，要么是一段围栏代码。
enum LingShuMessageBlock {
    case markdown(String)
    case code(language: String?, code: String)

    /// 按 ``` 围栏切块。未闭合的围栏（流式生成中常见）按到结尾处理，照样进代码卡片。
    static func parse(_ text: String) -> [LingShuMessageBlock] {
        var blocks: [LingShuMessageBlock] = []
        let lines = text.components(separatedBy: "\n")
        var buffer: [String] = []

        func flushMarkdown() {
            let joined = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.markdown(joined)) }
            buffer.removeAll()
        }

        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushMarkdown()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: lang.isEmpty ? nil : lang,
                                    code: code.joined(separator: "\n")))
                i += 1 // 跳过闭合围栏（越界也无妨）
                continue
            }
            buffer.append(lines[i])
            i += 1
        }
        flushMarkdown()

        if blocks.isEmpty { blocks.append(.markdown(text)) }
        return blocks
    }
}

/// 围栏代码卡片：顶栏标语言 + 复制按钮，正文等宽可横向滚动、可选中。
struct LingShuCodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text((language ?? "code").uppercased())
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.lingHolo.opacity(0.82))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "已复制" : "复制")
                    }
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(copied ? Color.lingHolo : .white.opacity(0.66))
                }
                .buttonStyle(.plain)
                .help("复制这段代码")
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.05))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .padding(11)
                    .frame(minWidth: 0, alignment: .leading)
            }
        }
        .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
        }
    }
}

/// 正文 Markdown：逐行识别标题 / 分割线 / 列表，行内交给系统 Markdown 解析（加粗、斜体、行内码、链接）。
struct LingShuMarkdownText: View {
    let content: String
    var color: Color = .white.opacity(0.88)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(Self.elements(from: content).enumerated()), id: \.offset) { _, element in
                switch element {
                case .line(let raw):
                    lineView(raw)
                case .table(let header, let rows):
                    tableView(header: header, rows: rows)
                }
            }
        }
    }

    /// 正文元素:普通行,或一张 Markdown 表格(连续 `|...|` 行 + 第二行分隔线)。
    private enum MDElement {
        case line(String)
        case table(header: [String], rows: [[String]])
    }

    private static func elements(from content: String) -> [MDElement] {
        let lines = content.components(separatedBy: "\n")
        var out: [MDElement] = []
        var i = 0
        while i < lines.count {
            if isTableRow(lines[i]), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                let header = tableCells(lines[i])
                var rows: [[String]] = []
                i += 2
                while i < lines.count, isTableRow(lines[i]), !isTableSeparator(lines[i]) {
                    rows.append(tableCells(lines[i]))
                    i += 1
                }
                out.append(.table(header: header, rows: rows))
            } else {
                out.append(.line(lines[i]))
                i += 1
            }
        }
        return out
    }

    private static func isTableRow(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.dropFirst().contains("|")
    }

    private static func isTableSeparator(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.contains("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func tableCells(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    @ViewBuilder
    private func tableView(header: [String], rows: [[String]]) -> some View {
        let colCount = max(header.count, rows.map(\.count).max() ?? 0)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                ForEach(0..<colCount, id: \.self) { c in
                    inline(c < header.count ? header[c] : "")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(color)
                }
            }
            Divider().overlay(Color.white.opacity(0.16)).gridCellColumns(colCount)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<colCount, id: \.self) { c in
                        inline(c < row.count ? row[c] : "")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(color.opacity(0.92))
                    }
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 0.8)
        }
    }

    @ViewBuilder
    private func lineView(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Color.clear.frame(height: 3)
        } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            Divider().overlay(Color.white.opacity(0.14))
        } else if trimmed.hasPrefix("### ") {
            inline(String(trimmed.dropFirst(4)))
                .font(.system(size: 14, weight: .bold)).foregroundStyle(color)
        } else if trimmed.hasPrefix("## ") {
            inline(String(trimmed.dropFirst(3)))
                .font(.system(size: 15.5, weight: .bold)).foregroundStyle(color)
        } else if trimmed.hasPrefix("# ") {
            inline(String(trimmed.dropFirst(2)))
                .font(.system(size: 17, weight: .bold)).foregroundStyle(color)
        } else if let (marker, body) = listItem(trimmed) {
            HStack(alignment: .top, spacing: 6) {
                Text(marker)
                    .font(.system(size: 14.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.lingHolo.opacity(0.82))
                inline(body)
                    .font(.system(size: 14.5, weight: .medium)).foregroundStyle(color)
            }
        } else {
            inline(trimmed)
                .font(.system(size: 14.5, weight: .medium)).foregroundStyle(color)
        }
    }

    /// 识别无序（-、*、+）和有序（1.）列表项，返回（项目符号, 正文）。
    private func listItem(_ s: String) -> (String, String)? {
        for p in ["- ", "* ", "+ "] where s.hasPrefix(p) {
            return ("•", String(s.dropFirst(p.count)))
        }
        if let dot = s.firstIndex(of: "."),
           dot > s.startIndex,
           s[s.startIndex..<dot].allSatisfy(\.isNumber),
           s.index(after: dot) < s.endIndex,
           s[s.index(after: dot)] == " " {
            let number = String(s[s.startIndex..<dot])
            let rest = String(s[s.index(dot, offsetBy: 2)...])
            return ("\(number).", rest)
        }
        return nil
    }

    /// 行内 Markdown：交给系统解析器，保留空白；解析失败回退为纯文本。
    private func inline(_ s: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(s)
    }
}
