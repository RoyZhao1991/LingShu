import SwiftUI
import AppKit
import Foundation

/// Obsidian-style memory graph for the local LingShu vault.
/// It is read-only UI: the source of truth remains the Markdown vault under
/// `~/Library/Application Support/LingShu/Memory/vault`.
struct LingShuKnowledgeGraphView: View {
    @ObservedObject var state: LingShuState

    @State private var query = ""
    @State private var selectedKind: LingShuMemoryNote.Kind?
    @State private var selectedID: String?
    @State private var nodeLimit: Double = 160

    private var allNotes: [LingShuMemoryNote] {
        state.knowledgeGraph.notes
    }

    private var candidateNotes: [LingShuMemoryNote] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [LingShuMemoryNote]
        if trimmed.isEmpty {
            base = allNotes.sorted { lhs, rhs in
                if lhs.updated != rhs.updated { return lhs.updated > rhs.updated }
                return lhs.title < rhs.title
            }
        } else {
            let recalled = state.knowledgeGraph.recall(trimmed, limit: 240)
            let direct = allNotes.filter { note in
                note.title.localizedCaseInsensitiveContains(trimmed)
                || note.body.localizedCaseInsensitiveContains(trimmed)
                || note.aliases.contains { $0.localizedCaseInsensitiveContains(trimmed) }
                || note.tags.contains { $0.localizedCaseInsensitiveContains(trimmed) }
            }
            base = dedupe(recalled + direct)
        }
        let kindFiltered = selectedKind.map { kind in base.filter { $0.kind == kind } } ?? base
        return Array(kindFiltered.prefix(Int(nodeLimit)))
    }

    private var selectedNote: LingShuMemoryNote? {
        guard let selectedID else { return nil }
        return allNotes.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            controls
            graphPanel
        }
        .onAppear {
            if selectedID == nil { selectedID = candidateNotes.first?.id }
        }
        .onChange(of: query) { _, _ in keepSelectionVisible() }
        .onChange(of: selectedKind) { _, _ in keepSelectionVisible() }
        .onChange(of: nodeLimit) { _, _ in keepSelectionVisible() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.loc("知识图谱", "Knowledge Graph"))
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(Color.lingFg.opacity(0.92))
                Text(state.loc(
                    "本地 Markdown Vault · 原子笔记 · 别名归一 · 双链关系",
                    "Local Markdown vault · Atomic notes · Alias normalization · Bidirectional links"
                ))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.lingFg.opacity(0.46))
            }
            Spacer()
            statChip(state.loc("节点", "Nodes"), "\(allNotes.count)", tint: .lingHolo)
            statChip(state.loc("当前显示", "Visible"), "\(candidateNotes.count)", tint: .cyan)
            Button {
                NSWorkspace.shared.open(LingShuKnowledgeGraph.defaultRoot)
            } label: {
                Label(state.loc("打开 Vault", "Open Vault"), systemImage: "folder")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.lingHolo)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.lingHolo.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.lingFg.opacity(0.45))
                    TextField(state.loc("搜索标题、正文、别名或标签", "Search titles, content, aliases, or tags"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.lingVoid.opacity(0.42), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.lingHolo.opacity(0.13)) }

                HStack(spacing: 7) {
                    Text(state.loc("显示", "Show"))
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Color.lingFg.opacity(0.42))
                    Slider(value: $nodeLimit, in: 40...260, step: 20)
                        .frame(width: 120)
                    Text("\(Int(nodeLimit))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.lingFg.opacity(0.62))
                        .frame(width: 32, alignment: .trailing)
                }
            }

            HStack(spacing: 6) {
                kindButton(nil, title: state.loc("全部", "All"), count: allNotes.count)
                ForEach(LingShuMemoryNote.Kind.allCases, id: \.rawValue) { kind in
                    kindButton(kind, title: kind.displayName, count: allNotes.filter { $0.kind == kind }.count)
                }
                Spacer()
            }
        }
    }

    private var graphPanel: some View {
        HStack(spacing: 12) {
            LingShuKnowledgeGraphCanvas(
                notes: candidateNotes,
                selectedID: selectedID,
                onSelect: { selectedID = $0 }
            )
            .frame(minHeight: 640)
            .background(Color.lingVoid.opacity(0.52), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.lingHolo.opacity(0.16)) }

            detailPanel
                .frame(width: 300)
        }
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let note = selectedNote {
                HStack(spacing: 8) {
                    Circle()
                        .fill(note.kind.graphColor)
                        .frame(width: 10, height: 10)
                    Text(note.kind.displayName)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(note.kind.graphColor)
                    Spacer()
                    Text(note.updated.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.lingFg.opacity(0.38))
                }

                Text(note.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.lingFg)
                    .lineLimit(3)

                if !note.aliases.isEmpty {
                    tagWrap(note.aliases.prefix(8).map { $0 }, color: .cyan.opacity(0.85))
                }

                ScrollView {
                    Text(note.body.isEmpty ? state.loc("这条笔记暂无正文。", "This note has no content yet.") : note.body)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.lingFg.opacity(0.86))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.vertical, 2)
                }

                Divider().overlay(Color.lingFg.opacity(0.1))

                metricRow(state.loc("热度", "Heat"), "\(Int(selectedHeat(note) * 100))%", icon: "flame")
                metricRow(state.loc("置信度", "Confidence"), String(format: "%.2f", note.confidence), icon: "checkmark.seal")
                metricRow(state.loc("来源", "Source"), note.source.rawValue, icon: "dot.radiowaves.left.and.right")
                metricRow(state.loc("出链", "Links"), "\(note.links.count)", icon: "point.3.connected.trianglepath.dotted")
                metricRow(state.loc("历史", "History"), "\(note.history.count)", icon: "clock.arrow.circlepath")

                if !note.tags.isEmpty {
                    tagWrap(note.tags.prefix(10).map { "#\($0)" }, color: .lingHolo.opacity(0.75))
                }

                Button {
                    let url = LingShuKnowledgeGraph.defaultRoot
                        .appendingPathComponent(note.kind.rawValue, isDirectory: true)
                        .appendingPathComponent("\(note.id).md")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label(state.loc("在访达中定位", "Show in Finder"), systemImage: "scope")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.lingHolo)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(Color.lingHolo.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Color.lingFg.opacity(0.35))
                    Text(state.loc("选择一个节点查看详情", "Select a node to view details"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.lingFg.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.lingHolo.opacity(0.13)) }
    }

    private func keepSelectionVisible() {
        let ids = Set(candidateNotes.map(\.id))
        if let selectedID, ids.contains(selectedID) { return }
        selectedID = candidateNotes.first?.id
    }

    private func selectedHeat(_ note: LingShuMemoryNote) -> Double {
        let inbound = allNotes.filter { $0.links.contains(note.id) }.count
        return note.graphHeat(degree: note.links.count + inbound, now: Date())
    }

    private func kindButton(_ kind: LingShuMemoryNote.Kind?, title: String, count: Int) -> some View {
        let active = selectedKind == kind
        let color = kind?.graphColor ?? Color.lingHolo
        return Button {
            selectedKind = kind
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(active ? color : Color.lingFg.opacity(0.28))
                    .frame(width: 6, height: 6)
                Text(title)
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(active ? Color.lingVoid.opacity(0.75) : Color.lingFg.opacity(0.38))
            }
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(active ? Color.lingVoid : Color.lingFg.opacity(0.62))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(active ? color : Color.lingFg.opacity(0.055), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func statChip(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.lingFg.opacity(0.38))
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func metricRow(_ title: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.lingHolo.opacity(0.75))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.lingFg.opacity(0.58))
            Spacer()
            Text(value)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.lingFg.opacity(0.9))
                .lineLimit(1)
        }
    }

    private func tagWrap(_ tags: [String], color: Color) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(color.opacity(0.08), in: Capsule())
            }
        }
    }

    private func dedupe(_ notes: [LingShuMemoryNote]) -> [LingShuMemoryNote] {
        var seen: Set<String> = []
        var out: [LingShuMemoryNote] = []
        for note in notes where !seen.contains(note.id) {
            seen.insert(note.id)
            out.append(note)
        }
        return out
    }
}

