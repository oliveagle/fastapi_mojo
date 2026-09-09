# ADR-0021: UploadFile 对象 API — 文件字段声明 / 422 parity / 对象操作 / multipart OpenAPI

- **日期**：2026-09-10
- **状态**：✅ 已接受
- **决策者**：oliveagle（agent 执行，Goal-0003 P2 矩阵 #6 落地）
- **关联**：AGENTS.md §3.2/§6（**决策-46**）、Goal-0003（P2：UploadFile 对象 API，
  对标矩阵行 #6）、North Star（单 binary 零依赖 — **零新 crate**；FFI diff = +1
  `mp_part_save`）、ADR-0020（决策-45 Form 多值/alias/desc + 422 parity — 本 ADR 的
  multipart 对偶 + 422 detail 约定继承）、ADR-0014（决策-38 422 detail Pydantic v2
  结构）、ADR-0010（Rust bridge + FFI NUL 终止契约，决策-36）、决策-32（multipart
  解析 foundation：Rust bridge 解析 + `file_` 注入 — 本 ADR 在其上声明化）、
  FastAPI 0.141.1 + pydantic 2.13.5（/tmp/fm_probe p1–p8 逐条实测，本 ADR §1 证据）

## 1. 背景

Goal-0003 P2 矩阵 #6：`UploadFile` 对象 API（read/seek/size/close 语义等价 +
422 校验 parity + multipart OpenAPI）。决策-32 已有 multipart 解析（Rust bridge
`[u8]` 解析 + `file_<name>_filename/_size/_content_type/_body_b64` 注入），
但缺：**文件字段声明与类型**（file vs bytes）、**422 校验**（文本/文件错位）、
**对象操作**（head/range/sha256/save）、**multipart OpenAPI**（contentMediaType
schema）。

**实测证据（FastAPI 0.141.1 + pydantic 2.13.5，/tmp/fm_probe p1–p8 逐条 probe；
raw body + CT 发送，避开 TestClient/httpx 编码差异 — ADR-0020 同姿势）**：

- **U1**：`file.size` = **实际 raw 字节数**（256B 0..255 文件 → 256，非 b64 长
  344、非 tempfile 落盘大小）。决策-32 的 `file_*_size` 此前 = b64 长度（偏差），
  本 ADR 修正。
- **U2**：文本 part 送 `UploadFile` 参数 → 422
  `{"type":"value_error","loc":["body","f"],"msg":"Value error, Expected
  UploadFile, received: <class 'str'>","input":"txtval","ctx":{"error":{}}}`
  （本实现省略 `ctx` — ADR-0020 §3.5-1 约定 loc,msg,type,input）。
- **U3**（p4/p7）：文件 part 送声明的 `str` Form 字段 → **单条** 422
  `{"type":"string_type","loc":["body","note"],"msg":"Input should be a valid
  string","input":{...UploadFile dict...}}`；input 含
  `_file/_max_size/_rolled/_TemporaryFileArgs/_max_mem_size` 等 env 相关实现
  细节（p4 实测输出）— 本实现取稳定子集（§3.5-2）。**标量 last-wins**：
  file-then-text → 200（text 生效，p7 实测）；**list** = 逐 occurrence
  （loc `["body","tags",1]`，p7 实测）。
- **U4**：非 List 字段 = **last-wins**（file-then-text / text-then-file 双向
  实测）；`List` = **全部 occurrence**（顺序）。
- **U5**：**非 multipart Content-Type**（无 CT / urlencoded / json）→ 所有
  文件字段 **missing 422**（`request.form()`/`files()` 空）；必填 form 字段
  同样 missing（urlencoded 时 form 字段仍解析 — U8 对偶）。
- **U6**：1MB+10 字节文件 → 200（上游 1MB 仅是 tempfile spool 阈值，**无大小
  限制**；本实现全内存 — 预算内一致，无 spool 分支）。
