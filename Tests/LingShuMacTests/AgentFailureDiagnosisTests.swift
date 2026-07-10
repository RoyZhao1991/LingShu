import XCTest
@testable import LingShuMac

final class AgentFailureDiagnosisTests: XCTestCase {

    func testParsesHighConfidenceQuotaAsPluginUnavailable() {
        let raw = """
        {"category":"unavailable_quota","confidence":"high","mark_plugin_unavailable":true,
         "reason":"额度用尽","user_message":"Codex 插件当前不可用:额度用尽。","retry_advice":"补额度后重试"}
        """
        let diagnosis = LingShuAgentFailureDiagnosis.parse(raw)
        XCTAssertEqual(diagnosis?.category, .unavailableQuota)
        XCTAssertEqual(diagnosis?.reason, "额度用尽")
        XCTAssertTrue(diagnosis?.markPluginUnavailable == true)
    }

    func testTaskFailureCannotBeMarkedPluginUnavailableEvenIfModelAsks() {
        let raw = """
        {"category":"task_failed","confidence":"high","mark_plugin_unavailable":true,
         "reason":"测试失败","user_message":"Codex 已启动但测试失败。","retry_advice":"修复测试"}
        """
        let diagnosis = LingShuAgentFailureDiagnosis.parse(raw)
        XCTAssertEqual(diagnosis?.category, .taskFailed)
        XCTAssertFalse(diagnosis?.markPluginUnavailable ?? true)
    }

    func testLowConfidenceInfrastructureGuessDoesNotHidePlugin() {
        let raw = """
        {"category":"unavailable_auth","confidence":"low","mark_plugin_unavailable":true,
         "reason":"可能未登录","user_message":"可能需要登录。","retry_advice":"确认登录状态"}
        """
        let diagnosis = LingShuAgentFailureDiagnosis.parse(raw)
        XCTAssertEqual(diagnosis?.category, .unavailableAuth)
        XCTAssertFalse(diagnosis?.markPluginUnavailable ?? true)
    }

    func testSanitizesCommonSecretsBeforeModelFallback() {
        let text = "Authorization: Bearer ghp_secrettoken123\napi_key=sk-secretabc1234567890\nout"
        let sanitized = LingShuAgentFailureDiagnosis.sanitizedEvidence(text)
        XCTAssertFalse(sanitized.contains("ghp_secrettoken123"))
        XCTAssertFalse(sanitized.contains("sk-secretabc1234567890"))
        XCTAssertTrue(sanitized.contains("***"))
    }
}
