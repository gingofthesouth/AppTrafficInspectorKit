import Foundation
import Testing
@testable import AppTrafficInspectorKit

@Suite("AppTrafficInspectorKit")
struct AppTrafficInspectorKitTests {
    @MainActor
    @Test
    func start_withDefaultConfiguration() throws {
        // Ensure clean state
        AppTrafficInspectorKit.stop()
        #expect(AppTrafficInspectorKit.isActive == false)
        
        // Start with defaults
        AppTrafficInspectorKit.start()
        
        // Verify active
        #expect(AppTrafficInspectorKit.isActive == true)
        
        // Cleanup
        AppTrafficInspectorKit.stop()
    }
    
    @MainActor
    @Test
    func start_withCustomConfiguration() throws {
        AppTrafficInspectorKit.stop()
        
        let customConfig = Configuration(
            netServiceType: "_Custom._tcp",
            netServiceDomain: "custom.local",
            project: ProjectInfo(projectName: "TestApp"),
            device: DeviceInfo(deviceId: "test-id", deviceName: "TestDevice", deviceDescription: "Test"),
            maxBodyBytes: 128 * 1024
        )
        
        AppTrafficInspectorKit.start(with: customConfig)
        #expect(AppTrafficInspectorKit.isActive == true)
        
        AppTrafficInspectorKit.stop()
    }
    
    @MainActor
    @Test
    func stop_clearsSharedInstance() throws {
        AppTrafficInspectorKit.start()
        #expect(AppTrafficInspectorKit.isActive == true)
        
        AppTrafficInspectorKit.stop()
        #expect(AppTrafficInspectorKit.isActive == false)
    }
    
    @MainActor
    @Test
    func setDelegate_setsDelegateOnSharedInspector() throws {
        AppTrafficInspectorKit.stop()
        AppTrafficInspectorKit.start()
        
        let delegate = FilteringDelegate()
        AppTrafficInspectorKit.setDelegate(delegate)
        
        // Verify setDelegate doesn't crash
        // Delegate functionality is tested in TrafficInspectorTests
        AppTrafficInspectorKit.setDelegate(delegate)
        #expect(AppTrafficInspectorKit.isActive == true)
        
        AppTrafficInspectorKit.stop()
    }
    
    @MainActor
    @Test
    func isActive_returnsCorrectState() throws {
        AppTrafficInspectorKit.stop()
        #expect(AppTrafficInspectorKit.isActive == false)
        
        AppTrafficInspectorKit.start()
        #expect(AppTrafficInspectorKit.isActive == true)
        
        AppTrafficInspectorKit.stop()
        #expect(AppTrafficInspectorKit.isActive == false)
    }
    
    @MainActor
    @Test
    func multipleStartStopCycles() throws {
        for _ in 0..<3 {
            AppTrafficInspectorKit.start()
            #expect(AppTrafficInspectorKit.isActive == true)
            
            AppTrafficInspectorKit.stop()
            #expect(AppTrafficInspectorKit.isActive == false)
        }
    }
    
    @MainActor
    @Test
    func delegatePersistenceAcrossStartStop() throws {
        let delegate = FilteringDelegate()
        
        AppTrafficInspectorKit.start()
        AppTrafficInspectorKit.setDelegate(delegate)
        AppTrafficInspectorKit.stop()
        
        // After stop, delegate should be nil
        AppTrafficInspectorKit.start()
        // Setting delegate again should work
        AppTrafficInspectorKit.setDelegate(delegate)
        #expect(AppTrafficInspectorKit.isActive == true)
        
        AppTrafficInspectorKit.stop()
    }
}
