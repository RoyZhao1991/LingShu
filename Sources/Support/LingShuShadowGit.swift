import Foundation
import CryptoKit

/// 灵枢**影子 git**:对任意工作目录,在 `~/Library/Application Support/LingShu/ShadowGits/<hash>` 维护一个
/// **灵枢自己的** git-dir(全程 `--git-dir=影子 --work-tree=目标夹`,**绝不在目标夹放 .git**),用 git 的**内容级 diff**
/// 量"一次 agent 跑到底真正动了哪些文件",取代"按 mtime 足迹 / agent 自报"的产出物归属。
///
/// 为什么(2026-06-27 用户实测,见 [[artifact-attribution-shadow-git]]):所有任务共用一个扁平工作目录,旧逻辑把 agent
/// "碰过"的文件(甚至只 touch、内容没变的)都算成本任务产出 → 昨天的坦克文档串进今天的超级玛丽任务。
/// 影子 git 看的是**文件系统内容**、不依赖 agent 自报,且:① 只被 touch、内容没变的文件 git 直接无视;② 真新增/修改/删除
/// 带精确 ±行;③ 盖在**已是用户仓库**的目录上互不干扰(不吞用户 .git、不动用户历史、零污染);④ work-tree 的 .gitignore
/// 自动挡掉构建垃圾。以上四点均已实测。**纯壳、nonisolated、可单测。**
enum LingShuShadowGit {

    /// 本次相对基线真正动过的一个文件。
    struct FileChange: Equatable, Sendable {
        enum Kind: String, Sendable { case added, modified, deleted }
        let kind: Kind
        let path: String      // 绝对路径(已还原成 work-tree 下的绝对路径)
        let added: Int        // +行
        let removed: Int      // −行
    }

    /// 跑前打的基线引用(影子 git 的一个提交)。delta 据此算本次增量。
    struct Baseline: Equatable, Sendable {
        let commit: String
        let workDir: String   // 标准化后的绝对路径
    }

    // MARK: - 公开 API

    /// **跑前打基线**:确保影子 git 存在,把当前工作目录状态提交成基线,返回引用。
    /// 失败(目录不存在/git 不可用/提交失败)返回 nil → 调用方据此退回"不做 git 归属"。
    static func baseline(workDir rawDir: String) -> Baseline? {
        guard let (shadow, dir) = prepare(rawDir) else { return nil }
        _ = run(shadow, dir, ["add", "-A"])
        let c = run(shadow, dir, ["commit", "-q", "--allow-empty", "-m", "lingshu-baseline-\(Int(Date().timeIntervalSince1970))"])
        guard c.status == 0 else { return nil }
        let head = run(shadow, nil, ["rev-parse", "HEAD"])
        let sha = head.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.status == 0, !sha.isEmpty else { return nil }
        return Baseline(commit: sha, workDir: dir)
    }

    /// **跑后量 delta**:相对基线,本次真正新增/修改/删除了哪些文件(内容级;只被 touch、内容没变的不算)。
    static func delta(since base: Baseline) -> [FileChange] {
        guard let shadow = shadowDir(for: base.workDir) else { return [] }
        let dir = base.workDir
        _ = run(shadow, dir, ["add", "-A"])
        // 内容级 diff(基线 → 当前 index);--no-renames 让重命名稳定地呈现为 删除旧+新增新,解析确定。
        let names = run(shadow, dir, ["diff", "--cached", "--no-renames", "--name-status", base.commit])
        let nums = run(shadow, dir, ["diff", "--cached", "--no-renames", "--numstat", base.commit])
        guard names.status == 0, nums.status == 0 else { return [] }
        return parse(nameStatus: names.out, numstat: nums.out, workDir: dir)
    }

    /// 构建/缓存类**噪声路径**:就算 work-tree 的 .gitignore 没挡(很多目录没配),也别当产出物登记——
    /// `__pycache__`/`.pyc`/`node_modules`/`.build`/`.DS_Store` 等(对齐旧扫盘的 skip 集)。纯函数,单测覆盖。
    static func isBuildOrCacheNoise(_ path: String) -> Bool {
        let skipDirs: Set<String> = [".git", ".build", "node_modules", "__pycache__", ".venv", "venv",
                                     "dist", "build", "target", ".pytest_cache", ".idea", ".next", ".cache", "DerivedData"]
        if !Set((path as NSString).pathComponents).isDisjoint(with: skipDirs) { return true }
        if ["pyc", "pyo", "class", "o"].contains((path as NSString).pathExtension.lowercased()) { return true }
        return (path as NSString).lastPathComponent == ".DS_Store"
    }

    // MARK: - 解析(纯函数,单测覆盖)

