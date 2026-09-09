# ADR-0018: 查询参数精化 — List 多值 / alias / description（声明式纯 Mojo）

- **日期**：2026-09-10
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行，Goal-0003 P2 矩阵 #3 落地）
- **关联**：AGENTS.md §3.2/§6（**决策-43**）、Goal-0003（P2：查询多值/alias/desc）、
  North Star（单 binary 零依赖 — **零新增依赖**，纯 Mojo 模块，**FFI diff = 0**）、
  FastAPI 0.141.1（`Query(alias=...)` / `description=...` / `List[T]` 语义，
  /tmp/fm_probe 实测）、决策-38（`T[values]` enum 语法 + 422 detail 结构 +
  `alias` 是 Mojo 关键字教训）、决策-42（声明式数据模式 — `set_data` 扩展点）

## 1. 背景

决策-38 落地了 query/path 参数的类型化（`int` / `int=10` / `str[low,high]`
enum）+ FastAPI 422 detail（loc/msg/type，全收集）。但 FastAPI 查询参数的
三个常用能力仍缺失：

1. **多值（List）参数**：`?tag=a&tag=b` → FastAPI 绑定 `List[str]` 得
   `[a,b]`（**全部 occurrence，顺序**）；单值 → wrap `[a]`；缺失 → 默认值
   或 422 missing（loc `["query","tag"]`，`Field required`）。本实现旧行为
   = 扁平 dict last-wins（`?tag=a&tag=b` → `"b"`）。
2. **alias**：`Query(alias="lvl")` — **查询 key = alias**，原始参数名无
   绑定效力（请求只带 `?lvl=low` 时绑定 `level`）；OpenAPI
   `parameter.name` = alias。
3. **description**：`Query(description="...")` → OpenAPI parameter 对象
   **与** schema **双处** description。

实测证据（FastAPI 0.141.1，/tmp/fm_probe）：
- multi→list：全部 occurrence 按序；单值 → wrap；缺失 → 默认值或 422
  `{"type":"missing","loc":["query","n"],"msg":"Field required"}`
- multi→scalar：**last wins**（Starlette `MultiDict.get`）
- 非法 list 元素：**首个失败即报**（不继续收集），loc 带数组下标；
  int/float/bool 用 pydantic v2 完整措辞（bool：`"Input should be a valid
  boolean, unable to interpret input"`）
- alias：仅 alias key 绑定；raw name 忽略；OpenAPI `parameter.name` =
  alias；description 在 parameter 对象与 schema 双处
- OpenAPI list schema：`{"type":"array","items":{"type":"..."},"default":[...]}`；
  required list → 无 default
- 裸 `n: list[int]`（无 `Query()`）= 上游 **body** 参数 — 本实现声明式
  `T[]` 恒指 query-list（§3.5 偏差 1 文档化）

约束（Mojo 1.0.0 + North Star）：
- Mojo 无闭包 → 扩展点 = 声明式数据（`handler.data` 的 `set_data`，与
  `_param_types`/`_reads_headers`/`_body_schema` 同模式，决策-37/38/42）
- query 解析/类型化校验本就属**纯 Mojo 层**（params_query / params_typed）→
  本能力同层落地，**Rust bridge 零改动**
- `alias` 是 Mojo 1.0.0 **关键字**（实测，不可作标识符）→ 一律
  `alias_name`；`mut var` 非法语法（实测）→ 普通 `var` 传 `mut` 参数
  （HEAD 既有模式）
- 测试同目录自测（本仓库约定），`check()` + `std.os.abort()` 真断言
  （决策-38：Mojo `assert` 是 no-op）

## 2. 候选方案

