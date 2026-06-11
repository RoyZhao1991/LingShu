import Foundation

extension LingShuEngineeringArtifactService {
    func write(_ text: String, to url: URL) -> Bool {
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
