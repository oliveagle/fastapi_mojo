# syntax=docker/dockerfile:1.7
# Dockerfile — fastapi_mojo production runtime (G3-v0.6).
#
# ⚠️  本 Dockerfile 默认假设 binary 已在 host 上 ./build_single.sh 预构建:
#      docker build -t fastapi_mojo:dev .
#      docker run --rm -p 8080:8000 fastapi_mojo:dev
#
# 如需在容器内完整 build (CI 多阶段场景), 用 Dockerfile.full (含 Rust + Mojo toolchain).
#
# 为什么 runtime 用 ubuntu:24.04 而不是 distroless:
#   host (Ubuntu 24.04, glibc 2.39) 预构建的 binary 链接了 GLIBC_2.39 符号
#   (pidfd_spawnp / pidfd_getpid, Rust std 引入), distroless cc-debian12
#   (glibc 2.36) 无法加载. 若要在 distroless 上跑, 必须用 Dockerfile.full
#   在容器内 (bookworm, glibc 2.36) 完整构建 → 链接 2.36 → distroless 可跑.
#
# 镜像大小: ~33MB (ubuntu:24.04 + 1 个 2.85MB binary).
# 运行期依赖: libc only (ldd 已实测).
# 用户: nonroot (系统新建 fastapi 用户, 非容器 root).

# ---------- Stage 1: builder (host-built binary 拷贝) ----------
FROM scratch AS builder
COPY build/fastapi_mojo /fastapi_mojo

# ---------- Stage 2: runtime (ubuntu 24.04, glibc 2.39) ----------
FROM ubuntu:24.04 AS runtime

# 最小运行期: 只需 binary + nonroot 用户 + tzdata (TLS/CA 当前不依赖).
# 不装任何包管理器 / shell 扩展 (保持最小攻击面).
RUN useradd -r -s /usr/sbin/nologin -u 10001 fastapi 2>/dev/null || true

COPY --from=builder /fastapi_mojo /usr/local/bin/fastapi_mojo

USER fastapi

EXPOSE 8000

# 默认参数 (可被 docker run 覆盖):
#   --host 0.0.0.0   监听所有接口 (容器内)
#   --port 8000       (default; container port 8080 -> host)
#   --workers 0       auto = CPU 数 (pre-fork + SO_REUSEPORT)
ENTRYPOINT ["/usr/local/bin/fastapi_mojo"]
CMD ["--host", "0.0.0.0", "--port", "8000", "--workers", "0"]