- **U7**（p3/p3b/p5）：OpenAPI 字段 schema（**实测字段序**）：
  - 非 list 非 optional：`{"type":"string","contentMediaType":
    "application/octet-stream","title":"Doc","description":"..."}`
  - optional（`=`）：`{"anyOf":[{"type":"string","contentMediaType":
    "application/octet-stream"},{"type":"null"}],"title":"Opt"}`
  - list（`[]`）：`{"items":{...},"type":"array","title":"Docs"}`
  - optional list：`{"anyOf":[{"items":...,"type":"array"},{"type":"null"}],
    "title":"..."}`
  - `requestBody` = `{"required":true,"content":{"multipart/form-data":
    {"schema":{"$ref":"#/components/schemas/Body_..."}}}}` — **`required` 仅当
    存在必填字段**（全 optional → 无 `required` key，p3b 实测）；
  - body schema 对象 key 序 = **properties/type/required/title**（p5 实测）；
  - 命名 = `Body_<fn>_<route>_<method>`（上游；本实现 `Body_<handler.name>_<method>`
    — §3.5-3）。
- **U8**：multipart **文本 part 供给 Form 字段**（`request.form()` 含 text
  part — p7 实测：`note` Form 字段从 text part 取值 200）。
- **U9**：上游 `List[bytes]` + **文本** part → **500**
  `AttributeError: 'str' object has no attribute 'read'`（上游 bug，p2 实测）—
  本实现 bytes 接受 text/file 双路（§3.5-1）。
- **p7 补充**：**form 字段 presence 胜** — 文件 part 使 form 字段「存在」，
  其 missing 422 被去重丢弃（上游 file-then-text → 200 单一路径；file 单独 →
  仅 string_type 一条，无 missing 双错）。
- **p8**：`Form("")` / `Form(None)` / `Optional[str]=Form(None)` 缺失 → **全
  200**（空标量默认 = optional）。本实现 `name:type=`（空默认）= **required**
  （决策-45 `TypeSpec.has_default()` = `default_value != ""`）— §3.5-6 偏差。

**约束（Mojo 1.0.0 + North Star）**：Mojo 无闭包/文件句柄 → 声明式
（`handler.data`，决策-32/34/38/43/44/45 同模式）；Mojo 无 OS file API →
save 走 Rust bridge FFI（§3.1）；SHA-256 手写（bridge 零第三方 crate 延续，
ADR-0010 SHA-1 同先例）。

## 2. 候选方案

- **A. Python 式 UploadFile 对象（file 句柄 / seek / tempfile）**：❌ Mojo
  1.0.0 无 OS file 模块（std 缺口，ADR-0001/0010 同立场）；tempfile 引入磁盘
  IO 生命周期（崩溃残留 / 清理）+ 与 North Star「零外部依赖」气质相悖；
  seek 语义在内存模型下无对等价值。
- **B. 内存字节快照 + 声明式对象 API**（✅ 采纳）：parts 全内存（决策-32
  既有 Rust buffer），`_file_types`/`_file_aliases`/`_file_ops` 声明式；
  `size` = 实际字节（U1）；head/range/sha256 = 快照重读（纯计算，零拷贝开销）；
  save = 唯一新增 FFI（原子写）；422 parity 纯 Mojo 校验；OpenAPI 纯 Mojo
  构造。与决策-44/45 分层一致（解析/校验/归一化 = Mojo 应用层）。
- **C. 等 Mojo 原生 file/network 模块**：❌ Mojo 1.0.0 无（ADR-0001/0010
  既有立场：bridge 承载 std 缺口）。

## 3. 决策

