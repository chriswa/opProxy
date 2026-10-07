import AppKit
import OpProxyCore

/// Sits just below 1Password's own authorization prompt and says what it's for, chiming as each
/// prompt it frames appears. No buttons: it never takes focus or clicks, so the 1Password
/// dialog stays the thing you act on.
final class AuthContextPanel: AuthPromptObserver {
    /// Only calls still waiting after this long are assumed to be showing a prompt.
    static let showDelay: TimeInterval = 0.4
    let expiresIn: TimeInterval
    let log: Log?
    private var panel: NSPanel?
    private var follow: Timer?
    private var generation = 0

    init(expiresIn: TimeInterval, log: Log? = nil) {
        self.expiresIn = expiresIn
        self.log = log
    }

    func authorizationMayPrompt(_ reason: AuthReason) -> () -> Void {
        var token = 0
        let claim = { self.generation += 1; token = self.generation }
        if Thread.isMainThread { claim() } else { DispatchQueue.main.sync(execute: claim) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay) { [self] in
            if generation == token { show(reason) }
        }
        return { DispatchQueue.main.async { [self] in
            if generation == token { generation += 1; hide() }
        } }
    }

    private var reason: AuthReason = .startup
    private var prompt: PromptWindow?
    /// Owner of the prompt last framed, so each new prompt chimes once.
    private var framedOwner: String?

    private func show(_ reason: AuthReason) {
        hide()
        self.reason = reason
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Below 1Password's prompt (window level 101), so the prompt always sits on top of it.
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        self.panel = panel
        framedOwner = nil
        prompt = Self.promptWindow()
        log?.write("watching for 1Password prompts (\(reason)); prompt window: \(Self.describe(prompt))")
        layout()
        // 1Password's prompt can appear or move after we do; keep framing it.
        follow = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let current = Self.promptWindow()
            if current != self.prompt {
                self.log?.write("prompt window: \(Self.describe(current))")
                self.prompt = current
                self.layout()
            }
        }
    }

    private static func describe(_ p: PromptWindow?) -> String {
        guard let p else { return "none" }
        return "\(p.owner) layer \(p.layer), \(Int(p.frame.width))x\(Int(p.frame.height)) at \(Int(p.frame.minX)),\(Int(p.frame.minY))"
    }

    private func hide() {
        follow?.invalidate()
        follow = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// A backdrop behind the prompt: heading above it, a gap it fills, explanation below.
    /// Visible only while a prompt is on screen to frame.
    private func layout() {
        guard let panel else { return }
        if Chime.rings(forPromptBy: prompt?.owner, after: framedOwner) { Chime.play() }
        framedOwner = prompt?.owner
        guard let prompt else {
            panel.orderOut(nil)
            return
        }
        let clock = DateFormatter()
        clock.dateFormat = "h:mm a"
        let until = clock.string(from: Date().addingTimeInterval(expiresIn))
        let frame = prompt.frame
        let width = max(AuthContextView.width, frame.width + 40)
        let view = AuthContextView(reason: reason, until: until, width: width, gap: frame.height, promptOwner: prompt.owner)
        panel.contentView = view
        let size = view.fittingSize
        // The gap in the view lines up exactly with the prompt's window.
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY - view.heightBelowGap)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    struct PromptWindow: Equatable {
        let owner: String
        let layer: Int
        let frame: NSRect
    }

    /// The windows worth framing, by owning process, as observed: 1Password's CLI
    /// authorization prompt, and macOS's privacy consent dialog ("would like to access data
    /// from other apps") that can precede it. Nothing else is ever wrapped.
    static let promptOwners: Set<String> = ["1Password", "UserNotificationCenter"]

    /// The prompt on screen right now, in Cocoa coordinates. Window bounds and owners need no
    /// screen-recording permission.
    static func promptWindow() -> PromptWindow? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let candidates = windows.compactMap { w -> PromptWindow? in
            guard let owner = w[kCGWindowOwnerName as String] as? String, promptOwners.contains(owner),
                  // Above ordinary windows: 1Password's main window (level 0) doesn't count.
                  let layer = w[kCGWindowLayer as String] as? Int, layer > 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  width > 150, width < 900, height > 100, height < 800 else { return nil }
            return PromptWindow(owner: owner, layer: layer,
                                frame: NSRect(x: x, y: primaryHeight - y - height, width: width, height: height))
        }
        return candidates.max { $0.layer < $1.layer }
    }
}

