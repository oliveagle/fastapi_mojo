// http_bridge_final.c — C bridge: socket I/O + CORS + static files + body limits + graceful shutdown
//
// v14: concurrency — multi-process workers + SO_REUSEPORT (ADR-0005):
//      init_workers() (FASTAPI_MOJO_WORKERS=N, default 1 = single process;
//      spawner = worker 0, children re-exec themselves for a fresh runtime),
//      create_bound_socket sets SO_REUSEPORT, get_worker_id().
//
// v13: configurable listen port — get_configured_port(): CLI --port N /
//      --port=N (via /proc/self/cmdline) > FASTAPI_MOJO_PORT env > 8000.
//
// v12: bulk field transfer — request fields (method/path/query/body) are
//      handed to Mojo as CStringSlice (pointer + length) instead of one
//      external_call per byte (1MB body: ~33ms -> ~5ms transfer).
//
// v11: poll-based event loop — one poll() watches the listen socket plus
//      every accepted connection (per-connection state machine, MAX_CONNS
//      cap). Fixes the v10 head-of-line blocking: idle keep-alive
//      connections no longer stall other clients (measured: hey 10k/100c
//      0.32s -> stuck ~500s under v10). Slowloris is guarded by
//      per-connection deadlines (no progress for RECV_TIMEOUT, or total
//      request time > MAX_REQUEST -> 408); idle connections close after
//      IDLE_TIMEOUT (default 60s). Mojo still dispatches one parsed
//      request at a time; only I/O wait is shared.
//
// v10b: TCP_NODELAY on accepted connections — the keep-alive response
//      (header + body, two sends) triggered the classic Nagle/delayed-ACK
//      40ms stall per request; with NODELAY each request is one RTT.
//
// v10: HTTP/1.1 keep-alive — one connection serves a sequence of requests.
//      The Connection header is now dynamic (computed per request: HTTP/1.1
//      keeps unless the client says close; HTTP/1.0 closes unless the client
//      says keep-alive). Error responses always close (uncertain state).
//      Idle keep-alive connections are closed silently (recv timeout with no
//      bytes, return -10); a stalled mid-request client still gets 408.
//
// v9: Transfer-Encoding requests are rejected with 411 Length Required
//     (bodies are read strictly by Content-Length; old behavior silently
//     dropped chunked bodies and answered 200 with no data).
//
// v8: Expect: 100-continue — interim "HTTP/1.1 100 Continue" is sent
//     before the body is read (was: clients stalling ~1s waiting for it).
//
// v7: 405 support — send_response takes an extra header line, and
//     send_simple_response_allow() emits the RFC 7231 Allow header for
//     "path exists, method not registered" (was: 404).
//
// v6: oversized request headers (>= HDR_BUF_SIZE, 16KB) -> 431 Request
//     Header Fields Too Large (was: silent connection reset).
//
// v5: request-line validation (400 Bad Request on malformed METHOD/PATH/
//     protocol token, e.g. a bare "BLAH\r\n\r\n"; was: 404 for path "").
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
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <signal.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <poll.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdarg.h>
#include <ctype.h>

// ws.c 协议原语 (显式 bridge, ADR-0006/0007/0008)
#define WS_MAX_MSG (1024 * 1024)
// NOTE: 布局必须与 ws.c 的 ws_parser_t 完全一致 (逐字段镜像)
typedef struct {
    int stage;
    int fin, opcode, masked;
    unsigned char ext[8];
    int ext_need, ext_got;
    uint64_t flen;
    unsigned char mask[4];
    int mask_got;
    uint64_t pgot;
    int in_msg;
    int msg_opcode;
    size_t reasm_len;
} ws_parser_t;
extern void ws_parser_init(ws_parser_t *p);
extern int ws_parser_feed(ws_parser_t *p, const unsigned char *buf, size_t n,
                          int *opcode, size_t *melen, unsigned char *reasm);
extern int ws_handshake(int fd, const char *key, const char *subprotocol);
extern int ws_write_message(int fd, int opcode, const unsigned char *payload, size_t plen);
extern int ws_validate_utf8(const unsigned char *p, size_t n);
extern int ws_reply_close_buf(int fd, const unsigned char *payload, size_t n);
extern int ws_send_close(int fd, int code);
extern int get_ws_ping_max(void);

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
static int g_method_len, g_path_len, g_query_len;
static char g_static_dir[MAX_STATIC_DIR] = "./static";
static int g_max_body_size = DEFAULT_MAX_BODY_SIZE;

// Where the single-binary shim staged the embedded static assets
// (<stage_dir>/static); empty unless the shim ran (i.e. not the single
// binary). Used as fallback when the CWD-relative default doesn't exist.
static char g_embedded_static_dir[MAX_STATIC_DIR] = "";

static volatile int g_running = 1;

// Slowloris guard: a stalled client (half-sent request line, or slow reads of
// our response) must not block the single-threaded server. Per-connection
// SO_RCVTIMEO/SO_SNDTIMEO turn a stall into EAGAIN, which recv_and_parse
// answers with 408 and closes. Default 5s; override with
// FASTAPI_MOJO_RECV_TIMEOUT (seconds, 1..300).
static int g_recv_timeout_ms = 5000;

// Keep-alive state, recomputed by recv_and_parse for every request
// (single-threaded server, so globals are safe):
//   g_protocol_11        — the current request speaks HTTP/1.1
//   g_close_after_response — 1: the next response announces "Connection: close"
//                            and the server closes the fd right after it;
//                            0: keep-alive, serve the next request on the same
//                            fd. Default 1 (close): the safe behavior for every
//                            error path, where the connection state is uncertain
//                            (e.g. an unread body).
static int g_protocol_11 = 0;
static int g_close_after_response = 1;

// Event loop (v11): the listen socket lives here (C-driven poll loop);
// per-connection deadlines.
static long g_listen_fd = -1;
static long g_idle_max_ms = 60000;   // idle keep-alive connections (FASTAPI_MOJO_IDLE_TIMEOUT)
static long g_max_request_ms = 30000;  // total time allowed per request (FASTAPI_MOJO_MAX_REQUEST)

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

void set_embedded_static_dir(const char *dir) {
    if (!dir || !dir[0]) return;
    strncpy(g_embedded_static_dir, dir, MAX_STATIC_DIR - 1);
    g_embedded_static_dir[MAX_STATIC_DIR - 1] = 0;
}

