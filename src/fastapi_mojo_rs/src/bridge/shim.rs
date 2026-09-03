//! bridge/shim.rs — DC3: 单 binary loader (端口 runtime_shim.c 360 LOC, ADR-0010).
//!
//! 流程 (端口 C 注释):
//!   1. 阶段嵌入的 3 个 Mojo 运行时 .so 到 `/dev/shm` (RAM, 优先) / `/tmp` / 可执行目录
//!   2. 设 `LD_LIBRARY_PATH` 指向 stage 目录 (KGEN DT_NEEDED 解析)
//!   3. `dlopen(KGEN, RTLD_NOW | RTLD_GLOBAL)`
//!   4. `dlsym(RTLD_DEFAULT, ...)` 绑 11 个 `KGEN_CompilerRT_*` C-API 入口
//!   5. sweep SIGKILLed 前实例遗留的 stage 目录 (self-heal)
//!   6. `atexit(runtime_cleanup)` 退出清理
//!   7. 嵌入的 static 资源 (index.html / test.json) 同步 stage 到 `<dir>/static/`,
//!      通过 `state::set_embedded_static_dir` 告知 bridge
//!
//! 入口: `__attribute__((constructor))` → Rust `#[used] #[link_section = ".init_array"]`,
//! 保证 shim 早于 Mojo 首次 `KGEN_CompilerRT_*` 引用 (实测 server.o 无 .init_array,
//! Mojo 在 main 首次 dispatch 才触发 KGEN 调用, 故 shim 在 .init_array 即可).

#![allow(static_mut_refs)]  // shim 构造期访问; panic=abort 单线程上下文, 安全.
#![cfg_attr(test, allow(dead_code))]  // test 模式 try_stage/kgen_runtime_bootstrap 未调用, 内部 dead_code 抑制.

use std::ffi::CStr;
use std::fs;
use std::io::Write;
use std::os::raw::{c_char, c_int, c_void};
use std::os::unix::fs::OpenOptionsExt;

// include generated static file table (build.rs 在 build_single.sh 设 SHIM_STATIC_* env)
include!(concat!(env!("OUT_DIR"), "/shim_static_gen.rs"));

// ===== objcopy payload 符号 (build_single.sh 写入 *.bin -> *.o) =====
// 符号名由 objcopy -I binary 从文件名派生, 在 build_single.sh 里固定:
extern "C" {
    static _binary_payload_kgen_bin_start: u8;
    static _binary_payload_kgen_bin_end: u8;
    static _binary_payload_msupp_bin_start: u8;
    static _binary_payload_msupp_bin_end: u8;
    static _binary_payload_asyncrt_bin_start: u8;
    static _binary_payload_asyncrt_bin_end: u8;
}

