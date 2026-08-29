// src/fastapi_mojo/ws.c
//
// WebSocket (RFC 6455) 协议层 — fastapi_mojo 单一 binary 的 WS 支持
// (ADR-0006 基础, ADR-0007 增强).
//
// 纯 C、零依赖: SHA-1 + base64 (握手 Sec-WebSocket-Accept)、帧编解码
// (掩码 / 7|16|64-bit 长度 / 分片重组)、close 码校验、text UTF-8 校验。
//
// 边界 (与 ADR-0006/0007/0008 一致):
//   - 本文件只做 RFC 6455 协议原语: 握手、**状态化帧解析器** (非阻塞 feed,
//     partial frame 安全)、帧写、close 码校验、text UTF-8 校验。
//   - **会话由 bridge poll 循环驱动 (ADR-0008)**: 每个 WS 连接有自己的
//     ws_parser_t + 重组缓冲 (bridge 的 conn 字段); 控制帧 (ping/pong/close)
//     与保活、UTF-8 校验由 bridge 在 poll 循环内自动处理 (纯协议);
//     数据帧 (text/binary) 经 FIFO 事件队列逐条交给 Mojo 分派 —
//     Mojo 不再阻塞在 recv 上, 多 WS 会话与 HTTP 并发不互相阻塞。
//   - 连接生命周期 (accept/超时/conn_done/worker) 归 http_bridge_final.c;
//     路由决策 (哪个 path 是 WS 端点) 归 router.mojo。
//
// 已知限制 (文档化, ADR-0006/0007/0008):
//   - 单条消息上限 1 MB (与 HTTP body 上限一致, WS_MAX_MSG)
//   - 客户端必须掩码 (RFC 6455 §5.1); 未掩码帧 = 协议错误
//   - 保活/空闲超时由 bridge 的 poll 周期 (1s tick) 粒度执行

#include <errno.h>
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
// subprotocol 非 NULL 且非空 -> 101 响应含 `Sec-WebSocket-Protocol: <sp>`
// (RFC 6455 §4.1: 服务端只能选择客户端提供的子协议)。
int ws_handshake(int fd, const char *key, const char *subprotocol) {
    char accept[64];
    if (ws_compute_accept(key, accept, sizeof accept) != 0) return -1;
    char resp[320];
    int n;
    if (subprotocol != NULL && subprotocol[0] != '\0') {
        n = snprintf(resp, sizeof resp,
                     "HTTP/1.1 101 Switching Protocols\r\n"
                     "Upgrade: websocket\r\n"
                     "Connection: Upgrade\r\n"
                     "Sec-WebSocket-Accept: %s\r\n"
                     "Sec-WebSocket-Protocol: %s\r\n"
                     "\r\n",
                     accept, subprotocol);
    } else {
        n = snprintf(resp, sizeof resp,
                     "HTTP/1.1 101 Switching Protocols\r\n"
                     "Upgrade: websocket\r\n"
                     "Connection: Upgrade\r\n"
                     "Sec-WebSocket-Accept: %s\r\n"
                     "\r\n",
                     accept);
    }
    if (n < 0 || (size_t)n >= sizeof resp) return -1;
    return ws_send_all(fd, (const unsigned char *)resp, (size_t)n);
}

// ---------- 状态化帧解析器 (非阻塞 feed, ADR-0008) ----------
// 每个 WS 连接一个 ws_parser_t (bridge conn 字段)。feed 任意长度的原始
// 字节块 (poll 循环的 MSG_DONTWAIT recv 结果), partial frame 安全。
//
// 数据消息重组在 reasm (WS_MAX_MSG+1, 调用方持有; 消息完成时 NUL 结尾)。
// 控制帧载荷也写入 reasm[0..mlen) (≤125B, 处理后立即可被下一条消息覆盖 —
// bridge 在返回前同步处理完控制帧)。
//
// 返回: 0 = 暂无完整消息; 1 = 数据消息完成 (*opcode/*melen, reasm);
//       2 = 控制帧完成 (*opcode/*melen, reasm); -1 = 协议错误 (应 close 1002)
typedef struct {
    int stage;          // 0=hdr0 1=hdr1 2=extlen 3=mask 4=payload
    int fin, opcode, masked;
    unsigned char ext[8];
    int ext_need, ext_got;
    uint64_t flen;
    unsigned char mask[4];
    int mask_got;
    uint64_t pgot;
    int in_msg;         // 数据消息分片进行中
    int msg_opcode;
    size_t reasm_len;
} ws_parser_t;

