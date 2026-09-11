# ADR-0040: UPX 复评 — 仍是 opt-in 部署产物，不用 readelf 替代 ldd

**状态**：已接受
**日期**：2026-09-12
**决策**：65（Goal-0003 packaging / `upx-revisit` bead）

## 1. 背景

决策-30 在 v0.5.1 的 2,850,696 B 产物上评估过 UPX：`-9` 可压到 1,011,584 B，
但压缩后 `ldd` 输出 `not a dynamic executable`，因此当时将其限定为手动部署选项。
`upx-revisit` bead 有两个新问题：

1. 决策-64 引入 rustls/RustCrypto 后，正常交付 binary 已变为 **4,954,416 B**，
   需要重新测量体积、冷启动与稳态性能；
2. 需要验证 CI 是否能用 `readelf` 或其它旁路保留 North Star 依赖证明。

## 2. 目标

1. 使用 UPX 5.2.1 与 Ubuntu 4.2.2 复测当前 TLS 版产物的压缩率；
2. 测量 `-9` 与 `--brute` 的冷启动、RSS 与 e2e/benchmark 影响；
3. 判定 `readelf` 是否能在 UPX 副本上替代 `ldd` 作为依赖门禁；
4. 收敛 `compress_upx.sh` 的安全边界：不覆盖未压缩证明、可恢复、压缩后可运行。

## 3. 测量

### 3.1 体积与冷启动（10 次 ready 采样）

| 产物 | 体积 | 占原体积 | 冷启动均值 | 最小/最大 | 健康后 RSS |
|---|---:|---:|---:|---:|---:|
| 未压缩（当前 HEAD） | 4,954,416 B | 100% | 12.1 ms | 12 / 13 ms | 18,896.4 kB |
| UPX 5.2.1 `-9` | 1,718,420 B | 34.68% | 31.6 ms | 28 / 34 ms | 18,888.0 kB |
| UPX 5.2.1 `--brute` | 1,527,172 B | 30.82% | 95.0 ms | 85 / 104 ms | 与上两者持平 |

- `-9` 减少 **3,235,996 B（-65.32%）**，一次性冷启动成本约 **+19.5 ms**；
- `--brute` 相比 `-9` 仅再省 **191,248 B（约 187 KiB）**，冷启动却额外增加
  约 63 ms；对长期运行的 server 不划算，**拒绝**；
- Ubuntu UPX 4.2.2 的 `-9` 为 1,913,288 B，`--brute` 为 1,527,728 B；结论一致，
  推荐 CI/人工验证固定使用 UPX 5.2.1 `-9`；
- RSS 基本不变，说明解压后的 Mojo runtime 映射与未压缩路径一致。

### 3.2 功能与稳态性能

UPX 5.2.1 `-9` 副本实测：

- `upx -t`：OK；
- e2e：**521 / 521 passed**（HTTP、WS、multipart、HTTP/2、TLS 等全部现有检查）；
- benchmark：6 场景 **0 errors**；`get_root_10k_100c = 30,120.48 req/s`
  （决策-64 未压缩记录为 32,372.94 req/s，差异约 7%；其余多场景在噪声区间内，
  且 50k/500c、100k/200c、/hello 高于本轮未压缩记录。UPX 只影响冷启动解包，
  稳态代码路径不应存在系统性热点，故记录为单机噪声而非回归结论）；
- `env -i PATH=/usr/bin:/bin` 启动：`/health` 200，SIGTERM 后无孤儿进程。

### 3.3 `ldd` / `readelf` 事实

| 检查 | 未压缩 | UPX 压缩后 |
|---|---|---|
| `file` | dynamically linked PIE + interpreter | statically linked, no section header |
| `ldd` | libc / loader / vdso | `not a dynamic executable` |
| `readelf -l` | 有 `INTERP` | 无 `INTERP` |
| `readelf -d` | `NEEDED libc.so.6`、loader | 无 `NEEDED` 记录 |

UPX 把原 ELF 打包进自解压 stub，可见 ELF 头属于 stub 而不是原始程序；
`readelf` 无法“恢复”被打包前的动态依赖元数据。因此：

> **`readelf` 不是等价的 North Star 依赖证明，不能替代未压缩 binary 上的 `ldd` 门禁。**

若未来发布压缩交付物，唯一安全的 CI 旁路是**双产物顺序验证**：

1. 正常 `./build_single.sh` 产物先通过现有 `ldd` 断言；
2. 复制该已验证产物并执行 UPX；
3. 对压缩副本单独执行 `upx -t` 与 `env -i /health` smoke；
4. CI 的主交付物与 North Star 门禁仍必须是未压缩 binary。

