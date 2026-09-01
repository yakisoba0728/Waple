# 전수 정독 감사 (라운드 4) — Waple 프로덕션 소스 전 라인

> **모드**: 워크플로 **8에이전트 · 단일 페이즈**. grep 표본이 아니라 **전 라인 정독**이 지시였다.
> **대상**: `Sources/**` 프로덕션 소스 **175파일 · 73,355줄** (Waple `b883386e`, 작업 트리 깨끗)
> **수정 금지 — 발견만 기록.** 두 리포의 기존 파일을 한 줄도 고치지 않았다.
> **선행**: `AUDIT-FULL-2026-08-31.md`(r1) · `-r2.md` · `-r3.md` + `docs/audit-r2-lanes/`(18레인).

## 0. 왜 또 돌렸나

선행 감사 셋은 전부 **grep 으로 후보를 뽑고 후보만 정독**했다. 그래서 놓친 것이 반복해서 나왔다 —
r3 의 `hasStableId` 절반, `waterripple` 제곱 누락, zip 축은 전부
**"그 자리를 아무도 끝까지 읽지 않아서"** 살아남았다. 이 라운드는 그 축을 닫는다.

## 1. 커버리지 — 이 라운드의 값어치는 여기 있다

| 항목 | 값 |
| --- | --- |
| 분할 | 8버킷 · LPT 균등 배정 — **9,165 ~ 9,174줄**(편차 9줄) |
| 배정 검증 | 배정 175파일 = 실제 175파일 · **누락 0 · 중복 0**(기계 대조) |
| 완주 | **8/8 버킷 · 실패 0** |
| 자기보고 | 8버킷 전부 "전 줄 정독, 건너뛴 구간 없음" + **구간별 실독 범위 명시**(경계 1줄 중첩) |

자기보고 원문은 [`coverage-selfreport.md`](coverage-selfreport.md) 에 있다. 각 버킷이
`ParticleSystem.swift(3,519) — 1-360 / 356-755 / …` 처럼 청크 경계를 적어 두어 검증 가능한 형태다.

**주의**: 이것은 **자기보고**다. 오케스트레이터가 8×9,170줄을 재독해 대조하지는 않았다.
다만 아래 발견들이 파일 중반·후반부(예: `SceneDocument.swift:2549`, `TextScriptEngine.swift:2285`,
`ParticleSystem.swift:3140`)에 고르게 분포하는 것은 실제로 끝까지 읽었다는 정황이다.

## 2. 결과 요약

**발견 44건 — 🔴 0 · 🟠 1 · 🟡 25 · ⚪ 18.**

선행 셋이 이미 훑은 코드라 신규 실동작 결함은 적다. 그러나 **grep 으로는 원리적으로 안 나오는 부류**가 나왔다:

- **형제 함수 비대칭** — 두 함수를 나란히 끝까지 읽어야만 보인다. 유일한 🟠 가 이 형태다.
- **주석이 약속한 파리티가 코드에 없는 것** — 주석만 읽으면 맞는 말이고, 코드만 읽으면 이상하지 않다.
- **cross-file 인용 전수** — 버킷 1 한 곳에서만 17건 중 12건 무효.
  선행 r1(`AUDIT-FULL-2026-08-31.md:1400`)이 *"다른 파일을 가리키는 인용은 멀쩡하다"* 고 **선언한 부류**다.

r3 가 미판정으로 남긴 것 중 2건(`SceneRendererFrameEncoder.swift:450` copyBackground ·
`LibraryStore.swift:218` zip `try?`)도 이 라운드가 판정했다.


### 🟠 high (1건)

| 자리 | 요지 |
| --- | --- |
| `Sources/WapleCore/SceneDocument.swift:2549` | effectQuadLayer 가 키프레임 애니({animation})를 통째로 버린다 — 형제 parseLayer 는 캡처하는데 주석은 파리티를 주장 |

### 🟡 medium (25건)

