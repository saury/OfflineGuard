#import "NetworkStateHooks.h"
#import "ReachabilityCallback.h"
#import "fishhook.h"
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <objc/runtime.h>

// Older Reachability libraries still use these APIs on current iOS versions.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static Boolean (*originalGetFlags)(SCNetworkReachabilityRef, SCNetworkReachabilityFlags *);
static Boolean (*originalSetCallback)(SCNetworkReachabilityRef, SCNetworkReachabilityCallBack,
                                      SCNetworkReachabilityContext *);
static void (*originalMonitorStart)(nw_path_monitor_t);

// Only take addresses here. The implementations use Swift's method ABI.
extern void OGSwiftPathStatus(void);
extern void OGSwiftPathDNS(void);
extern void OGSwiftPathIPv4(void);
extern void OGSwiftPathIPv6(void);
extern void OGSwiftPathExpensive(void);
extern void OGSwiftPathConstrained(void);
extern void OGSwiftPathInterfaces(void);
extern void OGSwiftPathReason(void);
extern void OGSwiftPathUsesInterface(void);

static Boolean offlineGetFlags(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags) {
    if (!target || !flags) return originalGetFlags(target, flags);
    *flags = 0;
    return TRUE;
}

static Boolean offlineSetCallback(SCNetworkReachabilityRef target,
                                   SCNetworkReachabilityCallBack callback,
                                   SCNetworkReachabilityContext *context) {
    return OGSetOfflineReachabilityCallback(target, callback, context, originalSetCallback);
}

static nw_path_status_t offlinePathStatus(nw_path_t path) {
    return nw_path_status_unsatisfied;
}

static nw_path_unsatisfied_reason_t offlinePathReason(nw_path_t path) {
    return nw_path_unsatisfied_reason_not_available;
}

static bool offlinePathBoolean(nw_path_t path) { return false; }
static bool offlinePathUsesInterface(nw_path_t path, nw_interface_type_t type) { return false; }
static void offlinePathInterfaces(nw_path_t path, nw_path_enumerate_interfaces_block_t block) {}
static void offlinePathGateways(nw_path_t path, nw_path_enumerate_gateways_block_t block) {}
static CFDictionaryRef offlineWiFiInfo(CFStringRef interfaceName) { return NULL; }

static void offlineMonitorStart(nw_path_monitor_t monitor) {
    // Let the system produce an actually unsatisfied path object. Swift's
    // overlay may read a path through shared-cache calls that bypass rebinding.
    const nw_interface_type_t types[] = {
        nw_interface_type_wifi, nw_interface_type_cellular, nw_interface_type_wired,
        nw_interface_type_loopback, nw_interface_type_other
    };
    for (size_t i = 0; i < sizeof(types) / sizeof(types[0]); ++i) {
        nw_path_monitor_prohibit_interface_type(monitor, types[i]);
    }
    originalMonitorStart(monitor);
}

static void maskRadioTechnology(void) {
#if TARGET_OS_IOS
    // Loading CoreTelephony explicitly also makes the class available before
    // the guest creates its first network-info object. Keep the handle open.
    dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY | RTLD_LOCAL);
    Class cls = NSClassFromString(@"CTTelephonyNetworkInfo");
    for (NSString *name in @[@"currentRadioAccessTechnology", @"serviceCurrentRadioAccessTechnology", @"dataServiceIdentifier"]) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) continue;
        IMP replacement = imp_implementationWithBlock(^id(id object) { return nil; });
        if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
            method_setImplementation(method, replacement);
        }
    }
#endif
}

int OGInstallNetworkStateHooks(void) {
    originalGetFlags = dlsym(RTLD_DEFAULT, "SCNetworkReachabilityGetFlags");
    originalSetCallback = dlsym(RTLD_DEFAULT, "SCNetworkReachabilitySetCallback");
    originalMonitorStart = dlsym(RTLD_DEFAULT, "nw_path_monitor_start");
    if (!originalGetFlags || !originalSetCallback || !originalMonitorStart) return -1;
    struct rebinding hooks[] = {
        { "SCNetworkReachabilityGetFlags", (void *)offlineGetFlags, NULL },
        { "SCNetworkReachabilitySetCallback", (void *)offlineSetCallback, NULL },
        { "nw_path_get_status", (void *)offlinePathStatus, NULL },
        { "nw_path_monitor_start", (void *)offlineMonitorStart, NULL },
        { "nw_path_get_unsatisfied_reason", (void *)offlinePathReason, NULL },
        { "nw_path_is_expensive", (void *)offlinePathBoolean, NULL },
        { "nw_path_is_constrained", (void *)offlinePathBoolean, NULL },
        { "nw_path_has_ipv4", (void *)offlinePathBoolean, NULL },
        { "nw_path_has_ipv6", (void *)offlinePathBoolean, NULL },
        { "nw_path_has_dns", (void *)offlinePathBoolean, NULL },
        { "nw_path_uses_interface_type", (void *)offlinePathUsesInterface, NULL },
        { "nw_path_enumerate_interfaces", (void *)offlinePathInterfaces, NULL },
        { "nw_path_enumerate_gateways", (void *)offlinePathGateways, NULL },
        { "CNCopyCurrentNetworkInfo", (void *)offlineWiFiInfo, NULL },
        { "$s7Network6NWPathV6statusAC6StatusOvg", (void *)OGSwiftPathStatus, NULL },
        { "$s7Network6NWPathV11supportsDNSSbvg", (void *)OGSwiftPathDNS, NULL },
        { "$s7Network6NWPathV12supportsIPv4Sbvg", (void *)OGSwiftPathIPv4, NULL },
        { "$s7Network6NWPathV12supportsIPv6Sbvg", (void *)OGSwiftPathIPv6, NULL },
        { "$s7Network6NWPathV11isExpensiveSbvg", (void *)OGSwiftPathExpensive, NULL },
        { "$s7Network6NWPathV13isConstrainedSbvg", (void *)OGSwiftPathConstrained, NULL },
        { "$s7Network6NWPathV19availableInterfacesSayAA11NWInterfaceVGvg", (void *)OGSwiftPathInterfaces, NULL },
        { "$s7Network6NWPathV17unsatisfiedReasonAC011UnsatisfiedE0Ovg", (void *)OGSwiftPathReason, NULL },
        { "$s7Network6NWPathV17usesInterfaceTypeySbAA11NWInterfaceV0dE0OF", (void *)OGSwiftPathUsesInterface, NULL },
    };
    maskRadioTechnology();
    return rebind_symbols(hooks, sizeof(hooks) / sizeof(hooks[0]));
}