void set_static_dir(const char *dir) {
    // Resolution priority:
    //   1) FASTAPI_MOJO_STATIC_DIR env (explicit override, any mode)
    //   2) the passed dir if it exists (CWD-relative "./static" in dev)
    //   3) the embedded statics staged by the single-binary shim
    //   4) the passed dir anyway (old behavior: 404s)
    const char *env = getenv("FASTAPI_MOJO_STATIC_DIR");
    if (env && env[0]) dir = env;
    if (!dir) return;
    struct stat st;
    int dir_exists = (stat(dir, &st) == 0 && S_ISDIR(st.st_mode));
    if (!dir_exists && g_embedded_static_dir[0]) {
        struct stat est;
        if (stat(g_embedded_static_dir, &est) == 0 && S_ISDIR(est.st_mode))
            dir = g_embedded_static_dir;
    }
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
// Forward decl (defined below the worker machinery).
long get_configured_port(void);

// Keep-alive: after a fully-parsed request, 0 = the connection may be reused
// (the response announced "keep-alive"), 1 = the server closes it.
long get_close_after_response(void) { return g_close_after_response; }

// ---------- worker processes (ADR-0005) ----------
//
// FASTAPI_MOJO_WORKERS=N (>1): the first process (the "spawner") becomes
// worker 0 and forks N-1 children; each child re-execs itself as worker i
// (fresh process, fresh Mojo runtime init — forking a process whose KGEN/
// AsyncRT runtime may hold threads/locks is unsafe). Each worker binds the
// same port with SO_REUSEPORT; the kernel distributes new connections
// (nginx pre-fork model). FASTAPI_MOJO_WORKERS unset = 1 (default, single
// process, exactly the pre-v14 behavior).

static int g_worker_id = 0;

long get_worker_id(void) { return g_worker_id; }

void init_workers(void) {
    const char *wn = getenv("FASTAPI_MOJO_WORKERS");
    int n = (wn && wn[0]) ? atoi(wn) : 1;
    if (n <= 1) return;

    const char *am_worker = getenv("FASTAPI_MOJO_WORKER");
    if (am_worker && am_worker[0]) {
        // Already a spawned worker: record my id and go on.
        g_worker_id = atoi(am_worker);
        return;
    }

    // Spawner: I am worker 0.
    g_worker_id = 0;
    setenv("FASTAPI_MOJO_WORKER", "0", 1);

    long port = get_configured_port();
    char port_str[16];
    snprintf(port_str, sizeof port_str, "%ld", port);

    char exe[1024];
    ssize_t len = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (len <= 0) return;  // cannot re-exec: continue single-process
    exe[len] = 0;

    for (int i = 1; i < n; i++) {
        pid_t pid = fork();
        if (pid < 0) break;  // fork failed: run with fewer workers
        if (pid == 0) {
            char wstr[16];
            snprintf(wstr, sizeof wstr, "%d", i);
            setenv("FASTAPI_MOJO_WORKER", wstr, 1);
            char *argv[] = { exe, "--port", port_str, NULL };
            execv(exe, argv);
            _exit(127);  // execv failed
        }
    }
}

// Resolve the listen port. Priority (per task p3-2):
//   1) CLI  --port N  or  --port=N   (read from /proc/self/cmdline)
//   2) env  FASTAPI_MOJO_PORT
//   3) default 8000
long get_configured_port(void) {
    long port = 8000;
    const char *env = getenv("FASTAPI_MOJO_PORT");
    if (env && env[0]) {
        long v = atol(env);
        if (v > 0 && v < 65536) port = v;
    }
    // CLI overrides env. /proc/self/cmdline is NUL-separated; a single
    // fread can return SEVERAL arguments at once, so walk it byte-by-byte
    // and split on NUL (a naive per-fread loop only saw argv[0]).
    FILE *f = fopen("/proc/self/cmdline", "r");
    if (f) {
        char arg[256];
        size_t alen = 0;
        int pending_port = 0;  // previous arg was "--port"
        int c;
        while ((c = fgetc(f)) != EOF) {
            if (c == 0) {
                arg[alen] = 0;
                if (alen > 0) {
                    if (pending_port) {
                        long v = atol(arg);
                        if (v > 0 && v < 65536) port = v;
                        break;
                    }
                    if (strcmp(arg, "--port") == 0) {
                        pending_port = 1;
                    } else if (strncmp(arg, "--port=", 7) == 0) {
                        long v = atol(arg + 7);
                        if (v > 0 && v < 65536) port = v;
                        break;
                    }
                }
                alen = 0;
            } else if (alen < sizeof(arg) - 1) {
                arg[alen++] = (char)c;
            }
        }
        fclose(f);
    }
    cdebug("get_configured_port: port=%ld", port);
    return port;
}

long create_bound_socket(int port) {
    setup_signal_handlers();
    init_recv_timeout();
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    // ADR-0005: workers share the port; the kernel distributes new
    // connections by 4-tuple hash (no-op for the default single worker).
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));
    struct sockaddr_in a; memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = INADDR_ANY;
    a.sin_port = htons((unsigned short)port);
    if (bind(fd, (struct sockaddr*)&a, sizeof(a)) < 0) { close(fd); return -1; }
    if (listen(fd, 128) < 0) { close(fd); return -1; }
    g_listen_fd = fd;
    return fd;
}

// ---------- v11: poll-based event loop ----------
//
// v10 (blocking recv, one connection at a time) serializes keep-alive:
// the server stuck waiting on one connection's idle recv cannot service
// any other client. Measured with the hey benchmark: 100 concurrent
// workers x (work + 5s idle wait) -> the 10k/100c scenario stalls ~500s
// (baseline 0.32s). v11 moves I/O multiplexing into the C bridge:
// one poll() watches the listen socket plus every accepted connection.
//
//   - idle keep-alive connections block nothing; they are closed after
//     FASTAPI_MOJO_IDLE_TIMEOUT (default 60s)
//   - a connection with a partial request gets a per-connection deadline:
//     no progress for FASTAPI_MOJO_RECV_TIMEOUT (default 5s) OR total
//     request time > FASTAPI_MOJO_MAX_REQUEST (default 30s) -> 408
//     (Slowloris, both the "send nothing" and "dribble bytes" variants)
//   - the connection cap is MAX_CONNS; overflow gets 503
//   - the Mojo side still dispatches one fully-parsed request at a time
//     (single-threaded runtime); only the I/O wait is shared
//
// Per-connection state:
//   hdr[HDR_BUF_SIZE] — bytes of the current request so far
//   phase 0 — waiting for the complete header
//   phase 1 — header done, waiting for the Content-Length body
//   phase 2 — request complete, Mojo is dispatching (conn_done resets)
// Bodies are malloc'd per connection (cl+1) and freed in conn_done.
// Completed requests are exposed via the g_method/g_path/g_query globals
// and the body accessors (which point at the active connection).

#define MAX_CONNS 1024
#define POLL_TICK_MS 1000

