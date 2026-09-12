# ADR-0053: GZip 中间件 Starlette 1.6.0 全量对齐（决策-78）

**状态**：已接受（取代 ADR-0015 §3/§7 —— 决策-40 的 GZip 语义）
**日期**：2026-09-12
**决策**：78（Goal-0003 §1 矩阵 #24 压缩 / `fastapi_mojo-mxs` bead）
**关联**：AGENTS.md §3.1/§6（**决策-78**）、决策-40（ADR-0015，被本 ADR 取代其 §3/§7
语义）、North Star（单 binary 零依赖 — flate2 纯 Rust miniz_oxide 后端，静态，ldd
仅 libc）、上游 `starlette/middleware/gzip.py`（1.6.0）

## 1. 背景

决策-40（ADR-0015）引入了 `FASTAPI_MOJO_GZIP` 声明式 GZip，但对上游只有部分对齐，
且**三处语义与 starlette 1.6.0 不符**：

| 项 | 决策-40（旧） | starlette 1.6.0（上游，实读源码） |
|---|---|---|
| `Vary: Accept-Encoding` | 压缩时才加 | **可压响应恒加**（`IdentityResponder` 也加，与 client 是否真接受 gzip 无关） |
| client 判定 | `gzip`/`x-gzip` 裸 token（不支持 q） | **大小写敏感子串** `"gzip" in Accept-Encoding`（`GZIP`/`Gzip` 不命中；`x-gzip`/`gzip;q=0` 命中） |
| media-type 过滤 | **不按 CT 过滤**（压缩所有 CT） | **默认排除表**（`application/zip`、`image/*` 具体项、`image/gif|png|jpeg|webp|avif`、`font/woff|woff2`、`text/event-stream`、`video/*`、`audio/*` …） |
| streaming 响应 | 不压（绕过） | **可压**（`more_body` 分支，不受 `minimum_size` 门；压则删 `Content-Length`） |
| FileResponse | 不压 | 小文件（< `minimum_size`）不压；≥ `minimum_size` 压（CL = 压缩后长度） |
| `compresslevel` | 6 | **9** |

`starlette/middleware/gzip.py`（1.6.0）核心（实读）：

```python
class GZipMiddleware:
    async def __call__(self, scope, receive, send):
        if "gzip" in Headers(scope=scope).get("Accept-Encoding", ""):
            responder = GZipResponder(self.app, self.minimum_size, compresslevel=self.compresslevel, ...)
        else:
            responder = IdentityResponder(self.app, self.minimum_size, ...)
        await responder(scope, receive, send)
```

`IdentityResponder.send_with_compression`（`GZipResponder` 继承之，仅
`apply_compression` 不同）：

- `http.response.start`：记录 `content_encoding_set`（已有 CE）/ `partial_response`
  （status == 206）/ `content_type_is_excluded`（`content-type` 去 `;` 小写 → 与
  排除表 `{ct, "type/*"}` 求交）。
- `http.response.body` 且 (排除 / 206 / 有 CE)：直通（**不加 Vary**）。
- `http.response.body` 单 body 且 `len(body) < minimum_size`：**不加 Vary**，直通。
- 单 body（`not more_body`）：`add_vary_header("Accept-Encoding")`；若 `body != 压缩后`
  → 设 `Content-Encoding` + `Content-Length`。
- streaming（`more_body=True`）：`add_vary_header`；若压缩 → 设 `Content-Encoding` +
  **删 `Content-Length`**。

> `IdentityResponder.apply_compression` 返回原 body → `body == message["body"]` →
> 不加 CE，但 **Vary 仍加**。这解释了「未接受 gzip 的客户端也收到 `Vary`」。

**上游探测证据**（本机 system python：`fastapi 0.141.1` + `starlette 1.6.0`；ASGI
原始 message 捕获，绕开 httpx 自动解压）：