| 方案 | 描述 | 评估 |
|------|------|------|
| A. dispatch 主流程内联实现 | 在 http_server_final 的 serve_forever 里直接写 list/alias 逻辑 | ❌ dispatch 已 1173 行（既有超阈值，HEAD 1148）；逻辑混入主流程，不可独立自测；违反「新行为 = 数据 + 单点」模式 |
| B. **新纯 Mojo 模块 `params_query_extra` + 声明式 spec（本 ADR）** | `_param_types` 语法扩展（`T[]`/`T[]=csv`，向后兼容）+ 新声明表 `_param_aliases` / `_param_descs` + 纯函数（`parse_table` 泛化 / list 归一化 / alias 回写 / list 元素校验）+ dispatch 2 处接线 + OpenAPI 生成扩展 | ✅ FFI diff = 0；零新增依赖；声明式 = 既有模式（决策-38/42）；依赖图无环；自测可独立跑（`mojo run`）；binary +49 KB |
| C. 新增 Rust FFI 导出（`set_query_alias` 等） | Mojo 启动时经新 FFI 通道传配置 | ❌ 破坏「进程级声明式数据」模式；FFI 面 +N；query 解析本属纯 Mojo 层（params_query），无下推 bridge 必要 |

**决策：B** —— 纯 Mojo `params_query_extra` + 声明式 spec（决策-43）。

## 3. 决策

1. **语法扩展（`_param_types` 向后兼容；空括号 = list，非空 = enum
   决策-38）**：
   - `name:int[]` = List[int] **必填**（无默认）
   - `name:int[]=` = List[int] **可选**（默认空 list — FastAPI
     `Query([])` 在 String 世界的等价：`query_<name> = ""`）
   - `name:int[]=1,2` = List[int] 默认 `[1,2]`（CSV 字面量）
   - 注册期 `set_param_type` 校验 list 默认值逐元素（int/float/bool 必须
     可解析，否则 raise）；**拒绝 enum-list**（`str[low][]` 不可表达）
2. **alias（`_param_aliases = "name=alias;..."`，query-only，path 豁免）**：
   - FastAPI `Query(alias=...)` 语义：**查询 key = alias**；原始 name 无
     绑定效力
   - 校验：按 **alias key** 取值（缺失 → 默认值 / 422）
   - 成功路径：`values[name]` **恒覆写**为绑定值（请求含 alias key → 其
     last-wins 值；否则 → 默认值）→ handler 读 `query_<name>` 永远得到
     绑定结果（请求只带 raw name 时 = 默认值覆写，e2e QS-8/10 固化）
   - **path 参数豁免**（alias 只适用 query，决策-38 同款边界）
   - OpenAPI `parameter.name` = alias
3. **description（`_param_descs = "name=desc;..."`）**：OpenAPI parameter
   对象级 `"description"` + schema 级 `"description"`（上游双处）；
   path/header 循环同样支持
4. **请求侧归一化（`apply_query_extras`，dispatch 成功路径单点，在
   `match_error_map` 之前）**：
   - list：`values[key]` = 全部 occurrence 的 **CSV**（join）/ 缺失 →
     默认 CSV
   - 内部表示 = **CSV 字符串**（String-dict 世界；handler 读
     `query_<key>` 得 `"a,b"`，与 `_reads_headers`/`_param_types` 的 CSV
     约定一致）
   - alias 按 §3.2；path 参数跳过
5. **list 校验（`validate_list_values`，首败即停，上游同款）**：
   - 逐元素复用决策-38 `parse_typed_value`；**首个失败即停**（不继续
     收集 — FastAPI 0.141.1 实测行为）
   - loc 带数组下标：`["query","n",1]`；type = int_parsing /
     float_parsing / bool_parsing
   - 缺失 → `{"type":"missing","loc":["query","n"],"msg":"field required"}`
     （标量既有小写措辞，决策-38 e2e 固化；list 缺失复用同款）
6. **OpenAPI 生成扩展**：
   - `_openapi_param_schema(base, desc)`：list → `{"type":"array",
     "items":{"type":"t"},"default":[...]}`（**仅显式 `=` 时带 default**；
     `int[]=1,2` → `[1,2]` 数字裸值 / string 带引号）；enum → `+default`；
     scalar → `+default`；desc 非空 → schema 级 description
   - `_generate_parameter(..., desc)`：parameter 级 description
   - query 循环 `name` = alias（声明时）
