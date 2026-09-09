# ADR-0016: response_model 精化 — exclude / exclude_none（FastAPI/Pydantic 语义，声明式）

- **日期**：2026-09-09
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行，Goal-0003 P2 矩阵 #11 落地）
- **关联**：AGENTS.md §6（**决策-41**）、Goal-0003（矩阵 #11 response_model
  exclude/include/none 精化）、决策-35（_response_model include 基础版）、
  FastAPI `response_model_exclude` / `response_model_exclude_none` 语义

## 1. 背景

决策-35 落地 response_model 的 **include** 语义（`_response_model` CSV =
模型字段，只返回它们）。FastAPI 完整 API 面还包括：
- `exclude={"a"}` / `response_model_exclude` —— 从**模型字段**中剔除
- `exclude_none=True` / `response_model_exclude_none` —— 剔除值为 None 的字段

矩阵 #11（🟡 基础字段过滤）的剩余缺口。

FastAPI 语义关键点（本 ADR 逐条对齐）：
1. include/exclude/exclude_none **作用于 response_model 的字段**；
   **无 response_model 时全部 no-op**（FastAPI 序列化路径：无 model 时
   响应原样返回，这三个参数不生效）— 本 ADR 严格保留该行为。
2. exclude 与 include 可组合：`response_model=X, exclude={"a"}` = X 的字段
   减 a。
3. exclude_none 剔除 **None**（不是字符串 "null"）— 本项目扁平 string dict
   的等价物：空串（handler 未赋值的 null 表达）与 `__nested__:null`
   （真实 JSON null 的直传形式）。

## 2. 候选方案

| 方案 | 描述 | 评估 |
|------|------|------|
| A. 独立 dispatch 分支处理 exclude/exclude_none | 主循环加 if/else 链 | ❌ 违反「新增行为 = 数据 + 单点」约束（决策-33/34/35/36/37/38/40 同一模式）；dispatch 分支膨胀 |
| B. **单一 helper `response_model_body(handler, resp_data) -> String`（本 ADR）** | 全部过滤逻辑收敛到 request_response.mojo 一个函数（include → exclude → exclude_none 序）；dispatch 只调一行；声明式 = handler.data 三个 key | ✅ dispatch 净减行（原 14 行 inline 块 → 1 行调用）；无模型时 helper 内部 no-op（FastAPI 对齐）；纯 Mojo 字符串/字典操作，零 syscall 零 FFI |
| C. Rust bridge 侧过滤 | body JSON 在 bridge 解析后过滤 | ❌ FFI 面要加导出；JSON 结构解析（我们有 object body 解析）重走一遍；过滤是 FastAPI 语义层职责，归 Mojo |

**决策：B** —— 单一 helper（决策-41）。

## 3. 决策

1. **声明式 API（handler.data）**：
   - `_response_model` = `"f1,f2,..."` —— include（决策-35 既有，语义不变）
   - `_response_exclude` = `"a,b"` —— 从模型字段剔除（**仅当 _response_model
     声明时生效**，FastAPI 对齐）
   - `_response_exclude_none` = `"true"` —— 剔除 null 值字段（同上仅模型时
     生效）
2. **应用序**：include → exclude → exclude_none（FastAPI 序列化序：先定
   模型字段集，再 exclude，再 exclude_none）。
3. **null 等价**：`_is_null_value(v)` = `v == ""` 或 `v.startswith(
   "__nested__:null")`（真实 JSON null）。普通值 `"null"` 是 JSON 字符串，
   不算 null（与 FastAPI「只去 None」对齐）。
4. **dispatch**：原 inline 14 行过滤块 → `var body = response_model_body(
   route_result.handler, resp_data)`（单点；无模型时 helper 直接
   `json_serialize_dict(resp_data)`，与旧行为字节一致）。
5. **demo + e2e**：`/profile`（模型 4 字段 + exclude secret）/
   `/profile-none`（exclude_none 剔除空 note）/ `/profile-keep`（对照保留）/
   `/rm-noop`（KIND_ECHO + 无模型，exclude/exclude_none no-op 回归）。

## 4. 风险

| 风险 | 缓解 |
|------|------|
| `/profile` demo 模型从 2 字段改 4 字段，既有 RM-1/RM-2 断言变化 | RM-1/RM-2 更新为「模型字段含 email + exclude 后无 secret」，断言语义不变（模型内字段返回 / 剔除字段不返回 / meta 不返回）；RM-3/RM-4 原样通过 |
| exclude_none 把合法空串误删 | 仅当显式声明 `_response_exclude_none=true` 才删（默认关，对照 demo /profile-keep + RM-6 回归守护） |
| 无模型 no-op 语义与直觉冲突（用户声明 exclude 期望生效） | **FastAPI 上游同款行为**（无 response_model 时参数无效）；/rm-noop demo + RM-7 e2e 固化该语义 |
| request_response.mojo 超 500 行 | 215 LOC（+~48），阈值内 |

## 5. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | `http_server_final` → `request_response`（helper）→ `json` / `handler` / `string_builder`；单向，无回调上溯 |
| 2. 分层向下依赖 | ✅ 遵守 | 过滤 = 响应序列化语义层（纯 Mojo 字典/字符串操作，零 syscall 零 FFI）；body 字节仍经既有 `send_simple_response*` FFI 出口（FFI 面不变） |
| 3. God package 阈值 | ✅ 遵守 | request_response.mojo **215** / http_server_final.mojo **1148**（净 -1 行：inline 14 行块 → 1 行调用，+demo 路由）均符合既有边界 |
| 4. 主题域边界清晰 | ✅ 遵守 | response_model 三参数同属「响应序列化」主题，收敛在 request_response.mojo 单 helper（不再散落 dispatch）；`_csv_contains`/`_is_null_value` 私有（`_` 前缀）不外泄 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（Rust bridge 零改动，cargo 323/0/4 复跑不变）；声明式 = handler.data，与决策-33/34/35/36/38/40 同一模式 |
| 6. 测试文件跟随 | ✅ 遵守 | e2e **RM-1..RM-7 = 213/213 全绿**（RM-1/2 更新语义 + RM-5/6/7 新增：exclude / exclude_none / no-op 回归）；demo 路由 4 个（/profile 更新 + /profile-none + /profile-keep + /rm-noop） |

## 7. 验证方式

1. **单 binary 不变式**：ldd 仅 libc；3.1M（≤4.2M）；env -i 干净启动。
2. **e2e**：210 → **213**（+RM-5/6/7；RM-1/2 语义更新）全绿：
   - RM-1 模型字段返回（name/age/email）；RM-2 exclude 剔除 secret；
   - RM-3 meta 不返回；RM-4 无模型原样（回归）
   - RM-5 exclude_none 剔除空字段；RM-6 对照（默认保留空字段）
   - RM-7 无模型时 exclude/exclude_none no-op（FastAPI 对齐）
3. **质量门禁**：cargo test **323/0/4**（Rust 零改动复跑）；clippy
   `-D warnings` 0 警告；bench 6 场景 0 errors（Mojo 侧改动仅 dispatch
   一行调用 + 新 demo 路由，热路径无新增分支）；ldd 仅 libc；env -i 干净
   启动；无孤儿进程。
