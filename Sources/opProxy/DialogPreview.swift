#if OPPROXY_TESTING
import AppKit
import OpProxyCore

/// `opProxy render-dialog <dir>`: renders the approval panel for sample requests to PNGs
/// (light and dark), for checking layout without a live request.
enum DialogPreview {
    /// Lays captured images out in a row, numbered and named.
    static func contactSheet(_ shots: [(String, URL)], to url: URL) {
        let images = shots.compactMap { name, url in NSImage(contentsOf: url).map { (name, $0) } }
        guard let first = images.first?.1 else { return }
        let rep0 = first.representations.first!
        let scale = CGFloat(rep0.pixelsWide) / first.size.width
        let pad: CGFloat = 30, labelHeight: CGFloat = 40
        let w = images.reduce(pad) { $0 + $1.1.size.width + pad }
        let h = images.map { $0.1.size.height }.max()! + pad * 2 + labelHeight
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        var x = pad
        for (i, (name, image)) in images.enumerated() {
            image.draw(in: NSRect(x: x, y: pad, width: image.size.width, height: image.size.height))
            NSAttributedString(string: "\(i + 1). \(name)", attributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.white,
            ]).draw(at: NSPoint(x: x, y: h - labelHeight - 4))
            x += image.size.width + pad
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print(url.path)
    }

