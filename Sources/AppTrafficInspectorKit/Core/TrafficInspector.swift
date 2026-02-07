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

public protocol TrafficInspectorDelegate: AnyObject {
    func trafficInspector(_ inspector: TrafficInspector, willSend packet: RequestPacket) -> RequestPacket?
}

public final class TrafficInspector {
    public weak var delegate: TrafficInspectorDelegate?

    private let configuration: Configuration
    private let browser: ServiceBrowser
    private let client: NetworkClient
    private let queue = DispatchQueue(label: "com.apptrafficinspector.trafficInspector")

    private struct Accum {
        var start: Date
        var requestMethod: String
        var requestHeaders: [String: String]
        var requestBody: Data?
        var response: URLResponse?
        var body: Data
    }
    private var byURL: [URL: Accum] = [:]

    public private(set) var packetsSent: Int = 0
    public private(set) var packetsDropped: Int = 0

    public init(configuration: Configuration, client: NetworkClient) {
        self.configuration = configuration
        self.client = client
        self.browser = ServiceBrowser(serviceType: configuration.netServiceType, domain: configuration.netServiceDomain)
        self.browser.delegate = self
        self.browser.startBrowsing()
        TrafficURLProtocol.eventSink = self
        TrafficURLProtocol.maxBodyBytes = configuration.maxBodyBytes
    }

}

extension TrafficInspector: TrafficURLProtocolEventSink {
    public func record(_ event: TrafficEvent) {
        // Phase 1: state mutations + packet build (under lock)
        let pending: (packet: RequestPacket, delegate: TrafficInspectorDelegate?)? = queue.sync {
            switch event.kind {
            case .start(let method, let headers, let body):
                byURL[event.url] = Accum(
                    start: Date(),
                    requestMethod: method,
                    requestHeaders: headers,
                    requestBody: body,
                    response: nil,
                    body: Data()
                )
                return buildPacket(for: event.url).map { ($0, delegate) }
            case .response(let resp):
                guard var acc = byURL[event.url] else { return nil }
                acc.response = resp
                byURL[event.url] = acc
                return buildPacket(for: event.url).map { ($0, delegate) }
            case .data(let d):
                guard var acc = byURL[event.url] else { return nil }
                acc.body.append(d)
                byURL[event.url] = acc
                return nil
            case .finish:
                let result = buildPacket(for: event.url, complete: true).map { ($0, delegate) }
                byURL.removeValue(forKey: event.url)
                return result
            }
        }
        // Phase 2: delegate callback + network send (no lock held for delegate)
        if let pending {
            dispatchPacket(pending.packet, delegate: pending.delegate)
        }
    }

    /// Builds a RequestPacket from current state. Must be called from inside queue.sync.
    private func buildPacket(for url: URL, complete: Bool = false) -> RequestPacket? {
        guard let acc = byURL[url] else { return nil }

        var responseHeaders: [String: String]?
        if let httpResponse = acc.response as? HTTPURLResponse {
            responseHeaders = [:]
            for (key, value) in httpResponse.allHeaderFields {
                if let keyString = key as? String {
                    if let valueString = value as? String {
                        responseHeaders?[keyString] = valueString
                    } else {
                        responseHeaders?[keyString] = String(describing: value)
                    }
                }
            }
        }

        let info = RequestInfo(
            url: url,
            requestHeaders: acc.requestHeaders,
            requestBody: acc.requestBody,
            requestMethod: acc.requestMethod,
            responseHeaders: responseHeaders,
            responseData: complete ? acc.body : nil,
            statusCode: (acc.response as? HTTPURLResponse).map { Int($0.statusCode) },
            startDate: acc.start,
            endDate: complete ? Date() : nil
        )
        return RequestPacket(packetId: UUID().uuidString, requestInfo: info, project: configuration.project, device: configuration.device)
    }

    /// Delegate callback runs outside any lock (re-entrant record() is safe). Network send + counters under lock.
    private func dispatchPacket(_ packet: RequestPacket, delegate: TrafficInspectorDelegate?) {
        let hasDelegate = delegate != nil
        let delegateResult = delegate?.trafficInspector(self, willSend: packet)

        queue.sync {
            if let modified = delegateResult {
                client.sendPacket(modified)
                packetsSent += 1
            } else if hasDelegate {
                packetsDropped += 1
            } else {
                client.sendPacket(packet)
                packetsSent += 1
            }
        }
    }
}

extension TrafficInspector: ServiceBrowserDelegate {
    public func serviceBrowser(_ browser: ServiceBrowser, didFindService service: NetService) {
        queue.sync { client.setService(service) }
    }
    public func serviceBrowser(_ browser: ServiceBrowser, didRemoveService service: NetService) {}
    public func serviceBrowser(_ browser: ServiceBrowser, didFailWithError error: Error) {}
}
