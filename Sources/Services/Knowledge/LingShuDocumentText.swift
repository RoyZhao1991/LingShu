import Foundation
import PDFKit

/// 本机知识中枢·**文档文本抽取**(多源接入 ①):把不同格式的文件抽成纯文本供索引。
/// 第一刀文本/代码直接读;**PDF 经 PDFKit 抽取**(.string)。新增格式只在这里加一个分支,索引器不动。
enum LingShuDocumentText {
    /// 可被抽取的文档扩展名(在文本/代码之外额外支持的)。
    static let documentExtensions: Set<String> = ["pdf"]

    /// 抽取文件文本;不支持/失败返回 nil。
    static func extract(from url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let doc = PDFDocument(url: url) else { return nil }
            let text = doc.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty == false) ? text : nil
        default:
            let text = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty == false) ? text : nil
        }
    }
}
