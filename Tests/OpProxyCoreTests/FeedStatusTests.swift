import XCTest
@testable import OpProxyCore

final class FeedStatusTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let lost = Date(timeIntervalSince1970: 900_000)

    func testAuthorizedReportsItsCap() {
        let status = FeedStatus(AuthWindow(signedIn: true, authorizedAt: start), prompting: false, lostSince: lost,
                                now: start.addingTimeInterval(60))
        XCTAssertTrue(status.ok)
        XCTAssertEqual(status.until, start.addingTimeInterval(AuthWindow.hardCap))
        XCTAssertEqual(status.json["until"] as? Int64, 1_000_000_000 + Int64(AuthWindow.hardCap) * 1000)
        XCTAssertEqual(status.json["since"] as? Int64, 1_000_000_000)
        XCTAssertNil(status.json["title"])
    }

    func testSignedOutIsLostSinceTheFeedSawItGo() {
        let status = FeedStatus(AuthWindow(signedIn: false, authorizedAt: nil), prompting: false, lostSince: lost, now: start)
        XCTAssertFalse(status.ok)
        XCTAssertNil(status.json["until"])
        XCTAssertEqual(status.json["since"] as? Int64, 900_000_000)
        XCTAssertEqual(status.json["title"] as? String, FeedStatus.lostTitle)
    }

    func testPastTheCapIsLostEvenIfWhoamiStillPasses() {
        let status = FeedStatus(AuthWindow(signedIn: true, authorizedAt: start), prompting: false, lostSince: lost,
                                now: start.addingTimeInterval(AuthWindow.hardCap + 1))
        XCTAssertFalse(status.ok)
    }

    func testSaysWhenThePromptIsUp() {
        let window = AuthWindow(signedIn: false, authorizedAt: nil)
        let waiting = FeedStatus(window, prompting: true, lostSince: lost, now: start)
        let idle = FeedStatus(window, prompting: false, lostSince: lost, now: start)
        XCTAssertNotEqual(waiting, idle)
        XCTAssertTrue(waiting.detail.contains("asking"))
    }
}