    /// Puts `view` on screen briefly and captures its window as composited.
    static func capture(_ view: NSView, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        Caution.style(window)
        window.contentView = view
        window.setContentSize(view.fittingSize)
        window.setFrameOrigin(.zero)
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                               [.boundsIgnoreFraming, .bestResolution]) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
        print(url.path)
    }

    static func render(to dir: URL, onScreen: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Setup-backdrop color candidates, side by side with names.
        var shots: [(String, URL)] = []
        for theme in SetupTheme.options {
            let url = dir.appendingPathComponent("setup-\(theme.name).png")
            capture(AuthContextView(reason: .startup, until: "4:23 AM", width: 440, gap: 300, promptOwner: "1Password",
                                    theme: theme, placeholder: true), to: url)
            shots.append((theme.name, url))
        }
        contactSheet(shots, to: dir.appendingPathComponent("setup-themes.png"))
        let session = AgentSession(agent: .claude, sessionId: "c7d70e94-8847-4d74-b674-231862575006")
        let surface = SpacetermSurface(nodeId: "60af98d7-fdba-42a0-bb45-e02c94476075",
                                       title: "opProxy menu bar + hardening", agentName: "Kevin")
        let linear = ItemIdentity(itemId: "h3j8k1m6n4p9r2s7t5v0w8x3yz", vaultId: "q4a7m2x9c1v6b3n8z5k0w2e7rt",
                                  title: "Issue Tracker API key", vaultName: "Private")
        let samples: [(String, [String], String?, String?, ItemIdentity)] = [
            ("item-get",
             ["item", "get", "Issue Tracker API key", "--fields", "label=credential", "--reveal"],
             #"TRACKER_KEY=$(op item get "Issue Tracker API key" --fields label=credential --reveal) && curl -s -X POST https://api.example.com/graphql -H "Authorization: $TRACKER_KEY" -H "Content-Type: application/json" -d '{"query":"{ issue(id: \"PROJ-521\") { title state { name } assignee { name } } }"}' | jq ."#,
             "I'll pull the ticket details from the issue tracker so I can check whether PROJ-521 is already assigned before starting on the config change.",
             linear),
            ("read-by-id",
             ["read", "op://Private/a8d2f6g1h9j4k7l3m5n0p2q6rs/password"],
             #"export DEPLOY_KEY=$(op read 'op://Private/a8d2f6g1h9j4k7l3m5n0p2q6rs/password')"# + "\n" + #"curl -s https://api.example.com/v1/sessions -H "Authorization: Bearer $DEPLOY_KEY" | jq '.sessions[] | {session_id, status_enum, title}' | head -40"#,
             "The release build failed again. Next I'll list recent deploys to find the one that ran the migration, then read its log.\n\nIf that deploy is gone I'll fall back to the build logs API.",
             ItemIdentity(itemId: "a8d2f6g1h9j4k7l3m5n0p2q6rs", vaultId: "q4a7m2x9c1v6b3n8z5k0w2e7rt",
                          title: "Deploy key", vaultName: "Private")),
            ("forever-all", ["read", "op://Private/Chat webhook/credential"],
             #"CHAT_TOKEN=$(op read "op://Private/Chat webhook/credential") ./post-summary.sh"#,
             "Posting the summary to #team-updates.",
             ItemIdentity(itemId: "b5c9d3e7f1g6h0i4j8k2l6m1np", vaultId: "q4a7m2x9c1v6b3n8z5k0w2e7rt",
                          title: "Chat webhook", vaultName: "Private")),
            ("minimal", ["document", "get", "prod-ssh-config", "--vault", "Engineering"], nil, nil,
             ItemIdentity(itemId: "q2w3e4r5t6y7u8i9o0p1a2s3d4", vaultId: "pk3m7c2vq4xzt6nyb5rwd8hjfa",
                          title: "prod-ssh-config", vaultName: "Engineering")),
            ("terminal", ["item", "get", "Issue Tracker API key", "--fields", "label=credential", "--reveal"],
             nil, nil, linear),
        ]
        for (name, argv, tool, message, target) in samples {
            guard case .success(let item) = ItemRequest.parse(argv) else { fatalError("unparseable sample \(argv)") }
            let request = ProxyRequest(session: session, spacetermNodeId: surface.nodeId, argv: argv, env: [:],
                                       cwd: "/Users/me/projects/app")
            let requester: Requester
            let key: DialogKey
            if name == "terminal" {
                key = .terminal(TerminalKey(sid: 30112, leaderStart: 1))
                requester = .terminal(TerminalRequester(
                    info: TerminalInfo(app: "iTerm", tty: "ttys012", sid: 30112, chain: [
                        "48213  op item get Issue Tracker API key --fields label=credential --reveal",
                        "48190  python3 scripts/sync_linear.py --since yesterday",
                        "30112  -zsh"]),
                    surface: nil))
            } else {
                key = .agent(ApprovalKey(audience: .session(agent: .claude, sessionId: session.sessionId),
                                         item: ItemRef(account: nil, vaultId: target.vaultId, itemId: target.itemId)))
                // The minimal sample is an agent outside Spaceterm, which has no name.
                requester = .agent(AgentRequester(session: session, surface: name == "minimal" ? nil : surface,
                                                  caller: CallerContext(toolCommand: tool, viaProcess: nil),
                                                  lastMessage: message, agentPid: 26441))
            }
            let prompt = ApprovalPrompt(key: key, request: request, requester: requester, item: item, target: target,
                                        peerPid: 48213)
            // The panel has one fixed look; render it under both system appearances to prove it.
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let view = ApprovalView(prompt: prompt, actions: nil, authContext: nil)
                if name == "read-by-id" { view.setWaiting(2) }
                if name == "forever-all" { view.choose(.forever, .allAgents) }
                view.setRemaining(name == "minimal" ? 14 : 87)
                if name == "minimal" { view.showAbandoned() }
                try? view.copyText.write(to: dir.appendingPathComponent("dialog-\(name).txt"), atomically: true, encoding: .utf8)
                NSApp.appearance = NSAppearance(named: appearance)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize),
                                      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                Caution.style(window)
                window.contentView = view
                window.setContentSize(view.fittingSize)
                view.layoutSubtreeIfNeeded()
                let frame = window.contentView!.superview!
                let url = dir.appendingPathComponent("dialog-\(name)-\(suffix)\(onScreen ? "-screen" : "").png")
                if onScreen {
                    // Composited by the window server exactly as it would appear. Capturing our
                    // own window needs no screen-recording permission.
                    window.setFrameOrigin(NSPoint(x: 0, y: 0))
                    window.orderFrontRegardless()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                    if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                           [.boundsIgnoreFraming, .bestResolution]) {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                    }
                    window.orderOut(nil)
                } else {
                    let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
                    frame.cacheDisplay(in: frame.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
                print(url.path)
            }
        }
    }
}
#endif
