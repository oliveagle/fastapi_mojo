# ADR-0039: Opt-in TLS/HTTPS with a pure-Rust rustls transport

**状态**：已接受
**日期**：2026-09-12
**决策**：64（Goal-0003 deployment / `tls-rustls` bead）

## 1. 背景

FastAPI/uvicorn 的生产入口通常有三种 TLS 形态：反向代理终结、stunnel/sidecar
终结，或应用进程原生 HTTPS。此前 fastapi_mojo 只支持前两类部署，单一 binary
自身监听明文 HTTP；`tls-rustls` bead 要求补齐原生入口，同时不得破坏
“Mojo + Rust only、单 binary、运行期 libc-only” 的 North Star。

rustls 默认生态常用 `ring` 或 `aws-lc-rs` 作为 crypto provider，但两者都携带
C/asm 构建路径；系统 OpenSSL 则引入外部动态依赖。它们均不可作为本项目交付面。

## 2. 目标

1. `FASTAPI_MOJO_TLS_CERT` + `FASTAPI_MOJO_TLS_KEY` 同时设置时启用 HTTPS；
   两者默认缺省，HTTP 行为零变化；
2. HTTP/1.1、WebSocket、SSE/streaming 与既有 HTTP/2 子集复用同一 Router 和
   协议状态机，不新增 Mojo 协议分支；
3. ALPN 默认 `h2,http/1.1`，可直接衔接决策-63 的 HTTP/2 子集；
4. 静态链接后 `ldd` 仍仅 libc/loader/vdso，不引入 C/asm 或 Python；
5. 证书/私钥/ALPN 配置错误必须 fail closed，不能留下明文半启动状态。

## 3. 决策

### 3.1 配置与生命周期

| 环境变量 | 语义 |
|----------|------|
| `FASTAPI_MOJO_TLS_CERT` | PEM 证书链路径；与 key 必须成对出现 |
| `FASTAPI_MOJO_TLS_KEY` | PEM 私钥路径；不支持加密私钥密码 |
| `FASTAPI_MOJO_TLS_ALPN` | 逗号分隔、按偏好排序；默认 `h2,http/1.1` |

- 配置在 `create_bound_socket()` 前经 `OnceLock` 初始化一次；证书或 key 变更
  需要重启进程，不做热加载；
- 只设置其中一个、证书链为空、私钥解析失败、provider 初始化失败或 ALPN 含
  空项/重复项/非法字符/超长项时，socket 创建返回 `-1`，Mojo 哨兵检查调用
  `bridge_fail(1)`；
- 多 worker 下每个进程独立初始化 TLS config 与 session 表，SO_REUSEPORT 语义不变；
- 启动日志在 cert/key 成对出现时显示 `https://`。

### 3.2 Crypto provider 与版本边界

采用：

```toml
rustls = { version = "=0.23.42", default-features = false, features = ["std"] }
rustls-rustcrypto = { version = "=0.0.2-alpha", default-features = false, features = ["std", "zeroize"] }
```

- `rustls` 的 `tls12` feature 未启用；当前边界为 **TLS 1.3 only**，TLS 1.2
  ClientHello 会收到 protocol version alert；
- `rustls-rustcrypto` 是 **alpha、非生产加固** 的纯 Rust provider，这是本决策
  最重要的运行边界：面向公网的生产流量仍建议优先由 nginx/反向代理终结 TLS；
- 禁止为了性能或算法覆盖切换到 `ring` / `aws-lc`；也禁止链接系统 OpenSSL；
- 本轮实测 enabled normal+build 依赖闭包 79 个 crate，无 `.c` / `.h` / `.S` /
  `.asm` 源文件（本地 vendor 中存在未启用的 `ring`，但 cargo tree 闭包不包含它）；
- 二进制增加约 733,280 B（4,221,136 → 4,954,416 B），高于 bead 估算
  200-400 KB，但仍在 CI ≤6 MiB 门禁内；后续可在不放宽安全边界的前提下评估
  provider 算法子集裁剪。

### 3.3 Transport adapter

TLS 对 Mojo 与协议层保持透明：

```
Mojo Router / WS session / H2 state machine
        ↓ (unchanged)
bridge io::sys_recv ──→ tls::recv ──→ rustls ServerConnection
bridge send::send_all → tls::send_all → rustls ServerConnection
bridge Conn::reset_for_close → close_notify + remove session → close(fd)
```

- 每进程维护 `fd → ServerConnection` 的 Mutex HashMap；fd 复用前先 remove；
- accepted socket 在进入 poll 后 attach session；`tls::recv()` 完成握手、消费
  ciphertext 并返回既有 `sys_recv` 语义（`-1` pending / `0` EOF / `-2` error）；
- 所有 HTTP/1、WS、streaming 与 H2 输出统一经 `send::send_all()`；WS 旧直连
  socket helper 改为委托同一 facade，避免第二条明文路径；
- close 时 best-effort 发送 TLS `close_notify`、flush、移除 session，再执行原
  raw fd close；
- **FFI diff = 0**：不新增、不修改任何 `extern "C"` 导出；Mojo 仍只看到字节流
  和 fd。

### 3.4 C `int` 失败哨兵修复

实测发现 Mojo 64-bit `Int` 读取 C `int` 返回值时，`create_bound_socket() = -1`
会以 `4294967295` 进入 Mojo，原有 `sfd < 0` 判断失效，导致 TLS 配置失败后仍打印
Listening 并进入空 poll。现在同时检查 `sfd < 0 || sfd > INT32_MAX`，使 bind/TLS
失败恢复 `bridge_fail(1)` fail-closed 路径。e2e TLS-9 固化该回归。

