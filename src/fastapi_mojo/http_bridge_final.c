// http_bridge_final.c — C bridge: socket I/O + CORS + static files + body limits + graceful shutdown
//
// v4: Slowloris guard (per-connection SO_RCVTIMEO/SO_SNDTIMEO, default 5s,
//     FASTAPI_MOJO_RECV_TIMEOUT; stalled clients get 408 Request Timeout and
//     the connection is dropped, the single-threaded server keeps serving).
//
// v3: correctness fixes on top of the v2 hardening:
//   - 413 check now runs BEFORE the MAX_BODY clamp (v2 clamped Content-Length
//     to exactly MAX_BODY, so the limit check was dead code and oversized
//     bodies were truncated instead of rejected).
//   - g_body reserves one extra byte for the NUL terminator (v2 could write
//     one byte past the buffer for a full-size body).
//   - All error responses build their body with snprintf and use the real
//     length (v2 hardcoded wrong Content-Length values).
//   - Request line and body are validated as UTF-8; invalid input -> 400
//     (the Mojo side decodes bytes to codepoints and would otherwise build
//     a mojibake string or crash on surrogates).
//   - Static file serving supports HEAD (headers only, no body).
//
// The Mojo side reads request fields byte-by-byte via the read_*_byte
// accessors (single-threaded sequential server, so global state is safe).
//
// Diagnostics: set FASTAPI_MOJO_CDEBUG=1 to trace accept/parse/send events
// to stderr (including send failures with errno — e.g. EPIPE when a client
// resets the connection mid-response).

#define _GNU_SOURCE
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <signal.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>

#define HDR_BUF_SIZE 16384      // request header buffer (first line + headers)
#define MAX_METHOD 16
#define MAX_PATH 1024
#define MAX_QUERY 1024
#define MAX_BODY (1024*1024)    // 1MB max body
#define MAX_STATIC_DIR 256
#define MAX_FILE_SIZE (1024*1024)  // 1MB max static file
#define DEFAULT_MAX_BODY_SIZE (1024*1024)
#define RESP_HDR_SIZE 1024      // response header buffer

static char g_method[MAX_METHOD], g_path[MAX_PATH], g_query[MAX_QUERY];
static char g_body[MAX_BODY + 1];  // +1 for the NUL terminator
static int g_method_len, g_path_len, g_query_len, g_body_len;
static char g_static_dir[MAX_STATIC_DIR] = "./static";
static int g_max_body_size = DEFAULT_MAX_BODY_SIZE;

static volatile int g_running = 1;

// Slowloris guard: a stalled client (half-sent request line, or slow reads of
// our response) must not block the single-threaded server. Per-connection
// SO_RCVTIMEO/SO_SNDTIMEO turn a stall into EAGAIN, which recv_and_parse
// answers with 408 and closes. Default 5s; override with
// FASTAPI_MOJO_RECV_TIMEOUT (seconds, 1..300).
static int g_recv_timeout_ms = 5000;