1. **Rust bridge（`bridge/multipart.rs` 重构 +249/-146，净 -28；`ffi.rs` +13）**：
   - 解析 helper 提取 `pub(crate)`（`extract_boundary` / `find_from` /
     `extract_attr`（quoted+unquoted）/ `split_part_headers` /
     `parse_header_line`）— 单测面扩大（决策-23 质量门禁延续）。
   - 新增 **`b64_decode`**（save 路径 b64→bytes；roundtrip 全 0..255 测试）/
     **`to_hex`** + **`sha256_hex_of`**（**lock-free** 纯 std 手写 SHA-256 —
     读路径零锁；决策-23 教训：已知向量 `abc/empty` + e2e `sha256sum` 交叉
     验证）/ **`part_save`**（**原子**：`.tmp` 写 + `rename`，无半文件；
     0 成功 / -1 失败（b64 空/解码失败/fs 失败））/ `part_sha256_hex`
     `#[cfg(test)]`（避免 plain build dead-code 警告）。
   - **parts getter field 5 = sha256hex**（锁-free 缓存于解析时计算 — 读路径
     无 Mutex）。**🔴 实测发现并修复死锁隐患**：原 getter 对非重入 `Mutex`
     自锁路径（读持锁再算 sha256 取锁）— 改为解析期预算，读路径纯读。
   - **`ffi.rs` + `mp_part_save(i: c_int, path: *const c_char) -> c_int`**
     （C ABI；`path` NUL 终止 — 决策-36 契约；**路径穿越检查在 Mojo 层**
     `_path_safe` — FFI 不复制安全策略）。
   - 测试拆出 **`multipart_tests.rs`**（212 行，17 测 = 原 12 测平移 + 5 新：
     b64 decode padding/roundtrip / sha256 已知向量 / save 写盘/坏 index）。
2. **Mojo 新模块（纯逻辑，无 FFI；全 <500 行）**：
   - **`file_params.mojo`（427）**：`MpParts`（**parallel lists + `copy()`**
     — Mojo 1.0.0 无 struct-of-Strings 可拷贝）/ b64 enc/dec（纯 Mojo，
     自检向量）/ `get_file_types` + `get_file_aliases`（**`;` 分隔** —
     decision-45 同约定；**修复**：`file_field_names_ordered` 初版误用 `,`
     切分）/ `_parse_file_spec`（base/`[]`/`=` 三布尔）/
     `validate_file_collect`（声明序 collect-all：missing（"Field required"
     F 大写 + input null）/ U2 value_error（上游完整措辞）/ U4 last-wins /
     list 逐 occurrence / unknown_type）/ `_decl_of(wire, types, aliases)`
     （声明名 key 命中 **或** alias-value 命中 → 声明名）/
     `file_declared_names`（文本 map 过滤用）/ `text_multi_map_filtered` /
     `text_multi_map` / `apply_file_extras`（file part →
     `file_<declared>_filename/_content_type/_size`（**实际字节 U1**）`/
     _body_b64`；alias 字段按**声明名** key（wire alias 无绑定效力 —
     决策-45 同语义）；text part → 声明 **bytes** 字段 → `file_` key
     （U9 双路）/ 声明 form 字段 → `form_`（U8）/ 其余 text → `form_<wire>`
     （决策-32 兼容）；list 声明 → `file_<k>_count` + `file_<k>_list_json`
     （`[{"filename","content_type","size","body_b64"},...]` 全 occurrence
     顺序，size = 实际字节））。
   - **`file_form_check.mojo`（126，500 行规则拆分）**：`_file_obj_input`
     （U3 input = **稳定子集** `{filename,size,headers{content-disposition[,
     content-type]}}` — 上游 `_file/_max_size/_rolled/_TemporaryFileArgs/
     _max_mem_size` env 细节排除，§3.5-2）/ `validate_file_vs_form`
     （U3：标量 last-wins / list 逐 occurrence loc idx；**被声明 file 字段
     claim 的 part 不参与** — 声明名优先）/ `file_part_fields`（有 file
     part 的 form 字段名 — 422 de-dup 输入）。
   - **`file_ops_ffi.mojo`（195）**：`snapshot_mp_parts()`（**单一 FFI
     快照点** — 解析失败/非 multipart → 空 = U5 语义；conn 仍活跃，重读
     安全）/ `apply_file_ops(params, parts, ops_csv, aliases)`（`name:op[:a1]
     [:a2];...`；alias-aware lookup；**输出 key 统一声明名**：`_head_b64` /
     `_range_b64`（off+len，越界 clamp）/ `_sha256` / `_saved_ok`（"true"/
     "false"）/ `_saved_path`；未出现/坏 entry → no-op）/ `_path_safe`
     （拒绝 `..` / 空 — §3.5-4 安全超集）。
   - **`openapi_multipart.mojo`（145，自 openapi 抽取，ADR-0020
     openapi_schemas 先例）**：`_file_field_schema`（U7 四形态，**实测字段
     序** type/contentMediaType/title/description；`title` = property 名
     首字母大写（**alias-aware**）/ description = `_param_descs` 共享表
     决策-43）/ `multipart_request_body_required`（file/form 任一必填 →
     true）/ `multipart_route`（`_file_types` 声明 = multipart；或
     `_multipart="true"` + form 声明）/ `multipart_openapi_schema`（**key
     序 properties/type/required/title** = 上游实测；file 字段先（声明序）
     后 form（声明序）；`required` 仅当非空；`Body_<handler.name>_<method>`
     — §3.5-3）。
