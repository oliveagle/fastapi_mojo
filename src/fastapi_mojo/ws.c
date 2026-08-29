// src/fastapi_mojo/ws.c
//
// WebSocket (RFC 6455) 协议层 — fastapi_mojo 单一 binary 的 WS 支持 (ADR-0006).
//
// 纯 C、零依赖: SHA-1 + base64 (握手 Sec-WebSocket-Accept)、帧编解码
// (掩码 / 7|16|64-bit 长度 / 分片重组)、以及最小 echo 会话
// (text/binary 回显, ping->pong, close->close)。
//
// 边界 (与 ADR-0006 §4 一致):
//   - 本文件只做 RFC 6455 协议 + 对给定 fd 的原始 I/O;
//     连接生命周期 (accept/超时/conn_done/worker) 归 http_bridge_final.c;
//     路由决策 (是否 /ws + 升级头) 归 Mojo (http_server_final.mojo)。
//   - 通过 external_call["ws_upgrade_and_echo"] 被 Mojo 以单一显式入口调用。
//
// 已知限制 (文档化, ADR-0006):
//   - 单条消息上限 1 MB (与 HTTP body 上限一致)
//   - 帧间隔超过 socket SO_RCVTIMEO (FASTAPI_MOJO_RECV_TIMEOUT, 默认 5s)
//     即断开; 客户端可用 ping 帧保活 (服务端回 pong)
//   - 仅 /ws 一个端点 (echo); 无 subprotocol / 无鉴权

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define WS_MAX_MSG (1024 * 1024)
static const char WS_GUID[] = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"; // 36 chars

// ---------- SHA-1 (FIPS 180-1) ----------
static void ws_sha1(const unsigned char *data, size_t len, unsigned char out[20]) {
    uint32_t h[5] = {0x67452301u, 0xEFCDAB89u, 0x98BADCFEu, 0x10325476u, 0xC3D2E1F0u};
    uint32_t w[80];
    size_t padded = (((len + 8) / 64) + 1) * 64;
    unsigned char *p = (unsigned char *)malloc(padded);
    if (!p) return;
    memcpy(p, data, len);
    p[len] = 0x80;
    for (size_t i = len + 1; i < padded - 8; i++) p[i] = 0;
    uint64_t bitlen = (uint64_t)len * 8u;
    for (int i = 0; i < 8; i++)
        p[padded - 1 - i] = (unsigned char)((bitlen >> (8 * i)) & 0xFFu);
    for (size_t off = 0; off < padded; off += 64) {
        for (int i = 0; i < 16; i++)
            w[i] = ((uint32_t)p[off + 4 * i] << 24) | ((uint32_t)p[off + 4 * i + 1] << 16) |
                   ((uint32_t)p[off + 4 * i + 2] << 8) | (uint32_t)p[off + 4 * i + 3];
        for (int i = 16; i < 80; i++) {
            uint32_t x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
            w[i] = (x << 1) | (x >> 31);
        }
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
        for (int i = 0; i < 80; i++) {
            uint32_t f, k;
            if (i < 20) { f = (b & c) | ((~b) & d); k = 0x5A827999u; }
            else if (i < 40) { f = b ^ c ^ d; k = 0x6ED9EBA1u; }
            else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDCu; }
            else { f = b ^ c ^ d; k = 0xCA62C1D6u; }
            uint32_t tmp = ((a << 5) | (a >> 27)) + f + e + k + w[i];
            e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = tmp;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
    }
    free(p);
    for (int i = 0; i < 5; i++) {
        out[4 * i]     = (unsigned char)((h[i] >> 24) & 0xFFu);
        out[4 * i + 1] = (unsigned char)((h[i] >> 16) & 0xFFu);
        out[4 * i + 2] = (unsigned char)((h[i] >> 8) & 0xFFu);
        out[4 * i + 3] = (unsigned char)(h[i] & 0xFFu);
    }
}

