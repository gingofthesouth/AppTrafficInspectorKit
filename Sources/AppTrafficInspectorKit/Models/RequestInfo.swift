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

public struct RequestInfo: Codable, Equatable {
    public let url: URL
    public let requestHeaders: [String: String]
    public let requestBody: Data?
    public let requestMethod: String
    public let responseHeaders: [String: String]?
    public let responseData: Data?
    public let statusCode: Int?
    public let startDate: Date
    public let endDate: Date?

    public init(
        url: URL,
        requestHeaders: [String: String],
        requestBody: Data? = nil,
        requestMethod: String,
        responseHeaders: [String: String]? = nil,
        responseData: Data? = nil,
        statusCode: Int? = nil,
        startDate: Date,
        endDate: Date? = nil
    ) {
        self.url = url
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.requestMethod = requestMethod
        self.responseHeaders = responseHeaders
        self.responseData = responseData
        self.statusCode = statusCode
        self.startDate = startDate
        self.endDate = endDate
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case requestHeaders
        case requestBody
        case requestMethod
        case responseHeaders
        case responseData
        case statusCode
        case startDate
        case endDate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try c.decode(URL.self, forKey: .url)
        self.requestHeaders = try c.decode([String: String].self, forKey: .requestHeaders)
        self.requestBody = try c.decodeIfPresent(Data.self, forKey: .requestBody)
        self.requestMethod = try c.decode(String.self, forKey: .requestMethod)
        self.responseHeaders = try c.decodeIfPresent([String: String].self, forKey: .responseHeaders)
        self.responseData = try c.decodeIfPresent(Data.self, forKey: .responseData)
        if let sc = try? c.decode(Int.self, forKey: .statusCode) {
            self.statusCode = sc
        } else if let scString = try? c.decode(String.self, forKey: .statusCode), let scInt = Int(scString) {
            self.statusCode = scInt
        } else {
            self.statusCode = nil
        }
        self.startDate = try c.decode(Date.self, forKey: .startDate)
        self.endDate = try c.decodeIfPresent(Date.self, forKey: .endDate)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url, forKey: .url)
        try c.encode(requestHeaders, forKey: .requestHeaders)
        try c.encodeIfPresent(requestBody, forKey: .requestBody)
        try c.encode(requestMethod, forKey: .requestMethod)
        try c.encodeIfPresent(responseHeaders, forKey: .responseHeaders)
        try c.encodeIfPresent(responseData, forKey: .responseData)
        try c.encodeIfPresent(statusCode, forKey: .statusCode)
        try c.encode(startDate, forKey: .startDate)
        try c.encodeIfPresent(endDate, forKey: .endDate)
    }
}
