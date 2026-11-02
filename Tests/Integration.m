#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <WebKit/WebKit.h>
#include <arpa/inet.h>
#include <assert.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>

static atomic_int requests;
static atomic_bool stopping;
static ssize_t (*server_send)(int, const void *, size_t, int);

static void *serve(void *context) {
    int listener = *(int *)context;
    while (!atomic_load(&stopping)) {
        struct pollfd descriptor = { .fd = listener, .events = POLLIN };
        if (poll(&descriptor, 1, 50) <= 0) continue;
        int client = accept(listener, NULL, NULL);
        if (client < 0) continue;
        atomic_fetch_add(&requests, 1);
        char buffer[8192];
        struct timeval timeout = { .tv_sec = 1 };
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        if (recv(client, buffer, sizeof(buffer), 0) > 0) {
            const char response[] = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
            server_send(client, response, sizeof(response) - 1, 0);
        }
        close(client);
    }
    return NULL;
}

static void waitForAtLine(dispatch_semaphore_t semaphore, int line) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) != 0) {
        if (deadline.timeIntervalSinceNow <= 0) {
            fprintf(stderr, "Timed out waiting for completion at line %d\n", line);
            abort();
        }
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}
#define waitFor(semaphore) waitForAtLine(semaphore, __LINE__)

static void checkDataTask(NSURLSession *session, NSURL *url, BOOL blocked) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (blocked) {
            assert(error != nil);
            assert([error.domain isEqualToString:NSURLErrorDomain]);
            assert(error.code == NSURLErrorCancelled || error.code == NSURLErrorNotConnectedToInternet);
        } else {
            assert(error == nil);
            assert(data.length == 2);
        }
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    waitFor(done);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        alarm(30);
        BOOL coldStart = argc > 1 && strcmp(argv[1], "--cold") == 0;
        int expectedRequests = coldStart ? 0 : 1;
        int listener = socket(AF_INET, SOCK_STREAM, 0);
        assert(listener >= 0);
        struct sockaddr_in address = {
            .sin_len = sizeof(address), .sin_family = AF_INET,
            .sin_addr.s_addr = htonl(INADDR_LOOPBACK), .sin_port = 0
        };
        assert(bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0);
        socklen_t addressLength = sizeof(address);
        assert(getsockname(listener, (struct sockaddr *)&address, &addressLength) == 0);
        assert(listen(listener, 16) == 0);
        server_send = dlsym(RTLD_DEFAULT, "send");
        assert(server_send);
        pthread_t thread;
        assert(pthread_create(&thread, NULL, serve, &listener) == 0);

        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/probe", ntohs(address.sin_port)]];
        NSURLSession *existingSession = nil;
        if (!coldStart) {
            existingSession = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
            checkDataTask(existingSession, url, NO);
        }
        assert(atomic_load(&requests) == expectedRequests);

        int tcp = socket(AF_INET, SOCK_STREAM, 0);
        int udp = socket(AF_INET, SOCK_DGRAM, 0);
        int ipv6 = socket(AF_INET6, SOCK_STREAM, 0);
        assert(tcp >= 0 && udp >= 0 && ipv6 >= 0);
        int pair[2];
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);

        void *guard = dlopen("build/OfflineGuard-macOS.dylib", RTLD_NOW | RTLD_GLOBAL);
        if (!guard) fprintf(stderr, "%s\n", dlerror());
        assert(guard);

