import XCTest
@testable import LingShuMac

/// P1 声明式插件清单 + 权限作用域单测:解析 / 作用域匹配(glob+域名)/ 风险评级 / 越权检测 / skill 接入。
final class PluginManifestTests: XCTestCase {

    // MARK: - 清单解析

    func testManifestParseFromFrontmatter() {
        let fm = [
            "id": "my-plugin", "title": "我的插件", "version": "2.1",
            "provides": "do_x, do_y",
            "perm_read": "~/Documents/**",
            "perm_write": "/work/out/**, /tmp/x",
            "perm_network": "api.openai.com, *.example.com",
            "perm_shell": "true"
        ]
        let m = LingShuPluginManifest.from(frontmatter: fm, source: .discovered)
        XCTAssertEqual(m.id, "my-plugin")
        XCTAssertEqual(m.version, "2.1")
        XCTAssertEqual(m.providedTools, ["do_x", "do_y"])
        XCTAssertEqual(m.permissions.fileWrite, ["/work/out/**", "/tmp/x"])
        XCTAssertEqual(m.permissions.network, ["api.openai.com", "*.example.com"])
        XCTAssertTrue(m.permissions.shell)
        XCTAssertFalse(m.permissions.systemSensitive)
        XCTAssertEqual(m.source, .discovered)
    }

    func testManifestDefaultsLeastPrivilege() {
        let m = LingShuPluginManifest.from(frontmatter: ["title": "空插件"], source: .user)
        XCTAssertTrue(m.permissions.isEmpty, "没声明=最小权限")
        XCTAssertEqual(m.permissionSummary, "无特殊权限声明(最小权限)")
    }

    // MARK: - 作用域匹配

    private func manifest(read: [String] = [], write: [String] = [], net: [String] = [], shell: Bool = false, sys: Bool = false) -> LingShuPluginManifest {
        .init(id: "t", name: "t", version: "1", providedTools: [],
              permissions: .init(fileRead: read, fileWrite: write, network: net, shell: shell, systemSensitive: sys), source: .user)
    }

    func testWriteScopeGlobAndPrefix() {
        let m = manifest(write: ["/work/**", "/tmp/single"])
        XCTAssertTrue(LingShuPluginPermissionChecker.allowsWrite(m, path: "/work/a/b.txt"), "** 覆盖子目录")
        XCTAssertTrue(LingShuPluginPermissionChecker.allowsWrite(m, path: "/tmp/single"))
        XCTAssertFalse(LingShuPluginPermissionChecker.allowsWrite(m, path: "/etc/passwd"), "范围外应拒")
    }

    func testSingleStarDoesNotCrossSlash() {
        let m = manifest(write: ["/work/*"])
        XCTAssertTrue(LingShuPluginPermissionChecker.allowsWrite(m, path: "/work/a"))
        XCTAssertFalse(LingShuPluginPermissionChecker.allowsWrite(m, path: "/work/a/b"), "* 不跨 /")
    }

    func testDirPrefixWithoutWildcard() {
        let m = manifest(write: ["/work"])
        XCTAssertTrue(LingShuPluginPermissionChecker.allowsWrite(m, path: "/work/a/b"), "声明目录覆盖其下")
        XCTAssertTrue(LingShuPluginPermissionChecker.allowsWrite(m, path: "/work"))
        XCTAssertFalse(LingShuPluginPermissionChecker.allowsWrite(m, path: "/workshop/x"), "前缀不能误伤同名前缀目录")
    }

    func testReadFallsBackToWriteScope() {
        let m = manifest(write: ["/work/**"])
        XCTAssertTrue(LingShuPluginPermissionChecker.allowsRead(m, path: "/work/a"), "可写即可读")
    }

    func testNetworkScope() {
        XCTAssertTrue(LingShuPluginPermissionChecker.allowsNetwork(manifest(net: ["*"]), host: "anything.com"))
        let m = manifest(net: ["api.openai.com", "*.example.com"])
        XCTAssertTrue(LingShuPluginPermissionChecker.allowsNetwork(m, host: "api.openai.com"))
        XCTAssertTrue(LingShuPluginPermissionChecker.allowsNetwork(m, host: "cdn.example.com"))
        XCTAssertTrue(LingShuPluginPermissionChecker.allowsNetwork(m, host: "example.com"), "*.x 也匹配裸域")
        XCTAssertFalse(LingShuPluginPermissionChecker.allowsNetwork(m, host: "evil.com"))
    }

    // MARK: - 风险评级 + 越权

    func testRiskLevels() {
        XCTAssertEqual(LingShuPluginPermissionChecker.riskLevel(manifest()), .low)
        XCTAssertEqual(LingShuPluginPermissionChecker.riskLevel(manifest(write: ["/work/**"])), .low)
        XCTAssertEqual(LingShuPluginPermissionChecker.riskLevel(manifest(shell: true)), .medium)
        XCTAssertEqual(LingShuPluginPermissionChecker.riskLevel(manifest(net: ["*"])), .medium)
        XCTAssertEqual(LingShuPluginPermissionChecker.riskLevel(manifest(net: ["*"], shell: true)), .high, "跑命令+任意联网=高")
        XCTAssertEqual(LingShuPluginPermissionChecker.riskLevel(manifest(sys: true)), .high)
    }

    func testViolationsDetected() {
        let m = manifest(write: ["/work/**"], net: ["api.openai.com"], shell: false)
        let v = LingShuPluginPermissionChecker.violations(of: m, writes: ["/etc/x"], hosts: ["evil.com"], shell: true)
        XCTAssertEqual(v.count, 3, "写越权 + 联网越权 + 未声明 shell")
        XCTAssertTrue(LingShuPluginPermissionChecker.violations(of: m, writes: ["/work/ok"], hosts: ["api.openai.com"]).isEmpty)
    }

    // MARK: - skill 接入

    func testSkillLoaderParsesManifest() {
        let md = """
        ---
        id: writer
        title: 写作助手
        triggers: 写文章
        perm_write: ~/Documents/**
        perm_shell: false
        ---
        ## 专业要点
        - 写得好
        """
        guard let loaded = LingShuSkillLoader.parse(md, fallbackID: "x") else { return XCTFail("解析失败") }
        XCTAssertEqual(loaded.manifest.permissions.fileWrite, ["~/Documents/**"])
        XCTAssertFalse(loaded.manifest.permissions.shell)
        XCTAssertEqual(LingShuPluginPermissionChecker.riskLevel(loaded.manifest), .low)
    }
}
