import XCTest
@testable import LingShuMac

/// # 执行器/动作型外围测试(M4 架构)
///
/// 守住:① 执行器风险模型(reversible/physical + 每次确认判定)② actuator 组件组装→往返解析(provides + 目标 + 风险)
/// ③ 校验 ④ LoadedSkill 携带 frontmatter(供工具装配识别 actuator_risk)。
final class ActuatorComponentTests: XCTestCase {

    // MARK: - ① 风险模型

    func testRiskParsedFromDeclarationOnly() {
        // 风险**由大脑显式声明**,零关键词清单(撤定制,方案 §4 #7)。
        XCTAssertEqual(LingShuActuatorSafety.Risk.from("physical"), .physical)
        XCTAssertEqual(LingShuActuatorSafety.Risk.from("irreversible"), .physical)
        XCTAssertEqual(LingShuActuatorSafety.Risk.from("reversible"), .reversible)
        XCTAssertEqual(LingShuActuatorSafety.Risk.from(""), .reversible, "未声明=默认可逆")
        // 不再靠关键词猜:未显式声明 physical 的就是 reversible(安全靠确认门,不靠关键词命中)。
        XCTAssertEqual(LingShuActuatorSafety.Risk.from("servo motor control"), .reversible, "零关键词:不再从'motor'猜physical")
        XCTAssertEqual(LingShuActuatorSafety.Risk.from("门锁继电器"), .reversible, "零关键词:不再从'锁/继电器'猜physical")
    }

    func testRequiresConfirmationEachCall() {
        XCTAssertTrue(LingShuActuatorSafety.requiresConfirmationEachCall(.physical), "物理动作每次确认")
        XCTAssertFalse(LingShuActuatorSafety.requiresConfirmationEachCall(.reversible), "可逆动作不必每次确认")
    }

    func testConfirmationPrompt() {
        let p = LingShuActuatorSafety.confirmationPrompt(actuatorName: "门锁", target: "/dev/cu.usbserial-1", command: "{\"action\":\"unlock\"}")
        XCTAssertTrue(p.contains("门锁") && p.contains("/dev/cu.usbserial-1") && p.contains("unlock"))
    }

    // MARK: - ② actuator 组件组装 → 往返解析

    func testActuatorMarkdownRoundTrip() {
        let spec = LingShuComponentAuthoring.Spec(
            name: "系统音量控制", toolName: "set_volume",
            description: "设置系统输出音量,入参 volume(0-100)", language: .python,
            runnerCode: "import sys,json,subprocess\na=json.loads(sys.stdin.read() or '{}')\nsubprocess.run(['osascript','-e',f\"set volume output volume {int(a.get('volume',30))}\"])\nprint(json.dumps({'ok':True}))",
            parametersJSON: "", kind: .actuator, actuatorTarget: "system.volume", actuatorRisk: "reversible")
        XCTAssertTrue(LingShuComponentAuthoring.validate(spec).isEmpty)
        let id = LingShuComponentAuthoring.componentID(for: spec)
        XCTAssertEqual(id, "actuator-set-volume")
        let md = LingShuComponentAuthoring.assembleMarkdown(spec, id: id)
        let fm = LingShuComponentAuthoring.parseFrontmatter(md)
        XCTAssertEqual(fm["provides"], "set_volume", "执行器也暴露工具")
        XCTAssertEqual(fm["actuator_target"], "system.volume")
        XCTAssertEqual(fm["actuator_risk"], "reversible")
        // 往返解析:LoadedSkill 携带 frontmatter(工具装配处据此识别执行器)+ 安全 runner 挂为 bundledScript。
        let loaded = LingShuSkillLoader.parse(md, fallbackID: id)
        XCTAssertEqual(loaded?.frontmatter["actuator_risk"], "reversible")
        XCTAssertEqual(loaded?.manifest.providedTools, ["set_volume"])
        XCTAssertNotNil(loaded?.profile.bundledScript)
    }

    func testPhysicalActuatorRoundTrip() {
        let spec = LingShuComponentAuthoring.Spec(
            name: "舵机控制", toolName: "set_servo_angle",
            description: "转动舵机到指定角度", language: .python, runnerCode: "print('{}')",
            parametersJSON: "", kind: .actuator, actuatorTarget: "/dev/cu.usbserial-1420", actuatorRisk: "physical")
        let md = LingShuComponentAuthoring.assembleMarkdown(spec, id: LingShuComponentAuthoring.componentID(for: spec))
        let loaded = LingShuSkillLoader.parse(md, fallbackID: "x")
        XCTAssertEqual(loaded?.frontmatter["actuator_risk"], "physical")
        XCTAssertEqual(LingShuActuatorSafety.Risk.from(loaded?.frontmatter["actuator_risk"] ?? ""), .physical)
    }

    // MARK: - ③ 校验

    func testValidateActuatorRequiresTargetAndValidRisk() {
        var s = LingShuComponentAuthoring.Spec(
            name: "x", toolName: "do_thing", description: "d", language: .python, runnerCode: "print(1)",
            parametersJSON: "", kind: .actuator, actuatorTarget: "", actuatorRisk: "reversible")
        XCTAssertTrue(LingShuComponentAuthoring.validate(s).contains { $0.contains("actuator_target") }, "执行器须声明目标")
        s.actuatorTarget = "system.volume"; s.actuatorRisk = "maybe"
        XCTAssertTrue(LingShuComponentAuthoring.validate(s).contains { $0.contains("actuator_risk") }, "非法风险类被拦")
        s.actuatorRisk = "physical"
        XCTAssertTrue(LingShuComponentAuthoring.validate(s).isEmpty)
        // 执行器也产出工具 → 不可遮蔽内核四肢
        s.toolName = "run_command"
        XCTAssertTrue(LingShuComponentAuthoring.validate(s).contains { $0.contains("内核四肢冲突") })
    }
}