```
/json    ae=gzip  CE=gzip  Vary=Accept-Encoding  CL=42     CT=application/json
/json    ae=None  CE=-     Vary=Accept-Encoding  CL=2008   CT=application/json
/json    ae=GZIP  CE=-     Vary=Accept-Encoding  CL=2008   CT=application/json
/small   ae=gzip  CE=-     Vary=-                CL=11     CT=application/json
/f30     ae=gzip  CE=-     Vary=-                CL=30     CT=application/octet-stream
/f2000   ae=gzip  CE=gzip  Vary=Accept-Encoding  CL=35     CT=application/octet-stream
/f2000   ae=None  CE=-     Vary=Accept-Encoding  CL=2000   CT=application/octet-stream
```

（`GZIP` 大写 → 走 `IdentityResponder`：identity + Vary；small/小文件 → 无 Vary；
2000B FileResponse → CE + Vary + CL=压缩长度。）

## 2. 目标

1. 与 starlette 1.6.0 `GZipMiddleware` 逐项对齐（client 判定 / Vary / 排除表 /
   streaming / FileResponse / level）；
2. 单点判定（`plan()` 纯函数）覆盖所有响应类型（JSON/HTML/text/SSE/static/
   FileResponse/StreamingResponse/error）；
3. 零新 FFI 符号（沿用 `send_response` 单点 + request 全局 `accepts_gzip`）；
4. 保持 North Star（flate2 纯 Rust；ldd 仅 libc；binary ≤ 6 MiB）。

## 3. 决策

### 3.1 `bridge/gzip.rs` 重写（`plan()` 纯判定 + env 配置）

```rust
pub struct GzipConfig { enabled, min_size, max_size, level, exclude }
pub struct GzipPlan { vary: bool, compress: bool }
pub const SKIP: GzipPlan = GzipPlan { vary: false, compress: false };

pub fn plan(cfg, content_type, body_len, status, extra,
            client_accepts, include_body, streaming) -> GzipPlan {
    if !cfg.enabled || !include_body { return SKIP; }
    if status.starts_with("206") { return SKIP; }
    if extra.map_or(false, extra_has_content_encoding) { return SKIP; }
    if media_type_excluded(content_type, &cfg.exclude) { return SKIP; }
    let effective_streaming = streaming && body_len > 0;
    if !effective_streaming && body_len < cfg.min_size { return SKIP; }
    let within_cap = cfg.max_size == 0 || body_len <= cfg.max_size;
    GzipPlan { vary: true, compress: client_accepts && within_cap && body_len > 0 }
}
```

- `vary` = 可压响应（上游 `add_vary_header` 语义，与 client 无关）；
  `compress` = client 真接受（大小写敏感子串）。
- `DEFAULT_EXCLUDE` = 上游 13 项默认表（**pub**，供测试与文档引用）。
- `extra_add_lines(vary, compress)` → `Vary: Accept-Encoding`（先）+
  `Content-Encoding: gzip`（后）—— 与上游 `add_vary_header` 后再设 CE 的顺序一致；
  `merge_extra` 把其并入既有 extra 头串（`\r\n` 分隔）。
- env：`FASTAPI_MOJO_GZIP`（默认关）/`_MIN_SIZE`（默认 500）/`_LEVEL`（默认 9）/
  `_MAX_SIZE`（默认 0 = 无上限，**非上游内存保护扩展**）/`_EXCLUDE`（逗号分隔，整体
  覆盖默认表）。
- config 仍用 `Mutex<Option<GzipConfig>>`（单线程 worker 无竞争；`#[cfg(test)]
  __test_reset_config()` 隔离 env 全局副作用）。

### 3.2 client 判定 = 大小写敏感子串（`parse::accepts_gzip`）

```rust
pub fn accepts_gzip(hdr: &[u8]) -> bool {
    match get_header_value_ci(hdr, b"Accept-Encoding") {
        Some(v) => v.windows(4).any(|w| w == b"gzip"),
        None => false,
    }
}
```

