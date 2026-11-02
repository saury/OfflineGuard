import Foundation
import Network
import Darwin

// Exercise the Swift overlay itself, not just calls to Network.framework's C API.
precondition(dlopen("build/OfflineGuard-macOS.dylib", RTLD_NOW | RTLD_GLOBAL) != nil)
let monitor = NWPathMonitor()
let done = DispatchSemaphore(value: 0)
monitor.pathUpdateHandler = { path in
    precondition(path.status == .unsatisfied, "Swift NWPath still reports a usable network")
    precondition(!path.supportsDNS && !path.supportsIPv4 && !path.supportsIPv6)
    precondition(!path.isExpensive && !path.isConstrained)
    precondition(!path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.cellular))
    precondition(path.availableInterfaces.isEmpty)
    precondition(path.unsatisfiedReason == .notAvailable)
    done.signal()
}
monitor.start(queue: DispatchQueue(label: "OfflineGuard.SwiftPathTest"))
precondition(done.wait(timeout: .now() + 5) == .success, "No Swift path callback delivered")
monitor.cancel()
print("PASS: Swift NWPathMonitor reports offline with no usable interfaces.")