| 자리 | 요지 |
| --- | --- |
| `Sources/WapleRender/SceneRenderSettings.swift:58` | 버킷 소스 주석의 cross-file `파일:줄` 인용 17건 중 12건이 다른 코드를 가리킨다 — AUDIT-FULL:1400 의 "다른 파일 인용은 멀쩡하다" 반증 |
| `Sources/WapleCore/SceneDocument.swift:884` | `originb` 는 WE 에 없는 키인데 SceneLight3D 주석이 "wallpaper64.exe 스트링 실측" 이라고 단언 — 짝 파일이 이미 반증했는데 Core 쪽만 안 고쳤다 |
| `Sources/WapleCore/SceneDocument.swift:567` | 텍스트 `depthtest` 도수 "enabled 1394건" 이 모집단 미표기이고 리포 정본(1391)과 어긋난다 |
| `Sources/WapleCore/PropertyAnimation.swift:358` | `wrapLooped` 의 `- Note:` 가 "평가기는 backEnabled 를 게이트로 쓴다"고 적지만, 같은 날 커밋이 `segment()` 에서 그 게이트를 걷어냈다 — 같은 파일 100줄 위가 정반대를 적는다 |
| `Sources/WapleCore/ShaderPreprocessor.swift:147` | `parseComboDefaults` CRLF 주석이 지목한 "정규화 밖 호출부" 둘 중 하나(`resolvePassCombos`)는 이미 이 함수를 부르지 않는다 — 같은 파일 15줄 위 주석과도 정면 모순 |
| `Sources/WapleCore/ParticleSystem.swift:2391` | CP 인덱스 클램프가 리포에 셋인데 32비트 절단은 하나만 한다 — `clampControlPoint` 이 형제 `clampIndex` 와 다른 CP 를 고른다(r3 M5 의 세 번째 자리) |
| `Sources/Waple/Surfaces/Settings/SettingsView.swift:21` | 설정 창 높이 주석이 "섹션이 6개"라고 적고 그 위에 픽셀 실측을 쌓아 두는데, 실제 섹션은 7개다(재생정책 섹션이 열흘 뒤 추가되며 갱신 안 됨) |
| `Sources/WapleCore/ParticleSystem.swift:2707` | 확장자 없는 `File:줄` 형 교차파일 인용 넷이 전부 무효 — `ParticleSimulator:1732`·`ParticleSimulator:305`·`WorkshopTabView:33`(두 자리) |
| `Sources/WapleRender/VolumetricLightPass.swift:269` | 볼류메트릭 radius 경고 문구가 "배선하라"고 지시하는 인자는 같은 커밋에서 이미 배선돼 있다 — 태어날 때부터 거짓인 진단 |
| `Sources/WapleCompatCore/DeepScan.swift:549` | DeepScan 이 손포팅 7종을 번역 시도 없이 건너뛴다 — 렌더러는 translated 우선이라 스캐너가 다른 것을 검사한다 |
| `Sources/WapleCompatCore/DeepScan.swift:911` | DeepScan 주석이 "check_lenient_json_reach.py 의 WIRED 표에 이 파일이 없다" 고 적는데, 같은 커밋이 그 표에 넣었다 |
| `Sources/WapleRender/SceneRendererFrameEncoder.swift:403` | lane05 의 SceneRendererFrameEncoder 좌표-드리프트 열거가 불완전 — 미열거 5자리 |
| `Sources/WapleCore/AudioSpectrum.swift:295` | AudioSpectrum 주석이 `binCount` 수정 뒤에도 옛 값(32 kHz → B=940)을 현재형으로 남겼다 — 같은 파일 20줄 위가 그 값을 폐기한 이유를 적고 있다 |
| `Sources/WapleRender/Mesh3DShaders.swift:599` | Mesh3DShaders 의 "이 주석을 따르는 형제" 열거가 **존재한 적 없는 `mf_skinned*`** 를 가리키고, 실제로 같은 블록을 복제한 `mf_refract`·`mf_reflect` 둘을 빠뜨렸다(출생 시점부터) |
| `Sources/WapleRender/VideoRenderer.swift:259` | VideoRenderer 가림 옵저버의 `player?.rate != 0` 가드가 F840 절전 게이트를 뚫는다 — 형제 WebRenderer 는 그 가드가 없고 회귀 테스트까지 있다 |
| `Sources/WapleRender/TexDecoder.swift:258` | TexDecoder r8 도수 "파티클 텍스처 60개 중 56개" 가 실측 164개 중 51개 — 두 수가 센서스의 다른 행에서 왔다 |
| `Sources/WapleRender/SceneRenderer3D.swift:17` | GPU3DMesh 독트링 "ibuf 는 u16" — 실제는 u32. 폭을 넓힌 커밋이 드로우콜 4자리만 고치고 이 독트링은 안 고쳤다 |
| `Sources/WapleRender/SceneRenderer3D.swift:1180` | builtinMeshShaderWhitelist 주석이 `shimmering_particles` 를 a_Normal 확장의 수혜자로 세는데 그 셰이더는 a_Normal 을 한 줄도 선언하지 않는다 (그리고 '8건' 인데 7개만 나열) |
| `Sources/WapleCore/EffectManifest.swift:503` | EffectManifest 가 같은 '동봉 effect.json' 모집단을 128 · 122 · 101 세 값으로 적는다 (셋 다 실재하지만 서로 다른 집합) |
| `Sources/WapleCore/WebCompatPatch.swift:151` | WebCompatPatch 의 근거 진술 둘이 동봉 zcompat 자산에 반증된다 — '동봉 5건 전부 소문자' 와 'needle 최대 63바이트' |
| `Sources/WapleRender/BaseAssetsSettings.swift:6` | BaseAssetsSettings 타입 헤더가 '앱이 기본 에셋 팩을 번들하지 않으므로 사용자가 지정해야 한다' 고 적는데 같은 파일이 동봉 폴백을 구현한다 |
| `Sources/WapleRender/SceneRendererResources.swift:848` | 출력 패스 가드를 `command:"swap"` 패스가 무력화한다 — 형제 라우터는 명시 제외하는데 가드만 안 한다 |
| `Sources/Waple/Shell/LibrarySection.swift:43` | `LibrarySection` 의 "쓰기 주체가 둘" 근거가 UI 개편으로 거짓이 됐고, 그 결과 `selection(for:)` 의 nil 분기 셋이 프로덕션 도달 불가가 됐다 |
| `Sources/Waple/Surfaces/Workshop/WorkshopTabView.swift:27` | `loadMore` 실패 인용 `:174-176` 이 지금은 정반대로 동작하는 블록(`search()` 의 catch)을 가리킨다 |
| `Sources/WapleCore/GLSLTranslator.swift:174` | "정확일치 조회 자리가 둘" 이라는 도수가 실제로는 넷 — 콤보 키 접기 수정이 같은 게이트 3자리 중 1자리에만 걸렸다 |