本轮不把 UPX 加进默认 CI：它会增加一个与功能无关的可选包装面，而不能提高
依赖闭包证明强度。现有 CI 继续守护未压缩交付物。

## 4. 决策

1. `./build_single.sh` 输出仍是唯一默认交付物；UPX **不进入默认构建、不替换 CI 主产物**。
2. UPX 继续作为磁盘紧张场景的 **opt-in 手动部署副本**，模式固定为 **`-9`**；
   `--brute` 因启动成本被拒绝。
3. `compress_upx.sh` 收敛为安全包装器：
   - 压缩前强制确认输入是 dynamically linked PIE，且 `ldd` 仅有允许依赖；
   - 先压缩到唯一临时文件，再执行 `upx -t`；
   - 默认用 `env -i` 启动压缩候选并检查 `/health` 200（`--no-smoke` 可跳过）；
   - 只有全部通过后才把原文件保存为 `build/fastapi_mojo.pre-upx` 并替换产物；
   - `--restore` 恢复未压缩文件并重新执行依赖检查；
   - 已存在备份时拒绝二次压缩，避免丢失唯一依赖证明。
4. 文档明确压缩副本的边界：`ldd` / `readelf` 均不能证明其依赖闭包；North Star
   证明属于未压缩构建产物，压缩副本只做完整性与运行 smoke。

## 5. 备选方案对比

| 方案 | 结论 | 理由 |
|---|---|---|
| UPX 进入默认构建 | 拒绝 | 主产物失去 `ldd` 门禁，启动变慢，默认场景收益不成立 |
| CI 用 `readelf` 检查压缩副本 | 拒绝 | stub 无 `INTERP`/`NEEDED`，不证明原 ELF 依赖 |
| CI 双产物验证 | 保留为未来发布选项 | 可行，但只验证包装副本，不能替代主产物 ldd；当前无发布需求 |
| `--brute` | 拒绝 | 仅再省约 187 KiB，冷启动均值约 95 ms |
| 未压缩 + strip（现状） | 接受 | 保留动态依赖元数据与 CI 门禁；5 MiB 仍在预算内 |

## 6. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|---|---|---|
| 1. 无循环依赖 | ✅ 遵守 | UPX 只作用于构建后的单个文件；不引入源码模块、构建目标或运行时依赖图 |
| 2. 分层向下依赖 | ✅ 遵守 | packaging 位于 build/deploy 层，位于 binary 产出之后；不改 Mojo 应用、协议层或 Rust bridge |
| 3. God package 阈值 | ✅ 遵守 | 变更收敛在一个 shell 包装器（<500 行）；无生产 Rust/Mojo 模块膨胀 |
| 4. 主题域边界清晰 | ✅ 遵守 | 只做可选部署压缩与恢复；不混入 FastAPI 语义、TLS、HTTP/2 或 benchmark 逻辑 |
| 5. bridge/adapter 显式化 | ✅ 遵守 | **FFI diff = 0 / Rust bridge diff = 0 / Mojo runtime diff = 0**；UPX 是外部打包工具，不进入交付运行时 |
| 6. 测试文件跟随 | ✅ 遵守 | 无新增生产模块；验证使用现有 e2e、`upx -t`、脚本内 `env -i` health smoke 与最终未压缩 ldd 断言 |

## 7. 验收（2026-09-12）

- 压缩实验：4,954,416 → **1,718,420 B**（UPX 5.2.1 `-9`，-65.32%）；`upx -t` OK
- e2e：UPX 副本 **521 / 521 passed**
- benchmark：6 场景 **0 errors**（get_root_10k_100c = 30,120.48 req/s）
- clean env：`env -i PATH=/usr/bin:/bin` 启动 UPX 副本，`/health` 200，退出后无孤儿
- 脚本验证：`bash -n` + compress smoke + restore 成功；已有 `.pre-upx` 时二次压缩被显式拒绝已实测
- 恢复后：正常 binary **4,954,416 B**，`ldd` 仅 libc / loader / vdso
- 交付面保持：`find src -name '*.c'` = 0；交付面 Python = 0；孤儿 server = 0
- 未修改运行时代码，Rust bridge / fmtool test 与 clippy 门禁按 HEAD 复跑确认

## 8. 实现

- `compress_upx.sh`：输入 ldd 预检、UPX `-9` 临时产物、`upx -t`、`env -i` health
  smoke、原子替换、`.pre-upx` 备份保护与 `--restore`
- `docs/adr/0040-upx-revisit/01-decisions.md`：本决策
- `AGENTS.md` / `docs/goals/0001-fastapi-parity-and-de-python-toolchain.md` /
  `docs/goals/0003-fastapi-full-parity.md` / `README.md`：决策-65 与可选部署边界记录
