# ADR-0023: FileResponse / StreamingResponse — Rust bridge 协议层（Range/206/multipart/etag/CD/500 + chunked streaming）

- **日期**：2026-09-10
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行，Goal-0003 P1 矩阵 #10 落地）
- **关联**：AGENTS.md §3/§6（**决策-48**）、Goal-0003（P1 矩阵 #10：FileResponse /
  StreamingResponse 全量语义）、North Star（Mojo + Rust only 单 binary 零依赖 —
  **零新 crate**；ldd = 仅 libc）、ADR-0006~0009（WebSocket bridge 协议层先例：
  协议原语 + 状态机在 Rust，Mojo 声明式路由）、ADR-0010（Rust bridge 终态）、
  ADR-0015（GZip 中间件 — 本 ADR §3.5-3 交互偏差）、FastAPI 0.141.1 +
  starlette 1.6.0 + uvicorn 0.52.4（/tmp/fresp_probe p10* 逐条 probe + 源码
  核对，本 ADR §1 证据）

## 1. 背景

Goal-0003 矩阵 #10：`FileResponse`（文件下载响应：Range/206/etag/Content-
Disposition/500 语义）+ `StreamingResponse`（chunked 流式响应；SSE 是其特例，
F5/F9 已覆盖）。这是 FastAPI「响应类型」API 的两大核心成员 — 此前仓库仅有
静态目录服务（`/static`：200/404/403-traversal）与 JSON 响应。

**上游实测证据（starlette 1.6.0 源码 + uvicorn 0.52.4 活体 + /tmp/fresp_probe
p10*；关键项全部复跑验证）**：

- **200 全量**：Content-Type = 扩展猜测（`data.txt`→`text/plain` +
  `charset=utf-8` charset 规则：`text/*` 前缀且无 `charset=`）/
  `Accept-Ranges: bytes` / `Content-Length` / `Last-Modified =
  formatdate(st_mtime, usegmt=True)`（`Wdy, DD Mon YYYY HH:MM:SS GMT`）/
  `ETag = md5(str(st_mtime) + "-" + str(size))`（**str(f64) 最短 round-trip**）
  / `Content-Disposition: attachment|inline; filename="..."`（filename 含
  非 ASCII/空格 → RFC5987 `filename*=utf-8''<quote>`，quote = 永不转义集
  `[A-Za-z0-9_.~-]` 其余 %XX 大写）/ 64KB chunk 块读（`chunk_size`）。
- **206 单段**：`Content-Range: bytes s-e/size` + 切片；suffix `-N` →
  `(max(size-N,0), size)`；open `S-` → `(S, size)`；**end ≥ size clamp 到
  size**（`bytes=0-30` 对 30B 文件 → 206 全量，非 416）。
- **206 多段**：`multipart/byteranges; boundary=token_hex(13)`（**26 位小写
  hex**，浏览器 95-96 bit 熵对齐）；每段 `--bd / CT / Content-Range / CRLF /
  data / CRLF`，终止 `--bd--`；Content-Length = 闭式公式
  （`4+bl + Σ(49+bl+ct+s+(e-1)+(e-s))`，p10c MP2 实测 242 = 手算 242）；
  **重叠段合并**（`0-1,1-3` → `0-3` 单段，MG1 实测）；头无 Content-Range。
- **400 ×4 精确消息**（`_parse_range_header`）：无 `=` →
  `Malformed range header.`；单位≠bytes → `Only support bytes range`；
  0 有效段（空/`-`/无 `-`/非数字均被忽略后为空）→ `Range header: range
  must be requested`；start≥end → `Range header: start must be less than
  end`。顺序敏感：101+ 段检查 → 有效段检查 → **start 越界（→416）先于
  start≥end（→400）**。
- **416**：start < 0 或 ≥ size → `Content-Range: bytes */size` + CL 0 +
  空体（body 无内容）；400/416/500 均为**全新 PlainTextResponse**（无文件
  头，仅 CT text/plain; charset=utf-8 + CL + Connection）。
