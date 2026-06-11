import Foundation

extension LingShuEngineeringArtifactService {
    func manifestJSON(prompt: String, artifacts: [LingShuMaterializedArtifact], now: Date) -> String {
        let rows = artifacts.map { artifact in
            """
              {
                "title": "\(jsonEscape(artifact.title))",
                "producer": "\(jsonEscape(artifact.producer))",
                "location": "\(jsonEscape(artifact.location))"
              }
            """
        }
            .joined(separator: ",\n")

        return """
        {
          "prompt": "\(jsonEscape(prompt))",
          "createdAt": "\(ISO8601DateFormatter().string(from: now))",
          "artifacts": [
        \(rows)
          ]
        }
        """
    }

    private func jsonEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
