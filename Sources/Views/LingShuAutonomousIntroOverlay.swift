import SwiftUI
import AppKit

/// 自主运行「进入仪式」(用户定调 2026-06-17,只增强仪式感、不改任何业务流程):
/// 自主模式开启的**瞬间**——整屏覆一层暗幕(界面"融化")→ 大量青色离子从屏幕各处汇聚到**右上角**、
/// 凝成灵枢本体(光球)→ 暗幕退去。之后界面整个让位给 `LingShuAutonomousOrbOnlyView`(只剩右上角半透明本体)。
/// 触发:`isStandingPersonOnDuty` 由 false→true(上岗瞬间)。纯表现,`allowsHitTesting(false)` 不挡操作。
struct LingShuAutonomousIntroOverlay: View {
    @ObservedObject var state: LingShuState
    @State private var startedAt: Date?
    private let duration: Double = 2.8

    var body: some View {
        GeometryReader { geo in
            Group {
                if let startedAt {
                    TimelineView(.animation) { tl in
                        let p = min(max(tl.date.timeIntervalSince(startedAt) / duration, 0), 1)
                        AutonomousIntroCanvas(progress: p, size: geo.size)
                    }
                }
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
            .onChange(of: state.isStandingPersonOnDuty) { _, onDuty in
                guard onDuty else { startedAt = nil; return }
                startedAt = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.25) {
                    if Date().timeIntervalSince(startedAt ?? Date()) >= duration { startedAt = nil }
                }
            }
        }
    }
}

/// 自主模式「只剩本体」终态(用户定调 2026-06-17):仪式结束后整窗收缩成一颗**半透明悬浮本体** +
/// 一条小控制条(**暂停/继续 + 退出**)。灵枢界面整个消失、化身为悬浮光球,除本体与控制条外别无一物。
/// 暂停=本体冻结变暗(`pauseAutonomousRun`);继续=激活;退出=回主界面(`stopAutonomousRun`)。
/// 窗口收缩成小浮窗 + 透明背景 + **内容铺满整窗(无黑标题条、本体不被裁)** 由 `LingShuAutonomousWindowController` 负责。
struct LingShuAutonomousOrbOnlyView: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway

    private var paused: Bool { state.autonomousRun.phase == .paused }

    var body: some View {
        let snapshot = state.digitalHumanSnapshot(voice: voice, vision: vision, perceptionGateway: perceptionGateway)
        VStack(spacing: 8) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                let bob = paused ? 0 : sin(tl.date.timeIntervalSinceReferenceDate * 1.4) * 3   // 暂停=冻结不浮动
                LingShuDigitalHumanMiniOrb(snapshot: snapshot, audioLevel: paused ? 0 : Double(voice.outputLevel))
                    .frame(width: 96, height: 96)
                    .opacity(paused ? 0.4 : 0.95)        // 暂停=冻结变暗
                    .saturation(paused ? 0.25 : 1)
                    .shadow(color: Color.lingHolo.opacity(paused ? 0.15 : 0.6), radius: 18)
                    .offset(y: bob)
                    .overlay { if paused { Image(systemName: "pause.fill").font(.system(size: 22, weight: .heavy)).foregroundStyle(.white.opacity(0.85)) } }
            }
            controlBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // 填满整窗、内容居中(本体不被裁)
        .contextMenu {   // 兜底:无边框窗口若按钮点不动,右键本体一样能暂停/退出
            if paused {
                Button { state.resumeAutonomousRun() } label: { Label("继续运行", systemImage: "play.fill") }
            } else {
                Button { state.pauseAutonomousRun() } label: { Label("暂停", systemImage: "pause.fill") }
            }
            Divider()
            Button(role: .destructive) { state.stopAutonomousRun() } label: { Label("退出自主模式", systemImage: "xmark") }
        }
        .transition(.scale(scale: 0.3).combined(with: .opacity))
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            pill(paused ? "继续" : "暂停", icon: paused ? "play.fill" : "pause.fill", tint: paused ? .lingHolo : .lingHoloAlt) {
                if paused { state.resumeAutonomousRun() } else { state.pauseAutonomousRun() }
            }
            pill("退出", icon: "xmark", tint: .red) { state.stopAutonomousRun() }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5) }
    }

    private func pill(_ label: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 9).frame(height: 24)
                .background(tint.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 自主模式终态的窗口处理:把灵枢主窗口**变无边框(borderless,根治黑标题条)+ 透明背景 + 浮于顶层 + 收成右上角小浮窗**。
/// borderless 没有标题栏视图(那条黑框就是标题栏),从源头消除;`object_setClass` 换成可成为 key 的子类让本体上的
/// 暂停/退出按钮仍可点。退出自主模式时**完整还原**(类/样式/尺寸/透明/层级);兜底:控制条「退出」任何时候可回正常界面。
struct LingShuAutonomousWindowController: NSViewRepresentable {
    let active: Bool   // true = 进入只剩本体的小浮窗终态

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coord = context.coordinator
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if active, !coord.shrunk {
                coord.capture(window)
                Self.applyOrbMode(window)
                coord.shrunk = true
            } else if !active, coord.shrunk {
                coord.restore(window)
                coord.shrunk = false
            }
        }
    }

    private static func applyOrbMode(_ w: NSWindow) {
        // **无边框=无标题栏视图=无黑框**(根治)。不再 object_setClass(实测会让 SwiftUI 窗口崩溃)——
        // 只改 styleMask 为 borderless;按钮在前台 app 里靠鼠标事件仍可点(canBecomeKey 只影响键盘焦点)。
        w.styleMask = [.borderless, .resizable]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isMovableByWindowBackground = true                  // 拖本体即可挪动这颗悬浮球
        w.minSize = NSSize(width: 100, height: 120)
        w.level = .floating
        if let screen = w.screen ?? NSScreen.main {
            let width: CGFloat = 140, height: CGFloat = 168, margin: CGFloat = 24
            let vf = screen.visibleFrame
            w.setFrame(NSRect(x: vf.maxX - width - margin, y: vf.maxY - height - margin, width: width, height: height), display: true, animate: true)
        }
        w.orderFront(nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shrunk = false
        private var frame: NSRect?
        private var opaque = true
        private var bg: NSColor?
        private var shadow = true
        private var styleMask: NSWindow.StyleMask = []
        private var movableByBG = false
        private var level: NSWindow.Level = .normal
        private var minSize = NSSize.zero

        func capture(_ w: NSWindow) {
            frame = w.frame; opaque = w.isOpaque; bg = w.backgroundColor; shadow = w.hasShadow
            styleMask = w.styleMask
            movableByBG = w.isMovableByWindowBackground
            level = w.level; minSize = w.minSize
        }

        func restore(_ w: NSWindow) {
            w.styleMask = styleMask                                       // 恢复 .titled 等(标题栏回来)
            w.isOpaque = opaque; w.backgroundColor = bg; w.hasShadow = shadow
            w.isMovableByWindowBackground = movableByBG
            w.level = level; w.minSize = minSize
            if let frame { w.setFrame(frame, display: true, animate: true) }
            w.makeKeyAndOrderFront(nil)
        }
    }
}

