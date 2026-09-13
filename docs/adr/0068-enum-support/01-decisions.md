# ADR-0068: Enum Support (Decision-94)

**状态**：已接受
**日期**：2026-09-13
**决策**：94（FastAPI Enum 支持）
**关联**：AGENTS.md §6（**Decision-94**）、North Star（**FFI diff = 0**；纯 Mojo）

## 1. 背景

FastAPI 支持 Python 的 `Enum` 类型：

```python
from enum import Enum

class Direction(Enum):
    UP = "UP"
    DOWN = "DOWN"

class Item(BaseModel):
    direction: Direction
```

当 `direction` 不在枚举列表中时，FastAPI 自动返回 422 错误，包含允许值的列表。

当前实现缺少枚举验证的声明式公开面。

## 2. 目标

用声明式 `_enum_<name>` 键支持枚举约束，与上游 FastAPI 行为对齐；
验证失败时返回包含允许值列表的 422 错误；FFI diff=0。

## 3. 实现（纯 Mojo；**FFI diff = 0**）

1. **`enum_support.mojo`**：
   - `validate_enum_value` — 验证值是否在枚举列表中，否则抛 `EnumValidationError`
   - `get_allowed_values` — 返回允许的枚举值列表
   - `enum_error_to_422` — 转换为 FastAPI 422 错误格式
   - `EnumValidationError` — 自定义错误类，包含字段名、无效值、允许值列表

2. **验证器语法**：

   在 `handler.data` 中声明 `_enum_<field_name>` 键，值为 CSV 格式的枚举值列表：
   
   ```mojo
   handler.set_data("_enum_direction", "UP,DOWN,LEFT,RIGHT")
   handler.set_data("_enum_status", "active,inactive,pending")
   ```

   与现有的 `_param_types` 和 `_body_schema` 枚举声明语法一致：
   `field:type[value1,value2,value3]=default`

3. **demo 路由**：
   - `/enum/direction`：GET 参数枚举 (UP/DOWN/LEFT/RIGHT)
   - `/enum/status`：POST body 枚举 (active/inactive/pending)
   - `/enum/priority`：整数枚举 (1-5)

4. **接线**：`http_server_final.mojo` 中 `register_enum_routes(router)`

## 4. 已知偏差

| 偏差 | 上游行为 | 本实现 |
|------|---------|--------|
| Enum 类型 | Python class | 声明式 CSV 列表 |
| 验证错误消息 | 自动包含允许值 | 422 错误含 `"Input should be a,b,c"` |
| Enum 序列化 | 自动 | 手动声明 |

## 5. 六条架构隔离约束声明

| 约束 | 立场 |
|------|------|
| 1. 无循环依赖 | ✅ 叶模块，仅依赖 body_schema/router/handler |
| 2. 分层向下依赖 | ✅ 纯 Mojo 列表查询；零 FFI / 零 fd / 零 env |
| 3. God package 阈值 | ✅ 99 LOC < 500 |
| 4. 主题域边界清晰 | ✅ 枚举验证全收敛 |
| 5. bridge/adapter 显式化 | ✅ **FFI diff = 0** |
| 6. 测试文件跟随 | ✅ e2e 同目录；demo 同文件 |

## 6. 验收

- e2e 测试覆盖枚举验证
- binary 构建成功，130+ routes
- `ldd build/fastapi_mojo` 仅 libc.so.6
- 验证错误返回 422 且包含允许值列表
