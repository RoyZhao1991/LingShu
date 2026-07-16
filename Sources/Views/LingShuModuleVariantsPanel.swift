import SwiftUI

/// P6+ 无界自进化·**模块变体管理面板**。
/// 列每个可进化槽位(执行策略 / 行为人格 / 获取上限 / 编译核心组合器)的全部变体(基线 + 自进化版),
/// 标活跃、**一键切换**任一变体、**一键回退**上一版/基线。自进化产物默认 inactive,人在此一键启用/撤回——
/// 这就是「连核心也能改、但任何改动都模块化、可一键切换、可一键回退」的治理台。
struct LingShuModuleVariantsPanel: View {
    @ObservedObject var state: LingShuState
    @State private var showRiskConfirm = false

    // ObservedObject 订阅整对象 objectWillChange:state.moduleVariantsRevision bump 即触发本面板刷新
    // (注册表本身存 UserDefaults 按需读)。
    private var registry: LingShuModuleVariantRegistry { state.moduleRegistry() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            selfEvolutionSwitch   // P6 自我进化总开关(默认关,开启前弹风险提示)
            Divider().overlay(Color.lingFg.opacity(0.08))

            SectionHeader(icon: "arrow.triangle.branch",
                          title: state.loc("模块变体(无界自进化)", "Module Variants (Self-evolution)"),
                          subtitle: state.loc("每个可进化槽位存多版本变体;自进化产物默认未启用,你一键切换生效 / 一键回退。连核心算法也走这套治理。", "Each evolvable slot keeps multiple variants. Generated variants start inactive and can be enabled or rolled back with one click."))

            let _ = state.moduleVariantsRevision   // 显式建立刷新依赖

            ForEach(LingShuModuleSlots.all, id: \.self) { slot in
                slotCard(slot)
            }
        }
        .padding(14)
        .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.lingHolo.opacity(0.14)) }
        .alert(state.loc("开启自我进化?", "Enable Self-evolution?"), isPresented: $showRiskConfirm) {
            Button(state.loc("取消", "Cancel"), role: .cancel) { }
            Button(state.loc("我已了解,开启", "I Understand, Enable"), role: .destructive) { state.setSelfEvolutionEnabled(true) }
        } message: {
            Text(state.loc(
                "开启后,灵枢会自检反复失败的弱点、主动提出改进提案(自写工具 / 装技能 / 接连接器 / 调执行策略)。\n\n安全护栏仍在:每条提案都需你逐条批准才生效、且都能一键回退;安全红线(危险/未审代码绝不静默执行)不放松。\n\n但自我进化属高风险能力——它会让灵枢主动改变自己的行为与能力边界。确认开启?",
                "When enabled, Nous identifies repeated weaknesses and proposes improvements such as authoring tools, installing skills, adding connectors, or tuning execution policy.\n\nEvery proposal still requires explicit approval and can be rolled back. Safety boundaries remain enforced.\n\nSelf-evolution is high risk because it changes behavior and capability boundaries. Enable it?"
            ))
        }
    }

    /// P6 自我进化总开关:默认关;打开前弹风险提示(确认后才真开),关闭直接生效。
    @ViewBuilder private var selfEvolutionSwitch: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state.selfEvolutionEnabled ? "wand.and.stars" : "wand.and.stars.inverse")
                .font(.system(size: 15)).foregroundStyle(state.selfEvolutionEnabled ? Color.lingHolo : Color.lingFg.opacity(0.4))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(state.loc("自我进化", "Self-evolution")).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.92))
                    Text(state.selfEvolutionEnabled ? state.loc("已开启", "Enabled") : state.loc("已关闭(默认)", "Off (Default)"))
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(state.selfEvolutionEnabled ? Color.lingVoid : Color.lingFg.opacity(0.55))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(state.selfEvolutionEnabled ? Color.lingHolo : Color.lingFg.opacity(0.08), in: Capsule())
                }
                Text(state.selfEvolutionEnabled
                     ? state.loc("灵枢会自检反复弱点 → 提待批改进提案;采纳仍需你逐条批准、可一键回退。", "Nous identifies repeated weaknesses and proposes improvements. Every adoption requires approval and remains reversible.")
                     : state.loc("关闭时灵枢不挖弱点、不提案、不采纳。开启属高风险授权。", "When off, Nous does not identify weaknesses, propose changes, or adopt them. Enabling is a high-risk authorization."))
                    .font(.system(size: 10.5)).foregroundStyle(Color.lingFg.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { state.selfEvolutionEnabled },
                set: { want in
                    if want { showRiskConfirm = true }            // 开启前先弹风险提示,确认后才真开
                    else { state.setSelfEvolutionEnabled(false) } // 关闭直接生效
                })).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    @ViewBuilder private func slotCard(_ slot: String) -> some View {
        let variants = registry.variants(slotID: slot)
        let activeID = registry.activeVariant(slotID: slot)?.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(localizedSlotLabel(slot))
                    .font(.system(size: 12.5, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.9))
                Text(slot).font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.lingFg.opacity(0.35))
                Spacer()
                Button {
                    _ = state.rollbackModuleVariant(slotID: slot)
                } label: {
                    Label(state.loc("回退", "Rollback"), systemImage: "arrow.uturn.backward")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(variants.count <= 1)
            }
            ForEach(variants) { v in variantRow(slot: slot, v: v, isActive: v.id == activeID) }
        }
        .padding(10)
        .background(Color.lingFg.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder private func variantRow(slot: String, v: LingShuModuleVariant, isActive: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 12)).foregroundStyle(isActive ? Color.lingHolo : Color.lingFg.opacity(0.3))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(v.label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.85)).lineLimit(1)
                    Text(sourceTag(v.source)).font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.lingFg.opacity(0.55))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.lingFg.opacity(0.08), in: Capsule())
                }
                Text(payloadPreview(v)).font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(Color.lingFg.opacity(0.45)).lineLimit(2)
            }
            Spacer(minLength: 6)
            if isActive {
                Text(state.loc("活跃", "Active")).font(.system(size: 9.5, weight: .bold)).foregroundStyle(Color.lingHolo)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.lingHolo.opacity(0.12), in: Capsule())
            } else {
                Button {
                    _ = state.switchModuleVariant(slotID: slot, to: v.id)
                } label: {
                    Text(state.loc("切到此", "Activate")).font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.bordered).controlSize(.small)
                // 基线不可删;非活跃的自进化/手动变体可删(清掉否决/测试变体)。
                if v.source != "baseline" {
                    Button {
                        _ = state.removeModuleVariant(slotID: slot, variantID: v.id)
                    } label: {
                        Image(systemName: "trash").font(.system(size: 10.5)).foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(Color.lingFg.opacity(isActive ? 0.05 : 0.02), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func sourceTag(_ source: String) -> String {
        switch source {
        case "baseline": return state.loc("基线", "Baseline")
        case "authored": return state.loc("自进化", "Self-evolved")
        case "discovered": return state.loc("发现", "Discovered")
        case "manual": return state.loc("手动", "Manual")
        default: return source
        }
    }

    private func payloadPreview(_ v: LingShuModuleVariant) -> String {
        let p = v.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return state.loc("(空 payload = 不改行为·基线)", "(Empty payload = unchanged baseline behavior)") }
        if v.slotID == LingShuModuleSlots.guidanceAssembly { return state.loc("组合器实现键:\(p)", "Composer key: \(p)") }
        if v.slotID == LingShuModuleSlots.acquisitionCeiling { return state.loc("驱动获取上限:\(p) 轮", "Acquisition limit: \(p) rounds") }
        return String(p.prefix(110))
    }

    private func localizedSlotLabel(_ slot: String) -> String {
        guard state.language == .english else { return LingShuModuleSlots.label(slot) }
        switch slot {
        case LingShuModuleSlots.executionGuidance: return "Execution Guidance"
        case LingShuModuleSlots.personaStrategy: return "Behavior Persona"
        case LingShuModuleSlots.acquisitionCeiling: return "Acquisition Limit"
        case LingShuModuleSlots.guidanceAssembly: return "Core Guidance Composer"
        default: return slot
        }
    }
}
