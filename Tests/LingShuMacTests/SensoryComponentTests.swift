import XCTest
@testable import LingShuMac

/// # 自编传感器型外围测试(M2)
///
/// 守住:① runner 源把 stdout 解析成归一读数 ② Hub 运行时动态注册/注销 ③ sensor 组件组装→往返解析。
final class SensoryComponentTests: XCTestCase {

    // MARK: - ① runner 源解析(纯)

    func testParseReadingsSingleObject() {
        let out = "{\"headline\":\"系统负载 1.23\",\"detail\":\"1/5/15 分钟\",\"salience\":2,\"metadata\":{\"load1\":\"1.23\"}}"
        let rs = LingShuRunnerSensorySource.parseReadings(out, channel: .smartHome, sourceID: "load")
        XCTAssertEqual(rs.count, 1)
        XCTAssertEqual(rs.first?.headline, "系统负载 1.23")
        XCTAssertEqual(rs.first?.channel, .smartHome)
        XCTAssertEqual(rs.first?.sourceID, "load")
        XCTAssertEqual(rs.first?.salience, 2)
        XCTAssertEqual(rs.first?.metadata["load1"], "1.23")
    }

    func testParseReadingsArrayAndClamp() {
        let out = "[{\"headline\":\"A\",\"salience\":9},{\"headline\":\"B\"},{\"detail\":\"无headline忽略\"}]"
        let rs = LingShuRunnerSensorySource.parseReadings(out, channel: .wearable, sourceID: "w")
        XCTAssertEqual(rs.count, 2, "缺 headline 的项被忽略")
        XCTAssertEqual(rs[0].salience, 3, "salience 越界被钳到 0…3")
        XCTAssertEqual(rs[1].salience, 1, "默认 salience=1")
    }

    func testParseReadingsRejectsGarbage() {
        XCTAssertTrue(LingShuRunnerSensorySource.parseReadings("not json", channel: .smartHome, sourceID: "x").isEmpty)
        XCTAssertTrue(LingShuRunnerSensorySource.parseReadings("", channel: .smartHome, sourceID: "x").isEmpty)
        XCTAssertTrue(LingShuRunnerSensorySource.parseReadings("ERR: boom", channel: .smartHome, sourceID: "x").isEmpty)
    }

    func testRunnerSourceActivateYieldsReadingFromInjectedRunner() async {
        // 注入假 runOnce(免子进程):验证 activate 轮询→解析→yield 读数的链路。
        let descriptor = LingShuExternalSensoryDescriptor(
            id: "mock-load", displayName: "负载", englishName: "Load", channel: .smartHome,
            requiresPairing: false, summary: "", englishSummary: "")
        let manifest = LingShuPluginManifest(id: "mock-load", name: "负载", version: "1", providedTools: [], permissions: .init(), source: .user)
        let source = LingShuRunnerSensorySource(
            descriptor: descriptor, manifest: manifest, executable: "/bin/echo", baseArguments: [],
            channel: .smartHome, sourceID: "mock-load", pollInterval: 1,
            runOnce: { _, _, _, _, _ in "{\"headline\":\"负载 0.5\",\"salience\":1}" })
        var sawReading: LingShuExternalSensoryReading?
        for await signal in source.activate() {
            if case .reading(let r) = signal { sawReading = r; break }
        }
        source.deactivate()
        XCTAssertEqual(sawReading?.headline, "负载 0.5")
        XCTAssertEqual(sawReading?.sourceID, "mock-load")
    }

    // MARK: - ② Hub 运行时动态注册/注销

    private final class StubSource: LingShuExternalSensorySource, @unchecked Sendable {
        let descriptor: LingShuExternalSensoryDescriptor
        init(_ id: String) {
            descriptor = .init(id: id, displayName: id, englishName: id, channel: .smartHome,
                               requiresPairing: false, summary: "", englishSummary: "")
        }
        func activate() -> AsyncStream<LingShuExternalSensorySignal> { AsyncStream { $0.finish() } }
        func deactivate() {}
    }

    @MainActor
    func testHubDynamicRegisterAndUnregister() {
        let hub = LingShuExternalSensoryHub(sources: [])
        XCTAssertFalse(hub.isRegistered("s1"))
        hub.registerSource(StubSource("s1"))
        XCTAssertTrue(hub.isRegistered("s1"))
        XCTAssertTrue(hub.availableSources.contains { $0.id == "s1" }, "注册后进可用源清单")
        hub.unregisterSource("s1")
        XCTAssertFalse(hub.isRegistered("s1"))
        XCTAssertFalse(hub.availableSources.contains { $0.id == "s1" }, "注销后移出清单")
    }

    @MainActor
    func testHubRegisterReplaceSameID() {
        let hub = LingShuExternalSensoryHub(sources: [])
        hub.registerSource(StubSource("dup"))
        hub.registerSource(StubSource("dup"))   // 同 id 热替换,不重复
        XCTAssertEqual(hub.availableSources.filter { $0.id == "dup" }.count, 1)
    }

    // MARK: - ③ sensor 组件组装 → 往返解析

    func testSensorComponentMarkdownRoundTrip() {
        let spec = LingShuComponentAuthoring.Spec(
            name: "系统负载传感器", toolName: "system_load_sensor",
            description: "周期读系统负载", language: .python,
            runnerCode: "import os,json\nl=os.getloadavg()[0]\nprint(json.dumps({\"headline\":f\"负载 {l}\"}))",
            parametersJSON: "", kind: .sensor, sensorChannel: "smartHome", pollIntervalSeconds: 3)
        XCTAssertTrue(LingShuComponentAuthoring.validate(spec).isEmpty)
        let id = LingShuComponentAuthoring.componentID(for: spec)
        XCTAssertEqual(id, "sensor-system-load-sensor")
        let md = LingShuComponentAuthoring.assembleMarkdown(spec, id: id)
        // frontmatter 识别传感器(sensor_channel),且不写 provides(不是工具)。
        let fm = LingShuComponentAuthoring.parseFrontmatter(md)
        XCTAssertEqual(LingShuComponentAuthoring.sensorChannel(fromFrontmatter: fm), .smartHome)
        XCTAssertEqual(fm["sensor_poll"], "3")
        XCTAssertNil(fm["provides"], "传感器型不暴露工具")
        // runner 安全 → 解析挂为 bundledScript(才能被加载器接成源)。
        let loaded = LingShuSkillLoader.parse(md, fallbackID: id)
        XCTAssertNotNil(loaded?.profile.bundledScript)
    }

    func testValidateRejectsBadSensorChannelAndPoll() {
        var s = LingShuComponentAuthoring.Spec(
            name: "x", toolName: "bad_sensor", description: "d", language: .python,
            runnerCode: "print(1)", parametersJSON: "", kind: .sensor, sensorChannel: "telepathy", pollIntervalSeconds: 3)
        XCTAssertTrue(LingShuComponentAuthoring.validate(s).contains { $0.contains("sensor_channel") })
        s.sensorChannel = "smartHome"; s.pollIntervalSeconds = 0
        XCTAssertTrue(LingShuComponentAuthoring.validate(s).contains { $0.contains("poll_interval") })
    }
}
