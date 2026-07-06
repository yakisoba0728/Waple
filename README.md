# Waple

macOS용 [Wallpaper Engine](https://www.wallpaperengine.io/) 재구현. 로컬에 가지고 있는 Wallpaper
Engine 워크샵 프로젝트(`scene.pkg`, 동영상, 웹, 이미지)를 데스크톱 배경으로 네이티브 재생합니다.

씬 월페이퍼는 미리보기 이미지를 늘려 쓰는 것이 아니라, 패키지 안의 실제 씬 데이터를 Metal로 직접
렌더합니다 — WE의 GLSL 셰이더를 Metal Shading Language로 번역해 GPU에서 실행하고, 파티클·3D 메시·
퍼펫·오디오 반응까지 재현합니다.

> 비공식 프로젝트입니다. Valve, Steam, Wallpaper Engine과 무관하며 Wallpaper Engine은 해당 소유자의
> 상표입니다. Steam 접속·다운로드·인증 우회를 하지 않고, 사용자가 이미 로컬에 가진 파일만 재생합니다.

## 지원 범위

| 유형 | 재생 방식 |
| --- | --- |
| `scene.pkg` 씬 | 네이티브 Metal 렌더러(아래 씬 기능 참고) |
| `.mp4` `.mov` `.m4v` 동영상 | AVFoundation 바로 재생 |
| `.webm` `.mkv` `.avi` 동영상 | 로컬 `ffmpeg`로 mp4 변환 후 네이티브 재생 |
| `index.html` 웹 | 제한된 오프라인 WKWebView |
| `.jpg` `.png` `.gif` 이미지 | 정적 레이어 |

### 씬 렌더러가 지원하는 것

- **GLSL→MSL 트랜스파일러** — WE 이펙트 셰이더를 소스-투-소스 번역해 GPU 실행(실측 코퍼스 효과 ~99.9%
  컴파일). 전처리기(combos/`#include`/함수형 매크로), 식-레벨 타입 추론(HLSL 암시적 벡터 절단), GLSL
  struct·배열·`inverse()` 등 대응.
- **텍스처** — packed `.tex`(LZ4 블록), DXT1/3/5, RG88, R8, 스프라이트시트 프레임(`TEXS0001`–`0003`).
- **파티클** — 구/박스 이미터, 버스트, 전 이니셜라이저/연산자(움직임·수명·오실레이터·컨트롤포인트 인력·
  난류·remap 등), 자식 시스템(eventfollow/spawn/death), 스프라이트/트레일 렌더러, mapsequence.
- **레이어** — 키프레임 애니메이션(위치·크기·회전·불투명도·색, mirror 핑퐁), 프로퍼티 스크립트(JS),
  컴포지션(`_rt_` 프레임버퍼) 레이어, `colorBlendMode` 전 32종(`common_blending.h` 실공식).
- **3D 씬** — look-at 카메라, `.mdl` 메시(`MDLV0023`/변종), 빌보드, 부모 트랜스폼 계층, GPU 스키닝.
- **퍼펫 워프** — `MDLV0013` 메시·본·mirror 본 애니메이션·CPU 스키닝.
- **텍스트** — 폰트/정렬/색, 시계·날짜·미디어 스크립트(JavaScriptCore `update(value)`).
- **오디오** — 오디오 반응 이펙트(pulse/스펙트럼 바), 씬 내장 사운드(mp3) 재생.
- **마우스** — 시차(parallax), `g_PointerPosition` 커서 반응, `cursorClick`/`Down`/`Up`/`Move` 훅.

전체 Wallpaper Engine 런타임 호환을 주장하지는 않습니다. 미지원 씬 기능은 조용히 넘기고 로그를 남깁니다.

## 요구 사항

- macOS 13 이상, Apple Silicon
- Swift 5.9 이상 toolchain (Xcode command line tools)
- 선택: `.webm`/`.mkv`/`.avi` 변환용 `ffmpeg` (`brew install ffmpeg`)

### 공유 베이스 에셋

WE 씬은 패키지에 없는 공유 텍스처와 셰이더 헤더(`shaders/common.h` 등)를 참조합니다. 이 폴더를
지정해야 그런 씬이 온전히 렌더됩니다:

```bash
defaults write kr.yaki.waple waple.baseAssetsPath /path/to/wallpaper_engine/assets
```

미설정 시 `~/Downloads/wallpaper_dev/assets`, `~/Downloads/assets`를 자동 탐지합니다(`shaders/common.h`
존재로 검증). 저작권상 앱에 기본 번들하지 않으므로 사용자가 제공해야 합니다.

## 빌드와 실행

```bash
swift run Waple            # 메뉴바 유틸리티로 실행
swift test                 # 전체 테스트(523개) + 실물 씬 그라운드-트루스
swift build -c release     # 릴리스 빌드
bash scripts/package-app.sh  # Waple.app 번들 생성(화면보호기 .saver 포함)
```

## 데스크톱 통합

- **아이콘 위 창레벨** — 데스크톱 아이콘이 월페이퍼 위에 그대로 보입니다.
- **가림 자동 일시정지**(옵션) — 창이 데스크톱을 덮으면 렌더링을 멈춰 전력을 아낍니다.
- **정지 배경으로 설정** — 동영상 한 프레임·씬 캡처·이미지를 시스템 배경으로 지정.
- **화면보호기** — 동영상 배경을 macOS 화면보호기(`.saver`)로 재생(원래 화면보호기는 백업/복원).
- **로그인 시 시작**, **재생목록 로테이션**(셔플·간격), **모니터별 배경 할당**.

## 프로젝트 구조

```
Sources/
  WapleCore/     씬 파서, .tex/.mdl 디코더, GLSL 트랜스파일러, 파티클 시뮬레이터 (순수, 테스트 가능)
  WapleRender/   Metal 렌더러, 셰이더, 텍스처 디코드, 오디오/비디오/웹 렌더러
  WapleLibrary/  워크샵 폴더 스캔·가져오기·라이브러리 저장
  Waple/         메뉴바 앱(AppKit), 데스크톱 창, 화면보호기, 설정
Tests/           4개 타깃 · 523 테스트(합성 단위 + 실물 코퍼스 그라운드-트루스)
scripts/         package-app.sh (앱/화면보호기 번들)
```

## 검증 방식

렌더러 변경은 실물 씬 코퍼스를 전수 마운트·캡처해 검증합니다. 씬별 평균 휘도(luma) 기준선과 미리보기
픽셀 비교를 자동 판정에 쓰고, 오프스크린 PNG 렌더로 파티클·이펙트·3D 시각을 직접 확인합니다.

## 라이선스

미정.