// ===== libc (extern "C" 直连; 零第三方 crate) =====
extern "C" {
    fn dlopen(filename: *const c_char, flag: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    fn dlerror() -> *mut c_char;
    fn setenv(name: *const c_char, value: *const c_char, overwrite: c_int) -> c_int;
    fn getenv(name: *const c_char) -> *mut c_char;
    fn kill(pid: c_int, sig: c_int) -> c_int;
    fn getpid() -> c_int;
    fn __errno_location() -> *mut c_int;
    fn unlink(path: *const c_char) -> c_int;
    fn rmdir(path: *const c_char) -> c_int;
    fn readlink(path: *const c_char, buf: *mut c_char, bufsiz: usize) -> isize;
    fn atexit(cb: unsafe extern "C" fn()) -> c_int;
    fn exit(status: c_int) -> !;
}

const RTLD_NOW: c_int = 2;
const RTLD_GLOBAL: c_int = 0x100;
const RTLD_DEFAULT: *mut c_void = -1isize as *mut c_void;

const STAGED_KGEN: &str = "libKGENCompilerRTShared.so";
const STAGED_MSUPP: &str = "libMSupportGlobals.so";
const STAGED_ASYNC: &str = "libAsyncRTRuntimeGlobals.so";

// ===== KGEN forwarder 函数指针 (单线程构造期写; 之后只读) =====
type KgenFn6 = unsafe extern "C" fn(
    *mut c_void, *mut c_void, *mut c_void, *mut c_void, *mut c_void, *mut c_void,
) -> *mut c_void;

static mut G_FP_ALIGNED_ALLOC: Option<KgenFn6> = None;
static mut G_FP_ALIGNED_FREE: Option<KgenFn6> = None;
static mut G_FP_GET_CURRENT_CPU_DEVICE: Option<KgenFn6> = None;
static mut G_FP_GET_OR_CREATE_CPU_DEVICE: Option<KgenFn6> = None;
static mut G_FP_RELEASE_CPU_DEVICE: Option<KgenFn6> = None;
static mut G_FP_DESTROY_GLOBALS: Option<KgenFn6> = None;
static mut G_FP_GET_OR_CREATE_GLOBAL: Option<KgenFn6> = None;
static mut G_FP_GET_STACK_TRACE: Option<KgenFn6> = None;
static mut G_FP_PRINT_STACK_TRACE_ON_FAULT: Option<KgenFn6> = None;
static mut G_FP_SET_ARGV: Option<KgenFn6> = None;
static mut G_FP_FPRINTF: Option<KgenFn6> = None;

// 当前 stage 目录 (atexit cleanup 用); 与 C `g_stage_dir[512]` 等价
static mut G_STAGE_DIR: [c_char; 512] = [0; 512];
static mut G_VERBOSE: c_int = 0;

unsafe fn errno() -> c_int { *__errno_location() }

fn vlog(msg: &str) {
    unsafe {
        if G_VERBOSE == 0 { return; }
        let stderr = std::io::stderr();
        let mut h = stderr.lock();
        let _ = h.write_all(b"[fastapi_mojo:shim] ");
        let _ = h.write_all(msg.as_bytes());
        let _ = h.write_all(b"\n");
    }
}

unsafe fn write_all(path: &str, data: *const u8, len: usize) {
    let slice = std::slice::from_raw_parts(data, len);
    match fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o755).open(path) {
        Ok(mut f) => {
            if let Err(e) = f.write_all(slice) {
                eprintln!("fastapi_mojo: short write to {path}: {e}");
            }
        }
        Err(e) => eprintln!("fastapi_mojo: cannot write {path}: {e}"),
    }
}

unsafe fn write_payload(dir: &str, name: &str, start: *const u8, end: *const u8) {
    let len = end.offset_from(start) as usize;
    let path = format!("{dir}/{name}");
    write_all(&path, start, len);
}

unsafe fn remove_file_quiet(path: &str) {
    let c = std::ffi::CString::new(path).unwrap();
    unlink(c.as_ptr());
}

unsafe fn rmdir_quiet(path: &str) {
    let c = std::ffi::CString::new(path).unwrap();
    rmdir(c.as_ptr());
}

fn stage_embedded_statics(dir: &str) {
    let subdir = format!("{dir}/static");
    if let Err(e) = fs::create_dir_all(&subdir) {
        if e.kind() != std::io::ErrorKind::AlreadyExists {
            eprintln!("fastapi_mojo: mkdir {subdir}: {e}");
            return;
        }
    }
    let files = embedded_static_files();
    for (name, start, end) in files {
        unsafe {
            let len = end.offset_from(start) as usize;
            let path = format!("{subdir}/{name}");
            write_all(&path, start, len);
        }
    }
}

unsafe fn remove_embedded_statics(dir: &str) {
    let subdir = format!("{dir}/static");
    let files = embedded_static_files();
    for (name, _, _) in files {
        remove_file_quiet(&format!("{subdir}/{name}"));
    }
    rmdir_quiet(&subdir);
}

