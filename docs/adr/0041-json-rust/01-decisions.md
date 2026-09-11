# ADR-0041: JSON response serialization Rust acceleration（opt-in）

**状态**：已接受
**日期**：2026-09-12
**决策**：66（Goal-0001 future #9 / `json-rust` bead）

## 1. 背景

`json.mojo` 已在决策-10 中消除 O(n²) 字符串拼接，对 JSON object 的序列化是线性
时间。但当前 response model 的最终形态是扁平 `Dict[String, String]`；对大响应
（约 1 MiB 级别）而言，每个字节的 escape 判断、控制字符展开和输出缓冲追加仍由
Mojo 循环承担。Goal-0001 future #9 因此要求评估「手写 serde-like Rust writer +
FFI」的 opt-in 加速路径。

本轮明确范围：

- **加速对象**：response JSON object serialization（`response_model_body` 的最终
  flat dict → JSON bytes）；
- **不改变对象**：request body JSON parsing 仍在 Mojo `params_json.mojo` 中完成；
- **默认行为**：纯 Mojo serializer 保持不变，Rust 路径只由环境变量显式启用。

## 2. 目标

1. 大响应（escape 密集型 ~1 MiB）获得可测量的端到端收益；
2. 输出与 `json_serialize_dict` 字节兼容，避免客户端可见行为变化；
3. 保持 Mojo + Rust only、零第三方运行时依赖与 single binary North Star；
4. FFI 返回缓冲满足决策-36 的 NUL 终止契约；
5. 失败时回退 Mojo serializer，不把 FFI/分配问题升级成 500 响应。

## 3. 决策

### 3.1 Opt-in dispatch

`response_model_body` 继续是唯一 response serialization 调用点，改调
`serialize_dict_opt_in()`：

```bash
FASTAPI_MOJO_JSON_SERIALIZER=rust
FASTAPI_MOJO_JSON_RUST_MIN_BYTES=65536
```

- 默认 `FASTAPI_MOJO_JSON_SERIALIZER` 非 `rust` 时，完全走原 `json.mojo`；
- 阈值按 flat response dict 的输入字节估算：
  `sum(key.byte_length + value.byte_length + 6)`；
- 阈值默认 65,536 bytes；空值、非正数或非法数字回退默认值；
- 小响应继续留在 Mojo 路径，避免每字段 FFI 固定成本反向损失。

### 3.2 字节兼容契约

Rust writer 不重新定义 JSON 格式：

- 字段顺序 = Mojo `Dict` 迭代顺序；
- object 格式 = `{`、`", "` 成员分隔、`"key": value`；
- ordinary string escape = `"` / `\`、`\n` / `\r` / `\t`、其它 `<0x20` 控制字符
  输出小写 `\u00xx`（因此 `\b` / `\f` 与既有 `json.mojo` 一样输出
  `\u0008` / `\u000c`），非 ASCII UTF-8 bytes 原样透传；
- `__nested__:<raw JSON>` 仍为 raw passthrough，字段顺序和内层格式不变；
- begin/add/finish 任一步失败或输出为空时，Mojo wrapper 回退
  `json_serialize_dict(data)`。

### 3.3 Rust writer 与 FFI

新增 std-only 手写 writer（无 serde / serde_json / 第三方 crate）：

- `bridge/json_writer.rs`：`JsonObjectWriter`，一次性 Vec 输出、首字节预置 `{`、
  finish 追加 `}`，避免 `Vec::insert(0, ..)` 的整段 memmove；
- `bridge/json_ffi.rs`：进程内 global `Mutex<JsonObjectWriter>`，导出 4 个
  `extern "C"` API：

| FFI | 语义 |
|---|---|
| `fm_json_object_begin()` | 重置 writer；0 成功 / -1 lock poisoned |
| `fm_json_object_add(key, key_len, value, value_len, raw)` | 添加一个成员；显式长度，输入 binary-safe |
| `fm_json_object_finish()` | 返回 `malloc(n+1)` 且 `[n]=0` 的 `CSlice` |
| `fm_json_object_free(ptr)` | 释放 finish 缓冲；null no-op |

当前 dispatch 为每 worker 进程内的串行 response 构造；Mutex 防止状态数据竞争。
若未来 bridge 内部引入并发 response dispatch，需要把 begin/add/finish 升级为
session handle API，不能依赖跨调用隐式 global 事务。

### 3.4 ASCII span 快速构造

`span_to_str()` 原先对 bridge 返回的每个 ASCII byte 调一次
`StringBuilder.append_byte()`。Rust JSON 输出回到 Mojo 时，这会额外引入一次
byte-by-byte Mojo 循环，足以抵消 writer 收益。

本轮增加保守 fast path：

1. 先线性探测 span 是否全部 `<0x80`；
2. ASCII span 使用 `String(unsafe_from_utf8=span)` 批量构造；
3. 含非 ASCII 的 span 保持原 robust UTF-8 decoder 与 U+FFFD fallback。

该优化对默认与 Rust 两条路径同样生效；输入 span 的 UTF-8 有效性仍由 bridge
请求校验与 `CStringSlice` 契约保证，非 ASCII 不走 unsafe 分支。

### 3.5 benchmark 工具补充

`fmtool bench` 场景新增 `data_file` 字段，POST 时映射到 `hey -D <file>`。
这不是运行时功能，而是为了让唯一 benchmark 入口可以测试 >128 KiB 的请求体：
把 1 MiB JSON 放进场景 `data` 会触发 Linux `MAX_ARG_STRLEN` / `E2BIG`。

## 4. 备选方案对比

| 方案 | 结论 | 理由 |
|---|---|---|
| 全量替换默认 serializer | 拒绝 | 小响应 FFI 固定成本不划算；默认语义应保持零扰动 |
| serde / serde_json | 拒绝 | 新增运行时 crate，且 flat dict 契约不需要 derive 生态 |
| Rust 解析 request JSON | 拒绝 | Goal-0001 future #9 明确是 serialization；request parser 不在本轮 |
| 单个 giant FFI 参数序列化 | 拒绝 | Mojo dict 无法零拷贝导出，需先拼中间格式，抵消收益 |
| streaming begin/add/finish | 接受 | 字段顺序留在 Mojo，Rust 承担 byte-heavy escape / buffer assembly |

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `request_response → json_rust → bridge/json_ffi → bridge/json_writer` 单向；Rust 不回读 Router/Handler/HTTP/WS 状态 |
| 2. 分层向下依赖 | ✅ 遵守 | Mojo 仍拥有 response dict 与字段顺序；Rust 只做叶子层 byte writer / buffer adapter |
| 3. God package 阈值 | ✅ 遵守 | 新生产模块 `json_writer.rs` 84 行、`json_ffi.rs` 111 行、`json_rust.mojo` 87 行，均 <500 行 |
| 4. 主题域边界清晰 | ✅ 遵守 | JSON writer 只处理 flat object 序列化；不混入路由、request parsing、OpenAPI 或发送策略 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | 显式 +4 个 C ABI export；输入带长度、输出 `malloc(n+1)+NUL`，无第三方 runtime crate |
| 6. 测试文件跟随 | ✅ 遵守 | `json_writer_tests.rs` / `json_ffi_tests.rs` 与生产模块同目录；e2e JR-1..JR-6 覆盖真实 binary |

## 6. 性能测量

### 6.1 JSON-specific（escape 密集 1 MiB）

统一经由 `./benchmark.sh --scenarios /tmp/...`；场景文件中的 `data_file` 字段映射到 `hey -D`：

- 请求：`POST /echo`，JSON body 1,000,014 B；
- `payload` 解码后为 1,000,000 个 `"`，response 序列化时每个字符需展开为 `\"`；
- `n=200`、`c=1`、`--no-warmup`；两种模式使用同一 final binary，仅 env 开关不同；
- 每组两个独立 run，结果取算术平均。

