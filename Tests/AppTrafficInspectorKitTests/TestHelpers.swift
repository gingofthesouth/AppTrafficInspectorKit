import Foundation
@testable import AppTrafficInspectorKit

final class CollectingConnection: ConnectionType {
    var isReady: Bool = true
    var onReady: (() -> Void)?
    var frames: [Data] = []
    func send(_ data: Data) { frames.append(data) }
}

final class RecordingScheduler: SchedulerType {
    private(set) var scheduled: [(TimeInterval, @Sendable () -> Void)] = []
    func schedule(after interval: TimeInterval, _ block: @escaping @Sendable () -> Void) {
        scheduled.append((interval, block))
        // Execute immediately in tests
        block()
    }
}

final class FilteringDelegate: TrafficInspectorDelegate {
    var shouldFilter: Bool = false
    var callCount: Int = 0

    func trafficInspector(_ inspector: TrafficInspector, willSend packet: RequestPacket) -> RequestPacket? {
        callCount += 1
        return shouldFilter ? nil : packet
    }
}

/// Delegate that re-enters record() from willSend to verify no deadlock.
final class ReentrantDelegate: TrafficInspectorDelegate {
    var didReenter = false

    func trafficInspector(_ inspector: TrafficInspector, willSend packet: RequestPacket) -> RequestPacket? {
        if !didReenter {
            didReenter = true
            let url = URL(string: "https://reentrant.test/inner")!
            inspector.record(TrafficEvent(url: url, kind: .start(requestMethod: "GET", requestHeaders: [:], requestBody: nil)))
            inspector.record(TrafficEvent(url: url, kind: .finish))
        }
        return packet
    }
}

func makeDummyService() -> NetService {
    NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Mac", port: 43435)
}
