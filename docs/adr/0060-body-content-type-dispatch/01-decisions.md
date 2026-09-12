# ADR-0060: body 解析 Content-Type 分派 + 顶层值语义（决策-85）

**状态**：已接受
**日期**：2026-09-12
**决策**：85（兑现 ADR-0058 §5 偏差行「Content-Type 语义」+ §8 后续缺口 #3；
bead `fastapi_mojo-body-content-type-dispatch-iyj`）
**关联**：AGENTS.md §3.2/§6（**决策-85**）、决策-83（ADR-0058：登记本缺口 +
`json_invalid`/`ctx` 基建）、决策-84（ADR-0059：body 面字节安全）、
North Star（纯 Mojo 逻辑；**FFI diff = 0**；zero new crate；zero Rust/C 改动）、
上游 `fastapi 0.141.1`（`fastapi/routing.py:395-455` `strict_content_type`）、
`pydantic 2.13.4`、CPython `json`

## 1. 背景（缺口）

本实现此前**不按 Content-Type 分派 body 解析**：只要 body 是合法 JSON 就按 JSON
解析（ADR-0058 §5 明确登记为「既有全局取舍」）。上游 FastAPI
`strict_content_type=True` 默认（`fastapi/routing.py`）：

```python
body_bytes = await request.body()
if body_bytes:
    json_body = Undefined
    content_type_value = request.headers.get("content-type")
    if not content_type_value:
        if not actual_strict_content_type:      # 默认 True -> 不解析
            json_body = await request.json()
    else:
        message["content-type"] = content_type_value
        if message.get_content_maintype() == "application":
            subtype = message.get_content_subtype()
            if subtype == "json" or subtype.endswith("+json"):
                json_body = await request.json()
    body = json_body if json_body != Undefined else body_bytes
```

即：**仅 `application/json` 或 `application/*+json`（大小写不敏感，忽略
`;` 参数）触发 JSON 解析**；否则（含缺失 CT、`text/plain`、form CT、`text/json`）
body 作为**原始字符串**送进 pydantic → 模型报 `model_attributes_type`。

由此派生的**顶层值语义**（JSON CT 命中时）同样缺失：

| body 顶层 | 上游 | 本实现（修复前） |
|---|---|---|
| 无 body（0 字节） | `missing` `["body"]` input `null` | `json_invalid`（`empty body`） |
| JSON `null` | `missing` `["body"]` input `null` | `json_invalid` |
| JSON 数组 / 字符串 / 数字 / bool | `model_attributes_type` `["body"]` input = 原值 | `json_invalid` |
| 非法 JSON | `json_invalid` `["body", pos]` + `ctx.error` + input `{}` | `json_invalid` `["body"]`（无 pos/ctx）+ **`input` 为裸文本 → detail 非法 JSON** |
| 非 JSON CT + 任意 body | `model_attributes_type` `["body"]` input = 原始字符串（带引号） | 按 JSON 解析（偏差） |

第三行末列是**真实 BUG**：`{not json` 的 422 detail 里 `input` 直接回显裸文本
（`"input":{not json`），使整个 `detail` 不是合法 JSON。

## 2. 目标

body 解析与顶层校验对齐上游 `strict_content_type=True` 默认：CT 分派 + 顶层
值语义 + `json_invalid` 的 `loc[1]`/`ctx.error`/`input` 全部对齐 CPython `json`
错误位置与消息；`detail` 恒为合法 JSON。ASCII / 既有多字节字节安全语义不变。

## 3. 实现（纯 Mojo；核心 `run_handler` / router / FFI 零改动）

1. **新叶模块 `body_json.mojo`（378 LOC，零 import，全 `as_bytes()` 字节安全）+ 同目录自测 `body_json_test.mojo`（85 LOC）**：
   - `validate_body_json(body) -> JsonScan`：递归下降扫描器复刻 CPython `json`
     的**首个错误位置 + 消息**（`Expecting value` / `Expecting property name
     enclosed in double quotes` / `Expecting ':' delimiter` / `Expecting ','
     delimiter` / `Extra data` / `Unterminated string starting at` /
     `Invalid \escape` / `Invalid \uXXXX escape` / `Invalid control character at`）。
     数字扫描复刻 CPython（`0`/`[1-9]\d*` + 可选 `.\d+` + 可选 `[eE][+-]?\d+`；
     不完整小数/指数整体不匹配 → 留给容器报 `,` 分隔符错，如 `{"x":"1."}` → pos 6）；
     接受 CPython `allow_nan` 常量 `NaN` / `Infinity` / `-Infinity`（大小写敏感）。
     成功时返回顶层 `top_kind` + 顶层值原始 span。
   - `content_type_is_json(ct)`：取 `;` 前 media-type，trim 后按 `/` 切
     maintype/subtype，`application`(ci) + (`json`(ci) 或 `*+json`(ci))。