// ---------- base64 (encode, NUL-terminated) ----------
static void ws_b64encode(const unsigned char *in, size_t inlen, char *out, size_t outsz) {
    static const char tbl[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t o = 0;
    for (size_t i = 0; i < inlen; i += 3) {
        unsigned int b0 = in[i];
        unsigned int b1 = (i + 1 < inlen) ? in[i + 1] : 0;
        unsigned int b2 = (i + 2 < inlen) ? in[i + 2] : 0;
        unsigned int t = (b0 << 16) | (b1 << 8) | b2;
        if (o + 4 < outsz) {
            out[o++] = tbl[(t >> 18) & 0x3Fu];
            out[o++] = tbl[(t >> 12) & 0x3Fu];
            out[o++] = (i + 1 < inlen) ? tbl[(t >> 6) & 0x3Fu] : '=';
            out[o++] = (i + 2 < inlen) ? tbl[t & 0x3Fu] : '=';
        }
    }
    if (o < outsz) out[o] = '\0';
}

// Sec-WebSocket-Accept = base64(SHA1(key + GUID))  (RFC 6455 §4.1)
int ws_compute_accept(const char *key, char *out, size_t outsz) {
    size_t klen = strlen(key);
    size_t total = klen + sizeof(WS_GUID) - 1;
    unsigned char *data = (unsigned char *)malloc(total);
    unsigned char sha[20] = {0};
    if (!data) return -1;
    memcpy(data, key, klen);
    memcpy(data + klen, WS_GUID, sizeof(WS_GUID) - 1);
    ws_sha1(data, total, sha);
    free(data);
    ws_b64encode(sha, 20, out, outsz);
    return 0;
}

// ---------- 原始 I/O (fd 上的精确读写) ----------
static int ws_read_exact(int fd, unsigned char *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = recv(fd, buf + got, n - got, 0);
        if (r <= 0) return -1;  // EOF 或 SO_RCVTIMEO 超时 -> 丢弃连接
        got += (size_t)r;
    }
    return 0;
}

static int ws_send_all(int fd, const unsigned char *buf, size_t n) {
    size_t sent = 0;
    while (sent < n) {
        ssize_t r = send(fd, buf + sent, n - sent, 0);
        if (r <= 0) return -1;
        sent += (size_t)r;
    }
    return 0;
}

// ---------- 握手: 101 Switching Protocols ----------
int ws_handshake(int fd, const char *key) {
    char accept[64];
    if (ws_compute_accept(key, accept, sizeof accept) != 0) return -1;
    char resp[256];
    int n = snprintf(resp, sizeof resp,
                     "HTTP/1.1 101 Switching Protocols\r\n"
                     "Upgrade: websocket\r\n"
                     "Connection: Upgrade\r\n"
                     "Sec-WebSocket-Accept: %s\r\n"
                     "\r\n",
                     accept);
    if (n < 0 || (size_t)n >= sizeof resp) return -1;
    return ws_send_all(fd, (const unsigned char *)resp, (size_t)n);
}

