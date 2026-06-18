import AppKit
import SwiftUI

@main
struct TrinityApp: App {
    init() {
        if CommandLine.arguments.contains("--self-test") {
            Foundation.exit(SelfTests.run())
        }
        Self.exitIfAnotherInstanceIsRunning()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
    }

    private static func exitIfAnotherInstanceIsRunning() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.trinity.orchestrator"
        let currentPID = NSRunningApplication.current.processIdentifier
        let duplicate = NSWorkspace.shared.runningApplications.first { app in
            app.bundleIdentifier == bundleIdentifier && app.processIdentifier != currentPID
        }
        guard let duplicate else { return }
        duplicate.activate(options: [.activateAllWindows])
        Foundation.exit(0)
    }
}
