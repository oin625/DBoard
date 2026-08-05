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

# 重新 ad-hoc 签名整个 .app, 绑定 Info.plist / bundle id(通知授权必需)
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || echo "⚠️  codesign 失败(通知可能无法注册)"

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
sleep 0.5
open "$APP_DIR"

echo ""
echo "================================"
echo "✅ 安装完成！"
echo ""
echo "   📍 App 位置: $APP_DIR"
echo "   📍 开机自启: $LAUNCH_AGENT_DIR/$LAUNCH_AGENT_PLIST"
echo "   📍 数据源:   ~/.claude/demand-center-cache.md"
echo ""
echo "   菜单栏右上角找 ☑️ 图标即可使用"
echo ""
echo "   卸载方式:"
echo "   rm -rf \"$APP_DIR\""
echo "   launchctl unload \"$LAUNCH_AGENT_DIR/$LAUNCH_AGENT_PLIST\""
echo "   rm \"$LAUNCH_AGENT_DIR/$LAUNCH_AGENT_PLIST\""
echo "================================"
