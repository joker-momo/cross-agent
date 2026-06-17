import Foundation

struct AgentCommandBuilder {
    static func build(agent: Agent, role: Role, prompt: String, schemaPath: String? = nil) -> [String] {
        let needsEdit = role == .planner || role == .implementer
        let needsJSON = role == .reviewer

        switch agent {
        case .claude:
            var command = ["claude", "-p", prompt]
            if needsEdit {
                command += ["--permission-mode", "acceptEdits"]
            }
            if needsJSON {
                command += ["--output-format", "json"]
            }
            return command
        case .codex:
            var command = ["codex", "exec", prompt]
            if needsEdit {
                command += ["--sandbox", "workspace-write"]
            }
            if needsJSON, let schemaPath {
                command += ["--output-schema", schemaPath]
            }
            return command
        case .agy:
            var command = ["agy", "-p", prompt, "--yes"]
            if needsJSON {
                command += ["--output-format", "json"]
            }
            return command
        }
    }
}

final class AgentRunner {
    private let shell: ShellRunning

    init(shell: ShellRunning = Shell()) {
        self.shell = shell
    }

    func run(agent: Agent, role: Role, prompt: String, cwd: URL, timeout: TimeInterval) async throws -> ProcessResult {
        let command = AgentCommandBuilder.build(agent: agent, role: role, prompt: prompt)
        let result = try await shell.run(command, cwd: cwd, timeout: timeout)
        if !result.ok {
            throw ShellError.nonZero(result)
        }
        return result
    }
}
