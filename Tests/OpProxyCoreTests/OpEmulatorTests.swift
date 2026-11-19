import XCTest
@testable import OpProxyCore

final class OpEmulatorTests: XCTestCase {
    static let now = OpOutput.date("2026-11-18T12:00:00Z")!
    static let account = OnePasswordAccount(url: "acme.1password.com", email: "me@acme.com", userUUID: "USER", accountUUID: "ACCT")
    static let employee = SDK.VaultOverview(id: "v1", title: "Employee", description: "Yours", vaultType: "personal",
                                            activeItemCount: 2, contentVersion: 7, attributeVersion: 1,
                                            createdAt: "2025-01-27T23:51:09Z", updatedAt: "2026-11-15T12:00:00Z")
    static let shared = SDK.VaultOverview(id: "v2", title: "Engineering", vaultType: "userCreated", activeItemCount: 1)

    static let apiKey = SDK.Item(
        id: "key1", title: "Tracker key", category: "ApiCredentials", vaultId: "v1",
        fields: [SDK.Field(id: "username", title: "username", fieldType: "Text", value: ""),
                 SDK.Field(id: "credential", title: "credential", fieldType: "Concealed", value: "sk-secret"),
                 SDK.Field(id: "f1", title: "region", sectionId: "s1", fieldType: "Text", value: "ca-central")],
        sections: [SDK.Section(id: "s1", title: "Details")], notes: "rotate yearly", tags: ["infra"], version: 3,
        createdAt: "2026-02-25T05:00:18Z", updatedAt: "2026-11-15T12:00:00Z")
    static let login = SDK.Item(
        id: "login1", title: "GitHub", category: "Login", vaultId: "v2",
        fields: [SDK.Field(id: "username", title: "username", fieldType: "Text", value: "octocat"),
                 SDK.Field(id: "password", title: "password", fieldType: "Concealed", value: "hunter2"),
                 SDK.Field(id: "otp", title: "one-time password", sectionId: "add more", fieldType: "Totp", value: "otpauth://x",
                           details: .object(["type": .string("Otp"), "content": .object(["code": .string("654321")])]))],
        sections: [SDK.Section(id: "add more", title: "")],
        websites: [SDK.Website(url: "https://github.com")], version: 1,
        createdAt: "2026-11-17T12:00:00Z", updatedAt: "2026-11-18T09:00:00Z")

    var op: FakeOnePassword!
    var emulator: OpEmulator!

    override func setUp() {
        op = FakeOnePassword(vaults: [Self.employee, Self.shared], items: [Self.apiKey, Self.login])
        emulator = OpEmulator(client: op, account: Self.account, now: { Self.now })
    }

    func out(_ r: ProxyResponse, file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertEqual(r.exitCode, 0, String(decoding: r.stderr, as: UTF8.self), file: file, line: line)
        return String(decoding: r.stdout, as: UTF8.self)
    }

    func read(_ argv: [String], _ target: SDK.Item, env: [String: String] = [:]) -> ProxyResponse {
        guard case .proxy(let plan) = OpCommand(argv: argv).routing, let item = plan.item else { fatalError("\(argv)") }
        let vault = [Self.employee, Self.shared].first { $0.id == target.vaultId }!
        return emulator.read(item, target: ItemIdentity(itemId: target.id, vaultId: vault.id, title: target.title, vaultName: vault.title),
                             env: env)
    }

    func metadata(_ argv: [String], env: [String: String] = [:]) -> ProxyResponse {
        guard case .proxy(let plan) = OpCommand(argv: argv).routing, let m = plan.metadata else { fatalError("\(argv)") }
        return emulator.metadata(m, env: env)
    }

