// runtime_shim.c — Mojo runtime bootstrap for the single-binary build.
//
// The final executable embeds the three Mojo runtime shared libraries
// (libKGENCompilerRTShared.so, libMSupportGlobals.so, libAsyncRTRuntimeGlobals.so)
// as raw data. The data lives in objects built with:
//
//     objcopy -I binary -O elf64-x86-64 payload_kgen.bin   payload_kgen.o
//
// which exports `payload_kgen_start` / `payload_kgen_end` (and _size) symbols.
//
// At process start (before main), the constructor below:
//   1. stages the three .so files into a private temp directory,
//   2. points LD_LIBRARY_PATH at it (so the KGEN runtime's own DT_NEEDED on
//      the sibling runtime libs resolves from the staged copy),
//   3. dlopen()s the KGEN runtime with RTLD_NOW | RTLD_GLOBAL,
//   4. binds the 11 KGEN_CompilerRT_* C-API entry points referenced by the
//      compiled Mojo code.
//
// The 11 exported KGEN_CompilerRT_* symbols are thin forwarders. Every call
// site in the generated Mojo object passes at most two pointer/integer
// arguments (verified by disassembly of server.o), so forwarding the first
// six integer registers (SysV x86-64: rdi rsi rdx rcx r8 r9) is ABI-safe.
// No call site passes floating-point register arguments.

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

/* ---------- embedded payload data ---------- */
/*
 * The three Mojo runtime .so files are embedded as raw binary data via
 * `objcopy -I binary`, which emits <name>_start / <name>_end / <name>_size
 * symbols. The exact symbol names depend on the input file path, so the
 * build script extracts them with `nm` and injects them here as macros
 * (-DKGEN_PAYLOAD_START=... etc.). They are plain C identifiers.
 */
extern char KGEN_PAYLOAD_START[];
extern char KGEN_PAYLOAD_END[];
extern char MSUPP_PAYLOAD_START[];
extern char MSUPP_PAYLOAD_END[];
extern char ASYNCRT_PAYLOAD_START[];
extern char ASYNCRT_PAYLOAD_END[];

#define STAGED_KGEN   "libKGENCompilerRTShared.so"
#define STAGED_MSUPP  "libMSupportGlobals.so"
#define STAGED_ASYNC  "libAsyncRTRuntimeGlobals.so"

/* ---------- KGEN C-API forwarders ---------- */

typedef void *(*kgen_fn6_t)(void *, void *, void *, void *, void *, void *);

static kgen_fn6_t g_fp_aligned_alloc;
static kgen_fn6_t g_fp_aligned_free;
static kgen_fn6_t g_fp_get_current_cpu_device;
static kgen_fn6_t g_fp_get_or_create_cpu_device;
static kgen_fn6_t g_fp_release_cpu_device;
static kgen_fn6_t g_fp_destroy_globals;
static kgen_fn6_t g_fp_get_or_create_global;
static kgen_fn6_t g_fp_get_stack_trace;
static kgen_fn6_t g_fp_print_stack_trace_on_fault;
static kgen_fn6_t g_fp_set_argv;
static kgen_fn6_t g_fp_fprintf;

static char g_stage_dir[512] = {0};
static int g_verbose = 0;

static void vlog(const char *msg) {
    if (!g_verbose) return;
    fputs("[fastapi_mojo:shim] ", stderr);
    fputs(msg, stderr);
    fputc('\n', stderr);
}

static void stage_file(const char *dir, const char *name, const char *data, size_t len) {
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "wb");
    if (!f) {
        fprintf(stderr, "fastapi_mojo: cannot write %s: %s\n", path, strerror(errno));
        return;
    }
    if (len > 0 && fwrite(data, 1, len, f) != len) {
        fprintf(stderr, "fastapi_mojo: short write to %s\n", path);
    }
    fclose(f);
    chmod(path, 0755);
}

static void remove_stage_file(const char *dir, const char *name) {
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    (void)unlink(path);
}

static void remove_all_staged(const char *dir) {
    remove_stage_file(dir, STAGED_KGEN);
    remove_stage_file(dir, STAGED_MSUPP);
    remove_stage_file(dir, STAGED_ASYNC);
    (void)rmdir(dir);
}

static int bind_symbols(void) {
    struct { const char *sym; kgen_fn6_t *fp; } need[] = {
        { "KGEN_CompilerRT_AlignedAlloc",               &g_fp_aligned_alloc },
        { "KGEN_CompilerRT_AlignedFree",               &g_fp_aligned_free },
        { "KGEN_CompilerRT_AsyncRT_GetCurrentCPUDevice", &g_fp_get_current_cpu_device },
        { "KGEN_CompilerRT_AsyncRT_GetOrCreateCPUDevice", &g_fp_get_or_create_cpu_device },
        { "KGEN_CompilerRT_AsyncRT_ReleaseCPUDevice",  &g_fp_release_cpu_device },
        { "KGEN_CompilerRT_DestroyGlobals",            &g_fp_destroy_globals },
        { "KGEN_CompilerRT_GetOrCreateGlobal",         &g_fp_get_or_create_global },
        { "KGEN_CompilerRT_GetStackTrace",             &g_fp_get_stack_trace },
        { "KGEN_CompilerRT_PrintStackTraceOnFault",    &g_fp_print_stack_trace_on_fault },
        { "KGEN_CompilerRT_SetArgV",                   &g_fp_set_argv },
        { "KGEN_CompilerRT_fprintf",                   &g_fp_fprintf },
    };
    for (size_t i = 0; i < sizeof need / sizeof need[0]; i++) {
        void *p = dlsym(RTLD_DEFAULT, need[i].sym);
        if (!p) {
            fprintf(stderr, "fastapi_mojo: missing runtime symbol %s: %s\n",
                    need[i].sym, dlerror());
            return 0;
        }
        *need[i].fp = (kgen_fn6_t)p;
    }
    return 1;
}