头名仍大小写不敏感（HTTP 头名）；**值**按上游 quirk 大小写敏感（`GZIP`/`Gzip`
不命中，`x-gzip`/`gzip;q=0` 命中）。

### 3.3 三个发送点接线（全部走 `plan`）

- `send.rs::send_response`（单点，覆盖 JSON/HTML/text/SSE/static/error/404/405）：
  `plan(..., include_body && !HEAD, streaming=false)`。
- `send.rs::send_streaming_response`（StreamingResponse chunked）：
  `plan(..., streaming=true)`；`compress` → 合并后的 body 压成**单个 gzip chunk** +
  `Vary`/`CE`（chunked 无 CL，与上游一致）；HEAD → 仅头。
- `file_serve.rs::send_full`（FileResponse 200/2xx，206/Range 别径）：
  `plan(..., streaming=false)`；`compress` → `read_all`（≤4 MiB）读全量 + gzip，
  `Content-Length` = 压缩后长度 + `Vary`/`CE`；否则原样流式。
- `http2_response.rs::send_streaming` 改收 `body: &[u8]`（单 body，DATA 带 END_STREAM；
  HEAD → HEADERS 带 END_STREAM）。

### 3.4 FFI diff = 0

`bridge/ffi.rs` 的 `send_streaming_response` 仍收 `*const c_char` body（Rust 侧按
`&str` 处理，"|" 切分在桥内做）—— **无签名变更、无新符号**；Mojo 侧零改动。

## 4. 备选方案对比

| 方案 | 结论 | 理由 |
|---|---|---|
| 保持决策-40（不按 CT 过滤 / level 6 / 不压 streaming+file） | 拒绝 | 与上游三条语义不符；且「压缩不可压二进制」浪费 CPU |
| 在 Mojo 侧判定 + 传压缩后 body | 拒绝 | 与 North Star「编解码设施归 Rust bridge」冲突；且 Mojo 无 gzip 库 |
| 逐响应类型加 gzip 分支 | 拒绝 | 重复、易漏；`plan()` 单点判定更稳 |
| **`plan()` 纯判定 + 三发送点接线 + env 声明式（本 ADR）** | 接受 | 单点判定、FFI diff=0、逐项对齐上游、North Star 不破 |

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `send` → `gzip`（config/plan/compress/merge_extra）+ `send` → `request`（accepts_gzip）；`file_serve` → `gzip`；`gzip` 只依赖 std + flate2（crate 内零同层 import） |
| 2. 分层向下依赖 | ✅ 遵守 | gzip = 编解码设施，归 Rust bridge（§3.3 Mojo std 缺口归属层）；Mojo dispatch 零分支（纯 env 声明） |
| 3. God package 阈值 | ✅ 遵守 | `gzip.rs` ~250 LOC / `send.rs` <400 / `file_serve.rs`（send_full 局部）/ `http2_response.rs`（send_streaming 局部）均 <500；测试文件 `gzip_tests.rs`/`file_serve_tests.rs`（`send_tests.rs` 为既有超阈值文件，仅增 1 测） |
| 4. 主题域边界清晰 | ✅ 遵守 | gzip.rs 只管「配置 + 判定 + 压缩 + Vary/CE 头行」纯逻辑（不碰 fd）；`send`/`file_serve` 只管「何时压缩 + 头装配 + 字节发送」；client 判定归 `parse.rs` |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（零新导出；`plan`/`config`/`gzip_compress`/`merge_extra` 全是 crate 内 Rust API）；Cargo.toml 唯一第三方 = flate2（纯 Rust miniz_oxide，静态，ldd 仅 libc 实测） |
| 6. 测试文件跟随 | ✅ 遵守 | `gzip_tests.rs`（plan 矩阵 / 空流 / Vary 顺序 / 排除表 / env / roundtrip）、`parse_tests.rs`（accepts_gzip 大小写敏感）、`file_serve_tests.rs`（FileResponse 大/小 + StreamingResponse 压缩/排除 + gunzip 还原）、`send_tests.rs`（单点 gzip 全链路） |

