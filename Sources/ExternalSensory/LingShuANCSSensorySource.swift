import Foundation
import CoreBluetooth

/// 外接感知源 · **iPhone 系统通知桥（ANCS over BLE）**。
///
/// 角色（§1）：iPhone = Notification Provider（GATT Server）；本源 = Notification Consumer
/// （GATT Client）。这里走 **posture #1：Mac 作 central** 主动连 iPhone、发现并订阅 ANCS。
///
/// ⚠️ M0 spike 现实（[[no-fake-demos]] 如实标注）：iPhone 通常**不向任意 central 广播 ANCS
/// service**，ANCS 只暴露给**已配对（bond）的配件**。因此纯 central 扫描很可能发现不到 ANCS——
/// 这正是方案 §1 的头号风险。本实现把链路写**结构完整**（扫描→连接→发现 ANCS→订阅 Notification
/// Source→Control Point 取属性→Data Source 重组→归一），但在 macOS 上能否真订到，由真机配对验证；
/// 订不到时**如实**发 `.unavailable`，由 Hub 无缝切到 EventKit 兜底（§8）。解析逻辑见
/// `LingShuANCSProtocol`（已单测）。
final class LingShuANCSSensorySource: NSObject, LingShuExternalSensorySource, @unchecked Sendable {
    static let sourceID = "ancs.iphone-bridge"

    let descriptor = LingShuExternalSensoryDescriptor(
        id: LingShuANCSSensorySource.sourceID,
        displayName: "iPhone 通知桥",
        englishName: "iPhone Alerts (ANCS)",
        channel: .phoneNotifications,
        requiresPairing: true,
        summary: "通过蓝牙读 iPhone 系统通知（微信/钉钉/iMessage…），需在 iPhone 上确认配对",
        englishSummary: "Read iPhone system notifications over BLE; confirm pairing on iPhone"
    )

    /// CoreBluetooth 必须有自己的串行队列——这就是本模块的独立线程。
    private let bleQueue = DispatchQueue(label: "lingshu.sensory.ancs")
    private var central: CBCentralManager?
    /// 外设广播器:以灵枢的对外名(中文「灵枢」/ 英文「Nous」)对外广播 BLE 存在
    /// (plan §1 posture #2 的广播半边)。名字随界面语言切换。
    private var peripheralManager: CBPeripheralManager?
    /// 当前广播用的蓝牙名(i18n;默认中文)。读写都在 bleQueue 上。
    private var advertisedName = "灵枢"
    private var phone: CBPeripheral?
    private var controlPoint: CBCharacteristic?
    private var dataSource: CBCharacteristic?
    private var continuation: AsyncStream<LingShuExternalSensorySignal>.Continuation?

    /// 已收到 Source 包但属性尚未取回的待办（UID → Source 包）。
    private var pendingPackets: [UInt32: LingShuANCSProtocol.SourcePacket] = [:]
    /// Data Source 分片重组缓冲。
    private var dataSourceBuffer = Data()
    /// 扫描超时:扫不到广播 ANCS 的设备就如实报不可用,不无限"连接中"。
    private var scanTimeoutWork: DispatchWorkItem?
    /// 附近蓝牙外设去重 + 计数(仅诊断:证明蓝牙在扫,但没有设备暴露 ANCS)。
    private var seenPeerIDs = Set<UUID>()
    private var nearbyCount = 0
    /// 扫不到 ANCS 多久就判定不可用(秒)。
    private let scanTimeout: TimeInterval = 12

    func activate() -> AsyncStream<LingShuExternalSensorySignal> {
        AsyncStream { continuation in
            bleQueue.async { [weak self] in
                guard let self else { continuation.finish(); return }
                self.continuation = continuation
                self.continuation?.yield(.status(.connecting))
                // 在本模块私有队列上起 central —— 回调都落在这条线程。
                self.central = CBCentralManager(delegate: self, queue: self.bleQueue)
                // 同时起外设广播器:对外以「灵枢/Nous」名义广播 BLE 存在。
                self.peripheralManager = CBPeripheralManager(delegate: self, queue: self.bleQueue)
            }
            continuation.onTermination = { [weak self] _ in self?.teardown() }
        }
    }

    func deactivate() {
        bleQueue.async { [weak self] in self?.continuation?.finish() }
    }

