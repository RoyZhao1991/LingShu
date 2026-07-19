import Foundation

enum LingShuPublicLinks {
    static let repository = URL(string: "https://github.com/RoyZhao1991/LingShu")!
    static let discussions = URL(string: "https://github.com/RoyZhao1991/LingShu/discussions")!

    static func firstRunReport(for language: LingShuVoiceLanguage) -> URL {
        let template = language == .chinese
            ? "first_run_report_zh.yml"
            : "first_run_report.yml"
        return URL(string: "https://github.com/RoyZhao1991/LingShu/issues/new?template=\(template)")!
    }
}
