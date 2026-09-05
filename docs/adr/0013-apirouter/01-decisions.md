# ADR-0013: APIRouter — prefix/tags/dependencies + include_router（include 时合并，dispatch 零改动）

- **日期**：2026-09-05
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行，Goal-0003 P1 落地）
- **关联**：AGENTS.md §3.2/§6（**决策-37**）、Goal-0003（T-P1b APIRouter）、
  ADR-0004（路由注册「用户代码 = 数据」扩展点模式）、F-DI 依赖注入（决策-33，
  `_depends` 机制复用）、F4 OpenAPI（决策-24，tags 输出 + path 分组修复）、
  FastAPI `APIRouter` / `app.include_router`（语义对标）

## 1. 背景

FastAPI 的 **APIRouter** 是 Goal-0003 矩阵**第 18 项**（❌ 缺失）：

```python
items_api = APIRouter(prefix="/api/items", tags=["items"], dependencies=[get_api_env])
@items_api.get("/")
@items_api.get("/{item_id}")
app.include_router(items_api)            # 或 include_router(items_api, prefix="/v1")
```

- `APIRouter` = 独立路由表 + 自身 `prefix` / `tags` / `dependencies`
- `include_router(sub, prefix=, tags=, dependencies=)` = 把 sub 的全部路由合并进
  主 app，**两个层级的 prefix/tags/deps 与路由自身标注逐层合并**
- 典型用途：按业务域拆模块、按 API 版本挂前缀（`/v1`）、域级共享依赖与文档 tag

约束（Mojo 1.0.0 + North Star）：
- Mojo 无闭包 / 无嵌套对象运行时 → APIRouter 无法是「请求时递归查找的路由树」，
  只能是**注册期数据结构**
- dispatch 主循环是核心路径（决策-33 后已按 handler.data 元数据工作），
  不应为 APIRouter 引入新的请求期查找成本

## 2. 候选方案

| 方案 | 描述 | 评估 |
|------|------|------|
| A. 请求期路由树 | 保留 APIRouter 对象，dispatch 时递归遍历 app→sub→route | ❌ 每请求 O(树深) 查找；Mojo 无对象嵌套引用（struct 含 List[Handler] 非 ImplicitlyCopyable，传递即复制）；核心 dispatch 膨胀 |
| B. **include 时合并（本 ADR）** | `include_router` 在**注册期**把 sub 的每条路由展平进主表：path 前缀拼接 + tags/`_depends` 合并进 `handler.data`；dispatch 完全无感（决策-33 `_depends` 机制 + 既有 pattern 匹配自动生效） | ✅ dispatch 零改动（核心路径不变）；与 ADR-0004「路由 = 数据」一致；Mojo 无新语言约束（纯字符串拼接 + List append）；WS 路由同语义 |
| C. 配置文件驱动 | APIRouter 描述放 JSON/YAML，启动时展平 | ❌ 需解析器（json.mojo 仅序列化）；路由逻辑（handler 选择）无法表达为纯数据 |

**决策：B** —— include 时展平合并，dispatch 零改动（决策-37）。

## 3. 决策

1. **API 面（Router 扩展，router.mojo）**：
   - 字段：`prefix` / `tags`（CSV，',' 分隔）/ `base_deps`（';' 分隔，
     与 `_depends` 同格式）+ `set_prefix` / `set_tags` / `set_base_deps`
   - `include_router(mut self, sub: Router, prefix="", tags="", deps="") raises`
     — 把 sub 的全部 HTTP 路由 + WS 路由 + 依赖表合并进 self
2. **合并语义（三层，与 FastAPI 一致）**：
   - **path** = `_join_path(include_prefix, sub.prefix, route.path)`
   - **tags** = `include.tags` `,` `sub.tags` `,` 路由自身 `_tags`（CSV 追加）
   - **deps** = `include.deps` `;` `sub.base_deps` `;` 路由自身 `_depends`
     （';'-CSV 追加，决策-33 机制，dispatch 自动注入 `<depname>_<key>`）
   - 顺序即 FastAPI 的 `include_router args → router args → route args` 叠加序；
     依赖**解析**仍在 dispatch（`find_handler_by_name`），故 include 时同步合并
     sub 的 `dependencies` 表（KIND_DEPENDENCY handlers）