    /// 切换广播用的蓝牙名(界面语言变 → 中文「灵枢」/ 英文「Nous」)。立即重广播。
    func updateAdvertisedName(_ name: String) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != self.advertisedName else { return }
            self.advertisedName = trimmed
            self.startAdvertisingName()
        }
    }

    /// 在 bleQueue 上重启广播(仅当外设广播器已就绪)。
    private func startAdvertisingName() {
        guard let pm = peripheralManager, pm.state == .poweredOn else { return }
        pm.stopAdvertising()
        pm.startAdvertising([CBAdvertisementDataLocalNameKey: advertisedName])
    }

    private func teardown() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.scanTimeoutWork?.cancel()
            self.scanTimeoutWork = nil
            if let phone = self.phone { self.central?.cancelPeripheralConnection(phone) }
            self.central?.stopScan()
            self.peripheralManager?.stopAdvertising()
            self.peripheralManager = nil
            self.central = nil
            self.phone = nil
            self.controlPoint = nil
            self.dataSource = nil
            self.pendingPackets.removeAll()
            self.dataSourceBuffer.removeAll()
            self.continuation = nil
        }
    }

    private func emit(_ signal: LingShuExternalSensorySignal) {
        continuation?.yield(signal)
    }
}

// MARK: - CBCentralManagerDelegate（回调跑在 bleQueue 上）

extension LingShuANCSSensorySource: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            emit(.status(.connecting))
            // 已配对/已连接的 iPhone 可能已经把 ANCS 暴露出来——优先检索已连接的。
            let connected = central.retrieveConnectedPeripherals(
                withServices: [CBUUID(string: LingShuANCSProtocol.serviceUUID)]
            )
            if let phone = connected.first {
                connect(to: phone, central: central)
            } else {
                startDiscovery(central)
            }
        case .unauthorized:
            emit(.status(.unavailable("蓝牙未授权（系统设置 → 隐私 → 蓝牙）")))
        case .poweredOff:
            emit(.status(.unavailable("蓝牙已关闭")))
        case .unsupported:
            emit(.status(.unavailable("本机不支持蓝牙 LE")))
        default:
            emit(.status(.connecting))
        }
    }

    /// 起扫描:**不能只按 ANCS 过滤**——iPhone 不向任意 Mac 广播 ANCS,过滤=永远空、永远"连接中"。
    /// 扫全部外设(诊断:证明蓝牙在工作),但**只对真正广播/solicit ANCS 的设备自动连**(几乎不会发生,
    /// 但保留正确路径)。超时仍无 ANCS 设备就如实报不可用。
    private func startDiscovery(_ central: CBCentralManager) {
        nearbyCount = 0
        seenPeerIDs.removeAll()
        central.scanForPeripherals(withServices: nil, options: nil)
        let work = DispatchWorkItem { [weak self] in self?.handleScanTimeout() }
        scanTimeoutWork = work
        bleQueue.asyncAfter(deadline: .now() + scanTimeout, execute: work)
    }

    private func handleScanTimeout() {
        guard phone == nil else { return }   // 已连上就别覆盖
        central?.stopScan()
        emit(.status(.unavailable(
            "未发现可配对的 ANCS 设备(附近已扫到 \(nearbyCount) 个蓝牙外设,但无一暴露通知服务)。"
            + "iOS 不向第三方 Mac 应用开放 ANCS——这是 macOS 端的已知限制(M0)。请改用「日历+提醒事项」。"
        )))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        if seenPeerIDs.insert(peripheral.identifier).inserted { nearbyCount += 1 }
        let ancs = CBUUID(string: LingShuANCSProtocol.serviceUUID)
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let solicited = (advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID]) ?? []
        // 只对真广播/solicit ANCS 的设备自动连(不盲连任意外设)。
        guard advertised.contains(ancs) || solicited.contains(ancs) else { return }
        scanTimeoutWork?.cancel()
        connect(to: peripheral, central: central)
    }

    private func connect(to peripheral: CBPeripheral, central: CBCentralManager) {
        scanTimeoutWork?.cancel()
        central.stopScan()
        phone = peripheral
        peripheral.delegate = self
        emit(.status(.pairing))
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // 发现 ANCS service —— 订/读需要加密的特征会触发 iPhone 弹配对框（§3 步骤1）。
        peripheral.discoverServices([CBUUID(string: LingShuANCSProtocol.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        emit(.status(.unavailable("连接失败：\(error?.localizedDescription ?? "未知")")))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        controlPoint = nil
        dataSource = nil
        emit(.status(.connecting))
        // 断线重连（iPhone 可能进出范围）。
        if central.state == .poweredOn { central.connect(peripheral, options: nil) }
    }
}

// MARK: - CBPeripheralManagerDelegate（对外广播灵枢/Nous 名,回调跑在 bleQueue 上）

extension LingShuANCSSensorySource: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            startAdvertisingName()
        case .poweredOff:
            emit(.fatal("蓝牙已关闭——无可用的外设广播器,无法启用 iPhone 通知桥。请在系统里打开蓝牙后重试。"))
        case .unsupported:
            emit(.fatal("本机不支持蓝牙外设广播(BLE peripheral),无法启用 iPhone 通知桥。"))
        case .unauthorized:
            emit(.fatal("蓝牙未授权——请在「系统设置 → 隐私与安全性 → 蓝牙」中允许灵枢,再重试。"))
        case .resetting, .unknown:
            break   // 瞬态,等下一次状态回调
        @unknown default:
            break
        }
    }
}

