import Foundation

/// 控制面调用**基线观测**的纯格式化/判定逻辑(第③站起用,后续 ④⑤⑥ 各控制面调用可复用)。
///
/// 只做「把观测到的原始数据 → 一行可读 trace 文案」和「JSON 脏净判定」这类纯计算,
/// **不产生任何副作用、不依赖 LingShuState**——副作用(appendTrace/计时)留在调用点。
/// 目的:让「归属解析/目标认知/缺口分析…」每一次控制面模型调用都**可观测**(走哪个当前主脑、多慢、载荷多大、结构脏不脏),
/// 用数据回答「这次调用值不值/该不该存在」,不靠猜。
enum LingShuControlPlaneBaseline {

    /// 一次控制面模型调用的可观测指标(全部由调用点就地测得后传入)。
    struct CallMetrics {
        let role: String            // 角色(分诊/目标认知…)
        let provider: String        // 实际落地的脑 provider
        let model: String           // 实际落地的脑 model
        let elapsedMs: Int          // 本次调用 wall-clock 耗时
        let payloadChars: Int       // 送进模型的载荷字符数(token 粗代理:没有 usage 回传时的替代量)
        let timeoutSeconds: Int     // 该角色的超时上限
    }

    /// 调用侧 trace 文案:回答抓手1「分诊落在哪档脑、多慢、载荷多大」。
    static func callDetail(_ m: CallMetrics) -> String {
        return "角色=\(m.role) · 当前主脑=\(m.provider)/\(m.model) · 耗时=\(m.elapsedMs)ms · 载荷≈\(m.payloadChars)字符(token粗代理) · 超时上限=\(m.timeoutSeconds)s"
    }

    /// **JSON 脏净判定(纯函数,可单测)**:回答抓手2「structured output 是保证出来的、还是清洗兜出来的」。
    /// 脏 = ① 清洗前后不一致(含 <think> 标签/推理前言,被 stripThinkTags 改动过)或
    ///      ② 清洗后仍不是纯 `{…}` 包裹(JSON 外还裹着解释文字)。
    static func isDirtyJSON(raw: String, cleaned: String) -> Bool {
        if raw != cleaned { return true }
        let t = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return !(t.hasPrefix("{") && t.hasSuffix("}"))
    }

    /// 输出侧 trace 文案:结构脏净 + 大脑自报置信 + 清洗后样本。
    static func outputDetail(raw: String, cleaned: String, jsonDirty: Bool, brainConfidence: String) -> String {
        let sample = cleaned.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)
        let note = jsonDirty
            ? "需 stripThinkTags/清洗才解析出结构(上 JSON mode 可根治)"
            : "模型直接吐了纯 JSON"
        return "JSON\(jsonDirty ? "脏" : "净"):\(note) · 大脑自报置信=\(brainConfidence) · 清洗后≈「\(sample)」"
    }

    /// **基线旁路(sentinel 文件门控,零生产开销)**:仅当开关文件
    /// `~/Library/Application Support/LingShu/.baseline-log-enabled` 存在时,把基线 trace 同时 append 到
    /// `triage-baseline.log`,供命令行持久观测——内存 trace 每回合会清、抓不全多样本,持久日志才能量分布/脏率。
    /// 开关文件不存在时仅一次 `fileExists` 检查即返回,不写任何东西(生产默认关)。不依赖 `#if DEBUG`
    /// (SwiftPM debug 构建默认不定义 DEBUG,会把整段编译掉)。
    nonisolated static func baselineLog(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LingShu", isDirectory: true)
        let sentinel = dir.appendingPathComponent(".baseline-log-enabled")
        guard FileManager.default.fileExists(atPath: sentinel.path) else { return }
        let url = dir.appendingPathComponent("triage-baseline.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "[\(stamp)] \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
