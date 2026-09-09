# src/fastapi_mojo/dep_cache.mojo
#
# Decision-47 (ADR-0022): per-request Depends memo table — upstream 0.141.1
# `Depends(..., use_cache=True/False)` 语义的声明式等价 (probe P9-1..P9-5):
#   - 每个**实际派发**的 dep 存一条 memo (append-only; 每次新派发追加,
#     P9-3: nocache 派发的结果同样入库, 后续 cached 引用复用最新一条);
#   - cached 引用 (默认, upstream use_cache=True): 命中 memo -> 重注入,
#     不重复派发 (菱形/三重菱形 = 1 次, P9-1/P9-5);
#   - nocache 引用 (upstream use_cache=False): 恒重新派发, 结果覆写式入库
#     (追加新条, P9-2/P9-4);
#   - 每请求作用域 (请求间 cache 清空, P9-1 第二请求再派发).
#
# 纯 Mojo 数据结构 (并行 List, MpParts 同模式 — struct-of-Lists 可拷贝);
# 零 FFI。Mojo 1.0.0 无闭包: 上游 per-dependant 缓存 = 本表 per-name memo
# (dep 名 = 函数身份, 声明式等价 — ADR-0022 §3.5-1)。


struct DepCache:
    """每请求 dep memo 表. 扁平并行 List:
    names[i] = dep 名 (可重复 — 每次实际派发一条);
    kstarts[i]/kcounts[i] = 该条 outputs 在 okeys/ovals 的 [start, start+count) 范围."""
    var names: List[String]
    var kstarts: List[Int]
    var kcounts: List[Int]
    var okeys: List[String]
    var ovals: List[String]

    def __init__(out self):
        self.names = List[String]()
        self.kstarts = List[Int]()
        self.kcounts = List[Int]()
        self.okeys = List[String]()
        self.ovals = List[String]()

    def entry_count(self) -> Int:
        return len(self.names)

    def find(mut self, name: String) -> Int:
        """最后一个同 name 条目的下标 (P9-3: 最新派发优先); 无 = -1."""
        var i = len(self.names) - 1
        while i >= 0:
            if self.names[i] == name:
                return i
            i -= 1
        return -1

    def append(mut self, name: String, keys: List[String], vals: List[String]):
        """新派发入库 (append-only, 覆写 = 追加新条, find 取最新)."""
        self.names.append(name)
        self.kstarts.append(len(self.okeys))
        self.kcounts.append(len(keys))
        var i = 0
        while i < len(keys):
            self.okeys.append(keys[i])
            self.ovals.append(vals[i])
            i += 1

    def inject(mut self, name: String, i: Int, mut target: Dict[String, String]):
        """memo 条 i 的输出重注入 target (前缀 name_, 与首次派发注入完全一致)."""
        var j = 0
        while j < self.kcounts[i]:
            target[name + "_" + self.okeys[self.kstarts[i] + j]] = \
                self.ovals[self.kstarts[i] + j]
            j += 1

    def calls_of(self, name: String) -> Int:
        """dep name 在本请求的**实际派发次数** (memo 条数; P9 计数语义)."""
        var c = 0
        var i = 0
        while i < len(self.names):
            if self.names[i] == name:
                c += 1
            i += 1
        return c

    def unique_names(self) -> List[String]:
        """按首现序去重的 dep 名列表 (calls 注入用)."""
        var out = List[String]()
        var i = 0
        while i < len(self.names):
            var n = self.names[i]
            var seen = False
            var j = 0
            while j < len(out):
                if out[j] == n:
                    seen = True
                    break
                j += 1
            if not seen:
                out.append(n)
            i += 1
        return out^


def inject_dep_calls(data: Dict[String, String], mut params: Dict[String, String],
                     cache: DepCache) raises:
    """`_dep_calls=true` 声明 (observability 超集, ADR-0022 §3.5-2): 本请求
    实际派发的每个 dep -> params[<name>_calls] = 派发次数. 未声明 = 零输出
    (上游无此面, 默认响应体不变)."""
    if "_dep_calls" not in data or data["_dep_calls"] != "true":
        return
    var names = cache.unique_names()
    var i = 0
    while i < len(names):
        params[names[i] + "_calls"] = String(cache.calls_of(names[i]))
        i += 1
