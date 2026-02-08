# Detailed Implementation Plan: AppTrafficInspectorKit

## 📋 Project Overview

**Goal**: Create a Swift-native network traffic inspection library that replicates Bagel's functionality for debugging iOS app network requests.

**Distribution**: Swift Package Manager
**Target Platforms**: iOS 12.0+, macOS 10.15+
**Architecture**: Modern Swift with minimal Objective-C interop for method swizzling

## 🏗️ Architecture Design

### Core Components
1. **Network Interception Layer** - Method swizzling for URLSession/URLConnection
2. **Data Models** - Request/response data structures
3. **Network Communication** - Bonjour discovery + TCP socket communication
4. **Configuration Management** - Device/project metadata
5. **Public API** - Simple integration interface

### Mac App Compatibility
The iOS client library is designed to work with a Mac app that receives and displays network traffic. The Mac app uses the following Bonjour configuration:

```swift
class AppTrafficConfiguration: NSObject {
    static let netServiceDomain: String = ""
    static let netServiceType: String = "_AppTraffic._tcp"
    static let netServiceName: String = ""
    static let netServicePort: Int32 = 43435
}
```

**Key Compatibility Points:**
- **Service Type**: `_AppTraffic._tcp` (matches Mac app)
- **Port**: `43435` (matches Mac app)
- **Domain**: Empty string for local network discovery
- **Protocol**: TCP socket communication with length-prefixed JSON packets

## 📁 Project Structure

```
AppTrafficInspectorKit/
├── Package.swift
├── Sources/
│   └── AppTrafficInspectorKit/
│       ├── AppTrafficInspectorKit.swift (Public API)
│       ├── Core/
│       │   ├── TrafficInspector.swift (Main controller)
│       │   ├── Configuration.swift
│       │   └── TrafficInspectorDelegate.swift
│       ├── Interception/
│       │   ├── URLSessionInterceptor.swift
│       │   ├── URLConnectionInterceptor.swift
│       │   └── MethodSwizzler.swift
│       ├── Models/
│       │   ├── RequestPacket.swift
│       │   ├── RequestInfo.swift
│       │   ├── DeviceInfo.swift
│       │   ├── ProjectInfo.swift
│       │   └── NetworkRequest.swift
│       ├── Communication/
│       │   ├── ServiceBrowser.swift
│       │   ├── NetworkClient.swift
│       │   └── PacketSerializer.swift
│       └── Utilities/
│           ├── DeviceIdentifier.swift
│           ├── BundleInfo.swift
│           └── Extensions.swift
└── Tests/
    └── AppTrafficInspectorKitTests/
        ├── AppTrafficInspectorKitTests.swift
        ├── Core/
        │   ├── TrafficInspectorTests.swift
        │   └── ConfigurationTests.swift
        ├── Interception/
        │   ├── URLSessionInterceptorTests.swift
        │   └── MethodSwizzlerTests.swift
        ├── Models/
        │   ├── RequestPacketTests.swift
        │   └── RequestInfoTests.swift
        ├── Communication/
        │   ├── ServiceBrowserTests.swift
        │   └── NetworkClientTests.swift
        └── Utilities/
            └── DeviceIdentifierTests.swift
```

## ✅ Development & Testing Rules

- Test-first per task: write/update unit tests, then implement code, then run tests; proceed only when green.
- Use Swift Testing for unit tests (`import Testing`, `@Test`). Introduce XCTest only if a capability is missing.
- No live network in unit tests: inject fakes/mocks; reserve live sockets for a small, opt-in integration suite.
- Deterministic tests: inject clock/UUID/random providers; avoid sleeps; use timeouts sparingly.
- Keep unit tests fast and focused (<100ms typical); move end-to-end scenarios to an integration suite.

## 🚀 Implementation Phases

### Phase 0: Swift Testing Setup & Test Plan (Pre-implementation)

