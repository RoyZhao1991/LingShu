import CoreLocation
import Foundation

/// Mac 系统精确定位(CoreLocation)。macOS 用 Wi-Fi/Apple 定位服务,通常能到城市/街区级,比 IP 准。
/// 首次调用会弹一次系统授权框(需 Info.plist 的 NSLocation*UsageDescription + 系统「定位服务」开启)。
/// 未授权/失败/超时返回 nil,由调用方(get_location 工具)回退到 IP 城市级或系统时区。
///
/// 并发:@MainActor 单例;CLLocationManager 的 delegate 回调发生在创建它的主线程,故 delegate 方法用
/// `nonisolated` + `MainActor.assumeIsolated` 安全回到主 actor。延续(continuation)只 resume 一次(取走即置 nil),
/// 配超时兜底,杜绝用户不点授权框时永远挂起。
@MainActor
final class LingShuLocationProvider: NSObject {
    private static var instance: LingShuLocationProvider?

    /// 取当前位置文本(国家·省·市·区);未授权/失败/超时返回 nil。供工具从 nonisolated 上下文 `await` 调用。
    static func current(timeout: TimeInterval = 8) async -> String? {
        let provider = instance ?? {
            let created = LingShuLocationProvider()
            instance = created
            return created
        }()
        return await provider.resolve(timeout: timeout)
    }

    private let manager = CLLocationManager()
    private var locationCont: CheckedContinuation<CLLocation?, Never>?
    private var authCont: CheckedContinuation<CLAuthorizationStatus, Never>?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    private func resolve(timeout: TimeInterval) async -> String? {
        let status = await ensureAuthorized()
        guard status == .authorizedAlways || status == .authorized else { return nil }
        guard let location = await oneShotLocation(timeout: timeout) else { return nil }
        return await reverseGeocode(location)
    }

    private func ensureAuthorized() async -> CLAuthorizationStatus {
        let status = manager.authorizationStatus
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { (cont: CheckedContinuation<CLAuthorizationStatus, Never>) in
            authCont = cont
            manager.requestWhenInUseAuthorization()
            Task { @MainActor in   // 兜底:用户一直不点授权框也别永远挂着
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if let c = self.authCont { self.authCont = nil; c.resume(returning: self.manager.authorizationStatus) }
            }
        }
    }

    private func oneShotLocation(timeout: TimeInterval) async -> CLLocation? {
        await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            locationCont = cont
            manager.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let c = self.locationCont { self.locationCont = nil; c.resume(returning: nil) }
            }
        }
    }

    private func reverseGeocode(_ location: CLLocation) async -> String? {
        guard let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location),
              let p = placemarks.first else { return nil }
        let parts = [p.country, p.administrativeArea, p.locality, p.subLocality].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension LingShuLocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus   // 先取 Sendable 值,别把 manager 带进 MainActor 闭包(Swift 6 数据竞争)
        MainActor.assumeIsolated {
            guard status != .notDetermined, let c = authCont else { return }
            authCont = nil
            c.resume(returning: status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last   // 先取出,别捕获非 Sendable 的 manager
        MainActor.assumeIsolated {
            guard let c = locationCont else { return }
            locationCont = nil
            c.resume(returning: last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            guard let c = locationCont else { return }
            locationCont = nil
            c.resume(returning: nil)
        }
    }
}
