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
        client.setService(NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Test", port: 12345))
        let inspector = TrafficInspector(configuration: Configuration(), client: client)

        let url = URL(string: "https://example.com/path")!
        inspector.record(TrafficEvent(url: url, kind: .start))
        inspector.record(TrafficEvent(url: url, kind: .finish))

        #expect(inspector.packetsSent > 0)
    }
}
