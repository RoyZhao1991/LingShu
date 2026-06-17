import Foundation
import Combine

/// 感知通道(感知链里的"感官"维度,各通道独立采集、在链上汇聚)。
enum LingShuSenseChannel: String, CaseIterable, Sendable {
    case vision         // 眼:摄像头视觉
    case hearing        // 耳(主):麦克风转写,听主人说话
    case ambientAudio   // 耳(环境):系统/会议声音转写,听电脑/会议在说什么
    case screen         // 屏:屏幕语义(VL)
    case externalDevice // 第六感:手机通知/日历等外接设备
    case situation      // 情境:时间/连续使用/后台任务

    var label: String {
        switch self {
        case .vision: "视觉"
        case .hearing: "听觉(麦克风)"
        case .ambientAudio: "听觉(系统声音)"
        case .screen: "屏幕"
        case .externalDevice: "外接设备"
        case .situation: "情境"
        }
    }
    /// 排序权重(格式化窗口时的展示顺序)。
    var order: Int {
        switch self {
        case .vision: 0
        case .hearing: 1
        case .ambientAudio: 2
        case .screen: 3
        case .externalDevice: 4
        case .situation: 5
        }
    }
}

/// 一次采样样本(供采样器把"某通道此刻的内容"投进链)。
struct LingShuPerceptionSample: Equatable, Sendable {
    let channel: LingShuSenseChannel
    let text: String
}

/// 感知链上的一条带时间戳记录。
struct LingShuPerceptionChainEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let timestamp: Date
    let channel: LingShuSenseChannel
    let text: String
}

/// **感知链(多模态实时融合缓冲)**。
///
/// 设计取向(用户拍板 2026-06-17):**感知节奏与大脑节奏解耦**。各感官各自独立线程持续采集
/// (摄像头/麦克风/屏幕/外接设备…),由一个高频(~1s)采样器把每个通道**此刻**的内容**持续**写进
/// 这条链(纯内存、有界、带时间戳);大脑做决策时,**按一个时间窗(默认 5s)瞬时拉取**链上已经备好的
/// 最新多模态态势——**不必当场触发昂贵感知(VL 等)再等结果**,因此快。
///
/// 边界:链只**汇聚事实**,不下结论、不替大脑决策。隐私:纯内存、有界、随感知关闭而清空,不落盘。
@MainActor
final class LingShuPerceptionChain: ObservableObject {
    /// 最新在前的链条(有界)。@Published 供 UI 观测(可选)。
    @Published private(set) var entries: [LingShuPerceptionChainEntry] = []

    /// 缓冲上限:时间窗 + 条数双保险(纯内存,避免无限增长)。
    private let retention: TimeInterval
    private let maxEntries: Int

    init(retention: TimeInterval = 120, maxEntries: Int = 300) {
        self.retention = retention
        self.maxEntries = maxEntries
    }

    /// 投一条采样进链。**连续相同**(同通道、文本未变)只更新时间戳、不重复堆积(免被"时间 14:30"这类
    /// 每秒不变的情境刷屏),让链条只记录真正的变化 + 各通道最新态。
    func note(_ channel: LingShuSenseChannel, _ rawText: String, now: Date = Date()) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 该通道最近一条文本没变 → 只刷新时间戳(不堆重复);变了或没有 → 追加一条。
        if let idx = entries.lastIndex(where: { $0.channel == channel }), entries[idx].text == text {
            entries[idx] = LingShuPerceptionChainEntry(timestamp: now, channel: channel, text: text)
        } else {
            entries.append(LingShuPerceptionChainEntry(timestamp: now, channel: channel, text: text))
        }
        prune(now: now)
    }

    /// 批量投样(采样器一拍把多个通道一起投)。
    func ingest(_ samples: [LingShuPerceptionSample], now: Date = Date()) {
        for sample in samples { note(sample.channel, sample.text, now: now) }
    }

    private func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.timestamp) > retention }
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
    }

    /// 取最近 `seconds` 秒窗内的记录(最新在前)。
    func window(seconds: TimeInterval, now: Date = Date()) -> [LingShuPerceptionChainEntry] {
        entries.filter { now.timeIntervalSince($0.timestamp) <= seconds }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// 把感知链格式化成给大脑的**多模态合并快照**:每通道取最新一条,**标注时延**。
    /// 快通道(视觉/听觉/外接/情境,~1s 采样)只在 `seconds` 窗内才算"此刻";屏幕语义因 VL 昂贵节流、
    /// 天然慢于窗口,放宽到 retention 内但如实标龄——既不漏掉它,也不把陈旧当实时。
    func formattedWindow(seconds: TimeInterval = 5, now: Date = Date()) -> String {
        var latest: [LingShuSenseChannel: LingShuPerceptionChainEntry] = [:]
        for entry in entries.sorted(by: { $0.timestamp > $1.timestamp }) where latest[entry.channel] == nil {
            latest[entry.channel] = entry
        }
        let lines: [String] = latest.values
            .sorted { $0.channel.order < $1.channel.order }
            .compactMap { entry in
                let age = now.timeIntervalSince(entry.timestamp)
                let isSlow = entry.channel == .screen
                guard age <= seconds || (isSlow && age <= retention) else { return nil }
                let ageStr = age < 2 ? "刚刚" : "\(Int(age))s前"
                return "· \(entry.channel.label)(\(ageStr)):\(entry.text)"
            }
        guard !lines.isEmpty else {
            return "【感知链】最近 \(Int(seconds))s 内无活动感知信号(相关传感器可能未开启)。"
        }
        return "【感知链·最近 \(Int(seconds))s(多模态实时融合,标注时延)】\n" + lines.joined(separator: "\n")
    }

    /// 清空(感知总开关关闭/隐私):链是纯内存,关即清。
    func clear() { entries.removeAll() }
}
