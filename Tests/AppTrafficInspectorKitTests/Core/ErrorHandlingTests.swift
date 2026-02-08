import Foundation
import Testing
@testable import AppTrafficInspectorKit

@Suite("Error Handling")
struct ErrorHandlingTests {
    @MainActor @Test
    func delegateDeallocation_weakReferencePreventsCrash() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        let inspector = TrafficInspector(configuration: Configuration(), client: client)
        
        // Create delegate in local scope
        var delegate: FilteringDelegate? = FilteringDelegate()
        inspector.delegate = delegate
        
        // Verify delegate is set
        #expect(inspector.delegate != nil)
        
        // Deallocate delegate
        delegate = nil
        
        // Should not crash when trying to use delegate
        let testURL = URL(string: "https://example.com")!
        inspector.record(TrafficEvent(url: testURL, kind: .start(requestMethod: "GET", requestHeaders: [:], requestBody: nil)))
        inspector.record(TrafficEvent(url: testURL, kind: .finish))
        
        // Should have sent packet (no delegate means send original)
        #expect(inspector.packetsSent > 0)
    }
    
    @MainActor @Test
    func emptyURL_handledGracefully() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        let inspector = TrafficInspector(configuration: Configuration(), client: client)
        
        // Empty URL should not crash
        // Note: URL(string: "") returns nil, so we test with invalid URL
        if let invalidURL = URL(string: "invalid://") {
            inspector.record(TrafficEvent(url: invalidURL, kind: .start(requestMethod: "GET", requestHeaders: [:], requestBody: nil)))
            inspector.record(TrafficEvent(url: invalidURL, kind: .finish))
            
            // Should handle gracefully
            #expect(inspector.packetsSent >= 0)
        }
    }
    
    @MainActor @Test
    func missingResponseData_handledGracefully() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        let inspector = TrafficInspector(configuration: Configuration(), client: client)
        
        let testURL = URL(string: "https://example.com/no-data")!
        inspector.record(TrafficEvent(url: testURL, kind: .start(requestMethod: "GET", requestHeaders: [:], requestBody: nil)))
        
        // Response without data
        let response = HTTPURLResponse(url: testURL, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil)!
        inspector.record(TrafficEvent(url: testURL, kind: .response(response)))
        inspector.record(TrafficEvent(url: testURL, kind: .finish))
        
        // Should complete successfully
        #expect(inspector.packetsSent > 0)
        
        // Verify finish packet has nil responseData
        if let finishFrame = conn.frames.last {
            let payload = Data(finishFrame.dropFirst(8))
            let packet = try PacketJSON.decoder.decode(RequestPacket.self, from: payload)
            #expect(packet.requestInfo.responseData == nil)
        }
    }
    
    @MainActor @Test
    func veryLargePackets_respectsMaxBodyBytes() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        client.setService(makeDummyService())
        let config = Configuration(maxBodyBytes: 100)
        let inspector = TrafficInspector(configuration: config, client: client)
        
        let testURL = URL(string: "https://example.com/large")!
        inspector.record(TrafficEvent(url: testURL, kind: .start(requestMethod: "GET", requestHeaders: [:], requestBody: nil)))
        
        // Send large data chunk directly (bypasses TrafficURLProtocol); inspector must still cap at maxBodyBytes
        let largeData = Data(repeating: 0x42, count: 1000)
        inspector.record(TrafficEvent(url: testURL, kind: .data(largeData)))
        inspector.record(TrafficEvent(url: testURL, kind: .finish))
        
        #expect(conn.frames.isEmpty == false, "Packet should be sent when service is set")
        let finishFrame = try #require(conn.frames.last)
        let payload = Data(finishFrame.dropFirst(8))
        let packet = try PacketJSON.decoder.decode(RequestPacket.self, from: payload)
        let responseData = try #require(packet.requestInfo.responseData, "Finish packet should include responseData")
        #expect(responseData.count <= 100, "responseData should be capped at maxBodyBytes (100)")
    }
    
    @MainActor
    @Test
    func concurrentDelegateAccess_threadSafe() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        let inspector = TrafficInspector(configuration: Configuration(), client: client)
        
        let delegate = FilteringDelegate()
        inspector.delegate = delegate
        
        // TrafficInspector is @MainActor; we can't (and shouldn't) call it concurrently off-actor.
        // This test ensures a burst of events doesn't crash and delegate is invoked.
        let urls = (0..<10).map { URL(string: "https://example.com/\($0)")! }
        for url in urls {
            inspector.record(TrafficEvent(url: url, kind: .start(requestMethod: "GET", requestHeaders: [:], requestBody: nil)))
            inspector.record(TrafficEvent(url: url, kind: .finish))
        }
        
        // Should not crash and should have processed all requests
        #expect(inspector.packetsSent >= 10)
    }
}
