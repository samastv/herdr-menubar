import AppKit

final class StatusController: NSObject, NSMenuDelegate {
    private static let terminalBundleID = "com.googlecode.iterm2"

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client: HerdrClient
    private var model = Model()
    private var pulseTimer: Timer?

    init(client: HerdrClient) {
        self.client = client
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        client.onSnapshot = { [weak self] snap in
            self?.model = snap.map(Model.init(snapshot:)) ?? Model()
            self?.render()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.render() }
        render()
    }

    private var terminalFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.terminalBundleID
    }

    private var attention: [Agent] {
        model.agents.filter { model.needsAttention($0, terminalFrontmost: terminalFrontmost) }
    }

    // MARK: - rendering

    private func render() {
        let alerts = attention
        if alerts.isEmpty { stopPulse() } else { startPulse() }
        draw(alpha: 1)
    }

    private func draw(alpha: CGFloat) {
        let alerts = attention
        let working = model.agents.filter { $0.status == .working }.count
        let text: String
        let color: NSColor

        if !model.connected {
            text = "◌"
            color = .tertiaryLabelColor
        } else if !alerts.isEmpty {
            text = "● \(alerts.count)"
            color = (alerts.contains { $0.status == .blocked } ? NSColor.systemRed : NSColor.systemOrange).withAlphaComponent(alpha)
        } else {
            text = working > 0 ? "● \(working)" : "●"
            color = .secondaryLabelColor
        }
        item.button?.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: color, .font: NSFont.menuBarFont(ofSize: 0)]
        )
    }

    private func startPulse() {
        guard pulseTimer == nil else { return }
        let start = Date()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            // ~1.2s period, alpha swinging 0.25...1.0
            let phase = Date().timeIntervalSince(start) * 2 * .pi / 1.2
            self?.draw(alpha: 0.625 + 0.375 * CGFloat(cos(phase)))
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    // MARK: - menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !model.connected {
            menu.addItem(withTitle: "herdr not running", action: nil, keyEquivalent: "")
        }
        let byWorkspace = Dictionary(grouping: model.agents, by: \.workspaceID)
        for ws in byWorkspace.keys.sorted() {
            let header = NSMenuItem(title: model.workspaceLabels[ws] ?? ws, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for agent in byWorkspace[ws] ?? [] {
                let row = NSMenuItem(title: "\(agent.status.glyph)  \(agent.title)", action: #selector(focus(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = agent.paneID
                row.indentationLevel = 1
                menu.addItem(row)
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func focus(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? String else { return }
        client.send("agent.focus", params: ["target": pane])
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.terminalBundleID).first?.activate()
    }
}
