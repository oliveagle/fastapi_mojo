# ADR-0067: Custom Field Validators (Decision-93)

**状态**：已接受
**日期**：2026-09-13
**决策**：93（兑现 FastAPI @validator 等价：自定义字段验证器）
**关联**：AGENTS.md §6（**Decision-93**）、North Star（**FFI diff = 0**；纯 Mojo）

## 1. 背景（缺口）

FastAPI 的 `@validator` 允许在 Pydantic 模型上定义自定义验证逻辑：

```python
class Item(BaseModel):
    price: float
    @validator('price')
    def price_must_be_positive(cls, v):
        if v < 0:
            raise ValueError('must be positive')
        return v
```

当前实现已有基础约束（gt/lt/pattern/length），但缺少声明式自定义验证器面，
无法实现复杂的字段级验证（如邮箱格式、URL 验证、UUID 格式检查等）。

## 2. 目标

用声明式 `_validators_<field>` 补全 `@validator` 自定义验证器公开面，
支持常用验证器（positive/negative/email/url/uuid/range），FFI diff=0。

## 3. 实现（纯 Mojo；**FFI diff = 0**）

1. **`validators.mojo`**：
   - `apply_field_validators` — 应用验证器到字段值
   - `validate_model_fields` — 主入口，从 handler.data 读取 `_validators_<field>`
   - `ValidationError` — 自定义错误类，包含字段名、消息、约束名
   - `validation_error_to_422` — 转换为 FastAPI 422 错误格式
   - 内置验证器：
     - `gt` / `ge` / `lt` / `le` — 数值范围验证（arg 为比较值）
     - `positive` / `negative` — 正数/负数验证
     - `email` — 邮箱格式验证（包含 @ 和域点）
     - `url` — URL 格式验证（包含 ://）
     - `uuid` — UUID 格式验证（8-4-4-4-12 hex）

2. **demo 路由**：
   - `/validator/positive`：正数验证
   - `/validator/email`：邮箱格式验证
   - `/validator/range`：范围验证 (gt:10;lt:100)
   - `/validator/uuid`：UUID 格式验证

3. **接线**：`http_server_final.mojo` 中 `register_validator_routes(router)`

## 4. 验证器语法

在 `handler.data` 中声明 `_validators_<field_name>` 键，值为 CSV 格式的验证器列表：

```mojo
handler.set_data("_validators_price", "positive")  # 单一验证器
handler.set_data("_validators_number", "gt:10;lt:100")  # 范围验证
handler.set_data("_validators_id", "uuid")  # 格式验证
```

验证器参数用冒号分隔：`validator_name:arg`，多个用分号分隔。

## 5. 已知偏差

| 偏差 | 上游行为 | 本实现 |
|------|---------|--------|
| `@validator` 闭包 | Python callable | Dict[String,String] 映射 |
| 自定义异常 | ValueError/ValidationError | 422 JSON 错误 |
| 验证顺序 | 定义顺序 | CSV 顺序 |
| 验证时机 | 模型加载时 | 请求处理时 |

## 6. 六条架构隔离约束声明

| 约束 | 立场 |
|------|------|
| 1. 无循环依赖 | ✅ 叶模块，仅依赖 body_schema/router/handler |
| 2. 分层向下依赖 | ✅ 纯 Mojo 字典查询；零 FFI / 零 fd / 零 env |
| 3. God package 阈值 | ✅ 383 LOC < 500 |
| 4. 主题域边界清晰 | ✅ 验证器全收敛在单文件 |
| 5. bridge/adapter 显式化 | ✅ **FFI diff = 0** |
| 6. 测试文件跟随 | ✅ e2e 同目录；demo 同文件 |

## 7. 验收

- e2e 测试覆盖验证器路由（positive/email/uuid/range）
- binary 构建成功，130+ routes
- `ldd build/fastapi_mojo` 仅 libc.so.6
- `register_validator_routes` 在 `register_routes` 中被调用
