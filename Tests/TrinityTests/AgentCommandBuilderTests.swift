import XCTest
@testable import Trinity

final class AgentCommandBuilderTests: XCTestCase {
    func testClaudeImplementerHasEditFlag() {
        let command = AgentCommandBuilder.build(agent: .claude, role: .implementer, prompt: "do x")
        XCTAssertEqual(Array(command.prefix(3)), ["claude", "-p", "do x"])
        XCTAssertTrue(command.contains("--permission-mode"))
        XCTAssertTrue(command.contains("acceptEdits"))
        XCTAssertFalse(command.contains("--output-format"))
    }

    func testCodexReviewerUsesSchema() {
        let command = AgentCommandBuilder.build(agent: .codex, role: .reviewer, prompt: "review", schemaPath: "/tmp/review.schema.json")
        XCTAssertEqual(Array(command.prefix(2)), ["codex", "exec"])
        XCTAssertTrue(command.contains("--output-schema"))
        XCTAssertTrue(command.contains("/tmp/review.schema.json"))
    }

    func testAgyAlwaysUsesYes() {
        let command = AgentCommandBuilder.build(agent: .agy, role: .implementer, prompt: "go")
        XCTAssertEqual(command.first, "agy")
        XCTAssertTrue(command.contains("--yes"))
    }
}
