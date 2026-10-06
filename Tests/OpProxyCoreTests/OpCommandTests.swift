import XCTest
@testable import OpProxyCore

final class OpCommandTests: XCTestCase {
    func plan(_ argv: [String]) -> ProxyPlan? {
        if case .proxy(let plan) = OpCommand(argv: argv).routing { return plan }
        return nil
    }

    func testCommonReadOnlyShapesAreProxied() {
        let shapes: [[String]] = [
            ["item", "get", "Issue Tracker API key", "--fields", "label=credential", "--reveal"],
            ["item", "get", "CI token", "--vault", "Private", "--fields", "label=password", "--reveal"],
            ["item", "get", "em5qippbdjh4jgmmhkidhxonka", "--format", "json"],
            ["item", "get", "x", "--vault=Private", "--format=json", "--reveal"],
            ["read", "op://Private/Deploy key/password"],
            ["read", "-n", "op://Private/Build Bot GitHub App/add more/App ID"],
            ["--account", "acme.1password.com", "read", "op://A/B/c"],
        ]
        for argv in shapes {
            let p = plan(argv)
            XCTAssertNotNil(p, "\(argv)")
            XCTAssertNotNil(p?.item, "\(argv)")
            XCTAssertEqual(p?.daemonArgv, argv)
            XCTAssertNil(p?.outFile)
        }
    }

    func testMetadataNeedsNoApproval() {
        XCTAssertNil(plan(["whoami"])?.item)
        XCTAssertNil(plan(["whoami", "--account", "acme.1password.com"])?.item)
        XCTAssertNil(plan(["account", "list"])?.item)
        XCTAssertNil(plan(["vault", "list"])?.item)
        XCTAssertNil(plan(["vault", "get", "Private"])?.item)
        XCTAssertNil(plan(["item", "list", "--vault", "Private", "--format", "json"])?.item)
        XCTAssertNil(plan(["item", "list", "--tags", "platform-service"])?.item)
        XCTAssertNil(plan(["document", "list"])?.item)
        XCTAssertNotNil(plan(["item", "get", "x", "--otp"])?.item)
        XCTAssertNotNil(plan(["document", "get", "x"])?.item)
    }

    func testWritesAndUnknownCommandsPassThrough() {
        let shapes: [[String]] = [
            ["--version"],
            [],
            ["item", "create", "--category", "API Credential", "credential[concealed]=sk-ant-x"],
            ["item", "delete", "abc", "--vault", "Private", "--archive"],
            ["item", "edit", "abc", "password=x"],
            ["run", "--no-masking", "--", "/bin/echo", "ok"],
            ["inject", "-i", "tpl"],
            ["item", "share", "abc", "--expires-in", "1h"],
            ["signin", "--raw"],
            ["plugin", "run", "--", "gh", "auth", "status"],
            ["signin"],
            ["item", "get", "-", "--format", "json"],
            ["item", "get", "x", "--help"],
            ["read", "op://A/B/c", "--config", "/tmp/cfg"],
            ["item", "get", "x", "--out-file", "f"],
            // Secret reads outside the allowlisted shapes
            ["item", "get", "x", "--share-link"],
            ["item", "get", "x", "y"],
            ["item", "get", "--vault", "Private"],
            ["item", "get", "x", "--fields", "a", "--fields", "b"],
            ["read", "op://a/b/c", "op://a/b/d"],
            ["read", "not-a-ref"],
            ["read", "op://a/b/c", "--vault", "x"],
            ["document", "get", "x", "--", "y"],
            ["item", "get", "x", "--debug"],
        ]
        for argv in shapes {
            XCTAssertNil(plan(argv), "\(argv) should pass through")
        }
    }

    func testReadOutFileIsWrittenByShim() throws {
        let p = try XCTUnwrap(plan(["read", "op://Shared/app-api/env", "-o", ".env", "--force"]))
        XCTAssertEqual(p.daemonArgv, ["read", "op://Shared/app-api/env"])
        XCTAssertEqual(p.outFile, OutFile(path: ".env", mode: 0o600, force: true))

        let q = try XCTUnwrap(plan(["read", "--out-file=./key.pem", "--file-mode", "0644", "op://a/b/c"]))
        XCTAssertEqual(q.daemonArgv, ["read", "op://a/b/c"])
        XCTAssertEqual(q.outFile, OutFile(path: "./key.pem", mode: 0o644, force: false))
    }

