#!/bin/sh
# ============================================================
# 00 启动横幅 + 性能状态检测建议
# 文档：docs/project-structure.md §1（00-container-info.sh）
# 拍板（2026-08-16）：PHP_OPCACHE_ENABLE 默认 0，本脚本的性能
#   检测建议即其补偿机制（模式参考 serversideup 0-container-info.sh，
#   GPL-3.0 边界：只学模式，自研实现）。
# ============================================================
script_name="container-info"

: "${SHOW_WELCOME_MESSAGE:=true}"
: "${DISABLE_DEFAULT_CONFIG:=false}"
: "${LOG_OUTPUT_LEVEL:=warn}"
: "${PHPRUNNER_FORM:=unknown}"   # 镜像内 ENV 烘焙：web|cli|runtime
: "${AUTORUN_ENABLED:=false}"

if [ "$SHOW_WELCOME_MESSAGE" = "false" ] || [ "$DISABLE_DEFAULT_CONFIG" = "true" ]; then
    if [ "$LOG_OUTPUT_LEVEL" = "debug" ]; then
        echo "👉 $script_name: 横幅跳过（SHOW_WELCOME_MESSAGE/DISABLE_DEFAULT_CONFIG）" >&2
    fi
    return 0 2>/dev/null || exit 0
fi

# PHP_BIN 按形态解析（§7.2）：有 php 用 php——cli/runtime 为真二进制，
# web 为 /usr/local/bin/php 垫片（frankenphp php-cli 转发 + 剥 -d，官方
# known-issues 同款；垫片仅一次性脚本用，常驻进程走 cli 形态；
# 一次性探测自然结束，不涉信号禁区——M2-07 实证 exit 透传）。
if command -v php >/dev/null 2>&1; then
    PHP_BIN="php"
elif command -v frankenphp >/dev/null 2>&1; then
    PHP_BIN="frankenphp php-cli"
else
    PHP_BIN=""
fi

php_ini_get() {
    # 经 ENV 传参而非 argv：frankenphp php-cli 的 -r+argv 组合不传参
    # （M3-2 实证：真 php 二进制 argv 可用，frankenphp 侧返回空；artisan
    # 走文件路径不受影响）——getenv 对两二进制均稳
    [ -n "$PHP_BIN" ] || { echo ""; return; }
    INI_KEY="$1" $PHP_BIN -r 'echo (string)ini_get(getenv("INI_KEY"));' 2>/dev/null
}

OPCACHE_STATUS="$(php_ini_get opcache.enable)"
MEMORY_LIMIT="$(php_ini_get memory_limit)"
UPLOAD_LIMIT="$(php_ini_get upload_max_filesize)"
PHP_VERSION_DESC="$([ -n "$PHP_BIN" ] && $PHP_BIN -r 'echo PHP_VERSION;' 2>/dev/null || echo n/a)"

# 占位符 ${ENV} 由 PHP 解析期展开（M2-08），ini_get 读到的即
# 用户覆写后的生效值——横幅天然反映运行时终态
if [ "$OPCACHE_STATUS" = "1" ]; then
    OPCACHE_MESSAGE="✅ 开启"
else
    OPCACHE_MESSAGE="❌ 关闭"
fi

echo "------------------------------------------------------------"
echo " phprunner · ${PHPRUNNER_FORM} 形态"
echo "------------------------------------------------------------"
echo "📦 版本"
echo "   镜像:      $(cat /etc/phprunner-version 2>/dev/null || echo unknown)"
echo "   PHP:       $PHP_VERSION_DESC"
echo "   系统:      $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-}")"
echo ""
echo "👤 运行身份"
echo "   用户:      $(whoami 2>/dev/null || echo "uid=$(id -u)")（uid=$(id -u) gid=$(id -g)）"
echo ""
echo "⚡ 性能"
echo "   OPcache:   $OPCACHE_MESSAGE"
echo "   内存上限:  ${MEMORY_LIMIT:-n/a}"
echo "   上传上限:  ${UPLOAD_LIMIT:-n/a}"
echo ""
echo "🔄 运行时"
echo "   自动化:    AUTORUN_ENABLED=$AUTORUN_ENABLED"
echo "   日志级别:  LOG_OUTPUT_LEVEL=$LOG_OUTPUT_LEVEL"
echo "------------------------------------------------------------"

# opcache=0 补偿建议（拍板机制核心行）
if [ -n "$PHP_BIN" ] && [ "$OPCACHE_STATUS" != "1" ]; then
    echo "👉 [NOTICE]: 生产环境建议开启 OPcache：设 PHP_OPCACHE_ENABLE=1（classic 模式性能主要杠杆，§9 #3 已实证原生构建可用）"
fi
