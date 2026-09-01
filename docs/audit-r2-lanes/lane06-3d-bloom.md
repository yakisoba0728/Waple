# 레인 6 — 3D · 라이팅 · 블룸/HDR (2026-08-31 r2, HEAD `b883386e`)

작업 트리 무수정. `swift build`/`swift test` 미실행. 도구: `git show` · grep · python3(pefile/capstone,
읽기 전용 디스어셈) · 짝 저장소 `Waple-wallpaper-source` 직접 읽기.

---

## 🟠 F6-1 — WE 는 라이트 forward 로 모델행렬 **열 0**(로컬 +X)을 쓴다. Waple 은 **열 2**(+Z)를 쓴다

- 자리(Waple): `Sources/WapleRender/Scene3DLighting.swift:355-357`
  ```swift
  let forward = normalizedOr(
      SIMD3(worldMatrix.columns.2.x, worldMatrix.columns.2.y, worldMatrix.columns.2.z),
      SIMD3(0, 0, 1))
  ```
  소비: `Sources/WapleRender/Mesh3DShaders.swift:297`(directional `L = normalizedOr(-light.axis.xyz, …)`) ·
  `:314`(spot `dot(normalizedOr(light.axis.xyz, …), -L)`).
- 자리(WE): `wallpaper64.exe` V1 PBR 패커 `FUN_140190c80`
  - `0x14019d3e0` = **glm `column(mat4, index)`**. 어서션 문자열 두 개가 함수 정체를 못박는다:
    `0x1404869d0` = `D:\dev\we\windows\src\lib\include\glm\gtc\matrix_access.inl`(UTF-16LE),
    `0x140486980` = `index >= 0 && index < m.length()`, 뒤이어 `0x140477e70` =
    `…\glm\detail\type_mat4x4.inl` / `0x140477da0` = `(i) >= 0 && (i) < (this->length())`.
    본문은 `movups xmm0, [rsi + rax*8]`(rax = 2·index) = **`m[index]`, 16바이트 연속** →
    `row()` 가 아니라 `column()` 이고 저장은 열우선이다.
  - **spot**: `0x140192dfa mov r8d, 3` → `column(M,3)` = 월드 원점 → `g_LSpot_Origin[i].xyz`(store `0x140192e55`).
    `0x140192e79 xor r8d, r8d` → `column(M,0)` **무부호변경** → `g_LSpot_Direction[i].xyz`(store `0x140192e9e`).
  - **directional**: `0x140191162 xor r8d, r8d` → `column(M,0)`(call `0x1401911a6`, rcx=`[rbp+0xae0]`, rdx=r15).
    이어 `0x14005f5a0`(= `vec4(s)` 브로드캐스트 ctor: `shufps xmm1,xmm1,0; movups [rcx],xmm1`)로
    스칼라 xmm9 를 벡터화한 뒤 `0x1401911db`–`0x1401911ea` 의 4× `subss` 로 `vec4(s) − column0` 을 만들고
    `0x140191208`/`0x140191215` 가 그것을 `g_LDirectional_Direction[i].xyz` 에 싣는다(`.w=0` @`0x140191224`).
    xmm9 는 루프 진입 전 `0x140191095 xorps xmm9,xmm9` 로 0 이다 — **처음 처리되는 라이트에서는
    `s=0` 이 증명되고**, 따라서 `g_LDirectional_Direction = −column0`. (`0x140193178` 에도 재-제로가
    있으나 그것은 point 분기 fall-through 경로만 확인했다. 다만 **열 인덱스 결론은 xmm9 와 무관하다** —
    `xor r8d, r8d` 하나로 확정된다. 부호는 아래 spot(+col0)/셰이더 규약 대조가 독립적으로 뒷받침한다.)
  - 셰이더 쪽 규약이 이를 확증한다: `wallpaper_engine/assets/shaders/generic3.frag:101`
    `spotCookie = -dot(normalize(lightDelta), g_LSpot_Direction[l].xyz)` (= `dot(광원→표면, Direction)`)
    → `Direction` = 광자 진행 forward. `common_pbr_2.h:317` `ComputePBRLightShadowInfinite(N, L, …)` 의
    `L` 은 `generic3.frag:118/160` 에서 `g_LDirectional_Direction[l].xyz` 를 **정규화 없이 그대로** 받는다
    (= 표면→광원). 곧 WE 안에서 forward=`+col0`, `L = −forward = −col0` 로 일관된다.
