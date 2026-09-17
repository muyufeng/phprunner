# syntax=docker/dockerfile:1
# ============================================================
# 产 php(NTS) cli 二进制 —— spc glibc 半静态（mostly static：仅动态链 glibc）
# 决策：glibc 半静态（弃 musl 以保留 dlopen）；NTS SAPI
#
# target：spc-env = 构建环境（可交互调试）；artifact = 仅 php 二进制
# 输入：build/versions.env + extensions.txt + libs.txt（一律 Makefile 注入 ARG）
# 输出：--target artifact → /php-cli（Makefile 落位 artifacts/php-cli-linux-<arch>）
#
# 已收口：ini 路径 /etc/php(+conf.d)；glibc 开关改 SPC_LIBC=glibc
#         （2026-09-02，弃 SPC_TARGET=native-native-gnu.2.17）；命令面用新语法 spc build
# 未闭合：SPC_VERSION 锚点定稿后，SPC_DOWNLOAD_URL 随版本拼接 + sha256 校验
# ============================================================

ARG SPC_ENV_BASE_IMAGE=debian:trixie-slim

# ------------------------------------------------------------
# 构建环境层（可交互）：docker build --target spc-env
# ------------------------------------------------------------
FROM ${SPC_ENV_BASE_IMAGE} AS spc-env

ARG SPC_VERSION=nightly-pending
# spc 自身静态分发（self-contained，不依赖系统 PHP）
ARG SPC_DOWNLOAD_URL=https://dl.static-php.dev/static-php-cli/spc-bin/nightly/spc-linux-x86_64

