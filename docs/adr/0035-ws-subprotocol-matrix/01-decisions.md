# ADR-0035: WebSocket application subprotocol matrix

**状态**：已接受
**日期**：2026-09-12
**决策**：60（Goal-0003 P2 / `ws-subprotocol` bead）

## 1. 背景

决策-15~18、51、59 已提供 RFC 6455 会话、路由/鉴权、声明式 close/exception
指令与 RFC 7692 压缩，但应用层子协议示例仍只有 `chat`。真实上游客户端
常在 `Sec-WebSocket-Protocol` 中携带 JSON-RPC、GraphQL WebSocket 或二进制
RPC 约定；服务端需要证明子协议选择和应用消息分派不是一个硬编码 echo 特例。

本决议补齐三个端点：

- `/ws/jsonrpc`：`jsonrpc` / `v2.jsonrpc`
- `/ws/graphql-ws`：`graphql-transport-ws` / legacy `graphql-ws`
- `/ws/grpc-web`：二进制 `grpc-web` 透明桥接

## 2. 候选方案

| 方案 | 描述 | 判定 |
|------|------|------|
| A. 每个 RPC 协议新增 `KIND_WS_*` | 扩 handler kind + dispatch | ❌ handler.mojo 已 495 LOC，会把通用扩展点推向 God file |
| B. 只加三个 echo 路由 | 仅验证 `Sec-WebSocket-Protocol` 回显 | ❌ 无法证明应用消息语义，上游客户端不可用 |
| C. **`_ws_protocol` 数据驱动 + 纯协议模块** | route 仍用 echo kind，`ws_protocols.mojo` 处理应用消息 | ✅ 用户代码=数据；协议逻辑 FFI-free；FFI diff=0 |
| D. 完整实现 GraphQL/gRPC 引擎 | schema/protobuf/服务定义全量执行 | ❌ 远超 bead 范围，且 FastAPI 核心不内嵌这些引擎 |

**决策**：C。gRPC-Web 明确作为二进制透明桥接边界，不伪装为完整 RPC 引擎。

## 3. 决策

### 3.1 子协议协商

`ws_sp` 从单候选扩展为**逗号分隔 server-preference 候选列表**：

- 客户端 offer 仍按 `Sec-WebSocket-Protocol` 逗号列表解析并 trim；
- 服务端按 `ws_sp` 前后顺序选择第一个交集；
- 响应只回显被选中的一个 token；
- 单候选 `/ws/chat` 行为不变；
- 无交集仍返回既有 HTTP 400 JSON error。

例子：

```text
server ws_sp: graphql-transport-ws,graphql-ws
client offer: graphql-ws, graphql-transport-ws
selected:    graphql-transport-ws
```

### 3.2 JSON-RPC 2.0

`/ws/jsonrpc` 支持 `jsonrpc` 与 `v2.jsonrpc` fallback，消息语义：

- `echo`：params 必须是 object/array，result 原样保留 JSON 结构；
- `ping`：result 为 `"pong"`；
- `add`：params object 的 `a` / `b` 数值相加；
- notification（无 `id`）：不回复；
- parse error：`-32700`；
- invalid request：`-32600`；
- invalid params：`-32602`；
- method not found：`-32601`；
- response 按 JSON-RPC 2.0 保留 String/Number/Null id 类型。

### 3.3 GraphQL WebSocket

`/ws/graphql-ws` 同时接受：

- modern `graphql-transport-ws`；
- legacy `graphql-ws`。

支持控制面：

- `connection_init` → `connection_ack`
- `ping` → `pong`
- `subscribe` / legacy `start`：
  - 提取 `id` 与 `payload.query`
  - 发送 `next`（`data.query` echo）
  - 随后发送 `complete`
- `complete` / legacy `stop` / `connection_terminate`：不回复
- malformed/unknown message：close `4400:<reason>`

### 3.4 gRPC-Web binary bridge

`/ws/grpc-web`：

- 必需子协议 token 为 `grpc-web`；
- 仅接受 BINARY WebSocket frame；
- 使用既有 zero-copy current-binary writer 原样回传（NUL 安全）；
- TEXT 输入按 unsupported data close `1003`。

该端点证明二进制应用协议可穿过 WS 会话层；**不声称**实现 protobuf codec、
gRPC service dispatch、status/trailer frame 生成或 HTTP/2 gRPC-Web transport。

### 3.5 FFI / ABI 不变式

**FFI diff = 0**。

