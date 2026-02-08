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

public protocol ServiceBrowserDelegate: AnyObject {
    func serviceBrowser(_ browser: ServiceBrowser, didFindService service: NetService)
    func serviceBrowser(_ browser: ServiceBrowser, didRemoveService service: NetService)
    func serviceBrowser(_ browser: ServiceBrowser, didFailWithError error: Error)
}

public final class ServiceBrowser: NSObject, @unchecked Sendable {
    nonisolated(unsafe) public weak var delegate: ServiceBrowserDelegate?
    private let serviceType: String
    private let domain: String
    private let browser: NetServiceBrowser

    public init(serviceType: String, domain: String = "") {
        self.serviceType = serviceType
        self.domain = domain
        self.browser = NetServiceBrowser()
        super.init()
        self.browser.delegate = self
    }

    public func startBrowsing() {
        browser.searchForServices(ofType: serviceType, inDomain: domain)
    }

    public func stopBrowsing() {
        browser.stop()
    }
}

extension ServiceBrowser: NetServiceBrowserDelegate {
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        // Capture service reference with nonisolated(unsafe) to avoid Sendable warnings
        // NetService is a Foundation class that's safe to pass across threads in this context
        nonisolated(unsafe) let serviceRef = service
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.serviceBrowser(self, didFindService: serviceRef)
        }
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        nonisolated(unsafe) let serviceRef = service
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.serviceBrowser(self, didRemoveService: serviceRef)
        }
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        let error = NSError(domain: "ServiceBrowser", code: -1, userInfo: errorDict)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.serviceBrowser(self, didFailWithError: error)
        }
    }
}

#if DEBUG
extension ServiceBrowser {
    // Test helpers to simulate events
    func _simulateDidFind(_ service: NetService) { delegate?.serviceBrowser(self, didFindService: service) }
    func _simulateDidRemove(_ service: NetService) { delegate?.serviceBrowser(self, didRemoveService: service) }
    func _simulateDidFail(_ error: Error) { delegate?.serviceBrowser(self, didFailWithError: error) }
}
#endif
