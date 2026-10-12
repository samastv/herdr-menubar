import AppKit

final class StatusController: NSObject, NSMenuDelegate {
    private static let terminalBundleID = "com.googlecode.iterm2"
    private static let pulseKey = "pulse"
    private static let settleDelay: TimeInterval = 0.8

    private enum Tint { case off, calm, done, blocked }

    /// Everything that is visible in the menu bar. Setting the button title is a synchronous
    /// round-trip to the window server, so it is only done when this value changes.
    private struct Display: Equatable {
        var text: String
        var tint: Tint
        var pulsing: Bool
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client: HerdrClient
    private let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: StatusController.terminalBundleID)
    private var model = Model()
    private var terminalFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == StatusController.terminalBundleID
    private var shown: Display?
    private var lastWorking: [String: Date] = [:]
    private var settleTimer: Timer?

    init(client: HerdrClient) {
        self.client = client
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.wantsLayer = true

        client.onSnapshot = { [weak self] snap in
            self?.model = Model(snapshot: snap)
            self?.render()
        }
        client.onDisconnect = { [weak self] in
            self?.model = Model()
            self?.render()
        }
        client.onPaneUpdated = { [weak self] pane in
            self?.model.apply(pane: pane)
            self?.render()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.terminalFrontmost = app?.bundleIdentifier == Self.terminalBundleID
            self?.render()
        }
        commit(display(of: model.agents))
    }

    // MARK: - rendering

    private func display(of agents: [Agent]) -> Display {
        if !model.connected { return Display(text: "◌", tint: .off, pulsing: false) }
        let alerts = agents.filter { model.needsAttention($0, terminalFrontmost: terminalFrontmost) }
        if !alerts.isEmpty {
            let blocked = alerts.contains { $0.status == .blocked }
            return Display(text: "● \(alerts.count)", tint: blocked ? .blocked : .done, pulsing: true)
        }
        let working = agents.filter { $0.status == .working }.count
        return Display(text: working > 0 ? "● \(working)" : "●", tint: .calm, pulsing: false)
    }

    /// herdr's status detector briefly misreads a working agent as `blocked` or `idle` for one
    /// frame (~100ms) every few seconds. Each agent therefore counts as working until it has
    /// stopped reporting working for `settleDelay`, so a blip never reaches the menu bar. This is
    /// per agent, not on the combined display: with several agents, one agent's blips would
    /// otherwise keep postponing another's real alert.
    private func render() {
        let now = Date()
        for agent in model.agents where agent.status == .working { lastWorking[agent.paneID] = now }
        var agents = model.agents
        var releaseAt: Date?
        for i in agents.indices where agents[i].status != .working {
            guard let last = lastWorking[agents[i].paneID], last.addingTimeInterval(Self.settleDelay) > now else { continue }
            agents[i].status = .working
            let expiry = last.addingTimeInterval(Self.settleDelay)
            releaseAt = min(releaseAt ?? expiry, expiry)
        }
        lastWorking = lastWorking.filter { $0.value.addingTimeInterval(Self.settleDelay) > now }

        settleTimer?.invalidate()
        settleTimer = nil
        if let releaseAt {
            let timer = Timer(fire: releaseAt, interval: 0, repeats: false) { [weak self] _ in self?.render() }
            RunLoop.main.add(timer, forMode: .common)
            settleTimer = timer
        }

        let next = display(of: agents)
        if next != shown { commit(next) }
    }

    private func commit(_ next: Display) {
        let pulseChanged = next.pulsing != shown?.pulsing
        shown = next
        item.button?.attributedTitle = NSAttributedString(
            string: next.text,
            attributes: [.foregroundColor: Self.color(next.tint), .font: NSFont.menuBarFont(ofSize: 0)]
        )
        if pulseChanged { setPulse(next.pulsing) }
    }

    private static func color(_ tint: Tint) -> NSColor {
        switch tint {
        case .off: return .tertiaryLabelColor
        case .calm: return .secondaryLabelColor
        case .done: return .systemOrange
        case .blocked: return .systemRed
        }
    }

    /// Core Animation runs the pulse in the render server, so it costs the app no per-frame work.
    private func setPulse(_ on: Bool) {
        guard let layer = item.button?.layer else { return }
        layer.removeAnimation(forKey: Self.pulseKey)
        if on {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.25
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: Self.pulseKey)
        }
    }

    // MARK: - menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !model.connected {
            menu.addItem(withTitle: "herdr not running", action: nil, keyEquivalent: "")
        }
        let active = model.activeAgents
        if model.connected && active.isEmpty {
            menu.addItem(withTitle: "No active agents", action: nil, keyEquivalent: "")
        }
        let byWorkspace = Dictionary(grouping: active, by: \.workspaceID)
        for ws in byWorkspace.keys.sorted() {
            menu.addItem(withTitle: model.workspaceLabels[ws] ?? ws, action: nil, keyEquivalent: "")
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
        // Synchronous NSRunningApplication.activate() blocks the main thread on an XPC round-trip.
        if let url = terminalURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
    }
}
