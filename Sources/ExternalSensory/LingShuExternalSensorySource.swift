import Foundation

/// 一个外接设备感知源发出的信号：要么是状态变化，要么是一条标准读数。
/// 用一个枚举走同一条 `AsyncStream`，让汇聚端（Hub）单一消费点拿到状态 + 数据。
enum LingShuExternalSensorySignal: Sendable {
    case status(LingShuExternalSensoryStatus)
    case reading(LingShuExternalSensoryReading)
    /// 手机通知专用：除了归一读数，也透传原始通知给下游蒸馏器（M3）。
    case notification(LingShuPhoneNotification)
    /// 致命:本源依赖的能力(如蓝牙外设广播器 CBPeripheralManager)不可用 → Hub 弹警告并**自动关闭**本源。
    case fatal(String)
}

/// 一条需要弹给用户的外接感知警告(如蓝牙不可用)。Identifiable 供 SwiftUI `.alert(item:)`。
struct LingShuExternalSensoryWarning: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}

/// 模块静态描述（注册表 / UI 列举用）。
struct LingShuExternalSensoryDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let englishName: String
    let channel: LingShuExternalSensoryChannel
    /// 是否需要在外部设备上确认配对（ANCS=true，EventKit=false）。
    let requiresPairing: Bool
    /// 一句话能力说明（UI 副标题）。
    let summary: String
    let englishSummary: String

    var id_: String { id }
}

/// **外接设备感知源协议**——每一类外接设备实现一个，跑在自己的线程/隔离域里。
///
/// 约定：
/// - `activate()` 起线程开始采集，返回一条 `AsyncStream`，状态与读数都从这里出来；
///   重复 `activate()` 返回同一条流（幂等）。
/// - `deactivate()` 停线程、断连、结束流——**无缝切换**就是停一个源、起另一个源。
/// - 实现自己负责线程安全（CoreBluetooth 用私有串行队列、EventKit 用自己的 store 队列），
///   把读数经 continuation 投递出来即汇聚到统一感知流。
protocol LingShuExternalSensorySource: AnyObject, Sendable {
    var descriptor: LingShuExternalSensoryDescriptor { get }
    func activate() -> AsyncStream<LingShuExternalSensorySignal>
    func deactivate()
}