struct conn {
    int in_use;
    int fd;
    int phase;  // 0=header 1=body 2=HTTP dispatch(Mojo busy)
               // 3=WS session(poll 可驱动) 4=WS dispatch(Mojo 处理一条消息)
    char hdr[HDR_BUF_SIZE];
    int hdr_total;
    int cl;             // parsed Content-Length
    char *body;         // malloc(cl+1) when cl > 0
    int body_got;
    long connected_ms;
    long last_active_ms; // last completed response (or accept time)
    long first_data_ms;  // first byte of the current request (0 = none)
    long last_data_ms;   // last byte of the current request (0 = none)
    // WebSocket session (ADR-0008): per-conn 帧解析状态 + 待处理消息
    char ws_path[MAX_PATH];        // upgrade 时的 path (Mojo 逐消息查 WS 路由)
    unsigned char *ws_reasm;       // 惰性 malloc(WS_MAX_MSG+1); 消息载荷 (NUL 结尾)
    ws_parser_t ws_par;            // 状态化帧解析器 (ws.c)
    int ws_opcode;                 // 待处理数据帧的 opcode (1/2)
    size_t ws_mlen;                // 待处理数据帧的长度
    int ws_strikes;                // 保活: 自上次客户端数据以来的超时计数
};

static struct conn g_conns[MAX_CONNS];
static struct conn *g_active_conn = NULL;

static long now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (long)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

static struct conn *find_conn(int fd) {
    for (int i = 0; i < MAX_CONNS; i++)
        if (g_conns[i].in_use && g_conns[i].fd == fd)
            return &g_conns[i];
    return NULL;
}

static struct conn *alloc_conn(int fd) {
    for (int i = 0; i < MAX_CONNS; i++) {
        if (!g_conns[i].in_use) {
            struct conn *c = &g_conns[i];
            memset(c, 0, sizeof(*c));
            c->in_use = 1;
            c->fd = fd;
            long t = now_ms();
            c->connected_ms = t;
            c->last_active_ms = t;
            return c;
        }
    }
    return NULL;
}

static void close_conn(struct conn *c) {
    if (!c->in_use) return;
    if (c->body) { free(c->body); c->body = NULL; }
    if (c->ws_reasm) { free(c->ws_reasm); c->ws_reasm = NULL; }
    if (c->fd >= 0) close(c->fd);
    if (g_active_conn == c) g_active_conn = NULL;
    c->in_use = 0;
    c->fd = -1;
    c->phase = 0;
    c->hdr_total = 0;
    c->body_got = 0;
    c->first_data_ms = 0;
    c->last_data_ms = 0;
}

static void setup_conn_fd(int cfd) {
    // Slowloris guard: bound how long this client may stall us.
    struct timeval tv;
    tv.tv_sec = (time_t)(g_recv_timeout_ms / 1000);
    tv.tv_usec = (suseconds_t)(g_recv_timeout_ms % 1000) * 1000;
    setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    // TCP_NODELAY: the response is sent in two parts (header, then body).
    // Without it, Nagle holds the (small) body segment until the client
    // ACKs the header — a keep-alive client's delayed-ACK logic waits the
    // full 40ms with no outgoing data to piggyback on: 40ms per request.
    int nodelay = 1;
    setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));
}

static void init_recv_timeout(void) {
    const char *env = getenv("FASTAPI_MOJO_RECV_TIMEOUT");
    if (env) {
        long v = atol(env);
        if (v >= 1 && v <= 300) g_recv_timeout_ms = (int)(v * 1000);
    }
    const char *env_idle = getenv("FASTAPI_MOJO_IDLE_TIMEOUT");
    if (env_idle) {
        long v = atol(env_idle);
        if (v >= 1 && v <= 3600) g_idle_max_ms = v * 1000;
    }
    const char *env_req = getenv("FASTAPI_MOJO_MAX_REQUEST");
    if (env_req) {
        long v = atol(env_req);
        if (v >= 1 && v <= 3600) g_max_request_ms = v * 1000;
    }
}

static int find_header_end(const char *buf, int total) {
    char *p = (char*)memmem(buf, (size_t)total, "\r\n\r\n", 4);
    if (!p) return -1;
    return (int)(p - buf) + 4;
}

static char *bounded_strstr(const char *hay, size_t hlen, const char *needle) {
    size_t nlen = strlen(needle);
    if (nlen == 0 || nlen > hlen) return NULL;
    for (size_t i = 0; i + nlen <= hlen; i++) {
        if (hay[i] == needle[0] && memcmp(hay + i, needle, nlen) == 0)
            return (char *)hay + i;
    }
    return NULL;
}

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
// (Defined below; needed by recv_and_parse for the 100-continue interim.)
static int send_all(int fd, const char *buf, int len);

static int has_header_name_ci(const char *hdr, size_t hlen, const char *name) {
    size_t nlen = strlen(name);
    if (nlen == 0 || nlen > hlen) return 0;
    for (size_t i = 0; i + nlen <= hlen; i++) {
        if (i > 0 && hdr[i - 1] != '\n') continue;
        int match = 1;
        for (size_t k = 0; k < nlen; k++) {
            if (tolower((unsigned char)hdr[i + k]) != tolower((unsigned char)name[k])) {
                match = 0;
                break;
            }
        }
        if (match) return 1;
    }
    return 0;
}

// Case-insensitive header value extraction: copies the trimmed value of the
// first `name: value` line into out (NUL-terminated). Returns 1 if found.
static int get_header_value_ci(const char *hdr, size_t hlen, const char *name,
                               char *out, size_t outsz) {
    size_t nlen = strlen(name);
    if (nlen == 0 || nlen > hlen || outsz == 0) return 0;
    for (size_t i = 0; i + nlen <= hlen; i++) {
        if (i > 0 && hdr[i - 1] != '\n') continue;
        if (strncasecmp(hdr + i, name, nlen) != 0) continue;
        size_t j = i + nlen;
        while (j < hlen && (hdr[j] == ' ' || hdr[j] == '\t')) j++;
        if (j >= hlen || hdr[j] != ':') continue;
        j++;
        while (j < hlen && (hdr[j] == ' ' || hdr[j] == '\t')) j++;
        size_t k = j;
        while (k < hlen && hdr[k] != '\r' && hdr[k] != '\n') k++;
        size_t vlen = k - j;
        if (vlen >= outsz) vlen = outsz - 1;
        memcpy(out, hdr + j, vlen);
        out[vlen] = '\0';
        return 1;
    }
    return 0;
}

// Directive scan of the Connection header value:
// returns 1 if "close" is present, 2 if "keep-alive" is present (close wins),
// 0 if the header is absent or carries other directives only.
static int connection_directive(const char *hdr, size_t hlen) {
    size_t nlen = 10;  // strlen("Connection")
    for (size_t i = 0; i + nlen <= hlen; i++) {
        if (i > 0 && hdr[i - 1] != '\n') continue;
        if (strncasecmp(hdr + i, "Connection", nlen) != 0) continue;
        size_t j = i + nlen;
        while (j < hlen && (hdr[j] == ' ' || hdr[j] == '\t')) j++;
        if (j >= hlen || hdr[j] != ':') continue;
        j++;
        int has_close = 0, has_keep = 0;
        while (j < hlen && hdr[j] != '\r' && hdr[j] != '\n') {
            if (strncasecmp(hdr + j, "close", 5) == 0) has_close = 1;
            if (strncasecmp(hdr + j, "keep-alive", 10) == 0) has_keep = 1;
            j++;
        }
        if (has_close) return 1;
        if (has_keep) return 2;
        return 0;
    }
    return 0;
}

