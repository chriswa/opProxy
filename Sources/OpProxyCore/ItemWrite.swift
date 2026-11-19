import Foundation

/// `op item create`, `op item edit` and `op item delete`, reduced to what they change. Only
/// command lines built from allowlisted flags qualify; the rest (templates, stdin, file
/// fields, favorites) go to the real `op`. Values never appear in the dialog, the phone's
/// copy or the log: `redactedArgv` and `details` name the fields, not what's written to them.
public struct ItemWrite: Equatable {
    public enum Kind: Equatable {
        case create
        case edit
        case delete(archive: Bool)
    }

    /// `[<section>.]<field>[[<type>]]=<value>`, or `…[delete]`.
    public struct Assignment: Equatable {
        public let section: String?
        public let field: String
        /// `op`'s type name: password, text, email, url, date, monthYear, phone, otp.
        public let type: String?
        /// nil for `[delete]`.
        public let value: String?

        public var isDelete: Bool { value == nil }

        /// "Database.password", for the dialog.
        public var name: String { (section.map { "\($0)." } ?? "") + field }
    }

    public let kind: Kind
    /// The item as the caller named it (edit and delete).
    public let item: String?
    public let vault: String?
    public let account: String?
    /// The SDK category (create).
    public let category: String?
    /// The new title.
    public let title: String?
    public let url: String?
    public let tags: [String]?
    public let generatePassword: SDK.PasswordRecipe?
    public let assignments: [Assignment]
    let flags: [String: String]
    let argv: [String]

    public struct Unsupported: Error, Equatable {
        public let reason: String
    }

    static let commandFlags: [String: Set<String>] = [
        "item create": ["--category", "--title", "--vault", "--url", "--tags", "--generate-password", "--reveal"],
        "item edit": ["--title", "--vault", "--url", "--tags", "--generate-password", "--reveal"],
        "item delete": ["--vault", "--archive"],
    ]

    /// Parses `argv` (after `op`).
    public static func parse(_ argv: [String]) -> Result<ItemWrite, Unsupported> {
        func refuse(_ reason: String) -> Result<ItemWrite, Unsupported> { .failure(Unsupported(reason: reason)) }
        var words: [String] = []
        var flags: [String: String] = [:]
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            if arg == "--" { return refuse("uses --") }
            guard arg.hasPrefix("-"), arg != "-" else {
                words.append(arg)
                i += 1
                continue
            }
            let eq = arg.hasPrefix("--") ? arg.firstIndex(of: "=") : nil
            let name = eq.map { String(arg[..<$0]) } ?? arg
            let inline = eq.map { String(arg[arg.index(after: $0)...]) }
            guard flags[name] == nil else { return refuse("repeats \(name)") }
            if OpCommand.valueFlags.contains(name), inline == nil {
                guard i + 1 < argv.count else { return refuse("\(name) has no value") }
                i += 1
                flags[name] = argv[i]
            } else {
                flags[name] = inline ?? ""
            }
            i += 1
        }
        guard words.count >= 2 else { return refuse("names no command") }
        let path = words[0] + " " + words[1]
        guard let allowed = commandFlags[path] else { return refuse("`op \(path)` isn't an item write opProxy handles") }
        if let other = flags.keys.sorted().first(where: { !allowed.contains($0) && !ItemRequest.globalFlags.contains($0) }) {
            return refuse("uses \(other)")
        }
        var positionals = Array(words.dropFirst(2))
        if positionals.contains("-") { return refuse("reads from stdin") }
        let kind: Kind
        var item: String?
        switch path {
        case "item create":
            kind = .create
        case "item edit":
            kind = .edit
            guard !positionals.isEmpty else { return refuse("names no item") }
            item = positionals.removeFirst()
        default:
            kind = .delete(archive: flags["--archive"] != nil)
            guard positionals.count == 1 else { return refuse("names \(positionals.count) items") }
            item = positionals.removeFirst()
        }
        if item?.isEmpty == true { return refuse("names an empty item") }
        var assignments: [Assignment] = []
        for word in positionals {
            guard let a = parseAssignment(word) else { return refuse("has an assignment opProxy can't read") }
            if a.type == "file" { return refuse("attaches a file") }
            if let type = a.type, !assignmentTypes.keys.contains(type), type != "delete" {
                return refuse("uses field type \(type)")
            }
            if a.isDelete, kind == .create { return refuse("deletes a field from a new item") }
            assignments.append(a)
        }
        var category: String?
        if kind == .create {
            guard let named = flags["--category"], let sdk = OpOutput.sdkCategory(named: named) else {
                return refuse("has no category opProxy knows")
            }
            category = sdk
            if sdk == "Document" { return refuse("creates a document") }
        }
        var recipe: SDK.PasswordRecipe?
        if let spec = flags["--generate-password"] {
            guard let parsed = Self.recipe(spec) else { return refuse("has a password recipe opProxy can't read") }
            recipe = parsed
        }
        if case .delete = kind, !assignments.isEmpty { return refuse("deletes and assigns at once") }
        let title = flags["--title"]
        if title?.isEmpty == true { return refuse("has an empty --title") }
        if flags["--vault"]?.isEmpty == true { return refuse("has an empty --vault") }
        let tags = flags["--tags"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        return .success(ItemWrite(kind: kind, item: item, vault: flags["--vault"], account: flags["--account"],
                                  category: category, title: title, url: flags["--url"], tags: tags, generatePassword: recipe,
                                  assignments: assignments, flags: flags, argv: argv))
    }

