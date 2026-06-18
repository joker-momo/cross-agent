import Foundation

@MainActor
final class RunManager: ObservableObject {
    @Published private(set) var runs: [RunRecord] = []
    @Published private(set) var activeRunId: String?

    private var cancels: [String: Bool] = [:]
    private let git: GitService
    private let runner: AgentRunner
    private let fileManager: FileManager

    init(git: GitService = GitService(), runner: AgentRunner = AgentRunner(), fileManager: FileManager = .default) {
        self.git = git
        self.runner = runner
        self.fileManager = fileManager
    }

    var hasActiveRun: Bool {
        activeRunId != nil
    }

    func start(project: String, request: String, roles: Roles, config: RunConfig) -> String {
        let runId = Self.newRunId()
        let record = RunRecord(runId: runId, project: project, request: request, roles: roles)
        runs.append(record)
        activeRunId = runId
        cancels[runId] = false

        Task {
            await execute(runId: runId, project: project, request: request, roles: roles, config: config)
        }
        return runId
    }

    func stop(_ runId: String) {
        cancels[runId] = true
    }

    private func execute(runId: String, project: String, request: String, roles: Roles, config: RunConfig) async {
        let projectURL = URL(fileURLWithPath: project)
        var branch: String?

        do {
            try await git.preflight(cwd: projectURL)
            if try await git.isDirty(cwd: projectURL) {
                try await git.stash(cwd: projectURL)
                append(runId, .init(kind: .log, text: "stashed dirty worktree before run"))
            }
            let baseRef = try await git.currentHead(cwd: projectURL)
            branch = try await git.createBranch(cwd: projectURL, slug: git.slugify(request))
            append(runId, .init(kind: .log, text: "created branch \(branch ?? "")"))

            let planPath = ".trinity/runs/\(runId)/plan.md"
            try ensureArtifacts(project: projectURL, runId: runId, task: request)
            setState(runId, .planning, iteration: 0, branch: branch)
            _ = try await runner.run(agent: roles.planner, role: .planner, prompt: Prompts.planner(task: request, planPath: planPath), cwd: projectURL, timeout: config.callTimeoutSeconds)
            let plan: ExecutionPlan
            do {
                let rawPlan = try String(contentsOf: projectURL.appendingPathComponent(planPath), encoding: .utf8)
                plan = try PlanParser.parse(rawPlan)
            } catch {
                finish(runId, reason: .planRejected, message: "planner produced an invalid executable plan: \(error.localizedDescription)", iteration: 0, branch: branch)
                return
            }
            append(runId, .init(kind: .log, text: "planner produced \(plan.parts.count) executable part(s)"))

            var iteration = 0
            for (partIndex, part) in plan.parts.enumerated() {
                var partFeedback: [String]?
                var partApproved = false

                for attempt in 1...config.maxIter {
                    iteration += 1
                    if cancels[runId] == true {
                        finish(runId, reason: .cancelled, message: "cancelled by user", iteration: iteration - 1, branch: branch)
                        return
                    }

                    append(runId, .init(kind: .log, text: "part \(partIndex + 1)/\(plan.parts.count) attempt \(attempt): \(part.title)", iteration: iteration))
                    setState(runId, .implementing, iteration: iteration, branch: branch)
                    let implement = try await runner.run(
                        agent: roles.implementer,
                        role: .implementer,
                        prompt: Prompts.implementer(part: part, planPath: planPath, feedback: partFeedback),
                        cwd: projectURL,
                        timeout: config.callTimeoutSeconds
                    )

                    guard try await git.hasChanges(cwd: projectURL) else {
                        finish(runId, reason: .noChanges, message: "implementer produced no edits for \(part.id)", iteration: iteration, branch: branch)
                        return
                    }

                    let diff = try await git.diff(cwd: projectURL, from: baseRef)

                    setState(runId, .reviewing, iteration: iteration, branch: branch)
                    let review = try await runner.run(
                        agent: roles.reviewer,
                        role: .reviewer,
                        prompt: Prompts.reviewer(part: part, task: request, planPath: planPath, diff: diff, implementerOutput: implement.stdout),
                        cwd: projectURL,
                        timeout: config.callTimeoutSeconds
                    )
                    let verdict = try VerdictParser.parse(review.stdout)
                    append(runId, .init(
                        kind: .verdict,
                        text: verdict.approved
                            ? "part \(partIndex + 1)/\(plan.parts.count) attempt \(attempt): APPROVED - \(verdict.reason)"
                            : "part \(partIndex + 1)/\(plan.parts.count) attempt \(attempt): rejected - \(verdict.blockingIssues.joined(separator: "; "))",
                        approved: verdict.approved,
                        iteration: iteration
                    ))

                    if verdict.approved {
                        partApproved = true
                        break
                    }

                    partFeedback = verdict.blockingIssues
                }

                guard partApproved else {
                    finish(runId, reason: .maxIterations, message: "\(part.id) was not approved in \(config.maxIter) attempt(s)", iteration: iteration, branch: branch)
                    return
                }
            }

            if cancels[runId] == true {
                finish(runId, reason: .cancelled, message: "cancelled by user", iteration: iteration, branch: branch)
                return
            }

            let finalDiff = try await git.diff(cwd: projectURL, from: baseRef)
            setState(runId, .reviewing, iteration: iteration + 1, branch: branch)
            let finalReview = try await runner.run(
                agent: roles.reviewer,
                role: .reviewer,
                prompt: Prompts.finalReviewer(task: request, planPath: planPath, diff: finalDiff),
                cwd: projectURL,
                timeout: config.callTimeoutSeconds
            )
            let finalVerdict = try VerdictParser.parse(finalReview.stdout)
            append(runId, .init(
                kind: .verdict,
                text: finalVerdict.approved
                    ? "final review: APPROVED - \(finalVerdict.reason)"
                    : "final review: rejected - \(finalVerdict.blockingIssues.joined(separator: "; "))",
                approved: finalVerdict.approved,
                iteration: iteration + 1
            ))

            if finalVerdict.approved {
                setState(runId, .done, iteration: iteration + 1, branch: branch, stopReason: .approved)
                finish(runId, reason: .approved, message: "all \(plan.parts.count) part(s) and final review approved", iteration: iteration + 1, branch: branch, setStoppedState: false)
            } else {
                finish(runId, reason: .maxIterations, message: "final full-plan review rejected: \(finalVerdict.blockingIssues.joined(separator: "; "))", iteration: iteration + 1, branch: branch)
            }
        } catch {
            finish(runId, reason: .agentError, message: error.localizedDescription, iteration: currentIteration(runId), branch: branch)
        }
    }

