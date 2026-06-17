import Foundation

struct ProcessResult: Equatable {
    var code: Int32
    var stdout: String
    var stderr: String
    var command: [String]

    var ok: Bool { code == 0 }
}

enum ShellError: LocalizedError, Equatable {
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

protocol ShellRunning {
    func which(_ binary: String) -> String?
    func run(_ command: [String], cwd: URL?, timeout: TimeInterval?) async throws -> ProcessResult
}

final class Shell: ShellRunning {
    func which(_ binary: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(binary).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    func run(_ command: [String], cwd: URL? = nil, timeout: TimeInterval? = nil) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice
            process.currentDirectoryURL = cwd

            if command.count == 1 {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [command[0]]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = command
            }

            var didResume = false
            let lock = NSLock()

            func finish(_ result: Result<ProcessResult, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(with: result)
            }

            process.terminationHandler = { proc in
                let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                finish(.success(ProcessResult(code: proc.terminationStatus, stdout: out, stderr: err, command: command)))
            }

            do {
                try process.run()
            } catch {
                finish(.failure(ShellError.failedToLaunch(error.localizedDescription)))
                return
            }

            if let timeout {
                Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if process.isRunning {
                        process.terminate()
                    }
                }
            }
        }
    }
}
