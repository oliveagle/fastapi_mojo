# ADR-0010: Bridge 层语言终态 = Rust（Mojo + Rust only）— C 清零

- **日期**：2026-09-04
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行，拍板「一步到位，mojo + rust only」）
- **关联**：AGENTS.md §1/§3/§6（**决策-19**）、Goal-0001（Track C 定稿）、
  ADR-0001~0009（桥接层全部历史决策，**FFI 表面与架构分层不变**）、
  `http_bridge_final.c`（1774 LOC，含在途 KIND_RUN_CMD WIP）、`ws.c`（380）、`runtime_shim.c`（360）、
  `build_single.sh`（gcc 链接流程）、`.github/workflows/ci.yml`（rust toolchain）、
  `docs/adr/0003-single-binary-mechanism/`（loader 机制，shim 迁 Rust 后不变）

## 1. 背景

Phase 3 已达成「单 binary 零依赖」，但 bridge 层是 **C**（三份 `.c`，工作树 2514 LOC，含在途 KIND_RUN_CMD WIP +187）。
随功能演进（ADR-0006~0009），bridge 累积了协议/业务逻辑（CORS / 限流 / 静态 / 信号 /
WS 会话状态 / WS 帧解析），C 的脆弱性（buffer 越界、off-by-one、内存安全）在 WS 帧
解析这类字节级逻辑上风险突出（ADR-0009 合并帧尾块丢失 P0 即为字节级 bug）。

Goal-0001 Track C 首版主张「迁回 Mojo」，但 Mojo 1.0.0 标准库**无 socket / 网络 /
crypto / 静态运行时库**，这些能力迁回 Mojo 要么被阻塞、要么产出别扭的绕行实现。
用户定调：**一步到位，mojo + rust only** —— bridge 层由 Rust staticlib（C ABI）
替代全部 C，C 清零。

## 2. 候选方案

| 方案 | 描述 | 评估 |
|------|------|------|
| A. 迁回 Mojo | Track C 原方向：C 逻辑逐步 Mojo 化 | socket/poll/crypto/loader 被 Mojo 1.0.0 stdlib 缺口阻塞；WS 帧解析虽可做但 SHA-1/base64/掩码等需自研且无内存安全保证；仅对「业务逻辑」可行 |
| B. **Rust staticlib 替代全部 C（本 ADR）** | 三份 `.c` → `bridge.rs` / `ws.rs` / `shim.rs`；`extern "C"` 导出，FFI 表面不变；C 清零 | ✅ 用户定调；Rust ownership 覆盖 WS 帧解析/HTTP 解析的内存安全；loader（dlopen/embed）Rust 直接写；staticlib 静态链接保单 binary |
| C. 混合（ws.c → Rust，其余留 C） | 先吃最小果子 | 用户明确「不，一步到位」；混合态保留 C 违背终态 |

**决策：B** —— 终态 **Mojo + Rust only**，C 清零（决策-19）。

## 3. 决策

1. **语言终态**：bridge 层全部 Rust（staticlib），`src/` 下 `*.c` 清零；
   FFI 表面（~40 个 `extern "C"` 导出符号，含 `recv_and_parse` / `send_*` /
   `get_*_slice` / `ws_*` / `bridge_fail` / `init_workers` 等）与既有 C 完全一致。
2. **模块映射**：`http_bridge_final.c` → `bridge.rs`（按职责拆子模块：
   `socket.rs` / `parse.rs` / `cors.rs` / `ratelimit.rs` / `static.rs` / `signal.rs` /
   `ws_state.rs` / `worker.rs`）；`ws.c` → `ws.rs`；`runtime_shim.c` → `shim.rs`。
3. **Crate 形态**：`[lib] crate-type = ["staticlib"]`；`panic = "abort"`；
   `lto = true`；`codegen-units = 1`；`opt-level = "z"`；系统 allocator。
4. **依赖策略**：倾向**零第三方 crate**（SHA-1 / base64 / UTF-8 / 帧解析全手写）；
   若引入，仅限**纯 Rust、静态链接、无系统依赖** crate，且经 ADR 评审。
5. **链接机制**：`gcc -pie ... --whole-archive librust_bridge.a`；
   objcopy payload（Mojo 运行时 .so 与静态资源）用 `extern "C"` 引用
   `_binary_*_start/_end`；shim 构造函数经 `#[used] #[link_section = ".init_array"]`
   保证先于 Mojo 运行时符号（KGEN_CompilerRT_*）首次引用。
