# src/fastapi_mojo/mp_parts.mojo
#
# 决策-102 (上游 0.143.5 / 0.150.0 parity): multipart part 快照结构 +
# 上游 presence 语义判定. 从 file_params.mojo 拆出 (500 行阈值).
#
# 快照 = 并行 List (各字段同长度, 下标 i 平行对应一个 part); Mojo 1.0.0 无
# class — MpParts + 显式 copy() (ServerInfo 同模式).
#
# has_filenames (0.143.5 新增) 语义 — 上游 Starlette multipart 解析:
#   1 = part 的 Content-Disposition 带 filename 属性
#       (浏览器未选文件时 filename="" — 上游 UploadFile.filename == "")
#   0 = 无 filename 属性 = 纯文本 part (上游 FormData 的 str 项)
# 上游 0.150.0 的 _is_empty_file_input 只过滤前者且 filename=="" 且 size==0;
# 上游 0.143.5 要求 bytes 列表保留纯文本 part (含空文本 -> size 0) —
# 二者必须可区分, 故快照不能把 None 与 Some("") 压成同一个 "".
#
# 依赖: 无 (纯数据结构 + 纯逻辑).

struct MpParts:
    """multipart part 快照 (并行 List — 可复制, ServerInfo 同模式;
    各字段同长度, 下标 i 平行对应一个 part)."""
    var names: List[String]
    var filenames: List[String]
    var cts: List[String]
    var b64s: List[String]
    var raw_lens: List[Int]
    var idxs: List[Int]
    var has_filenames: List[Int]

    def __init__(out self):
        self.names = List[String]()
        self.filenames = List[String]()
        self.cts = List[String]()
        self.b64s = List[String]()
        self.raw_lens = List[Int]()
        self.idxs = List[Int]()
        self.has_filenames = List[Int]()

    def copy(self) -> MpParts:
        var p = MpParts()
        p.names = self.names.copy()
        p.filenames = self.filenames.copy()
        p.cts = self.cts.copy()
        p.b64s = self.b64s.copy()
        p.raw_lens = self.raw_lens.copy()
        p.idxs = self.idxs.copy()
        p.has_filenames = self.has_filenames.copy()
        return p^

    def count(self) -> Int:
        return len(self.names)

    def is_file(self, i: Int) -> Bool:
        """part 是否为文件 (上游 UploadFile): 有 filename 属性即为文件
        (含 filename="" 的未选文件输入); 无 filename 属性 = 文本 part
        (上游 FormData 的 str 项)."""
        return has_filename(self, i)


def has_filename(parts: MpParts, i: Int) -> Bool:
    """part 是否带 filename 属性 (0.143.5 新增维度).
    快照缺 has_filenames 字段时 (旧构造, 仅自检路径) 以 filename 非空兜底 —
    与 0.143.5 前的旧快照语义一致."""
    if len(parts.has_filenames) != len(parts.names):
        return parts.filenames[i] != ""
    return parts.has_filenames[i] != 0


def is_empty_file_input(parts: MpParts, i: Int) -> Bool:
    """上游 _is_empty_file_input (0.150.0, PR #16534): 浏览器未选择文件
    (有 filename 属性 且 filename=="" 且 size==0) -> 视为缺失.
    纯文本 part (无 filename 属性) 即使内容为空也不命中 — 上游 0.143.5
    要求 bytes 列表保留空文本项 (size 0)."""
    return has_filename(parts, i) and parts.filenames[i] == "" and parts.raw_lens[i] == 0


def scalar_missing(parts: MpParts, i: Int) -> Bool:
    """标量字段 presence (上游 _get_multidict_value 单值分支):
    - 文件 part: 仅 "filename=='' 且 size==0" 视为缺失 (0.150.0)
    - 文本 part: 内容为空 -> 缺失 (上游 "" -> Undefined)
    base (file/bytes) 不影响判定 — bytes 接受 str, file 接受 UploadFile."""
    if parts.is_file(i):
        return is_empty_file_input(parts, i)
    return parts.raw_lens[i] == 0


def occurrences(parts: MpParts, lookup: String) -> List[Int]:
    """同名 part 的全部 occurrence 下标 (按 part 序; 上游 FormData.getlist)."""
    var occ = List[Int]()
    var pi = 0
    while pi < parts.count():
        if parts.names[pi] == lookup:
            occ.append(pi)
        pi += 1
    return occ^
