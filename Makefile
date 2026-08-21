# ============================================================
# phprunner 项目编排唯一入口
# 文档：docs/project-structure.md §1（根 Makefile——跨 build/smoke/images
#       三子系统，故放仓库根）
#
# 目标：
#   make binaries   双二进制成对产出 → build/artifacts/（M1）
#   make smoke      冒烟总入口 smoke/run-all.sh（M2 二进制级 / M3 镜像级，
#                   脚本按产物/镜像存在性自知分层，此处不区分）
#   make images     三镜像装配（M3 实装，当前为守卫占位）
#   make clean      清 build/artifacts/
#
# 原则：
#   - 幂等可重复；失败即停（.ONESHELL + set -euo pipefail）
#   - 单一事实源：一切版本来自 build/versions.env，扩展清单来自
#     build/extensions.txt；本文件与 images/ 层禁止硬编码版本/扩展名
#   - 成对不变量（讨论文档 §7.1）：frankenphp 与 php-cli 必须同批产出，
#     binarah 目标收尾统一校验
#   - 交互调试不经此处：./dev builder
# ============================================================

# 注意：make 的 SHELL 必须是单一程序路径（"/usr/bin/env bash" 这种带参数的写法
# 会被整体当路径 exec 而报 No such file or directory——那是 shebang/Dockerfile 的语法）
SHELL := /bin/bash
.ONESHELL:

ROOT          := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
BUILD_DIR     := $(ROOT)/build
SMOKE_DIR     := $(ROOT)/smoke
VARIATIONS_DIR := $(ROOT)/src/variations
ARTIFACTS     := $(BUILD_DIR)/artifacts

# ---- 单一事实源①：版本（include 为 make 变量，export 给 recipe）----
include $(BUILD_DIR)/versions.env
export PHP_VERSION FRANKENPHP_VERSION SPC_VERSION STATIC_BUILDER_IMAGE \
       SPC_ENV_BASE_IMAGE BASE_IMAGE RELEASE_ITER TARGET_ARCH \
       APT_MIRROR S6_OVERLAY_VERSION

# ---- 单一事实源②：冻结扩展清单 → 逗号列表（喂两个构建器）----
# 机器行 = 行首小写字母开头（extensions.txt 的约定），其余为注释/空行；
# 字符类含连字符（password-argon2）——与 smoke/lib.sh 的 ext_list 保持同一正则
EXT_COMMA := $(shell grep -E '^[a-z0-9_-]+$$' $(BUILD_DIR)/extensions.txt | paste -sd, -)

.DEFAULT_GOAL := help
.PHONY: help binaries frankenphp php-cli smoke images clean

help:
	@echo "phprunner 编排入口（结构：docs/project-structure.md）"
	@echo "  make binaries   双二进制成对产出 → $(ARTIFACTS)/"
	@echo "  make smoke      冒烟总入口（smoke/run-all.sh）"
	@echo "  make images     三镜像装配（M3）"
	@echo "  make clean      清 $(ARTIFACTS)/"
	@echo "自检：PHP=$(PHP_VERSION) FRANKENPHP=$(FRANKENPHP_VERSION) ARCH=$(TARGET_ARCH)"
	@echo "      EXTENSIONS=$(EXT_COMMA)"
	@if [[ -f $(BUILD_DIR)/secrets.env ]]; then \
		echo "      GITHUB_TOKEN=已配置（build/secrets.env）"; \
	else \
		echo "      GITHUB_TOKEN=未配置（匿名限额；可选：cp build/secrets.env.example）"; \
	fi

# ------------------------------------------------------------
# 上游：产二进制（M1）
# 双产物用同一 EXT_COMMA / 同一 PHP_VERSION 快照 → 成对发布不变量
# ------------------------------------------------------------
.PHONY: binaries frankenphp php-cli

