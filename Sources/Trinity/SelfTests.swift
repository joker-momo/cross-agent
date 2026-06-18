import Foundation

enum SelfTests {
    static func run() -> Int32 {
        var failures: [String] = []
        var total = 0

        check("claude implementer has edit flag", &failures, &total) {
            let command = AgentCommandBuilder.build(agent: .claude, role: .implementer, prompt: "do x")
            return Array(command.prefix(3)) == ["claude", "-p", "do x"]
                && command.contains("--permission-mode")
                && command.contains("acceptEdits")
                && !command.contains("--output-format")
        }

        check("codex reviewer uses output schema", &failures, &total) {
            let command = AgentCommandBuilder.build(agent: .codex, role: .reviewer, prompt: "review", schemaPath: "/tmp/review.schema.json")
            return Array(command.prefix(2)) == ["codex", "exec"]
                && command.contains("--output-schema")
                && command.contains("/tmp/review.schema.json")
        }

        check("agy uses current non-interactive permission flag", &failures, &total) {
            let command = AgentCommandBuilder.build(agent: .agy, role: .implementer, prompt: "go")
            let reviewer = AgentCommandBuilder.build(agent: .agy, role: .reviewer, prompt: "review")
            return command.first == "agy"
                && command.contains("--dangerously-skip-permissions")
                && !command.contains("--yes")
                && !reviewer.contains("--output-format")
        }

        check("planner prompt emits executable part schema", &failures, &total) {
            let planner = Prompts.planner(task: "build x", planPath: ".trinity/plan.md")
            let replan = Prompts.replan(task: "build x", planPath: ".trinity/plan.md", blockingIssues: ["bug"])
            return planner.contains("Split the work into small")
                && planner.contains("Each part must include its own verification")
                && planner.contains("\"parts\"")
                && planner.contains("\"pass_criteria\"")
                && planner.contains("reviewer must approve that part before the next part starts")
                && replan.contains("same JSON schema")
        }

        check("implementer and reviewer prompts are scoped to one part", &failures, &total) {
            let part = samplePlanPart()
            let implementer = Prompts.implementer(part: part, planPath: ".trinity/plan.md", feedback: ["missing test"])
            let reviewer = Prompts.reviewer(part: part, task: "build x", planPath: ".trinity/plan.md", diff: "diff", implementerOutput: "tests pass")
            let final = Prompts.finalReviewer(task: "build x", planPath: ".trinity/plan.md", diff: "diff")
            return implementer.contains("implement ONLY the current part")
                && implementer.contains("Do not start any later plan part")
                && implementer.contains("Do not create commits")
                && implementer.contains("missing test")
                && reviewer.contains("ONLY the current plan part")
                && reviewer.contains("verification was missing")
                && reviewer.contains("implementers often hallucinate")
                && reviewer.contains("Inspect every changed file")
                && reviewer.contains("break existing behavior")
                && final.contains("final full-plan review")
                && final.contains("Inspect every changed file")
        }

        check("plan parser accepts fenced executable plan json", &failures, &total) {
            let raw = """
            # Plan
            ```json
            {
              "parts": [
                {
                  "id": "part-1",
                  "title": "Wire parser",
                  "scope": "Parser only",
                  "files": ["Sources/Trinity/VerdictParser.swift"],
                  "steps": ["Add parser"],
                  "verification": ["rtk swift build"],
                  "pass_criteria": ["Parser decodes one part"]
                }
              ]
            }
            ```
            """
            let plan = try? PlanParser.parse(raw)
            return plan?.parts.count == 1
                && plan?.parts.first?.id == "part-1"
                && plan?.parts.first?.passCriteria == ["Parser decodes one part"]
        }

        check("plan parser rejects empty parts", &failures, &total) {
            do {
                _ = try PlanParser.parse("```json\n{\"parts\": []}\n```")
                return false
            } catch {
                return true
            }
        }

        check("verdict parser accepts fenced json", &failures, &total) {
            let raw = """
            ok
            ```json
            {"approved": false, "blocking_issues": ["bug"], "minor_notes": [], "reason": "broken"}
            ```
            """
            let verdict = try? VerdictParser.parse(raw)
            return verdict?.approved == false && verdict?.blockingIssues == ["bug"]
        }

        check("verdict parser rejects missing json", &failures, &total) {
            do {
                _ = try VerdictParser.parse("no verdict")
                return false
            } catch {
                return true
            }
        }

        check("git slugify matches branch contract", &failures, &total) {
            let git = GitService()
            return git.slugify("Fix Account Switch Button!!") == "fix-account-switch-button"
                && git.slugify("___") == "task"
        }

        check("git slugify drops non-ascii digits", &failures, &total) {
            // Arabic-Indic digits are Character.isNumber == true but not ASCII;
            // they must not leak into a git branch name.
            let git = GitService()
            return git.slugify("v١٢٣ build") == "v-build"
        }

        check("git preflight allows main before trinity branch creation", &failures, &total) {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("trinity-selftest-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: temp) }
                _ = try shell(["git", "init", "-b", "main"], cwd: temp)
                _ = try shell(["git", "config", "user.email", "selftest@example.com"], cwd: temp)
                _ = try shell(["git", "config", "user.name", "Self Test"], cwd: temp)
                try "hello".write(to: temp.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
                _ = try shell(["git", "add", "README.md"], cwd: temp)
                _ = try shell(["git", "commit", "-m", "init"], cwd: temp)
                let semaphore = DispatchSemaphore(value: 0)
                let resultBox = BoolBox()
                Task.detached {
                    do {
                        try await GitService().preflight(cwd: temp)
                        resultBox.set(true)
                    } catch {
                        resultBox.set(false)
                    }
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 10)
                return resultBox.value
            } catch {
                return false
            }
        }

        check("agent runner resolves bundled review schema", &failures, &total) {
            guard let path = AgentRunner.reviewSchemaPath() else { return false }
            let command = AgentCommandBuilder.build(agent: .codex, role: .reviewer, prompt: "r", schemaPath: path)
            return command.contains("--output-schema") && command.contains(path)
        }

        check("codex jwt claims decode for account email", &failures, &total) {
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

        check("codex free plan claim is suppressed", &failures, &total) {
            AgentHealthService.codexDisplayPlan("free").isEmpty
                && AgentHealthService.codexDisplayPlan("plus") == "Plus"
                && AgentHealthService.codexDisplayPlan(nil).isEmpty
        }

        check("codex live usage parses wham quota schema", &failures, &total) {
            let value: [String: Any] = [
                "email": "dev@example.com",
                "plan_type": "plus",
                "rate_limit": [
                    "primary_window": [
                        "used_percent": 4.0,
                        "limit_window_seconds": 18_000.0,
                        "reset_at": 1_781_760_400.0,
                    ],
                    "secondary_window": [
                        "used_percent": 1.0,
                        "limit_window_seconds": 604_800.0,
                        "reset_at": 1_782_347_200.0,
                    ],
                ],
            ]
            guard let parsed = AgentHealthService.parseCodexUsage(value) else { return false }
            return parsed.account == "dev@example.com"
                && parsed.plan == "Plus"
                && parsed.remaining.contains("5h 96% left")
                && parsed.remaining.contains("7d 99% left")
                && parsed.hint.contains("5h resets")
        }

        check("claude usage parses utilization to remaining", &failures, &total) {
            let value: [String: Any] = [
                "five_hour": ["utilization": 4.0, "resets_at": "2026-05-31T11:00:00Z"],
                "seven_day": ["utilization": 14.0, "resets_at": "2026-06-05T03:00:00Z"],
                "subscription_type": "max",
            ]
            guard let parsed = AgentHealthService.parseClaudeUsage(value) else { return false }
            return parsed.remaining.contains("5h 96% left, resets")
                && parsed.remaining.contains("7d 86% left, resets")
                && parsed.plan == "Max"
                && parsed.hint.contains("5h resets")
        }

        check("claude usage nil without utilization", &failures, &total) {
            AgentHealthService.parseClaudeUsage(["extra_usage": ["is_enabled": false]]) == nil
        }

        check("claude live note appends reason without losing hints", &failures, &total) {
            return AgentHealthService.appendNote("out of credits", "live quota: run `claude setup-token`")
                    == "out of credits · live quota: run `claude setup-token`"
                && AgentHealthService.appendNote("", "live quota unavailable") == "live quota unavailable"
        }

        check("claude usage parses model-specific weekly windows", &failures, &total) {
            let value: [String: Any] = [
                "five_hour": ["utilization": 10.0] as [String: Any],
                "seven_day": ["utilization": 20.0] as [String: Any],
                "seven_day_opus": ["utilization": 90.0] as [String: Any],
            ]
            guard let parsed = AgentHealthService.parseClaudeUsage(value) else { return false }
            return parsed.remaining.contains("5h 90% left")
                && parsed.remaining.contains("7d 80% left")
                && parsed.remaining.contains("7d Opus 10% left")
        }

        check("claude auth status parser separates sign-in state", &failures, &total) {
            let signedOut = AgentHealthService.parseClaudeAuthStatus([
                "loggedIn": false,
                "authMethod": "none",
                "apiProvider": "firstParty",
            ])
            let signedIn = AgentHealthService.parseClaudeAuthStatus([
                "loggedIn": true,
                "authMethod": "oauth",
                "subscriptionType": "pro",
                "user": ["email": "dev@example.com"],
            ])
            return signedOut.loggedIn == false
                && signedOut.method == "none"
                && signedIn.loggedIn == true
                && signedIn.account == "dev@example.com"
                && signedIn.method == "oauth"
                && signedIn.plan == "Pro"
        }

        check("claude cached billing type is not account plan", &failures, &total) {
            AgentHealthService.humanizeAccountPlan("stripe_subscription") == "Stripe Subscription"
                && AgentHealthService.parseClaudeAuthStatus([
                    "loggedIn": true,
                    "billingType": "stripe_subscription",
                ]).plan.isEmpty
        }

        check("antigravity status: worst model + plan + account", &failures, &total) {
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
            // worst = Claude Opus 0.4 remaining => 60% used => 40% left, labeled
            return p.remaining == "Claude Opus 40% left" && p.plan == "Pro" && p.account == "Designer"
                && p.hint.contains("Claude Opus 40% left")
        }

        check("antigravity proto3 missing fraction = exhausted", &failures, &total) {
            let value: [String: Any] = [
                "userStatus": ["cascadeModelConfigData": ["clientModelConfigs": [
                    ["label": "Gemini", "quotaInfo": ["remainingFraction": 1.0]],
                    ["label": "Opus", "quotaInfo": ["resetTime": "x"]],  // omitted => 0.0 => exhausted
                ]]],
            ]
            guard let p = AgentHealthService.parseAntigravityStatus(value) else { return false }
            return p.remaining == "Opus 0% left" && p.hint.contains("Opus 0% left")
        }

        check("antigravity quota summary parses grouped weekly + 5h", &failures, &total) {
            let value: [String: Any] = [
                "response": [
                    "groups": [
                        [
                            "displayName": "Gemini Models",
                            "buckets": [
                                ["window": "weekly", "remainingFraction": 0.706],
                                ["window": "5h", "remainingFraction": 0.8317],
                            ],
                        ],
                        [
                            "displayName": "Claude and GPT models",
                            "buckets": [
                                ["window": "weekly", "remainingFraction": 0.804],
                                ["window": "5h", "remainingFraction": 1.0],
                            ],
                        ],
                    ],
                ],
            ]
            guard let q = AgentHealthService.parseAntigravityQuotaSummary(value) else { return false }
            return q.remaining.contains("Gemini weekly 71% left")
                && q.remaining.contains("Gemini 5h 83% left")
                && q.remaining.contains("Claude/GPT weekly 80% left")
                && q.remaining.contains("Claude/GPT 5h 100% left")
        }

        check("antigravity argValue extracts csrf + extension port", &failures, &total) {
            let line = "12 /x/language_server --csrf_token ABC123 --extension_server_port 51234"
            return AgentHealthService.argValue(line, flag: "--csrf_token") == "ABC123"
                && AgentHealthService.argValue(line, flag: "--extension_server_port") == "51234"
        }

        check("antigravity surfaces monthly prompt credits", &failures, &total) {
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
            return p.hint.contains("credits 300/1000") && p.remaining == "Credits 30% left; Gemini 50% left"
        }

        check("augmented PATH adds common install dirs and dedups", &failures, &total) {
            // Simulate a Finder-launched .app's minimal PATH.
            let path = Shell.augmentedPATH(basePATH: "/usr/bin:/bin")
            let dirs = path.split(separator: ":").map(String.init)
            return dirs.contains("/opt/homebrew/bin")
                && dirs.contains("/usr/local/bin")
                && dirs.contains("\(FileManager.default.homeDirectoryForCurrentUser.path)/.antigravity/antigravity/bin")
                && dirs.first == "/usr/bin"
                && dirs.filter { $0 == "/usr/bin" }.count == 1
        }

        check("shell drains large output without deadlock", &failures, &total) {
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
            print("SelfTests: \(total) passed")
            return 0
        }
        print("SelfTests: \(failures.count) failed")
        for failure in failures {
            print("- \(failure)")
        }
        return 1
    }

    private static func check(_ name: String, _ failures: inout [String], _ total: inout Int, _ body: () -> Bool) {
        total += 1
        if !body() {
            failures.append(name)
        }
    }

    private static func samplePlanPart() -> PlanPart {
        PlanPart(
            id: "part-1",
            title: "Small part",
            scope: "Only one change",
            files: ["Sources/Trinity/RunManager.swift"],
            steps: ["Make the change"],
            verification: ["rtk swift build"],
            passCriteria: ["Build passes"]
        )
    }

    @discardableResult
    private static func shell(_ command: [String], cwd: URL) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = cwd
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return ProcessResult(
            code: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            command: command
        )
    }

    /// Thread-safe int holder for bridging an async result back to a sync check.
    private final class CountBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        func set(_ value: Int) { lock.lock(); storage = value; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private final class BoolBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false
        func set(_ value: Bool) { lock.lock(); storage = value; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
    }
}
