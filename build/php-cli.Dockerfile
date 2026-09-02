# syntax=docker/dockerfile:1
# ============================================================
# 产 php(NTS) cli 二进制 —— spc glibc 半静态（gnu.2.17）
# 决策：docs/static-php-runtime-discussion.md §3 #4（glibc，弃 musl）
#       §7（queue/scheduler 走 NTS：最稳象限 + 免 ZTS 税）
#
# 双 target：
#   - spc-env ：构建环境层（含 spc 本体与工具链），
#               docker build --target spc-env 产出交互调试镜像
#   - artifact：产物层（make binaries 用），仅含 php 二进制
#
# 输入：build/versions.env + build/extensions.txt（Makefile 注入 ARG）
# 输出：--target artifact → dist/php-cli
#       （Makefile 落位 build/artifacts/php-cli-linux-<arch>）
#
# ⚠️ M1 验证点（讨论文档 §9）：
#   - #7：--with-config-file-path=/etc/php（+ scan-dir /etc/php/conf.d）
#     能否传入 spc 构建。spc 经典命令 build:php 未直接暴露该编译选项——
#     首选路径：spc 的 build 选项/config 透传；若不支持的登记结论，
#     备选：生成后 post-check（php -i 确认实际路径）或评估 spc patch。
#   - SPC_TARGET / SPC_LIBC 的 glibc 传递（static-php-cli FAQ 示例：
#     SPC_LIBC=glibc spc build "…" --build-cli；旧写法 SPC_TARGET=native-native-gnu.2.17）
#   - spc 本体的下载校验（versions.env 的 SPC_VERSION 锚点方案）
#   - ✔ 已关闭：doctor 门——spc 2.8.6 在 trixie 的上游 bug（autopoint 无包可装，
#     见下方"工具链验证说明"）；依赖清单已按 doctor 输出固化在 apt 层
#   - ✔ 已收口（2026-09-02）：命令面统一为官方新语法 `spc build`（旧名 build:php
#     仍为文档在录命令，二者并存，非淘汰关系；cli 侧对应 --build-cli）
#   - ✔ 已收口（2026-09-02）：glibc 开关由 SPC_TARGET=native-native-gnu.2.17 改为
#     SPC_LIBC=glibc。旧取值是为"跨老发行版可移植"压低 glibc 下限，而产物只跑在
#     debian:trixie-slim 底座容器里（见下方"兼容性下限"注），无此需求；改用后走
#     trixie 原生工具链，glibc 要求与构建/运行时底座一致，并去掉 zig 一层工具链
# ============================================================

ARG SPC_ENV_BASE_IMAGE=debian:trixie-slim

# ------------------------------------------------------------
# 构建环境层（可交互）：docker build --target spc-env 的产物镜像
# ------------------------------------------------------------
FROM ${SPC_ENV_BASE_IMAGE} AS spc-env

ARG SPC_VERSION=nightly-pending
# spc 静态本体分发地址（self-contained，无需系统 PHP）
# ⚠️ TODO(M1)：SPC_VERSION 锚点定稿后，URL 随版本拼接 + sha256 校验
ARG SPC_DOWNLOAD_URL=https://dl.static-php.dev/static-php-cli/spc-bin/nightly/spc-linux-x86_64

# APT 源加速（国内构建）：trixie 为 DEB822 格式（/etc/apt/sources.list.d/debian.sources），
# 安全更新源在同一文件内（deb.debian.org/debian-security），一次 sed 同时替换（中科大方案）；
# 传空 build-arg（--build-arg APT_MIRROR=）可回退官方源。M3 的 images/*.Dockerfile 沿用此模式。
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
# ↑ 2026-08-16 依 spc doctor 输出补齐（M1 首编实测）：bison/re2c/flex/autoconf/
#   automake/libtoolize(libtool)/autopoint(gettext)——七件套缺一，build 预检即失败
#   （错误消息表现为误导性的 "Cannot find pkg-config executable"）

# 安装 spc 本体（self-contained 静态可执行）
RUN curl -fsSL "${SPC_DOWNLOAD_URL}" -o /usr/local/bin/spc \
    && chmod +x /usr/local/bin/spc \
    && spc --version || spc --help | head -3   # 冒烟自检: 能执行即装好

WORKDIR /work

# spc 自带工具包（2026-08-16 M1 定位，两条实测要点）：
#   ① pkg-config：spc 不认系统 /usr/bin/pkg-config——只查自身 pkgroot 路径，
#     缺它则 build 预检报误导性的 "Cannot find pkg-config executable"；
#     （2026-09-02：原 ② zig 已移除——改用 SPC_LIBC=glibc 走 trixie 原生工具链后
#      不再需要"面向低版本 glibc 的兼容编译器"；运行时下限即 trixie，见下方
#      "兼容性下限"注。TARGET_ARCH 命名陷阱在 zig 下取得，禁令按保守原则保留）
#   ② ⚠️ 必须在 WORKDIR /work 之后执行：install-pkg 按相对路径落盘 <cwd>/pkgroot/…，
#     spc 构建时也按 CWD 相对路径查找，WORKDIR 错位即全部找不到（第五轮教训）
#   本组命令是 doctor 对应修复项的等价直连，绕开 doctor 的 autopoint 上游 bug（见下）；
#   ⚠️ install-pkg 单命令只收一个包参数（空格多包报 Too many arguments）——多包须分多条 RUN
RUN spc install-pkg pkg-config

