# ADR-0011: FastAPI 安全 / 认证 — 任务清单

> Goal-0003 P0 落地。关联 `docs/goals/0003-fastapi-full-parity.md`。

| # | 任务 | 状态 | 证据 |
|---|------|------|------|
| 1 | ADR-0011 决策记录（候选方案 + 6 约束 + 验证方式） | ✅ 完成 | `docs/adr/0011-security-auth/01-decisions.md` |
| 2 | `security.mojo`：base64 解码（RFC 4648 标准 + URL-safe，掩码防 64-bit 溢出）+ `AuthResult` + `check_auth` 单一 dispatch（basic/bearer/apikey:header/query/cookie）+ UTF-8 边界安全 + `main()` 自测 | ✅ 完成 | `src/fastapi_mojo/security.mojo`（~360 LOC，< 500）；b64 向量 + 前缀 + 未声明/未知 spec 自测 |
| 3 | `http_server_final.mojo`：import + 4 demo 路由（/basic /secure /api /api-q）+ dispatch 钩子（F1 前 gate，`do_handler` flag，401 + WWW-Authenticate 短路，auth_* 注入）+ 响应发送加 auth_www 头 | ✅ 完成 | 4 路由 + ~30 行钩子；零 KIND 新增；零 FFI 新增（复用 extract_request_header） |
| 4 | e2e SEC-* 13 项：basic（无/错/对/第二用户）+ bearer（无/错/对）+ apikey header（无/错/对）+ apikey query（对/错），覆盖 401 + WWW-Authenticate + 200 + auth_* 注入 | ✅ 完成 | `scripts/e2e_test.sh` SEC-B1..B5 / SEC-N1..N3 / SEC-K1..K3 / SEC-Q1..Q2 |
| 5 | 质量门禁：clippy 0 警告 + cargo test 不回归 + e2e 全量不回归 + ldd 仅 libc + 体积 ≤4.2M | ✅ 完成 | clippy 0 警告；cargo test **299/0/4**；e2e **160/160**；ldd 仅 libc；binary 2.8M |

## 后续（P1/P2，不在本 ADR 范围）

- OAuth2（Password / Authorization Code / Client Credentials / Implicit）+ JWT 验证（P1）
- get_current_user 模式（基于 `_depends` + 安全依赖，复用决策-33 DI）
- 凭据哈希 / 环境变量注入 / bcrypt（生产就绪，P2）
- APIKey cookie 位置 + bearer scope / role 校验（P2）
- base64 解码改返回 bytes 列表（非 UTF-8 凭据，P2）
