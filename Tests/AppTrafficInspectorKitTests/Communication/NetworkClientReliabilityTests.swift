import Foundation
import Testing
@testable import AppTrafficInspectorKit

/// Thread-safe connection double whose lifecycle callbacks can be driven by tests.
private final class ControllableConnection: ConnectionType, @unchecked Sendable {
    private let lock = NSLock()
    private var ready: Bool
    private var sentFrames: [Data] = []
    private(set) var cancelCount = 0
    var onReady: (() -> Void)?
    var onFailure: (() -> Void)?

    init(ready: Bool = true) { self.ready = ready }

    var isReady: Bool {
        get { lock.withLock { ready } }
        set { lock.withLock { ready = newValue } }
    }

    var frames: [Data] { lock.withLock { sentFrames } }

    func send(_ data: Data) { lock.withLock { sentFrames.append(data) } }
    func cancel() { lock.withLock { cancelCount += 1 } }

    func fail() {
        isReady = false
        onFailure?()
    }
}

/// Captures scheduled work without running it so tests control when reconnects happen.
private final class ManualScheduler: SchedulerType, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(TimeInterval, @Sendable () -> Void)] = []

    var intervals: [TimeInterval] { lock.withLock { pending.map(\.0) } }

    func schedule(after interval: TimeInterval, _ block: @escaping @Sendable () -> Void) {
        lock.withLock { pending.append((interval, block)) }
    }

    func runNext() {
        let next = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        next?.1()
    }
}

private func packet(_ id: String, statusCode: Int? = nil, body: Data? = nil) -> RequestPacket {
    RequestPacket(
        packetId: id,
        requestInfo: RequestInfo(
            url: URL(string: "https://example.com/\(id)")!,
            requestHeaders: ["X-Id": id],
            requestMethod: "GET",
            responseData: body,
            statusCode: statusCode,
            startDate: Date(timeIntervalSince1970: 1_700_000_000)
        ),
        project: ProjectInfo(projectName: "App"),
        device: DeviceInfo(deviceId: "d1", deviceName: "Device", deviceDescription: "Desc")
    )
}

private func decodeFrames(_ frames: [Data]) throws -> [RequestPacket] {
    let framer = PacketFramer()
    var payloads: [Data] = []
    for frame in frames {
        payloads.append(contentsOf: framer.append(frame))
    }
    return try payloads.map { try PacketJSON.decoder.decode(RequestPacket.self, from: $0) }
}

@Suite("NetworkClient reliability")
struct NetworkClientReliabilityTests {

    @Test
    func connectionFailure_reconnectsAndFlushesBufferedPackets() throws {
        var created: [ControllableConnection] = []
        let scheduler = ManualScheduler()
        let client = NetworkClient(
            connectionFactory: { _ in
                let conn = ControllableConnection(ready: created.isEmpty)
                created.append(conn)
                return conn
            },
            scheduler: scheduler
        )
        client.setService(makeDummyService())
        client.sendPacket(packet("before"))
        #expect(created[0].frames.count == 1)

        created[0].fail()
        #expect(created[0].cancelCount == 1, "The dead connection must be cancelled")
        #expect(scheduler.intervals == [NetworkClient.initialReconnectDelay])

        client.sendPacket(packet("while-down"))
        scheduler.runNext()
        #expect(created.count == 2, "A replacement connection must be created")

        created[1].isReady = true
        created[1].onReady?()
        let delivered = try decodeFrames(created[1].frames)
        #expect(delivered.map(\.packetId) == ["while-down"])
    }

    @Test
    func repeatedFailures_backOffUntilAConnectionBecomesReady() {
        var created: [ControllableConnection] = []
        let scheduler = ManualScheduler()
        let client = NetworkClient(
            connectionFactory: { _ in
                let conn = ControllableConnection(ready: false)
                created.append(conn)
                return conn
            },
            scheduler: scheduler
        )
        client.setService(makeDummyService())

        created[0].fail()
        scheduler.runNext()
        created[1].fail()
        scheduler.runNext()
        created[2].fail()
        #expect(scheduler.intervals == [4])

        scheduler.runNext()
        created[3].isReady = true
        created[3].onReady?()
        created[3].fail()
        #expect(scheduler.intervals == [NetworkClient.initialReconnectDelay], "Backoff resets after a successful connection")
    }

