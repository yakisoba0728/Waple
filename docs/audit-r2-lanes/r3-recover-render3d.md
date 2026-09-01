# 보충 레인 — WapleRender 3D · 라이팅 · 포스트프로세스 (r3 복구, HEAD `b883386e`)

작업 트리 무수정. `swift build`/`swift test` 미실행. 도구: grep · `git show` · 파일 읽기 · 짝 저장소
`Waple-wallpaper-source/wallpaper_engine/assets/shaders/` 원문 대조.

기지 대조 범위: `AUDIT-FULL-2026-08-31.md` · `-r2.md` · `-r3.md` · `docs/` 전수(`docs/audit-r2-lanes/`
16레인 + `docs/sweep-2026-08-19.md` + `docs/history/` 포함) · `spec/`.

---

## 🟡 R-1 — PR #8 의 `[동기화 2026-08-31]` 목록이 `Mesh3DShaders` 를 **반만** 고쳤고, `Scene3DLighting` 2자리는 목록에도 r1 의 "전수 22자리" 센서스에도 없다

- **자리**
  - `Sources/WapleRender/Mesh3DShaders.swift:610-611` — 반만 고쳐진 자리
    ```
    610: //    씬 `general.hdr:true` 일 때 엔진이 HDR 콤보를 주입해 그 가지가 켜진다(동봉 172 + 설치본 186
    611: //    단일 모집단 186 씬 전수에서 `hdr:true` 3건). 지금은 g_Brightness(applyHDRBrightness)만 …
    ```
    → 한 문장이 "**동봉 172 + 설치본 186 단일 모집단 186 씬 전수에서**" 가 되어 자기모순이다.
  - `Sources/WapleRender/Scene3DLighting.swift:170` — `/// 실물 대조(동봉 172 + 설치본 186 씬 전수): …`
  - `Sources/WapleRender/Scene3DLighting.swift:230` — `/// 코드는 그대로 둔다: 동봉 172 + 설치본 186 씬 전수에서 `ltube` 라이트 **0건** …`
- **재현**
  ```
  git show b883386e -- Sources/WapleRender/Mesh3DShaders.swift    # 611 한 줄만 고침(2 +-), 610 그대로
  git show --stat b883386e | grep Scene3DLighting                 # 0행 — PR #8 이 이 파일을 안 건드렸다
  grep -rn "동봉 172 + 설치본 186" Sources spec docs/re docs/history README.md AGENTS.md BACKLOG.md
  #  → Mesh3DShaders.swift:610 · Scene3DLighting.swift:170 · :230
  #    (spec/schema.json:18 · docs/re/volumetric-light.md:337 은 **정정 문맥**이라 제외)
  ```
