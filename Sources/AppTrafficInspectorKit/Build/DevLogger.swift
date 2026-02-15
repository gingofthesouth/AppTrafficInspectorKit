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

import Foundation
import os

/// Logs errors via OSLog only when building with DEBUG (Debug configuration).
/// Call from any error path; in Release builds these calls are no-ops with no logging overhead.
/// Uses os_log (not Logger) for compatibility with the package's deployment targets.
public enum DevLogger {
#if DEBUG
    private static let log = OSLog(subsystem: "AppTrafficInspectorKit", category: "Error")

    public static func logError(_ error: Error) {
        if #available(macOS 10.14, iOS 12.0, *) {
            os_log(.error, log: log, "%{public}@", error.localizedDescription)
        }
    }

    public static func logError(message: String) {
        if #available(macOS 10.14, iOS 12.0, *) {
            os_log(.error, log: log, "%{public}@", message)
        }
    }
#else
    public static func logError(_ error: Error) {}

    public static func logError(message: String) {}
#endif
}