6. **工具链**：`rust-toolchain.toml` pin 固定版本；`build_single.sh` 与 CI
   自动检测/安装 rustup；构建顺序 `cargo build --release` → gcc 链接。

## 4. 后果与限制（文档化）

- **C 清零**：Phase 6 末 `find src -name '*.c'` = 0；`build_single.sh` 中
  `gcc -c` 三份 C 的步骤移除。
- **体积**：Rust staticlib 预期增幅 ≤ +2 MB（CI 断言）；`ldd` 仍仅 libc。
- **性能**：Rust poll 事件循环与 C 同构（无 async 运行时，仍是「单线程 poll +
  Mojo 串行 dispatch」），bench 不倒退 >10% 为门禁。
- **风险**：
  - 构造函数顺序：`.init_array` + `--whole-archive`，启动即验证（失败 = 段错误）；
  - 结构体布局：`#[repr(C)]` 与 C 头逐字段镜像（ws_parser_t / conn 状态等）；
  - 第三方 crate 若走动态链接破坏 ldd 不变量 → 一律禁止；
  - e2e 是行为等价唯一门禁：每迁移一文件，全量回归通过才切流。

## 5. 实测教训 / 预期验证点

- ADR-0009 教训「发一帧等一帧的 e2e 不能证明帧解析器正确」→ ws.rs 迁移后
  M17（合并帧）必须保留并回归。
- 用户态缓冲不产生 I/O 事件（ADR-0009 教训 2）→ `ws_pump_now` 语义在 bridge.rs
  中原样保留。
- 越界检查「写入前 + 未写」语义（ADR-0009 教训 3）→ Rust 侧用 bounds + Option
  显式表达，Rust 编译器静态保证。

## 6. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 方向单向不变：Mojo（`http_server_final`/`ws_session`）→ Rust bridge（`bridge.rs`/`shim.rs`）→ Rust 协议原语（`ws.rs`）→ OS。无回调上溯，Mojo 显式调用 bridge 入口 |
| 2. 分层向下依赖 | ✅ 遵守 | socket/poll/loader 是系统层（Rust）；协议/会话状态在 bridge（Rust）或 Mojo（业务分派）；帧字节语义在 `ws.rs`。与 C 版分层逐位对应，仅实现语言切换 |
| 3. God package 阈值 | ✅ 遵守 | `.mojo` 均 < 500 行（既有）；Rust 模块 < 500 行（建议）：`ws.rs` ~380 等价、`bridge.rs` 拆 8 子模块、`shim.rs` ~360；超限拆子模块并标注边界 |
| 4. 主题域边界清晰 | ✅ 遵守 | `ws.rs` 只含帧解析原语（不感知尾块/队列/连接）；`bridge.rs` 各子模块职责单一（socket/parse/cors/ratelimit/static/signal/ws_state/worker）；`shim.rs` 只做 loader；Mojo 侧路由/鉴权/分派不动 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | Rust 段全部经 `extern "C"` 导出表暴露（~40 符号与 C 版逐一对齐）；`#[repr(C)]` 结构体镜像；无 Rust 侧隐藏全局入口；迁移以「导出符号清单 diff = 0」为验收 |
| 6. 测试文件跟随 | ✅ 遵守 | e2e 79 项全量回归 + WS 节 M10-M21（含合并帧 M17）；Rust 模块单元测试（`cargo test`，与生产代码同目录）；bench 不倒退 >10% |

## 7. 验证方式

1. **导出符号清单 diff = 0**：迁移后 `nm build/librust_bridge.a | grep ' T '` 覆盖
   C 版全部非静态导出（~40 个），无缺失无多余。
2. **行为等价**：e2e 全量（HTTP + WS 节）不回归；WS 合并帧 M17 / 大帧 76800B /
   并发 3 项 / 鉴权 M20 重点回归。
3. **单 binary 不变式**：`ldd` 仅 libc；`env -i` 启动正常；启动即验证 shim
   构造函数顺序。
4. **体积门禁**：`du -h build/fastapi_mojo` 增幅 ≤ +2 MB（CI 断言）。
5. **性能**：`./benchmark.sh` 固定姿势，吞吐不倒退 >10%。
6. **C 清零**：`find src -name '*.c'` = 0；`build_single.sh` 无 `gcc -c` C 源入口。