private struct LingShuKnowledgeGraphCanvas: View {
    let notes: [LingShuMemoryNote]
    let selectedID: String?
    let onSelect: (String) -> Void

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var hoveredID: String?
    @State private var pulse = false
    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var pinchScale: CGFloat = 1

    private var effectiveZoom: CGFloat {
        clamp(zoom * pinchScale, min: 0.35, max: 4)
    }

    private var effectivePan: CGSize {
        CGSize(width: pan.width + dragOffset.width, height: pan.height + dragOffset.height)
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = LingShuKnowledgeGraphLayout.make(notes: notes, size: proxy.size, selectedID: selectedID)
            let focusIDs = focusedIDs(layout: layout)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                Canvas { context, _ in
                    drawGrid(context: &context, size: proxy.size)
                    drawEdges(
                        context: &context,
                        layout: layout,
                        focusIDs: focusIDs,
                        center: center,
                        zoom: effectiveZoom,
                        pan: effectivePan
                    )
                    drawRings(context: &context, size: proxy.size, zoom: effectiveZoom, pan: effectivePan)
                }
                ForEach(layout.nodes) { node in
                    graphNode(node, focusIDs: focusIDs, zoom: effectiveZoom)
                        .position(screenPoint(node.point, center: center, zoom: effectiveZoom, pan: effectivePan))
                        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: selectedID)
                        .animation(.easeOut(duration: 0.16), value: hoveredID)
                }
                if notes.isEmpty {
                    Text(LingShuLanguagePreferenceStore.localized("没有可显示的知识节点", "No knowledge nodes to display"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.lingFg.opacity(0.45))
                }
                overlayControls
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        pan.width += value.translation.width
                        pan.height += value.translation.height
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .updating($pinchScale) { value, state, _ in
                        state = value
                    }
                    .onEnded { value in
                        zoom = clamp(zoom * value, min: 0.35, max: 4)
                    }
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
    }

