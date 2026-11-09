# FastAPI 上游追踪（upstream tracking）

> 追踪 fastapi_mojo 与 FastAPI 上游（fastapi/fastapi, PyPI fastapi）的语义差距。
> 对标基线：**FastAPI 0.141.1**（+ pydantic 2.13.5 + starlette 1.6.0，AGENTS.md §2 注）。
> 上游最新：**0.162.2**（2026-11-07）。本文档记录 0.141.1 → 0.162.2 每个功能性改动
> 的 fastapi_mojo 状态：✅ 已覆盖 / 🔶 部分 / ❌ 缺失 / ➖ 不适用（N/A）。
> 更新规则：每个差距项闭环时必须更新本文档 + AGENTS.md 决策链 + e2e 计数。

## 差距总览

| 主题 | 行数 | ✅ | 🔶 | ❌ | ➖ |
|------|------|----|----|----|----|
| A. Form/参数模型语义 | 14 | 3 | 3 | 6 | 2 |
| B. AliasChoices/参数元数据 | 11 | 0 | 3 | 8 | 0 |
| C. 序列化/body/文件 | 4 | 1 | 1 | 1 | 1 |
| D. WebSocket 安全依赖 | 1 | 0 | 0 | 1 | 0 |
| E. OpenTelemetry | 5 | 0 | 1 | 0 | 4 |
| F. 框架杂项 | 6 | 1 | 0 | 1 | 4 |
| **合计** | **41** | **5** | **8** | **17** | **11** |

> 注：0.142.0 有 2 条 Refactors（docs 前端），0.143.4 为可选依赖升级（httpx2），
> 0.147.0 被 0.162.0 反转，不计入差距。功能改动合计 45 条；下表按行计 41 项
> （0.156.4 两个 PR 分列），按 release 去重 40 项。计数以各节表格行为准。

## A. Form / 参数模型语义（2026-10-19~23 上游主线）

| 版本 | 改动 | fastapi_mojo 状态 | 说明 |
|------|------|--------------------|------|
| 0.162.0 | 省略 boolean form 字段 → 声明默认值 / missing 错误（反转 0.147.0 的 False 推断） | ✅ | form_params 现状：bool 无默认缺失 → 422 "Field required"；有默认 → 默认值。与终态语义一致 |
| 0.161.0 | 组合 form 模型 union | ❌ | fastapi_mojo 无模型 union 概念（声明式 _form_types 单表） |
| 0.161.1 | standalone nullable form unions OpenAPI schema 修复 | ❌ | 同上（union 缺席） |
| 0.160.0 | 每个参数模型的 extra 配置应用到兄弟字段（breaking） | ❌ | pydantic extra 语义；fastapi_mojo 无模型 Config extra |
| 0.159.1 | 可选 form 模型 union | ➖ | union 缺席；可选模型 = "=" 已支持（单字段级） |
| 0.159.0 | 可选 query/header/cookie 参数模型 | 🔶 | 单字段可选已支持（"=" 默认）；"可选整个模型"概念缺席 |
| 0.158.2 | 可选 form 模型 | 🔶 | 同上 |
| 0.158.1 | OpenAPI 保留 form media types 修复 | ❌ | multipart OpenAPI 已有（决策-46）；urlencoded media type 保留需核对 |
| 0.158.0 | 组合 form 模型 | ❌ | 模型组合概念缺席 |
| 0.157.0 | 组合 query/header/cookie 参数模型 | ❌ | 同上 |
| 0.149.0 | form 模型空标量值视为缺失（breaking） | ✅ | form_params.validate_form_collect/apply_form_extras：空串视为缺失 → 有默认用默认 / 无默认 422 missing（列表内空串保留）。e2e FM-21~25 |
| 0.150.0 | 未选择浏览器文件输入视为缺失（breaking） | ✅ | file_params：filename=="" 且 size==0 的 part 视为缺失 — validate_file_collect 不进 occurrence、apply_file_extras 不注入 file_/form_ 键、list count/list_json 过滤该 part。e2e MP-24/25 |
| 0.148.0 | 请求参数和模型默认值处理修复 | 🔶 | 单字段默认已支持；模型级默认需核对 |
| 0.147.0 | 省略 bool form 字段 → False | ➖ | 已被 0.162.0 反转，跳过 |

## B. AliasChoices / 参数元数据

| 版本 | 改动 | fastapi_mojo 状态 | 说明 |
|------|------|--------------------|------|
| 0.154.0 | 请求参数支持 Pydantic validation options | ❌ | 已有参数约束（ADR-0029/0033）；Pydantic 直传选项缺席 |
| 0.156.0 | 保留 Field() 属性在请求参数中 | 🔶 | 声明式 _param_descs 等近似；Field 级元数据保留需核对 |
| 0.156.1 | 请求选项省略时保留字段元数据 | 🔶 | 同上 |
| 0.156.2 | 推断请求参数中保留字段元数据 | 🔶 | 同上 |
| 0.156.3 | AliasChoices 支持（query/header/cookie） | ❌ | **待实现**：当前单 alias（_param_aliases/_form_aliases）；AliasChoices=多候选别名按序尝试 |
| 0.156.4 | AliasChoices（named JSON body） | ❌ | 同上 |
| 0.156.4 | AliasChoices（form 模型） | ❌ | 同上 |
| 0.156.5 | AliasChoices（path 参数） | ❌ | 同上 |
| 0.156.6 | 模型 alias 设置应用于 query/header/cookie | ❌ | 模型级 alias 缺席 |
| 0.156.7 | form/file AliasChoices 校验错误位置修复 | ❌ | 随 AliasChoices 一起 |
| 0.152.0 | header model 校验错误报告 HTTP header 名 | ❌ | **待实现**：header 校验 loc 用 header 名（当前 _reads_headers 无 422 校验） |