/// 仪式的离子粒子场 + 暗幕 + 本体凝聚 + 冲击波(Canvas 一次画完;helper 拆小避免 SwiftUI 类型检查超时)。
private struct AutonomousIntroCanvas: View {
    let progress: Double
    let size: CGSize
    private let particleCount = 120
    private let accent = Color.lingHolo

    var body: some View {
        Canvas { ctx, sz in
            let target = CGPoint(x: sz.width - 64, y: 64)   // 右上角本体落点
            // ① 暗幕(界面"融化"成暗)先铺底,② 之后所有发光元素画在它上面。
            ctx.fill(Path(CGRect(origin: .zero, size: sz)), with: .color(.black.opacity(veilOpacity(progress))))
            drawCornerGlow(ctx, sz, target: target)
            drawParticles(ctx, sz, target: target)
            drawOrb(ctx, target: target)
            drawShockwave(ctx, target: target)
        }
    }

    // MARK: - 各层

    private func drawCornerGlow(_ ctx: GraphicsContext, _ sz: CGSize, target: CGPoint) {
        // 角落渐起的青色辉光(离子汇聚处越来越亮)。
        let glow = min(max((progress - 0.2) / 0.6, 0), 1)
        guard glow > 0 else { return }
        let r = max(sz.width, sz.height) * (0.25 + 0.35 * glow)
        let grad = Gradient(stops: [
            .init(color: accent.opacity(0.22 * glow), location: 0),
            .init(color: accent.opacity(0.05 * glow), location: 0.5),
            .init(color: .clear, location: 1)
        ])
        ctx.fill(
            Path(ellipseIn: CGRect(x: target.x - r, y: target.y - r, width: r * 2, height: r * 2)),
            with: .radialGradient(grad, center: target, startRadius: 0, endRadius: r)
        )
    }