7. **demo 路由**（`/enum` 之后）：
   - `/query-extra`（KIND_ECHO）：`tag:str[]=;nums:int[]=;level:
     str[low,medium,high]=high;limit:int=10` + aliases `level=lvl;
     limit=lmt` + descs 4 项
   - `/query-req`（KIND_ECHO）：`n:int[]` 必填 list（缺失 422 守护）
8. **依赖图（无环）**：`params_typed → params_query_extra →
   params_query`（params_query 不 import 本 ADR 任何模块）；唯一反向引用
   = `validate_list_values` 的**函数级** import（`from params_typed
   import parse_typed_value`）— 调用发生时两侧模块均已完全加载，实测
   可用（e2e 248/248 + 自测全绿）

### 3.5 文档化偏差（上游 vs 本实现）

1. **裸 `n: list[int]`（无 `Query()`）**：上游 = **body** 参数；本实现
   声明式 `T[]` 恒指 query-list（body 数组走决策-38 `_body_schema` 的
   `arr`/`T[]`）。
2. **CSV 逗号歧义**：list 值内部 CSV 表示 — 值本身含 `,` 时不可区分
   （与既有 CSV 声明同类已知取舍）。
3. **bool 措辞**：标量 bool 失败消息 = 决策-38 既有短消息（e2e 固化）；
   list 元素 bool 失败 = 上游完整 pydantic 措辞。
4. **`field required` 小写**：决策-38 既有（上游 `Field required`），
   e2e 固化；list missing 复用同款措辞。
5. **`http_server_final.mojo` 1173 行**：既有超阈值（HEAD 1148，God
   package 阈值 500）；本 ADR 仅 +25 行 dispatch 接线（2 处单点调用），
   新增逻辑全部在 `params_query_extra` 纯函数；既有超阈值瘦身 = 独立
   任务（beads 跟踪）。

## 4. 风险

| 风险 | 缓解 |
|------|------|
| 标量多值行为变化？ | **无**：标量保持 last-wins（Starlette `MultiDict.get`，上游同款）；`multi_values` 为新增字段，`values` 行为不变；QS-R1 回归守护（`/typed?count=1&count=2` → `"query_count": "2"`）+ 221 既有 e2e 全绿 |
| alias 覆写 raw name：客户端故意发 raw name 的场景 | 这正是 FastAPI 语义（`Query(alias)` — raw name 无绑定效力）；文档化（§3.5）+ QS-8/10 e2e 固化；handler 永远收到绑定值，行为确定 |
| CSV 逗号歧义（值含逗号） | 文档化（§3.5-2）；与既有 CSV 声明同类取舍；不影响 e2e/bench 场景 |
| `T[]` 语法与既有路由 spec 冲突 | 向后兼容：只影响「空括号」后缀的 spec，既有 spec 均为 scalar/enum（`T[a,b]`）；`parse_base` 空括号 → list 判据确定；221 既有 e2e 全绿 = 零回归 |
| 函数级 back-import（`validate_list_values` → params_typed） | 模块级无环（`params_typed → params_query_extra → params_query` 单向）；函数调用发生时两侧已完全加载；实测可用（e2e 248/248） |
| 性能（成功路径每请求 +list join/alias 覆写） | 纯字符串操作（单次拼接，无分配放大）；bench 6 场景 0 errors，get_root_10k_100c 37.3k req/s（历史区间 32.9k–43.9k 内；bench 客户端不发多值 query，热路径不变） |

