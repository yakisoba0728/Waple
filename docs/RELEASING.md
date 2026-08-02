# 배포(Releasing)

Waple 은 외부 SPM 의존성 0 원칙을 지킨다. 패키징도 macOS 기본 도구(`swift`, `clang`,
`codesign`, `hdiutil`)만 쓴다.

## 1. 릴리스 절차(자동화)

**태그 push 가 릴리스의 시작점이다.** `.github/workflows/release.yml` 이 아래를 자동 수행한다:

1. 태그(`v0.2.0` 등)에서 버전 추출(v 접두사 제거) → `WAPLE_VERSION` 으로 주입.
   빌드 번호(`WAPLE_BUILD`)는 `github.run_number`.
2. `scripts/package-app.sh` 실행 → `Waple.dmg` 산출(서명: 아래 §2 참조).
3. `shasum -a 256 Waple.dmg` 계산.
4. **draft** GitHub Release 생성 + `Waple.dmg` 업로드. 본문에 sha256 포함
   (Homebrew cask 갱신용). 웹 UI 에서 검토 후 "Publish release" 로 공개한다.

로컬에서의 릴리스 체크리스트:

1. `swift test` 그린 확인(CI 에서도 돌지만, 태그는 로컬에서 그린을 확인한 커밋에 붙인다).
2. `git tag v<버전> && git push origin v<버전>`.
3. 워크플로 완료 후 draft 릴리스를 열어 DMG/노트/sha256 검토 → Publish.
4. Homebrew cask 사용 시 §3 템플릿의 `version`/`sha256` 갱신.

## 2. 패키징 스크립트(로컬)

```sh
scripts/package-app.sh
```

버전/빌드 번호/서명 아이덴티티는 env 로 주입할 수 있다(기본값은 과거 하드코딩과 동일):

```sh
WAPLE_VERSION=1.2.3 WAPLE_BUILD=45 WAPLE_SIGN_IDENTITY="Developer ID Application: <NAME> (<TEAMID>)" \
  scripts/package-app.sh
```

- `WAPLE_VERSION`(기본 `0.1`) — 앱과 내장 saver 양쪽의 `CFBundleShortVersionString`.
- `WAPLE_BUILD`(기본 `1`) — 양쪽의 `CFBundleVersion`.
- `WAPLE_SIGN_IDENTITY`(기본 `-` = ad-hoc) — Developer ID 지정 시 `--options runtime`
  (hardened runtime, 공증 전제 조건)이 자동으로 붙는다.

스크립트가 하는 일:

1. `swift build -c release` 로 릴리스 바이너리 빌드.
2. `Waple.app` 번들 구성(`Contents/MacOS/Waple` + `Info.plist`, `LSUIElement`=메뉴 바 전용 앱).
3. 화멘보호기 번들 `Waple.saver` 를 `clang -bundle` 로 컴파일해 앱 `Resources/` 에 동봉
   (SPM 은 `.saver` 타깃을 못 만들므로 직접 컴파일).
4. `codesign --force --deep` 서명(중첩 saver 번들 포함).
5. `hdiutil create -format UDZO` 로 배포용 `Waple.dmg` 생성(앱 + `/Applications` 심볼릭 링크).
6. `shasum -a 256 Waple.dmg` 출력.

산출물:

- `Waple.app` — 로컬 실행/설치용.
- `Waple.dmg` — 배포용 압축 디스크 이미지(드래그 설치).

### 배포 게이트 (package-app.sh)

패키징은 두 게이트를 통과해야 DMG 를 만든다. 둘 다 실제 사고에서 나왔다.

1. **리소스 번들 동봉 확인** — `.build/<config>/*.bundle` 을 전부 `Contents/Resources/` 에 넣고,
   하나라도 없으면 실패한다. SwiftPM 의 `Bundle.module` 은 못 찾으면 경고가 아니라
   **fatalError** 라, 빠뜨리면 앱이 실행 즉시 죽는다.
2. **실행 스모크** — 패키징된 앱을 6초 띄워 살아 있는지 본다. GUI 세션이 없는 환경에서는
   `WAPLE_SKIP_SMOKE=1` 로 끌 수 있다(끄면 ①만 남는다).

