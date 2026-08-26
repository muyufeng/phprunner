#!/bin/sh
# ============================================================
# 30 Laravel 启动自动化
# 文档：docs/project-structure.md §1（30-laravel-automations.sh）
#       docs/static-php-runtime-discussion.md §6 #7（模式来源）
#
# 职责：storage:link / migrate（等 DB + 可选 --isolated 互斥）/ optimize
#   全 ENV 开关控制（四层命名空间之 AUTORUN_* 层）。
# 目标版本：Laravel 13（项目 V13 拍板）——不做旧版本兼容矩阵，
#   optimize --except / migrate --isolated 均按 13 线能力直用。
# PHP_BIN 按形态解析（§7.2）：有 php 用 php——cli/runtime 真二进制，
#   web 为 /usr/local/bin/php 垫片（frankenphp php-cli 转发，官方
#   known-issues 同款；一次性脚本语义已实证）。
# 接口最小面：缓存族只留 OPTIMIZE 聚合开关（config/route/view/event
#   细粒度拆分待真实需求再加，避免接口面先于需求膨胀）。
# 模式参考 serversideup 50-laravel-automations.sh（GPL-3.0 边界：自研）。
# ============================================================
script_name="laravel-automations"

: "${DISABLE_DEFAULT_CONFIG:=false}"
: "${LOG_OUTPUT_LEVEL:=warn}"
: "${APP_BASE_DIR:=/var/www/html}"
: "${AUTORUN_ENABLED:=false}"
: "${AUTORUN_DEBUG:=false}"
: "${AUTORUN_LARAVEL_SKIP_IF_NOT_FOUND:=false}"
: "${AUTORUN_LARAVEL_STORAGE_LINK:=true}"
: "${AUTORUN_LARAVEL_OPTIMIZE:=true}"
: "${AUTORUN_LARAVEL_MIGRATION:=true}"
: "${AUTORUN_LARAVEL_MIGRATION_ISOLATION:=false}"
: "${AUTORUN_LARAVEL_MIGRATION_TIMEOUT:=30}"

debug_log() {
    if [ "$LOG_OUTPUT_LEVEL" = "debug" ] || [ "$AUTORUN_DEBUG" = "true" ]; then
        echo "👉 DEBUG ($script_name): $1" >&2
    fi
}

if [ "$DISABLE_DEFAULT_CONFIG" = "true" ] || [ "$AUTORUN_ENABLED" = "false" ]; then
    debug_log "跳过：DISABLE_DEFAULT_CONFIG=$DISABLE_DEFAULT_CONFIG AUTORUN_ENABLED=$AUTORUN_ENABLED"
    return 0 2>/dev/null || exit 0
fi

# PHP_BIN 按形态解析
if command -v php >/dev/null 2>&1; then
    PHP_BIN="php"
else
    PHP_BIN="frankenphp php-cli"
fi

# Laravel 检出判据：artisan 在场（smoke/02 同款判据）
ARTISAN="$APP_BASE_DIR/artisan"
if [ ! -f "$ARTISAN" ]; then
    if [ "$AUTORUN_LARAVEL_SKIP_IF_NOT_FOUND" = "true" ]; then
        debug_log "未检出 Laravel（$ARTISAN 不存在），SKIP_IF_NOT_FOUND=true 静默跳过"
        return 0 2>/dev/null || exit 0
    fi
    echo "❌ ($script_name): 未检出 Laravel（$ARTISAN 不存在）" >&2
    echo "ℹ️  确认应用在 APP_BASE_DIR=$APP_BASE_DIR；共享镜像/CI 场景可设 AUTORUN_ENABLED=false 或 AUTORUN_LARAVEL_SKIP_IF_NOT_FOUND=true" >&2
    return 1
fi

# 子 shell 执行：不污染 entrypoint 的 cwd；失败即中止整链（set -e 语义）
artisan() {
    debug_log "artisan $*"
    ( cd "$APP_BASE_DIR" && $PHP_BIN artisan "$@" )
}

# 等 DB 就绪：migrate:status 只读探测（建库/授权未就绪时非零），
# 循环至超时——多副本滚动发布时 DB 先于本容器存在是常态
wait_for_db() {
    waited=0
    until artisan migrate:status >/dev/null 2>&1; do
        if [ "$waited" -ge "$AUTORUN_LARAVEL_MIGRATION_TIMEOUT" ]; then
            return 1
        fi
        debug_log "DB 未就绪（${waited}s/$AUTORUN_LARAVEL_MIGRATION_TIMEOUT），2s 后重试"
        sleep 2
        waited=$((waited + 2))
    done
}

# ---- storage:link（幂等：已存在时非零退出属正常，不视为失败）----
if [ "$AUTORUN_LARAVEL_STORAGE_LINK" = "true" ]; then
    artisan storage:link --quiet || debug_log "storage:link 非零退出（已存在属正常）"
fi

# ---- migrate（等 DB + 互斥可选）----
if [ "$AUTORUN_LARAVEL_MIGRATION" = "true" ]; then
    MIGRATE_FLAGS="--force --no-interaction"
    if [ "$AUTORUN_LARAVEL_MIGRATION_ISOLATION" = "true" ]; then
        # 多副本并发 migrate 互斥（表锁；⚠️ 不支持 sqlite——sqlite 单文件
        # 场景天然单写者，互斥无意义，M2-05 驱动实证背景）
        MIGRATE_FLAGS="$MIGRATE_FLAGS --isolated"
    fi
    if ! wait_for_db; then
        echo "❌ ($script_name): DB ${AUTORUN_LARAVEL_MIGRATION_TIMEOUT}s 未就绪，放弃 migrate" >&2
        return 1
    fi
    artisan migrate $MIGRATE_FLAGS
fi

# ---- optimize（config/event/route/view 四合一缓存）----
if [ "$AUTORUN_LARAVEL_OPTIMIZE" = "true" ]; then
    artisan optimize --quiet
fi