1. Establish Swift Testing as the framework of record in the test target.
2. Create test folder structure and initial skeleton files:
   - `Tests/AppTrafficInspectorKitTests/Communication/PacketSerializerTests.swift`
   - `Tests/AppTrafficInspectorKitTests/Models/RequestPacketTests.swift`
   - `Tests/AppTrafficInspectorKitTests/Interception/TrafficURLProtocolTests.swift`
   - `Tests/AppTrafficInspectorKitTests/Communication/ServiceBrowserTests.swift`
   - `Tests/AppTrafficInspectorKitTests/Communication/NetworkClientTests.swift`
   - `Tests/AppTrafficInspectorKitTests/Core/TrafficInspectorTests.swift`
   - `Tests/AppTrafficInspectorKitTests/Privacy/FiltersAndRedactorsTests.swift`
   - `Tests/AppTrafficInspectorKitTests/Build/DebugGatingTests.swift`
   - `Tests/AppTrafficInspectorKitTests/Integration/EndToEndTests.swift` (opt-in)
3. Add test utilities and DI protocols for fakes:
   - FakeClock, FakeUUIDProvider, TestPacketSink
   - Browser and Connection abstractions for discovery/transport
4. Document commands:
   - All tests: `swift test`
   - Filtered: `swift test --filter PacketSerializerTests`
   - Integration: `ENABLE_INTEGRATION_TESTS=1 swift test --filter EndToEndTests`

### Phase 1: Foundation & Data Models (Week 1)

#### 1.1 Update Package.swift
```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppTrafficInspectorKit",
    platforms: [
        .iOS(.v12),
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "AppTrafficInspectorKit",
            targets: ["AppTrafficInspectorKit"]
        ),
    ],
    dependencies: [
        // No external dependencies - pure Swift implementation
    ],
    targets: [
        .target(
            name: "AppTrafficInspectorKit",
            dependencies: [],
            path: "Sources/AppTrafficInspectorKit"
        ),
        .testTarget(
            name: "AppTrafficInspectorKitTests",
            dependencies: ["AppTrafficInspectorKit"],
            path: "Tests/AppTrafficInspectorKitTests"
        ),
    ]
)
```

#### 1.2 Core Data Models
**File**: `Sources/AppTrafficInspectorKit/Models/RequestPacket.swift`
```swift
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
```

**File**: `Sources/AppTrafficInspectorKit/Models/RequestInfo.swift`
```swift
import Foundation

public struct RequestInfo: Codable, Equatable {
    public let url: URL
    public let requestHeaders: [String: String]
    public let requestBody: Data?
    public let requestMethod: String
    public let responseHeaders: [String: String]?
    public let responseData: Data?
    public let statusCode: String?
    public let startDate: Date
    public let endDate: Date?
    
    public init(url: URL, 
                requestHeaders: [String: String], 
                requestBody: Data? = nil,
                requestMethod: String,
                responseHeaders: [String: String]? = nil,
                responseData: Data? = nil,
                statusCode: String? = nil,
                startDate: Date,
                endDate: Date? = nil) {
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
}
```

#### 1.3 Configuration & Device Info
**File**: `Sources/AppTrafficInspectorKit/Models/DeviceInfo.swift`
```swift
import Foundation

public struct DeviceInfo: Codable, Equatable {
    public let deviceId: String
    public let deviceName: String
    public let deviceDescription: String
    
    public init(deviceId: String, deviceName: String, deviceDescription: String) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceDescription = deviceDescription
    }
}
```

**File**: `Sources/AppTrafficInspectorKit/Models/ProjectInfo.swift`
```swift
import Foundation

public struct ProjectInfo: Codable, Equatable {
    public let projectName: String
    
    public init(projectName: String) {
        self.projectName = projectName
    }
}
```

