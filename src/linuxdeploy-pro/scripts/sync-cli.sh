#!/bin/bash
################################################################################
# 同步 CLI 仓库 → APK assets（单一数据源：linuxdeploy-cli 仓库）
#
# 背景：CLI 唯一数据源原则。任何 CLI 改动先在 src/linuxdeploy-cli 提交，
# 然后运行本脚本把权威版本同步进 APK assets，避免双仓库分叉（2026-08-14
# 曾因手工复制导致 327 行分叉，本脚本为修复该问题的机制保证）。
#
# 用法：scripts/sync-cli.sh [--check]
#   --check   只报告差异，不复制（CI 或提交前自检用）
#
# 注意：Gradle 构建已内置同等同步（app/build.gradle.kts 的 syncCli 任务，
# 每次 assemble/install 前自动执行），本脚本仅用于不跑 Gradle 时手动同步。
#
# 复制范围：
#   cli.sh、statx_shim.c、statx_test.c、include/、docs/、LICENSE、README.md、tools/
# 排除：config/、tmp/、builds/、scripts/regression.sh（开发机专用）
################################################################################

set -e
cd "$(dirname "$0")/.."

CLI="${CLI_REPO:-../linuxdeploy-cli}"          # CLI 仓库绝对/相对路径
DEST="app/src/main/assets/linuxdeploy-cli"     # APK assets 目标
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

[ -f "${CLI}/cli.sh" ] || { echo "!! CLI 仓库路径无效: ${CLI}（可用 CLI_REPO= 覆盖）"; exit 1; }

# 排除项：运行时目录与开发机脚本
EXCLUDES=(--exclude='.git' --exclude='config' --exclude='tmp' --exclude='builds'
          --exclude='scripts/regression.sh' --exclude='*.log' --exclude='*.bak')

if [ "${CHECK_ONLY}" = "1" ]; then
    echo "==> [sync-cli] 差异检查（CLI 仓库 vs APK assets）："
    rsync -n -avc "${EXCLUDES[@]}" "${CLI}/" "${DEST}/" | grep -v '/$' || true
    exit 0
fi

echo "==> [sync-cli] 同步 ${CLI} → ${DEST}"
mkdir -p "${DEST}"
rsync -avc "${EXCLUDES[@]}" "${CLI}/" "${DEST}/"

# 同步后修正执行位（assets 需要 755；git 仅记录 100644 时 rsync -p 会带过来）
find "${DEST}" -type f \( -name "*.sh" -o -name "debootstrap" -o -name "pkgdetails" \) \
    -exec chmod 755 {} + 2>/dev/null || true

echo "==> [sync-cli] 完成。请检查 git status 后提交 APK 仓库。"
