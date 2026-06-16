import XCTest
@testable import LingShuMac

/// 增量记忆持久化(WAL 追加写 + 阈值压缩 + 跨重启回放恢复)+ 产出物公共目录/网络状态判定。
final class IncrementalStoreTests: XCTestCase {

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("lingshu-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func deliverable(_ id: String, _ title: String) -> LingShuDeliverable {
        .init(id: id, title: title, primaryDir: "/x/\(id)", summaryExcerpt: "做了 \(title)", completedAt: Date())
    }

    func testWALAppendRecoversAcrossReload() async {
        let dir = tempDir()
        let store = LingShuIncrementalStore<LingShuDeliverable>(directory: dir, name: "t")
        await store.upsert(deliverable("a", "任务A"))
        await store.upsert(deliverable("b", "任务B"))
        let all = await store.all()
        XCTAssertEqual(all.map(\.id), ["a", "b"])

        // 新实例(同目录)= 模拟 app 重启:从 WAL 回放恢复。
        let reloaded = LingShuIncrementalStore<LingShuDeliverable>(directory: dir, name: "t")
        let all2 = await reloaded.all()
        XCTAssertEqual(all2.map(\.id), ["a", "b"])
        XCTAssertEqual(all2.first(where: { $0.id == "b" })?.title, "任务B")
    }

    func testUpsertUpdatesAndDeletePersist() async {
        let dir = tempDir()
        let store = LingShuIncrementalStore<LingShuDeliverable>(directory: dir, name: "u")
        await store.upsert(deliverable("a", "旧"))
        await store.upsert(deliverable("a", "新"))      // 同 id → 更新,不重复
        await store.upsert(deliverable("b", "B"))
        await store.delete("a")

        let reloaded = LingShuIncrementalStore<LingShuDeliverable>(directory: dir, name: "u")
        let all = await reloaded.all()
        XCTAssertEqual(all.map(\.id), ["b"], "删除 a 后只剩 b,且回放后一致")
    }

    func testCompactionClearsWALButKeepsData() async {
        let dir = tempDir()
        let store = LingShuIncrementalStore<LingShuDeliverable>(directory: dir, name: "c", compactThreshold: 8)
        for i in 0..<12 { await store.upsert(deliverable("\(i)", "T\(i)")) }   // 超过阈值 → 触发 checkpoint 压缩
        await store.compact()

        let snapshot = dir.appendingPathComponent("c.snapshot.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path), "压缩后应有 snapshot")
        let wal = dir.appendingPathComponent("c.wal.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wal.path), "压缩后 WAL 应被清空")

        let reloaded = LingShuIncrementalStore<LingShuDeliverable>(directory: dir, name: "c")
        let all = await reloaded.all()
        XCTAssertEqual(all.count, 12, "压缩 + 重启回放后数据完整")
    }

    func testCommonParentDirIsProjectRoot() {
        let files = ["/Users/x/app/mario_game/mario/player.py",
                     "/Users/x/app/mario_game/tests/test_player.py",
                     "/Users/x/app/mario_game/smoke_run.py"]
        XCTAssertEqual(LingShuState.commonParentDir(files), "/Users/x/app/mario_game")
    }

    func testNetworkStatusNoticeDetection() {
        XCTAssertTrue(LingShuState.isNetworkStatusNotice("🌐 网络异常中断,正在重试…"))
        XCTAssertTrue(LingShuState.isNetworkStatusNotice("🔄 网络已恢复,继续执行。"))
        XCTAssertTrue(LingShuState.isNetworkStatusNotice("模型调用失败:网络中断"))
        XCTAssertFalse(LingShuState.isNetworkStatusNotice("✅ 已完成 FizzBuzz,41 个测试全绿。"))
        XCTAssertFalse(LingShuState.isNetworkStatusNotice("你好,我是灵枢。"))
    }
}
