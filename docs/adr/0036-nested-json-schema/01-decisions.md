# ADR-0036: Recursive nested JSON body schemas

**状态**：已接受
**日期**：2026-09-12
**决策**：61（Goal-0003 #4/#20 / `json-schema` bead）

## 1. 背景

决策-38 已提供声明式 `_body_schema`、直接嵌套 `obj{...}` 与标量数组；
决策-57/58 继续补齐 body regex 与标量数组元素级约束。但 body schema 对
`obj[]{...}` 只检查元素首字节是 `{`，不会递归校验元素内部字段，OpenAPI 也
只把 `items.type` 错映射成 `string`。这不足以表达 FastAPI/Pydantic 常见的
`list[ChildModel]` 请求体。

本决议闭环 **对象数组递归 schema**：

```text
models:obj[]{id:int|ge=1;tag:str|len=2-3}|items=1-2
```

## 2. 候选方案

| 方案 | 描述 | 判定 |
|------|------|------|
| A. 每个 JSON shape 新增 Handler kind | 扩展 handler God file | ❌ 与决策-60 同理，配置应数据驱动 |
| B. 仅把 `obj[]` 保留为 opaque object | 只检查元素是 object | ❌ 无法校验 child model / 无法生成正确 OpenAPI |
| C. **递归复用 `_validate_fields` + OpenAPI object schema** | 每个 array element 递归进入同一 schema | ✅ 文法零改动，错误 loc/input 自然对齐 |
| D. 引入通用 JSON Schema DSL | 新增一套 schema parser/validator | ❌ 超出当前声明式 `_body_schema` 兼容面 |

**决策**：C。

## 3. 决策

### 3.1 递归校验语义

- `obj[]{subspec}` 的每个元素必须为 JSON object；
- 元素内部逐字段递归 `_validate_fields`；
- 422 loc：`["body", <field>, <index>, <child-field>]`；
- missing 字段的 `input` 是**该 array element object**，不是整个请求体；
- 类型错误、默认值、`len/pat/gt/ge/lt/le/items` 沿用既有递归语义；
- 成功值保留 raw array（`body_models`），并注入可预测的扁平字段
  `body_models_<index>_<child>`；
- 外层 `items=N-M` 仍约束数组长度。

### 3.2 OpenAPI 3.0 schema

`obj[]{...}` 输出：

```json
{
  "type": "array",
  "items": {
    "type": "object",
    "properties": {
      "id": {"type": "integer", "format": "int32", "minimum": 1},
      "tag": {"type": "string", "minLength": 2, "maxLength": 3}
    },
    "required": ["id", "tag"]
  },
  "minItems": 1,
  "maxItems": 2
}
```

同时补齐 body 标量数值字段的 OpenAPI `minimum/maximum` 输出，并统一
`gt/lt` 为 OpenAPI 3.0 的 `minimum/exclusiveMinimum:true` 与
`maximum/exclusiveMaximum:true` 编码。

### 3.3 架构与 ABI

- **FFI diff = 0**
- **Rust bridge diff = 0**
- 递归校验全部在 Mojo 字符串/JSON parsed-value 层完成；
- body schema demo 路由拆到 `body_schema_routes.mojo`；
- body 校验自测拆到同目录 `body_validate_test.mojo`，保持生产/测试文件均
  低于 500 行。

## 4. 风险与权衡

| 风险 | 处置 |
|------|------|
| 深层递归 spec 可能组合爆炸/过深 | 与直接 `obj{...}` 一样由声明方控制；当前服务端 body 上限与 JSON parser 边界仍生效 |
| 扁平注入键可能与用户字段冲突 | 前缀含字段名+索引，只有显式声明 nested schema 才启用；raw array 仍保留 |
| `obj[]` OpenAPI 曾错为 string | 本次 e2e JS-8a 精确断言 recursive object items |
| 修改 body 数值 OpenAPI 键影响既有 spec | 仅补齐缺失键；e2e 497/497 零回归 |
| Mojo regex FFI 使 self-test JIT 需要符号 | CI 以既有 `jit_stub.sh` 注入只含 `regex_match` 的桩 |

## 5. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|------|------|------|
| 1. 无循环依赖 | ✅ 遵守 | `body_validate → body_schema/params_json/handler`、`openapi_schemas → body_schema`、`body_schema_routes → handler/router` 均单向 |
| 2. 分层向下依赖 | ✅ 遵守 | 校验在 Mojo 域层；无新 syscall、无新 bridge 能力 |
| 3. God package 阈值 | ✅ 遵守 | `body_validate.mojo` 371 行、`body_validate_test.mojo` 141 行、`openapi_schemas.mojo` 358 行、`body_schema_routes.mojo` 38 行；server hub 净减 23 行 |
| 4. 主题域边界清晰 | ✅ 遵守 | spec 文法零改动；校验/OpenAPI/路由注册分别留在三个模块 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff=0 / Rust bridge diff=0**；仅复用既有 regex FFI |
| 6. 测试文件跟随 | ✅ 遵守 | `body_validate_test.mojo` 与生产代码同目录；e2e 直接打真实 binary |

## 6. 验收（2026-09-12）

- Mojo CI-style units：`json/params_query/params_json/router/string_builder/params_query_extra/mw_spec/ws_protocols` + `params_typed` + `body_validate_test` 全绿
- Rust bridge：**470 passed / 0 failed / 4 ignored**；clippy `-D warnings` **0 警告**
- fmtool：**35 passed / 0 failed**；clippy `-D warnings` **0 警告**
- build：`./build_single.sh` 成功；binary **4,180,120 B**（≤4.2M）
- ldd：仅 libc/loader/vdso
- clean env：`env -i PATH=/usr/bin:/bin ./build/fastapi_mojo …` health 200，退出无孤儿
- e2e：479 → **497/497**（新增 JS-1a..JS-8b 共 18 项，既有 479 零回归）
- benchmark：6 场景 **0 errors**；get_root_10k_100c = **31,836.99 req/s**（HTTP 热路径不进 nested body schema）
- `find src -name '*.c'` = 0；仓库交付面 `*.py` = 0

## 7. 文档化偏差 / 边界

1. `T[][]` / 嵌套数组的元素级约束仍不在本决策范围；
2. opaque `obj`（无 `{subspec}`）不猜内部 schema；
3. nested default 值沿用声明原文，不在注册期反序列化校验；
4. validator/custom serializer closure 仍是 Mojo 1.0.0 无闭包硬边界
   （ADR-0014）；
5. OpenAPI 仍为项目既有 3.0.3 面，不切换 3.1.0。

## 8. 实现

- `src/fastapi_mojo/body_validate.mojo`：`obj[]{...}` 每元素递归校验
- `src/fastapi_mojo/body_validate_test.mojo`：决策-38~61 body schema 自测拆分与新增 object-array assertions
- `src/fastapi_mojo/openapi_schemas.mojo`：recursive object `items`、body 数值 min/max、obj/arr type mapping
- `src/fastapi_mojo/body_schema_routes.mojo`：body schema demo 路由拆分 + `/validate/nested`
- `src/fastapi_mojo/http_server_final.mojo`：委托 `register_body_schema_routes(router)`
- `scripts/e2e_test.sh`、`.github/workflows/ci.yml`：JS-1a..8b 与 497 门禁
- `AGENTS.md`、`docs/goals/0003-fastapi-full-parity.md`：决策-61 / bead 销账
