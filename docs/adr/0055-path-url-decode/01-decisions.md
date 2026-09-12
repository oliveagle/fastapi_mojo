# ADR-0055: 请求 path 百分号解码（uvicorn 等价）（决策-80）

**状态**：已接受
**日期**：2026-09-12
**决策**：80（Goal-0003 对标矩阵 #2 路径参数 / bead `fastapi_mojo-v50`）
**关联**：AGENTS.md §3.2/§6（**决策-80**）、决策-54（numlit / 约束面）、
决策-71（redirect_slashes）、North Star（纯 Mojo 逻辑；FFI diff = 0；zero new crate）、
上游 `fastapi 0.141.1` / `starlette 1.6.0` / `uvicorn 0.52.4`

## 1. 背景（缺口）

此前 `parse_path_params` 对路径段**原样返回**：`/items/a%20b` 的 `item_id` 是
`"a%20b"`（未解码），而上游 FastAPI（经 uvicorn）在 Starlette 路由**之前**就对
request target 做百分号解码，所以：

- `GET /items/a%20b` → `{"item_id": "a b"}`
- `GET /items/%7Bx%7D` → `{"item_id": "{x}"}`
- `GET /items/a%2Fb` → **404**（解码后 `a/b` 变成两段，`{item_id}` 单段不匹配）
- `GET /items/%E4%B8%AD` → `{"item_id": "中"}`
- `GET /items/%FF` → `{"item_id": "\uFFFD"}`（无效 UTF-8 → 替换字符）
- `GET /items/a+b` → `{"item_id": "a+b"}`（路径规则：`+` **不是**空格）

本仓库路径既不解码也不按解码结果分段，与上游有明显语义差异（矩阵 #2 的
"类型 + 约束"面已全，但取值规范化这一维缺失）。

## 2. 目标

对齐 uvicorn：在请求进入路由 / 静态 / 参数抽取 / 访问日志 / 遥测**之前**，对
`path` 做一次 RFC 3986 百分号解码（`+` 不转空格；非法 `%XX` 保留字面量；解码出的
字节按 UTF-8 解码，无效序列 → U+FFFD，等价 `unquote(errors="replace")`）。

## 3. 实现（纯 Mojo；核心零改动）

1. **`params_query.url_decode_path(s)`（新）**：逐字节扫描，`%XX`（两位 hex）→ 单字节，
   其它字节原样（ASCII 或原始 UTF-8 续字节）追加；`decode_utf8_bytes` 收尾
   （畸形序列 → U+FFFD）。**不**把 `+` 视作空格（区别于既有 `url_decode`，后者用于
   query，`+` → 空格）。`%` 后不足两位 hex / 非 hex → 字面 `%`。
2. **`http_server_final.mojo` 接线**：`get_path_slice` 读入后
   `var raw_path = ...; var path = url_decode_path(raw_path)`。此后所有消费者
   （`router.match_route_with_params` / `is_static_path` / `send_static_file` /
   `parse_path_params` / `methods_for_path` / `_finish_request` / OTel span /
   WS upgrade 匹配）统一使用解码后的 `path`。
3. **redirect_slashes Location 保留 wire 形态**：`alt_slash_path(raw_path)` 用于拼装
   Location（`build_redirect_location` 不做重编码；用原始百分号编码路径等价于上游
   `URL(scope)` 的重编码结果，对规范编码逐字节一致）。
4. **WS 数据帧路径**（`get_ws_path_slice`，bridge 在升级时存储的 wire path）**不在本轮
   范围**：升级匹配已用解码 `path`；仅当 WS 路径含 `%XX` 时数据帧路由的参数取值
   仍为 wire 形态（边界，见 §3.5）。

### 3.5 已知偏差（相对上游）

