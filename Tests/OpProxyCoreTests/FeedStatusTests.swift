import XCTest
@testable import OpProxyCore

final class FeedStatusTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let lost = Date(timeIntervalSince1970: 900_000)

    func testAuthorizedReportsSinceWhen() {
        let status = FeedStatus(AuthWindow(signedIn: true, authorizedAt: start), prompting: false, lostSince: lost)
        XCTAssertTrue(status.ok)
        XCTAssertEqual(status.json["since"] as? Int64, 1_000_000_000)
        XCTAssertNil(status.json["until"], "an SDK authorization has no set end")
        XCTAssertNil(status.json["title"])
    }

    func testSignedOutIsLostSinceTheFeedSawItGo() {
        let status = FeedStatus(AuthWindow(signedIn: false, authorizedAt: nil), prompting: false, lostSince: lost)
        XCTAssertFalse(status.ok)
        XCTAssertNil(status.json["until"])
        XCTAssertEqual(status.json["since"] as? Int64, 900_000_000)
        XCTAssertEqual(status.json["title"] as? String, FeedStatus.lostTitle)
    }

    func testSaysWhenThePromptIsUp() {
        let window = AuthWindow(signedIn: false, authorizedAt: nil)
        let waiting = FeedStatus(window, prompting: true, lostSince: lost)
        let idle = FeedStatus(window, prompting: false, lostSince: lost)
        XCTAssertNotEqual(waiting, idle)
        XCTAssertTrue(waiting.detail.contains("asking"))
    }
}
