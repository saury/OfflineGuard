#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <SystemConfiguration/SystemConfiguration.h>
#include <arpa/inet.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdatomic.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

typedef struct {
    atomic_int retains;
    atomic_int releases;
    dispatch_semaphore_t done;
} CallbackContext;

static const void *retainInfo(const void *info) {
    CallbackContext *context = (CallbackContext *)info;
    atomic_fetch_add(&context->retains, 1);
    return info;
}

static void releaseInfo(const void *info) {
    CallbackContext *context = (CallbackContext *)info;
    atomic_fetch_add(&context->releases, 1);
}

static void flagsChanged(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info) {
    assert(flags == 0);
    CallbackContext *context = info;
    dispatch_semaphore_signal(context->done);
}

static void waitForAtLine(dispatch_semaphore_t semaphore, int line) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) != 0) {
        if (deadline.timeIntervalSinceNow <= 0) {
            fprintf(stderr, "Network-state callback timed out at line %d\n", line);
            abort();
        }
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}
#define waitFor(semaphore) waitForAtLine(semaphore, __LINE__)

static void assertOfflinePath(nw_path_t path) {
    assert(nw_path_get_status(path) == nw_path_status_unsatisfied);
    assert(nw_path_get_unsatisfied_reason(path) == nw_path_unsatisfied_reason_not_available);
    assert(!nw_path_has_dns(path) && !nw_path_has_ipv4(path) && !nw_path_has_ipv6(path));
    assert(!nw_path_is_expensive(path) && !nw_path_is_constrained(path));
    assert(!nw_path_uses_interface_type(path, nw_interface_type_wifi));
    assert(!nw_path_uses_interface_type(path, nw_interface_type_cellular));
    assert(!nw_path_uses_interface_type(path, nw_interface_type_wired));
    assert(!nw_path_uses_interface_type(path, nw_interface_type_loopback));
    __block int interfaces = 0;
    nw_path_enumerate_interfaces(path, ^bool(nw_interface_t interface) { ++interfaces; return true; });
    nw_path_enumerate_gateways(path, ^bool(nw_endpoint_t endpoint) { ++interfaces; return true; });
    assert(interfaces == 0);
}

int main(void) {
    @autoreleasepool {
        alarm(30);
        struct sockaddr_in address = {
            .sin_len = sizeof(address), .sin_family = AF_INET,
            .sin_addr.s_addr = htonl(INADDR_LOOPBACK)
        };
        SCNetworkReachabilityRef target = SCNetworkReachabilityCreateWithAddress(NULL, (struct sockaddr *)&address);
        assert(target);
        SCNetworkReachabilityFlags flags = 0;
        assert(SCNetworkReachabilityGetFlags(target, &flags));
        assert(flags & kSCNetworkReachabilityFlagsReachable);

        dispatch_semaphore_t initial = dispatch_semaphore_create(0);
        nw_path_monitor_t monitor = nw_path_monitor_create();
        __block nw_path_t snapshot;
        nw_path_monitor_set_queue(monitor, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
        nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
            snapshot = path;
            dispatch_semaphore_signal(initial);
        });
        nw_path_monitor_start(monitor);
        waitFor(initial);
        nw_path_monitor_cancel(monitor);

        assert(dlopen("build/OfflineGuard-macOS.dylib", RTLD_NOW | RTLD_GLOBAL));
        flags = UINT32_MAX;
        assert(SCNetworkReachabilityGetFlags(target, &flags) && flags == 0);
        assertOfflinePath(snapshot);
        CFRelease(target);
        address.sin_addr.s_addr = INADDR_ANY;
        target = SCNetworkReachabilityCreateWithAddress(NULL, (struct sockaddr *)&address);

        CallbackContext context = { .done = dispatch_semaphore_create(0) };
        SCNetworkReachabilityContext caller = {
            .version = 0, .info = &context, .retain = retainInfo, .release = releaseInfo
        };
        assert(SCNetworkReachabilitySetCallback(target, flagsChanged, &caller));
        dispatch_queue_t queue = dispatch_queue_create("OfflineGuard.ReachabilityTest", DISPATCH_QUEUE_SERIAL);
        assert(SCNetworkReachabilitySetDispatchQueue(target, queue));
        // Reachability need not emit an initial callback when its flags stay
        // zero. Translation of actual change events is tested with an injected
        // event source in ReachabilityCallbacks.m, without changing host radios.
        assert(SCNetworkReachabilitySetDispatchQueue(target, NULL));
        dispatch_sync(queue, ^{});
        assert(SCNetworkReachabilitySetCallback(target, NULL, NULL));
        assert(atomic_load(&context.retains) > 0);
        assert(atomic_load(&context.retains) == atomic_load(&context.releases));

        // The same callback contract must work for legacy run-loop scheduling.
        CFRelease(target);
        target = SCNetworkReachabilityCreateWithAddress(NULL, (struct sockaddr *)&address);
        assert(SCNetworkReachabilitySetCallback(target, flagsChanged, &caller));
        assert(SCNetworkReachabilityScheduleWithRunLoop(target, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode));
        assert(SCNetworkReachabilityUnscheduleFromRunLoop(target, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode));
        assert(SCNetworkReachabilitySetCallback(target, NULL, NULL));
        CFRelease(target);
        assert(atomic_load(&context.retains) == atomic_load(&context.releases));

        dispatch_semaphore_t updated = dispatch_semaphore_create(0);
        nw_path_monitor_t offlineMonitor = nw_path_monitor_create();
        nw_path_monitor_set_queue(offlineMonitor, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
        nw_path_monitor_set_update_handler(offlineMonitor, ^(nw_path_t path) {
            assertOfflinePath(path);
            dispatch_semaphore_signal(updated);
        });
        nw_path_monitor_start(offlineMonitor);
        waitFor(updated);
        nw_path_monitor_cancel(offlineMonitor);
        puts("PASS: Reachability query, dispatch/run-loop registration and context lifetime; cached and new NWPath snapshots report offline.");
    }
    return 0;
}
