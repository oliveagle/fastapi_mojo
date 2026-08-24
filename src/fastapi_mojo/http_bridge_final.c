// http_bridge_final.c — C bridge: socket I/O + CORS + static files + body limits + graceful shutdown

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/time.h>

#define BUF_SIZE 8192
#define MAX_METHOD 16
#define MAX_PATH 1024
#define MAX_QUERY 1024
#define MAX_BODY 65536
#define MAX_STATIC_DIR 256
#define MAX_FILE_SIZE (1024*1024)  // 1MB max
#define DEFAULT_MAX_BODY_SIZE (1024*1024)  // 1MB default limit

static char g_method[MAX_METHOD], g_path[MAX_PATH], g_query[MAX_QUERY], g_body[MAX_BODY];
static int g_method_len, g_path_len, g_query_len, g_body_len;
static char g_static_dir[MAX_STATIC_DIR] = "./static";
static int g_max_body_size = DEFAULT_MAX_BODY_SIZE;

static volatile int g_running = 1;

void signal_handler(int sig) {
    (void)sig;
    g_running = 0;
}

void setup_signal_handlers() {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
}

int is_running() {
    return g_running;
}

void set_static_dir(const char *dir) {
    strncpy(g_static_dir, dir, MAX_STATIC_DIR - 1);
    g_static_dir[MAX_STATIC_DIR - 1] = 0;
}

long gettimeofday_ms() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (long)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

void set_max_body_size(int size) {
    if (size > 0 && size <= MAX_BODY) {
        g_max_body_size = size;
    }
}

int create_bound_socket(int port) {
    setup_signal_handlers();
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = INADDR_ANY;
    a.sin_port = htons(port);
    if (bind(fd, (struct sockaddr*)&a, sizeof(a)) < 0) { close(fd); return -1; }
    if (listen(fd, 128) < 0) { close(fd); return -1; }
    return fd;
}

int accept_connection(int sfd) {
    if (!g_running) return -1;
    struct sockaddr_in ca; socklen_t cl = sizeof(ca);
    return accept(sfd, (struct sockaddr*)&ca, &cl);
}

int recv_and_parse(int fd) {
    char buf[BUF_SIZE];
    int total = 0;
    int n;

    // Read until we get the full request (headers + body)
    while (total < BUF_SIZE - 1) {
        n = recv(fd, buf + total, BUF_SIZE - 1 - total, 0);
        if (n <= 0) break;
        total += n;
        buf[total] = '\0';
        // Check if we have complete headers
        if (strstr(buf, "\r\n\r\n") != NULL) break;
    }

    if (total <= 0) return 0;

    g_method_len = g_path_len = g_query_len = g_body_len = 0;
    int i = 0;

    // Method
    while (i < total && buf[i] != ' ' && i < MAX_METHOD - 1)
        g_method[g_method_len++] = buf[i++];
    g_method[g_method_len] = 0;
    i++;

    // Path
    while (i < total && buf[i] != ' ' && buf[i] != '?' && buf[i] != '\r' && g_path_len < MAX_PATH - 1)
        g_path[g_path_len++] = buf[i++];
    g_path[g_path_len] = 0;

    // Query
    if (i < total && buf[i] == '?') {
        i++;
        while (i < total && buf[i] != ' ' && buf[i] != '\r' && g_query_len < MAX_QUERY - 1)
            g_query[g_query_len++] = buf[i++];
        g_query[g_query_len] = 0;
    }

    // Parse Content-Length from headers
    int content_length = 0;
    char *cl_header = strstr(buf, "Content-Length: ");
    if (cl_header) {
        cl_header += 16;  // Skip "Content-Length: "
        while (*cl_header >= '0' && *cl_header <= '9') {
            content_length = content_length * 10 + (*cl_header - '0');
            cl_header++;
        }
    }

    // Check body size limit
    if (content_length > g_max_body_size) {
        // Body too large - send 413 response
        const char *resp =
            "HTTP/1.1 413 Payload Too Large\r\n"
            "Content-Type: application/json\r\n"
            "Content-Length: 49\r\n"
            "Connection: close\r\n"
            "Access-Control-Allow-Origin: *\r\n"
            "\r\n"
            "{\"error\":\"Request body too large\",\"status\":\"413\"}";
        send(fd, resp, strlen(resp), 0);
        return -2;  // Special return code for body too large
    }

    // Body (after \r\n\r\n)
    char *bs = strstr(buf, "\r\n\r\n");
    if (bs) {
        bs += 4;
        int bl = total - (bs - buf);
        if (bl > g_max_body_size) bl = g_max_body_size;
        if (bl > MAX_BODY - 1) bl = MAX_BODY - 1;
        memcpy(g_body, bs, bl);
        g_body[bl] = 0;
        g_body_len = bl;
    }

    return total;
}

// Byte accessors
int get_method_len() { return g_method_len; }
int get_path_len() { return g_path_len; }
int get_query_len() { return g_query_len; }
int get_body_len() { return g_body_len; }
int read_method_byte(int i) { return (i>=0 && i<g_method_len) ? (unsigned char)g_method[i] : -1; }
int read_path_byte(int i) { return (i>=0 && i<g_path_len) ? (unsigned char)g_path[i] : -1; }
int read_query_byte(int i) { return (i>=0 && i<g_query_len) ? (unsigned char)g_query[i] : -1; }
int read_body_byte(int i) { return (i>=0 && i<g_body_len) ? (unsigned char)g_body[i] : -1; }

int close_fd(int fd) { return close(fd); }

