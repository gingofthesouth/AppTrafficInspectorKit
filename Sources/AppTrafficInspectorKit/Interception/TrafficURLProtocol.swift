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

public enum TrafficEventKind: Equatable {
    case start
    case response(URLResponse)
    case data(Data)
    case finish
}

public struct TrafficEvent: Equatable {
    public let url: URL
    public let kind: TrafficEventKind
}

@MainActor
public protocol TrafficURLProtocolEventSink: AnyObject {
    func record(_ event: TrafficEvent)
}

public final class TrafficURLProtocol: URLProtocol {
    nonisolated(unsafe) public static weak var eventSink: TrafficURLProtocolEventSink?
    nonisolated(unsafe) public static var maxBodyBytes: Int?

    private var receivedBytes: Int = 0

    public override class func canInit(with request: URLRequest) -> Bool {
        // For testing, handle mock:// scheme
        if request.url?.scheme == "mock" { return true }
        return false
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        guard let url = request.url else { return }
        DispatchQueue.main.async {
            Self.eventSink?.record(TrafficEvent(url: url, kind: .start))
        }

        // Synthesize a response and small body for mock://
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.main.async {
            Self.eventSink?.record(TrafficEvent(url: url, kind: .response(response)))
        }

        let fullBody = Data([0x41, 0x42, 0x43, 0x44, 0x45]) // ABCDE
        let limit = Self.maxBodyBytes ?? fullBody.count
        let body = fullBody.prefix(limit)
        receivedBytes += body.count
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
            DispatchQueue.main.async {
                Self.eventSink?.record(TrafficEvent(url: url, kind: .data(Data(body))))
            }
        }

        client?.urlProtocolDidFinishLoading(self)
        DispatchQueue.main.async {
            Self.eventSink?.record(TrafficEvent(url: url, kind: .finish))
        }
    }

    public override func stopLoading() {}
}
