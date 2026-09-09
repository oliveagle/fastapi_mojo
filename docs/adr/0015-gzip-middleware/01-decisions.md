# ADR-0015: GZip 响应压缩（FastAPI/Starlette GZipMiddleware 声明式等价，env 驱动）

- **日期**：2026-09-09
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行，Goal-0003 P2 矩阵 #24 落地）
- **关联**：AGENTS.md §3.1/§6（**决策-40**）、Goal-0003（P2：压缩 GZipMiddleware）、
  North Star（单 binary 零依赖 — flate2 纯 Rust miniz_oxide 后端，静态，
  ldd 仍仅 libc）、Starlette `GZipMiddleware`（min_size=500 / compresslevel=6 /
  `_zlib_accept_encoding` quirk）、决策-36（env 声明式横切配置模式）

## 1. 背景

FastAPI 的 `fastapi.middleware.GZipMiddleware`（继承 Starlette）是矩阵 **第 24 项**
（❌ 缺失）：客户端 `Accept-Encoding: gzip` 时压缩响应体（`Content-Encoding: gzip`，
`Content-Length` 更新，Content-Type 不变），压缩下限 `min_size=500`，级别 6。

约束（Mojo 1.0.0 + North Star）：
- Mojo 无闭包 / 无中间件对象 → Starlette 的 `async __call__(scope,receive,send)`
  包装器形态不可移植；本项目横切能力一律**声明式 env**（lifespan / access-log /
  worker 数同模式，决策-36 先例）
- Mojo 无压缩库 → gzip 由 **Rust bridge** 承载（Mojo 1.0.0 std 缺口的既定
  归属层，§3.3）
- flate2 已在 Cargo.toml（ws-deflate 预置，决策链未定）——本 ADR 将其**第一个
  用途落地**；flate2 默认后端 = **纯 Rust miniz_oxide**（无 zlib-ng / C 路径），
  静态链接进 staticlib → ldd 仍仅 libc（North Star 不破，实测确认）

## 2. 候选方案

| 方案 | 描述 | 评估 |
|------|------|------|
| A. Mojo 侧 gzip | Mojo 手写 DEFLATE | ❌ 算法复杂度极高（LZ77 + Huffman），与 North Star「协议层 Mojo 原生」冲突（压缩是编解码设施，非 HTTP 协议语义）；易错 |
| B. **Rust bridge gzip + env 声明式开关（本 ADR）** | `bridge/gzip.rs`（flate2 纯 Rust）+ `send_response` 单点钩子 + `FASTAPI_MOJO_GZIP*` env；client 侧判定经 request 全局（`set_accepts_gzip`，io.rs 解析 header 时写入） | ✅ 钩子单点（所有响应类型必经 `send_response`）；声明式 = 现有模式；FFI 面 diff = 0（无新 extern "C"）；纯 Rust 依赖，ldd 不破 |
| C. 每个 send_* 函数分别加 gzip | 8+ 个入口各改 | ❌ 重复 8 次；新增响应类型会漏；与「新能力 = 单点钩子」约束冲突 |

**决策：B** —— Rust bridge gzip + 声明式 env（决策-40）。

## 3. 决策

1. **env API（声明式，进程启动一次读取，Mutex<Option> 缓存）**：
   - `FASTAPI_MOJO_GZIP=1|true|yes|on` —— 启用（**默认关** = FastAPI 默认无 gzip）
   - `FASTAPI_MOJO_GZIP_MIN_SIZE`（默认 **500**，对齐 Starlette）
   - `FASTAPI_MOJO_GZIP_MAX_SIZE`（默认 **1 MiB**，内存保护，对齐静态文件上限）
2. **压缩条件（Starlette GZipMiddleware 对齐）**：
   请求 `Accept-Encoding` 含**裸 token** `gzip`/`x-gzip`（strip 后精确匹配，
   **不支持 q-value** —— 上游 `_zlib_accept_encoding` quirk：`gzip;q=0.5` 不算；
   `parse::accepts_gzip` 纯函数）+ 响应 `include_body` + body 非空 +
   `min_size <= len <= max_size` + status 非 304 + extra 未声明
   `Content-Encoding`（按头名判定）。
3. **钩子位置 = `send_response` 单点**（send.rs）：所有动态/静态/SSE/HTML/
   error 响应必经；压缩时 body 换 gzip 字节（level 6 = `Compression::default()`，
   对齐 Starlette），响应头追加 `Content-Encoding: gzip`（与既有 extra 行按
   `\r\n` 合并），Content-Length = 压缩后长度，Content-Type 不变。
4. **client 判定走 request 全局**：io.rs 解析 header 时 `set_accepts_gzip(
   parse::accepts_gzip(hdr))`（CurrentRequest 新增字段，reset_request_fields
   复位）—— 沿用「worker 进程内单请求串行 + 请求全局」既定线程模型（决策-20
   FFI 契约同一体系），无新 FFI 导出（**FFI diff = 0**）。
5. **config 用 `Mutex<Option<GzipConfig>>` 而非 OnceLock**：单线程 worker 下
   无竞争；Mutex 额外提供 `#[cfg(test)] __test_reset_config()` 钩子隔离
   env 全局副作用（与 conn 的 `sys_close` no-op 同一类测试隔离机制）。
