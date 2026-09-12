# ADR-0059: 多字节 / 非法字节 raw wire 输入字节安全（决策-84）

**状态**：已接受
**日期**：2026-09-12
**决策**：84（兑现 ADR-0058 §8 后续缺口 #1「多字节 UTF-8 字节下标审计其余面」/
bead `fastapi_mojo-multibyte-wire-byte-safety-led`）
**关联**：AGENTS.md §3.2/§6（**决策-84**）、决策-83（ADR-0058：起点
`request_response._bof` / `body_validate` 字节安全 + §8 登记本缺口）、
决策-79（ADR-0054 `date_types.bof` 雏形）、决策-80（ADR-0055 `url_decode_path`）、
North Star（纯 Mojo 逻辑；**FFI diff = 0**；zero new crate；zero Rust/C 改动）、
上游 `fastapi 0.141.1` / `starlette 1.6.0`

## 1. 背景（缺口）

决策-83 修复了 body 数组元素 / form / cookie 值面的 `String[byte=i]` 崩溃，并在
ADR-0058 §8 登记后续缺口 #1：**原始（未经 curl 重编码）多字节 / 非法字节 wire
输入在其余请求处理面仍让 server 进程 `Assert Error` abort（可远程触发）**。

Mojo 1.0.0 实测语义（`/tmp/byteprobe2.mojo` probe）：

- `s[byte=i]` 在 **continuation 字节**（`0x80..0xBF`）下标 → `Assert Error:
  String span index, N does not lie on a codepoint boundary`（**进程 abort**）；
- `s[byte=i]` 在 **lead 字节**（码点起点）→ 返回整个码点，`ord()` = 码点值；
- `s.as_bytes()[i]` → 原始字节，**永不 assert**（决策-79 `bof` 契约）。

curl 会对原始 wire 重编码（percent-encode / 校验 UTF-8），故此前 e2e 未暴露；
用 `fmtool raw`（精确字节 hex）或 `printf | nc` 直发即复现。

实测崩溃点（修复前逐面）：

| 面 | raw 输入 | 崩溃点 |
|---|---|---|
| 路由 redirect | `GET /café`、`/café/`（未匹配 → redirect_slashes） | `redirect_slashes.mojo` `alt_slash_path`（尾字节续字节） |
| path 参数 | `GET /items/café`（匹配 `{item_id}`） | `params_query.mojo` `url_decode_path` / `_hexval` |
| Content-Type | `application/x-www-form-urlencoded; café` | `form_params.lower_ascii`（media-type 小写判定） |
| 文本 body | `{"s":café}`（未加引号标量） | `params_json` 标量扫描（逐字节 `s[byte=j]`） |
| bool/数值字面量 | body 值 `café`（bool 字段） | `numlit._lower_ascii` |
| Authorization | `Basic café` / `Bearer café` / `Digest café` | `security.b64_decode` / `security._trim` / `security_jwt._lower` |
| 任意头值 | `Content-Type: \xff`（非法 lead 字节） | `string_builder.span_to_str` 非 ASCII 解码分支**越界读**（`bs[i+1..i+3]`） |
| WS 子协议 | `Sec-WebSocket-Protocol: café`（`/ws/chat`） | `string_builder.trim_spaces`（尾字节续字节） |
| JSON access log | 多字节 path（`FASTAPI_MOJO_ACCESS_LOG=json`） | `middleware._json_escape`（`String(s[byte=i])`） |
| JWT | `Authorization: Bearer café` / 多字节 payload | `security_jwt._jwt_parts` / `_json_field` |
| typed list header | raw CSV 含多字节 | `params_query_extra.split_csv` |
| auth scheme | `Authorization: café` / `Digest café` | `security._starts_with` / `security.mojo:208` 头扫描 |

## 2. 目标

原始多字节 / 非法字节 wire 输入（path / query / header name+value / method /
Content-Type / body / WS 子协议 / access log / auth / JWT）在**全请求处理面**
不再崩溃；ASCII 输入字节语义逐字节不变；非法 UTF-8 退化为 U+FFFD（对齐既有
`decode_utf8_bytes` / `span_to_str` 契约）。

## 3. 实现（纯 Mojo；核心 `run_handler` / router / FFI 零改动）

1. **字节取值 helper（每模块一个，避免跨模块耦合）**：
   `Int(s.as_bytes()[i])` 取原始字节。新增 `security._bt` / `security_jwt._bt`；
   复用 `request_response._bof`（决策-83）/ `date_types.bof`（决策-79）。
2. **`string_builder.mojo`**：
   - `trim_spaces`：首尾 ASCII 空格判定改 `as_bytes()`（WS 子协议 offer 尾字节）。
   - `next_codepoint_len`：分类改用原始 lead 字节（`as_bytes()`）；off-boundary
     续字节（`0x80..0xBF`）返回 1（调用方按字节前进，不再 abort）。
   - `span_to_str`（非 ASCII 分支）：重写为**全边界 + continuation 校验**的
     robust decoder（镜像 `decode_utf8_bytes`）；非法 lead（`0xF5..0xFF`）/ 截断
     序列 → U+FFFD，**消除越界读**（`\xff` 头值崩溃根因）。
3. **`redirect_slashes.mojo`**：`alt_slash_path` 尾/首字节判定改
   `Int(path.as_bytes()[n-1])`。
4. **`params_query.mojo`**：`url_decode_path` 主循环 + `_hexval` 改字节安全
   （`%XX` 语义不变）。
5. **`params_json.mojo`**：`_is_ws` + 未加引号标量扫描 + `is_float` 判定改
   `as_bytes()`（原始 JSON body 多字节标量）。
6. **`params_query_extra.mojo`**：`split_csv` 分隔/trim 改 `as_bytes()`
   （typed list header raw CSV）。