- 未新增 `extern "C"`；
- 未改 Rust bridge；
- 复用 `get_ws_protocol_slice`、`ws_session_begin`、`ws_payload_slice`、
  `ws_write_text`、`ws_write_current_binary`、`ws_send_close_reason`；
- 新逻辑位于 Mojo 协议纯模块 + session 数据驱动分支。

## 4. 风险与权衡

| 风险 | 处置 |
|------|------|
| 多候选协商破坏既有 chat 行为 | 单候选等价；e2e M7 与新增 WSP8 回归 |
| 应用协议解析引入 FFI/全局状态 | `ws_protocols.mojo` 只 import json/numlit/params_json，bridge-free 可单测 |
| GraphQL 客户端等待 complete | subscribe/start 一次产生 next + complete 两个 TEXT frame |
| JSON-RPC notification 后连接静默 | e2e 立即发送下一个带 id 请求验证连接仍活跃 |
| gRPC-Web 被误读为完整 RPC | ADR 明确 transparent binary bridge 边界，不做 protobuf 解码 |
| 新路由增加体积 | 实测仍低于 4.2M；ldd 仍仅 libc |

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|------|------|------|
| 1. 无循环依赖 | ✅ 遵守 | `ws_session.mojo → ws_protocols.mojo → {json, params_json, numlit}` 单向；协议模块不 import session/handler |
| 2. 分层向下依赖 | ✅ 遵守 | 应用子协议位于 Mojo session 层；bridge 只继续提供既有 RFC 6455/WS FFI |
| 3. God package 阈值 | ✅ 遵守 | 新 `ws_protocols.mojo` 163 LOC；`ws_session.mojo` 207 LOC；`ws_protocol_routes.mojo` 26 LOC；未扩 495 LOC 的 handler.mojo |
| 4. 主题域边界清晰 | ✅ 遵守 | 子协议选择在升级层，JSON/GraphQL消息语义在纯协议模块，gRPC-Web二进制透传在 session 层 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff=0**；`_ws_protocol` 是显式路由数据，不隐藏在 echo kind 中 |
| 6. 测试文件跟随 | ✅ 遵守 | `ws_protocols.mojo` 自测与生产文件同目录；fmtool/e2e WSP 场景直接打真实 server |

## 6. 验收（2026-09-12）

- Mojo bridge-free unit：`mojo run ws_protocols.mojo` ✅
- fmtool：**35 passed / 0 failed**；clippy `-D warnings` **0 警告**
- Rust bridge 回归：**470 passed / 0 failed / 4 ignored**；clippy `-D warnings` **0 警告**（本决策 Rust diff=0）
- build：`./build_single.sh` 成功；binary **4,171,928 B**（≤4.2M）
- ldd：仅 libc/loader/vdso
- standalone WSP matrix：**WSP1..WSP8 全绿**
- full e2e：471 → **479/479**（新增 8 项，既有 471 零回归）
- bench：6 场景 **0 errors**（get_root_10k_100c = 34,176.35 req/s；HTTP 基准不进 WS 子协议热路径）
- `find src -name '*.c'` = 0；未新增 Python/C 路径

## 7. 文档化偏差 / 边界

1. JSON-RPC batch 请求暂不支持；当前单帧请求/notification 语义先行。
2. GraphQL 端点是控制面 + query echo adapter，不包含 schema parser/executor。
3. `grpc-web` WebSocket token 不是本项目定义的 IETF 标准；该端点是二进制透明
   bridge，不生成 gRPC status/trailer frame，也不解码 protobuf。
4. 多候选 `ws_sp` 采用 server-preference 顺序；这是 WebSocket 协商允许的服务端
   选择策略，不模拟客户端优先级。
5. 应用协议 route 复用 `KIND_WS_ECHO`，行为由 `_ws_protocol` 数据切换；这是为
   避免扩 495 LOC handler God file 的显式扩展点。

## 8. 实现

- `src/fastapi_mojo/ws_session.mojo`：多候选子协议选择 + `_ws_protocol` dispatch
- `src/fastapi_mojo/ws_protocols.mojo`：FFI-free JSON-RPC/GraphQL 消息纯函数
- `src/fastapi_mojo/ws_protocol_routes.mojo`：三个应用子协议 route 注册
- `src/fastapi_mojo/http_server_final.mojo`：仅委托注册（不继续堆积 route 细节）
- `src/fmtool/src/e2e.rs`、`src/fmtool/src/main.rs`：`wsmatrix` WSP1..WSP8
- `scripts/e2e_test.sh`、`.github/workflows/ci.yml`：e2e 471→479 + unit 列表
