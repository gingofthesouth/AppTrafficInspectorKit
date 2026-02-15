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

public protocol ConnectionType {
    var isReady: Bool { get }
    /// Called by the connection implementation when the connection transitions to ready.
    /// `NetworkClient` sets this to flush buffered packets as soon as the connection is available.
    var onReady: (() -> Void)? { get set }
    func send(_ data: Data)
}

public protocol SchedulerType {
    func schedule(after interval: TimeInterval, _ block: @escaping @Sendable () -> Void)
}

public final class NetworkClient {
    private let connectionFactory: (NetService) -> ConnectionType
    private let scheduler: SchedulerType
    private var service: NetService?
    private var connection: ConnectionType?
    private var buffer: [Data] = []
    private let bufferCapacity: Int

    public init(connectionFactory: @escaping (NetService) -> ConnectionType,
                scheduler: SchedulerType,
                bufferCapacity: Int = 64) {
        self.connectionFactory = connectionFactory
        self.scheduler = scheduler
        self.bufferCapacity = bufferCapacity
    }

    public func setService(_ service: NetService) {
        self.service = service
        var conn = connectionFactory(service)
        conn.onReady = { [weak self] in
            DevLogger.logError(message: "Connecting to service: \(service.hostName ?? "unknown host")")
            DevLogger.logError(message: "Connection ready – flushing \(self?.buffer.count ?? 0) buffered frame(s)")
            self?.flushIfReady()
        }
        self.connection = conn
    }

    public func sendPacket(_ packet: RequestPacket) {
        let data: Data
        do {
            data = try PacketJSON.encoder.encode(packet)
        } catch {
            DevLogger.logError(message: "Failed to encode packet \(packet.packetId): \(error)")
            return
        }
        let frame = PacketSerializer.makeFrame(payload: data)
        enqueue(frame)
        flushIfReady()
    }

    private func enqueue(_ frame: Data) {
        buffer.append(frame)
        if buffer.count > bufferCapacity {
            buffer.removeFirst(buffer.count - bufferCapacity)
        }
    }

    public func flushIfReady() {
        guard let conn = connection else { return }
        guard conn.isReady else { return }
        while !buffer.isEmpty {
            let frame = buffer.removeFirst()
            conn.send(frame)
        }
    }
}
