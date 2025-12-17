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

public struct RequestPacket: Codable, Equatable {
    public let packetId: String
    public let requestInfo: RequestInfo
    public let project: ProjectInfo
    public let device: DeviceInfo

    public init(packetId: String, requestInfo: RequestInfo, project: ProjectInfo, device: DeviceInfo) {
        self.packetId = packetId
        self.requestInfo = requestInfo
        self.project = project
        self.device = device
    }
}
