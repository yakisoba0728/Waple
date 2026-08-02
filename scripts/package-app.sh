#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# 버전/빌드 번호/서명 아이덴티티는 env 로 주입한다(기본값은 하드코딩 시절과 동일 → 무회귀).
#   WAPLE_VERSION       CFBundleShortVersionString (기본 0.1)
#   WAPLE_BUILD         CFBundleVersion            (기본 1)
#   WAPLE_SIGN_IDENTITY codesign 아이덴티티        (기본 "-" = ad-hoc)
# Developer ID 를 지정하면 Gatekeeper 통과를 위해 --options runtime(hardened runtime)을 추가한다.
WAPLE_VERSION="${WAPLE_VERSION:-0.1}"
WAPLE_BUILD="${WAPLE_BUILD:-1}"
WAPLE_SIGN_IDENTITY="${WAPLE_SIGN_IDENTITY:--}"

CONFIG=release
swift build -c "$CONFIG"

APP="$PWD/Waple.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/Waple" "$APP/Contents/MacOS/Waple"

# 앱 아이콘 — scripts/make-icon.sh 로 생성해 커밋한 .icns 를 번들에 동봉(CFBundleIconFile 로 참조).
mkdir -p "$APP/Contents/Resources"
cp "scripts/Waple.icns" "$APP/Contents/Resources/Waple.icns"

# 현지화 카탈로그 — 키가 곧 한국어 원문이라 ko.lproj 는 비어 있고, en.lproj 만 실제 번역을 담는다.
# **앱 번들의 Contents/Resources** 에 놓는 것이 핵심이다: SwiftUI 의 Text("한국어") 리터럴은
# Bundle.main 에서 LocalizedStringKey 를 찾으므로, SPM 리소스 번들에 두면 조회가 안 된다.
# (그래서 `swift run Waple` 개발 실행은 항상 한국어로 나온다 — 의도된 차이다.)
cp -R "Resources/en.lproj" "Resources/ko.lproj" "$APP/Contents/Resources/"

# WE 공유 에셋 — **앱 안에 반드시 들어가야 한다.** 없으면 씬이 흰 화면으로 그려진다
# (실측: 에셋 차단 시 170종 중 156종 변화·113종 심각).
#
# SwiftPM 리소스 번들(Waple_WapleRender.bundle)을 통째로 넣지 않고 **WEAssets 폴더만** 넣는다.
# 이유: `Bundle.module` 의 탐색 후보가 빌드 시스템마다 다르고(swiftbuild=Contents/Resources,
# native=앱 루트+빌드 절대경로), 앱 루트에는 codesign 이 파일을 못 두게 한다. 그래서 코드가
# Bundle.module 을 안 쓰고 직접 찾도록 바꿨고(BaseAssetsSettings), 그 첫 후보가 여기다.
SRC_ASSETS=""
for cand in ".build/$CONFIG/Waple_WapleRender.bundle/Contents/Resources/WEAssets" \
            ".build/$CONFIG/Waple_WapleRender.bundle/WEAssets"; do
  [ -d "$cand" ] && { SRC_ASSETS="$cand"; break; }
done
[ -n "$SRC_ASSETS" ] || { echo "!! .build/$CONFIG 에서 WEAssets 를 못 찾았다 — 빌드 확인" >&2; exit 1; }
cp -R "$SRC_ASSETS" "$APP/Contents/Resources/WEAssets"
echo "  WE 공유 에셋 동봉: $(du -sh "$APP/Contents/Resources/WEAssets" | cut -f1)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Waple</string>
  <key>CFBundleDisplayName</key><string>Waple</string>
  <key>CFBundleIdentifier</key><string>kr.yaki.waple</string>
  <key>CFBundleVersion</key><string>${WAPLE_BUILD}</string>
  <key>CFBundleShortVersionString</key><string>${WAPLE_VERSION}</string>
  <key>CFBundleExecutable</key><string>Waple</string>
  <key>CFBundleIconFile</key><string>Waple</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <!-- 원본 언어. 사용 가능한 언어는 Contents/Resources/*.lproj 가 스스로 선언하므로
       CFBundleLocalizations 는 두지 않는다(둘 다 두면 목록이 중복된다). -->
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
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

cat > "$SAVER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Waple</string>
  <key>CFBundleIdentifier</key><string>kr.yaki.waple.saver</string>
  <key>CFBundleExecutable</key><string>WapleSaver</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleVersion</key><string>${WAPLE_BUILD}</string>
  <key>CFBundleShortVersionString</key><string>${WAPLE_VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>WapleSaverView</string>
</dict>
</plist>
PLIST

# --deep 이 중첩 번들(saver)까지 서명한다. 기본 "-" = ad-hoc.
# Developer ID 지정 시 hardened runtime(--options runtime)을 함께 건다(공증 전제 조건).
SIGN_ARGS=(--force --deep --sign "$WAPLE_SIGN_IDENTITY")
if [ "$WAPLE_SIGN_IDENTITY" != "-" ]; then
  SIGN_ARGS+=(--options runtime)
fi
codesign "${SIGN_ARGS[@]}" --identifier kr.yaki.waple "$APP"

# ── 배포 게이트 ────────────────────────────────────────────────────────
# ① 구조: 공유 에셋이 실제로 들어갔는지(대표 파일까지) 확인한다.
[ -f "$APP/Contents/Resources/WEAssets/shaders/common.h" ] \
  || { echo "!! 앱에 WEAssets/shaders/common.h 가 없다 — 씬이 흰 화면으로 나간다" >&2; exit 1; }

# ② 실행: 앱을 실제로 띄워 **죽지 않는지** 본다. 마운트·plist·서명 검증만으로는
#    v0.1.0-beta.3 의 즉사(Bundle.module fatalError)를 못 잡았다.
#    WAPLE_SKIP_SMOKE=1 로 끌 수 있다(GUI 세션이 없는 환경 대비).
if [ "${WAPLE_SKIP_SMOKE:-0}" != "1" ]; then
  SMOKE_LOG="$(mktemp)"
  "$APP/Contents/MacOS/Waple" > "$SMOKE_LOG" 2>&1 &
  SMOKE_PID=$!
  sleep 6
  if kill -0 "$SMOKE_PID" 2>/dev/null; then
    kill "$SMOKE_PID" 2>/dev/null || true
    wait "$SMOKE_PID" 2>/dev/null || true
    echo "  실행 스모크 통과(6초 생존)"
  else
    echo "!! 앱이 6초 안에 죽었다 — 배포 불가. 로그:" >&2
    head -20 "$SMOKE_LOG" >&2
    rm -f "$SMOKE_LOG"
    exit 1
  fi
  rm -f "$SMOKE_LOG"
fi

echo "Built $APP"

# ── 배포용 DMG ──────────────────────────────────────────────────────────
# 외부 의존성 없이(zero-dep) hdiutil 로 압축 DMG(UDZO) 생성. 스테이징 폴더에
# 앱 + /Applications 심볼릭 링크를 넣어 드래그 설치 UX 를 준다.
DMG="$PWD/Waple.dmg"
rm -f "$DMG"
STAGING="$(mktemp -d)"
# hdiutil 실패 등 set -e 중간 종료 시에도 스테이징이 /tmp 에 남지 않도록 EXIT trap(make-icon.sh:9 와 동일 패턴).
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Waple" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
echo "Built $DMG"

# 릴리스 노트/Homebrew cask 갱신에 쓸 sha256 을 항상 출력한다.
shasum -a 256 "$DMG"
