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
}

struct Agent {
    let paneID: String
    let workspaceID: String
    let status: AgentStatus
    let title: String
    let focused: Bool
}

struct Model {
    var connected = false
    var agents: [Agent] = []
    var workspaceLabels: [String: String] = [:]

    init() {}

    init(snapshot: [String: Any]) {
        connected = true
        agents = (snapshot["agents"] as? [[String: Any]] ?? []).compactMap { a in
            guard let pane = a["pane_id"] as? String else { return nil }
            return Agent(
                paneID: pane,
                workspaceID: a["workspace_id"] as? String ?? "",
                status: AgentStatus(rawValue: a["agent_status"] as? String ?? "") ?? .unknown,
                title: (a["terminal_title_stripped"] as? String) ?? (a["agent"] as? String) ?? pane,
                focused: a["focused"] as? Bool ?? false
            )
        }
        for ws in snapshot["workspaces"] as? [[String: Any]] ?? [] {
            if let id = ws["workspace_id"] as? String { workspaceLabels[id] = ws["label"] as? String ?? id }
        }
    }

    /// A pane you are already looking at (herdr-focused and the terminal is frontmost) needs no alert.
    func needsAttention(_ agent: Agent, terminalFrontmost: Bool) -> Bool {
        (agent.status == .blocked || agent.status == .done) && !(agent.focused && terminalFrontmost)
    }
}
