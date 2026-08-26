# syntax=docker/dockerfile:1
# ============================================================
# phprunner unit 形态（派生：frankenphp 的变体 + php-cli 引入）
# 结构：docs/结构设计-v0.2.0.md（临时设计稿）——方案A FROM 继承：
#   ENV/CMD/HEALTHCHECK/USER/WORKDIR/EXPOSE 与全部层继承自 frankenphp
#   镜像，本文件只写差异；"跨形态逐字节同源"由层继承成为物理事实
# 增量：php 真 NTS 二进制（同位覆盖继承的垫片）+ s6 overlay + 服务树
#   + /run chown（非 root s6）+ FORM/S6/开关 ENV + PID1 换 /init
# ============================================================
ARG PHP_VERSION=8.5.9
ARG RELEASE_ITER=1
FROM phprunner/frankenphp:${PHP_VERSION}-r${RELEASE_ITER}

# FROM 后需重新声明方可使用（Dockerfile ARG 作用域规则）
ARG PHP_VERSION
ARG RELEASE_ITER
ARG S6_OVERLAY_VERSION=v3.2.1.0

# 继承镜像默认 USER www-data——以下构建步骤（apt / tar 解包 / chown）
# 需 root 权限，临时提升；构建尾部恢复非特权默认
USER root

# ---- php-cli 引入：真 NTS 二进制覆盖继承的垫片（同位 /usr/local/bin/php，
#      PHP_BINARY 继承值随之自然指向真二进制）----
COPY --chmod=755 build/artifacts/php-cli-linux-x86_64 /usr/local/bin/php

# ---- s6 overlay（xz-utils 本形态自装；apt 源已自 frankenphp 镜像继承）----
RUN apt-get update \
    && apt-get install -y --no-install-recommends xz-utils \
    && rm -rf /var/lib/apt/lists/*
# ⚠️ ADD 远程 URL 不自动解包（Docker 行为）——tar -Jxpf 手工解（-p 保权限位）
ADD https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp/
ADD https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-x86_64.tar.xz /tmp/
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz \
    && tar -C / -Jxpf /tmp/s6-overlay-x86_64.tar.xz \
    && rm -f /tmp/s6-overlay-noarch.tar.xz /tmp/s6-overlay-x86_64.tar.xz

# ---- s6 三服务树（rootfs/ 整树平铺；--chmod 保 data/check 执行位）----
COPY --chmod=755 src/variations/unit/rootfs/ /

RUN echo "php-${PHP_VERSION}-r${RELEASE_ITER}-unit" > /etc/phprunner-version \
    && chown www-data:www-data /run

# ---- 差异 ENV（其余全继承：PHP_*/CADDY_*/SSL_*/AUTORUN_*/COMPOSER_*/XDG_*）----
ENV PHPRUNNER_FORM=unit \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_VERBOSITY=1 \
    QUEUE_ENABLED=true \
    SCHEDULER_ENABLED=true

# USER/WORKDIR/EXPOSE/HEALTHCHECK（healthcheck-web）均继承；
# 恢复非特权运行身份（覆盖上方构建期的临时 USER root）
USER www-data

CMD ["/init"]
