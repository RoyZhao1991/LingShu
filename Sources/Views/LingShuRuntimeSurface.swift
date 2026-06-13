import SwiftUI

/// 运行态表面：中枢核心、任务/通道读数、调用链与底层执行窗的统一驻地。
/// 对话表面只保留一条脉搏条，完整状态检阅都在这里。
struct LingShuRuntimeSurface: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 14) {
                LingShuCoreHeader(state: state, voice: voice)

                LingShuAutonomousRunPanel(state: state)

                LingShuExecutionConsoleView(state: state)
                    .frame(maxHeight: .infinity)
            }
            .padding(18)
            .lingShuHUDPanel()

            LingShuCallChainPanel(state: state)
                .frame(width: 390)
        }
        .padding(20)
    }
}
