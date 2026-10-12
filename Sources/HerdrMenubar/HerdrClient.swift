import Foundation

/// Talks to herdr's newline-delimited JSON API over its unix socket.
///
/// `pane_updated` events carry the whole pane, so they are applied directly. herdr emits
/// them continuously (agent title spinners), so re-fetching a snapshot for each would
/// dominate the app's work. Any other event is structural and triggers a snapshot instead.
final class HerdrClient {
    static let socketPath = NSString(string: "~/.config/herdr/herdr.sock").expandingTildeInPath

    /// Called on the main queue. `nil` means herdr is unreachable.
    var onSnapshot: (([String: Any]?) -> Void)?
    /// Called on the main queue with the `pane` object of a `pane_updated` event.
    var onPaneUpdated: (([String: Any]) -> Void)?

    // Separate queues so a click's command never waits behind a snapshot fetch.
    private let work = DispatchQueue(label: "herdr.snapshot")
    private let commands = DispatchQueue(label: "herdr.commands")
    private var refreshPending = false

    private static let subscriptions: [[String: String]] = [
        "pane.updated", "pane.created", "pane.closed", "pane.agent_detected",
        "tab.renamed", "tab.closed", "workspace.created", "workspace.renamed", "workspace.closed",
    ].map { ["type": $0] }

    func start() {
        Thread.detachNewThread { [weak self] in self?.subscribeLoop() }
    }

    /// Fire-and-forget request, e.g. `agent.focus`.
    func send(_ method: String, params: [String: Any]) {
        commands.async { _ = Self.request(method, params) }
    }

    // MARK: - subscription

    private func subscribeLoop() {
        var backoff: UInt32 = 1
        while true {
            if let fd = Self.connect(), Self.write(fd, Self.encode("sub", "events.subscribe", ["subscriptions": Self.subscriptions])) {
                backoff = 1
                refresh()
                var buffer = Data()
                while let chunk = Self.read(fd) {
                    buffer.append(chunk)
                    var needsSnapshot = false
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let line = buffer.subdata(in: buffer.startIndex..<nl)
                        buffer.removeSubrange(buffer.startIndex...nl)
                        guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                              let event = msg["event"] as? String else { continue }
                        if event == "pane_updated", let pane = (msg["data"] as? [String: Any])?["pane"] as? [String: Any] {
                            DispatchQueue.main.async { self.onPaneUpdated?(pane) }
                        } else {
                            needsSnapshot = true
                        }
                    }
                    if needsSnapshot { refresh() }
                }
                close(fd)
            }
            DispatchQueue.main.async { self.onSnapshot?(nil) }
            sleep(backoff)
            backoff = min(backoff * 2, 10)
        }
    }

    /// Coalesces bursts of events into one snapshot fetch.
    private func refresh() {
        work.async {
            if self.refreshPending { return }
            self.refreshPending = true
            self.work.asyncAfter(deadline: .now() + 0.15) {
                self.refreshPending = false
                let snap = (Self.request("session.snapshot", [:])?["result"] as? [String: Any])?["snapshot"] as? [String: Any]
                DispatchQueue.main.async { self.onSnapshot?(snap) }
            }
        }
    }

    // MARK: - socket plumbing

    private static func encode(_ id: String, _ method: String, _ params: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])) ?? Data()
        data.append(0x0A)
        return data
    }

    private static func request(_ method: String, _ params: [String: Any]) -> [String: Any]? {
        guard let fd = connect(), write(fd, encode("req", method, params)) else { return nil }
        defer { close(fd) }
        var buffer = Data()
        while !buffer.contains(0x0A), let chunk = read(fd) { buffer.append(chunk) }
        guard let nl = buffer.firstIndex(of: 0x0A) else { return nil }
        return try? JSONSerialization.jsonObject(with: buffer.subdata(in: buffer.startIndex..<nl)) as? [String: Any]
    }

    private static func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            path.withUnsafeBytes { dst.copyMemory(from: $0) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { close(fd); return nil }
        return fd
    }

    private static func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) == data.count }
    }

    private static func read(_ fd: Int32) -> Data? {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.read(fd, &buf, buf.count)
        return n > 0 ? Data(buf[0..<n]) : nil
    }
}
