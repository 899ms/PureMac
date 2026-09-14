import Foundation
import XCTest
@testable import puremac

final class ShellTests: XCTestCase {
    func testArgumentsArePassedWithoutShellExpansion() {
        let result = Shell.run("/usr/bin/printf", ["%s", "$(echo injected); *"])

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.out, "$(echo injected); *")
        XCTAssertEqual(result.err, "")
    }

    func testMissingExecutableHasDeterministicError() {
        let path = "/path/that/does/not/exist/puremac-test"
        let result = Shell.run(path, [])

        XCTAssertEqual(result.status, 127)
        XCTAssertEqual(result.out, "")
        XCTAssertEqual(result.err, "not found: \(path)")
    }

    func testNonzeroExitWithoutStderrHasDeterministicError() {
        let result = Shell.run("/bin/sh", ["-c", "exit 7"])

        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.out, "")
        XCTAssertEqual(result.err, "command exited with status 7")
    }

    func testTimeoutTerminatesTheDirectProcess() {
        let start = Date()
        let result = Shell.run("/bin/sh", ["-c", "exec /bin/sleep 5"], timeout: 0.05)

        XCTAssertEqual(result.status, 124)
        XCTAssertEqual(result.err, "command timed out")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testBothOutputStreamsAreDrainedAndBounded() {
        let script = "/usr/bin/yes O | /usr/bin/head -c 1200000 & /usr/bin/yes E | /usr/bin/head -c 1200000 >&2 & wait"
        let result = Shell.run("/bin/sh", ["-c", script], timeout: 10)

        XCTAssertEqual(result.status, 0)
        XCTAssertLessThanOrEqual(result.out.utf8.count, Shell.outputLimit)
        XCTAssertLessThanOrEqual(result.err.utf8.count, Shell.outputLimit)
        XCTAssertTrue(result.out.hasSuffix("[output truncated]"))
        XCTAssertTrue(result.err.hasSuffix("[output truncated]"))
    }

    func testRunnerReturnsWhenDescendantKeepsPipeOpen() {
        let start = Date()
        let result = Shell.run("/bin/sh", ["-c", "/bin/sleep 2 & /usr/bin/printf done"], timeout: 1)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.out, "done")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }
}
