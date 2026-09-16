# syntax=docker/dockerfile:1
# ============================================================
# 产 frankenphp(ZTS) 二进制 —— 官方 static-builder-gnu 薄包装
# 决策：官方 builder 薄包装（内部即 spc 编 libphp；Go 侧集成交还原作者）
#
# 输入：build/versions.env + extensions.txt + libs.txt（一律根 Makefile 注入 ARG；
#       本文件不出现任何具体版本号/扩展名/库名——单一事实源不变量）
# 输出：--target artifact → /frankenphp-linux-x86_64（Makefile 落位 artifacts/）
# 调用：勿手跑，走 make binaries
#
# 已收口：build-static.sh 于 build 期执行可行（2026-08-16 M1 产物即冒烟基座；原
#         compose 运行时回退方案已随 docker-compose.yaml 移除）
# 既有结论：SPC_REL_TYPE 仅 source/binary、无 pin 接口 ⇒ 唯一稳态锚点 =
#         STATIC_BUILDER_IMAGE digest（versions.env 必填）
# Caddy 模块：不设 XCADDY_ARGS = 官方默认集（标准 + frankenphp + cbrotli/mercure/
#         vulcain）；一旦自定义必须显式 --with 列全，否则三件套静默丢失
# ============================================================

ARG STATIC_BUILDER_IMAGE=dunglas/frankenphp:static-builder-gnu
FROM ${STATIC_BUILDER_IMAGE} AS builder

# --- 参数（全部由 Makefile 从 versions.env / extensions.txt / libs.txt 注入）---
ARG FRANKENPHP_VERSION=1.12.7
ARG PHP_VERSION=8.5.10
# 扩展名即 spc 扩展名（官方 builder 直接透传内部 spc）
ARG PHP_EXTENSIONS="bcmath"
# 可选依赖库（闭包之外，如 gd 的 freetype/libjpeg/libwebp/libavif）：官方接口，
# 逗号分隔，内部即透传 spc --with-libs
ARG PHP_EXTENSION_LIBS=""
# token 走 --secret 而非 ARG/build-arg：build-arg 值参与 BuildKit 缓存键，CI 每轮
# GITHUB_TOKEN 轮换会让层缓存永远 miss；secret 不进缓存键、不落 history。
# 密钥约定：fine-grained PAT、零权限（公开仓库读取仅提限额）+ 短有效期，禁止入库

# 官方脚本环境变量接口（frankenphp.dev/docs/static；全量见 build-static.sh 头注）：
#   NO_COMPRESS=1 —— 关掉官方默认 UPX（解压内存/启动代价 + 扫描器误报）
#   SPC_OPT_BUILD_ARGS —— 官方 gnu 镜像默认 ini 路径为 /etc/frankenphp(+php.d)，此处
#     覆盖为 /etc/php(+conf.d)，与 php-cli 侧对齐即实现双二进制统一；
#     保留原有 --debug（spc 构建详日志，长跑监控用）
ENV FRANKENPHP_VERSION=${FRANKENPHP_VERSION} \
    PHP_VERSION=${PHP_VERSION} \
    PHP_EXTENSIONS=${PHP_EXTENSIONS} \
    PHP_EXTENSION_LIBS=${PHP_EXTENSION_LIBS} \
    SPC_OPT_BUILD_ARGS="--with-config-file-path=/etc/php --with-config-file-scan-dir=/etc/php/conf.d --debug" \
    NO_COMPRESS=1

# 官方镜像内：源码树 /go/src/app，入口 build-static.sh，产物落
# /go/src/app/dist/frankenphp-linux-<arch>
# ⚠️ 先清过期 buildroot（2026-08-16 M1 教训）：官方镜像自带一次按其默认扩展集的构建
#   残留（libzip.a 带 BZ2 引用），与本扩展集不符 → 链接 undefined reference
#   （frankenphp #2395 族）。只清 buildroot，保留 downloads 缓存与 spc 本体
#   （比官方 CLEAN=1 全清省时；仍失败再升级）
# re2c 预装（2026-08-16 两轮迭代定稿）：当日 spc nightly doctor 要求 re2c，官方镜像
#   （CentOS 7 底座）未装且仓库无此包，yum 修复必败（spc nightly 漂移的又一实证）。
#   选 2.2 版：4.x 构建系统需 Python≥3.7（镜像无 python3），2.x 纯 autotools；官方
#   release 资产仅 tar.xz/lz ⇒ 用 GitHub tag 自动打包 + 先跑 autogen.sh。php-src 发布
#   包自带生成文件，实际编译不依赖 re2c，纯为过 doctor 检查
RUN cd /tmp && curl -fsSL -o re2c.tgz \
        https://github.com/skvadrik/re2c/archive/refs/tags/2.2.tar.gz \
    && tar xf re2c.tgz && cd re2c-2.2 \
    && ./autogen.sh && ./configure --prefix=/usr/local \
    && make -j"$(nproc)" && make install \
    && re2c --version && cd / && rm -rf /tmp/re2c*

# 下载走 BuildKit cache mount（同 php-cli 线）：失败重跑不再全量重下 45 个源
# ⚠️ 容错（2026-08-16 M1 实测）：spc 圆满完成（Build complete + embed/version 自检全过）
#   后，build-static.sh 收尾记账步骤仍可能非零退出并连坐整个 RUN 层。处置：容忍其
#   退出码，以产物存在性为准——buildroot/bin/frankenphp 正是 sanity check 验过的那份
RUN --mount=type=cache,target=/go/src/app/dist/static-php-cli/downloads \
    --mount=type=secret,id=github_token \
    export GITHUB_TOKEN="$(cat /run/secrets/github_token 2>/dev/null || true)" \
    && cd /go/src/app && rm -rf dist/static-php-cli/buildroot \
    && { ./build-static.sh || echo "⚠️ build-static.sh 非零退出（收尾记账），以产物为准"; } \
    && ls -lh dist/static-php-cli/buildroot/bin/ \
    && test -x dist/static-php-cli/buildroot/bin/frankenphp

# ---- 产物层：空基础 + 仅二进制，供 --output type=local 原样导出 ----
# ⚠️ 两个落点讲究（M1 实测教训）：
#   ① COPY 到根级：buildkit 本地导出保留层内完整路径（.dist/frankenphp-linux-<arch>）
#   ② 取自 buildroot/bin/frankenphp（sanity check 验证过的原件），不取 dist/ 拷贝件
#      ——后者依赖 build-static.sh 的收尾 cp 步骤（该步骤有非零退出的前科）
FROM scratch AS artifact
COPY --from=builder /go/src/app/dist/static-php-cli/buildroot/bin/frankenphp /frankenphp-linux-x86_64