// Case-insensitive check for "Expect: 100-continue"// Case-insensitive check for "Expect: 100-continue" among the header lines
// in hdr[0..hlen). (100-continue is the only Expect value we honor; per
// RFC 7231 \u00a75.1.1 we must answer it with an interim response or a 4xx,
// never ignore it.)
static int expect_100_continue(const char *hdr, size_t hlen) {
    size_t i = 0;
    while (i + 7 <= hlen) {
        char name[8];
        for (int k = 0; k < 7; k++) name[k] = (char)tolower((unsigned char)hdr[i + k]);
        name[7] = 0;
        if (strcmp(name, "expect:") == 0) {
            size_t j = i + 7;
            while (j < hlen && hdr[j] != '\r' && hdr[j] != '\n') {
                if (j + 12 <= hlen) {
                    char val[13];
                    for (int k = 0; k < 12; k++) val[k] = (char)tolower((unsigned char)hdr[j + k]);
                    val[12] = 0;
                    if (strcmp(val, "100-continue") == 0) return 1;
                }
                j++;
            }
            return 0;
        }
        i++;
    }
    return 0;
}

// Parse a completed header (c->hdr[0..hdr_end)); fills the request-line
// globals, applies the protocol rules (400/411/413/100/keep-alive) and sets
// up the body phase. Returns 1 = request complete (no body, or the body is
// already fully buffered), 0 = body still arriving (phase 1), -1 = connection
// closed (an error response was already sent).
static int finish_header(struct conn *c) {
    int hdr_end = find_header_end(c->hdr, c->hdr_total);

    // Per-request reset.
    g_method_len = g_path_len = g_query_len = 0;
    g_method[0] = g_path[0] = g_query[0] = 0;
    g_protocol_11 = 0;
    g_close_after_response = 1;

    // 1) Request line: METHOD SP PATH SP HTTP/1.x
    int i = 0;
    while (i < c->hdr_total && c->hdr[i] != ' ' && g_method_len < MAX_METHOD - 1)
        g_method[g_method_len++] = c->hdr[i++];
    g_method[g_method_len] = 0;
    if (i < c->hdr_total && c->hdr[i] == ' ') i++;
    while (i < c->hdr_total && c->hdr[i] != ' ' && c->hdr[i] != '\r' && g_path_len < MAX_PATH - 1)
        g_path[g_path_len++] = c->hdr[i++];
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

    // 2) Request-line validation (v5): 400 unless the method is an uppercase
    //    token, the target starts with '/', and the protocol is exactly
    //    HTTP/1.0 or HTTP/1.1 with nothing after it.
    {
        int ok_method = (g_method_len >= 1 && g_method_len < MAX_METHOD);
        for (int k = 0; ok_method && k < g_method_len; k++) {
            unsigned char ch = (unsigned char)g_method[k];
            if (ch < 'A' || ch > 'Z') ok_method = 0;
        }
        int ok_path = (g_path_len >= 1 && g_path[0] == '/');
        char proto[16];
        int plen = 0;
        int j = i;
        if (j < c->hdr_total && c->hdr[j] == ' ') j++;
        while (j < c->hdr_total && c->hdr[j] != '\r' && plen < (int)sizeof(proto) - 1)
            proto[plen++] = c->hdr[j++];
        proto[plen] = 0;
        int ok_proto = (strcmp(proto, "HTTP/1.0") == 0 ||
                        strcmp(proto, "HTTP/1.1") == 0);
        if (ok_proto) g_protocol_11 = (strcmp(proto, "HTTP/1.1") == 0);
        if (!ok_method || !ok_path || !ok_proto) {
            send_error_json(c->fd, "400 Bad Request", "Malformed request line");
            close_conn(c);
            return -1;
        }
    }

    // 2b) Request-line UTF-8 validation (v3): invalid bytes -> 400 (the
    //      Mojo side would otherwise decode them as U+FFFD and route a
    //      garbled path).
    if (!utf8_valid(g_method, g_method_len) ||
        !utf8_valid(g_path, g_path_len) ||
        !utf8_valid(g_query, g_query_len)) {
        send_error_json(c->fd, "400 Bad Request", "Invalid UTF-8 in request line");
        close_conn(c);
        return -1;
    }

    // 3) Transfer-Encoding is not supported (v9): 411.
    if (has_header_name_ci(c->hdr, (size_t)hdr_end, "Transfer-Encoding")) {
        send_error_json(c->fd, "411 Length Required",
                        "Transfer-Encoding not supported; send Content-Length");
        close_conn(c);
        return -1;
    }

    // 4) Content-Length (capped so the limit check can distinguish).
    int content_length = 0;
    char *cl = bounded_strstr(c->hdr, (size_t)hdr_end, "Content-Length:");
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
    if (content_length > g_max_body_size) {
        cdebug("413 fd=%d content_length=%d", c->fd, content_length);
        send_error_json(c->fd, "413 Payload Too Large", "Request body too large");
        close_conn(c);
        return -1;
    }
    if (content_length > MAX_BODY) content_length = MAX_BODY;
    c->cl = content_length;

    // 5) Expect: 100-continue (v8): interim response before the body.
    if (content_length > 0 && expect_100_continue(c->hdr, (size_t)hdr_end)) {
        cdebug("100-continue fd=%d", c->fd);
        (void)send_all(c->fd, "HTTP/1.1 100 Continue\r\n\r\n",
                       (int)strlen("HTTP/1.1 100 Continue\r\n\r\n"));
    }

    // 6) Keep-alive decision (v10, RFC 7230 §6).
    {
        int keep = g_protocol_11 ? 1 : 0;
        int dir = connection_directive(c->hdr, (size_t)hdr_end);
        if (dir == 1) keep = 0;
        if (dir == 2) keep = 1;
        g_close_after_response = keep ? 0 : 1;
    }

    // 7) Body (some may already be in the header buffer).
    int body_in_hdr = c->hdr_total - hdr_end;
    c->first_data_ms = now_ms();
    c->last_data_ms = c->first_data_ms;
    if (content_length == 0) {
        c->body = NULL;
        c->body_got = 0;
        c->phase = 2;
        // Extra bytes (a pipelined next request) are dropped: pipelining is
        // not supported (same limitation as the pre-v11 server).
        return 1;
    }
    c->body = malloc((size_t)content_length + 1);
    if (!c->body) {
        send_error_json(c->fd, "500 Internal Server Error", "Out of memory");
        close_conn(c);
        return -1;
    }
    c->body_got = 0;
    if (body_in_hdr > 0) {
        int copy = body_in_hdr < content_length ? body_in_hdr : content_length;
        memcpy(c->body, c->hdr + hdr_end, (size_t)copy);
        c->body_got = copy;
    }
    if (c->body_got >= content_length) {
        c->body[c->body_got] = 0;
        c->phase = 2;
        if (!utf8_valid(c->body, c->body_got)) {
            send_error_json(c->fd, "400 Bad Request", "Invalid UTF-8 in request body");
            close_conn(c);
            return -1;
        }
        return 1;
    }
    c->phase = 1;
    return 0;
}

