import Foundation
import CryptoKit

final class AgentHealthService: @unchecked Sendable {
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

    func hasRunnableCLI(_ agent: Agent) -> Bool {
        shell.which(agent.rawValue) != nil
    }

    func check(_ agent: Agent) async -> AgentStatus {
        let cliPath = shell.which(agent.rawValue)
        let appURL = agent == .agy ? antigravityAppURL() : nil
        let installed = cliPath != nil || appURL != nil
        var status = AgentStatus(
            agent: agent,
            installed: installed,
            status: installed ? "ready" : "missing",
            detail: installed ? "" : "not found on PATH"
        )

        if let cliPath {
            if let result = try? await shell.run([agent.rawValue, "--version"], cwd: nil, timeout: 8) {
                status.version = (result.stdout.isEmpty ? result.stderr : result.stdout)
                    .split(separator: "\n").first.map(String.init) ?? ""
                status.status = result.ok ? "ready" : "error"
                status.detail = result.ok ? "" : String(result.stderr.prefix(200))
            } else {
                status.status = "error"
                status.detail = "version check failed"
            }
            attachAccount(to: &status)
            if agent == .claude {
                switch await claudeAuthStatus() {
                case .ok(let loggedIn, let account, let plan):
                    if !account.isEmpty { status.account = account }
                    if !plan.isEmpty { status.plan = status.plan.isEmpty ? plan : status.plan }
                    if !loggedIn {
                        status.status = "auth"
                        status.detail = "Claude CLI is installed but not signed in"
                        status.quotaRemaining = Self.appendNote(status.quotaRemaining, "sign in for live quota")
                    }
                case .unavailable:
                    status.detail = Self.appendNote(status.detail, "auth status unavailable")
                }
            }
            if agent == .agy {
                status.detail = status.detail.isEmpty ? "CLI: \(cliPath)" : status.detail
            }
        } else if agent == .agy, let appURL {
            status.status = "app"
            status.version = antigravityAppVersion(appURL) ?? ""
            status.detail = "Antigravity app installed; CLI not found on PATH"
            status.canSwitch = true
        }

        // Codex account + quota come from ~/.codex on disk, readable WITHOUT the
        // CLI — surface them even when `codex` isn't on PATH (parity with agy).
        if agent == .codex, cliPath == nil {
            let info = codexAccount()
            if !info.account.isEmpty || !info.quotaRemaining.isEmpty {
                status.account = info.account
                status.plan = info.plan
                status.quotaHint = info.quotaHint
                status.quotaRemaining = info.quotaRemaining
                status.canSwitch = true
                if status.status == "missing" {
                    status.status = "app"
                    status.detail = "Signed in; codex CLI not on PATH"
                }
            }
        }

        // Live Claude quota (exact %) overrides config-file hints when available;
        // otherwise surface WHY realtime is missing instead of silently showing hints.
        if agent == .claude, installed, status.status != "auth" {
            switch await claudeLive() {
            case .ok(let remaining, let hint, let plan):
                if !remaining.isEmpty { status.quotaRemaining = remaining }
                if !hint.isEmpty { status.quotaHint = hint }
        if !plan.isEmpty { status.plan = Self.humanizeAccountPlan(plan) }
            case .noToken:
                status.status = status.status == "ready" ? "auth" : status.status
                status.quotaRemaining = Self.appendNote(status.quotaRemaining, "sign in for live quota")
            case .unavailable:
                status.quotaRemaining = Self.appendNote(status.quotaRemaining, "live quota unavailable")
            }
        }

        // Antigravity quota comes from the running IDE's language server, NOT the
        // `agy` CLI — surface it even when the CLI isn't installed.
        if agent == .agy {
            switch await antigravityLive() {
            case .ok(let remaining, let hint, let plan, let account):
                if !remaining.isEmpty { status.quotaRemaining = remaining }
                if !hint.isEmpty { status.quotaHint = hint }
                if !plan.isEmpty { status.plan = plan }
                if !account.isEmpty { status.account = account }
                if status.status == "missing" { status.status = "app" }
                status.installed = true
                status.canSwitch = true
            case .ideClosed:
                status.quotaRemaining = Self.appendNote(status.quotaRemaining, "open Antigravity IDE for quota")
            case .unavailable:
                status.quotaRemaining = Self.appendNote(status.quotaRemaining, "quota unavailable")
            }
        }

        return status
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
        case (.agy, "login"):
            guard let appURL = antigravityAppURL() else {
                throw NSError(domain: "Trinity.AgentHealth", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Antigravity app is not installed"
                ])
            }
            let result = try await shell.run(["open", appURL.path], cwd: nil, timeout: 15)
            if !result.ok {
                throw ShellError.nonZero(result)
            }
            return "open \(appURL.path)"
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

