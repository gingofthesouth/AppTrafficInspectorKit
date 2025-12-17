import Foundation
import Testing
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

        waitUntil(1.0) { sink.events.count >= 3 }

        #expect(sink.events.count >= 3)
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

        waitUntil(1.0) { sink.events.contains { $0.kind == .finish } }

        let datas = sink.events.compactMap { event -> Data? in
            if case let .data(d) = event.kind { return d } else { return nil }
        }
        let joined = Data(datas.flatMap { Array($0) })
        #expect(joined.count == 3)
    }
}

private func waitUntil(_ timeout: TimeInterval, predicate: @escaping () -> Bool) {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if predicate() { return }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}
