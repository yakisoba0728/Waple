# Waple — GLSL→MSL 셰이더 변환기 (Stage 1: fragment/vertex 효과) 설계 문서

- 작성일: 2026-06-25
- 상태: 설계 확정(사용자 선택: "GLSL→MSL 변환기 Stage 1")
- 목표: WE 셰이더(GLSL 방언)를 MSL 로 변환해 **스톡 효과 전체 + 워크샵 GLSL 효과**를 렌더. 손-포팅 7종을 **정답 오라클**로 검증.
- 비-목표(이후 Stage): 3D 머티리얼/모델 셰이더, geometry shader(파티클 GS), compute, 복잡 제어흐름의 워크샵 셰이더(폴백).

---

## 0. 핵심 통찰 / 위험 관리
- WE 셰이더는 **한정된 방언**(범용 GLSL 아님): 고정 인클루드 집합 + 고정 엔진 매크로 + 고정 유니폼 규약. → 범용 컴파일러 대신 **방언 전용 소스-투-소스 변환기**로 충분.
- **무회귀 원칙**: 변환 실패/미지원 구문 → 기존 손-포팅(EffectShaders) 또는 스킵으로 폴백. 커버리지만 증가, 절대 깨지지 않음.
- **검증**: 손-포팅 7종을 원본 GLSL 에서 변환 → 렌더 → PNG 로 손-포팅 결과와 비교(오라클). + 라이브 데스크탑 PNG.

## 1. 정찰 결과 (실제 WE GLSL)
- 전처리: `// [COMBO] {"combo":"NAME","default":N,...}`(콤보 선언+기본값), `#include "common*.h"`, `#if NAME`/`#if NAME == N`/`#ifdef`/`#else`/`#elif`/`#endif`/`#define`.
- 매크로(엔진 주입, 에셋에 없음 → 변환기가 정의): `mul(v,M)`=행벡터곱(MSL: `M*v`), `CAST2/3/4(x)`=`float2/3/4(x)`, `texSample2D(t,uv)`=`t.sample(s,uv)`, `frac`=`fract`, `lerp`=`mix`, `saturate(x)`=`clamp(x,0,1)`, `M_PI`/`M_PI_HALF`/`M_PI_2` 등.
- 유니폼:
  - `uniform sampler2D g_Texture{N};` → fragment `texture2d<float> [[texture(N)]]` + 공유 sampler. g_Texture0=레이어 프레임버퍼, 이후=보조(마스크/노멀…).
  - 엔진 유니폼: `g_Time`, `g_ModelViewProjectionMatrix`(효과는 풀스크린→항등/ortho), `g_Texture{N}Resolution`(vec4: w,h,1/w,1/h or 실/패딩), `g_AudioSpectrum16Left/Right[16]`.
  - 머티리얼 파라미터: `uniform <type> g_X; // {"material":"key","default":...}` → scene.json `constantshadervalues[key]` 또는 default.
- attribute(vert): `a_Position`(vec3), `a_TexCoord`(vec2). varying: `v_*`(vert out→frag in).
- 진입: `void main()` — vert 는 `gl_Position`+varying 기록, frag 는 `gl_FragColor` 기록.

## 2. 아키텍처

### 2.1 ShaderPreprocessor (WapleCore, 순수)
- `preprocess(source:, combos:[String:Int], includes:(String)->String?) -> String`
- ① `[COMBO]` 파싱 → 기본 combo 값(명시 combos 가 우선). ② `#include` 재귀 인라인(인클루드 해석기 주입; 미발견은 빈 문자열+로그). ③ `#if/#ifdef/#ifndef/#elif/#else/#endif` 평가 + `#define`(단순). 식: `NAME`, `NAME == N`, `NAME != N`, `A && B`, `A || B`, `!A`, 괄호. 정의 안 된 토큰=0.
- 출력: 조건부 해소된 평면 GLSL.

### 2.2 GLSLTranslator (WapleCore, 순수)
- `translate(vertex:, fragment:, combos:) -> TranslatedShader?` (전처리 후 변환). 실패 시 nil(→폴백).
- 단계: 유니폼/attribute/varying 수집·분류 → stage_in/out struct 생성 → 본문 토큰 치환(타입/매크로/내장) → main() 을 `ev_main`(vertex)/`ef_main`(fragment)로 변환. `gl_Position→out.pos`, `gl_FragColor→return`, varying 읽기/쓰기→`in./out.`.
- 미지원 구문(함수 정의 다수, 배열 유니폼 외, geometry 등) 감지 시 nil 반환(폴백). Stage 1 은 효과 패턴(단일 main, 표준 attr) 중심.

### 2.3 TranslatedShader / Reflection
- `struct TranslatedShader { let msl: String; let materialParams: [MaterialParam]; let textureSlots: [Int]; let engineUniforms: Set<EngineUniform> }`
- `MaterialParam { name(GLSL), type(.float/.vec2/.vec3/.vec4), sceneKey(String), default:[Float] }` — **선언 순서 보존**(버퍼 레이아웃).
- `EngineUniform`: time, mvp, audioL, audioR, texRes(N)…
- 머티리얼 파라미터는 단일 constant 버퍼(buffer(0))에 선언 순서로 패킹(float/vec2/vec3/vec4 → 16바이트 정렬은 변환기가 std140-유사 패딩 처리, 또는 모두 float4 슬롯으로 단순화). 엔진 유니폼은 buffer(1), 오디오는 buffer(2).

