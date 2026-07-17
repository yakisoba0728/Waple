#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
swift build -c "$CONFIG"

APP="$PWD/Waple.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/Waple" "$APP/Contents/MacOS/Waple"

# 앱 아이콘 — scripts/make-icon.sh 로 생성해 커밋한 .icns 를 번들에 동봉(CFBundleIconFile 로 참조).
mkdir -p "$APP/Contents/Resources"
cp "scripts/Waple.icns" "$APP/Contents/Resources/Waple.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Waple</string>
  <key>CFBundleDisplayName</key><string>Waple</string>
  <key>CFBundleIdentifier</key><string>kr.yaki.waple</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleExecutable</key><string>Waple</string>
  <key>CFBundleIconFile</key><string>Waple</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# ── 화면보호기(.saver) 번들 ─────────────────────────────────────────────
# SPM 은 .saver 번들 타깃을 만들 수 없으므로 clang -bundle 로 직접 컴파일해
# Resources 에 동봉한다. 앱의 ScreenSaverController 가 ~/Library/Screen Savers 로 설치.
SAVER="$APP/Contents/Resources/Waple.saver"
mkdir -p "$SAVER/Contents/MacOS"
xcrun clang -fobjc-arc -bundle -mmacosx-version-min=13.0 \
  -framework AppKit -framework AVFoundation -framework CoreMedia \
  -framework QuartzCore -framework ScreenSaver \
  Sources/WapleSaver/WapleSaverView.m \
  -o "$SAVER/Contents/MacOS/WapleSaver"

cat > "$SAVER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Waple</string>
  <key>CFBundleIdentifier</key><string>kr.yaki.waple.saver</string>
  <key>CFBundleExecutable</key><string>WapleSaver</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>WapleSaverView</string>
</dict>
</plist>
PLIST

# --deep 이 중첩 번들(saver)까지 ad-hoc 서명한다.
codesign --force --deep --sign - --identifier kr.yaki.waple "$APP"
echo "Built $APP"

# ── 배포용 DMG ──────────────────────────────────────────────────────────
# 외부 의존성 없이(zero-dep) hdiutil 로 압축 DMG(UDZO) 생성. 스테이징 폴더에
# 앱 + /Applications 심볼릭 링크를 넣어 드래그 설치 UX 를 준다.
DMG="$PWD/Waple.dmg"
rm -f "$DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Waple" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"
echo "Built $DMG"
