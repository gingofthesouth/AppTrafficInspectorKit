import Foundation
import Testing
import XCTest

@Suite("Integration")
struct EndToEndTests {
    @Test
    func endToEnd_skippedUnlessEnabled() throws {
        let env = ProcessInfo.processInfo.environment["ENABLE_INTEGRATION_TESTS"]
        if env != "1" {
            throw XCTSkip("Skipped: set ENABLE_INTEGRATION_TESTS=1 to run.")
        }
        // Placeholder: would start NWListener and assert frames received.
    }
}
