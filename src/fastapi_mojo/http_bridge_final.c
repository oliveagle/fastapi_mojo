// http_bridge_final.c — Final C bridge: socket I/O + Mojo builds response

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#define BUF_SIZE 8192
#define MAX_METHOD 16
#define MAX_PATH 1024
#define MAX_QUERY 1024
#define MAX_BODY 65536

static char g_method[MAX_METHOD], g_path[MAX_PATH], g_query[MAX_QUERY], g_body[MAX_BODY];
static int g_method_len, g_path_len, g_query_len, g_body_len;

int create_bound_socket(int port) {
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

    // Body (after \r\n\r\n)
    char *bs = strstr(buf, "\r\n\r\n");
    if (bs) {
        bs += 4;
        int bl = total - (bs - buf);
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

// Dynamic response builder - allocates buffer for large responses
int send_simple_response(int fd, const char *status, const char *body) {
    int body_len = strlen(body);
    int header_len = strlen(status) + 128; // room for headers
    int total_len = header_len + body_len + 4;

    char *resp = malloc(total_len);
    if (!resp) return -1;

    int rlen = sprintf(resp,
        "HTTP/1.1 %s\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n"
        "\r\n"
        "%s", status, body_len, body);

    int sent = send(fd, resp, rlen, 0);
    free(resp);
    return sent;
}
