# ADR-0047: SSE `ServerSentEvent` 字段等价（event / id / retry / comment）

**状态**：已接受
**日期**：2026-09-12
**决策**：72（Goal-0003 §1 矩阵 #10 响应类型 / `fastapi_mojo-sdo` bead）

## 1. 背景

FastAPI 0.140+ 新增 `fastapi.sse` 模块，公开 `ServerSentEvent` 与
`format_sse_event`：SSE 事件不再只有 `data`，还可携带 `event` / `id` / `retry` /
`comment` 字段（`EventSourceResponse` 消费）。此前本仓库的 SSE 仅支持 data-only
事件（决策-48，`format_sse_event(data)` 逐行 `data: ` 输出），缺少其余四个字段。

**上游实测（fastapi 0.141.1，`python3 -c "import fastapi.sse"`）**：

`fastapi.sse.format_sse_event(*, data_str, event, id, retry, comment) -> bytes`，
字段输出顺序固定：

```
comment(逐行 `: <line>`) -> event -> data(逐行 `data: `) -> id -> retry + "\n\n"
```

`_split_sse_lines` 语义：`\r\n` / `\r` 归一为 `\n`，split **保留尾空串**（因此
`data="tail\n"` → `data: tail\ndata: \n\n`）；`data` = `raw_data`（原样，不做 JSON
编码）。已知向量逐字节核对：

| 输入 | 输出 |
|---|---|
| `('hello',)` | `data: hello\n\n` |
| `('line1\nline2')` | `data: line1\ndata: line2\n\n` |
| `('tail\n')` | `data: tail\ndata: \n\n`（尾空串保留） |
| `('a\r\nb\rc')` | `data: a\ndata: b\ndata: c\n\n` |
| `('',)` | `data: \n\n` |
| `full('d','e','7','5','c1\nc2')` | `: c1\n: c2\nevent: e\ndata: d\nid: 7\nretry: 5\n\n` |
| `('x','','','3000','')` | `data: x\nretry: 3000\n\n` |

`KEEPALIVE_COMMENT = b': ping\n\n'`；`EventSourceResponse.media_type =
"text/event-stream"`。

## 2. 目标

1. `format_sse_event` 全字段逐字节对齐上游（含字段序 + 行切分 + 尾空串）；
2. `data` 保持 `raw_data` 语义（本仓库既有声明式语义，与上游一致）；
3. 路由级声明式接线（`_sse_event` / `_sse_id` / `_sse_retry` / `_sse_comment`）；
4. 旧 data-only 入口 `build_sse_body` 零行为变化（向后兼容）；
5. 零新依赖 / **FFI diff = 0** / North Star 不变。

## 3. 决策

### 3.1 `streaming.mojo` 重写（150 LOC，纯逻辑）

| 函数 | 语义 |
|---|---|
| `_split_sse_lines(value)` | 上游 `_split_sse_lines`：`\r\n`/`\r` → `\n`，split 保留尾空串 |
| `format_sse_event_full(data, event, id, retry, comment)` | 上游 `format_sse_event` 逐字节对齐（字段序 + `\n\n` 终止符） |
| `format_sse_event(data)` | 兼容入口 = `format_sse_event_full(data, "","","","")` |
| `build_sse_body_fields(events_csv, event, id, retry, comment)` | `\|` 分隔事件 → 路由级字段施加到每个事件 → 完整 body |
| `build_sse_body(events_csv)` | 兼容入口 = `build_sse_body_fields(..., "","","","")` |
| `sse_event_count(events_csv)` | 事件数 = `\|` 数 + 1（空 → 0） |

含 `main()` 自检（`mojo run streaming.mojo`），覆盖上表全部已知向量。

### 3.2 dispatch 接线

`http_server_final.mojo` 的 `KIND_SSE` 分支读取 `_stream_events` 后，追加读
`_sse_event` / `_sse_id` / `_sse_retry` / `_sse_comment`（缺省空串），调用
`build_sse_body_fields(...)`。路由级字段施加到该路由**每个**事件。

新增 demo：`/sse/fields`（`alpha|beta` + event `msg` + id `42` + retry `3000` +
comment `ping`，wire = `: ping\nevent: msg\ndata: alpha\nid: 42\nretry: 3000\n\n` ×2）、
`/sse/tail`（`_stream_events = "t\n"`，验尾空串保留）。

### 3.3 `data` 语义 = `raw_data`

上游 `format_sse_event` 的 `data` 参数即 `raw_data`（不 JSON 编码）；本仓库既有
SSE 亦为原样输出，故 **parity 保持**，不引入 JSON 编码路径（e2e SF-5 守护）。

## 4. 备选方案对比

| 方案 | 结论 | 理由 |
|---|---|---|
| 逐事件声明字段（JSON 列表 per event） | 拒绝 | 声明式路由难以承载逐事件异构字段；路由级（施加到每事件）覆盖上游常见用法，边界记 §7 |
| data 改为 JSON 编码 | 拒绝 | 破坏上游 `raw_data` parity 与本仓库既有语义 |
| 重写 `streaming.mojo` 全字段 + 兼容入口 | 接受 | 纯逻辑模块、逐字节对齐、旧入口零变化 |

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `streaming` 只 import `string_builder`；dispatch 单向依赖它 |
| 2. 分层向下依赖 | ✅ 遵守 | 纯逻辑模块 → dispatch 使用者；无反向 |
| 3. God package 阈值 | ✅ 遵守 | `streaming.mojo` **150 LOC**（< 500）；`http_server_final.mojo` 既有超阈值文件（grandfathered） |
| 4. 主题域边界清晰 | ✅ 遵守 | SSE 序列化 = streaming 域 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（无新增/修改 FFI）；零新 crate |
| 6. 测试文件跟随 | ✅ 遵守 | `streaming.mojo` 自检（含全部已知向量）+ e2e SF-1..SF-5 |

## 6. 验收（2026-09-12）

- e2e **577 → 582/582**（SF-1..SF-5）。
- canonical `./benchmark.sh` 6 场景 **0 errors**。
- cargo bridge **500/0/4**；clippy 双 crate `-D warnings` 0；fmtool **35/0**。
- `ldd build/fastapi_mojo` 仅 libc / loader / vdso；`env -i` 干净启动 200。
- binary 5,044,576 B（≤6 MiB）；C=Python=orphans 0。
- Mojo 自检：`streaming` / `json` / `params_query` / `params_json` / `router` /
  `string_builder` / `params_query_extra` / `mw_spec` / `ws_protocols` /
  `security_jwt` / `openapi_custom_selftest` 全绿。

## 7. 实现 / 边界

- `src/fastapi_mojo/streaming.mojo`（重写 150 LOC）：`_split_sse_lines` +
  `format_sse_event_full` + 兼容 `format_sse_event` / `build_sse_body` +
  `build_sse_body_fields` + `sse_event_count` + `main()` 自检。
- `src/fastapi_mojo/http_server_final.mojo`：import 更新 + `KIND_SSE` 分支读
  `_sse_*` 字段 + `/sse/fields`、`/sse/tail` demo。
- `scripts/e2e_test.sh`：SF-1..SF-5。

边界：字段为**路由级**（施加到该路由每个事件），非上游的逐事件
`ServerSentEvent(event=..., id=..., ...)` 异构声明（声明式模型承载不到逐事件异构；
常见 SSE 用法每事件字段一致，路由级覆盖）；keepalive `: ping` 常量注释未接入为
可配置 `_sse_keepalive`（`/sse/fields` 的 `_sse_comment` 已可产出注释行）。