    private var overlayControls: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(LingShuLanguagePreferenceStore.localized(
                        "拖拽平移 · 触控板捏合缩放 · 悬停放大并显示标题",
                        "Drag to pan · Pinch to zoom · Hover to enlarge and reveal titles"
                    ))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.lingFg.opacity(0.62))
                    if let selectedID, let note = notes.first(where: { $0.id == selectedID }) {
                        Text(LingShuLanguagePreferenceStore.localized("聚焦：\(note.title)", "Focus: \(note.title)"))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.lingHolo.opacity(0.92))
                            .lineLimit(1)
                    }
                }
                Spacer()
                HStack(spacing: 7) {
                    graphToolButton("minus.magnifyingglass", LingShuLanguagePreferenceStore.localized("缩小", "Zoom Out")) {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                            zoom = clamp(zoom / 1.22, min: 0.35, max: 4)
                        }
                    }
                    Text("\(Int(effectiveZoom * 100))%")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.lingFg.opacity(0.68))
                        .frame(width: 44)
                    graphToolButton("plus.magnifyingglass", LingShuLanguagePreferenceStore.localized("放大", "Zoom In")) {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                            zoom = clamp(zoom * 1.22, min: 0.35, max: 4)
                        }
                    }
                    graphToolButton("scope", LingShuLanguagePreferenceStore.localized("回到聚焦", "Return to Focus")) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            pan = .zero
                            zoom = 1.35
                        }
                    }
                    graphToolButton("arrow.counterclockwise", LingShuLanguagePreferenceStore.localized("重置视图", "Reset View")) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            pan = .zero
                            zoom = 1
                        }
                    }
                }
            }
            Spacer()
            HStack {
                legend
                Spacer()
                heatLegend
            }
        }
        .padding(12)
        .allowsHitTesting(true)
    }

    private var legend: some View {
        HStack(spacing: 8) {
            ForEach(LingShuMemoryNote.Kind.allCases, id: \.rawValue) { kind in
                HStack(spacing: 4) {
                    Circle().fill(kind.graphColor).frame(width: 7, height: 7)
                    Text(kind.displayName)
                }
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Color.lingFg.opacity(0.68))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().stroke(Color.lingHolo.opacity(0.12)) }
    }

    private var heatLegend: some View {
        HStack(spacing: 8) {
            Text(LingShuLanguagePreferenceStore.localized("冷", "Cold"))
            LinearGradient(
                colors: [
                    Color.lingHolo.opacity(0.2),
                    Color.lingHolo.opacity(0.55),
                    Color.lingHolo.opacity(1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 74, height: 7)
            .clipShape(Capsule())
            Text(LingShuLanguagePreferenceStore.localized("热", "Hot"))
            Text(LingShuLanguagePreferenceStore.localized("颜色深浅 = 热度", "Color intensity = heat"))
                .foregroundStyle(Color.lingFg.opacity(0.58))
        }
        .font(.system(size: 9.5, weight: .bold))
        .foregroundStyle(Color.lingFg.opacity(0.72))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().stroke(Color.lingHolo.opacity(0.12)) }
    }

    private func graphToolButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.lingFg.opacity(0.72))
                .frame(width: 30, height: 28)
                .background(Color.lingFg.opacity(0.075), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.lingHolo.opacity(0.13)) }
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func graphNode(_ node: LingShuKnowledgeGraphLayout.Node, focusIDs: Set<String>, zoom: CGFloat) -> some View {
        let active = node.note.id == selectedID
        let hovered = node.id == hoveredID
        let focused = focusIDs.isEmpty || focusIDs.contains(node.id)
        let neighbor = !active && focusIDs.contains(node.id)
        let heatColor = node.note.kind.heatColor(node.heat)
        let radiusBoost: CGFloat = hovered ? 1.95 : active ? 1.48 : neighbor ? 1.16 : 1
        let radius = node.radius * clamp(sqrt(zoom), min: 0.78, max: 1.9) * radiusBoost
        let showLabel = hovered || active
        return Button {
            onSelect(node.note.id)
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(heatColor)
                        .frame(width: radius * 2, height: radius * 2)
                        .shadow(color: heatColor.opacity(active || hovered ? 0.75 : focused ? 0.3 : 0.08), radius: active || hovered ? 16 : focused ? 6 : 2)
                    if active || hovered {
                        Circle()
                            .stroke(heatColor.opacity(pulse ? 0.14 : 0.72), lineWidth: hovered ? 1.5 : 1.2)
                            .frame(width: radius * (pulse ? 4.2 : 2.35), height: radius * (pulse ? 4.2 : 2.35))
                    }
                    Circle()
                        .stroke(Color.lingFg.opacity(active || hovered ? 0.92 : focused ? 0.46 : 0.16), lineWidth: active || hovered ? 1.6 : 0.7)
                        .frame(width: radius * 2 + 3, height: radius * 2 + 3)
                }
                if showLabel {
                    Text(node.note.title)
                        .font(.system(size: hovered ? 12 : 11.5, weight: .bold))
                        .foregroundStyle(Color.lingFg)
                        .lineLimit(1)
                        .frame(width: hovered ? 220 : 180)
                        .allowsHitTesting(false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .overlay { Capsule().stroke(heatColor.opacity(0.42), lineWidth: 0.8) }
                }
            }
            .contentShape(Rectangle())
            .opacity(focused ? 1 : 0.13)
        }
        .buttonStyle(.plain)
        .help("\(node.note.kind.displayName) · \(node.note.title)")
        .onHover { inside in
            hoveredID = inside ? node.id : (hoveredID == node.id ? nil : hoveredID)
        }
    }

    private func drawEdges(
        context: inout GraphicsContext,
        layout: LingShuKnowledgeGraphLayout,
        focusIDs: Set<String>,
        center: CGPoint,
        zoom: CGFloat,
        pan: CGSize
    ) {
        let visibleIDs = Set(layout.nodes.map(\.id))
        let byID = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0) })
        var drawn: Set<String> = []
        for node in layout.nodes {
            for dst in node.note.links where visibleIDs.contains(dst) {
                let key = node.id < dst ? "\(node.id)->\(dst)" : "\(dst)->\(node.id)"
                guard !drawn.contains(key), let target = byID[dst] else { continue }
                drawn.insert(key)
                var path = Path()
                path.move(to: screenPoint(node.point, center: center, zoom: zoom, pan: pan))
                path.addLine(to: screenPoint(target.point, center: center, zoom: zoom, pan: pan))
                let highlighted = focusIDs.contains(node.id) && focusIDs.contains(target.id)
                context.stroke(
                    path,
                    with: .color(highlighted ? Color.lingHolo.opacity(0.48) : Color.lingFg.opacity(0.045)),
                    lineWidth: highlighted ? 1.2 : 0.45
                )
            }
        }
    }

    private func drawRings(context: inout GraphicsContext, size: CGSize, zoom: CGFloat, pan: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let ringCenter = CGPoint(x: center.x + pan.width, y: center.y + pan.height)
        let maxRadius = max(80, min(size.width, size.height) * 0.42)
        for ratio in [0.33, 0.66, 1.0] {
            let r = maxRadius * ratio * zoom
            let rect = CGRect(x: ringCenter.x - r, y: ringCenter.y - r, width: r * 2, height: r * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(Color.lingHolo.opacity(0.045)), lineWidth: 0.8)
        }
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        let step: CGFloat = 42
        let color = Color.lingHolo.opacity(0.025)
        var path = Path()
        var x: CGFloat = 0
        while x <= size.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            x += step
        }
        var y: CGFloat = 0
        while y <= size.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            y += step
        }
        context.stroke(path, with: .color(color), lineWidth: 0.55)
    }

    private func focusedIDs(layout: LingShuKnowledgeGraphLayout) -> Set<String> {
        guard let focus = hoveredID ?? selectedID else { return [] }
        var ids: Set<String> = [focus]
        for node in layout.nodes {
            if node.id == focus {
                ids.formUnion(node.note.links)
            }
            if node.note.links.contains(focus) {
                ids.insert(node.id)
            }
        }
        return ids
    }

    private func screenPoint(_ point: CGPoint, center: CGPoint, zoom: CGFloat, pan: CGSize) -> CGPoint {
        CGPoint(
            x: center.x + (point.x - center.x) * zoom + pan.width,
            y: center.y + (point.y - center.y) * zoom + pan.height
        )
    }

    private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.max(lower, Swift.min(upper, value))
    }
}

