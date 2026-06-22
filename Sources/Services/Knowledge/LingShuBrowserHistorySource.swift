import Foundation
import SQLite3

/// 本机知识中枢·**浏览器历史源**(多源接入 ①):读 Safari / Chrome 本地历史(标题+URL+最近访问),
/// 索引进本机知识 → "我那天看的那篇关于X的文章" 能找回。全本地读取、零上传。
/// 隐私:读本机历史库(Safari 需「完全磁盘访问」);读不到(无权限/未装/锁)的源静默跳过。
/// db 先复制到临时只读副本再查(避开 Chrome 运行时锁/WAL),查完删。
struct LingShuBrowserHistoryEntry: Equatable, Sendable {
    let url: String
    let title: String
    let lastVisit: Double   // unix 秒
}

enum LingShuBrowserHistorySource {
    // —— epoch 转换(纯函数,可单测)——
    /// Safari visit_time = CFAbsoluteTime(2001-01-01 起的秒)→ unix 秒。
    static func safariUnixTime(_ cfAbsolute: Double) -> Double { cfAbsolute + 978_307_200 }
    /// Chrome last_visit_time = 1601-01-01 起的微秒 → unix 秒。
    static func chromeUnixTime(_ micros: Double) -> Double { micros / 1_000_000 - 11_644_473_600 }

    static var safariHistoryPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Safari/History.db")
    }
    static var chromeHistoryPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Google/Chrome/Default/History")
    }

    static let pathPrefix = "history://"
    static func owns(_ path: String) -> Bool { path.hasPrefix(pathPrefix) }

    /// 汇集 Safari + Chrome 历史(各取最近 limit 条)。
    static func collect(limit: Int = 2000) -> [LingShuBrowserHistoryEntry] {
        safari(dbPath: safariHistoryPath, limit: limit) + chrome(dbPath: chromeHistoryPath, limit: limit)
    }

    /// 扫描浏览历史 → 归一成 `LingShuKnowledgeScan`(增量:按 lastVisit 跳过未变)。
    static func scan(limit: Int = 2000, knownMtime: (String) -> Double?) -> LingShuKnowledgeScan {
        var scan = LingShuKnowledgeScan()
        for e in collect(limit: limit) {
            let path = pathPrefix + e.url
            scan.seenPaths.insert(path)
            if knownMtime(path) == e.lastVisit { continue }
            scan.changed.append(.init(path: path, mtime: e.lastVisit, text: "\(e.title)\n\(e.url)"))
        }
        return scan
    }

    static func safari(dbPath: String, limit: Int) -> [LingShuBrowserHistoryEntry] {
        let sql = """
        SELECT i.url AS url, v.title AS title, MAX(v.visit_time) AS vt
        FROM history_visits v JOIN history_items i ON v.history_item = i.id
        GROUP BY i.url ORDER BY vt DESC LIMIT \(max(1, limit))
        """
        return readRows(dbPath: dbPath, sql: sql).compactMap { row in
            guard let url = row["url"] as? String, !url.isEmpty else { return nil }
            return .init(url: url, title: (row["title"] as? String) ?? "", lastVisit: safariUnixTime((row["vt"] as? Double) ?? 0))
        }
    }

    static func chrome(dbPath: String, limit: Int) -> [LingShuBrowserHistoryEntry] {
        let sql = "SELECT url, title, last_visit_time AS vt FROM urls ORDER BY last_visit_time DESC LIMIT \(max(1, limit))"
        return readRows(dbPath: dbPath, sql: sql).compactMap { row in
            guard let url = row["url"] as? String, !url.isEmpty else { return nil }
            return .init(url: url, title: (row["title"] as? String) ?? "", lastVisit: chromeUnixTime((row["vt"] as? Double) ?? 0))
        }
    }

    /// 复制 db 到临时只读副本再查(纯读、避锁)。任何失败(不存在/无权限/格式)→ []。
    static func readRows(dbPath: String, sql: String) -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
        let tmp = NSTemporaryDirectory() + "lk-hist-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        guard (try? FileManager.default.copyItem(atPath: dbPath, toPath: tmp)) != nil else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var rows: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for col in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, col))
                switch sqlite3_column_type(stmt, col) {
                case SQLITE_TEXT: if let c = sqlite3_column_text(stmt, col) { row[name] = String(cString: c) }
                case SQLITE_INTEGER: row[name] = Double(sqlite3_column_int64(stmt, col))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, col)
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }
}
