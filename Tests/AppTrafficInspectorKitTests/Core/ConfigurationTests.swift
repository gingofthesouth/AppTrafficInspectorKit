import Foundation
import Testing
@testable import AppTrafficInspectorKit

@Suite("Configuration")
struct ConfigurationTests {
    @Test
    func defaultInitialization_usesBundleMainForProjectName() throws {
        let config = Configuration()
        
        // Should use Bundle.main.infoDictionary["CFBundleName"] or "App" as fallback
        let expectedName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "App"
        #expect(config.project.projectName == expectedName)
    }
    
    @Test
    func defaultInitialization_generatesUUIDForDeviceId() throws {
        let config1 = Configuration()
        let config2 = Configuration()
        
        // Each should have unique UUID
        #expect(config1.device.deviceId != config2.device.deviceId)
        
        // Should be valid UUID format
        #expect(UUID(uuidString: config1.device.deviceId) != nil)
        #expect(UUID(uuidString: config2.device.deviceId) != nil)
    }
    
    @Test
    func defaultInitialization_usesHostCurrentForDeviceName() throws {
        let config = Configuration()
        
        let expectedName = Host.current().localizedName ?? "Device"
        #expect(config.device.deviceName == expectedName)
    }
    
    @Test
    func defaultInitialization_usesProcessInfoForDeviceDescription() throws {
        let config = Configuration()
        
        let expectedDescription = ProcessInfo.processInfo.operatingSystemVersionString
        #expect(config.device.deviceDescription == expectedDescription)
    }
    
    @Test
    func customValues_arePreserved() throws {
        let customProject = ProjectInfo(projectName: "CustomApp")
        let customDevice = DeviceInfo(deviceId: "custom-id", deviceName: "CustomDevice", deviceDescription: "Custom Desc")
        
        let config = Configuration(
            netServiceType: "_Custom._tcp",
            netServiceDomain: "custom.local",
            project: customProject,
            device: customDevice,
            maxBodyBytes: 256 * 1024
        )
        
        #expect(config.netServiceType == "_Custom._tcp")
        #expect(config.netServiceDomain == "custom.local")
        #expect(config.project.projectName == "CustomApp")
        #expect(config.device.deviceId == "custom-id")
        #expect(config.device.deviceName == "CustomDevice")
        #expect(config.device.deviceDescription == "Custom Desc")
        #expect(config.maxBodyBytes == 256 * 1024)
    }
    
    @Test
    func maxBodyBytes_nilVsSetValue() throws {
        let configNil = Configuration(maxBodyBytes: nil)
        #expect(configNil.maxBodyBytes == nil)
        
        let configSet = Configuration(maxBodyBytes: 64 * 1024)
        #expect(configSet.maxBodyBytes == 64 * 1024)
    }
    
    @Test
    func defaultValues_useExpectedDefaults() throws {
        let config = Configuration()
        
        #expect(config.netServiceType == "_AppTraffic._tcp")
        #expect(config.netServiceDomain == "")
    }
}
