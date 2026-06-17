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
        var lastVerdict: Verdict?
        var consecutiveFails = 0
        var escalations = 0

        do {
            try await git.preflight(cwd: projectURL)
            if try await git.isDirty(cwd: projectURL) {
                try await git.stash(cwd: projectURL)
                append(runId, .init(kind: .log, text: "stashed dirty worktree before run"))
            }
            branch = try await git.createBranch(cwd: projectURL, slug: git.slugify(request))
            append(runId, .init(kind: .log, text: "created branch \(branch ?? "")"))

            let planPath = ".trinity/runs/\(runId)/plan.md"
            try ensureArtifacts(project: projectURL, runId: runId, task: request)
            setState(runId, .planning, iteration: 0, branch: branch)
            _ = try await runner.run(agent: roles.planner, role: .planner, prompt: Prompts.planner(task: request, planPath: planPath), cwd: projectURL, timeout: config.callTimeoutSeconds)

            for iteration in 1...config.maxIter {
                if cancels[runId] == true {
                    finish(runId, reason: .cancelled, message: "cancelled by user", iteration: iteration - 1, branch: branch)
                    return
                }

                setState(runId, .implementing, iteration: iteration, branch: branch)
                let feedback = lastVerdict?.blockingIssues
                _ = try await runner.run(agent: roles.implementer, role: .implementer, prompt: Prompts.implementer(planPath: planPath, feedback: feedback), cwd: projectURL, timeout: config.callTimeoutSeconds)

                guard try await git.hasChanges(cwd: projectURL) else {
                    finish(runId, reason: .noChanges, message: "implementer produced no edits", iteration: iteration, branch: branch)
                    return
                }

                let diff = try await git.diff(cwd: projectURL)
                let sha = try await git.checkpoint(cwd: projectURL, message: "wip: iter \(iteration)") ?? "none"
                append(runId, .init(kind: .log, text: "checkpoint \(sha) for iter \(iteration)"))

                setState(runId, .reviewing, iteration: iteration, branch: branch)
                let review = try await runner.run(agent: roles.reviewer, role: .reviewer, prompt: Prompts.reviewer(task: request, diff: diff), cwd: projectURL, timeout: config.callTimeoutSeconds)
                let verdict = try VerdictParser.parse(review.stdout)
                lastVerdict = verdict
                append(runId, .init(kind: .verdict, text: verdict.approved ? "iter \(iteration): APPROVED - \(verdict.reason)" : "iter \(iteration): rejected - \(verdict.blockingIssues.joined(separator: "; "))", approved: verdict.approved, iteration: iteration))

                if verdict.approved {
                    setState(runId, .done, iteration: iteration, branch: branch, stopReason: .approved)
                    finish(runId, reason: .approved, message: "approved after \(iteration) iteration(s)", iteration: iteration, branch: branch, setStoppedState: false)
                    return
                }

                consecutiveFails += 1
                if consecutiveFails >= config.escalateAfter && iteration < config.maxIter {
                    setState(runId, .planning, iteration: iteration, branch: branch)
                    append(runId, .init(kind: .log, text: "escalating to planner"))
                    _ = try await runner.run(agent: roles.planner, role: .planner, prompt: Prompts.replan(task: request, planPath: planPath, blockingIssues: verdict.blockingIssues), cwd: projectURL, timeout: config.callTimeoutSeconds)
                    consecutiveFails = 0
                    escalations += 1
                }
            }

            if escalations >= config.escalateAfter {
                finish(runId, reason: .planRejected, message: "plan repeatedly wrong after \(escalations) re-plans", iteration: config.maxIter, branch: branch)
            } else {
                finish(runId, reason: .maxIterations, message: "not approved in \(config.maxIter) iterations", iteration: config.maxIter, branch: branch)
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