### 3.5 E2E / 开发工具边界

`scripts/e2e_test.sh` 新增 TLS-0..TLS-9：

- openssl 只在 CI/e2e 中生成一次性自签证书，是 dev tool，不进入交付 binary；
- curl 作为 TLS 客户端覆盖 HTTPS ready、GET、POST JSON、同连接 5 请求 keep-alive、
  ALPN h2、TLS 1.3、TLS 1.2 拒绝、明文 HTTP 拒绝、SIGTERM、invalid config
  fail-closed。

## 4. 备选方案对比

| 方案 | 结论 | 理由 |
|------|------|------|
| nginx/stunnel 继续独占 TLS | 拒绝为本决策终态 | 保留运维选项，但单一 binary 缺原生 HTTPS 入口 |
| rustls + `ring` | 拒绝 | C/asm 构建路径违反 North Star |
| rustls + `aws-lc` | 拒绝 | C/asm 与额外构建面违反 North Star |
| 系统 OpenSSL | 拒绝 | 外部动态依赖，破坏 single binary / libc-only |
| 手写 TLS 协议与密码学 | 拒绝 | 密码学实现安全风险过高 |
| rustls + RustCrypto provider | 接受（opt-in） | 纯 Rust、静态链接；alpha 边界显式文档化 |

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|------|------|------|
| 1. 无循环依赖 | ✅ 遵守 | `socket/io/send/conn → tls → rustls` 单向；TLS 不回读 Router、Handler、HTTP/2 或 WS 协议状态 |
| 2. 分层向下依赖 | ✅ 遵守 | TLS 位于 raw-fd transport adapter；Mojo 请求语义与既有 poll 循环不感知证书、握手或 record framing |
| 3. God package 阈值 | ✅ 遵守 | `bridge/tls.rs` 395 行、`bridge/tls_tests.rs` 25 行，均 <500 行；未扩大既有超大模块 |
| 4. 主题域边界清晰 | ✅ 遵守 | TLS 配置、rustls session、ALPN、close_notify 全部收敛在 `tls.rs`；不混入 HTTP 解析、路由、WS 业务或 OpenAPI |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff=0**；第三方依赖只新增 rustls + RustCrypto provider，且关闭 default features、不启用 `ring`/`aws-lc` |
| 6. 测试文件跟随 | ✅ 遵守 | `tls_tests.rs` 与生产模块同目录；真实 binary e2e 覆盖 TLS-0..TLS-9 |

## 6. 验收（2026-09-12）

- Rust bridge：**486 passed / 0 failed / 4 ignored**；clippy `--release --tests -D warnings` **0 警告**
- fmtool：**35 passed / 0 failed**；clippy **0 警告**
- build：`CARGO_HOME=/tmp/fm-cargo-home ./build_single.sh` 成功；binary **4,954,416 B**（≤6 MiB；较 ADR-0038 +733,280 B）
- e2e：511 → **521/521**（新增 TLS-0..TLS-9，既有 511 零回归）
- manual smoke：HTTPS GET/POST 200；同连接 5 请求复用；20 并发 HTTPS + 10 并发 ALPN h2 全 200；3 worker × 30 请求全 200；TLS 1.3；明文 HTTP 拒绝；SIGTERM 干净退出
- benchmark：6 场景 **0 errors**；get_root_10k_100c = **32,372.94 req/s**（未启用 TLS 的默认 HTTP 门禁）
- `ldd`：仅 libc / loader / vdso
- clean env：`env -i PATH=/usr/bin:/bin` 默认 HTTP 与显式 cert/key TLS 启动均 health 200，SIGTERM 干净退出
- enabled 依赖闭包：无 C/asm 源文件
- `find src -name '*.c'` = 0；交付面 `*.py` = 0；无孤儿 server 进程

## 7. 文档化偏差 / 后续边界

1. `rustls-rustcrypto` 0.0.2-alpha 不是生产级加固 provider；公网生产建议反向代理终结；
2. TLS 1.3 only，TLS 1.2 不启用；
3. 无 client mTLS / CA trust 配置；
4. 不支持加密私钥密码输入；
5. 无证书热加载、OCSP stapling、多 SNI 证书选择、session ticket 调优或 key log；
6. 无 HTTPS→HTTP 自动重发、HSTS、Secure/Rewrite cookie 策略；
7. e2e 尚无 WSS 客户端；WS 输入/输出已走同一 TLS adapter，后续可扩展 fmtool TLS；
8. TLS 发送背压当前按连接失败处理，不把 fd 挂入独立 write-ready 队列；
9. 二进制体积 +733 KB，虽在 CI 门禁内但值得后续做 provider 算法子集裁剪。

## 8. 实现

- `src/fastapi_mojo_rs/Cargo.toml`：rustls / RustCrypto provider 依赖与 feature 收敛
- `src/fastapi_mojo_rs/src/bridge/tls.rs`：config OnceLock、ALPN parser、fd→session、recv/send/close adapter
- `src/fastapi_mojo_rs/src/bridge/tls_tests.rs`：ALPN 单测
- `src/fastapi_mojo_rs/src/bridge/{socket,io,conn,send}.rs`：初始化、recv/send/close 接线
- `src/fastapi_mojo_rs/src/ws.rs`：WS 发送复用统一 send facade
- `src/fastapi_mojo/http_server_final.mojo`：https 启动显示 + C `int` 失败哨兵修复
- `scripts/e2e_test.sh`：TLS-0..TLS-9 真实 binary 集成测试
- `README.md` / `docs/deploy-nginx.md` / `AGENTS.md` / Goal-0003：决策-64 使用与边界记录