    func json(_ text: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(text.utf8)) }

    // MARK: Reads

    func testItemGetJSONLooksLikeOps() throws {
        let text = out(read(["item", "get", "Tracker key", "--format", "json"], Self.apiKey))
        XCTAssertTrue(text.hasPrefix("{\n  \"id\": \"key1\",\n  \"title\": \"Tracker key\",\n  \"tags\": [\n"), text)
        let item = try XCTUnwrap(json(text) as? [String: Any])
        XCTAssertEqual(item["category"] as? String, "API_CREDENTIAL")
        XCTAssertEqual(item["version"] as? Int, 3)
        XCTAssertEqual((item["vault"] as? [String: String]), ["id": "v1", "name": "Employee"])
        XCTAssertEqual(item["created_at"] as? String, "2026-02-25T05:00:18Z")
        let fields = try XCTUnwrap(item["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.map { $0["id"] as? String }, ["notesPlain", "username", "credential", "f1"])
        XCTAssertEqual(fields[0]["purpose"] as? String, "NOTES")
        XCTAssertEqual(fields[0]["value"] as? String, "rotate yearly")
        XCTAssertNil(fields[1]["value"], "op leaves out empty values")
        XCTAssertEqual(fields[2]["type"] as? String, "CONCEALED")
        XCTAssertEqual(fields[2]["value"] as? String, "sk-secret", "op's JSON has concealed values even without --reveal")
        XCTAssertEqual(fields[2]["reference"] as? String, "op://Employee/Tracker key/credential")
        XCTAssertEqual(fields[3]["section"] as? [String: String], ["id": "s1", "label": "Details"])
        XCTAssertEqual(fields[3]["reference"] as? String, "op://Employee/Tracker key/Details/region")
        XCTAssertEqual(item["sections"] as? [[String: String]], [["id": "s1", "label": "Details"]])
    }

    func testLoginFieldsHaveTheirPurposesAndURLs() throws {
        let item = try XCTUnwrap(json(out(read(["item", "get", "GitHub", "--format", "json"], Self.login))) as? [String: Any])
        let fields = try XCTUnwrap(item["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.compactMap { $0["purpose"] as? String }, ["NOTES", "USERNAME", "PASSWORD"])
        XCTAssertEqual(fields.last?["totp"] as? String, "654321")
        XCTAssertEqual(fields.last?["reference"] as? String, "op://Engineering/GitHub/one-time password", "an untitled section isn't in the path")
        XCTAssertEqual(item["urls"] as? [NSDictionary], [["label": "website", "primary": true, "href": "https://github.com"]])
    }

    func testItemGetHumanHidesConcealedValues() {
        let text = out(read(["item", "get", "GitHub"], Self.login))
        XCTAssertTrue(text.hasPrefix("ID:          login1\nTitle:       GitHub\nVault:       Engineering (v2)\nCreated:     1 day ago\n"), text)
        XCTAssertTrue(text.contains("Fields:\n  username:    octocat\n  password:    [use 'op item get login1 --reveal' to reveal]\n"), text)
        XCTAssertTrue(text.contains("URLs:\n  website:    https://github.com (primary)\n"), text)
        XCTAssertTrue(out(read(["item", "get", "GitHub", "--reveal"], Self.login)).contains("  password:    hunter2\n"))
    }

    func testFields() throws {
        XCTAssertEqual(out(read(["item", "get", "x", "--fields", "label=credential", "--reveal"], Self.apiKey)), "sk-secret\n")
        XCTAssertEqual(out(read(["item", "get", "x", "--fields", "label=credential"], Self.apiKey)),
                       "[use 'op item get key1 --reveal' to reveal]\n")
        XCTAssertEqual(out(read(["item", "get", "x", "--fields", "username,password", "--reveal"], Self.login)), "octocat,hunter2\n")
        XCTAssertEqual(out(read(["item", "get", "x", "--fields", "Details.region"], Self.apiKey)), "ca-central\n")
        let one = try XCTUnwrap(json(out(read(["item", "get", "x", "--fields", "label=credential", "--format", "json"], Self.apiKey)))
                                as? [String: Any])
        XCTAssertEqual(one["value"] as? String, "sk-secret")
        let many = try XCTUnwrap(json(out(read(["item", "get", "x", "--fields", "type=concealed,label=username", "--format=json"],
                                               Self.login))) as? [[String: Any]])
        XCTAssertEqual(many.map { $0["id"] as? String }, ["password", "username"])
        let missing = read(["item", "get", "x", "--fields", "label=nope"], Self.apiKey)
        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertTrue(String(decoding: missing.stderr, as: UTF8.self).contains("\"label=nope\" isn't a field in the \"Tracker key\" item"))
    }

    func testOTPAndRead() {
        XCTAssertEqual(out(read(["item", "get", "x", "--otp"], Self.login)), "654321\n")
        XCTAssertEqual(out(read(["read", "op://Employee/Tracker key/credential"], Self.apiKey)), "sk-secret\n")
        XCTAssertEqual(out(read(["read", "-n", "op://Employee/Tracker key/credential"], Self.apiKey)), "sk-secret")
        XCTAssertTrue(op.calls.contains("resolve op://v1/key1/credential"), "resolved by IDs, not names: \(op.calls)")
        XCTAssertEqual(read(["document", "get", "x"], Self.apiKey).exitCode, 1, "only a document has contents")
        var document = Self.apiKey
        document.document = .object(["id": .string("f"), "name": .string("a.pem"), "size": .number(9)])
        op.stored[0] = document
        XCTAssertEqual(out(read(["document", "get", "x"], document)), "contents of key1")
    }

    func testFailuresLookLikeOps() {
        op.failure = SDK.Failure(.unauthorized, "invalid client id")
        let r = read(["read", "op://Employee/Tracker key/credential"], Self.apiKey)
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertEqual(String(decoding: r.stderr, as: UTF8.self).range(of: #"^\[ERROR\] \d{4}/\d\d/\d\d \d\d:\d\d:\d\d invalid client id\n$"#,
                                                                     options: .regularExpression) != nil, true)
    }

    // MARK: Listings

    func testItemList() throws {
        let human = out(metadata(["item", "list"]))
        XCTAssertEqual(human, """
            ID        TITLE          VAULT          EDITED
            login1    GitHub         Engineering    3 hours ago
            key1      Tracker key    Employee       3 days ago

            """)
        let listed = try XCTUnwrap(json(out(metadata(["item", "list", "--format", "json"]))) as? [[String: Any]])
        XCTAssertEqual(listed.map { $0["id"] as? String }, ["login1", "key1"])
        XCTAssertEqual(listed[1]["vault"] as? [String: String], ["id": "v1", "name": "Employee"])
        XCTAssertEqual(listed[1]["tags"] as? [String], ["infra"])
        let credentials = try XCTUnwrap(json(out(metadata(["item", "list", "--categories", "API Credential", "--format", "json"])))
                                        as? [[String: Any]])
        XCTAssertEqual(credentials.map { $0["id"] as? String }, ["key1"])
        XCTAssertTrue(out(metadata(["item", "list", "--tags", "infra"])).contains("key1"))
        XCTAssertFalse(out(metadata(["item", "list", "--tags", "infra"])).contains("login1"))
        XCTAssertFalse(out(metadata(["item", "list", "--vault", "employee"])).contains("login1"), "vault by name in any case")
        XCTAssertTrue(out(metadata(["item", "list"], env: ["OP_FORMAT": "json"])).hasPrefix("["))
        XCTAssertEqual(metadata(["item", "list", "--vault", "Nope"]).exitCode, 1)
    }

    func testVaultsAndWhoami() throws {
        XCTAssertEqual(out(metadata(["vault", "list"])), "ID    NAME\nv1    Employee\nv2    Engineering\n")
        let vault = try XCTUnwrap(json(out(metadata(["vault", "get", "employee", "--format", "json"]))) as? [String: Any])
        XCTAssertEqual(vault["type"] as? String, "PERSONAL")
        XCTAssertEqual(vault["items"] as? Int, 2)
        XCTAssertEqual(out(metadata(["whoami"])), "URL:        https://acme.1password.com/\nEmail:      me@acme.com\nUser ID:    USER\n")
        let me = try XCTUnwrap(json(out(metadata(["whoami", "--format", "json"]))) as? [String: String])
        XCTAssertEqual(me, ["url": "https://acme.1password.com/", "email": "me@acme.com", "user_uuid": "USER", "account_uuid": "ACCT"])
    }

    func testAccountMatching() {
        for name in ["acme.1password.com", "https://acme.1password.com/", "ACME", "me@acme.com", "acct", "USER"] {
            XCTAssertTrue(Self.account.matches(name), name)
        }
        XCTAssertFalse(Self.account.matches("other.1password.com"))
    }

    func testRelativeTimes() {
        func ago(_ s: TimeInterval) -> String { OpOutput.relative(Self.now.addingTimeInterval(-s), now: Self.now) }
        XCTAssertEqual(ago(30), "30 seconds ago")
        XCTAssertEqual(ago(90), "1 minute ago")
        XCTAssertEqual(ago(3 * 86400), "3 days ago")
        XCTAssertEqual(ago(10 * 86400), "1 week ago")
        XCTAssertEqual(ago(240 * 86400), "8 months ago")
        XCTAssertEqual(ago(800 * 86400), "2 years ago")
    }

    // MARK: Writes

    func write(_ argv: [String]) throws -> ItemWrite {
        guard case .proxy(let plan) = OpCommand(argv: argv).routing, let w = plan.write else {
            throw XCTSkip("not a write: \(argv)")
        }
        return w
    }

    func testCreate() throws {
        let w = try write(["item", "create", "--category", "login", "--title", "Staging DB", "--vault", "Engineering",
                           "--url", "https://db.example.com", "--tags", "db,staging", "username=admin", "password=s3cret!",
                           "Connection.port[text]=5432", "notes=primary", "--format", "json"])
        let vault = try emulator.vaultForCreate(w.vault).get()
        XCTAssertEqual(vault.id, "v2")
        let created = try XCTUnwrap(json(out(emulator.write(w, target: ItemIdentity(itemId: "", vaultId: vault.id, title: "Staging DB",
                                                                                     vaultName: vault.title), env: [:]))) as? [String: Any])
        XCTAssertEqual(created["title"] as? String, "Staging DB")
        let item = try XCTUnwrap(op.stored.last)
        XCTAssertEqual(item.category, "Login")
        XCTAssertEqual(item.vaultId, "v2")
        XCTAssertEqual(item.tags, ["db", "staging"])
        XCTAssertEqual(item.websites.first?.url, "https://db.example.com")
        XCTAssertEqual(item.notes, "primary")
        XCTAssertEqual(item.fields.first { $0.id == "username" }?.value, "admin")
        XCTAssertEqual(item.fields.first { $0.id == "password" }?.fieldType, "Concealed")
        let port = try XCTUnwrap(item.fields.first { $0.title == "port" })
        XCTAssertEqual(item.section(port.sectionId)?.title, "Connection")
        XCTAssertEqual(port.value, "5432")
    }

    func testCreateWithoutVaultUsesTheAccountsOwn() throws {
        XCTAssertEqual(try emulator.vaultForCreate(nil).get().id, "v1")
    }

    func testGeneratedPassword() throws {
        let w = try write(["item", "create", "--category", "Password", "--title", "Token", "--generate-password=letters,digits,20"])
        _ = out(emulator.write(w, target: ItemIdentity(itemId: "", vaultId: "v1", title: "Token", vaultName: "Employee"), env: [:]))
        let password = try XCTUnwrap(op.stored.last?.fields.first { $0.id == "password" }?.value)
        XCTAssertEqual(password.count, 20)
        XCTAssertTrue(password.allSatisfy { $0.isLetter || $0.isNumber } && password.contains { $0.isNumber })
        XCTAssertEqual(w.details.map(\.value), ["PASSWORD", "Token", "password (generated, 20 characters)"])
    }

    func testEdit() throws {
        let w = try write(["item", "edit", "Tracker key", "credential[password]=sk-new", "Details.region[delete]",
                           "Details.owner=platform", "added=x", "--title", "Tracker key (rotated)"])
        let target = ItemIdentity(itemId: "key1", vaultId: "v1", title: "Tracker key", vaultName: "Employee")
        let text = out(emulator.write(w, target: target, env: [:]))
        XCTAssertTrue(text.contains("Title:       Tracker key (rotated)"), text)
        XCTAssertFalse(text.contains("sk-new"), "concealed in the human output without --reveal")
        let item = try XCTUnwrap(op.stored.first { $0.id == "key1" })
        XCTAssertEqual(item.fields.first { $0.id == "credential" }?.value, "sk-new")
        XCTAssertNil(item.fields.first { $0.title == "region" })
        XCTAssertEqual(item.fields.first { $0.title == "owner" }?.sectionId, "s1", "into the existing section, by title")
        XCTAssertEqual(item.section(item.fields.first { $0.title == "added" }?.sectionId)?.id, "add more")
        XCTAssertEqual(item.version, 4)

        let shown = try XCTUnwrap(json(out(emulator.write(try write(["item", "edit", "Tracker key", "--tags", "x", "--format", "json", "--reveal"]),
                                                          target: target, env: [:]))) as? [String: Any])
        let credential = try XCTUnwrap((shown["fields"] as? [[String: Any]])?.first { $0["id"] as? String == "credential" })
        XCTAssertNil(credential["value"], "approving a change doesn't approve reading the item's secrets")

        let missing = try write(["item", "edit", "Tracker key", "nope[delete]"])
        XCTAssertEqual(emulator.write(missing, target: target, env: [:]).exitCode, 1)
    }

    func testDeleteAndArchive() throws {
        let target = ItemIdentity(itemId: "login1", vaultId: "v2", title: "GitHub", vaultName: "Engineering")
        XCTAssertEqual(out(emulator.write(try write(["item", "delete", "GitHub", "--archive"]), target: target, env: [:])), "")
        XCTAssertEqual(op.archived, ["login1"])
        XCTAssertEqual(out(emulator.write(try write(["item", "delete", "GitHub"]), target: target, env: [:])), "")
        XCTAssertFalse(op.stored.contains { $0.id == "login1" })
    }

    func testValuesNeverShow() throws {
        let w = try write(["item", "edit", "x", "password=hunter2", #"API\.key[password]=a=b"#, "--title", "T"])
        XCTAssertEqual(w.redactedArgv, ["item", "edit", "x", "password=‹hidden›", #"API\.key[password]=‹hidden›"#, "--title", "T"])
        XCTAssertEqual(w.details.map(\.value), ["T", "password (7 characters), API.key (password, 3 characters)"])
        XCTAssertEqual(w.secrets, ["hunter2", "a=b"])
        XCTAssertFalse(w.details.contains { $0.value.contains("hunter2") })
    }

    func testRecipes() {
        XCTAssertEqual(ItemWrite.recipe(""), SDK.PasswordRecipe(length: 32, digits: true, symbols: true))
        XCTAssertEqual(ItemWrite.recipe("letters,digits,64"), SDK.PasswordRecipe(length: 64, digits: true, symbols: false))
        XCTAssertNil(ItemWrite.recipe("letters,emoji"))
        let symbols = SDK.PasswordRecipe(length: 12, digits: false, symbols: true).generate()
        XCTAssertTrue(symbols.contains { "!@#$%^&*-_=+.?".contains($0) } && !symbols.contains { $0.isNumber })
        let a = SDK.PasswordRecipe(length: 32, digits: true, symbols: true)
        XCTAssertNotEqual(a.generate(), a.generate())
    }

    func testAssignments() {
        XCTAssertEqual(ItemWrite.parseAssignment("password=x"), .init(section: nil, field: "password", type: nil, value: "x"))
        XCTAssertEqual(ItemWrite.parseAssignment("S.f[url]=https://a=b"), .init(section: "S", field: "f", type: "url", value: "https://a=b"))
        XCTAssertEqual(ItemWrite.parseAssignment(#"a\.b=c"#), .init(section: nil, field: "a.b", type: nil, value: "c"))
        XCTAssertEqual(ItemWrite.parseAssignment("S.f[delete]"), .init(section: "S", field: "f", type: nil, value: nil))
        XCTAssertEqual(ItemWrite.parseAssignment("f="), .init(section: nil, field: "f", type: nil, value: ""))
        XCTAssertNil(ItemWrite.parseAssignment("no-equals"))
        XCTAssertNil(ItemWrite.parseAssignment(".f=x"))
    }
}
