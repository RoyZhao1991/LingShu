import XCTest
@testable import LingShuMac

final class PublicLinksTests: XCTestCase {
    func testFirstRunReportFollowsConfiguredLanguage() {
        XCTAssertEqual(
            LingShuPublicLinks.firstRunReport(for: .english).absoluteString,
            "https://github.com/RoyZhao1991/LingShu/issues/new?template=first_run_report.yml"
        )
        XCTAssertEqual(
            LingShuPublicLinks.firstRunReport(for: .chinese).absoluteString,
            "https://github.com/RoyZhao1991/LingShu/issues/new?template=first_run_report_zh.yml"
        )
    }

    func testCommunityLinksStayOnCanonicalRepository() {
        XCTAssertEqual(LingShuPublicLinks.repository.host, "github.com")
        XCTAssertEqual(LingShuPublicLinks.repository.path, "/RoyZhao1991/LingShu")
        XCTAssertEqual(LingShuPublicLinks.discussions.path, "/RoyZhao1991/LingShu/discussions")
    }
}
