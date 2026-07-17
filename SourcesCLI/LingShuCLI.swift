import Darwin
import Foundation
import LingShuCLIKit

@main
struct LingShuCLI {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let json = removeFlag("--json", from: &arguments)
        let timeout = removeOption("--timeout", from: &arguments).flatMap(TimeInterval.init)
        let command: String
        if let first = arguments.first, ["ask", "answer", "status", "stop", "help", "--help", "-h"].contains(first) {
            command = first
            arguments.removeFirst()
        } else {
            command = "ask"
        }

        let client = LingShuCLIClient()
        do {
            switch command {
            case "ask":
                let prompt = try inputText(arguments)
                let result = try await client.ask(prompt, timeout: timeout)
                output(result, json: json)
                terminate(for: result.status)
            case "answer":
                guard !arguments.isEmpty else { throw UsageError("answer requires a message id and an answer") }
                let messageID = arguments.removeFirst()
                let answer = try inputText(arguments)
                let result = try await client.answer(messageID: messageID, answer: answer, timeout: timeout)
                output(result, json: json)
                terminate(for: result.status)
            case "status":
                outputObject(try await client.status(), json: json)
            case "stop":
                outputObject(try await client.stop(), json: json)
            default:
                printHelp()
            }
        } catch let error as UsageError {
            writeError("Error: \(error.message)\n\n")
            printHelp(toError: true)
            Darwin.exit(64)
        } catch {
            writeError("Error: \(error)\n")
            Darwin.exit(1)
        }
    }

    private static func inputText(_ arguments: [String]) throws -> String {
        let direct = arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty { return direct }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let piped = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !piped.isEmpty else { throw UsageError("no input was provided") }
        return piped
    }

    private static func output(_ result: LingShuCLIResult, json: Bool) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(result), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            return
        }
        switch result.status {
        case .completed:
            print(result.reply)
        case .failed:
            print(result.reply.isEmpty ? "LingShu could not complete the task." : result.reply)
        case .timedOut:
            print(result.reply)
            if !result.recordID.isEmpty { print("Task record: \(result.recordID)") }
        case .needsUserAction:
            guard let interaction = result.interaction else {
                print(result.reply)
                return
            }
            print(interaction.title.isEmpty ? "Your action is required" : interaction.title)
            print(interaction.prompt)
            for material in interaction.materials {
                let label = material.title.isEmpty ? material.kind : material.title
                print("\n\(label):\n\(material.value)")
            }
            if !interaction.options.isEmpty {
                print("\nOptions:")
                for option in interaction.options {
                    let detail = option.detail.isEmpty ? "" : " - \(option.detail)"
                    print("- \(option.label)\(detail)")
                }
            }
            print("\nContinue this exact session with:")
            print("lingshu answer \(result.messageID) \"<your result>\"")
        }
    }

    private static func outputObject(_ object: [String: Any], json: Bool) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: json ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.prettyPrinted, .sortedKeys]
              ),
              let text = String(data: data, encoding: .utf8) else {
            print(String(describing: object))
            return
        }
        print(text)
    }

    private static func terminate(for status: LingShuCLIResult.Status) -> Never {
        switch status {
        case .completed: Darwin.exit(0)
        case .needsUserAction: Darwin.exit(3)
        case .timedOut: Darwin.exit(4)
        case .failed: Darwin.exit(1)
        }
    }

    private static func removeFlag(_ flag: String, from arguments: inout [String]) -> Bool {
        guard let index = arguments.firstIndex(of: flag) else { return false }
        arguments.remove(at: index)
        return true
    }

    private static func removeOption(_ option: String, from arguments: inout [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
        arguments.remove(at: index)
        return arguments.remove(at: index)
    }

    private static func printHelp(toError: Bool = false) {
        let text = """
        LingShu CLI - one request, one main-session response

        Usage:
          lingshu ask [--json] [--timeout SECONDS] "<message>"
          echo "<message>" | lingshu ask
          lingshu answer [--json] <message-id> "<result>"
          lingshu status [--json]
          lingshu stop [--json]

        The CLI connects only to LingShu's local loopback control service. It reuses
        the app's main conversation, memory, authorization, task queue, and human
        interaction protocol. Environment: LINGSHU_MCP_URL, LINGSHU_MCP_PORT,
        LINGSHU_MCP_TOKEN, LINGSHU_CLI_TIMEOUT, LINGSHU_CLI_NO_LAUNCH=1.
        """
        if toError { writeError(text + "\n") } else { print(text) }
    }

    private static func writeError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

private struct UsageError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