- 재현:
  ```
  cd Waple-wallpaper-source
  python3 <capstone 스크립트> 0x140191114 0x1a0     # directional: xor r8d,r8d → call 0x14019d3e0
  python3 <capstone 스크립트> 0x140192dc0 0x100     # spot: mov r8d,3(origin) / xor r8d,r8d(direction)
  python3 <capstone 스크립트> 0x14019d3e0 0x90      # glm::column 본문
  # 어서션 문자열: VA 0x140486980 / 0x1404869d0 을 UTF-16LE 로 디코드
  grep -n "g_LSpot_Direction" wallpaper_engine/assets/shaders/generic3.frag
  ```
  두 바이너리(`wallpaper64.exe` / `wallpaper64_rich.exe`)는 인용 VA 네 곳에서 바이트 동일 —
  `analysis/decompiled`(rich) 의 함수 경계와 VA 인용이 서로 유효하다.
- 왜 문제인가: Waple 은 `angles` 가 0 이 아닌 **모든 `lspot`/`ldirectional`** 의 광축을 90° 어긋난 축에서
  뽑는다. `angles=(0,0,0)` 라이트만 봐도 WE 는 `L=(-1,0,0)`(빛이 +X 에서 온다), Waple 은 `L=(0,0,-1)`.
  스팟 콘의 방향, directional 의 명암 경계, directional CSM 광원공간 basis 가 전부 같이 틀어진다.
  도달: `docs/re/scene-lighting.md:750` 워크샵 코퍼스 `ldirectional` 5 · `lspot` 5.
- 부호 규약 자체는 **Waple 안에서 정확히 되돌려진다**(넣을 때 `+forward`, directional 에서 `-axis`,
  spot 에서 `dot(axis, -L)`) — 틀린 것은 **열 인덱스 하나**다. `Scene3DLighting.swift:353` 의
  `let position = worldMatrix.columns.3…` 은 WE `column(M,3)` 과 일치하므로 열우선 해석 자체는 맞다.
- **정당화 주석 반박**(브리핑 규약 4): `Scene3DLighting.swift:306-309` 이 col2 선택의 근거로 WE 스크립트 API
  `lib.sceneScript.d.ts` 의 `Mat4.forward() = Blue axis` 를 든다. 그러나 **V1 패커는 `forward()` 를 부르지
  않는다** — `glm::column(m, 0)` 을 직접 부른다. 스크립트 API 의 `forward()` 규약은 스크립트가 만든 행렬에
  대한 것이고 라이트 유니폼 패커를 구속하지 않는다.
- **정본·테스트 파급**(같이 고쳐야 하는 자리): 두 테스트가 지금 규약을 **잠그고 있다** —
  `Tests/WapleRenderTests/Scene3DLightingTests.swift:271`("방향 규약 잠금: forward = 월드행렬 blue축(+Z…).
  WE Mat4.forward()=\"Blue axis\".") · `Tests/WapleCoreTests/SceneForwardLightKindTests.swift:6 · :37 · :48 · :103`
  (`axis = 모델회전 blue축(col2)`, "directional — axis = Rx(90°) blue축 = (0,-1,0)").
  재현: `grep -rn "columns.2\|blue축\|Blue axis" Tests spec`. `spec/` 에는 열 규약 기록이 **0건**이다.
- 기지 목록 대조: **해당 없음.** 브리핑 "직전 감사가 확인하지 못한 것 #1"(팩커 미특정, 정본 기록 0건)의
  **해소**다. Waple `docs/`·`spec/` · 짝 저장소 `spec/` 어디에도 열 인덱스 기록이 없음을 grep 으로 확인했다.
- 방증: `SceneLight3D.WEDefaults.controlPoint = (2,0,0)`(ltube 단점 B 기본값)이 라이트 로컬 **+X** 로 2 —
  라이트의 주축이 X 라는 규약과 맞물린다(`Scene3DLighting.swift` 의 자체 주석도 "A 에서 +X 로 2 떨어진 B").

---