    @Test
    func failureFromDiscardedConnection_isIgnored() {
        var created: [ControllableConnection] = []
        let scheduler = ManualScheduler()
        let client = NetworkClient(
            connectionFactory: { _ in
                let conn = ControllableConnection()
                created.append(conn)
                return conn
            },
            scheduler: scheduler
        )
        client.setService(makeDummyService())
        client.clearService()
        client.setService(makeDummyService())

        created[0].fail()
        #expect(scheduler.intervals.isEmpty)
        client.sendPacket(packet("current"))
        #expect(created[1].frames.count == 1)
    }

    @Test
    func clearService_doesNotReconnect() {
        var created: [ControllableConnection] = []
        let scheduler = ManualScheduler()
        let client = NetworkClient(
            connectionFactory: { _ in
                let conn = ControllableConnection()
                created.append(conn)
                return conn
            },
            scheduler: scheduler
        )
        client.setService(makeDummyService())
        client.clearService()
        #expect(created[0].cancelCount == 1)
        created[0].fail()
        #expect(scheduler.intervals.isEmpty)
        #expect(created.count == 1)
    }

    /// Regression: sends from the inspector queue raced flushes triggered by `onReady` on main,
    /// producing torn frames that the receiver could not decode.
    @Test
    func concurrentSendsAndReadyFlushes_produceOnlyIntactFrames() throws {
        let conn = ControllableConnection(ready: false)
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: ManualScheduler(), bufferCapacity: 10_000)
        client.setService(makeDummyService())

        let count = 2_000
        let body = Data(repeating: 0x7A, count: 2_048)
        DispatchQueue.concurrentPerform(iterations: count + 200) { index in
            if index < count {
                client.sendPacket(packet("p\(index)", statusCode: 200, body: body))
            } else {
                conn.isReady = index.isMultiple(of: 2)
                conn.onReady?()
            }
        }
        conn.isReady = true
        client.flushIfReady()

        let delivered = try decodeFrames(conn.frames)
        #expect(delivered.count == count)
        #expect(Set(delivered.map(\.packetId)).count == count)
    }
}

@Suite("TrafficInspector ordering")
struct TrafficInspectorOrderingTests {

    /// Holds the first packet in the delegate long enough for another thread to record later events.
    private final class SlowFirstPacketDelegate: TrafficInspectorDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        let firstPacketEntered = DispatchSemaphore(value: 0)

        func trafficInspector(_ inspector: TrafficInspector, willSend packet: RequestPacket) -> RequestPacket? {
            let isFirst = lock.withLock { calls += 1; return calls == 1 }
            if isFirst {
                firstPacketEntered.signal()
                Thread.sleep(forTimeInterval: 0.3)
            }
            return packet
        }
    }

    @Test
    func startPacketIsSentBeforeResponseAndFinishFromAnotherThread() throws {
        let conn = ControllableConnection()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: ManualScheduler())
        client.setService(makeDummyService())
        let inspector = TrafficInspector(configuration: Configuration(), client: client)
        let delegate = SlowFirstPacketDelegate()
        inspector.delegate = delegate

        let url = URL(string: "https://example.com/ordered")!
        let id = UUID()
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let done = DispatchGroup()

        DispatchQueue.global().async(group: done) {
            inspector.record(TrafficEvent(requestId: id, url: url, kind: .start(requestMethod: "GET", requestHeaders: [:], requestBody: nil)))
        }
        delegate.firstPacketEntered.wait()
        DispatchQueue.global().async(group: done) {
            inspector.record(TrafficEvent(requestId: id, url: url, kind: .response(response)))
            inspector.record(TrafficEvent(requestId: id, url: url, kind: .finish))
        }
        #expect(done.wait(timeout: .now() + 5) == .success)

        let delivered = try decodeFrames(conn.frames)
        #expect(delivered.map(\.requestInfo.statusCode) == [nil, 200, 200])
        #expect(delivered.last?.requestInfo.endDate != nil)
    }
}
