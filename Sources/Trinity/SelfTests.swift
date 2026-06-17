import Foundation

enum SelfTests {
    static func run() -> Int32 {
        var failures: [String] = []

        check("claude implementer has edit flag", &failures) {
            let command = AgentCommandBuilder.build(agent: .claude, role: .implementer, prompt: "do x")
            return Array(command.prefix(3)) == ["claude", "-p", "do x"]
                && command.contains("--permission-mode")
                && command.contains("acceptEdits")
                && !command.contains("--output-format")
        }

        check("codex reviewer uses output schema", &failures) {
            let command = AgentCommandBuilder.build(agent: .codex, role: .reviewer, prompt: "review", schemaPath: "/tmp/review.schema.json")
            return Array(command.prefix(2)) == ["codex", "exec"]
                && command.contains("--output-schema")
                && command.contains("/tmp/review.schema.json")
        }

        check("agy always uses yes", &failures) {
            let command = AgentCommandBuilder.build(agent: .agy, role: .implementer, prompt: "go")
            return command.first == "agy" && command.contains("--yes")
        }

        check("verdict parser accepts fenced json", &failures) {
            let raw = """
            ok
            ```json
            {"approved": false, "blocking_issues": ["bug"], "minor_notes": [], "reason": "broken"}
            ```
            """
            let verdict = try? VerdictParser.parse(raw)
            return verdict?.approved == false && verdict?.blockingIssues == ["bug"]
        }

        check("verdict parser rejects missing json", &failures) {
            do {
                _ = try VerdictParser.parse("no verdict")
                return false
            } catch {
                return true
            }
        }

        check("git slugify matches branch contract", &failures) {
            let git = GitService()
            return git.slugify("Fix Account Switch Button!!") == "fix-account-switch-button"
                && git.slugify("___") == "task"
        }

        check("git slugify drops non-ascii digits", &failures) {
            // Arabic-Indic digits are Character.isNumber == true but not ASCII;
            // they must not leak into a git branch name.
            let git = GitService()
            return git.slugify("v١٢٣ build") == "v-build"
        }

        check("agent runner resolves bundled review schema", &failures) {
            guard let path = AgentRunner.reviewSchemaPath() else { return false }
            let command = AgentCommandBuilder.build(agent: .codex, role: .reviewer, prompt: "r", schemaPath: path)
            return command.contains("--output-schema") && command.contains(path)
        }

        check("codex jwt claims decode for account email", &failures) {
            // base64url payload (no padding) carrying {"email":"dev@example.com"}
            func seg(_ json: String) -> String {
                Data(json.utf8).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            }
            let token = "\(seg("{\"alg\":\"RS256\"}")).\(seg("{\"email\":\"dev@example.com\"}")).sig"
            let claims = AgentHealthService.decodeJWTClaims(token)
            return claims["email"] as? String == "dev@example.com"
        }

        check("claude usage parses utilization to remaining", &failures) {
            let value: [String: Any] = [
                "five_hour": ["utilization": 4.0, "resets_at": "2026-05-31T11:00:00Z"],
                "seven_day": ["utilization": 14.0, "resets_at": "2026-06-05T03:00:00Z"],
                "subscription_type": "max",
            ]
            guard let parsed = AgentHealthService.parseClaudeUsage(value) else { return false }
            return parsed.remaining == "5h 96% left; weekly 86% left"
                && parsed.plan == "max"
                && parsed.hint.contains("5h reset 2026-05-31T11:00:00Z")
        }

        check("claude usage nil without utilization", &failures) {
            AgentHealthService.parseClaudeUsage(["extra_usage": ["is_enabled": false]]) == nil
        }

        check("claude live note appends reason without losing hints", &failures) {
            return AgentHealthService.appendNote("out of credits", "live quota: run `claude setup-token`")
                    == "out of credits · live quota: run `claude setup-token`"
                && AgentHealthService.appendNote("", "live quota unavailable") == "live quota unavailable"
        }

        check("claude usage parses model-specific weekly windows", &failures) {
            let value: [String: Any] = [
                "five_hour": ["utilization": 10.0],
                "seven_day": ["utilization": 20.0],
                "seven_day_opus": ["utilization": 90.0],
            ]
            guard let parsed = AgentHealthService.parseClaudeUsage(value) else { return false }
            return parsed.remaining.contains("5h 90% left")
                && parsed.remaining.contains("weekly 80% left")
                && parsed.remaining.contains("weekly opus 10% left")
        }