7. **ASCII 小写 helper 全量字节安全**（非 ASCII 码点整体透传、续字节跳过）：
   `form_params.lower_ascii`（Content-Type）/ `numlit._lower_ascii` /
   `openapi_custom._lower_ascii` / `security_jwt._lower`（append_byte 曾把
   `>=0x80` 变成 U+FFFD）/ `date_types._lower`。
8. **`security.mojo`**：新增 `_bt`；`_starts_with`（原始 Authorization 前缀）/
   `b64_decode` / `_split_csv` / `_trim` / Basic colon 扫描 / APIKey `:` 扫描 /
   cookie `=` 扫描 / digest+authcode 首个空格扫描 —— 全部改字节安全。
9. **`security_jwt.mojo`**：新增 `_bt`；`b64url_encode` / `_jwt_parts`
   （`. `切分）/ `_json_field`（payload 扫描 + key 比较）/ `_int_or` /
   `_has_scope` / `check_oauth2`（首个空格）全部改字节安全。
10. **`middleware.mojo`**：`_json_escape` 重写为 codepoint-aware（非 ASCII 码点
    整体透传，仅 ASCII 转义）；新增 `from string_builder import ...`。

## 4. 上游探测证据（fastapi 0.141.1 / starlette 1.6.0）

```
GET /items/café          -> 上游 200（uvicorn percent-decode 后路由，path 参数原样 "café"）
GET /café                -> 上游 404
Content-Type: \xff       -> 上游 200（ASGI server 容忍非法字节头值，不崩）
Authorization: Basic café-> 上游 401（Invalid credentials）
Sec-WebSocket-Protocol: café (/ws/chat) -> 上游 400（required subprotocol not offered）
```
本实现修复后与上游一致（见 §7）。其余崩溃点均为实现内部字节下标缺陷，
上游无对应行为（N/A）。

## 5. 已知偏差（相对上游）

| 偏差 | 上游行为 | 本实现 | 影响 |
|---|---|---|---|
| 原始（非 percent-encoded）非 ASCII query/form 值 | `café` | `url_decode` 把裸非 ASCII 码点替换为 `?`（`caf?`） | **既有**（决策-81，ADR-0058 §5）；非本决策引入 |
| 非法 byte 头值 | 上游保留原始字节 | 本实现 `span_to_str` 退化为 U+FFFD（access log / 回显处） | 仅影响回显文本；不崩溃（本决策目标） |
| 其余 | — | 与上游一致 | — |

## 6. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | helper（`_bt`/`_bof`）为模块内叶函数；`middleware -> string_builder` 单向；`string_builder` 仅依赖 `std.ffi`。无新跨层边 |
| 2. 分层向下依赖 | ✅ 遵守 | 纯字节/码点变换（无 FFI / 无 fd / 无 env）；接线在原函数内单点，语义不变 |
| 3. God package 阈值 | ✅ 遵守 | 全部为**现有文件内**函数改写 + 2 个小 helper；`string_builder.mojo` / `security.mojo`（477）/ `security_jwt.mojo` / `params_json.mojo` / `middleware.mojo` 均 < 500（既有 grandfathered 文件不变） |
| 4. 主题域边界清晰 | ✅ 遵守 | wire 字节安全归各所属域（transport = `string_builder`/`request_response`；安全 = `security`/`security_jwt`；body = `params_json`；middleware = `middleware`） |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（零新导出 / 零新 crate / 零 Rust / 零 C）；全部纯 Mojo |
| 6. 测试文件跟随 | ✅ 遵守 | e2e 新增 `MB-1..MB-15`（raw wire 面）+ `MB-16/17`（JSON access log 多字节）；mojo 自测 `string_builder`（span_to_str）延续覆盖；CI mojo 列表不变 |

## 7. 验收（2026-09-12）

- Mojo 自测全绿（CI 列表 9 模块 + `params_typed` + `body_validate_test`）。
- e2e **768 → 785/785 全绿**（新增 `MB-1..MB-15` raw wire：path 命中/尾斜杠 307/
  未匹配 404/多字节 query/Content-Type/非法 lead 字节头/Basic·Bearer·Digest·JWT/
  WS 子协议/裸多字节 JSON body；`MB-16/17`：JSON access log 多字节 path 服务 +
  逐字节回显）。
- raw-wire fuzz（`fmtool raw` / `nc`，3602 请求）：path+query 1330 / header 1800 /
  body 352 / WS 120 = **0 crash**。
- bridge `cargo test --release -- --test-threads=1` = **516 passed / 0 failed /
  4 ignored**（本轮无 Rust 改动）；fmtool **35/0**；双 crate clippy `-D warnings`
  = **0**。
- `./benchmark.sh` 6 场景 0 errors（get_root_10k_100c ≈ 32.8k req/s，噪声带内）；
  `ldd build/fastapi_mojo` 仅 libc；`env -i` 干净启动（`/health` 200）；
  binary **5,188,032 B**（≤ 6 MiB）；`find src -name '*.c'` = 0；
  `*.py`（除 docs/.git）= 0；`pgrep -x fastapi_mojo` = 0。

## 8. 后续缺口（本决策未覆盖，另立 ADR）

1. 非有限 `inf`/`nan` float JSON 渲染语义（上游 500）。
2. Content-Type 分派 parity（`model_attributes_type`，ADR-0058 §5）。
3. float 格式化边界（CPython repr 之外）。
4. `SecurityScopes` 对象面 / `OAuth2PasswordRequestForm` 对象面。
5. CORS 裸 `OPTIONS` 通配超集（ADR-0048 §5 既有文档化）。
6. multi-arch（aarch64）/ asgi-shim（P2 open beads）。