#### 1.4 Unit Tests for Models
**File**: `Tests/AppTrafficInspectorKitTests/Models/RequestPacketTests.swift`
```swift
import XCTest
@testable import AppTrafficInspectorKit

final class RequestPacketTests: XCTestCase {
    
    func testRequestPacketInitialization() {
        let requestInfo = RequestInfo(
            url: URL(string: "https://example.com")!,
            requestHeaders: ["Content-Type": "application/json"],
            requestMethod: "GET",
            startDate: Date()
        )
        
        let projectInfo = ProjectInfo(projectName: "TestApp")
        let deviceInfo = DeviceInfo(
            deviceId: "test-device",
            deviceName: "Test Device",
            deviceDescription: "Test Description"
        )
        
        let packet = RequestPacket(
            packetId: "test-packet-id",
            requestInfo: requestInfo,
            project: projectInfo,
            device: deviceInfo
        )
        
        XCTAssertEqual(packet.packetId, "test-packet-id")
        XCTAssertEqual(packet.requestInfo.url.absoluteString, "https://example.com")
        XCTAssertEqual(packet.project.projectName, "TestApp")
        XCTAssertEqual(packet.device.deviceId, "test-device")
    }
    
    func testRequestPacketCodable() throws {
        let requestInfo = RequestInfo(
            url: URL(string: "https://example.com")!,
            requestHeaders: ["Content-Type": "application/json"],
            requestMethod: "GET",
            startDate: Date()
        )
        
        let projectInfo = ProjectInfo(projectName: "TestApp")
        let deviceInfo = DeviceInfo(
            deviceId: "test-device",
            deviceName: "Test Device",
            deviceDescription: "Test Description"
        )
        
        let packet = RequestPacket(
            packetId: "test-packet-id",
            requestInfo: requestInfo,
            project: projectInfo,
            device: deviceInfo
        )
        
        let encoded = try JSONEncoder().encode(packet)
        let decoded = try JSONDecoder().decode(RequestPacket.self, from: encoded)
        
        XCTAssertEqual(packet, decoded)
    }
}
```

### Phase 2: Utilities & Configuration (Week 1-2)

#### 2.1 Device Identification
**File**: `Sources/AppTrafficInspectorKit/Utilities/DeviceIdentifier.swift`
```swift
import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct DeviceIdentifier {
    
    public static func generateDeviceId() -> String {
        let deviceName = getDeviceName()
        let deviceDescription = getDeviceDescription()
        return "\(deviceName)-\(deviceDescription)".replacingOccurrences(of: " ", with: "-")
    }
    
    public static func getDeviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #elseif canImport(AppKit)
        return Host.current().localizedName ?? "Unknown"
        #else
        return "Unknown"
        #endif
    }
    
    public static func getDeviceDescription() -> String {
        #if canImport(UIKit)
        let device = UIDevice.current
        return "\(device.model) \(device.systemName) \(device.systemVersion)"
        #elseif canImport(AppKit)
        let processInfo = ProcessInfo.processInfo
        return processInfo.operatingSystemVersionString
        #else
        return "Unknown"
        #endif
    }
    
    public static func getProjectName() -> String {
        return Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Unknown"
    }
}
```

#### 2.2 Configuration Management
**File**: `Sources/AppTrafficInspectorKit/Core/Configuration.swift`
```swift
import Foundation

public struct Configuration {
    public let project: ProjectInfo
    public let device: DeviceInfo
    public let netServicePort: UInt16
    public let netServiceType: String
    public let netServiceDomain: String
    public let netServiceName: String
    
    public init(project: ProjectInfo? = nil,
                device: DeviceInfo? = nil,
                netServicePort: UInt16 = 43435,
                netServiceType: String = "_AppTraffic._tcp",
                netServiceDomain: String = "",
                netServiceName: String = "") {
        self.project = project ?? ProjectInfo(projectName: DeviceIdentifier.getProjectName())
        self.device = device ?? DeviceInfo(
            deviceId: DeviceIdentifier.generateDeviceId(),
            deviceName: DeviceIdentifier.getDeviceName(),
            deviceDescription: DeviceIdentifier.getDeviceDescription()
        )
        self.netServicePort = netServicePort
        self.netServiceType = netServiceType
        self.netServiceDomain = netServiceDomain
        self.netServiceName = netServiceName
    }
    
    public static let `default` = Configuration()
}
```

### Phase 3: Network Communication (Week 2-3)

#### 3.1 Service Discovery
**File**: `Sources/AppTrafficInspectorKit/Communication/ServiceBrowser.swift`
```swift
import Foundation
import Network

public protocol ServiceBrowserDelegate: AnyObject {
    func serviceBrowser(_ browser: ServiceBrowser, didFindService service: NetService)
    func serviceBrowser(_ browser: ServiceBrowser, didRemoveService service: NetService)
    func serviceBrowser(_ browser: ServiceBrowser, didFailWithError error: Error)
}

public class ServiceBrowser: NSObject {
    public weak var delegate: ServiceBrowserDelegate?
    private let netServiceBrowser: NetServiceBrowser
    private let serviceType: String
    private let domain: String
    
    public init(serviceType: String, domain: String = "") {
        self.netServiceBrowser = NetServiceBrowser()
        self.serviceType = serviceType
        self.domain = domain
        super.init()
        self.netServiceBrowser.delegate = self
    }
    
    public func startBrowsing() {
        netServiceBrowser.searchForServices(ofType: serviceType, inDomain: domain)
    }
    
    public func stopBrowsing() {
        netServiceBrowser.stop()
    }
}

extension ServiceBrowser: NetServiceBrowserDelegate {
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        delegate?.serviceBrowser(self, didFindService: service)
    }
    
    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        delegate?.serviceBrowser(self, didRemoveService: service)
    }
    
    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch error: [String : NSNumber]) {
        delegate?.serviceBrowser(self, didFailWithError: NSError(domain: "ServiceBrowser", code: -1, userInfo: error))
    }
}
```