## C. 序列化 / body / 文件

| 版本 | 改动 | fastapi_mojo 状态 | 说明 |
|------|------|--------------------|------|
| 0.143.3 | JSONL/SSE 流非有限 float 序列化修复 | ➖ | SSE data 为声明式 raw（不 JSON 编码）；响应面 inf/nan 已 500（决策-90） |
| 0.151.0 | 区分 JSON null 与省略的 body 值（breaking） | 🔶 | 决策-63 json input canon 已处理 body 422 input；null vs omitted 语义需核对 |
| 0.143.5 | byte 文件列表参数空值处理修复 | ✅ | 决策-102：multipart 快照新增 `has_filenames` 维度（区分"无 filename 属性的文本 part"与"filename=\"\" 的未选文件"）→ bytes 列表保留全部文本 part（含空文本 → size 0），未选文件输入仍被 0.150.0 过滤；标量 presence 由**最后一个** occurrence 决定（上游 `values.get(alias)`）；urlencoded CT 下 File/bytes 字段收 form 值（上游 `File` 继承 `Form` → `is_body_form`）→ `files=` 保留为 1 个空元素（count=1, size=0，PR #9383），缺失则字段缺席，字符串送 file 基础字段 → 422 value_error。e2e MP-26~31 |
| 0.156.8 | 上传文件转 bytes 保留文件位置 | ❌ | Rust bridge file_protocol；文件位置保留需评估 |

## D. WebSocket 安全依赖

| 版本 | 改动 | fastapi_mojo 状态 | 说明 |
|------|------|--------------------|------|
| 0.144.0 | WebSocket 支持 security dependencies | ❌ | WS 升级 token 鉴权已有（ADR-0009）；security deps（OAuth2 等）在 WS 上缺席 |

## E. OpenTelemetry

| 版本 | 改动 | fastapi_mojo 状态 | 说明 |
|------|------|--------------------|------|
| 0.142.0 | 原生 OpenTelemetry 支持 | 🔶 | fastapi_mojo 有 OTEL in-memory traces（ADR-0037，简化版） |
| 0.142.2 | OTel 自动配置失败允许启动 | ➖ | 无自动配置逻辑 |
| 0.142.3 | 缓存 OTel tracers 保 warning 去重 | ➖ | 同上 |
| 0.142.4 | 隔离排除请求的 telemetry | ➖ | 同上 |
| 0.143.0 | OTel exporter 自动设置需 opt-in | ➖ | 无 exporter 设置 |

## F. 框架杂项

| 版本 | 改动 | fastapi_mojo 状态 | 说明 |
|------|------|--------------------|------|
| 0.142.1 | included routers 重复 endpoint 包装修复 | ✅ | APIRouter include_router（决策-37）无重复包装问题（声明式表） |
| 0.143.1 | iter_route_contexts() included route metadata | ➖ | fastapi_mojo 无此 API |
| 0.143.2 | blocking frontend fallback file checks | ❌ | 静态文件 fallback 同步检查需评估 |
| 0.145.0 | 移除 openapi_prefix / FastAPI **extra | ➖ | fastapi_mojo 无此概念 |
| 0.146.0 | 弃用 FastAPI root_path 参数 | ➖ | 无 root_path |
| 0.155.0 | 移除请求参数 **extra | ➖ | 无 **extra |

## 优先实现队列（bead 化）

1. ~~**0.149.0** form 空标量视为缺失~~ ✅ 已完成（e2e FM-21~25）
2. ~~**0.150.0** 未选择文件输入视为缺失~~ ✅ 已完成（e2e MP-24/25，含 list count/list_json 过滤）
3. ~~**0.143.5** byte 文件列表空值（file_params.mojo）~~ ✅ 已完成（决策-102，e2e MP-26~31）
4. **0.152.0** header model 校验错误报告 header 名（header_params）
5. **0.156.3~7** AliasChoices 多候选别名（params/form/body 全类型）
6. **0.151.0** JSON null vs omitted body（json_canon）
7. **0.158.1** OpenAPI form media types 保留
8. **0.144.0** WS security dependencies
9. **0.156.8** 上传文件位置保留（Rust bridge）
10. 模型组合/可选/union 系列（0.157~0.161，需新增声明语法）

---
*更新：2026-11-10（0.149.0/0.150.0/0.143.5 闭环；合计 41 行 ✅=5 / 🔶=8 / ❌=17 / ➖=11，计数与各节表格对齐）。数据源：fastapi/fastapi GitHub releases（0.141.1→0.162.2，44 releases）。*
