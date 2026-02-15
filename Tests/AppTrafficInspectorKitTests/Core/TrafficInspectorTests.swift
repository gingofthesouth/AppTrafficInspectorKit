import Foundation
import Testing
@testable import AppTrafficInspectorKit

final class CollectingConnection: ConnectionType {
    var isReady: Bool = true
    var onReady: (() -> Void)?
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
        client.setService(NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Test", port: 12345))
        let inspector = TrafficInspector(configuration: Configuration(), client: client)

        // Simulate the event stream the URLProtocol would emit for a request (start → response → finish)
        let url = URL(string: "https://example.com/path")!
        inspector.record(TrafficEvent(url: url, kind: .start))
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/plain"])!
        inspector.record(TrafficEvent(url: url, kind: .response(response)))
        inspector.record(TrafficEvent(url: url, kind: .finish))

        #expect(conn.frames.count == 3) // start + response + finish
    }

    @MainActor @Test
    func allLifecyclePacketsShareSamePacketId() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        client.setService(NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Test", port: 12345))
        let inspector = TrafficInspector(configuration: Configuration(), client: client)

        let url = URL(string: "https://example.com/path")!
        inspector.record(TrafficEvent(url: url, kind: .start))
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/plain"])!
        inspector.record(TrafficEvent(url: url, kind: .response(response)))
        inspector.record(TrafficEvent(url: url, kind: .data(Data("body".utf8))))
        inspector.record(TrafficEvent(url: url, kind: .finish))

        #expect(conn.frames.count == 3, "start, response, and finish each send one packet; .data does not")

        let packets = try decodePackets(from: conn.frames)
        #expect(packets.count == 3)

        #expect(packets[0].packetId == packets[1].packetId)
        #expect(packets[1].packetId == packets[2].packetId)
        #expect(!packets[0].packetId.isEmpty)
        #expect(UUID(uuidString: packets[0].packetId) != nil, "packetId must be a valid UUID string")
    }

    /// With requestId, two concurrent requests to the same URL are tracked separately (no overwrite in byURL).
    @MainActor @Test
    func concurrentSameURLRequestsTrackedSeparately() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        client.setService(NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Test", port: 12345))
        let inspector = TrafficInspector(configuration: Configuration(), client: client)

        let url = URL(string: "https://example.com/same")!
        let idA = UUID()
        let idB = UUID()

        // Request A: start
        inspector.record(TrafficEvent(requestId: idA, url: url, kind: .start))
        // Request B: start (same URL; would overwrite A if keyed only by URL)
        inspector.record(TrafficEvent(requestId: idB, url: url, kind: .start))

        let respA = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["X-Request": "A"])!
        let respB = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: ["X-Request": "B"])!

        inspector.record(TrafficEvent(requestId: idA, url: url, kind: .response(respA)))
        inspector.record(TrafficEvent(requestId: idB, url: url, kind: .response(respB)))
        inspector.record(TrafficEvent(requestId: idA, url: url, kind: .finish))
        inspector.record(TrafficEvent(requestId: idB, url: url, kind: .finish))

        #expect(conn.frames.count == 6)

        let packets = try decodePackets(from: conn.frames)
        #expect(packets.count == 6)
        // Order: start A, start B, response A, response B, finish A, finish B
        let packetIdA = packets[0].packetId
        let packetIdB = packets[1].packetId
        #expect(packetIdA != packetIdB)
        #expect(packets[0].packetId == packets[2].packetId && packets[2].packetId == packets[4].packetId, "request A: same packetId for start, response, finish")
        #expect(packets[1].packetId == packets[3].packetId && packets[3].packetId == packets[5].packetId, "request B: same packetId for start, response, finish")
        #expect(packets[4].requestInfo.statusCode == 200, "request A finish has status 200")
        #expect(packets[5].requestInfo.statusCode == 201, "request B finish has status 201")
    }
    
    /// Simulates what happens when stopLoading() fires a .finish without a prior .response (cancelled request).
    /// The accumulator must be removed so it does not leak.
    @MainActor @Test
    func cancelledRequestCleansUpAccumulator() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        client.setService(NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Test", port: 12345))
        let inspector = TrafficInspector(configuration: Configuration(), client: client)

        let url = URL(string: "https://example.com/cancelled")!
        let reqId = UUID()

        // Start → immediate finish (no response), simulating a cancellation
        inspector.record(TrafficEvent(requestId: reqId, url: url, kind: .start))
        inspector.record(TrafficEvent(requestId: reqId, url: url, kind: .finish))

        // start sends a packet, finish sends a packet → 2 total
        #expect(conn.frames.count == 2)

        // A duplicate .finish for the same requestId should be a no-op (accumulator already removed)
        inspector.record(TrafficEvent(requestId: reqId, url: url, kind: .finish))
        #expect(conn.frames.count == 2, "Duplicate .finish must not produce an extra packet")
    }

    @MainActor @Test
    func delegateFilteringDropsPacketsAndIncrementsCounter() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        client.setService(NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Test", port: 12345))
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
        client.setService(NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Test", port: 12345))
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
        client.setService(NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Test", port: 12345))
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
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

private func decodePackets(from frames: [Data]) throws -> [RequestPacket] {
    let framer = PacketFramer()
    return try frames.flatMap { framer.append($0) }
        .map { try PacketJSON.decoder.decode(RequestPacket.self, from: $0) }
}