#### 3.2 Network Client
**File**: `Sources/AppTrafficInspectorKit/Communication/NetworkClient.swift`
```swift
import Foundation
import Network

public protocol NetworkClientDelegate: AnyObject {
    func networkClient(_ client: NetworkClient, didConnectTo service: NetService)
    func networkClient(_ client: NetworkClient, didDisconnectFrom service: NetService)
    func networkClient(_ client: NetworkClient, didFailWithError error: Error)
}

public class NetworkClient {
    public weak var delegate: NetworkClientDelegate?
    private var connections: [NWConnection] = []
    
    public func connect(to service: NetService) {
        guard let addresses = service.addresses else { return }
        
        for addressData in addresses {
            let connection = NWConnection(to: .hostPort(host: .ipv4(.any), port: .any), using: .tcp)
            connection.stateUpdateHandler = { [weak self] state in
                self?.handleConnectionStateChange(state, for: service)
            }
            connection.start(queue: .global())
            connections.append(connection)
        }
    }
    
    public func sendPacket(_ packet: RequestPacket) {
        do {
            let data = try JSONEncoder().encode(packet)
            let lengthData = withUnsafeBytes(of: UInt64(data.count).bigEndian) { Data($0) }
            let packetData = lengthData + data
            
            for connection in connections {
                connection.send(content: packetData, completion: .contentProcessed { error in
                    if let error = error {
                        print("Failed to send packet: \(error)")
                    }
                })
            }
        } catch {
            print("Failed to encode packet: \(error)")
        }
    }
    
    private func handleConnectionStateChange(_ state: NWConnection.State, for service: NetService) {
        switch state {
        case .ready:
            delegate?.networkClient(self, didConnectTo: service)
        case .failed(let error):
            delegate?.networkClient(self, didFailWithError: error)
        case .cancelled:
            delegate?.networkClient(self, didDisconnectFrom: service)
        default:
            break
        }
    }
}
```

### Phase 4: Method Swizzling & Interception (Week 3-4)

#### 4.1 Method Swizzler
**File**: `Sources/AppTrafficInspectorKit/Interception/MethodSwizzler.swift`
```swift
import Foundation
import ObjectiveC

public class MethodSwizzler {
    
    public static func swizzleMethod(
        originalSelector: Selector,
        swizzledSelector: Selector,
        for class: AnyClass
    ) -> Bool {
        guard let originalMethod = class_getInstanceMethod(`class`, originalSelector),
              let swizzledMethod = class_getInstanceMethod(`class`, swizzledSelector) else {
            return false
        }
        
        let didAddMethod = class_addMethod(
            `class`,
            originalSelector,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )
        
        if didAddMethod {
            class_replaceMethod(
                `class`,
                swizzledSelector,
                method_getImplementation(originalMethod),
                method_getTypeEncoding(originalMethod)
            )
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
        
        return true
    }
    
    public static func swizzleClassMethod(
        originalSelector: Selector,
        swizzledSelector: Selector,
        for class: AnyClass
    ) -> Bool {
        guard let originalMethod = class_getClassMethod(`class`, originalSelector),
              let swizzledMethod = class_getClassMethod(`class`, swizzledSelector) else {
            return false
        }
        
        method_exchangeImplementations(originalMethod, swizzledMethod)
        return true
    }
}
```

