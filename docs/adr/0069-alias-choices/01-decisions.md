# ADR-0069: AliasChoices 多候选别名（Decision-104）

**状态**：已接受
**日期**：2026-11-10
**决策**：104（FastAPI 上游 0.156.3~0.156.7 AliasChoices，PR #16555/#16557/#16559/#16560/#16562/#16564）
**关联**：AGENTS.md §6（**已决策-104**）、docs/upstream-tracking.md B 主题、North Star（**FFI diff = 0**；纯 Mojo）

## 1. 背景

FastAPI 上游 0.156.3 起引入 `AliasChoices`（Pydantic `validation_alias`），一个参数可以声明
**多个候选别名**，请求里命中任一即可：

```python
from pydantic import AliasChoices

@app.get("/items")
def read(q: int = Query(validation_alias=AliasChoices("alpha", "beta"))): ...
# ?alpha=7 或 ?beta=9 都能取到 q；两个都没给 -> 422 missing, loc = ("query", "alpha")
```

fastapi_mojo 此前只有**单别名**语义（`_param_aliases` / `_form_aliases` / `_file_aliases` /
`_reads_headers` 的 `name=alias`），无法表达「多候选任选其一」。

上游语义（已从 fastapi master 源码与上游测试逐行核实）：

| 维度 | 上游行为 |
|------|---------|
| 候选顺序 | 按**声明序**尝试；请求中**首个出现**者生效（与 query 串出现顺序无关） |
| 全不命中 | 用**第一个候选**（作 loc / 默认来源） |
| 候选名 | **字面名**（header 候选也不做 `_` → `-` 转换） |
| 422 loc | **命中的候选**；query/header/body/path 各自 in_ 前缀 |
| path 面 | 候选里**首个出现在路由 path 模板名**者生效；OpenAPI path 参数名 = 路由模板名 |
| form/file 面 | 首个**值非空**的候选命中（空串视为缺失）；422 loc 报**别名**而非 Python 字段名 |
| OpenAPI | 参数名 / schema 属性名 = **候选首个** |

## 2. 目标

以声明式语法支持六面（query / header / path / form / file / body）的多候选别名，
loc / OpenAPI 名称与上游逐条对齐；**不新增声明面**（沿用既有 alias 表，值多候选化）；
**FFI diff = 0**（纯 Mojo）。

## 3. 决策

1. **alias 表的**值**用 `|` 分隔多候选** —— 单候选写法与既有语义完全等价（零回归）：

   | 声明面 | 声明键 | 示例 |
   |--------|--------|------|
   | query / path | `_param_aliases` | `q=alpha\|beta` |
   | header | `_reads_headers` | `x_alt=alt-one\|alt_two` |
   | form | `_form_aliases` | `field=f-one\|f-two` |
   | file | `_file_aliases` | `doc=doc-a\|doc-b` |
   | body | `_body_aliases`（**本轮新增**） | `name=full_name\|nickname` |

2. **新增叶子模块 `src/fastapi_mojo/alias_choices.mojo`（106 LOC）** —— 纯函数底座，
   零 FFI / 零 fd / 零 env，被六面按需 import：
   `alias_candidates` / `candidates_for` / `pick_in_dict`（query·body：在场即命中）/
   `pick_in_multi`（form·file：标量空串视为缺席继续试下一个，list 有 occurrence 即命中）/
   `pick_path_name`（path：首个出现在模板名集合的候选）/ `first_candidate`（都没命中时）。

3. **各面接线**：query/path（`params_typed.mojo` + `params_query_extra.mojo`，新增
   `apply_path_aliases` 做声明名再绑定）、header（`header_params.mojo` 新增
   `header_entry_parts` / `header_candidates`；候选为**字面**名）、form/file
   （`form_params.mojo` / `file_params.mojo` / `file_form_values.mojo` / `file_form_check.mojo`）、
   body（`body_validate.mojo` 新增 `get_body_aliases`）。

4. **OpenAPI 同步**：`openapi.mojo` / `openapi_schemas.mojo` / `openapi_multipart.mojo` /
   `form_params.mojo` —— 参数名 / 属性名取**候选首个**。

5. **顺带修掉 2 个实测暴露的 OpenAPI 真 bug**：
   - urlencoded form schema 属性名仍用声明名（multipart 面早已用别名）→ 统一为候选首个；
   - 声明名 ≠ 模板名时，OpenAPI **同时出现同名 path 参数与 query 参数** → query 分支的
     is_path 判定改为「候选命中模板名」；path 分支的类型/描述/约束改取自**声明名**。

## 4. 已知偏差

| 偏差 | 上游行为 | 本实现 |
|------|---------|--------|
| 候选写法 | `AliasChoices("a", "b")` | 声明表值 `name=a\|b` |
| 模型级 alias（0.156.6） | 模型 config 的 alias 应用到 query/header/cookie | 无模型概念 → 不适用（归 0.157.0 项） |
| cookie 参数 | 支持 AliasChoices | 无 cookie 参数概念 → 不适用 |
| BaseModel 作 query/header 参数 | 支持 | 扁平声明式 → 不适用 |

## 5. 六条架构隔离约束声明

| 约束 | 立场 |
|------|------|
| 1. 无循环依赖 | ✅ `alias_choices` 为零依赖叶子模块；form_params / body_validate / params_query_extra / header_params 单向 import 它 |
| 2. 分层向下依赖 | ✅ 纯 Mojo 纯函数（无 FFI / 无 fd / 无 env）；**FFI diff = 0** |
| 3. God package 阈值 | ✅ 新模块 106 LOC < 500；未新增超限文件（存量 6 个超限文件另立拆分待办） |
| 4. 主题域边界清晰 | ✅ 多候选解析收敛到单模块；六面只做「取候选 → 命中 → 注入」 |
| 5. bridge/adapter 显式化 | ✅ **无新增 bridge 符号**；`bridge/ffi.rs` 导出数保持 87 |
| 6. 测试文件跟随 | ✅ e2e（`scripts/e2e_test.sh` AL-* 26 项）与生产代码同仓库；demo 路由同文件（`http_server_final.mojo`） |

## 6. 验收

- e2e **917/917** 全绿（新增 AL-* 26 项；另按上游更正 4 处存量 file 别名 loc 断言）
- bridge `cargo test --release -- --test-threads=1`：530 passed / 2 failed / 4 ignored
  （2 failed 为 pristine HEAD 既有且**本机环境依赖**：`/bin/sh`=bash、`TMPDIR=$HOME/tmp`；
  `TMPDIR=/tmp` 下转绿，CI 环境不受影响）
- 双 crate `clippy --release --tests -D warnings` = 0 警告
- `ldd build/fastapi_mojo` 仅 libc.so.6 + libm.so.6；`env -i` 干净启动 health 200
- binary 5,418,424 B (5.17 MiB) ≤ 6M 预算；`find src -name '*.c'` = 0；`*.py` = 0；无 `.venv`
