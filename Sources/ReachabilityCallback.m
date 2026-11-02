#import "ReachabilityCallback.h"
#import <Foundation/Foundation.h>

@interface OGReachabilityContext : NSObject {
@public
    SCNetworkReachabilityCallBack callback;
    SCNetworkReachabilityContext caller;
}
@end

@implementation OGReachabilityContext
- (void)dealloc {
    if (caller.release && caller.info) caller.release(caller.info);
}
@end

static const void *retainContext(const void *info) {
    return CFBridgingRetain((__bridge id)info);
}

static void releaseContext(const void *info) {
    (void)CFBridgingRelease(info);
}

static CFStringRef describeContext(const void *info) {
    OGReachabilityContext *box = (__bridge OGReachabilityContext *)info;
    if (box->caller.copyDescription) return box->caller.copyDescription(box->caller.info);
    return CFSTR("OfflineGuard reachability callback");
}

static void offlineCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info) {
    OGReachabilityContext *box = (__bridge OGReachabilityContext *)info;
    // Use the system's delivery queue/run loop and retain the caller's context.
    box->callback(target, 0, box->caller.info);
}

Boolean OGSetOfflineReachabilityCallback(SCNetworkReachabilityRef target,
                                         SCNetworkReachabilityCallBack callback,
                                         SCNetworkReachabilityContext *context,
                                         OGReachabilitySetter setter) {
    if (!target || !callback || (context && context->version != 0)) {
        return setter(target, callback, context);
    }
    OGReachabilityContext *box = [OGReachabilityContext new];
    box->callback = callback;
    if (context) {
        box->caller = *context;
        if (context->retain && context->info) {
            box->caller.info = (void *)context->retain(context->info);
        }
    }
    SCNetworkReachabilityContext wrapped = {
        .version = 0, .info = (__bridge void *)box,
        .retain = retainContext, .release = releaseContext,
        .copyDescription = describeContext
    };
    // The system retains the wrapper on success and releases it on callback
    // replacement/unregistration. No global target-to-context map is needed.
    return setter(target, offlineCallback, &wrapped);
}