    private func ensureArtifacts(project: URL, runId: String, task: String) throws {
        let dir = project.appendingPathComponent(".trinity/runs/\(runId)")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try task.write(to: dir.appendingPathComponent("task.md"), atomically: true, encoding: .utf8)
    }

    private func currentIteration(_ runId: String) -> Int {
        runs.first(where: { $0.runId == runId })?.iteration ?? 0
    }

    private func setState(_ runId: String, _ state: RunState, iteration: Int, branch: String?, stopReason: StopReason? = nil) {
        guard let index = runs.firstIndex(where: { $0.runId == runId }) else { return }
        runs[index].state = state
        runs[index].iteration = iteration
        runs[index].branch = branch
        runs[index].stopReason = stopReason
        runs[index].history.append(.init(kind: .state, text: "\(state.rawValue) · iter \(iteration)", iteration: iteration))
    }

    private func append(_ runId: String, _ event: RunEvent) {
        guard let index = runs.firstIndex(where: { $0.runId == runId }) else { return }
        runs[index].history.append(event)
    }

    private func finish(_ runId: String, reason: StopReason, message: String, iteration: Int, branch: String?, setStoppedState: Bool = true) {
        if setStoppedState {
            setState(runId, .stopped, iteration: iteration, branch: branch, stopReason: reason)
        }
        append(runId, .init(kind: .stop, text: "\(reason.rawValue) - \(message)"))
        activeRunId = nil
        cancels.removeValue(forKey: runId)
    }

    private static func newRunId() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "Z", with: "")
    }
}
