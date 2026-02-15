import Foundation
import Testing
@testable import AppTrafficInspectorKit

@Suite("TrafficInspector")
struct TrafficInspectorTests {
    @MainActor @Test
    func sendsPacketsOnEvents() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        client.setService(makeDummyService())
        let inspector = TrafficInspector(configuration: Configuration(), client: client)

        // Trigger a request via mock:// which our URLProtocol handles
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TrafficURLProtocol.self]
        let session = URLSession(configuration: config)
        let task = session.dataTask(with: URL(string: "mock://host/path")!)
        task.resume()

        waitUntil(1.0) { conn.frames.count >= 2 }
        #expect(conn.frames.count >= 2) // start + response at least
        _ = inspector
    }
    
    /// Simulates what happens when stopLoading() fires a .finish without a prior .response (cancelled request).
    /// The accumulator must be removed so it does not leak.
    @MainActor @Test
    func cancelledRequestCleansUpAccumulator() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        client.setService(makeDummyService())
        let inspector = TrafficInspector(configuration: Configuration(), client: client)

        let url = URL(string: "https://example.com/cancelled")!

        // Start → immediate finish (no response), simulating a cancellation
        inspector.record(TrafficEvent(url: url, kind: .start(requestMethod: "GET", requestHeaders: [:], requestBody: nil)))
        inspector.record(TrafficEvent(url: url, kind: .finish))

        // start sends a packet, finish sends a packet → 2 total
        #expect(conn.frames.count == 2)

        // A duplicate .finish for the same URL should be a no-op (accumulator already removed)
        inspector.record(TrafficEvent(url: url, kind: .finish))
        #expect(conn.frames.count == 2, "Duplicate .finish must not produce an extra packet")
    }

    @MainActor @Test
    func delegateFilteringDropsPacketsAndIncrementsCounter() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        client.setService(makeDummyService())
        let inspector = TrafficInspector(configuration: Configuration(), client: client)

        let filteringDelegate = FilteringDelegate()
        filteringDelegate.shouldFilter = true
        inspector.delegate = filteringDelegate
        
        let initialSent = inspector.packetsSent
        let initialDropped = inspector.packetsDropped
        let initialFrames = conn.frames.count
        
        // Directly test the sendPacket logic by calling record() which triggers sendPacket
        let testURL = URL(string: "https://example.com/test")!
        inspector.record(TrafficEvent(url: testURL, kind: .start(requestMethod: "GET", requestHeaders: [:], requestBody: nil)))
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
        client.setService(makeDummyService())
        let inspector = TrafficInspector(configuration: Configuration(), client: client)

        let modifyingDelegate = FilteringDelegate()
        modifyingDelegate.shouldFilter = false // Don't filter, just pass through
        inspector.delegate = modifyingDelegate
        
        let initialSent = inspector.packetsSent
        let initialDropped = inspector.packetsDropped
        let initialFrames = conn.frames.count
        
        // Directly test by calling record() which triggers sendPacket
        let testURL = URL(string: "https://example.com/allowed")!
        inspector.record(TrafficEvent(url: testURL, kind: .start(requestMethod: "GET", requestHeaders: [:], requestBody: nil)))
        inspector.record(TrafficEvent(url: testURL, kind: .finish))
        
        // Verify delegate was called
        #expect(modifyingDelegate.callCount > 0, "Delegate should be called")
        
        // Verify packet was sent (not dropped)
        #expect(inspector.packetsSent > initialSent, "packetsSent should increment when delegate returns packet")
        #expect(inspector.packetsDropped == initialDropped, "packetsDropped should not increment when delegate returns packet")
        #expect(conn.frames.count > initialFrames, "Frames should be sent when delegate returns packet")
    }
    
    @MainActor @Test
    func delegateReenteringRecord_doesNotDeadlock() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        client.setService(makeDummyService())
        let inspector = TrafficInspector(configuration: Configuration(), client: client)
        let reentrantDelegate = ReentrantDelegate()
        inspector.delegate = reentrantDelegate

        let testURL = URL(string: "https://example.com/outer")!
        inspector.record(TrafficEvent(url: testURL, kind: .start(requestMethod: "GET", requestHeaders: [:], requestBody: nil)))
        inspector.record(TrafficEvent(url: testURL, kind: .finish))

        #expect(reentrantDelegate.didReenter, "Delegate should have re-entered record()")
        #expect(conn.frames.count >= 2, "Both outer and inner request packets should be sent without deadlock")
    }

    @MainActor @Test
    func noDelegateSendsOriginalPacket() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        client.setService(makeDummyService())
        let inspector = TrafficInspector(configuration: Configuration(), client: client)

        // No delegate set
        #expect(inspector.delegate == nil)
        
        let initialSent = inspector.packetsSent
        let initialDropped = inspector.packetsDropped
        let initialFrames = conn.frames.count
        
        // Directly test by calling record() which triggers sendPacket
        let testURL = URL(string: "https://example.com/no-delegate")!
        inspector.record(TrafficEvent(url: testURL, kind: .start(requestMethod: "GET", requestHeaders: [:], requestBody: nil)))
        inspector.record(TrafficEvent(url: testURL, kind: .finish))
        
        // Verify packet was sent (no delegate means send original)
        #expect(inspector.packetsSent > initialSent, "packetsSent should increment when no delegate")
        #expect(inspector.packetsDropped == initialDropped, "packetsDropped should not increment when no delegate")
        #expect(conn.frames.count > initialFrames, "Frames should be sent when no delegate")
    }
    
    @MainActor @Test
    func multipleConcurrentRequests_trackedSeparately() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        client.setService(makeDummyService())
        let inspector = TrafficInspector(configuration: Configuration(), client: client)
        
        let url1 = URL(string: "https://example.com/request1")!
        let url2 = URL(string: "https://example.com/request2")!
        let url3 = URL(string: "https://example.com/request3")!
        
        // Start multiple requests
        inspector.record(TrafficEvent(url: url1, kind: .start(requestMethod: "GET", requestHeaders: [:], requestBody: nil)))
        inspector.record(TrafficEvent(url: url2, kind: .start(requestMethod: "POST", requestHeaders: ["Content-Type": "application/json"], requestBody: Data([1, 2, 3]))))
        inspector.record(TrafficEvent(url: url3, kind: .start(requestMethod: "PUT", requestHeaders: [:], requestBody: nil)))
        
        // All should send initial packets
        #expect(inspector.packetsSent >= 3)
        
        // Finish them
        inspector.record(TrafficEvent(url: url1, kind: .finish))
        inspector.record(TrafficEvent(url: url2, kind: .finish))
        inspector.record(TrafficEvent(url: url3, kind: .finish))
        
        // Should have sent packets for all three
        #expect(inspector.packetsSent >= 6) // start + finish for each
    }
    
    @MainActor @Test
    func requestMethodHeadersBody_propagatedCorrectly() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        client.setService(makeDummyService())
        let inspector = TrafficInspector(configuration: Configuration(), client: client)
        
        let testURL = URL(string: "https://example.com/api")!
        let requestHeaders = ["Authorization": "Bearer token123", "Content-Type": "application/json"]
        let requestBody = Data([0x7B, 0x22, 0x6B, 0x65, 0x79, 0x22, 0x3A, 0x22, 0x76, 0x61, 0x6C, 0x75, 0x65, 0x22, 0x7D]) // {"key":"value"}
        
        inspector.record(TrafficEvent(url: testURL, kind: .start(requestMethod: "POST", requestHeaders: requestHeaders, requestBody: requestBody)))
        inspector.record(TrafficEvent(url: testURL, kind: .finish))
        
        // Verify packet was sent with correct method/headers/body
        #expect(conn.frames.count >= 2)
        
        // Decode the finish packet to verify content
        if let finishFrame = conn.frames.last {
            let payload = Data(finishFrame.dropFirst(8))
            let packet = try PacketJSON.decoder.decode(RequestPacket.self, from: payload)
            #expect(packet.requestInfo.requestMethod == "POST")
            #expect(packet.requestInfo.requestHeaders == requestHeaders)
            #expect(packet.requestInfo.requestBody == requestBody)
        }
    }
    
    @MainActor @Test
    func bodyAccumulation_acrossMultipleDataEvents() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        client.setService(makeDummyService())
        let inspector = TrafficInspector(configuration: Configuration(), client: client)
        
        let testURL = URL(string: "https://example.com/stream")!
        inspector.record(TrafficEvent(url: testURL, kind: .start(requestMethod: "GET", requestHeaders: [:], requestBody: nil)))
        
        // Send data in chunks
        let chunk1 = Data([1, 2, 3])
        let chunk2 = Data([4, 5, 6])
        let chunk3 = Data([7, 8, 9])
        
        inspector.record(TrafficEvent(url: testURL, kind: .data(chunk1)))
        inspector.record(TrafficEvent(url: testURL, kind: .data(chunk2)))
        inspector.record(TrafficEvent(url: testURL, kind: .data(chunk3)))
        
        // Finish should include all accumulated data
        inspector.record(TrafficEvent(url: testURL, kind: .finish))
        
        // Verify complete body in finish packet
        if let finishFrame = conn.frames.last {
            let payload = Data(finishFrame.dropFirst(8))
            let packet = try PacketJSON.decoder.decode(RequestPacket.self, from: payload)
            let expectedBody = chunk1 + chunk2 + chunk3
            #expect(packet.requestInfo.responseData == expectedBody)
        }
    }
    
    @MainActor @Test
    func partialPackets_sentOnStartAndResponse() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        client.setService(makeDummyService())
        let inspector = TrafficInspector(configuration: Configuration(), client: client)
        
        let testURL = URL(string: "https://example.com/partial")!
        let initialFrames = conn.frames.count
        
        // Start should send a packet
        inspector.record(TrafficEvent(url: testURL, kind: .start(requestMethod: "GET", requestHeaders: [:], requestBody: nil)))
        #expect(conn.frames.count > initialFrames)
        
        // Response should send another packet
        let response = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
        inspector.record(TrafficEvent(url: testURL, kind: .response(response)))
        let framesAfterResponse = conn.frames.count
        #expect(framesAfterResponse > initialFrames + 1)
        
        // Finish should send complete packet
        inspector.record(TrafficEvent(url: testURL, kind: .finish))
        #expect(conn.frames.count > framesAfterResponse)
    }
    
    @MainActor @Test
    func cleanupAfterFinish_removesFromByURL() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        client.setService(makeDummyService())
        let inspector = TrafficInspector(configuration: Configuration(), client: client)
        
        let testURL = URL(string: "https://example.com/cleanup")!
        
        // Start request
        inspector.record(TrafficEvent(url: testURL, kind: .start(requestMethod: "GET", requestHeaders: [:], requestBody: nil)))
        
        // Add some data
        inspector.record(TrafficEvent(url: testURL, kind: .data(Data([1, 2, 3]))))
        
        // Finish should clean up
        inspector.record(TrafficEvent(url: testURL, kind: .finish))
        
        // Verify cleanup by trying to send another packet for same URL
        // Should not accumulate (would be new request)
        let initialSent = inspector.packetsSent
        inspector.record(TrafficEvent(url: testURL, kind: .start(requestMethod: "GET", requestHeaders: [:], requestBody: nil)))
        inspector.record(TrafficEvent(url: testURL, kind: .finish))
        
        // Should have sent new packets (not accumulated with old)
        #expect(inspector.packetsSent > initialSent)
    }
    
    @MainActor @Test
    func responseHeadersAndStatusCode_extractedFromHTTPURLResponse() throws {
        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)
        client.setService(makeDummyService())
        let inspector = TrafficInspector(configuration: Configuration(), client: client)
        
        let testURL = URL(string: "https://example.com/response")!
        inspector.record(TrafficEvent(url: testURL, kind: .start(requestMethod: "GET", requestHeaders: [:], requestBody: nil)))
        
        let responseHeaders = ["Content-Type": "application/json", "X-Custom": "value"]
        let response = HTTPURLResponse(url: testURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: responseHeaders)!
        inspector.record(TrafficEvent(url: testURL, kind: .response(response)))
        inspector.record(TrafficEvent(url: testURL, kind: .finish))
        
        // Verify response headers and status code in finish packet
        if let finishFrame = conn.frames.last {
            let payload = Data(finishFrame.dropFirst(8))
            let packet = try PacketJSON.decoder.decode(RequestPacket.self, from: payload)
            #expect(packet.requestInfo.statusCode == 201)
            #expect(packet.requestInfo.responseHeaders?["Content-Type"] == "application/json")
            #expect(packet.requestInfo.responseHeaders?["X-Custom"] == "value")
        }
    }
}

@MainActor
private func waitUntil(_ timeout: TimeInterval, predicate: @escaping () -> Bool) {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if predicate() { return }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}