    private func drawParticles(_ ctx: GraphicsContext, _ sz: CGSize, target: CGPoint) {
        for i in 0..<particleCount {
            let fi = Double(i)
            let sx = Self.hash(fi * 1.13) * Double(sz.width)
            let sy = Self.hash(fi * 2.71 + 5) * Double(sz.height)
            let delay = Self.hash(fi * 3.30) * 0.30
            let psize = 1.4 + Self.hash(fi * 0.70) * 3.2
            let swirl = (Self.hash(fi * 4.10) - 0.5) * 2.4

            let lp = Self.easeInOut(min(max((progress - delay) / (1 - delay), 0), 1))
            // 位置:起点→落点,带逐渐收敛的横向涡流。
            let curve = sin(lp * .pi) * swirl * 60 * (1 - lp)
            let x = sx + (target.x - sx) * lp + curve
            let y = sy + (target.y - sy) * lp - curve * 0.6
            // 透明度:先现身,接近落点更亮,落点后被"吸收"消失。
            let fadeIn = min(lp / 0.15, 1)
            let absorbed = max(0, (lp - 0.92) / 0.08)
            let alpha = fadeIn * (0.35 + 0.65 * lp) * (1 - absorbed)
            guard alpha > 0.01 else { continue }
            let s = psize * (1.0 + 0.6 * lp)
            ctx.fill(
                Path(ellipseIn: CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s)),
                with: .color((lp > 0.6 ? Color.white : accent).opacity(alpha))
            )
        }
    }

    private func drawOrb(_ ctx: GraphicsContext, target: CGPoint) {
        let form = min(max((progress - 0.55) / 0.45, 0), 1)   // 凝聚度
        guard form > 0 else { return }
        let r = 30.0 * Self.easeOut(form)
        // 外辉光
        let glowGrad = Gradient(stops: [
            .init(color: accent.opacity(0.55 * form), location: 0),
            .init(color: accent.opacity(0.12 * form), location: 0.55),
            .init(color: .clear, location: 1)
        ])
        let gr = r * 2.4
        ctx.fill(
            Path(ellipseIn: CGRect(x: target.x - gr, y: target.y - gr, width: gr * 2, height: gr * 2)),
            with: .radialGradient(glowGrad, center: target, startRadius: 0, endRadius: gr)
        )
        // 本体核
        let coreGrad = Gradient(stops: [
            .init(color: .white.opacity(0.95 * form), location: 0),
            .init(color: accent.opacity(0.7 * form), location: 0.4),
            .init(color: .clear, location: 1)
        ])
        ctx.fill(
            Path(ellipseIn: CGRect(x: target.x - r, y: target.y - r, width: r * 2, height: r * 2)),
            with: .radialGradient(coreGrad, center: target, startRadius: 0, endRadius: r)
        )
        // 凝成瞬间的白色绽放(~0.9 峰值)
        let bloom = max(0, 1 - abs(progress - 0.9) / 0.1)
        if bloom > 0 {
            let br = r * (1.0 + 1.2 * bloom)
            ctx.fill(
                Path(ellipseIn: CGRect(x: target.x - br, y: target.y - br, width: br * 2, height: br * 2)),
                with: .color(.white.opacity(0.5 * bloom))
            )
        }
    }

    private func drawShockwave(_ ctx: GraphicsContext, target: CGPoint) {
        let w = min(max((progress - 0.82) / 0.18, 0), 1)
        guard w > 0, w < 1 else { return }
        let r = 24 + w * 220
        ctx.stroke(
            Path(ellipseIn: CGRect(x: target.x - r, y: target.y - r, width: r * 2, height: r * 2)),
            with: .color(accent.opacity(0.5 * (1 - w))),
            lineWidth: 2.5 * (1 - w)
        )
    }

    // MARK: - 工具(纯函数)

    /// 暗幕不透明度:快速融化到 0.58,凝聚完成后退去。
    private func veilOpacity(_ p: Double) -> Double {
        if p < 0.28 { return 0.58 * (p / 0.28) }
        if p < 0.78 { return 0.58 }
        return 0.58 * (1 - (p - 0.78) / 0.22)
    }

    private static func hash(_ n: Double) -> Double {
        let x = sin(n * 12.9898 + 1.7) * 43758.5453
        return x - floor(x)
    }
    private static func easeInOut(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }
    private static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
}
