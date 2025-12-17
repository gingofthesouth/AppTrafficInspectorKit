import Foundation
import Testing
@testable import AppTrafficInspectorKit

final class CollectingConnection: ConnectionType {
    var isReady: Bool = true
    var frames: [Data] = []
    func send(_ data: Data) { frames.append(data) }
}

final class FilteringDelegate: TrafficInspectorDelegate {
    var shouldFilter: Bool = false
    var callCount: Int = 0
    
    func trafficInspector(_ inspector: TrafficInspector, willSend packet: RequestPacket) -> RequestPacket? {
        callCount += 1
        return shouldFilter ? nil : packet
    }
}

@Suite("TrafficInspector")
struct TrafficInspectorTests {
    @MainActor @Test
    func sendsPacketsOnEvents() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        let inspector = TrafficInspector(configuration: Configuration(), client: client)

        // Trigger a request via mock:// which our URLProtocol handles
        let config = URLSessionConfiguration.ephemeral
        URLSessionConfigurationInjector.install()
        let session = URLSession(configuration: config)
        let task = session.dataTask(with: URL(string: "mock://host/path")!)
        task.resume()

        wait(0.1)
        #expect(conn.frames.count >= 2) // start + response at least
    }
    
    @MainActor @Test
    func delegateFilteringDropsPacketsAndIncrementsCounter() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        let inspector = TrafficInspector(configuration: Configuration(), client: client)
        
        let filteringDelegate = FilteringDelegate()
        filteringDelegate.shouldFilter = true
        inspector.delegate = filteringDelegate
        
        let initialSent = inspector.packetsSent
        let initialDropped = inspector.packetsDropped
        let initialFrames = conn.frames.count
        
        // Directly test the sendPacket logic by calling record() which triggers sendPacket
        let testURL = URL(string: "https://example.com/test")!
        inspector.record(TrafficEvent(url: testURL, kind: .start))
        inspector.record(TrafficEvent(url: testURL, kind: .finish))
        
        // Verify delegate was called
        #expect(filteringDelegate.callCount > 0, "Delegate should be called")
        
        // Verify packet was dropped (not sent to client)
        #expect(conn.frames.count == initialFrames, "No frames should be sent when packet is filtered")
        
        // Verify packetsDropped incremented
        #expect(inspector.packetsDropped > initialDropped, "packetsDropped should increment when delegate returns nil")
        
        // Verify packetsSent did NOT increment
        #expect(inspector.packetsSent == initialSent, "packetsSent should NOT increment when packet is filtered")
    }
    
    @MainActor @Test
    func delegateModificationSendsModifiedPacket() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        let inspector = TrafficInspector(configuration: Configuration(), client: client)
        
        let modifyingDelegate = FilteringDelegate()
        modifyingDelegate.shouldFilter = false // Don't filter, just pass through
        inspector.delegate = modifyingDelegate
        
        let initialSent = inspector.packetsSent
        let initialDropped = inspector.packetsDropped
        let initialFrames = conn.frames.count
        
        // Directly test by calling record() which triggers sendPacket
        let testURL = URL(string: "https://example.com/allowed")!
        inspector.record(TrafficEvent(url: testURL, kind: .start))
        inspector.record(TrafficEvent(url: testURL, kind: .finish))
        
        // Verify delegate was called
        #expect(modifyingDelegate.callCount > 0, "Delegate should be called")
        
        // Verify packet was sent (not dropped)
        #expect(inspector.packetsSent > initialSent, "packetsSent should increment when delegate returns packet")
        #expect(inspector.packetsDropped == initialDropped, "packetsDropped should not increment when delegate returns packet")
        #expect(conn.frames.count > initialFrames, "Frames should be sent when delegate returns packet")
    }
    
    @MainActor @Test
    func noDelegateSendsOriginalPacket() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        let inspector = TrafficInspector(configuration: Configuration(), client: client)
        
        // No delegate set
        #expect(inspector.delegate == nil)
        
        let initialSent = inspector.packetsSent
        let initialDropped = inspector.packetsDropped
        let initialFrames = conn.frames.count
        
        // Directly test by calling record() which triggers sendPacket
        let testURL = URL(string: "https://example.com/no-delegate")!
        inspector.record(TrafficEvent(url: testURL, kind: .start))
        inspector.record(TrafficEvent(url: testURL, kind: .finish))
        
        // Verify packet was sent (no delegate means send original)
        #expect(inspector.packetsSent > initialSent, "packetsSent should increment when no delegate")
        #expect(inspector.packetsDropped == initialDropped, "packetsDropped should not increment when no delegate")
        #expect(conn.frames.count > initialFrames, "Frames should be sent when no delegate")
    }
}

@MainActor
private func wait(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}
