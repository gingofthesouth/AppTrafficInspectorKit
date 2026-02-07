import Foundation
import Testing
@testable import AppTrafficInspectorKit

final class RecordingSink: TrafficURLProtocolEventSink {
    private let lock = NSLock()
    private var _events: [TrafficEvent] = []

    func record(_ event: TrafficEvent) {
        lock.lock(); defer { lock.unlock() }
        _events.append(event)
    }
    
    func snapshot() -> [TrafficEvent] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }
}

@Suite("TrafficURLProtocol")
struct TrafficURLProtocolTests {
    @MainActor @Test
    func emitsStartResponseCompletion_forMockScheme() throws {
        let sink = RecordingSink()
        TrafficURLProtocol.eventSink = sink
        TrafficURLProtocol.maxBodyBytes = nil

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TrafficURLProtocol.self]
        let session = URLSession(configuration: config)

        let url = URL(string: "mock://host/path")!
        let task = session.dataTask(with: url) { _, _, _ in }
        task.resume()

        waitUntil(1.0) {
            sink.snapshot().contains { $0.kind == .finish }
        }
        let events = sink.snapshot()

        #expect(events.count >= 3)
        guard events.count >= 3 else { return }
        let firstEventKind = events[0].kind
        let isStartEvent: Bool = {
            if case .start = firstEventKind { return true } else { return false }
        }()
        #expect(isStartEvent)
        #expect(events.contains(where: { 
            if case .response = $0.kind { return true } else { return false }
        }))
        #expect(events.last?.kind == .finish)
    }

    @MainActor @Test
    func enforcesMaxBodyBytes_onResponseData() throws {
        let sink = RecordingSink()
        TrafficURLProtocol.eventSink = sink
        TrafficURLProtocol.maxBodyBytes = 3

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TrafficURLProtocol.self]
        let session = URLSession(configuration: config)

        let url = URL(string: "mock://host/body")!
        let task = session.dataTask(with: url) { _, _, _ in }
        task.resume()

        waitUntil(1.0) {
            let events = sink.snapshot()
            return events.contains { $0.kind == .finish } &&
                events.contains { if case .data = $0.kind { return true } else { return false } }
        }
        
        let events = sink.snapshot()

        let datas = events.compactMap { event -> Data? in
            if case let .data(d) = event.kind { return d } else { return nil }
        }
        let joined = Data(datas.flatMap { Array($0) })
        #expect(joined.count == 3)
    }
    
    @MainActor @Test
    func startEvent_carriesMethodHeadersBody() throws {
        let sink = RecordingSink()
        TrafficURLProtocol.eventSink = sink
        TrafficURLProtocol.maxBodyBytes = nil

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TrafficURLProtocol.self]
        let session = URLSession(configuration: config)

        var request = URLRequest(url: URL(string: "mock://host/api")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer token123", forHTTPHeaderField: "Authorization")
        request.httpBody = Data([0x7B, 0x22, 0x6B, 0x65, 0x79, 0x22, 0x3A, 0x22, 0x76, 0x61, 0x6C, 0x75, 0x65, 0x22, 0x7D]) // {"key":"value"}
        
        let task = session.dataTask(with: request) { _, _, _ in }
        task.resume()

        waitUntil(1.0) { sink.snapshot().count >= 1 }
        
        // Verify start event has correct method/headers/body
        let startEvents = sink.snapshot().filter {
            if case .start = $0.kind { return true } else { return false }
        }
        #expect(startEvents.count >= 1)
        guard let startEvent = startEvents.first else { return }
        
        if case let .start(method, headers, body) = startEvent.kind {
            #expect(method == "POST")
            #expect(headers["Content-Type"] == "application/json")
            #expect(headers["Authorization"] == "Bearer token123")
            #expect(body == request.httpBody)
        } else {
            Issue.record("Start event should contain method, headers, and body")
        }
    }
    
    @MainActor @Test
    func stopLoading_cancelsTask() throws {
        let sink = RecordingSink()
        TrafficURLProtocol.eventSink = sink
        TrafficURLProtocol.maxBodyBytes = nil

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TrafficURLProtocol.self]
        let session = URLSession(configuration: config)

        let url = URL(string: "mock://host/cancel")!
        let task = session.dataTask(with: url) { _, _, _ in }
        task.resume()
        
        // Give it a moment to start
        waitUntil(0.1) { sink.snapshot().count >= 1 }
        
        // Cancel the task (which calls stopLoading)
        task.cancel()
        
        // Wait a bit for cancellation
        waitUntil(0.5) { 
            task.state == URLSessionTask.State.canceling || task.state == URLSessionTask.State.completed 
        }
        
        // Task should be cancelled or completed
        #expect(task.state == URLSessionTask.State.canceling || task.state == URLSessionTask.State.completed)
    }
    
    @MainActor @Test
    func maxBodyBytes_enforcedOnRealRequest() throws {
        let sink = RecordingSink()
        TrafficURLProtocol.eventSink = sink
        TrafficURLProtocol.maxBodyBytes = 50

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TrafficURLProtocol.self]
        let session = URLSession(configuration: config)

        let url = URL(string: "mock://host/large")!
        let task = session.dataTask(with: url) { _, _, _ in }
        task.resume()

        waitUntil(1.0) {
            sink.snapshot().contains { $0.kind == .finish }
        }
        let events = sink.snapshot()

        // Collect all data events
        let datas = events.compactMap { event -> Data? in
            if case let .data(d) = event.kind { return d } else { return nil }
        }
        let totalData = Data(datas.flatMap { Array($0) })
        
        // Total should be limited to maxBodyBytes
        #expect(totalData.count <= 50)
    }
}

private func waitUntil(_ timeout: TimeInterval, predicate: @escaping () -> Bool) {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if predicate() { return }
        // Avoid pumping the main run loop here; yielding can interleave other tests and mutate
        // global protocol configuration (e.g. TrafficURLProtocol.maxBodyBytes).
        Thread.sleep(forTimeInterval: 0.01)
    }
}
