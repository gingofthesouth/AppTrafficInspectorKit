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
#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#endif

public var deviceDisplayName: String {
    #if os(iOS) || os(tvOS) || os(visionOS)
    return MainActor.assumeIsolated { UIDevice.current.name }
    #else
    return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    #endif
}

public struct Configuration {
    /// Default per-body capture limit (8 MiB). Request and response bodies are each capped at this size so a
    /// base64-encoded packet stays under the Mac app's 25 MiB per-transaction limit. Truncated bodies are flagged
    /// on the wire (`requestBodyTruncated` / `responseDataTruncated`).
    public static let defaultMaxBodyBytes = 8 * 1024 * 1024

    public var netServiceType: String
    public var netServiceDomain: String
    public var project: ProjectInfo
    public var device: DeviceInfo
    /// Maximum bytes captured per request body and per response body. `nil` means unlimited.
    /// This only limits what is sent to the inspector; the app's traffic is never truncated.
    public var maxBodyBytes: Int?

    public init(
        netServiceType: String = "_AppTraffic._tcp",
        netServiceDomain: String = "",
        project: ProjectInfo = ProjectInfo(projectName: Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "App"),
        device: DeviceInfo = DeviceInfo(deviceId: UUID().uuidString, deviceName: deviceDisplayName, deviceDescription: ProcessInfo.processInfo.operatingSystemVersionString),
        maxBodyBytes: Int? = Configuration.defaultMaxBodyBytes
    ) {
        self.netServiceType = netServiceType
        self.netServiceDomain = netServiceDomain
        self.project = project
        self.device = device
        self.maxBodyBytes = maxBodyBytes
    }
}
