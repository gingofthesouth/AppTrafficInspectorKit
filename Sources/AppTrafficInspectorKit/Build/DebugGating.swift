import Foundation

public var appTrafficDebugEnabled: Bool {
#if DEBUG
    return true
#else
    return false
#endif
}