# 工具链验证说明（2026-08-16 M1 实测结论，替代 doctor 门）：
#   不在此跑 `spc doctor --auto-fix`——spc 2.8.6-nightly 在 Debian trixie 有上游 bug：
#   doctor 检查 autopoint 并尝试 `apt-get install autopoint`，但 trixie 没有任何
#   包提供 autopoint（gettext 0.22.5 文件清单已核验不含它）→ auto-fix 永远失败，
#   且会死在 pkg-config 修复项之前（连锁导致第 4 层排查）。七件套已上方预装
#   （doctor 除 autopoint 外的检查项全过）；工具齐备的最终验证由 build
#   自身预检承担。doctor 留作 spc-env 交互容器内诊断用（autopoint 缺失可人工判忽略）。

# ------------------------------------------------------------
# 构建执行层：在 spc-env 基础上跑下载 + 编译
# ------------------------------------------------------------
FROM spc-env AS build

ARG PHP_VERSION=8.5.9
ARG PHP_EXTENSIONS="bcmath"
# token 经 --secret id=github_token 注入（同 frankenphp.Dockerfile）而非 ARG/build-arg：
# build-arg 值参与缓存键，CI 每轮 token 轮换会让层缓存永远 miss。背景不变：
# 匿名 60/h 限额下 spc download 会退回 dl.static-php.dev 镜像源，而该源 TLS 偶发
# 不稳（2026-08-17 实测 curl 35），故注入 token 让 GitHub 主源直接成功。
# ⚠️ 教训（M1 第九轮）：禁止在此声明名为 TARGET_ARCH 的 ARG——ARG 会注入 RUN 环境变量，
#   而 make 内建隐式规则拼接 $(TARGET_ARCH)，编译器会把裸词 "x86_64" 当输入文件
#   （libargon2 的 Makefile 依赖隐式规则，是唯一受害者）。架构信息只活在 Makefile 侧。
#   注：原记载发生在 zig cc 下；2026-09-02 改用 trixie 原生工具链后未复验，
#   该禁令按保守原则保留（根因在 make 隐式规则拼接，未必随编译器消失）

# glibc 半静态（§3 #4：弃 musl 选 glibc——为保留 dlopen 之门，与发行版兼容无关）
# 产物 = mostly static：仅动态链 glibc，dlopen 之门保留（§4）
# 2026-09-02：SPC_TARGET=native-native-gnu.2.17 → SPC_LIBC=glibc
#   旧取值把 glibc 下限压到 2.17，属"跨老发行版可移植"的遗留要求；产物只跑在
#   debian:trixie-slim 底座容器内（见下方"兼容性下限"注），无此需求。
#   改用 SPC_LIBC=glibc 后走 trixie 原生工具链：glibc 要求 = 构建底座版本 = 运行时
#   底座版本，天然对齐；并省掉 zig 这一层工具链（见上方 install-pkg 注释）
ENV SPC_LIBC=glibc

# 两步走：先下载（php-src + 扩展依赖库），再编译（改扩展清单只重跑第二步）。
# 下载目录走 BuildKit cache mount（syntax=docker/dockerfile:1 特性）：
#   层缓存失效（改扩展清单/上层依赖）时无需全量重下，缓存卷独立于层生命周期，
#   且缓存内容不进镜像层；两步共享同一 target（编译步骤要读 downloads/）
#   docker builder prune 才清
# --prefer-pre-built（2026-09-02）：优先取有预编译包的依赖库，跳过本地编译——
#   省的是依赖库（openssl / curl / libxml2 / libzip / sqlite3 / oniguruma …），
#   与扩展清单选了什么无关；清单里主流库越多，收益越明显
#   ⚠️ 未验证：预编译包是否覆盖 gnu.2.17（glibc）目标——static-php 主目标是
#     musl-static，glibc 目标可能无包可命中（退化为 no-op，无害）
#   ---
#   兼容性下限（2026-09-02 拍板）：产物只在 docker 内运行，底座最低 debian:trixie-slim
#     ⇒ 基线是 trixie 自带的 glibc，不是 2.17。预编译包即便抬高要求也几乎不可能越界，
#       故本 flag 无"破坏可移植性"风险。核对（须 ≤ trixie 的 glibc 版本）：
#       objdump -T <bin> | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1
#       docker run --rm debian:trixie-slim ldd --version | head -1   # 取基线
RUN --mount=type=cache,target=/work/downloads \
    --mount=type=secret,id=github_token \
    export GITHUB_TOKEN="$(cat /run/secrets/github_token 2>/dev/null || true)" \
    && spc download --with-php="${PHP_VERSION}" \
                 --for-extensions="${PHP_EXTENSIONS}" \
                 --prefer-pre-built

RUN --mount=type=cache,target=/work/downloads \
    --mount=type=secret,id=github_token \
    export GITHUB_TOKEN="$(cat /run/secrets/github_token 2>/dev/null || true)" \
    && spc build "${PHP_EXTENSIONS}" --build-cli \
    --with-config-file-path=/etc/php \
    --with-config-file-scan-dir=/etc/php/conf.d
# ↑ §9 #7（2026-08-16 M1 收口落地）：与 frankenphp 侧统一为 /etc/php（+conf.d）。
#   依据：官方 gnu 镜像即以 SPC_OPT_BUILD_ARGS 传同款 flag（frankenphp 线已实测生效，
#   产物 phpinfo 确认 Configuration File Path => /etc/php）；本行 flag 属同一 spc 选项域

# ------------------------------------------------------------
# 产物层：仅 php 二进制（Makefile 侧重命名为 php-cli-linux-<arch>）
# ⚠️ COPY 到根级（/php-cli）：buildkit 本地导出保留层内完整路径，
#   拷到 /dist/ 会导致导出产物落在 .dist/dist/ 下（M1 第十轮教训）
# ------------------------------------------------------------
FROM scratch AS artifact
COPY --from=build /work/buildroot/bin/php /php-cli
