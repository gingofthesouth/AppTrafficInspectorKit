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
import Network

@available(iOS 12.0, macOS 10.14, *)
final class DefaultConnection: ConnectionType, @unchecked Sendable {
    private let connection: NWConnection
    private var isReadyValue = false
    private let queue = DispatchQueue(label: "com.apptrafficinspector.connection")

    /// Callback fired (on main queue) when the connection transitions to `.ready`.
    nonisolated(unsafe) var onReady: (() -> Void)?
    
    var isReady: Bool {
        queue.sync { isReadyValue }
    }
    
    init(service: NetService) {
        let serviceName = service.name
        let endpoint = NWEndpoint.service(name: service.name,
                                          type: service.type,
                                          domain: service.domain,
                                          interface: nil)
        connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                let interfaceDesc = self.connectionInterfaceDescription(connection: self.connection)
                DevLogger.logError(message: "Connection ready to \(serviceName) via \(interfaceDesc)")
                self.queue.async { self.isReadyValue = true }
                DispatchQueue.main.async { self.onReady?() }
            case .failed(let error):
                DevLogger.logError(message: "Connection failed: \(error)")
                self.queue.async { self.isReadyValue = false }
            case .cancelled:
                DevLogger.logError(message: "Connection cancelled")
                self.queue.async { self.isReadyValue = false }
            case .waiting(let error):
                DevLogger.logError(message: "Connection waiting: \(error)")
                self.queue.async { self.isReadyValue = false }
            default:
                self.queue.async { self.isReadyValue = false }
            }
        }
        connection.start(queue: queue)
    }
    
    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                DevLogger.logError(message: "Send failed: \(error)")
            }
        })
    }

    /// Returns a short description of the interface the connection is using (e.g. "interface en0 (wifi)").
    private func connectionInterfaceDescription(connection: NWConnection) -> String {
        guard let path = connection.currentPath else { return "interface unknown" }
        let interfaces = path.availableInterfaces
        if let first = interfaces.first {
            let name = first.name
            let typeStr = String(describing: first.type)
            return "interface \(name) (\(typeStr))"
        }
        if path.usesInterfaceType(.wifi) { return "interface (wifi)" }
        if path.usesInterfaceType(.cellular) { return "interface (cellular)" }
        if path.usesInterfaceType(.wiredEthernet) { return "interface (wiredEthernet)" }
        return "interface unknown"
    }
}

final class DefaultScheduler: SchedulerType {
    func schedule(after interval: TimeInterval, _ block: @escaping @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: block)
    }
}
