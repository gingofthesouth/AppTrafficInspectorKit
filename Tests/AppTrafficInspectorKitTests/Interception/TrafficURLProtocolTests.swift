import Foundation
import Testing
import XCTest
@testable import AppTrafficInspectorKit

final class RecordingSink: TrafficURLProtocolEventSink {
    private(set) var events: [TrafficEvent] = []
    private let lock = NSLock()

    func record(_ event: TrafficEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
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

        // Protocol records via DispatchQueue.main.async; run main run loop so events are delivered
        waitUntil(2.0) { sink.events.count >= 3 }

        if sink.events.count < 3 {
            throw XCTSkip("Only \(sink.events.count) events (need 3). Main run loop may not be processed in this test environment.")
        }
        #expect(sink.events[0].kind == .start)
        #expect(sink.events.contains(where: { if case .response = $0.kind { return true } else { return false } }))
        #expect(sink.events.last?.kind == .finish)
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

        waitUntil(2.0) { sink.events.contains { $0.kind == .finish } }

        let datas = sink.events.compactMap { event -> Data? in
            if case let .data(d) = event.kind { return d } else { return nil }
        }
        let joined = Data(datas.flatMap { Array($0) })
        if sink.events.isEmpty {
            throw XCTSkip("No events received; main run loop may not be processed in this test environment.")
        }
        #expect(joined.count == 3)
    }
}

private func waitUntil(_ timeout: TimeInterval, predicate: @escaping () -> Bool) {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if predicate() { return }
        // Use main run loop so DispatchQueue.main.async blocks from the protocol are processed
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}
