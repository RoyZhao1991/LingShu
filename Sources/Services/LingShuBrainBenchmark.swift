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
        case easy = 1, medium = 2, hard = 3, expert = 4
        var label: String { switch self { case .easy: "易"; case .medium: "中"; case .hard: "难"; case .expert: "极难" } }
    }

    /// 长链编码任务的**隐藏用例判分**(由 runner 跑真代码,不看回复、不靠 LLM 评分)。
    /// 模型把解写到 benchDir 里(prompt 用 `{DIR}` 占位,runner 替换成真路径);runner 跑 `harness` 隐藏用例,
    /// 输出含 `BENCH_PASS` 才算过。`preWrite` 预置文件(如待修 bug 的文件,用于"调试"题)。
    struct CodeCheck: Sendable {
        var preWrite: [String: String] = [:]   // relpath → content(任务开始前预置)
        var harness: String                    // python 隐藏用例:全过 print("BENCH_PASS")
    }

    struct Item: Sendable, Identifiable {
        let id: String
        let title: String
        let prompt: String
        let difficulty: Difficulty
        let agentic: Bool
        let maxTurns: Int
        let weight: Int                        // 计分权重(默认=难度;长链编码题显式给高权重,让分差由难题主导)
        let codeCheck: CodeCheck?              // 非 nil → runner 跑隐藏用例判分(忽略下面的 grade)
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
        item("a_bigmult", "工具·大数乘法", "用工具写脚本并运行,算出 123456789 × 987654321,把完整结果告诉我。必须真运行。", .hard, agentic: true, maxTurns: 14) { r, u in has(r, "121932631112635269") && u },

        // ===== 极难·长链编码(隐藏用例跑真代码判分;写得出但写错/写一半摆烂=0 分,照前沿差距)=====
        item("c_balanced", "编码·括号匹配", "用工具在 {DIR}/solution.py 写函数 is_balanced(s):判断字符串里的括号 ()[]{} 是否正确匹配且嵌套正确,返回 True/False(忽略非括号字符)。写完自己跑几个用例验证再回复。", .expert, agentic: true, maxTurns: 20, weight: 5,
             codeCheck: .init(harness: "import solution\ncs=[('',True),('()',True),('([{}])',True),('([)]',False),('(()',False),('}{',False),('a(b)c[d]',True),('(]',False)]\nprint('BENCH_PASS' if all(solution.is_balanced(s)==e for s,e in cs) else 'BENCH_FAIL')")),
        item("c_roman", "编码·罗马数字", "用工具在 {DIR}/solution.py 写函数 roman_to_int(s):把罗马数字字符串转整数,要支持减法记法(IV/IX/XL/XC/CD/CM)。自测后回复。", .expert, agentic: true, maxTurns: 20, weight: 5,
             codeCheck: .init(harness: "import solution\ncs=[('III',3),('IV',4),('IX',9),('LVIII',58),('MCMXCIV',1994),('XL',40),('XCIX',99)]\nprint('BENCH_PASS' if all(solution.roman_to_int(s)==e for s,e in cs) else 'BENCH_FAIL')")),
        item("c_calc", "编码·表达式求值", "用工具在 {DIR}/solution.py 写函数 calc(expr):对含非负整数、+ - * / 和小括号的算术表达式求值,遵守优先级,/ 用整数除法(向下取整),返回整数。自测含括号和优先级的用例。", .expert, agentic: true, maxTurns: 24, weight: 6,
             codeCheck: .init(harness: "import solution\ncs=[('2+3*4',14),('(2+3)*4',20),('10-2*3',4),('2*(3+4)-5',9),('100/3',33),('(1+2)*(3+4)',21)]\nprint('BENCH_PASS' if all(solution.calc(e)==v for e,v in cs) else 'BENCH_FAIL')")),
        item("c_debug", "编码·调试", "{DIR}/solution.py 里的函数 median(nums) 想算中位数但有 bug(偶数长度时不对)。用工具修复它,让奇偶长度都正确(偶数取中间两数平均)。自测确认。", .expert, agentic: true, maxTurns: 20, weight: 6,
             codeCheck: .init(preWrite: ["solution.py": "def median(nums):\n    s=sorted(nums); n=len(s); return s[n//2]\n"],
                              harness: "import solution\ncs=[([1,2,3],2),([1,2,3,4],2.5),([5],5),([4,1,3,2],2.5),([7,7,7],7)]\nprint('BENCH_PASS' if all(abs(solution.median(n)-v)<1e-9 for n,v in cs) else 'BENCH_FAIL')")),
        item("c_project", "编码·多文件工程", "用工具在 {DIR} 下分步真建文件真跑:① mathutils.py 含 gcd(a,b)、lcm(a,b);② stats.py(import mathutils)含 mean(nums) 返回浮点平均、median(nums) 返回中位数;③ test_all.py 用 assert 各测 2 个用例;④ 运行 test_all.py 确认全过。必须真建这 3 个文件并把测试跑到全过。", .expert, agentic: true, maxTurns: 30, weight: 8,
             codeCheck: .init(harness: "import mathutils, stats\nok=(mathutils.gcd(12,18)==6 and mathutils.lcm(4,6)==12 and abs(stats.mean([1,2,3,4])-2.5)<1e-9 and abs(stats.median([1,2,3])-2)<1e-9 and abs(stats.median([1,2,3,4])-2.5)<1e-9)\nprint('BENCH_PASS' if ok else 'BENCH_FAIL')")),

        // ===== 前沿·只有强脑能稳过的硬核题(LeetCode Hard 级,隐藏用例真验;高权重,差距在此显)=====
        item("f_regex", "前沿·正则匹配", "用工具在 {DIR}/solution.py 写函数 is_match(s, p):实现支持 '.'(匹配任意单字符)和 '*'(匹配前一字符 0 次或多次)的正则,p 必须**完整匹配**整个 s,返回 True/False。自测含 * 的用例。", .expert, agentic: true, maxTurns: 26, weight: 8,
             codeCheck: .init(harness: """
             import solution
             cs=[("aa","a",False),("aa","a*",True),("ab",".*",True),("aab","c*a*b",True),("mississippi","mis*is*p*.",False),("","",True),("a","",False),("","a*",True)]
             print("BENCH_PASS" if all(solution.is_match(s,p)==e for s,p,e in cs) else "BENCH_FAIL")
             """)),
        item("f_json", "前沿·手写JSON解析", "用工具在 {DIR}/solution.py 写函数 parse_json(s):**不要用 json 模块**,手写解析 JSON 字符串(对象/数组/字符串/整数/true/false/null/任意嵌套),返回对应 Python 对象(dict/list/str/int/bool/None)。自测嵌套用例。", .expert, agentic: true, maxTurns: 28, weight: 8,
             codeCheck: .init(harness: """
             import solution
             cs=[('{"a":1,"b":[2,3],"c":{"d":true}}', {"a":1,"b":[2,3],"c":{"d":True}}), ('[1,2,3]',[1,2,3]), ('{"x":null,"y":false}',{"x":None,"y":False}), ('{"name":"张三","age":28}',{"name":"张三","age":28}), ('42',42)]
             print("BENCH_PASS" if all(solution.parse_json(a)==b for a,b in cs) else "BENCH_FAIL")
             """)),
        item("f_nqueens", "前沿·N皇后", "用工具在 {DIR}/solution.py 写函数 nqueens(n):返回 n 皇后问题解的数量(n 个皇后放 n×n 棋盘、互不攻击)。自测 n=8 应为 92。", .expert, agentic: true, maxTurns: 24, weight: 8,
             codeCheck: .init(harness: "import solution\nprint('BENCH_PASS' if solution.nqueens(1)==1 and solution.nqueens(4)==2 and solution.nqueens(6)==4 and solution.nqueens(8)==92 else 'BENCH_FAIL')")),
        item("f_stradd", "前沿·大数字符串加法", "用工具在 {DIR}/solution.py 写函数 str_add(a, b):a、b 是十进制非负整数字符串,**不许转成 int 再加**,手工逐位相加处理进位,返回和的字符串。自测大数。", .expert, agentic: true, maxTurns: 24, weight: 8,
             codeCheck: .init(harness: """
             import solution
             cs=[("999","1","1000"),("123456789123456789","987654321987654321","1111111111111111110"),("0","0","0"),("1","9999999999","10000000000")]
             print("BENCH_PASS" if all(solution.str_add(a,b)==e for a,b,e in cs) else "BENCH_FAIL")
             """)),

        // ===== 生产/长任务(多需求·多文件·扩存量代码;隐藏用例**逐项打分**=部分给分,照真实生产能力,占最高权重)=====
        // 这层是关键:有界谜题强弱难分,**真实生产任务**才区分得开——做一半/漏需求会按比例丢分,弱脑在此现形。
        item("p_inventory", "生产·库存系统", "用工具在 {DIR}/inventory.py 写一个 Inventory 类(完整可用):add_item(name,qty,price)(同名累加数量、更新单价)、remove(name,qty)(数量不足要抛异常)、total_value()(库存总价值,保留2位)、low_stock(threshold)(返回数量<阈值的名字列表,升序)、save(path)/load(path)(JSON 持久化)。把它做完整、自测各方法。", .expert, agentic: true, maxTurns: 30, weight: 18,
             codeCheck: .init(harness: """
             import os; D=os.path.dirname(os.path.abspath(__file__))
             import inventory
             Inv=inventory.Inventory; p=0; t=0
             def ck(c):
                 global p,t; t+=1
                 try:
                     if c(): p+=1
                 except Exception: pass
             inv=Inv(); inv.add_item("a",10,2.0)
             ck(lambda: inv.total_value()==20.0)
             inv.add_item("a",5,2.0); ck(lambda: inv.total_value()==30.0)
             inv.remove("a",3); ck(lambda: inv.total_value()==24.0)
             def od():
                 try: inv.remove("a",999); return False
                 except Exception: return True
             ck(od)
             inv.add_item("b",1,5.0); ck(lambda: inv.low_stock(5)==["b"])
             inv.add_item("c",2,1.0); ck(lambda: inv.low_stock(3)==["b","c"])
             ck(lambda: round(inv.total_value(),2)==31.0)
             sp=os.path.join(D,"inv_saved.json"); inv.save(sp); ck(lambda: os.path.exists(sp))
             inv2=Inv(); inv2.load(sp); ck(lambda: inv2.total_value()==31.0)
             print(f"BENCH_SCORE {p} {t}")
             """)),
        item("p_extend", "生产·扩展存量代码", "{DIR}/library.py 已有一个 Library 类(add_book(title,author) / find_by_author(author))。用工具**在不破坏现有功能**的前提下扩展它:加 borrow(title)(借出,成功返 True;书不存在或已借出返 False)、return_book(title)(归还,成功 True 否则 False)、is_available(title)(在馆且未借出才 True)。自测,并确认 find_by_author 仍正常。", .expert, agentic: true, maxTurns: 28, weight: 14,
             codeCheck: .init(preWrite: ["library.py": "class Library:\n    def __init__(self): self.books=[]\n    def add_book(self, title, author): self.books.append({\"title\":title,\"author\":author})\n    def find_by_author(self, author): return [b[\"title\"] for b in self.books if b[\"author\"]==author]\n"],
                              harness: """
             import library
             L=library.Library; p=0;t=0
             def ck(c):
                 global p,t;t+=1
                 try:
                     if c(): p+=1
                 except Exception: pass
             lib=L(); lib.add_book("A","x"); lib.add_book("B","x"); lib.add_book("C","y")
             ck(lambda: sorted(lib.find_by_author("x"))==["A","B"])
             ck(lambda: lib.borrow("A")==True)
             ck(lambda: lib.borrow("A")==False)
             ck(lambda: lib.is_available("A")==False)
             ck(lambda: lib.is_available("B")==True)
             ck(lambda: lib.return_book("A")==True and lib.is_available("A")==True)
             ck(lambda: lib.borrow("ZZZ")==False)
             print(f"BENCH_SCORE {p} {t}")
             """)),
        item("p_pipeline", "生产·多需求数据流", "用工具在 {DIR}/pipeline.py 写函数 process(records)(records 是 dict 列表,字段 status/dept/salary):① 只保留 status=='active';② 按 dept 分组;③ 算每组 salary 平均(保留2位);④ **剔除人数<2 的组**;⑤ 返回 [{'dept','avg','count'}] 列表,按 avg 降序、avg 相同按 dept 升序。自测覆盖每条需求。", .expert, agentic: true, maxTurns: 26, weight: 14,
             codeCheck: .init(harness: """
             import pipeline
             process=pipeline.process; p=0;t=0
             def ck(c):
                 global p,t;t+=1
                 try:
                     if c(): p+=1
                 except Exception: pass
             recs=[{"status":"active","dept":"eng","salary":100},{"status":"active","dept":"eng","salary":200},{"status":"inactive","dept":"eng","salary":999},{"status":"active","dept":"sales","salary":150},{"status":"active","dept":"sales","salary":150},{"status":"active","dept":"solo","salary":500},{"status":"active","dept":"hr","salary":120},{"status":"active","dept":"hr","salary":120}]
             r=process(recs)
             ck(lambda: all(d["dept"]!="solo" for d in r))
             ck(lambda: next(d for d in r if d["dept"]=="eng")["avg"]==150.0)
             ck(lambda: next(d for d in r if d["dept"]=="sales")["avg"]==150.0)
             ck(lambda: [d["dept"] for d in r]==["eng","sales","hr"])
             ck(lambda: next(d for d in r if d["dept"]=="eng")["count"]==2)
             ck(lambda: len(r)==3)
             print(f"BENCH_SCORE {p} {t}")
             """))
    ]

    private static func item(_ id: String, _ title: String, _ prompt: String, _ difficulty: Difficulty,
                             agentic: Bool = false, maxTurns: Int = 2, weight: Int? = nil, codeCheck: CodeCheck? = nil,
                             _ grade: @escaping @Sendable (String, Bool) -> Bool = { _, _ in false }) -> Item {
        Item(id: id, title: title, prompt: prompt, difficulty: difficulty, agentic: agentic, maxTurns: maxTurns,
             weight: weight ?? difficulty.rawValue, codeCheck: codeCheck, grade: grade)
    }

    static var totalWeight: Int { items.reduce(0) { $0 + $1.weight } }

    /// 综合评分(0–100):通过题权重之和 / 总权重 × 100(全过/全不过的二元题用)。
    static func composite(passedIDs: Set<String>) -> Int {
        let earned = items.filter { passedIDs.contains($0.id) }.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return 0 }
        return Int((Double(earned) / Double(totalWeight) * 100).rounded())
    }

    /// **部分给分**综合评分:每题给一个完成度 fraction(0~1,生产/长任务按隐藏用例通过比例),
    /// 加权 = Σ(weight × fraction) / 总权重 × 100。这是真实评分入口(二元题 fraction=0 或 1)。
    static func compositeWeighted(_ fractions: [String: Double]) -> Int {
        let earned = items.reduce(0.0) { $0 + Double($1.weight) * max(0, min(1, fractions[$1.id] ?? 0)) }
        guard totalWeight > 0 else { return 0 }
        return Int((earned / Double(totalWeight) * 100).rounded())
    }

    /// 单一难度档的得分(加权 %)+ 全过题数 + 题数 + 该档总权重。用来**照出模型能力水位**:
    /// 易/中通常人人满分,真正拉开差距的是难/极难档——分档看才看得清不同脑卡在哪一层。
    struct TierScore: Equatable, Sendable, Codable {
        var label: String   // 易/中/难/极难
        var pct: Int        // 该档加权得分(0~100)
        var passed: Int     // 该档全过题数
        var total: Int      // 该档题数
        var weight: Int     // 该档总权重(占全局比重)
    }

    /// 按难度分档给分(让"难题分值高、看水位差异"显式化)。
    static func tierBreakdown(_ fractions: [String: Double]) -> [TierScore] {
        Difficulty.allCases.map { d in
            let its = items.filter { $0.difficulty == d }
            let w = its.reduce(0) { $0 + $1.weight }
            let earned = its.reduce(0.0) { $0 + Double($1.weight) * max(0, min(1, fractions[$1.id] ?? 0)) }
            let passed = its.filter { (fractions[$0.id] ?? 0) >= 0.999 }.count
            return TierScore(label: d.label, pct: w > 0 ? Int((earned / Double(w) * 100).rounded()) : 0,
                             passed: passed, total: its.count, weight: w)
        }
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
    var tiers: [LingShuBrainBenchmark.TierScore] = []   // 按难度档的水位拆解(易/中/难/极难)
    var ranAt: Date = Date()

    struct Row: Equatable, Sendable, Identifiable {
        var id: String { itemID }
        var itemID: String
        var title: String
        var difficulty: String
        var agentic: Bool
        var passed: Bool
        var scoreText: String = ""   // 部分给分题显示 "7/9";二元题空
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

    var snapshot: LingShuBrainBenchmarkSnapshot {
        .init(brainID: brainID, score: score, grade: grade, passed: passedCount, total: totalCount, tiers: tiers, ranAt: ranAt)
    }
}

/// 一次测评的**紧凑快照**(持久化用,不存逐题 rows):供「跨脑对比」——每颗测过的脑存一份,弹窗并排比各档水位。
struct LingShuBrainBenchmarkSnapshot: Codable, Equatable, Sendable, Identifiable {
    var id: String { brainID }
    var brainID: String
    var score: Int
    var grade: String
    var passed: Int
    var total: Int
    var tiers: [LingShuBrainBenchmark.TierScore]
    var ranAt: Date

    func tierPct(_ label: String) -> Int { tiers.first { $0.label == label }?.pct ?? 0 }
}
