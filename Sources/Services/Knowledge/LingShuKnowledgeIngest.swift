import Foundation

/// 本机知识·**统一增量入库管线**(通用,所有源共用,知识模块内)。
///
/// 通用化"源增量化":任何源(文件/日历/邮件/照片/浏览历史/未来的…)都把本次扫描归一成 `Scan`
/// (changed=需重索引的项 + seenPaths=本次该源确实存在的全部条目),交给同一个 `ingest`:
/// ① upsert 变化项 ② 按 `owns` 只剪枝"本源管辖、本次没出现、且确实不在了"的条目(不误删别源)。
/// **每源只需:用 `knownMtime` 跳过未变(省掉重复解析/OCR)+ 声明 owns/stillExists**,不再各写一套入库/剪枝。
struct LingShuKnowledgeItem: Sendable, Equatable {
    let path: String      // 唯一定位:文件绝对路径 / calendar:// / mail:// / history://
    let mtime: Double
    let text: String
}

/// 一次源扫描的归一结果。
struct LingShuKnowledgeScan: Sendable {
    var changed: [LingShuKnowledgeItem] = []   // 新增/变化(mtime 变)的项,需(重)索引
    var seenPaths: Set<String> = []            // 本次该源确实存在的全部条目路径(供剪枝)
}

enum LingShuKnowledgeIngest {
    struct Stats: Equatable { var indexed = 0; var removed = 0; var seen = 0 }

    /// 通用增量入库。`owns` 判某已存路径是否归本源(剪枝只动本源);`stillExists` 已存路径是否仍真实存在
    /// (文件/照片源传 fileExists,防目录临时不可达误删;合成源默认 false=本次没出现即视作已删)。
    @discardableResult
    static func ingest(_ scan: LingShuKnowledgeScan,
                       owns: (String) -> Bool,
                       stillExists: (String) -> Bool = { _ in false },
                       into index: LingShuFileKnowledgeIndex) -> Stats {
        var stats = Stats()
        stats.seen = scan.seenPaths.count
        for item in scan.changed {
            index.upsertFile(path: item.path, mtime: item.mtime, text: item.text)
            stats.indexed += 1
        }
        for path in index.indexedPaths() where owns(path) && !scan.seenPaths.contains(path) && !stillExists(path) {
            index.removeFile(path: path)
            stats.removed += 1
        }
        return stats
    }

    /// 文件/照片源共用的图片扩展名判定(数据,非控制分支),用于把 "/…" 路径在文件源与照片源间划清归属。
    static func isImagePath(_ path: String) -> Bool {
        LingShuPhotoSource.imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }
}