- **500**：文件缺失/非普通文件/open 失败 → `Internal Server Error`（21B）。
- **HEAD → 405 quirk**（uvicorn 活体实测）：`APIRoute` 的 methods 集合 =
  **`{GET}`（不含 HEAD）** — 与 starlette 内置 `Route`/`/openapi.json`
  （`{GET, HEAD}`）不同（源码核对：APIRoute 覆写方法集）。故 `HEAD /file`
  → **405 `Allow: GET`**（带 Range 也 405）；starlette `FileResponse` 的
  `send_header_only` 分支实际不可达。
- **If-Range** = 与 Last-Modified **或** ETag 的字符串相等比较（源码
  `responses.py:457`）；**If-None-Match / If-Modified-Since 不被
  FileResponse 处理**（忽略 → 200 全量 = parity，非偏差）。
- **101+ 段 quirk**（P1 实测 200 CL 10）：`max_ranges = 100`，
  `count(",")+1 > 100 → return []` → 200 全量（不是 400）。
- **StreamingResponse**：`media_type=None` → **无 Content-Type**（quirk）；
  `Transfer-Encoding: chunked`（`{hex}\r\ndata\r\n…0\r\n\r\n` 帧格式）；
  `status_code` / `headers` 透传（F9 同机制）；上游 GZipMiddleware 包 body
  iterator → **file/streaming 均被压缩**（p10f 实测 `content-encoding:
  gzip`）。

**约束（Mojo 1.0.0 + North Star）**：Mojo 1.0.0 **无 `std.file`**（实测
`from std.file import File` → `unable to locate module 'file'`）→ 纯 Mojo
侧无文件 I/O 可用；socket fd 在 bridge（C5，ADR-0001 决策-9）；文件/流式
协议与 WS 同构（ADR-0006~0009 先例）：协议原语 + I/O 在 Rust bridge，
Mojo 只做声明式路由（`KIND_FILE` + `handler.data` 透传，SSE 分支同型）；
零新 crate（MD5/边界生成/时间格式化全部手写或 std-only）。

## 2. 候选方案

- **A. Mojo 侧实现**：❌ Mojo 1.0.0 无 `std.file`（无文件 I/O）；且
  Range/206/multipart 协议 + 64KB 块 fd 直发需要持有 socket fd — 该 fd
  属 bridge 域（C5），Mojo 侧拿不到裸 fd 写权限（FFI 来回传递 = 反向
  依赖）。
- **B. Rust bridge 协议层**（✅ 采纳）：`file_protocol.rs`（纯函数：
  Range 解析 / RFC1123 / RFC5987 / CD / charset / etag / multipart CL /
  boundary）+ `file_serve.rs`（stat/open/lseek/read/send + 单点
  `send_file_response` / `send_streaming_response` FFI）+ `crypto.rs` MD5；
  Mojo 声明式接线与 SSE 分支完全同型（cfd 透传 + `continue`）。先例 = WS
  （ADR-0006~0009）；零新 crate；ldd 不变（**libm 零化**，见 §3-6）。
- **C. 不实现（静态文件覆盖）**：❌ 静态目录服务与 `FileResponse` 是
  不同 API：后者是显式声明的下载响应（Range/CD/etag/500/自定义 status），
  矩阵 #10 核心语义，不可跳过。

## 3. 决策

1. **`file_protocol.rs`（230 行，纯函数层，零 I/O）**：`fmt_rfc1123`
   （civil_from_days 历法换算 + `%02d` 补零，1970-01-01=Thu 校验）/
   `rfc5987_quote`（永不转义集 `[A-Za-z0-9_.~-]`，其余 %XX 大写）/
   `build_content_disposition`（quote 后不变 → `filename="f"`；变 →
   `filename*=utf-8''{q}`）/ `apply_charset_rule`（`text/*` 前缀 + 无
   `charset=` → `; charset=utf-8`）/ `etag_from_mtime_size`（`"
   md5(f64Display(mtime) + "-" + size)"`）/ `parse_range_header`
   （**顺序敏感** 7 步：无 `=` → 400；单位≠bytes → 400；**>100 段 →
   Ok([]) quirk → 200**；逐段解析（空/`-`/无 `-`/非数字跳过；suffix/
   open/clamp）；0 有效段 → 400；**start 越界 → 416（先于** start≥end）；
   start≥end → 400；单段直返；多段排序 + 重叠合并）/
   `multipart_content_length`（闭式公式，p10c MP2 锚定）/
   `generate_boundary`（xorshift32 ×6 取前 26 小写 hex，seed =
   `now_ns ^ fd×0x9E3779B9 ^ size`，每请求唯一）。
