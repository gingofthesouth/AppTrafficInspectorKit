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

public struct RedactionPolicy {
    public var headerRedactor: ([String:String]) -> [String:String]
    public var bodyRedactor: (Data) -> Data

    public init(headerRedactor: @escaping ([String:String]) -> [String:String] = { $0 },
                bodyRedactor: @escaping (Data) -> Data = { $0 }) {
        self.headerRedactor = headerRedactor
        self.bodyRedactor = bodyRedactor
    }
}