2. **`body_validate.mojo` `validate_body_schema`** 增加 `content_type: String =
   "application/json"` 形参（默认值保持既有单元测试调用点语义），在字段校验
   **之前**插入顶层分派：无 body → `missing`；非 JSON CT → `model_attributes_type`
   （input = 带引号原始串）；`validate_body_json` 失败 → `json_invalid`
   (`["body", pos]`, `ctx.error`, input `{}`)；`null` → `missing`；非 `object`
   → `model_attributes_type`（input = 原值 span；非有限 number 常量 `NaN`/`Infinity`
   → 转义字符串保 detail 合法）；否则进入既有 `_validate_fields`。
   - 「无 body」判定 = `body_str` 为空 **且** `body_params` 为平凡空
     （`param_count==0` 且无 error）—— 单元测试只传 `body_params` 时（`body_str=""`）
     仍按「有 body」处理；dispatch 真路径两者一致。
3. **`http_server_final.mojo` dispatch**：把已在同一分支读取的 `ct_hdr`
   （`_get_header("Content-Type")`）上移到 `validate_body_schema` 调用前并透传。
4. **`scripts/e2e_test.sh` helper**：`http_code`/`http_body` 在 `--data` 形参
   首字符为 `{`/`[` 时追加 `-H 'Content-Type: application/json'`（裸 `--data`
   默认 form CT；上游语义下 JSON body 必须显式 JSON CT）。form 测试（`a=1&b=2`）
   与显式 `-H` 调用不受影响。

## 4. 上游探测证据（fastapi 0.141.1 / pydantic 2.13.4 / CPython json）

```
POST /model (x:float)  body '{"x":"nan"}'  CT json   -> 500 (JSON 渲染 allow_nan=False) [另立]
POST /model  CT text/plain   body '{"x":1}'          -> 422 model_attributes_type ["body"] input "{\"x\":1}"
POST /model  CT (无)         body '{"x":1}'          -> 422 model_attributes_type ["body"] input "{\"x\":1}"
POST /model  CT application/x-www-form-urlencoded '{"x":1}' -> 422 model_attributes_type ["body"] input "{\"x\":1}"
POST /model  CT application/vnd.api+json '{"x":1.5}' -> 200 {"x":1.5}
POST /model  CT APPLICATION/JSON '{"x":1.5}'         -> 200
POST /model  CT application/json; charset=utf-8      -> 200
POST /model  CT text/json    body '{"x":1}'          -> 422 model_attributes_type
POST /model  CT json  body ''                        -> 422 missing ["body"] input null
POST /model  CT json  body 'null'                    -> 422 missing ["body"] input null
POST /model  CT json  body '[1,2]'                   -> 422 model_attributes_type ["body"] input [1,2]
POST /model  CT json  body '"hi"'                    -> 422 model_attributes_type ["body"] input "hi"
POST /model  CT json  body '{bad'                    -> 422 json_invalid ["body",1] ctx.error "Expecting property name enclosed in double quotes" input {}
POST /model  CT json  body '{"x":1}trailing'         -> 422 json_invalid ["body",7] ctx.error "Extra data" input {}
POST /model  CT json  body '   '                     -> 422 json_invalid ["body",3] ctx.error "Expecting value" input {}
```

CPython `json.loads` 位置向量（`probe`，本实现逐条对齐）：
`{bad`→(1, prop-name)、`{"x":1}trailing`→(7, Extra data)、`   `→(3, Expecting
value)、`{`→(1, prop-name)、`[`→(1, Expecting value)、`[1,`→(3, Expecting
value)、`[1 2]`→(3, Expecting ',' delimiter)、`{"x":}`→(5, Expecting value)、
`{"x" 1}`→(5, Expecting ':' delimiter)、`{"a":1,}`→(7, prop-name)、`{"x":01}`→(6,
',' delimiter)、`{"x":1.}`→(6, ',' delimiter)、`{"x":.5}`→(5, Expecting value)、
`{"x":tru}`→(5, Expecting value)、`{"x":"abc}`→(5, Unterminated string starting
at)、`{"x":"a\qb"}`→(7, Invalid \escape)、`{"x":"a\u12zz"}`→(8, Invalid \uXXXX
escape)、`5x`→(1, Extra data)、`nul`→(0, Expecting value)、`falsee`→(5, Extra
data)、`{"a":{"b":}}`→(10, Expecting value)、`{"x":1}{`→(7, Extra data)。

## 5. 已知偏差（相对上游）

