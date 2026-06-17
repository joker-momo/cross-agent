import SwiftUI

@main
struct TrinityApp: App {
    init() {
        if CommandLine.arguments.contains("--self-test") {
            Foundation.exit(SelfTests.run())
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
    }
}
