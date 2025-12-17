import Foundation
import Testing
@testable import AppTrafficInspectorKit

@Suite("RequestInfo Codable")
struct RequestInfoCodableTests {
    @Test
    func encodesStatusCodeAsNumber_andDecodesFromNumberOrString() throws {
        let info = RequestInfo(
            url: URL(string: "https://example.com/path")!,
            requestHeaders: ["Accept":"application/json"],
            requestBody: Data([1,2,3]),
            requestMethod: "POST",
            responseHeaders: ["Content-Type":"application/json"],
            responseData: Data([4,5,6]),
            statusCode: 201,
            startDate: Date(timeIntervalSince1970: 1_700_000_100),
            endDate: Date(timeIntervalSince1970: 1_700_000_200)
        )

        let data = try PacketJSON.encoder.encode(info)
        // Ensure statusCode encoded as number, not string
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["statusCode"] as? Int == 201)

        // Decoding from string value should also succeed
        let jsonWithString = """
        {
          "url":"https://example.com/path",
          "requestHeaders":{"Accept":"application/json"},
          "requestBody":"AQID",
          "requestMethod":"POST",
          "responseHeaders":{"Content-Type":"application/json"},
          "responseData":"BAUG",
          "statusCode":"404",
          "startDate":1700000100,
          "endDate":1700000200
        }
        """.data(using: .utf8)!

        let decoded = try PacketJSON.decoder.decode(RequestInfo.self, from: jsonWithString)
        #expect(decoded.statusCode == 404)
    }
}

@Suite("RequestPacket Codable")
struct RequestPacketCodableTests {
    @Test
    func roundTripsWithConfiguredStrategies() throws {
        let info = RequestInfo(
            url: URL(string: "https://example.com")!,
            requestHeaders: ["X":"Y"],
            requestBody: Data([9,9]),
            requestMethod: "GET",
            responseHeaders: nil,
            responseData: nil,
            statusCode: nil,
            startDate: Date(timeIntervalSince1970: 1_700_123_456),
            endDate: nil
        )
        let packet = RequestPacket(
            packetId: "pid-1",
            requestInfo: info,
            project: ProjectInfo(projectName: "MyApp"),
            device: DeviceInfo(deviceId: "dev-1", deviceName: "iPhone", deviceDescription: "iOS 18.0")
        )

        let data = try PacketJSON.encoder.encode(packet)
        let decoded = try PacketJSON.decoder.decode(RequestPacket.self, from: data)
        #expect(decoded == packet)
    }
}
