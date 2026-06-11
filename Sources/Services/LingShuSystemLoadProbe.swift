import Foundation

/// 一次系统负载采样：CPU 每核负载、空闲内存占比、正在执行的任务管线数。
struct LingShuSystemLoadSample: Equatable, Sendable {
    var cpuLoadPerCore: Double
    var freeMemoryRatio: Double
    var activePipelines: Int
}

/// 任务准入裁决：现在就开新任务上下文，还是先排队等环境合适。
struct LingShuTaskAdmissionVerdict: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        case proceed
        case queue
    }

    var decision: Decision
    var reason: String
}

/// 任务准入策略：主线程创建新的子任务上下文前，综合"是否已有管线在跑、
/// CPU 负载、内存余量"评定。会造成卡顿/异常时进队列，并把理由告诉用户。
/// 策略是纯函数，便于测试与替换（可插拔）。
enum LingShuTaskAdmissionPolicy {
    static func evaluate(_ sample: LingShuSystemLoadSample) -> LingShuTaskAdmissionVerdict {
        if sample.activePipelines >= 1 {
            return .init(
                decision: .queue,
                reason: "已有任务管线在执行（\(sample.activePipelines) 条）。为保证任务上下文隔离与执行质量，新任务先进入队列，前序完成后自动开始。"
            )
        }
        if sample.cpuLoadPerCore > 1.6 {
            return .init(
                decision: .queue,
                reason: String(format: "当前 CPU 负载偏高（每核 %.1f）。现在开新任务可能造成卡顿，已先排队，负载回落后自动开始。", sample.cpuLoadPerCore)
            )
        }
        if sample.freeMemoryRatio < 0.06 {
            return .init(
                decision: .queue,
                reason: String(format: "当前可用内存吃紧（剩余约 %.0f%%）。已先排队，等内存压力缓解后自动开始。", sample.freeMemoryRatio * 100)
            )
        }
        return .init(decision: .proceed, reason: "系统资源充足，立即创建任务上下文。")
    }
}

/// 真实系统负载探测：loadavg + Mach 虚拟内存统计。读取失败时给保守乐观值
/// （宁可放行也不要因为探测失败把任务卡死在队列里）。
enum LingShuSystemLoadProbe {
    static func currentSample(activePipelines: Int) -> LingShuSystemLoadSample {
        .init(
            cpuLoadPerCore: cpuLoadPerCore() ?? 0,
            freeMemoryRatio: freeMemoryRatio() ?? 1,
            activePipelines: activePipelines
        )
    }

    static func cpuLoadPerCore() -> Double? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) >= 1 else { return nil }
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        return loads[0] / Double(cores)
    }

    static func freeMemoryRatio() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        guard pageSize > 0 else { return nil }
        let pageBytes = Double(pageSize)
        let reclaimable = (Double(stats.free_count) + Double(stats.inactive_count) + Double(stats.purgeable_count)) * pageBytes
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return nil }
        return min(1, max(0, reclaimable / total))
    }
}
