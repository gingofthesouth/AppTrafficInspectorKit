import Foundation
import Testing
@testable import AppTrafficInspectorKit

final class ServiceBrowserDelegateRecorder: ServiceBrowserDelegate {
    private(set) var found: [NetService] = []
    private(set) var removed: [NetService] = []
    private(set) var errors: [Error] = []

    func serviceBrowser(_ browser: ServiceBrowser, didFindService service: NetService) { found.append(service) }
    func serviceBrowser(_ browser: ServiceBrowser, didRemoveService service: NetService) { removed.append(service) }
    func serviceBrowser(_ browser: ServiceBrowser, didFailWithError error: Error) { errors.append(error) }
}

@Suite("ServiceBrowser")
struct ServiceBrowserTests {
    @MainActor @Test
    func forwardsFindAndRemove() throws {
        let sb = ServiceBrowser(serviceType: "_AppTraffic._tcp", domain: "")
        let rec = ServiceBrowserDelegateRecorder()
        sb.delegate = rec

        let service = NetService(domain: "local.", type: "_AppTraffic._tcp", name: "MacReceiver", port: 43435)
        sb._simulateDidFind(service)
        sb._simulateDidRemove(service)

        #expect(rec.found.count == 1)
        #expect(rec.removed.count == 1)
        #expect(rec.found.first?.name == "MacReceiver")
    }
    
    @MainActor @Test
    func errorDelegateCallback_onBrowseFailure() throws {
        let sb = ServiceBrowser(serviceType: "_AppTraffic._tcp", domain: "")
        let rec = ServiceBrowserDelegateRecorder()
        sb.delegate = rec
        
        let error = NSError(domain: "ServiceBrowser", code: -1, userInfo: [NSLocalizedDescriptionKey: "Browse failed"])
        sb._simulateDidFail(error)
        
        #expect(rec.errors.count == 1)
        #expect(rec.errors.first?.localizedDescription == "Browse failed")
    }
    
    @MainActor @Test
    func multipleServices_foundAndRemoved() throws {
        let sb = ServiceBrowser(serviceType: "_AppTraffic._tcp", domain: "")
        let rec = ServiceBrowserDelegateRecorder()
        sb.delegate = rec
        
        let service1 = NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Mac1", port: 43435)
        let service2 = NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Mac2", port: 43436)
        let service3 = NetService(domain: "local.", type: "_AppTraffic._tcp", name: "Mac3", port: 43437)
        
        sb._simulateDidFind(service1)
        sb._simulateDidFind(service2)
        sb._simulateDidFind(service3)
        
        #expect(rec.found.count == 3)
        #expect(rec.found.map { $0.name } == ["Mac1", "Mac2", "Mac3"])
        
        sb._simulateDidRemove(service2)
        sb._simulateDidRemove(service1)
        
        #expect(rec.removed.count == 2)
        #expect(rec.removed.map { $0.name } == ["Mac2", "Mac1"])
    }
}
