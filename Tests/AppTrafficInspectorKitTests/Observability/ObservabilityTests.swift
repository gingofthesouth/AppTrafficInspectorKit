import Foundation
import Testing
@testable import AppTrafficInspectorKit

private func waitUntil(_ timeout: TimeInterval, predicate: @escaping () -> Bool) {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if predicate() { return }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

@Suite("Observability")
struct ObservabilityTests {
    @MainActor @Test
    func incrementsPacketsSent() {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        client.setService(makeDummyService())
        let inspector = TrafficInspector(configuration: Configuration(), client: client)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TrafficURLProtocol.self]
        let session = URLSession(configuration: config)
        let task = session.dataTask(with: URL(string: "mock://host/path")!)
        task.resume()
        
        waitUntil(1.0) { inspector.packetsSent > 0 }
        #expect(inspector.packetsSent > 0)
    }
}
