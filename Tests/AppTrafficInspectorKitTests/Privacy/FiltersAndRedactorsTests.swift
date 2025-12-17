import Foundation
import Testing
@testable import AppTrafficInspectorKit

@Suite("Filters & Redactors")
struct FiltersAndRedactorsTests {
    @MainActor @Test
    func headerRedactorMasksAuthorization() throws {
        let policy = RedactionPolicy(headerRedactor: { headers in
            var h = headers
            if h["Authorization"] != nil { h["Authorization"] = "***" }
            return h
        })

        let conn = CollectingConnection()
        let scheduler = RecordingScheduler()
        let client = NetworkClient(connectionFactory: { _ in conn }, scheduler: scheduler)

        // Use a custom inspector that applies redaction
        let inspector = TestableInspector(redaction: policy, client: client)
        // Emit events simulating a request
        inspector.record(TrafficEvent(url: URL(string: "mock://h")!, kind: .start))
        let resp = HTTPURLResponse(url: URL(string: "mock://h")!, statusCode: 200, httpVersion: nil, headerFields: ["Authorization":"secret"])!
        inspector.record(TrafficEvent(url: URL(string: "mock://h")!, kind: .response(resp)))
        inspector.record(TrafficEvent(url: URL(string: "mock://h")!, kind: .finish))

        #expect(conn.frames.count >= 2)
        // Decode last packet
        if let frame = conn.frames.last {
            let payload = Data(frame.dropFirst(8))
            let packet = try PacketJSON.decoder.decode(RequestPacket.self, from: payload)
            #expect(packet.requestInfo.responseHeaders?["Authorization"] == "***")
        }
    }
}

@MainActor
final class TestableInspector: @MainActor TrafficURLProtocolEventSink {
    private let policy: RedactionPolicy
    private let client: NetworkClient
    private var start: Date = Date()
    init(redaction: RedactionPolicy, client: NetworkClient) {
        self.policy = redaction
        self.client = client
    }
    func record(_ event: TrafficEvent) {
        switch event.kind {
        case .start:
            start = Date()
        case .response(let resp):
            var headers = (resp as? HTTPURLResponse)?.allHeaderFields as? [String:String] ?? [:]
            headers = policy.headerRedactor(headers)
            let ri = RequestInfo(url: event.url, requestHeaders: [:], requestBody: nil, requestMethod: "GET", responseHeaders: headers, responseData: nil, statusCode: 200, startDate: start, endDate: nil)
            let packet = RequestPacket(packetId: "p", requestInfo: ri, project: ProjectInfo(projectName: "App"), device: DeviceInfo(deviceId: "d", deviceName: "n", deviceDescription: "d"))
            client.sendPacket(packet)
        case .data:
            break
        case .finish:
            break
        }
    }
}
