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
                .disabled(state.agentsLoading || state.accountRefreshInProgress)

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

/// A titled content card with a soft material background — the standard
/// container for Workbench sections (Mac-native, HIG-aligned).
private struct LabeledCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
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

                if state.accountRefreshInProgress {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for account...")
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(Agent.allCases) { agent in
                    AgentStatusRow(
                        agent: agent,
                        status: state.agents.first(where: { $0.agent == agent }),
                        isRunning: state.phase == .running || state.accountRefreshInProgress,
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(agent.rawValue.capitalized)
                        .font(.subheadline.weight(.semibold))
                    StatusBadge(title: statusLabel, color: statusColor)
                }
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

            VStack(alignment: .leading, spacing: 8) {
                AccountLine(account: accountText, plan: planText)
                QuotaBreakdown(text: quotaText)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary.opacity(0.7), lineWidth: 1)
        )
        .padding(.vertical, 3)
    }

    private var canSwitch: Bool {
        status?.canSwitch == true || (status?.installed == true && (agent == .claude || agent == .codex || agent == .agy))
    }

    private var actionTitle: String {
        if status?.status == "auth" { return "Connect" }
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

    private var planText: String {
        status?.plan ?? ""
    }

    private var statusLabel: String {
        switch status?.status {
        case "ready": return "Connected"
        case "auth": return "Sign in required"
        case "app": return "App available"
        case "missing": return "Not installed"
        case "error": return "Needs attention"
        default: return "Checking"
        }
    }

    private var statusIcon: String {
        switch status?.status {
        case "ready": return "checkmark.circle"
        case "auth": return "person.badge.key"
        case "app": return "app"
        case "missing": return "xmark.circle"
        case "error": return "exclamationmark.triangle"
        default: return "clock"
        }
    }

    private var statusColor: Color {
        switch status?.status {
        case "ready": return .green
        case "auth": return .orange
        case "app": return .blue
        case "missing": return .red
        case "error": return .orange
        default: return .secondary
        }
    }
}

private struct StatusBadge: View {
    var title: String
    var color: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(.quaternary.opacity(0.55))
            )
            .lineLimit(1)
    }
}

private struct AccountLine: View {
    var account: String
    var plan: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.tertiary)
            if !plan.isEmpty {
                Text(plan)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(account)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary.opacity(0.45))
        )
        .accessibilityLabel(plan.isEmpty ? account : "\(plan), \(account)")
    }
}

private struct QuotaBreakdown: View {
    var text: String

    private var items: [QuotaItem] {
        QuotaItem.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                QuotaUsageRow(item: item)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.28))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Quota")
    }
}

private struct QuotaUsageRow: View {
    var item: QuotaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.windowLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(item.percentText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(percentColor)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            if let percent = item.remainingPercent {
                QuotaMeter(percent: percent)
            }

            if item.reset != nil {
                Text(item.resetDisplay)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 1)
    }

    private var percentColor: Color {
        guard let percent = item.remainingPercent else { return .secondary }
        switch percent {
        case 0...10: return .red
        case 11...30: return .orange
        default: return .secondary
        }
    }
}

private struct QuotaMeter: View {
    var percent: Int

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(fillColor)
                    .frame(width: geometry.size.width * CGFloat(clampedPercent) / 100)
            }
        }
        .frame(height: 4)
        .accessibilityLabel("Quota remaining")
        .accessibilityValue("\(clampedPercent)%")
    }

    private var clampedPercent: Int {
        min(max(percent, 0), 100)
    }

    private var fillColor: Color {
        switch clampedPercent {
        case 0...10: return .red
        case 11...30: return .orange.opacity(0.9)
        default: return .accentColor.opacity(0.72)
        }
    }
}

private struct QuotaItem: Identifiable {
    var primary: String
    var reset: String?

    var id: String {
        primary + "|" + (reset ?? "")
    }

    static func parse(_ text: String) -> [QuotaItem] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "Unknown" else {
            return [QuotaItem(primary: "Unknown", reset: nil)]
        }

        return trimmed
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { part in
                parsePart(String(part).trimmingCharacters(in: .whitespacesAndNewlines))
            }
    }

    private static func parsePart(_ text: String) -> QuotaItem {
        for separator in [", resets ", " resets "] {
            if let range = text.range(of: separator) {
                let primary = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let resetValue = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return QuotaItem(primary: primary, reset: resetValue.hasPrefix("resets ") ? resetValue : "resets \(resetValue)")
            }
        }
        return QuotaItem(primary: text, reset: nil)
    }

    var windowLabel: String {
        let tokens = primary.split(separator: " ").map(String.init)
        guard let percentIndex = tokens.firstIndex(where: { $0.contains("%") }) else {
            return "Usage"
        }
        let label = tokens[..<percentIndex].joined(separator: " ")
        return label.isEmpty ? "Quota" : label
    }

    var percentText: String {
        if let percent = remainingPercent { return "\(percent)%" }
        return primary
    }

    var resetDisplay: String {
        guard let reset else { return "" }
        if reset.hasPrefix("resets ") {
            let value = String(reset.dropFirst("resets ".count))
            return "Reset \(value)"
        }
        return reset
    }

    var remainingPercent: Int? {
        primary
            .split(separator: " ")
            .compactMap { token -> Int? in
                let value = token.trimmingCharacters(in: CharacterSet(charactersIn: "%,"))
                return token.contains("%") ? Int(value) : nil
            }
            .first
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
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
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
        LabeledCard(title: "Task Request", systemImage: "text.badge.plus") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $state.request)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 150)
                    .padding(8)
                    .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if state.request.isEmpty {
                            Text("e.g. Add OAuth login to the settings page, with tests.")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    )
                    .disabled(state.phase == .running)

                HStack {
                    Text("Describe the change for the agents to plan, implement, and review.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(state.request.trimmingCharacters(in: .whitespacesAndNewlines).count) chars")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct ConfigurationGroup: View {
    @ObservedObject var state: AppState

    var body: some View {
        LabeledCard(title: "Run Configuration", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    RolePicker(title: "Planner", systemImage: "map", selection: $state.roles.planner)
                    RolePicker(title: "Implementer", systemImage: "hammer", selection: $state.roles.implementer)
                    RolePicker(title: "Reviewer", systemImage: "checkmark.seal", selection: $state.roles.reviewer)
                }
                .disabled(state.phase == .running)

                Divider()

                HStack(spacing: 24) {
                    Stepper("Max iterations: \(state.maxIter)", value: $state.maxIter, in: 1...20)
                    Stepper("Escalate after: \(state.escalateAfter)", value: $state.escalateAfter, in: 1...10)
                    Spacer()
                }
                .disabled(state.phase == .running)

                if let issue = state.runReadinessIssue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct RolePicker: View {
    var title: String
    var systemImage: String
    @Binding var selection: Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Picker(title, selection: $selection) {
                ForEach(Agent.allCases) { agent in
                    Text(agent.rawValue.capitalized).tag(agent)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LiveActivityGroup: View {
    var run: RunRecord?

    var body: some View {
        LabeledCard(title: "Live Activity", systemImage: "list.bullet.rectangle") {
            let events = run?.history ?? []
            if events.isEmpty {
                EmptyActivityState()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
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
            }
        }
    }
}

private struct EmptyActivityState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.tertiary)
            Text("No activity yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Run a task to watch the plan → implement → review loop here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
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