2. **`file_serve.rs`（416 行，I/O 层）**：`LinuxStat`（**144B glibc
   `struct stat` 布局**，`stat(2)` 整写 — 128B 缓冲 = 栈 OOB 写；偏移
   mode@24/size@48/mtime@88(+8)，`file_serve_tests` 断言 `size_of==144` +
   `offset_of!` 守护）/ `stat_file`（mtime = `st_mtime + st_mtime_nsec
   ×1e-9` f64；`S_IFMT=0o170000` 判 REG）/ `write_file_range`（64KB 块
   lseek+read+send_all，EINTR 续读，上游 `chunk_size` 一致）/
   `file_header_block`（CT/AR/CL/LM/ETag/[CR]/[CD]/Connection/CORS/extra
   统一头块，200/206/多段共用）/ `send_plain_error`（400/416/500：全新
   PlainTextResponse，**无文件头**，500 日志 `eprintln!`）/ `send_full`
   （200/2xx + 101+ 段退化路径）/ **`send_file_response`（单点 FFI：
   stat→open→Range 分派：无 Range/If-Range 失配 → 全量；单段 → 206；
   多段 → 206 multipart；若 If-Range = LM 或 ETag 才用 Range）** /
   `send_streaming_response`（TE: chunked；media 空 = 无 CT quirk；
   body 按 `|` 切段 → `{len:x}\r\n{data}\r\n` 帧 + `0\r\n\r\n` 终止；
   自定义 status + extra 头透传，F9 同机制）。
3. **FFI ×2（`ffi.rs` 647 → 686）**：`send_file_response(fd, path,
   media_type, filename, cdt, status, extra) -> c_long` /
   `send_streaming_response(fd, status, body, media_type, extra) ->
   c_long`（既有 C ABI 契约：CStringSlice NUL 终止 / malloc 内存规则
   不变；0 = 成功，-1 = 写失败）。
4. **`CurrentRequest` 扩展（`io.rs` + `request.rs`）**：请求解析时记录
   `Range` / `If-Range` 头（`current_range()` / `current_if_range()`
   getter；与既有 Origin/Connection 记录同模式，无其他状态变化）。
5. **Mojo 接线（声明式，SSE 同型）**：`handler.mojo` **KIND_FILE = 300**
   （477 → 495 行，声明面：`_file_path`（静态目录相对/绝对）/
   `_file_media`（空 = guess + charset 规则）/ `_file_name` /
   `_file_cdt`（空 = attachment）/ `_file_status`（默认 `200 OK`）/
   `_response_headers`（extra，不得覆写 CT/ETag））+ `http_server_final.
   mojo` dispatch FILE 分支（1332 → 1444 行：cfd 透传 + `continue`，
   位于 SSE 分支之后）+ **8 个 demo 路由**（`/file` / `/file-name` /
   `/file-inline` / `/file-missing` / `/file-201` / `/stream` /
   `/stream-json` / `/stream-empty`）+ `static/filedemo.bin`（30B
   `ABCDEFGHIJKLMNOPQRSTUVWXYZ0123`，`build_single.sh` 自动嵌入 ≤5 个
   static 之一）。
6. **MD5（`crypto.rs` 185 → 273，`crypto_tests.rs` 14 → 22）**：RFC 1321
   全量（padding/64 轮 F/G/S/小端输出）；**K 表 const 嵌入**
   （`K[i] = floor(2^32 × |sin(i+1)|)`，(i+1) 本身是弧度 — 勿
   `to_radians()`；**const 而非运行时派生 = libm 零化**：运行时 `f64::sin`
   会链入 `libm.so.6`，CI ldd 门禁禁 libm（ci.yml L101），const 表 =
   256B `.rodata`，值由 glibc 正确舍入 sin 逐位导出，
   `md5_k_table_matches_sin_derivation` 测试守护 const ≡ 派生）→
   **ldd 保持仅 libc**。

