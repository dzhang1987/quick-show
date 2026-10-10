#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# 检查是否已配置代码签名证书
SIGN_IDENTITY="QuickShow Development"
if ! security find-identity -p codesigning -v 2>/dev/null | grep -q "QuickShow Development"; then
    SIGN_IDENTITY="-"
fi

# 新增/删除源文件后必须重新生成 Xcode 工程（XcodeGen）
if command -v xcodegen > /dev/null 2>&1; then
    echo "⚙️  重新生成 Xcode 工程 (xcodegen)..."
    xcodegen generate > /dev/null
else
    echo "⚠️  未检测到 xcodegen，跳过工程生成（新增源文件将不会参与编译）"
fi

echo "🔨 正在编译 QuickShow (Release)..."
# 编译输出落盘到临时日志：成功即删；失败打印错误摘要与完整日志路径，不再静默吞错
BUILD_LOG="$(mktemp -t quickshow_build)"
# CODE_SIGN_STYLE=Manual：SPM 包产物（如 SwiftMath）默认 Automatic 风格会强制要求
# 开发团队（Team），自签证书没有 Team 会编译失败；全局覆盖为 Manual 后包产物跳过
# Team 校验，随主 target 一并用 SIGN_IDENTITY 签名，身份稳定，TCC 权限跨编译持续有效
if ! xcodebuild -project QuickShow.xcodeproj -scheme QuickShow -configuration Release -destination 'platform=macOS' -derivedDataPath ./build CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_STYLE=Manual build > "$BUILD_LOG" 2>&1; then
    echo "❌ 编译失败，错误摘要："
    grep -E "error: " "$BUILD_LOG" | head -20 || echo "（日志中无 error: 行，请查看完整日志）"
    echo "💡 完整日志：$BUILD_LOG"
    exit 1
fi
rm -f "$BUILD_LOG"

echo "🛑 退出旧版本进程..."
killall QuickShow 2>/dev/null || true

# 稍微等待 0.2 秒让进程彻底释放
sleep 0.2

echo "🚀 启动最新 QuickShow..."
open ./build/Build/Products/Release/QuickShow.app 2>/dev/null || {
    echo "💡 启动失败，请在主机终端直接执行：./scripts/restart.sh"
}

echo "✅ 重启脚本执行完毕！"