    /// 把 `git diff --name-status`(定 kind)+ `--numstat`(定 ±行)按路径合并成 FileChange 列表。
    static func parse(nameStatus: String, numstat: String, workDir: String) -> [FileChange] {
        var lineStat: [String: (added: Int, removed: Int)] = [:]   // repo 相对路径 → ±行
        for row in numstat.split(separator: "\n") {
            // "<add>\t<rem>\t<path>";二进制文件 add/rem 为 "-"。
            let cols = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard cols.count == 3 else { continue }
            lineStat[cols[2]] = (Int(cols[0]) ?? 0, Int(cols[1]) ?? 0)
        }
        var out: [FileChange] = []
        for row in nameStatus.split(separator: "\n") {
            let cols = row.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard cols.count == 2, let status = cols[0].first else { continue }
            let kind: FileChange.Kind
            switch status {
            case "A": kind = .added
            case "M": kind = .modified
            case "D": kind = .deleted
            default: continue   // C/T/U… 暂不收
            }
            let rel = cols[1]
            let stat = lineStat[rel] ?? (0, 0)
            out.append(FileChange(kind: kind, path: (workDir as NSString).appendingPathComponent(rel),
                                  added: stat.added, removed: stat.removed))
        }
        return out
    }

    // MARK: - 内部:影子 git-dir 准备

    /// 校验目录、定位/初始化影子 git-dir(首建配好身份/中文路径/不签名)。返回 (影子git-dir, 标准化work-tree)。
    private static func prepare(_ rawDir: String) -> (shadow: String, dir: String)? {
        let dir = URL(fileURLWithPath: rawDir).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
              let shadow = shadowDir(for: dir) else { return nil }
        if !FileManager.default.fileExists(atPath: shadow) {
            try? FileManager.default.createDirectory(atPath: shadow, withIntermediateDirectories: true)
            guard run(shadow, nil, ["init", "-q"]).status == 0 else { return nil }
            _ = run(shadow, nil, ["config", "user.name", "灵枢"])
            _ = run(shadow, nil, ["config", "user.email", "lingshu@local"])
            _ = run(shadow, nil, ["config", "core.quotePath", "false"])   // 中文文件名别被转义成 \xxx
            _ = run(shadow, nil, ["config", "commit.gpgsign", "false"])   // 免签名卡住
            _ = run(shadow, nil, ["config", "gc.auto", "0"])             // 免自动 gc 意外
            setupAlternates(shadow: shadow, workDir: dir)               // 目标在仓库里→复用其对象库,大目录基线提速+不重复存
        }
        return (shadow, dir)
    }

    /// 若目标目录隶属某 git 仓库,让影子对象库 alternates 指向真仓库 objects:**已提交内容不重复存**——
    /// 大目录基线从"重存全树/十几秒"降到"秒级/几百KB"(实测大型工作区:13.3s/310MB → 2.6s/420KB)。
    /// 纯**只读复用**真仓库对象,绝不写真仓库(影子的新对象进影子自己的库),零污染。目标不在仓库则跳过、影子自存。
    private static func setupAlternates(shadow: String, workDir: String) {
        let r = exec(["-C", workDir, "rev-parse", "--absolute-git-dir"])
        guard r.status == 0 else { return }
        let objects = (r.out.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).appendingPathComponent("objects")
        guard FileManager.default.fileExists(atPath: objects) else { return }
        let infoDir = (shadow as NSString).appendingPathComponent("objects/info")
        try? FileManager.default.createDirectory(atPath: infoDir, withIntermediateDirectories: true)
        try? (objects + "\n").write(toFile: (infoDir as NSString).appendingPathComponent("alternates"),
                                    atomically: true, encoding: .utf8)
    }

    /// 某工作目录对应的影子 git-dir 路径(按标准化绝对路径 SHA256 取稳定短哈希)。
    static func shadowDir(for dir: String) -> String? {
        let base = LingShuRuntimeEnvironment.applicationSupportDirectory()
        let std = URL(fileURLWithPath: dir).standardizedFileURL.path
        let hash = SHA256.hash(data: Data(std.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        return base.appendingPathComponent("LingShu/ShadowGits/\(hash)").path
    }

    // MARK: - git 进程(同步、防死锁并发读管道)

    private static let gitPath: String = {
        ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git",
         "/Library/Developer/CommandLineTools/usr/bin/git"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
    }()

    /// 影子 git 命令(自动带 --git-dir,可选 --work-tree)。
    @discardableResult
    private static func run(_ shadow: String, _ workDir: String?, _ args: [String]) -> (status: Int32, out: String, err: String) {
        var full = ["--git-dir=\(shadow)"]
        if let workDir { full.append("--work-tree=\(workDir)") }
        return exec(full + args)
    }

    /// 裸 git(不带影子 git-dir);用于查目标目录所属真仓库(setupAlternates)等。
    @discardableResult
    private static func exec(_ args: [String]) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_OPTIONAL_LOCKS"] = "0"   // 永不交互提示/免锁干扰
        p.environment = env
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "", "\(error)") }
        // 并发读 stdout/stderr,避免任一管道写满 64KB 缓冲、进程阻塞 → 死锁。
        let group = DispatchGroup()
        var oData = Data(); var eData = Data()
        group.enter(); DispatchQueue.global().async { oData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { eData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        p.waitUntilExit(); group.wait()
        return (p.terminationStatus, String(data: oData, encoding: .utf8) ?? "", String(data: eData, encoding: .utf8) ?? "")
    }
}
