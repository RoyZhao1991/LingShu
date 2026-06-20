import Foundation

/// 内置「脑力测试」题库(硬编码,37 题,难度/复杂度全谱)+ 确定性判分 + 难度加权综合分。纯逻辑可单测。
///
/// **设计目标:照出大脑真实差距,不是给满分**。所以题库:
/// - 不只考单轮原子问答(弱脑也会、区分不出),还含**多步 agentic 工具任务**(必须真驱动工具循环,口算/摆烂不算)。
/// - 故意塞进一批**已知 LLM 高失误题**(9.11 vs 9.9、strawberry 里几个 r、认知反射陷阱、三段论有效性、超大数计算…),
///   这些连不少强模型也会翻车——能拉开分差。
/// 判分签名 `(reply, usedTools)`:reasoning 题只看回复;agentic 题要求"答案对 **且** 真调过工具"。
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
        let agentic: Bool
        let maxTurns: Int
        let grade: @Sendable (_ reply: String, _ usedTools: Bool) -> Bool
    }

    /// 归一:小写 + 去空白/常见标点(**保留数字与字母**),便于稳健子串判分。
    static func normalize(_ s: String) -> String {
        let drop = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，。、；：！？,.;:!?\"'`*#·（）()【】[]"))
        return String(s.lowercased().unicodeScalars.filter { !drop.contains($0) })
    }
    private static func has(_ r: String, _ n: String) -> Bool { normalize(r).contains(normalize(n)) }
    private static func hasRaw(_ r: String, _ n: String) -> Bool { r.lowercased().contains(n.lowercased()) }  // 保留小数点,用于 9.9 / 0.05 / 7.5
    private static func firstJSONObject(_ reply: String) -> [String: Any]? {
        guard let s = reply.firstIndex(of: "{"), let e = reply.lastIndex(of: "}"), s < e,
              let data = String(reply[s...e]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static let items: [Item] = [
        // ===== 易(7,权重1)·常识/基础算术 =====
        item("e_arith", "算术", "67 加 48 等于多少?只回答数字。", .easy) { r, _ in has(r, "115") },
        item("e_chem", "常识", "水的化学分子式是什么?", .easy) { r, _ in has(r, "h2o") || r.contains("H₂O") },
        item("e_capital", "常识", "中国的首都是哪个城市?", .easy) { r, _ in has(r, "北京") },
        item("e_apple", "翻译", "‘苹果’用英语怎么说?只回答单词。", .easy) { r, _ in hasRaw(r, "apple") },
        item("e_months", "常识", "一年有几个月?只回答数字。", .easy) { r, _ in has(r, "12") },
        item("e_sunrise", "常识", "太阳从哪个方向升起?只回答一个字。", .easy) { r, _ in has(r, "东") },
        item("e_square", "算术", "3 的平方是多少?只回答数字。", .easy) { r, _ in has(r, "9") },

        // ===== 中(15,权重2)·推理/计数/格式/已知失误题 =====
        item("m_animals", "鸡兔同笼", "笼子里鸡和兔共 8 只、共 22 条腿,鸡有几只?只回答数字。", .medium) { r, _ in has(r, "5") && !has(r, "3只") },
        item("m_weekday", "日期推理", "今天星期三,再过 10 天是星期几?只回答星期几。", .medium) { r, _ in has(r, "六") },
        item("m_race", "排名推理", "甲乙丙赛跑,丙是第二名,甲不是第一名。谁是第一名?只回答一个字。", .medium) { r, _ in
            has(r, "乙") && !has(r, "甲是第一") && !has(r, "丙是第一")
        },
        item("m_batball", "认知反射", "一个球拍和一个球共 1.10 元,球拍比球贵 1.00 元。球多少钱?只回答金额。", .medium) { r, _ in
            hasRaw(r, "0.05") || has(r, "5分") || has(r, "五分")
        },
        item("m_decimal", "数值比较", "9.11 和 9.9,哪个数更大?用‘前者’或‘后者’回答。", .medium) { r, _ in has(r, "后者") && !has(r, "前者") },
        item("m_strawberry", "字母计数", "英文单词 strawberry 里有几个字母 r?只回答数字。", .medium) { r, _ in has(r, "3") && !has(r, "13") && !has(r, "23") },
        item("m_machines", "认知反射", "5 台机器 5 分钟生产 5 个零件,那么 100 台机器生产 100 个零件需要几分钟?只回答数字。", .medium) { r, _ in
            has(r, "5") && !has(r, "100")
        },
        item("m_relative", "亲属推理", "我父亲唯一的弟弟的儿子,是我的什么亲戚?(如 堂哥/表弟…)只回答关系。", .medium) { r, _ in has(r, "堂") },
        item("m_gcd", "数学", "12 和 18 的最大公约数是多少?只回答数字。", .medium) { r, _ in has(r, "6") && !has(r, "36") },
        item("m_area", "几何", "一个长方形长 8、宽 3,面积是多少?只回答数字。", .medium) { r, _ in has(r, "24") },
        item("m_palindrome", "字符串", "单词 level 是回文吗?只回答‘是’或‘否’。", .medium) { r, _ in has(r, "是") && !has(r, "否") && !has(r, "不是") },
        item("m_sort", "排序", "把数字 3,1,4,1,5,9,2,6 从大到小排序,直接给排好的序列。", .medium) { r, _ in has(r, "96543211") },
        item("m_charcount", "计数", "句子‘我爱北京天安门’有几个汉字?只回答数字。", .medium) { r, _ in has(r, "7") },
        item("m_roman", "进制", "罗马数字 XIV 代表的整数是多少?只回答数字。", .medium) { r, _ in has(r, "14") },
        item("m_json", "结构化输出", "把‘张三, 28, 工程师’转成 JSON,字段 name/age/job,age 用数字。只输出 JSON。", .medium) { r, _ in
            guard let o = firstJSONObject(r) else { return false }
            let name = (o["name"] as? String) ?? "", job = (o["job"] as? String) ?? ""
            let ageOK = (o["age"] as? Int == 28) || (o["age"] as? String == "28") || (o["age"] as? Double == 28)
            return name.contains("张三") && job.contains("工程师") && ageOK
        },

        // ===== 难(10,权重3)·多步推理/心算/经典难题 =====
        item("h_lilypad", "认知反射", "湖里荷叶每天数量翻倍,第 48 天恰好铺满整个湖。那么铺满半个湖是第几天?只回答数字。", .hard) { r, _ in has(r, "47") },
        item("h_tallest", "传递推理", "甲乙丙丁比身高:甲比乙高,丙比丁高,乙比丙高。谁最高?只回答一个字。", .hard) { r, _ in has(r, "甲") && !has(r, "丁") },
        item("h_mult", "心算", "17 乘以 23 等于多少?只回答数字。", .hard) { r, _ in has(r, "391") },
        item("h_syllogism", "逻辑有效性", "判断这个推理是否有效:‘所有玫瑰都是花;有些花会很快凋谢;所以有些玫瑰会很快凋谢。’只回答‘有效’或‘无效’。", .hard) { r, _ in has(r, "无效") },
        item("h_equation", "方程", "一个数加上它自己的一半等于 15,这个数是多少?只回答数字。", .hard) { r, _ in has(r, "10") && !has(r, "100") },
        item("h_clock", "几何", "时钟显示 3 点 15 分时,时针和分针的夹角是多少度?只回答数字。", .hard) { r, _ in hasRaw(r, "7.5") },
        item("h_prime10", "数论", "从小到大数,第 10 个质数是多少?只回答数字。", .hard) { r, _ in has(r, "29") },
        item("h_percent", "百分比", "一件商品先涨价 20%,再降价 20%,最终价格是原价的百分之几?只回答数字。", .hard) { r, _ in has(r, "96") },
        item("h_reverse", "字符串", "把字符串 DeepSeek 的字母顺序整个倒过来,只回答倒过来的字符串。", .hard) { r, _ in hasRaw(r, "keespeed") },
        item("h_river", "经典难题", "农夫要带狼、羊、菜过河,船每次只能带一样;没人看着时狼吃羊、羊吃菜。最少要渡河几次(单程算一次)?只回答数字。", .hard) { r, _ in has(r, "7") && !has(r, "3次") && !has(r, "5次") },

        // ===== agentic(5,权重3)·必须真驱动工具循环(口算/摆烂不算;后两题数太大必须真运行)=====
        item("a_sum", "工具·求和", "用工具**真写脚本并运行**算出 1 到 1000 的整数和,把运行结果告诉我。必须真运行,别口算。", .hard, agentic: true, maxTurns: 14) { r, u in has(r, "500500") && u },
        item("a_primes", "工具·质数计数", "用工具**写脚本并运行**,统计 100 以内(含)质数有几个,把运行结果告诉我。必须真运行。", .hard, agentic: true, maxTurns: 14) { r, u in has(r, "25") && u },
        item("a_multistep", "工具·多步", "分步用工具:① 先写一个文件,每行一个数,内容 1 到 20;② 再写脚本读它求和并运行;③ 把求和结果告诉我。必须真建文件真运行。", .hard, agentic: true, maxTurns: 18) { r, u in has(r, "210") && u },
        item("a_factorial", "工具·大数阶乘", "用工具写脚本并运行,算出 20 的阶乘(20!),把完整结果数值告诉我。这个数很大,必须真运行、别口算。", .hard, agentic: true, maxTurns: 14) { r, u in has(r, "2432902008176640000") && u },
        item("a_bigmult", "工具·大数乘法", "用工具写脚本并运行,算出 123456789 × 987654321,把完整结果告诉我。必须真运行。", .hard, agentic: true, maxTurns: 14) { r, u in has(r, "121932631112635269") && u }
    ]

    private static func item(_ id: String, _ title: String, _ prompt: String, _ difficulty: Difficulty,
                             agentic: Bool = false, maxTurns: Int = 2,
                             _ grade: @escaping @Sendable (String, Bool) -> Bool) -> Item {
        Item(id: id, title: title, prompt: prompt, difficulty: difficulty, agentic: agentic, maxTurns: maxTurns, grade: grade)
    }

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
    var score: Int
    var passedCount: Int
    var totalCount: Int
    var rows: [Row]
    var ranAt: Date = Date()

    struct Row: Equatable, Sendable, Identifiable {
        var id: String { itemID }
        var itemID: String
        var title: String
        var difficulty: String
        var agentic: Bool
        var passed: Bool
        var replyExcerpt: String
    }

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
