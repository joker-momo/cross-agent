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
            if agent == .agy {
                status.detail = status.detail.isEmpty ? "CLI: \(cliPath)" : status.detail
            }
        } else if agent == .agy, let appURL {
            status.status = "app"
            status.version = antigravityAppVersion(appURL) ?? ""
            status.detail = "Antigravity app installed; CLI not found on PATH"
            status.canSwitch = true
        }

        // Live Claude quota (exact %) overrides config-file hints when available;
        // otherwise surface WHY realtime is missing instead of silently showing hints.
        if agent == .claude, installed {
            switch await claudeLive() {
            case .ok(let remaining, let hint, let plan):
                if !remaining.isEmpty { status.quotaRemaining = remaining }
                if !hint.isEmpty { status.quotaHint = hint }
                if !plan.isEmpty { status.plan = plan }
            case .noToken:
                status.quotaRemaining = Self.appendNote(status.quotaRemaining, "live quota: run `claude setup-token`")
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
        for server in servers {
            for port in server.ports {
                if let object = await antigravityUserStatus(scheme: "https", port: port, csrf: server.csrf),
                   let parsed = Self.parseAntigravityStatus(object) {
                    return .ok(remaining: parsed.remaining, hint: parsed.hint, plan: parsed.plan, account: parsed.account)
                }
            }
            if let extPort = server.extPort,
               let object = await antigravityUserStatus(scheme: "http", port: extPort, csrf: server.csrf),
               let parsed = Self.parseAntigravityStatus(object) {
                return .ok(remaining: parsed.remaining, hint: parsed.hint, plan: parsed.plan, account: parsed.account)
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

    private func antigravityUserStatus(scheme: String, port: UInt16, csrf: String) async -> [String: Any]? {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/GetUserStatus")
        else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        // Connect RPC expects this exact CSRF header name.
        request.setValue(csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.httpBody = #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}"#.data(using: .utf8)
        guard let (data, response) = try? await Self.loopbackSession.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
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
        let plan = planInfo["planName"] as? String ?? ""
        let account = userStatus["email"] as? String ?? userStatus["name"] as? String ?? ""

        var hintParts = models.map { "\($0.label) \(100 - $0.used)% left" }
        // Monthly prompt credits, if the plan reports them.
        if let available = planStatus["availablePromptCredits"] as? Double,
           let monthly = planInfo["monthlyPromptCredits"] as? Double, monthly > 0 {
            hintParts.insert("credits \(Int(available))/\(Int(monthly))", at: 0)
        }
        return ("5h \(100 - worst.used)% left", hintParts.joined(separator: "; "), plan, account)
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

    // MARK: - Claude live usage (exact %)

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

    /// Parse api/oauth/usage: five_hour/seven_day each carry utilization (0-100)
    /// + resets_at. Returns nil if neither window has a number.
    static func parseClaudeUsage(_ value: [String: Any]) -> (remaining: String, hint: String, plan: String)? {
        var labels: [String] = []
        var resets: [String] = []

        func add(_ label: String, _ window: [String: Any]) {
            guard let used = window["utilization"] as? Double else { return }
            let remaining = max(0, min(100, Int((100 - used).rounded())))
            labels.append("\(label) \(remaining)% left")
            if let reset = window["resets_at"] as? String {
                resets.append("\(label) reset \(reset)")
            }
        }

        if let w = value["five_hour"] as? [String: Any] { add("5h", w) }
        if let w = value["seven_day"] as? [String: Any] { add("weekly", w) }
        // Model-specific weekly windows, e.g. seven_day_sonnet / seven_day_opus.
        for key in value.keys.sorted() where key.hasPrefix("seven_day_") && key != "seven_day" {
            if let w = value[key] as? [String: Any] {
                add("weekly \(key.replacingOccurrences(of: "seven_day_", with: ""))", w)
            }
        }
        guard !labels.isEmpty else { return nil }
        var plan = ""
        for key in ["subscription_type", "plan", "plan_type", "tier", "account_type"] {
            if let raw = value[key] as? String, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                plan = raw
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
        let plan = authClaims["chatgpt_plan_type"] as? String ?? ""
        let quota = latestCodexQuota(in: codexHome.appendingPathComponent("sessions"))
        return (account, plan.isEmpty ? quota.plan : plan, quota.hint, quota.remaining)
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
            let minutes = (window["window_minutes"] as? Double) ?? 0
            let label = minutes >= 1_440 ? "weekly" : "5h"
            let remaining = max(0, min(100, Int((100 - used).rounded())))
            labels.append("\(label) \(remaining)% left")
            if let reset = window["resets_at"] {
                resets.append("\(label) reset \(reset)")
            }
        }
        let plan = limits["plan_type"] as? String ?? ""
        return (plan, resets.joined(separator: "; "), labels.joined(separator: "; "))
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