    func item(_ argv: [String]) throws -> ItemRequest {
        try XCTUnwrap(plan(argv)?.item, "\(argv)")
    }

    static let target = ItemIdentity(itemId: "h3j8k1m6n4p9r2s7t5v0w8x3yz", vaultId: "q4a7m2x9c1v6b3n8z5k0w2e7rt",
                                     title: "Issue Tracker API key", vaultName: "Private")

    func testItemGetIsPinnedToIDs() throws {
        let byName = try item(["item", "get", "Issue Tracker API key", "--fields", "label=credential", "--reveal"])
        XCTAssertEqual(byName.item, "Issue Tracker API key")
        XCTAssertNil(byName.vault)
        XCTAssertEqual(byName.pinned(to: Self.target),
                       ["item", "get", "h3j8k1m6n4p9r2s7t5v0w8x3yz", "--fields", "label=credential", "--reveal",
                        "--vault", "q4a7m2x9c1v6b3n8z5k0w2e7rt"])

        let withVault = try item(["item", "get", "x", "--vault=private", "--format=json"])
        XCTAssertEqual(withVault.vault, "private")
        XCTAssertEqual(withVault.pinned(to: Self.target),
                       ["item", "get", "h3j8k1m6n4p9r2s7t5v0w8x3yz", "--vault=q4a7m2x9c1v6b3n8z5k0w2e7rt", "--format=json"])

        let account = try item(["--account", "acme", "document", "get", "doc", "--vault", "Private"])
        XCTAssertEqual(account.account, "acme")
        XCTAssertEqual(account.pinned(to: Self.target),
                       ["--account", "acme", "document", "get", "h3j8k1m6n4p9r2s7t5v0w8x3yz", "--vault", "q4a7m2x9c1v6b3n8z5k0w2e7rt"])
    }

    func testReadIsPinnedToIDs() throws {
        let r = try item(["read", "-n", "op://Private/Build Bot GitHub App/add more/App ID?attribute=x"])
        XCTAssertEqual(r.item, "Build Bot GitHub App")
        XCTAssertEqual(r.vault, "Private")
        XCTAssertEqual(r.pinned(to: Self.target),
                       ["read", "-n", "op://q4a7m2x9c1v6b3n8z5k0w2e7rt/h3j8k1m6n4p9r2s7t5v0w8x3yz/add more/App ID?attribute=x"])
    }

    func testDescriptions() throws {
        let r = try item(["read", "op://Private/Build Bot GitHub App/add more/App ID"])
        XCTAssertEqual(r.details.map(\.label), ["Section", "Field"])
        XCTAssertEqual(r.details.map(\.value), ["add more", "App ID"])
        XCTAssertEqual(r.summary(Self.target), "read App ID from “Private / Issue Tracker API key”")
        let otp = try item(["read", "op://v/i/one-time password?attribute=otp"])
        XCTAssertEqual(otp.details.last, .init(label: "Options", value: "attribute=otp"))

        let fields = try item(["item", "get", "Chat webhook", "--vault", "private", "--reveal", "--fields", "label=A,type=otp"])
        XCTAssertEqual(fields.details, [.init(label: "Fields", value: "A, type otp")])
        XCTAssertEqual(fields.summary(Self.target), "get A, type otp from “Private / Issue Tracker API key”")
        let all = try item(["item", "get", "x", "--format", "json"])
        XCTAssertEqual(all.details, [.init(label: "Fields", value: "all fields", style: .placeholder)])
        XCTAssertEqual(all.summary(Self.target), "get every field of “Private / Issue Tracker API key”")
    }
}

final class ItemCatalogTests: XCTestCase {
    static let json = Data("""
        [
          {"id": "aaaaaaaaaaaaaaaaaaaaaaaaaa", "title": "Chat webhook", "vault": {"id": "v1", "name": "Private"}},
          {"id": "bbbbbbbbbbbbbbbbbbbbbbbbbb", "title": "Build Bot Tracker App", "vault": {"id": "v1", "name": "Private"}},
          {"id": "cccccccccccccccccccccccccc", "title": "Build Bot Tracker App", "vault": {"id": "v2", "name": "Engineering"}},
          {"id": "dddddddddddddddddddddddddd", "title": "Token", "vault": {"id": "v1", "name": "Private"}},
          {"id": "eeeeeeeeeeeeeeeeeeeeeeeeee", "title": "token", "vault": {"id": "v1", "name": "Private"}}
        ]
        """.utf8)