// Read available data from a connection and advance its state machine.
// Returns 1 = a request is complete, 0 = still waiting, -1 = the connection
// was closed (an error response was sent where appropriate).
// ---------- WebSocket 事件队列 (ADR-0008) ----------
// poll 循环在 WS 连接上发现"数据帧完成"或"会话结束"时入队; Mojo 在
// recv_and_parse 返回处取队首 (FIFO, 天然处理 fd 复用的时序)。
#define WS_EV_MAX 1024
static int g_ws_ev_fd[WS_EV_MAX];
static int g_ws_ev_type[WS_EV_MAX];  // 1 = 数据消息就绪, 2 = 会话结束
static int g_ws_ev_head = 0, g_ws_ev_count = 0;
static int g_ws_event_type = 0;     // 最近一次 recv_and_parse 返回的事件类型

static void ws_event_push(int fd, int type) {
    if (g_ws_ev_count >= WS_EV_MAX) return;  // 溢出丢弃 (连接保持, 极罕见)
    int tail = (g_ws_ev_head + g_ws_ev_count) % WS_EV_MAX;
    g_ws_ev_fd[tail] = fd;
    g_ws_ev_type[tail] = type;
    g_ws_ev_count++;
}

static int ws_event_pop(int *type) {
    if (g_ws_ev_count == 0) return -1;
    int fd = g_ws_ev_fd[g_ws_ev_head];
    *type = g_ws_ev_type[g_ws_ev_head];
    g_ws_ev_head = (g_ws_ev_head + 1) % WS_EV_MAX;
    g_ws_ev_count--;
    return fd;
}

