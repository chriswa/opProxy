import Foundation

/// What `op` prints, built from the SDK's types: its JSON field names and order, and its
/// tab-aligned human output. The SDK has no record of who last edited an item, its one-line
/// summary (`additional_information`) or whether it's a favorite, so those are left out.
public enum OpOutput {
    // MARK: Names

    /// The SDK's category names as `op` spells them.
    static let categories: [String: String] = [
        "Login": "LOGIN", "SecureNote": "SECURE_NOTE", "CreditCard": "CREDIT_CARD", "CryptoWallet": "CRYPTO_WALLET",
        "Identity": "IDENTITY", "Password": "PASSWORD", "Document": "DOCUMENT", "ApiCredentials": "API_CREDENTIAL",
        "BankAccount": "BANK_ACCOUNT", "Database": "DATABASE", "DriverLicense": "DRIVER_LICENSE", "Email": "EMAIL_ACCOUNT",
        "MedicalRecord": "MEDICAL_RECORD", "Membership": "MEMBERSHIP", "OutdoorLicense": "OUTDOOR_LICENSE",
        "Passport": "PASSPORT", "Rewards": "REWARD_PROGRAM", "Router": "WIRELESS_ROUTER", "Server": "SERVER",
        "SshKey": "SSH_KEY", "SocialSecurityNumber": "SOCIAL_SECURITY_NUMBER", "SoftwareLicense": "SOFTWARE_LICENSE",
        "Person": "PERSON", "Unsupported": "CUSTOM",
    ]

    public static func category(_ sdk: String) -> String { categories[sdk] ?? sdk.uppercased() }

