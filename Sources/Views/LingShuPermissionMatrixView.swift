import SwiftUI

/// 完全版 #5·**权限矩阵 UI**(只读可视化):把 `LingShuPermissionMatrix` 的裁决清楚展示——
/// 资源域 × 运行模式,在所选风险档下放行/审批/拒绝一目了然。红线(供应链/紧急停止/不可逆)由求值器硬保证。
struct LingShuPermissionMatrixView: View {
    @State private var risk: LingShuRiskLevel = .medium
    @State private var durablyAllowed = false

    private let domains = LingShuResourceDomain.allCases
    private let modes: [LingShuRunMode] = [.readOnly, .standard, .developerFull, .autonomous, .presentation]

    private static let domainName: [LingShuResourceDomain: String] = [
        .file: "文件", .terminal: "终端", .network: "网络", .browser: "浏览器", .microphone: "麦克风",
        .camera: "摄像头", .speaker: "音箱", .systemControl: "系统控制", .externalAccount: "外部账号",
        .privateKnowledge: "私密知识", .supplyChain: "供应链/未审代码"
    ]
    private static let modeName: [LingShuRunMode: String] = [
        .readOnly: "只读", .standard: "标准", .developerFull: "开发全权", .autonomous: "自主", .presentation: "演示"
    ]
    private static let riskName: [LingShuRiskLevel: String] = [
        .readonly: "只读", .low: "低", .medium: "中", .high: "高", .critical: "极高(不可逆/系统)"
    ]
    private let risks: [LingShuRiskLevel] = [.readonly, .low, .medium, .high, .critical]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LingShuLanguagePreferenceStore.localized("权限矩阵", "Permission Matrix")).font(.headline)
            Text(LingShuLanguagePreferenceStore.localized("裁决 = 资源域 × 风险 × 运行模式。红线(供应链/紧急停止/不可逆)恒不自动放行,不随任何旋钮放松。", "Decision = resource domain × risk × run mode. Red lines such as supply-chain risk and irreversible actions are never auto-approved."))
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Picker(LingShuLanguagePreferenceStore.localized("风险档", "Risk Level"), selection: $risk) {
                    ForEach(risks, id: \.self) { Text(localizedRiskName($0)).tag($0) }
                }.frame(width: 240)
                Toggle(LingShuLanguagePreferenceStore.localized("已持久授权(主人勾过完全授权)", "Durable authorization granted"), isOn: $durablyAllowed)
            }

            grid
            legend
        }
    }

    private var grid: some View {
        VStack(spacing: 1) {
            HStack(spacing: 1) {
                cellText(LingShuLanguagePreferenceStore.localized("资源域 \\ 模式", "Domain \\ Mode"), bold: true).frame(width: 120, alignment: .leading)
                ForEach(modes, id: \.self) { cellText(localizedModeName($0), bold: true).frame(maxWidth: .infinity) }
            }
            ForEach(domains, id: \.self) { domain in
                HStack(spacing: 1) {
                    cellText(localizedDomainName(domain)).frame(width: 120, alignment: .leading)
                    ForEach(modes, id: \.self) { mode in
                        let v = LingShuPermissionMatrix.decide(domain: domain, risk: risk, mode: mode, durablyAllowed: durablyAllowed)
                        verdictCell(v).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .background(Color.gray.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func cellText(_ s: String, bold: Bool = false) -> some View {
        Text(s).font(.system(size: 11, weight: bold ? .semibold : .regular))
            .padding(.vertical, 6).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: bold ? .center : .leading)
            .background(Color(NSColor.windowBackgroundColor))
    }

    private func verdictCell(_ v: LingShuPermissionVerdict) -> some View {
        let (text, color): (String, Color) = {
            switch v {
            case .allow: return (LingShuLanguagePreferenceStore.localized("放行", "Allow"), .green)
            case .askUser: return (LingShuLanguagePreferenceStore.localized("审批", "Ask"), .orange)
            case .deny: return (LingShuLanguagePreferenceStore.localized("拒绝", "Deny"), .red)
            }
        }()
        return Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            .padding(.vertical, 6).frame(maxWidth: .infinity)
            .background(color.opacity(0.12))
    }

    private var legend: some View {
        HStack(spacing: 16) {
            label(LingShuLanguagePreferenceStore.localized("放行", "Allow"), .green)
            label(LingShuLanguagePreferenceStore.localized("审批(先确认)", "Ask First"), .orange)
            label(LingShuLanguagePreferenceStore.localized("拒绝", "Deny"), .red)
        }.font(.caption)
    }
    private func label(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 8, height: 8); Text(t).foregroundStyle(.secondary) }
    }

    private func localizedDomainName(_ domain: LingShuResourceDomain) -> String {
        let zh = Self.domainName[domain] ?? domain.rawValue
        let en: [LingShuResourceDomain: String] = [
            .file: "Files", .terminal: "Terminal", .network: "Network", .browser: "Browser", .microphone: "Microphone",
            .camera: "Camera", .speaker: "Speaker", .systemControl: "System Control", .externalAccount: "External Accounts",
            .privateKnowledge: "Private Knowledge", .supplyChain: "Supply Chain / Unreviewed Code"
        ]
        return LingShuLanguagePreferenceStore.localized(zh, en[domain] ?? domain.rawValue)
    }

    private func localizedModeName(_ mode: LingShuRunMode) -> String {
        let zh = Self.modeName[mode] ?? ""
        let en: [LingShuRunMode: String] = [
            .readOnly: "Read-only", .standard: "Standard", .developerFull: "Developer", .autonomous: "Autonomous", .presentation: "Presentation"
        ]
        return LingShuLanguagePreferenceStore.localized(zh, en[mode] ?? mode.rawValue)
    }

    private func localizedRiskName(_ risk: LingShuRiskLevel) -> String {
        let zh = Self.riskName[risk] ?? "\(risk)"
        let en: [LingShuRiskLevel: String] = [
            .readonly: "Read-only", .low: "Low", .medium: "Medium", .high: "High", .critical: "Critical (Irreversible / System)"
        ]
        return LingShuLanguagePreferenceStore.localized(zh, en[risk] ?? "\(risk)")
    }
}
