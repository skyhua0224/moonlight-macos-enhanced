#ifndef HOST_PATH_ROUTE_H
#define HOST_PATH_ROUTE_H

#include "HostPathRank.h"

#ifdef __cplusplus
extern "C" {
#endif

/* How this machine would reach address right now.
   PHYSICAL means a real interface (en*, bridge*). TUNNEL means utun/tun/ipsec/ppp.
   UNKNOWN means a name we did not resolve, or the routing table did not answer.
   name may be NULL. */
int host_path_route_kind(const char *address, char *name, size_t name_len);

#ifdef __cplusplus
}
#endif

#endif