// ---------- 帧读取: 一条完整消息 (分片重组; 控制帧原样返回) ----------
// *opcode: 1=text 2=binary 8=close 9=ping 10=pong
// *payload: malloc 分配, 用 ws_free_payload 释放
// 返回 0 成功, -1 错误/超时/EOF/超限
int ws_read_message(int fd, int *opcode, unsigned char **payload, size_t *plen) {
    static unsigned char reasm[WS_MAX_MSG];
    size_t reasm_len = 0;
    int msg_opcode = -1;
    for (;;) {
        unsigned char h[2];
        if (ws_read_exact(fd, h, 2) != 0) return -1;
        int fin = (h[0] & 0x80) != 0;
        int op = h[0] & 0x0F;
        int masked = (h[1] & 0x80) != 0;
        uint64_t len = h[1] & 0x7F;
        if (len == 126) {
            unsigned char e2[2];
            if (ws_read_exact(fd, e2, 2) != 0) return -1;
            len = ((uint64_t)e2[0] << 8) | e2[1];
        } else if (len == 127) {
            unsigned char e8[8];
            if (ws_read_exact(fd, e8, 8) != 0) return -1;
            len = 0;
            for (int i = 0; i < 8; i++) len = (len << 8) | e8[i];
        }
        if (len > WS_MAX_MSG) return -1;
        unsigned char mask[4] = {0, 0, 0, 0};
        if (masked && ws_read_exact(fd, mask, 4) != 0) return -1;
        unsigned char *p = (unsigned char *)malloc(len ? len : 1);
        if (!p) return -1;
        if (len > 0 && ws_read_exact(fd, p, len) != 0) { free(p); return -1; }
        if (masked)
            for (uint64_t i = 0; i < len; i++) p[i] ^= mask[i % 4];

        // 控制帧 (close/ping/pong) 不可分片 (RFC 6455 §5.5): 原样返回
        if (op >= 8) {
            *opcode = op;
            *payload = p;
            *plen = (size_t)len;
            return 0;
        }
        // 数据帧: op!=0 = 消息首帧; op==0 = 延续帧
        if (op != 0) {
            msg_opcode = op;
            reasm_len = 0;
        }
        if (reasm_len + (size_t)len > WS_MAX_MSG) { free(p); return -1; }
        memcpy(reasm + reasm_len, p, (size_t)len);
        reasm_len += (size_t)len;
        free(p);
        if (fin) {
            *opcode = msg_opcode;
            *payload = (unsigned char *)malloc(reasm_len ? reasm_len : 1);
            if (!*payload) return -1;
            memcpy(*payload, reasm, reasm_len);
            *plen = reasm_len;
            return 0;
        }
    }
}

void ws_free_payload(unsigned char *p) { free(p); }

// ---------- 帧写入: 单帧, 未掩码 (server -> client, RFC 6455 §5.1) ----------
int ws_write_message(int fd, int opcode, const unsigned char *payload, size_t plen) {
    unsigned char hdr[10];
    hdr[0] = (unsigned char)(0x80 | (opcode & 0x0F));  // FIN=1, 不掩码
    size_t hlen;
    if (plen < 126) {
        hdr[1] = (unsigned char)plen;
        hlen = 2;
    } else if (plen <= 0xFFFF) {
        hdr[1] = 126;
        hdr[2] = (unsigned char)(plen >> 8);
        hdr[3] = (unsigned char)(plen & 0xFF);
        hlen = 4;
    } else {
        hdr[1] = 127;
        for (int i = 0; i < 8; i++)
            hdr[2 + i] = (unsigned char)((plen >> (56 - 8 * i)) & 0xFFu);
        hlen = 10;
    }
    if (ws_send_all(fd, hdr, hlen) != 0) return -1;
    if (plen > 0 && ws_send_all(fd, payload, plen) != 0) return -1;
    return 0;
}

// ---------- 完整会话: 握手 + 最小 echo 循环 ----------
// text/binary -> 原样回显; ping -> pong; close -> close 后结束。
// 返回 0 正常关闭, -1 错误/超时/EOF。
int ws_upgrade_and_echo(int fd, const char *key) {
    if (ws_handshake(fd, key) != 0) return -1;
    for (;;) {
        int op;
        unsigned char *payload;
        size_t plen;
        if (ws_read_message(fd, &op, &payload, &plen) != 0) return -1;
        if (op == 8) {  // close: 回显 close (至多 2 字节 code), 结束会话
            (void)ws_write_message(fd, 8, payload, plen > 2 ? 2 : plen);
            ws_free_payload(payload);
            return 0;
        } else if (op == 9) {  // ping -> pong (同载荷)
            (void)ws_write_message(fd, 10, payload, plen);
            ws_free_payload(payload);
        } else if (op == 10) {  // pong -> 忽略
            ws_free_payload(payload);
        } else {  // text/binary -> 回显
            (void)ws_write_message(fd, op, payload, plen);
            ws_free_payload(payload);
        }
    }
}
