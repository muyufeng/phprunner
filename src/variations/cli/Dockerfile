# syntax=docker/dockerfile:1
# ============================================================
# phprunner cli 形态（根形态①：NTS php 单进程直跑，无 web 层 / 无 s6）
# 结构：docs/结构设计-v0.2.0.md（临时设计稿）
# 装配：src/common（全形态）+ php(NTS) 二进制
# 部署形态：compose 用 command: 覆盖为 queue:work / schedule:work
#   （扩缩不对称：queue ×N、scheduler 恰 1 份）
# HEALTHCHECK 不设——compose 按服务选探针（healthcheck-queue/schedule；
#   默认 CMD sleep 下进程探针必失败，不该惩罚）
# ⚠️ ENV 块与 frankenphp/unit Dockerfile 及 src/common/etc/php/php.ini 同源维护
# ============================================================
ARG BASE_IMAGE=debian:trixie-slim
FROM ${BASE_IMAGE}

ARG APT_MIRROR=mirrors.ustc.edu.cn
ARG PHP_VERSION=8.5.9
ARG RELEASE_ITER=1

RUN if [ -n "${APT_MIRROR}" ]; then \
        sed -i "s/deb.debian.org/${APT_MIRROR}/g" /etc/apt/sources.list.d/debian.sources; \
    fi \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates tzdata curl procps \
    && rm -rf /var/lib/apt/lists/*

# ---- 装配：共享层 + 二进制（路径镜像式）----
COPY --chmod=755 src/common/ /
COPY --chmod=755 build/artifacts/php-cli-linux-x86_64 /usr/local/bin/php

RUN echo "php-${PHP_VERSION}-r${RELEASE_ITER}-cli" > /etc/phprunner-version \
    && mkdir -p /var/www/html/public /composer \
    && chown -R www-data:www-data /var/www/html /composer /etc/php/conf.d

# ---- ENV 出厂默认（frankenphp 形态减 CADDY_/SSL_/XDG 层——无 web 服务器）----
ENV PHPRUNNER_FORM=cli \
    APP_BASE_DIR=/var/www/html \
    PHP_INI_SCAN_DIR=/etc/php/conf.d \
    SHOW_WELCOME_MESSAGE=true \
    DISABLE_DEFAULT_CONFIG=false \
    LOG_OUTPUT_LEVEL=warn \
    PHP_MEMORY_LIMIT=256M \
    PHP_MAX_EXECUTION_TIME=99 \
    PHP_MAX_INPUT_TIME=-1 \
    PHP_MAX_INPUT_VARS=1000 \
    PHP_POST_MAX_SIZE=100M \
    PHP_UPLOAD_MAX_FILE_SIZE=100M \
    PHP_OPEN_BASEDIR="" \
    PHP_REALPATH_CACHE_TTL=120 \
    PHP_DISPLAY_ERRORS=Off \
    PHP_DISPLAY_STARTUP_ERRORS=Off \
    PHP_ERROR_REPORTING=22527 \
    PHP_ERROR_LOG=/dev/stderr \
    PHP_DATE_TIMEZONE=UTC \
    PHP_SESSION_COOKIE_SECURE=false \
    PHP_OPCACHE_ENABLE=0 \
    PHP_OPCACHE_MEMORY_CONSUMPTION=128 \
    PHP_OPCACHE_INTERNED_STRINGS_BUFFER=8 \
    PHP_OPCACHE_MAX_ACCELERATED_FILES=10000 \
    PHP_OPCACHE_VALIDATE_TIMESTAMPS=1 \
    PHP_OPCACHE_REVALIDATE_FREQ=2 \
    PHP_OPCACHE_SAVE_COMMENTS=1 \
    PHP_OPCACHE_ENABLE_FILE_OVERRIDE=0 \
    PHP_OPCACHE_JIT=off \
    PHP_OPCACHE_JIT_BUFFER_SIZE=0 \
    AUTORUN_ENABLED=false \
    AUTORUN_DEBUG=false \
    AUTORUN_LARAVEL_SKIP_IF_NOT_FOUND=false \
    AUTORUN_LARAVEL_STORAGE_LINK=true \
    AUTORUN_LARAVEL_OPTIMIZE=true \
    AUTORUN_LARAVEL_MIGRATION=true \
    AUTORUN_LARAVEL_MIGRATION_ISOLATION=false \
    AUTORUN_LARAVEL_MIGRATION_TIMEOUT=30 \
    COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_HOME=/composer \
    COMPOSER_MAX_PARALLEL_HTTP=24

USER www-data
WORKDIR /var/www/html

ENTRYPOINT ["phprunner-entrypoint"]
# 默认保活（compose command: 覆盖为 php artisan queue:work / schedule:work）
CMD ["sleep", "infinity"]
