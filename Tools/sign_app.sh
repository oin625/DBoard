#!/bin/bash
# Shared by install.sh and incremental local updates. Run with bash, after packaging.
set -euo pipefail

sign_app="${1:-$HOME/Applications/DBoard.app}"
sign_identity="DBoard Local Sign"
sign_keychain="$HOME/Library/Keychains/dboard-sign.keychain-db"

if [ "$#" -gt 1 ] || [ ! -d "$sign_app/Contents" ]; then
    echo "用法: bash Tools/sign_app.sh /绝对路径/DBoard.app" >&2
    exit 2
fi

# Validation needs no private key; an unchanged valid app does not need to be signed again.
if /usr/bin/codesign --verify --deep --strict "$sign_app" >/dev/null 2>&1 &&
   /usr/bin/codesign -dv --verbose=2 "$sign_app" 2>&1 | /usr/bin/grep -Fx "Authority=$sign_identity" >/dev/null; then
    echo "✅ DBoard 签名有效，无需重复签名"
    exit 0
fi

if [ ! -f "$sign_keychain" ] ||
   ! /usr/bin/security find-identity -v -p codesigning "$sign_keychain" 2>/dev/null |
       /usr/bin/grep -F "\"$sign_identity\"" >/dev/null; then
    echo "❌ 未找到 DBoard 本机签名证书，请先运行 install.sh 完成首次安装。" >&2
    exit 1
fi

# This is only the dedicated DBoard signing keychain's existing installation password.
# Keep its sleep/timeout locking and existing key ACLs; never touch the login keychain.
if ! /usr/bin/security unlock-keychain -p dboard "$sign_keychain" >/dev/null 2>&1; then
    echo "❌ 无法自动解锁 DBoard 专用签名钥匙串；已停止签名，请核对该专用钥匙串的安装配置。" >&2
    exit 1
fi

/usr/bin/codesign --force --deep --sign "$sign_identity" --keychain "$sign_keychain" "$sign_app"
/usr/bin/codesign --verify --deep --strict "$sign_app"
echo "✅ DBoard 已使用原本机证书完成签名"
