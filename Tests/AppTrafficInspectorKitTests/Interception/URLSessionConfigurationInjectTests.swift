import Foundation
import Testing
@testable import AppTrafficInspectorKit

@Suite("URLSessionConfiguration Inject")
struct URLSessionConfigurationInjectTests {
    @MainActor @Test
    func prependsTrafficURLProtocol_toDefaultAndEphemeral() throws {
        // The injector is expected to be safe/idempotent.
        URLSessionConfigurationInjector.install()
        URLSessionConfigurationInjector.install()
        #expect(URLProtocol.registerClass(TrafficURLProtocol.self))
    }
}