# APT 源加速（国内）：trixie 为 DEB822 格式，deb.debian.org 与安全源同文件，一次 sed
# 替换；传空 --build-arg APT_MIRROR= 回退官方源。M3 镜像层沿用此模式
ARG APT_MIRROR=mirrors.ustc.edu.cn
RUN if [ -n "${APT_MIRROR}" ]; then \
        sed -i "s/deb.debian.org/${APT_MIRROR}/g" /etc/apt/sources.list.d/debian.sources; \
    fi \
    && apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        xz-utils \
        unzip \
        pkg-config \
        make \
        build-essential \
        cmake \
        bison \
        re2c \
        flex \
        autoconf \
        automake \
        gettext \
        libtool \
    && rm -rf /var/lib/apt/lists/*
# ↑ 工具链按 spc doctor 输出固化（2026-08-16 M1 首编）：bison/re2c/flex/autoconf/
#   automake/libtool/gettext 缺一则 build 预检失败，且报错误导为
#   "Cannot find pkg-config executable"

# 安装 spc 本体（self-contained 静态可执行）
RUN curl -fsSL "${SPC_DOWNLOAD_URL}" -o /usr/local/bin/spc \
    && chmod +x /usr/local/bin/spc \
    && spc --version || spc --help | head -3   # 冒烟自检: 能执行即装好

WORKDIR /work

# pkg-config 必须走 spc 自带包：spc 只查自身 pkgroot，不认系统 /usr/bin/pkg-config，
# 缺它则预检报 "Cannot find pkg-config executable"。
# ⚠️ 两条硬约束：① 必须在 WORKDIR /work 之后——install-pkg 按 CWD 相对落盘
#    <cwd>/pkgroot，spc 构建也按 CWD 查找，错位即全部找不到（第五轮教训）；
#    ② 单命令只收一个包参数，多包须分多条 RUN
# 此处 = doctor 修复项的等价直连，绕开 doctor 的 autopoint 上游 bug（见下）
RUN spc install-pkg pkg-config

# 不跑 spc doctor --auto-fix（2026-08-16 结论）：spc 2.8.6-nightly 在 trixie 有上游 bug
# ——doctor 要装 autopoint，而 trixie 无任何包提供（gettext 0.22.5 清单已核验），
# auto-fix 必败且挡在 pkg-config 修复项之前（连锁致第 4 层排查）。工具齐备由 build
# 自身预检兜底；doctor 仅留作 spc-env 交互容器内诊断（autopoint 缺失可人工判忽略）

# ------------------------------------------------------------
# 构建执行层：下载 + 编译
# ------------------------------------------------------------
FROM spc-env AS build

ARG PHP_VERSION=8.5.10
ARG PHP_EXTENSIONS="bcmath"
# 可选依赖库（扩展依赖闭包之外，如 gd 的 freetype/libjpeg/libwebp/libavif）：Makefile
# 从 libs.txt 注入；空值条件拼参——spc 对空串参数的行为未验证，不赌
# ⚠️ 两阶段参数面不同名（2026-09-16 实测）：download 只收 --for-libs，--with-libs 是
#    build 的选项；download 侧误用 --with-libs 会以 "option does not exist" 立即退出 1
ARG PHP_EXTENSION_LIBS=""
# token 走 --secret 而非 ARG/build-arg（同 frankenphp 线）：build-arg 值参与缓存键，
# CI 每轮轮换会让层缓存永远 miss；secret 不进缓存键、不落 history。
# 背景：匿名 60/h 限额下 spc download 退回 dl.static-php.dev 镜像源，该源 TLS 偶发
# 不稳（2026-08-17 实测 curl 35），注入 token 让 GitHub 主源直接成功
# ⚠️ 禁令：禁止声明名为 TARGET_ARCH 的 ARG——ARG 会注入 RUN 环境变量，make 隐式规则
#   拼出裸词被当输入文件（libargon2 唯一受害者）。架构信息只活在 Makefile 侧。
#   （原记载发生于 zig cc；改原生工具链后未复验，按保守原则保留）

# glibc 半静态：仅动态链 glibc，dlopen 之门保留
# 2026-09-02：SPC_TARGET=native-native-gnu.2.17 → SPC_LIBC=glibc。旧值意在压低 glibc
# 下限以跨老发行版；而产物只跑 debian:trixie-slim ⇒ 构建底座 = 运行时底座，天然对齐，
# 并省掉 zig 一层工具链（见上方 install-pkg 注）
ENV SPC_LIBC=glibc

# 两步走（download → build）+ BuildKit cache mount：层缓存失效时无需全量重下，缓存卷
# 独立于层生命周期且不进镜像层（docker builder prune 才清）；改扩展清单只重跑第二步。
# --prefer-pre-built（2026-09-02）：优先取预编译依赖库（openssl/curl/libxml2/libzip/
# sqlite3/oniguruma…），与清单选什么无关，省本地编译；⚠️ 未验证 glibc 目标是否有包
# 命中（spc 主目标是 musl-static；未命中退化为 no-op，无害）。
# 兼容性下限（2026-09-02 拍板）：产物只在 docker 内跑、底座最低 trixie ⇒ 基线是 trixie
# 的 glibc 而非 2.17，预编译包抬高的要求不会越界。核对：objdump -T <bin> |
# grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1，对比 debian:trixie-slim 的 ldd --version
RUN --mount=type=cache,target=/work/downloads \
    --mount=type=secret,id=github_token \
    export GITHUB_TOKEN="$(cat /run/secrets/github_token 2>/dev/null || true)" \
    && case "${PHP_EXTENSION_LIBS:-}" in '') DL_LIBS_ARGS='' ;; *) DL_LIBS_ARGS="--for-libs=${PHP_EXTENSION_LIBS}" ;; esac \
    && spc download --with-php="${PHP_VERSION}" \
                 --for-extensions="${PHP_EXTENSIONS}" \
                 --prefer-pre-built ${DL_LIBS_ARGS}

RUN --mount=type=cache,target=/work/downloads \
    --mount=type=secret,id=github_token \
    export GITHUB_TOKEN="$(cat /run/secrets/github_token 2>/dev/null || true)" \
    && case "${PHP_EXTENSION_LIBS:-}" in '') LIBS_ARGS='' ;; *) LIBS_ARGS="--with-libs=${PHP_EXTENSION_LIBS}" ;; esac \
    && spc build "${PHP_EXTENSIONS}" --build-cli ${LIBS_ARGS} \
    --with-config-file-path=/etc/php \
    --with-config-file-scan-dir=/etc/php/conf.d
# ↑ ini 路径收口：与 frankenphp 侧统一为 /etc/php(+conf.d)。依据：官方 gnu 镜像即以
#   SPC_OPT_BUILD_ARGS 传同款 flag（frankenphp 线实测 phpinfo 已生效），同属 spc 选项域

# ------------------------------------------------------------
# 产物层：仅 php 二进制（Makefile 侧重命名为 php-cli-linux-<arch>）
# ⚠️ COPY 到根级：buildkit 本地导出保留层内完整路径，拷 /dist/ 会导出到 .dist/dist/
#    （M1 第十轮教训）
# ------------------------------------------------------------
FROM scratch AS artifact
COPY --from=build /work/buildroot/bin/php /php-cli
