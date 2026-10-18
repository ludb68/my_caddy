# syntax=docker/dockerfile:1
#
# 自定义 Caddy（xcaddy 编译插件）+ Cloudflare 插件
# 一阶段：官方 caddy:<ver>-builder 镜像里跑 xcaddy，编出带插件的 caddy 二进制
# 二阶段：把二进制覆盖进官方 caddy:<ver> 运行时镜像（保持官方目录结构/ENTRYPOINT）

ARG CADDY_VERSION=2.11.7

# ---------------- build stage ----------------
FROM caddy:${CADDY_VERSION}-builder AS builder

# builder 镜像已内置：xcaddy、WORKDIR=/usr/bin、ENV XCADDY_SETCAP=1、ENV CADDY_VERSION=vX.Y.Z
# 仓库内自带的本地插件（plugins.txt 里写成 pkg=相对路径 的会被 xcaddy 当成 replace）
COPY plugins /src/plugins

ARG CADDY_VERSION
# 空格分隔的插件列表（pkg 或 pkg@version），由 CI 从 plugins.txt 生成
ARG CADDY_PLUGINS=""
# 编译完做自检：对 `caddy list-modules` 做 grep -E，空则跳过
ARG VERIFY_MODULES="cloudflare"

# 统一 Caddy 版本号：2.11.7 → v2.11.7；填 branch/commit 时原样保留
# 逐个插件展开成 --with pkg 参数（支持 pkg@version）
# 最后对编译产物做自检：版本、模块数、VERIFY_MODULES 关键字必须命中
RUN set -eux; \
    ver="${CADDY_VERSION#v}"; \
    case "$ver" in [0-9]*) ver="v$ver" ;; esac; \
    with_args=""; \
    for p in ${CADDY_PLUGINS}; do with_args="${with_args} --with ${p}"; done; \
    xcaddy build "${ver}" --output /usr/bin/caddy ${with_args}; \
    /usr/bin/caddy version; \
    /usr/bin/caddy list-modules | wc -l; \
    if [ -n "${VERIFY_MODULES}" ]; then /usr/bin/caddy list-modules | grep -E "${VERIFY_MODULES}"; fi

# ---------------- runtime stage ----------------
FROM caddy:${CADDY_VERSION}

ARG CADDY_VERSION

LABEL org.opencontainers.image.title="caddy-custom" \
      org.opencontainers.image.description="Caddy built with xcaddy: cloudflare dns, cloudflare trusted proxies" \
      org.opencontainers.image.licenses="Apache-2.0" \
      caddy.version="${CADDY_VERSION}"

# 用编译出来的 caddy 覆盖官方二进制（官方镜像里就是 /usr/bin/caddy）
COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# 落盘日志目录（默认日志走 stdout，docker logs 直接看；用 file 输出时才需要这个目录）
RUN set -eux; \
    mkdir -p /var/log/caddy; \
    chmod 1777 /var/log/caddy; \
    caddy version

# 默认 Caddyfile（:80 健康检查；真实站点写在里面注释里，改成你的域名再放开）
COPY Caddyfile /etc/caddy/Caddyfile

# 官方镜像已有：ENTRYPOINT 无、CMD ["caddy","run","--config","/etc/caddy/Caddyfile","--adapter","caddyfile"]
# 端口：80 443 443/udp 2019