### 2.4 SceneRenderer 통합 (WapleRender)
- `EffectShaders.translated(effectName, glsl…, combos, constants) -> (pipeline, bindplan)?` 경로 추가. 효과 GLSL 소스는 ① pkg(워크샵: `shaders/workshop/…`) ② 기본 에셋(스톡: `effects/<name>/shaders/effects/<name>.{vert,frag}`)에서 로드(BaseAssetsSettings).
- 빌드: 변환 성공 → 변환 파이프라인 + 머티리얼/엔진/오디오 버퍼 바인딩(reflection 기반). 실패 → 기존 손-포팅(EffectShaders dict) → 그것도 없으면 스킵+로그.
- 텍스처: reflection.textureSlots 로 보조 텍스처 해석(기존 resolveTexture). 엔진 유니폼: time/해상도/오디오 주입.

## 3. 컴포넌트 / 검증
| 컴포넌트 | 위치 | 검증 |
|---|---|---|
| ShaderPreprocessor(combo/include/#if) | WapleCore | **TDD**(조건부·식·인클루드) |
| 엔진 매크로/타입 치환 테이블 | WapleCore | **TDD** |
| GLSLTranslator(uniform/varying/main) | WapleCore | **TDD**(구조 단위) |
| Reflection 추출 | WapleCore | **TDD**(순서·키·기본값) |
| 번들된 common_*.h(인라인용) | WapleCore/리소스 | 변환 산출물이 MSL 컴파일 |
| SceneRenderer 변환 경로+폴백 | WapleRender | **MSL 컴파일** + **PNG 오라클 비교**(opacity/scroll/tint/waterwaves vs 손-포팅) + 라이브 |

## 3.5 결정 사항 (advisor 반영)
- **Premultiplied 주입(필수)**: WE frag 는 straight alpha(`gl_FragColor = albedo`) 출력. 우리 컴포지터는 premultiplied(src=one). 변환기는 frag 의 모든 출력 지점에 `c.rgb *= c.a` 를 주입(a=1 효과는 no-op, 알파 효과는 교정). 안 하면 pulse/opacity 에서 고친 버그가 전 효과에 재발.
- **파라미터 패킹 = 파라미터당 float4 1개**: `constant float4* p [[buffer(0)]]`, 변환기가 `g_X` → `p[i].x/.xy/.xyz/.xyzw`(선언 타입별)로 재작성. 혼합 float/float3 정렬 손상 클래스 제거.
- **엔진 유니폼 = 고정 struct(buffer(1))**: `mvp(float4x4)`, `time(float)`, `texRes[N](float4)`, (오디오는 buffer(2)). 변환기가 `g_ModelViewProjectionMatrix→eng.mvp`, `g_Time→eng.time`, `g_Texture{N}Resolution→eng.texRes[N]` 재작성. 효과는 MVP=항등 + a_Position=NDC 코너 → vert 통과(mul 규약은 3D 단계에서만 문제).
- **주석 먼저 추출**: `// {"material":...,"default":...}` 어노테이션을 reflection 으로 먼저 파싱한 뒤 본문에서 주석 제거(`{}":` 가 토크나이저 방해).
- **오라클 유효성**: 픽셀 일치 비교는 **opacity/scroll/tint 만**(충실한 손-포팅). shake/waterwaves/waterripple/pulse 는 손-포팅이 단순화됨 → 변환본은 더 정확하고 **다름** → 이들은 "컴파일+렌더+실씬 그럴듯" 으로 검증(픽셀 일치 기대 금지).
- **g_TextureNResolution 의미**: 추측 말고 기존 처리/실데이터로 확인. opacity 스파이크는 MASK=0(기본)이라 v_TexCoord.zw 미사용 → 해상도 무관하게 시작 가능.
- **무회귀**: translate→`makeLibrary` 실패 시 손-포팅/스킵 폴백(load-bearing, 끝까지 유지).

## 4. 단계 (Stage 1 내부) — opacity 풀-경로 스파이크 우선
- **Step 0 (스파이크)**: opacity(MASK=0) 를 **풀 경로로** — 최소 전처리(#if/#else/#endif) + 최소 변환 + reflection→버퍼 바인딩 + premult 주입 → 렌더 → 손-포팅 opacity 와 PNG 일치. **바인딩 계약을 1-유니폼 효과에서 먼저 증명.**
1. Preprocessor(콤보·인클루드·#if) — 순수 TDD.
2. 매크로/타입 치환 + 유니폼/varying 수집 + reflection — 순수 TDD.
3. main()→ev_main/ef_main 변환(가장 단순 효과 opacity 부터) — TDD + MSL 컴파일.
4. SceneRenderer 변환 경로(opacity 변환본으로 PNG 오라클 비교) + 폴백.
5. 확장: scroll→tint→waterwaves→waterripple→shake→pulse 순으로 오라클 PNG 일치. (vert 로직 있는 것 포함.)
6. 워크샵 효과 1~2종 라이브 PNG 확인. 미지원은 폴백 로그.

## 5. 에러/강등 (loudly)
- 인클루드 미발견/변환 실패/미지원 구문 → nil → 폴백(손-포팅/스킵) + `NSLog`. MSL 컴파일 실패 → 폴백. 무크래시.

## 6. 범위 밖 (이후)
- 파티클 geometry shader, 3D/모델/PBR 머티리얼 셰이더, compute, 복잡 워크샵(루프/다중함수/특이 내장), 스프라이트시트, 스크립트 바인딩(JS). std140 완전 정합(필요시 float4 슬롯 단순화로 우회).
