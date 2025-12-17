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

/// Simple API for starting network traffic inspection
@MainActor
public enum AppTrafficInspectorKit {
    private static var sharedInspector: TrafficInspector?
    
    /// Start traffic inspection with default configuration
    /// 
    /// This is the simplest way to use the library. It automatically:
    /// - Installs URLProtocol interception
    /// - Creates default network connection and scheduler
    /// - Starts service discovery
    ///
    /// Example:
    /// ```swift
    /// import AppTrafficInspectorKit
    ///
    /// func application(_ application: UIApplication, didFinishLaunchingWithOptions...) -> Bool {
    ///     #if DEBUG
    ///     AppTrafficInspectorKit.start()
    ///     #endif
    ///     return true
    /// }
    /// ```
    public static func start() {
        start(with: Configuration())
    }
    
    /// Start traffic inspection with custom configuration
    ///
    /// - Parameter configuration: Custom configuration (defaults are used if not specified)
    public static func start(with configuration: Configuration) {
        // Install URLProtocol interception
        URLSessionConfigurationInjector.install()
        
        // Create default implementations
        let connectionFactory: (NetService) -> ConnectionType
        if #available(iOS 12.0, macOS 10.14, *) {
            connectionFactory = { DefaultConnection(service: $0) }
        } else {
            fatalError("Network framework requires iOS 12.0+ or macOS 10.14+")
        }
        let scheduler = DefaultScheduler()
        let client = NetworkClient(connectionFactory: connectionFactory, scheduler: scheduler)
        
        // Create and start inspector
        sharedInspector = TrafficInspector(configuration: configuration, client: client)
    }
    
    /// Stop traffic inspection
    public static func stop() {
        sharedInspector = nil
    }
    
    /// Set delegate for custom packet filtering/modification
    public static func setDelegate(_ delegate: TrafficInspectorDelegate?) {
        sharedInspector?.delegate = delegate
    }
    
    /// Check if traffic inspection is currently active
    public static var isActive: Bool {
        sharedInspector != nil
    }
}