#### 4.2 URLSession Interceptor
**File**: `Sources/AppTrafficInspectorKit/Interception/URLSessionInterceptor.swift`
```swift
import Foundation

public protocol URLSessionInterceptorDelegate: AnyObject {
    func urlSessionInterceptor(_ interceptor: URLSessionInterceptor, didStart task: URLSessionTask)
    func urlSessionInterceptor(_ interceptor: URLSessionInterceptor, didReceive response: URLResponse, for task: URLSessionTask)
    func urlSessionInterceptor(_ interceptor: URLSessionInterceptor, didReceive data: Data, for task: URLSessionTask)
    func urlSessionInterceptor(_ interceptor: URLSessionInterceptor, didFinishWith error: Error?, for task: URLSessionTask)
}

public class URLSessionInterceptor: NSObject {
    public weak var delegate: URLSessionInterceptorDelegate?
    private static var isSwizzled = false
    
    public init(delegate: URLSessionInterceptorDelegate) {
        self.delegate = delegate
        super.init()
        Self.swizzleMethods()
    }
    
    private static func swizzleMethods() {
        guard !isSwizzled else { return }
        
        // Swizzle URLSessionTask resume method
        if let taskClass = NSClassFromString("__NSCFURLSessionTask") {
            let originalResume = #selector(URLSessionTask.resume)
            let swizzledResume = #selector(URLSessionTask.swizzledResume)
            MethodSwizzler.swizzleMethod(originalSelector: originalResume, swizzledSelector: swizzledResume, for: taskClass)
        }
        
        // Swizzle URLSessionConnection methods
        if let connectionClass = NSClassFromString("__NSCFURLLocalSessionConnection") {
            // Handle different iOS versions
            if #available(iOS 13.0, *) {
                let originalDidReceiveResponse = NSSelectorFromString("_didReceiveResponse:sniff:rewrite:")
                let swizzledDidReceiveResponse = #selector(URLSessionConnection.swizzledDidReceiveResponse(_:sniff:rewrite:))
                MethodSwizzler.swizzleMethod(originalSelector: originalDidReceiveResponse, swizzledSelector: swizzledDidReceiveResponse, for: connectionClass)
            } else {
                let originalDidReceiveResponse = NSSelectorFromString("_didReceiveResponse:sniff:")
                let swizzledDidReceiveResponse = #selector(URLSessionConnection.swizzledDidReceiveResponse(_:sniff:))
                MethodSwizzler.swizzleMethod(originalSelector: originalDidReceiveResponse, swizzledSelector: swizzledDidReceiveResponse, for: connectionClass)
            }
            
            let originalDidReceiveData = NSSelectorFromString("_didReceiveData:")
            let swizzledDidReceiveData = #selector(URLSessionConnection.swizzledDidReceiveData(_:))
            MethodSwizzler.swizzleMethod(originalSelector: originalDidReceiveData, swizzledSelector: swizzledDidReceiveData, for: connectionClass)
            
            let originalDidFinishWithError = NSSelectorFromString("_didFinishWithError:")
            let swizzledDidFinishWithError = #selector(URLSessionConnection.swizzledDidFinishWithError(_:))
            MethodSwizzler.swizzleMethod(originalSelector: originalDidFinishWithError, swizzledSelector: swizzledDidFinishWithError, for: connectionClass)
        }
        
        isSwizzled = true
    }
}

// MARK: - URLSessionTask Swizzling
extension URLSessionTask {
    @objc func swizzledResume() {
        // Notify delegate
        if let interceptor = URLSessionInterceptor.shared {
            interceptor.delegate?.urlSessionInterceptor(interceptor, didStart: self)
        }
        
        // Call original implementation
        swizzledResume()
    }
}

// MARK: - URLSessionConnection Swizzling
extension NSObject {
    @objc func swizzledDidReceiveResponse(_ response: URLResponse, sniff: Bool, rewrite: Bool) {
        // Notify delegate
        if let interceptor = URLSessionInterceptor.shared,
           let task = value(forKey: "task") as? URLSessionTask {
            interceptor.delegate?.urlSessionInterceptor(interceptor, didReceive: response, for: task)
        }
        
        // Call original implementation
        swizzledDidReceiveResponse(response, sniff: sniff, rewrite: rewrite)
    }
    
    @objc func swizzledDidReceiveResponse(_ response: URLResponse, sniff: Bool) {
        // Notify delegate
        if let interceptor = URLSessionInterceptor.shared,
           let task = value(forKey: "task") as? URLSessionTask {
            interceptor.delegate?.urlSessionInterceptor(interceptor, didReceive: response, for: task)
        }
        
        // Call original implementation
        swizzledDidReceiveResponse(response, sniff: sniff)
    }
    
    @objc func swizzledDidReceiveData(_ data: Data) {
        // Notify delegate
        if let interceptor = URLSessionInterceptor.shared,
           let task = value(forKey: "task") as? URLSessionTask {
            interceptor.delegate?.urlSessionInterceptor(interceptor, didReceive: data, for: task)
        }
        
        // Call original implementation
        swizzledDidReceiveData(data)
    }
    
    @objc func swizzledDidFinishWithError(_ error: Error?) {
        // Notify delegate
        if let interceptor = URLSessionInterceptor.shared,
           let task = value(forKey: "task") as? URLSessionTask {
            interceptor.delegate?.urlSessionInterceptor(interceptor, didFinishWith: error, for: task)
        }
        
        // Call original implementation
        swizzledDidFinishWithError(error)
    }
}
```