| 偏差 | 说明 | 影响 |
|---|---|---|
| WS 数据帧路径未解码 | bridge 存储的 `ws_path` 为升级时 wire 形态（本决策未改 Rust） | 仅当 WS 路由 path 含 `%XX` 时帧级参数取值不同（升级匹配已解码） |
| `%00` NUL 边界 | 解码后 path 含 NUL 时，静态/FFI 的 C 串（NUL 终止）会截断 | 极端输入；上游 `x%00y` 参数可含 NUL（本实现 FFI slice 不可承载） |
| redirect Location 不重编码 | 用 wire path 拼装（规范编码等价）；非规范编码（如小写 `%7b`）不归一化为大写 | 罕见非规范编码输入 |
| `+` 语义 | 路径 `+` 保持字面（与上游同）；query `+` → 空格（既有 url_decode） | 无 |
| 仅解一次 | `%252F` → `%2F`（与上游同，不递归解） | 无 |

## 4. 上游探测证据（fastapi 0.141.1 / starlette 1.6.0 / uvicorn 0.52.4）

```
GET /hello/a%20b      -> 200 {"name":"a b"}
GET /hello/%7Bx%7D    -> 200 {"name":"{x}"}
GET /hello/a%2Fb      -> 404 {"detail":"Not Found"}      # 解码后分段, 单段不匹配
GET /hello/%E4%B8%AD  -> 200 {"name":"中"}
GET /hello/a+b        -> 200 {"name":"a+b"}              # 路径 '+' 非空格
GET /hello/%FF        -> 200 {"name":"\uFFFD"}           # 无效 UTF-8 -> U+FFFD
GET /hello/%          -> 200 {"name":"%"}                # 畸形 -> 字面
GET /hello/%zz        -> 200 {"name":"%zz"}
GET /hello/%2         -> 200 {"name":"%2"}
GET /hello/%252F      -> 200 {"name":"%2F"}              # 单次解码
GET /echo             -> scope.path="/echo", raw_path="/echo"
```

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `url_decode_path` 与 `url_decode` 同层，仅依赖 `string_builder.decode_utf8_bytes`；消费点单向 |
| 2. 分层向下依赖 | ✅ 遵守 | 纯字符串变换（无 FFI / 无 fd / 无 env）；接线在 dispatch 读取 path 的单点 |
| 3. God package 阈值 | ✅ 遵守 | `params_query.mojo` 仍 < 500（新增约 30 行）；无新文件 |
| 4. 主题域边界清晰 | ✅ 遵守 | URL 解码归 `params_query`（与 query 解码同域）；路由/静态/日志只消费结果 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（零新导出/零新 crate/零 Rust 改动/零 C）；解码纯 Mojo |
| 6. 测试文件跟随 | ✅ 遵守 | `params_query.mojo` `main()` 新增 9 条自检；e2e 新增 `PD-1..PD-11` |

## 6. 验收（2026-09-12）

- Mojo 自测全绿（`params_query` 新增 9 断言 + 既有 CI 列表 8 模块 + `scalar_types_selftest`
  + `params_typed` / `body_validate_test`）。
- e2e **664 → 676/676 全绿**（新增 `PD-1..PD-11`：%20 / %7Bx%7D / UTF-8 / `+` 字面 /
  `%2F` 分段 404 / `%FF` → U+FFFD / 孤立 `%` / `%25` 单解 / 编码 `../` 路由 404 /
  静态编码 `../` 403 / `%2E` 扩展名解码后静态命中）。
- bridge `cargo test --release -- --test-threads=1` = **516 passed / 0 failed / 4 ignored**
  （本轮无 Rust 改动）；fmtool **35/0**；双 crate clippy `-D warnings` = **0**。
- `./benchmark.sh` 6 场景 0 errors。
- `ldd build/fastapi_mojo` 仅 libc；`env -i` 干净启动；binary ≤ 6 MiB；
  `find src -name '*.c'` = 0；`*.py`（除 docs/.git）= 0；`pgrep -x fastapi_mojo` = 0。
