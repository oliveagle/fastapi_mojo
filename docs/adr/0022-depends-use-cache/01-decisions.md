# ADR-0022: Depends use_cache — 每请求 memo 表（cached / nocache 双语义）

- **日期**：2026-09-10
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行，Goal-0003 P2 矩阵 #9 落地）
- **关联**：AGENTS.md §3.2/§6（**决策-47**）、Goal-0003（P2：Depends use_cache，
  对标矩阵行 #9）、North Star（单 binary 零依赖 — **FFI diff = 0，零新 crate**）、
  ADR-0013（决策-33 依赖注入 foundation：`_depends` 声明 + 递归派发 + 前缀注入 +
  环检测）、ADR-0016（决策-37 APIRouter 基础依赖合并 — 本 ADR 对称扩展
  `_depends_nocache`）、FastAPI 0.141.1 + starlette 1.6.0（/tmp/fm_probe 逐条
  probe，本 ADR §1 证据）

## 1. 背景

Goal-0003 P2 矩阵 #9：`Depends` **缓存**（`use_cache`）。决策-33 已落地
Depends 的声明式等价（`_depends` CSV + 递归派发 + `depname_outputkey` 前缀
注入 + visited 环检测），但其 diamond 语义为「各路径独立解析」（同一共享
依赖被多个路径引用时**每次重派发**）— 与上游默认行为相悖。

**实测证据（FastAPI 0.141.1 + starlette 1.6.0，/tmp/fm_probe p9 逐条 probe；
in-process 计数观测 dep 调用次数）**：

- **P9-1**（菱形，默认 `use_cache=True`）：`dep_a=Depends(shared)` +
  route 直接 `Depends(shared)` → **`calls==1`**（shared 只解析一次）；
  两引用拿到**同一值**（`a="A(s11)"`, `s="s11"`）。第二请求再派发
  （**每请求作用域**，计数跨请求累加 = 每请求 +1）。
- **P9-2**（route 引用 `use_cache=False`，嵌套引用默认）：
  `dep_b=Depends(shared)` + route `Depends(shared, use_cache=False)` →
  **`calls==2`**；值不同：嵌套引用 `B(s21)`，直接 nocache 引用 `s22`
  （**解析序**：dep_b 先（嵌套 shared 第一次派发），route 参数后
  （nocache 第二次派发））。
- **P9-3**（**嵌套** `use_cache=False`，route 引用默认）：
  `dep_c=Depends(shared, use_cache=False)` + route `Depends(shared)` →
  **`calls==1`** 且 `c="C(s31)"`, `s="s31"` 同值 — **nocache 派发的结果
  同样写入缓存**（写入无条件；use_cache=False 仅跳过**查找**），route
  的 cached 引用直接复用（不重新派发）。
- **P9-4**（双 nocache）：两个 `use_cache=False` 引用 → `calls==2`
  （各自重新派发）。
- **P9-5**（三重菱形）：`dep_e`/`dep_f` 都 `Depends(shared)` + route 也
  `Depends(shared)` → **`calls==1`**，三引用同值。

**约束（Mojo 1.0.0 + North Star）**：Mojo 无闭包 → 声明式
（`handler.data`，决策-33/37/43/45/46 同模式）；缓存状态 = **每请求**
Mojo 纯数据结构（并行 List，`MpParts` 同模式 — struct-of-Lists 可拷贝）；
零 FFI（dispatch_dep/resolve_depends 本就是纯 Mojo 递归）。

## 2. 候选方案

- **A. per-dependant 闭包缓存**（上游实现：`solve_dependencies` 的
  sub_dependant 缓存表）：❌ Mojo 1.0.0 无闭包，dependant = 声明式
  （dep 名 + 引用位点 + nocache 标志），缓存表需要可拷贝容器。
- **B. 每请求 memo 表（per-name，append-only）**（✅ 采纳）：`DepCache`
  结构（dep 名 → 输出扁平 List）随请求创建，递归派发时传入；cached 引用
  命中 = 重注入不派发；nocache 引用恒派发 + 追加新条（P9-3 覆写语义 =
  find 取最新条）；`calls(name)` = memo 条数。纯 Mojo，零 FFI，与
  ADR-0020/0021 分层一致（应用/协议层）。
- **C. 维持现状（各路径独立解析）**：❌ 与上游默认（`use_cache=True`
  P9-1/P9-5）相悖 — 共享依赖重派发 = 语义倒退（副作用型依赖重复执行 /
  值不一致）。

## 3. 决策