### Phase 5: Core Controller & Public API (Week 4-5)

#### 5.1 Main Controller
**File**: `Sources/AppTrafficInspectorKit/Core/TrafficInspector.swift`
```swift
import Foundation

public protocol TrafficInspectorDelegate: AnyObject {
    func trafficInspector(_ inspector: TrafficInspector, willSend packet: RequestPacket) -> RequestPacket?
}

public class TrafficInspector: NSObject {
    public weak var delegate: TrafficInspectorDelegate?
    
    private let configuration: Configuration
    private let serviceBrowser: ServiceBrowser
    private let networkClient: NetworkClient
    private let urlSessionInterceptor: URLSessionInterceptor
    private let urlConnectionInterceptor: URLConnectionInterceptor
    
    private var activeRequests: [String: NetworkRequest] = [:]
    private let requestQueue = DispatchQueue(label: "com.apptrafficinspector.requests", attributes: .concurrent)
    
    public init(configuration: Configuration = .default) {
        self.configuration = configuration
        self.serviceBrowser = ServiceBrowser(serviceType: configuration.netServiceType, domain: configuration.netServiceDomain)
        self.networkClient = NetworkClient()
        self.urlSessionInterceptor = URLSessionInterceptor(delegate: self)
        self.urlConnectionInterceptor = URLConnectionInterceptor(delegate: self)
        
        super.init()
        
        setupDelegates()
        startServiceDiscovery()
    }
    
    private func setupDelegates() {
        serviceBrowser.delegate = self
        networkClient.delegate = self
    }
    
    private func startServiceDiscovery() {
        serviceBrowser.startBrowsing()
    }
    
    private func sendPacket(_ packet: RequestPacket) {
        // Allow delegate to modify or filter packet
        let finalPacket = delegate?.trafficInspector(self, willSend: packet) ?? packet
        
        guard finalPacket != nil else { return }
        
        networkClient.sendPacket(finalPacket!)
    }
}

// MARK: - URLSessionInterceptorDelegate
extension TrafficInspector: URLSessionInterceptorDelegate {
    public func urlSessionInterceptor(_ interceptor: URLSessionInterceptor, didStart task: URLSessionTask) {
        requestQueue.async(flags: .barrier) {
            let request = NetworkRequest(task: task)
            self.activeRequests[request.id] = request
            self.sendPacket(request.createPacket(configuration: self.configuration))
        }
    }
    
    public func urlSessionInterceptor(_ interceptor: URLSessionInterceptor, didReceive response: URLResponse, for task: URLSessionTask) {
        requestQueue.async(flags: .barrier) {
            guard let request = self.activeRequests[task.taskIdentifier.description] else { return }
            request.updateResponse(response)
            self.sendPacket(request.createPacket(configuration: self.configuration))
        }
    }
    
    public func urlSessionInterceptor(_ interceptor: URLSessionInterceptor, didReceive data: Data, for task: URLSessionTask) {
        requestQueue.async(flags: .barrier) {
            guard let request = self.activeRequests[task.taskIdentifier.description] else { return }
            request.appendResponseData(data)
        }
    }
    
    public func urlSessionInterceptor(_ interceptor: URLSessionInterceptor, didFinishWith error: Error?, for task: URLSessionTask) {
        requestQueue.async(flags: .barrier) {
            guard let request = self.activeRequests[task.taskIdentifier.description] else { return }
            request.complete(with: error)
            self.sendPacket(request.createPacket(configuration: self.configuration))
            self.activeRequests.removeValue(forKey: task.taskIdentifier.description)
        }
    }
}

// MARK: - ServiceBrowserDelegate
extension TrafficInspector: ServiceBrowserDelegate {
    public func serviceBrowser(_ browser: ServiceBrowser, didFindService service: NetService) {
        networkClient.connect(to: service)
    }
    
    public func serviceBrowser(_ browser: ServiceBrowser, didRemoveService service: NetService) {
        // Handle service removal if needed
    }
    
    public func serviceBrowser(_ browser: ServiceBrowser, didFailWithError error: Error) {
        print("Service browser failed: \(error)")
    }
}

// MARK: - NetworkClientDelegate
extension TrafficInspector: NetworkClientDelegate {
    public func networkClient(_ client: NetworkClient, didConnectTo service: NetService) {
        print("Connected to service: \(service.name)")
    }
    
    public func networkClient(_ client: NetworkClient, didDisconnectFrom service: NetService) {
        print("Disconnected from service: \(service.name)")
    }
    
    public func networkClient(_ client: NetworkClient, didFailWithError error: Error) {
        print("Network client failed: \(error)")
    }
}
```

