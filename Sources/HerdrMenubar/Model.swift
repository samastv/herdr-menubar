import Foundation

enum AgentStatus: String {
    case blocked, done, working, idle, unknown

    var glyph: String {
        switch self {
        case .blocked: return "⏸"
        case .done: return "✓"
        case .working: return "◐"
        case .idle, .unknown: return "·"
        }
    }

    var isActive: Bool { self == .working || self == .blocked || self == .done }
}

struct Agent {
    let paneID: String
    let workspaceID: String
    let status: AgentStatus
    let title: String
    var focused: Bool

    /// Both `session.snapshot` agents and `pane_updated` events use this shape.
    /// Panes without an agent status (plain shells) are not agents.
    init?(_ dict: [String: Any]) {
        guard let pane = dict["pane_id"] as? String, let status = dict["agent_status"] as? String else { return nil }
        paneID = pane
        workspaceID = dict["workspace_id"] as? String ?? ""
        self.status = AgentStatus(rawValue: status) ?? .unknown
        title = (dict["terminal_title_stripped"] as? String) ?? (dict["agent"] as? String) ?? pane
        focused = dict["focused"] as? Bool ?? false
    }
}

struct Model {
    var connected = false
    private(set) var agents: [String: Agent] = [:]
    private var order: [String] = []
    private(set) var workspaceLabels: [String: String] = [:]

    init() {}

    init(snapshot: [String: Any]) {
        connected = true
        for case let dict as [String: Any] in snapshot["agents"] as? [Any] ?? [] {
            if let agent = Agent(dict) {
                agents[agent.paneID] = agent
                order.append(agent.paneID)
            }
        }
        for case let ws as [String: Any] in snapshot["workspaces"] as? [Any] ?? [] {
            if let id = ws["workspace_id"] as? String { workspaceLabels[id] = ws["label"] as? String ?? id }
        }
    }

    var orderedAgents: [Agent] { order.compactMap { agents[$0] } }
    var activeAgents: [Agent] { orderedAgents.filter { $0.status.isActive } }

    /// Applies one `pane_updated` event in place. herdr has a single focused pane,
    /// so focusing one clears the flag on the rest rather than waiting for their own events.
    mutating func apply(pane dict: [String: Any]) {
        guard let paneID = dict["pane_id"] as? String else { return }
        guard let agent = Agent(dict) else {
            agents[paneID] = nil
            order.removeAll { $0 == paneID }
            return
        }
        if agents[paneID] == nil { order.append(paneID) }
        agents[paneID] = agent
        if agent.focused {
            for id in agents.keys where id != paneID { agents[id]?.focused = false }
        }
    }

    /// A pane you are already looking at (herdr-focused and the terminal is frontmost) needs no alert.
    func needsAttention(_ agent: Agent, terminalFrontmost: Bool) -> Bool {
        (agent.status == .blocked || agent.status == .done) && !(agent.focused && terminalFrontmost)
    }
}