3. **dispatch 接线（`http_server_final` 1210 → 1238，净 +28）**：
   - **移除** `_mp_read_field` / `inject_multipart_fields`（决策-32 旧注入
     — 被 `apply_file_extras` 取代；`/upload` 未声明字段行为不变：wire 名
     直用，决策-32 兼容）。
   - 校验段：`ct_hdr` → `_ct_is_multipart` → `snapshot_mp_parts()` +
     `fmulti`（multipart = **filtered text map**（file 声明名/alias 不进
     map — U3 前提）；urlencoded = `parse_form_multi`（决策-45）；其余 =
     空）；`validate_file_collect` **恒执行**（非 multipart = 空 parts =
     U5 全缺失）；**422 de-dup**（p7 presence 胜）：`flagged`
     （file part 触及的 form 字段）命中时，其 canonical `missing_err_json`
     **整串精确匹配**的 missing 422 丢弃（narrow：只丢同名字段 missing，
     其他错误全保留）。
   - 注入段（成功路径）：`apply_file_extras` +（声明 `_file_ops` 时）
     `apply_file_ops`（快照重读 — conn 活跃，无生命周期问题）。
   - OpenAPI：`_generate_operation` multipart 分支（与 `_body_schema`
     互斥；urlencoded 分支保留回归）+ components 循环按 `multipart_route`
     分流 multipart vs form schema。
4. **demo 路由**：`/upload-file`（`_file_types="doc:file;opt:file=;
   docs:file[]"` + `_file_aliases="doc=docfile"` + `_form_types="note:str"`
   （必填 — 刻意规避 p8 空默认偏差）+ `_file_ops="doc:sha256"` +
   `_param_descs`）/ `/upload-bytes`（`_file_types="raw:bytes=;small:bytes="`
   全 optional（OpenAPI 无 `required` case + U5 全 optional → 非 multipart
   CT 200）+ `_file_ops="raw:head:4;raw:range:1:3;raw:save:/tmp/fm_upload/
   raw.bin"`）。

## 3.5 文档化偏差

1. **U9 上游 500 不复制**：`List[bytes]` + 文本 part 上游 = 500
   `AttributeError: 'str' has no attribute 'read'`；本实现 bytes 接受
   text/file 双路 200（e2e MP16/17 固化）。上游 bug，非语义。
2. **U3 `string_type` input = 稳定子集**：`{filename,size,headers
   {content-disposition[,content-type]}}`；上游 input 含 `_file/_max_size/
   _rolled/_TemporaryFileArgs/_max_mem_size`（p4 实测：env 相关实现细节，
   不可逐字节对齐）— 语义等价（字段齐全、值正确）。
3. **`Body_<handler.name>_<method>` 命名**：上游 = `Body_<fn>_<route>_<method>`
   （如 `Body_upload_file_upload_file_post`）；同 ADR-0020 §3.5-4 约定
   （handler.name 稳定，route 可重复 — 避免同 fn 多 route 撞名）。
4. **`save` op 路径守卫 = 安全超集**：拒绝 `..` / 空路径（上游
   `UploadFile.save` 无穿越守卫，直写）— 生产化安全超集（G3 硬化同方向）。
