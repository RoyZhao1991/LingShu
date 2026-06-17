import XCTest
@testable import LingShuMac

/// 外接设备感知框架测试：ANCS 线协议解析(纯)、归一映射、下游蒸馏、汇聚中枢的无缝切换 + 标准输入贡献。
/// 脱网、不依赖真设备——验证"解析逻辑/汇聚逻辑是真的、可验证的"([[no-fake-demos]])。
final class ExternalSensoryTests: XCTestCase {

    // MARK: - ANCS 线协议(§3)

    func testParseNotificationSourcePacket() {
        // EventID=0(Added) Flags=0x02(Important) Category=4(Social) Count=1 UID=0x01020304(LE)
        let data = Data([0x00, 0x02, 0x04, 0x01, 0x04, 0x03, 0x02, 0x01])
        let packet = LingShuANCSProtocol.parseSourcePacket(data)
        XCTAssertEqual(packet?.eventID, .added)
        XCTAssertTrue(packet?.isImportant ?? false)
        XCTAssertEqual(packet?.categoryName, "Social")
        XCTAssertEqual(packet?.categoryCount, 1)
        XCTAssertEqual(packet?.notificationUID, 0x01020304)
    }

    func testParseNotificationSourceRejectsShortPacket() {
        XCTAssertNil(LingShuANCSProtocol.parseSourcePacket(Data([0x00, 0x01])))
    }

    func testBuildGetNotificationAttributesRequest() {
        let request = LingShuANCSProtocol.buildGetNotificationAttributes(
            uid: 0x01020304,
            attributes: [.appIdentifier, .title],
            maxTextLength: 256
        )
        // CommandID(0) + UID(4 LE) + AttrID 0 + AttrID 1 + maxLen(256 LE = 0x00,0x01)
        XCTAssertEqual([UInt8](request), [0x00, 0x04, 0x03, 0x02, 0x01, 0x00, 0x01, 0x00, 0x01])
    }

    func testParseDataSourceAttributeResponse() {
        // CommandID(0) + UID(4) + (AttrID=0 len=2 "微") wait keep ASCII to be deterministic.
        var data = Data([0x00, 0x04, 0x03, 0x02, 0x01])
        // AttrID 0 (AppIdentifier) length 3 "abc"
        data.append(contentsOf: [0x00, 0x03, 0x00])
        data.append(contentsOf: Array("abc".utf8))
        // AttrID 1 (Title) length 5 "hello"
        data.append(contentsOf: [0x01, 0x05, 0x00])
        data.append(contentsOf: Array("hello".utf8))

        let response = LingShuANCSProtocol.parseAttributeResponse(data)
        XCTAssertEqual(response?.notificationUID, 0x01020304)
        XCTAssertEqual(response?.attributes[0], "abc")
        XCTAssertEqual(response?.attributes[1], "hello")
    }

    func testParseDataSourceHandlesFragmentation() {
        // 只给到一半的 value：已解析到的属性应返回(其余等后续分片)。
        var data = Data([0x00, 0x04, 0x03, 0x02, 0x01])
        data.append(contentsOf: [0x00, 0x03, 0x00])           // AppIdentifier len 3
        data.append(contentsOf: Array("ab".utf8))             // 只到了 2 字节(差 1)
        let response = LingShuANCSProtocol.parseAttributeResponse(data)
        // 第一个属性不完整 → attributes 为空 → 返回 nil(继续等分片)
        XCTAssertNil(response)
    }

    func testMakeNotificationMapsAttributes() {
        let packet = LingShuANCSProtocol.SourcePacket(
            eventID: .added, eventFlags: 0, categoryID: 4, categoryCount: 1, notificationUID: 42
        )
        let notif = LingShuANCSProtocol.makeNotification(
            sourceID: "ancs", packet: packet,
            attributes: [0: "com.tencent.xin", 1: "张三", 3: "明天的合同还没签"]
        )
        XCTAssertEqual(notif.appName, "微信")
        XCTAssertEqual(notif.title, "张三")
        XCTAssertEqual(notif.body, "明天的合同还没签")
        XCTAssertEqual(notif.category, "Social")
        XCTAssertEqual(notif.id, "ancs#42")
    }

