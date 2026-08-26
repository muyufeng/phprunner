# syntax=docker/dockerfile:1
# ============================================================
# 产 frankenphp(ZTS) 二进制 —— 官方 static-builder-gnu 薄包装
# 决策：docs/static-php-runtime-discussion.md §3 #11（选方案①：官方 builder，
#       内部即 spc 编 libphp；风险守恒——Go 侧集成交还原作者）
#
# 输入：build/versions.env + build/extensions.txt（一律由根 Makefile 注入 ARG，
#       本文件不出现任何具体版本号/扩展名——单一事实源不变量）
# 输出：--target artifact → dist/frankenphp-linux-<arch>
#       （Makefile 落位 build/artifacts/frankenphp-linux-<arch>）
#
# 调用方（勿手跑，走 make binaries）：
#   docker buildx build -f build/frankenphp.Dockerfile \
#     --target artifact -o type=local,dest=… build/
#
# ⚠️ M1 验证点（docs/static-php-runtime-discussion.md §9）：
#   - #12：官方 builder 内部 spc 版本锁定方式（static-builder.Dockerfile
#     是否提供 ARG；可 pin 则回填 versions.env，实现双 spc 统一）
#   - build-static.sh 在 RUN 阶段调用的可行性：官方默认流程是镜像
#     ENTRYPOINT 运行时执行构建 + docker cp 提取；本包装改为 build 期
#     固化参数执行。✔ 已验证成立（2026-08-16 M1 产物即全套冒烟基座），
#     原 compose 运行时回退方案随 docker-compose.yaml 一并移除。
#   - 需要时经 --secret 注入 GITHUB_TOKEN 避开 API 限流（build-static.sh 读同名 env）
#   - spc 版本锁定（§9 #12 已有源码级结论）：SPC_REL_TYPE 仅 source(main+pull)/
#     binary(nightly)，无 pin 接口 → 唯一稳态锚点 = STATIC_BUILDER_IMAGE digest
#     （versions.env 的 TODO 已升级为必填）
#
# Caddy 模块集（M0 决定：零自定义）：
#   - 未设 XCADDY_ARGS → 官方默认集：Caddy 标准 + frankenphp
#     + cbrotli / mercure / vulcain（三件套仅在 XCADDY_ARGS 为空时默认含，
#     一旦自定义必须显式 --with 列全，否则静默丢失）
#   - 是否裁剪 mercure/vulcain（省几 MB，损"与官方产物同构"的排障锚点）
#     = M1 小拍板项（讨论文档 §8）
# ============================================================

ARG STATIC_BUILDER_IMAGE=dunglas/frankenphp:static-builder-gnu
FROM ${STATIC_BUILDER_IMAGE} AS builder

# --- 参数（全部由 Makefile 从 versions.env / extensions.txt 注入）---
ARG FRANKENPHP_VERSION=1.12.7
ARG PHP_VERSION=8.5.9
# 扩展名列表即 spc 扩展名（官方 builder 直接透传给内部 spc）
ARG PHP_EXTENSIONS="bcmath"
ARG PHP_EXTENSION_LIBS=""
# token 经 --secret id=github_token 注入（Makefile 读宿主环境变量）而非 ARG/build-arg：
# build-arg 值参与 BuildKit 缓存键，CI 每轮 GITHUB_TOKEN 轮换会让层缓存永远 miss；
# secret 挂载不进缓存键、不落镜像 history（原 ARG 方案的泄露面一并消除）。
# 密钥约定不变：fine-grained PAT、零权限（公开仓库读取仅提限额）+ 短有效期，禁止入库

# 官方构建脚本的环境变量接口
# （frankenphp.dev/docs/static → "Customizing the FrankenPHP static build"；
#   全量接口见 build-static.sh 头部注释）
# NO_COMPRESS=1：官方脚本默认 UPX 压缩（--with-upx-pack）——讨论文档 §1.1
# 决策"默认不用 UPX"（解压内存/启动代价 + 扫描器误报），必须显式关闭
#
# SPC_OPT_BUILD_ARGS（2026-08-16 预检发现并覆盖）：官方 gnu 镜像默认将 ini 路径
# 设为 /etc/frankenphp（+php.d 扫描目录）——与 §6 #3"双二进制统一读 /etc/php"
# 不符。此处覆盖为 /etc/php（+conf.d），php-cli 侧对齐后即完成 §9 #7 统一；
# 保留镜像原有的 --debug（spc 构建详日志，长跑监控用）
ENV FRANKENPHP_VERSION=${FRANKENPHP_VERSION} \
    PHP_VERSION=${PHP_VERSION} \
    PHP_EXTENSIONS=${PHP_EXTENSIONS} \
    PHP_EXTENSION_LIBS=${PHP_EXTENSION_LIBS} \
    SPC_OPT_BUILD_ARGS="--with-config-file-path=/etc/php --with-config-file-scan-dir=/etc/php/conf.d --debug" \
    NO_COMPRESS=1

# 官方镜像内：frankenphp 源码树位于 /go/src/app，构建入口为 build-static.sh
# 产物落 /go/src/app/dist/frankenphp-linux-<arch>
# ⚠️ 先清过期 buildroot（2026-08-16 M1 实测教训）：官方镜像出厂自带一次完整构建的
#   dist/（按其默认扩展集含 bz2 编的 libzip.a 等）——我们的扩展集不同，残留状态导致
#   libzip 带 BZ2 引用而链接集无 -lbz2 → undefined reference（同 frankenphp #2395 族）。
#   只清 buildroot：保留 downloads 缓存与 spc 本体（比官方 CLEAN=1 全清省时；
#   若仍失败再升级为 CLEAN=1）
# re2c 预装（2026-08-16 M1 实测，两轮迭代后的定稿方案）：
#   背景：当日 spc nightly 的 doctor 要求 re2c，官方镜像（Aug-6 构建）未装、
#   CentOS7 仓库无此包（yum 修复必败）；spc nightly 日漂移的又一实证（§9 #12）。
#   版本选择 re2c 2.2：4.x 构建系统要求 Python≥3.7（镜像无 python3），2.x 纯
#   autotools（镜像内 autoreconf/autoconf/automake/g++ 齐备）；官方 release 资产
#   仅 tar.xz/lz，故用 GitHub tag 自动打包（无 configure，需先 autogen.sh）。
#   php-src 发布包自带生成文件，实际编译不依赖 re2c，纯满足 doctor 检查
RUN cd /tmp && curl -fsSL -o re2c.tgz \
        https://github.com/skvadrik/re2c/archive/refs/tags/2.2.tar.gz \
    && tar xf re2c.tgz && cd re2c-2.2 \
    && ./autogen.sh && ./configure --prefix=/usr/local \
    && make -j"$(nproc)" && make install \
    && re2c --version && cd / && rm -rf /tmp/re2c*

# 下载走 BuildKit cache mount（php-cli 线同款）：失败重跑不再全量重下 45 个源
# ⚠️ 构建成功后的容错（2026-08-16 M1 实测）：spc 圆满完成（Build complete 490s +
#   embed 自检 + frankenphp version 自检全过）后，build-static.sh 的收尾记账步骤
#   以非零退出（上游尾部小毛病），会连坐整个 RUN 层。处置：容忍脚本退出码，
#   以产物存在性为准——buildroot/bin/frankenphp 正是 sanity check 验证过的那份
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
#      ——后者依赖 build-static.sh 的收尾 cp 步骤（该步骤存在非零退出的前科）
FROM scratch AS artifact
COPY --from=builder /go/src/app/dist/static-php-cli/buildroot/bin/frankenphp /frankenphp-linux-x86_64
