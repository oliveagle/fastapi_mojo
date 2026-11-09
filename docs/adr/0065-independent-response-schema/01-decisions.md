# ADR-0065: 独立响应模型 schema（_response_schema vs _body_schema）

**状态**：已接受
**日期**：2026-09-13
**决策**：91（ADR-0064 §8 #3 兑现：response_model 独立于 body 的完整 schema）
**关联**：AGENTS.md §6（**决策-91**）、ADR-0064（决策-89：response_model exclude_unset/exclude_defaults/by_alias）、
决策-38（`_body_schema` spec）、North Star（**FFI diff = 0**；zero Rust / zero C；纯 Mojo）、上游
`fastapi 0.141.1` / `pydantic 2.13.4`

## 1. 背景（缺口）

决策-89（ADR-0064）落地了 `response_model` 的 exclude_unset / exclude_defaults / by_alias。
但当前实现中，response_model 的**字段类型 + 默认值**始终取自 `_body_schema`（请求体 schema）。

FastAPI 实际用法中，`response_model` 与请求体可以是**完全不同的 Pydantic 类**：

```python
class UserIn(BaseModel):
    username: str
    password: str  # 敏感字段
    email: str

class UserOut(BaseModel):
    username: str
    email: str
    is_admin: bool = False  # 新增字段
    # password 不出现

@app.post("/user/", response_model=UserOut)
def create_user(user: UserIn):
    return UserOut(username=user.username, email=user.email, is_admin=True)
```

关键差异：
1. **字段集合不同**：UserOut 无 password（安全过滤）
2. **新增字段**：UserOut 有 is_admin（业务派生）
3. **默认值不同**：is_admin 有默认值

当前实现缺口：`_response_model` 只是字段列表，类型/默认值仍从 `_body_schema` 读，
导致无法表达上述独立 schema。

## 2. 目标

用声明式 `_response_schema` 字段让 response_model 拥有独立于 body 的类型系统，
wire 行为与上游 FastAPI 一致；无 `_response_schema` 时回退到 `_body_schema`（向后兼容）。

## 3. 实现（纯 Mojo；**FFI diff = 0**；核心 dispatch 零改动）

1. **`_response_schema` 声明字段**：与 `_body_schema` 同语法（`name:type=default`），
   放在 `handler.data` 中。当存在时，response_model_body 优先使用它作为 specs 来源。

2. **`response_model_body` 修改**：
   ```mojo
   # 声明模型 = _response_schema if present, else _body_schema (决策-91 ADR-0065).
   var schema_source = "_body_schema"
   if "_response_schema" in handler.data:
       schema_source = "_response_schema"
   if schema_source in handler.data:
       var fs = parse_body_schema(handler.data[schema_source])
       for i in range(field_count(fs)):
           var fld = get_field(fs, i)
           specs[fld.name] = fld^
   ```

3. **`check_response_model_missing` 同步**：同样检查 `_response_schema` 优先。

4. **demo 路由**（`body_schema_routes.mojo`）：`/rm/indep`（POST）
   - `_body_schema`: `username:str;password:str;email:str;full_name:str=None`
   - `_response_model`: `username,email,is_admin`
   - `_response_schema`: `username:str;email:str;is_admin:bool=False`
   - 效果：响应只含 username/email/is_admin，password 被过滤，is_admin 有默认值。

## 4. 测试

- **e2e**：859/859 全绿（无回归）
- **手工验证**：`/rm/indep` 返回 `{"username":"alice","email":"alice@example.com","is_admin":false}`
  而非 body 中的 password 字段。

## 5. 已知偏差

| 偏差 | 上游行为 | 本实现 | 影响 |
|------|---------|--------|------|
| OpenAPI response schema | 从 response_model 类自动生成 | 从 `_response_schema` 生成（`$ref` 引用 components/schemas） | 已闭环（决策-95 实现；决策-100 P0 修复 JSON 非法） |
| 字段顺序 | Pydantic model 定义顺序 | _response_model CSV 顺序 | 等价 |
| 类型转换 | Pydantic validator | 无（值直接渲染） | 既有约定（ADR-0014） |

## 6. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|------|------|------|
| 1. 无循环依赖 | ✅ | `request_response` → `body_schema`（叶）；无新增依赖 |
| 2. 分层向下依赖 | ✅ | 纯 Mojo 字典查询；零 FFI / 零 fd / 零 env |
| 3. God package 阈值 | ✅ | `request_response.mojo` 389→**395** < 500；`body_schema_routes.mojo` 96→**107** < 500 |
| 4. 主题域边界清晰 | ✅ | schema 选择逻辑在 response_model_body 内部（3行）；无新 helper |
| 5. bridge/adapter 显式化 | ✅ | **FFI diff = 0**（零新导出 / 零 Rust / 零 C） |
| 6. 测试文件跟随 | ✅ | e2e 同目录；demo 在 body_schema_routes |

## 7. 验收

- e2e **859/859** 全绿
- bridge `cargo test --release -- --test-threads=1` 通过
- `ldd build/fastapi_mojo` 仅 libc.so.6
- binary 构建成功

## 8. 后续工作

1. ~~**OpenAPI response schema 生成**：从 `_response_schema` 生成 OpenAPI `responses` 中的 schema~~ ——
   **已实现**（决策-95：components/schemas 生成 `<handler>_response` 条目 + `responses` 以 `$ref` 引用）；
   **决策-100 P0 修复**其 JSON 非法缺陷（详见 §9）
