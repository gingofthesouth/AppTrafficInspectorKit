import Foundation
import Testing
@testable import AppTrafficInspectorKit

private struct Envelope: Codable, Equatable {
    let when: Date
    let bytes: Data
}

@Suite("PacketJSON")
struct PacketJSONTests {
    @Test
    func encoder_usesBase64ForData_andUnixEpochForDate() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let bytes = Data([0, 1, 2, 3])
        let env = Envelope(when: date, bytes: bytes)

        let data = try PacketJSON.encoder.encode(env)

        // Parse to dictionary to assert types
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["bytes"] as? String == "AAECAw==")

        // date encoded as numeric seconds since 1970 (Double)
        let seconds = object["when"] as? Double
        #expect(seconds != nil)
        #expect(abs((seconds ?? 0) - 1_700_000_000) < 0.001)
    }

    @Test
    func decoder_decodesUnixEpochSeconds() throws {
        // when as integer seconds and bytes as base64
        let json = """
        {"when":1700000000,"bytes":"AAECAw=="}
        """.data(using: .utf8)!

        let decoded = try PacketJSON.decoder.decode(Envelope.self, from: json)
        #expect(decoded.when.timeIntervalSince1970 == 1_700_000_000)
        #expect(decoded.bytes == Data([0,1,2,3]))
    }
}
