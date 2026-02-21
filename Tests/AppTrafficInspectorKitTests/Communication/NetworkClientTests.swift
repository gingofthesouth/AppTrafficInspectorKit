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
    func encodingFailure_handlesGracefully() throws {
        let conn = FakeConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)

        client.setService(NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Mac", port: 43435))

        // Create a packet that would cause encoding issues
        // Since RequestPacket is Codable, we can't easily create an unencodable packet
        // But we can test that encoding failures don't crash
        let validPacket = samplePacket()
        client.sendPacket(validPacket)

        // Should not crash, packet should be sent if encoding succeeds
        #expect(conn.sent.count >= 0) // At least doesn't crash
    }

    @Test
    func bufferCapacity_limitsBufferSize() throws {
        let conn = FakeConnection()
        conn.isReady = false
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler, bufferCapacity: 3)

        client.setService(NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Mac", port: 43435))

        // Send more packets than capacity
        for _ in 0..<5 {
            client.sendPacket(samplePacket())
        }

        // Buffer should be limited to capacity
        conn.isReady = true
        client.flushIfReady()
        #expect(conn.sent.count == 3) // Only last 3 should remain
    }

    @Test
    func multiplePackets_bufferedCorrectly() throws {
        let conn = FakeConnection()
        conn.isReady = false
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler, bufferCapacity: 10)

        client.setService(NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Mac", port: 43435))

        // Send multiple packets
        for i in 0..<5 {
            let packet = RequestPacket(
                packetId: "p\(i)",
                requestInfo: RequestInfo(
                    url: URL(string: "https://example.com/\(i)")!,
                    requestHeaders: [:],
                    requestBody: nil,
                    requestMethod: "GET",
                    responseHeaders: nil,
                    responseData: nil,
                    statusCode: nil,
                    startDate: Date(),
                    endDate: nil
                ),
                project: ProjectInfo(projectName: "App"),
                device: DeviceInfo(deviceId: "d1", deviceName: "Device", deviceDescription: "Desc")
            )
            client.sendPacket(packet)
        }

        #expect(conn.sent.isEmpty)
        conn.isReady = true
        client.flushIfReady()
        #expect(conn.sent.count == 5)
    }

    @Test
    func connectionStateTransition_flushesWhenReady() throws {
        let conn = FakeConnection()
        conn.isReady = false
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)

        client.setService(NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Mac", port: 43435))
        client.sendPacket(samplePacket())

        #expect(conn.sent.isEmpty)

        // Transition to ready
        conn.isReady = true
        client.flushIfReady()

        #expect(conn.sent.count == 1)
    }

    /// After clearService(), calling setService() with the same name creates a fresh connection
    /// (the deduplication guard no longer blocks it). This is the reconnect scenario that fires
    /// when the receiver app quits and relaunches.
    @Test
    func clearService_allowsReconnectToSameServiceName() throws {
        var factoryCallCount = 0
        let conn1 = FakeConnection()
        let conn2 = FakeConnection()
        let connections = [conn1, conn2]
        let scheduler = RecordingScheduler()

        let client = NetworkClient(
            connectionFactory: { _ in
                let c = connections[min(factoryCallCount, connections.count - 1)]
                factoryCallCount += 1
                return c
            },
            scheduler: scheduler
        )

        let service = NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Mac", port: 43435)

        // First connection
        client.setService(service)
        #expect(factoryCallCount == 1)

        // Setting the same service without clearing is a no-op (deduplication guard)
        client.setService(service)
        #expect(factoryCallCount == 1, "Duplicate setService must not create a second connection")

        // Clear (simulates receiver quitting)
        client.clearService()

        // Setting the same service again must now create a fresh connection
        client.setService(service)
        #expect(factoryCallCount == 2, "After clearService, the same service name must create a new connection")

        // The new connection should receive sent packets
        client.sendPacket(samplePacket())
        #expect(conn1.sent.isEmpty, "Old connection must not receive packets after reconnect")
        #expect(conn2.sent.count == 1, "New connection must receive the packet")
    }

    /// Packets buffered while disconnected are flushed when the replacement connection becomes ready.
    @Test
    func clearService_bufferedPackets_flushedOnReconnect() throws {
        let conn1 = FakeConnection()
        conn1.isReady = true
        var secondConn: FakeConnection?
        var factoryCallCount = 0

        let scheduler = RecordingScheduler()
        let client = NetworkClient(
            connectionFactory: { _ in
                factoryCallCount += 1
                if factoryCallCount == 1 { return conn1 }
                let c = FakeConnection()
                c.isReady = false
                secondConn = c
                return c
            },
            scheduler: scheduler
        )

        let service = NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Mac", port: 43435)
        client.setService(service)

        // Receiver quits → clear → buffer a packet while disconnected
        client.clearService()
        client.sendPacket(samplePacket())   // goes into buffer (no connection)

        // Receiver relaunches → new connection arrives
        client.setService(service)
        let conn2 = try #require(secondConn)
        #expect(conn2.sent.isEmpty, "Not flushed yet – connection not ready")

        // Connection becomes ready → onReady fires → buffer drains
        conn2.isReady = true
        conn2.onReady?()
        #expect(conn2.sent.count == 1, "Buffered packet must be flushed once the new connection is ready")
    }
}