**Bug 修复记录（5 项，勿回退）**：
1. **MD5 K 表弧度**：初版 `(i+1).to_radians().sin()` 双转换（RFC 的
   (i+1) 已是弧度）→ 全向量错；修 `(i as f64 + 1.0).sin()`。两个
   「RFC 1321 向量」凭记忆抄错 — 一律以 `md5sum`/`hashlib` oracle 为准
   （如 `md5("message digest") = f96b697d…`、`md5("abcdefghijklmnopqrstuvwxyz")
   = c3fcd3d7…`）。
2. **144B glibc stat 布局**：128B 缓冲 = 栈 OOB 写 → 垃圾/segfault；
   14 字段布局固化 + 偏移守护测试。
3. **`S_IFMT = 0o170000`**：初版 `0o070000` 少一位八进制（C:
   `00170000` = 0xF000）→ 所有普通文件判「非文件」→ 恒 500。
4. **测试确定性**：`headers_only` 助手含 `\r\n\r\n` 终止；`file_case`
   钉 mtime = `1788996557.9171202`（`File::set_modified`，跨文件/跨运行
   etag 确定）；multipart boundary 字符校验用 `is_ascii_uppercase()`
   （数字既非大写也非小写 — 初版 lowercase 检查对 hex 数字恒 false 误判）。
5. **工具链（rustc 1.97.1）**：`[T; N]` 无 `FromIterator` →
   `.collect::<Vec<_>>().try_into().expect(...)`；FFI 签名（8/10/12 参数）
   `#[allow(clippy::too_many_arguments)]`（对齐 C bridge 参数面，同
   决策-20 立场）。

## 3.5 文档化偏差

1. **ORJSON/UJSON ≡ 原生 json.mojo**（F3 既有决策）：file/streaming 不
   走 JSON 路径；本 ADR 的 JSON 类响应（`/stream-json`）media 声明
   `application/json`，字节与 orjson compact 等价（既有 parity，列此
   保持 §3.5 完整性）。
2. **HEAD = 仅头（200/206）vs 上游 405 quirk**：FastAPI 0.141.1
   `APIRoute` methods = `{GET}`（不含 HEAD，与 starlette 内置 Route 不同）
   → 上游 `HEAD /file` = 405 `Allow: GET`（uvicorn 活体实测，带 Range 也
   405）；本实现 HEAD = 仅头（含 `Content-Range`/`Content-Length`），
   遵循 RFC 9110 §9.2 HEAD 语义 — **行为更优**的文档化偏差（FR-26/27
   线级守护：`\r\n\r\n` 后 0 字节）。
3. **GZip（决策-40）不介入 file/streaming**：上游 starlette 1.6.0
   GZipMiddleware 包 body iterator → file/streaming **均被压缩**（实测
   `content-encoding: gzip`）；本实现 GZip 作用在 `send_response` 单点，
   file/streaming 绕过（SSE 同）— 压缩这两类响应需把 gzip 层重构为 body
   iterator 包装，P2 剩余面（`FASTAPI_MOJO_GZIP=1` 时 file/streaming
   响应不压缩 = 窄化）。
4. **整秒 mtime 的 ETag**：上游 `str(N.0) = "N.0"` vs 本实现 f64 最短
   Display `"N"` → 同文件 etag token 不同（**opaque token**：稳定性/
   If-Range 条件匹配语义不受影响，两请求间一致）；**非整秒 mtime
   与上游逐字节相同**（`str(f64)` 与 Rust `{}` 均为最短 round-trip；
   活体交叉验证：data.txt etag 两边 = `588d6b9d…` 相同）。
5. **i64 溢出 Range 段**：上游 Python 无界 int → 天文数字 start =
   416；本实现 `i64::parse` 溢出 → 该段按无效跳过（全跳过 → 400
   `range must be requested`）— 仅当请求 >9.2 EB（i64 max 字节）可触发，
   实际不可达（文档化，非行为回退）。
6. **`_file_path` 声明面 = 静态目录相对**（绝对路径直通亦可）+ extra 头
   **不得覆写** 已计算的 CT/ETag（与 F9 同约束）：上游 `FileResponse`
   的 `headers` 参数可覆写 content-type（`headers={"content-type": …}`
   实测生效）— 本实现声明面收窄（安全取向，防 MIME 混淆），P2 剩余面。
