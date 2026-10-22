#!/bin/bash
# DBoard 构建 & 安装脚本
# 用法: ./install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="DBoard"
INSTALL_DIR="$HOME/Applications"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="com.zz.dboard.plist"

echo "📋 DBoard — Mac 菜单栏看板插件"
echo "================================"
echo ""

# 1. 构建
echo "🔨 正在构建..."
cd "$SCRIPT_DIR"
swift build -c release 2>&1

BUILD_PATH=".build/release/$APP_NAME"
if [ ! -f "$BUILD_PATH" ]; then
    echo "❌ 构建失败"
    exit 1
fi
echo "✅ 构建成功"

# 2. 创建 .app 包
echo "📦 正在打包 .app..."
APP_DIR="$INSTALL_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_PATH" "$MACOS_DIR/$APP_NAME"
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns" 2>/dev/null || echo "⚠️  缺少 AppIcon.icns"

# 皮肤背景图复制到 App bundle
for bgf in "$SCRIPT_DIR"/Resources/bg-*; do
    [ -f "$bgf" ] && cp "$bgf" "$RESOURCES_DIR/"
done

# 应用发布台 token 指引图
for arf in "$SCRIPT_DIR"/Resources/app-release-*; do
    [ -f "$arf" ] && cp "$arf" "$RESOURCES_DIR/"
done

# Chrome 桥接扩展
[ -d "$SCRIPT_DIR/Resources/CookieBridge" ] && rm -rf "$RESOURCES_DIR/CookieBridge" && cp -R "$SCRIPT_DIR/Resources/CookieBridge" "$RESOURCES_DIR/"
# 已加载的解压版扩展也同步更新；Chrome 在 chrome://extensions 点「重新加载」后生效。
if [ -f "$HOME/DBoardCookieBridge/manifest.json" ]; then
    cp "$SCRIPT_DIR/Resources/CookieBridge/background.js" "$HOME/DBoardCookieBridge/background.js"
    cp "$SCRIPT_DIR/Resources/CookieBridge/manifest.json" "$HOME/DBoardCookieBridge/manifest.json"
fi

# Info.plist
cat > "$CONTENTS_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DBoard</string>
    <key>CFBundleDisplayName</key>
    <string>D板</string>
    <key>CFBundleIdentifier</key>
    <string>com.zz.dboard</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>DBoard</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# 稳定签名: ad-hoc 签名每次重建 cdhash 都变, 会导致"辅助功能"等 TCC 授权失效。
# 用一次性创建的自签证书签名, 授权绑定证书指纹, 重建后依然有效。
SIGN_IDENTITY="DBoard Local Sign"
SIGN_DIR="$HOME/Library/Application Support/DBoard/sign"
SIGN_KC="$HOME/Library/Keychains/dboard-sign.keychain-db"
if ! security find-identity -v -p codesigning "$SIGN_KC" 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "🔐 首次安装: 创建本地签名证书(之后重建不再丢失辅助功能授权)..."
    mkdir -p "$SIGN_DIR"
    cat > "$SIGN_DIR/cert.cnf" << 'CERTCNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = DBoard Local Sign
[ext]
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
CERTCNF
    openssl req -x509 -newkey rsa:2048 -keyout "$SIGN_DIR/key.pem" -out "$SIGN_DIR/cert.pem" \
        -days 3650 -nodes -config "$SIGN_DIR/cert.cnf" >/dev/null 2>&1
    security create-keychain -p dboard "$SIGN_KC" >/dev/null 2>&1 || true
    security unlock-keychain -p dboard "$SIGN_KC" >/dev/null 2>&1 || true
    security import "$SIGN_DIR/cert.pem" -k "$SIGN_KC" >/dev/null 2>&1 || true
    security import "$SIGN_DIR/key.pem" -k "$SIGN_KC" -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1 || true
    security add-trusted-cert -p codeSign "$SIGN_DIR/cert.pem" >/dev/null 2>&1 || true
fi
security unlock-keychain -p dboard "$SIGN_KC" >/dev/null 2>&1 || true
# 专用钥匙串加入搜索列表, 否则 codesign 找不到自签身份
security list-keychains -d user -s "$SIGN_KC" $(security list-keychains -d user | tr -d '"') >/dev/null 2>&1 || true
codesign --force --deep --sign "$SIGN_IDENTITY" --keychain "$SIGN_KC" "$APP_DIR" 2>/dev/null \
    || codesign --force --deep --sign - "$APP_DIR" 2>/dev/null \
    || echo "⚠️  codesign 失败(通知可能无法注册)"

echo "✅ App 已安装到 $APP_DIR"

# 3. 配置开机自启（LaunchAgent）
echo "⚙️  配置开机自启..."
mkdir -p "$LAUNCH_AGENT_DIR"

cat > "$LAUNCH_AGENT_DIR/$LAUNCH_AGENT_PLIST" << AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.zz.dboard</string>
    <key>ProgramArguments</key>
    <array>
        <string>open</string>
        <string>-a</string>
        <string>$APP_DIR</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
AGENT

# 加载 LaunchAgent
launchctl unload "$LAUNCH_AGENT_DIR/$LAUNCH_AGENT_PLIST" 2>/dev/null || true
launchctl load "$LAUNCH_AGENT_DIR/$LAUNCH_AGENT_PLIST"

echo "✅ 开机自启已配置"

# 4. 立即启动
echo ""
echo "🚀 启动 DBoard..."
# 先杀掉旧进程
pkill -f "$APP_NAME.app" 2>/dev/null || true
# 等旧进程真正退出再 open: 只 sleep 固定 0.5s 有竞态——旧进程没死透时
# open 会去唤醒那个将死的实例, 结果就是安装完应用"悄悄消失"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.3
done
open "$APP_DIR"

echo ""
echo "================================"
echo "✅ 安装完成！"
echo ""
echo "   📍 App 位置: $APP_DIR"
echo "   📍 开机自启: $LAUNCH_AGENT_DIR/$LAUNCH_AGENT_PLIST"
echo "   📍 D板数据:  ~/.claude/demand-center-cache.md"
echo "   📍 AI 引擎:  Qoder CN CLI（配置见 ~/.config/dboard/ai-provider.json）"
echo ""
echo "   菜单栏右上角找 ☑️ 图标即可使用"
echo ""
echo "   卸载方式:"
echo "   rm -rf \"$APP_DIR\""
echo "   launchctl unload \"$LAUNCH_AGENT_DIR/$LAUNCH_AGENT_PLIST\""
echo "   rm \"$LAUNCH_AGENT_DIR/$LAUNCH_AGENT_PLIST\""
echo "================================"
