import XCTest
@testable import OpProxyCore

final class RequesterLabelTests: XCTestCase {
    func testParsesAndTrims() {
        let label = RequesterLabel.parse(Data(#"{"name": " Kevin ", "title": "fix flaky tests", "openURL": "app://x", "id": "n1"}"#.utf8))
        XCTAssertEqual(label, RequesterLabel(name: "Kevin", title: "fix flaky tests", openURL: URL(string: "app://x"), id: "n1"))
    }

    func testEmptyOrJunkIsNoLabel() {
        XCTAssertNil(RequesterLabel.parse(Data("{}".utf8)))
        XCTAssertNil(RequesterLabel.parse(Data(#"{"name": "  "}"#.utf8)))
        XCTAssertNil(RequesterLabel.parse(Data("not json".utf8)))
    }

    func testLongNamesAreCut() {
        let label = RequesterLabel.parse(Data(#"{"name": "\#(String(repeating: "k", count: 500))"}"#.utf8))
        XCTAssertEqual(label?.name?.count, 60)
    }

    func testRunsTheCommandWithTheRequest() throws {
        let labeler = OpProxyConfig.Labeler(command: ["/bin/sh", "-c", #"read line; echo "{\"name\": \"$(echo "$line" | tr -dc 0-9)\"}""#],
                                            environment: nil, timeoutSeconds: nil)
        XCTAssertEqual(labeler.label(["pid": 4242])?.name, "4242")
    }

    func testSlowOrFailingCommandsGiveNoLabel() {
        let slow = OpProxyConfig.Labeler(command: ["/bin/sleep", "3"], environment: nil, timeoutSeconds: 0.2)
        let started = Date()
        XCTAssertNil(slow.label([:]))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertNil(OpProxyConfig.Labeler(command: ["/usr/bin/false"], environment: nil, timeoutSeconds: nil).label([:]))
        XCTAssertNil(OpProxyConfig.Labeler(command: ["/nonexistent"], environment: nil, timeoutSeconds: nil).label([:]))
    }

    func testOnlyRequestedVariablesAreForwarded() throws {
        let config = try JSONDecoder().decode(OpProxyConfig.self, from: Data(#"{"requesterLabel": {"command": ["x"], "environment": ["A"]}}"#.utf8))
        XCTAssertEqual(config.labelEnvironment(["A": "1", "B": "2"]), ["A": "1"])
    }
}
