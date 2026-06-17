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

    let projectStore: ProjectStore
    let health: AgentHealthService
    let runManager: RunManager

    init(
        projectStore: ProjectStore = ProjectStore(),
        health: AgentHealthService = AgentHealthService(),
        runManager: RunManager = RunManager()
    ) {
        self.projectStore = projectStore
        self.health = health
        self.runManager = runManager
    }

    var currentRun: RunRecord? {
        guard let runId else { return nil }
        return runManager.runs.first(where: { $0.runId == runId })
    }

    var runReadinessIssue: String? {
        let selectedAgents = Set([roles.planner, roles.implementer, roles.reviewer])
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
        Task { await loadAgents() }
    }

    func loadAgents() async {
        agentsLoading = true
        agents = await health.checkAll()
        agentsLoading = false
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
                await loadAgents()
            } catch {
                self.error = error.localizedDescription
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