3. **`_join_path(prefix, sub_prefix, path)` 规范化**：
   - 各段前导 `/` 保证；不产生 `//`；结果尾 `/` 去除（`/` 除外）
   - 路由 `/`（根路由）+ prefix → prefix 本身（`/api/items` + `/` → `/api/items`）
   - 边界向量：`("","","/x")→"/x"`、`("/","", "/x")→"/x"`、
     `("/a/","","/x")→"/a/x"`、`("a","b","/x")→"/a/b/x"`
4. **WS 路由同语义**：`sub.ws_routes` 同 prefix/tags/deps 合并（WS 无 tags 消费
   点，仅 deps 生效 + 路径前缀）
5. **OpenAPI 配套（openapi.mojo）**：
   - 操作级 `"tags":["a","b"]`（`handler.data["_tags"]` CSV 拆分 + trim +
     json_escape）
   - **path 分组**：同一 path 的多 method 合并进单个 JSON key（`"/items":{GET,POST}`）
     —— 修复**既有**重复 key 产生非法 JSON 的 bug（`/items` GET+POST 原本输出
     两个 `"/items":` key；Python `json.load` 静默取最后一个，属潜在静默错误）
6. **demo（http_server_final.mojo，注册期 3 个 APIRouter）**：
   - `items_api`（prefix `/api/items` + tags `items` + base dep `api_env`）→
     `/api/items` + `/api/items/{item_id}`
   - `v1_api`（include 级 prefix `/v1` + tags `v1`）→ `/v1/ping`
   - `ws_api`（prefix `/api/ws`）→ `/api/ws/echo`（WS 端到端）
   - 路由用 **KIND_ECHO**（非 KIND_STATIC）：ECHO 过滤 `_` 前缀内部字段，
     避免 `_tags`/`_depends` 泄漏进响应体（KIND_STATIC 全量 dump 为既有行为，
     不在本 ADR 改动；`__nested__:` 前缀机制同样以 `_` 开头，naive 过滤会破坏它）
7. **文件布局（扩展点模式，核心零 dispatch 改动）**：
   - `router.mojo`：字段/setter/`include_router`/`_join_path`/`_merge_csv` +
     `main()` 自测（10 断言组）
   - `openapi.mojo`：tags 输出 + path 分组（`_generate_operation` +
     `generate_openapi` 局部改动）
   - `http_server_final.mojo`：demo 路由（~40 行，注册区）
   - **dispatch 主循环零改动**（`_depends` 注入在决策-33 已就位）

## 4. 边界与已知限制

- **include 即消费**：`include_router` 后 sub 被展平，主表持有合并后的路由副本
  （Mojo `Route` 非 ImplicitlyCopyable，构造器内复制 handler）。不支持「同一 sub
  多次 include 到不同 prefix」之外的动态再挂载；多次 include 同一 sub 会重复
  注册（路径冲突时先注册者胜出，匹配 = 线性首中，与 FastAPI 相同）。
- **无 per-route `dependencies=` 参数**（FastAPI 单路由级 deps 用 `handler.data
  ["_depends"]` 表达，等效能力已在决策-33 覆盖）。
- **tags 不跨层去重**：三层合并纯 CSV 追加，重复 tag 名会重复出现（OpenAPI 消费
  端不敏感，文档美观问题）。
- **`_tags` 仅 OpenAPI 消费**：不产生响应/路由行为（与 FastAPI 一致：tags 是
  文档分组）。
- **KIND_STATIC 响应体泄漏 `_` 前缀字段**：既有行为（见 §3.6 注），demo 用
  KIND_ECHO 规避；是否修 KIND_STATIC 属独立决策（`__nested__:` 前缀约束使
  naive 过滤不可行）。

## 5. 风险

