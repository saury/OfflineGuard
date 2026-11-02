#import "../Sources/ReachabilityCallback.h"
#import <Foundation/Foundation.h>
#include <assert.h>

static SCNetworkReachabilityCallBack registeredCallback;
static SCNetworkReachabilityContext registeredContext;
static int retained, released, delivered;
static int token;

static const void *retainInfo(const void *info) { ++retained; return info; }
static void releaseInfo(const void *info) { ++released; }

// A deterministic source of physical-network changes. It follows the same
// retain/release contract as SCNetworkReachabilitySetCallback.
static Boolean setCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityCallBack callback,
                            SCNetworkReachabilityContext *context) {
    if (registeredContext.release) registeredContext.release(registeredContext.info);
    registeredCallback = callback;
    registeredContext = context ? *context : (SCNetworkReachabilityContext){0};
    if (registeredContext.retain) {
        registeredContext.info = (void *)registeredContext.retain(registeredContext.info);
    }
    return TRUE;
}

static void receiveFlags(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info) {
    assert(info == &token);
    assert(flags == 0);
    ++delivered;
}

static Boolean rejectCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityCallBack callback,
                               SCNetworkReachabilityContext *context) { return FALSE; }

int main(void) {
    @autoreleasepool {
        SCNetworkReachabilityRef target = (SCNetworkReachabilityRef)&token;
        SCNetworkReachabilityContext context = {
            .info = &token, .retain = retainInfo, .release = releaseInfo
        };
        assert(OGSetOfflineReachabilityCallback(target, receiveFlags, &context, setCallback));
        assert(retained == 1 && released == 0);
        registeredCallback(target, kSCNetworkReachabilityFlagsReachable, registeredContext.info);
        registeredCallback(target, UINT32_MAX, registeredContext.info);
        registeredCallback(target, 0, registeredContext.info);
        assert(delivered == 3);
        // Replacement must release the previous caller context exactly once.
        assert(OGSetOfflineReachabilityCallback(target, receiveFlags, &context, setCallback));
        assert(retained == 2 && released == 1);
        assert(OGSetOfflineReachabilityCallback(target, NULL, NULL, setCallback));
        assert(retained == released && !registeredCallback);
        assert(!OGSetOfflineReachabilityCallback(target, receiveFlags, &context, rejectCallback));
        assert(retained == released);
        puts("PASS: simulated online/offline Reachability events all report offline; context replacement, unregistration and failed registration are balanced.");
    }
    return 0;
}
