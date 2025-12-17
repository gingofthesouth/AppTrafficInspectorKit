import Foundation
import Testing
@testable import AppTrafficInspectorKit

@Suite("DebugGating")
struct DebugGatingTests {
    @Test
    func debugEnabledIsTrueInDebugBuilds() {
        #expect(appTrafficDebugEnabled)
    }
}


