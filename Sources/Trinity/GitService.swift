import Foundation

enum GitGuardError: LocalizedError, Equatable {
    case notRepository(String)
    case protectedBranch(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRepository(let path):
            return "\(path) is not a git repository"
        case .protectedBranch(let branch):
            return "refusing to run on protected branch '\(branch)'"
        case .commandFailed(let message):
            return message
        }
    }
}

final class GitService {
    private let shell: ShellRunning
    private let protectedBranches = Set(["main", "master"])

    init(shell: ShellRunning = Shell()) {
        self.shell = shell
    }

    func preflight(cwd: URL) async throws {
        let inside = try await git(cwd: cwd, "rev-parse", "--is-inside-work-tree")
        guard inside.ok, inside.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw GitGuardError.notRepository(cwd.path)
        }
        let branch = try await currentBranch(cwd: cwd)
        if protectedBranches.contains(branch) {
            throw GitGuardError.protectedBranch(branch)
        }
    }

    func currentBranch(cwd: URL) async throws -> String {
        let result = try await git(cwd: cwd, "rev-parse", "--abbrev-ref", "HEAD")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isDirty(cwd: URL) async throws -> Bool {
        let result = try await git(cwd: cwd, "status", "--porcelain")
        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func stash(cwd: URL, message: String = "trinity: pre-run stash") async throws {
        let result = try await git(cwd: cwd, "stash", "push", "-u", "-m", message)
        if !result.ok { throw GitGuardError.commandFailed("stash failed: \(result.stderr)") }
    }

    func createBranch(cwd: URL, slug: String) async throws -> String {
        let base = "trinity/\(slug)"
        var name = base
        var suffix = 2
        while true {
            let exists = try await git(cwd: cwd, "rev-parse", "--verify", name)
            if !exists.ok { break }
            name = "\(base)-\(suffix)"
            suffix += 1
        }
        let result = try await git(cwd: cwd, "checkout", "-b", name)
        if !result.ok { throw GitGuardError.commandFailed("branch create failed: \(result.stderr)") }
        return name
    }

    func hasChanges(cwd: URL) async throws -> Bool {
        try await isDirty(cwd: cwd)
    }

    func checkpoint(cwd: URL, message: String) async throws -> String? {
        guard try await hasChanges(cwd: cwd) else { return nil }
        _ = try await git(cwd: cwd, "add", "-A")
        let commit = try await git(cwd: cwd, "commit", "-m", message, "--no-verify")
        if !commit.ok { throw GitGuardError.commandFailed("checkpoint commit failed: \(commit.stderr)") }
        let sha = try await git(cwd: cwd, "rev-parse", "HEAD")
        return sha.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func diff(cwd: URL) async throws -> String {
        try await git(cwd: cwd, "diff").stdout
    }

    func slugify(_ text: String, maxLength: Int = 40) -> String {
        let lower = text.lowercased()
        let mapped = lower.map { char -> Character in
            if char.isASCII && char.isLetter || char.isNumber {
                return char
            }
            return "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let prefix = String(collapsed.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return prefix.isEmpty ? "task" : prefix
    }

    private func git(cwd: URL, _ args: String...) async throws -> ProcessResult {
        try await shell.run(["git"] + args, cwd: cwd, timeout: nil)
    }
}