| Mode | Run 1 req/s | Run 2 req/s | 平均 req/s | 平均 latency | 平均 P50 |
|---|---:|---:|---:|---:|---:|
| Mojo default | 92.47 | 90.06 | **91.27** | 10.96 ms | 10.70 ms |
| Rust opt-in | 115.94 | 110.75 | **113.35** | 8.83 ms | 8.50 ms |
| 变化 |  |  | **+24.19%** | **-19.44%** | **-20.56%** |

这是完整 HTTP request parse + loopback + response send 的保守端到端结果，而不是
孤立 microbenchmark；0 errors。

### 6.2 Canonical benchmark

默认（未启用 Rust JSON）6 个既有场景全部 **0 errors**：

| Scenario | req/s |
|---|---:|
| get_root_10k_100c | 34,722.22 |
| get_root_50k_500c | 13,791.58 |
| get_root_100k_200c | 27,941.55 |
| get_hello_10k_100c | 30,432.14 |
| post_items_10k_100c | 31,565.66 |
| get_items_42_10k_100c | 31,675.64 |

## 7. 验收（2026-09-12）

- Rust bridge：**496 passed / 0 failed / 4 ignored**（baseline 486 + 10）；
  clippy `--release --tests -D warnings` **0 警告**
- fmtool：**35 passed / 0 failed**；clippy **0 警告**
- Mojo `string_builder.mojo` 自检通过（ASCII fast path + UTF-8 decoder）
- e2e：521 → **527/527**（新增 JR-1..JR-6；主 e2e server 以
  `FASTAPI_MOJO_JSON_SERIALIZER=rust` + threshold=1 运行，既有 521 项同时守兼容性）
- build：binary **4,962,656 B**（≤6 MiB；较决策-65 +8,240 B）
- `ldd build/fastapi_mojo`：仅 libc / loader / vdso
- clean env：默认与 Rust JSON opt-in 均 `/health` 200，最终无孤儿 server
- 交付面：`find src -name '*.c'` = 0；`find src -name '*.py'` = 0
- benchmark：JSON-specific +24.19%；canonical 6 场景 0 errors

## 8. 实现 / 边界

- `src/fastapi_mojo/json_rust.mojo`：opt-in env、阈值、输入估算、FFI wrapper 与 fallback
- `src/fastapi_mojo/request_response.mojo`：两个 response serialization 调用点改走 `serialize_dict_opt_in`
- `src/fastapi_mojo/string_builder.mojo`：ASCII span fast path + 自测
- `src/fastapi_mojo_rs/src/bridge/json_writer.rs`：std-only serde-like object writer
- `src/fastapi_mojo_rs/src/bridge/json_ffi.rs`：global writer + 4 个 C ABI export
- `src/fastapi_mojo_rs/src/bridge/json_{writer,ffi}_tests.rs`：格式 / escape / NUL / FFI 回归
- `src/fmtool/src/bench.rs`：benchmark scenario `data_file` → `hey -D`
- `scripts/e2e_test.sh`：JR-1..JR-6
- `README.md` / `AGENTS.md` / Goal-0001 / Goal-0003：使用与决策记录

边界：只支持 flat response dict 的 object 序列化；`__nested__` 后缀必须是调用方
保证的合法 JSON（literal NUL raw JSON 不在有效 JSON 契约内）；request parsing
与任意 JSON value tree 序列化不随本决策迁移。