| 偏差 | 上游行为 | 本实现 | 影响 |
|---|---|---|---|
| 422 对象键序 | `type,loc,msg,input,ctx` | house `loc,msg,type,input,ctx`（`ctx` 末位） | **既有约定**（ADR-0029 §3.7），非本决策引入 |
| 错误体附加字段 | `{"detail":[...]}` | `detail` 外带 `status/method/path/handler/request_id/duration_ms`（超集） | **既有约定**（ADR-0058 §5） |
| 顶层非 object `input` 规范化 | Python 反序列化后**重新序列化**（去空白 / 数字规范化，如 `[ 1 , 2 ]`→`[1,2]`） | 回显**原始 span**（紧凑常见情形一致；`[ 1 , 2 ]` 保留空白） | 仅空白/数字字面量形态差异；语义一致 |
| JSON string 顶层 `input` 转义 | 解码后重编码（`"\u0041"`→`"A"`） | 回显原始 span（`"\u0041"`） | 同上（形态差异） |
| `json_invalid` `ctx.error` 覆盖面 | CPython 全错误面 | 覆盖上表 9 类常见错误；极冷门分支（如深度递归保护）未逐一复刻 | 消息覆盖常见路径 |
| 非有限 `inf`/`nan` float JSON 渲染 | 500 | 回显字符串 `"inf"`/`"nan"` | 决策-81 既有偏差，另立 ADR |
| form/multipart CT 分派 | `is_body_form` 仅在声明 `Form`/`File` 时；模型 body 走 body_bytes | 同（模型 `_body_schema` + form CT → `model_attributes_type`） | 一致 |

## 6. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | `body_json`（叶，零 import）← `body_validate`（校验层）单向；dispatch 只透传 CT 字符串。无新跨层边、无环 |
| 2. 分层向下依赖 | ✅ 遵守 | 纯字符串/字节变换（无 FFI / 无 fd / 无 env）；接线在 `validate_body_schema` 单点；`JsonScan` 值语义（`return r^`，非隐式拷贝） |
| 3. God package 阈值 | ✅ 遵守 | 新文件 `body_json.mojo` **378** + `body_json_test.mojo` **85**（自测独立，均 < 500）；`body_validate.mojo` 333→**371** < 500；`body_validate_test.mojo` 240→**288** < 500；`http_server_final.mojo` 为既有 grandfathered 文件（+3/-2） |
| 4. 主题域边界清晰 | ✅ 遵守 | 「body 顶层 JSON 校验 + CT 分派」归 body 域（`body_json`/`body_validate`）；transport CT 头读取沿用 dispatch 既有 `_get_header` |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（零新导出 / 零新 crate / 零 Rust / 零 C）；全部纯 Mojo |
| 6. 测试文件跟随 | ✅ 遵守 | 新 `body_json_test.mojo` 自测（~40 断言：合法/非法/位置/消息 + CT 判定）；`body_validate_test.mojo` +13 组（CT 分派/空/null/非 object/json_invalid loc·ctx·input）并**为 39 处既有调用点补真实 body_str**；e2e 新增 `CT-1..CT-17`；CI mojo 列表 +`body_json` |

## 7. 验收（2026-09-12）

- Mojo 自测全绿（CI 列表 10 模块 + `body_json_test` + `params_typed` + `body_validate_test`）。
- e2e **785 → 802/802 全绿**（新增 `CT-1..CT-17`：text/plain·无 CT·form·`text/json`
  → model_attributes_type；`json;charset`/`APPLICATION/JSON`/`*+json` → 解析 200；
  `null`→missing；数组/字符串/数字→model_attributes_type；非法 JSON→loc pos+ctx+input
  `{}`；trailing→Extra data pos；`jsoncheck` detail 合法 JSON；空 body→missing；
  `NaN` 顶层→input 转义字符串 + `jsoncheck` 合法；回归 200）。
- bridge `cargo test --release -- --test-threads=1` = **516 passed / 0 failed /
  4 ignored**（本轮无 Rust 改动）；fmtool **35/0**；双 crate clippy `-D warnings`
  = **0**。
- `./benchmark.sh` 6 场景 0 errors（get_root_10k_100c ≈ 31.7k req/s，噪声带内）；
  `ldd build/fastapi_mojo` 仅 libc；`env -i` 干净启动（`/health` 200）；
  binary **5,204,416 B**（≤ 6 MiB）；`find src -name '*.c'` = 0；
  `*.py`（除 docs/.git）= 0；`pgrep -x fastapi_mojo` = 0。

## 8. 后续缺口（本决策未覆盖，另立 ADR）

1. 非有限 `inf`/`nan` float JSON 渲染语义（上游 500）。
2. float 格式化边界（CPython repr 之外）。
3. 顶层非 object `input` 的 CPython 反序列化-重序列化规范化（空白/数字/转义形态）。
4. `SecurityScopes` 对象面 / `OAuth2PasswordRequestForm` 对象面。
5. CORS 裸 `OPTIONS` 通配超集（ADR-0048 §5 既有文档化）。
6. multi-arch（aarch64）/ asgi-shim（P2 open beads）。
