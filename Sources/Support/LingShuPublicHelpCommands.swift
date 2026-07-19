import AppKit
import SwiftUI

struct LingShuPublicHelpCommands: Commands {
    @ObservedObject var state: LingShuState

    var body: some Commands {
        CommandGroup(after: .help) {
            Button(state.loc("提交 Alpha 首跑报告…", "Share Alpha First-run Report…")) {
                NSWorkspace.shared.open(LingShuPublicLinks.firstRunReport(for: state.language))
            }
            Button(state.loc("到 GitHub 社区提问…", "Ask the GitHub Community…")) {
                NSWorkspace.shared.open(LingShuPublicLinks.discussions)
            }
            Divider()
            Button(state.loc("查看灵枢源码…", "View LingShu Source…")) {
                NSWorkspace.shared.open(LingShuPublicLinks.repository)
            }
        }
    }
}
