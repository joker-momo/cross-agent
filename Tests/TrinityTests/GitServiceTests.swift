import XCTest
@testable import Trinity

final class GitServiceTests: XCTestCase {
    func testSlugify() {
        let git = GitService()
        XCTAssertEqual(git.slugify("Fix Account Switch Button!!"), "fix-account-switch-button")
        XCTAssertEqual(git.slugify("___"), "task")
    }
}
