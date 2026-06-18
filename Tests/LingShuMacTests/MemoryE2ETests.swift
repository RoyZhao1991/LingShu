import XCTest
@testable import LingShuMac

/// 端到端证明:记忆 v2 走的是 **app 真实代码路径**(dreaming 的解析函数 → 真实门面 remember → 真实落盘 →
/// 模拟重启恢复 → recall_memory 调用的同一 recallText → 园丁 tend),不是孤立 demo。
/// 用固定目录 /tmp/lingshu-memory-e2e,跑完**不清理**,便于人工 `cat` 看真实产物。
@MainActor
final class MemoryE2ETests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/lingshu-memory-e2e")

    override func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: root)   // 每次干净起跑
    }

    func testFullPipelineProvesUpgradeLive() throws {
        // ① 模拟一轮对话后,大脑(dreaming)抽取出的原子事实——这是 dreaming 真实喂给解析器的输出格式(带代码块/前后缀)。
        let modelOutput = """
        好的,我从对话里抽取到这些值得长期记住的事实:
        ```json
        [
          {"kind":"person","title":"Roy Zhao","aliases":["主人","灵枢"],"body":"灵枢的作者,要求始终用中文回复","source":"user-explicit","confidence":0.97,"sensitive":false},
          {"kind":"preference","title":"语音打断偏好","body":"灵枢说话时喊灵枢要能实时打断","source":"user-explicit","confidence":0.9},
          {"kind":"fact","title":"所在城市","body":"北京","source":"user-explicit","confidence":0.85},
          {"kind":"decision","title":"记忆系统升级","body":"采用 Obsidian 化原子笔记知识图谱(记忆 v2)","source":"user-explicit","confidence":0.95},
          {"kind":"fact","title":"身份证号","body":"110xxx","source":"inference","confidence":0.9,"sensitive":true}
        ]
        ```
        """

        // ② 真实解析(= dreaming 里用的 LingShuState.parseKnowledgeCandidates)
        let candidates = LingShuState.parseKnowledgeCandidates(modelOutput)
        XCTAssertEqual(candidates.count, 5, "解析出 5 条候选(含 1 条敏感)")

        // ③ 真实门面并入(= app 用的同一对象/方法);敏感那条应被园丁护栏拒入。
        let kg = LingShuKnowledgeGraph(root: root)
        for candidate in candidates { kg.remember(candidate) }
        XCTAssertEqual(kg.count, 4, "敏感(身份证)被隐私红线拒入,只入 4 条")

        // ④ 模拟 AEC 坏时把"灵枢"误听成"林叔"的污染:再并一条 person「林叔」→ 应靠读音归并到 Roy,不新增 person。
        kg.remember(.init(kind: .person, title: "林叔", body: "主人", source: .inference, confidence: 0.4))
        XCTAssertEqual(kg.count, 4, "同音污染被归并,不产生第二个 person(根治记错名)")

        // ⑤ 模拟 app 重启:全新门面从磁盘恢复(证明真落盘 + 跨重启持久)。
        let reopened = LingShuKnowledgeGraph(root: root)
        XCTAssertEqual(reopened.count, 4, "跨重启从 .md 文件恢复")

        // ⑥ 真实召回(= recall_memory 工具 / recallMemoryText 调用的同一 recallText)。
        let recalled = reopened.recallText("主人是谁,在哪个城市,记忆怎么升级的") ?? ""
        XCTAssertTrue(recalled.contains("Roy Zhao"), "召回到主人")
        XCTAssertTrue(recalled.contains("北京"), "召回到城市")
        XCTAssertTrue(recalled.contains("记忆 v2") || recalled.contains("知识图谱"), "召回到升级决定")
        XCTAssertFalse(recalled.contains("110xxx"), "敏感内容绝不出现在召回里")

        // ⑦ 园丁维护(= dreaming 调的同一 tend:衰减/补链/剪枝)。
        let change = reopened.tend()

        // ⑧ 语义召回演示(M1):用**无关键词重叠的换种说法**查,验证靠本地句向量(NLEmbedding)也能召回到。
        //    NLEmbedding 不可用则退化(关键词+图),不在此硬断言,只作为真实演示写进证据文件。
        let paraphrase = "这台电脑现在搁在哪个地方"   // 与「所在城市/北京」无字面重叠
        let semantic = reopened.recall(paraphrase).map { "- [\($0.kind.rawValue)] \($0.title):\($0.body)" }.joined(separator: "\n")
        let embeddingAvailable = LingShuLocalTextEmbedding().vectorWithLanguage(for: "测试") != nil

        // ⑨ 落证据文件:把召回结果 + 语义召回演示 + 维护结论写盘,供人工核对真实产物。
        let evidence = """
        【精确/关键词召回:主人是谁,在哪个城市,记忆怎么升级的】
        \(recalled)

        【语义召回演示(换种说法,无关键词重叠):\(paraphrase)】
        本机 NLEmbedding 句向量:\(embeddingAvailable ? "可用" : "不可用(退化为关键词+图)")
        \(semantic.isEmpty ? "(无命中)" : semantic)

        【园丁维护】\(change)
        """
        try? evidence.data(using: .utf8)?.write(to: root.appendingPathComponent("_demo_recall.txt"))
    }

    /// M3「子→主」:子任务完成的知识蒸馏进**常驻** vault,子线程结束后主线程仍能召回到。
    func testSubtaskKnowledgePromotedThenRecalledFromMain() {
        // 子任务完成 → promoteSubtaskKnowledge 走的同一 remember 路径(decision/tool 来源)。
        let kg = LingShuKnowledgeGraph(root: root)
        kg.remember(.init(kind: .decision, title: "做清分结算系统的PPT",
                          body: "已产出 10 页,覆盖对账与清分流程,落在工作目录", source: .tool, confidence: 0.7))
        // 模拟子线程早已结束、主线程(新实例)事后召回。
        let mainLater = LingShuKnowledgeGraph(root: root)
        let recalled = mainLater.recallText("之前那个清分的演示做了啥") ?? ""
        XCTAssertTrue(recalled.contains("清分") || recalled.contains("对账"), "子任务知识应能从常驻主脑召回(子→主未丢)")
    }
}

/// 前缀缓存累计命中率指标单测。
final class PrefixCacheMeterTests: XCTestCase {
    func testCumulativeHitRate() {
        let meter = LingShuPrefixCacheMeter()
        _ = meter.record(prompt: 1000, cached: 800)
        let snap = meter.record(prompt: 1000, cached: 600)
        XCTAssertEqual(snap.calls, 2)
        XCTAssertEqual(snap.totalPrompt, 2000)
        XCTAssertEqual(snap.totalCached, 1400)
        XCTAssertEqual(snap.ratePercent, 70, "累计 1400/2000 = 70%")
    }

    func testZeroPromptIgnored() {
        let meter = LingShuPrefixCacheMeter()
        let snap = meter.record(prompt: 0, cached: 0)
        XCTAssertEqual(snap.calls, 0, "无效(0 prompt)不计入")
    }
}
