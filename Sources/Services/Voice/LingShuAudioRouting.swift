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

    // MARK: - 诊断:设备全景(定位"开 VPIO 绑到怪设备导致没麦克风音频")

    static func deviceName(_ id: AudioDeviceID) -> String { deviceString(id, kAudioDevicePropertyDeviceNameCFString) }

    /// 系统当前默认**输入**设备 id。
    static func defaultInputDeviceID() -> AudioDeviceID { defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice) }
    /// 系统当前默认**输出**设备 id。
    static func defaultOutputDeviceID() -> AudioDeviceID { defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice) }

    private static func defaultDeviceID(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    /// 某设备某 scope(输入/输出)的总声道数。
    static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// 内建麦克风(传输类型=Built-in 且有输入声道)的设备 id;找不到返回 nil。
    static func builtInInputDeviceID() -> AudioDeviceID? {
        for id in allDeviceIDs() where channelCount(id, scope: kAudioDevicePropertyScopeInput) > 0 {
            if transportType(id) == kAudioDeviceTransportTypeBuiltIn { return id }
        }
        return nil
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t)
        return t
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// 把设备全景打进诊断日志:默认输入/输出是谁、各几声道、所有带输入的设备列表、内建麦 id。
    /// 用来坐实"VPIO 绑到的 dev 是不是聚合/虚拟设备、真内建麦是哪个"。
    static func logDeviceLandscape() {
        let di = defaultInputDeviceID(), dor = defaultOutputDeviceID()
        lingShuControlLog("voice/devices: 默认输入 id=\(di)「\(deviceName(di))」inCh=\(channelCount(di, scope: kAudioDevicePropertyScopeInput)) | 默认输出 id=\(dor)「\(deviceName(dor))」outCh=\(channelCount(dor, scope: kAudioDevicePropertyScopeOutput)) | 内建麦 id=\(builtInInputDeviceID().map(String.init) ?? "无")")
        for id in allDeviceIDs() where channelCount(id, scope: kAudioDevicePropertyScopeInput) > 0 {
            lingShuControlLog("voice/devices:   输入设备 id=\(id)「\(deviceName(id))」inCh=\(channelCount(id, scope: kAudioDevicePropertyScopeInput))")
        }
    }

    private static func deviceString(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr else { return "" }
        return cf as String
    }
}