        check("antigravity status: worst model + plan + account", &failures) {
            let value: [String: Any] = [
                "userStatus": [
                    "name": "Designer",
                    "planStatus": ["planInfo": ["planName": "Pro"]],
                    "cascadeModelConfigData": ["clientModelConfigs": [
                        ["label": "Gemini 3 Pro", "quotaInfo": ["remainingFraction": 1.0]],
                        ["label": "Claude Opus", "quotaInfo": ["remainingFraction": 0.4]],
                    ]],
                ],
            ]
            guard let p = AgentHealthService.parseAntigravityStatus(value) else { return false }
            // worst = Claude Opus 0.4 remaining => 60% used => 40% left
            return p.remaining == "5h 40% left" && p.plan == "Pro" && p.account == "Designer"
                && p.hint.contains("Claude Opus 40% left")
        }

        check("antigravity proto3 missing fraction = exhausted", &failures) {
            let value: [String: Any] = [
                "userStatus": ["cascadeModelConfigData": ["clientModelConfigs": [
                    ["label": "Gemini", "quotaInfo": ["remainingFraction": 1.0]],
                    ["label": "Opus", "quotaInfo": ["resetTime": "x"]],  // omitted => 0.0 => exhausted
                ]]],
            ]
            guard let p = AgentHealthService.parseAntigravityStatus(value) else { return false }
            return p.remaining == "5h 0% left" && p.hint.contains("Opus 0% left")
        }

        check("antigravity argValue extracts csrf + extension port", &failures) {
            let line = "12 /x/language_server --csrf_token ABC123 --extension_server_port 51234"
            return AgentHealthService.argValue(line, flag: "--csrf_token") == "ABC123"
                && AgentHealthService.argValue(line, flag: "--extension_server_port") == "51234"
        }

        check("antigravity surfaces monthly prompt credits", &failures) {
            let value: [String: Any] = [
                "userStatus": [
                    "planStatus": [
                        "availablePromptCredits": 300.0,
                        "planInfo": ["planName": "Pro", "monthlyPromptCredits": 1000.0],
                    ],
                    "cascadeModelConfigData": ["clientModelConfigs": [
                        ["label": "Gemini", "quotaInfo": ["remainingFraction": 0.5]],
                    ]],
                ],
            ]
            guard let p = AgentHealthService.parseAntigravityStatus(value) else { return false }
            return p.hint.contains("credits 300/1000") && p.remaining == "5h 50% left"
        }

        check("augmented PATH adds common install dirs and dedups", &failures) {
            // Simulate a Finder-launched .app's minimal PATH.
            let path = Shell.augmentedPATH(basePATH: "/usr/bin:/bin")
            let dirs = path.split(separator: ":").map(String.init)
            return dirs.contains("/opt/homebrew/bin")
                && dirs.contains("/usr/local/bin")
                && dirs.contains("\(FileManager.default.homeDirectoryForCurrentUser.path)/.antigravity/antigravity/bin")
                && dirs.first == "/usr/bin"
                && dirs.filter { $0 == "/usr/bin" }.count == 1
        }

        check("shell drains large output without deadlock", &failures) {
            // Output far exceeds the OS pipe buffer; if Shell.run reads only after
            // waitUntilExit() this hangs. A returned result proves concurrent drain.
            let payload = String(repeating: "x", count: 200_000)
            let semaphore = DispatchSemaphore(value: 0)
            let countBox = CountBox()
            Task.detached {
                let result = try? await Shell().run(["printf", "%s", payload], cwd: nil, timeout: 30)
                countBox.set(result?.stdout.count ?? -1)
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 30)
            return countBox.value == payload.count
        }

        if failures.isEmpty {
            print("SelfTests: 20 passed")
            return 0
        }
        print("SelfTests: \(failures.count) failed")
        for failure in failures {
            print("- \(failure)")
        }
        return 1
    }

    private static func check(_ name: String, _ failures: inout [String], _ body: () -> Bool) {
        if !body() {
            failures.append(name)
        }
    }

    /// Thread-safe int holder for bridging an async result back to a sync check.
    private final class CountBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        func set(_ value: Int) { lock.lock(); storage = value; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
    }
}