1. **`dep_cache.mojo`（106 行，纯数据层，零 FFI）**：`DepCache`（parallel
   Lists：`names`（每次实际派发一条，可重复）/ `kstarts` + `kcounts`（输出
   在 `okeys`/`ovals` 的扁平范围））+ `find`（**最新条**优先，P9-3）/
   `append`（新派发入库）/ `inject`（memo 重注入，与首次注入完全一致）/
   `calls_of`（memo 条数 = 实际派发次数，P9 计数语义）/ `unique_names`
   （首现序去重）+ `inject_dep_calls`（`_dep_calls=true` 声明门控 →
   `params[<name>_calls]`）。
2. **dispatch 接线（`http_server_final` 1238 → 1332，+94）**：
   - `dispatch_dep` 新增 `nocache: Bool` + `mut cache: DepCache` 参数：
     子依赖递归同时处理 `_depends`（cached）与 `_depends_nocache`
     （nocache）；memo 查找（cached only）→ 命中重注入返回；未命中或
     nocache → 派发 + **入库**（cached = 首次存；nocache = 恒追加，
     P9-3 覆写）+ 注入。visited 环检测优先于 memo（自身祖先恒跳过）。
   - `resolve_depends` 新增 `mut cache: DepCache` + 第二循环
     `_depends_nocache`（**解析序：先 `_depends` CSV 序，后
     `_depends_nocache` CSV 序** — 确定性，§3.5-4）。
   - dispatch 调用点：请求内创建单一 `DepCache`（每请求作用域，P9-1
     第二请求语义）+ `inject_dep_calls`（未声明 `_dep_calls` = no-op，
     既有 `/di`、`/api/*` 响应体零变化）。
3. **声明式表面**：
   - `_depends`（既有）= **默认 cached**（upstream `use_cache=True`）—
     **语义收紧**：diamond/三重菱形共享 dep 从「各路径独立派发」（
     决策-33）收紧为每请求 1 次（P9-1/P9-5 对齐）。
   - `_depends_nocache`（**新增**）= `use_cache=False`（`;` 分隔，同
     `_depends` 语法）：路由级与 dep 嵌套级均可用（P9-2/P9-3/P9-4）。
   - `_dep_calls="true"`（**新增，observability 超集**）：响应注入
     `<dep>_calls` = 本请求实际派发次数（§3.5-2）。
4. **APIRouter 对称扩展（`router.mojo` 495 行，≤500）**：`base_deps_nocache`
   字段 + `set_base_deps_nocache` + `include_router(deps_nc=)` 参数 —
   include 时与路由 `_depends_nocache` 合并（`;`-CSV，与 `_depends`/
   `_tags` 三层合并同构；WS 路由同步合并）。基础依赖本身恒 cached
   引用（§3.5-3）。
5. **demo 路由**：`dc_tick`（base dep）/ `dc_auth`（`_depends=dc_tick`
   默认 cached）/ `dc_auth2`（`_depends_nocache=dc_tick` 嵌套 nocache）
   + `/di-cache`（`_depends=dc_auth;dc_tick` 菱形 + `_dep_calls=true`）/
   `/di-nocache`（`_depends_nocache=dc_auth;dc_tick`）/ `/di-mix`
   （`_depends=dc_auth2;dc_tick`）。

## 3.5 文档化偏差

1. **per-name memo vs per-dependant**：上游缓存键 = dependant（函数 +
   参数位点）；本实现 dep 无 per-reference 参数面（声明式 = dep 名，
   函数身份 = 名）→ **per-name memo 是声明式等价**（同一 dep 名的所有
   引用共享 memo，与上游无参 `Depends(fn)` 行为一致 — P9-1..P9-5 全部
   对齐）。
2. **`_dep_calls` observability 超集**：上游无 dep 调用计数面（测试靠
   in-process 闭包计数）；本实现以声明式 `<dep>_calls` 注入暴露（默认
   关闭 = 零输出，既有响应面不变）— 生产化诊断超集（同 `_file_ops`
   方向）。
3. **APIRouter 基础依赖恒 cached 引用**：上游 router 级 `dependencies=[
   Depends(fn, use_cache=False)]` 可 per-dependant 声明 nocache；本实现
   基础依赖合并进 `_depends`（cached）— `base_deps_nocache` 字段存在但
   include 入口无独立 nocache 参数（`deps_nc` 为 include 调用方参数，
   非 router 声明面）— 窄化，P2 剩余面。
4. **解析序 = 先 `_depends` CSV 序，后 `_depends_nocache` CSV 序**
   （确定性）：上游 = 路由参数声明序（两列表交错）；同请求内 dep 集合
   相同时结果等价（memo 值同源），仅**首次派发先后**（副作用时序）
   理论上可异 — 文档化。

## 4. 风险

