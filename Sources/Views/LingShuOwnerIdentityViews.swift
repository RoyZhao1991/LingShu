import SwiftUI

struct LingShuOwnerIdentityPanel: View {
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @State private var ownerName = "主人"

    var body: some View {
        let snapshot = perceptionGateway.ownerIdentitySnapshot

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("身份锁")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))

                Spacer()

                Toggle("", isOn: Binding<Bool>(
                    get: { snapshot.lockEnabled },
                    set: { perceptionGateway.setOwnerIdentityLockEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(snapshot.enrollmentState != .enrolled)
            }

            HStack(spacing: 8) {
                TextField("主人名称", text: $ownerName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.lingHolo.opacity(0.14))
                    }

                Button("开始认主") {
                    perceptionGateway.beginOwnerEnrollment(ownerName: ownerName)
                }
                .buttonStyle(IdentityCapsuleButtonStyle(active: snapshot.enrollmentState == .enrolling))

                Button("重置") {
                    perceptionGateway.resetOwnerIdentity()
                }
                .buttonStyle(IdentityCapsuleButtonStyle(active: false))
            }

            HStack(spacing: 8) {
                IdentityMetric(title: "面容", value: "\(snapshot.faceSampleCount)/3", confidence: snapshot.faceConfidence)
                IdentityMetric(title: "声线", value: "\(snapshot.voiceSampleCount)/3", confidence: snapshot.voiceConfidence)
                IdentityMetric(title: "综合", value: snapshot.isLocked ? "通过" : "待确认", confidence: snapshot.combinedConfidence)
            }

            Text(snapshot.detailText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            Text(hintText)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(identityStrokeColor.opacity(0.18))
        }
    }

    private var hintText: String {
        if !voice.isRecording && !vision.isCameraRunning {
            return "认主需要同时启用收音和视觉；身份锁开启后，触发词命中也必须先通过面容和声线联合确认。"
        }
        if !voice.isRecording {
            return "请启用收音并连续说几句话，用于采集声线样本。"
        }
        if !vision.isCameraRunning {
            return "请启用视觉并面向摄像头，用于采集面容样本。"
        }
        return "采集中。请面向摄像头，用自然语速连续说几句话。"
    }

    private var identityStrokeColor: Color {
        perceptionGateway.isOwnerIdentityLocked ? .green : .lingHolo
    }
}

private struct IdentityMetric: View {
    let title: String
    let value: String
    let confidence: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.46))

            HStack(spacing: 5) {
                Text(value)
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))

                if let confidence {
                    Text(LingShuOwnerIdentitySnapshot.percent(confidence))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.lingHolo.opacity(0.9))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct IdentityCapsuleButtonStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(active ? Color.lingVoid : .white.opacity(0.82))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                active ? Color.lingHolo : Color.white.opacity(configuration.isPressed ? 0.14 : 0.075),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.lingHolo.opacity(active ? 0 : 0.16))
            }
    }
}