unsafe fn remove_all_staged(dir: &str) {
    remove_file_quiet(&format!("{dir}/{STAGED_KGEN}"));
    remove_file_quiet(&format!("{dir}/{STAGED_MSUPP}"));
    remove_file_quiet(&format!("{dir}/{STAGED_ASYNC}"));
    remove_embedded_statics(dir);
    rmdir_quiet(dir);
}

unsafe fn bind_symbols() -> bool {
    let names: &[(&str, *mut Option<KgenFn6>)] = &[
        ("KGEN_CompilerRT_AlignedAlloc", &mut G_FP_ALIGNED_ALLOC),
        ("KGEN_CompilerRT_AlignedFree", &mut G_FP_ALIGNED_FREE),
        ("KGEN_CompilerRT_AsyncRT_GetCurrentCPUDevice", &mut G_FP_GET_CURRENT_CPU_DEVICE),
        ("KGEN_CompilerRT_AsyncRT_GetOrCreateCPUDevice", &mut G_FP_GET_OR_CREATE_CPU_DEVICE),
        ("KGEN_CompilerRT_AsyncRT_ReleaseCPUDevice", &mut G_FP_RELEASE_CPU_DEVICE),
        ("KGEN_CompilerRT_DestroyGlobals", &mut G_FP_DESTROY_GLOBALS),
        ("KGEN_CompilerRT_GetOrCreateGlobal", &mut G_FP_GET_OR_CREATE_GLOBAL),
        ("KGEN_CompilerRT_GetStackTrace", &mut G_FP_GET_STACK_TRACE),
        ("KGEN_CompilerRT_PrintStackTraceOnFault", &mut G_FP_PRINT_STACK_TRACE_ON_FAULT),
        ("KGEN_CompilerRT_SetArgV", &mut G_FP_SET_ARGV),
        ("KGEN_CompilerRT_fprintf", &mut G_FP_FPRINTF),
    ];
    for (name, slot) in names {
        let cname = std::ffi::CString::new(*name).unwrap();
        let p = dlsym(RTLD_DEFAULT, cname.as_ptr());
        if p.is_null() {
            let err = dlerror();
            let msg = if err.is_null() { "<no msg>".to_string() } else {
                unsafe { CStr::from_ptr(err).to_string_lossy().into_owned() }
            };
            eprintln!("fastapi_mojo: missing runtime symbol {name}: {msg}");
            return false;
        }
        **slot = Some(std::mem::transmute::<*mut c_void, KgenFn6>(p));
    }
    true
}

/// 用 pid 后缀生成唯一 stage 目录; mkdtemp 在 Rust 没有 portable 直接对应,
/// 用 create_dir + 自增后缀替代 (pid 死了后 sweep 会清理, 活 pid 不会冲突).
unsafe fn make_stage_dir(base: &str, pid: i32) -> Option<String> {
    for n in 0..1000 {
        let dir = format!("{base}/fastapi_mojo_rt_{pid}_{n}");
        match fs::create_dir(&dir) {
            Ok(()) => return Some(dir),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => { eprintln!("fastapi_mojo: mkdir {dir}: {e}"); return None; }
        }
    }
    None
}

