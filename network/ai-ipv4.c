#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <netdb.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

/* Keep the shim in the CLI itself, not in commands that its tools launch. */
__attribute__((constructor)) static void scope_to_cli(void) {
    const char *previous = getenv("AI_IPV4_PREVIOUS_PRELOAD");
    if (previous) {
        if (*previous) setenv("LD_PRELOAD", previous, 1);
        else unsetenv("LD_PRELOAD");
        unsetenv("AI_IPV4_PREVIOUS_PRELOAD");
    }
}

int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **result) {
    int (*original)(const char *, const char *, const struct addrinfo *, struct addrinfo **) =
        dlsym(RTLD_NEXT, "getaddrinfo");
    if (!original) return EAI_SYSTEM;
    /* Preserve loopback, bind/listen lookups, and local IPC. */
    if (!node || !strcmp(node, "localhost") || !strcmp(node, "127.0.0.1") ||
        !strcmp(node, "::1") || (hints && (hints->ai_flags & AI_PASSIVE)))
        return original(node, service, hints, result);
    struct addrinfo ipv4 = {0};
    if (hints) ipv4 = *hints;
    ipv4.ai_family = AF_INET;
    ipv4.ai_flags &= ~(AI_V4MAPPED | AI_ALL);
    return original(node, service, &ipv4, result);
}

int connect(int fd, const struct sockaddr *address, socklen_t length) {
    int (*original)(int, const struct sockaddr *, socklen_t) = dlsym(RTLD_NEXT, "connect");
    if (!original) { errno = ENOSYS; return -1; }
    if (address && address->sa_family == AF_INET6 && length >= sizeof(struct sockaddr_in6)) {
        const struct sockaddr_in6 *ipv6 = (const void *)address;
        /* IPv4-mapped sockets really use IPv4. The system resolver may still
         * reach its configured DNS server over IPv6; that isn't API traffic. */
        if (!IN6_IS_ADDR_LOOPBACK(&ipv6->sin6_addr) &&
            !IN6_IS_ADDR_V4MAPPED(&ipv6->sin6_addr) && ntohs(ipv6->sin6_port) != 53) {
            errno = ENETUNREACH;
            return -1;
        }
    }
    return original(fd, address, length);
}
