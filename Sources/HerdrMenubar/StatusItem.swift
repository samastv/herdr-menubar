import AppKit

final class StatusController: NSObject, NSMenuDelegate {
    private static let terminalBundleID = "com.googlecode.iterm2"
    private static let pulseKey = "pulse"

    private enum Tint { case off, idle, working, done, blocked }

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

    init(client: HerdrClient) {
        self.client = client
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.wantsLayer = true

        client.onSnapshot = { [weak self] snap in
            self?.model = snap.map(Model.init(snapshot:)) ?? Model()
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
        render()
    }

    // MARK: - rendering

    private func display() -> Display {
        if !model.connected { return Display(text: "◌", tint: .off, pulsing: false) }
        let alerts = model.orderedAgents.filter { model.needsAttention($0, terminalFrontmost: terminalFrontmost) }
        if !alerts.isEmpty {
            let blocked = alerts.contains { $0.status == .blocked }
            return Display(text: "● \(alerts.count)", tint: blocked ? .blocked : .done, pulsing: true)
        }
        let working = model.agents.values.filter { $0.status == .working }.count
        return Display(text: working > 0 ? "● \(working)" : "●", tint: working > 0 ? .working : .idle, pulsing: false)
    }

    private func render() {
        let next = display()
        guard next != shown else { return }
        let previous = shown
        shown = next

        item.button?.attributedTitle = NSAttributedString(
            string: next.text,
            attributes: [.foregroundColor: Self.color(next.tint), .font: NSFont.menuBarFont(ofSize: 0)]
        )
        if previous?.pulsing != next.pulsing { setPulse(next.pulsing) }
    }

    private static func color(_ tint: Tint) -> NSColor {
        switch tint {
        case .off: return .tertiaryLabelColor
        case .idle, .working: return .secondaryLabelColor
        case .done: return .systemOrange
        case .blocked: return .systemRed
        }
    }

    /// Core Animation runs the pulse in the render server, so it costs the app no per-frame work.
    private func setPulse(_ on: Bool) {
        guard let layer = item.button?.layer else { return }
        if on {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.25
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: Self.pulseKey)
        } else {
            layer.removeAnimation(forKey: Self.pulseKey)
        }
    }

    // MARK: - menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !model.connected {
            menu.addItem(withTitle: "herdr not running", action: nil, keyEquivalent: "")
        }
        let byWorkspace = Dictionary(grouping: model.orderedAgents, by: \.workspaceID)
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
        // Synchronous NSRunningApplication.activate() blocks the main thread on an XPC round-trip.
        if let url = terminalURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
    }
}
