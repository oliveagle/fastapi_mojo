// http_bridge_v3.c — Full HTTP handling, route data from Mojo

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#define BUF_SIZE 4096
static char g_buf[BUF_SIZE];
static int g_buf_len = 0;
static char g_method[16], g_path[256];
static int g_method_len, g_path_len;

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

int recv_to_global(int fd) {
    g_buf_len = recv(fd, g_buf, BUF_SIZE-1, 0);
    if (g_buf_len > 0) g_buf[g_buf_len] = '\0';
    return g_buf_len;
}

void parse_request_c() {
    g_method_len = g_path_len = 0;
    int i = 0;
    while (i < g_buf_len && g_buf[i] != ' ' && i < 15) g_method[g_method_len++] = g_buf[i++];
    g_method[g_method_len] = 0;
    i++;
    while (i < g_buf_len && g_buf[i] != ' ' && g_buf[i] != '?' && g_buf[i] != '\r' && g_path_len < 255)
        g_path[g_path_len++] = g_buf[i++];
    g_path[g_path_len] = 0;
}

int get_method_len() { return g_method_len; }
int get_path_len() { return g_path_len; }
int read_method_byte(int i) { return (i>=0 && i<g_method_len) ? (unsigned char)g_method[i] : -1; }
int read_path_byte(int i) { return (i>=0 && i<g_path_len) ? (unsigned char)g_path[i] : -1; }

// Build and send JSON response
// matched: 1=route found, 0=404
// method/path come from the parsed request (already in globals)
int send_json_response(int fd, int matched) {
    const char *status = matched ? "200 OK" : "404 Not Found";
    const char *code = matched ? "200" : "404";

    char body[512];
    int blen = snprintf(body, sizeof(body),
        "{\"server\":\"Mojo v3\",\"method\":\"%.*s\",\"path\":\"%.*s\",\"status\":\"%s\",\"matched\":%s}",
        g_method_len, g_method, g_path_len, g_path, code, matched ? "true" : "false");

    char resp[1024];
    int rlen = snprintf(resp, sizeof(resp),
        "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
        status, blen, body);

    return send(fd, resp, rlen, 0);
}

int close_fd(int fd) { return close(fd); }
