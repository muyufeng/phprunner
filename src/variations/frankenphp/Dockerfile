# syntax=docker/dockerfile:1
# ============================================================
# phprunner frankenphp 形态（根形态②：frankenphp ZTS 单进程直跑，无 s6）
# 结构：docs/结构设计-v0.2.0.md（临时设计稿）
# 装配：src/common（全形态）+ 本形态自有资产（etc/frankenphp + php 垫片）
#       + frankenphp 二进制
# 本形态同时是 unit 形态的继承基底（unit = 本镜像 + php-cli 引入）
# 权限模型：USER www-data 非特权默认 / 8080·8443 非特权端口 / 构建期 chown
# ⚠️ ENV 块与 cli Dockerfile 及 src/common/etc/php/php.ini 同源维护
# ============================================================
ARG BASE_IMAGE=debian:trixie-slim
FROM ${BASE_IMAGE}

ARG APT_MIRROR=mirrors.ustc.edu.cn
ARG PHP_VERSION=8.5.9
ARG RELEASE_ITER=1

# 公共基础包：ca-certificates（静态 PHP 的 CA 链）/ tzdata / curl
#   （healthcheck-web + 应急探针）/ procps（pgrep 探针——全装，激活层选用）
RUN if [ -n "${APT_MIRROR}" ]; then \
        sed -i "s/deb.debian.org/${APT_MIRROR}/g" /etc/apt/sources.list.d/debian.sources; \
    fi \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates tzdata curl procps \
    && rm -rf /var/lib/apt/lists/*

# ---- 装配：共享层 + 本形态资产（rootfs/ 整树平铺——路径镜像纯资产树，
#      与元文件 Dockerfile 分离；垫片在 rootfs/usr/local/bin/php：官方
#      known-issues 的 Composer @php workaround 同款，与传统 php 安装位
#      一致，unit 继承后由真 php 同位覆盖）----
COPY --chmod=755 src/common/ /
COPY --chmod=755 src/variations/frankenphp/rootfs/ /

# ---- 二进制（§6 取舍：单 arch x86_64 起步）----
COPY --chmod=755 build/artifacts/frankenphp-linux-x86_64 /usr/local/bin/frankenphp

# ---- 版本标记 + 目录/属主（构建期权限模型；含 zzz-debug.ini 运行时写入位）----
RUN echo "php-${PHP_VERSION}-r${RELEASE_ITER}-frankenphp" > /etc/phprunner-version \
    && mkdir -p /var/www/html/public /config/caddy /data/caddy /composer \
    && chown -R www-data:www-data /var/www/html /config /data /composer /etc/php/conf.d

# ---- ENV 出厂默认（四层命名空间；PHP_OPCACHE_ENABLE=0 拍板 + 横幅 NOTICE 补偿）----
ENV PHPRUNNER_FORM=frankenphp \
    APP_BASE_DIR=/var/www/html \
    PHP_INI_SCAN_DIR=/etc/php/conf.d \
    PHP_BINARY=/usr/local/bin/php \
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
    CADDY_SERVER_ROOT=/var/www/html/public \
    CADDY_HTTP_PORT=8080 \
    CADDY_HTTPS_PORT=8443 \
    CADDY_ADMIN=off \
    CADDY_AUTO_HTTPS=off \
    CADDY_WORKER_MODE=classic \
    CADDY_WORKER_FILE=/var/www/html/public/index.php \
    TRUSTED_PROXY=local \
    SSL_MODE=off \
    SSL_CERTIFICATE_FILE=/etc/ssl/private/web.crt \
    SSL_PRIVATE_KEY_FILE=/etc/ssl/private/web.key \
    HEALTHCHECK_PATH=/healthcheck \
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
    COMPOSER_MAX_PARALLEL_HTTP=24 \
    XDG_CONFIG_HOME=/config \
    XDG_DATA_HOME=/data

USER www-data
WORKDIR /var/www/html
EXPOSE 8080 8443

ENTRYPOINT ["phprunner-entrypoint"]
CMD ["frankenphp", "run", "--config", "/etc/frankenphp/Caddyfile", "--adapter", "caddyfile"]

# 三路健康契约之①（激活层选择：本形态 → healthcheck-web；unit 继承）
HEALTHCHECK --start-period=10s --interval=10s --timeout=5s --retries=3 \
    CMD ["healthcheck-web"]
