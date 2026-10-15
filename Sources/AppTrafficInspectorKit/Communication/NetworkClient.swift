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
    /// Called by the connection implementation when the connection fails or is closed by the peer.
    /// `NetworkClient` sets this to replace the dead connection. Must not be invoked on a queue that
    /// `isReady` synchronises on.
    var onFailure: (() -> Void)? { get set }
    func send(_ data: Data)
    /// Tears down the underlying transport. Called before a connection is discarded.
    func cancel()
}

public extension ConnectionType {
    var onFailure: (() -> Void)? {
        get { nil }
        set {}
    }

    func cancel() {}
}

public protocol SchedulerType {
    func schedule(after interval: TimeInterval, _ block: @escaping @Sendable () -> Void)
}

/// All mutable state is confined to `stateQueue`. Packets arrive on the inspector queue while
/// connection callbacks arrive on the main queue; unsynchronised access to `buffer` corrupted
/// frames on the wire (torn `Data` values) and desynchronised the receiver's length-prefixed stream.
public final class NetworkClient: @unchecked Sendable {
    static let initialReconnectDelay: TimeInterval = 1
    static let maximumReconnectDelay: TimeInterval = 30

    private let connectionFactory: (NetService) -> ConnectionType
    private let scheduler: SchedulerType
    private var service: NetService?
    private var connection: ConnectionType?
    /// Incremented for every connection so callbacks from a discarded connection are ignored.
    private var connectionGeneration = 0
    private var reconnectDelay = NetworkClient.initialReconnectDelay
    private var reconnectScheduled = false
    private var buffer: [Data] = []
    private let bufferCapacity: Int

    private let stateQueue = DispatchQueue(label: "com.apptrafficinspector.networkClient")
    private let stateQueueKey = DispatchSpecificKey<Void>()

    public init(connectionFactory: @escaping (NetService) -> ConnectionType,
                scheduler: SchedulerType,
                bufferCapacity: Int = 64) {
        self.connectionFactory = connectionFactory
        self.scheduler = scheduler
        self.bufferCapacity = bufferCapacity
        stateQueue.setSpecific(key: stateQueueKey, value: ())
    }

    private func onStateQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            return work()
        }
        return stateQueue.sync(execute: work)
    }

    /// Uses a single connection per logical service (name+type+domain) so Bonjour reporting the same service
    /// multiple times does not open duplicate connections.
    public func setService(_ service: NetService) {
        onStateQueue {
            let key = Self.key(for: service)
            if let existing = self.service, Self.key(for: existing) == key, connection != nil {
                return
            }
            self.service = service
            reconnectDelay = Self.initialReconnectDelay
            connect()
        }
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
        onStateQueue {
            enqueue(frame)
            flushIfReadyLocked()
        }
    }

    public func flushIfReady() {
        onStateQueue { flushIfReadyLocked() }
    }

    /// Drops the current service and connection so that the next `setService` call — even for the
    /// same logical service — creates a fresh connection. Call this when the remote service
    /// disappears (e.g. the receiver app quits) so the kit reconnects automatically when the
    /// receiver relaunches.
    public func clearService() {
        onStateQueue {
            service = nil
            discardConnection()
        }
    }

    // MARK: - State-queue only

    private static func key(for service: NetService) -> String {
        "\(service.name).\(service.type).\(service.domain)"
    }

    private func connect() {
        guard let service else { return }
        discardConnection()
        connectionGeneration += 1
        let generation = connectionGeneration
        var conn = connectionFactory(service)
        conn.onReady = { [weak self] in
            self?.onStateQueue {
                guard let self, generation == self.connectionGeneration else { return }
                DevLogger.logError(message: "Connected to service: \(service.hostName ?? service.name)")
                DevLogger.logError(message: "Connection ready – flushing \(self.buffer.count) buffered frame(s)")
                self.reconnectDelay = Self.initialReconnectDelay
                self.flushIfReadyLocked()
            }
        }
        conn.onFailure = { [weak self] in
            self?.onStateQueue {
                guard let self, generation == self.connectionGeneration else { return }
                self.handleConnectionFailure()
            }
        }
        connection = conn
        // The connection may already be ready before the callbacks were attached.
        flushIfReadyLocked()
    }

    private func discardConnection() {
        connectionGeneration += 1
        connection?.cancel()
        connection = nil
    }

    /// The receiver closed or reset the connection (e.g. after an undecodable frame). Bonjour does
    /// not report the still-advertised service again, so reconnect explicitly with backoff.
    private func handleConnectionFailure() {
        discardConnection()
        guard service != nil, !reconnectScheduled else { return }
        reconnectScheduled = true
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, Self.maximumReconnectDelay)
        DevLogger.logError(message: "Connection lost – reconnecting in \(delay)s")
        scheduler.schedule(after: delay) { [weak self] in
            self?.onStateQueue {
                guard let self else { return }
                self.reconnectScheduled = false
                guard self.connection == nil, self.service != nil else { return }
                self.connect()
            }
        }
    }

    private func enqueue(_ frame: Data) {
        buffer.append(frame)
        if buffer.count > bufferCapacity {
            buffer.removeFirst(buffer.count - bufferCapacity)
        }
    }

    private func flushIfReadyLocked() {
        guard let conn = connection, conn.isReady else { return }
        while !buffer.isEmpty {
            conn.send(buffer.removeFirst())
        }
    }
}