    func testParseANCSDate() {
        let date = LingShuANCSProtocol.parseANCSDate("20260617T143000")
        XCTAssertNotNil(date)
        let comps = Calendar.current.dateComponents([.year, .hour, .minute], from: date!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.hour, 14)
        XCTAssertEqual(comps.minute, 30)
    }

    // MARK: - 归一映射

    func testPhoneNotificationAsReading() {
        let notif = LingShuPhoneNotification(
            id: "x#1", uid: 1, appID: "com.tencent.xin", appName: "微信",
            title: "张三", subtitle: "", body: "在吗", date: Date(), category: "Social"
        )
        let reading = notif.asReading(sourceID: "ancs")
        XCTAssertEqual(reading.channel, .phoneNotifications)
        XCTAssertEqual(reading.originApp, "微信")
        XCTAssertEqual(reading.detail, "在吗")
        XCTAssertEqual(reading.salience, 2) // Social → 2
        XCTAssertTrue(reading.headline.contains("微信"))
    }

    func testSalienceByCategory() {
        XCTAssertEqual(LingShuPhoneNotification.salience(forCategory: "IncomingCall"), 3)
        XCTAssertEqual(LingShuPhoneNotification.salience(forCategory: "Advertisement"), 0)
        XCTAssertEqual(LingShuPhoneNotification.salience(forCategory: "Other"), 1)
    }

    // MARK: - EventKit 日期格式

