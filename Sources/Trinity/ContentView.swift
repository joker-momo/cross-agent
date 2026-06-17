import SwiftUI

struct ContentView: View {
    @StateObject private var state = AppState()

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
        } detail: {
            WorkbenchView(state: state)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await state.loadAgents() }
                } label: {
                    Label("Recheck Agents", systemImage: "arrow.clockwise")
                }
                .disabled(state.agentsLoading)

                Button {
                    state.stopRun()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(state.phase != .running)

                Button {
                    state.startRun()
                } label: {
                    Label(state.phase == .running ? "Running" : "Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStartRun)
            }
        }
        .frame(minWidth: 1040, minHeight: 700)
        .onAppear { state.load() }
        .onReceive(state.runManager.$activeRunId) { active in
            if active == nil, state.phase == .running {
                state.phase = .stopped
            }
        }
    }

    private var canStartRun: Bool {
        state.phase != .running
            && !state.selectedProject.isEmpty
            && !state.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && state.runReadinessIssue == nil
    }
}

private struct SidebarView: View {
    @ObservedObject var state: AppState

    var body: some View {
        List {
            Section {
                BrandHeader()
                    .padding(.vertical, 4)
            }

            Section("Workspace") {
                Picker("Project", selection: $state.selectedProject) {
                    if state.projects.isEmpty {
                        Text("No projects").tag("")
                    }
                    ForEach(state.projects, id: \.self) { project in
                        Text(projectDisplayName(project)).tag(project)
                    }
                }

                HStack(spacing: 8) {
                    TextField("Add project path", text: $state.newPath)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        state.addProject(state.newPath)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(state.newPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Add project")
                }

                if !state.selectedProject.isEmpty {
                    Label(state.selectedProject, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(state.selectedProject)
                }
            }

            Section("Agents") {
                if state.agentsLoading {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking accounts...")
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(Agent.allCases) { agent in
                    AgentStatusRow(
                        agent: agent,
                        status: state.agents.first(where: { $0.agent == agent }),
                        isRunning: state.phase == .running,
                        onSwitch: { state.switchAccount(agent) }
                    )
                }
            }

            if let error = state.error {
                Section("Issue") {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Trinity")
    }

    private func projectDisplayName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}

private struct WorkbenchView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            RunSummaryBar(state: state)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RequestGroup(state: state)
                    ConfigurationGroup(state: state)
                    LiveActivityGroup(run: state.currentRun)
                }
                .padding(20)
                .frame(maxWidth: 980, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .navigationTitle("Workbench")
    }
}

private struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            AppLogoMark(size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Trinity")
                    .font(.title3.weight(.semibold))
                Text("Multi-agent orchestration")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct AppLogoMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.04, green: 0.06, blue: 0.08),
                            Color(red: 0.08, green: 0.11, blue: 0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            TriangleMark()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.20, green: 0.78, blue: 1.0),
                            Color(red: 0.04, green: 0.58, blue: 0.90)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size * 0.46, height: size * 0.48)
                .offset(y: size * 0.02)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 4, x: 0, y: 1)
        .accessibilityLabel("Trinity app logo")
    }
}

