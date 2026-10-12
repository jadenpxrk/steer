import Foundation

enum TerminalLink {
    /// Normalises a link tapped in terminal output. Bare domains such as `example.com/path` open over https.
    static func url(from link: String) -> URL? {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if text.contains("://") || text.hasPrefix("mailto:") {
            return URL(string: text).flatMap { $0.scheme == nil ? nil : $0 }
        }
        guard let host = text.split(separator: "/").first, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else {
            return nil
        }
        return URL(string: "https://" + text)
    }
}

/// `steer://open?host=<name or hostname>` optionally followed by one target:
/// `&tmux=<session>`, `&zellij=<session>`, or `&pane=<herdr pane>[&herdr-session=<name>]`.
struct SteerDeepLink: Equatable {
    let host: String
    let target: MuxRow?

    init?(url: URL) {
        guard url.scheme == "steer", url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let host = value("host") else { return nil }
        self.host = host
        if let session = value("tmux") {
            target = .tmux(TmuxSession(name: session, windowCount: nil, isAttached: false))
        } else if let session = value("zellij") {
            target = .zellij(ZellijSession(name: session))
        } else if let pane = value("pane") {
            target = .herdrAgent(HerdrAgent(
                paneID: pane, agent: "", status: nil, cwd: nil, foregroundCWD: nil, terminalTitle: nil,
                focused: false, workspaceID: nil, tabID: nil, terminalID: nil, sessionName: value("herdr-session")
            ))
        } else {
            target = nil
        }
    }

    func matches(_ candidate: Host) -> Bool {
        [candidate.displayName, candidate.name, candidate.hostname].contains {
            $0.caseInsensitiveCompare(host) == .orderedSame
        }
    }
}
