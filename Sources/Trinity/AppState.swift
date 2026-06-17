import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var projects: [String] = []
    @Published var selectedProject = ""
    @Published var newPath = ""
    @Published var request = ""
    @Published var roles = Roles()
    @Published var maxIter = 5
    @Published var escalateAfter = 2
    @Published var phase: RunPhase = .idle
    @Published var runId: String?
    @Published var error: String?
    @Published var agents: [AgentStatus] = []
    @Published var agentsLoading = false
    @Published var accountRefreshInProgress = false

    let projectStore: ProjectStore
    let health: AgentHealthService
    let runManager: RunManager
    private var agentRefreshTask: Task<Void, Never>?

    init(
        projectStore: ProjectStore = ProjectStore(),
        health: AgentHealthService = AgentHealthService(),
        runManager: RunManager = RunManager()
    ) {
        self.projectStore = projectStore
        self.health = health
        self.runManager = runManager
    }

    deinit {
        agentRefreshTask?.cancel()
    }

    var currentRun: RunRecord? {
        guard let runId else { return nil }
        return runManager.runs.first(where: { $0.runId == runId })
    }

    var runReadinessIssue: String? {
        let selectedAgents = Set([roles.planner, roles.implementer, roles.reviewer])
        let authRequired = agents
            .filter { selectedAgents.contains($0.agent) && $0.status == "auth" }
            .map { $0.agent.rawValue.capitalized }
        if !authRequired.isEmpty {
            return "Sign in required for \(authRequired.joined(separator: ", ")) before running a task."
        }

        let missing = Agent.allCases.filter { selectedAgents.contains($0) && !health.hasRunnableCLI($0) }
        guard !missing.isEmpty else { return nil }
        let names = missing.map { $0.rawValue.capitalized }.joined(separator: ", ")
        return "Missing runnable CLI for \(names). Account/quota can use the app, but task runs require the CLI on PATH."
    }

    func load() {
        projects = projectStore.listProjects()
        if selectedProject.isEmpty, let first = projects.first {
            selectedProject = first
        }
        startAgentRefreshLoop()
        Task { await loadAgents() }
    }

    func loadAgents(showLoading: Bool = true) async {
        guard !agentsLoading else { return }
        if showLoading { agentsLoading = true }
        defer {
            if showLoading { agentsLoading = false }
        }
        agents = await health.checkAll()
    }

    private func startAgentRefreshLoop() {
        guard agentRefreshTask == nil else { return }
        agentRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.refreshAgentsIfIdle()
            }
        }
    }

    private func refreshAgentsIfIdle() async {
        guard phase != .running, !accountRefreshInProgress, !agentsLoading else { return }
        await loadAgents(showLoading: false)
    }

    func addProject(_ path: String) {
        do {
            projects = try projectStore.addProject(path)
            selectedProject = projects.last ?? selectedProject
            newPath = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func switchAccount(_ agent: Agent) {
        guard phase != .running else { return }
        Task {
            do {
                _ = try await health.switchAccount(agent)
                await pollAccountStatus(afterSwitching: agent)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func pollAccountStatus(afterSwitching agent: Agent) async {
        accountRefreshInProgress = true
        defer { accountRefreshInProgress = false }

        // Opening a CLI login flow returns immediately; the user finishes auth in
        // Terminal/browser later. Poll so the sidebar updates automatically after
        // the credential lands instead of requiring a manual Recheck.
        for attempt in 0..<60 {
            await loadAgents()
            if let status = agents.first(where: { $0.agent == agent }),
               status.status != "auth",
               status.status != "missing",
               !status.account.isEmpty {
                return
            }
            if attempt < 59 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func startRun() {
        guard !selectedProject.isEmpty, !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        if let runReadinessIssue {
            error = runReadinessIssue
            return
        }
        error = nil
        phase = .running
        let id = runManager.start(
            project: selectedProject,
            request: request.trimmingCharacters(in: .whitespacesAndNewlines),
            roles: roles,
            config: RunConfig(maxIter: maxIter, escalateAfter: escalateAfter)
        )
        runId = id
    }

    func stopRun() {
        guard let runId else { return }
        runManager.stop(runId)
        phase = .stopped
    }
}
