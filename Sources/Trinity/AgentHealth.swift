import Foundation

final class AgentHealthService {
    private let shell: ShellRunning
    private let home: URL

    init(shell: ShellRunning = Shell(), home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.shell = shell
        self.home = home
    }

    func checkAll() async -> [AgentStatus] {
        var statuses: [AgentStatus] = []
        for agent in Agent.allCases {
            statuses.append(await check(agent))
        }
        return statuses
    }

    func check(_ agent: Agent) async -> AgentStatus {
        guard shell.which(agent.rawValue) != nil else {
            return AgentStatus(agent: agent, installed: false, status: "missing", detail: "not found on PATH")
        }
        let versionArgs = [agent.rawValue, "--version"]
        do {
            let result = try await shell.run(versionArgs, cwd: nil, timeout: 8)
            let firstLine = (result.stdout.isEmpty ? result.stderr : result.stdout)
                .split(separator: "\n")
                .first
                .map(String.init) ?? ""
            var status = AgentStatus(
                agent: agent,
                installed: true,
                version: firstLine,
                status: result.ok ? "ready" : "error",
                detail: result.ok ? "" : String(result.stderr.prefix(200))
            )
            attachAccount(to: &status)
            return status
        } catch {
            return AgentStatus(agent: agent, installed: true, status: "error", detail: error.localizedDescription)
        }
    }

    func switchAccount(_ agent: Agent, action: String = "login") async throws -> String {
        let command: String
        switch (agent, action) {
        case (.claude, "login"):
            command = "claude auth login"
        case (.claude, "logout"):
            command = "claude auth logout"
        case (.codex, "login"):
            command = "codex login"
        case (.codex, "logout"):
            command = "codex logout"
        default:
            throw NSError(domain: "Trinity.AgentHealth", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(agent.rawValue) has no supported \(action) flow"
            ])
        }

        let script = """
        tell application "Terminal" to do script "\(command)"
        tell application "Terminal" to activate
        """
        let result = try await shell.run(["osascript", "-e", script], cwd: nil, timeout: 15)
        if !result.ok {
            throw ShellError.nonZero(result)
        }
        return command
    }

    private func attachAccount(to status: inout AgentStatus) {
        switch status.agent {
        case .claude:
            let info = claudeAccount()
            status.account = info.account
            status.plan = info.plan
            status.quotaHint = info.quotaHint
            status.quotaRemaining = info.quotaHint
            status.canSwitch = true
        case .codex:
            let info = codexAccount()
            status.account = info.account
            status.plan = info.plan
            status.quotaHint = info.quotaHint
            status.quotaRemaining = info.quotaRemaining
            status.canSwitch = true
        case .agy:
            break
        }
    }

    private func claudeAccount() -> (account: String, plan: String, quotaHint: String) {
        let path = home.appendingPathComponent(".claude.json")
        guard let object = readJSONObject(path) else { return ("", "", "") }
        let oauth = object["oauthAccount"] as? [String: Any] ?? [:]
        var hints: [String] = []
        if let features = object["cachedGrowthBookFeatures"] as? [String: Any],
           let lattice = features["tengu_saffron_lattice"] as? [String: Any],
           let reset = lattice["planLimitsEndDate"] as? String {
            hints.append("plan resets \(reset)")
        }
        if let reason = object["cachedExtraUsageDisabledReason"] as? String {
            hints.append(reason.replacingOccurrences(of: "_", with: " "))
        } else if oauth["hasExtraUsageEnabled"] as? Bool == true {
            hints.append("extra usage on")
        }
        return (
            oauth["emailAddress"] as? String ?? "",
            oauth["billingType"] as? String ?? "",
            hints.joined(separator: "; ")
        )
    }

    private func codexAccount() -> (account: String, plan: String, quotaHint: String, quotaRemaining: String) {
        let codexHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path)
        let auth = readJSONObject(codexHome.appendingPathComponent("auth.json")) ?? [:]
        let tokens = auth["tokens"] as? [String: Any] ?? [:]
        let user = (auth["user"] as? [String: Any]) ?? (auth["account"] as? [String: Any]) ?? [:]
        let account = user["email"] as? String
            ?? auth["email"] as? String
            ?? tokens["account_id"] as? String
            ?? auth["account_id"] as? String
            ?? ""
        let quota = latestCodexQuota(in: codexHome.appendingPathComponent("sessions"))
        return (account, quota.plan, quota.hint, quota.remaining)
    }

    private func latestCodexQuota(in sessions: URL) -> (plan: String, hint: String, remaining: String) {
        guard let enumerator = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return ("", "", "")
        }
        let files = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
            .sorted {
                let lhs = ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                let rhs = ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                return lhs > rhs
            }
            .prefix(20)

        for file in files {
            guard let text = try? String(contentsOf: file) else { continue }
            for line in text.split(separator: "\n").reversed() {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let limits = (object["rate_limits"] as? [String: Any]) ?? (object["rate_limit"] as? [String: Any])
                else { continue }
                let parsed = quota(from: limits)
                if !parsed.remaining.isEmpty { return parsed }
            }
        }
        return ("", "", "")
    }

    private func quota(from limits: [String: Any]) -> (plan: String, hint: String, remaining: String) {
        var labels: [String] = []
        var resets: [String] = []
        for key in ["primary_window", "secondary_window"] {
            guard let window = limits[key] as? [String: Any],
                  let used = window["used_percent"] as? Double
            else { continue }
            let seconds = (window["limit_window_seconds"] as? Double) ?? 0
            let label = seconds >= 86_400 ? "weekly" : "5h"
            let remaining = max(0, min(100, Int((100 - used).rounded())))
            labels.append("\(label) \(remaining)% left")
            if let reset = window["reset_at"] {
                resets.append("\(label) reset \(reset)")
            }
        }
        return ("", resets.joined(separator: "; "), labels.joined(separator: "; "))
    }

    private func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }
}
