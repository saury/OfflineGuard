#pragma once
#include <SystemConfiguration/SystemConfiguration.h>

typedef Boolean (*OGReachabilitySetter)(SCNetworkReachabilityRef,
                                        SCNetworkReachabilityCallBack,
                                        SCNetworkReachabilityContext *);

Boolean OGSetOfflineReachabilityCallback(SCNetworkReachabilityRef target,
                                         SCNetworkReachabilityCallBack callback,
                                         SCNetworkReachabilityContext *context,
                                         OGReachabilitySetter setter);