| 风险 | 影响 | 应对 |
|------|------|------|
| diamond 语义收紧（决策-33 各路径独立 → 每请求 1 次） | 既有 `/di`、`/api/*` 行为 | 静态 dep 输出幂等（值不变 — DC-6/DC-7 回归 + AR-3/4 e2e 全量绿）；副作用型 dep 从「重派发」变「单派发」= **向上游对齐**（方向正确） |
| memo 表 per-request 内存 | 每请求 O(deps × outputs) | deps/outputs 均个位数（声明式）；请求结束即释放（dispatch 局部变量） |
| P9-3 覆写语义实现复杂度（append-only + find 最新条） | 误注入旧值 | find 恒取最后一条；selftest 16 check（P9-1/2/3 映射）+ e2e DC-1..5 守护 |
| `_depends` / `_depends_nocache` 双声明同名 dep | 歧义 | 解析序确定（cached 先）；cached 引用先入库，后续 nocache 重派发追加（P9-2 等价）— 文档化 |
| http_server_final 1238 → 1332 膨胀 | 既有超阈值 | +94 = 声明式接线（dispatch_dep/resolve_depends 语义扩展 + demo 路由）；纯数据层拆出 dep_cache(106) — 同 ADR-0018/0019/0020/0021 立场 |

## 5. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 单向：`dep_cache -> {}`（纯 std 数据结构，零 import）；`http_server_final -> dep_cache`（新，无反向）；`router.mojo` 零新依赖（`_depends_nocache` = 纯 data key）；依赖图零环 |
| 2. 分层向下依赖 | ✅ 遵守 | memo/注入/解析序 = 纯 Mojo 应用/协议层；**FFI diff = 0**（零新增 `extern "C"`；Rust 零改动 — cargo 354/0/4 保持不变）；零新 crate |
| 3. God package 阈值 | ⚠️ 遵守（带说明） | dep_cache **106**（新，<500）/ dep_cache_selftest **76**（新）/ router **495**（465→495，≤500）/ **http_server_final 1332**（1238→1332，既有超阈值 — +94 声明式接线，同 ADR-0018/0019/0020/0021 立场） |
| 4. 主题域边界清晰 | ✅ 遵守 | dep_cache 只管 memo 数据结构 + `_dep_calls` 注入（无路由/HTTP 知识）；dispatch_dep/resolve_depends = DI 派发语义（http_server_final 既有域）；router = include 合并（决策-37 域对称扩展）；query/path/form 域不碰 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0**；`ldd` 实测仅 libc；binary **3,556,048 B (3.4M)** ≤4.2M（vs 决策-46 +25 KB）；`find src -name '*.c'` = 0 保持 |
| 6. 测试文件跟随 | ✅ 遵守 | `dep_cache_selftest.mojo`（76 行，16 check：P9-1 菱形命中 / P9-3 覆写最新条 / 多 dep 独立 memo / 双前缀注入 / `_dep_calls` 门控 / 混合计数 / unique_names）与 dep_cache.mojo 同目录，JIT 可达；e2e 新增 **DC-1..DC-7**（菱形 1 次 / 值同源性 / route nocache 2 次 / 嵌套 nocache 1 次（P9-3）/ 每请求作用域 / `/di` 回归 / APIRouter 基础依赖回归） |

## 7. 验证方式

1. **单 binary 不变式**：`ldd build/fastapi_mojo` 仅 libc（实测）；binary
   **3,556,048 B (3.4M)** ≤4.2M（决策-46 基线 3,531,472 B + 25 KB）；
   `env -i` 干净启动（health 200 + `/di-cache` 200 + `dc_tick_calls=1`，
   实测）。
2. **Rust 质量门禁**：`cargo test --release -- --test-threads=1`
   **354/0/4**（FFI 零改动，保持不变）；`cargo clippy --release --tests
   -- -D warnings` 双 crate **0 警告**。
3. **e2e 全量**：312 → **319/319**（+7 DC）全绿（实测 0 FAIL）：
   - DC-1 菱形默认 cached → dc_tick 仅派发 1 次（P9-1）
   - DC-2 菱形双引用值同源于 memo（P9-1 value identity）
   - DC-3 route nocache 引用 → dc_tick 2 次（P9-2）
   - DC-4 嵌套 nocache + 直接 cached → cached 复用 nocache 入库结果 =
     1 次（**P9-3**）
   - DC-5 每请求 cache 作用域（第二请求独立计数）
   - DC-6 `/di`（决策-33）回归：未声明 `_dep_calls` → 零泄漏
   - DC-7 APIRouter 基础依赖（AR-3）回归：`api_env_*` 保持 + 零泄漏
4. **Mojo 自检**：`dep_cache_selftest.mojo` 16 check 全绿（JIT）；
   既有 self-test 零回归。
5. **性能**：bench 6 场景 **0 errors**，get_root_10k_100c **34.8k req/s**
   （历史区间 32.9k–43.9k 内，无回归 — memo 开销 = 个位数 List 操作，
   非热路径）；ldd/env-i/C-zero 全保持。
