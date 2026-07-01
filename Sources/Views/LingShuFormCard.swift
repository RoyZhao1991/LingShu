import SwiftUI

/// 多项确认表单卡(用户定调):一次确认多个事项时,**每个事项一行、各带选择菜单**,
/// 每个菜单末行恒是「其他(自行输入)」→ 选它展开文本框填自由值。填完点「提交」一次性回传所有答案。
/// 已提交后置只读态(显示各项答案,不再可改),对齐选择卡的"选过即解决"。
struct LingShuFormCard: View {
    let form: LingShuConfirmForm
    let resolved: [String: String]?      // 非 nil = 已提交(只读展示)
    let onSubmit: ([String: String]) -> Void

    @State private var picked: [String: String] = [:]      // key → 选中的预设项(或 otherLabel)
    @State private var otherText: [String: String] = [:]   // key → 自行输入文本

    private var otherLabel: String { LingShuConfirmForm.otherOptionLabel }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if !form.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(form.title)
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.82))
            }
            ForEach(Array(form.fields.enumerated()), id: \.element.id) { idx, field in
                fieldRow(idx: idx, field: field)
            }
            if resolved == nil {
                Button { onSubmit(collectAnswers()) } label: {
                    Text("提交")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 18).padding(.vertical, 7)
                        .background(Color.lingHolo, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!allAnswered)
                .opacity(allAnswered ? 1 : 0.45)
                .help(allAnswered ? "提交确认" : "请把每一项都填好")
            }
        }
        .padding(13)
        .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.lingFg.opacity(0.10), lineWidth: 0.8) }
    }

    @ViewBuilder
    private func fieldRow(idx: Int, field: LingShuConfirmFormField) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("\(idx + 1)").font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.lingHolo.opacity(0.8))
                    .frame(width: 17, height: 17).background(Color.lingHolo.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                Text(field.question).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.86))
            }
            if let resolved {
                Text(resolved[field.key]?.isEmpty == false ? resolved[field.key]! : "(未填)")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.lingHolo.opacity(0.92))
                    .padding(.leading, 23)
            } else {
                let isOther = field.options.isEmpty || picked[field.key] == otherLabel
                HStack(spacing: 8) {
                    if !field.options.isEmpty {
                        Menu {
                            ForEach(field.options, id: \.self) { opt in
                                Button(opt) { picked[field.key] = opt }
                            }
                            Divider()
                            Button(otherLabel) { picked[field.key] = otherLabel }
                        } label: {
                            HStack(spacing: 5) {
                                Text(picked[field.key] ?? "请选择…")
                                    .foregroundStyle((picked[field.key] == nil) ? Color.lingFg.opacity(0.45) : Color.lingFg.opacity(0.9))
                                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.5))
                            }
                            .font(.system(size: 12.5, weight: .medium))
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(Color.lingFg.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if isOther {
                        TextField(field.options.isEmpty ? "请输入…" : "自行输入…", text: bindingOther(field.key))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.lingFg.opacity(0.92))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
                            .frame(maxWidth: 240)
                    }
                }
                .padding(.leading, 23)
            }
        }
    }

    private func bindingOther(_ key: String) -> Binding<String> {
        Binding(get: { otherText[key] ?? "" }, set: { otherText[key] = $0 })
    }

    /// 一项是否已答:无预设项→看文本框;有预设项→选了非"其他"即可,选了"其他"则要文本非空。
    private func answered(_ field: LingShuConfirmFormField) -> Bool {
        if field.options.isEmpty { return !(otherText[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let p = picked[field.key] else { return false }
        if p == otherLabel { return !(otherText[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return true
    }

    private var allAnswered: Bool { form.fields.allSatisfy(answered) }

    private func collectAnswers() -> [String: String] {
        var out: [String: String] = [:]
        for field in form.fields {
            if field.options.isEmpty || picked[field.key] == otherLabel {
                out[field.key] = (otherText[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                out[field.key] = picked[field.key] ?? ""
            }
        }
        return out
    }
}
