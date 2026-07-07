import Foundation

/// UI/账本展示层的模型文本清洗。
/// 流程控制仍只读取严格 JSON；这里仅负责把违规混合输出里的 `reply` 提取成用户可见文本。
enum LingShuVisibleModelText {
    static func clean(_ raw: String) -> String {
        let visible = LingShuStructuredModelOutput.visibleText(from: raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !visible.isEmpty { return visible }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
