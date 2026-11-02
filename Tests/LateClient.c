#include <errno.h>
#include <sys/socket.h>

__attribute__((visibility("default")))
int late_client_is_blocked(void) {
    return socket(AF_INET, SOCK_STREAM, 0) == -1 && errno == ENETDOWN;
}
