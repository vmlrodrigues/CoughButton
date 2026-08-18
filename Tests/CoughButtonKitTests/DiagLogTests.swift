import XCTest
@testable import CoughButtonKit

/// `COUGHBUTTON_LOG_DIR` is what keeps the test suite from writing real-looking
/// diagnostic lines into the user's actual log — `make test` sets it to a fresh
/// temp directory. This confirms `DiagLog` honours the override; the Makefile
/// is what makes it apply during a real run.
final class DiagLogTests: XCTestCase {

    func testDirectoryHonoursEnvironmentOverride() {
        guard let override = ProcessInfo.processInfo.environment["COUGHBUTTON_LOG_DIR"] else {
            XCTFail("expected COUGHBUTTON_LOG_DIR to be set while running tests")
            return
        }
        XCTAssertEqual(DiagLog.directory.path, override)
    }

    func testWriteLandsInTheOverriddenDirectoryNotTheRealOne() throws {
        let realDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CoughButton", isDirectory: true)
        let realFile = realDirectory.appendingPathComponent("coughbutton.log")
        func size(_ url: URL) -> Int {
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        }
        let before = size(realFile)

        let marker = "TEST-MARKER-\(UUID().uuidString)"
        DiagLog.write(marker)

        // DiagLog writes asynchronously on its own queue; give it a moment.
        let expectation = XCTestExpectation(description: "log write settles")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(before, size(realFile), "the real log must be untouched by a test run")

        let contents = try String(contentsOf: DiagLog.fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains(marker), "the write should have landed in the overridden directory instead")
    }
}
