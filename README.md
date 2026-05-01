# AppTrafficInspectorKit

Swift package to capture app HTTP(S) traffic during development and stream it to a Mac receiver over the local network.

## Requirements

- iOS 13.0+ / macOS 10.15+ / tvOS 13.0+ / watchOS 6.0+
- Swift 5.9+
- Xcode 15.0+

## Features

- URLProtocol-based interception (with configuration injection)
- Bonjour discovery of a Mac receiver (`_AppTraffic._tcp`)
- Length-prefixed JSON framing (8-byte big-endian)
- Privacy: redaction hooks and body-size caps
- Swift Testing-first suite

## Installation

Add AppTrafficInspectorKit to your project using Swift Package Manager.

### Xcode

1. File → Add Package Dependencies...
2. Enter the package repository URL
3. Select the version or branch you want to use

### Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/gingofthesouth/AppTrafficInspectorKit.git", from: "1.0.0")
]
```

Then add `AppTrafficInspectorKit` to your target's dependencies.

## Quick Start

The simplest way to get started:

```swift
import AppTrafficInspectorKit

@MainActor
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        #if DEBUG
        AppTrafficInspectorKit.start()
        #endif
        return true
    }
}
```

That's it! The library automatically handles:
- URLProtocol interception setup
- Network connection management
- Service discovery
- Packet transmission

For custom configuration:

```swift
#if DEBUG
let config = Configuration(maxBodyBytes: 64 * 1024)
AppTrafficInspectorKit.start(with: config)
#endif
```

## Usage

### Simple API (Recommended)

For most use cases, the simple API is all you need:

```swift
import AppTrafficInspectorKit

@MainActor
func application(_ application: UIApplication, didFinishLaunchingWithOptions...) -> Bool {
    #if DEBUG
    AppTrafficInspectorKit.start()
    #endif
    return true
}
```

### Advanced Usage

If you need custom implementations of `ConnectionType` or `SchedulerType`, you can use the lower-level API:

```swift
import AppTrafficInspectorKit
import Network

// 1. Install URLProtocol interception
URLSessionConfigurationInjector.install()

// 2. Create your custom implementations
final class CustomConnection: ConnectionType {
    // Your implementation
}

final class CustomScheduler: SchedulerType {
    // Your implementation
}

// 3. Create and start inspector
@MainActor
let config = Configuration(maxBodyBytes: 64 * 1024)
let connFactory: (NetService) -> ConnectionType = { CustomConnection(service: $0) }
let scheduler = CustomScheduler()
let client = NetworkClient(connectionFactory: connFactory, scheduler: scheduler)
let inspector = TrafficInspector(configuration: config, client: client)
```

### Configuration

`Configuration` has sensible defaults. You can customize:

```swift
let config = Configuration(
    netServiceType: "_AppTraffic._tcp",  // Default
    netServiceDomain: "",                 // Default (local network)
    project: ProjectInfo(projectName: "MyApp"),  // Auto-detected from Bundle
    device: DeviceInfo(
        deviceId: UUID().uuidString,      // Auto-generated
        deviceName: Host.current().localizedName ?? "Device",
        deviceDescription: ProcessInfo.processInfo.operatingSystemVersionString
    ),
    maxBodyBytes: 64 * 1024  // Optional: limit body size
)
```

### Mutual TLS (mTLS)

If your app communicates with a server that requires a client certificate, you need to supply a challenge handler to the library. Because the library re-issues intercepted requests through its own internal `URLSession`, authentication challenges from the server arrive at that session rather than at your app's `URLSessionDelegate`. Without a handler, the TLS handshake fails.

Set `TrafficURLProtocol.challengeHandler` before calling `start()`:

```swift
#if DEBUG
TrafficURLProtocol.challengeHandler = { challenge, completionHandler in
    switch challenge.protectionSpace.authenticationMethod {
    case NSURLAuthenticationMethodClientCertificate:
        // Load your identity and respond with a credential.
        let credential = URLCredential(
            identity: yourIdentity,
            certificates: yourCertificateChain,
            persistence: .forSession
        )
        completionHandler(.useCredential, credential)
    default:
        completionHandler(.performDefaultHandling, nil)
    }
}
AppTrafficInspectorKit.start()
#endif
```

The closure signature matches `URLSessionDelegate.urlSession(_:didReceive:completionHandler:)`, so you can forward the challenge directly to any existing delegate rather than duplicating logic:

```swift
TrafficURLProtocol.challengeHandler = { challenge, completionHandler in
    mySessionDelegate.urlSession(
        URLSession.shared,
        didReceive: challenge,
        completionHandler: completionHandler
    )
}
```

If `challengeHandler` is `nil` (the default), all challenges fall back to `.performDefaultHandling`, which is appropriate for servers that do not require client certificates.

### Privacy and Redaction

Use the `TrafficInspectorDelegate` to filter or modify packets before sending:

```swift
class MyTrafficDelegate: TrafficInspectorDelegate {
    func trafficInspector(_ inspector: TrafficInspector, willSend packet: RequestPacket) -> RequestPacket? {
        // Filter out sensitive requests
        if packet.requestInfo.url.host?.contains("sensitive-api") == true {
            return nil  // Don't send this packet
        }
        
        // Optionally modify the packet
        return packet
    }
}

// Set the delegate (works with simple API)
AppTrafficInspectorKit.setDelegate(MyTrafficDelegate())
```

### Lifecycle Management

- **Initialization**: Call `AppTrafficInspectorKit.start()` early in your app lifecycle (e.g., in `application(_:didFinishLaunchingWithOptions:)`).
- **Main Actor**: The simple API is marked `@MainActor`, so ensure initialization happens on the main thread.
- **Cleanup**: Call `AppTrafficInspectorKit.stop()` when you want to stop inspection, or it will automatically stop when the app terminates.

## iOS Info.plist (iOS 14+)

Add these keys to your `Info.plist`:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>This app uses the local network to stream network traffic to a Mac debugging tool.</string>

<key>NSBonjourServices</key>
<array>
    <string>_AppTraffic._tcp</string>
</array>
```

## Wire Contract

See `WIRE_CONTRACT.md` for detailed information about:
- Framing protocol (8-byte big-endian length prefix)
- JSON schema
- Compatibility notes

## Testing

Run tests using Swift Package Manager:

```bash
# Run all tests
swift test

# Run specific test suite
swift test --filter PacketSerializerTests

# Run integration tests (requires Mac receiver)
ENABLE_INTEGRATION_TESTS=1 swift test --filter EndToEndTests
```

Swift Testing is used for all test suites (`import Testing`, `@Test`).

## Notes

- **Debug builds only**: This library is intended for development and debugging. Gate its usage via build settings/flags (e.g., `#if DEBUG`) to ensure it's never included in release builds.
- **Privacy**: Be mindful of sensitive data. Configure redaction appropriately using the delegate pattern or body-size limits.
- **URLProtocol registration**: The `URLSessionConfigurationInjector.install()` method automatically injects `TrafficURLProtocol` into `URLSessionConfiguration.default` and `.ephemeral`. Custom configurations must manually add the protocol class.
- **Service discovery**: The inspector automatically discovers Mac receivers on the local network using Bonjour. Ensure your Mac receiver app is running and advertising the `_AppTraffic._tcp` service.
