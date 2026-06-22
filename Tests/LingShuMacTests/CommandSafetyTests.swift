import XCTest
@testable import LingShuMac

/// run_command 危险性判定(纯逻辑,模型无关)。棘轮:守住"`> /dev/null` 被误拦致 SpringCloud 永远交付不了"这个真 bug 不复发。
final class CommandSafetyTests: XCTestCase {

    func testAllowsDevNullAndPseudoDevices() {
        // 核心回归:后台启动服务/静音输出的家常写法,必须放行。
        XCTAssertFalse(LingShuCommandSafety.isDangerous("mvn spring-boot:run > /dev/null 2>&1 &"))
        XCTAssertFalse(LingShuCommandSafety.isDangerous("java -jar app.jar >/dev/null 2>&1 &"))
        XCTAssertFalse(LingShuCommandSafety.isDangerous("echo hi > /dev/stdout"))
        XCTAssertFalse(LingShuCommandSafety.isDangerous("cat foo 2>/dev/null"))
        XCTAssertFalse(LingShuCommandSafety.isDangerous("dd if=/dev/zero of=test.bin bs=1m count=1"))
    }

    func testAllowsOrdinaryEngineeringCommands() {
        XCTAssertFalse(LingShuCommandSafety.isDangerous("mvn clean package -DskipTests"))
        XCTAssertFalse(LingShuCommandSafety.isDangerous("npm run build"))
        XCTAssertFalse(LingShuCommandSafety.isDangerous("git commit -m 'x'"))
        XCTAssertFalse(LingShuCommandSafety.isDangerous("python3 manage.py runserver"))
    }

    func testBlocksTrulyDangerous() {
        XCTAssertTrue(LingShuCommandSafety.isDangerous("sudo rm -rf /etc"))
        XCTAssertTrue(LingShuCommandSafety.isDangerous("rm -rf /"))
        XCTAssertTrue(LingShuCommandSafety.isDangerous("mkfs.ext4 /dev/disk2"))
        XCTAssertTrue(LingShuCommandSafety.isDangerous("diskutil eraseDisk JHFS+ X /dev/disk3"))
        XCTAssertTrue(LingShuCommandSafety.isDangerous("shutdown -h now"))
    }

    func testBlocksWriteToBlockDevice() {
        // 写裸块设备(毁盘)仍要拦——伪设备放行不能放过真磁盘。
        XCTAssertTrue(LingShuCommandSafety.isDangerous("echo x > /dev/disk0"))
        XCTAssertTrue(LingShuCommandSafety.isDangerous("dd if=foo.img of=/dev/rdisk2"))
        XCTAssertTrue(LingShuCommandSafety.isDangerous("cat img >> /dev/sda"))
    }
}