6. **e2e 零 python3（Track B 决策-22）**：roundtrip 验证用 `curl --compressed`
   自动 gunzip + `cmp` 逐字节比对（GZ-5）。

## 4. 风险

| 风险 | 缓解 |
|------|------|
| flate2 意外引入 C 依赖（zlib-ng feature） | 用默认 feature（miniz_oxide 纯 Rust）；**实测** ldd build/fastapi_mojo 仍仅 libc（3,207,192 B） |
| 压缩所有 Content-Type（Starlette 不按 CT 过滤）压缩不可压数据浪费 CPU | max_size 1MiB 上限 + min_size 500 下限；level 6 平衡（Starlette 同款）；SSE 一次性推送同样受益 |
| env 默认关 vs FastAPI 默认关 | 完全对齐（GZ-1 e2e 验证）；启用是部署方声明（nginx 时代可改反代层 gzip） |
| q-value 语义（`gzip;q=0` 上游也压，quirk 对齐） | 已知与 RFC 不符但**与上游一致**；文档注明 |
| `send_response` 增加 Mutex lock（config）+ 判定 | bench 6 场景 0 errors，get_root_10k_100c 39.2k req/s（历史区间 32.9k–43.9k 内，噪声）；未接受 gzip 的客户端只多 2 次 bool/size 比较 |

## 5. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 单向：`send` → `gzip`（config/should_gzip/gzip_compress）+ `request`（accepts_gzip 全局）；`gzip` 只依赖 std + flate2（crate 内零同层 import）；`io` → `parse`（accepts_gzip 纯函数）+ `request`（setter） |
| 2. 分层向下依赖 | ✅ 遵守 | gzip 压缩 = 编解码设施，归 Rust bridge（§3.3 Mojo std 缺口归属层）；Mojo 侧零代码改动（纯 env 声明，dispatch 零分支 — 与 lifespan/access-log 同一声明式模式） |
| 3. God package 阈值 | ✅ 遵守 | gzip.rs **~130 LOC** / send.rs **339** / parse.rs **257** / request.rs **489**（均 <500）；io.rs 810（既有超阈值文件，本 ADR 仅 +2 行 set_accepts_gzip 调用，无新分支） |
| 4. 主题域边界清晰 | ✅ 遵守 | gzip.rs 只管「配置 + 判定 + 压缩」纯逻辑（不碰 fd）；send.rs 只管「何时压缩 + 头装配」；client 判定（Accept-Encoding 解析）归 parse.rs（header 工具域）；request 全局只管状态存储 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（无新 extern "C" 导出；`set_accepts_gzip`/`config`/`should_gzip`/`gzip_compress` 全是 crate 内 Rust API）；Cargo.toml 唯一第三方 = flate2（纯 Rust miniz_oxide，静态，ldd 仅 libc 实测） |
| 6. 测试文件跟随 | ✅ 遵守 | `gzip_tests.rs`（should_gzip 矩阵 / env 读取 / text+binary 0..255 roundtrip）+ `parse_tests.rs`（accepts_gzip 4 测）+ `request.rs` tests（set/reset）+ `send_tests.rs`（socketpair 真 fd 全链路 gzip + identity 对照，含 config 重置钩子）；e2e **GZ-1..GZ-5 = 210/210 全绿** |

## 7. 验证方式

1. **单 binary 不变式**：`ldd build/fastapi_mojo` 仅 libc（**3,207,192 B = 3.1M**，
   ≤4.2M）；`env -i ./build/fastapi_mojo --port N` 干净启动（health 200）。
2. **e2e 全量不回归**：205 → **210**（+5 GZ 项）全绿：
   - GZ-1 默认关（无 env）+ Accept-Encoding: gzip → 无 Content-Encoding（FastAPI 对齐）
   - GZ-2 启用 + Accept-Encoding: gzip + /openapi.json（>500B）→ `Content-Encoding: gzip`
   - GZ-3 启用 + 无 Accept-Encoding → identity
   - GZ-4 启用 + 小 body（/health <500B）→ identity（min_size 门）
   - GZ-5 gunzip roundtrip 逐字节一致（curl --compressed + cmp）
3. **质量门禁**：`cargo clippy --release --tests -- -D warnings` **0 警告**；
   `cargo test --release -- --test-threads=1` **323 passed / 0 failed / 4 ignored**
   （312 → 323，+9 新：gzip 4 + accepts_gzip 4 + request 1，另 1 个为 send 全链路
   socketpair 测试并入 323 计数）。
4. **手动全链路**（本 ADR 执行期实测）：off/on 双 server，`Content-Encoding: gzip`
   头 + Content-Type 保持 + gzip magic `1f 8b` + `curl --compressed` roundtrip
   与 identity 响应逐字节一致 + 响应仍为合法 JSON。
5. **性能**：bench 6 场景 **0 errors**；get_root_10k_100c **39,200 req/s**
   （历史区间 32.9k–43.9k 内；bench 客户端不发 Accept-Encoding，gzip 判定
   短路，热路径仅 +2 比较）。