## 6. 验收（2026-09-12）

- bridge cargo `509 → 516 passed / 0 failed / 4 ignored`（+7）；clippy 双 crate **0 警告**；
  fmtool **35/0**。
- e2e **604 → 609/609**（GZ-1..GZ-10）：
  - GZ-1 默认关 → 无 CE 且无 `Vary`；
  - GZ-2 启用 + AE gzip + `/openapi.json` → `CE: gzip` + `Vary: Accept-Encoding`；
  - GZ-3 启用 + 无 AE → identity + **`Vary`**（上游 IdentityResponder）；
  - GZ-4 小体（`/health`）→ identity 且 **无 Vary**；
  - GZ-5 gunzip roundtrip 逐字节一致（`curl --compressed` + `cmp`）；
  - GZ-6 AE `GZIP` 大写 → identity + Vary（大小写敏感 quirk）；
  - GZ-7 SSE（`text/event-stream`）→ 无 CE 且无 Vary；
  - GZ-8 StreamingResponse → chunked + `CE: gzip` + Vary + roundtrip；
  - GZ-9 FileResponse 小文件（30B）→ 无 CE 且无 Vary；
  - GZ-10 静态大文件（2000B）→ `CE: gzip` + Vary + roundtrip。
- canonical `./benchmark.sh` 6 场景 **0 errors**（get_root_10k_100c ≈ 29.9k req/s —
  bench 客户端不发 `Accept-Encoding`，gzip 判定短路，热路径零额外开销）。
- `ldd build/fastapi_mojo` 仅 libc；`env -i` 干净启动 health 200；binary **5,093,824 B**
  （≤6 MiB）；C=Python=orphans 0；Mojo 自检 10 模块全绿。

## 7. 实现 / 边界（文档化偏差）

实现：`src/fastapi_mojo_rs/src/bridge/{gzip,parse,send,http2_response,file_serve}.rs`
（+ `gzip_tests`/`parse_tests`/`file_serve_tests`/`send_tests`）；
`scripts/e2e_test.sh` GZ-1..GZ-10。

边界 / 偏差：

1. **`FASTAPI_MOJO_GZIP_MAX_SIZE`**（默认 0 = 无上限）是本仓库**内存保护扩展**，
   上游无此参数（上游无 size 上限）。
2. **大 FileResponse（≥ 64 KiB）**：上游 `FileResponse` 以 64 KiB 块发送（`more_body=True`
   → streaming 分支 → 压缩且无 `Content-Length`）；本实现把整文件（≤4 MiB）作为**单
   body** 压缩并**带 `Content-Length`**（= 压缩后长度）。解压后内容逐字节相同，wire
   上本实现多 `Content-Length`（等价或更优）。
3. **streaming 压缩字节**：上游逐块 `Z_SYNC_FLUSH`（`more_body`）；本实现合并后一次性
   gzip。**解压后字节相同**，但压缩后字节/长度不同（chunked 无 CL，客户端无感）。
4. **gzip 字节流**：flate2/miniz_oxide 与 CPython zlib 的 DEFLATE 输出非逐字节相同
   （level 语义/实现差异）→ `Content-Length` 数值可能不同；**解压后内容一致**（opaque）。
5. **`thread_minimum_size`（128 KiB 卸载到线程）** 未建模：本仓库为 pre-fork
   多进程单线程 worker，压缩同步执行（无 event-loop 阻塞问题）。
6. **排除表项**：`media_type_excluded` 对**响应** CT 去 `;` 小写（对齐上游），但
   env 提供的排除项不做 `;` 剥离（默认表无参数，实际无差）；`_EXCLUDE` 整体覆盖默认表
   （上游为构造参数）。
7. **`Vary` 顺序**：`Vary` 在 `Content-Encoding` 之前（上游 `add_vary_header` 先），
   已逐字节对齐；小体 / 排除 / 206 / 有 CE / HEAD → 无 `Vary`（对齐上游）。
