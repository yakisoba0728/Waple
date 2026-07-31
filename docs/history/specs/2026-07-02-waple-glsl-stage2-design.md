# GLSL→MSL 변환기 Stage 2 + 렌더 버그 정리 — 설계

날짜: 2026-07-02. 브랜치: `feat/glsl-stage2`. 선행: Stage 1 (Steps 0–4, main 머지).

## 상태(2026-07-04) — 구현됨, 실측 코퍼스 재이전

Stage 2 (엔진 심볼 상시 매핑·헬퍼 방출·straight-alpha premult 전환·파티클 z-순서 인터리브)는 구현·병합됨. §25 의 "이전 세션 실측 데이터(~/Downloads/packages)는 디스크에서 삭제됨(2026-07-02)"는 당시 사실 기록으로 유지한다 — 이후 실측 코퍼스는 `~/Downloads/wallpaper_dev/backgrounds`(공유 에셋 팩 `~/Downloads/wallpaper_dev/assets`)로 재구성되었다. §3 의 premult 규약 전환과 §"파티클 z-순서"는 각각 glsl-to-msl §3.5·sp4 문서의 폐기 마킹과 연결된다.

## 배경 / 목표

Stage 1 결론(26개 실측 pkg): 실제 워크샵/스톡 효과는 전부 graceful fallback.
근본 원인 두 가지:

1. **선언이 common.h 에 있다** — 실제 effect `.frag/.vert` 는 `g_Time`, `g_ModelViewProjectionMatrix`,
   `a_Position`, `a_TexCoord` 등을 직접 선언하지 않고 `#include "common.h"` (베이스팩 전용, pkg 에 없음)에
   의존한다. 우리 번역기는 **파싱된 선언**에서만 심볼 맵을 만들므로, 선언이 없으면 본문의 `g_Time` 이
   원형 그대로 남아 MSL 컴파일 실패 → 스킵.
2. **non-main 함수가 통째로 드롭된다** — `extractMain` 이 main 만 추출. 효과 파일 자체에 정의된 헬퍼
   (예: pulse 의 `CreateAudioResponse`)와 common.h 헬퍼(`rotateVec2` 등) 모두 누락.

Stage 2 목표: (1) 선언 없이도 엔진 심볼을 항상 매핑, (2) 헬퍼 함수 방출 + 컨텍스트 캡처.
이로써 **효과 파일 자체에 정의된 헬퍼를 쓰는 효과는 base-assets 없이도** 번역되고, base-assets 디렉터리가
설정되면(사용자 게이트) common.h 헬퍼까지 동일 메커니즘으로 번역된다.

**의도적으로 안 하는 것**: WE 저작권 헤더(common.h)의 자체 번들/클린룸 재구현. 함수 의미를 검증할 실데이터
없이 추측 구현하면 "조용히 틀린 그림"이 된다 — 컴파일 실패→스킵(현 안전망)이 낫다. 실제 헤더는
사용자가 base-assets 폴더를 지정하면 기존 include 체인(pkg→base)이 그대로 로드한다.

주의: 이전 세션의 실측 데이터(~/Downloads/packages, 26 pkg)는 **디스크에서 삭제됨**(2026-07-02 확인).
본 단계는 합성 GLSL(TDD) + MSL 런타임 컴파일 + PNG 오라클로 검증하고, 실측 재검증은 사용자가 데이터를
다시 제공할 때 수행한다.

## 1. 엔진 심볼 상시 매핑 (gate 1 해소)

- 심볼 맵을 선언 파싱뿐 아니라 **전처리된 본문의 토큰 출현**으로도 구성:
  `g_Time`, `g_ModelViewProjectionMatrix`, `g_AudioSpectrum16Left/Right`, `g_Texture<N>Resolution`,
  (vertex) `a_Position`, `a_TexCoord`, (fragment) `gl_FragCoord → in.gl_Position`.
- `usesAudio` 도 본문 스캔으로 판정.
- `g_Texture<N>` 샘플러는 효과 파일에 항상 선언되므로 기존(선언 기반) 유지. 단, 본문에서 참조되면 선언이
  없어도 슬롯 인식(방어).
- precision 한정자(`highp/mediump/lowp`, `precision ...;` 문) 는 파싱 전에 제거.

## 2. 헬퍼 함수 방출 + 컨텍스트 캡처 (gate 2 해소)