/// Colors for the setup backdrop: authorizing opProxy itself isn't a risky decision, so it
/// deliberately doesn't wear the yellow/black of approval dialogs. Teal is the one in use; the
/// others remain for `render-dialog` comparisons.
struct SetupTheme {
    let name: String
    let background: NSColor
    let stripeLight: NSColor
    let stripeDark: NSColor
    let accent: NSColor
    let text: NSColor
    let secondary: NSColor
    let border: NSColor

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    static let onePasswordBlue = SetupTheme(name: "1Password blue", background: rgb(0x0E1A2E), stripeLight: rgb(0x1A8CFF),
                                            stripeDark: rgb(0x0A2A57), accent: rgb(0x5AAEFF), text: rgb(0xEEF4FB),
                                            secondary: rgb(0xA3B4CC), border: rgb(0x1A8CFF, 0.4))
    static let teal = SetupTheme(name: "Calm teal", background: rgb(0x0F1E1F), stripeLight: rgb(0x2BB5A8),
                                 stripeDark: rgb(0x123B3A), accent: rgb(0x4FD1C2), text: rgb(0xEAF6F4),
                                 secondary: rgb(0x9DB9B5), border: rgb(0x2BB5A8, 0.4))
    static let graphite = SetupTheme(name: "Graphite", background: rgb(0x1C1C1E), stripeLight: rgb(0x8E8E93),
                                     stripeDark: rgb(0x3A3A3C), accent: rgb(0xD1D1D6), text: rgb(0xF2F2F7),
                                     secondary: rgb(0xA1A1A6), border: rgb(0x8E8E93, 0.45))
    static let violet = SetupTheme(name: "Violet", background: rgb(0x17132A), stripeLight: rgb(0xA78BFA),
                                   stripeDark: rgb(0x3B2F6E), accent: rgb(0xC4B5FD), text: rgb(0xF3F0FF),
                                   secondary: rgb(0xB3AACF), border: rgb(0xA78BFA, 0.4))
    static let options = [onePasswordBlue, teal, graphite, violet]
}

final class AuthContextView: NSView {
    private let theme: SetupTheme
    static let width: CGFloat = 440
    /// Height of the part below the gap, for lining the gap up with 1Password's prompt.
    private(set) var heightBelowGap: CGFloat = 0
    private let below = NSStackView()

    init(reason: AuthReason, until: String, width: CGFloat = AuthContextView.width, gap: CGFloat = 0,
         promptOwner: String? = nil, theme: SetupTheme = .teal, placeholder: Bool = false) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        let stripe = HazardStripe()
        stripe.light = theme.stripeLight
        stripe.dark = theme.stripeDark
        stripe.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stripe)

        func text(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor? = nil) -> NSTextField {
            let f = NSTextField(wrappingLabelWithString: s)
            f.font = .systemFont(ofSize: size, weight: weight)
            f.textColor = color ?? theme.text
            f.preferredMaxLayoutWidth = width - 40
            return f
        }
        let kicker = text("opProxy → 1Password", size: 12, weight: .heavy, color: theme.accent)
        let heading: String
        heading = promptOwner == "UserNotificationCenter"
            ? "Allow this macOS prompt so opProxy can reach 1Password"
            : "Approve this 1Password prompt to authorize opProxy"
        let title = text(heading, size: 15, weight: .bold)
        let above = NSStackView(views: [kicker, title])
        above.orientation = .vertical
        above.alignment = .leading
        above.spacing = 3
        above.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)

        let body = text("opProxy needs its own 1Password CLI session so the requests you approve in its dialogs "
                        + "can run without further 1Password prompts.", size: 12, color: theme.secondary)
        let why = text("Why now: " + reason.rawValue, size: 12, weight: .semibold)
        let expiry = text("Lasts until about \(until) (1Password's 12-hour limit).", size: 12, color: theme.secondary)
        [body, why, expiry].forEach(below.addArrangedSubview)
        below.orientation = .vertical
        below.alignment = .leading
        below.spacing = 6
        below.setCustomSpacing(10, after: body)
        below.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 16, right: 20)

        let spacer = NSView()
        if placeholder {
            // Previews only: where 1Password's prompt would sit.
            let mock = NSTextField(labelWithString: "1Password's prompt here")
            mock.textColor = .tertiaryLabelColor
            mock.alignment = .center
            mock.wantsLayer = true
            mock.layer?.backgroundColor = NSColor(white: 0.23, alpha: 1).cgColor
            mock.layer?.cornerRadius = 12
            mock.translatesAutoresizingMaskIntoConstraints = false
            spacer.addSubview(mock)
            NSLayoutConstraint.activate([
                mock.centerXAnchor.constraint(equalTo: spacer.centerXAnchor),
                mock.centerYAnchor.constraint(equalTo: spacer.centerYAnchor),
                mock.widthAnchor.constraint(equalToConstant: 360),
                mock.heightAnchor.constraint(equalTo: spacer.heightAnchor, constant: -20),
            ])
        }
        let column = NSStackView(views: [above, spacer, below])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            stripe.leadingAnchor.constraint(equalTo: leadingAnchor),
            stripe.trailingAnchor.constraint(equalTo: trailingAnchor),
            stripe.topAnchor.constraint(equalTo: topAnchor),
            stripe.heightAnchor.constraint(equalToConstant: 10),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: stripe.bottomAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.widthAnchor.constraint(equalToConstant: width),
            spacer.heightAnchor.constraint(equalToConstant: gap),
            spacer.widthAnchor.constraint(equalToConstant: width),
        ])
        layoutSubtreeIfNeeded()
        heightBelowGap = below.fittingSize.height
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = theme.background.cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = theme.border.cgColor
        layer?.masksToBounds = true
    }
}
