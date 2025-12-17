import Foundation
import Testing
@testable import AppTrafficInspectorKit

@Suite("Observability")
struct ObservabilityTests {
    @MainActor @Test
    func incrementsPacketsSent() {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        let inspector = TrafficInspector(configuration: Configuration(), client: client)

        let config = URLSessionConfiguration.ephemeral
        URLSessionConfigurationInjector.install()
        let session = URLSession(configuration: config)
        let task = session.dataTask(with: URL(string: "mock://host/path")!)
        task.resume()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        #expect(inspector.packetsSent > 0)
    }
}
