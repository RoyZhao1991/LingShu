import SwiftUI

/// 常驻与定时触发管理：开机自启开关 + 定时任务（提醒/例行任务）的增删与启停。
struct LingShuTriggerSettingsView: View {
    @ObservedObject var triggerService: LingShuScheduledTriggerService
    @State private var launchAtLogin = LingShuResidencyService.isLaunchAtLoginEnabled
    @State private var residencyNote = ""
    @State private var newTitle = ""
    @State private var newPrompt = ""
    @State private var newHour = 9
    @State private var newMinute = 0
    @State private var newRepeats = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(icon: "clock.badge", title: "常驻与定时触发", subtitle: "关窗不退出 · 菜单栏值守 · 到点自动执行")

            HStack(spacing: 10) {
                Toggle("开机自启", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, enabled in
                        residencyNote = LingShuResidencyService.setLaunchAtLogin(enabled)
                    }
                if !residencyNote.isEmpty {
                    Text(residencyNote)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Text("主窗口关闭后灵枢仍在菜单栏值守，定时任务照常触发")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }

            // 新建定时任务
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("名称（可空）", text: $newTitle)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    TextField("到点交给灵枢的指令，例如：提醒我喝水 / 整理今天的工作日志", text: $newPrompt)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $newHour) {
                        ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }
                    .frame(width: 64)
                    Text(":")
                    Picker("", selection: $newMinute) {
                        ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }
                    .frame(width: 64)
                    Toggle("每天", isOn: $newRepeats)
                        .toggleStyle(.checkbox)
                    Button {
                        triggerService.add(title: newTitle, prompt: newPrompt, hour: newHour, minute: newMinute, repeatsDaily: newRepeats)
                        newTitle = ""
                        newPrompt = ""
                    } label: {
                        Label("添加", systemImage: "plus.circle.fill")
                            .font(.system(size: 11.5, weight: .bold))
                    }
                    .disabled(newPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if triggerService.triggers.isEmpty {
                Text("还没有定时任务。到点后内容是提醒就开口提醒，是任务就走完整协同管线。")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                VStack(spacing: 6) {
                    ForEach(triggerService.triggers) { trigger in
                        HStack(spacing: 10) {
                            Image(systemName: trigger.repeatsDaily ? "repeat.circle.fill" : "1.circle")
                                .foregroundStyle(trigger.enabled ? Color.lingHolo : .white.opacity(0.3))
                            Text(trigger.scheduleText)
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(trigger.enabled ? 0.85 : 0.4))
                            Text(trigger.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(trigger.enabled ? 0.9 : 0.45))
                            Text(trigger.prompt)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                            Spacer()
                            if let firedAt = trigger.lastFiredAt {
                                Text("上次 \(firedAt.taskRecordDisplayTime)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.32))
                            }
                            Toggle("", isOn: Binding(
                                get: { trigger.enabled },
                                set: { triggerService.setEnabled(id: trigger.id, enabled: $0) }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            Button {
                                triggerService.remove(id: trigger.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.lingHolo.opacity(0.14))
        }
    }
}
