import Foundation
import Testing
@testable import AppTrafficInspectorKit

@Suite("DevLogger")
struct DevLoggerTests {
    @Test
    func logErrorWithErrorIsCallableWithoutCrashing() {
        struct TestError: Error { let message = "test" }
        DevLogger.logError(TestError())
        // If we get here without crashing, the API is callable (no-op in Release, logs in DEV).
    }

    @Test
    func logErrorWithMessageIsCallableWithoutCrashing() {
        DevLogger.logError(message: "test message")
        // If we get here without crashing, the API is callable.
    }
}
