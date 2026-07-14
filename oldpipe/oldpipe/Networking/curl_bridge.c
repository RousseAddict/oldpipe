#include "curl_bridge.h"
#include <curl/curl.h>
#include <stdlib.h>
#include <pthread.h>
#include <poll.h>

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
/* One mutex PER lock-data type (indexed by curl_lock_data). CRITICAL: libcurl NESTS share
   locks of different types — e.g. it holds the CONNECT (connection cache) lock while taking
   the DNS or SSL_SESSION lock. A single non-recursive mutex for all types self-deadlocks on
   the very first transfer once CONNECT sharing is enabled (DNS-only sharing never nested,
   which is why one mutex used to work). curl never nests locks of the SAME type. */
static pthread_mutex_t g_share_locks[CURL_LOCK_DATA_LAST];

static void curl_bridge_share_lock(CURL *handle, curl_lock_data data,
                                   curl_lock_access access, void *userptr) {
    (void)handle; (void)access; (void)userptr;
    if (data >= 0 && data < CURL_LOCK_DATA_LAST) pthread_mutex_lock(&g_share_locks[data]);
}
static void curl_bridge_share_unlock(CURL *handle, curl_lock_data data, void *userptr) {
    (void)handle; (void)userptr;
    if (data >= 0 && data < CURL_LOCK_DATA_LAST) pthread_mutex_unlock(&g_share_locks[data]);
}

void curl_bridge_global_init(void) {
    curl_global_init(CURL_GLOBAL_ALL);
    for (int i = 0; i < CURL_LOCK_DATA_LAST; i++) pthread_mutex_init(&g_share_locks[i], NULL);
    g_share = curl_share_init();
    if (g_share) {
        curl_share_setopt(g_share, CURLSHOPT_LOCKFUNC, curl_bridge_share_lock);
        curl_share_setopt(g_share, CURLSHOPT_UNLOCKFUNC, curl_bridge_share_unlock);
        curl_share_setopt(g_share, CURLSHOPT_SHARE, CURL_LOCK_DATA_DNS);
        /* Share the CONNECTION CACHE + TLS SESSION cache across handles too. Every
           curl_bridge_init() makes a fresh easy handle whose private connection pool dies with
           curl_easy_cleanup(), so each transfer paid a full TCP+TLS handshake (~1-3s on an
           iPhone 4S). The HLS transmux path does many short bounded ranged GETs to the same
           googlevideo host (2 head fetches + 2 per segment) — without connection reuse the
           handshakes alone blow past AVPlayer's readiness window. With CONNECT shared, an idle
           kept-alive googlevideo connection is reused by the next handle; SSL_SESSION makes any
           new connection resume the TLS session instead of a full handshake. */
        curl_share_setopt(g_share, CURLSHOPT_SHARE, CURL_LOCK_DATA_CONNECT);
        curl_share_setopt(g_share, CURLSHOPT_SHARE, CURL_LOCK_DATA_SSL_SESSION);
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

void curl_bridge_set_header_fn(CurlHandle handle, CurlBridgeWriteFn fn, void *userdata) {
    CURL *e = ((CurlBridgeHandle *)handle)->easy;
    curl_easy_setopt(e, CURLOPT_HEADERFUNCTION, fn);
    curl_easy_setopt(e, CURLOPT_HEADERDATA, userdata);
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

/* --- Raw TLS socket (CONNECT_ONLY) — Chromecast CASTV2 --- */

/* Fetch the live socket fd for poll(). CURLINFO_ACTIVESOCKET is the CONNECT_ONLY-safe
   accessor (CURLINFO_LASTSOCKET is deprecated / truncates on 64-bit). */
static int curl_bridge_active_fd(CURL *e) {
    curl_socket_t sock = CURL_SOCKET_BAD;
    if (curl_easy_getinfo(e, CURLINFO_ACTIVESOCKET, &sock) != CURLE_OK) return -1;
    if (sock == CURL_SOCKET_BAD) return -1;
    return (int)sock;
}

/* Wait for the socket to become readable/writable. events = POLLIN or POLLOUT.
   Returns 1 ready, 0 timeout, -1 error. */
static int curl_bridge_wait(int fd, short events, long timeout_ms) {
    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = events;
    pfd.revents = 0;
    int r = poll(&pfd, 1, (int)timeout_ms);
    if (r < 0) return -1;
    if (r == 0) return 0;
    return 1;
}

int curl_bridge_connect_only(CurlHandle handle, const char *host, long port) {
    CurlBridgeHandle *h = (CurlBridgeHandle *)handle;
    CURL *e = h->easy;
    /* Chromecast presents a self-signed device cert — don't verify. */
    curl_easy_setopt(e, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(e, CURLOPT_SSL_VERIFYHOST, 0L);
    curl_easy_setopt(e, CURLOPT_URL, host);
    curl_easy_setopt(e, CURLOPT_PORT, port);
    /* Force a TLS layer even though there's no HTTPS scheme in the bare host. */
    curl_easy_setopt(e, CURLOPT_DEFAULT_PROTOCOL, "https");
    curl_easy_setopt(e, CURLOPT_USE_SSL, (long)CURLUSESSL_ALL);
    /* CONNECT_ONLY = do DNS + TCP + TLS handshake, then stop and expose the socket. */
    curl_easy_setopt(e, CURLOPT_CONNECT_ONLY, 1L);
    curl_easy_setopt(e, CURLOPT_CONNECTTIMEOUT, 15L);
    return (int)curl_easy_perform(e);
}

long curl_bridge_send(CurlHandle handle, const void *buf, long len) {
    CurlBridgeHandle *h = (CurlBridgeHandle *)handle;
    CURL *e = h->easy;
    const char *p = (const char *)buf;
    long remaining = len;
    while (remaining > 0) {
        size_t sent = 0;
        CURLcode rc = curl_easy_send(e, p, (size_t)remaining, &sent);
        if (rc == CURLE_OK) {
            p += sent;
            remaining -= (long)sent;
        } else if (rc == CURLE_AGAIN) {
            int fd = curl_bridge_active_fd(e);
            if (fd < 0) return -1;
            int w = curl_bridge_wait(fd, POLLOUT, 15000);
            if (w <= 0) return -1;   /* timeout or poll error */
        } else {
            return -1;
        }
    }
    return len;
}

long curl_bridge_recv(CurlHandle handle, void *buf, long len, long timeout_ms) {
    CurlBridgeHandle *h = (CurlBridgeHandle *)handle;
    CURL *e = h->easy;
    int fd = curl_bridge_active_fd(e);
    if (fd < 0) return -1;
    /* Wait first so we don't spin — curl_easy_recv would just return CURLE_AGAIN. */
    int w = curl_bridge_wait(fd, POLLIN, timeout_ms);
    if (w < 0) return -1;
    if (w == 0) return 0;   /* timeout, no data */
    size_t got = 0;
    CURLcode rc = curl_easy_recv(e, buf, (size_t)len, &got);
    if (rc == CURLE_OK) {
        return (got == 0) ? -1 : (long)got;   /* 0 bytes on a readable socket = peer closed */
    }
    if (rc == CURLE_AGAIN) return 0;   /* readable flag was stale — treat as timeout */
    return -1;
}