    /// `op`'s assignment types and the SDK field types they make.
    static let assignmentTypes: [String: String] = [
        "password": "Concealed", "concealed": "Concealed", "text": "Text", "string": "Text", "email": "Email",
        "url": "Url", "date": "Date", "monthYear": "MonthYear", "monthyear": "MonthYear", "phone": "Phone", "otp": "Totp",
    ]

    /// `[<section>.]<field>[[<type>]]=<value>`, where `\` escapes `.`, `=` and `\`.
    static func parseAssignment(_ word: String) -> Assignment? {
        var left: [(Character, escaped: Bool)] = []
        var value: String?
        var chars = Array(word)[...]
        while let c = chars.popFirst() {
            if c == "\\", let next = chars.popFirst() {
                left.append((next, true))
            } else if c == "=" {
                value = String(chars)
                break
            } else {
                left.append((c, false))
            }
        }
        var type: String?
        if left.last?.0 == "]", !left.last!.escaped, let open = left.lastIndex(where: { $0.0 == "[" && !$0.escaped }) {
            type = String(left[(open + 1)..<(left.count - 1)].map(\.0))
            left = Array(left[..<open])
        }
        if value == nil, type != "delete" { return nil }
        if type == "delete", value != nil { return nil }
        var section: String?
        var field = left
        if let dot = left.firstIndex(where: { $0.0 == "." && !$0.escaped }) {
            section = String(left[..<dot].map(\.0))
            field = Array(left[(dot + 1)...])
        }
        let name = String(field.map(\.0))
        guard !name.isEmpty, section?.isEmpty != true else { return nil }
        return Assignment(section: section, field: name, type: type == "delete" ? nil : type, value: value)
    }