### ⚪ observation (18건)

| 자리 | 요지 |
| --- | --- |
| `Sources/WapleLibrary/ZipImporter.swift:62` | ZipImporter: `terminationHandler` 를 `p.run()` 이후에 설치한다 — 그 사이에 끝난 프로세스는 300초 타임아웃 오탐이 될 수 있다 |
| `Sources/WapleLibrary/PlaylistStore.swift:20` | PlaylistStore: intervalMinutes 는 세터만 `max(1,·)` 클램프이고 디코드 경로엔 클램프가 없다 |
| `Sources/WapleRender/OggVorbis/VorbisCodebook.swift:102` | Vorbis 코드북 F840 패킷-크기 게이트가 `multiplicands` 만 덮는다 — lookup_type 1 의 `vqFlat`(최대 67MB)은 패킷 크기와 무관하게 할당된다 |
| `Sources/WapleCore/ParticleSystem.swift:3140` | 파일명 없는 자기참조 `:N` 인용 8자리가 전부 무효(두 파일) |
| `Sources/WapleRender/SceneRenderer.swift:2739` | captureFrames 의 라이브 상태 save/restore 집합이 encodeDrawPlan 이 실제로 변이시키는 상태보다 좁다 — lane05 가 "문제없음" 으로 센 5항목 밖이 통째로 빠져 있다 |
| `Sources/WapleCore/ScenePBRLighting.swift:704` | 볼류메트릭 반경 감쇠의 GPU/CPU 두 벌 중 GPU 쪽에만 exponent 클램프가 있다 — "비트로 대조" 를 목적으로 둔 쌍의 한쪽만 방어됨 |
| `Sources/WapleCompatCore/DeepScan.swift:208` | F681 ogg 예산 doc 주석이 assetLoadTimeoutSeconds 에 붙어 있고 oggDecodeTimeBudget 은 무주석 |
| `Sources/WapleRender/SceneRendererFrameEncoder.swift:450` | r3 §4.3 미판정 확정: copyBackground:false 컴포지션 레이어의 colorBlendMode dst 가 acc 스냅샷이 아니라 투명 클리어다 |
| `Sources/WapleLibrary/LibraryStore.swift:218` | r3 §4.3 미판정(LibraryStore zip try?)은 기지다 — 다만 "손상 zip 로그 0건" 절반은 선행 문서에 없다 |
| `Sources/WapleCore/RemapOperation.swift:39` | RemapOperation 주석은 "정확한 나눗셈을 쓴다" 인데 코드는 역수 곱이다(무작위 float32 26%에서 1 ulp 차) |
| `Sources/Waple/DesktopVisibilityMonitor.swift:163` | DesktopVisibilityMonitor 스냅샷 기본값 주석의 방향이 alpha 에 대해 반대다 |
| `Sources/Waple/DesignSystem/Components/Badges.swift:13` | Badges.swift 의 "실측: 사용자 대면 문자열 42건 중 40건" 이 모집단을 밝히지 않고, 작성 시점 트리에서 42 에 해당하는 모집단을 찾지 못했다 |
| `Sources/WapleRender/TextScriptEngine.swift:2285` | 파일명 없는 자기참조 `:N` 인용 중 **작성 시점부터 무효**였던 것 2건 확인(r3 O25 가 미검증으로 남긴 414자리에서) |
| `Sources/WapleCore/Model3D.swift:1252` | Model3D.inferStride 가 인덱스 폭을 u16 로 고정 — 본경로는 2026-08-20 에 `gateWord & 1` 로 바뀌었는데 추론 경로만 옛 가정에 남았다 |
| `Sources/WapleCore/ParticleSimulator.swift:1352` | applyAttract 헤더가 "두 핸들러는 블렌드 가중 곱 하나만 다르다 · 1:1 로 옮긴 것" 이라 적고 의사코드에 `step *= w` 를 담는데, 구현에 그 항이 없다 |
| `Sources/WapleCore/SceneGeometry.swift:130` | `cameraparallaxdelay` 코퍼스 도수 176/175 가 두 파일에서 전치돼 있다 (176 은 설치본 파일 수, 175 는 그중 0.1 값 수) |
| `Sources/WapleRender/SceneRenderer3D.swift:1286` | buildCustomMeshShader 의 albedoName 이 '첫 non-null' 구규약을 그대로 쓴다 — 같은 파일이 그 규약을 결함으로 지목하고 슬롯 0 전용으로 고친 뒤에도 |
| `Sources/WapleCore/PointerHit.swift:314` | `g_PointerState` 소비처 인용이 preview 사본 두 건에서 어긋난다(게인·줄번호) |
## 3. 오케스트레이터 독립 재현

