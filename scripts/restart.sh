#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# 检查是否已配置代码签名证书
if ! security find-identity -p codesigning -v 2>/dev/null | grep -q "QuickShow Development"; then
    echo "⚠️ 未检测到 QuickShow Development 证书，正在执行初始化配置..."
    "$PROJECT_DIR/scripts/setup_codesign.sh"
fi

echo "🔨 正在编译 QuickShow (Release)..."
xcodebuild -project QuickShow.xcodeproj -scheme QuickShow -configuration Release -destination 'platform=macOS' -derivedDataPath ./build_release build > /dev/null

echo "🛑 退出旧版本进程..."
killall QuickShow 2>/dev/null || true

# 稍微等待 0.2 秒让进程彻底释放
sleep 0.2

echo "🚀 启动最新 QuickShow..."
open ./build_release/Build/Products/Release/QuickShow.app 2>/dev/null || {
    echo "💡 如果处于沙箱环境，请在主机终端直接执行：pnpm restart 或 open ./build_release/Build/Products/Release/QuickShow.app"
}

echo "✅ 重启脚本执行完毕！"
