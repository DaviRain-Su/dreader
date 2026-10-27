#!/bin/bash
set -e

echo "🔨 正在编译 DReader 原生 macOS Release 版本..."
swift build -c release

BIN_PATH=$(swift build -c release --show-bin-path)/DReader
APP_BUNDLE="DReader.app"

echo "📦 正在打包 ${APP_BUNDLE}..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/DReader"

if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

cat << 'EOF' > "${APP_BUNDLE}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>DReader</string>
    <key>CFBundleIdentifier</key>
    <string>com.dreader.mac</string>
    <key>CFBundleName</key>
    <string>DReader</string>
    <key>CFBundleDisplayName</key>
    <string>DReader</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Electronic Publication (EPUB)</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.idpf.epub-container</string>
                <string>public.epub-book</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

echo "🔏 正在进行本机 ad-hoc 代码签名..."
codesign --force --deep -s - "${APP_BUNDLE}"

echo "✨ 打包完成！你可以直接双击运行 DReader.app 或在终端执行 open DReader.app"