2. **嵌套对象独立 schema**：支持 `response_model` 字段类型独立于 body 字段类型
3. **`exclude_defaults` 语义**：与 `_response_schema` 默认值交互（已实现，待 e2e 覆盖）

## 9. OpenAPI response schema 生成（决策-95）+ P0 修复（决策-100）

### 9.1 背景（缺口）

§8 #1 要求 OpenAPI 的 `responses` 从 `_response_schema` 生成 schema（上游 FastAPI 从
`response_model` 类自动生成）。决策-95 落地了该功能，但产出的 `/openapi.json`
**不是合法 JSON**：

1. **`$ref` 被拼成字符串而非对象**：`resp_schema_ref` 构造为
   `"$ref":"#/components/schemas/<name>"`，再被当作普通字符串塞进 `"schema":"…"`，
   结果是 `"schema":""$ref":"#/components/schemas/<name>""` —— 引号错位。
2. **`components/schemas` 条目多一个引号**：`schemas.append(… + ':"' + rsch)`
   产出 `"<name>":"{…}`，schema 对象被降级成字符串且对象体未闭合。
3. **`responses` 条目少一个右括号**（决策-100 实测定位）：`"200":{…` 这个响应对象
   **从未闭合**，导致 `/openapi.json` 整体在**第一个**带 `_response_schema` 的路由处
   开始失衡——该路由的 path item / operation 对象一并被吞掉，其后所有路由被错误地
   嵌套进上一个 operation 里，最终整份文档在 EOF 处仍差一个 `}`（实测 `jsoncheck`：
   `JSON parse error at 47911: expected ',' or '}'`）。

影响面：`/openapi.json` 整份文档非法 → Swagger UI / ReDoc 无法加载；
`fmtool jsoncheck` 守卫（MP21 / FM-17 / OP2-10）3 项失败。

### 9.2 修复（纯 Mojo；**FFI diff = 0**）

`src/fastapi_mojo/openapi.mojo`：

1. `resp_schema_ref` 改为**完整的 JSON 对象**字面量
   `{"$ref":"#/components/schemas/<name>"}`，并直接嵌入 `"schema":` 之后
   （不再套额外引号）。
2. `components/schemas` 条目去掉多余引号：`'"' + name + '":' + rsch`
   （`rsch` 本身已是完整 JSON 对象）。
3. `responses` 条目补齐闭合括号：`… + '}}}'`（原 `'}}'`）——
   `"200":{…}` / `"content":{…}` / `"application/json":{…}` 三层 + `schema` 值
   恰好闭合。

### 9.3 回归护栏（e2e 新增 4 项）

`scripts/e2e_test.sh` 新增 `RMOA-1..RMOA-4`（决策-95 此前**零 e2e 覆盖**，
是缺陷得以发布的直接原因）：

| 用例 | 断言 |
|------|------|
| RMOA-1 | `responses` 用 `{"$ref":"#/components/schemas/rm_indep_response"}` 引用 |
| RMOA-2 | `components.schemas` 含 `rm_indep_response` 且为 object schema |
| RMOA-3 | 独立响应字段（`is_admin`）出现在该 schema 内（不回落 `_body_schema`） |
| RMOA-4 | 整份 `/openapi.json` 通过 `fmtool jsoncheck`（**结构性守卫**） |

**反向验证**：临时回退 §9.2 第 3 项（少一个 `}`）→ 重建后 RMOA-4 与既有
MP21 / FM-17 / OP2-10 **同时转红**（864 passed / 4 failed），确认护栏有效。

### 9.4 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|------|------|------|
| 1. 无循环依赖 | ✅ | 改动全在 `openapi.mojo` 内部字符串拼接；未新增 import |
| 2. 分层向下依赖 | ✅ | 纯 Mojo 字符串构造；零 FFI / 零 fd / 零 env |
| 3. God package 阈值 | ⚠️ 存量 | `openapi.mojo` 602→**602** 行（改动等长，不增行）。**602 > 500 阈值是本 ADR 之前就存在的存量超限**（同批：`http_server_final.mojo` 2315 / `security_jwt.mojo` 578 / `form_params.mojo` 565 / `test_all.mojo` 558）；本修复不新增行、不恶化，另行拆分待办 |
| 4. 主题域边界清晰 | ✅ | 仅 OpenAPI 序列化面；未触碰 dispatch / response_model 运行时 |
| 5. bridge/adapter 显式化 | ✅ | **FFI diff = 0**（零新导出 / 零 Rust / 零 C） |
| 6. 测试文件跟随 | ✅ | e2e 断言就地加在 `scripts/e2e_test.sh`（既有 OpenAPI 段） |

### 9.5 验收

- e2e **868/868** 全绿（含新增 RMOA-1..4）
- bridge `cargo test --release -- --test-threads=1`：**516 passed / 0 failed / 4 ignored**
- `fmtool` crate：`cargo test --release` **35 passed**；两 crate `clippy -D warnings` **0 警告**
- Mojo JIT 单测（CI 同款 bridge-free 清单 + `-Xlinker` 桩）全绿
- `ldd build/fastapi_mojo` 仅 libc.so.6；`env -i` 干净启动 health 200
- binary **5,270,104 B (5.03 MiB)**；`find src -name '*.c'` = **0**