## 🟡 F6-2 — PR #8 의 "코퍼스 8 → 3" 동기화가 반만 됐다. 같은 숫자가 `SceneRenderer.swift:1165` 에 그대로 남았다

- 자리: `Sources/WapleRender/SceneRenderer.swift:1165`
  ```
  /// #22 HDR bloom authored 게이트(hdr && bloom — 코퍼스 8씬). 패스 생성 실패 시 hdrPost(클램프) 폴백.
  ```
- 근거/재현:
  `git show b883386e -- Sources/WapleRender/HDRBloomPass.swift` 가 `:5` 의 "코퍼스 8" 을
  "설치본 assets+projects 186 중 3" 으로 고치고, `:64-67` 에 **[동기화 2026-08-31]** 로
  "`HDRPostPass`·`LDRBloomPass`·`LDRBloomMath`·`VolumetricLightPass`·`Mesh3DShaders`와 `docs/re/` 도
  함께 고쳤다" 고 적었다. 그 목록에 `SceneRenderer.swift` 가 없고, 실제로 안 고쳐졌다.
  `grep -rn "코퍼스 8" Sources` → `SceneRenderer.swift:1165` 1건.
  정본: `spec/engine/tonemapping.json` `entries[2].value.corpusReach` =
  `{"LDR + bloom off":178,"LDR + bloom on":5,"HDR + bloom on":3,"HDR + bloom off":0}` · `corpusScenes` 186.
  즉 `hdr && bloom` = **3**.
- 왜 문제인가: 기지 M13 이 지목한 바로 그 숫자("어느 모집단에서도 안 나온다")가 **HDR bloom 게이트를
  실제로 소유한 자리**에 그대로 살아 있다. PR #8 의 동기화 주장 자체가 거짓이 된다.
- 기지 목록 대조: **M13 의 부분 미해결.** (M13 이 지목한 `HDRBloomPass.swift:5` 는 정상 수정됐다.)

---

## 🟡 F6-3 — README 의 HDR 피라미드 탭 반경이 `b19db5b1` 이후로 낡았다(±0.5 vs 실제 ±1.0)

