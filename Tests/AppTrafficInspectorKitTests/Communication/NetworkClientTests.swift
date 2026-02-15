import Foundation
import Testing
@testable import AppTrafficInspectorKit

final class FakeConnection: ConnectionType {
    var sent: [Data] = []
    var isReady: Bool = true
    var onReady: (() -> Void)?
    var onFail: (() -> Void)?

    func send(_ data: Data) {
        sent.append(data)
    }
}

final class RecordingScheduler: SchedulerType {
    private(set) var scheduled: [(TimeInterval, () -> Void)] = []
    func schedule(after interval: TimeInterval, _ block: @escaping () -> Void) {
        scheduled.append((interval, block))
        // Execute immediately in tests
        block()
    }
}

private func samplePacket() -> RequestPacket {
    let info = RequestInfo(
        url: URL(string: "https://example.com")!,
        requestHeaders: [:],
        requestBody: nil,
        requestMethod: "GET",
        responseHeaders: nil,
        responseData: nil,
        statusCode: nil,
        startDate: Date(timeIntervalSince1970: 1_700_000_000),
        endDate: nil
    )
    return RequestPacket(
        packetId: "p1",
        requestInfo: info,
        project: ProjectInfo(projectName: "App"),
        device: DeviceInfo(deviceId: "d1", deviceName: "Device", deviceDescription: "Desc")
    )
}

@Suite("NetworkClient")
struct NetworkClientTests {
    @Test
    func framesPacketsWithLengthPrefix() throws {
        let conn = FakeConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler, bufferCapacity: 8)

        client.setService(NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Mac", port: 43435))
        client.sendPacket(samplePacket())

        #expect(conn.sent.count == 1)
        let frame = conn.sent[0]
        var len: UInt64 = 0
        frame.prefix(8).withUnsafeBytes { src in
            withUnsafeMutableBytes(of: &len) { dst in dst.copyBytes(from: src) }
        }
        let length = UInt64(bigEndian: len)
        #expect(frame.count == 8 + Int(length))
    }

    @Test
    func buffersWhenNotReady_andFlushesOnReady() throws {
        let conn = FakeConnection()
        conn.isReady = false
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler, bufferCapacity: 2)

        client.setService(NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Mac", port: 43435))
        client.sendPacket(samplePacket())
        client.sendPacket(samplePacket())
        client.sendPacket(samplePacket()) // should drop oldest due to capacity=2

        #expect(conn.sent.isEmpty)
        conn.isReady = true
        client.flushIfReady()
        #expect(conn.sent.count == 2)
    }

    @Test
    func onReadyCallbackFlushesBufferedPackets() throws {
        let conn = FakeConnection()
        conn.isReady = false
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)

        client.setService(NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Mac", port: 43435))

        // Buffer packets while connection is not ready
        client.sendPacket(samplePacket())
        client.sendPacket(samplePacket())
        #expect(conn.sent.isEmpty, "Packets should be buffered while connection is not ready")

        // Simulate connection becoming ready – fire the onReady callback
        conn.isReady = true
        conn.onReady?()

        #expect(conn.sent.count == 2, "onReady callback should flush all buffered packets")
    }
}