### 파싱
- 파일 스코프 함수 정의: `<ret> <name>(<params>) { balanced-body }`, ret ∈ {void,float,int,bool,vec2..4,mat3,mat4}.
- `void main` 추출은 word-boundary 로 수정(`mainImage` 같은 이름 오매치 방지).
- 파일 스코프 `const <type> <name> = <expr>;` → MSL `constant` 전역으로 방출.

### 캡처 (핵심 설계)
MSL 파일 스코프 함수는 유니폼/varying/텍스처에 접근 불가 → **참조하는 컨텍스트 심볼을 추가 파라미터로 승격**:

- 머티리얼 파라미터 → 원래 GLSL 이름·타입의 값 파라미터 (호출부에서 `p[i].xyz` 전달)
- 엔진 유니폼 → `float g_Time`, `float4x4 g_ModelViewProjectionMatrix`, `float4 g_Texture<N>Resolution`
- varying/attribute → 값 파라미터 (호출부: fragment `in.name` / vertex `vin.name`·`out.name`)
- 텍스처 → `texture2d<float> g_TextureN` + (텍스처 캡처가 하나라도 있으면) `sampler smp` 1개
- 오디오 배열 → `constant float* g_AudioSpectrum16Left/Right`

전이 폐쇄: 헬퍼 A 가 헬퍼 B 를 호출하면 A 의 캡처셋 ⊇ B 의 캡처셋 (fixed-point).
호출부 재작성: main/헬퍼 본문의 `foo(a)` → `foo(a, <mapped captures>)`. 헬퍼 내부에서는 캡처 심볼이
파라미터로 존재하므로 원래 이름 그대로 전달.

한계(의도): vertex 가 텍스처 캡처 헬퍼를 호출하면(정점 샘플링) 컴파일 실패 → 기존 스킵 안전망. 로그로 확인.

## 3. Premultiply 규약 전환 (체인 이중-premult 버그의 근본 수정)

현재: 최종 컴포지터 f_main 은 straight 출력 + src=one 블렌드(premult-over 가정) → 알파를 이펙트가
패스 내부에서 premult 하여 보정(opacity/pulse/번역기 주입). 체인하면 이중 적용(0.7² → 0.34≠0.49).

전환: **이펙트 패스는 straight-in/straight-out, premultiply 는 최종 컴포지트에서 단 한 번**.
- QuadShaders f_main: `a = c.a*tint.a; return float4(c.rgb*tint.rgb*a, a)`.
- EffectShaders opacity/pulse: premult 제거(straight 출력) — 실제 WE GLSL 과 1:1.
- GLSLTranslator: premult 주입 제거. `gl_FragColor` 는 로컬 변수 선언 + 본문 치환 + 말미 `return`
  (다중 대입·스위즐 대입·조기 `return;` 모두 지원 — 기존 단일-대입 rewrite 의 한계 제거).
- 파티클 파이프라인은 자체 셰이더가 premult 출력 + src=one 으로 자기완결 — 불변.
- 부수 이득: 반투명 텍스처를 가진 무-이펙트 레이어의 합성도 비로소 정확해짐.
- 한 커밋으로 원자 적용(스위트 그린 유지). 오라클: 기존(0.4 단일) 유지 + 신규 체인(0.7×0.7→0.49).

## 4. 나머지 정리

- 2-인자 `atan` → `atan2`, `ddx/ddy` → `dfdx/dfdy`, `texSample2DLod` → `sample(..., level(l))`.
- 전처리기: 비정수 object-like `#define` 을 본문 텍스트 치환으로 지원(현재는 드롭 → 컴파일 실패).
- vertex 오디오: assemble 이 vertex 에도 audioL/R 파라미터 방출 + SceneRenderer 가 vertex 스테이지에 바인드.
- texRes[N]: aux 텍스처의 실제 dims 로 채움(현재 레이어 dims 근사).
- **파티클 z-순서**: SceneDocument 가 오브젝트 순서를 보존, 렌더러가 레이어·파티클을 씬 순서대로
  인터리브 드로우(현재: 파티클이 항상 최상단). PNG 오라클: fg 레이어가 파티클을 가림.

## 검증

- WapleCore 단위(TDD): 전처리기/번역기 각 기능.
- WapleRender: MSL 런타임 컴파일 테스트(합성 WE-dialect 셰이더, 헬퍼+캡처+오디오 포함),
  PNG luma 오라클(체인 0.49, 헬퍼 경유 효과, z-순서).
- 전체 스위트 + 릴리스 빌드. 실측 pkg 재검증은 사용자 데이터 제공 후(게이트 기록).
