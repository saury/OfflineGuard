#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import "SocketHooks.h"
#import "NetworkStateHooks.h"
#import "BuildVersion.h"

static NSError *offlineError(void) {
    return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet
                          userInfo:@{NSLocalizedDescriptionKey: @"Network access is disabled by OfflineGuard."}];
}

// This also handles legacy NSURLConnection clients using the URL loading system.
@interface OGOfflineProtocol : NSURLProtocol
@end

@implementation OGOfflineProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *scheme = request.URL.scheme.lowercaseString;
    return [@[@"http", @"https", @"ws", @"wss", @"ftp", @"ftps"] containsObject:scheme];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading { [self.client URLProtocol:self didFailWithError:offlineError()]; }
- (void)stopLoading {}
@end

static BOOL isSubclass(Class candidate, Class parent) {
    for (Class current = candidate; current; current = class_getSuperclass(current)) {
        if (current == parent) return YES;
    }
    return NO;
}

static NSUInteger blockSessionTasks(void) {
    // Foundation's task classes override resume at multiple levels. Replacing
    // only NSURLSessionTask's base implementation misses concrete task classes.
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSUInteger installed = 0;
    for (unsigned int i = 0; i < count; ++i) {
        if (!isSubclass(classes[i], NSURLSessionTask.class)) continue;
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(classes[i], &methodCount);
        for (unsigned int j = 0; j < methodCount; ++j) {
            if (method_getName(methods[j]) == @selector(resume)) {
                IMP original = method_getImplementation(methods[j]);
                IMP replacement = imp_implementationWithBlock(^(NSURLSessionTask *task) {
                    // Cancel before allowing Foundation to advance the task.
                    // Preserve the original scheduling/state-machine path for
                    // a task that is already cancelled.
                    [task cancel];
                    ((void (*)(id, SEL))original)(task, @selector(resume));
                });
                method_setImplementation(methods[j], replacement);
                ++installed;
            }
        }
        free(methods);
    }
    free(classes);
    return installed;
}

static void replaceMethod(Class cls, SEL selector, id block) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    IMP replacement = imp_implementationWithBlock(block);
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
        method_setImplementation(method, replacement);
    }
}

static void blockWebSockets(void) {
    // Foundation may leave queued WebSocket operations waiting when a task is
    // cancelled before its first handshake. Complete these operations ourselves.
    // The concrete WebSocket class can inherit from __NSCFLocalSessionTask,
    // rather than the public NSURLSessionWebSocketTask class.
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; ++i) {
        Class cls = classes[i];
        if (!isSubclass(cls, NSURLSessionTask.class)) continue;
        replaceMethod(cls, @selector(receiveMessageWithCompletionHandler:),
                      ^(id task, void (^completion)(NSURLSessionWebSocketMessage *, NSError *)) {
            if (completion) dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                completion(nil, offlineError());
            });
        });
        replaceMethod(cls, @selector(sendMessage:completionHandler:),
                      ^(id task, NSURLSessionWebSocketMessage *message, void (^completion)(NSError *)) {
            if (completion) dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                completion(offlineError());
            });
        });
        replaceMethod(cls, @selector(sendPingWithPongReceiveHandler:), ^(id task, void (^completion)(NSError *)) {
            if (completion) dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                completion(offlineError());
            });
        });
    }
    free(classes);
}

static void blockWebViews(void) {
    // WebKit networking runs in a separate process: socket hooks and
    // NSURLProtocol cannot reach it. Strict mode prevents ALL content loads,
    // including local HTML, whose scripts/subresources could otherwise connect.
    Class cls = WKWebView.class;
    replaceMethod(cls, @selector(loadRequest:), ^id(id view, NSURLRequest *request) { return nil; });
    replaceMethod(cls, @selector(loadHTMLString:baseURL:), ^id(id view, NSString *html, NSURL *base) { return nil; });
    replaceMethod(cls, @selector(loadFileURL:allowingReadAccessToURL:), ^id(id view, NSURL *url, NSURL *root) { return nil; });
    replaceMethod(cls, @selector(loadData:MIMEType:characterEncodingName:baseURL:),
                  ^id(id view, NSData *data, NSString *mime, NSString *encoding, NSURL *base) { return nil; });
    replaceMethod(cls, @selector(loadSimulatedRequest:response:responseData:),
                  ^id(id view, NSURLRequest *request, NSURLResponse *response, NSData *data) { return nil; });
    replaceMethod(cls, @selector(loadSimulatedRequest:responseHTMLString:),
                  ^id(id view, NSURLRequest *request, NSString *html) { return nil; });
    for (NSString *name in @[@"reload", @"reloadFromOrigin", @"goBack", @"goForward"]) {
        replaceMethod(cls, NSSelectorFromString(name), ^id(id view) { return nil; });
    }
    replaceMethod(cls, @selector(goToBackForwardListItem:), ^id(id view, WKBackForwardListItem *item) { return nil; });
    replaceMethod(cls, @selector(evaluateJavaScript:completionHandler:),
                  ^(id view, NSString *script, void (^completion)(id, NSError *)) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, offlineError()); });
    });
    replaceMethod(cls, @selector(evaluateJavaScript:inFrame:inContentWorld:completionHandler:),
                  ^(id view, NSString *script, WKFrameInfo *frame, WKContentWorld *world,
                    void (^completion)(id, NSError *)) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, offlineError()); });
    });
    replaceMethod(cls, @selector(callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:),
                  ^(id view, NSString *script, NSDictionary *arguments, WKFrameInfo *frame,
                    WKContentWorld *world, void (^completion)(id, NSError *)) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, offlineError()); });
    });
}

__attribute__((constructor))
static void installOfflineGuard(void) {
    @autoreleasepool {
        int stateStatus = OGInstallNetworkStateHooks();
        [NSURLProtocol registerClass:OGOfflineProtocol.class];
        NSUInteger taskHooks = blockSessionTasks();
        blockWebSockets();
        blockWebViews();
        int socketStatus = OGInstallSocketHooks();
        NSLog(@"[OfflineGuard %s] Loaded: %lu URLSession resume hooks; WebView loads disabled; socket hooks %@; offline state hooks %@.",
              OG_VERSION, (unsigned long)taskHooks, socketStatus == 0 ? @"OK" : @"FAILED",
              stateStatus == 0 ? @"OK" : @"FAILED");
    }
}