// Content-Type detection
const char* get_content_type(const char *path) {
    const char *ext = strrchr(path, '.');
    if (!ext) return "application/octet-stream";
    if (strcmp(ext, ".html") == 0 || strcmp(ext, ".htm") == 0) return "text/html";
    if (strcmp(ext, ".css") == 0) return "text/css";
    if (strcmp(ext, ".js") == 0) return "application/javascript";
    if (strcmp(ext, ".json") == 0) return "application/json";
    if (strcmp(ext, ".png") == 0) return "image/png";
    if (strcmp(ext, ".jpg") == 0 || strcmp(ext, ".jpeg") == 0) return "image/jpeg";
    if (strcmp(ext, ".gif") == 0) return "image/gif";
    if (strcmp(ext, ".svg") == 0) return "image/svg+xml";
    if (strcmp(ext, ".ico") == 0) return "image/x-icon";
    if (strcmp(ext, ".txt") == 0) return "text/plain";
    if (strcmp(ext, ".xml") == 0) return "application/xml";
    if (strcmp(ext, ".pdf") == 0) return "application/pdf";
    if (strcmp(ext, ".woff") == 0) return "font/woff";
    if (strcmp(ext, ".woff2") == 0) return "font/woff2";
    return "application/octet-stream";
}

// Static file serving
int send_static_file(int fd, const char *path) {
    // Build full path
    char full_path[MAX_PATH + MAX_STATIC_DIR + 16];
    if (strcmp(path, "/") == 0) {
        snprintf(full_path, sizeof(full_path), "%s/index.html", g_static_dir);
    } else {
        snprintf(full_path, sizeof(full_path), "%s%s", g_static_dir, path);
    }

    // Security: prevent directory traversal
    if (strstr(full_path, "..") != NULL) {
        const char *resp =
            "HTTP/1.1 403 Forbidden\r\n"
            "Content-Type: application/json\r\n"
            "Content-Length: 42\r\n"
            "Connection: close\r\n"
            "Access-Control-Allow-Origin: *\r\n"
            "\r\n"
            "{\"error\":\"Forbidden\",\"status\":\"403\"}";
        return send(fd, resp, strlen(resp), 0);
    }

    FILE *f = fopen(full_path, "rb");
    if (!f) {
        const char *resp =
            "HTTP/1.1 404 Not Found\r\n"
            "Content-Type: application/json\r\n"
            "Content-Length: 38\r\n"
            "Connection: close\r\n"
            "Access-Control-Allow-Origin: *\r\n"
            "\r\n"
            "{\"error\":\"Not Found\",\"status\":\"404\"}";
        return send(fd, resp, strlen(resp), 0);
    }

    // Get file size
    fseek(f, 0, SEEK_END);
    long file_size = ftell(f);
    fseek(f, 0, SEEK_SET);

    if (file_size > MAX_FILE_SIZE) {
        fclose(f);
        const char *resp =
            "HTTP/1.1 413 Payload Too Large\r\n"
            "Content-Type: application/json\r\n"
            "Content-Length: 49\r\n"
            "Connection: close\r\n"
            "Access-Control-Allow-Origin: *\r\n"
            "\r\n"
            "{\"error\":\"File too large\",\"status\":\"413\"}";
        return send(fd, resp, strlen(resp), 0);
    }

    // Read file content
    char *content = malloc(file_size + 1);
    if (!content) {
        fclose(f);
        return -1;
    }
    fread(content, 1, file_size, f);
    content[file_size] = 0;
    fclose(f);

    // Build response
    const char *content_type = get_content_type(full_path);
    int header_len = 256 + strlen(content_type);
    int total_len = header_len + file_size + 4;

    char *resp = malloc(total_len);
    if (!resp) {
        free(content);
        return -1;
    }

    int rlen = sprintf(resp,
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %ld\r\n"
        "Connection: close\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\n"
        "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
        "\r\n",
        content_type, file_size);

    memcpy(resp + rlen, content, file_size);
    rlen += file_size;

    int sent = send(fd, resp, rlen, 0);
    free(resp);
    free(content);
    return sent;
}

// Dynamic response builder with CORS headers
int send_simple_response(int fd, const char *status, const char *body) {
    int body_len = strlen(body);
    int header_len = strlen(status) + 256; // room for headers + CORS
    int total_len = header_len + body_len + 4;

    char *resp = malloc(total_len);
    if (!resp) return -1;

    int rlen = sprintf(resp,
        "HTTP/1.1 %s\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, HEAD, OPTIONS\r\n"
        "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
        "Access-Control-Max-Age: 86400\r\n"
        "\r\n"
        "%s", status, body_len, body);

    int sent = send(fd, resp, rlen, 0);
    free(resp);
    return sent;
}

// HEAD response (same headers as GET but no body)
int send_head_response(int fd, const char *status, const char *body) {
    int body_len = strlen(body);
    int header_len = strlen(status) + 256;
    int total_len = header_len + 4;

    char *resp = malloc(total_len);
    if (!resp) return -1;

    int rlen = sprintf(resp,
        "HTTP/1.1 %s\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, HEAD, OPTIONS\r\n"
        "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
        "\r\n", status, body_len);

    int sent = send(fd, resp, rlen, 0);
    free(resp);
    return sent;
}

// Handle OPTIONS preflight
int send_preflight_response(int fd) {
    const char *resp =
        "HTTP/1.1 204 No Content\r\n"
        "Content-Length: 0\r\n"
        "Connection: close\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, HEAD, OPTIONS\r\n"
        "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
        "Access-Control-Max-Age: 86400\r\n"
        "\r\n";
    return send(fd, resp, strlen(resp), 0);
}