    func id(_ match: ItemCatalog.Match) -> String? {
        if case .one(let found) = match { return found.itemId }
        return nil
    }

    func testResolution() throws {
        let catalog = try ItemCatalog(json: Self.json)
        XCTAssertEqual(id(catalog.resolve(item: "aaaaaaaaaaaaaaaaaaaaaaaaaa", vault: nil)), "aaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(id(catalog.resolve(item: "Chat webhook", vault: "private")), "aaaaaaaaaaaaaaaaaaaaaaaaaa", "vault name in any case")
        XCTAssertEqual(id(catalog.resolve(item: "chat webhook", vault: nil)), "aaaaaaaaaaaaaaaaaaaaaaaaaa", "title in any case")
        XCTAssertEqual(id(catalog.resolve(item: "Slack", vault: nil)), nil, "never a substring")
        XCTAssertEqual(catalog.resolve(item: "Chat webhook", vault: "Engineering"), .none)
        XCTAssertEqual(id(catalog.resolve(item: "Build Bot Tracker App", vault: "v2")), "cccccccccccccccccccccccccc")
        guard case .many(let both) = catalog.resolve(item: "Build Bot Tracker App", vault: nil) else {
            return XCTFail("a title in two vaults is ambiguous")
        }
        XCTAssertEqual(both.map(\.vaultName), ["Private", "Engineering"])
        XCTAssertEqual(id(catalog.resolve(item: "token", vault: nil)), "eeeeeeeeeeeeeeeeeeeeeeeeee", "an exact title wins")
        if case .many = catalog.resolve(item: "TOKEN", vault: nil) {} else { XCTFail("two titles differing only in case") }
    }
}

final class AgentSessionTests: XCTestCase {
    func testDetectsEachAgent() {
        XCTAssertEqual(AgentSession.detect(environment: ["CLAUDE_CODE_SESSION_ID": "c1", "SPACETERM_SURFACE_ID": "s1"]),
                       AgentSession(agent: .claude, sessionId: "c1"))
        XCTAssertEqual(AgentSession.detect(environment: ["CODEX_THREAD_ID": "x1"])?.agent, .codex)
        XCTAssertEqual(AgentSession.detect(environment: ["CURSOR_CONVERSATION_ID": "u1", "CURSOR_AGENT": "1"])?.agent, .cursor)
        XCTAssertNil(AgentSession.detect(environment: ["CLAUDE_CODE_SESSION_ID": ""]))
        XCTAssertNil(AgentSession.detect(environment: ["TERM": "xterm"]))
    }

    func testNestedAgentsResolveToNearestProcess() {
        let env = ["CLAUDE_CODE_SESSION_ID": "claude-outer", "CODEX_THREAD_ID": "codex-inner"]
        let chain = [
            ProcessEntry(pid: 5, ppid: 4, executable: "/bin/zsh", argv: ["/bin/zsh", "-lc", "op read op://a/b/c"]),
            ProcessEntry(pid: 4, ppid: 3, executable: "/opt/homebrew/bin/codex", argv: ["codex", "exec"]),
            ProcessEntry(pid: 3, ppid: 2, executable: "/bin/zsh", argv: ["/bin/zsh", "-c", "codex exec"]),
            ProcessEntry(pid: 2, ppid: 1, executable: "/opt/homebrew/Caskroom/claude-code@latest/2.1.284/claude", argv: ["claude"]),
        ]
        XCTAssertEqual(AgentSession.detect(environment: env, ancestry: { chain })?.sessionId, "codex-inner")
        XCTAssertEqual(AgentSession.detect(environment: env, ancestry: { Array(chain.dropFirst(2)) })?.sessionId,
                       "claude-outer")
        XCTAssertEqual(AgentSession.detect(environment: env)?.agent, .claude, "no tree: fixed order")

        let cursorEnv = ["CLAUDE_CODE_SESSION_ID": "claude-outer", "CURSOR_CONVERSATION_ID": "cursor-inner"]
        let cursorChain = [
            ProcessEntry(pid: 4, ppid: 3, executable: "/Users/u/.local/share/cursor-agent/versions/1/node",
                         argv: ["/Users/u/.local/bin/cursor-agent", "/Users/u/.local/share/cursor-agent/versions/1/index.js"]),
            ProcessEntry(pid: 2, ppid: 1, executable: "/opt/claude", argv: ["claude"]),
        ]
        XCTAssertEqual(AgentSession.detect(environment: cursorEnv, ancestry: { cursorChain })?.sessionId, "cursor-inner")
    }