- **왜 문제인가**
  1. `HDRBloomPass.swift:66-68` 의 `**[동기화 2026-08-31]**` 이 "`HDRPostPass`·`LDRBloomPass`·
     `LDRBloomMath`·`VolumetricLightPass`·**`Mesh3DShaders`**와 `docs/re/` 도 함께 고쳤다" 고 적는데,
     `Mesh3DShaders` 는 **숫자(4→3)만** 고쳐졌고 이중계수 모집단 문자열은 남았다.
     lane06 F6-2 가 잡은 `SceneRenderer.swift:1165`(코퍼스 8)와 **같은 부류의 두 번째 자리**다.
  2. `Scene3DLighting.swift` 는 그 목록에도, `AUDIT-FULL-2026-08-31.md:1563-1575` 의 "전수 22자리"
     파일별 표에도 **없다**(표 = tonemapping.md 7 · scene-postprocessing.md 6 · HDRBloomPass 2 ·
     scene-lighting.md 2 · Volumetric/LDRBloomPass/HDRPostPass/LDRBloomMath 각 1 · spec/schema.json 1 = 22).
     **그 센서스의 선택 기준이 좁았다**는 것이 요지다 — r1 이 밝힌 기준은 `"동봉 172 + 설치본 186 **= 358**"
     **형태**였는데, 여기 세 자리는 `= 358` 없이 `"동봉 172 + 설치본 186 씬 전수"` 로만 적혀 있어
     그 grep 에 안 걸렸다. 이중계수의 **실질**은 같다(172 는 186 의 부분집합이므로 두 수를 나란히
     적는 것 자체가 잘못된 모집단 표기다). 곧 22 라는 수를 "이 부류의 전수" 로 인용하면 안 된다 —
     같은 실질이 `Sources/WapleRender/` 안에 3자리 더 살아 있다.
  3. lane06 의 clean 항목 2("`M13` … 전부 단일 모집단 186 과 정합")도 `Scene3DLighting` 을
     열거하지 않았으므로 그 clean 판정의 모집단이 좁다.
- **모집단**: 설치본(`Waple-wallpaper-source/wallpaper_engine` 의 `assets/`+`projects/`, 글롭
  `{scene,gifscene}.json`) **186**. 동봉 코퍼스(`Sources/WapleRender/Resources/WEAssets`) 172 는
  그 부분집합(사본)이라 더하면 안 된다 — 정본 `spec/engine/tonemapping.json:1256` `corpusPopulation`.
- **기지 대조**: `M13`(r1) 은 `HDRBloomPass.swift:5` 한 자리, lane06 `F6-2` 는 `SceneRenderer.swift:1165`
  한 자리다. 여기 세 자리는 두 문서 어디에도 없고 `docs/` 전수 grep 에서도 0건이다.
- **severity**: medium (정본·주석 거짓 · 낡은 수치 · "고쳤다" 주장 반증)

---

## 🟡 R-2 — `waterripple` 손포팅이 **애니메이션 속도를 제곱하지 않는다**. 같은 커밋이 그 제곱식을 주석에 적어 놓고 자매 항(strength)만 고쳤다

- **자리**: `Sources/WapleRender/EffectShaders.swift:212`
  ```
  float2 nUV = in.uv * P[2] + float2(P[0] * P[3], P[0] * P[3] * 0.5);
  ```
  `P[0]`=time · `P[2]`=`scale` · `P[3]`=`animationspeed`(`:98`, 기본 **0.15**).
  바로 위 `:93` 의 주석이 WE 원문을 이렇게 인용한다 —
  `WE vert: v_TexCoordRipple = coords + g_Time*g_AnimationSpeed² + scroll`.
- **WE 원문**: `Waple-wallpaper-source/wallpaper_engine/assets/effects/waterripple/shaders/effects/waterripple.vert:48-50`
  ```glsl
  v_TexCoordRipple.xy = coordsRotated  + g_Time * g_AnimationSpeed * g_AnimationSpeed + scroll;
  v_TexCoordRipple.zw = coordsRotated2 - g_Time * g_AnimationSpeed * g_AnimationSpeed + scroll;
  v_TexCoordRipple *= g_Scale;
  ```
  `g_AnimationSpeed` 어노테이션(`:24`) = `{"material":"animationspeed","default":0.15,"range":[0,0.5]}`.
- **수치**: WE 실효 스크롤 속도 = `t · 0.15² = 0.0225 t`. Waple = `t · 0.15 = 0.15 t`.
  → 기본값에서 **6.667배 빠르다**(0.15 / 0.0225). `range` 상한 0.5 에서도 `0.5 / 0.25 = 2배`,
  하한으로 갈수록 오차가 커진다(0.05 → 20배).
- **재현 / 이력** — 이 결함은 F-X8 커밋이 **키를 바꾸면서 3배 악화시켰다**:
  ```
  git show e1c483b3 -- Sources/WapleRender/EffectShaders.swift
  #  -let scrollSpeed = c["scrollspeed"] ?? c["speed"] ?? 0.05
  #  +let scrollSpeed = c["animationspeed"] ?? c["scrollspeed"] ?? c["speed"] ?? 0.15
  #  -float2 distort = n.xy * P[1] * maskV;
  #  +float2 distort = n.xy * (P[1] * P[1]) * maskV;      ← strength 만 제곱 적용
  #   float2 nUV = in.uv * P[2] + float2(P[0] * P[3], P[0] * P[3] * 0.5);   ← 무변경
  git log -S 'float2(P[0] * P[3], P[0] * P[3] * 0.5)' --oneline -- Sources/WapleRender/EffectShaders.swift
  #  → b88e367e (최초 구현). F-X8 은 이 줄을 건드리지 않았다.
  ```
  F-X8 이전은 `0.05 t`(2.22배), 이후가 `0.15 t`(6.67배)다 — **정정이 오차를 3배 키웠다.**
- **부수 이탈 2건**(같은 줄):
  1. `* 0.5` (y축 절반)은 WE 에 대응물이 **없다**. WE 는 xy 에 같은 스칼라를 더하고
     비등방은 `.yw *= g_Ratio`(`ratio` 키, 기본 1)로 따로 준다 — Waple 은 `ratio` 를 안 읽는다.
  2. WE 는 시간 항까지 포함해 `rippleCoords *= g_Scale` 로 **전체**에 scale 을 곱하는데
     (`:50`), Waple 은 `in.uv * P[2]` 로 uv 에만 곱한다. `scale` 기본 1 에서만 동치이고
     range 는 `[0,10]` 이다.
- **모집단·도달**: `effects/waterripple` 저작 씬 — **동봉 코퍼스 2씬 · 설치본 2씬**
  (`effects/waterripple/preview/scene.json` · `effects/reflection/preview/scene.json`,
  두 모집단에서 동일 파일). 워크샵 코퍼스(446)는 이 머신에 없어 미측정.
  경로는 **손포팅 폴백 한정**이다 — `SceneRendererResources.swift:336-348` 이 `buildTranslatedEffect`
  를 먼저 시도하고 실패할 때만 `buildHandPortEffect` 로 내려간다(M61 과 같은 도달 조건).
  실제로 돌린 재현 명령(cwd = `/Users/yakisoba0728/Documents/GitHub/Waple`):
  ```
  python3 - <<'EOP'
  import glob,os
  roots={'동봉':'Sources/WapleRender/Resources/WEAssets',
         '설치본':'/Users/yakisoba0728/Documents/GitHub/Waple-wallpaper-source/wallpaper_engine'}
  for name,root in roots.items():
      n=[p for p in glob.glob(root+'/**/*.json',recursive=True)
         if os.path.basename(p) in ('scene.json','gifscene.json')
         and 'effects/waterripple' in open(p,encoding='utf-8',errors='ignore').read()]
      print(name,len(n),[os.path.relpath(x,root) for x in sorted(n)])
  EOP
  # 동봉 2 ['effects/reflection/preview/scene.json', 'effects/waterripple/preview/scene.json']
  # 설치본 2 ['assets/effects/reflection/preview/scene.json', 'assets/effects/waterripple/preview/scene.json']
  ```
- **기지 대조**: `M61`(r3)은 `EffectShaders.swift:136` 의 **shake 진폭**이다 — 같은 계통·다른 줄·다른 이펙트.
  `docs/history/parity-sweep-2026-08-19.md:128`(G-B4-02)는 waterwaves `direction` 단위다.
  `grep -rn "waterripple" AUDIT-FULL-*.md AUDIT.md docs/ BACKLOG.md` 에 이 결함은 0건.
- **severity**: medium (실동작 — 잠복. 도달은 폴백 경로 한정이나 도달 시 6.67배)

---

## 🟡 R-3 — `waterwaves` 손포팅이 WE 에 **없는 유니폼(`perspective`)** 을 읽어 두 자리에 곱하고, 실재하는 `exponent` 는 안 읽는다

- **자리**
  - `Sources/WapleRender/EffectShaders.swift:130`
    `return [-sin(a), cos(a), f("speed", 5), f("scale", 200), f("strength", 0.1), f("perspective", 0)]`
    → `P[6] = constants["perspective"] ?? 0`
  - 같은 파일 `:169`·`:171`(MSL)
    ```
    float distance = P[0] * P[3] + dot(tc, dir) * (P[4] + P[6] * pos);
    float strength = P[5] * P[5] + P[6] * pos;
    ```
- **WE 원문**: `…/assets/effects/waterwaves/shaders/effects/waterwaves.frag:44-46,66`
  ```glsl
  float pos = abs(dot((texCoordMotion - 0.5), v_Direction));      // ← WE 안에서 한 번도 안 쓰인다
  float distance = g_Time * g_Speed + dot(texCoordMotion, v_Direction) * g_Scale;
  float strength = g_Strength * g_Strength;
  ```
  `g_Scale`·`g_Strength` 어디에도 `pos` 항이 없다. **WE 의 `pos` 는 데드 변수다**(`:44` 이후 참조 0건 —
  `grep -c "\bpos\b" waterwaves.frag` → 1).
- **`perspective` 는 WE 의 유니폼이 아니다**: WE 의 PERSPECTIVE 는 **콤보**(`waterwaves.vert:2`
  `[COMBO] {"combo":"PERSPECTIVE","default":0}`)이고, 데이터는 스칼라가 아니라 네 코너점
  `g_Point0..3`(`waterwaves.vert:26-29`)이다. `effects/waterwaves/effect.json` 의 `gizmos[0]`
  (`"type":"EffectPerspectiveUV"`, `vars: p0..p3 → point0..point3`)가 이를 확인한다.
  즉 `constants["perspective"]` 는 **WE 가 저작할 수 없는 유령 키**이고, 그 슬롯이 0 이 아닌
  값을 받으면 WE 에 존재하지 않는 두 항이 켜진다.
- **반대로 실재 키 `exponent` 는 안 읽는다**: `waterwaves.frag:18`
  `{"material":"exponent","default":1,"range":[0.51,4]}` — WE 는 `val1 = sign(sin d)·pow(|sin d|, g_Exponent)`
  (`:69-71`)로 파형을 뾰족/뭉툭하게 만든다. Waple(`:172`)은 `sin(distance)` 직접이라
  `exponent ≠ 1` 저작이 조용히 무시된다. (`DUALWAVES`·`TIMEOFFSET` 미포팅은 별개로,
  `shake` 포트처럼 "미포팅" 이라 적힌 주석이 이 이펙트에는 없다.)
- **재현**
  ```
  sed -n '2p;12p;26,29p' …/effects/waterwaves/shaders/effects/waterwaves.vert   # COMBO + g_Point0..3
  sed -n '18p;44,46p;66,71p' …/effects/waterwaves/shaders/effects/waterwaves.frag
  cat Sources/WapleRender/Resources/WEAssets/effects/waterwaves/materials/effects/waterwaves.json
  #  → passes[0] 에 constantshadervalues 자체가 없다(perspective/exponent 어느 쪽도 머티리얼 기본값 없음)
  ```
- **모집단·도달**: `effects/waterwaves` 저작 씬 — **동봉 1씬 · 설치본 1씬**(effect preview).
  두 모집단 전수에서 `perspective`/`exponent` 를 `constantshadervalues` 로 저작한 자리 **0건**
  → 기본 0 이라 두 항은 현재 항등이다(잠복). 워크샵 코퍼스는 이 머신에 없다 —
  `docs/history/parity-sweep-2026-08-19.md:128` 은 워크샵에서 waterwaves 를 **83/162 씬**
  (도달 1위)으로 적는데 그 저작 내용은 이 머신에서 확인 불가다.
- **기지 대조**: `docs/history/parity-sweep-2026-08-19.md:128`(G-B4-02)은 `direction` 단위만 다뤘고
  `EffectShaders.swift:115-128` 의 주석이 그것을 기록한다. 유령 키·`pos` 항·`exponent` 미이식은
  `AUDIT-FULL-*.md` 3종 · `docs/` 전수 grep 에 0건.
- **severity**: medium (유령 키 + WE 무대응 항 = F267/F-X8 이 정리한 부류의 미스윕 잔여. 실동작은 잠복)

---

## ⚪ R-4 — 감사 V07 `nearestSource` 의 치환 범위 주석이 **두 파일에서 서로 다르게, 둘 다 틀리게** 적혀 있다

- **자리**
  - `Sources/WapleRender/QuadShaders.swift:274-278` — "**4개 frag**(f_main/f_blend/f_compose/f_lit)의
    **유일한** 선형 샘플러 선언만 `filter::nearest` 로 치환"
  - `Sources/WapleRender/ParticleShaders.swift:163-165` — "**pf_main/pf_refract** 의 유일한 선형 샘플러 선언만"
  - `Sources/WapleRender/SceneRendererResources.swift:2235-2236` — "`ParticleShaders.nearestSource`(**pf_main 샘플러만**)"
    ← 바로 위 항목과 **서로 모순**
- **실제**: `replacingOccurrences(of:with:)` 는 전건 치환이다.
  ```
  grep -c 'constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);' \
      Sources/WapleRender/QuadShaders.swift      # 7 (선언 6 + :280 의 치환 패턴 문자열 1)
  grep -n  … Sources/WapleRender/QuadShaders.swift
  #  :30 f_main · :50 f_main_premul · :78 f_compose · :92 f_blend · :110 f_refract · :186 f_lit  → 6개
  grep -n  … Sources/WapleRender/ParticleShaders.swift
  #  :66 pf_main · :100 pf3d_fog · :135 pf_refract  → 3개
  ```
- **왜 문제인가**: 현재는 화면 무영향이다 — 소비부가 nearest 라이브러리에서 꺼내는 함수가
  `f_main`/`f_blend`/`f_compose`/`f_lit`(`SceneRenderer.swift:2088-2101`)와
  `pv_main`/`pf_main`(`SceneRendererResources.swift:2237-2242`)뿐이라 나머지 치환분은 죽어 있다.
  그러나 그 주석이 V07 의 **무회귀 근거**로 서 있고, 누군가 `libN.makeFunction("f_refract")` 를
  한 줄 추가하면 그때부터 굴절의 **배경 스냅샷(`fbTex`)과 노멀맵**까지 nearest 가 된다 —
  WE 의 NoInterpolation 은 그 텍스처의 플래그가 아니다. `f_main_premul`(DIRECTDRAW 체인 출력)도 같다.
- **기지 대조**: `O20`(r3)은 `BaseAssetsSettings` 게터/세터, `V07` 관련 발견은 세 감사·`docs/` 전수에 0건.
- **severity**: observation (문서/근거 결함 · 현 시점 화면 영향 0)

---

## ⚪ R-5 — 같은 WE 패스(`combine_hdr`)를 Waple 이 두 벌 구현하는데 **폴백 쪽만 4탭이 아니라 1탭**이다

- **자리**
  - `Sources/WapleRender/HDRBloomPyramidPass.swift:463-474` — `t = 1/source dims` 로 **±1텍셀 대각 4탭 평균**
    (주석이 "WE combine_hdr.frag: 블룸을 ±g_TexelSize 코너 4탭으로 평균해 가산한다" 라고 명시)
  - `Sources/WapleRender/HDRBloomPass.swift:345-356`(`hdrBloomCombine`) — `:352` 가 `base.rgb + bloom.sample(linearClamp, in.uv).rgb` 로 **단일 탭**
- **WE 원문**: `…/assets/shaders/combine_hdr.frag:21-25`
  ```glsl
  vec3 bloom1 = tex(g_Texture1, v_TexCoord + g_TexelSize) + tex(… - g_TexelSize)
              + tex(… + vec2(g_TexelSize.x,-g_TexelSize.y)) + tex(… + vec2(-g_TexelSize.x, g_TexelSize.y));
  bloom1 *= 0.25;
  ```
- **도달**: `HDRBloomPass` 는 **피라미드 실패 시 폴백**이다(`SceneRendererFinalizer.swift:31-70` 이
  피라미드를 먼저 시도하고 성공하면 `return true` — 같은 파일의 `HDRBloomPass.swift:203-205` 주석이
  이 사실을 스스로 적는다). 모집단: `hdr && bloom` = 설치본 186 중 **3씬**.
  화면 차는 1/8 해상도 블룸 위의 풀해상도 ±1텍셀 박스라 미세하다 — 그래서 관찰로 둔다.
- **기지 대조**: lane06 F6-3 은 **README 의 피라미드 탭 반경**이고 이 자리가 아니다
  (`lane06-3d-bloom.md:98` 이 인용한 것은 README 문장이지 `HDRBloomPass` 구현이 아니다).
  `grep -rn "combine_hdr" AUDIT-FULL-*.md AUDIT.md docs/` 전건을 확인했고 이 자리를 지목한 발견은 0건이다.
- **severity**: observation

---

## ⚪ R-6 — 볼류메트릭 레이마치가 WE 의 루프 내 `ApplyFogAlpha` 를 이식하지 않았고, 헤더의 "옮겼다/이탈" 목록에도 그 항목이 없다

- **자리**: `Sources/WapleRender/VolumetricLightPass.swift:373-387`(루프) · `:17-38`(이식 범위 헤더)
- **WE 원문**: `…/assets/shaders/volumetricsfront.frag:170-175`
  ```glsl
  #if FOG_HEIGHT || FOG_DIST
      vec3 viewDir = g_EyePosition - worldStart.xyz;
      vec2 fogPixelState = CalculateFogPixelState(length(viewDir), worldStart.y);
      shadowSample *= ApplyFogAlpha(shadowSample, fogPixelState);
  #endif
  ```
  (`FOG` 콤보 기본 1 — `volumetricsfront.frag:2`.) Waple 의 `shadowFactor += radiusFalloff * spotCookie`
  에는 이 항이 없다. 헤더 `:17-38` 의 "옮겼다 / 해석해로 대체 / 의도적 이탈" 세 목록 어디에도
  포그가 없어, 이식 범위 서술이 실제보다 넓게 읽힌다.
- **도달**: `castvolumetrics` = 설치본 186 씬 **0건** · 동봉 코퍼스 0건(문자열 자체 부재).
  워크샵 코퍼스 162 씬 중 3씬/라이트 4개(`spec/corpus/scene-schema.json` 인용, 이 머신에서 재현 불가).
  그 3씬이 씬 포그를 저작했는지는 측정 불가 → **관찰**.
- **기지 대조**: `grep -rn "ApplyFogAlpha" AUDIT-FULL-*.md AUDIT.md docs/` → **0행**
  (`docs/re/volumetric-light.md` 포함 전수).
- **severity**: observation

---

## 확인했지만 **문제없던** 것 (다음 라운드 시간 절약 — 전부 WE 원문 대조로 닫았다)

1. **lane06 의 "의심" 항목(clean 10, 포인트 섀도 아틀라스 인덱싱)은 WE 와 정확히 일치한다 — 닫아도 된다.**
   `Mesh3DShaders.swift:355-369`(`pointShadowFace`/`pointShadowCell`)의 6면→2×3 셀 사상이
   `common_pbr_2.h:167-235` `CalculateProjectedCoordsPoint` 의 `viewportOffset` 분기와 **행 대 행 동일**하다
   (+X→(0,0) · −X→(1,0) · +Y→(0,1) · −Y→(1,1) · +Z→(0,2) · −Z→(1,2), 지배축 판정도 `>=` 까지 같다).
   `lightDelta = worldPos − lightOrigin` 방향도 같고(`:151` vs `Mesh3DShaders.swift:467`),
   `0.49` 는 WE 의 `viewportPointCompensation` **QUALITY 4 가지**(`:160`)와 일치한다.
   CPU 쪽 `PointShadowMath.atlasCell`(`Scene3DLighting.swift:515-521`)과 뷰포트 배치
   (`SceneRenderer3D.swift:1542-1552`)도 같은 표를 쓴다.
2. **9탭 PCF 커널은 WE 와 탭 순서까지 동일하다.** `Mesh3DShaders.swift:449-457`·`:498-506` vs
   `common_pbr_2.h:79-90`(`roundOffset = offsets*0.81616`, `offsets *= 1.02323`, 9탭 `/9.0`).
3. **LDR 블룸 3패스는 WE 와 수식·가중·스트라이드가 전건 일치.** `LDRBloomPass.swift:230-289` vs
   `downsample_quarter_bloom.frag:10-26`(4탭 평균 → `saturate(max−T)` → `2c − gray` → `max(0, c·strength·tint)`) ·
   `blur_h_bloom.frag:7-19`/`downsample_eighth_blur_v.frag:7-19`(13탭 7가중, 합 0.999998).
   축 배정도 맞다 — WE 는 이름이 뒤집혀 있고(`blur_h_bloom.vert:12` 가 **y**, `downsample_eighth_blur_v.vert:12`
   가 **x**), `LDRBloomPass.swift:42-43` 의 표가 그것을 정확히 반영한다.
4. **HDR 피라미드의 bicubic 업샘플은 `hdr_downsample.frag:8-51` 축자 이식이다.**
   `HDRBloomPyramidPass.swift:353-387`(`weCubicWeights`/`weBicubic`)의 `c`·`s`·`offset`·4샘플 좌표·
   `mix(mix(s3,s2,sx), mix(s1,s0,sx), sy)` 가 원문과 한 항씩 대응한다.
5. **`BlendMSL.applyBlending` 32모드는 `common_blending.h:106-271` 과 전건 일치.**
   경계 규약(`select(a,b,c)` = `c ? b : a` ⇔ WE `blend < 0.5 ? a : b`), `we_overlay` 가 **base** 로 분기하는
   것, 5/10/31 의 opacity 미적용, 30 `BlendTint`, 26~29 의 HSL 인자 순서까지 확인했다.
   `RGBToHSL`/`HSLToRGB`(`:9-88`)도 1:1(WE 의 `else if (color.b == fmax)` 는 fmax 정의상 bare `else` 와 동치).
   D3(범위 가드)와 D1(GGX 1e-4)은 정본에 등재된 의도적 이탈이라 손대지 않았다.
6. **`ParticleShaders` 의 크로스페이드·포그·굴절은 `genericparticle.frag` 와 일치.**
   `pf_main` 의 `v_Color * mix(t0, t1, blend)`(WE `:75-77`), overbright 곱 위치(WE `:119`, 포그 **직전**),
   `pf3d_fog` 의 HEIGHT→DIST 순서와 `ApplyFogAlpha`(`common_fog.h:24-55`), `pf_refract` 의
   `color.rgb *= framebuffer.rgb`(WE `:116`) 순서 전부 맞다.
7. **`scroll` 이펙트는 WE 와 완전 일치.** `EffectShaders.swift:107-113`+`:223` vs
   `scroll.vert:18-20`(`sign(s)·s²·time`) · `scroll.frag:10`(`frac((uv + scroll) * repeat)`) — 곱 순서까지 같다.
8. **`QuadShaders.f_lit` 의 2D PBR 은 `common_pbr_2.h ComputePBRLightShadow` 포트로 정확하다.**
   `finiteLightFalloff`(HLSL lane `pow(falloff + 1.17549435e-38, exponent)`, `common_pbr_2.h:266`),
   spot 콘 `smoothstep(cosOuter, cosInner, ·)`(`generic3.frag:143-144` 규약과 동형), tube 의
   `PointSegmentDelta`(`common_pbr.h:9-16`), 분모 `max(4·max(N·V,0)·NL, 0.001)` 전부 원문과 같다.
9. **lane06 clean 7 의 "`tan(fov·π/360)` 은 NaN 을 못 받는다" 는 참이다.**
   `TextScriptEngine.evaluateVec`(`:998`)이 `result.allSatisfy({ $0.isFinite })` 로 비유한 결과를
   **버리고** nil 을 반환하므로 스크립트 경로로 NaN 이 `cameraFrame.fov` 에 실릴 수 없다
   (`SceneRenderer3D.swift:706-725`). M39 가 지목한 것은 NaN 이 아니라 범위이고, 그것은 유효하다.
10. **볼류메트릭 레이마치 본체는 `volumetricsfront.frag` 와 일치**(포그 제외, R-6).
    `worldStep = 구간/(N+1)`(`:113`) · `maxLightScale = intensity·|구간|/hull·(point면 ×0.5)`(`:115-122`) ·
    `pow(saturate(1 − d/hull), exponent)`(`:132`) · `smoothstep(OUTER, INNER, dot(normalize(delta), forward))`
    (`:139-140`) · `/= sampleCount`(`:187`) · `density·maxLightScale·shadowFactor·color·0.1`(`:190`) ·
    `a=1`(`:191`) · 샘플 수 8(QUALITY 4, 무섀도우 — `:88-96`) 전건 대조했다.
