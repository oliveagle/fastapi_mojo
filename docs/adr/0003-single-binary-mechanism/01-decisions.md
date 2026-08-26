# ADR-0003: 单一二进制实现机制（运行时嵌入 + 暂存 + dlopen shim）

- **日期**：2026-08-26
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行）
- **关联**：ADR-0002（本标：单一 Binary 零依赖部署）、`build_single.sh`、`src/fastapi_mojo/runtime_shim.c`

## 1. 背景

ADR-0002 确立了本标：`mojo build` 产出单一可执行文件，运行时零外部依赖（除
libc/libm 等基础运行时）。Mojo 1.0.0 的现实约束：

1. 编译器运行时只以 3 个共享库分发（`libKGENCompilerRTShared.so` ~1.2MB、
   `libAsyncRTRuntimeGlobals.so` ~0.7MB、`libMSupportGlobals.so` ~0.05MB），
   **没有 `.a` 静态库**；
2. `mojo build` 无 `--static` 选项（1.0.0 公开/隐藏选项均已核实）；
3. `ld.lld -r` / `ld.bfd -r` 拒绝把完整链接的 .so 合并为 relocatable
   （"attempted static link of dynamic object"），.so 内含 JUMP_SLOT/RELATIVE
   重定位，无法静态再链接；
4. Linux 的 `dlopen` 要求文件在磁盘上，无法从内存加载。

因此"纯静态单一二进制"在当前工具链下不可行；需要一种**单文件部署**的替代机制。

## 2. 决策

### 2.1 选定方案：运行时嵌入 + 启动暂存 + dlopen 符号转发

1. **嵌入**：`objcopy -I binary` 将 3 个运行时 .so 作为原始数据嵌入可执行文件
   （payload ~2MB，最终 binary ~2.1MB）。
2. **编译链路**：`mojo build --emit object` 产出单一服务器对象 `server.o`；
   反汇编证实其对外依赖仅 **11 个 `KGEN_CompilerRT_*` C API 符号**
   （AlignedAlloc/Free、CPUDevice Get/GetOrCreate/Release、Globals
   GetOrCreate/Destroy、SetArgV、GetStackTrace、PrintStackTraceOnFault、
   fprintf）+ libc + C 桥接符号；其余 Mojo stdlib 代码（print/String 等）
   已内联进对象。
3. **暂存**：进程启动时（`main` 之前的 C constructor，`__attribute__((constructor))`）
   将 3 个 .so 写入私有临时目录（优先级 `/dev/shm` > `/tmp` > 可执行文件目录，
   `mkdtemp` 保证唯一且 0700 权限），`setenv(LD_LIBRARY_PATH)` 后
   `dlopen(RTLD_NOW|RTLD_GLOBAL)` KGEN 运行时，`dlsym` 绑定 11 个符号。
4. **转发**：可执行文件导出 11 个同名符号作为 6 寄存器通用转发函数
   （SysV x86-64：rdi/rsi/rdx/rcx/r8/r9；已逐一核对 server.o 中全部调用点，
   无调用点超过 2 个整型/指针参数，无浮点寄存器参数）。
5. **清理**：`atexit` 删除临时目录（SIGKILL 场景会残留，属可接受边界）。

### 2.2 否决的备选

| 备选 | 否决原因 |
|------|---------|
| 纯静态链接运行时 | 无 .a；.so 无法转 relocatable（JUMP_SLOT/RELATIVE 重定位） |
| 两阶段静态 launcher（extract+execve） | 可行但引入进程重 exec；单进程 shim 更贴合"一个 binary 一个进程" |
| deploy 目录附带 3 个 .so + RPATH=$ORIGIN | 违反本标"单一文件"（旧 deploy.sh 方案，保留为回退） |
| 等待 Mojo 上游 `--static` | 时间不可控；嵌入方案已达成部署体验目标 |

### 2.3 约束与边界

- 运行期仍依赖系统 **libc/libm/libstdc++/libgcc_s**（基础运行时，AGENTS.md §1 允许）。
  部署目标为任意带 glibc + libstdc++ 的 x86-64 Linux（debian/ubuntu/rhel/centos 开箱可用）。
- 临时目录为 dlopen 硬性要求，不是可选项；`/dev/shm` 不可用时自动回退。
- 11 个转发符号的 ABI 安全性依赖"调用点参数 ≤ 6 个整型寄存器"这一**已验证不变式**；
  若未来 `mojo build --emit object` 的调用约定变化，需重新核对（见 §5 验证方式）。

## 3. 决策结果

- `./build_single.sh` 为单一二进制构建入口，产出 `build/fastapi_mojo`。
- `./deploy.sh` 构建 + 自包含验证（ldd 无运行时 .so + `env -i` 冒烟 /health=200）。
- 本方案使 **Phase 3（单一 Binary 交付）在本工具链下达成**：scp 一个文件即可运行。

## 4. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 依赖方向单向：server.o → (11 符号) shim → dlopen → 运行时 .so → libc；shim 不反向引用 server.o |
| 2. 分层向下依赖 | ✅ 遵守 | Mojo 业务层 → C FFI 桥接（socket）→ 操作系统；运行时 shim 位于可执行文件内部，不引入上层依赖 |
| 3. God package 阈值 | ✅ 遵守 | 每个 .mojo < 500 行；C 文件：http_bridge_final.c 381 行、runtime_shim.c 232 行 |
| 4. 主题域边界清晰 | ✅ 遵守 | `src/fastapi_mojo/` 仅 FastAPI 域；shim 是部署机制而非业务逻辑，单独成文件并有文档 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | 两个显式 bridge：`http_bridge_final.c`（HTTP/socket）与 `runtime_shim.c`（运行时加载），均为唯一入口并在 ADR 中记录；无隐式符号依赖（11 个转发函数显式列出） |
| 6. 测试文件跟随 | ✅ 遵守 | 各模块 main() 自检 + `test_all.mojo` 集成测试与生产代码同目录；deploy.sh 内含冒烟验证 |

## 5. 验证方式

1. `ldd build/fastapi_mojo` 仅显示 libc / vdso / ld-linux（无 Mojo 运行时 .so）。
2. `env -i ./build/fastapi_mojo` 启动成功且 `/health` 返回 200。
3. 全端点冒烟（GET/POST/DELETE/HEAD/OPTIONS/404/403/413/400/UTF-8）通过。
4. `hey -n 2000 -c 16` 无性能退化（~20k rps GET）。
5. 进程退出后临时目录被清理（`ls /dev/shm /tmp | grep fastapi_mojo_rt` 为空）。
