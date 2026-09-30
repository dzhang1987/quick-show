#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# 检查是否已配置代码签名证书
SIGN_IDENTITY="QuickShow Development"
if ! security find-identity -p codesigning -v 2>/dev/null | grep -q "QuickShow Development"; then
    SIGN_IDENTITY="-"
fi

echo "🔨 正在编译 QuickShow (Release)..."
xcodebuild -project QuickShow.xcodeproj -scheme QuickShow -configuration Release -destination 'platform=macOS' -derivedDataPath ./build_release CODE_SIGN_IDENTITY="$SIGN_IDENTITY" build > /dev/null

echo "🛑 退出旧版本进程..."
killall QuickShow 2>/dev/null || true

# 稍微等待 0.2 秒让进程彻底释放
sleep 0.2

echo "🚀 启动最新 QuickShow..."
open ./build_release/Build/Products/Release/QuickShow.app 2>/dev/null || {
    echo "💡 如果处于沙箱环境，请在主机终端直接执行：pnpm restart 或 open ./build_release/Build/Products/Release/QuickShow.app"
}

echo "✅ 重启脚本执行完毕！"
