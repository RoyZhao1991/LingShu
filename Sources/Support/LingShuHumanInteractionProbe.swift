import Foundation

enum LingShuHumanInteractionProbe {
    static func waitUntilSatisfied(_ probe: LingShuHumanInteractionRequest.CompletionProbe) async -> Bool {
        guard probe.kind != .manual else { return false }
        let deadline = Date().addingTimeInterval(probe.timeoutSeconds)
        while !Task.isCancelled, Date() < deadline {
            if await isSatisfied(probe) { return true }
            let nanoseconds = UInt64(probe.intervalSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
        return false
    }

    private static func isSatisfied(_ probe: LingShuHumanInteractionRequest.CompletionProbe) async -> Bool {
        switch probe.kind {
        case .manual:
            return false
        case .fileExists:
            let path = NSString(string: probe.target).expandingTildeInPath
            return !path.isEmpty && FileManager.default.fileExists(atPath: path)
        case .httpStatus:
            guard let url = URL(string: probe.target), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return false
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = min(max(probe.intervalSeconds, 1), 15)
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return false }
                if let expected = probe.expectedStatus { return http.statusCode == expected }
                return (200..<400).contains(http.statusCode)
            } catch {
                return false
            }
        }
    }
}
