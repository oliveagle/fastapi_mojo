// http_bridge_v2.c — C bridge for Mojo integration

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#define BUF_SIZE 4096

// Global request buffer
static char g_buf[BUF_SIZE];
static int g_buf_len = 0;

// Parsed fields
static char g_method[16], g_path[256], g_body[1024];
static int g_method_len, g_path_len, g_body_len;

// Socket helpers
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
    struct sockaddr_in ca;
    socklen_t cl = sizeof(ca);
    return accept(sfd, (struct sockaddr*)&ca, &cl);
}

// Receive into global buffer
int recv_to_global(int fd) {
    g_buf_len = recv(fd, g_buf, BUF_SIZE-1, 0);
    if (g_buf_len > 0) g_buf[g_buf_len] = '\0';
    return g_buf_len;
}

int get_global_buf_len() { return g_buf_len; }

// Parse method/path/body from global buffer
void parse_request_c() {
    g_method_len = g_path_len = g_body_len = 0;
    int i = 0;
    // Method
    while (i < g_buf_len && g_buf[i] != ' ' && i < 15) g_method[g_method_len++] = g_buf[i++];
    g_method[g_method_len] = 0;
    i++; // skip space
    // Path
    while (i < g_buf_len && g_buf[i] != ' ' && g_buf[i] != '?' && g_buf[i] != '\r' && g_path_len < 255)
        g_path[g_path_len++] = g_buf[i++];
    g_path[g_path_len] = 0;
    // Body (after \r\n\r\n)
    char *bs = strstr(g_buf, "\r\n\r\n");
    if (bs) {
        bs += 4;
        int bl = g_buf_len - (bs - g_buf);
        if (bl > 1023) bl = 1023;
        memcpy(g_body, bs, bl);
        g_body[bl] = 0;
        g_body_len = bl;
    }
}

// Byte accessors
int get_method_len() { return g_method_len; }
int get_path_len() { return g_path_len; }
int get_body_len() { return g_body_len; }
int read_method_byte(int i) { return (i>=0 && i<g_method_len) ? (unsigned char)g_method[i] : -1; }
int read_path_byte(int i) { return (i>=0 && i<g_path_len) ? (unsigned char)g_path[i] : -1; }
int read_body_byte(int i) { return (i>=0 && i<g_body_len) ? (unsigned char)g_body[i] : -1; }

// Send raw buffer
int send_raw(int fd, const char *data, int len) {
    return send(fd, data, len, 0);
}

int close_fd(int fd) { return close(fd); }