    func testEventKitDueDescription() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: 9, minute: 0))!
        let today = cal.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: 14, minute: 30))!
        XCTAssertEqual(LingShuEventKitSensorySource.dueDescription(today, now: now, calendar: cal), "今天 14:30")
        let tomorrow = cal.date(from: DateComponents(year: 2026, month: 6, day: 18, hour: 9, minute: 0))!
        XCTAssertEqual(LingShuEventKitSensorySource.dueDescription(tomorrow, now: now, calendar: cal), "明天 09:00")
    }

    // MARK: - 下游蒸馏(纯)

    private func reading(_ headline: String, salience: Int, app: String = "微信", uid: String? = nil) -> LingShuExternalSensoryReading {
        LingShuExternalSensoryReading(
            channel: .phoneNotifications, sourceID: "ancs", timestamp: Date(),
            headline: headline, originApp: app, salience: salience,
            metadata: uid.map { ["uid": $0] } ?? [:]
        )
    }

    func testDistillerDenoiseDropsNoiseAndDedups() {
        let readings = [
            reading("营销推送", salience: 0, uid: "1"),
            reading("张三：在吗", salience: 2, uid: "2"),
            reading("张三：在吗", salience: 2, uid: "2") // 同 UID 重复
        ]
        let denoised = LingShuPhoneTodoDistiller.denoise(readings)
        XCTAssertEqual(denoised.count, 1)
        XCTAssertEqual(denoised.first?.headline, "张三：在吗")
    }

    func testHeuristicDistillOnlyHighSalience() {
        let readings = [
            reading("低优先", salience: 1, uid: "1"),
            reading("合同到期提醒", salience: 3, uid: "2")
        ]
        let todos = LingShuPhoneTodoDistiller.heuristicDistill(readings)
        XCTAssertEqual(todos.count, 1)
        XCTAssertEqual(todos.first?.title, "合同到期提醒")
    }

    func testSituationSummary() {
        let todos = [
            LingShuPhoneTodo(title: "回复张三", sourceApp: "微信", due: "今天 18:00"),
            LingShuPhoneTodo(title: "确认会议", sourceApp: "日历")
        ]
        let summary = LingShuPhoneTodoDistiller.situationSummary(todos: todos)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.contains("回复张三"))
        XCTAssertTrue(summary!.contains("今天 18:00"))
    }

    func testSituationSummaryEmpty() {
        XCTAssertNil(LingShuPhoneTodoDistiller.situationSummary(todos: []))
    }

    // MARK: - JSON 蒸馏解析

    func testParsePhoneTodosFromModelOutput() {
        let text = """
        ```json
        [{"title":"回复客户合同","sourceApp":"微信","due":"今天 18:00","people":["王经理"],"actionSuggestion":"草拟回复","sourceQuote":"合同还没签"}]
        ```
        """
        let todos = LingShuState.parsePhoneTodos(from: text)
        XCTAssertEqual(todos?.count, 1)
        XCTAssertEqual(todos?.first?.title, "回复客户合同")
        XCTAssertEqual(todos?.first?.due, "今天 18:00")
        XCTAssertEqual(todos?.first?.people, ["王经理"])
    }

    func testParsePhoneTodosEmptyArray() {
        XCTAssertEqual(LingShuState.parsePhoneTodos(from: "[]")?.count, 0)
    }

    func testParsePhoneTodosNullDue() {
        let todos = LingShuState.parsePhoneTodos(from: #"[{"title":"x","due":"null"}]"#)
        XCTAssertNil(todos?.first?.due)
    }

    // MARK: - 汇聚中枢(无缝切换 + 标准输入贡献)

    @MainActor
    func testHubSeamlessSwitching() {
        let hub = LingShuExternalSensoryHub(sources: [LingShuEventKitSensorySource()])
        XCTAssertFalse(hub.masterEnabled)
        XCTAssertFalse(hub.isEnabled(LingShuEventKitSensorySource.sourceID))

        hub.enableSource(LingShuEventKitSensorySource.sourceID)
        XCTAssertTrue(hub.masterEnabled) // 启用任一源自动开主开关
        XCTAssertTrue(hub.isEnabled(LingShuEventKitSensorySource.sourceID))

        hub.disableSource(LingShuEventKitSensorySource.sourceID)
        XCTAssertFalse(hub.isEnabled(LingShuEventKitSensorySource.sourceID))
    }

    @MainActor
    func testHubMasterOffClearsState() {
        let hub = LingShuExternalSensoryHub(sources: [LingShuEventKitSensorySource()])
        hub.setMasterEnabled(true)
        hub.ingestForTesting(reading("张三：在吗", salience: 3, uid: "1"))
        XCTAssertFalse(hub.recentReadings.isEmpty)
        hub.setMasterEnabled(false)
        XCTAssertTrue(hub.recentReadings.isEmpty)   // 关闭即清空(隐私)
        XCTAssertTrue(hub.phoneTodos.isEmpty)
    }

    @MainActor
    func testHubSituationContributionWithoutSignalsIsNil() {
        let hub = LingShuExternalSensoryHub(sources: [LingShuEventKitSensorySource()])
        XCTAssertNil(hub.situationContribution())  // 未开启/无信号 → 不浪费 token
        XCTAssertFalse(hub.hasLiveSignals)
    }

    // MARK: - 与情境上下文汇聚(标准输入)

    func testSituationContextIncludesExternalSensoryLine() {
        let composed = LingShuSituationContext.compose(.init(externalSensoryLine: "外接设备感知 · 关键待办：\n・回复张三"))
        XCTAssertTrue(composed.contains("回复张三"))
    }

    func testSituationContextSkipsEmptyExternalSensory() {
        let composed = LingShuSituationContext.compose(.init(externalSensoryLine: nil))
        XCTAssertFalse(composed.contains("外接设备"))
    }

    // MARK: - 蓝牙不可用 → 警告 + 自动关闭(part 1)

    /// 一个会立刻发 `.fatal` 的假源,模拟"没有可用外设广播器"。
    private final class FatalStubSource: LingShuExternalSensorySource, @unchecked Sendable {
        let descriptor = LingShuExternalSensoryDescriptor(
            id: "stub.fatal", displayName: "假蓝牙源", englishName: "Stub",
            channel: .phoneNotifications, requiresPairing: true,
            summary: "测试用", englishSummary: "test"
        )
        func activate() -> AsyncStream<LingShuExternalSensorySignal> {
            AsyncStream { continuation in
                continuation.yield(.fatal("蓝牙已关闭——无可用的外设广播器"))
            }
        }
        func deactivate() {}
    }

    @MainActor
    func testFatalSignalWarnsAndAutoDisables() async {
        let hub = LingShuExternalSensoryHub(sources: [FatalStubSource()])
        hub.enableSource("stub.fatal")
        XCTAssertTrue(hub.isEnabled("stub.fatal"))
        // 等消费 Task 处理 .fatal。
        for _ in 0..<50 where hub.warning == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(hub.warning)                       // 弹了警告
        XCTAssertTrue(hub.warning?.message.contains("蓝牙") ?? false)
        XCTAssertFalse(hub.isEnabled("stub.fatal"))        // 自动关闭(开关回到关)
        if case .unavailable = hub.status(for: "stub.fatal") {} else { XCTFail("应为不可用状态") }
    }

    // MARK: - 感知链(多模态实时融合,大脑按时间窗拉取)

    @MainActor
    func testPerceptionChainDedupsUnchangedAndKeepsLatestPerChannel() {
        let chain = LingShuPerceptionChain()
        let t0 = Date()
        chain.note(.situation, "14:30 下午", now: t0)
        chain.note(.situation, "14:30 下午", now: t0.addingTimeInterval(1))   // 不变 → 不堆,只刷新
        chain.note(.hearing, "有人在说话", now: t0.addingTimeInterval(1))
        chain.note(.situation, "14:31 下午", now: t0.addingTimeInterval(2))   // 变了 → 新增
        // situation 去重后应只有 2 条(14:30 刷新 + 14:31),hearing 1 条
        let situationCount = chain.entries.filter { $0.channel == .situation }.count
        XCTAssertEqual(situationCount, 2)
        XCTAssertEqual(chain.entries.filter { $0.channel == .hearing }.count, 1)
    }

    @MainActor
    func testPerceptionChainWindowFiltersByTime() {
        let chain = LingShuPerceptionChain()
        let now = Date()
        chain.note(.hearing, "旧声音", now: now.addingTimeInterval(-20))
        chain.note(.vision, "此刻画面", now: now.addingTimeInterval(-1))
        let win = chain.window(seconds: 5, now: now)
        XCTAssertEqual(win.count, 1)
        XCTAssertEqual(win.first?.channel, .vision)
    }

    @MainActor
    func testPerceptionChainFormattedAnnotatesAgeAndIncludesSlowScreen() {
        let chain = LingShuPerceptionChain()
        let now = Date()
        chain.note(.hearing, "有人说话", now: now.addingTimeInterval(-1))     // 快通道,窗内
        chain.note(.vision, "陈旧画面", now: now.addingTimeInterval(-30))     // 快通道,窗外 → 不显示
        chain.note(.screen, "VS Code 报错", now: now.addingTimeInterval(-18)) // 慢通道,放宽显示带龄
        let text = chain.formattedWindow(seconds: 5, now: now)
        XCTAssertTrue(text.contains("听觉"))
        XCTAssertFalse(text.contains("陈旧画面"))      // 快通道陈旧不冒充实时
        XCTAssertTrue(text.contains("屏幕"))           // 慢通道仍纳入
        XCTAssertTrue(text.contains("18s前"))          // 如实标龄
    }

    @MainActor
    func testPerceptionChainEmptyWindow() {
        let chain = LingShuPerceptionChain()
        XCTAssertTrue(chain.formattedWindow(seconds: 5).contains("无活动感知信号"))
    }

    @MainActor
    func testAmbientAudioIsSeparateChannelFromMic() {
        let chain = LingShuPerceptionChain()
        let now = Date()
        chain.note(.hearing, "主人说:帮我订会议室", now: now)          // 麦克风(听主人)
        chain.note(.ambientAudio, "会议中:本季度营收增长12%", now: now) // 系统声音(听会议)
        // 两路独立共存,不互相覆盖
        XCTAssertEqual(chain.entries.filter { $0.channel == .hearing }.count, 1)
        XCTAssertEqual(chain.entries.filter { $0.channel == .ambientAudio }.count, 1)
        let text = chain.formattedWindow(seconds: 5, now: now)
        XCTAssertTrue(text.contains("听觉(麦克风)"))
        XCTAssertTrue(text.contains("听觉(系统声音)"))
        XCTAssertTrue(text.contains("营收增长12%"))
    }
}
