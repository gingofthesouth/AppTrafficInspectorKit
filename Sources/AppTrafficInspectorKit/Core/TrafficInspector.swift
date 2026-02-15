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

@MainActor
public final class TrafficInspector {
    public weak var delegate: TrafficInspectorDelegate?

    private let configuration: Configuration
    private let browser: ServiceBrowser
    private let client: NetworkClient

    private struct Accum {
        let packetId: String
        var url: URL
        var start: Date
        var response: URLResponse?
        var body = Data()
        var requestMethod: String = "GET"
        var requestHeaders: [String: String] = [:]
        var requestBody: Data?
    }
    /// Keyed by requestId when events provide it (concurrent same-URL requests stay separate).
    private var byRequestId: [UUID: Accum] = [:]
    /// Fallback when requestId is nil (e.g. tests); only one in-flight request per URL.
    private var byURL: [URL: Accum] = [:]

    public private(set) var packetsSent: Int = 0
    public private(set) var packetsDropped: Int = 0

    /// Session for forwarding real HTTP/HTTPS. Created on main at init so the protocol never touches URLSession on the CFNetwork queue.
    private lazy var forwardingSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = []
        let session = URLSession(configuration: config)
        TrafficURLProtocol.setForwardingSession(session)
        return session
    }()

    public init(configuration: Configuration, client: NetworkClient) {
        self.configuration = configuration
        self.client = client
        self.browser = ServiceBrowser(serviceType: configuration.netServiceType, domain: configuration.netServiceDomain)
        self.browser.delegate = self
        self.browser.startBrowsing()
        TrafficURLProtocol.eventSink = self
        TrafficURLProtocol.maxBodyBytes = configuration.maxBodyBytes
        _ = forwardingSession
    }

}

@MainActor
extension TrafficInspector: TrafficURLProtocolEventSink {
    public func record(_ event: TrafficEvent) {
        if let id = event.requestId {
            recordByRequestId(event, requestId: id)
        } else {
            recordByURL(event)
        }
    }

    private func recordByRequestId(_ event: TrafficEvent, requestId: UUID) {
        switch event.kind {
        case .start:
            var acc = Accum(packetId: UUID().uuidString, url: event.url, start: Date(), response: nil, body: Data())
            if let req = event.request {
                acc.requestMethod = req.httpMethod ?? "GET"
                acc.requestHeaders = req.allHTTPHeaderFields ?? [:]
                if let body = req.httpBody {
                    let limit = configuration.maxBodyBytes ?? body.count
                    acc.requestBody = body.count <= limit ? body : Data(body.prefix(limit))
                }
            }
            byRequestId[requestId] = acc
            sendPacket(forRequestId: requestId)
        case .response(let resp):
            guard var acc = byRequestId[requestId] else { return }
            acc.response = resp
            byRequestId[requestId] = acc
            sendPacket(forRequestId: requestId)
        case .data(let d):
            guard var acc = byRequestId[requestId] else { return }
            acc.body.append(d)
            byRequestId[requestId] = acc
        case .finish:
            sendPacket(forRequestId: requestId, complete: true)
            byRequestId.removeValue(forKey: requestId)
        }
    }

    private func recordByURL(_ event: TrafficEvent) {
        switch event.kind {
        case .start:
            var acc = Accum(packetId: UUID().uuidString, url: event.url, start: Date(), response: nil, body: Data())
            if let req = event.request {
                acc.requestMethod = req.httpMethod ?? "GET"
                acc.requestHeaders = req.allHTTPHeaderFields ?? [:]
                if let body = req.httpBody {
                    let limit = configuration.maxBodyBytes ?? body.count
                    acc.requestBody = body.count <= limit ? body : Data(body.prefix(limit))
                }
            }
            byURL[event.url] = acc
            sendPacket(for: event.url)
        case .response(let resp):
            guard var acc = byURL[event.url] else { return }
            acc.response = resp
            byURL[event.url] = acc
            sendPacket(for: event.url)
        case .data(let d):
            guard var acc = byURL[event.url] else { return }
            acc.body.append(d)
            byURL[event.url] = acc
        case .finish:
            sendPacket(for: event.url, complete: true)
            byURL.removeValue(forKey: event.url)
        }
    }

    private func sendPacket(forRequestId requestId: UUID, complete: Bool = false) {
        guard let acc = byRequestId[requestId] else { return }
        sendPacket(acc: acc, complete: complete)
    }

    private func sendPacket(for url: URL, complete: Bool = false) {
        guard let acc = byURL[url] else { return }
        sendPacket(acc: acc, complete: complete)
    }

    private func sendPacket(acc: Accum, complete: Bool) {
        let info = RequestInfo(
            url: acc.url,
            requestHeaders: acc.requestHeaders,
            requestBody: acc.requestBody,
            requestMethod: acc.requestMethod,
            responseHeaders: (acc.response as? HTTPURLResponse)?.allHeaderFields as? [String:String],
            responseData: complete ? acc.body : nil,
            statusCode: (acc.response as? HTTPURLResponse).map { Int($0.statusCode) },
            startDate: acc.start,
            endDate: complete ? Date() : nil
        )
        let packet = RequestPacket(packetId: acc.packetId, requestInfo: info, project: configuration.project, device: configuration.device)

        let hasDelegate = delegate != nil
        let delegateResult = delegate?.trafficInspector(self, willSend: packet)

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

extension TrafficInspector: ServiceBrowserDelegate {
    public func serviceBrowser(_ browser: ServiceBrowser, didFindService service: NetService) {
        client.setService(service)
    }
    public func serviceBrowser(_ browser: ServiceBrowser, didRemoveService service: NetService) {}
    public func serviceBrowser(_ browser: ServiceBrowser, didFailWithError error: Error) {
        DevLogger.logError(error)
    }
}
