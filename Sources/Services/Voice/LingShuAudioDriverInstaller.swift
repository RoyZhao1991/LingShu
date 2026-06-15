import Foundation

/// 灵枢虚拟麦克风的**自安装**——驱动随 app 包发布,灵枢自己装上,**一次系统授权**即成为常驻能力,
/// 用户不必手动跑任何脚本/sudo。这才符合"安装灵枢后就该有这个能力"。
///
/// 机制:把随包的 `LingShuAudioDriver.driver` 经一次"管理员授权"(osascript `with administrator privileges`,
/// 系统原生密码框,只弹一次)拷到 `/Library/Audio/Plug-Ins/HAL/` + 重启 coreaudiod。装好后永久生效。
///
/// 注:这是**安装机制**(已可用);驱动本体的属性模型/IO 需在本机一轮 compile→install→『音频 MIDI 设置』
/// 出现设备→会议听见 收敛后,设备才真正可用(见 Drivers/LingShuAudioDriver/README)。
enum LingShuAudioDriverInstaller {
    static let driverBundleName = "LingShuAudioDriver.driver"
    static let halDir = "/Library/Audio/Plug-Ins/HAL"
    static var installedPath: String { halDir + "/" + driverBundleName }

    enum InstallResult: Equatable { case alreadyInstalled, installed, missingBundle, authDenied, failed(String) }

    /// 是否已装(系统目录里有驱动)。
    static func isInstalled() -> Bool { FileManager.default.fileExists(atPath: installedPath) }

    /// 随包驱动路径(build-app.sh 把编译好的 .driver 拷进 app Resources)。
    static func bundledDriverPath() -> String? {
        if let res = Bundle.main.resourceURL?.appendingPathComponent(driverBundleName).path,
           FileManager.default.fileExists(atPath: res) { return res }
        // 开发期回退:源码树编译产物。
        let dev = "/Users/example/app/LingShuMac/Drivers/LingShuAudioDriver/build/" + driverBundleName
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }

    /// 没装就装(一次管理员授权)。已装直接返回。**主线程外调用**(会弹系统授权框、可能阻塞)。
    static func installIfNeeded() -> InstallResult {
        if isInstalled() { return .alreadyInstalled }
        guard let src = bundledDriverPath() else { return .missingBundle }
        // osascript 一次性管理员授权:拷贝 + 重启 coreaudiod。路径转义防注入。
        let escSrc = src.replacingOccurrences(of: "\"", with: "\\\"")
        let shell = "mkdir -p \\\"\(halDir)\\\" && rm -rf \\\"\(installedPath)\\\" && cp -R \\\"\(escSrc)\\\" \\\"\(halDir)/\\\" && killall coreaudiod"
        let osa = "do shell script \"\(shell)\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", osa]
        let err = Pipe(); proc.standardError = err
        do { try proc.run() } catch { return .failed(error.localizedDescription) }
        proc.waitUntilExit()
        if proc.terminationStatus == 0 { return .installed }
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return msg.contains("-128") || msg.lowercased().contains("cancel") ? .authDenied : .failed(msg.prefix(160).description)
    }
}
