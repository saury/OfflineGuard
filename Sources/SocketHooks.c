#include "SocketHooks.h"
#include "fishhook.h"
#include <Network/Network.h>
#include <dlfcn.h>
#include <errno.h>
#include <netdb.h>
#include <stdbool.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>

static int (*original_socket)(int, int, int);
static int (*original_connect)(int, const struct sockaddr *, socklen_t);
static int (*original_connectx)(int, const sa_endpoints_t *, sae_associd_t,
                                unsigned int, const struct iovec *, unsigned int,
                                size_t *, sae_connid_t *);
static ssize_t (*original_send)(int, const void *, size_t, int);
static ssize_t (*original_sendto)(int, const void *, size_t, int,
                                 const struct sockaddr *, socklen_t);
static ssize_t (*original_sendmsg)(int, const struct msghdr *, int);
static ssize_t (*original_write)(int, const void *, size_t);
static ssize_t (*original_writev)(int, const struct iovec *, int);
static int (*original_getaddrinfo)(const char *, const char *,
                                  const struct addrinfo *, struct addrinfo **);

static bool is_internet_family(int family) {
    return family == AF_INET || family == AF_INET6;
}

static bool is_internet_address(const struct sockaddr *address, socklen_t length) {
    return address && length >= sizeof(struct sockaddr) &&
           is_internet_family(address->sa_family);
}

static bool is_internet_socket(int fd) {
    struct sockaddr_storage address;
    socklen_t length = sizeof(address);
    int saved_errno = errno;
    bool blocked = getsockname(fd, (struct sockaddr *)&address, &length) == 0 &&
                   is_internet_family(address.ss_family);
    // Probing a file, pipe or UNIX socket must not change its observable errno.
    errno = saved_errno;
    return blocked;
}

static int unavailable(void) {
    errno = ENETDOWN;
    return -1;
}

static int guarded_socket(int domain, int type, int protocol) {
    if (is_internet_family(domain)) return unavailable();
    return original_socket(domain, type, protocol);
}

static int guarded_connect(int fd, const struct sockaddr *address, socklen_t length) {
    if (is_internet_address(address, length) || is_internet_socket(fd)) return unavailable();
    return original_connect(fd, address, length);
}

static int guarded_connectx(int fd, const sa_endpoints_t *endpoints,
                            sae_associd_t association, unsigned int flags,
                            const struct iovec *vectors, unsigned int count,
                            size_t *length, sae_connid_t *connection) {
    if (is_internet_socket(fd) ||
        (endpoints && is_internet_address(endpoints->sae_dstaddr,
                                          endpoints->sae_dstaddrlen))) return unavailable();
    return original_connectx(fd, endpoints, association, flags, vectors, count, length, connection);
}

static ssize_t guarded_send(int fd, const void *data, size_t length, int flags) {
    if (is_internet_socket(fd)) return unavailable();
    return original_send(fd, data, length, flags);
}

static ssize_t guarded_sendto(int fd, const void *data, size_t length, int flags,
                              const struct sockaddr *address, socklen_t address_length) {
    if (is_internet_address(address, address_length) || is_internet_socket(fd)) return unavailable();
    return original_sendto(fd, data, length, flags, address, address_length);
}

static ssize_t guarded_sendmsg(int fd, const struct msghdr *message, int flags) {
    if (is_internet_socket(fd) ||
        (message && is_internet_address(message->msg_name, message->msg_namelen))) return unavailable();
    return original_sendmsg(fd, message, flags);
}

static ssize_t guarded_write(int fd, const void *data, size_t length) {
    if (is_internet_socket(fd)) return unavailable();
    return original_write(fd, data, length);
}

static ssize_t guarded_writev(int fd, const struct iovec *vectors, int count) {
    if (is_internet_socket(fd)) return unavailable();
    return original_writev(fd, vectors, count);
}

static int guarded_getaddrinfo(const char *host, const char *service,
                               const struct addrinfo *hints, struct addrinfo **result) {
    if (!hints || hints->ai_family == AF_UNSPEC || is_internet_family(hints->ai_family)) {
        if (result) *result = NULL;
        return EAI_AGAIN;
    }
    return original_getaddrinfo(host, service, hints, result);
}

static void guarded_connection_start(nw_connection_t connection) {
    nw_connection_cancel(connection);
}

static void guarded_group_start(nw_connection_group_t group) {
    nw_connection_group_cancel(group);
}

static void guarded_listener_start(nw_listener_t listener) {
    nw_listener_cancel(listener);
}

int OGInstallSocketHooks(void) {
    // Resolve originals once. Do not let rebinding individual images overwrite
    // them with lazy-binding stubs or another copy of our replacement.
#define ORIGINAL(name) original_##name = dlsym(RTLD_DEFAULT, #name); \
    if (!original_##name) return -1
    ORIGINAL(socket);
    ORIGINAL(connect);
    ORIGINAL(connectx);
    ORIGINAL(send);
    ORIGINAL(sendto);
    ORIGINAL(sendmsg);
    ORIGINAL(write);
    ORIGINAL(writev);
    ORIGINAL(getaddrinfo);
#undef ORIGINAL
#define HOOK(name) { #name, (void *)guarded_##name, NULL }
    struct rebinding hooks[] = {
        HOOK(socket), HOOK(connect), HOOK(connectx), HOOK(send), HOOK(sendto),
        HOOK(sendmsg), HOOK(write), HOOK(writev), HOOK(getaddrinfo),
        { "nw_connection_start", (void *)guarded_connection_start, NULL },
        { "nw_connection_group_start", (void *)guarded_group_start, NULL },
        { "nw_listener_start", (void *)guarded_listener_start, NULL },
    };
#undef HOOK
    return rebind_symbols(hooks, sizeof(hooks) / sizeof(hooks[0]));
}