binaries: frankenphp php-cli
	@set -euo pipefail
	test -x "$(ARTIFACTS)/frankenphp-linux-$(TARGET_ARCH)" \
	  || { echo "❌ 成对校验失败：frankenphp 产物缺失"; exit 1; }
	test -x "$(ARTIFACTS)/php-cli-linux-$(TARGET_ARCH)" \
	  || { echo "❌ 成对校验失败：php-cli 产物缺失"; exit 1; }
	# 产物清单：固定文件名 + 本清单 = 完整可追溯（版本/时间/git/sha256）。
	# 文件名本身不带版本是有意设计——槽位名由 versions.env 定义其内容（§4 规约）
	{ \
	  echo "# phprunner 构建清单（自动生成，gitignore 内 artifacts 随产物存续）"; \
	  echo "build_time:  $$(date -u '+%F %T UTC')"; \
	  echo "php:         $(PHP_VERSION)"; \
	  echo "frankenphp:  $(FRANKENPHP_VERSION)"; \
	  echo "spc:         $(SPC_VERSION)"; \
	  echo "arch:        $(TARGET_ARCH)"; \
	  echo "git_commit:  $$(git -C $(ROOT) rev-parse --short HEAD 2>/dev/null || echo n/a)"; \
	  echo "extensions:  $(EXT_COMMA)"; \
	  echo; \
	  cd "$(ARTIFACTS)" && sha256sum frankenphp-linux-$(TARGET_ARCH) php-cli-linux-$(TARGET_ARCH); \
	} > "$(ARTIFACTS)/BUILD-INFO"
	echo "✅ 成对产出完成 → $(ARTIFACTS)/{{frankenphp,php-cli}}-linux-$(TARGET_ARCH)"
	echo "✅ 构建清单   → $(ARTIFACTS)/BUILD-INFO"

frankenphp:
	@set -euo pipefail
	echo "▶ frankenphp(ZTS)：v$(FRANKENPHP_VERSION) × PHP $(PHP_VERSION)"
	# 构建密钥加载顺序：build/secrets.env（仓库内、gitignore）→ 宿主环境变量兜底；
	# 都没有则传空 token（匿名限额，不影响构建正确性）
	if [[ -f $(BUILD_DIR)/secrets.env ]]; then . $(BUILD_DIR)/secrets.env; fi
	# token 预检（两轮教训固化：坏 token 401 引爆全场 + 瞬时网络抖动误杀构建）：
	#   重试 3 次；401/403 = 凭证问题 → 硬失败；000/超时 = 网络问题 → 警告放行
	#   （真断网时构建自会在下载处失败，无需预检越俎代庖）
	if [[ -n "$${GITHUB_TOKEN:-}" ]]; then
		code=000
		for i in 1 2 3; do
			code=$$(curl -s -o /dev/null -m 8 -w '%{http_code}' \
				-H "Authorization: Bearer $${GITHUB_TOKEN}" https://api.github.com/rate_limit || true)
			[[ "$$code" == "200" ]] && break
			sleep 2
		done
		case "$$code" in
			200) echo "GITHUB_TOKEN 预检通过" ;;
			000) echo "⚠️  预检时网络不可达（已重试 3 次）——放行，构建自行验证网络" ;;
			*)   echo "❌ GITHUB_TOKEN 无效（HTTP $$code）——修复 build/secrets.env 后重试"; exit 1 ;;
		esac
	else
		echo "⚠️  未配置 GITHUB_TOKEN：匿名限额 60 次/小时，spc 查询库版本可能撞 403"
	fi
	docker buildx build -f $(BUILD_DIR)/frankenphp.Dockerfile \
		--target artifact \
		--build-arg STATIC_BUILDER_IMAGE='$(STATIC_BUILDER_IMAGE)' \
		--build-arg FRANKENPHP_VERSION='$(FRANKENPHP_VERSION)' \
		--build-arg PHP_VERSION='$(PHP_VERSION)' \
		--build-arg PHP_EXTENSIONS='$(EXT_COMMA)' \
		--build-arg GITHUB_TOKEN="$${GITHUB_TOKEN:-}" \
		-o 'type=local,dest=$(ARTIFACTS)/.dist' \
		$(BUILD_DIR)
	mv "$(ARTIFACTS)/.dist/frankenphp-linux-$(TARGET_ARCH)" \
	   "$(ARTIFACTS)/frankenphp-linux-$(TARGET_ARCH)"
	rm -rf "$(ARTIFACTS)/.dist"
	ls -lh "$(ARTIFACTS)/frankenphp-linux-$(TARGET_ARCH)"