    /// The SDK category a name given to `op` means: `Login`, `API Credential`, `API_CREDENTIAL`.
    public static func sdkCategory(named name: String) -> String? {
        let wanted = normalized(name)
        return categories.first { normalized($0.value) == wanted || normalized($0.key) == wanted }?.key
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter }.replacingOccurrences(of: "credentials", with: "credential")
    }

    static let fieldTypes: [String: String] = [
        "Text": "STRING", "Concealed": "CONCEALED", "CreditCardType": "CREDIT_CARD_TYPE",
        "CreditCardNumber": "CREDIT_CARD_NUMBER", "Phone": "PHONE", "Url": "URL", "Totp": "OTP", "Email": "EMAIL",
        "Reference": "REFERENCE", "SshKey": "SSHKEY", "Menu": "MENU", "MonthYear": "MONTH_YEAR", "Address": "ADDRESS",
        "Date": "DATE", "Unsupported": "UNKNOWN",
    ]

    public static func fieldType(_ sdk: String) -> String { fieldTypes[sdk] ?? sdk.uppercased() }

    /// Fields whose values `op` hides in its human output unless asked to `--reveal` them.
    static func isConcealed(_ field: SDK.Field) -> Bool {
        ["Concealed", "CreditCardNumber", "SshKey", "Totp"].contains(field.fieldType)
    }

    static let vaultTypes = ["personal": "PERSONAL", "everyone": "EVERYONE", "transfer": "TRANSFER", "userCreated": "USER_CREATED"]

    // MARK: Items

    /// A field as `op item get --format json` shows it, with the item's notes as the
    /// `notesPlain` field `op` has.
    public struct OpField {
        public let id: String
        public let type: String
        public let purpose: String?
        public let label: String
        public let value: String
        public let section: SDK.Section?
        public let totp: String?
        public let reference: String
        /// The SDK field it came from; nil for notes.
        public let sdk: SDK.Field?

        public var concealed: Bool { sdk.map(OpOutput.isConcealed) ?? false }

        var json: [(String, Any)] {
            var out: [(String, Any)] = [("id", id)]
            if let section { out.append(("section", ordered([("id", section.id), ("label", section.title)]))) }
            out.append(("type", type))
            if let purpose { out.append(("purpose", purpose)) }
            out.append(("label", label))
            if !value.isEmpty { out.append(("value", value)) }
            if let totp { out.append(("totp", totp)) }
            out.append(("reference", reference))
            return out
        }
    }

    public static func fields(of item: SDK.Item, vaultName: String) -> [OpField] {
        func reference(_ section: SDK.Section?, _ label: String) -> String {
            (["op:/", vaultName, item.title] + [section?.title].compactMap { $0 }.filter { !$0.isEmpty } + [label]).joined(separator: "/")
        }
        var out = [OpField(id: "notesPlain", type: "STRING", purpose: "NOTES", label: "notesPlain", value: item.notes,
                           section: nil, totp: nil, reference: reference(nil, "notesPlain"), sdk: nil)]
        for field in item.fields {
            let section = item.section(field.sectionId)
            var purpose: String?
            if section == nil, ["Login", "Password"].contains(item.category) {
                if field.id == "username", item.category == "Login" { purpose = "USERNAME" }
                if field.id == "password" { purpose = "PASSWORD" }
            }
            let label = field.title.isEmpty ? field.id : field.title
            out.append(OpField(id: field.id, type: fieldType(field.fieldType), purpose: purpose, label: label,
                               value: field.value, section: section, totp: field.code,
                               reference: reference(section, label), sdk: field))
        }
        return out
    }

    /// `concealing`: leave concealed values out, as a write's output does.
    public static func itemJSON(_ item: SDK.Item, vaultName: String, concealing: Bool = false) -> [(String, Any)] {
        var out: [(String, Any)] = [("id", item.id), ("title", item.title)]
        if !item.tags.isEmpty { out.append(("tags", item.tags)) }
        out += [("version", item.version), ("vault", ordered([("id", item.vaultId), ("name", vaultName)])),
                ("category", category(item.category))]
        if !item.createdAt.isEmpty { out.append(("created_at", timestamp(item.createdAt))) }
        if !item.updatedAt.isEmpty { out.append(("updated_at", timestamp(item.updatedAt))) }
        if !item.websites.isEmpty { out.append(("urls", urls(item.websites))) }
        let used = Set(item.fields.compactMap(\.sectionId))
        let sections = item.sections.filter { used.contains($0.id) }
        if !sections.isEmpty { out.append(("sections", sections.map { ordered([("id", $0.id), ("label", $0.title)]) })) }
        out.append(("fields", fields(of: item, vaultName: vaultName).map { field in
            ordered(concealing && field.concealed ? field.json.filter { $0.0 != "value" && $0.0 != "totp" } : field.json)
        }))
        return out
    }

    public static func overviewJSON(_ item: SDK.ItemOverview, vaultName: String) -> [(String, Any)] {
        var out: [(String, Any)] = [("id", item.id), ("title", item.title)]
        if let tags = item.tags, !tags.isEmpty { out.append(("tags", tags)) }
        out += [("vault", ordered([("id", item.vaultId), ("name", vaultName)])), ("category", category(item.category))]
        if let created = item.createdAt { out.append(("created_at", timestamp(created))) }
        if let updated = item.updatedAt { out.append(("updated_at", timestamp(updated))) }
        if let websites = item.websites, !websites.isEmpty { out.append(("urls", urls(websites))) }
        return out
    }

    private static func urls(_ websites: [SDK.Website]) -> [Any] {
        websites.enumerated().map { i, w in
            ordered([("label", w.label)] + (i == 0 ? [("primary", true)] : []) + [("href", w.url)])
        }
    }

    /// `op item get` without `--format json`.
    public static func itemHuman(_ item: SDK.Item, vaultName: String, reveal: Bool, iso: Bool, now: Date = Date()) -> String {
        var head: [(String, String)] = [("ID:", item.id), ("Title:", item.title), ("Vault:", "\(vaultName) (\(item.vaultId))")]
        if !item.createdAt.isEmpty { head.append(("Created:", when(item.createdAt, iso: iso, now: now))) }
        if !item.updatedAt.isEmpty { head.append(("Updated:", when(item.updatedAt, iso: iso, now: now))) }
        if !item.tags.isEmpty { head.append(("Tags:", item.tags.joined(separator: ", "))) }
        head += [("Version:", "\(item.version)"), ("Category:", category(item.category))]
        var out = columns(head.map { [$0.0, $0.1] })
        let shown = fields(of: item, vaultName: vaultName).filter { !$0.value.isEmpty }
        func value(_ f: OpField) -> String {
            f.concealed && !reveal ? concealedHint(item.id) : f.value
        }
        let loose = shown.filter { $0.section == nil }
        if !loose.isEmpty {
            out += "Fields:\n" + columns(loose.map { ["  \($0.label):", value($0)] })
        }
        var seen: [String] = []
        for field in shown where field.section != nil && !seen.contains(field.section!.id) { seen.append(field.section!.id) }
        for sectionId in seen {
            let inSection = shown.filter { $0.section?.id == sectionId }
            let title = inSection[0].section!.title
            out += "\n\(title.isEmpty ? "Section" : title):\n" + columns(inSection.map { ["  \($0.label):", value($0)] })
        }
        if !item.websites.isEmpty {
            out += "URLs:\n" + columns(item.websites.enumerated().map { i, w in
                ["  \(w.label):", w.url + (i == 0 ? " (primary)" : "")]
            })
        }
        return out
    }

    public static func concealedHint(_ itemId: String) -> String {
        "[use 'op item get \(itemId) --reveal' to reveal]"
    }

    // MARK: Vaults

    public static func vaultJSON(_ vault: SDK.VaultOverview, detailed: Bool) -> [(String, Any)] {
        var out: [(String, Any)] = [("id", vault.id), ("name", vault.title)]
        if let v = vault.contentVersion { out.append(("content_version", v)) }
        if let c = vault.createdAt { out.append(("created_at", timestamp(c))) }
        if let u = vault.updatedAt { out.append(("updated_at", timestamp(u))) }
        if let n = vault.activeItemCount { out.append(("items", n)) }
        guard detailed else { return out }
        if let d = vault.description, !d.isEmpty { out.append(("description", d)) }
        if let a = vault.attributeVersion { out.append(("attribute_version", a)) }
        if let t = vault.vaultType { out.append(("type", vaultTypes[t] ?? t.uppercased())) }
        return out
    }

    public static func vaultHuman(_ vault: SDK.VaultOverview, iso: Bool, now: Date = Date()) -> String {
        var rows = [["ID:", vault.id], ["Name:", vault.title]]
        if let d = vault.description, !d.isEmpty { rows.append(["Description:", d]) }
        if let t = vault.vaultType { rows.append(["Type:", vaultTypes[t] ?? t.uppercased()]) }
        if let a = vault.attributeVersion { rows.append(["Attribute version:", "\(a)"]) }
        if let c = vault.contentVersion { rows.append(["Content version:", "\(c)"]) }
        if let n = vault.activeItemCount { rows.append(["Items:", "\(n)"]) }
        if let c = vault.createdAt { rows.append(["Created:", when(c, iso: iso, now: now)]) }
        if let u = vault.updatedAt { rows.append(["Updated:", when(u, iso: iso, now: now)]) }
        return columns(rows)
    }

    // MARK: Formatting

    /// Keys in the order given, for `JSON.encode`.
    public struct Ordered {
        let pairs: [(String, Any)]
    }

    public static func ordered(_ pairs: [(String, Any)]) -> Ordered { Ordered(pairs: pairs) }

    /// `op`'s JSON style: two-space indent, keys in its order, no escaped slashes.
    public static func json(_ value: Any) -> String {
        encode(value, indent: "") + "\n"
    }

    private static func encode(_ value: Any, indent: String) -> String {
        let inner = indent + "  "
        switch value {
        case let o as Ordered:
            if o.pairs.isEmpty { return "{}" }
            let body = o.pairs.map { inner + quote($0.0) + ": " + encode($0.1, indent: inner) }
            return "{\n" + body.joined(separator: ",\n") + "\n" + indent + "}"
        case let pairs as [(String, Any)]:
            return encode(Ordered(pairs: pairs), indent: indent)
        case let a as [Any]:
            if a.isEmpty { return "[]" }
            return "[\n" + a.map { inner + encode($0, indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
        case let s as String: return quote(s)
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        default: return "null"
        }
    }

    private static func quote(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes, .fragmentsAllowed])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// Left-aligned columns, four spaces apart, as `op`'s human tables are.
    public static func columns(_ rows: [[String]]) -> String {
        guard let count = rows.map(\.count).max() else { return "" }
        var widths = [Int](repeating: 0, count: count)
        for row in rows { for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) } }
        return rows.map { row in
            row.enumerated().map { i, cell in
                i == row.count - 1 ? cell : cell.padding(toLength: widths[i] + 4, withPad: " ", startingAt: 0)
            }.joined()
        }.joined(separator: "\n") + "\n"
    }

    private static let parsers: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [ISO8601DateFormatter(), fractional]
    }()

    static func date(_ s: String) -> Date? {
        parsers.lazy.compactMap { $0.date(from: s) }.first
    }

    /// `2026-02-25T05:00:18Z`, as `op` writes times (whole seconds, UTC).
    static func timestamp(_ s: String) -> String {
        date(s).map { parsers[0].string(from: $0) } ?? s
    }

    static func when(_ s: String, iso: Bool, now: Date) -> String {
        guard let d = date(s) else { return s }
        return iso ? parsers[0].string(from: d) : relative(d, now: now)
    }

    /// "3 days ago", "8 months ago", like `op`.
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        let minute = 60.0, hour = 3600.0, day = 86400.0, week = 7 * day, month = 30 * day, year = 365 * day
        func n(_ unit: Double) -> Int { Int(s / unit) }
        let phrase: String
        switch s {
        case ..<1: return "now"
        case ..<2: phrase = "1 second"
        case ..<minute: phrase = "\(n(1)) seconds"
        case ..<(2 * minute): phrase = "1 minute"
        case ..<hour: phrase = "\(n(minute)) minutes"
        case ..<(2 * hour): phrase = "1 hour"
        case ..<day: phrase = "\(n(hour)) hours"
        case ..<(2 * day): phrase = "1 day"
        case ..<week: phrase = "\(n(day)) days"
        case ..<(2 * week): phrase = "1 week"
        case ..<month: phrase = "\(n(week)) weeks"
        case ..<(2 * month): phrase = "1 month"
        case ..<year: phrase = "\(n(month)) months"
        case ..<(18 * month): phrase = "1 year"
        case ..<(2 * year): phrase = "2 years"
        default: phrase = "\(n(year)) years"
        }
        return phrase + " ago"
    }
}
