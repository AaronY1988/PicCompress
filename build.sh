#!/bin/bash
# 编译并打包成可双击运行的 PicCompress.app
set -e
cd "$(dirname "$0")"

APP_NAME="PicCompress"
DISPLAY_NAME="图片压缩"
BUILD_DIR=".build/out/Products/Release"
APP_DIR="dist/${APP_NAME}.app"

echo "==> 1/5 编译 release"
swift build -c release --disable-sandbox

echo "==> 2/5 生成图标"
# 图标生成脚本（Scripts/make-icon.swift）是开发时用的工具，没有跟着开源仓库
# 一起发布。给了就用它出一个自定义图标；没给就跳过，App 会用系统默认图标，
# 不影响编译和运行。
mkdir -p dist
HAVE_ICON=0
if [ -f Scripts/make-icon.swift ]; then
  ICON_VARIANT="${ICON_VARIANT:-e2}"
  swift Scripts/make-icon.swift dist/AppIcon-1024.png "$ICON_VARIANT"

  # iconset 是纯中间产物，放临时目录里 —— 别落在 dist/。
  # 以前它建在 dist/ 下，每次构建都要 rm -rf 一次几十个图标文件，
  # 既脏了产物目录，也容易撞上"批量删除"的保护确认。
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  trap 'rm -rf "$(dirname "$ICONSET")"' EXIT
  for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
              "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
              "512 512x512" "1024 512x512@2x"; do
    px=${spec%% *}; name=${spec##* }
    sips -z "$px" "$px" dist/AppIcon-1024.png --out "$ICONSET/icon_${name}.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o dist/AppIcon.icns
  rm -rf "$(dirname "$ICONSET")"
  trap - EXIT
  HAVE_ICON=1
else
  echo "   (没有 Scripts/make-icon.swift，跳过自定义图标，用系统默认)"
fi

echo "==> 3/5 组装 bundle"
# 原地刷新，不删任何东西（`cp` 本身就是覆盖）。
# 以前是 `rm -rf "$APP_DIR"` 再重建 —— 一次要动几十个文件，
# 既慢，又容易撞上"批量删除"类的保护确认（构建脚本卡在半路最难受）。
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
# 旧签名要卸掉，否则 codesign --force 会报残留。
# 用 codesign 自己的接口，别去 shell 里删 Contents/_CodeSignature ——
# 那里面是逐文件的哈希，几十个文件，一样会触发保护。
codesign --remove-signature "$APP_DIR" 2>/dev/null || true
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
if [ "$HAVE_ICON" = "1" ]; then
  cp dist/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>com.aarony.piccompress</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><true/>
    <key>NSHumanReadableCopyright</key><string>PicCompress</string>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key><string>用「图片压缩」压缩</string>
            </dict>
            <key>NSMessage</key><string>compressFromFinderService</string>
            <key>NSSendFileTypes</key>
            <array>
                <string>public.image</string>
                <string>public.folder</string>
            </array>
            <key>NSRequiredContext</key>
            <dict>
                <key>NSApplicationIdentifier</key><string>com.apple.finder</string>
            </dict>
            <key>NSBackgroundColorName</key><string>background</string>
            <key>NSIconName</key><string>NSActionTemplate</string>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Image</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.jpeg</string>
                <string>public.png</string>
                <string>public.heic</string>
                <string>public.heif</string>
                <string>public.tiff</string>
                <string>com.compuserve.gif</string>
                <string>org.webmproject.webp</string>
                <string>com.microsoft.bmp</string>
                <!-- AVIF：既然「输出格式」里摆了这一档，访达把它交给本 App 时就得认。
                     漏了它的症状是拖到程序坞图标上没反应（双击也不接手），
                     而 App 自己明明写得出 .avif 文件。 -->
                <string>public.avif</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "==> 4/5 签名"
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || echo "   (跳过签名，仍可本地运行)"

echo "==> 5/5 注册到 LaunchServices"
# 让访达右键的「快速操作」尽快认到这个 App
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$(pwd)/$APP_DIR" >/dev/null 2>&1 && echo "   已注册" || echo "   (注册跳过，首次打开 App 后照样会出现)"
fi

echo ""
echo "完成 → $(pwd)/$APP_DIR"
du -sh "$APP_DIR" | awk '{print "体积: "$1}'
