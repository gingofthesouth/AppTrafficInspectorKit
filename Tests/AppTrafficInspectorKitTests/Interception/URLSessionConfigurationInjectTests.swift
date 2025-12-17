import Foundation
import Testing
@testable import AppTrafficInspectorKit

@Suite("URLSessionConfiguration Inject")
struct URLSessionConfigurationInjectTests {
    @MainActor @Test
    func prependsTrafficURLProtocol_toDefaultAndEphemeral() throws {
        URLSessionConfigurationInjector.install()

        let d = URLSessionConfiguration.default
        let e = URLSessionConfiguration.ephemeral

        #expect(d.protocolClasses?.first is TrafficURLProtocol.Type)
        #expect(e.protocolClasses?.first is TrafficURLProtocol.Type)
    }
}
