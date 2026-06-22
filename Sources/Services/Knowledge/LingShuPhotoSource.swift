import Foundation
import Vision
import ImageIO

/// 本机知识·**照片源**(多源接入):给图片生成字幕再索引 → "我那张写着X的截图/照片在哪"能找回。
/// **隐私红线([[perception-data-zero-retention]]):字幕全程 on-device 生成(Vision OCR + 场景分类),照片绝不上云。**
/// 失败/无文字的图跳过。
enum LingShuPhotoSource {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "bmp", "gif"]

    /// 给一张图算字幕(本机 Vision):OCR 文字 + 场景标签。无内容→nil。
    static func caption(imageAt url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let ocr = VNRecognizeTextRequest()
        ocr.recognitionLevel = .accurate
        ocr.recognitionLanguages = ["zh-Hans", "en-US"]
        ocr.usesLanguageCorrection = true
        let classify = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([ocr, classify])

        var parts: [String] = []
        if let texts = ocr.results?.compactMap({ $0.topCandidates(1).first?.string }), !texts.isEmpty {
            parts.append(texts.joined(separator: " "))
        }
        if let labels = classify.results?.filter({ $0.confidence > 0.1 }).prefix(3).map({ $0.identifier }), !labels.isEmpty {
            parts.append("场景:" + labels.joined(separator: "、"))
        }
        let caption = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return caption.isEmpty ? nil : caption
    }

    /// 照片源**归属**(图片的绝对文件路径;非图片归文件源)。
    static func owns(_ path: String) -> Bool { path.hasPrefix("/") && LingShuKnowledgeIngest.isImagePath(path) }

    /// 扫描目录图片 → 归一成 `LingShuKnowledgeScan`(**增量:mtime 未变的不重新 OCR**——本机 Vision 的关键优化)。
    /// 路径用真实文件路径(可点开 + 删了能 fileExists 剪枝)。
    static func scan(folders: [String], limit: Int = 500, knownMtime: (String) -> Double?) -> LingShuKnowledgeScan {
        var scan = LingShuKnowledgeScan()
        var processed = 0
        for folder in folders.map({ ($0 as NSString).expandingTildeInPath }) {
            guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: folder),
                includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en where imageExtensions.contains(url.pathExtension.lowercased()) {
                if processed >= limit { return scan }
                let path = url.path
                let mtime = ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast).timeIntervalSince1970
                scan.seenPaths.insert(path)
                if knownMtime(path) == mtime { continue }   // 增量:这张没变,不重 OCR
                processed += 1
                guard let cap = caption(imageAt: url) else { continue }
                scan.changed.append(.init(path: path, mtime: mtime, text: cap))
            }
        }
        return scan
    }
}