static int try_stage(const char *base) {
    char tmpl[512];
    snprintf(tmpl, sizeof tmpl, "%s/fastapi_mojo_rt_%d_XXXXXX", base, (int)getpid());
    char *dir = mkdtemp(tmpl);
    if (!dir) return 0;

    stage_file(dir, STAGED_KGEN, KGEN_PAYLOAD_START,
               (size_t)(KGEN_PAYLOAD_END - KGEN_PAYLOAD_START));
    stage_file(dir, STAGED_MSUPP, MSUPP_PAYLOAD_START,
               (size_t)(MSUPP_PAYLOAD_END - MSUPP_PAYLOAD_START));
    stage_file(dir, STAGED_ASYNC, ASYNCRT_PAYLOAD_START,
               (size_t)(ASYNCRT_PAYLOAD_END - ASYNCRT_PAYLOAD_START));

    setenv("LD_LIBRARY_PATH", dir, 1);

    char kgen_path[1024];
    snprintf(kgen_path, sizeof kgen_path, "%s/%s", dir, STAGED_KGEN);
    void *h = dlopen(kgen_path, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        fprintf(stderr, "fastapi_mojo: dlopen(%s) failed: %s\n", kgen_path, dlerror());
        remove_all_staged(dir);
        return 0;
    }
    if (!bind_symbols()) {
        remove_all_staged(dir);
        return 0;
    }

    strncpy(g_stage_dir, dir, sizeof g_stage_dir - 1);
    g_stage_dir[sizeof g_stage_dir - 1] = 0;
    vlog(dir);
    return 1;
}

static void runtime_cleanup(void) {
    if (g_stage_dir[0]) {
        vlog(g_stage_dir);
        remove_all_staged(g_stage_dir);
    }
}

__attribute__((constructor)) static void kgen_runtime_bootstrap(void) {
    if (getenv("FASTAPI_MOJO_DEBUG")) g_verbose = 1;

    /* /dev/shm (RAM) first: no disk I/O, exec permissions for dlopen. */
    if (try_stage("/dev/shm")) { atexit(runtime_cleanup); return; }
    if (try_stage("/tmp"))      { atexit(runtime_cleanup); return; }

    /* Last resort: the directory containing this executable (if writable). */
    char exe[1024];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (n > 0) {
        exe[n] = 0;
        char *slash = strrchr(exe, '/');
        if (slash && slash != exe) {
            *slash = 0;
            if (try_stage(exe)) { atexit(runtime_cleanup); return; }
        }
    }

    fprintf(stderr,
            "fastapi_mojo: fatal: could not stage the embedded Mojo runtime "
            "(no writable location among /dev/shm, /tmp, the executable dir)\n");
    exit(1);
}

/*
 * The 11 KGEN C-API entry points. Generic 6-register forwarders; see the
 * header comment for why this is ABI-safe for every call site in server.o.
 */
void *KGEN_CompilerRT_AlignedAlloc(void *a1, void *a2, void *a3, void *a4, void *a5, void *a6) {
    return g_fp_aligned_alloc(a1, a2, a3, a4, a5, a6);
}
void *KGEN_CompilerRT_AlignedFree(void *a1, void *a2, void *a3, void *a4, void *a5, void *a6) {
    return g_fp_aligned_free(a1, a2, a3, a4, a5, a6);
}
void *KGEN_CompilerRT_AsyncRT_GetCurrentCPUDevice(void *a1, void *a2, void *a3, void *a4, void *a5, void *a6) {
    return g_fp_get_current_cpu_device(a1, a2, a3, a4, a5, a6);
}
void *KGEN_CompilerRT_AsyncRT_GetOrCreateCPUDevice(void *a1, void *a2, void *a3, void *a4, void *a5, void *a6) {
    return g_fp_get_or_create_cpu_device(a1, a2, a3, a4, a5, a6);
}
void *KGEN_CompilerRT_AsyncRT_ReleaseCPUDevice(void *a1, void *a2, void *a3, void *a4, void *a5, void *a6) {
    return g_fp_release_cpu_device(a1, a2, a3, a4, a5, a6);
}
void *KGEN_CompilerRT_DestroyGlobals(void *a1, void *a2, void *a3, void *a4, void *a5, void *a6) {
    return g_fp_destroy_globals(a1, a2, a3, a4, a5, a6);
}
void *KGEN_CompilerRT_GetOrCreateGlobal(void *a1, void *a2, void *a3, void *a4, void *a5, void *a6) {
    return g_fp_get_or_create_global(a1, a2, a3, a4, a5, a6);
}
void *KGEN_CompilerRT_GetStackTrace(void *a1, void *a2, void *a3, void *a4, void *a5, void *a6) {
    return g_fp_get_stack_trace(a1, a2, a3, a4, a5, a6);
}
void *KGEN_CompilerRT_PrintStackTraceOnFault(void *a1, void *a2, void *a3, void *a4, void *a5, void *a6) {
    return g_fp_print_stack_trace_on_fault(a1, a2, a3, a4, a5, a6);
}
void *KGEN_CompilerRT_SetArgV(void *a1, void *a2, void *a3, void *a4, void *a5, void *a6) {
    return g_fp_set_argv(a1, a2, a3, a4, a5, a6);
}
void *KGEN_CompilerRT_fprintf(void *a1, void *a2, void *a3, void *a4, void *a5, void *a6) {
    return g_fp_fprintf(a1, a2, a3, a4, a5, a6);
}