5. **未声明字段 = 未校验**：无 `_file_types` 声明的字段只做注入（决策-32
   兼容，`/upload` legacy demo 行为不变），不 422（同 ADR-0020 §3.5-5）。
6. **`name:type=`（空标量默认）= required**，上游 `Form("")` / `Form(None)` /
   `Optional[str]=Form(None)` = optional（p8：缺失全 200）— 决策-45
   `has_default()` = `default_value != ""` 既有语义；修复将 ripple query +
   form（决策-43/45 面）→ **本决策记录不修**（demo 刻意用必填 `note:str`
   规避）。
7. **U3 de-dup（presence 胜）**：文件 part 使 form 字段「存在」→ 其 missing
   422 丢弃（上游 p7：file 单独 → 仅 string_type 一条；file-then-text →
   200）；整串精确匹配保证只丢同字段 missing。

（422 detail 字段序 loc,msg,type,input vs 上游 type,loc,msg,input — 仓库
约定，ADR-0020 §3.5-1 继承。）

## 4. 风险

| 风险 | 影响 | 应对 |
|------|------|------|
| `part_save` 写真实文件（新 IO 面） | 环境 /tmp 依赖；路径穿越 | `_path_safe` 拒绝 `..`/空（Mojo 层）；`.tmp`+rename 原子（无半文件）；rc 契约 0/-1；e2e 用 `/tmp/fm_upload` + `cmp` roundtrip |
| SHA-256 手写（零 crate） | 算法错误 | 已知向量（`abc`/`empty`）+ e2e MP8 `sha256sum` 交叉验证 + `field5_sha256_hex_known_vector` 单测 |
| multipart.rs 重构（helper 提取 + 测试拆分） | 解析回归 | 17 测（含原 12 平移：binary 保真/中文/尾 CRLF/multi-field）+ e2e MP1–MP7 全回归绿 |
| 422 de-dup 误丢错误 | 漏报 | 仅 **整串精确匹配** canonical missing（同字段名）— narrow；MP12/18/19 守护（非 de-dup 的 missing 全保留） |
| bytes 双路（text/file 皆 200，U9） | 语义歧义 | demo + e2e MP16/17 固化；`file` base + text = 422（U2）双轨对称（file 严格 / bytes 宽松 = 上游 bytes 语义超集） |
| http_server_final 1210 → 1238 继续膨胀 | 既有超阈值 | 声明式接线 +28（移除旧 inject -15 + dispatch ~+43），同 ADR-0018/0019/0020 立场；逻辑主体在 4 个新模块（均 <500） |

## 5. 架构隔离约束声明

| 约束 | 本决议的立场 | 说明 |
|------|------------|------|
| 1. 无循环依赖 | ✅ 遵守 | 单向：`file_params -> {params_query_extra, json, handler}`；`file_form_check -> {file_params, json, handler}`；`file_ops_ffi -> {file_params}`；`openapi_multipart -> {handler, form_params, file_params, params_query_extra, json}`；`openapi -> openapi_multipart`（新，one-way）；`http_server_final ->` 以上全部（无反向）；依赖图零环 |
| 2. 分层向下依赖 | ✅ 遵守 | 声明解析/422 校验/对象 API/OpenAPI = 纯 Mojo 应用/协议层；FFI = **唯一** +1 `mp_part_save`（bridge 层，NUL 契约决策-36）；**零新 crate**（SHA-256 纯 std 手写，ADR-0010 SHA-1 同先例）；Mojo `file_params`/`file_form_check`/`openapi_multipart` 零 FFI |
| 3. God package 阈值 | ⚠️ 遵守（带说明） | file_params **427** / file_form_check **126** / file_ops_ffi **195** / openapi_multipart **145**（均 <500）/ form_params **499**（≤500）/ openapi **403**（494→403 抽取回落）/ **http_server_final 1238**（1210→1238，既有超阈值 — +28 声明式接线，同 ADR-0018/0019/0020 立场） |
| 4. 主题域边界清晰 | ✅ 遵守 | file_params = file 字段声明/校验/注入（body 侧文件域）；file_form_check = file↔form 交互 422（U3，独立拆分保 500 行规则）；file_ops_ffi = 快照重读 ops（唯一 FFI 边界）；openapi_multipart = multipart schema 构造（openapi_schemas 先例，各管各的声明源）；query/path 域不碰（params_typed/params_query_extra） |
| 5. bridge/adapter 显式化 | ✅ 遵守 | FFI diff = **+1**（`mp_part_save`；C ABI 对齐 + NUL 契约）；Rust staticlib **零新 crate**（SHA-256/b64/hex 全手写）；`ldd` 实测仅 libc；binary **3,531,472 B (3.4M)** ≤4.2M（vs 决策-45 +131 KB）；`find src -name '*.c'` = 0 保持 |
| 6. 测试文件跟随 | ✅ 遵守 | `file_params_selftest.mojo`（270 行，~40 check：spec×5 / b64 向量 / U2–U5 双序 / U3×4 / filtered map / bytes-text / alias / list / decl 表）JIT 可达；`multipart_tests.rs`（17 测）与 multipart.rs 同目录；e2e 新增 **MP8–MP23b（18 项）** + MP4 语义修正（size = 实际字节 U1）；fmtool `jsoncheck` 整文门禁复用（MP21） |