- 자리: `README.md:46` — "a dual-filter pyramid built from `hdr_downsample.frag` **with 4 taps at ±0.5
  source texels**, no Gaussian pass, a 4-tap additive upsample chain and the 4-tap `combine_hdr` add"
  vs `Sources/WapleRender/HDRBloomPyramidPass.swift:9-10`
  "추출·다운샘플은 **±1.0 소스 텍셀**(소스 4×4 박스), 업샘플만 **±0.5 소스 텍셀**(소스 2×2 박스)".
  산술 본체: `Sources/WapleCore/HDRBloomMath.swift:131`(`downsampleTapScale = 1 << level`) ·
  `:136`(`upsampleTapScale = 2 << (sourceLevel-1)`) · `:138-141` 주석("다운샘플 계열은 정확히 1.0,
  업샘플은 0.5").
- 재현:
  ```
  git log -S "4 taps at ±0.5 source texels" --oneline -- README.md   # 44503a87 (2026-08-02) 도입
  git show --stat b19db5b1                                            # 2026-08-21, HDRBloomPyramidPass.swift 만 179+/23-
  ```
  `b19db5b1` 커밋 메시지가 "HDR 블룸 다운샘플 탭이 반경 절반이었다 — 업샘플 항등식을 다운샘플에
  일반화했다 … **화면이 바뀐다** — 각 단의 글로우 반경이 2배" 라고 스스로 밝히면서 README 를 안 고쳤다.
- 왜 문제인가: README 표가 "코드와 맞는 서술" 로 인용되는 자리인데, 3단계 중 2단계의 탭 반경이 틀렸다.
  이 리포에서 가장 생산적인 결함 부류(낡은 수치 · 코드가 앞서간 문서)에 정확히 해당한다.
- 기지 목록 대조: **해당 없음**(M5 는 README 의 **셰이더 줄 인용 3건 범위 이탈**이라 다른 자리).
- README 의 나머지 블룸 서술은 코드와 맞는다(아래 "문제없던 것" 참조).

---

## 🟡 F6-4 — `VolumetricLightPass.swift:95` 가 PR #8 이 지운 폴백(`?? 0`)을 아직 인용한다

- 자리: `Sources/WapleRender/VolumetricLightPass.swift:93-98`
  ```
  /// … 이 기본값 0 이 남아 있는 것은 **씬이 `radius` 를
  /// 저작하지 않은 경우**(`parseLight` 의 `radius: float(obj["radius"]) ?? 0`) 때문이고, 그때
  /// `hullRadius` 가 WE 라이트 생성자 기본 1.0(`0x140190494`)을 대신 써서 **헐 반경 0.99** 로 마치한다
  ```
- 근거/재현: PR #8 이 그 폴백을 바꿨다 —
  `Sources/WapleCore/SceneDocument.swift:2765` `radius: float(obj["radius"]) ?? SceneLight3D.WEDefaults.radius`
  (= **1.0**). `git show b883386e -- Sources/WapleCore/ScenePBRLighting.swift` 의 표도 `radius … 1.0 ✓` 로 바뀌었다.
  `grep -rn 'obj\["radius"\]' Sources` → 인용 1건(`VolumetricLightPass.swift:95`) + 실코드 1건(`SceneDocument.swift:2765`).
- 왜 문제인가: 주석이 설명하는 인과(파스 기본 0 → hull 폴백 1.0 → 0.99)가 더 이상 성립하지 않는다.
  `VolumetricLightParameters.radius = 0` 기본값과 `warnMissingRadiusOnce`(`:216`)는 이제 파스 경로로는
  도달 불가고, 명시적으로 `radius: 0` 을 저작한 씬에서만 걸린다. 화면 결과는 중립(hull 은 양쪽 다 0.99)이라
  🟡 로 둔다. `docs/re/volumetric-light.md` §6.1 의 "radius 유무로 0.5062 ↔ 0.2254" 실측도 같이 무효화됐다.
- 기지 목록 대조: **해당 없음**(H8 수정이 새로 남긴 밀린 인용).

---

## ⚪ F6-5 — 3D shake 가 clip-space 에서 world-space 로 옮겨가면서 "섀도우 불변" 보증이 사라졌다

- 자리: `Sources/WapleRender/SceneRenderer3D.swift:737-744`(shake 를 `eye`/`center` 에 월드 델타로 가산) ·
  `:1707-1709`(`DirectionalShadowMath.ShadowCamera(eye: eye, forward: fwd, …)` 가 그 **흔들린** eye 를 받는다).
- 근거/재현: `git show b883386e -- Sources/WapleRender/SceneRenderer3D.swift` 가 encode3D 에서
  ```
  - if frameShakeOffset != .zero { viewProj = Scene3DMath.clipTranslation(frameShakeOffset) * viewProj }
  ```
  와 함께 그 위 주석 "**shadow VP(광원공간)는 viewProj 미참조 → 월드 지오메트리·섀도우 불변,
  화면만 흔들림**" 을 통째로 지웠다. 새 경로는 CSM 프러스텀 슬라이스 입력(`ShadowCamera.eye`)이
  프레임마다 shake 만큼 움직인다.
- 왜 문제인가: `camerashake` + `ldirectional castshadow:true` 가 겹치는 씬에서 CSM 이 매 프레임 다시
  피팅돼 그림자 경계가 텍셀 스냅 없이 떨린다(shimmer). 종전 구현에는 없던 성질이다. 다만 이 조합의
  **동봉 코퍼스 도달은 0 이다** — `grep -rl "ldirectional" Sources/WapleRender/Resources/WEAssets/scenes/`
  가 0건이고(camerashake 저작 씬은 여럿 있으나 전부 파티클 프리뷰), 설치본/워크샵 코퍼스는 이 머신에 없어
  못 쟀다(`docs/re/scene-lighting.md:750` 기준 워크샵 `ldirectional` 5). 그래서 ⚪ 관찰로 둔다. 이중 적용은 없다: `SceneRenderer.swift:2551`/`:2787` 이 3D 경로에서
  `frameShakeOffset = .zero` 로 clip 병진을 끈다(확인함). `Scene3DMath.clipTranslation` 의 남은 소비자는
  `SceneRendererFrameEncoder.swift:1201`(2D 정사영 하이브리드)뿐이고, `Scene3DMath.swift:51-53` 의 새 주석이
  이를 정확히 반영한다.
- 기지 목록 대조: 해당 없음.

---

## 확인했지만 **문제없던** 것 (다음 라운드 시간 절약)

1. **H8 — `parseLight` 기본값 6/6 이 실제로 고쳐졌다.** `SceneDocument.swift:2764-2769` 가 `color`(0,0,0) ·
   `radius`(1.0) · `intensity`(0) · `exponent`(2.0) · `innercone`(20°) · `outercone`(30°) 을 전부
   `SceneLight3D.WEDefaults.*` 로 소비한다. RE 문서 `docs/re/scene-lighting.md:76-82` 표와 **여섯 값 전부**
   일치(오프셋 0x2cc/0x2e4/0x2e8/0x2ec/0x2f0/0x2f4). `density` 2.0 · `volumetricsexponent` 1.0 은 종전부터 일치.
   `exponent` 상수는 바이너리로 재확인했다 — `0x14019049e` 바이트 `c7 87 ec 02 00 00 00 00 00 40`
   = `mov dword [rdi+0x2ec], 0x40000000` = **2.0f**. `ScenePBRLighting.swift:406-419` 의 표도 같이 갱신됐다.
   (파생 거동 변화 1건: `radius` 미저작 라이트가 이제 드롭되지 않고 슬롯을 먹는다 — WE 패커도 안 버리므로
   더 충실한 쪽이다.)
2. **M13 — `HDRBloomPass.swift:5` 는 정상 수정됐다.** "코퍼스 8" → "설치본 assets+projects 186 중 3",
   정본 `spec/engine/tonemapping.json` `corpusReach["HDR + bloom on"] = 3` 과 일치.
   `LDRBloomPass.swift:33-34`(183 중 bloom:true 5), `HDRPostPass.swift:21-24`(183 / 3),
   `Mesh3DShaders.swift:611`(186 중 3), `VolumetricLightPass.swift:41`(186 중 0),
   `LDRBloomMath.swift:74-75`(186 중 저작 77) 전부 단일 모집단 186 과 정합.
   잔존 "358/354/4" 는 `HDRBloomPass.swift:55-56` 의 **인용된 종전 서술**뿐(의도적).
3. **블룸 나머지 README 서술은 맞다.** `0.25 * g_BloomScatter` 는 짝 저장소
   `wallpaper_engine/assets/shaders/hdr_downsample.frag:78` 원문 그대로(`#if UPSAMPLE albedo *= 0.25 * g_BloomScatter; #else albedo *= 0.25;`).
   추출의 `scatter^(max(N,2)−2)+1` 나눗셈 짝은 유지된다(`HDRBloomMath.swift:102-105`, 위임
   `HDRBloomPyramidPass.swift:129-133`). 톤커브 없음 = plain saturate(`HDRPostPass.swift:6-12`, 셰이더 본문
   `saturate(c.rgb * exposure)`). LDR 은 여전히 3패스(`LDRBloomPass.swift:59-61` extract/blur/composite 파이프라인 3개).
4. **PBR 분모 0 방어는 전부 있고 WE 원문과 같다.** `Mesh3DShaders.swift:257`
   `max(4.0*max(dot(N,V),0.0)*NL, 0.001)` = `common_pbr_2.h:310`(유한광)·`:358`(무한광)의 `max(denominator, 0.001)`.
   `GeometrySmith` 의 0.001 · `FresnelSchlick` 의 `max(1-cos, 0.001)` 도 WE `common_pbr.h:6/36` 동일.
   `Distribution_GGX` 의 `max(raw, 1e-4)` 는 문서화된 의도적 이탈(`spec/engine/deviations.json` D1) —
   `deviations.json` 이 "안전장치처럼 보이는 이탈로 다시 적출하지 마라" 고 명시.
5. **법선 정규화 누락 없음.** 4개 프래그먼트 진입점 전부 `float3 N = normalizedOr(in.worldNormal, …)`
   (`Mesh3DShaders.swift:570 · 652 · 772 · 845`).
6. **본 상한(M12)은 코드에 없다.** `Mesh3DShaders.swift:75`/`:119` 의 `bones` 는
   `const device float4x4*`(고정 배열 아님)이고, CPU 가 정점 팩 시 인덱스를 `boneCount-1` 로 클램프한다
   (`SceneRenderer3D.swift:345-347`). 곧 `g_Bones` 40 vs 48 은 **문서 쪽 수치 문제**이고 셰이더 상한 결함이 아니다
   (M12 는 기지 — 재보고 안 함).
7. **`clampedFovDegrees` 는 NaN 안전하다.** PR #8 이 `resolveCamera3DFrame` 에서 종전 `f > 0` 가드를
   지웠지만(`SceneRenderer3D.swift:723-724`, 종전 `f > 0` 가 사라진 자리), `CameraMotion.swift:380-384` 가
   `(fov < 179.9) ? fov : 179.9` → `(0.1 > upper) ? 0.1 : upper` 형태라 NaN → **179.9**(상한),
   0/음수 → 0.1 로 접힌다. 주석의 "NaN(minss → 상한)" 주장과 일치. `cameraFrame.fov` 의 다른 소비자는
   `SceneRenderer3D.swift:1673-1709` 의 `Scene3DMath.perspective`(내부에서 클램프)와
   `tan(fov*π/360)`(ShadowCamera) 둘뿐 — 후자는 NaN 을 못 받는다.
8. **버려지는 커서-훅 엔진은 no-op 이 아니다.** PR #8 이 3D 텍스트의 `alpha`/`color` 스크립트에 대해
   `_ = makeScriptEngine(…)` 로 반환값을 버리지만, `SceneRenderer.swift:279-292` 가 `hookNames` 보유 엔진을
   `eventEngines` / `hoverEngineOwners` / `pointerEngineOwners` 에 **등록**한다 — 계약대로 배달된다.
9. **`EngineU` 336B 주석 2건은 맞다.** `GLSLTranslator.swift:2222` 방출 구조체 =
   64+16+16+128+32+32+16+16+16 = **336**.
10. **포인트 섀도 아틀라스 인덱싱**: `slice`/`matrixIndex` 는 CPU(`encodePointShadows`)가 정하고 셰이더는
    `light.shadow.x < 0` 만 거른다(`Mesh3DShaders.swift:379/434/466-469`). 상한 클램프는 없지만 CPU 쪽
    할당(`maximumLights*6`)에 묶여 있어 실도달 결함 근거를 못 찾았다 — **의심**으로만 남긴다.

11. **3D 포인터 히트 쿼드의 y 방향이 2D 경로와 일치한다.** PR #8 이 새로 넣은
    `SceneRenderer3D.projectedBillboardHitQuad`(`SceneRenderer3D.swift:2118`)는
    `(ndc.y + 1) * 0.5 * projH` 로 매핑한다(Metal NDC +1 = 화면 위 → 씬 y 최대). 입력 역매핑
    `SceneRenderer.sceneCoords`(`SceneRenderer.swift:1413-1416`)도 AppKit 비-flipped 뷰 좌표
    (y 위쪽 증가)를 `(ny+1)/2*projH` 로 그대로 옮긴다. 2D 발행부(`SceneRendererFrameEncoder.swift:1697` ·
    `:2159` → `SceneRenderer.layerHitQuad:596`)와 같은 y-up 규약이다 — 세로 미러 없음.

## 의심(확인 못 함)

- F6-1 의 화면 영향 크기: 워크샵 코퍼스 446 폴더 부재로 `lspot`/`ldirectional` 의 실제 `angles` 분포를
  못 봤다. `angles=(0,0,0)` 라이트만 있는 씬이라면 방향 차이가 90° 고정으로 드러나고, 회전이 있으면 씬마다 다르다.
- F6-5 의 설치본/워크샵 도달: 동봉 코퍼스는 0 으로 확정했으나 설치본 `assets/`+`projects/` 와 워크샵 446
  폴더가 이 머신에 없어 `camerashake` × `ldirectional castshadow:true` 조합의 실도달을 못 쟀다.
- 볼류메트릭 패커(`0x140196ce0`–)의 방향 열: 그 범위 안의 `0x14019d3e0` 호출은 `r15d = 3`(원점)뿐이고
  스팟 방향은 다른 경로로 들어간다 — V1 패커만큼 확정하지 못했다.
