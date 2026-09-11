# fastapi_mojo — nginx 反向代理配置 (G3-v0.6)

> 单 binary 监听 `0.0.0.0:8000`. 生产部署建议 nginx 反代 + TLS 终结.
> WebSocket 原生支持 `/ws`, nginx 需按 RFC 6455 upgrade 转发.

## 0. 原生 TLS 还是反代 TLS？

决策-64（ADR-0039）起，单 binary 也可以原生监听 HTTPS：

```bash
FASTAPI_MOJO_TLS_CERT=/etc/fastapi_mojo/cert.pem \
FASTAPI_MOJO_TLS_KEY=/etc/fastapi_mojo/key.pem \
FASTAPI_MOJO_TLS_ALPN=h2,http/1.1 \
./fastapi_mojo --port 8443
```

边界与建议：

- 当前 crypto provider 是 `rustls-rustcrypto` **alpha 版**，且仅支持 TLS 1.3；
- 面向公网 / 合规生产，建议仍由 nginx、云 LB 或其它经过审计的 TLS 终结层负责证书；
- 原生 TLS 适合内网、边车、临时入口和单 binary 演示，不要求额外进程；
- 两种模式不要混用同一监听端口：启用 TLS 后明文 HTTP 会被 TLS 握手拒绝。

下方示例是 **nginx 终结 TLS、fastapi_mojo 保持内网 HTTP** 的推荐形态。

## 1. 最小 nginx 配置 (HTTP only)

```nginx
upstream fastapi_mojo {
    server 127.0.0.1:8000;
    keepalive 32;
}

server {
    listen 80;
    server_name api.example.com;
    
    # HTTPS 终结 (证书见 nginx-ssl.md 或 certbot).
    # listen 443 ssl http2;
    
    location / {
        proxy_pass http://fastapi_mojo;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # keepalive: Connection header 清空 (HTTP/1.1 keepalive)
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        # 长响应缓冲 (SSE / 大文件)
        proxy_buffering off;
        proxy_cache off;
    }
    
    # WebSocket upgrade (RFC 6455): /ws 路径
    location /ws {
        proxy_pass http://fastapi_mojo/ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        # 关闭 buffering (WS 帧要实时)
        proxy_buffering off;
        # 超时 (比 worker 的 FASTAPI_MOJO_IDLE_TIMEOUT 略长)
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
    
    # 静态文件 (单 binary 自带 /static 路由, 可选:
    #   从二进制读 -> 不经 nginx; nginx 可做缓存层)
    location /static/ {
        proxy_pass http://fastapi_mojo/static/;
        proxy_set_header Host $host;
        expires 1d;
        add_header Cache-Control "public";
    }
    
    # Prometheus metrics (可选, 内网才开)
    location /metrics {
        proxy_pass http://fastapi_mojo/metrics;
        # 建议 IP 白名单:
        # allow 10.0.0.0/8;
        # deny all;
    }
}
```

## 2. 验证

```bash
# 1. 启动 fastapi_mojo (单 binary 或 docker)
docker compose up -d

# 2. nginx 配置测试
nginx -t -c /path/to/nginx.conf

# 3. 反向代理 + health
curl -H "Host: api.example.com" http://localhost/health
curl -N http://localhost/sse           # SSE (长连接)
wscat -c ws://localhost/ws/chat        # WebSocket (wscat 或 curl --http1.1)
```

## 3. 常见坑

| 症状 | 根因 | 修复 |
|------|------|------|
| SSE 数据缓冲 1 秒后才到 | nginx proxy_buffering 开启 | `proxy_buffering off` + `proxy_cache off` |
| WS upgrade 502 | nginx 版本 <1.3 不支持 upgrade map | 用上面 `Connection "upgrade"` 硬写 (非 map) |
| keep-alive 连接断开 | nginx `Connection: close` 默认 | `proxy_set_header Connection ""` + `proxy_http_version 1.1` |
| 大响应截断 | nginx proxy_max_temp_file_size | `proxy_max_temp_file_size 0` (关闭磁盘缓冲) |
