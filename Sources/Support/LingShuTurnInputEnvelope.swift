import Foundation

/// One user turn has three different consumers:
/// - the chat UI needs the user's visible words;
/// - triage needs intent plus compact attachment metadata;
/// - the brain/tool loop may need expanded attachment context.
///
/// Keeping them separate prevents attachment body text from being mistaken for
/// the user's latest intent while still giving the model enough context to act.
struct LingShuTurnInputEnvelope: Equatable, Sendable {
    let visibleText: String
    let modelPrompt: String
    let attachmentNames: [String]
    let attachmentPaths: [String]

    init(
        visibleText: String,
        modelPrompt: String,
        attachmentNames: [String] = [],
        attachmentPaths: [String] = []
    ) {
        self.visibleText = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelPrompt = modelPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.attachmentNames = attachmentNames
        self.attachmentPaths = attachmentPaths
    }

    var userFacingText: String {
        visibleText.isEmpty ? modelPrompt : visibleText
    }

    var hasAttachments: Bool {
        !attachmentNames.isEmpty || !attachmentPaths.filter { !$0.isEmpty }.isEmpty
    }

    /// Triage should know attachments exist, but should not read extracted file
    /// content. The content belongs to model execution, not context ownership.
    var triageText: String {
        guard hasAttachments else { return userFacingText }
        let rows = attachmentNames.enumerated().map { idx, name in
            let path = idx < attachmentPaths.count ? attachmentPaths[idx] : ""
            return "- \(name)" + (path.isEmpty ? "" : " @ \(path)")
        }.joined(separator: "\n")
        return """
        \(userFacingText)

        【附件元信息】
        \(rows)
        """
    }
}
