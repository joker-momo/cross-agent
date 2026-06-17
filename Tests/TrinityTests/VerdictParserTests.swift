import XCTest
@testable import Trinity

final class VerdictParserTests: XCTestCase {
    func testParsesBareJSON() throws {
        let verdict = try VerdictParser.parse("""
        {"approved": true, "blocking_issues": [], "minor_notes": ["ok"], "reason": "done"}
        """)
        XCTAssertTrue(verdict.approved)
        XCTAssertEqual(verdict.minorNotes, ["ok"])
    }

    func testParsesFencedJSONWithProse() throws {
        let verdict = try VerdictParser.parse("""
        Looks good.
        ```json
        {"approved": false, "blocking_issues": ["bug"], "minor_notes": [], "reason": "broken"}
        ```
        """)
        XCTAssertFalse(verdict.approved)
        XCTAssertEqual(verdict.blockingIssues, ["bug"])
    }

    func testRejectsMissingJSON() {
        XCTAssertThrowsError(try VerdictParser.parse("no verdict"))
    }
}