    func testSpacetermNodeIdSurvivesRestarts() {
        XCTAssertEqual(SpacetermSurface.nodeId(environment: ["SPACETERM_SURFACE_ID": "pty-2", "SPACETERM_NODE_ID": "n1"]), "n1")
        XCTAssertEqual(SpacetermSurface.nodeId(environment: ["SPACETERM_SURFACE_ID": "s1", "SPACETERM_NODE_ID": ""]), "s1")
        XCTAssertNil(SpacetermSurface.nodeId(environment: [:]))
    }

    func testSpacetermSurfaceReply() {
        let named = SpacetermSurface.from(reply: ["type": "script-get-node-result", "agentName": " Kevin ",
                                                  "node": ["name": "", "shellTitleHistory": ["fix flaky tests", "zsh"]]],
                                          nodeId: "n1")
        XCTAssertEqual(named, SpacetermSurface(nodeId: "n1", title: "fix flaky tests", agentName: "Kevin"))
        XCTAssertEqual(SpacetermSurface.from(reply: ["error": "unknown-node"], nodeId: "n1"), SpacetermSurface(nodeId: "n1"))
    }

    func testEnvironmentForwarding() {
        let env = ["OP_ACCOUNT": "a", "OP_FORMAT": "json", "OP_SESSION_x": "t", "PATH": "/bin"]
        XCTAssertEqual(ProxyRequest.forwardedEnvironment(env), ["OP_ACCOUNT": "a", "OP_FORMAT": "json"])
        XCTAssertTrue(ProxyRequest.bypassesDesktopApp(["OP_SERVICE_ACCOUNT_TOKEN": "t"]))
        XCTAssertTrue(ProxyRequest.bypassesDesktopApp(["OP_SESSION_my": "t"]))
        XCTAssertFalse(ProxyRequest.bypassesDesktopApp(["OP_ACCOUNT": "a"]))
    }
}

final class ApprovalStoreTests: XCTestCase {
    var url: URL!
    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("approvals-\(UUID()).json")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    let key = ApprovalKey(audience: .session(agent: .claude, sessionId: "s"), item: ItemRef(account: nil, vaultId: "v", itemId: "i"))
    // Stand-in for the Secure Enclave signature: a keyed hash only the test knows.
    static func fakeSign(_ d: Data) -> Data { Data((d + Data("secret".utf8)).reversed()) }
    static let fakeVerify: (Data, Data) -> Bool = { fakeSign($0) == $1 }
    func store(now: @escaping () -> Date = Date.init) -> ApprovalStore {
        ApprovalStore(url: url, now: now, verify: Self.fakeVerify)
    }

    func variant(_ audience: ApprovalAudience = .session(agent: .claude, sessionId: "s"), item: ItemRef? = nil) -> ApprovalKey {
        ApprovalKey(audience: audience, item: item ?? key.item)
    }

    static let otherItem = ItemRef(account: nil, vaultId: "v", itemId: "other")
    static let otherAccount = ItemRef(account: "acme", vaultId: "v", itemId: "i")

    func testExactKeyAndDay() throws {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = store(now: { now })
        XCTAssertFalse(store.isApproved(key))
        try store.approve(key, lifetime: .day, sessionLabel: "t", sign: Self.fakeSign)
        XCTAssertTrue(store.isApproved(key))
        XCTAssertTrue(store.isApproved(variant()), "same session ID, e.g. resumed in a new process")
        XCTAssertFalse(store.isApproved(variant(.session(agent: .claude, sessionId: "other"))))
        XCTAssertFalse(store.isApproved(variant(.session(agent: .codex, sessionId: "s"))))
        XCTAssertFalse(store.isApproved(variant(.process(agent: .claude, instance: "10@1"))))
        XCTAssertFalse(store.isApproved(variant(item: Self.otherItem)))
        XCTAssertFalse(store.isApproved(variant(item: Self.otherAccount)))

        now += 24 * 3600 - 1
        XCTAssertTrue(self.store(now: { now }).isApproved(key), "persists across instances")
        now += 2
        XCTAssertFalse(store.isApproved(key), "expires after a day")
    }