## 7. 验证方式

1. **单 binary 不变式**：`ldd build/fastapi_mojo` 仅 libc（实测）；binary
   **3,531,472 B (3.4M)** ≤4.2M（决策-45 基线 3,400,400 B + 131 KB）；
   `env -i` 干净启动（health 200 + `/upload-file` 200（file+alias+list+form+
   sha256 op）+ `/upload-bytes` 200（bytes+save op），实测）。
2. **Rust 质量门禁**：`cargo test --release -- --test-threads=1`
   **349 → 354/0/4**（+5：b64 decode padding/roundtrip、sha256 已知向量、
   save 写盘/坏 index）；`cargo clippy --release --tests -- -D warnings`
   双 crate **0 警告**（含 multipart_tests 拆分后 dead-code 清零）。
3. **e2e 全量**：294 → **312/312**（+18，MP8–MP23b）全绿（实测 0 FAIL）：
   - MP8 sha256 op == `sha256sum`（alias → 声明名 key + size = 实际字节 U1）
   - MP9 head:4 / range:1:3 → b64（动态计算，python-free）
   - MP10/10b save roundtrip（saved_ok/path + `cmp` 逐字节）
   - MP11 all-optional 非 multipart CT → 200 无 file_*（U5）
   - MP12 required missing ×2（doc+docs，422）
   - MP13 文本 → file 字段（alias）→ 422 value_error（U2 完整措辞）
   - MP14 文件 → form 字段 → 422 string_type（U3，input 稳定子集：
     filename/size/content-disposition）
   - MP15 list file[] → count=2 + list_json 顺序（s1,s2）+ 标量 last-wins（U4）
   - MP16/17 bytes 接受 text/file（U9）→ size/body/head/range b64
   - MP18 无 CT → 422 ×3 missing（U5）；MP19 urlencoded CT → ×2（note 在场）
   - MP20 openapi.json 子串（contentMediaType / Body_upload_file_post /
     required / multipart/form-data）；MP21 `fmtool jsoncheck` 整文
   - MP22 文本 part → 声明 form 字段（U8，form_note=hello）
   - MP23a/23b alias（wire key 200 + 声明名 key / 声明名做 wire → 422
     missing — 无绑定效力）
4. **Mojo 自检**：`file_params_selftest.mojo` ~40 check 全绿（JIT）；
   `openapi_multipart` 四形态 schema 逐字节核对（U7，`zz_dbg` JIT probe
   后拆除）；既有 self-test 零回归。
5. **性能**：bench 6 场景 **0 errors**，get_root_10k_100c **34.3k req/s**
   （历史区间 32.9k–43.9k 内，无回归 — file 路由不在 bench 热路径）；
   RSS 平台化无泄漏（save 为一次性文件 IO）。
