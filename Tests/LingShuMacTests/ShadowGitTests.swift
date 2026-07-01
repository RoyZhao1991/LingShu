import XCTest
@testable import LingShuMac

/// 影子 git 产出物归属(根治共享工作目录串台,见 [[artifact-attribution-shadow-git]])。
/// 把设计阶段在 scratchpad 实测过的几幕固化:① 真新增/修改量到、只被 touch 内容没变的不算;② .gitignore 挡掉;
/// ③ 删除认出;④ 中文文件名不被转义;⑤ 盖在已有用户仓库上互不干扰、零污染。
final class ShadowGitTests: XCTestCase {

    private var work: String!

    override func setUpWithError() throws {
        work = (NSTemporaryDirectory() as NSString).appendingPathComponent("lingshu-shadow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: work)
        if let shadow = LingShuShadowGit.shadowDir(for: work) {   // 别把影子 git-dir 留在 ~/Library
            try? FileManager.default.removeItem(atPath: shadow)
        }
    }

    private func write(_ rel: String, _ text: String) {
        let p = (work as NSString).appendingPathComponent(rel)
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: p, atomically: true, encoding: .utf8)
    }

    private func change(_ d: [LingShuShadowGit.FileChange], named name: String) -> LingShuShadowGit.FileChange? {
        d.first { ($0.path as NSString).lastPathComponent == name }
    }

    /// 真新增 + 真修改量得到;只被 touch、内容没变的文件 → 不算本次产出。
    func testDetectsAddedAndModifiedButIgnoresTouchOnly() throws {
        write("a.txt", "v1\n")
        write("c.txt", "keep\n")
        let base = try XCTUnwrap(LingShuShadowGit.baseline(workDir: work), "基线应建成")

        write("a.txt", "v1\nv2\n")                                   // 改:+1 行
        write("b.txt", "new\n")                                      // 新建
        let cPath = (work as NSString).appendingPathComponent("c.txt")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: cPath)  // 只动 mtime

        let d = LingShuShadowGit.delta(since: base)
        XCTAssertEqual(change(d, named: "a.txt")?.kind, .modified)
        XCTAssertEqual(change(d, named: "a.txt")?.added, 1, "改了应有 +1 行")
        XCTAssertEqual(change(d, named: "b.txt")?.kind, .added)
        XCTAssertNil(change(d, named: "c.txt"), "只被 touch、内容没变的文件不该算产出(根治坦克串台)")
    }

    /// work-tree 的 .gitignore 自动挡掉(构建垃圾不进产出物)。
    func testHonorsGitignore() throws {
        write(".gitignore", "build/\n")
        let base = try XCTUnwrap(LingShuShadowGit.baseline(workDir: work))
        write("build/out.o", "junk\n")
        write("real.txt", "deliver\n")
        let d = LingShuShadowGit.delta(since: base)
        XCTAssertNotNil(change(d, named: "real.txt"), "正常产物要量到")
        XCTAssertNil(change(d, named: "out.o"), "被 .gitignore 忽略的不该进产出物")
    }

    /// 删除认得出来。
    func testDetectsDeletion() throws {
        write("gone.txt", "bye\n")
        let base = try XCTUnwrap(LingShuShadowGit.baseline(workDir: work))
        try FileManager.default.removeItem(atPath: (work as NSString).appendingPathComponent("gone.txt"))
        let d = LingShuShadowGit.delta(since: base)
        XCTAssertEqual(change(d, named: "gone.txt")?.kind, .deleted)
    }

    /// 中文文件名不被 git 转义成 \xxx(实际产出物多是中文名,如"架构设计文档_…")。
    func testChineseFilenameNotEscaped() throws {
        let base = try XCTUnwrap(LingShuShadowGit.baseline(workDir: work))
        write("架构设计文档_测试.md", "# 标题\n")
        let d = LingShuShadowGit.delta(since: base)
        let c = try XCTUnwrap(change(d, named: "架构设计文档_测试.md"), "中文名文件应被量到、且路径不是转义串")
        XCTAssertTrue(c.path.hasSuffix("架构设计文档_测试.md"))
        XCTAssertFalse(c.path.contains("\\"), "路径不该含反斜杠转义")
    }

    /// 盖在**已有用户 .git** 的目录上:量得到本次改动,且**绝不动用户仓库历史**(零污染)。
    func testCoexistsWithUserRepoNoPollution() throws {
        // 把 work 造成用户自己的仓库(1 个提交)。
        runUserGit(["init", "-q"])
        runUserGit(["config", "user.name", "用户"]); runUserGit(["config", "user.email", "u@local"])
        write("app.py", "v1\n")
        runUserGit(["add", "-A"]); runUserGit(["commit", "-q", "-m", "用户初始提交"])
        let before = runUserGit(["rev-list", "--count", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

        let base = try XCTUnwrap(LingShuShadowGit.baseline(workDir: work))
        write("app.py", "v1\nv2\n")
        let d = LingShuShadowGit.delta(since: base)
        XCTAssertEqual(change(d, named: "app.py")?.kind, .modified, "盖在用户仓库上也能量到改动")

        let after = runUserGit(["rev-list", "--count", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(before, after, "用户仓库的提交数不该被影子 git 改变(零污染)")
        XCTAssertFalse(runUserGit(["log", "--oneline"]).contains("lingshu-baseline"), "用户历史里不该出现灵枢基线提交")
    }

    /// 构建/缓存噪声过滤:.pyc / __pycache__ / node_modules / .DS_Store 不当产出物,真源码/文档算。
    func testBuildCacheNoiseFiltered() {
        XCTAssertTrue(LingShuShadowGit.isBuildOrCacheNoise("/a/__pycache__/x.cpython-313.pyc"))
        XCTAssertTrue(LingShuShadowGit.isBuildOrCacheNoise("/a/foo.pyc"))
        XCTAssertTrue(LingShuShadowGit.isBuildOrCacheNoise("/a/node_modules/lib/index.js"))
        XCTAssertTrue(LingShuShadowGit.isBuildOrCacheNoise("/a/.build/debug/bin"))
        XCTAssertTrue(LingShuShadowGit.isBuildOrCacheNoise("/a/.DS_Store"))
        XCTAssertFalse(LingShuShadowGit.isBuildOrCacheNoise("/a/super_mario_3d.html"))
        XCTAssertFalse(LingShuShadowGit.isBuildOrCacheNoise("/a/架构设计文档.md"))
        XCTAssertFalse(LingShuShadowGit.isBuildOrCacheNoise("/a/src/main.py"))
    }

    @discardableResult
    private func runUserGit(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", work] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
