import Foundation

@MainActor
extension LingShuState {
    nonisolated static func explicitWorkingDirectoryHint(in text: String) -> String? {
        LingShuWorkingDirectoryHint.explicitDirectory(in: text)
    }

    func effectiveAgentWorkingDirectory(
        override explicitOverride: String? = nil,
        fallback: String? = nil
    ) -> String {
        let selected = explicitOverride?.nonEmptyWorkingDirectory
            ?? currentAgentWorkingDirectoryOverride?.nonEmptyWorkingDirectory
            ?? fallback?.nonEmptyWorkingDirectory
            ?? agentWorkingDirectory
        return (selected as NSString).standardizingPath
    }

    func currentWorkingDirectoryGuidance() -> String? {
        guard let dir = currentAgentWorkingDirectoryOverride?.nonEmptyWorkingDirectory else { return nil }
        return """
        【本轮工作目录】
        用户已明确指定本轮目录:\(dir)。
        本轮所有相对路径、write_file/edit_file/apply_patch、run_command 的默认执行目录都必须以这里为准;回复产出物路径也必须指向这里。不要把本轮产出落到全局默认 Workspace。
        """
    }
}

private extension String {
    var nonEmptyWorkingDirectory: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (trimmed as NSString).standardizingPath
    }
}

