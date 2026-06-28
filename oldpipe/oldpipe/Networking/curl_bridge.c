#include "curl_bridge.h"
#include <curl/curl.h>
#include <stdlib.h>

/* Wrapper struct — holds easy handle + header slist so both are freed together */
typedef struct {
    CURL *easy;
    struct curl_slist *headers;
} CurlBridgeHandle;

void curl_bridge_global_init(void) {
    curl_global_init(CURL_GLOBAL_ALL);
}

CurlHandle curl_bridge_init(void) {
    CurlBridgeHandle *h = (CurlBridgeHandle *)calloc(1, sizeof(CurlBridgeHandle));
    if (!h) return NULL;
    h->easy = curl_easy_init();
    h->headers = NULL;
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
