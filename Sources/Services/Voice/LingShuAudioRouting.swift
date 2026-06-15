import Foundation
import CoreAudio

/// 音频输出设备路由——把灵枢的 TTS 定向到指定输出设备(配虚拟麦克风用:TTS→虚拟麦 output→loopback→会议听见)。
/// 纯 Core Audio 枚举/解析;实际定向由 `LingShuStreamingPCMPlayer` 在 start 时读 `preferredOutputDeviceID` 应用。
enum LingShuAudioRouting {

    struct Device: Equatable, Sendable { let id: AudioDeviceID; let uid: String; let name: String }

    /// 灵枢 TTS 期望的输出设备(nil=系统默认)。流式播放器 start 时读取并定向。会议模式设成"灵枢虚拟麦克风"。
    nonisolated(unsafe) static var preferredOutputDeviceID: AudioDeviceID?

    /// 选定输出设备(按名字模糊匹配,如"灵枢虚拟麦克风");找不到返回 false 并清空(回落系统默认)。
    @discardableResult
    static func selectOutputDevice(named target: String) -> Bool {
        let t = target.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { preferredOutputDeviceID = nil; return true }
        if let dev = outputDevices().first(where: { $0.name.lowercased().contains(t) || $0.uid.lowercased().contains(t) }) {
            preferredOutputDeviceID = dev.id
            return true
        }
        preferredOutputDeviceID = nil
        return false
    }

    /// 枚举系统所有**输出**设备(有输出流的)。供 UI 选择 / 路由解析。
    static func outputDevices() -> [Device] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard deviceHasOutput(id) else { return nil }
            return Device(id: id, uid: deviceString(id, kAudioDevicePropertyDeviceUID), name: deviceString(id, kAudioDevicePropertyDeviceNameCFString))
        }
    }

    /// 该设备是否有输出声道(输出 scope 的 stream configuration 非空)。
    private static func deviceHasOutput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, bufferList) == noErr else { return false }
        let abl = bufferList.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func deviceString(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr else { return "" }
        return cf as String
    }
}