php-cli:
	@set -euo pipefail
	echo "▶ php-cli(NTS)：spc $(SPC_VERSION) × PHP $(PHP_VERSION)（gnu.2.17 半静态）"
	# 构建密钥加载 + token 预检（与 frankenphp 同款：坏 token 401 引爆全场 +
	#   瞬时网络抖动误杀构建两教训固化；2026-08-17 php-cli 补 token——无 token 时
	#   spc download 匿名 403 会 fallback 到 dl.static-php.dev，该源 TLS 偶发不稳）
	if [[ -f $(BUILD_DIR)/secrets.env ]]; then . $(BUILD_DIR)/secrets.env; fi
	if [[ -n "$${GITHUB_TOKEN:-}" ]]; then
		code=000
		for i in 1 2 3; do
			code=$$(curl -s -o /dev/null -m 8 -w '%{http_code}' \
				-H "Authorization: Bearer $${GITHUB_TOKEN}" https://api.github.com/rate_limit || true)
			[[ "$$code" == "200" ]] && break
			sleep 2
		done
		case "$$code" in
			200) echo "GITHUB_TOKEN 预检通过" ;;
			000) echo "⚠️  预检时网络不可达（已重试 3 次）——放行，构建自行验证网络" ;;
			*)   echo "❌ GITHUB_TOKEN 无效（HTTP $$code）——修复 build/secrets.env 后重试"; exit 1 ;;
		esac
	else
		echo "⚠️  未配置 GITHUB_TOKEN：匿名限额 60 次/小时，spc 下载扩展可能撞 403"
	fi
	docker buildx build -f $(BUILD_DIR)/php-cli.Dockerfile \
		--target artifact \
		--build-arg SPC_ENV_BASE_IMAGE='$(SPC_ENV_BASE_IMAGE)' \
		--build-arg SPC_VERSION='$(SPC_VERSION)' \
		--build-arg PHP_VERSION='$(PHP_VERSION)' \
		--build-arg PHP_EXTENSIONS='$(EXT_COMMA)' \
		--build-arg GITHUB_TOKEN="$${GITHUB_TOKEN:-}" \
		-o 'type=local,dest=$(ARTIFACTS)/.dist' \
		$(BUILD_DIR)
	mv "$(ARTIFACTS)/.dist/php-cli" \
	   "$(ARTIFACTS)/php-cli-linux-$(TARGET_ARCH)"
	rm -rf "$(ARTIFACTS)/.dist"
	ls -lh "$(ARTIFACTS)/php-cli-linux-$(TARGET_ARCH)"

# ------------------------------------------------------------
# 冒烟：脚本内部按产物/镜像存在性自行 SKIP，此处不做前置判断
# ------------------------------------------------------------
smoke:
	@set -euo pipefail
	# bash ./（不经 shebang exec）：UNC 直写会吃掉 x 位，入口不该这么脆
	cd $(SMOKE_DIR) && bash ./run-all.sh

# ------------------------------------------------------------
# 下游：三镜像装配（v0.2.0 结构：src/variations/<形态>/Dockerfile）
# tag 规约：phprunner/<形态>:<PHP>-r<迭代号>，形态 = cli / frankenphp / unit
# 依赖序：unit FROM frankenphp 镜像（构建序保证）；cli 独立
# 先决：双产物在场（成对不变量 §7.1——镜像只搬运不加工）
# ------------------------------------------------------------
images: $(ARTIFACTS)/frankenphp-linux-$(TARGET_ARCH) $(ARTIFACTS)/php-cli-linux-$(TARGET_ARCH)
	@set -euo pipefail
	for form in cli frankenphp unit; do \
		args=""; \
		if [ "$$form" = "unit" ]; then \
			args="--build-arg S6_OVERLAY_VERSION='$(S6_OVERLAY_VERSION)'"; \
		else \
			args="--build-arg BASE_IMAGE='$(BASE_IMAGE)' --build-arg APT_MIRROR='$(APT_MIRROR)'"; \
		fi; \
		echo "▶ 装配 phprunner/$$form:$(PHP_VERSION)-r$(RELEASE_ITER)"; \
		eval docker buildx build -f $(VARIATIONS_DIR)/$$form/Dockerfile \
			--build-arg PHP_VERSION='$(PHP_VERSION)' \
			--build-arg RELEASE_ITER='$(RELEASE_ITER)' \
			$$args \
			-t phprunner/$$form:$(PHP_VERSION)-r$(RELEASE_ITER) \
			$(ROOT) || exit 1; \
	done
	echo "✅ 三镜像装配完成 → phprunner/{cli,frankenphp,unit}:$(PHP_VERSION)-r$(RELEASE_ITER)"

clean:
	rm -rf $(ARTIFACTS)
