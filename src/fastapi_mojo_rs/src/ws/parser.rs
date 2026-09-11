//! parser.rs — WebSocket 状态化帧解析器 (ADR-0008/0009)
//!
//! God-file 阈值拆分边界 (ADR-0010 §6 约束 3): 从 ws.rs 拆出帧状态机。
//! WsParser 是 Rust 内部状态 (DC1 后不再存在 C twin), RFC 7692 压缩消息
//! 重定向到 pump 提供的 decomp 缓冲; FFI 参数表面保持 8 个不变。
//! feed 语义: 0=暂无消息; 1=数据消息完成; 2=控制帧完成; -1=协议错误
//! (consumed 指向出错字节); -2=reasm/decomp 容量不足 (未越界, 扩容重放)。

use std::os::raw::{c_int, c_uchar};
use super::WS_MAX_MSG;

// ========== 帧解析器结构体 (#[repr(C)], 与 C ws_parser_t 逐字段镜像) ==========
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct WsParser {
    pub stage: c_int,
    pub fin: c_int,
    pub opcode: c_int,
    pub masked: c_int,
    pub ext: [c_uchar; 8],
    pub ext_need: c_int,
    pub ext_got: c_int,
    pub flen: u64,
    pub mask: [c_uchar; 4],
    pub mask_got: c_int,
    pub pgot: u64,
    pub in_msg: c_int,
    pub msg_opcode: c_int,
    pub reasm_len: usize,
    /// 当前帧第一字节原样保留的 RSV bits (0x40/0x20/0x10)。
    pub rsv: c_uchar,
    /// 本数据消息是否压缩 (首帧 RSV1; 延续帧保持)。
    pub msg_rsv: c_uchar,
    /// 已收集的 RFC 7692 压缩字节数。
    pub decomp_len: usize,
    /// pump 拥有的压缩输入缓冲; 每次 feed 前刷新, 不改变 FFI 参数表。
    pub decomp_addr: usize,
    pub decomp_cap: usize,
    /// 1 = 本连接协商了 permessage-deflate, RSV1 允许出现在首数据帧。
    pub deflate_enabled: c_int,
}



// ========== parser init ==========

impl WsParser {
    /// 全字段清零的初始状态 (与 C ws_parser_init 等价). 所有字段都是 int /
    /// u64 / array, all-zero 是合法状态.
    pub fn new() -> Self {
        unsafe { std::mem::zeroed() }
    }
}

impl Default for WsParser {
    fn default() -> Self {
        Self::new()
    }
}


#[no_mangle]
pub extern "C" fn ws_parser_init(p: *mut WsParser) {
    unsafe {
        std::ptr::write_bytes(p, 0, 1);
    }
}

// ========== parser frame_done (内部辅助) ==========
fn ws_parser_frame_done(
    p: &mut WsParser,
    opcode_out: &mut c_int,
    melen_out: &mut usize,
    reasm: &mut [u8],
    decomp: &mut [u8],
) -> c_int {
    if p.opcode >= 8 {
        // 控制帧: 必须 FIN=1 且 ≤125B
        if p.fin == 0 || (p.flen as usize) > 125 {
            return -1;
        }
        *opcode_out = p.opcode;
        *melen_out = p.flen as usize;
        if *melen_out < reasm.len() {
            reasm[*melen_out] = 0;
        }
        return 2;
    }
    if p.opcode == 0 {
        // 延续帧: 必须在某消息中间
        if p.in_msg == 0 {
            return -1;
        }
    } else {
        // 新数据帧: 不能在消息中间
        if p.in_msg != 0 {
            return -1;
        }
        p.msg_opcode = p.opcode;
        p.reasm_len = 0;
        p.decomp_len = 0;
    }
    let compressed = p.msg_rsv != 0;
    let total = if compressed {
        p.decomp_len + p.flen as usize
    } else {
        p.reasm_len + p.flen as usize
    };
    if compressed {
        p.decomp_len = total;
    } else {
        p.reasm_len = total;
    }
    if p.fin != 0 {
        if compressed {
            if total < decomp.len() {
                decomp[total] = 0;
            }
        } else if total < reasm.len() {
            reasm[total] = 0;
        }
        *opcode_out = p.msg_opcode;
        *melen_out = total;
        p.in_msg = 0;
        p.reasm_len = 0;
        p.decomp_len = 0;
        return 1;
    }
    p.in_msg = 1;
    0
}

