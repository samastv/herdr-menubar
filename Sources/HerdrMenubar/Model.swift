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

    /// Entries of a snapshot's `agents[]` are agents by definition. A `pane_updated` event
    /// also covers plain shells (`agent` is null), so callers of this on events must check that.
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
    private(set) var agents: [Agent] = []
    private(set) var workspaceLabels: [String: String] = [:]

    init() {}

    init(snapshot: [String: Any]) {
        connected = true
        agents = (snapshot["agents"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(Agent.init) }
        for case let ws as [String: Any] in snapshot["workspaces"] as? [Any] ?? [] {
            if let id = ws["workspace_id"] as? String { workspaceLabels[id] = ws["label"] as? String ?? id }
        }
    }

    var activeAgents: [Agent] { agents.filter { $0.status.isActive } }

    /// Applies one `pane_updated` event in place. herdr has a single focused pane, so focusing
    /// one clears the flag on the rest. That happens before the agent check so that focusing a
    /// plain shell also un-focuses the agent you just left.
    mutating func apply(pane dict: [String: Any]) {
        guard let paneID = dict["pane_id"] as? String else { return }
        if dict["focused"] as? Bool == true {
            for i in agents.indices where agents[i].paneID != paneID { agents[i].focused = false }
        }
        let index = agents.firstIndex { $0.paneID == paneID }
        guard dict["agent"] is String, let agent = Agent(dict) else {
            if let index { agents.remove(at: index) }
            return
        }
        if let index { agents[index] = agent } else { agents.append(agent) }
    }

    /// A pane you are already looking at (herdr-focused and the terminal is frontmost) needs no alert.
    func needsAttention(_ agent: Agent, terminalFrontmost: Bool) -> Bool {
        (agent.status == .blocked || agent.status == .done) && !(agent.focused && terminalFrontmost)
    }
}
