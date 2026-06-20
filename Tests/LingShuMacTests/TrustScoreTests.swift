import XCTest
@testable import LingShuMac

/// # 系统就绪度 / TRUST 计算测试 —— 含"钉死 91%"回归
final class TrustScoreTests: XCTestCase {

    // MARK: - 通道就绪:本地 ASR/TTS 始终可用(根治钉死)

    func testLocalASRCountsAsReady() {
        // 脑✓眼✓ + 本地 ASR(默认)+ 本地 TTS → 4/4 就绪(旧 bug:本地 ASR 不计 → 只有 3/4)。
        let r = LingShuTrustScore.channelReadiness(
            brainValidated: true, visionValidated: true,
            asrLocalMode: true, asrCloudValidated: false,
            ttsLocalMode: true, ttsActiveValidated: false)
        XCTAssertEqual(r.ready, 4)
        XCTAssertEqual(r.total, 4)
    }

    func testCloudASRStillCountsWhenValidated() {
        let r = LingShuTrustScore.channelReadiness(
            brainValidated: true, visionValidated: false,
            asrLocalMode: false, asrCloudValidated: true,   // 云端 ASR 校验过
            ttsLocalMode: false, ttsActiveValidated: true)
        XCTAssertEqual(r.ready, 3, "脑+耳(云)+口(云)就绪,眼没过")
    }

    func testUnreadyChannelsNotCounted() {
        let r = LingShuTrustScore.channelReadiness(
            brainValidated: false, visionValidated: false,
            asrLocalMode: false, asrCloudValidated: false,
            ttsLocalMode: false, ttsActiveValidated: false)
        XCTAssertEqual(r.ready, 0, "啥都没就绪 → 0/4")
    }

    // MARK: - 「91% 钉死」回归:修复前 3/4、修复后 4/4

    func testNinetyOnePercentBugWasThreeOfFour() {
        // 复现旧值:模型连通 + 通道 3/4 + 近期 20/20 全过 → 0.40 + 0.2625 + 0.25 = 0.9125 → 91。
        XCTAssertEqual(LingShuTrustScore.score(modelConnected: true, channelsReady: 3, channelsTotal: 4,
                                               tasksPassed: 20, tasksFinished: 20), 91, "这就是被钉死的 91%")
        // 修复后(本地 ASR 也计 → 4/4)同条件 → 100,且会随连通/校验/任务真实波动。
        XCTAssertEqual(LingShuTrustScore.score(modelConnected: true, channelsReady: 4, channelsTotal: 4,
                                               tasksPassed: 20, tasksFinished: 20), 100)
    }

    // MARK: - 分数能真实波动(不再静态)

    func testScoreMovesWithSignals() {
        // 模型断开 → 砍掉 40 分权重
        XCTAssertEqual(LingShuTrustScore.score(modelConnected: false, channelsReady: 4, channelsTotal: 4,
                                               tasksPassed: 20, tasksFinished: 20), 60)
        // 近期任务 12/20 通过 → 验收维度按 0.6 计(避开 .5 取整边界)
        let tasks = LingShuTrustScore.score(modelConnected: true, channelsReady: 4, channelsTotal: 4,
                                            tasksPassed: 12, tasksFinished: 20)
        XCTAssertEqual(tasks, 90, "0.40 + 0.35 + 0.6*0.25 = 0.90 → 90")
        // 通道 1/4 就绪
        let chans = LingShuTrustScore.score(modelConnected: true, channelsReady: 1, channelsTotal: 4,
                                            tasksPassed: 20, tasksFinished: 20)
        XCTAssertEqual(chans, 74, "0.40 + 0.25*0.35 + 0.25 = 0.7375 → 74")
    }

    // MARK: - 无数据维度剔除权重(不凭空拉高/压低)

    func testNoTaskDataExcludesWeight() {
        // 没有近期任务数据 → 只按 连通+通道 归一(0.40+0.35=0.75 满分)。
        XCTAssertEqual(LingShuTrustScore.score(modelConnected: true, channelsReady: 4, channelsTotal: 4,
                                               tasksPassed: 0, tasksFinished: 0), 100)
        XCTAssertEqual(LingShuTrustScore.score(modelConnected: false, channelsReady: 4, channelsTotal: 4,
                                               tasksPassed: 0, tasksFinished: 0), 47, "断连:0.35/0.75≈0.467→47")
    }
}