> **왜 있는가**: `v0.1.0-beta.3` 이 **WEAssets 85MB 가 빠진 채**(DMG 2.9MB) 공개됐고,
> 앱은 `unable to find bundle named Waple_WapleRender` 로 즉사했다. 그때까지의 릴리스 검증은
> DMG 마운트·plist·arm64·codesign 만 봤다 — **앱을 실행해 본 적이 없었다.**
> 정상 산출물 크기는 app ≈94MB / DMG ≈70MB 다.

### 서명/공증 정책

- **CI**: 아래 secrets 가 **전부** 설정되면 Developer ID 서명 + `notarytool` 공증 +
  `stapler staple` + 검증까지 자동 수행한다. 하나라도 없으면 ad-hoc 서명으로 폴백하고
  릴리스 노트에 첫 실행 Gatekeeper 안내가 붙는다(릴리스 자체는 멈추지 않는다).

| secret | 내용 |
| --- | --- |
| `DEVELOPER_ID_APPLICATION` | `Developer ID Application: NAME (TEAMID)` — codesign 아이덴티티 문자열 |
| `DEVELOPER_ID_CERT_P12` | 인증서 `.p12` 를 base64 로 인코딩한 값 (`base64 -i cert.p12 \| pbcopy`) |
| `DEVELOPER_ID_CERT_PASSWORD` | `.p12` 내보내기 암호 |
| `NOTARY_APPLE_ID` | Apple ID (공증 제출 계정) |
| `NOTARY_TEAM_ID` | 10자 팀 ID |
| `NOTARY_PASSWORD` | **앱 암호**(app-specific password, 계정 암호 아님) |

워크플로가 하는 일(순서): 임시 키체인 생성 → `.p12` 임포트 →
`set-key-partition-list`(이걸 빼면 codesign 이 GUI 프롬프트를 기다리다 잡이 멈춘다) →
패키징 → `notarytool submit --wait` → `stapler staple` → `stapler validate` + `spctl` →
잡 종료 시 키체인 삭제(`if: always()`).

`--keychain-profile` 방식은 쓰지 않는다 — 그건 `notarytool store-credentials` 를 미리
돌린 머신에서만 통하고, 러너는 매 실행 새 VM 이다.

- **수동**: ad-hoc 서명은 로컬/개인 배포용이다. 공개 배포 시 수동 절차:

```sh
WAPLE_SIGN_IDENTITY="Developer ID Application: <NAME> (<TEAMID>)" scripts/package-app.sh
xcrun notarytool submit Waple.dmg --apple-id <APPLE_ID> --team-id <TEAMID> --password <APP_PASSWORD> --wait
xcrun stapler staple Waple.dmg
xcrun stapler validate Waple.dmg
```

## 3. Homebrew Cask 템플릿

GitHub 릴리스에 DMG 를 올린 뒤, 개인 tap(`homebrew-<tap>`)에 아래 cask 를 추가하면
`brew install --cask waple` 로 설치할 수 있다.

```ruby
cask "waple" do
  version "0.1.0"
  sha256 "REPLACE_WITH_DMG_SHA256"   # 릴리스 노트 본문 또는 shasum -a 256 Waple.dmg

  url "https://github.com/<owner>/Waple/releases/download/v#{version}/Waple.dmg"
  name "Waple"
  desc "macOS 메뉴 바 라이브 월페이퍼 앱"
  homepage "https://github.com/<owner>/Waple"

  app "Waple.app"

  # 메뉴 바 전용(LSUIElement) 앱이라 별도 서비스 정의는 없음.
  zap trash: [
    "~/Library/Application Support/Waple",
    "~/Library/Preferences/kr.yaki.waple.plist",
    "~/Library/Screen Savers/Waple.saver",
  ]
end
```

`sha256` 은 릴리스 노트에 포함된 값을 그대로 쓰거나 `shasum -a 256 Waple.dmg` 로 계산한다.

## 4. 향후 항목(현재 범위 외)

- **자동 업데이트 체커**: zero-dep 원칙상 Sparkle 등 외부 프레임워크는 추가하지 않는다.
  GitHub 릴리스 폴 링 기반 업데이트 체커는 릴리스 인프라(안정적 태그/에셋 네이밍 규약)가
  갖춰진 뒤 별도 SP 로 다룬다 — 현재는 미구현.
- **릴리스 자동 공개**: 현재 워크플로는 draft 로 생성한다. 자동 공개는 운영 안정화 후
  `--draft` 제거로 전환.
