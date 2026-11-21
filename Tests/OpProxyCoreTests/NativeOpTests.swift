import XCTest
@testable import OpProxyCore

final class NativeOpTests: XCTestCase {
    let shim = "/Users/me/.opProxy/bin"
    let hasOp: (String) -> Bool = { ["/opt/homebrew/bin/op", "/usr/local/bin/op"].contains($0) }

    func why(_ path: String?, argv0: String = "op") -> String {
        NativeOp.whyDirect(argv0: argv0, path: path, shimDir: shim, isExecutable: hasOp)
    }

    func testHomebrewAheadOfTheShim() {
        // What an agent's "reset PATH" prefix did: system dirs, Homebrew, then opProxy.
        XCTAssertEqual(why("/usr/bin:/bin:/opt/homebrew/bin:/Users/me/.opProxy/bin:/usr/bin"),
                       "/opt/homebrew/bin comes before /Users/me/.opProxy/bin on its PATH")
    }

    func testShimMissingFromPath() {
        XCTAssertEqual(why("/usr/bin:/bin:/opt/homebrew/bin"), "/Users/me/.opProxy/bin isn't on its PATH")
        XCTAssertEqual(why(nil), "/Users/me/.opProxy/bin isn't on its PATH")
    }

    func testFullPath() {
        XCTAssertEqual(why("/Users/me/.opProxy/bin:/opt/homebrew/bin", argv0: "/opt/homebrew/bin/op"),
                       "it ran /opt/homebrew/bin/op by its full path")
    }

    func testShimFirstButStillDirect() {
        // Dirs without an op before the shim don't count; a trailing slash is the same dir.
        XCTAssertEqual(why("/usr/bin:/Users/me/.opProxy/bin/:/opt/homebrew/bin"), "it didn't go through opProxy's op")
    }

    func testDisplayedHidesAssignedValues() {
        XCTAssertEqual(NativeOp.displayed(["item", "create", "--template", "t.json", "password=hunter3", "--vault=Private"]),
                       "op item create --template t.json password=‹hidden› --vault=Private")
        XCTAssertEqual(NativeOp.displayed(["read", "op://V/My Item/totp?attribute=otp"]), "op read 'op://V/My Item/totp?attribute=otp'")
        XCTAssertEqual(NativeOp.displayed(["run", "--env-file", ".env", "--", "env", "TOKEN=abc", "npm", "start"]),
                       "op run --env-file .env -- env TOKEN=‹hidden› npm start")
    }

    func testSubcommandHasNoArguments() {
        XCTAssertEqual(NativeOp.subcommand(["run", "--env-file", ".env", "--", "npm", "start"]), "op run")
        XCTAssertEqual(NativeOp.subcommand(["item", "create", "-", "--vault", "x"]), "op item create")
        XCTAssertEqual(NativeOp.subcommand(["--account", "x.1password.com", "inject", "-i", "t"]), "op inject")
    }

    func testOneLine() {
        XCTAssertEqual(NativeOp.oneLine("a\nb\rc"), "a b c")
        XCTAssertEqual(NativeOp.oneLine("abcdef", limit: 3), "abc…")
    }

    func testFindsOwnProcessByName() {
        let me = ProcessTree.entry(getpid())
        XCTAssertNotNil(me)
        let comm = String((me!.executable as NSString).lastPathComponent.prefix(16))
        XCTAssertTrue(ProcessTree.pids(named: comm).contains(getpid()))
        XCTAssertEqual(ProcessTree.cwd(getpid()), FileManager.default.currentDirectoryPath)
    }
}
