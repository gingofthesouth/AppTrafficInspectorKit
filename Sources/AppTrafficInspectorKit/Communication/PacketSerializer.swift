//
// AppTrafficInspectorKit
// Copyright 2025 Ernest Cunningham
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// This project is inspired by and based on the architecture of Bagel
// (https://github.com/yagiz/Bagel), Copyright (c) 2018 Bagel.
//

import Foundation

public enum PacketSerializer {
    public static func makeFrame(payload: Data) -> Data {
        var buffer = Data(capacity: 8 + payload.count)
        var lengthBE = UInt64(payload.count).bigEndian
        withUnsafeBytes(of: &lengthBE) { rawPtr in
            buffer.append(contentsOf: rawPtr)
        }
        buffer.append(payload)
        return buffer
    }
}

public final class PacketFramer {
    private var buffer = Data()

    public init() {}

    public func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []

        while buffer.count >= 8 {
            let lengthField = buffer.prefix(8)
            var len: UInt64 = 0
            lengthField.withUnsafeBytes { src in
                withUnsafeMutableBytes(of: &len) { dst in
                    dst.copyBytes(from: src)
                }
            }
            let length = UInt64(bigEndian: len)

            let totalNeeded = 8 + Int(length)
            if buffer.count < totalNeeded { break }

            let start = buffer.index(buffer.startIndex, offsetBy: 8)
            let end = buffer.index(start, offsetBy: Int(length))
            let payload = buffer[start..<end]
            frames.append(Data(payload))

            buffer.removeFirst(totalNeeded)
        }

        return frames
    }
}
