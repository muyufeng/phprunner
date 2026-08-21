#!/bin/sh
# ============================================================
# 10 运行时配置装配
# 文档：docs/project-structure.md §1（10-assemble-config.sh）
#
# 零渲染结论（§8 ENV 调研机制①，2026-08-16）：ini 占位符
#   ${PHP_XXX} 由 PHP 解析期展开、Caddyfile 占位符 {$VAR:default}
#   由 Caddy 运行期展开——本脚本无任何文本替换职责。
# 唯一职责：zzz-debug.ini 按 LOG_OUTPUT_LEVEL 生成/清除。
#   （目录创建一律属构建期——各形态 Dockerfile 的 RUN mkdir + chown，
#   serversideup 同款（其 frankenphp Dockerfile /config/caddy 等 RUN 内
#   预建）；运行期不再碰文件系统布局，2026-08-17 拍板收敛）
# ============================================================
script_name="assemble-config"

: "${DISABLE_DEFAULT_CONFIG:=false}"
: "${LOG_OUTPUT_LEVEL:=warn}"
PHP_CONF_D="${PHP_INI_SCAN_DIR:-/etc/php/conf.d}"

if [ "$DISABLE_DEFAULT_CONFIG" = "true" ]; then
    if [ "$LOG_OUTPUT_LEVEL" = "debug" ]; then
        echo "👉 $script_name: DISABLE_DEFAULT_CONFIG=true，跳过" >&2
    fi
    return 0 2>/dev/null || exit 0
fi

# debug 分片：LOG_OUTPUT_LEVEL=debug 时翻转错误可见性（覆盖主模板默认）
# ⚠️ 容错设计（2026-08-16 --user 覆写场景实证）：conf.d 属主 www-data，
#   部署层 user: 覆写为其他 uid 时 rm/cat 均无权——分片属锦上添花，
#   失败只降级提示，绝不炸入口（set -e 语义下须显式兜底）
DEBUG_INI="$PHP_CONF_D/zzz-debug.ini"
mkdir -p "$PHP_CONF_D" 2>/dev/null || true
case "$LOG_OUTPUT_LEVEL" in
    debug)
        if cat > "$DEBUG_INI" 2>/dev/null <<'EOF'
; 由 entrypoint.d/10-assemble-config.sh 生成（LOG_OUTPUT_LEVEL=debug）
display_errors = On
display_startup_errors = On
error_reporting = E_ALL
EOF
        then
            echo "ℹ️ NOTICE ($script_name): LOG_OUTPUT_LEVEL=debug → 错误显示已开启（$DEBUG_INI）" >&2
        else
            echo "⚠️  ($script_name): $DEBUG_INI 不可写（user 覆写非属主？），debug 分片降级跳过——可经 -d display_errors=1 自行注入" >&2
        fi
        ;;
    *)
        rm -f "$DEBUG_INI" 2>/dev/null || true
        ;;
esac