void ws_parser_init(ws_parser_t *p) { memset(p, 0, sizeof(*p)); }

static int ws_parser_frame_done(ws_parser_t *p, int *opcode, size_t *melen,
                                unsigned char *reasm) {
    // 一帧 payload 收齐: 控制帧立即返回; 数据帧做分片重组
    if (p->opcode >= 8) {
        if (!p->fin || p->flen > 125) return -1;  // 控制帧必须 fin=1 且 ≤125B
        *opcode = p->opcode;
        *melen = (size_t)p->flen;
        reasm[*melen] = 0;
        return 2;
    }
    if (p->opcode == 0) {
        if (!p->in_msg) return -1;  // 无消息起始的延续帧
    } else {
        if (p->in_msg) return -1;   // 消息未结束时又来新数据帧
        p->msg_opcode = p->opcode;
        p->reasm_len = 0;
    }
    p->reasm_len += (size_t)p->flen;
    if (p->fin) {
        reasm[p->reasm_len] = 0;    // NUL 结尾 (Mojo FFI 约定, ADR-0007 §5)
        *opcode = p->msg_opcode;
        *melen = p->reasm_len;
        p->in_msg = 0;
        p->reasm_len = 0;
        return 1;
    }
    p->in_msg = 1;
    return 0;
}

int ws_parser_feed(ws_parser_t *p, const unsigned char *buf, size_t n,
                   int *opcode, size_t *melen, unsigned char *reasm) {
    size_t off = 0;
    while (off < n) {
        if (p->stage == 4) {
            // payload: 批量拷贝 (不逐字节消耗 — 逐字节会在进入本阶段的首次迭代
            // 丢失 1 个字节; 头部 stage 0-3 才按字节推进)
            uint64_t need = p->flen - p->pgot;
            size_t avail = n - off;
            size_t take = avail < need ? avail : (size_t)need;
            // 帧内偏移 = 本帧已收字节 (pgot); 数据帧再加消息级偏移 (reasm_len)。
            // 漏掉 pgot 会让分块帧的所有块都从 0 覆盖 (大消息损坏)。
            size_t dst = (p->opcode >= 8) ? p->pgot : p->reasm_len + p->pgot;
            for (size_t i = 0; i < take; i++)
                reasm[dst + i] = buf[off + i] ^ p->mask[(p->pgot + i) % 4];
            off += take;
            p->pgot += take;
            if (p->pgot < p->flen) break;  // 帧未完, 等下一块
            p->stage = 0;
            // 注意: 不清 p->fin/p->masked — frame_done 需要本帧的 fin 判定
            // 消息完成; 下一帧在 stage 0/1 覆盖它们
            int r = ws_parser_frame_done(p, opcode, melen, reasm);
            if (r != 0) return r;  // 1/2 = 完整消息/控制帧; -1 = 协议错误
            continue;  // 同块内可能还有下一帧
        }
        unsigned char b = buf[off++];
        switch (p->stage) {
        case 0:  // 字节 0: FIN + opcode
            p->fin = (b & 0x80) != 0;
            p->opcode = b & 0x0F;
            if (p->opcode >= 3 && p->opcode <= 7) return -1;  // 保留 opcode
            if (p->opcode == 0 && !p->in_msg) return -1;      // 孤立的延续帧
            p->stage = 1;
            break;
        case 1:  // 字节 1: MASK + 7-bit 长度
            p->masked = (b & 0x80) != 0;
            if (!p->masked) return -1;  // RFC 6455 §5.1: 客户端帧必须掩码
            {
                uint64_t l7 = b & 0x7F;
                if (l7 < 126) {
                    p->flen = l7;
                    p->mask_got = 0;  // 逐帧重置 (否则跨帧残留 -> 越界写 mask[])
                    p->stage = 3;  // 直接进 mask
                } else {
                    p->ext_need = (l7 == 126) ? 2 : 8;
                    p->ext_got = 0;
                    p->stage = 2;
                }
            }
            break;
        case 2:  // 扩展长度 (2 或 8 字节, 大端)
            p->ext[p->ext_got++] = b;
            if (p->ext_got < p->ext_need) break;
            p->flen = 0;
            for (int i = 0; i < p->ext_need; i++) p->flen = (p->flen << 8) | p->ext[i];
            if (p->flen > WS_MAX_MSG) return -1;
            // 重组越界预检 (数据帧; 控制帧在 frame_done 再查 ≤125)
            if (p->opcode == 0 && p->reasm_len + p->flen > WS_MAX_MSG) return -1;
            p->mask_got = 0;  // 逐帧重置
            p->stage = 3;
            break;
        case 3:  // 掩码键 (4 字节)
            p->mask[p->mask_got++] = b;
            if (p->mask_got < 4) break;
            p->pgot = 0;
            p->stage = 4;
            break;
        default:
            return -1;
        }
    }
    return 0;
}


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

