#ifndef curl_bridge_h
#define curl_bridge_h

#include <stddef.h>

typedef void *CurlHandle;

typedef size_t (*CurlBridgeWriteFn)(const void *ptr, size_t size, size_t nmemb, void *userdata);
typedef int (*CurlBridgeProgressFn)(void *clientp,
                                    long long dltotal, long long dlnow,
                                    long long ultotal, long long ulnow);

void        curl_bridge_global_init(void);
CurlHandle  curl_bridge_init(void);
void        curl_bridge_cleanup(CurlHandle h);
void        curl_bridge_set_url(CurlHandle h, const char *url);
void        curl_bridge_set_ssl_noverify(CurlHandle h);
void        curl_bridge_set_follow_redirects(CurlHandle h);
void        curl_bridge_set_timeout(CurlHandle h, long secs);
void        curl_bridge_set_write_fn(CurlHandle h, CurlBridgeWriteFn fn, void *userdata);
void        curl_bridge_set_progress_fn(CurlHandle h, CurlBridgeProgressFn fn, void *clientp);
void        curl_bridge_add_header(CurlHandle h, const char *header);
void        curl_bridge_set_post_body(CurlHandle h, const char *body, long len);
void        curl_bridge_set_useragent(CurlHandle h, const char *ua);
int         curl_bridge_perform(CurlHandle h);
long        curl_bridge_response_code(CurlHandle h);
const char *curl_bridge_strerror(int code);

#endif
