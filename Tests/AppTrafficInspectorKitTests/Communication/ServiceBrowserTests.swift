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
}