private struct LingShuKnowledgeGraphLayout {
    struct Node: Identifiable {
        let id: String
        let note: LingShuMemoryNote
        let point: CGPoint
        let radius: CGFloat
        let rank: Int
        let degree: Int
        let heat: Double
    }

    let nodes: [Node]

    static func make(notes: [LingShuMemoryNote], size: CGSize, selectedID: String?) -> LingShuKnowledgeGraphLayout {
        guard !notes.isEmpty else { return .init(nodes: []) }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let visible = Array(notes.prefix(260))
        let visibleIDs = Set(visible.map(\.id))
        let inbound = Dictionary(grouping: visible.flatMap { source in
            source.links.filter { visibleIDs.contains($0) }.map { ($0, source.id) }
        }, by: { $0.0 }).mapValues(\.count)
        let maxRadius = max(90, min(size.width, size.height) * 0.43)
        let golden = CGFloat.pi * (3 - sqrt(5))
        var nodes: [Node] = []

        let selectedIndex = selectedID.flatMap { id in visible.firstIndex { $0.id == id } }
        let selectedNote = selectedIndex.map { visible[$0] }
        var neighborIDs: Set<String> = []
        if let selectedNote {
            neighborIDs.formUnion(selectedNote.links)
            for note in visible where note.links.contains(selectedNote.id) {
                neighborIDs.insert(note.id)
            }
        }
        var kindOffsets: [LingShuMemoryNote.Kind: Int] = [:]
        for (idx, note) in visible.enumerated() {
            let point: CGPoint
            let degree = note.links.filter { visibleIDs.contains($0) }.count + (inbound[note.id] ?? 0)
            let heat = note.graphHeat(degree: degree, now: Date())
            var radius = min(11, max(4.8, 4.8 + sqrt(CGFloat(max(degree, 1))) * 1.15))
            radius += CGFloat(heat) * 2.4
            if idx == selectedIndex {
                point = center
                radius = 11.5
            } else if neighborIDs.contains(note.id), selectedIndex != nil {
                let neighborRank = visible[..<idx].filter { neighborIDs.contains($0.id) }.count
                let totalNeighbors = max(1, visible.filter { neighborIDs.contains($0.id) }.count)
                let r = maxRadius * 0.24
                let angle = CGFloat(neighborRank) / CGFloat(totalNeighbors) * CGFloat.pi * 2 - CGFloat.pi / 2
                point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
                radius += 1.6
            } else {
                let shiftedIndex = idx > (selectedIndex ?? Int.max) ? idx - 1 : idx
                let kindIndex = CGFloat(LingShuMemoryNote.Kind.allCases.firstIndex(of: note.kind) ?? 0)
                let kindCount = CGFloat(max(1, LingShuMemoryNote.Kind.allCases.count))
                let n = kindOffsets[note.kind, default: 0]
                kindOffsets[note.kind] = n + 1
                let t = CGFloat(shiftedIndex + 1) / CGFloat(max(visible.count, 1))
                let r = maxRadius * (0.34 + 0.66 * sqrt(t))
                let sector = (kindIndex / kindCount) * CGFloat.pi * 2
                let angle = sector + CGFloat(n) * golden * 0.72
                let jitter = CGFloat(abs(note.id.hashValue % 17)) / 17.0 * 10.0
                point = CGPoint(
                    x: center.x + cos(angle) * (r + jitter),
                    y: center.y + sin(angle) * (r + jitter)
                )
            }
            nodes.append(.init(id: note.id, note: note, point: point, radius: radius, rank: idx, degree: degree, heat: heat))
        }
        return .init(nodes: nodes)
    }
}