unsafe fn try_stage(base: &str) -> bool {
    let pid = getpid();
    let dir = match make_stage_dir(base, pid) {
        Some(d) => d,
        None => return false,
    };

    write_payload(&dir, STAGED_KGEN,
        &_binary_payload_kgen_bin_start, &_binary_payload_kgen_bin_end);
    write_payload(&dir, STAGED_MSUPP,
        &_binary_payload_msupp_bin_start, &_binary_payload_msupp_bin_end);
    write_payload(&dir, STAGED_ASYNC,
        &_binary_payload_asyncrt_bin_start, &_binary_payload_asyncrt_bin_end);

    stage_embedded_statics(&dir);

    // LD_LIBRARY_PATH=<dir>
    let cname = std::ffi::CString::new("LD_LIBRARY_PATH").unwrap();
    let cval = std::ffi::CString::new(dir.as_str()).unwrap();
    setenv(cname.as_ptr(), cval.as_ptr(), 1);

    let kgen_path = format!("{dir}/{STAGED_KGEN}");
    let ckgen = std::ffi::CString::new(kgen_path.as_str()).unwrap();
    let h = dlopen(ckgen.as_ptr(), RTLD_NOW | RTLD_GLOBAL);
    if h.is_null() {
        let err = dlerror();
        let msg = if err.is_null() { "<no msg>".to_string() } else {
            CStr::from_ptr(err).to_string_lossy().into_owned()
        };
        eprintln!("fastapi_mojo: dlopen({kgen_path}) failed: {msg}");
        remove_all_staged(&dir);
        return false;
    }
    if !bind_symbols() {
        remove_all_staged(&dir);
        return false;
    }

    // g_stage_dir = dir
    let bytes = dir.as_bytes();
    let n = bytes.len().min(G_STAGE_DIR.len() - 1);
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), G_STAGE_DIR.as_mut_ptr() as *mut u8, n);
    G_STAGE_DIR[n] = 0;

    // set_embedded_static_dir("<dir>/static")
    let static_dir = format!("{dir}/static");
    super::state::set_embedded_static_dir(Some(&static_dir));

    vlog(&dir);
    true
}

/// atexit 回调: 清理 stage 目录
unsafe extern "C" fn runtime_cleanup() {
    // G_STAGE_DIR 是 [c_char;512] (= [i8;512]); 转 &[u8] 后再找 NUL
    let raw: &[u8] = unsafe {
        std::slice::from_raw_parts(G_STAGE_DIR.as_ptr() as *const u8, G_STAGE_DIR.len())
    };
    let end = raw.iter().position(|&b| b == 0).unwrap_or(0);
    if end == 0 { return; }
    let dir = match std::ffi::CStr::from_bytes_with_nul(&raw[..end + 1]) {
        Ok(c) => match c.to_str() { Ok(s) => s, Err(_) => return },
        Err(_) => return,
    };
    vlog(dir);
    remove_all_staged(dir);
}

/// SIGKILLed 前实例遗留的 stage 目录 self-heal: 仅清理 owning pid 已死的目录.
fn sweep_orphaned_stages(base: &str) {
    let entries = match fs::read_dir(base) {
        Ok(e) => e,
        Err(_) => return,
    };
    for e in entries.flatten() {
        let name = match e.file_name().into_string() {
            Ok(s) => s,
            Err(_) => continue,
        };
        if !name.starts_with("fastapi_mojo_rt_") { continue; }
        let suffix = &name["fastapi_mojo_rt_".len()..];
        // 找下划线分隔的 pid 部分
        let pid_str = match suffix.split('_').next() {
            Some(s) => s,
            None => continue,
        };
        let pid: i32 = match pid_str.parse() {
            Ok(n) if n > 0 => n,
            _ => continue,
        };
        unsafe {
            // kill(pid, 0) == 0 -> alive (leave); != 0 && errno == ESRCH -> dead (sweep)
            if kill(pid, 0) == 0 { continue; }
            if errno() != /* ESRCH */ 3 { continue; }
        }
        let dirpath = format!("{base}/{name}");
        // 递归删除整个孤儿目录 (含 static/ 子目录及其文件).
        // C 版只 unlink + 一级 rmdir, static/ 内文件导致清理失败 (残留);
        // 这里用 remove_dir_all 一次性递归清干净 (教训-12).
        if let Err(e) = fs::remove_dir_all(&dirpath) {
            eprintln!("fastapi_mojo: sweep {dirpath}: {e}");
        }
        vlog(&name);
    }
}