// MARK: - CBPeripheralDelegate（回调跑在 bleQueue 上）

extension LingShuANCSSensorySource: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: {
            $0.uuid == CBUUID(string: LingShuANCSProtocol.serviceUUID)
        }) else {
            emit(.status(.unavailable("对端未暴露 ANCS（很可能 macOS 作 central 不放行，见 M0 spike）")))
            return
        }
        peripheral.discoverCharacteristics([
            CBUUID(string: LingShuANCSProtocol.notificationSourceUUID),
            CBUUID(string: LingShuANCSProtocol.controlPointUUID),
            CBUUID(string: LingShuANCSProtocol.dataSourceUUID)
        ], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case CBUUID(string: LingShuANCSProtocol.notificationSourceUUID):
                peripheral.setNotifyValue(true, for: characteristic)   // 订阅触发加密配对
            case CBUUID(string: LingShuANCSProtocol.dataSourceUUID):
                dataSource = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case CBUUID(string: LingShuANCSProtocol.controlPointUUID):
                controlPoint = characteristic
            default:
                break
            }
        }
        emit(.status(.streaming))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        switch characteristic.uuid {
        case CBUUID(string: LingShuANCSProtocol.notificationSourceUUID):
            handleNotificationSource(value, peripheral: peripheral)
        case CBUUID(string: LingShuANCSProtocol.dataSourceUUID):
            handleDataSource(value)
        default:
            break
        }
    }

    /// 收到一条 Notification Source 包：Added/Modified → 向 Control Point 请详细属性。
    private func handleNotificationSource(_ data: Data, peripheral: CBPeripheral) {
        guard let packet = LingShuANCSProtocol.parseSourcePacket(data) else { return }
        guard packet.eventID != .removed else {
            pendingPackets[packet.notificationUID] = nil
            return
        }
        guard let controlPoint else { return }
        pendingPackets[packet.notificationUID] = packet
        let request = LingShuANCSProtocol.buildGetNotificationAttributes(uid: packet.notificationUID)
        peripheral.writeValue(request, for: controlPoint, type: .withResponse)
    }

    /// Data Source 分片到达：累积重组，解析出属性后组装归一通知发往 Hub + 下游蒸馏。
    private func handleDataSource(_ data: Data) {
        dataSourceBuffer.append(data)
        guard let response = LingShuANCSProtocol.parseAttributeResponse(dataSourceBuffer) else { return }
        // 需要 message 才算一条完整通知（否则继续等分片）。
        guard response.attributes[LingShuANCSProtocol.NotificationAttributeID.message.rawValue] != nil
                || response.attributes[LingShuANCSProtocol.NotificationAttributeID.title.rawValue] != nil else { return }

        dataSourceBuffer.removeAll()
        guard let packet = pendingPackets.removeValue(forKey: response.notificationUID) else { return }
        let notification = LingShuANCSProtocol.makeNotification(
            sourceID: descriptor.id,
            packet: packet,
            attributes: response.attributes
        )
        emit(.notification(notification))
        emit(.reading(notification.asReading(sourceID: descriptor.id)))
    }
}