    func testAllAgentsCoversEveryAudienceForThatItemOnly() throws {
        let store = store()
        try store.approve(key.reaching(.allAgents), lifetime: .forever, sessionLabel: nil, grantedTo: key.audience,
                          sign: Self.fakeSign)
        XCTAssertTrue(store.isApproved(key))
        XCTAssertTrue(store.isApproved(variant(.session(agent: .codex, sessionId: "x"))))
        XCTAssertTrue(store.isApproved(variant(.process(agent: .cursor, instance: "1@1"))))
        XCTAssertFalse(store.isApproved(variant(item: Self.otherItem)))
        XCTAssertFalse(store.isApproved(variant(.session(agent: .codex, sessionId: "x"), item: Self.otherAccount)))
        XCTAssertEqual(store.active.first?.grantedTo, key.audience)
    }

    func testWideningReplacesTheNarrowerEntry() throws {
        let store = store()
        try store.approve(key, lifetime: .day, sessionLabel: nil, sign: Self.fakeSign)
        try store.approve(key.reaching(.allAgents), lifetime: .forever, sessionLabel: nil, sign: Self.fakeSign)
        XCTAssertEqual(store.active.map(\.key.audience), [.allAgents])
    }

    func testAmendResignsAndKeepsApprovalTime() throws {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = store(now: { now })
        try store.approve(key, lifetime: .day, sessionLabel: "s", itemLabel: "Item", sign: Self.fakeSign)
        let approvedAt = try XCTUnwrap(store.active.first?.approvedAt)
        now += 60
        XCTAssertTrue(try store.amend(key, expiresAt: ApprovalStore.forever, sign: Self.fakeSign))
        now += 30 * 24 * 3600
        XCTAssertTrue(store.isApproved(key), "extended well past the original day")
        XCTAssertEqual(store.active.first?.approvedAt, approvedAt)
        XCTAssertEqual(store.active.first?.itemLabel, "Item")
        XCTAssertFalse(try store.amend(variant(.session(agent: .codex, sessionId: "x")), expiresAt: ApprovalStore.forever,
                                       sign: Self.fakeSign))

        // Widen to all agents, then narrow back to the session that asked.
        let codex = variant(.session(agent: .codex, sessionId: "x"))
        XCTAssertTrue(try store.amend(key, audience: .allAgents, sign: Self.fakeSign))
        XCTAssertTrue(store.isApproved(codex))
        XCTAssertEqual(store.active.first?.grantedTo, key.audience)
        XCTAssertTrue(try store.amend(key.reaching(.allAgents), audience: key.audience, sign: Self.fakeSign))
        XCTAssertFalse(store.isApproved(codex))
        XCTAssertTrue(store.isApproved(key))
        XCTAssertEqual(store.active.first?.approvedAt, approvedAt)
    }

    func testRevokeFromAnotherInstanceIsSeen() throws {
        let daemonStore = store()
        try daemonStore.approve(key, lifetime: .day, sessionLabel: nil, sign: Self.fakeSign)
        Thread.sleep(forTimeInterval: 0.01)
        XCTAssertEqual(try store().revoke { $0.key.audience.sessionId == "s" }, 1)
        XCTAssertFalse(daemonStore.isApproved(key))
    }