static int g_cdebug = -1;
static void cdebug(const char *fmt, ...) {
    if (g_cdebug == -1) g_cdebug = getenv("FASTAPI_MOJO_CDEBUG") ? 1 : 0;
    if (!g_cdebug) return;
    va_list ap; va_start(ap, fmt);
    fprintf(stderr, "[cbridge] ");
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

void signal_handler(int sig) { (void)sig; g_running = 0; }

void setup_signal_handlers() {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    // SIGPIPE: clients routinely reset the connection mid-response (e.g. they
    // abort a large upload after receiving a 413). Without ignoring it, the
    // next send() kills the whole server process. With SIG_IGN, send() fails
    // with EPIPE and send_all() returns -1, so the connection is simply
    // dropped and the server keeps serving.
    signal(SIGPIPE, SIG_IGN);
}

long is_running() { return g_running; }

void set_static_dir(const char *dir) {
    // FASTAPI_MOJO_STATIC_DIR overrides the directory so the single binary
    // is deployable from any CWD.
    const char *env = getenv("FASTAPI_MOJO_STATIC_DIR");
    if (env && env[0]) dir = env;
    if (!dir) return;
    strncpy(g_static_dir, dir, MAX_STATIC_DIR - 1);
    g_static_dir[MAX_STATIC_DIR - 1] = 0;
}

long gettimeofday_ms() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (long)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

void set_max_body_size(int size) {
    if (size > 0 && size <= MAX_BODY) g_max_body_size = size;
}

// Forward decl (definition lives with the other recv helpers below).
static void init_recv_timeout(void);

long create_bound_socket(int port) {
    setup_signal_handlers();
    init_recv_timeout();
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in a; memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = INADDR_ANY;
    a.sin_port = htons((unsigned short)port);
    if (bind(fd, (struct sockaddr*)&a, sizeof(a)) < 0) { close(fd); return -1; }
    if (listen(fd, 128) < 0) { close(fd); return -1; }
    return fd;
}

long accept_connection(int sfd) {
    if (!g_running) return -1;
    struct sockaddr_in ca; socklen_t cl = sizeof(ca);
    int cfd = accept(sfd, (struct sockaddr*)&ca, &cl);
    if (cfd < 0) return cfd;
    // Slowloris guard: bound how long this client may stall us.
    struct timeval tv;
    tv.tv_sec = (time_t)(g_recv_timeout_ms / 1000);
    tv.tv_usec = (suseconds_t)(g_recv_timeout_ms % 1000) * 1000;
    setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    cdebug("accept fd=%d", cfd);
    return cfd;
}

// Read bytes with per-connection timeout. Returns >0 on data, 0 on clean
// EOF, -1 on error/timeout (errno preserved; EAGAIN/EWOULDBLOCK = timeout).
static int recv_timeout(int fd, char *buf, int n) {
    if (n <= 0) return 0;
    return (int)recv(fd, buf, (size_t)n, 0);
}

static int is_timeout_errno(void) {
    return (errno == EAGAIN || errno == EWOULDBLOCK);
}

static void init_recv_timeout(void) {
    const char *env = getenv("FASTAPI_MOJO_RECV_TIMEOUT");
    if (env) {
        long v = atol(env);
        if (v >= 1 && v <= 300) g_recv_timeout_ms = (int)(v * 1000);
    }
}

// Find the header terminator; returns index of '\0' placed after "\r\n\r\n", or -1.
static int find_header_end(const char *buf, int total) {
    char *p = (char*)memmem(buf, (size_t)total, "\r\n\r\n", 4);
    if (!p) return -1;
    return (int)(p - buf) + 4;
}

// Portable bounded search: find needle in hay[0..hlen)
static char *bounded_strstr(const char *hay, size_t hlen, const char *needle) {
    size_t nlen = strlen(needle);
    if (nlen == 0 || nlen > hlen) return NULL;
    for (size_t i = 0; i + nlen <= hlen; i++) {
        if (hay[i] == needle[0] && memcmp(hay + i, needle, nlen) == 0)
            return (char *)hay + i;
    }
    return NULL;
}

// Strict UTF-8 validation (no overlongs, no surrogates, no > U+10FFFF).
static int utf8_valid(const char *s, int len) {
    int i = 0;
    while (i < len) {
        unsigned char c = (unsigned char)s[i];
        int extra;
        if (c < 0x80) { i += 1; continue; }
        if ((c & 0xE0) == 0xC0) {
            if (c < 0xC2) return 0;      // overlong
            extra = 1;
        } else if ((c & 0xF0) == 0xE0) {
            extra = 2;
        } else if ((c & 0xF8) == 0xF0) {
            if (c > 0xF4) return 0;      // > U+10FFFF
            extra = 3;
        } else {
            return 0;                    // stray continuation / invalid lead
        }
        for (int k = 1; k <= extra; k++) {
            if (i + k >= len) return 0;
            if (((unsigned char)s[i + k] & 0xC0) != 0x80) return 0;
        }
        if (extra == 2) {
            unsigned cp = ((unsigned)(c & 0x0F) << 12) |
                          ((unsigned)(s[i+1] & 0x3F) << 6) |
                          (unsigned)(s[i+2] & 0x3F);
            if (cp >= 0xD800 && cp <= 0xDFFF) return 0;  // surrogate
        }
        i += 1 + extra;
    }
    return 1;
}

// JSON error response with a correctly computed Content-Length.
// (Defined below send_response; prototype here for use in recv_and_parse.)
long send_error_json(int fd, const char *status, const char *msg);

long recv_and_parse(int fd) {
    char *hdr = malloc(HDR_BUF_SIZE);
    if (!hdr) return -1;
    int total = 0;

    // 1) Read until headers complete (stalled client -> 408)
    int hdr_end = -1;
    while (total < HDR_BUF_SIZE - 1 && hdr_end < 0) {
        int n = recv_timeout(fd, hdr + total, HDR_BUF_SIZE - 1 - total);
        if (n < 0) {
            if (is_timeout_errno()) {
                send_error_json(fd, "408 Request Timeout", "Request timeout");
                free(hdr);
                return -5;
            }
            break;  // reset / error: drop silently
        }
        if (n == 0) break;  // clean EOF
        total += n;
        hdr[total] = '\0';
        hdr_end = find_header_end(hdr, total);
    }
    if (total <= 0) { free(hdr); return 0; }
    if (hdr_end < 0) { free(hdr); return 0; }  // incomplete headers

    // 2) Reset globals
    g_method_len = g_path_len = g_query_len = g_body_len = 0;
    g_body[0] = 0;

    // 3) Parse request line: METHOD SP PATH SP HTTP/x.y
    int i = 0;
    while (i < total && hdr[i] != ' ' && g_method_len < MAX_METHOD - 1)
        g_method[g_method_len++] = hdr[i++];
    g_method[g_method_len] = 0;
    if (i < total && hdr[i] == ' ') i++;  // skip space after method

    while (i < total && hdr[i] != ' ' && hdr[i] != '\r' && g_path_len < MAX_PATH - 1)
        g_path[g_path_len++] = hdr[i++];
    g_path[g_path_len] = 0;

    // Path may include query: /path?query
    for (int k = 0; k < g_path_len; k++) {
        if (g_path[k] == '?') {
            int qlen = g_path_len - k - 1;
            if (qlen >= MAX_QUERY) qlen = MAX_QUERY - 1;
            memcpy(g_query, g_path + k + 1, (size_t)qlen);
            g_query[qlen] = 0;
            g_query_len = qlen;
            g_path[k] = 0;
            g_path_len = k;
            break;
        }
    }

    // 4) Parse Content-Length (capped at MAX_BODY + 1 so the limit check
    //    below can distinguish "too large" from "exactly at the cap").
    int content_length = 0;
    char *cl = bounded_strstr(hdr, (size_t)hdr_end, "Content-Length:");
    if (cl) {
        cl += 15;
        while (*cl == ' ' || *cl == '\t') cl++;
        while (*cl >= '0' && *cl <= '9') {
            if (content_length > (MAX_BODY + 1) / 10) {
                content_length = MAX_BODY + 1;
                break;
            }
            content_length = content_length * 10 + (*cl - '0');
            cl++;
        }
    }

    // 5) Body size limit — checked BEFORE any clamping (v2 bug).
    if (content_length > g_max_body_size) {
        cdebug("413 fd=%d content_length=%d (unread body stays in kernel)", fd, content_length);
        send_error_json(fd, "413 Payload Too Large", "Request body too large");
        free(hdr);
        return -2;
    }
    if (content_length > MAX_BODY) content_length = MAX_BODY;

    // 6) Read body: some may already be in hdr (after header end)
    int body_in_hdr = total - hdr_end;
    if (content_length > 0) {
        int got = 0;
        if (body_in_hdr > 0 && body_in_hdr <= content_length) {
            memcpy(g_body, hdr + hdr_end, (size_t)body_in_hdr);
            got = body_in_hdr;
        }
        while (got < content_length && got < MAX_BODY) {
            int n = recv_timeout(fd, g_body + got, content_length - got);
            if (n < 0) {
                if (is_timeout_errno()) {
                    send_error_json(fd, "408 Request Timeout", "Request timeout");
                    free(hdr);
                    return -5;
                }
                break;  // reset / error: drop silently
            }
            if (n == 0) break;  // clean EOF: short body
            got += n;
        }
        g_body[got] = 0;
        g_body_len = got;
    }

    cdebug("parsed fd=%d method_len=%d path_len=%d query_len=%d body_len=%d",
           fd, g_method_len, g_path_len, g_query_len, g_body_len);
    free(hdr);

    // 7) UTF-8 validation of the request line.
    if (!utf8_valid(g_method, g_method_len) ||
        !utf8_valid(g_path, g_path_len) ||
        !utf8_valid(g_query, g_query_len)) {
        send_error_json(fd, "400 Bad Request", "Invalid UTF-8 in request line");
        return -3;
    }
    // 8) UTF-8 validation of the body (JSON is UTF-8; the Mojo decoder
    //    turns invalid bytes into U+FFFD, which would silently corrupt data).
    if (g_body_len > 0 && !utf8_valid(g_body, g_body_len)) {
        send_error_json(fd, "400 Bad Request", "Invalid UTF-8 in request body");
        return -4;
    }
    return total;
}

// Byte accessors for the Mojo side
long get_method_len() { return g_method_len; }
long get_path_len() { return g_path_len; }
long get_query_len() { return g_query_len; }
long get_body_len() { return g_body_len; }
long read_method_byte(int i) { return (i>=0 && i<g_method_len) ? (unsigned char)g_method[i] : -1; }
long read_path_byte(int i) { return (i>=0 && i<g_path_len) ? (unsigned char)g_path[i] : -1; }
long read_query_byte(int i) { return (i>=0 && i<g_query_len) ? (unsigned char)g_query[i] : -1; }
long read_body_byte(int i) { return (i>=0 && i<g_body_len) ? (unsigned char)g_body[i] : -1; }

long close_fd(int fd) { return close(fd); }

// Exit the process with a failure code (used when bind fails — a server
// that cannot listen must not report success to the operator/CI).
void bridge_fail(void) { exit(1); }

// Content-Type detection by extension
const char* get_content_type(const char *path) {
    const char *ext = strrchr(path, '.');
    if (!ext) return "application/octet-stream";
    if (strcmp(ext, ".html")==0 || strcmp(ext, ".htm")==0) return "text/html";
    if (strcmp(ext, ".css")==0) return "text/css";
    if (strcmp(ext, ".js")==0) return "application/javascript";
    if (strcmp(ext, ".json")==0) return "application/json";
    if (strcmp(ext, ".png")==0) return "image/png";
    if (strcmp(ext, ".jpg")==0 || strcmp(ext, ".jpeg")==0) return "image/jpeg";
    if (strcmp(ext, ".gif")==0) return "image/gif";
    if (strcmp(ext, ".svg")==0) return "image/svg+xml";
    if (strcmp(ext, ".ico")==0) return "image/x-icon";
    if (strcmp(ext, ".txt")==0) return "text/plain";
    if (strcmp(ext, ".xml")==0) return "application/xml";
    if (strcmp(ext, ".pdf")==0) return "application/pdf";
    if (strcmp(ext, ".woff")==0) return "font/woff";
    if (strcmp(ext, ".woff2")==0) return "font/woff2";
    return "application/octet-stream";
}

static int send_all(int fd, const char *buf, int len) {
    int off = 0;
    while (off < len) {
        int n = send(fd, buf + off, (size_t)(len - off), 0);
        if (n <= 0) {
            cdebug("send_all fd=%d off=%d len=%d n=%d errno=%d (%s)",
                   fd, off, len, n, errno, strerror(errno));
            return -1;
        }
        off += n;
    }
    return 0;
}

// Track the last response status line so the Mojo side can log the real
// status for static file responses (which return 403/404/413 internally).
static char g_last_status[32] = "";

long get_last_status_len() { return (int)strlen(g_last_status); }
long read_last_status_byte(int i) {
    int n = (int)strlen(g_last_status);
    return (i >= 0 && i < n) ? (unsigned char)g_last_status[i] : -1;
}

// Send a full HTTP response (header + optional body) with a real length.
static int send_response(int fd, const char *status, const char *content_type,
                         const char *body, int body_len, int include_body) {
    char hdr[RESP_HDR_SIZE];
    int hlen = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, HEAD, OPTIONS\r\n"
        "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
        "Access-Control-Max-Age: 86400\r\n"
        "\r\n",
        status, content_type, body_len);
    if (hlen < 0 || hlen >= (int)sizeof(hdr)) return -1;
    snprintf(g_last_status, sizeof g_last_status, "%s", status);
    if (send_all(fd, hdr, hlen) != 0) return -1;
    if (include_body && body_len > 0) {
        if (send_all(fd, body, body_len) != 0) return -1;
    }
    return 0;
}

