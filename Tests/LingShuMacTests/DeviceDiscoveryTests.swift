import XCTest
@testable import LingShuMac

/// # 硬件设备发现测试(M3:发现没驱动的新外设)
final class DeviceDiscoveryTests: XCTestCase {

    func testParseSerialFiltersNoiseNoBrandGuess() {
        let paths = ["/dev/cu.Bluetooth-Incoming-Port", "/dev/cu.debug-console", "/dev/cu.usbserial-1420", "/dev/cu.SLAB_USBtoUART"]
        let devs = LingShuDeviceDiscovery.parseSerialPorts(paths)
        XCTAssertEqual(devs.count, 2, "蓝牙回环/debug(OS 伪端口)被过滤")
        XCTAssertTrue(devs.allSatisfy { $0.kind == "serial" })
        // 撤定制(§4 #9):不再靠 usbserial/slab/ftdi 关键词猜"这是什么设备",真实名照原样保留、识别交大脑。
        XCTAssertTrue(devs.contains { $0.name == "usbserial-1420" })
        XCTAssertTrue(devs.contains { $0.name == "SLAB_USBtoUART" })
        XCTAssertFalse(devs.contains { $0.detail.contains("USB-serial") || $0.detail.contains("ESP32") }, "零品牌/芯片关键词猜测")
    }

    func testParseUSBWalksItemsWithVidPid() {
        let json = """
        {"SPUSBDataType":[{"_name":"USB31Bus","_items":[
          {"_name":"USB-Serial CH340","vendor_id":"0x1a86","product_id":"0x7523"},
          {"_name":"Hub","_items":[{"_name":"ESP32-CAM","vendor_id":"0x10c4","product_id":"0xea60"}]}
        ]}]}
        """
        let devs = LingShuDeviceDiscovery.parseUSB(Data(json.utf8))
        XCTAssertEqual(devs.count, 2, "递归 _items;无 VID/PID 的 bus/hub 节点跳过")
        XCTAssertTrue(devs.contains { $0.name == "USB-Serial CH340" })
        XCTAssertTrue(devs.contains { $0.name == "ESP32-CAM" })
    }

    func testParseBluetoothConnectedAndBattery() {
        let json = """
        {"SPBluetoothDataType":[{
          "device_connected":[{"Magic Mouse":{"device_address":"AA:BB:CC:DD:EE:FF","device_batteryLevelMain":"75%","device_minorType":"Mouse"}}],
          "device_not_connected":[{"AirPods":{"device_address":"11:22:33:44:55:66"}}]
        }]}
        """
        let devs = LingShuDeviceDiscovery.parseBluetooth(Data(json.utf8))
        XCTAssertEqual(devs.count, 2)
        let mouse = devs.first { $0.name == "Magic Mouse" }
        XCTAssertEqual(mouse?.connected, true)
        XCTAssertTrue(mouse?.detail.contains("电量 75%") ?? false)
        XCTAssertEqual(devs.first { $0.name == "AirPods" }?.connected, false)
    }

    func testDriverGapAnalysis() {
        let battery = LingShuDeviceDiscovery.Device(kind: "power", id: "AppleSmartBattery", name: "电池管理控制器", detail: "", connected: true)
        let serial = LingShuDeviceDiscovery.Device(kind: "serial", id: "/dev/cu.usbserial-1420", name: "usbserial-1420", detail: "", connected: true)
        // 没有任何驱动源 → 都无驱动。
        XCTAssertFalse(LingShuDeviceDiscovery.hasDriver(for: battery, registeredSourceIDs: []))
        // 撤定制(§4 #9):驱动匹配靠**设备真实名/标识 token**(非 battery/电池 关键词)——
        // 驱动 id 含设备标识(applesmartbattery)→ 覆盖;串口名未被任何驱动 id 含 → 仍缺。
        let ids: Set<String> = ["sensor-applesmartbattery-monitor", "eventkit.calendar-reminders"]
        XCTAssertTrue(LingShuDeviceDiscovery.hasDriver(for: battery, registeredSourceIDs: ids))
        XCTAssertFalse(LingShuDeviceDiscovery.hasDriver(for: serial, registeredSourceIDs: ids))
    }

    func testSummarizeMarksGapsAndHints() {
        let devs = [
            LingShuDeviceDiscovery.Device(kind: "power", id: "AppleSmartBattery", name: "电池控制器", detail: "温度/电芯", connected: true),
            LingShuDeviceDiscovery.Device(kind: "serial", id: "/dev/cu.usbserial-1", name: "usbserial-1", detail: "ESP32类", connected: true)
        ]
        let out = LingShuDeviceDiscovery.summarize(devs, registeredSourceIDs: ["sensor-applesmartbattery"])
        XCTAssertTrue(out.contains("✅有驱动"), "电池已有驱动(驱动 id 含设备标识 applesmartbattery)")
        XCTAssertTrue(out.contains("⚠️无驱动组件"), "串口无驱动")
        XCTAssertTrue(out.contains("author_component"), "引导对没驱动设备自写驱动")
    }

    func testSummarizeEmpty() {
        XCTAssertTrue(LingShuDeviceDiscovery.summarize([], registeredSourceIDs: []).contains("未发现"))
    }
}
