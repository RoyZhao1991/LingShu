import Foundation

/// # 知识纪律(陈述非祈使)—— 纯逻辑可单测
///
/// 给大脑的知识必须是**陈述性事实/教训**(它推理时参考、自己拍板),不是**祈使性框架/步骤**(替它定步骤)。
/// 这道闸是"知识不退化成框架"的保证(见 `Docs/能力分层与知识驱动架构方案.md` §3.3):
/// 落库前过一道——命中祈使/步骤特征就拒(让大脑改写成事实再入);召回措辞永远"供参考"。
///
/// 判据(通用、零领域关键词):
/// - ❌ 祈使/步骤:有序步骤("第N步/步骤N"、多条行首编号项)、动作链("先X再/然后/接着Y")、
///   条件式操作规程("…时,先…")、直接命令(句首"请/务必/记得/你要…")。
/// - ✅ 陈述:事实("CozyLife 灯走 TCP 5555")、教训("写指南文档≠真接入")、偏好、结论。
///   教训虽含劝诫意味,但陈述的是**事实判断**(X≠Y / X 独占),不是**让大脑照做的步骤**,准入。
///
/// 偏置:**宁可错拒一条边界事实(大脑可改写重入),也不放过一条步骤污染知识库成框架**——这正是本方案要根治的。
enum LingShuKnowledgeDiscipline {

    /// 召回时固定免责措辞——知识永远是"参考",绝不写成规则/必须。
    static let recallDisclaimer = "相关知识·供参考,自行判断是否适用"

    enum Verdict: Equatable, Sendable {
        case declarative                  // 陈述事实/教训 → 准入
        case imperative(reason: String)   // 祈使/步骤 → 拒(让大脑改写成事实)
    }

    /// 是否陈述性(准入)。
    static func isDeclarative(_ body: String) -> Bool {
        if case .declarative = classify(body) { return true }
        return false
    }

    static func classify(_ body: String) -> Verdict {
        let s = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .declarative }   // 空交给其它护栏处理

        // 1) 有序步骤:中文"第N步/步骤N",或 ≥2 条行首数字编号项("1. …""2)…")。
        if s.range(of: "第[一二三四五六七八九十0-9]+步", options: .regularExpression) != nil
            || s.range(of: "步骤[一二三四五六七八九十0-9]", options: .regularExpression) != nil {
            return .imperative(reason: "含有序步骤(第N步/步骤N),是替大脑定的操作规程")
        }
        let numberedItems = s.components(separatedBy: .newlines).filter {
            $0.trimmingCharacters(in: .whitespaces)
                .range(of: "^[1-9][.).、]\\s*\\S", options: .regularExpression) != nil
        }
        if numberedItems.count >= 2 {
            return .imperative(reason: "含多条编号操作项,是步骤清单(框架),不是事实")
        }

        // 2) 动作链:"先…(再|然后|接着|之后|最后)…"——经典"先X再Y"流程。
        // **窗口约束**:必须是同一小句内 先→再 的真实先后,避免"预先/首先/优先"碰巧与"再次/不再"共现的误判
        // (如"…再逐类浏览…不必预先写死…"是事实,不是步骤)。
        if s.range(of: "先[^。;!?\\n]{1,16}(再|然后|接着|之后|最后)", options: .regularExpression) != nil {
            return .imperative(reason: "含\"先…再/然后…\"动作链,是步骤而非事实")
        }
        // 3) 条件式操作规程:"…时,先…" / "…时先…"。
        if s.range(of: "时[,，]?先", options: .regularExpression) != nil {
            return .imperative(reason: "含\"…时先…\"条件操作规程(替大脑定步骤)")
        }
        // 4) 直接命令(祈使语气,对大脑下令):句首的强祈使词。
        let directives = ["请", "务必", "记得", "切记", "你需要", "你应当", "你应该", "你要"]
        if directives.contains(where: { s.hasPrefix($0) }) {
            return .imperative(reason: "祈使语气(命令大脑照做),知识应改写成事实陈述")
        }
        return .declarative
    }
}
