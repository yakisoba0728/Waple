# 배포(Releasing)

Waple 은 외부 SPM 의존성 0 원칙을 지킨다. 패키징도 macOS 기본 도구(`swift`, `clang`,
`codesign`, `hdiutil`)만 쓴다.

## 1. 패키징

```sh
scripts/package-app.sh
```

이 스크립트가 하는 일:

1. `swift build -c release` 로 릴리스 바이너리 빌드.
2. `Waple.app` 번들 구성(`Contents/MacOS/Waple` + `Info.plist`, `LSUIElement`=메뉴바 전용 앱).
3. 화면보호기 번들 `Waple.saver` 를 `clang -bundle` 로 컴파일해 앱 `Resources/` 에 동봉
   (SPM 은 `.saver` 타깃을 못 만들므로 직접 컴파일).
4. `codesign --force --deep --sign -` 로 ad-hoc 서명(중첩 saver 번들 포함).
5. `hdiutil create -format UDZO` 로 배포용 `Waple.dmg` 생성(앱 + `/Applications` 심볼릭 링크).

산출물:

- `Waple.app` — 로컬 실행/설치용.
- `Waple.dmg` — 배포용 압축 디스크 이미지(드래그 설치).

### 서명/공증(선택)

ad-hoc 서명은 로컬/개인 배포용이다. 공개 배포 시 Developer ID 서명 + notarization 이 필요하다:

```sh
codesign --force --deep --options runtime --sign "Developer ID Application: <NAME> (<TEAMID>)" Waple.app
xcrun notarytool submit Waple.dmg --keychain-profile "<PROFILE>" --wait
xcrun stapler staple Waple.dmg
```

## 2. 릴리스 체크리스트

1. `scripts/package-app.sh` 의 `Info.plist` 에서 `CFBundleShortVersionString`/`CFBundleVersion` 갱신.
2. `swift test` 그린 확인(렌더 스위트 포함 전체를 로컬에서 전수 실행 — 시간이 오래 걸리지만 현재 저장소에 CI 는 없다).
3. `scripts/package-app.sh` 실행 → `Waple.dmg` 산출.
4. GitHub 릴리스에 `Waple.dmg` 업로드, 태그(`v0.1.0` 등) 부여.
5. Homebrew cask 사용 시 아래 템플릿의 `version`/`sha256`/`url` 갱신.

## 3. Homebrew Cask 템플릿

GitHub 릴리스에 DMG 를 올린 뒤, 개인 tap(`homebrew-<tap>`)에 아래 cask 를 추가하면
`brew install --cask waple` 로 설치할 수 있다.

```ruby
cask "waple" do
  version "0.1.0"
  sha256 "REPLACE_WITH_DMG_SHA256"   # shasum -a 256 Waple.dmg

  url "https://github.com/<owner>/Waple/releases/download/v#{version}/Waple.dmg"
  name "Waple"
  desc "macOS 메뉴바 라이브 월페이퍼 앱"
  homepage "https://github.com/<owner>/Waple"

  app "Waple.app"

  # 메뉴바 전용(LSUIElement) 앱이라 별도 서비스 정의는 없음.
  zap trash: [
    "~/Library/Application Support/Waple",
    "~/Library/Preferences/kr.yaki.waple.plist",
    "~/Library/Screen Savers/Waple.saver",
  ]
end
```

`sha256` 은 `shasum -a 256 Waple.dmg` 로 계산해 넣는다.

## 4. 향후 항목(현재 범위 외)

- **자동 업데이트 체커**: zero-dep 원칙상 Sparkle 등 외부 프레임워크는 추가하지 않는다.
  GitHub 릴리스 폴링 기반 업데이트 체커는 릴리스 인프라(안정적 태그/에셋 네이밍 규약)가
  갖춰진 뒤 별도 SP 로 다룬다 — 현재는 미구현.
- **Developer ID 서명·공증 자동화**: 위 수동 절차를 CI 파이프라인으로.
