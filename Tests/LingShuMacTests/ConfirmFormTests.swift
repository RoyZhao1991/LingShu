import XCTest
@testable import LingShuMac

/// 多项确认表单纯逻辑守卫(用户定调:多事项→多字段表单,每字段选择菜单 + 末行"其他自行输入")。
final class ConfirmFormTests: XCTestCase {

    func testParseMultiFieldForm() {
        let json = """
        {"title":"确认外卖事项","fields":[
          {"key":"city","question":"你在哪个城市?","options":["北京","上海"]},
          {"key":"pay","question":"支付方式?","options":["支付宝","微信","银行卡"]},
          {"key":"health","question":"健康标准?","options":["低卡","高蛋白"]}
        ]}
        """
        let form = LingShuConfirmForm.parse(json)
        XCTAssertEqual(form?.title, "确认外卖事项")
        XCTAssertEqual(form?.fields.count, 3)
        XCTAssertEqual(form?.fields[1].key, "pay")
        XCTAssertEqual(form?.fields[1].options, ["支付宝", "微信", "银行卡"])
    }

    func testParseAliasesAndDefaults() {
        // 别名:items/label/choices;缺 key 自动补;缺 title 给默认。
        let json = """
        {"items":[{"label":"预算?","choices":["20内","40内"]},{"key":"k2","question":"忌口?"}]}
        """
        let form = LingShuConfirmForm.parse(json)
        XCTAssertEqual(form?.fields.count, 2)
        XCTAssertFalse(form?.title.isEmpty ?? true)
        XCTAssertEqual(form?.fields[0].question, "预算?")
        XCTAssertEqual(form?.fields[0].options, ["20内", "40内"])
        XCTAssertTrue(form?.fields[1].options.isEmpty ?? false, "无 options 字段=纯自由输入")
    }

    func testSanitizedDropsEmptyQuestion() {
        let json = "{\"fields\":[{\"key\":\"a\",\"question\":\"\"},{\"key\":\"b\",\"question\":\"问\"}]}"
        let form = LingShuConfirmForm.parse(json)
        XCTAssertEqual(form?.fields.count, 1)
        XCTAssertEqual(form?.fields.first?.key, "b")
    }

    func testParseRejectsNoFields() {
        XCTAssertNil(LingShuConfirmForm.parse("{\"fields\":[]}"))
        XCTAssertNil(LingShuConfirmForm.parse("not json"))
    }

    func testFormatAnswersListsEachFieldInOrder() {
        let form = LingShuConfirmForm(title: "t", fields: [
            .init(key: "city", question: "城市?", options: []),
            .init(key: "pay", question: "支付?", options: []),
        ])
        let out = form.formatAnswers(["city": "深圳", "pay": "微信"])
        XCTAssertTrue(out.contains("城市? → 深圳"))
        XCTAssertTrue(out.contains("支付? → 微信"))
        // 顺序按 fields:城市在支付之前。
        XCTAssertLessThan(out.range(of: "城市")!.lowerBound, out.range(of: "支付")!.lowerBound)
    }

    func testFormatAnswersMarksMissing() {
        let form = LingShuConfirmForm(title: "t", fields: [.init(key: "x", question: "问?", options: [])])
        XCTAssertTrue(form.formatAnswers([:]).contains("(未填)"))
    }

    func testOtherOptionLabelConstant() {
        XCTAssertEqual(LingShuConfirmForm.otherOptionLabel, "其他(自行输入)")
    }

    @MainActor
    func testControlChatPayloadExposesPendingForm() {
        let state = LingShuState()
        let form = LingShuConfirmForm(title: "同步外部系统前确认", fields: [
            .init(key: "target", question: "目标系统?", options: ["Notion", "飞书"]),
            .init(key: "credential", question: "授权方式?", options: [])
        ])
        state.chatMessages.append(.init(speaker: "灵枢", text: form.title, isUser: false, form: form))
        let payload = LingShuControlRouter(state: state).chatPayload(limit: 1)
        let object = payload[0]
        XCTAssertEqual((object["choices"] as? [Any])?.count ?? -1, 0, "没有单选卡时仍保持 choices 为空数组")
        let formPayload = object["form"] as? [String: Any]
        XCTAssertEqual(formPayload?["title"] as? String, "同步外部系统前确认")
        let fields = formPayload?["fields"] as? [[String: Any]]
        XCTAssertEqual(fields?.count, 2)
        XCTAssertEqual(fields?.first?["key"] as? String, "target")
        XCTAssertEqual(fields?.first?["options"] as? [String], ["Notion", "飞书"])
    }

    @MainActor
    func testControlSendPromptReturnsStableAnchors() async throws {
        let state = LingShuState()
        let router = LingShuControlRouter(state: state)
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "lingshu_send_prompt",
                "arguments": ["text": "现在是几月几日星期几?只回答当前日期。"]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let response = await router.handle(requestBody: data)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(payload["submitted"] as? String, "现在是几月几日星期几?只回答当前日期。")
        XCTAssertFalse((payload["userMessageId"] as? String ?? "").isEmpty)
        XCTAssertFalse((payload["assistantMessageId"] as? String ?? "").isEmpty)
        XCTAssertFalse((payload["recordId"] as? String ?? "").isEmpty)
        XCTAssertFalse((payload["immediateReply"] as? String ?? "").isEmpty)
    }
}
