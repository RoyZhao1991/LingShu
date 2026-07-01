import SwiftUI

/// 常驻与定时触发管理：开机自启开关 + 定时任务（提醒/例行任务）的增删与启停。
struct LingShuTriggerSettingsView: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var triggerService: LingShuScheduledTriggerService
    @State private var launchAtLogin = LingShuResidencyService.isLaunchAtLoginEnabled
    @State private var residencyNote = ""
    @State private var newTitle = ""
    @State private var newPrompt = ""
    @State private var newHour = 9
    @State private var newMinute = 0
    @State private var newRepeats = true
    /// 当前展开看「执行记录」的定时任务 id(点开/收起)。
    @State private var expandedTriggerID: String?

    /// 某定时任务到点跑出来的执行记录(按 prompt 匹配——触发时 submitTextInput(trigger.prompt) 落的记录),最近在前。
    private func recordsFor(_ trigger: LingShuScheduledTrigger) -> [LingShuTaskExecutionRecord] {
        state.taskExecutionRecords
            .filter { $0.prompt == trigger.prompt }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

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
                        .foregroundStyle(Color.lingFg.opacity(0.5))
                }
                Spacer()
                Text("主窗口关闭后灵枢仍在菜单栏值守，定时任务照常触发")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.lingFg.opacity(0.4))
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

            let running = triggerService.triggers.filter(\.enabled)
            let finished = triggerService.triggers.filter { !$0.enabled }

            if triggerService.triggers.isEmpty {
                Text("还没有定时任务。到点后内容是提醒就开口提醒，是任务就走完整协同管线。")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.lingFg.opacity(0.4))
            } else {
                // 运行中(启用、会到点触发)
                if !running.isEmpty {
                    groupHeader("运行中", count: running.count, color: Color.lingHolo)
                    VStack(spacing: 6) { ForEach(running) { triggerRow($0) } }
                }
                // 已结束/已停用(一次性已触发 → 自动停用,或手动停用)
                if !finished.isEmpty {
                    HStack {
                        groupHeader("已结束 / 已停用", count: finished.count, color: Color.lingFg.opacity(0.4))
                        Spacer()
                        Button("清除已结束") { finished.forEach { triggerService.remove(id: $0.id) } }
                            .font(.system(size: 10.5, weight: .semibold)).buttonStyle(.plain)
                            .foregroundStyle(Color.lingFg.opacity(0.45))
                    }
                    VStack(spacing: 6) { ForEach(finished) { triggerRow($0) } }
                }
            }
        }
        .padding(14)
        .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.lingHolo.opacity(0.14))
        }
    }

    @ViewBuilder
    private func groupHeader(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(title)（\(count)）")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(color)
        }
        .padding(.top, 4)
    }

    /// 单条定时任务状态(分清运行中/已结束):运行中·每天 / 待触发 / 已完成 / 已停用。
    private func statusLabel(_ t: LingShuScheduledTrigger) -> (String, Color) {
        if t.enabled {
            return t.repeatsDaily ? ("运行中·每天", Color.lingHolo) : ("待触发", Color.lingHolo)
        }
        if !t.repeatsDaily, t.lastFiredAt != nil { return ("已完成", Color.lingFg.opacity(0.45)) }
        return ("已停用", Color.lingFg.opacity(0.4))
    }

    @ViewBuilder
    private func triggerRow(_ trigger: LingShuScheduledTrigger) -> some View {
        let (label, color) = statusLabel(trigger)
        let records = recordsFor(trigger)
        let expanded = expandedTriggerID == trigger.id
        VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 10) {
            Image(systemName: trigger.repeatsDaily ? "repeat.circle.fill" : "1.circle")
                .foregroundStyle(trigger.enabled ? Color.lingHolo : Color.lingFg.opacity(0.3))
            Text(label)
                .font(.system(size: 9.5, weight: .bold)).foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(color.opacity(0.14), in: Capsule())
            Text(trigger.scheduleText)
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.lingFg.opacity(trigger.enabled ? 0.85 : 0.4))
            Text(trigger.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.lingFg.opacity(trigger.enabled ? 0.9 : 0.45))
            Text(trigger.prompt)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.lingFg.opacity(0.45)).lineLimit(1)
            Spacer()
            if let firedAt = trigger.lastFiredAt {
                Text("上次 \(firedAt.taskRecordDisplayTime)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.lingFg.opacity(0.32))
            }
            Button { expandedTriggerID = expanded ? nil : trigger.id } label: {
                HStack(spacing: 3) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                    Text("执行记录 \(records.count)").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(records.isEmpty ? Color.lingFg.opacity(0.35) : Color.lingHolo.opacity(0.85))
            }
            .buttonStyle(.plain).help("展开看这个定时任务到点跑出来的执行记录")
            Toggle("", isOn: Binding(
                get: { trigger.enabled },
                set: { triggerService.setEnabled(id: trigger.id, enabled: $0) }
            ))
            .toggleStyle(.switch).controlSize(.mini)
            Button {
                triggerService.remove(id: trigger.id)
            } label: {
                Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        if expanded {
            VStack(alignment: .leading, spacing: 4) {
                if records.isEmpty {
                    Text("还没有执行记录(到点跑过就会出现在这里)。")
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.4))
                } else {
                    ForEach(records) { rec in
                        Button { state.openTaskRecord(rec.id) } label: {
                            HStack(spacing: 8) {
                                Circle().fill(rec.status.color).frame(width: 5, height: 5)
                                Text(rec.updatedAt.taskRecordDisplayTime)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.lingFg.opacity(0.62))
                                Text(rec.status.rawValue).font(.system(size: 10, weight: .bold)).foregroundStyle(rec.status.color)
                                Text("\(rec.messages.count) 条").font(.system(size: 10)).foregroundStyle(Color.lingFg.opacity(0.4))
                                Spacer()
                                Text("查看 →").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.lingHolo)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.lingFg.opacity(0.03), in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain).help("打开这次执行的完整记录(含参与方对话)")
                    }
                }
            }
            .padding(.leading, 22)
        }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(Color.lingFg.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
