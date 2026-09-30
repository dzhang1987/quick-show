#!/bin/bash
set -e

CERT_NAME="QuickShow Development"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="/tmp/quickshow_codesign_$$"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [ ! -f "$KEYCHAIN" ]; then
    KEYCHAIN="$HOME/Library/Keychains/login.keychain"
fi

echo "🔐 正在检查现有代码签名证书..."
if security find-identity -p codesigning -v | grep -q "$CERT_NAME"; then
    echo "🎉 证书 [$CERT_NAME] 已经存在且有效，无需重复创建！"
    exit 0
fi

echo "🚀 开始创建本地自签名代码签名证书: [$CERT_NAME]..."
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR"

# 1. 编写 OpenSSL 证书配置
cat << 'CNF' > cert.cnf
[ req ]
default_bits        = 2048
distinguished_name  = req_distinguished_name
x509_extensions     = v3_codesign
prompt              = no

[ req_distinguished_name ]
CN                  = QuickShow Development

[ v3_codesign ]
keyUsage            = critical, digitalSignature
extendedKeyUsage    = critical, codeSigning
basicConstraints    = critical, CA:FALSE
subjectKeyIdentifier= hash
CNF

# 2. 生成私钥和自签名证书（有效期 10 年）
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout quickshow.key -out quickshow.crt \
  -config cert.cnf >/dev/null 2>&1

# 3. 打包为 PKCS#12（使用 legacy 模式兼容 macOS Keychain）
openssl pkcs12 -export -out quickshow.p12 \
  -inkey quickshow.key -in quickshow.crt \
  -name "$CERT_NAME" \
  -password pass:quickshow_local \
  -legacy >/dev/null 2>&1

echo "📥 正在将证书导入用户登录钥匙串..."
security import quickshow.p12 -k "$KEYCHAIN" -P quickshow_local -T /usr/bin/codesign -T /usr/bin/security

echo "🔑 正在设置私钥访问权限..."
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" 2>/dev/null || true

echo "🛡️ 正在将证书加入用户受信任列表（macOS 可能会弹出密码或指纹确认窗口）..."
security add-trusted-cert -d -r trustRoot -p codeSign "$TEMP_DIR/quickshow.crt"

# 4. 清理临时文件
rm -rf "$TEMP_DIR"

echo "🔍 验证证书状态..."
if security find-identity -p codesigning -v | grep -q "$CERT_NAME"; then
    echo "✅ 成功！本地代码签名证书 [$CERT_NAME] 已就绪且已信任！"
else
    echo "⚠️ 证书已创建，但可能尚未在当前终端生效，请运行 'security find-identity -p codesigning -v' 检查。"
fi