private extension LingShuMemoryNote {
    /// A deterministic local "usefulness heat" score for visual exploration.
    /// It deliberately uses only existing vault metadata: confidence, recency,
    /// link degree, source authority and correction history.
    func graphHeat(degree: Int, now: Date) -> Double {
        let verifiedDays = max(0, now.timeIntervalSince(lastVerified) / 86_400)
        let updatedDays = max(0, now.timeIntervalSince(updated) / 86_400)
        let verifiedFreshness = exp(-verifiedDays / 45)
        let updatedFreshness = exp(-updatedDays / 30)
        let freshness = max(verifiedFreshness, updatedFreshness)
        let degreeScore = min(1, log2(Double(max(0, degree)) + 1) / 5)
        let sourceScore: Double
        switch source {
        case .userExplicit: sourceScore = 1
        case .tool: sourceScore = 0.72
        case .inference: sourceScore = 0.42
        }
        let historyScore = min(1, Double(history.count) / 5)
        let raw = confidence * 0.34
            + freshness * 0.26
            + degreeScore * 0.26
            + sourceScore * 0.1
            + historyScore * 0.04
        return min(1, max(0.08, raw))
    }
}

private extension LingShuMemoryNote.Kind {
    var displayName: String {
        switch self {
        case .person: LingShuLanguagePreferenceStore.localized("人物", "Person")
        case .project: LingShuLanguagePreferenceStore.localized("项目", "Project")
        case .preference: LingShuLanguagePreferenceStore.localized("偏好", "Preference")
        case .decision: LingShuLanguagePreferenceStore.localized("决策", "Decision")
        case .fact: LingShuLanguagePreferenceStore.localized("事实", "Fact")
        case .skill: LingShuLanguagePreferenceStore.localized("技能", "Skill")
        case .glossary: LingShuLanguagePreferenceStore.localized("术语", "Glossary")
        }
    }

    var graphColor: Color {
        switch self {
        case .person: .pink
        case .project: .blue
        case .preference: .orange
        case .decision: .purple
        case .fact: .lingHolo
        case .skill: .green
        case .glossary: .mint
        }
    }

    func heatColor(_ heat: Double) -> Color {
        graphColor.opacity(0.18 + 0.82 * min(1, max(0, heat)))
    }
}