| 风险 | 缓解 |
|------|------|
| 路径冲突（两 sub 同 path） | 首注册胜出（线性首中，FastAPI 同语义）；OpenAPI 分组后冲突在文档中可见 |
| 依赖名未注册（`_depends` 引用缺失 name） | 决策-33 既有行为：resolve 时跳过（不 500）；include 时同步合并依赖表降低遗漏概率 |
| tags CSV 注入畸形字符 | json_escape 在 OpenAPI 输出侧统一处理 |
| 既有 OpenAPI 重复 key bug 暴露下游 | 修复为**更严格**（分组后 key 唯一），`/items` 现输出合法 JSON（GET+POST 同 key）；e2e AR-7 断言 key 计数 = 1 |

## 6. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 单向：`http_server_final`（注册 demo）→ `router`（Router.include_router/_join_path）→ `handler`（KIND 常量）。router 不 import http_server_final/openapi；openapi 只读 `router.routes`（数据向下）；无回调上溯 |
| 2. 分层向下依赖 | ✅ 遵守 | prefix/tags/deps 合并 = **注册期字符串处理**（纯 Mojo，零 syscall、零 FFI）；依赖解析仍走决策-33 既有 dispatch 路径；本 ADR **零新 FFI 导出**（与 ADR-0010 分层一致：网络/syscall 面不变） |
| 3. God package 阈值 | ✅ 遵守 | `router.mojo` 472 LOC（< 500，含自测）；`openapi.mojo` 251 LOC（< 500）；`http_server_final.mojo` +40 行 demo（1100 LOC，既有超阈值文件，本 ADR 未引入新逻辑膨胀——dispatch 零改动） |
| 4. 主题域边界清晰 | ✅ 遵守 | `router.mojo` 只做路由表 + include 合并（不含序列化/OpenAPI/WS 协议）；OpenAPI tags/分组是 openapi.mojo 的**文档生成**职责（读 `handler.data`，不反向写）；`_join_path`/`_merge_csv` 是 module 私有 helper，不跨主题 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**（无新 extern "C" 导出，无 bridge 改动）；全部合并逻辑在 Mojo 注册期完成，Rust bridge 对 APIRouter 无感知（路径/元数据经既有 dispatch 路径） |
| 6. 测试文件跟随 | ✅ 遵守 | Mojo：`router.mojo` `main()` 自测（prefix/pattern/边界/三层合并/WS/`_join_path` 6 向量）；e2e **AR-1..AR-8 = 180/180 全绿**（12 项：状态码/body/依赖注入/tags/OpenAPI 分组/WS 端到端）；`cargo clippy --release --tests -D warnings` **0 警告**；`cargo test --release -- --test-threads=1` **307 passed / 0 failed / 4 ignored**（Rust 侧零改动，无新单测） |

## 7. 验证方式

1. **单 binary 不变式**：`ldd build/fastapi_mojo` 仅 libc；体积 2.9M（≤4.2M）。
2. **e2e 全量不回归**：168 → **180**（+12 AR 项）全绿，含：
   - AR-1a/1b：`/api/items/42` 200 + `item_id=42`（prefix + pattern）
   - AR-3a/3b：`api_env_env=api` / `api_env_ver=v1`（base dep 注入）
   - AR-2：`/api/items` 200（根路由归一）
   - AR-4a/4b：`/v1/ping` 200 + `pong=v1`（include 级 prefix）
   - AR-5：`/items` 200（无前缀回归）
   - AR-6a/6b：OpenAPI `"tags":["items"]` / `"tags":["v1"]`
   - AR-7：OpenAPI `"/items":` key 计数 = 1（分组，修复重复 key）
   - AR-8：WS `/api/ws/echo` 端到端 echo OK（fmtool wsbench）
3. **质量门禁**：`cargo clippy --release --tests -- -D warnings` **0 警告**；
   `cargo test --release -- --test-threads=1` **307 passed / 0 failed / 4 ignored**。
4. **Mojo 自测**：`mojo run src/fastapi_mojo/router.mojo` — APIRouter 断言组
   全过（含 `_join_path` 6 边界向量 + WS include + 三层合并）。
5. **性能**：bench 6 场景 0 errors，get_root_10k_100c ≈ 37.9k req/s
   （历史区间 32.9k–43.9k 内，无回归；注册期展平不影响请求期路径）。
