import Foundation

struct ProcessResult: Equatable, Sendable {
    var code: Int32
    var stdout: String
    var stderr: String
    var command: [String]

    var ok: Bool { code == 0 }
}

enum ShellError: LocalizedError, Equatable, Sendable {
    case failedToLaunch(String)
    case nonZero(ProcessResult)

    var errorDescription: String? {
        switch self {
        case .failedToLaunch(let message):
            return message
        case .nonZero(let result):
            return "\(result.command.joined(separator: " ")) exited \(result.code): \(result.stderr)"
        }
    }
}

protocol ShellRunning: Sendable {
    func which(_ binary: String) -> String?
    func run(_ command: [String], cwd: URL?, timeout: TimeInterval?) async throws -> ProcessResult
}

final class Shell: ShellRunning, @unchecked Sendable {
    func which(_ binary: String) -> String? {
        for dir in Shell.augmentedPATH().split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(binary).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// PATH for locating + spawning agent CLIs. A GUI `.app` launched from Finder
    /// inherits only a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), which omits
    /// Homebrew, /usr/local/bin, and per-user tool dirs where claude/codex/agy
    /// actually live. We always append those common install dirs so the app finds
    /// the CLIs regardless of how it was launched.
    static func augmentedPATH(basePATH: String? = ProcessInfo.processInfo.environment["PATH"]) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let common = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.antigravity/antigravity/bin",
            "\(home)/.npm-global/bin", "\(home)/.bun/bin",
            "\(home)/.deno/bin", "\(home)/.cargo/bin",
            "/opt/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let base = (basePATH ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        var ordered: [String] = []
        for dir in base + common where !dir.isEmpty && seen.insert(dir).inserted {
            ordered.append(dir)
        }
        return ordered.joined(separator: ":")
    }

    func run(_ command: [String], cwd: URL? = nil, timeout: TimeInterval? = nil) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            try Shell.runSync(command, cwd: cwd, timeout: timeout)
        }.value
    }

    /// Thread-safe container so pipe-draining closures can hand data back without
    /// tripping Swift 6 captured-var concurrency diagnostics.
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        func set(_ data: Data) { lock.lock(); storage = data; lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return storage }
    }

    /// Synchronous run. Lives outside the async context so DispatchGroup.wait()
    /// is legal here.
    private static func runSync(_ command: [String], cwd: URL?, timeout: TimeInterval?) throws -> ProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        process.currentDirectoryURL = cwd
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        // Augment PATH so `env <cli>` resolves Homebrew / per-user tool dirs even
        // when launched from Finder with a minimal PATH.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = augmentedPATH()
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw ShellError.failedToLaunch(error.localizedDescription)
        }

        // Drain both pipes concurrently with process execution. Agent CLIs emit
        // far more than the ~64KB pipe buffer; reading only after waitUntilExit()
        // deadlocks once the child fills the buffer and blocks on write.
        let outBox = DataBox()
        let errBox = DataBox()
        let readGroup = DispatchGroup()
        let readQueue = DispatchQueue(label: "trinity.shell.read", attributes: .concurrent)
        readGroup.enter()
        readQueue.async {
            outBox.set(stdout.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }
        readGroup.enter()
        readQueue.async {
            errBox.set(stderr.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }

        let killer: DispatchWorkItem?
        if let timeout {
            let item = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            killer = item
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
        } else {
            killer = nil
        }
        process.waitUntilExit()
        killer?.cancel()
        readGroup.wait()

        let out = String(data: outBox.value, encoding: .utf8) ?? ""
        let err = String(data: errBox.value, encoding: .utf8) ?? ""
        return ProcessResult(code: process.terminationStatus, stdout: out, stderr: err, command: command)
    }
}