struct TriangleMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct AgentStatusRow: View {
    var agent: Agent
    var status: AgentStatus?
    var isRunning: Bool
    var onSwitch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(agent.rawValue.capitalized)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if canSwitch {
                    Button(actionTitle) {
                        onSwitch()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(isRunning)
                    .help(isRunning ? "Available when no task is running" : actionHelp)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Label(statusLabel, systemImage: statusIcon)
                    .lineLimit(1)
                Label(accountText, systemImage: "person.crop.circle")
                    .lineLimit(1)
                Label("Quota: \(quotaText)", systemImage: "chart.bar")
                    .lineLimit(2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var canSwitch: Bool {
        status?.canSwitch == true || (status?.installed == true && (agent == .claude || agent == .codex || agent == .agy))
    }

    private var actionTitle: String {
        if agent == .agy { return "Open" }
        return accountText == "Unknown account" ? "Connect" : "Switch"
    }

    private var actionHelp: String {
        agent == .agy ? "Open Antigravity" : "Change account"
    }

    private var accountText: String {
        let value = status?.account ?? ""
        return value.isEmpty ? "Unknown account" : value
    }

    private var quotaText: String {
        let value = status?.quotaRemaining ?? status?.quotaHint ?? ""
        return value.isEmpty ? "Unknown" : value
    }

    private var statusLabel: String {
        switch status?.status {
        case "ready": return "Connected"
        case "app": return "App available"
        case "missing": return "Not installed"
        case "error": return "Needs attention"
        default: return "Checking"
        }
    }

    private var statusIcon: String {
        switch status?.status {
        case "ready": return "checkmark.circle"
        case "app": return "app"
        case "missing": return "xmark.circle"
        case "error": return "exclamationmark.triangle"
        default: return "clock"
        }
    }

    private var statusColor: Color {
        switch status?.status {
        case "ready": return .green
        case "app": return .blue
        case "missing": return .red
        case "error": return .orange
        default: return .secondary
        }
    }
}

private struct RunSummaryBar: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            PhaseBadge(phase: state.phase)

            if let run = state.currentRun {
                Label("Iteration \(run.iteration)", systemImage: "arrow.triangle.2.circlepath")
                if let branch = run.branch, !branch.isEmpty {
                    Label(branch, systemImage: "arrow.branch")
                }
                if let stopReason = run.stopReason {
                    Label(stopReason.rawValue, systemImage: "flag.checkered")
                }
            } else {
                Label("No active run", systemImage: "tray")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !state.selectedProject.isEmpty {
                Label(URL(fileURLWithPath: state.selectedProject).lastPathComponent, systemImage: "folder")
                    .lineLimit(1)
                    .help(state.selectedProject)
            }
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct PhaseBadge: View {
    var phase: RunPhase

    var body: some View {
        Label(title, systemImage: icon)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
    }

    private var title: String {
        switch phase {
        case .idle: return "Idle"
        case .running: return "Running"
        case .stopped: return "Stopped"
        }
    }

    private var icon: String {
        switch phase {
        case .idle: return "circle"
        case .running: return "play.circle.fill"
        case .stopped: return "stop.circle"
        }
    }

    private var color: Color {
        switch phase {
        case .idle: return .secondary
        case .running: return .accentColor
        case .stopped: return .orange
        }
    }
}

private struct RequestGroup: View {
    @ObservedObject var state: AppState

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $state.request)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 150)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.quaternary, lineWidth: 1)
                    )
                    .disabled(state.phase == .running)

                HStack {
                    Spacer()
                    Text("\(state.request.trimmingCharacters(in: .whitespacesAndNewlines).count) chars")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Task Request", systemImage: "text.badge.plus")
        }
    }
}

private struct ConfigurationGroup: View {
    @ObservedObject var state: AppState

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    RolePicker(title: "Planner", selection: $state.roles.planner)
                    RolePicker(title: "Implementer", selection: $state.roles.implementer)
                    RolePicker(title: "Reviewer", selection: $state.roles.reviewer)
                }
                .disabled(state.phase == .running)

                Divider()

                HStack(spacing: 24) {
                    Stepper("Max iterations: \(state.maxIter)", value: $state.maxIter, in: 1...20)
                    Stepper("Escalate after: \(state.escalateAfter)", value: $state.escalateAfter, in: 1...10)
                }
                .disabled(state.phase == .running)

                if let issue = state.runReadinessIssue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Run Configuration", systemImage: "slider.horizontal.3")
        }
    }
}

private struct RolePicker: View {
    var title: String
    @Binding var selection: Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(title, selection: $selection) {
                ForEach(Agent.allCases) { agent in
                    Text(agent.rawValue.capitalized).tag(agent)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }
}

private struct LiveActivityGroup: View {
    var run: RunRecord?

    var body: some View {
        GroupBox {
            let events = run?.history ?? []
            if events.isEmpty {
                EmptyActivityState()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(events) { event in
                        RunEventRow(event: event)
                        if event.id != events.last?.id {
                            Divider()
                                .padding(.leading, 28)
                        }
                    }
                }
                .padding(.top, 2)
            }
        } label: {
            Label("Live Activity", systemImage: "list.bullet.rectangle")
        }
    }
}

private struct EmptyActivityState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No activity yet")
                .font(.headline)
        }
    }
}

private struct RunEventRow: View {
    var event: RunEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(kindTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let iteration = event.iteration {
                        Text("Iteration \(iteration)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if event.approved == true {
                        Text("Approved")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    } else if event.approved == false {
                        Text("Needs work")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
                Text(event.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }

    private var icon: String {
        switch event.kind {
        case .state: return "arrowtriangle.right.fill"
        case .log: return "circle.fill"
        case .verdict: return event.approved == true ? "checkmark.circle.fill" : "xmark.circle.fill"
        case .stop: return "square.fill"
        }
    }

    private var color: Color {
        switch event.kind {
        case .state: return .accentColor
        case .log: return .secondary
        case .verdict: return event.approved == true ? .green : .red
        case .stop: return .orange
        }
    }

    private var kindTitle: String {
        switch event.kind {
        case .state: return "State"
        case .log: return "Log"
        case .verdict: return "Verdict"
        case .stop: return "Stop"
        }
    }
}
