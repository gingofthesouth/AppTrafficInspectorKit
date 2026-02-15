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
    case start(requestMethod: String, requestHeaders: [String: String], requestBody: Data?)
    case response(URLResponse)
    case data(Data)
    case finish
}

public struct TrafficEvent: Equatable, @unchecked Sendable {
    /// Unique id for this request lifecycle. When set, the inspector keys by this so concurrent requests to the same URL do not overwrite each other.
    public let requestId: UUID?
    public let url: URL
    public let kind: TrafficEventKind
    /// The underlying URLRequest, when available (e.g. for .start). Used to record method, headers, and body.
    public let request: URLRequest?

    public init(requestId: UUID? = nil, url: URL, kind: TrafficEventKind, request: URLRequest? = nil) {
        self.requestId = requestId
        self.url = url
        self.kind = kind
        self.request = request
    }

    public static func == (lhs: TrafficEvent, rhs: TrafficEvent) -> Bool {
        lhs.requestId == rhs.requestId && lhs.url == rhs.url && lhs.kind == rhs.kind
    }
}

public protocol TrafficURLProtocolEventSink: AnyObject {
    func record(_ event: TrafficEvent)
}

public final class TrafficURLProtocol: URLProtocol {
    nonisolated(unsafe) public static weak var eventSink: TrafficURLProtocolEventSink?
    nonisolated(unsafe) public static var maxBodyBytes: Int?

    /// No-op for API compatibility with TrafficInspector; this implementation uses internalSession for forwarding.
    static func setForwardingSession(_ session: URLSession?) {}

    private static let handledRequestKey = "TrafficURLProtocolHandledRequest"

    private var receivedBytes: Int = 0
    private var dataTask: URLSessionDataTask?
    private var responseData = Data()

    // Internal session that does NOT include TrafficURLProtocol to prevent infinite loops
    private static let internalSession: URLSession = {
        let config = URLSessionConfiguration.default
        var protocols = config.protocolClasses ?? []
        protocols.removeAll { $0 == TrafficURLProtocol.self }
        config.protocolClasses = protocols
        return URLSession(configuration: config)
    }()

    private static func readAllBytes(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 16 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }

    public override class func canInit(with request: URLRequest) -> Bool {
        // Prevent infinite loops - don't handle requests we've already marked
        if property(forKey: handledRequestKey, in: request) != nil {
            return false
        }
        
        // Handle http, https, and mock:// (for testing)
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "mock"
    }
    
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    public override class func requestIsCacheEquivalent(_ a: URLRequest, to b: URLRequest) -> Bool {
        return super.requestIsCacheEquivalent(a, to: b)
    }

    public override func startLoading() {
        guard let url = request.url else { return }

        // Capture request information
        let method = request.httpMethod ?? "GET"
        let headers = request.allHTTPHeaderFields ?? [:]
        var body: Data? = request.httpBody
        
        // Handle mock:// scheme for testing (safe to read the stream; request won't be sent)
        if url.scheme == "mock" {
            if body == nil, let stream = request.httpBodyStream {
                body = Self.readAllBytes(from: stream)
            }
            
            // Record start event with request info
            Self.eventSink?.record(TrafficEvent(url: url, kind: .start(requestMethod: method, requestHeaders: headers, requestBody: body)))
            handleMockRequest(url: url)
            return
        }
        
        // For real HTTP(S) requests, use internal session to avoid loops
        guard let mutableRequest = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            return
        }
        
        // If the body was moved into a stream by URLSession, read+restore the stream on the mutable request.
        if body == nil, let stream = mutableRequest.httpBodyStream {
            let streamBody = Self.readAllBytes(from: stream)
            body = streamBody
            mutableRequest.httpBodyStream = InputStream(data: streamBody)
            mutableRequest.httpBody = streamBody
        }
        
        // Record start event with request info
        Self.eventSink?.record(TrafficEvent(url: url, kind: .start(requestMethod: method, requestHeaders: headers, requestBody: body)))

        URLProtocol.setProperty(true, forKey: Self.handledRequestKey, in: mutableRequest)
        
        dataTask = Self.internalSession.dataTask(with: mutableRequest as URLRequest) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                self.client?.urlProtocol(self, didFailWithError: error)
                Self.eventSink?.record(TrafficEvent(url: url, kind: .finish))
                return
            }
            
            if let response = response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                Self.eventSink?.record(TrafficEvent(url: url, kind: .response(response)))
            }
            
            if let data = data {
                let limit = Self.maxBodyBytes ?? data.count
                let limitedData = data.prefix(limit)
                self.responseData = data
                self.receivedBytes += data.count
                // Forward full response to the app; only record limited data for inspection.
                if !data.isEmpty {
                    self.client?.urlProtocol(self, didLoad: data)
                }
                if !limitedData.isEmpty {
                    Self.eventSink?.record(TrafficEvent(url: url, kind: .data(Data(limitedData))))
                }
            }
            
            self.client?.urlProtocolDidFinishLoading(self)
            Self.eventSink?.record(TrafficEvent(url: url, kind: .finish))
        }
        
        dataTask?.resume()
    }
    
    private func handleMockRequest(url: URL) {
        // Synthesize a response and small body for mock://
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        Self.eventSink?.record(TrafficEvent(url: url, kind: .response(response)))

        let fullBody = Data([0x41, 0x42, 0x43, 0x44, 0x45])
        let limit = Self.maxBodyBytes ?? fullBody.count
        let limitedData = fullBody.prefix(limit)
        receivedBytes += fullBody.count
        if !fullBody.isEmpty {
            client?.urlProtocol(self, didLoad: fullBody)
        }
        if !limitedData.isEmpty {
            Self.eventSink?.record(TrafficEvent(url: url, kind: .data(Data(limitedData))))
        }

        client?.urlProtocolDidFinishLoading(self)
        Self.eventSink?.record(TrafficEvent(url: url, kind: .finish))
    }

    public override func stopLoading() {
        dataTask?.cancel()
        dataTask = nil
    }
}
