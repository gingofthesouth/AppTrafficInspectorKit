import Foundation
import Testing
@testable import AppTrafficInspectorKit

@Suite("PacketSerializer")
struct PacketSerializerTests {
    @Test
    func encodesSingleFrameWithBigEndianLength() throws {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let framed = PacketSerializer.makeFrame(payload: payload)

        #expect(framed.count == 8 + payload.count)

        let lengthPrefix = framed.prefix(8)
        var len: UInt64 = 0
        lengthPrefix.withUnsafeBytes { src in
            withUnsafeMutableBytes(of: &len) { dst in
                dst.copyBytes(from: src)
            }
        }
        let length = UInt64(bigEndian: len)
        #expect(length == 4)
        #expect(framed.suffix(4) == payload)
    }

    @Test
    func decodesMultipleConcatenatedFrames() throws {
        let frames = [
            PacketSerializer.makeFrame(payload: Data([0x01, 0x02])),
            PacketSerializer.makeFrame(payload: Data([0x03])),
            PacketSerializer.makeFrame(payload: Data([0x04, 0x05, 0x06]))
        ]
        var buffer = Data()
        frames.forEach { buffer.append($0) }

        let framer = PacketFramer()
        let out1 = framer.append(buffer)
        #expect(out1.count == 3)
        #expect(out1[0] == Data([0x01, 0x02]))
        #expect(out1[1] == Data([0x03]))
        #expect(out1[2] == Data([0x04, 0x05, 0x06]))
    }

    @Test
    func handlesFragmentationAcrossAppends() throws {
        let frame = PacketSerializer.makeFrame(payload: Data([0xAA, 0xBB, 0xCC]))

        let part1 = frame.prefix(5)
        let part2 = frame.dropFirst(5).prefix(4)
        let part3 = frame.dropFirst(9)

        let framer = PacketFramer()
        var out = framer.append(Data(part1))
        #expect(out.isEmpty)
        out = framer.append(Data(part2))
        #expect(out.isEmpty)
        out = framer.append(Data(part3))
        #expect(out.count == 1)
        #expect(out[0] == Data([0xAA, 0xBB, 0xCC]))
    }
}
