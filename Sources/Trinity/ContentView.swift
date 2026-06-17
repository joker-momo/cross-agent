import SwiftUI

struct ContentView: View {
    @StateObject private var state = AppState()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            AgentStatusGrid(state: state)
            HStack(alignment: .top, spacing: 16) {
                taskPanel
                liveBoard
            }
        }
        .padding(20)
        .frame(minWidth: 980, minHeight: 680)
        .onAppear { state.load() }
        .onReceive(state.runManager.$activeRunId) { active in
            if active == nil, state.phase == .running {
                state.phase = .stopped
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("△")
                .font(.title2.weight(.bold))
                .foregroundStyle(.green)
                .frame(width: 34, height: 34)
                .background(.green.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text("Trinity")
                    .font(.title2.weight(.semibold))
                Text("plan -> implement -> review, across claude / codex / agy")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var taskPanel: some View {
        Panel(title: "Task") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Project").font(.caption).foregroundStyle(.secondary)
                Picker("Project", selection: $state.selectedProject) {
                    if state.projects.isEmpty {
                        Text("no projects yet").tag("")
                    }
                    ForEach(state.projects, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()

                HStack {
                    TextField("/path/to/project", text: $state.newPath)
                    Button("Add") { state.addProject(state.newPath) }
                        .disabled(state.newPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text("Request").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $state.request)
                    .font(.body)
                    .frame(height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

                HStack {
                    rolePicker("Planner", selection: $state.roles.planner)
                    rolePicker("Implementer", selection: $state.roles.implementer)
                    rolePicker("Reviewer", selection: $state.roles.reviewer)
                }

                HStack {
                    Stepper("max iterations: \(state.maxIter)", value: $state.maxIter, in: 1...20)
                    Stepper("escalate after: \(state.escalateAfter)", value: $state.escalateAfter, in: 1...10)
                }

                HStack {
                    Button {
                        state.startRun()
                    } label: {
                        Label(state.phase == .running ? "Running" : "Run", systemImage: state.phase == .running ? "progress.indicator" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.phase == .running || state.selectedProject.isEmpty || state.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        state.stopRun()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .disabled(state.phase != .running)
                }

                if let error = state.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func rolePicker(_ title: String, selection: Binding<Agent>) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(Agent.allCases) { agent in
                    Text(agent.rawValue).tag(agent)
                }
            }
            .labelsHidden()
        }
    }

    private var liveBoard: some View {
        Panel(title: "Live board") {
            let events = state.currentRun?.history ?? []
            if events.isEmpty {
                Text("No activity yet. Start a run.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(events) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                eventIcon(event)
                                Text(event.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func eventIcon(_ event: RunEvent) -> some View {
        switch event.kind {
        case .state:
            return Image(systemName: "arrowtriangle.right.fill").foregroundStyle(.green)
        case .log:
            return Image(systemName: "circle.fill").foregroundStyle(.secondary)
        case .verdict:
            return Image(systemName: event.approved == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(event.approved == true ? .green : .red)
        case .stop:
            return Image(systemName: "square.fill").foregroundStyle(.orange)
        }
    }
}

struct AgentStatusGrid: View {
    @ObservedObject var state: AppState

    var body: some View {
        Panel(title: "Agent connections") {
            HStack {
                ForEach(Agent.allCases) { agent in
                    AgentCard(
                        agent: agent,
                        status: state.agents.first(where: { $0.agent == agent }),
                        isRunning: state.phase == .running,
                        onSwitch: { state.switchAccount(agent) }
                    )
                }
                Button {
                    Task { await state.loadAgents() }
                } label: {
                    Label("Recheck", systemImage: "arrow.clockwise")
                }
                .disabled(state.agentsLoading)
            }
        }
    }
}

struct AgentCard: View {
    var agent: Agent
    var status: AgentStatus?
    var isRunning: Bool
    var onSwitch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(agent.rawValue.capitalized)
                    .font(.headline)
                Spacer()
                if canSwitch {
                    Button(accountText == "unknown account" ? "Connect" : "Switch", action: onSwitch)
                        .disabled(isRunning)
                }
            }
            Text(statusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(accountText)
                .font(.caption)
                .lineLimit(1)
            Text("Quota: \(quotaText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var canSwitch: Bool {
        status?.canSwitch == true || (status?.installed == true && (agent == .claude || agent == .codex))
    }

    private var accountText: String {
        let value = status?.account ?? ""
        return value.isEmpty ? "unknown account" : value
    }

    private var quotaText: String {
        let value = status?.quotaRemaining ?? status?.quotaHint ?? ""
        return value.isEmpty ? "quota unknown" : value
    }

    private var statusLabel: String {
        switch status?.status {
        case "ready": return "connected"
        case "missing": return "not installed"
        case "error": return "error"
        default: return "checking..."
        }
    }

    private var statusColor: Color {
        switch status?.status {
        case "ready": return .green
        case "missing": return .red
        case "error": return .orange
        default: return .secondary
        }
    }
}

struct Panel<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }
}
