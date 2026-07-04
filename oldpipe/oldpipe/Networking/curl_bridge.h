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
void        curl_bridge_set_header_fn(CurlHandle h, CurlBridgeWriteFn fn, void *userdata);
void        curl_bridge_set_progress_fn(CurlHandle h, CurlBridgeProgressFn fn, void *clientp);
void        curl_bridge_add_header(CurlHandle h, const char *header);
void        curl_bridge_set_post_body(CurlHandle h, const char *body, long len);
void        curl_bridge_set_useragent(CurlHandle h, const char *ua);
int         curl_bridge_perform(CurlHandle h);
long        curl_bridge_response_code(CurlHandle h);
const char *curl_bridge_strerror(int code);

/* --- Raw TLS socket (CONNECT_ONLY) — used by the Chromecast CASTV2 client ---
   Chromecast speaks a length-prefixed protobuf protocol over a raw TLS socket on
   port 8009. libcurl's CURLOPT_CONNECT_ONLY performs the TLS handshake (OpenSSL,
   speaks the modern ciphers iOS 6 Secure Transport can't) then hands us the socket
   for curl_easy_send / curl_easy_recv. All three must be driven from ONE thread —
   OpenSSL SSL_read/SSL_write on the same SSL object are not thread-safe. */

/* TLS-connect to host:port (no HTTP). Returns 0 on success, else a CURLcode. */
int         curl_bridge_connect_only(CurlHandle h, const char *host, long port);
/* Blocking send of the whole buffer. Returns bytes sent (== len) or -1 on error. */
long        curl_bridge_send(CurlHandle h, const void *buf, long len);
/* Recv up to len bytes, waiting at most timeout_ms for readability.
   Returns >0 bytes read, 0 on timeout (no data), -1 on error/closed. */
long        curl_bridge_recv(CurlHandle h, void *buf, long len, long timeout_ms);

#endif