// ---------- close 码校验 (RFC 6455 §7.4.1) ----------
// *code: 收到的码 (plen==0 时写 0)
// 返回: 1 = 合法 (1000/1001/3000..4999, 可回显);
//       0 = 空 payload (约定按 1000 回复);
//      -1 = 非法 (保留码/越界, 应回 1002)
int ws_parse_close_code(const unsigned char *payload, size_t plen, int *code) {
    if (plen == 0) { *code = 0; return 0; }
    if (plen < 2) return -1;
    int c = ((int)payload[0] << 8) | payload[1];
    *code = c;
    if (c == 1000 || c == 1001 || (c >= 3000 && c <= 4999)) return 1;
    return -1;
}

// 对收到的 close 帧载荷回复 (RFC 6455 §7.4.1): 合法码 -> 回显 (code+reason,
// 上限 125B, §5.5); 空载荷 -> 1000; 非法码 -> 1002。
int ws_reply_close_buf(int fd, const unsigned char *payload, size_t n) {
    int code = 0;
    int r = ws_parse_close_code(payload, n, &code);
    if (r == -1) {
        unsigned char p2[2] = { 0x03, 0xEA };  // 1002 Protocol error
        return ws_write_message(fd, 8, p2, 2);
    }
    if (r == 0) {
        unsigned char p2[2] = { 0x03, 0xE8 };  // 1000 Normal closure
        return ws_write_message(fd, 8, p2, 2);
    }
    size_t cap = (n > 125) ? 125 : n;
    return ws_write_message(fd, 8, payload, cap);
}

// ---------- text 帧 UTF-8 校验 (RFC 6455 §5.6: text 必须是合法 UTF-8) ----------
// 1 = 合法; 0 = 非法 (会话应回 1007 并结束)
int ws_validate_utf8(const unsigned char *p, size_t n) {
    size_t i = 0;
    while (i < n) {
        unsigned char b = p[i];
        if (b < 0x80) { i += 1; continue; }
        int extra;
        unsigned int cp;
        if ((b & 0xE0) == 0xC0) { extra = 1; cp = b & 0x1Fu; }
        else if ((b & 0xF0) == 0xE0) { extra = 2; cp = b & 0x0Fu; }
        else if ((b & 0xF8) == 0xF0) { extra = 3; cp = b & 0x07u; }
        else return 0;  // 孤立延续字节 / 非法首字节
        if (i + (size_t)extra >= n) return 0;  // 截断 (需要 extra 个后续字节)
        int ok = 1;
        for (size_t k = 1; k <= (size_t)extra; k++) {
            if ((p[i + k] & 0xC0) != 0x80) { ok = 0; break; }
            cp = (cp << 6) | (p[i + k] & 0x3Fu);
        }
        if (!ok) return 0;
        if (extra == 1 && cp < 0x80) return 0;                        // overlong
        if (extra == 2 && (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF))) return 0;
        if (extra == 3 && (cp < 0x10000 || cp > 0x10FFFF)) return 0;
        i += 1 + (size_t)extra;
    }
    return 1;
}
