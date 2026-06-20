import Foundation

/// 内置「脑力测试」题库(硬编码,难度不等)+ 确定性判分 + 综合评分。纯逻辑可单测。
///
/// 跑法:每道题把 `prompt` 发给当前脑,拿回复用 `grade(reply)` 确定性判对错;
/// 综合分 = 通过题的难度权重 / 总权重 × 100(易=1/中=2/难=3)。换脑后重跑即测新脑。
enum LingShuBrainBenchmark {

    enum Difficulty: Int, Codable, Sendable, CaseIterable {
        case easy = 1, medium = 2, hard = 3
        var label: String { switch self { case .easy: "易"; case .medium: "中"; case .hard: "难" } }
    }

    struct Item: Sendable, Identifiable {
        let id: String
        let title: String
        let prompt: String
        let difficulty: Difficulty
        let grade: @Sendable (_ reply: String) -> Bool
    }

    /// 归一:小写 + 去空白/常见标点,便于稳健子串判分(抗措辞/格式波动)。
    static func normalize(_ s: String) -> String {
        let drop = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，。、；：！？,.;:!?\"'`*#·（）()【】[]"))
        return String(s.lowercased().unicodeScalars.filter { !drop.contains($0) })
    }
    private static func has(_ reply: String, _ needle: String) -> Bool { normalize(reply).contains(normalize(needle)) }

    /// 抽回复里第一个 JSON 对象并解析(供结构化题判分)。
    private static func firstJSONObject(_ reply: String) -> [String: Any]? {
        guard let s = reply.firstIndex(of: "{"), let e = reply.lastIndex(of: "}"), s < e,
              let data = String(reply[s...e]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// 硬编码题库(8 题:3 易 / 3 中 / 2 难,总权重 15)。
    static let items: [Item] = [
        Item(id: "e_arith", title: "算术", prompt: "67 加 48 等于多少?只回答数字。", difficulty: .easy) { has($0, "115") },
        Item(id: "e_chem", title: "常识", prompt: "水的化学分子式是什么?", difficulty: .easy) { has($0, "h2o") || $0.contains("H₂O") },
        Item(id: "e_instr", title: "指令遵循", prompt: "请只回复两个字:收到。", difficulty: .easy) {
            let n = normalize($0); return n.contains("收到") && n.count <= 8   // 短=遵循了"只回两个字"
        },
        Item(id: "m_animals", title: "鸡兔同笼", prompt: "笼子里鸡和兔共 8 只、共 22 条腿,鸡有几只?只回答数字。", difficulty: .medium) {
            let n = normalize($0); return n.contains("5") && !n.contains("3只")   // 鸡=5(兔=3)
        },
        Item(id: "m_weekday", title: "日期推理", prompt: "今天星期三,再过 10 天是星期几?只回答星期几。", difficulty: .medium) {
            has($0, "星期六") || has($0, "周六") || { let n = normalize($0); return n.contains("六") }($0)
        },
        Item(id: "m_json", title: "结构化输出", prompt: "把'张三, 28, 工程师'转成 JSON,字段 name/age/job,age 用数字。只输出 JSON。", difficulty: .medium) { reply in
            guard let o = firstJSONObject(reply) else { return false }
            let name = (o["name"] as? String) ?? ""
            let job = (o["job"] as? String) ?? ""
            let ageOK = (o["age"] as? Int == 28) || (o["age"] as? String == "28") || (o["age"] as? Double == 28)
            return name.contains("张三") && job.contains("工程师") && ageOK
        },
        Item(id: "h_logic", title: "逻辑推理", prompt: "甲乙丙赛跑,丙是第二名,甲不是第一名。谁是第一名?只回答一个字(甲/乙/丙)。", difficulty: .hard) {
            let n = normalize($0); return n.contains("乙") && !n.contains("甲是第一") && !n.contains("丙是第一")
        },
        Item(id: "h_sum", title: "计算", prompt: "1 到 100 里所有 3 的倍数之和是多少?只回答数字。", difficulty: .hard) { has($0, "1683") }
    ]

    static var totalWeight: Int { items.reduce(0) { $0 + $1.difficulty.rawValue } }

    /// 综合评分(0–100):通过题难度权重之和 / 总权重 × 100。
    static func composite(passedIDs: Set<String>) -> Int {
        let earned = items.filter { passedIDs.contains($0.id) }.reduce(0) { $0 + $1.difficulty.rawValue }
        guard totalWeight > 0 else { return 0 }
        return Int((Double(earned) / Double(totalWeight) * 100).rounded())
    }
}

/// 一次脑力测评的结果(供弹窗 + 持久/上报)。
struct LingShuBrainBenchmarkResult: Identifiable, Equatable, Sendable {
    let id = UUID()
    var brainID: String
    var score: Int                 // 综合分 0–100
    var passedCount: Int
    var totalCount: Int
    var rows: [Row]
    var ranAt: Date = Date()

    struct Row: Equatable, Sendable, Identifiable {
        var id: String { itemID }
        var itemID: String
        var title: String
        var difficulty: String     // 易/中/难
        var passed: Bool
        var replyExcerpt: String
    }

    /// 评级(给弹窗一个直观档位)。
    var grade: String {
        switch score {
        case 90...: "卓越"
        case 75..<90: "优秀"
        case 60..<75: "良好"
        case 40..<60: "及格"
        default: "偏弱"
        }
    }
}