    func testTamperedEntriesAreIgnored() throws {
        try store().approve(key, lifetime: .day, sessionLabel: nil, sign: Self.fakeSign)
        func rewrite(_ edit: (inout [String: Any]) -> Void) throws {
            var entries = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
            edit(&entries[0])
            try JSONSerialization.data(withJSONObject: entries).write(to: url)
        }
        XCTAssertTrue(store().isApproved(key))

        // Replay onto another session, or widen to all agents.
        try rewrite { e in var k = e["key"] as! [String: Any]; k["audience"] = ["session": ["agent": "claude", "sessionId": "victim"]]; e["key"] = k }
        XCTAssertFalse(store().isApproved(variant(.session(agent: .claude, sessionId: "victim"))))
        XCTAssertEqual(store().rejected.count, 1)
        try store().revoke { _ in true }
        try store().approve(key, lifetime: .day, sessionLabel: nil, sign: Self.fakeSign)
        try rewrite { e in var k = e["key"] as! [String: Any]; k["audience"] = ["allAgents": [String: Any]()]; e["key"] = k }
        XCTAssertFalse(store().isApproved(key))
        XCTAssertEqual(store().rejected.count, 1)

        // Forged entry with no signature, and one with an extended expiry.
        try store().revoke { _ in true }
        try store().approve(key, lifetime: .day, sessionLabel: nil, sign: Self.fakeSign)
        try rewrite { e in e["expiresAt"] = "2099-01-01T00:00:00Z" }
        XCTAssertFalse(store().isApproved(key))
        try rewrite { e in e["signature"] = nil }
        XCTAssertFalse(store().isApproved(key))
    }
}

final class CallerContextTests: XCTestCase {
    func entry(_ pid: Int32, _ ppid: Int32, _ argv: [String]) -> ProcessEntry {
        ProcessEntry(pid: pid, ppid: ppid, executable: argv.first ?? "", argv: argv)
    }

    static let claudeWrapper = """
        source /Users/u/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && export CLAUDE_SESSION_ID=abc
        : && setopt NO_EXTENDED_GLOB 2>/dev/null || true && { \\builtin unalias -- 'unsetenv'; } >/dev/null 2>&1 || true && eval 'TOKEN=$(op read '"'"'op://Private/x/password'"'"') && curl -H "Authorization: $TOKEN" https://api' < /dev/null && pwd -P >| /tmp/claude-acfc-cwd
        """