// WS 连接 pump (phase 3): 非阻塞读 -> 帧解析器 -> 控制帧自动处理 (纯协议),
// 数据帧入事件队列并置 phase 4 (Mojo 处理中, 本连接暂停 pump)。
static int pump_ws_conn(struct conn *c) {
    if (!c->ws_reasm) {
        c->ws_reasm = (unsigned char *)malloc(WS_MAX_MSG + 1);
        if (!c->ws_reasm) {
            ws_event_push(c->fd, 2);
            close_conn(c);
            return -1;
        }
    }
    for (;;) {
        unsigned char buf[8192];
        ssize_t n = recv(c->fd, buf, sizeof buf, MSG_DONTWAIT);
        if (n <= 0) {
            if (n == 0) {  // EOF
                ws_event_push(c->fd, 2);
                close_conn(c);
                return -1;
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            ws_event_push(c->fd, 2);
            close_conn(c);
            return -1;
        }
        c->last_data_ms = now_ms();
        c->ws_strikes = 0;  // 任何客户端数据 (含 pong) 都是活性证明
        int opcode = 0;
        size_t mlen = 0;
        int r = ws_parser_feed(&c->ws_par, buf, (size_t)n, &opcode, &mlen, c->ws_reasm);
        if (r == -1) {  // 协议错误 -> close 1002
            cdebug("ws parser ERROR fd=%d", c->fd);
            ws_send_close(c->fd, 1002);
            ws_event_push(c->fd, 2);
            close_conn(c);
            return -1;
        }
        if (r == 2) {  // 控制帧: 协议层自动处理
            if (opcode == 9) {  // ping -> pong (同载荷)
                (void)ws_write_message(c->fd, 10, c->ws_reasm, mlen);
            } else if (opcode == 8) {  // close -> 码校验回复, 结束会话
                (void)ws_reply_close_buf(c->fd, c->ws_reasm, mlen);
                ws_event_push(c->fd, 2);
                close_conn(c);
                return -1;
            }
            // opcode 10 (pong): 活性已计入 (last_data_ms), 无动作
        } else if (r == 1) {  // 数据消息 (text/binary)
            if (opcode == 1 && !ws_validate_utf8(c->ws_reasm, mlen)) {
                ws_send_close(c->fd, 1007);  // text 非法 UTF-8 (RFC 6455 §5.6)
                ws_event_push(c->fd, 2);
                close_conn(c);
                return -1;
            }
            c->ws_opcode = opcode;
            c->ws_mlen = mlen;
            c->phase = 4;  // Mojo 逐条处理; 暂停本连接 pump
            cdebug("ws msg fd=%d op=%d len=%zu", c->fd, opcode, mlen);
            ws_event_push(c->fd, 1);
            return 0;
        }
    }
    return 0;
}

static int pump_conn(struct conn *c) {
    if (c->phase == 2 || c->phase == 4) return 0;  // Mojo 分派中: 不做 I/O
    if (c->phase == 3) return pump_ws_conn(c);
    if (c->phase == 0) {
        // Header already complete (accumulated earlier, e.g. carried over)?
        if (find_header_end(c->hdr, c->hdr_total) >= 0)
            return finish_header(c);
        if (c->hdr_total >= HDR_BUF_SIZE - 1) {
            send_error_json(c->fd, "431 Request Header Fields Too Large",
                            "Request header too large");
            close_conn(c);
            return -1;
        }
        int n = recv(c->fd, c->hdr + c->hdr_total, (size_t)(HDR_BUF_SIZE - 1 - c->hdr_total), MSG_DONTWAIT);
        if (n <= 0) {
            if (n == 0) { close_conn(c); return -1; }  // EOF
            if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;  // spurious
            close_conn(c);
            return -1;
        }
        c->hdr_total += n;
        if (c->first_data_ms == 0) c->first_data_ms = now_ms();
        c->last_data_ms = now_ms();
        return pump_conn(c);  // one retry: the header may now be complete
    }
    // phase 1: body still arriving
    int n = recv(c->fd, c->body + c->body_got, (size_t)(c->cl - c->body_got), MSG_DONTWAIT);
    if (n <= 0) {
        if (n == 0) {
            // Client closed mid-body: complete with the short body (the
            // pre-v11 behavior processed it rather than hanging).
            c->body[c->body_got] = 0;
            c->phase = 2;
            if (c->body_got > 0 && !utf8_valid(c->body, c->body_got)) {
                send_error_json(c->fd, "400 Bad Request", "Invalid UTF-8 in request body");
                close_conn(c);
                return -1;
            }
            return 1;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        close_conn(c);
        return -1;
    }
    c->body_got += n;
    c->last_data_ms = now_ms();
    if (c->body_got >= c->cl) {
        c->body[c->body_got] = 0;
        c->phase = 2;
        if (!utf8_valid(c->body, c->body_got)) {
            send_error_json(c->fd, "400 Bad Request", "Invalid UTF-8 in request body");
            close_conn(c);
            return -1;
        }
        return 1;
    }
    return 0;
}

// Per-connection deadlines, checked on every poll tick (1s):
//  - partial request without progress for g_recv_timeout_ms -> 408
//    (Slowloris "send nothing after a few bytes")
//  - request in flight longer than g_max_request_ms -> 408
//    (Slowloris "dribble a byte every few seconds" / too-slow upload)
//  - idle keep-alive connection older than g_idle_max_ms -> silent close
//    (no request to answer; a 408 would just be noise for connection pools)
static void check_deadlines(void) {
    long now = now_ms();
    for (int i = 0; i < MAX_CONNS; i++) {
        struct conn *c = &g_conns[i];
        if (!c->in_use) continue;
        if (c->phase == 2 || c->phase == 4) continue;  // Mojo 分派中
        if (c->phase == 3) {
            // WS 保活 (ADR-0008): 空闲超 recv_timeout -> ping; 连续 ping_max
            // 次无客户端数据 -> close 1000 + 结束会话 (ping_max=0 禁用保活,
            // 首次空闲超时即 close)
            if (c->last_data_ms != 0 && now - c->last_data_ms >= g_recv_timeout_ms) {
                c->ws_strikes++;
                cdebug("ws keepalive fd=%d strike=%d idle=%ldms", c->fd, c->ws_strikes, now - c->last_data_ms);
                if (c->ws_strikes > get_ws_ping_max()) {
                    ws_send_close(c->fd, 1000);
                    ws_event_push(c->fd, 2);
                    close_conn(c);
                } else {
                    (void)ws_write_message(c->fd, 9, (const unsigned char *)"", 0);
                }
            }
            continue;
        }
        if (c->first_data_ms != 0) {
            if (now - c->last_data_ms >= g_recv_timeout_ms ||
                now - c->first_data_ms >= g_max_request_ms) {
                send_error_json(c->fd, "408 Request Timeout", "Request timeout");
                close_conn(c);
            }
        } else if (now - c->last_active_ms >= g_idle_max_ms) {
            close_conn(c);
        }
    }
}

// Block until a request is fully parsed (or the server is shutting down).
// Returns the fd of the completed request (>0; its fields are in the globals
// and the body accessors) or 0 (a connection was closed, or nothing to do —
// the Mojo side just loops again).
long recv_and_parse(void) {
    static struct pollfd pf[1 + MAX_CONNS];
    static int pf_pos[MAX_CONNS];

    for (;;) {
        if (!g_running) return 0;

        // WS 事件优先 (ADR-0008): FIFO 队首 = 最早就绪的消息/会话结束
        int ev_type;
        int ev_fd = ws_event_pop(&ev_type);
        if (ev_fd >= 0) {
            struct conn *c = find_conn(ev_fd);
            g_ws_event_type = ev_type;
            if (c) {
                g_active_conn = c;  // payload/path 等 getter 按 active conn 读取
                c->last_active_ms = now_ms();
            }
            cdebug("ws event fd=%d type=%d", ev_fd, ev_type);
            return (long)ev_fd;
        }

        int nfd = 0;
        pf[nfd].fd = (int)g_listen_fd;
        pf[nfd].events = POLLIN;
        nfd++;
        for (int i = 0; i < MAX_CONNS; i++) {
            if (!g_conns[i].in_use) continue;
            pf_pos[i] = nfd;
            pf[nfd].fd = g_conns[i].fd;
            pf[nfd].events = POLLIN;
            nfd++;
        }

        int pr = poll(pf, (nfds_t)nfd, POLL_TICK_MS);
        if (pr < 0) {
            if (errno == EINTR) continue;
            usleep(10000);
            continue;
        }

        // New connection (exactly one per poll iteration: a second
        // blocking accept() here would stall the event loop; any further
        // pending connections are picked up on the next iteration, since
        // the listen fd stays readable while the backlog is non-empty).
        if (pf[0].revents & (POLLIN | POLLHUP)) {
            struct sockaddr_in ca;
            socklen_t cl = sizeof(ca);
            int cfd = accept((int)g_listen_fd, (struct sockaddr *)&ca, &cl);
            if (cfd >= 0) {
                setup_conn_fd(cfd);
                struct conn *c = alloc_conn(cfd);
                if (!c) {
                    // Connection cap reached.
                    send_error_json(cfd, "503 Service Unavailable", "Too many connections");
                    close(cfd);
                    cdebug("accept fd=%d rejected (MAX_CONNS)", cfd);
                } else {
                    cdebug("accept fd=%d", cfd);
                    // The client usually sends right after the handshake:
                    // try to pump it now (non-blocking; the next poll
                    // iteration picks up the rest).
                    int r = pump_conn(c);
                    if (r == 1) {
                        g_active_conn = c;
                        c->last_active_ms = now_ms();
                        g_ws_event_type = 0;
                        cdebug("request ready fd=%d (first poll)", c->fd);
                        return c->fd;
                    }
                }
            }
        }

        if (pr > 0) {
            for (int i = 0; i < MAX_CONNS; i++) {
                struct conn *c = &g_conns[i];
                if (!c->in_use) continue;
                int re = pf[pf_pos[i]].revents;
                if (!(re & (POLLIN | POLLHUP | POLLERR))) continue;
                if ((re & (POLLERR | POLLHUP)) && !(re & POLLIN)) {
                    close_conn(c);
                    continue;
                }
                int r = pump_conn(c);
                if (r == 1) {
                    g_active_conn = c;
                    c->last_active_ms = now_ms();
                    g_ws_event_type = 0;
                    cdebug("request ready fd=%d method_len=%d path_len=%d query_len=%d body_len=%d",
                           c->fd, g_method_len, g_path_len, g_query_len, c->body_got);
                    return c->fd;
                }
                // r == 0: still waiting; r == -1: connection closed
            }
        }

        check_deadlines();
    }
}

// Mojo calls this after responding to the request on fd: reuse=1 keeps the
// connection for the next request (keep-alive), reuse=0 closes it. Frees the
// request's body buffer and resets the per-request state.
void conn_done(int fd, int reuse) {
    struct conn *c = find_conn(fd);
    if (!c) return;
    if (c->phase == 3 || c->phase == 4) return;  // WS 会话: 生命周期归 poll 循环 (ADR-0008)
    if (c->body) { free(c->body); c->body = NULL; }
    c->body_got = 0;
    c->phase = 0;
    c->hdr_total = 0;
    c->first_data_ms = 0;
    c->last_data_ms = 0;
    if (reuse && g_running) {
        c->last_active_ms = now_ms();
    } else {
        close_conn(c);
    }
}

// Shutdown: close the listen socket and every active connection.
void server_shutdown(void) {
    for (int i = 0; i < MAX_CONNS; i++)
        close_conn(&g_conns[i]);
    if (g_listen_fd >= 0) {
        close((int)g_listen_fd);
        g_listen_fd = -1;
    }
}

// Bulk field transfer: a string slice (pointer + 64-bit length), laid out
// to match Mojo's CStringSlice. The Mojo side decodes it in amortized O(n)
// instead of one external_call per byte (the read_*_byte loops). The C side
// has already validated the UTF-8 (request line + body), so the slice
// content is guaranteed valid.
typedef struct { const char *ptr; long len; } fmc_slice;

fmc_slice get_method_slice(void) { return (fmc_slice){ g_method, (long)g_method_len }; }
fmc_slice get_path_slice(void) { return (fmc_slice){ g_path, (long)g_path_len }; }
fmc_slice get_query_slice(void) { return (fmc_slice){ g_query, (long)g_query_len }; }
fmc_slice get_body_slice(void) {
    struct conn *c = g_active_conn;
    if (!c || !c->body) return (fmc_slice){ "", 0 };
    return (fmc_slice){ c->body, (long)c->body_got };
}

// ---------- WebSocket upgrade detection (ADR-0006) ----------
// The protocol (handshake + frame loop) lives in ws.c; this file only
// inspects the already-parsed request headers of the active connection.
static char g_ws_key[256];

// 1 if the active request is a valid RFC 6455 upgrade: GET method +
// `Upgrade: websocket` + Connection value contains "upgrade" + a non-empty
// `Sec-WebSocket-Key`. (Sec-WebSocket-Version not enforced: minimal endpoint.)
int is_ws_upgrade(void) {
    struct conn *c = g_active_conn;
    if (!c || !c->in_use) return 0;
    if (strcmp(g_method, "GET") != 0) return 0;
    int hdr_end = find_header_end(c->hdr, c->hdr_total);
    if (hdr_end < 0) return 0;
    char val[256];
    if (!get_header_value_ci(c->hdr, (size_t)hdr_end, "Upgrade", val, sizeof val)) return 0;
    if (strcasecmp(val, "websocket") != 0) return 0;
    if (!get_header_value_ci(c->hdr, (size_t)hdr_end, "Connection", val, sizeof val)) return 0;
    size_t vlen = strlen(val);
    int has_upgrade = 0;
    for (size_t i = 0; i + 7 <= vlen; i++)
        if (strncasecmp(val + i, "upgrade", 7) == 0) { has_upgrade = 1; break; }
    if (!has_upgrade) return 0;
    if (!get_header_value_ci(c->hdr, (size_t)hdr_end, "Sec-WebSocket-Key", g_ws_key, sizeof g_ws_key))
        return 0;
    if (g_ws_key[0] == '\0') return 0;
    return 1;
}

fmc_slice get_ws_key_slice(void) {
    return (fmc_slice){ g_ws_key, (long)strlen(g_ws_key) };
}

// ---------- WebSocket session (ADR-0008: poll 循环驱动) ----------
// 会话生命周期归 bridge poll 循环: WS 连接 (phase 3) 与 HTTP 并发 pump;
// 控制帧/保活/UTF-8 校验在 C 自动处理 (纯协议); 数据帧入事件队列, 由
// Mojo 逐条分派 (phase 4, 单连接暂停 pump)。以下均为 Mojo 面向的显式入口。

// 客户端 Sec-WebSocket-Protocol 原始 offer (无则空)。在 is_ws_upgrade()
// 之后调用 (读 active 连接已解析的头部)。
fmc_slice get_ws_protocol_slice(void) {
    struct conn *c = g_active_conn;
    static char proto[256];
    proto[0] = '\0';
    if (c && c->in_use) {
        int hdr_end = find_header_end(c->hdr, c->hdr_total);
        if (hdr_end >= 0)
            get_header_value_ci(c->hdr, (size_t)hdr_end, "Sec-WebSocket-Protocol",
                                proto, sizeof proto);
    }
    return (fmc_slice){ proto, (long)strlen(proto) };
}

// active 连接上的 101 握手; key = g_ws_key (is_ws_upgrade 提取)。
// subprotocol: Mojo 选中值 (空 = 省略头)。0 = ok, 1 = 失败 (无符号状态)。
int ws_session_begin(const char *subprotocol) {
    struct conn *c = g_active_conn;
    if (!c || !c->in_use) return 1;
    return ws_handshake(c->fd, g_ws_key, subprotocol ? subprotocol : "") == 0 ? 0 : 1;
}

// 移交: active 连接 (HTTP 请求已完整、101 已发) -> WS 会话 (phase 0 -> 3)。
// 保存请求 path 供 Mojo 逐消息查 WS 路由。0 = ok。
int ws_conn_upgrade(int fd) {
    struct conn *c = find_conn(fd);
    if (!c) return 1;
    if (c->body) { free(c->body); c->body = NULL; }
    c->body_got = 0;
    c->hdr_total = 0;
    c->first_data_ms = 0;
    ws_parser_init(&c->ws_par);
    c->ws_opcode = 0;
    c->ws_mlen = 0;
    c->ws_strikes = 0;
    c->last_data_ms = now_ms();
    c->last_active_ms = now_ms();
    size_t pl = strlen(g_path);
    if (pl > sizeof c->ws_path - 1) pl = sizeof c->ws_path - 1;
    memcpy(c->ws_path, g_path, pl);
    c->ws_path[pl] = 0;
    c->phase = 3;
    g_ws_event_type = 0;
    return 0;
}

// 最近一次 recv_and_parse 返回 fd 的事件类型:
//   0 = HTTP 请求 (原语义); 1 = WS 数据消息 (opcode/payload 见下);
//   2 = WS 会话结束 (Mojo 清理该 fd 的连接级状态)
int ws_event_type(void) { return g_ws_event_type; }

// WS 连接 upgrade 时的 path (消息事件时查 WS 路由用; NUL 结尾, FFI 约定)。
fmc_slice get_ws_path_slice(void) {
    struct conn *c = g_active_conn;
    if (!c) return (fmc_slice){ "", 0 };
    return (fmc_slice){ c->ws_path, (long)strlen(c->ws_path) };
}

// 待处理 WS 消息的 opcode (1=text 2=binary; 控制帧不经过 Mojo)。
int ws_last_opcode(void) {
    struct conn *c = g_active_conn;
    return (c && c->phase == 4) ? c->ws_opcode : 0;
}

// 待处理 WS 消息载荷 (NUL 结尾, ADR-0007 §5 FFI 约定; phase 4 期间稳定)。
fmc_slice ws_payload_slice(void) {
    struct conn *c = g_active_conn;
    if (!c || c->phase != 4) return (fmc_slice){ "", 0 };
    return (fmc_slice){ (const char *)c->ws_reasm, (long)c->ws_mlen };
}

// 零拷贝: 把待处理消息载荷原样发回 (text/binary echo)。
int ws_write_current(int fd, int opcode) {
    struct conn *c = find_conn(fd);
    if (!c || !c->ws_reasm) return 1;
    return ws_write_message(fd, opcode, c->ws_reasm, c->ws_mlen);
}

// NOTE (Mojo 1.0.0 FFI ABI, 实测): 传入的 CStringSlice 参数 C 端声明为
// const char* (只消费指针半 + strlen); 结构参数位置敏感 — 详见 ADR-0007 §5。
// 约束: WS text 回复不可含 NUL 字节 (需 NUL 的载荷走 binary 帧零拷贝路径)。
int ws_write_text(int fd, const char *data) {
    return ws_write_message(fd, 1, (const unsigned char *)data, strlen(data));
}

// 服务端发起的 close 帧 (2 字节 code 载荷)。
int ws_send_close(int fd, int code) {
    unsigned char p[2] = { (unsigned char)(code >> 8), (unsigned char)(code & 0xFF) };
    return ws_write_message(fd, 8, p, 2);
}

// Mojo 处理完一条 WS 消息 (active 连接 phase 4 -> 3, 恢复 pump)。
void ws_message_done(int fd) {
    struct conn *c = find_conn(fd);
    if (c && c->phase == 4) c->phase = 3;
}

// Mojo 发起结束会话 (如发完 close 1003): 关连接 + 入队"结束"事件
// (Mojo 据此清理连接级状态)。
void ws_conn_close(int fd) {
    struct conn *c = find_conn(fd);
    if (!c) return;
    ws_event_push(c->fd, 2);
    close_conn(c);
}

// FASTAPI_MOJO_WS_PING_MAX (默认 3): 连续保活 ping 无客户端数据的次数上限,
// 超过 -> close 1000 结束会话。0 = 禁用保活 (首次空闲超时即 close)。
int get_ws_ping_max(void) {
    static int v = -1;
    if (v == -1) {
        const char *e = getenv("FASTAPI_MOJO_WS_PING_MAX");
        int n = 3;
        if (e) {
            int p = atoi(e);
            if (p < 0) p = 0;
            n = p;
        }
        v = n;
    }
    return v;
}


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
// `extra` is an optional extra header line (no trailing CRLF, e.g.
// "Allow: GET, POST"); empty/NULL adds nothing.
static int send_response(int fd, const char *status, const char *content_type,
                         const char *body, int body_len, int include_body,
                         const char *extra) {
    char hdr[RESP_HDR_SIZE];
    const char *ex = (extra && extra[0]) ? extra : "";
    int hlen = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %d\r\n"
        "Connection: %s\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, HEAD, OPTIONS\r\n"
        "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
        "Access-Control-Max-Age: 86400\r\n"
        "%s"
        "\r\n",
        status, content_type, body_len,
        g_close_after_response ? "close" : "keep-alive", ex);
    if (hlen < 0 || hlen >= (int)sizeof(hdr)) return -1;
    snprintf(g_last_status, sizeof g_last_status, "%s", status);
    if (send_all(fd, hdr, hlen) != 0) return -1;
    if (include_body && body_len > 0) {
        if (send_all(fd, body, body_len) != 0) return -1;
    }
    return 0;
}

// Minimal JSON string escaper for a C string: escapes \" \\ and control
// chars (<0x20) as \\u00XX. Writes the escaped string (NUL-terminated) to
// out; returns the escaped length, or -1 if out is too small.
static int json_escape_cstr(const char *in, char *out, int out_size) {
    int o = 0;
    for (const unsigned char *cp = (const unsigned char *)in; *cp; cp++) {
        unsigned char c = *cp;
        const char *esc;
        int esc_len;
        char tmp[7];
        if (c == '"')           { esc = "\\\""; esc_len = 2; }
        else if (c == '\\')    { esc = "\\\\"; esc_len = 2; }
        else if (c == '\b')    { esc = "\\b"; esc_len = 2; }
        else if (c == '\f')    { esc = "\\f"; esc_len = 2; }
        else if (c == '\n')    { esc = "\\n"; esc_len = 2; }
        else if (c == '\r')    { esc = "\\r"; esc_len = 2; }
        else if (c == '\t')    { esc = "\\t"; esc_len = 2; }
        else if (c < 0x20)      { snprintf(tmp, sizeof tmp, "\\u%04x", c); esc = tmp; esc_len = 6; }
        else                    { esc = (const char *)cp; esc_len = 1; }
        if (o + esc_len + 1 > out_size) return -1;
        memcpy(out + o, esc, (size_t)esc_len);
        o += esc_len;
    }
    out[o] = 0;
    return o;
}

long send_error_json(int fd, const char *status, const char *msg) {
    char em[256], es[256], body[600];
    // Escape msg/status so user-influenced text can never break the JSON.
    if (json_escape_cstr(msg, em, (int)sizeof em) < 0) snprintf(em, sizeof em, "error");
    if (json_escape_cstr(status, es, (int)sizeof es) < 0) snprintf(es, sizeof es, "error");
    int blen = snprintf(body, sizeof body, "{\"error\":\"%s\",\"status\":\"%s\"}", em, es);
    if (blen < 0) blen = 0;
    if (blen >= (int)sizeof body) blen = (int)sizeof body - 1;
    return send_response(fd, status, "application/json", body, blen, 1, NULL);
}

// Dynamic JSON response
long send_simple_response(int fd, const char *status, const char *body) {
    return send_response(fd, status, "application/json", body, (int)strlen(body), 1, NULL);
}

// 405 response carrying the RFC 7231 Allow header (the methods registered
// for the matched path, computed on the Mojo side).
long send_simple_response_allow(int fd, const char *status, const char *body,
                                const char *allow) {
    char line[256];
    int n = snprintf(line, sizeof(line), "Allow: %s", allow);
    if (n < 0 || (size_t)n >= sizeof(line)) n = (int)sizeof(line) - 1;
    return send_response(fd, status, "application/json", body, (int)strlen(body), 1, line);
}

// HEAD: headers only, no body
long send_head_response(int fd, const char *status, const char *body) {
    return send_response(fd, status, "application/json", body, (int)strlen(body), 0, NULL);
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

    int rc = send_response(fd, "200 OK", get_content_type(resolved_path), content, (int)file_size, include_body, NULL);
    free(content);
    return rc;
}

long send_static_file(int fd, const char *path) {
    return serve_static_file(fd, path, 1);
}

long send_static_file_head(int fd, const char *path) {
    return serve_static_file(fd, path, 0);
}
