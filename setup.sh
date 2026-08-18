#!/usr/bin/env bash
set -euo pipefail

# 生成 / 重新生成 Xcode 工程（兜底方案）
# 用法：在项目根目录运行  ./setup.sh
# 说明：正常情况直接双击 Veil.xcodeproj 即可；仅当工程打不开时用本脚本重新生成。

echo "==> 检查 xcodegen..."
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "    未找到 xcodegen，正在安装（需要 Homebrew）..."
  if ! command -v brew >/dev/null 2>&1; then
    echo "    错误：未安装 Homebrew。请先到 https://brew.sh 安装 Homebrew，再重新运行本脚本。"
    exit 1
  fi
  brew install xcodegen
fi

echo "==> 生成 Xcode 工程..."
xcodegen generate

echo "==> 完成。用 Xcode 打开 Veil.xcodeproj 即可。"