// ========== parser feed (核心: 状态机 + consumed + reasm 按需扩容) ==========
//
// 返回值:
//   0  = 暂无完整消息 (consumed == n)
//   1  = 数据消息完成 (*opcode/*melen, reasm[..melen] 有效)
//   2  = 控制帧完成 (*opcode/*melen, reasm[..melen] 有效)
//  -1  = 协议错误 (consumed 指向出错字节处)
//  -2  = reasm 容量不足 (未越界写入; 调用方扩容后重放 [consumed..n))
#[no_mangle]
pub extern "C" fn ws_parser_feed(
    p: *mut WsParser,
    buf: *const c_uchar,
    n: usize,
    opcode_out: *mut c_int,
    melen_out: *mut usize,
    reasm: *mut c_uchar,
    reasm_cap: usize,
    consumed_out: *mut usize,
) -> c_int {
    unsafe {
        let p = &mut *p;
        let buf = std::slice::from_raw_parts(buf, n);
        let reasm_slice = std::slice::from_raw_parts_mut(reasm, reasm_cap);
        let decomp_slice = if p.decomp_cap == 0 || p.decomp_addr == 0 {
            &mut []
        } else {
            std::slice::from_raw_parts_mut(p.decomp_addr as *mut c_uchar, p.decomp_cap)
        };
        let mut off: usize = 0;

        while off < n {
            // stage 4: payload 字节 (批量拷贝, 不逐字节)
            if p.stage == 4 {
                let need = p.flen - p.pgot;
                let avail = n - off;
                let take = if (avail as u64) < need {
                    avail
                } else {
                    need as usize
                };
                // 控制帧与未压缩数据写 reasm; RFC 7692 压缩数据写 decomp。
                let compressed = p.opcode < 8 && p.msg_rsv != 0;
                let (out, out_cap, dst): (&mut [u8], usize, usize) = if p.opcode >= 8 {
                    (reasm_slice, reasm_cap, p.pgot as usize)
                } else if compressed {
                    (
                        decomp_slice,
                        p.decomp_cap,
                        p.decomp_len + p.pgot as usize,
                    )
                } else {
                    (
                        reasm_slice,
                        reasm_cap,
                        p.reasm_len + p.pgot as usize,
                    )
                };
                if dst + take > out_cap {
                    *consumed_out = off;
                    return -2;
                }
                for i in 0..take {
                    out[dst + i] = buf[off + i] ^ p.mask[(p.pgot as usize + i) % 4];
                }
                off += take;
                p.pgot += take as u64;
                if p.pgot < p.flen {
                    break;
                }
                p.stage = 0;
                let mut op: c_int = 0;
                let mut ml: usize = 0;
                let r = ws_parser_frame_done(p, &mut op, &mut ml, reasm_slice, decomp_slice);
                if r != 0 {
                    *opcode_out = op;
                    *melen_out = ml;
                    *consumed_out = off;
                    return r;
                }
                continue;
            }

            // stage 0-3: 按字节推进头部
            let b = buf[off];
            off += 1;
            match p.stage {
                0 => {
                    p.fin = if b & 0x80 != 0 { 1 } else { 0 };
                    p.rsv = b & 0x70;
                    p.opcode = (b & 0x0F) as c_int;
                    if p.opcode >= 3 && p.opcode <= 7 {
                        *consumed_out = off;
                        return -1;
                    }
                    if p.opcode == 0 && p.in_msg == 0 {
                        *consumed_out = off;
                        return -1;
                    }
                    // 本 bridge 只协商 permessage-deflate: RSV2/RSV3 永远非法;
                    // RSV1 只能出现在压缩数据消息首帧, 控制帧/延续帧禁止。
                    if p.rsv & 0x30 != 0 {
                        *consumed_out = off;
                        return -1;
                    }
                    let rsv1 = p.rsv & 0x40 != 0;
                    if rsv1
                        && (p.deflate_enabled == 0
                            || p.opcode >= 8
                            || p.opcode == 0
                            || p.in_msg != 0)
                    {
                        *consumed_out = off;
                        return -1;
                    }
                    if p.opcode == 1 || p.opcode == 2 {
                        p.msg_rsv = if rsv1 { 1 } else { 0 };
                        p.decomp_len = 0;
                    }
                    p.stage = 1;
                }
                1 => {
                    p.masked = if b & 0x80 != 0 { 1 } else { 0 };
                    if p.masked == 0 {
                        // 客户端帧必须掩码 (RFC 6455 §5.1)
                        *consumed_out = off;
                        return -1;
                    }
                    let l7 = (b & 0x7F) as u64;
                    if l7 < 126 {
                        p.flen = l7;
                        p.mask_got = 0; // 逐帧重置 (防跨帧残留 → 越界)
                        p.stage = 3;
                    } else {
                        p.ext_need = if l7 == 126 { 2 } else { 8 };
                        p.ext_got = 0;
                        p.stage = 2;
                    }
                }
                2 => {
                    p.ext[p.ext_got as usize] = b;
                    p.ext_got += 1;
                    if p.ext_got >= p.ext_need {
                        p.flen = 0;
                        for i in 0..(p.ext_need as usize) {
                            p.flen = (p.flen << 8) | (p.ext[i] as u64);
                        }
                        if p.flen > WS_MAX_MSG as u64 {
                            *consumed_out = off;
                            return -1;
                        }
                        // 重组越界预检 (数据帧; 控制帧在 frame_done 再查 ≤125)
                        if p.opcode == 0 {
                            let old = if p.msg_rsv != 0 {
                                p.decomp_len
                            } else {
                                p.reasm_len
                            };
                            if old + (p.flen as usize) > WS_MAX_MSG {
                                *consumed_out = off;
                                return -1;
                            }
                        } else if p.opcode < 8 && p.flen > WS_MAX_MSG as u64 {
                            *consumed_out = off;
                            return -1;
                        }
                        p.mask_got = 0;
                        p.stage = 3;
                    }
                }
                3 => {
                    p.mask[p.mask_got as usize] = b;
                    p.mask_got += 1;
                    if p.mask_got >= 4 {
                        p.pgot = 0;
                        p.stage = 4;
                    }
                }
                _ => {
                    *consumed_out = off;
                    return -1;
                }
            }
        }
        *consumed_out = n;
        0
    }
}