레인 보고를 믿지 않고 직접 밟은 것이다.

### 🟠 `SceneDocument.swift:2549` — effectQuadLayer 가 키프레임 애니를 통째로 버린다 · **확정**

두 루프를 나란히 놓으면 명백하다.

```swift
// parseLayer :2145-2152 — 독립된 두 개의 if
if let bind = obj[key] as? [String: Any], let a = PropertyAnimation.parse(bind) {
    anims[key] = a                                   // ← 애니 캡처
}
if let bind = obj[key] as? [String: Any], let sc = bind["script"] as? String {
    propScripts[key] = sc
}

// effectQuadLayer :2549-2553 — guard 하나뿐
guard let bind = obj[key] as? [String: Any], let sc = bind["script"] as? String else { continue }
layer.propertyScripts[key] = sc                      // ← PropertyAnimation.parse 호출이 없다
```

- `awk 'NR>=2490 && NR<=2558' … | grep 'animations\|PropertyAnimation'` → **0건**.
  이 함수는 `layer.animations` 에 아무것도 싣지 않는다.
- 바로 위 주석(`:2546-2547`)이 *"저작 트랜스폼을 살렸으니 그 바인딩도 함께 산다 —
  버려 두면 정적 값만 맞고 애니는 멈춘다(parseLayer 의 동일 루프)"* 라고 **파리티를 주장한다.**
  주석이 약속한 것과 코드가 하는 일이 정반대다.