unsafe extern "C" fn kgen_runtime_bootstrap() {
    // FASTAPI_MOJO_DEBUG -> verbose log
    let cname = std::ffi::CString::new("FASTAPI_MOJO_DEBUG").unwrap();
    let p = getenv(cname.as_ptr());
    if !p.is_null() { G_VERBOSE = 1; }

    // sweep 孤儿 stage 目录
    sweep_orphaned_stages("/dev/shm");
    sweep_orphaned_stages("/tmp");

    if try_stage("/dev/shm") { atexit(runtime_cleanup); return; }
    if try_stage("/tmp")      { atexit(runtime_cleanup); return; }

    // 兜底: 可执行文件所在目录
    let mut exe = [0u8; 1024];
    let n = readlink(c"/proc/self/exe".as_ptr(), exe.as_mut_ptr() as *mut c_char, exe.len() - 1);
    if n > 0 {
        let exe_path = String::from_utf8_lossy(&exe[..n as usize]).into_owned();
        if let Some(slash) = exe_path.rfind('/') {
            let dir = &exe_path[..slash];
            if try_stage(dir) { atexit(runtime_cleanup); return; }
        }
    }

    eprintln!(
        "fastapi_mojo: fatal: could not stage the embedded Mojo runtime \
         (no writable location among /dev/shm, /tmp, the executable dir)"
    );
    exit(1);
}

// === 11 KGEN_CompilerRT_* forwarders (6-register ABI-safe) ===
macro_rules! kgen_forwarder {
    ($name:ident, $fp:ident) => {
        #[no_mangle]
        pub unsafe extern "C" fn $name(
            a1: *mut c_void, a2: *mut c_void, a3: *mut c_void,
            a4: *mut c_void, a5: *mut c_void, a6: *mut c_void,
        ) -> *mut c_void {
            unsafe { $fp.unwrap()(a1, a2, a3, a4, a5, a6) }
        }
    };
}

kgen_forwarder!(KGEN_CompilerRT_AlignedAlloc, G_FP_ALIGNED_ALLOC);
kgen_forwarder!(KGEN_CompilerRT_AlignedFree, G_FP_ALIGNED_FREE);
kgen_forwarder!(KGEN_CompilerRT_AsyncRT_GetCurrentCPUDevice, G_FP_GET_CURRENT_CPU_DEVICE);
kgen_forwarder!(KGEN_CompilerRT_AsyncRT_GetOrCreateCPUDevice, G_FP_GET_OR_CREATE_CPU_DEVICE);
kgen_forwarder!(KGEN_CompilerRT_AsyncRT_ReleaseCPUDevice, G_FP_RELEASE_CPU_DEVICE);
kgen_forwarder!(KGEN_CompilerRT_DestroyGlobals, G_FP_DESTROY_GLOBALS);
kgen_forwarder!(KGEN_CompilerRT_GetOrCreateGlobal, G_FP_GET_OR_CREATE_GLOBAL);
kgen_forwarder!(KGEN_CompilerRT_GetStackTrace, G_FP_GET_STACK_TRACE);
kgen_forwarder!(KGEN_CompilerRT_PrintStackTraceOnFault, G_FP_PRINT_STACK_TRACE_ON_FAULT);
kgen_forwarder!(KGEN_CompilerRT_SetArgV, G_FP_SET_ARGV);
kgen_forwarder!(KGEN_CompilerRT_fprintf, G_FP_FPRINTF);

// === constructor ===
// test 模式不注册: 单测不触发真实 staging / dlopen。
#[cfg(not(test))]
#[used]
#[link_section = ".init_array"]
static SHIM_BOOTSTRAP: unsafe extern "C" fn() = kgen_runtime_bootstrap;

// === test-only payload stubs (满足链接器; 单测不调用 try_stage) ===
#[cfg(test)]
mod test_payload_stubs {
    #[no_mangle] pub static _binary_payload_kgen_bin_start: u8 = 0;
    #[no_mangle] pub static _binary_payload_kgen_bin_end: u8 = 0;
    #[no_mangle] pub static _binary_payload_msupp_bin_start: u8 = 0;
    #[no_mangle] pub static _binary_payload_msupp_bin_end: u8 = 0;
    #[no_mangle] pub static _binary_payload_asyncrt_bin_start: u8 = 0;
    #[no_mangle] pub static _binary_payload_asyncrt_bin_end: u8 = 0;
}