#### 5.2 Public API
**File**: `Sources/AppTrafficInspectorKit/AppTrafficInspectorKit.swift`
```swift
import Foundation

/// AppTrafficInspectorKit - A Swift library for inspecting network traffic in iOS apps
public class AppTrafficInspectorKit {
    
    private static var sharedInstance: TrafficInspector?
    
    /// Start network traffic inspection with default configuration
    public static func start() {
        start(with: .default)
    }
    
    /// Start network traffic inspection with custom configuration
    public static func start(with configuration: Configuration) {
        sharedInstance = TrafficInspector(configuration: configuration)
    }
    
    /// Stop network traffic inspection
    public static func stop() {
        sharedInstance = nil
    }
    
    /// Set delegate for custom packet filtering/modification
    public static func setDelegate(_ delegate: TrafficInspectorDelegate?) {
        sharedInstance?.delegate = delegate
    }
    
    /// Check if traffic inspection is currently active
    public static var isActive: Bool {
        return sharedInstance != nil
    }
}
```

### Phase 6: Comprehensive Testing (Week 5-6)

#### 6.1 Test Structure
Each component needs comprehensive unit tests covering:

1. **Model Tests**: Initialization, Codable conformance, equality
2. **Utility Tests**: Device identification, project name extraction
3. **Configuration Tests**: Default values, custom configuration
4. **Network Tests**: Service discovery, connection handling, packet transmission
5. **Interceptor Tests**: Method swizzling, delegate callbacks
6. **Integration Tests**: End-to-end functionality

#### 6.2 Example Test Files (Swift Testing)

**File**: `Tests/AppTrafficInspectorKitTests/Core/TrafficInspectorTests.swift`
```swift
import Testing
@testable import AppTrafficInspectorKit

@Suite("TrafficInspector")
struct TrafficInspectorTests {
    @Test
    func initialization_setsDelegate() {
        let inspector = TrafficInspector(configuration: .default)
        inspector.delegate = MockTrafficInspectorDelegate()
        #expect(inspector.delegate != nil)
    }

    @Test
    func delegate_canModifyOrDropPacket() {
        let inspector = TrafficInspector(configuration: .default)
        let mock = MockTrafficInspectorDelegate()
        inspector.delegate = mock
        let packet = RequestPacket(
            packetId: "test",
            requestInfo: RequestInfo(
                url: URL(string: "https://example.com")!,
                requestHeaders: [:],
                requestMethod: "GET",
                startDate: Date()
            ),
            project: ProjectInfo(projectName: "Test"),
            device: DeviceInfo(deviceId: "test", deviceName: "Test", deviceDescription: "Test")
        )
        _ = inspector.delegate?.trafficInspector(inspector, willSend: packet)
        #expect(mock.willSendPacketCalled)
    }
}

final class MockTrafficInspectorDelegate: TrafficInspectorDelegate {
    var willSendPacketCalled = false
    func trafficInspector(_ inspector: TrafficInspector, willSend packet: RequestPacket) -> RequestPacket? {
        willSendPacketCalled = true
        return packet
    }
}
```

