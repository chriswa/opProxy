import AppKit
import OpProxyCore

/// Key icon with how many hours the daemon's 1Password authorization has held; a red snapped
/// key once it's gone. The menu shows when it started and offers a fresh one.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let daemon: Daemon
    /// Pairs an iPhone through opProxy iCloud Relay.
    private let pairing: PhonePairing?
    private let paths: Paths
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let detailLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "")
    private let installedItem = NSMenuItem(title: "Installed", action: #selector(toggleInstalled), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    /// Phones that can answer from the approval feed; its submenu is rebuilt each time.
    private let phonesItem = NSMenuItem(title: "Paired Phones", action: nil, keyEquivalent: "")
    /// Recent approvals and Revoke All, rebuilt each time the menu opens.
    private var approvalItems: [NSMenuItem] = []
    private var refreshing = false
    private var lastError: String?
    private var timer: Timer?

    init(daemon: Daemon, pairing: PhonePairing?, paths: Paths) {
        self.daemon = daemon
        self.pairing = pairing
        self.paths = paths
        super.init()
        // Lets Ice and macOS remember the item's position.
        item.autosaveName = "opProxy"
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        detailLine.isEnabled = false
        refreshItem.target = self
        installedItem.target = self
        installedItem.toolTip = "Unchecked: every op call goes straight to 1Password, bypassing opProxy"
        loginItem.target = self
        let versionItem = NSMenuItem(title: "opProxy \(MacIdentity.appVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        let setupItem = NSMenuItem(title: "Setup…", action: #selector(showSetup), keyEquivalent: "")
        setupItem.target = self
        let restartItem = NSMenuItem(title: "Restart opProxy", action: #selector(restartApp), keyEquivalent: "")
        restartItem.target = self
        let quitItem = NSMenuItem(title: "Quit opProxy", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        quitItem.toolTip = "op calls go straight to 1Password until opProxy is opened again or you log in"
        // Top level, not under Paired Phones, so it's easy to find; the iPhone app shows a
        // picture of this menu (PairingGuide) to point to it.
        let pairItem = NSMenuItem(title: "Pair an iPhone…", action: #selector(pairPhone), keyEquivalent: "")
        pairItem.target = self
        pairItem.isHidden = pairing == nil
        [statusLine, detailLine, .separator(), refreshItem, .separator(), .separator(), pairItem, phonesItem, installedItem,
         loginItem, setupItem, .separator(), versionItem, restartItem, quitItem].forEach(menu.addItem)
        menu.delegate = self
        item.menu = menu
        daemon.auth.onChange = { [weak self] _ in
            self?.lastError = nil
            self?.render()
        }
        // Minute resolution is all the label shows.
        tick()
    }

    func menuWillOpen(_ menu: NSMenu) {
        render()
        rebuildApprovals(in: menu)
        rebuildPhones()
    }

    // MARK: Recent approvals

    private final class Action: NSObject {
        let revocation: Daemon.Revocation
        init(_ revocation: Daemon.Revocation) { self.revocation = revocation }
    }

    private func rebuildApprovals(in menu: NSMenu) {
        approvalItems.forEach(menu.removeItem)
        approvalItems = []
        let recent = daemon.recentApprovals(limit: 20)
        let header = NSMenuItem(title: recent.isEmpty ? "No Active Approvals" : "Recent Approvals", action: nil, keyEquivalent: "")
        header.isEnabled = false
        approvalItems.append(header)
        let time = DateFormatter()
        time.dateFormat = "MMM d, h:mm a"
        for approval in recent {
            let item = NSMenuItem(title: approval.title, action: nil, keyEquivalent: "")
            let title = NSMutableAttributedString(string: String(approval.title.prefix(48)),
                                                  attributes: [.font: NSFont.menuFont(ofSize: 13)])
            title.append(NSAttributedString(string: "   \(approval.requester.prefix(40)) · \(time.string(from: approval.approvedAt))",
                                            attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = title
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            var info = [approval.requester]
            if let ids = approval.ids { info.append(ids) }
            let expiry: String
            switch approval.expiresAt {
            case .some(let date) where date >= ApprovalStore.forever: expiry = "never expires"
            case .some(let date): expiry = "expires \(time.string(from: date))"
            case .none: expiry = "lapses after \(Int(TerminalApprovals.defaultIdle / 60)) idle minutes"
            }
            info.append("Allowed \(time.string(from: approval.approvedAt)) · " + expiry)
            for line in info {
                let infoItem = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                infoItem.isEnabled = false
                submenu.addItem(infoItem)
            }
            submenu.addItem(.separator())
            switch approval.target {
            case .agent(let key):
                let duration = NSMenu()
                duration.autoenablesItems = false
                let now = Date()
                for lifetime in ApprovalLifetime.allCases {
                    let until = lifetime.expiry(from: now)
                    let item = amendItem(lifetime.label + (lifetime == .day ? ", from Now" : ""),
                                         Amend(key: key, expiresAt: until))
                    // Checked when the current expiry is what this choice would set now.
                    if let current = approval.expiresAt {
                        let matches = lifetime == .forever ? current >= ApprovalStore.forever
                            : abs(current.timeIntervalSince(until)) <= 5 * 60
                        item.state = matches ? .on : .off
                    }
                    duration.addItem(item)
                }
                submenu.addItem(withTitle: "Duration", action: nil, keyEquivalent: "").submenu = duration
                let reach = NSMenu()
                reach.autoenablesItems = false
                let narrowTo = key.audience == .allAgents ? approval.grantedTo : key.audience
                let session = amendItem("This Agent", Amend(key: key, audience: narrowTo))
                session.state = key.audience == .allAgents ? .off : .on
                // An all-agents approval granted on a phone or before this was recorded has no session to narrow to.
                session.isEnabled = narrowTo != nil
                let all = amendItem("All Agents", Amend(key: key, audience: .allAgents))
                all.state = key.audience == .allAgents ? .on : .off
                [session, all].forEach(reach.addItem)
                submenu.addItem(withTitle: "For", action: nil, keyEquivalent: "").submenu = reach
                submenu.addItem(.separator())
                submenu.addItem(actionItem("Revoke This Approval", .one(approval.target)))
                if key.audience != .allAgents {
                    submenu.addItem(actionItem("Revoke Everything for This Agent", .session(approval.target)))
                }
            case .terminal:
                submenu.addItem(actionItem("Revoke This Terminal Tab's Access", .one(approval.target)))
            }
            item.submenu = submenu
            approvalItems.append(item)
        }
        if !recent.isEmpty { approvalItems.append(actionItem("Revoke All", .all)) }
        // Between the separators around this section.
        let anchor = menu.index(of: refreshItem) + 2
        for (offset, item) in approvalItems.enumerated() { menu.insertItem(item, at: anchor + offset) }
    }

    /// A change to one approval's expiry or audience.
    private final class Amend: NSObject {
        let key: ApprovalKey
        let audience: ApprovalAudience?, expiresAt: Date?
        init(key: ApprovalKey, audience: ApprovalAudience? = nil, expiresAt: Date? = nil) {
            (self.key, self.audience, self.expiresAt) = (key, audience, expiresAt)
        }
    }

    private func amendItem(_ title: String, _ amend: Amend) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(amend(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = amend
        return item
    }

    /// The expiry and audience are signed, so a change is signed again.
    @objc private func amend(_ sender: NSMenuItem) {
        guard let change = sender.representedObject as? Amend else { return }
        // Off the main thread: a build without the team's keychain asks for Touch ID to sign.
        DispatchQueue.global().async { [self] in
            let result = daemon.amend(change.key, audience: change.audience, expiresAt: change.expiresAt)
            DispatchQueue.main.async { [self] in
                if case .failed(let reason) = result { lastError = "Change failed: \(reason)" } else { lastError = nil }
                render()
            }
        }
    }

    // MARK: Paired phones

    private func rebuildPhones() {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let phones = daemon.devices.devices
        if phones.isEmpty {
            let none = NSMenuItem(title: "No Paired Phones", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        for phone in phones {
            let item = NSMenuItem(title: "Unpair \(phone.name) · \(phone.fingerprint)", action: #selector(unpair(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = phone.keyId
            item.toolTip = "Its lasting approvals stop working too"
            submenu.addItem(item)
        }
        phonesItem.submenu = submenu
    }

    @objc private func pairPhone() { pairing?.start() }

    @objc private func showSetup() { SetupWindow.show(paths: paths, pairing: pairing) }

    @objc private func unpair(_ sender: NSMenuItem) {
        guard let keyId = sender.representedObject as? String else { return }
        do { try daemon.devices.unpair { $0.keyId == keyId } } catch { lastError = "Unpair failed: \(error)" }
        render()
    }

    private func actionItem(_ title: String, _ revocation: Daemon.Revocation) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(revoke(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Action(revocation)
        return item
    }

    @objc private func revoke(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? Action else { return }
        daemon.revoke(action.revocation)
    }

    /// Redraws every minute; the label only counts hours.
    private func tick() {
        render()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in self?.tick() }
    }

    private func render() {
        loginItem.state = LaunchAgent.opensAtLogin ? .on : .off
        let disabled = daemon.paths.isDisabled
        installedItem.state = disabled ? .off : .on
        if disabled {
            item.button?.image = StatusIcon.disabled()
            item.button?.toolTip = "opProxy is off: op calls go straight to 1Password"
            statusLine.title = "opProxy is off"
            detailLine.title = "op calls go straight to 1Password"
            detailLine.isHidden = false
            refreshItem.isEnabled = false
            return
        }
        let window = daemon.auth.current
        let now = Date()
        let clock = DateFormatter()
        clock.dateFormat = Calendar.current.isDateInToday(window.authorizedAt ?? now) ? "h:mm a" : "EEE MMM d, h:mm a"
        if let age = window.age(at: now), let since = window.authorizedAt {
            item.button?.image = StatusIcon.key(label: Duration.hours(age))
            item.button?.toolTip = "1Password authorized \(Duration.long(age)) ago"
            statusLine.title = "1Password authorized · \(Duration.long(age))"
            detailLine.title = "Since \(clock.string(from: since)), until 1Password locks or updates"
        } else {
            item.button?.image = StatusIcon.snappedKey()
            item.button?.toolTip = "1Password not authorized"
            statusLine.title = "1Password not authorized"
            detailLine.title = "The next agent request will prompt 1Password"
        }
        if let lastError { detailLine.title = lastError }
        detailLine.isHidden = detailLine.title.isEmpty
        refreshItem.title = refreshing ? "Waiting for 1Password…" : "Refresh Now"
        refreshItem.isEnabled = !refreshing
    }

    @objc private func toggleLogin() {
        LaunchAgent.setOpensAtLogin(loginItem.state != .on)
        render()
    }

    @objc private func restartApp() { LaunchAgent.restart() }

    @objc private func quitApp() { LaunchAgent.quit() }

    @objc private func toggleInstalled() {
        do { try daemon.paths.setDisabled(!daemon.paths.isDisabled) } catch { lastError = "\(error)" }
        render()
    }

    @objc private func refresh() {
        refreshing = true
        lastError = nil
        render()
        DispatchQueue.global().async { [self] in
            let error = daemon.auth.refresh()
            DispatchQueue.main.async { [self] in
                refreshing = false
                lastError = error.map { "Refresh failed: \($0)" }
                render()
            }
        }
    }
}
