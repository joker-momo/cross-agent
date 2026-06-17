import Foundation

enum Agent: String, CaseIterable, Codable, Identifiable {
    case claude
    case codex
    case agy

    var id: String { rawValue }
}

enum Role: String, Codable, CaseIterable {
    case planner
    case implementer
    case reviewer
}

struct Roles: Codable, Equatable {
    var planner: Agent = .claude
    var implementer: Agent = .agy
    var reviewer: Agent = .claude
}

enum RunPhase: String, Codable {
    case idle
    case running
    case stopped
}

enum RunState: String, Codable {
    case pending
    case planning
    case implementing
    case reviewing
    case done
    case stopped
}

enum StopReason: String, Codable {
    case approved
    case maxIterations = "max_iterations"
    case planRejected = "plan_rejected"
    case agentError = "agent_error"
    case verdictUnparseable = "verdict_unparseable"
    case noChanges = "no_changes"
    case cancelled
}

struct RunConfig: Codable, Equatable {
    var maxIter: Int = 5
    var escalateAfter: Int = 2
    var callTimeoutSeconds: TimeInterval = 20 * 60
}

struct AgentStatus: Identifiable, Codable, Equatable {
    var id: String { agent.rawValue }
    var agent: Agent
    var installed: Bool
    var version: String = ""
    var status: String = "missing"
    var detail: String = ""
    var account: String = ""
    var plan: String = ""
    var quotaHint: String = ""
    var quotaRemaining: String = ""
    var canSwitch: Bool = false
}

struct RunRecord: Identifiable, Codable, Equatable {
    var id: String { runId }
    var runId: String
    var project: String
    var request: String
    var roles: Roles
    var state: RunState = .pending
    var stopReason: StopReason?
    var branch: String?
    var iteration: Int = 0
    var history: [RunEvent] = []
}

struct RunEvent: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case state
        case log
        case verdict
        case stop
    }

    var id = UUID()
    var kind: Kind
    var text: String
    var approved: Bool?
    var iteration: Int?
}

struct Verdict: Codable, Equatable {
    var approved: Bool
    var blockingIssues: [String]
    var minorNotes: [String]
    var reason: String

    enum CodingKeys: String, CodingKey {
        case approved
        case blockingIssues = "blocking_issues"
        case minorNotes = "minor_notes"
        case reason
    }
}
