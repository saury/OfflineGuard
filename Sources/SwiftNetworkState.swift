import Network

// Match the Swift ABI of NWPath's struct accessors, including its self argument
// and the ownership conventions for Array results. C replacements cannot safely
// substitute for these Swift entry points.
extension NWPath {
    public var ogOfflineStatus: Status {
        @_silgen_name("OGSwiftPathStatus") get { .unsatisfied }
    }
    public var ogOfflineSupportsDNS: Bool {
        @_silgen_name("OGSwiftPathDNS") get { false }
    }
    public var ogOfflineSupportsIPv4: Bool {
        @_silgen_name("OGSwiftPathIPv4") get { false }
    }
    public var ogOfflineSupportsIPv6: Bool {
        @_silgen_name("OGSwiftPathIPv6") get { false }
    }
    public var ogOfflineIsExpensive: Bool {
        @_silgen_name("OGSwiftPathExpensive") get { false }
    }
    public var ogOfflineIsConstrained: Bool {
        @_silgen_name("OGSwiftPathConstrained") get { false }
    }
    public var ogOfflineAvailableInterfaces: [NWInterface] {
        @_silgen_name("OGSwiftPathInterfaces") get { [] }
    }
    public var ogOfflineUnsatisfiedReason: UnsatisfiedReason {
        @_silgen_name("OGSwiftPathReason") get { .notAvailable }
    }
    @_silgen_name("OGSwiftPathUsesInterface")
    public func ogOfflineUsesInterfaceType(_ type: NWInterface.InterfaceType) -> Bool { false }
}
