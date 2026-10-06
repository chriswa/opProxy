import AppKit
import LocalAuthentication
import OpProxyCore

/// Key icon with time left on the daemon's 1Password authorization; a red snapped key once
/// it's gone. The menu shows the exact expiry and offers an early refresh.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let daemon: Daemon
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

    init(daemon: Daemon) {
        self.daemon = daemon
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
        let restartItem = NSMenuItem(title: "Restart opProxy", action: #selector(restartApp), keyEquivalent: "")
        restartItem.target = self
        let quitItem = NSMenuItem(title: "Quit opProxy", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        quitItem.toolTip = "op calls go straight to 1Password until opProxy is opened again or you log in"
        [statusLine, detailLine, .separator(), refreshItem, .separator(), .separator(), phonesItem, installedItem, loginItem,
         .separator(), restartItem, quitItem].forEach(menu.addItem)
        menu.delegate = self
        item.menu = menu
        daemon.auth.onChange = { [weak self] _ in
            self?.lastError = nil
            self?.render()
        }
        // Minute resolution is all the label shows.
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.render() }
        render()
    }

    func menuWillOpen(_ menu: NSMenu) {
        render()
        rebuildApprovals(in: menu)
        rebuildPhones()
        // Names for approvals stored under a bare ID; shows up the next time the menu opens.
        DispatchQueue.global().async { [daemon] in daemon.repairItemLabels() }
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
            if let command = approval.command { info.append(String(command.prefix(90))) }
            let expiry: String
            switch approval.expiresAt {
            case .some(let date) where date >= ApprovalStore.forever: expiry = "never expires (while the agent runs)"
            case .some(let date): expiry = "expires \(time.string(from: date))"
            case .none: expiry = "lapses after \(Int(TerminalApprovals.defaultIdle / 60)) idle minutes"
            }
            info.append("Approved \(time.string(from: approval.approvedAt)) · " + expiry)
            for line in info {
                let infoItem = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                infoItem.isEnabled = false
                submenu.addItem(infoItem)
            }
            submenu.addItem(.separator())
            switch approval.target {
            case .agent(let key):
                let heading = NSMenuItem(title: "Duration, from Now", action: nil, keyEquivalent: "")
                heading.isEnabled = false
                submenu.addItem(heading)
                for (label, until) in Self.durations() {
                    let item = NSMenuItem(title: label, action: #selector(changeDuration(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = DurationChange(key: key, title: approval.title, label: label, until: until)
                    // Checked when the current expiry is what this choice would set now.
                    if let current = approval.expiresAt {
                        let matches = until >= ApprovalStore.forever ? current >= ApprovalStore.forever
                            : abs(current.timeIntervalSince(until)) <= 5 * 60
                        item.state = matches ? .on : .off
                    }
                    submenu.addItem(item)
                }
                submenu.addItem(.separator())
                submenu.addItem(actionItem("Revoke This Approval", .one(approval.target)))
                submenu.addItem(actionItem("Revoke Everything for This Session", .session(approval.target)))
            case .terminal:
                submenu.addItem(actionItem("Revoke This Tab's Access", .one(approval.target)))
            }
            item.submenu = submenu
            approvalItems.append(item)
        }
        if !recent.isEmpty { approvalItems.append(actionItem("Revoke All", .all)) }
        // Between the separators around this section.
        let anchor = menu.index(of: refreshItem) + 2
        for (offset, item) in approvalItems.enumerated() { menu.insertItem(item, at: anchor + offset) }
    }

    private final class DurationChange: NSObject {
        let key: ApprovalKey, title: String, label: String, until: Date
        init(key: ApprovalKey, title: String, label: String, until: Date) {
            (self.key, self.title, self.label, self.until) = (key, title, label, until)
        }
    }

    private static func durations() -> [(String, Date)] {
        let now = Date()
        return [("1 Hour", now.addingTimeInterval(3600)),
                ("7 Days", now.addingTimeInterval(ApprovalStore.defaultTTL)),
                ("3 Months", now.addingTimeInterval(90 * 24 * 3600)),
                ("Forever", ApprovalStore.forever)]
    }

    /// The expiry is signed. The daemon re-signs with the context from your latest Touch ID
    /// approval; only when it has none (e.g. after a restart) does this ask for Touch ID, via
    /// the system sheet since menus can't host the inline glyph.
    @objc private func changeDuration(_ sender: NSMenuItem) {
        guard let change = sender.representedObject as? DurationChange else { return }
        switch daemon.changeExpiry(change.key, to: change.until) {
        case .changed:
            lastError = nil
            render()
        case .failed(let reason):
            lastError = "Change failed: \(reason)"
            render()
        case .needsTouchID:
            let context = LAContext()
            let reason = "change access to “\(change.title)” to \(change.label.lowercased())"
            context.evaluateAccessControl(EnclaveSigner.accessControl(), operation: .useKeySign, localizedReason: reason) { ok, _ in
                DispatchQueue.main.async { [self] in
                    guard ok else { return }
                    if case .failed(let reason) = daemon.changeExpiry(change.key, to: change.until, context: context) {
                        lastError = "Change failed: \(reason)"
                    }
                    render()
                }
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
        clock.dateFormat = "h:mm a"
        if let remaining = window.remaining(at: now), let expiresAt = window.expiresAt {
            item.button?.image = StatusIcon.key(remaining: Duration.short(remaining))
            item.button?.toolTip = "1Password CLI authorized for \(Duration.long(remaining)) more"
            statusLine.title = "1Password authorized · \(Duration.long(remaining)) left"
            detailLine.title = "Expires at \(clock.string(from: expiresAt))"
        } else {
            item.button?.image = StatusIcon.snappedKey()
            item.button?.toolTip = "1Password CLI not authorized"
            statusLine.title = window.signedIn ? "1Password authorization is past 12 hours" : "1Password not authorized"
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