## 5. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 单向：`params_typed → params_query_extra → params_query`（params_query 不 import 本 ADR 任何模块）；唯一反向引用是 `validate_list_values` 的**函数级** import（调用时两侧模块已加载，实测无环） |
| 2. 分层向下依赖 | ✅ 遵守 | query 参数解析/类型化 = 纯 Mojo 层（params_*.mojo，§3.3 依赖方向的应用/协议层）；本能力**不下沉 Rust bridge** — Rust 零改动（cargo test 335/0/4 不变、clippy 0 警告不变） |
| 3. God package 阈值 | ⚠️ 遵守（带说明） | params_query_extra **364**（新）/ params_typed **496**（431→496，<500）/ params_query **248**（199→248）/ openapi **480**（405→480）/ **http_server_final 1173（1148→1173，既有超阈值 — 本 ADR 仅 +25 行接线，未再膨胀主流程；瘦身 = 独立任务）** |
| 4. 主题域边界清晰 | ✅ 遵守 | params_query_extra 只管「声明表解析（`parse_table` 泛化）+ alias/desc 读写 + list/alias 请求侧归一化 + list 元素校验」纯函数（不碰 fd / 不读 env）；params_query 只管解析（新增 `multi_values` 字段 + `get_multi`）；openapi 只管 spec 生成；dispatch 只 2 处接线（`get_param_aliases` + `apply_query_extras` + 5-arg `validate_params_collect`） |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（无新 `extern "C"` 导出；Rust 代码零改动）；**零新增依赖**（纯 Mojo std，Cargo 无新增 crate）；ldd 实测仍仅 libc（**3,277,520 B = 3.12M**，vs 决策-42 3,228,368 B，+49 KB = 新模块 + demo 路由 + OpenAPI 扩展） |
| 6. 测试文件跟随 | ✅ 遵守 | 自测与生产代码同目录（本仓库约定：`.mojo` 尾部 `mojo run` 自测）：params_query +11 check / params_query_extra +26 check / params_typed +12 check（全部 `check()` 真断言，决策-38 assert-no-op 教训）；e2e **QS-1..13 + QS-R1 = 248/248 全绿**（+27） |

## 7. 验证方式

1. **单 binary 不变式**：`ldd build/fastapi_mojo` 仅 libc（**3,277,520 B =
   3.12M**，≤4.2M；vs 决策-42 3,228,368 B，+49 KB）；`env -i ./build/
   fastapi_mojo --port N` 干净启动（health 200，实测）。
2. **e2e 全量不回归**：221 → **248**（+27 QS 项）全绿：
   - QS-1 list 多值 `?tag=a&tag=b` → `"query_tag": "a,b"`
   - QS-2 单值 wrap `?tag=only` → `"only"`
   - QS-3 裸请求 → 空默认 `""` ×2（tag/nums）
   - QS-4 int list `?nums=1&nums=2` → `"1,2"`
   - QS-5/6 非法元素 → 422 + loc `["query","nums",1]` / `["query","nums",0]`
     + int_parsing（首败即停）
   - QS-7 alias 值 `?lvl=low` → `"query_level": "low"`
   - QS-8 raw name 忽略 `?level=low` → `"high"`（默认覆写）
   - QS-9/10 limit alias/raw：`?lmt=5` → `"5"` / `?limit=9` → `"10"`
   - QS-11 必填 list 缺失 → 422 `["query","n"]` + `"msg":"field required"`
   - QS-12 必填 list 正常 `?n=1&n=2` → `"1,2"`
   - QS-13a-d OpenAPI：`"name":"lmt"`（alias）/ `"type":"array"` +
     `"items":{"type":"string"}` / `"default":[]` / `"description":"Page size"`
   - QS-R1 标量 last-wins 回归 `/typed?count=1&count=2&verbose=true` →
     `"query_count": "2"`
3. **质量门禁**：`cargo clippy --release --tests -- -D warnings` **0 警告**
   （Rust 零改动）；`cargo test --release -- --test-threads=1` **335 passed
   / 0 failed / 4 ignored**（不变）；`mojo run` 自测 ×7（json /
   params_query / params_json / router / string_builder / params_typed /
   params_query_extra）全绿。
4. **性能**：bench 6 场景 **0 errors**；get_root_10k_100c **37,299 req/s**
   （历史区间 32.9k–43.9k 内；bench 客户端不发多值 query，热路径不变）。