7. **If-None-Match / If-Modified-Since 忽略（200 全量）**：上游
   FileResponse 同样不处理（源码核对：只有 If-Range 分支）= **parity，
   非偏差**（列此完备）。

## 4. 风险

| 风险 | 影响 | 应对 |
|------|------|------|
| 144B stat 布局跨 glibc 版本漂移 | 偏移错 → 垃圾 mtime/size | 布局测试（size_of==144 + offset_of! mode/size/mtime/mtime_nsec）守护；构建/部署目标 = ubuntu:24.04（glibc 2.39，Dockerfile 已钉）— 同一布局 |
| etag 与上游 token 不等价（整秒 mtime） | 客户端若与上游 FastAPI 部署互认 etag | opaque token 语义：单部署内一致（FR-3 交叉验证 md5sum oracle）；跨实现互认非契约（§3.5-4） |
| multipart boundary 随机源（xorshift32） | 低熵可预测 | seed = `now_ns ^ fd×0x9E3779B9 ^ size`（ns 精度 + fd 异或）= 104-bit 混合输出前 26 hex（浏览器 95-96 bit 量级，starlette 注释对齐）；boundary 非安全边界（防碰撞即可） |
| 64KB 块直发大文件内存 | 每请求 64KB 缓冲 | `write_file_range` 单 buf 复用；文件流不进入 Mojo 字符串缓冲（FFI 直通 fd）— RSS 平台化验证（e2e ×10 + 60/60 重复 0 漂移） |
| ffi.rs 647 → 686（>500 既有超阈值） | God package | 纯 `extern "C"` 包装层（FFI 表面的自然增长面，决策-20 413 → 决策-44/45/46/47 累积）；**拆分边界标注：~800 行时按域拆 ffi_http/ffi_ws/ffi_file**（本 ADR 只 +2 入口，不触发拆分） |
| http_server_final 1332 → 1444 | 既有超阈值 | +112 = 声明式接线（FILE 分支 + 8 demo 路由），同 ADR-0018/0019/0020/0021/0022 立场（纯数据层拆出 file_protocol/file_serve 230/416 <500） |

## 5. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 单向：`file_protocol → {crypto, time_util}`；`file_serve → {file_protocol, request, response, send, state, cors}`；`ffi → {file_serve, …}`；`mod.rs` 注册 `mod file_protocol; mod file_serve;` + tests — 无反向引用，依赖图零环 |
| 2. 分层向下依赖 | ✅ 遵守 | 协议原语 = 纯 Rust（file_protocol 零 I/O 零 Mojo 知识）；I/O + FFI = bridge 层（file_serve，C5 同域：持有 fd）；Mojo = 声明式透传（KIND_FILE + data keys，SSE 同型）；**FFI 表面 +2**（既有 C ABI 契约不变：NUL 终止 / c_long 返回）；**零新 crate**（MD5/boundary/历法全手写） |
| 3. God package 阈值 | ⚠️ 遵守（带说明） | file_protocol **230** / file_protocol_tests **296** / file_serve **416** / file_serve_tests **378** / crypto **273** / crypto_tests **22** — 新增全部 <500；ffi **686**（647→686，既有超阈值纯 FFI 包装面，拆分边界标注 = ~800）；handler.mojo **495**（≤500）；http_server_final **1444**（1332→1444，既有超阈值，+112 声明式接线） |
| 4. 主题域边界清晰 | ✅ 遵守 | file 协议 = 独立子域（file_protocol/file_serve，与 `ws_session_ffi` 同位）；静态目录服务（state/static，404/403）与 FileResponse（声明式下载，500/CD/Range）分离不混；router/json/openapi/metrics/form/upload 域零改动；request 域仅 +2 getter（Range/If-Range 记录） |
| 5. bridge/adapter 显式化 | ✅ 遵守 | `ldd` = **仅 libc**（+ vdso/ld-linux 内核组件）— **libm 零化**（MD5 K 表 const 嵌入，见 §3-6；此前运行时 sin 会链入 libm.so.6 破 CI 门禁）；binary **3,631,104 B (3.5M)** ≤4.2M（决策-47 基线 3,556,048 B + 75,056 B）；`find src -name '*.c'` = 0 保持；`-static-libgcc` 守则未触发新依赖（cargo build 产物 ldd 复核） |
| 6. 测试文件跟随 | ✅ 遵守 | `file_protocol_tests.rs`（30：RFC1123×4 / RFC5987×4 / CD×4 / charset×3 / etag×3 / Range 解析×12（含 101 段 quirk / 合并 / clamp / 4 条 400 / 416 序）/ multipart CL×2 / boundary×3）+ `file_serve_tests.rs`（15：200 头 / 206 单段 / suffix / open / clamp / 416 / 400×4 / 500 无文件头 / If-Range etag+LM+stale / 多段精确体 / HEAD×2 / streaming×3）+ `crypto_tests` +8（MD5 向量×7 + K 表 ≡ 派生）+ e2e **FR-1..FR-32**（319 → 351）— 全部与生产代码同目录/同 crate |

