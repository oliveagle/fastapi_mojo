# ADR-0066: `jsonable_encoder`（ADR-0064 §8 #5 兑现）

**状态**：已接受
**日期**：2026-09-13
**决策**：92（兑现 ADR-0064 §8 #5：`fastapi.encoders.jsonable_encoder` 等价实现）
**关联**：AGENTS.md §6（**决策-92**）、ADR-0064 §8 #5、决策-38（`_body_schema` spec）、
North Star（**FFI diff = 0**；zero Rust / zero C；纯 Mojo）、上游
`fastapi 0.141.1` / `pydantic 2.13.4`

## 1. 背景（缺口）

ADR-0064 §8 列出 P1/P2 缺口 #5：`fastapi.encoders.jsonable_encoder`。

上游 FastAPI 的 `jsonable_encoder(obj)` 将任意对象转换为 JSON 兼容形式：
- Pydantic model → `model_dump(mode="json")`
- dataclass → `dataclasses.asdict`
- Enum → `.value`
- datetime/UUID/Decimal/IP → 字符串
- dict/list/set → 递归编码
- include/exclude/exclude_none/exclude_defaults 过滤
- sqlalchemy_safe：剔除 `_sa*` 前缀键
- custom_encoder：用户自定义类型→值转换器

本实现此前无此公开面。

## 2. 目标

用声明式（`handler.data`）补全 `jsonable_encoder` 公开面，wire 行为对齐上游；
既有 dispatch / response_model / e2e 零回归。

## 3. 实现（纯 Mojo；**FFI diff = 0**）

1. **`jsonable_encoder.mojo`**（252 LOC < 500 God package 阈值）：
   - `jsonable_encode_value(v, exclude_none, custom_encoders)` — 单值编码器
   - `jsonable_encode_dict(data, include, exclude, exclude_none, exclude_defaults, sqlalchemy_safe, custom_encoders)` — 字典编码器
   - `jsonable_encode_list(items, exclude_none, custom_encoders)` — 列表编码器
   - `jsonable_encoder(data, ...)` — 主入口（对齐上游签名）
   - 类型启发式：`_is_datetime_str` / `_is_uuid_str` / `_is_ip_str` / `_is_decimal_str`

2. **`register_jsonable_encoder_routes(router)`**：demo 路由
   - `/encoder/basic`：展示 exclude_none + sqlalchemy_safe
   - `/encoder/exclude`：展示 exclude CSV

3. **接线**：`http_server_final.mojo` 中 `register_jsonable_encoder_routes(router)`

## 4. 测试

- **e2e**：864/864 全绿（决策-92 后新增 JE-1..JE-2a 过滤断言）
- **手工验证**：`/encoder/basic` 返回 200，`_sa_internal` 键被过滤
- **P0 修复（2026-09-13）**：`_is_*_str` 类型谓词曾用 `s[byte=i]`（多字节串续字节位置触发 codepoint-boundary assert → SIGABRT，e2e 685 连锁炸）；改 `s.as_bytes()[i]` + ASCII 守卫后多字节 path/值安全，e2e 回 858 passed

## 5. 已知偏差

| 偏差 | 上游行为 | 本实现 | 影响 |
|------|---------|--------|------|
| Pydantic model → dict | `model_dump(mode="json")` | Dict 已是 JSON 兼容 | Mojo 无 Pydantic；Dict[String,String] 等价 |
| dataclass → dict | `dataclasses.asdict` | 同上 | Mojo 无 dataclass |
| Enum → .value | 自动提取 | 手动声明 | 声明式等价 |
| custom_encoder 闭包 | Python callable | Dict[String,String] 映射 | Mojo 无闭包（ADR-0014 硬边界） |

## 6. 六条架构隔离约束声明

| 约束 | 立场 | 说明 |
|------|------|------|
| 1. 无循环依赖 | ✅ | 叶模块，无新增 import |
| 2. 分层向下依赖 | ✅ | 纯 Mojo 字典/列表操作；零 FFI / 零 fd / 零 env |
| 3. God package 阈值 | ✅ | 252 LOC < 500 |
| 4. 主题域边界清晰 | ✅ | jsonable_encoder 全收敛在单文件 |
| 5. bridge/adapter 显式化 | ✅ | **FFI diff = 0** |
| 6. 测试文件跟随 | ✅ | e2e 同目录；demo 同文件 |

## 7. 验收

- e2e **864/864** 全绿（决策-92 后新增 JE-1..JE-2a 过滤断言）
- bridge `cargo test --release -- --test-threads=1` 通过
- `ldd build/fastapi_mojo` 仅 libc.so.6
- binary 构建成功，127 routes

## 8. 后续工作

1. 将 `jsonable_encoder` 集成到 dispatch 主循环（当前作为公开 API 提供）
2. 添加 e2e 用例覆盖 include/exclude/exclude_none 路径
3. custom_encoder 完整闭包等价（Mojo 闭包支持后）
