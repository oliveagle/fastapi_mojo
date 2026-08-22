// http_helpers.c — HTTP server helpers for Mojo FFI

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#define BUF_SIZE 4096

int create_bound_socket(int port) {
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) return -1;

    int opt = 1;
    setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    if (bind(sockfd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(sockfd);
        return -1;
    }

    if (listen(sockfd, 128) < 0) {
        close(sockfd);
        return -1;
    }

    return sockfd;
}

int accept_connection(int server_fd) {
    struct sockaddr_in client_addr;
    socklen_t client_len = sizeof(client_addr);
    return accept(server_fd, (struct sockaddr*)&client_addr, &client_len);
}

// Receive request, parse method+path, send JSON response, close client.
// Returns 0 on success, -1 on error.
int handle_request(int client_fd) {
    char buf[BUF_SIZE];
    int n = recv(client_fd, buf, BUF_SIZE - 1, 0);
    if (n <= 0) return -1;
    buf[n] = '\0';

    // Parse method and path from "METHOD /path HTTP/1.x\r\n..."
    char method[16] = {0};
    char path[256] = {0};
    sscanf(buf, "%15s %255s", method, path);

    // Build JSON body
    char body[512];
    snprintf(body, sizeof(body),
        "{\"message\":\"Hello from Mojo HTTP Server\",\"method\":\"%s\",\"path\":\"%s\"}",
        method, path);

    // Build HTTP response
    char resp[1024];
    int resp_len = snprintf(resp, sizeof(resp),
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "\r\n"
        "%s",
        strlen(body), body);

    send(client_fd, resp, resp_len, 0);
    close(client_fd);
    return 0;
}

int close_fd(int fd) {
    return close(fd);
}