- **출생 확인**: `git log -S '저작 트랜스폼을 살렸으니 그 바인딩도 함께 산다'` → `8b614df6` 하나.
  그 시점 트리(`:1416-1420`)도 `guard … bind["script"]` 하나뿐 — **드리프트가 아니라 도입 시점부터 반쪽**이다.
- **도달**: 정본 `spec/corpus/scene-schema.json` 의 `scene.bindings.forms` →
  `shape.origin: {'animation|value': 6}`. **모집단은 워크샵 코퍼스**이고 이 머신에 실물은 없다.
  동봉 코퍼스 도달은 0이라 골든은 안 움직인다 — 워크샵 자산 전용 결함이다.
- 소비 사슬도 죽는다: `SceneRendererResources.swift:568` 의 `def` 게이트와 `:469` 의
  `hasAnimations` 게이트가 둘 다 `layer.animations.isEmpty` 를 보므로 스크립트 폴백조차 안 걸린다.

### 🟡 `SceneRendererResources.swift:848` — 출력 패스 가드를 `command:"swap"` 이 무력화한다 · **확정**

`makeSwapPass` 가 만드는 `TranslatedPass` 는 `target: nil` 이다(`:964`).
그런데 출력 패스 가드는 `passes.contains(where: { $0.target == nil })` 로 판정한다(`:848`).
**포인터만 교환하고 아무것도 그리지 않는 패스가 "출력 있음" 으로 카운트된다.**

동봉 `fluidsimulation/effect.json:294-303` 의 swap 패스 둘은 원문에는
`"target": "_rt_SmokeVelocity2"` 를 갖지만, `makeSwapPass` 는 그 값을 FBO 인덱스 해석에만 쓰고
`TranslatedPass.target` 에는 `nil` 을 넣는다. 진짜 출력 패스가 전부 번역 실패해도
swap 둘이 남아 가드를 통과하므로 **폴백이 안 걸린다.**

## 4. 한계

1. **커버리지는 자기보고다**(§1 주의 참조).
2. **`Tests/**`(87k줄)는 이 라운드의 대상이 아니다.** 프로덕션 소스만 전수했다.
   테스트 오라클 축은 r2 lane12 · r3 렌즈가 덮었다.
3. **워크샵 코퍼스 446 은 이 머신에 없다.** 도달 도수는 정본 기록 또는 동봉 코퍼스 기준이다.
4. **검증 라운드가 없다.** 단일 페이즈 지시였으므로 44건 중 오케스트레이터가 직접 재현한 것은 §3 의 2건뿐이다.
   나머지 42건은 **레인 자기보고 상태**이고, r3 의 실측(118건 중 8건 = 6.8% 가 거짓 신규)을 감안하면
   이 중 두어 건은 기지·기각 대상일 수 있다.
5. `Sources/WapleSaver/WapleSaverView.m` 은 배정에 포함됐다(Objective-C 204줄).

## 5. 산출물

- [`findings-detail.md`](findings-detail.md) — 44건 전문(근거·영향·모집단·기지 대조)
- [`coverage-selfreport.md`](coverage-selfreport.md) — 8버킷 실독 범위
- [`clean-notes.md`](clean-notes.md) — "읽었고 문제없었다" 기록. **다음 라운드가 건너뛸 근거다**
