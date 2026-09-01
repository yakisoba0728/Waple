# 레인 4 — GLSL → MSL 트랜스파일러 · 전처리기 (2026-08-31 r2)

대상 HEAD `b883386e`(PR #8). 읽기 전용 · `swift build`/`test` 미실행.
담당: `GLSLTranslator.swift` `GLSLTypeAdapter.swift` `ShaderPreprocessor.swift`
`BuiltinShaderIncludes.swift` `EffectManifest.swift` / `EffectShaders.swift` `BlendMSL.swift` `QuadShaders.swift`

**실동작 파손(🔴/🟠)은 0건이다.** 발견 7건은 전부 🟡(정본·주석 거짓 / 근거 추적 불능) + ⚪ 관찰 1건.
그중 F1~F4 는 **PR #8 이 이번 커밋에서 새로 심은 것**, F5 는 **M16 을 반만 고친 잔여**다.
**우선순위 ①(PR #8 의 회귀) 결과: 코드 회귀 0건** — `g_ParallaxPosition` 재배선 · 탭 접기(H1/H2) ·
`we_cast3x3` · EngineU `parallaxAndPad` · QuadShaders `projectiveDepth` 전부 실물·배선 대조로 정합 확인.
썩은 것은 **주석과 정본**뿐이다.

---

### [🟡] F1 — PR #8 의 새 주석 3곳이 **자기 커밋의 pre-image 줄번호**를 인용한다(정확히 +8 밀림)

- 자리: `Sources/WapleCore/GLSLTranslator.swift:1527`, `:1529`, `:1717`
  - `:1527` … "**타입은 vec3 다**(아래 engineReplacement **:1646**)"
  - `:1529` … "G-A2/A4/B2 블록(**:1640-1645**)이 바로 그 float4 주입이 …"
  - `:1717` … "산 경로의 근거는 **:1638-1645**(`engineReplacement`)에 있다."
- 근거/재현:
  ```
  git show b883386e^:Sources/WapleCore/GLSLTranslator.swift | grep -n 'g_LightAmbientColor" { return "float3'
    → 1646            # pre-image
  grep -n 'g_LightAmbientColor" { return "float3' Sources/WapleCore/GLSLTranslator.swift
    → 1654            # HEAD  (+8)
  git show b883386e^:… | grep -n '// G-A2/A4/B2: \*\*타입은 vec3'  → 1641
  grep -n         '// G-A2/A4/B2: \*\*타입은 vec3' …               → 1649  (+8)
  ```
  `git show b883386e -- …/GLSLTranslator.swift` 의 첫 hunk 가 1줄을 9줄로 바꿨다(**+8**) —
  그 hunk 바로 아래의 모든 인용이 정확히 그 8만큼 밀렸다.
- 왜 문제인가: HEAD 의 `:1638-1646` 은 **g_TexelSize / X-⑤ `targetRes`** 논의다. 인용을 따라간 사람은
  `g_LightAmbientColor` 근거가 아니라 **다른 유니폼의 블록**에 도착한다. 같은 커밋이 고친 H4 의
  "같은 사실을 두 자리에 적어 한쪽만 고쳤던 자리다" 라는 진단이 그대로 재현됐다.
  같은 주석의 `:1513`(isEngine) · `:323-335` · `:333` 은 삽입 지점 **위**라 정확하다 — 즉 판단이 아니라 빠뜨림.
- 기지 목록 대조: **M10 의 재발**(단, 직전 감사가 지적한 자리가 아니라 PR #8 이 새로 심은 자리).

---

### [🟡] F2 — 같은 패턴이 `ShaderPreprocessor.swift` 의 새 H2 주석에도 있다

- 자리: `Sources/WapleCore/ShaderPreprocessor.swift:638`, `:647`
  - `:638` … "위 **:261** 의 탭 접기(H1)로는 닫히지 않는다"
  - `:647` … "고치는 이유는 `#define`(**:401** 의 nameEnd 가 `\t` 포함)·`#require` 와의 일관성이다"
- 근거/재현:
  ```
  git show b883386e^:Sources/WapleCore/ShaderPreprocessor.swift | grep -n 'if t.dropFirst().first == " "'   → 261
  grep -n 'let rest = t.dropFirst().drop' Sources/WapleCore/ShaderPreprocessor.swift                        → 279
  git show b883386e^:… | grep -n 'let nameEnd = decl.firstIndex'   → 398   (인용은 401 — pre-image 기준으로도 3 밀림)
  grep -n 'let nameEnd = decl.firstIndex' …                        → 428
  ```
- 왜 문제인가: H2 주석 자체가 PR #8 이 새로 쓴 것인데, 그 안에서 **같은 커밋이 옮긴 코드**를 옮기기 전
  번호로 가리킨다. `:261` 은 지금 빈 `//` 줄이다.
- 기지 목록 대조: M10 재발.

---

### [🟡] F3 — "줄 번호 인용을 심볼명으로 바꿨다"는 PR #8 의 주장이 **3곳만** 적용됐다(스크립트·정본 잔여 ~20건)

- 자리: `scripts/spec/measure_workshop_shaders.py`(PR #8 이 +723/−102 로 재작성) 과
  `spec/corpus/workshop-shaders.json`
- 근거/재현: PR #8 diff 의 evidence note 3건이 "줄 번호 인용도 드리프트해 심볼명으로 바꿨다" 라고 적는다
  (`git show b883386e -- spec/corpus/workshop-shaders.json`). 그런데 같은 커밋이 새로 쓴 본문 주석이
  **pre-image 번호를 그대로** 들고 있다:

  | 인용 위치 | 인용값 | pre-image | HEAD 실제 |
  | --- | --- | --- | --- |
  | py:83 `two` 집합 | `ShaderPreprocessor.swift:914` | 914 ✓ | **961** |
  | py:83 단일 연산자 | `:922` | 922 ✓ | **969** |
  | py:88 `"uUfFlL"` | `:891` | 895 | **942** |
  | py:101 asciiDigit | `Swift:869-872` | 866-869 | **916-919** |
  | py:112 weNumericLiteral | `:865-897` | 865-895 ✓ | **912-945** |
  | py:160 tokenize | `:903-940` | 907-… | **955-987** |
  | py:224 evalChecked | `:702-853` | 703-… | **750-905** |
  | py:79 ExprEval 포트 | `:483-609` | (enum 683) | **enum 730** |

  정본 JSON 에 남은 것(생성기가 굽는다):
  `GLSLTranslator.swift:1178-1216`(isEngine → 실제 **1513**) · `:1289-1312`(engineNeutralDefault → **1719**) ·
  `:474-486`(mslType → **682**) · `:7-20`(GLSLType.from → **19-30**) · `:1061-1120`/`:1070,1096,1116`
  (parseUniforms/Varyings/Attributes → **1369+**) · `:365`(헬퍼 스킵 → **554**) ·
  `:248-249`("한 스테이지만 거부돼도 translate 는 nil" → 실제 nil 반환은 **:417**, 248-249 는 예약어 리네임 표) ·
  `ShaderPreprocessor.swift:113`(`#include` 인식 → **185**) · `:120-122`(미발견 경고 → **195**).
  재현: `grep -n "ShaderPreprocessor.swift:[0-9]\|GLSLTranslator.swift:[0-9]" scripts/spec/measure_workshop_shaders.py`
  + 위 표의 `grep -n` 앵커.
- 왜 문제인가: `workshop-shaders.json` 은 `status:"확정"` 정본이고 그 `failureMode`/`evidence` 가 코드를
  **줄로** 가리킨다. 지금 그 줄들은 전혀 다른 코드다 — 정본을 근거로 쓰는 다음 사람이 오독한다.
  게이트는 안 깨진다(`harvest_swift_operator_sets`(py:1187)는 **정규식** 수확이라 셀프테스트는 정상).
- 기지 목록 대조: M21(다른 스크립트) 동형 · M10 재발 · **PR #8 이 닫았다고 적은 항목의 부분 수정**.

---

### [🟡] F4 — PR #8 의 새 CAST3X3 주석 "행렬 인자는 위 두 오버로드가 받고" 가 **행렬 75건 중 48건에서 거짓**

- 자리: `Sources/WapleCore/GLSLTranslator.swift:2246-2247`(주석) · `:2270-2271`(`we_cast3x3` 오버로드)
- 근거/재현:
  - 도수는 주석대로다(전수 재현 완료):
    `grep -roh -E 'CAST3X3\([^)]*\)' Sources/WapleRender/Resources/WEAssets | sort | uniq -c`
    → g_ModelMatrix 14 · g_Bones 48(10×4 + 2×4) · g_ViewProjectionMatrix 5 · g_ModelMatrixInverse 3 ·
      g_EffectTextureProjectionMatrixInverse 1 · 스칼라 0. 형제 `projects/` → g_ModelMatrix 4 · `CAST3X3(1.0)` 1.
  - 그러나 `g_Bones` 의 선언 타입은 **`mat4x3`** 이다:
    `grep -rn "uniform mat4x3 g_Bones" Sources/WapleRender/Resources/WEAssets/shaders` → 9 파일
    (`base/model_vertex_v1.h:10`, `generic3/4.vert`, `genericimage2/3/4.vert`, `shadowcaster.vert`,
     `clippingmaskimage4.vert`, `passthroughblend.vert`).
    → `GLSLType.mat4x3` → MSL `float4x3`. `we_cast3x3` 오버로드는 `float4x4`/`float3x3`/`float` **셋뿐**이다.
- 왜 문제인가(두 층):
  1. 주석이 "미처리는 스칼라 1건뿐" 이라고 선언하는데, 실제로는 **가장 큰 모집단(중복제거 행렬 75건 중 48건)**
     도 오버로드가 없다(주석 자신의 중복제거 집계 `g_ModelMatrix 18 · g_Bones 48 · 5 · 3 · 1` 기준).
  2. 더 나쁜 잠복: `g_Bones` 는 `isEngine` 이 아니라 **머티리얼 파라미터**로 강등되고 `mat4x3.swizzle == ""`
     이라 `g_Bones[i]` 가 `p[n][i]` 로 방출된다 — `constant float4*` 의 성분, 즉 **`float`** 다. 그러면
     `we_cast3x3(float)` 스칼라 오버로드가 잡혀 **컴파일에 성공하면서 뼈 가중치를 대각행렬로 쓴다**
     (라우드 폴백이 아니라 조용한 오역).
  - **오늘 도달은 0**이다: 소비 `.vert` 가 전부 `a_BlendIndices` 를 참조하는데 그 이름이
    `vertexAttributeWhitelist`(:104-108)에 없어 `VIn` 미존재 멤버 → MSL 컴파일 실패 → 스톡 폴백.
    화이트리스트가 넓어지는 날 이 조용한 경로가 열린다.
- 기지 목록 대조: M12(`g_Bones 40 vs 48`)는 PR #8 이 **48 로 올바르게 정정**했다(위 전수로 확인). 이건 별건.

---

### [🟡] F5 — 정본이 "베이스에셋 미설정 = `withoutBaseAssets`" 라고 적지만 앱은 그 팩을 **동봉**한다 (정본 자기모순)

- 자리: `spec/corpus/workshop-shaders.json` → `workshop.shaders.includeResolution`
  (`resolverOrder`, `note`) 및 `workshop.shaders.translationRiskSummary`
- 근거/재현:
  - 정본 문면: `"베이스에셋(WE 설치본 assets/)은 사용자가 설정하거나 ~/Downloads/{wallpaper_dev/,}assets
    자동탐지로만 붙는다(BaseAssetsSettings.swift:17-46). 미설정 = withoutBaseAssets 열"`,
    `resolverOrder: "pkg shaders/<h> → pkg <h> → 베이스에셋 → BuiltinShaderIncludes"`.
  - 코드: `Package.swift:34 resources: [.copy("Resources/WEAssets")]` ·
    `ls -l Sources/WapleRender/Resources/WEAssets/shaders/common.h` → **945 B 존재** ·
    `BaseAssetsSettings.bundledAssetsDirectory`(:60-83) · `searchRoots`(:91-99, 사용자 → **동봉본**) ·
    `SceneRenderer.resolvedAssetBaseRoots()`(:1581) → `assetBaseRoots`(:1876) 가 `#include` 해석 루트 ·
    `scripts/package-app.sh:45` 가 복사하고 `:109-110` 이 `WEAssets/shaders/common.h` 부재를 **빌드 실패**로 만든다.
  - 그리고 **같은 산출물 안에서 모순**한다: 생성기 `scripts/spec/measure_workshop_shaders.py:43`
    `BASE_ASSETS = Sources/WapleRender/Resources/WEAssets` · `:2016` evidence 문구 "번들 베이스에셋 14헤더".
    즉 `withBaseAssets` 열은 **동봉본으로 잰 값**인데 note 는 그 열을 "설정해야 닿는다" 고 설명한다.
- 왜 문제인가: 헤드라인 리스크 수치 `silentIncludeDropWithoutBaseAssets 1550` ·
  `filesNeedingDroppedHeaderSymbolsWithoutBaseAssets 1385` · `brokenByBuiltinBlendingGapWithoutBaseAssets 43`
  와 결론 "위험은 전부 ②(조용한 인클루드 드롭)에 있다" 가 **어떤 빌드도 도달하지 않는 구성**을 서술한다
  (dev·test 는 `.build/**/Waple_WapleRender.bundle/**/WEAssets`, 배포본은 `Contents/Resources/WEAssets`).
  트랜스파일러 위험이 과대표시되고, 반대로 진짜로 확인이 필요한 것(F7)은 가려진다.
- 기지 목록 대조: M16(`measure_workshop_shaders.py` 자기모순)의 **미해결 잔여** — PR #8 은 portFidelity·
  히스토그램·evidence note 의 모순을 고쳤지만 이 모순은 남겼다.

---

### [🟡] F6 — `BuiltinShaderIncludes` 가 `common.h` 를 안 넣는 **이유가 사실이 아니다**

- 자리: `Sources/WapleCore/BuiltinShaderIncludes.swift:3-5`
  > "common.h 는 의도적으로 제공하지 않는다: 헬퍼(rotateVec2 등) 의미를 **검증할 실물 없이** 추측 구현하면
  > '조용히 틀린 그림'이 된다"
- 근거/재현: 실물이 트리 안에 있다 —
  `cat Sources/WapleRender/Resources/WEAssets/shaders/common.h`(37줄: `M_PI`/`M_PI_HALF`/`M_PI_2`/
  `SQRT_2`/`SQRT_3` + `hsv2rgb`/`rgb2hsv`/`rotateVec2`/`greyscale`) — 형제 저장소
  `wallpaper_engine/assets/shaders/common.h` 와 동일.
- 왜 문제인가: 그 헤더는 워크샵 코퍼스에서 **1,101 파일**(`includeDirectives`)이 include 하는 최대 의존이다.
  "근거가 없어서 안 한다" 는 서술은 지금 거짓이고(진짜 이유는 재배포 권리 — `release.yml:104-116`
  `WAPLE_WE_ASSETS_DISTRIBUTION_APPROVED` 게이트), 다음 사람이 "근거를 만들어야 한다" 는 잘못된 선행 작업을 잡는다.
- 기지 목록 대조: 해당 없음.

---

### [🟡] F7 — README 의 "~99.9% 컴파일" 은 트리 안에 근거가 없다

- 자리: `README.md:37`
- 근거/재현: `git log -S"99.9" -- README.md` → `76354e07`(**2026-07-06**) 최초 도입, 이후 무갱신.
  `grep -rn "99\.9" --include='*.py' --include='*.md' --include='*.json' --include='*.swift' .` →
  README 외에 셰이더 컴파일률을 내는 자리 **0건**. 트리의 유일한 셰이더 코퍼스 정본
  (`spec/corpus/workshop-shaders.json`)은 pairs·거부수·include 드롭만 내고 **컴파일 성공률을 내지 않는다**.
  브리핑 기반 실측대로 "measured local corpus"(`~/Downloads/wallpaper_dev/backgrounds`)는 이 머신에 없다.
- 왜 문제인가: 7주 반 사이에 번역기가 크게 바뀌었는데(G2·BK·H1~H4·타입어댑터) 그 수치는 2026-07-06 판본의
  것이고 재측정 경로가 트리에 없다. 공개 README 의 정량 주장이 재현 불가다.
- 기지 목록 대조: M5 는 README 의 **셰이더 인용 범위 이탈** — 이 문장은 별건.

---

## 의심 (확인 못 함 — 발견으로 올리지 않는다)

### ~~S1 — `g_ParallaxPosition` 의 정지값~~ → **닫힘. PR #8 의 배선이 옳다** (아래 "문제없던 것" 11 참조)

### S2 — 주석의 shim 인용 과장 (⚪)
`GLSLTranslator.swift:1813`·`:696` 의 "WE shim :44 `#define uvec4 uint4`(**ivec/2/3성분 〃**)" —
`analysis/strings/shader-strings.txt` 에 `uvec4` 한 줄뿐이고 `ivec*`/`uvec2`/`uvec3` 은 **0건**
(`grep -n "uvec\|ivec" analysis/strings/shader-strings.txt` → :44 한 줄). 우리 목록은 상위집합이고
무해하지만, 인용은 "실물도 그렇다"로 읽힌다.

---

## 확인했지만 문제없던 것 (다음 라운드 시간 절약용)

1. **WE 원문 줄번호 인용 25건 표본 → 25/25 정확**(`common_fragment.h:2` · `common_pbr_2.h:75,80-83` ·
   `common_blending.h:106,114,115,119` · `common_particles.h:54-58,88` · `common_pbr.h:9-16` ·
   `generic3.frag:83` · `genericimage3.frag:88` · `fur4.frag:23,152` · `refract.frag:8` · `ccsimple.frag:9,32,35` ·
   sampler2DComparison 8 · gl_VertexID 3 · gl_ViewportIndex 3 · `shadowcaster.vert:56` · clip() 3 ·
   `fluidsimulation_combine.frag:117` · `generic4.vert:9` · `depthparallax.vert:44` · 형제 `particle.vert:98,123`).
   **밀리는 것은 오직 자기 리포 안쪽 줄번호다**(F1~F3) — 외부 인용은 다시 훑을 필요 없다.
2. **모집단 도수 전건 재현**: effect.json 동봉 128 / 설치본 135(합 263) · 셰이더 502 / 502 / 형제 90 ·
   CAST3X3 도수 14·48·5·3·1·0 + 4·1 (M12 의 "40 vs 48" 은 PR #8 이 **48 로 옳게** 정정).
3. **"조용한 오역" 표적 전건 정합**: `M_PI_2=2π`(common.h:4) · `mod`→`we_mod` 가 shim `:50` 과 문자 동일 ·
   float `%`→`fmod`(HLSL) · `atan(y,x)`→`atan2` · `#if defined()` 지원 · `#define mix lerp`(:49) ↔ `lerp`→`mix` ·
   CRLF 정규화 · 함수형 매크로 중복 파라미터 `uniquingKeysWith` · `#include` 순환 = 이름 기준 include-once ·
   HLSL 암묵 절단 = `coerce`(작은 쪽)+`we_uv` · `mul(a,b)`→`(b*a)` · varying `mat3` 열 벡터 분해.
4. **WE shim 8종 대조 완료**(`shader-strings.txt:51-58`) — "CAST2X2/CAST4X4 는 로컬 추가" 주장 확인.
5. **`BuiltinShaderIncludes.commonBlending` 전 모드 ↔ 실물 `common_blending.h` 식 단위 일치**
   (HardLight=Overlay(B,A) · Glow=Reflect(B,A) · Hue/Sat/Color/Luminosity 피연산자 순서 · 5/10/31 opacity 무시).
6. **EngineU 레이아웃 동기**: MSL `struct EngineU`(:2222) 84 float/336 B ↔ `engineUniform`(:44-73)
   `16+8+32+8+8+4+4+4`, `e[80..81]=parallaxPosition`. `SpikeOpacityTranslatedTests:66` 과도 일치.
7. **QuadShaders 새 `buffer(5)` 배선 완전**: `v_main` 파생 파이프라인 전부의 draw 사이트
   (`SceneRendererFrameEncoder.swift:1835, 1949, 2184, 2200`)가 `index: 5` 를 바인딩. `nearestSource` 는
   `source` 치환 파생이라 시그니처 자동 상속 — 미바인딩 경로 0.
8. **H1/H2 탭 접기 회귀 없음**: `#if(`(sep 빈값으로 미진입) · `#endif//`/`#else //`(주석 절단 선행) ·
   `# if`(종전 경로) · `#require\t`(접기 선행) 전부 종전 동작. `engineDirectives` 순서상 접두 오매치도 없다.
9. **`--selftest` 는 살아 있다**: `harvest_swift_operator_sets`(py:1187)가 **정규식** 수확이라 F3 의
   줄번호 드리프트가 게이트를 죽이지 않는다. `we_inverse(float3x3)` adjugate/transpose/det 가드도 정확.
10. **README 외의 트랜스파일러 정량 주장은 재현됨** — 재현 불가는 F7 의 "99.9%" 하나뿐이다.
11. **[S1 닫힘] `g_ParallaxPosition` 정지값 (0,0) 은 실물과 일치 — PR #8 의 배선이 옳다.**
    renderState 생성자 디컴파일
    `Waple-wallpaper-source/analysis/decompiled/all/000000014017c6d0__FUN_14017c6d0.c:41-44` 가
    `+0x8c` · `+0x94` · **`+0x9c`** 세 qword 와 `+0xa4` dword 를 전부 0 으로 심는다 —
    즉 `g_ParallaxPosition`(= `renderState+0x9c/+0xa0`)의 실물 초기값이 `(0,0)` 이다. 갱신 블록의 게이트가
    `cameraparallax`(bit8) 하나뿐이므로(`docs/re/camera-parallax-binary-2026-08-31.md` §1 표) WE 도
    미저작 씬에서 `(0,0)` 을 유지한다. Waple `SceneRenderer.parallaxPosition` 기본 `.zero` +
    `advanceCameraParallax`(:1314) `guard parallaxEnabled` 가 이와 **정확히 같은 결말**이다.
    (`SceneGeometry.parallaxUniform`(:166) 주석의 "무저작 2D 씬 = (0.5,0.5)" 는 **parallax 가 켜진**
    씬의 focus 산출 결과를 말하는 것이라 모순이 아니다.) 재현:
    `grep -n "0x9c" …/000000014017c6d0__FUN_14017c6d0.c`