## 7. 验证方式

1. **单 binary 不变式**：`ldd build/fastapi_mojo` = **仅 libc**（vdso/
   ld-linux 内核组件）— libm 零化实测；binary **3,631,104 B (3.5M)**
   ≤4.2M（+75,056 B vs 决策-47）；`env -i` 干净启动（health 200 +
   `/file` 200 30B + `/stream` 200 14B，实测）；`build_single.sh`
   3 static 自动嵌入（index.html / test.json / **filedemo.bin**）。
2. **Rust 质量门禁**：`cargo test --release -- --test-threads=1` =
   **407/0/4**（354 → +53：file_protocol 30 + file_serve 15 + MD5 8）；
   `cargo clippy --release --tests -- -D warnings` 双 crate（
   fastapi_mojo_rs + fmtool）**0 警告**。
3. **e2e 全量**：319 → **351/351**（+32 FR）全绿（实测 0 FAIL）：
   - FR-1..3：200 精确体（30B）/ 头（CT/AR/CL/LM vs `date -u -R`）/
     **ETag = md5(f64repr(mtime)-size) 独立交叉验证**（fmtool f64repr
     × md5sum oracle，与 bridge 逐位一致）
   - FR-4..7：自定义 201 / CD `attachment; filename="report.txt"` /
     CD RFC5987 `inline; filename*=utf-8''a%20b.txt` / 500（21B，
     无任何文件头）
   - FR-8..12：206 单段 / suffix / open / **clamp**（0-30→206 全量）/
     416（`bytes */30` + CL 0 + 空体）
   - FR-13..17：400 ×4 精确消息 + CT
   - FR-18..20：101 段 quirk → 200 / 重叠合并 → `0-3` / **multi-range
     206 精确体**（boundary 抽取 + printf 期望 + cmp；CL = 246 闭式
     手算；26-hex 小写；头无 CR）
   - FR-21..25：If-Range = ETag/LM → 206 / stale → 200 / INM·IMS
     忽略（parity）
   - FR-26..27：HEAD 200/206 仅头（**raw-socket 线级证明**：`\r\n\r\n`
     后 0 字节；curl `-I -o` 会把头 dump 进 -o 文件 = curl quirk，故不
     依赖它）
   - FR-28..30：chunked（no-CT quirk / 3 段含 UTF-8 / 202 + CT +
     X-Custom extra / 空体键存在语义）
   - FR-31：**raw-socket chunked 帧级证明**（`6\r\nhello \r\n` /
     `5\r\nworld\r\n` / `3\r\n中\r\n` / `0\r\n\r\n`，Connection: close
     即关）
   - FR-32：/file ×10 稳定（无泄漏/无状态漂移）
4. **性能**：bench 6 场景 **0 errors**，get_root_10k_100c =
   **37,664.78 req/s**（历史区间 32.9k–43.9k 内，无回归 — K 表 const
   化后热路径零 sin 调用）；`pgrep -x fastapi_mojo` = 0（无孤儿）。
5. **零依赖红线**：`find src -name '*.c'` = 0；`find . -name '*.py'`
   （excl .git/docs）= 0（fmtool `f64repr` 子命令 = 纯 Rust，替代
   Python f64 repr oracle）；`.venv` 不存在。