    private func antigravityAppURL() -> URL? {
        for path in [
            "/Applications/Antigravity.app",
            "/Applications/Antigravity IDE.app",
            home.appendingPathComponent("Applications/Antigravity.app").path,
            home.appendingPathComponent("Applications/Antigravity IDE.app").path,
        ] {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func antigravityAppVersion(_ appURL: URL) -> String? {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
            ?? plist["CFBundleVersion"] as? String
    }

    // MARK: - Antigravity live quota (IDE language server)

    enum AntigravityResult: Equatable {
        case ok(remaining: String, hint: String, plan: String, account: String)
        case ideClosed     // no language server running
        case unavailable   // server found but the call/parse failed
    }

    /// Accepts the language server's self-signed loopback certificate. The server
    /// only listens on 127.0.0.1, so trusting it for that host is safe here.
    private final class LoopbackTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               challenge.protectionSpace.host == "127.0.0.1",
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }
    private static let loopbackSession = URLSession(
        configuration: .ephemeral, delegate: LoopbackTrustDelegate(), delegateQueue: nil
    )

    /// Antigravity has no offline quota file. While the IDE is open each
    /// `language_server_*` process listens on loopback (HTTPS, self-signed) and
    /// takes `--csrf_token` + `--extension_server_port` on its command line; we
    /// POST GetUserStatus to read live quota, falling back to HTTP on the
    /// extension port if the HTTPS handshake fails.
    private func antigravityLive() async -> AntigravityResult {
        let servers = await antigravityServers()
        if servers.isEmpty { return .ideClosed }
        let userStatusBody = #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}"#
        for server in servers {
            var endpoints: [(scheme: String, port: UInt16)] = server.ports.map { ("https", $0) }
            if let ext = server.extPort { endpoints.append(("http", ext)) }
            for (scheme, port) in endpoints {
                guard let status = await antigravityRPC(scheme: scheme, port: port, csrf: server.csrf,
                                                        method: "GetUserStatus", body: userStatusBody),
                      let base = Self.parseAntigravityStatus(status) else { continue }
                var remaining = base.remaining
                var hint = base.hint
                // The IDE "Model Quota" panel: grouped weekly + 5-hour limits per
                // model family. Richer than per-model GetUserStatus, so prefer it.
                if let summary = await antigravityRPC(scheme: scheme, port: port, csrf: server.csrf,
                                                      method: "RetrieveUserQuotaSummary", body: "{}"),
                   let q = Self.parseAntigravityQuotaSummary(summary) {
                    remaining = q.remaining
                    hint = base.hint.isEmpty ? q.hint : "\(q.hint); \(base.hint)"
                }
                return .ok(remaining: remaining, hint: hint, plan: base.plan, account: base.account)
            }
        }
        return .unavailable
    }

    /// (csrf_token, listening ports, extension http port) per language server process.
    private func antigravityServers() async -> [(csrf: String, ports: [UInt16], extPort: UInt16?)] {
        guard let res = try? await shell.run(["ps", "-ax", "-o", "pid=,command="], cwd: nil, timeout: 6),
              res.ok else { return [] }
        var servers: [(String, [UInt16], UInt16?)] = []
        for line in res.stdout.split(separator: "\n") {
            let lower = line.lowercased()
            guard lower.contains("language_server"), lower.contains("antigravity") else { continue }
            let text = String(line)
            guard let pid = text.split(separator: " ").first.map(String.init),
                  let csrf = Self.argValue(text, flag: "--csrf_token") else { continue }
            let extPort = Self.argValue(text, flag: "--extension_server_port").flatMap { UInt16($0) }
            let ports = await listeningPorts(pid: pid)
            if !ports.isEmpty || extPort != nil { servers.append((csrf, ports, extPort)) }
        }
        return servers
    }

    /// Value following a `--flag <value>` token on a command line.
    static func argValue(_ line: String, flag: String) -> String? {
        let tokens = line.split(whereSeparator: { $0 == " " }).map(String.init)
        guard let idx = tokens.firstIndex(of: flag), idx + 1 < tokens.count else { return nil }
        return tokens[idx + 1]
    }

    private func listeningPorts(pid: String) async -> [UInt16] {
        guard let res = try? await shell.run(
            ["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pid], cwd: nil, timeout: 6
        ), res.ok else { return [] }
        var ports: [UInt16] = []
        for line in res.stdout.split(separator: "\n").dropFirst() {
            let cols = line.split(whereSeparator: { $0 == " " }).map(String.init)
            guard cols.count > 8, let port = cols[8].split(separator: ":").last.flatMap({ UInt16($0) })
            else { continue }
            if !ports.contains(port) { ports.append(port) }
        }
        return ports
    }

    /// Generic Connect-RPC POST to the Antigravity language server.
    private func antigravityRPC(scheme: String, port: UInt16, csrf: String, method: String, body: String) async -> [String: Any]? {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/\(method)")
        else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        // Connect RPC expects this exact CSRF header name.
        request.setValue(csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.httpBody = body.data(using: .utf8)
        guard let (data, response) = try? await Self.loopbackSession.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// Parse RetrieveUserQuotaSummary: response.groups[].buckets[] each carry a
    /// `window` (weekly/5h), `remainingFraction`, and `resetTime`. This is the
    /// exact data the IDE's "Model Quota" panel shows.
    static func parseAntigravityQuotaSummary(_ value: [String: Any]) -> (remaining: String, hint: String)? {
        let groups = ((value["response"] as? [String: Any])?["groups"] as? [[String: Any]])
            ?? (value["groups"] as? [[String: Any]]) ?? []
        var rows: [String] = []
        for group in groups {
            let name = shortGroupName(group["displayName"] as? String ?? "")
            // Show the shorter 5-hour window before the weekly window in each group.
            let buckets = ((group["buckets"] as? [[String: Any]]) ?? []).sorted { a, b in
                let order = ["5h": 0, "weekly": 1]
                let ra = order[(a["window"] as? String) ?? ""] ?? 2
                let rb = order[(b["window"] as? String) ?? ""] ?? 2
                return ra < rb
            }
            for bucket in buckets {
                guard let frac = bucket["remainingFraction"] as? Double else { continue }
                let window = (bucket["window"] as? String) ?? (bucket["displayName"] as? String) ?? ""
                let remaining = max(0, min(100, Int((frac * 100).rounded())))
                let label = "\(name) \(window)".trimmingCharacters(in: .whitespaces)
                if let reset = bucket["resetTime"] as? String, !reset.isEmpty {
                    rows.append("\(label) \(remaining)% left, \(resetText(reset))")
                } else {
                    rows.append("\(label) \(remaining)% left")
                }
            }
        }
        guard !rows.isEmpty else { return nil }
        let joined = rows.joined(separator: "; ")
        return (joined, joined)
    }

    /// "Gemini Models" -> "Gemini"; "Claude and GPT models" -> "Claude/GPT".
    static func shortGroupName(_ display: String) -> String {
        var s = display
        for suffix in [" Models", " models"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        return s.replacingOccurrences(of: " and ", with: "/")
    }

    /// Parse GetUserStatus. Per-model `quotaInfo.remainingFraction` (proto3 omits
    /// a default value, so a missing fraction = 0.0 = exhausted; must NOT skip).
    /// The summary 5h window = the most-used model; also surface plan prompt
    /// credits when present.
    static func parseAntigravityStatus(_ value: [String: Any]) -> (remaining: String, hint: String, plan: String, account: String)? {
        let userStatus = value["userStatus"] as? [String: Any] ?? [:]
        let configs = ((userStatus["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"]) as? [[String: Any]] ?? []

        var models: [(label: String, used: Int)] = []
        for config in configs {
            guard let quota = config["quotaInfo"] as? [String: Any] else { continue }
            let remainingFraction = quota["remainingFraction"] as? Double ?? 0.0
            let used = max(0, min(100, Int(((1.0 - remainingFraction) * 100).rounded())))
            let label = config["label"] as? String
                ?? ((config["modelOrAlias"] as? [String: Any])?["model"] as? String)
                ?? "model"
            models.append((label, used))
        }
        guard !models.isEmpty else { return nil }

        let worst = models.max(by: { $0.used < $1.used })!
        let planStatus = userStatus["planStatus"] as? [String: Any] ?? [:]
        let planInfo = planStatus["planInfo"] as? [String: Any] ?? [:]
        let plan = (planInfo["planName"] as? String).map(Self.humanizeAccountPlan) ?? ""
        let account = userStatus["email"] as? String ?? userStatus["name"] as? String ?? ""

        var hintParts = models.map { "\($0.label) \(100 - $0.used)% left" }

        // Antigravity quota is per-MODEL (each resets on its own clock), plus a
        // monthly prompt-credit pool. Show the binding (most-used) model as the
        // labeled meter, and lead with credits when the plan reports them.
        var rows: [String] = []
        if let available = planStatus["availablePromptCredits"] as? Double,
           let monthly = planInfo["monthlyPromptCredits"] as? Double, monthly > 0 {
            let pct = max(0, min(100, Int((available / monthly * 100).rounded())))
            rows.append("Credits \(pct)% left")
            hintParts.insert("credits \(Int(available))/\(Int(monthly))", at: 0)
        }
        rows.append("\(worst.label) \(100 - worst.used)% left")
        return (rows.joined(separator: "; "), hintParts.joined(separator: "; "), plan, account)
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
            Self.claudeFallbackPlan(from: oauth, root: object),
            hints.joined(separator: "; ")
        )
    }

    private static func claudeFallbackPlan(from oauth: [String: Any], root: [String: Any]) -> String {
        for key in ["subscriptionType", "subscription_type", "plan", "planType", "tier", "account_type"] {
            if let value = (oauth[key] as? String) ?? (root[key] as? String) {
                let plan = humanizeAccountPlan(value)
                if !plan.isEmpty { return plan }
            }
        }

        // Claude's cached `billingType` can be values like `stripe_subscription`.
        // That is a payment mechanism, not the user-facing account plan.
        return ""
    }

    // MARK: - Claude live usage (exact %)

    enum ClaudeAuthResult: Equatable {
        case ok(loggedIn: Bool, account: String, plan: String)
        case unavailable
    }

    private func claudeAuthStatus() async -> ClaudeAuthResult {
        guard let result = try? await shell.run(["claude", "auth", "status"], cwd: nil, timeout: 8),
              result.ok,
              let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        else { return .unavailable }
        let parsed = Self.parseClaudeAuthStatus(object)
        return .ok(loggedIn: parsed.loggedIn, account: parsed.account, plan: parsed.plan)
    }

    static func parseClaudeAuthStatus(_ value: [String: Any]) -> (loggedIn: Bool, account: String, method: String, plan: String) {
        let loggedIn = value["loggedIn"] as? Bool ?? false
        let account = value["email"] as? String
            ?? value["account"] as? String
            ?? ((value["user"] as? [String: Any])?["email"] as? String)
            ?? ""
        let method = value["authMethod"] as? String ?? ""
        let plan = (value["subscriptionType"] as? String)
            ?? (value["subscription_type"] as? String)
            ?? (value["plan"] as? String)
            ?? (value["planType"] as? String)
            ?? ""
        return (loggedIn, account, method, Self.humanizeAccountPlan(plan))
    }

    /// Claude's config dir: `CLAUDE_CONFIG_DIR` if set (used by profile setups),
    /// else `~/.claude`. The keychain credential is keyed by this dir's hash.
    private func claudeConfigDir() -> URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".claude")
    }

    enum ClaudeLiveResult: Equatable {
        case ok(remaining: String, hint: String, plan: String)
        case noToken      // not logged in via keychain — realtime needs `claude setup-token`
        case unavailable  // token present but the endpoint/network failed
    }

    /// Append a parenthetical reason to an existing quota string (or use it alone).
    static func appendNote(_ base: String, _ note: String) -> String {
        base.isEmpty ? note : "\(base) · \(note)"
    }

    /// Per-config-dir cooldown after a 429 from the usage endpoint, so a status
    /// refresh loop never hammers it. (The chat token itself stays usable.)
    private final class CooldownStore: @unchecked Sendable {
        private let lock = NSLock()
        private var until: [String: Date] = [:]
        func active(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return (until[key].map { Date() < $0 }) ?? false }
        func arm(_ key: String, seconds: TimeInterval) { lock.lock(); until[key] = Date().addingTimeInterval(seconds); lock.unlock() }
    }
    private static let usageCooldown = CooldownStore()
    private static let usage429CooldownSeconds: TimeInterval = 180

    /// Claude Code's public OAuth client id (used to refresh an expired token).
    private static let claudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Live quota from the OAuth usage endpoint (the source `/usage` uses).
    /// Distinguishes "no token" (UI tells the user to log in) from a transient
    /// endpoint failure. Refreshes an expired token; backs off after a 429.
    private func claudeLive() async -> ClaudeLiveResult {
        let configDir = claudeConfigDir()
        guard let creds = await claudeCredentials(configDir: configDir) else { return .noToken }
        if Self.usageCooldown.active(configDir.path) { return .unavailable }

        var token = creds.accessToken
        if creds.isExpired, let refreshToken = creds.refreshToken,
           let fresh = await refreshClaudeToken(refreshToken) {
            token = fresh
        }

        let version = await claudeVersion()
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return .unavailable }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Missing User-Agent makes this endpoint return repeated 429s.
        request.setValue("claude-code/\(version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .unavailable }
        if http.statusCode == 429 {
            Self.usageCooldown.arm(configDir.path, seconds: Self.usage429CooldownSeconds)
            return .unavailable
        }
        guard (200..<400).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parsed = Self.parseClaudeUsage(object)
        else { return .unavailable }
        return .ok(remaining: parsed.remaining, hint: parsed.hint, plan: parsed.plan)
    }

    /// Refresh an expired Claude access token via the public OAuth client. The
    /// new token is used in-memory only (the CLI owns the stored credential).
    private func refreshClaudeToken(_ refreshToken: String) async -> String? {
        guard let url = URL(string: "https://api.anthropic.com/v1/oauth/token") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.claudeClientID,
        ])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["access_token"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    /// Parse api/oauth/usage. Each quota window carries utilization (0-100) and
    /// often a reset timestamp. Do not infer fixed windows from key names:
    /// account types can have different durations. Surface the reset time from
    /// the payload instead.
    static func parseClaudeUsage(_ value: [String: Any]) -> (remaining: String, hint: String, plan: String)? {
        var labels: [String] = []
        var resets: [String] = []

        func add(_ key: String, _ window: [String: Any]) {
            guard let used = window["utilization"] as? Double else { return }
            let remaining = max(0, min(100, Int((100 - used).rounded())))
            let label = Self.quotaWindowLabel(key: key, window: window)
            if let reset = window["resets_at"] as? String, !reset.isEmpty {
                let resetText = Self.resetText(reset)
                labels.append("\(label) \(remaining)% left, \(resetText)")
                resets.append("\(label) \(resetText)")
            } else {
                labels.append("\(label) \(remaining)% left")
            }
        }

        for key in value.keys.sorted() {
            if let w = value[key] as? [String: Any], w["utilization"] is Double {
                add(key, w)
            }
        }
        guard !labels.isEmpty else { return nil }
        var plan = ""
        for key in ["subscriptionType", "subscription_type", "plan", "plan_type", "tier", "account_type"] {
            if let raw = value[key] as? String, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                plan = Self.humanizeAccountPlan(raw)
                break
            }
        }
        return (labels.joined(separator: "; "), resets.joined(separator: "; "), plan)
    }

    /// Claude 2.x keys its keychain credential by sha256(config_dir)[:8] hex.
    private func claudeKeychainSuffix(_ configDir: URL) -> String {
        let digest = SHA256.hash(data: Data(configDir.path.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private struct ClaudeCreds {
        let accessToken: String
        let refreshToken: String?
        let expiresAtMs: Double?
        /// Treat as expired within 60s of the deadline. Unknown expiry => not expired.
        var isExpired: Bool {
            guard let expiresAtMs else { return false }
            return expiresAtMs <= Date().timeIntervalSince1970 * 1000 + 60_000
        }
    }

    /// Resolve Claude's OAuth credentials: per-dir keychain (2.x) -> per-dir
    /// .credentials.json -> legacy global keychain (default dir only).
    private func claudeCredentials(configDir: URL) async -> ClaudeCreds? {
        var blob = await readKeychain("Claude Code-credentials-\(claudeKeychainSuffix(configDir))")
        if blob == nil {
            let file = configDir.appendingPathComponent(".credentials.json")
            blob = (try? String(contentsOf: file, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if blob == nil, configDir == home.appendingPathComponent(".claude") {
            blob = await readKeychain("Claude Code-credentials")
        }
        guard let blob, !blob.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(blob.utf8)) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return ClaudeCreds(
            accessToken: token,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAtMs: oauth["expiresAt"] as? Double
        )
    }

    private func readKeychain(_ service: String) async -> String? {
        let result = try? await shell.run(
            ["security", "find-generic-password", "-s", service, "-w"],
            cwd: nil, timeout: 5
        )
        guard let result, result.ok else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func claudeVersion() async -> String {
        guard let result = try? await shell.run(["claude", "--version"], cwd: nil, timeout: 8) else {
            return "0.0.0"
        }
        for token in result.stdout.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            if token.first?.isNumber == true { return String(token) }
        }
        return "0.0.0"
    }

    private func codexAccount() -> (account: String, plan: String, quotaHint: String, quotaRemaining: String) {
        let codexHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path)
        let auth = readJSONObject(codexHome.appendingPathComponent("auth.json")) ?? [:]
        let tokens = auth["tokens"] as? [String: Any] ?? [:]
        let claims = (tokens["id_token"] as? String).map(Self.decodeJWTClaims) ?? [:]
        let user = (auth["user"] as? [String: Any]) ?? (auth["account"] as? [String: Any]) ?? [:]
        // Real email lives in the signed id_token, not as a plain field.
        let account = claims["email"] as? String
            ?? user["email"] as? String
            ?? auth["email"] as? String
            ?? tokens["account_id"] as? String
            ?? auth["account_id"] as? String
            ?? ""
        let authClaims = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let jwtPlan = authClaims["chatgpt_plan_type"] as? String
        let quota = latestCodexQuota(in: codexHome.appendingPathComponent("sessions"))
        // rate_limits.plan_type is the real Codex entitlement (e.g. "plus"); the
        // JWT chatgpt_plan_type can say "free" even for paying Codex users.
        let plan = quota.plan.isEmpty ? jwtPlan : quota.plan
        return (account, Self.codexDisplayPlan(plan), quota.hint, quota.remaining)
    }

    static func codexDisplayPlan(_ raw: String?) -> String {
        guard let raw else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // The Codex id_token may report ChatGPT plan `free` even when the user
        // has separate Codex/API entitlements. Do not present that as an account
        // type; showing nothing is more honest than showing a misleading plan.
        if trimmed.lowercased() == "free" { return "" }
        return humanizeAccountPlan(trimmed)
    }

    /// Decode (without verifying) a JWT payload. Codex stores the OAuth id_token
    /// in auth.json; account email and ChatGPT plan live in its claims.
    static func decodeJWTClaims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return object
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
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                // Codex nests the snapshot under "payload"; tolerate flat too.
                let payload = object["payload"] as? [String: Any] ?? [:]
                guard let limits = (payload["rate_limits"] as? [String: Any])
                    ?? (object["rate_limits"] as? [String: Any])
                    ?? (object["rate_limit"] as? [String: Any])
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
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any],
                  let used = window["used_percent"] as? Double
            else { continue }
            let label = Self.quotaWindowLabel(key: key, window: window)
            let remaining = max(0, min(100, Int((100 - used).rounded())))
            if let reset = window["resets_at"] {
                let resetText = Self.resetText(String(describing: reset))
                labels.append("\(label) \(remaining)% left, \(resetText)")
                resets.append("\(label) \(resetText)")
            } else {
                labels.append("\(label) \(remaining)% left")
            }
        }
        return (limits["plan_type"] as? String ?? "", resets.joined(separator: "; "), labels.joined(separator: "; "))
    }

    private static func quotaWindowLabel(key: String, window: [String: Any]) -> String {
        if let minutes = window["window_minutes"] as? Double, minutes > 0 {
            return durationLabel(minutes: minutes)
        }

        var parts = key.split(separator: "_").map(String.init)
        if parts.count >= 2,
           let count = wordNumber(parts[0]),
           let unit = shortDurationUnit(parts[1]) {
            parts.removeFirst(2)
            let suffix = parts.map(humanizeAccountPlan).joined(separator: " ")
            return suffix.isEmpty ? "\(count)\(unit)" : "\(count)\(unit) \(suffix)"
        }

        return humanizeQuotaKey(key)
    }

    private static func wordNumber(_ value: String) -> Int? {
        if let number = Int(value) { return number }
        return [
            "one": 1,
            "two": 2,
            "three": 3,
            "four": 4,
            "five": 5,
            "six": 6,
            "seven": 7,
            "eight": 8,
            "nine": 9,
            "ten": 10,
            "eleven": 11,
            "twelve": 12,
        ][value.lowercased()]
    }

    private static func shortDurationUnit(_ value: String) -> String? {
        switch value.lowercased() {
        case "minute", "minutes", "min", "mins": return "m"
        case "hour", "hours": return "h"
        case "day", "days": return "d"
        case "week", "weeks": return "w"
        default: return nil
        }
    }

    private static func durationLabel(minutes: Double) -> String {
        let total = max(1, Int(minutes.rounded()))
        if total % 1_440 == 0 { return "\(total / 1_440)d" }
        if total % 60 == 0 { return "\(total / 60)h" }
        if total > 60 {
            let hours = total / 60
            let mins = total % 60
            return "\(hours)h \(mins)m"
        }
        return "\(total)m"
    }

    private static func resetText(_ raw: String) -> String {
        guard let date = parseResetDate(raw) else { return "resets \(raw)" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let local = formatter.string(from: date)
        let relative = relativeResetText(to: date)
        return relative.isEmpty ? "resets \(local)" : "resets \(local) (\(relative))"
    }

    private static func parseResetDate(_ raw: String) -> Date? {
        if let numeric = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let seconds = numeric > 10_000_000_000 ? numeric / 1_000 : numeric
            return Date(timeIntervalSince1970: seconds)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private static func relativeResetText(to date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded()))
        if seconds == 0 { return "now" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(1, minutes))m"
    }

    private static func humanizeQuotaKey(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { part in
                part.prefix(1).uppercased() + part.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    static func humanizeAccountPlan(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { part in part.prefix(1).uppercased() + part.dropFirst().lowercased() }
            .joined(separator: " ")
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
