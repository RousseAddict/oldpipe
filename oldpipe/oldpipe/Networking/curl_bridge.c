#include "curl_bridge.h"
#include <curl/curl.h>
#include <stdlib.h>
#include <pthread.h>

/* Wrapper struct — holds easy handle + header slist so both are freed together */
typedef struct {
    CURL *easy;
    struct curl_slist *headers;
} CurlBridgeHandle;

/* Shared DNS cache across all easy handles.
   This libcurl ships with the SYNCHRONOUS name resolver (getaddrinfo), which under concurrent
   transfers (feed + player at once) stalls hard — a name resolve can block for tens of seconds.
   A CURLSH with CURL_LOCK_DATA_DNS lets every handle reuse addresses another handle already
   resolved, so after the feed resolves youtube.com the player does NO getaddrinfo and connects
   immediately. The lock callbacks (a single mutex) make the shared cache thread-safe — REQUIRED
   when sharing across threads. */
static CURLSH *g_share = NULL;
static pthread_mutex_t g_share_lock = PTHREAD_MUTEX_INITIALIZER;

static void curl_bridge_share_lock(CURL *handle, curl_lock_data data,
                                   curl_lock_access access, void *userptr) {
    (void)handle; (void)data; (void)access; (void)userptr;
    pthread_mutex_lock(&g_share_lock);
}
static void curl_bridge_share_unlock(CURL *handle, curl_lock_data data, void *userptr) {
    (void)handle; (void)data; (void)userptr;
    pthread_mutex_unlock(&g_share_lock);
}

void curl_bridge_global_init(void) {
    curl_global_init(CURL_GLOBAL_ALL);
    g_share = curl_share_init();
    if (g_share) {
        curl_share_setopt(g_share, CURLSHOPT_LOCKFUNC, curl_bridge_share_lock);
        curl_share_setopt(g_share, CURLSHOPT_UNLOCKFUNC, curl_bridge_share_unlock);
        curl_share_setopt(g_share, CURLSHOPT_SHARE, CURL_LOCK_DATA_DNS);
    }
}

CurlHandle curl_bridge_init(void) {
    CurlBridgeHandle *h = (CurlBridgeHandle *)calloc(1, sizeof(CurlBridgeHandle));
    if (!h) return NULL;
    h->easy = curl_easy_init();
    h->headers = NULL;
    /* CRITICAL for multi-threaded use: with the synchronous name resolver libcurl times out
       DNS/connect via SIGALRM/alarm(). We call curl_easy_perform() from several background
       threads at once (feed + player), so those signal timers race and get lost — a request
       that must wait on DNS/connect then hangs up to the full CURLOPT_TIMEOUT (~30s). NOSIGNAL
       disables the signal path so timeouts are handled safely per-handle. Required by libcurl
       docs whenever perform() runs off the main thread. */
    if (h->easy) {
        curl_easy_setopt(h->easy, CURLOPT_NOSIGNAL, 1L);
        /* With NOSIGNAL the connect phase still needs a bound (CURLOPT_TIMEOUT covers the whole
           transfer); cap connect at 15s so a stuck connect fails fast instead of dragging out. */
        curl_easy_setopt(h->easy, CURLOPT_CONNECTTIMEOUT, 15L);
        /* Use the shared DNS cache (see g_share comment above): once the feed has resolved
           youtube.com, this handle reuses that address and skips its own getaddrinfo. */
        if (g_share) curl_easy_setopt(h->easy, CURLOPT_SHARE, g_share);
    }
    return h;
}

void curl_bridge_cleanup(CurlHandle handle) {
    CurlBridgeHandle *h = (CurlBridgeHandle *)handle;
    if (!h) return;
    if (h->headers) curl_slist_free_all(h->headers);
    if (h->easy) curl_easy_cleanup(h->easy);
    free(h);
}

void curl_bridge_set_url(CurlHandle handle, const char *url) {
    curl_easy_setopt(((CurlBridgeHandle *)handle)->easy, CURLOPT_URL, url);
}

void curl_bridge_set_ssl_noverify(CurlHandle handle) {
    CURL *e = ((CurlBridgeHandle *)handle)->easy;
    curl_easy_setopt(e, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(e, CURLOPT_SSL_VERIFYHOST, 0L);
}

void curl_bridge_set_follow_redirects(CurlHandle handle) {
    CURL *e = ((CurlBridgeHandle *)handle)->easy;
    curl_easy_setopt(e, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(e, CURLOPT_MAXREDIRS, 10L);
}

void curl_bridge_set_timeout(CurlHandle handle, long secs) {
    curl_easy_setopt(((CurlBridgeHandle *)handle)->easy, CURLOPT_TIMEOUT, secs);
}

void curl_bridge_set_write_fn(CurlHandle handle, CurlBridgeWriteFn fn, void *userdata) {
    CURL *e = ((CurlBridgeHandle *)handle)->easy;
    curl_easy_setopt(e, CURLOPT_WRITEFUNCTION, fn);
    curl_easy_setopt(e, CURLOPT_WRITEDATA, userdata);
}

void curl_bridge_set_progress_fn(CurlHandle handle, CurlBridgeProgressFn fn, void *clientp) {
    CURL *e = ((CurlBridgeHandle *)handle)->easy;
    curl_easy_setopt(e, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(e, CURLOPT_XFERINFOFUNCTION, fn);
    curl_easy_setopt(e, CURLOPT_XFERINFODATA, clientp);
}

void curl_bridge_add_header(CurlHandle handle, const char *header) {
    CurlBridgeHandle *h = (CurlBridgeHandle *)handle;
    /* curl_slist_append copies the string */
    h->headers = curl_slist_append(h->headers, header);
}

void curl_bridge_set_post_body(CurlHandle handle, const char *body, long len) {
    CURL *e = ((CurlBridgeHandle *)handle)->easy;
    /* CURLOPT_POSTFIELDSIZE must be set before COPYPOSTFIELDS */
    curl_easy_setopt(e, CURLOPT_POSTFIELDSIZE, len);
    /* COPYPOSTFIELDS copies the data — safe to pass a temporary C string */
    curl_easy_setopt(e, CURLOPT_COPYPOSTFIELDS, body);
}

void curl_bridge_set_useragent(CurlHandle handle, const char *ua) {
    curl_easy_setopt(((CurlBridgeHandle *)handle)->easy, CURLOPT_USERAGENT, ua);
}

int curl_bridge_perform(CurlHandle handle) {
    CurlBridgeHandle *h = (CurlBridgeHandle *)handle;
    /* Apply accumulated headers right before perform */
    if (h->headers) {
        curl_easy_setopt(h->easy, CURLOPT_HTTPHEADER, h->headers);
    }
    return (int)curl_easy_perform(h->easy);
}

long curl_bridge_response_code(CurlHandle handle) {
    long code = 0;
    curl_easy_getinfo(((CurlBridgeHandle *)handle)->easy, CURLINFO_RESPONSE_CODE, &code);
    return code;
}

const char *curl_bridge_strerror(int code) {
    return curl_easy_strerror((CURLcode)code);
}