long send_error_json(int fd, const char *status, const char *msg) {
    char body[256];
    int blen = snprintf(body, sizeof body, "{\"error\":\"%s\",\"status\":\"%s\"}", msg, status);
    if (blen < 0) blen = 0;
    if (blen >= (int)sizeof body) blen = (int)sizeof body - 1;
    return send_response(fd, status, "application/json", body, blen, 1);
}

// Dynamic JSON response
long send_simple_response(int fd, const char *status, const char *body) {
    return send_response(fd, status, "application/json", body, (int)strlen(body), 1);
}

// HEAD: headers only, no body
long send_head_response(int fd, const char *status, const char *body) {
    return send_response(fd, status, "application/json", body, (int)strlen(body), 0);
}

// OPTIONS preflight
long send_preflight_response(int fd) {
    const char *resp =
        "HTTP/1.1 204 No Content\r\n"
        "Content-Length: 0\r\n"
        "Connection: close\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, HEAD, OPTIONS\r\n"
        "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
        "Access-Control-Max-Age: 86400\r\n"
        "\r\n";
    return send_all(fd, resp, (int)strlen(resp));
}

// Static file serving (shared by GET and HEAD)
static int serve_static_file(int fd, const char *path, int include_body) {
    char full_path[MAX_PATH + MAX_STATIC_DIR + 16];
    if (strcmp(path, "/") == 0)
        snprintf(full_path, sizeof(full_path), "%s/index.html", g_static_dir);
    else
        snprintf(full_path, sizeof(full_path), "%s%s", g_static_dir, path);

    // Security: prevent directory traversal AND symlink escape.
    // The old strstr(full_path, "..") both rejected legitimate names
    // (e.g. "a..b.html") and did not stop symlinks, which fopen follows —
    // a link static/evil.html -> /etc/hostname was served with 200.
    // Now: realpath() the static dir and the candidate, require the
    // resolved candidate to stay inside the resolved dir, and open the
    // final component with O_NOFOLLOW (TOCTOU hardening).
    char resolved_dir[PATH_MAX];
    char resolved_path[PATH_MAX];
    if (!realpath(g_static_dir, resolved_dir))
        return send_error_json(fd, "404 Not Found", "Not Found");
    if (!realpath(full_path, resolved_path))
        return send_error_json(fd, "404 Not Found", "Not Found");
    size_t dlen = strlen(resolved_dir);
    if (strncmp(resolved_path, resolved_dir, dlen) != 0 ||
        (resolved_path[dlen] != '/' && resolved_path[dlen] != '\0'))
        return send_error_json(fd, "403 Forbidden", "Forbidden");

    int ffd = open(resolved_path, O_RDONLY | O_NOFOLLOW);
    if (ffd < 0)
        return send_error_json(fd, "403 Forbidden", "Forbidden");
    FILE *f = fdopen(ffd, "rb");
    if (!f) { close(ffd); return send_error_json(fd, "404 Not Found", "Not Found"); }

    fseek(f, 0, SEEK_END);
    long file_size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (file_size < 0 || file_size > MAX_FILE_SIZE) {
        fclose(f);
        return send_error_json(fd, "413 Payload Too Large", "File too large");
    }

    char *content = malloc((size_t)file_size + 1);
    if (!content) { fclose(f); return -1; }
    size_t rd = fread(content, 1, (size_t)file_size, f);
    fclose(f);
    if (rd < (size_t)file_size) file_size = (long)rd;
    content[file_size] = 0;

    int rc = send_response(fd, "200 OK", get_content_type(resolved_path), content, (int)file_size, include_body);
    free(content);
    return rc;
}

long send_static_file(int fd, const char *path) {
    return serve_static_file(fd, path, 1);
}

long send_static_file_head(int fd, const char *path) {
    return serve_static_file(fd, path, 0);
}
