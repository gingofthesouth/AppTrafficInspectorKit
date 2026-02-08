import Foundation
import Testing
@testable import AppTrafficInspectorKit

@Suite("Integration")
struct EndToEndTests {
    @MainActor @Test
    func endToEnd_skippedUnlessEnabled() throws {
        let env = ProcessInfo.processInfo.environment["ENABLE_INTEGRATION_TESTS"]
        if env != "1" {
            return
        }
        // Placeholder: would start NWListener and assert frames received.
    }
    
    @MainActor @Test
    func fullPacketFlow_urlProtocolToInspectorToNetworkClient() throws {
        let env = ProcessInfo.processInfo.environment["ENABLE_INTEGRATION_TESTS"]
        if env != "1" {
            return
        }
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        let inspector = TrafficInspector(configuration: Configuration(), client: client)
        
        // Set inspector as event sink
        TrafficURLProtocol.eventSink = inspector
        TrafficURLProtocol.maxBodyBytes = nil
        
        // Install protocol
        URLSessionConfigurationInjector.install()
        
        // Create session and make request
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)
        let url = URL(string: "mock://host/e2e")!
        let task = session.dataTask(with: url) { _, _, _ in }
        task.resume()
        
        // Wait for events to flow through
        waitUntil(1.0) { inspector.packetsSent >= 2 }
        
        // Verify packets were sent through the full flow
        #expect(inspector.packetsSent >= 2) // start + finish at minimum
        #expect(conn.frames.count >= 2) // Should have frames from NetworkClient
        
        // Verify frames are properly formatted
        for frame in conn.frames {
            #expect(frame.count >= 8) // At least length prefix
            let lengthPrefix = frame.prefix(8)
            var len: UInt64 = 0
            lengthPrefix.withUnsafeBytes { src in
                withUnsafeMutableBytes(of: &len) { dst in dst.copyBytes(from: src) }
            }
            let length = UInt64(bigEndian: len)
            #expect(frame.count == 8 + Int(length)) // Frame should match length prefix
        }
    }
    
    @MainActor @Test
    func multiplePackets_transmittedCorrectly() throws {
        let env = ProcessInfo.processInfo.environment["ENABLE_INTEGRATION_TESTS"]
        if env != "1" {
            return
        }
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        let inspector = TrafficInspector(configuration: Configuration(), client: client)
        
        TrafficURLProtocol.eventSink = inspector
        URLSessionConfigurationInjector.install()
        
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)
        
        // Make multiple requests
        for i in 0..<3 {
            let url = URL(string: "mock://host/request\(i)")!
            let task = session.dataTask(with: url) { _, _, _ in }
            task.resume()
        }
        
        waitUntil(2.0) { inspector.packetsSent >= 6 } // 3 requests * 2 packets each (start + finish)
        
        #expect(inspector.packetsSent >= 6)
        #expect(conn.frames.count >= 6)
    }
}

private func waitUntil(_ timeout: TimeInterval, predicate: @escaping () -> Bool) {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if predicate() { return }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