#define BLOCKED(expression) do { errno = 0; assert((expression) == -1); assert(errno == ENETDOWN); } while (0)
        BLOCKED(socket(AF_INET, SOCK_STREAM, 0));
        BLOCKED(socket(AF_INET6, SOCK_DGRAM, 0));
        BLOCKED(connect(tcp, (struct sockaddr *)&address, sizeof(address)));
        sa_endpoints_t endpoints = { .sae_dstaddr = (struct sockaddr *)&address, .sae_dstaddrlen = sizeof(address) };
        BLOCKED(connectx(tcp, &endpoints, SAE_ASSOCID_ANY, 0, NULL, 0, NULL, NULL));
        BLOCKED(send(tcp, "x", 1, 0));
        BLOCKED(sendto(udp, "x", 1, 0, (struct sockaddr *)&address, sizeof(address)));
        struct iovec vector = { .iov_base = "x", .iov_len = 1 };
        struct msghdr message = { .msg_name = &address, .msg_namelen = sizeof(address), .msg_iov = &vector, .msg_iovlen = 1 };
        BLOCKED(sendmsg(udp, &message, 0));
        BLOCKED(write(tcp, "x", 1));
        BLOCKED(write(ipv6, "x", 1));
        BLOCKED(writev(tcp, &vector, 1));
        struct addrinfo *result = NULL;
        assert(getaddrinfo("localhost", "80", NULL, &result) == EAI_AGAIN);
        assert(result == NULL);

        // IPC and normal file operations remain usable after global rebinding.
        assert(write(pair[0], "x", 1) == 1);
        char character = 0;
        assert(read(pair[1], &character, 1) == 1 && character == 'x');
        assert(send(pair[0], "y", 1, 0) == 1);
        assert(recv(pair[1], &character, 1, 0) == 1 && character == 'y');
        int local = socket(AF_UNIX, SOCK_STREAM, 0);
        assert(local >= 0);
        close(local);
        int pipeFDs[2];
        assert(pipe(pipeFDs) == 0);
        assert(writev(pipeFDs[1], &vector, 1) == 1);
        assert(read(pipeFDs[0], &character, 1) == 1);
        close(pipeFDs[0]); close(pipeFDs[1]);
        int file = open("build/file-probe.txt", O_CREAT | O_TRUNC | O_RDWR, 0600);
        assert(file >= 0);
        assert(write(file, "ok", 2) == 2);
        close(file);
        errno = 0;
        assert(write(-1, "x", 1) == -1 && errno == EBADF);

        void *late = dlopen("build/LateClient.dylib", RTLD_NOW);
        assert(late);
        int (*lateCheck)(void) = dlsym(late, "late_client_is_blocked");
        assert(lateCheck && lateCheck());

        if (existingSession) checkDataTask(existingSession, url, YES);
        checkDataTask(NSURLSession.sharedSession, url, YES);
        NSURLSession *newSession = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration];
        checkDataTask(newSession, url, YES);

        dispatch_semaphore_t uploadDone = dispatch_semaphore_create(0);
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"POST";
        [[newSession uploadTaskWithRequest:request fromData:[@"test" dataUsingEncoding:NSUTF8StringEncoding]
                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            assert(error != nil);
            dispatch_semaphore_signal(uploadDone);
        }] resume];
        waitFor(uploadDone);

        dispatch_semaphore_t downloadDone = dispatch_semaphore_create(0);
        [[newSession downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            assert(error != nil && location == nil);
            dispatch_semaphore_signal(downloadDone);
        }] resume];
        waitFor(downloadDone);

        dispatch_semaphore_t websocketDone = dispatch_semaphore_create(0);
        NSURL *wsURL = [NSURL URLWithString:[url.absoluteString stringByReplacingOccurrencesOfString:@"http:" withString:@"ws:"]];
        NSURLSessionWebSocketTask *websocket = [newSession webSocketTaskWithURL:wsURL];
        [websocket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
            assert(error != nil);
            dispatch_semaphore_signal(websocketDone);
        }];
        [websocket resume];
        waitFor(websocketDone);
        dispatch_semaphore_t websocketSendDone = dispatch_semaphore_create(0);
        [websocket sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:@"test"] completionHandler:^(NSError *error) {
            assert(error.code == NSURLErrorNotConnectedToInternet);
            dispatch_semaphore_signal(websocketSendDone);
        }];
        waitFor(websocketSendDone);
        dispatch_semaphore_t websocketPingDone = dispatch_semaphore_create(0);
        [websocket sendPingWithPongReceiveHandler:^(NSError *error) {
            assert(error.code == NSURLErrorNotConnectedToInternet);
            dispatch_semaphore_signal(websocketPingDone);
        }];
        waitFor(websocketPingDone);

        dispatch_semaphore_t networkDone = dispatch_semaphore_create(0);
        NSString *port = [NSString stringWithFormat:@"%u", ntohs(address.sin_port)];
        nw_connection_t connection = nw_connection_create(nw_endpoint_create_host("127.0.0.1", port.UTF8String),
                                                         nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION));
        nw_connection_set_queue(connection, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
        nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
            assert(state != nw_connection_state_ready);
            if (state == nw_connection_state_cancelled) dispatch_semaphore_signal(networkDone);
        });
        nw_connection_start(connection);
        waitFor(networkDone);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSError *legacyError = nil;
        NSData *legacyData = [NSURLConnection sendSynchronousRequest:[NSURLRequest requestWithURL:url]
                                                 returningResponse:NULL error:&legacyError];
        assert(legacyData == nil && legacyError.code == NSURLErrorNotConnectedToInternet);
#pragma clang diagnostic pop

        WKWebView *webView = [[WKWebView alloc] initWithFrame:NSZeroRect];
        assert([webView loadRequest:[NSURLRequest requestWithURL:url]] == nil);
        NSString *html = [NSString stringWithFormat:@"<img src='%@'><script>fetch('%@')</script>", url, url];
        assert([webView loadHTMLString:html baseURL:url] == nil);
        assert([webView reload] == nil);
        dispatch_semaphore_t javaScriptDone = dispatch_semaphore_create(0);
        [webView evaluateJavaScript:[NSString stringWithFormat:@"fetch('%@')", url] completionHandler:^(id result, NSError *error) {
            assert(result == nil && error.code == NSURLErrorNotConnectedToInternet);
            dispatch_semaphore_signal(javaScriptDone);
        }];
        waitFor(javaScriptDone);
        assert(webView.URL == nil && !webView.loading);

        [existingSession invalidateAndCancel];
        [newSession invalidateAndCancel];
        // Let queued network work run before verifying that no new connections
        // reached the real loopback server after activation.
        struct timespec delay = { .tv_nsec = 300000000 };
        nanosleep(&delay, NULL);
        assert(atomic_load(&requests) == expectedRequests);
        atomic_store(&stopping, true);
        pthread_join(thread, NULL);
        close(listener); close(tcp); close(udp); close(ipv6);
        close(pair[0]); close(pair[1]);
        printf("PASS (%s): blocked sockets/DNS/URLSession/upload/download/WebSocket/Network.framework/legacy/WebView requests; late-loaded hooks; IPC and files preserved; zero new server connections.\n", coldStart ? "cold start" : "HTTP baseline verified");
        // Keep injected code loaded until process exit: installed IMPs and
        // dyld callbacks cannot safely survive dlclose.
    }
    return 0;
}
