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

public enum URLSessionConfigurationInjector {
    private static let installed: Void = {
        _ = swizzle(class: URLSessionConfiguration.self, original: #selector(getter: URLSessionConfiguration.default), replacement: #selector(URLSessionConfiguration.appTraffic_default))
        _ = swizzle(class: URLSessionConfiguration.self, original: #selector(getter: URLSessionConfiguration.ephemeral), replacement: #selector(URLSessionConfiguration.appTraffic_ephemeral))
    }()

    @MainActor
    public static func install() {
        _ = installed
        URLProtocol.registerClass(TrafficURLProtocol.self)
    }

    private static func swizzle(class cls: AnyClass, original: Selector, replacement: Selector) -> Bool {
        guard let originalMethod = class_getClassMethod(cls, original),
              let replacementMethod = class_getClassMethod(cls, replacement)
        else { return false }
        method_exchangeImplementations(originalMethod, replacementMethod)
        return true
    }
}

extension URLSessionConfiguration {
    @objc class func appTraffic_default() -> URLSessionConfiguration {
        let config = appTraffic_default()
        prependTrafficProtocol(config)
        return config
    }

    @objc class func appTraffic_ephemeral() -> URLSessionConfiguration {
        let config = appTraffic_ephemeral()
        prependTrafficProtocol(config)
        return config
    }

    private static func prependTrafficProtocol(_ config: URLSessionConfiguration) {
        var protocols = config.protocolClasses ?? []
        if !(protocols.first is TrafficURLProtocol.Type) {
            protocols.insert(TrafficURLProtocol.self, at: 0)
            config.protocolClasses = protocols
        }
    }
}