    /// `letters,digits,symbols,32`: `op`'s recipe. Empty means its default.
    static func recipe(_ spec: String) -> SDK.PasswordRecipe? {
        if spec.isEmpty { return SDK.PasswordRecipe(length: 32, digits: true, symbols: true) }
        var recipe = SDK.PasswordRecipe(length: 32, digits: false, symbols: false)
        for part in spec.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            switch part {
            case "letters": break
            case "digits": recipe.digits = true
            case "symbols": recipe.symbols = true
            default:
                guard let n = Int(part), (1...64).contains(n) else { return nil }
                recipe.length = n
            }
        }
        return recipe
    }

    // MARK: What it changes

    /// e.g. "Create an item".
    public var action: String {
        switch kind {
        case .create: return "Create an item"
        case .edit: return "Edit an item"
        case .delete(archive: false): return "Delete an item"
        case .delete(archive: true): return "Archive an item"
        }
    }

    /// The change, field by field, without any value.
    public var details: [ItemRequest.Detail] {
        var out: [ItemRequest.Detail] = []
        if let category { out.append(.init(label: "Category", value: OpOutput.category(category))) }
        if let title { out.append(.init(label: kind == .create ? "Title" : "New title", value: title)) }
        let sets = assignments.filter { !$0.isDelete }.map { a -> String in
            "\(a.name) (\(a.type.map { "\($0), " } ?? "")\(a.value!.count) character\(a.value!.count == 1 ? "" : "s"))"
        } + (generatePassword.map { ["password (generated, \($0.length) characters)"] } ?? [])
        if !sets.isEmpty { out.append(.init(label: "Sets", value: sets.joined(separator: ", "))) }
        let removes = assignments.filter(\.isDelete).map(\.name)
        if !removes.isEmpty { out.append(.init(label: "Removes", value: removes.joined(separator: ", "))) }
        if let url { out.append(.init(label: "Website", value: url)) }
        if let tags { out.append(.init(label: "Tags", value: tags.isEmpty ? "none" : tags.joined(separator: ", "))) }
        if kind == .edit, sets.isEmpty, removes.isEmpty, title == nil, url == nil, tags == nil {
            out.append(.init(label: "Changes", value: "nothing", style: .placeholder))
        }
        if let account { out.append(.init(label: "Account", value: account)) }
        return out
    }

    /// Completes "let Claude … <summary>".
    public func summary(_ target: ItemIdentity) -> String {
        let name = "“\(target.label)”"
        switch kind {
        case .create: return "create \(name)"
        case .edit: return "edit \(name)"
        case .delete(archive: false): return "delete \(name)"
        case .delete(archive: true): return "archive \(name)"
        }
    }

    /// The command line with every assigned value replaced, for showing and logging.
    public var redactedArgv: [String] {
        argv.map { word in
            guard !word.hasPrefix("-"), let a = Self.parseAssignment(word), !a.isDelete,
                  let eq = Self.unescapedEquals(word) else { return word }
            return String(word[..<eq]) + "=" + Self.hidden
        }
    }

    public static let hidden = "‹hidden›"

    /// Every value this write assigns, so the agent's own command line can be shown without them.
    public var secrets: [String] { assignments.compactMap(\.value).filter { $0.count >= 3 } }

    private static func unescapedEquals(_ word: String) -> String.Index? {
        var i = word.startIndex
        while i < word.endIndex {
            if word[i] == "\\" { i = word.index(after: i); if i < word.endIndex { i = word.index(after: i) }; continue }
            if word[i] == "=" { return i }
            i = word.index(after: i)
        }
        return nil
    }

    // MARK: Applying it

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// The fields each category has without a section, by the name `op` assigns them with.
    static let builtIn: [String: [String: (id: String, type: String)]] = [
        "Login": ["username": ("username", "Text"), "password": ("password", "Concealed")],
        "Password": ["password": ("password", "Concealed")],
        "ApiCredentials": ["username": ("username", "Text"), "credential": ("credential", "Concealed"),
                           "type": ("type", "Menu"), "filename": ("filename", "Text"), "valid from": ("validFrom", "Date"),
                           "validfrom": ("validFrom", "Date"), "expires": ("expires", "Date"), "hostname": ("hostname", "Text")],
        "Database": ["type": ("database_type", "Menu"), "server": ("hostname", "Text"), "port": ("port", "Text"),
                     "database": ("database", "Text"), "username": ("username", "Text"), "password": ("password", "Concealed")],
        "Server": ["url": ("url", "Text"), "username": ("username", "Text"), "password": ("password", "Concealed")],
    ]

    /// Section for fields assigned without one that aren't built in, as `op` does.
    static let looseSection = SDK.Section(id: "add more", title: "")

    /// The new item, for `create`.
    public func creation(vaultId: String, generated: String?) throws -> SDK.ItemCreate {
        var item = SDK.Item(id: "", title: title ?? "", category: category ?? "Login", vaultId: vaultId)
        try apply(to: &item, generated: generated)
        return SDK.ItemCreate(category: item.category, vaultId: vaultId, title: item.title, fields: item.fields,
                              sections: item.sections, notes: item.notes.isEmpty ? nil : item.notes, tags: item.tags,
                              websites: item.websites)
    }

    /// Makes this edit to `item` (also how `creation` fills a new one).
    public func apply(to item: inout SDK.Item, generated: String?) throws {
        if let title { item.title = title }
        if let tags { item.tags = tags }
        if let url {
            if item.websites.isEmpty { item.websites = [SDK.Website(url: url)] } else { item.websites[0].url = url }
        }
        if let generated {
            guard ["Login", "Password"].contains(item.category) else {
                throw Failure(description: "--generate-password only works on Login and Password items")
            }
            set(&item, Assignment(section: nil, field: "password", type: "password", value: generated))
        }
        for a in assignments {
            if a.section == nil, ["notesplain", "notes"].contains(a.field.lowercased()) {
                item.notes = a.value ?? ""
                continue
            }
            if a.isDelete {
                guard let i = index(of: a, in: item) else {
                    throw Failure(description: "“\(a.name)” isn't a field of “\(item.title)”")
                }
                item.fields.remove(at: i)
            } else {
                set(&item, a)
            }
        }
    }

    private func set(_ item: inout SDK.Item, _ a: Assignment) {
        let type = a.type.flatMap { Self.assignmentTypes[$0] }
        if let i = index(of: a, in: item) {
            item.fields[i].value = a.value ?? ""
            if let type { item.fields[i].fieldType = type }
            return
        }
        if a.section == nil, let builtIn = Self.builtIn[item.category]?[a.field.lowercased()] {
            item.fields.append(SDK.Field(id: builtIn.id, title: a.field, fieldType: type ?? builtIn.type, value: a.value ?? ""))
            return
        }
        let section: SDK.Section
        if let name = a.section {
            if let found = item.sections.first(where: { Self.matches($0.title, name) || $0.id == name }) {
                section = found
            } else {
                section = SDK.Section(id: Self.newId(), title: name)
                item.sections.append(section)
            }
        } else {
            if !item.sections.contains(where: { $0.id == Self.looseSection.id }) { item.sections.append(Self.looseSection) }
            section = Self.looseSection
        }
        item.fields.append(SDK.Field(id: Self.newId(), title: a.field, sectionId: section.id, fieldType: type ?? "Text",
                                     value: a.value ?? ""))
    }

    /// The field an assignment names: in its section (by title or ID), or else among fields
    /// with no section or an untitled one; by title or ID, in any case.
    private func index(of a: Assignment, in item: SDK.Item) -> Int? {
        item.fields.firstIndex { f in
            guard Self.matches(f.title, a.field) || f.id == a.field else { return false }
            let section = item.section(f.sectionId)
            if let name = a.section { return section.map { Self.matches($0.title, name) || $0.id == name } ?? false }
            return section == nil || section!.title.isEmpty
        }
    }

    private static func matches(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

    /// A field or section ID like 1Password's: 26 lowercase letters and digits.
    static func newId() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        return String((0..<26).map { _ in alphabet.randomElement()! })
    }
}