### Phase 7: Documentation & Examples (Week 6)

#### 7.1 README.md
```markdown
# AppTrafficInspectorKit

A Swift library for inspecting network traffic in iOS applications during development and debugging.

## Features

- 🔍 **Automatic Network Interception**: Captures all URLSession and URLConnection requests
- 📱 **Device Discovery**: Automatic Bonjour-based service discovery
- 📊 **Rich Data Capture**: Request/response headers, body data, timing information
- 🎯 **Easy Integration**: Simple API with minimal setup required
- 🔒 **Privacy Focused**: Only works in debug builds, no production impact

## Installation

Add AppTrafficInspectorKit to your project using Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/gingofthesouth/AppTrafficInspectorKit.git", from: "1.0.0")
]
```

## Usage

### Basic Usage

```swift
import AppTrafficInspectorKit

// Start with default configuration
AppTrafficInspectorKit.start()
```

### Custom Configuration

```swift
let configuration = Configuration(
    project: ProjectInfo(projectName: "MyApp"),
    device: DeviceInfo(deviceId: "custom-id", deviceName: "Custom Device", deviceDescription: "Custom Description"),
    netServicePort: 43435,
    netServiceType: "_AppTraffic._tcp"
)

AppTrafficInspectorKit.start(with: configuration)
```

### Packet Filtering

```swift
class MyTrafficDelegate: TrafficInspectorDelegate {
    func trafficInspector(_ inspector: TrafficInspector, willSend packet: RequestPacket) -> RequestPacket? {
        // Filter out sensitive requests
        if packet.requestInfo.url.host?.contains("sensitive-api") == true {
            return nil
        }
        
        // Modify packet before sending
        return packet
    }
}

AppTrafficInspectorKit.setDelegate(MyTrafficDelegate())
```

## Requirements

- iOS 12.0+ / macOS 10.15+
- Swift 5.9+
- Xcode 15.0+

## License

MIT License - see LICENSE file for details
```

#### 7.2 Example App
Create a sample iOS app demonstrating the library usage with:
- Basic network requests
- Custom configuration
- Packet filtering examples
- Error handling

## 🧪 Testing Strategy

### Unit Test Coverage Goals
- **Models**: 100% coverage for data structures
- **Utilities**: 100% coverage for helper functions
- **Configuration**: 100% coverage for configuration management
- **Network**: 90% coverage for network communication
- **Interception**: 80% coverage (method swizzling is hard to test)

### Integration Test Scenarios
1. **Basic Request Capture**: Verify URLSession requests are captured
2. **Service Discovery**: Test Bonjour service discovery
3. **Packet Transmission**: Verify packets are sent correctly
4. **Error Handling**: Test network failures and recovery
5. **Memory Management**: Ensure no retain cycles or memory leaks

### Performance Testing
- **Memory Usage**: Monitor memory consumption during operation
- **CPU Impact**: Measure performance impact of method swizzling
- **Network Overhead**: Ensure minimal impact on app's network performance

## 📦 Distribution Strategy

### Swift Package Manager
- Primary distribution method
- Semantic versioning (1.0.0, 1.1.0, etc.)
- Platform-specific builds for iOS/macOS

### Versioning Strategy
- **Major**: Breaking API changes
- **Minor**: New features, backward compatible
- **Patch**: Bug fixes, performance improvements

### Release Checklist
- [ ] All tests passing
- [ ] Documentation updated
- [ ] Example app tested
- [ ] Performance benchmarks met
- [ ] Memory leak tests passed
- [ ] Platform compatibility verified

## 🚀 Deployment Timeline

| Week | Phase | Deliverables |
|------|-------|-------------|
| 1 | Foundation | Data models, utilities, basic tests |
| 2 | Network Layer | Service discovery, socket communication |
| 3 | Interception | Method swizzling, URLSession/URLConnection hooks |
| 4 | Core Logic | Main controller, request tracking |
| 5 | Public API | Simple integration interface |
| 6 | Testing | Comprehensive test suite, integration tests |
| 7 | Documentation | README, examples, sample app |
| 8 | Polish | Performance optimization, final testing |

This implementation plan provides a comprehensive roadmap for creating a Swift-native network traffic inspection library that replicates and improves upon Bagel's functionality while maintaining modern Swift best practices and comprehensive testing coverage.