    func testClaudeToolCommandThroughSubshell() {
        let chain = [
            entry(40, 30, ["op", "read", "op://Private/x/password"]),
            entry(30, 20, ["/bin/zsh", "-c", Self.claudeWrapper]),  // $(…) subshell
            entry(20, 10, ["/bin/zsh", "-c", Self.claudeWrapper]),
            entry(10, 1, ["claude", "--dangerously-skip-permissions"]),
        ]
        let ctx = CallerContext.from(chain: chain, agentPid: 10)
        XCTAssertEqual(ctx.toolCommand, #"TOKEN=$(op read 'op://Private/x/password') && curl -H "Authorization: $TOKEN" https://api"#)
        XCTAssertNil(ctx.viaProcess)
    }

    func testSkillScriptIsReportedAsVia() {
        let chain = [
            entry(50, 40, ["op", "item", "get", "TRACKER_KEY"]),
            entry(40, 20, ["python3", "linear_client.py", "issues"]),
            entry(20, 10, ["/bin/zsh", "-lc", "python3 linear_client.py issues"]),
            entry(10, 1, ["/opt/homebrew/bin/codex"]),
        ]
        let ctx = CallerContext.from(chain: chain, agentPid: nil)
        XCTAssertEqual(ctx.toolCommand, "python3 linear_client.py issues")
        XCTAssertEqual(ctx.viaProcess, "python3 linear_client.py issues")
    }

    func testShellScriptBelowToolShell() {
        let chain = [
            entry(50, 40, ["op", "read", "op://a/b/c"]),
            entry(40, 20, ["/bin/bash", "./publish-docs.sh"]),
            entry(20, 10, ["bash", "-c", "./publish-docs.sh"]),
            entry(10, 1, ["cursor-agent"]),
        ]
        let ctx = CallerContext.from(chain: chain, agentPid: nil)
        XCTAssertEqual(ctx.toolCommand, "./publish-docs.sh")
        XCTAssertEqual(ctx.viaProcess, "/bin/bash ./publish-docs.sh")
    }

    func testShellWords() {
        XCTAssertEqual(ShellWords.firstWord(#"'a'"'"'b' rest"#), "a'b")
        XCTAssertEqual(ShellWords.firstWord(#""x \"y\"" z"#), #"x "y""#)
        XCTAssertEqual(ShellWords.firstWord(#"a\ b c"#), "a b")
        XCTAssertNil(ShellWords.firstWord("'unterminated"))
    }

    func testParseProcArgs() {
        var buf: [UInt8] = []
        withUnsafeBytes(of: Int32(2)) { buf += $0 }
        for part in ["/bin/zsh", "", "", "zsh", "-c", "FOO=bar"] {
            buf += Array(part.utf8)
            buf.append(0)
        }
        let args = ProcessTree.parseProcArgs(buf)!
        XCTAssertEqual(args.executable, "/bin/zsh")
        XCTAssertEqual(args.argv, ["zsh", "-c"])
        XCTAssertEqual(args.env, ["FOO": "bar"])
    }

    func testLiveAncestryIncludesThisProcess() {
        let chain = ProcessTree.ancestry(of: getpid())
        XCTAssertEqual(chain.first?.pid, getpid())
        XCTAssertGreaterThan(chain.count, 1)
        XCTAssertEqual(chain.first?.env["HOME"], ProcessInfo.processInfo.environment["HOME"])
        let start = try! XCTUnwrap(chain.first?.startTime)
        let age = Date().timeIntervalSince1970 - start
        XCTAssertTrue(age >= 0 && age < 3600, "start time is this test process's recent wall-clock start")
    }
}

final class AuthWindowTests: XCTestCase {
    func testRemaining() {
        let start = Date(timeIntervalSince1970: 0)
        let w = AuthWindow(signedIn: true, authorizedAt: start)
        XCTAssertEqual(w.remaining(at: start.addingTimeInterval(3600)), 11 * 3600)
        XCTAssertNil(w.remaining(at: start.addingTimeInterval(12 * 3600)), "12 hours up even if whoami still works")
        XCTAssertNil(AuthWindow(signedIn: false, authorizedAt: start).remaining(at: start))
        XCTAssertNil(AuthWindow(signedIn: true, authorizedAt: nil).remaining(at: start))
    }

    func testLabels() {
        XCTAssertEqual(Duration.short(29), "<1m")
        XCTAssertEqual(Duration.short(30), "1m")
        XCTAssertEqual(Duration.short(32 * 60 + 29), "32m")
        XCTAssertEqual(Duration.short(32 * 60 + 30), "33m")
        XCTAssertEqual(Duration.short(59 * 60 + 29), "59m")
        XCTAssertEqual(Duration.short(59 * 60 + 30), "1h")
        XCTAssertEqual(Duration.short(11 * 3600 + 57 * 60), "12h")
        XCTAssertEqual(Duration.short(11 * 3600 + 30 * 60), "12h")
        XCTAssertEqual(Duration.short(11 * 3600 + 29 * 60), "11h")
        XCTAssertEqual(Duration.long(11 * 3600 + 32 * 60 + 5), "11h 32m")
        XCTAssertEqual(Duration.long(59 * 60), "59m")
    }
}

final class SessionIdentityTests: XCTestCase {
    func entry(_ pid: Int32, _ argv: [String], start: Double = 1) -> ProcessEntry {
        ProcessEntry(pid: pid, ppid: 0, executable: argv[0], argv: argv, startTime: start)
    }
    let genuine: (ProcessEntry) -> AgentKind? = { $0.pid == 10 ? .claude : ($0.pid == 20 ? .codex : nil) }

    func testIdentityIsTheNearestGenuineAgentProcess() {
        let chain = [entry(40, ["op"]), entry(30, ["zsh"]), entry(10, ["claude"], start: 1.5)]
        XCTAssertEqual(SessionIdentity.from(chain: chain, isGenuine: genuine),
                       SessionIdentity(agent: .claude, agentPid: 10, agentInstance: "10@1500000"))
    }

    func testFakeAgentProcessIsSkipped() {
        let chain = [entry(50, ["op"]), entry(44, ["claude"]), entry(30, ["zsh"]), entry(10, ["claude"])]
        XCTAssertEqual(SessionIdentity.from(chain: chain, isGenuine: genuine)?.agentPid, 10)
    }

    func testNestedAgentsUseTheNearest() {
        let chain = [entry(50, ["op"]), entry(40, ["zsh"]), entry(20, ["codex"]), entry(15, ["zsh"]), entry(10, ["claude"])]
        XCTAssertEqual(SessionIdentity.from(chain: chain, isGenuine: genuine)?.agent, .codex)
    }

    func testCallerItselfDoesNotCount() {
        XCTAssertNil(SessionIdentity.from(chain: [entry(10, ["claude"]), entry(5, ["zsh"])], isGenuine: genuine))
    }

    func testLiveClaudeIsGenuineWhenPresent() throws {
        // Runs for real inside a Claude Code session; skipped elsewhere.
        let chain = ProcessTree.ancestry(of: getpid())
        guard let claude = chain.first(where: { $0.names.contains("claude") }) else { throw XCTSkip("not under Claude Code") }
        XCTAssertEqual(AgentKind.verify(claude), .claude)
        let impostor = ProcessEntry(pid: getpid(), ppid: 0, executable: "/tmp/claude", argv: ["claude"])
        XCTAssertNil(AgentKind.verify(impostor), "a process named claude that isn't Anthropic-signed")
    }
}

final class TerminalApprovalsTests: XCTestCase {
    func testIdleAndCap() {
        var now = Date(timeIntervalSince1970: 0)
        let approvals = TerminalApprovals(idle: 600, now: { now })
        let tab = TerminalKey(sid: 100, leaderStart: 1)
        XCTAssertFalse(approvals.use(tab))
        approvals.approve(tab, label: "iTerm · ttys012")
        XCTAssertEqual(approvals.active.map(\.label), ["iTerm · ttys012"])
        XCTAssertFalse(approvals.use(TerminalKey(sid: 100, leaderStart: 2)), "reused session ID")
        XCTAssertFalse(approvals.use(TerminalKey(sid: 101, leaderStart: 1)), "another tab")
        // Kept alive by use every 9 minutes...
        for _ in 0..<5 { now += 9 * 60; XCTAssertTrue(approvals.use(tab)) }
        // ...until 10 idle minutes pass.
        now += 10 * 60
        XCTAssertFalse(approvals.use(tab))
        XCTAssertTrue(approvals.active.isEmpty)

        approvals.approve(tab, label: "")
        approvals.revoke(tab)
        XCTAssertFalse(approvals.use(tab))

        approvals.approve(tab, label: "")
        for _ in 0..<(12 * 60 / 9) { now += 9 * 60; _ = approvals.use(tab) }
        XCTAssertFalse(approvals.use(tab), "never beyond 12 hours, however busy")
    }

    func testTerminalInfo() {
        let chain = [
            ProcessEntry(pid: 50, ppid: 40, executable: "/Users/u/opProxy/bin/opProxy", argv: ["op", "read", "op://a/b/c"], tty: "ttys012"),
            ProcessEntry(pid: 40, ppid: 30, executable: "/usr/bin/python3", argv: ["python3", "sync.py"], tty: "ttys012"),
            ProcessEntry(pid: 30, ppid: 20, executable: "/bin/zsh", argv: ["-zsh"], tty: "ttys012"),
            ProcessEntry(pid: 20, ppid: 10, executable: "/usr/bin/login", argv: ["login", "-fp", "u"]),
            ProcessEntry(pid: 10, ppid: 1, executable: "/Applications/iTerm.app/Contents/MacOS/iTerm2", argv: ["iTerm2"]),
        ]
        let info = TerminalInfo.from(chain: chain, sid: 30)
        XCTAssertEqual(info.app, "iTerm")
        XCTAssertEqual(info.tty, "ttys012")
        XCTAssertEqual(info.chain, ["50  op read op://a/b/c", "40  python3 sync.py", "30  -zsh"])

        let spaceterm = [chain[0], ProcessEntry(pid: 9, ppid: 1, executable: "/Users/u/spaceterm/pty-daemon/pty-daemon", argv: ["pty-daemon"])]
        XCTAssertEqual(TerminalInfo.from(chain: spaceterm, sid: 9).app, "Spaceterm")
        XCTAssertEqual(TerminalInfo.from(chain: [chain[0], chain[1]], sid: 40).app, "python3")
    }
}

final class ChimeTests: XCTestCase {
    func testChimeIsAPlayableWAVWithinFullScale() {
        let samples = Chime.samples()
        XCTAssertEqual(samples.count, Int(Chime.length * Double(Chime.sampleRate)))
        XCTAssertEqual(samples.map(abs).max() ?? 0, Chime.peak, accuracy: 1e-9)
        XCTAssertEqual(samples.first, 0)
        let wav = Chime.wav()
        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(wav.count, 44 + samples.count * 2)
    }
}
