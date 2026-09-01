
### 🟠 `Sources/WapleCore/SceneDocument.swift:2549`
**effectQuadLayer 가 키프레임 애니({animation})를 통째로 버린다 — 형제 parseLayer 는 캡처하는데 주석은 파리티를 주장**
- 근거: 코드 대조: parseLayer 의 5키 루프(:2144-2152)는 같은 dict 에서 `PropertyAnimation.parse(bind)` → `anims[key]` **와** `bind["script"]` 를 둘 다 캡처하고 그 anims 를 `SceneLayer(… animations: anims)`(:2256)로 싣는다. effectQuadLayer 의 같은 루프(:2549-2553)는 `guard … let sc = bind["script"]` 하나뿐이고, `sed -n '2505,2557p' … | grep -n 'animations\|PropertyAnimation'` 결과 0건 — 이 함수 전체에서 `layer.animations` 에 대입하는 곳이 없다.
도수(모집단: 워크샵 정본 코퍼스 `spec/corpus/scene-schema.json`, 162씬): `python3` 로 `scene.bindings.forms.byKeyPath` 조회 → `shape.origin = {'animation|value': 6}`. 같은 정본의 `scene.objects.keysByType.shape` 는 shape 오브젝트 41개/23씬이고 **전건 effects 보유**(= 전건 isEffectQuad 통과 → effectQuadLayer 경로).
재현 코퍼스 도달 0: 동봉 `Sources/WapleRender/Resources/WEAssets` 의 scene-like json 177개를 python 전수 스캔 → shape 오브젝트 3개, 그중 origin/scale/alpha/angles/color 에 `{animation}` 을 가진 것 0건.
소비 사슬 확인: `SceneRendererResources.swift:568` 이 `def: (layer.animations.isEmpty && puppetModel == nil && propScripts.isEmpty ? nil : layer)` 이고, per-frame 애니 평가는 `SceneRendererFrameEncoder.swift:1492/1503` 의 `def.animations[key]` 다. shape.origin 바인딩 6건은 `animation|value` 형태(script 미동반)라 propScripts 도 비어 def==nil 이 확정된다. 연속 리드로 게이트 `SceneRendererResources.swift:469` 의 `if !layer.animations.isEmpty { hasAnimations = true }` 도 서지 않는다.
출생 확인: `git log -S '저작 트랜스폼을 살렸으니 그 바인딩도 함께 산다' -- Sources/WapleCore/SceneDocument.swift` → 8b614df6 하나. `git show 8b614df6:… | grep -A12` 로 그 시점 루프(:1416-1420)를 펼치니 그때도 script 만 캡처 — 드리프트가 아니라 도입 시점부터 반쪽이다.
- 영향: 이펙트 캐리어 quad(전건 lightshafts/광속)에 `origin` 키프레임을 저작한 씬에서 광선 쿼드가 정적 위치에 못 박힌다. 애니가 값으로도 안 실리고 `def`/`hasAnimations` 도 안 서므로 스크립트 폴백조차 없다. 바로 위 주석(:2546-2547)이 "저작 트랜스폼을 살렸으니 그 바인딩도 함께 산다 — 버려 두면 정적 값만 맞고 애니는 멈춘다(parseLayer 의 동일 루프)" 라고 적어 파리티를 주장하므로, 다음 사람이 이 자리를 다시 열어 볼 이유가 없다. 재현 코퍼스 도달은 0이라 동봉 골든은 안 움직인다 — 워크샵 자산 전용 결함이다.
- 모집단: 워크샵 정본 코퍼스 spec/corpus/scene-schema.json 162씬 = shape.origin animation 6건 / shape 오브젝트 41개 · 23씬. 동봉 WEAssets 177 scene-json = shape 3개 중 0건. 설치본 미측정.
- 기지 대조: 선행 3감사(AUDIT-FULL / -r2 / -r3)와 docs/audit-r2-lanes 18파일 전체에서 `effectQuad`·`캐리어`·`shape.origin` grep 0건. r3 O25(파일명 없는 자기참조 인용)와도 다른 부류다.

### 🟡 `Sources/WapleRender/SceneRenderSettings.swift:58`
**버킷 소스 주석의 cross-file `파일:줄` 인용 17건 중 12건이 다른 코드를 가리킨다 — AUDIT-FULL:1400 의 "다른 파일 인용은 멀쩡하다" 반증**
- 근거: 방법: 버킷 21파일에서 `([A-Za-z0-9_]+\.swift)\s*:\s*(\d+)` 를 python 으로 전수 추출(19건) → 자기참조 2건 제외 → cross-file 17건. 각 대상 파일의 그 줄을 실제로 열어 대조했다.
불일치 12건(인용 → 실제 자리):
1) SceneDocument.swift:382 및 :859-860 → `SceneRendererResources.swift:329-341`(2D PuppetAttach 배선) / 실제 528-549. 329-341 은 이펙트 체인 코드.
2) SceneDocument.swift:1609 → `SceneRenderer3D.swift:510`(draw3DOrder) / 실제 554.
3) SceneDocument.swift:1680 → `SceneRenderer.swift:1403`(`projW = Float(max(1, doc.projectionWidth))`) / 실제 2002.
4) SceneDocument.swift:2141 → `SceneRendererResources.swift:458`(`!layer.animations.isEmpty → hasAnimations`) / 실제 469.
5) SceneDocument.swift:2947 → `SceneRendererFrameEncoder.swift:405`(852473d 의 `*.pi/180` 제거 3자리) / 실제 664·915·938. `git show --stat 852473d` 로 그 커밋이 이 파일만 6줄 고친 것을 확인.
6) PuppetModel.swift:232 → `Model3D.swift:255`. 주석 스스로 ":255 는 이제 MDLA Key 36바이트 산문" 이라고 정정했는데 실제 :255 는 `public let bind: simd_float4x4` — 정정문이 또 드리프트했다.
7) PuppetModel.swift:252 → `Model3D.swift:569`. 주석은 ":569 는 이제 hasAABB 대입" 이라는데 실제는 로제타석 검증 서술 줄.
8) AudioResponse.swift:223 → `GLSLTranslator.swift:2555` / 실제 2637(`split(whereSeparator: { $0 == " " || $0 == "," })`, 설명 주석 2623). 파일도 WapleRender 가 아니라 WapleCore 다.
9) WallpaperProject.swift:165 → `VideoRenderer.swift:296`(WallpaperProject 생성) / 실제 317.
10) MediaPoller.swift:33 → `AppDelegate.swift:701`(및 :755·:756, RunLoop `.common` 등록) / 실제 927·1096·1123.
11) SceneRenderSettings.swift:58 → `SceneRenderer.swift:919`(fitMode 소비) / 실제 992. 같은 문장의 `:2433`·`:2623` 도 실제 2591·2826.
12) SceneRenderSettings.swift:58 → `VideoRenderer.swift:200`(`switch SceneRenderSettings.fitMode`) / 실제 215.
정확 5건: `AudioResponse.swift:2`(=import simd), `PlaybackPolicyRuntime.swift:27-29`, `ProjectJSONParser.swift:84`(=`return WallpaperProject(`), `WebRenderer.swift:179`, `SnapshotPipeline.swift:34`.
정규식이 못 잡는 형태를 손으로 더 확인 — 전건 불일치: SceneRenderSettings.swift:62 의 `SnapshotPipeline.swift:326-327 pinRenderSettings`(실제 241·288·404), :55-56 의 `docs/re/media-playback.md:684,708`(alignment 0=Cover 는 실제 693·717), SceneDocument.swift:1632-1633 의 `spriteFrameTexture(:1848)`(실제 2426)·`TexImage.spriteFrameIndex(:208)`(실제 293), :3837 의 `SceneRendererFrameEncoder :1450 이미지 · :1629 텍스트`, DisplaysView.swift:210 의 `WorkshopTabView:33`(실제 45·55 — 같은 오인용이 WallpaperGridView.swift:114 에도 복제). 손 확인분 중 정확한 것은 `WallpaperGridView:114-116` 과 `scripts/spec/check_ortho_projection_census.py` 의 `EXPECT_PERSPECTIVE_SCENES`(:49) 둘.
- 영향: 이 리포의 주석은 근거 인용이 곧 문서다. 인용 12건이 딴 코드를 가리키므로, 그 주석이 미룬 결정(예: transparentsorting/orthoAuto 의 "착지 지점", PuppetAttach 배선, HDR fitMode 소비처)을 실행하려는 사람이 매번 엉뚱한 줄부터 다시 찾아야 한다. 특히 SceneRenderSettings.swift:53-63 은 기본값을 `.fit`→`.fill` 로 뒤집은 근거 문단인데 소비처 5자리 중 4자리와 근거 문서 줄 2자리가 전부 틀렸다 — 되돌리려는 사람이 근거를 재현할 수 없다. PuppetModel 의 두 정정문은 "줄 번호가 드리프트했다" 고 고쳐 놓고 그 정정 자체가 다시 드리프트해, 정정이 신뢰를 회복시키지 못한다는 것을 보여 준다.
- 모집단: 모집단: 버킷 1 의 21파일 주석에서 기계 추출한 `.swift:N` cross-file 인용 17건(자기참조 2건 제외). 손 확인분 12건은 별도.
- 기지 대조: 인접 선행과 다르다. r2 §4(:141)는 `GLSLTranslator.swift` 안의 **자기 인용** +8 드리프트, docs/audit-r2-lanes/lane14-docs.md 는 **문서→코드** 인용 드리프트, r3 O25 는 **파일명 없는 자기참조 `:N`** 416자리(표본 1건만 확인)다. 여기 12건은 전부 파일명이 붙은 **소스→소스 cross-file** 인용이고, AUDIT-FULL-2026-08-31.md:1400 이 명시적으로 "다른 파일을 가리키는 인용은 멀쩡하다" 고 선언한 바로 그 부류다. (그 문장이 근거로 든 `SceneDocument:4006` 블록은 현재 파일에 없어 재검증 불가 — 그래서 이 표본이 그 주장을 대체한다.)

### 🟡 `Sources/WapleCore/SceneDocument.swift:884`
**`originb` 는 WE 에 없는 키인데 SceneLight3D 주석이 "wallpaper64.exe 스트링 실측" 이라고 단언 — 짝 파일이 이미 반증했는데 Core 쪽만 안 고쳤다**
- 근거: SceneDocument.swift:884 = "ltube 세그먼트 단점 B(scene.json `originb` — wallpaper64.exe 스트링/에디터 키 실측, 소문자)", 같은 주장이 파스 자리 :2777 에도 있다(`originB: vec3(obj["originb"])` @:2778).
리포 안 반증 둘: (a) `docs/re/scene-lighting.md:95` — "**`originb` 는 존재하지 않는다.** tube 단점 B 는 `controlpoint`(`+0x2d8`)다"; 같은 문서 :724 표가 `originb` 도수 **0**. (b) `Sources/WapleRender/Scene3DLighting.swift:219-233` 이 "⛔️ 반증(2026-08-21): 입력 키 `originb` 는 WE 에 존재하지 않는다 … 바이너리 전체에서 ASCII 0건 / UTF-16 0건" 이라고 적고, 라이트 프로퍼티 등록 테이블(0x14025da80–0x14025e9da)의 키 목록에 `originb` 가 없음을 나열한 뒤 "그쪽을 고칠 때 `obj["originb"]` → `obj["controlpoint"]`(기본 (2,0,0))로 바꾸면 된다" 고 이관 지시까지 남겼다.
`grep -rn originb Sources spec docs scripts Tests` 로 두 주장이 같은 리포에 공존함을 확인.
- 영향: 같은 리포 안에서 한 파일은 "실측된 키" 라 하고 다른 파일과 정본 문서는 "존재하지 않는 키" 라고 한다 — 정본이 자기모순이다. 실동작 피해는 현재 0(동봉 172 + 설치본 186 씬 전수에서 ltube 0건 · originb 0건 · controlpoint 0건, scene-lighting.md:724). 다만 tube 라이트를 배선하는 사람이 Core 쪽 주석만 보면 존재하지 않는 키를 근거로 삼는다. 렌더 레인은 반증을 적어 뒀는데 파스 레인은 그대로 남은 "반만 고쳤다" 형태다.
- 모집단: 동봉 WEAssets 172씬 + 설치본 wallpaper_engine 186씬 — ltube/originb/controlpoint 전건 0(출처: docs/re/scene-lighting.md:724 · Scene3DLighting.swift:230-232)
- 기지 대조: 선행 3감사와 docs/audit-r2-lanes 전체에서 `originb` grep 0건.

### 🟡 `Sources/WapleCore/SceneDocument.swift:567`
**텍스트 `depthtest` 도수 "enabled 1394건" 이 모집단 미표기이고 리포 정본(1391)과 어긋난다**
- 근거: 주석 두 자리가 같은 수를 쓴다 — :566-567 "실측 코퍼스는 문자열 \"enabled\"(1394건, 불리언 형태도 관용 파스)" 와 파스 자리 :2692-2693 "실측 문자열 \"enabled\"(1394건)". 둘 다 모집단 라벨이 없다.
리포 정본 조회(python): `spec/corpus/scene-schema.json` → `scene.objects.keysByType.text.depthtest` = `{"n": 1391, "scenes": 101, "types": {"str": 1391}, "values": {"enabled": 1391}}`. 같은 표를 9개 오브젝트 타입 전체로 돌려 `depthtest` 키를 가진 타입이 text 하나뿐이고 합계도 1391 임을 확인(image/particle/model/node/light/shape/sound/camera 에 그 키 없음).
`git log -S '1394건' -- Sources/WapleCore/SceneDocument.swift` → 2c0b21fe. 그 시점엔 `spec/corpus/scene-schema.json` 이 아직 없어 어느 모집단에서 나온 수인지 리포 안에서 재현 불가하다.
- 영향: 브리핑 규약(도수를 적으면 모집단 명시)을 어긴 자리이자, 리포가 스스로 "확정" 등급으로 두고 있는 정본과 3 차이가 나는 수치다. 파스 동작은 정상(문자열 "disabled" 만 false, 불리언 관용) — 손해는 정본 신뢰도뿐이다.
- 모집단: 워크샵 정본 코퍼스 spec/corpus/scene-schema.json — 텍스트 오브젝트 1,597 중 depthtest 저작 1,391(101씬)
- 기지 대조: 선행 3감사와 docs/audit-r2-lanes 에서 `1394`/`1391` grep 0건.

### 🟡 `Sources/WapleCore/PropertyAnimation.swift:358`
**`wrapLooped` 의 `- Note:` 가 "평가기는 backEnabled 를 게이트로 쓴다"고 적지만, 같은 날 커밋이 `segment()` 에서 그 게이트를 걷어냈다 — 같은 파일 100줄 위가 정반대를 적는다**
- 근거: grep -n "backEnabled|frontEnabled" Sources/WapleCore/PropertyAnimation.swift → segment()(:270-289) 에 두 심볼이 **0건**. 소비처는 wrapLooped(:376-391)와 파스(:620-629)뿐.
git show da26d8ad -- Sources/WapleCore/PropertyAnimation.swift | grep -n "backEnabled" → `-        let p2x = k2.backEnabled ? p3x + half * k2.backX : p3x` / `-        let p2y = k2.backEnabled ? p3y + k2.backY : p3y` (제거된 줄).
git log --oneline -S "Waple 의 평가기는 `backEnabled` 를 게이트로 쓰므로" -- … → be7a3c03(2026-08-21, 게이트 제거 **전**). 즉 be7a3c03 이 쓴 Note 를 da26d8ad(같은 날)가 무효화하고도 안 지웠다.
- 영향: 코드는 옳다(실물처럼 backX/backY 잔존값을 그대로 곡선에 쓴다). 거짓인 것은 주석이고, **같은 파일 :259-264 가 정확히 반대를 적는다** — "종전 구현은 반대로 파스에서 좌표를 담고 여기서 enabled 로 접었다 … 합성 반례에서 frame 31 값이 10.000000 ↔ 18.888773 으로 갈렸다". 두 Note 중 하나만 읽은 다음 사람은 wraploop 덮기 경로의 잔존 핸들이 무해하다고 믿고 그 자리를 되돌릴 수 있다.
- 기지 대조: r3 M1(:419 firedMarkers 대소문자) · O5(:680 events 통째 캐스트) · lane01(:765-771 relative as? Bool) 과 별건. docs/full-audit-2026-08-26.md:231 은 "wraploop 덮기 경로" 를 주석↔코드 일치 표본으로 **통과시켰다**(그 감사 시점 08-26 은 게이트 제거 뒤라 오판이다). docs/ 대조 결과 이 자리를 지목한 선행 감사 0건.

### 🟡 `Sources/WapleCore/ShaderPreprocessor.swift:147`
**`parseComboDefaults` CRLF 주석이 지목한 "정규화 밖 호출부" 둘 중 하나(`resolvePassCombos`)는 이미 이 함수를 부르지 않는다 — 같은 파일 15줄 위 주석과도 정면 모순**
- 근거: grep -rn "parseComboDefaults" Sources/ → 호출부는 ShaderPreprocessor.swift:68·:95 와 GLSLTranslator.swift:271 **셋뿐**. SceneRendererResources.swift 0건.
awk 'NR>=1084&&NR<=1230' Sources/WapleRender/SceneRendererResources.swift | grep -n frag → `frag` 소비는 `GLSLTranslator.samplerCombos(frag)`·`GLSLTranslator.formatComboSlots(frag)` 둘뿐이고, 그 둘은 sed -n '1462,1502p' Sources/WapleCore/GLSLTranslator.swift 대로 이미 `split(whereSeparator: { $0.isNewline })` 다(= 이 주석이 :149-150 에서 "형제는 이미 고쳤다" 고 적은 바로 그 함수들).
git log --oneline -S parseComboDefaults -- Sources/WapleRender/SceneRendererResources.swift → 58047c9d 가 넣고 1b0d20ab 가 뺐다(그 제거는 resolvePassCombos 자신의 주석 :1088-1094 에 적혀 있다).
덧붙은 줄번호 3자리도 전건 무효: `_translate`(:173 → 실제 265, parseComboDefaults 호출은 271) · `resolvePassCombos` 선언(:1042 → 1084) · 호출부(:784 → 813).
- 영향: 이 주석은 "왜 여태 안 터졌나 / 남은 구멍은 어디인가" 를 규정하는 자리다. 지금 남은 raw-소스 호출부는 `GLSLTranslator._translate` **하나**뿐인데 둘이라고 적고, 없어진 쪽에 줄번호까지 달아 둔다. 게다가 같은 파일 :132-133 은 "`Sources/WapleRender/**` 의 `ShaderPreprocessor` 참조 0건(2026-08-21 실측)" 이라고 정반대를 적는다 — 두 주석이 20줄 안에서 서로를 반증한다.
- 기지 대조: r2 lane04 F2 는 같은 파일의 `:638`(`:261`)·`:647`(`:401`) 두 자리만 다뤘다. M10/M54/O25 계통이지만 이 자리는 어느 선행 감사에도 없고, 여기 핵심은 줄번호가 아니라 **호출부 존재 자체가 거짓**이라는 점이다.

### 🟡 `Sources/WapleCore/ParticleSystem.swift:2391`
**CP 인덱스 클램프가 리포에 셋인데 32비트 절단은 하나만 한다 — `clampControlPoint` 이 형제 `clampIndex` 와 다른 CP 를 고른다(r3 M5 의 세 번째 자리)**
- 근거: 세 구현을 파이썬으로 1:1 이식해 같은 입력을 먹였다(실행 결과):
  입력 4294967299 → 엔진(`cmp eax,7`/`cmovb`, 부호 없는 **32비트**)=3 · ParticleControlPointFrame.clampIndex=3 · **ParticleSystem.clampControlPoint=7** · mapSeqClampCP=4294967299
  입력 4294967301 → 엔진=5 · clampIndex=5 · clampControlPoint=7 · mapSeqClampCP=4294967301
  입력 -1 / 8 / 3 에서는 셋 다 일치(7/7/3).
세 자리의 주석이 서로 어긋난다: ParticleSystem.swift:2378-2383 은 "부호 없는 비교라 음수도 7" 까지만 적고, ParticleControlPointFrame.swift:64-66 은 "엔진은 `ecx` 의 하위 32비트만 본다 — 그래서 **절단 뒤** 부호 없는 비교다" 라고 적는다.
- 영향: `clampControlPoint` 은 `controlpointattract` · `maintaindistancetocontrolpoint` · `vortex` · `vortex_v2` · `reducemovementnearcontrolpoint` · `maintaindistancebetweencontrolpoints` 여섯 자리의 CP 바인딩을 정한다(:2511 · :2533 · :2543 · :2573 · :2767 · :2776-2777). 파티클 `.json` 은 신뢰 경계 밖이고 `pint`=`strictInt` 가 2^32 이상 정수를 그대로 통과시키므로, 그런 저작에서 오퍼레이터가 실물과 **다른 CP** 를 target 으로 굽는다(크래시는 없다 — 결과가 0..7 안이라 `bakeControlPointTargets` 의 경계검사는 통과한다). 동봉·설치 코퍼스는 `controlpoint` 가 전건 소수라 도달 0.
- 기지 대조: r3 M5 는 같은 파일 `mapSeqClampCP`(:3474-3477) **한 자리**만 지목했다. `clampControlPoint`(:2391) 은 별개 함수이고 어느 선행 감사(AUDIT-FULL 3종 · docs/audit-r2-lanes/** · sweep/full-audit/swarm)에도 `clampControlPoint`/`clampIndex` 문자열 자체가 0건이다(grep 확인).

### 🟡 `Sources/Waple/Surfaces/Settings/SettingsView.swift:21`
**설정 창 높이 주석이 "섹션이 6개"라고 적고 그 위에 픽셀 실측을 쌓아 두는데, 실제 섹션은 7개다(재생정책 섹션이 열흘 뒤 추가되며 갱신 안 됨)**
- 근거: sed -n '52,60p' … → Form 안 섹션 **7개**(playback / playbackPolicy / playlist / video / system / desktopSync / assets).
git show 4977df2a:Sources/Waple/Surfaces/Settings/SettingsView.swift | sed -n '/var body/,/formStyle/p' → 그 주석을 쓴 커밋(4977df2a, 2026-08-17) 시점에는 정확히 **6개**였다.
git log -S playbackPolicySection -- … → a9f271bb(2026-08-27)가 7번째를 넣었다. 주석은 손대지 않았다.
- 영향: 주석이 든 수치가 전부 6섹션 기준이다 — "콘텐츠 약 953pt", "썸이 트랙의 약 86%(= 820/953)", "고정 높이를 걷어낸 뷰 → 창이 560×1028 로 열리고 6개 섹션이 전부 보인다"(:21·:26·:39). 7번째 섹션은 Picker 6 + Button 1 이라 콘텐츠가 눈에 띄게 더 길고, 그래서 "560×1028 이면 전부 보인다" 는 지금 거짓이다. 이 문단은 `.frame(minHeight:idealHeight:maxHeight:)` 선택과 AppDelegate 의 `contentMaxSize` 해제를 정당화하는 근거 문단이라, 다음에 창 크기를 다시 만지는 사람이 재측정 없이 이 수치를 믿는다.
- 기지 대조: r3 M23 은 같은 파일 `:150`(표시 라벨 중복의 근거 두 개) 만 다뤘다. `953`/`6개 섹션` 은 선행 감사 3종 + docs/audit-r2-lanes/** + docs/*.md 전수 grep 에서 0건.

### 🟡 `Sources/WapleCore/ParticleSystem.swift:2707`
**확장자 없는 `File:줄` 형 교차파일 인용 넷이 전부 무효 — `ParticleSimulator:1732`·`ParticleSimulator:305`·`WorkshopTabView:33`(두 자리)**
- 근거: grep -n "0..<max(1, octaves)" Sources/WapleCore/ParticleSimulator.swift → **2050**(주석은 `ParticleSimulator:1732`; 1732-1733 은 `case let .positionOffsetRandom(...)` 패턴 줄이다).
ParticleSystem.swift:3143 "부모 파티클 하나당 ParticleSimulator 를 통째로 하나씩 할당한다(ParticleSimulator:305)" → sed -n '300,310p' 는 `var mv/ang/sc/cc…` 지역변수 선언부다. 실제 할당은 `grep -n "ParticleSimulator(" …` → **504**, 자식 인스턴스 타입은 **246**(`private struct ChildInstance`).
grep -n ContentUnavailableView Sources/Waple/Surfaces/Workshop/WorkshopTabView.swift → **45**, **55**(인용은 `:33`). 인용 자리는 WallpaperGridView.swift:114 와 SelectionPanelView.swift:38 **두 곳**.
- 영향: 네 자리 다 "형제가 이미 이렇게 한다" 를 근거로 드는 자리다. 따라간 사람은 근거가 아니라 무관한 코드에 도착한다. `ParticleSimulator:1732` 은 특히 상한 32 를 고른 산근거("파티클마다 매 스텝 도는 루프")를 가리키므로, 그 루프가 어디인지 못 찾으면 상한을 되돌릴 수 있다.
- 기지 대조: r2 lane03 F5 가 같은 형태 4자리를 표로 올렸고 그중 하나가 `ParticleSystem.swift:2323 → ParticleSimulator:1437`(현재 :2327) 다. 여기 넷은 그 표에 **없다**. r3 M54 의 모집단은 `파일.swift:줄` 형이라 확장자 없는 이 형태를 안 세고, O25 는 "파일명 없는 **자기참조** :N" 이라 교차파일인 이 형태를 안 센다.

### 🟡 `Sources/WapleRender/VolumetricLightPass.swift:269`
**볼류메트릭 radius 경고 문구가 "배선하라"고 지시하는 인자는 같은 커밋에서 이미 배선돼 있다 — 태어날 때부터 거짓인 진단**
- 근거: 실제로 돌림. ① 경고 본문: `warnMissingRadiusOnce`(:264-270)가 "SceneRenderer3D 의 VolumetricLightParameters 생성에 `radius: light.radius` 를 배선할 것." 을 낸다. ② 그 배선은 존재한다 — `sed -n '2094,2107p' Sources/WapleRender/SceneRenderer3D.swift` → `:2106 radius: light.radius))`. ③ `grep -rn "volumetricLightPass\.encode" Sources/` → 호출부는 그 한 곳뿐. ④ 출생 시점 확인(브리핑 규약): `git log --oneline -S 'radius: light.radius' -- Sources/WapleRender/SceneRenderer3D.swift` → `7c66d460` / `git log --oneline -S '를 배선할 것' -- Sources/WapleRender/VolumetricLightPass.swift` → **같은 커밋 `7c66d460`**. 즉 드리프트가 아니라 한 커밋이 배선과 "배선하라" 를 동시에 넣었다. ⑤ 같은 파일 :92-97 의 [2026-08-21 정정] 문단은 이미 "호출부는 배선돼 있다 … 이 기본값 0 이 남아 있는 것은 씬이 radius 를 저작하지 않은 경우" 라고 정정해 놓고, 바로 그 문단이 가리키는 경고 문자열("encode 가 한 번만 경고한다")은 안 고쳤다 — 반만 고친 정정.
- 영향: 경고를 보는 개발자는 이미 있는 인자를 다시 배선하러 갔다가 아무 차이도 못 만들고, 진짜 원인(씬이 `radius<=0` 을 저작 → `hullRadius` 가 WE 생성자 기본 1.0 폴백 → 헐 0.99 로 사실상 비가시)을 못 본다. 발화 조건은 `light.radius <= 0`(:216) 이므로 PR #8 이 파스 기본값을 1.0 으로 올린 뒤로는 명시 저작 0/음수에서만 도달한다 — 화면 파손은 없고 진단 오도가 전부다.
- 모집단: castvolumetrics 도달: 설치본 assets/+projects/ 186 씬 중 0건(ScenePBRLighting.swift:645-652 실측 인용), 워크샵 코퍼스 162 씬 중 3씬/라이트 4개 — 워크샵 코퍼스는 이 머신에 없어 미측정
- 기지 대조: 선행 3종 대조: `lane06-3d-bloom.md` F6-4 는 같은 doc 블록의 **다른 문장**(`parseLight` 의 `?? 0` 인용이 PR #8 로 무효화된 것)을 다루며 `warnMissingRadiusOnce(:216)` 을 "파스 경로로는 도달 불가" 로만 언급하고, 경고 **문자열이 이미 배선된 수정을 요구한다**는 지적은 없다. `grep -rn "warnMissingRadius" AUDIT-FULL-2026-08-31*.md docs/audit-r2-lanes/*.md docs/sweep-2026-08-19.md docs/full-audit-2026-08-26.md docs/swarm-audit-2026-08-26.md` → 0건. M10(줄번호 드리프트)과도 다르다 — 여기는 줄번호가 아니라 배선 사실 주장이고, git log -S 로 출생 시점이 같은 커밋임을 확인했다.

### 🟡 `Sources/WapleCompatCore/DeepScan.swift:549`
**DeepScan 이 손포팅 7종을 번역 시도 없이 건너뛴다 — 렌더러는 translated 우선이라 스캐너가 다른 것을 검사한다**
- 근거: 코드: `if handPortNames.contains(eff.name) { agg.effectHandPort += 1; continue }`(:549-552, 주석 "stock effects Waple renders via hand-ported MSL"). 렌더러 실제 순서는 `SceneRendererResources.swift:336-348` — `buildTranslatedEffect` 가 먼저이고 `buildHandPortEffect` 는 `else if` 폴백이다(주석 :333-335 "폴터 체인(Step 5, 2026-07-02 실물 검증 후 전환): **translated 우선**"). 출생 대조: `git log -S 'if handPortNames.contains(eff.name)' -- .../DeepScan.swift` → 도입 커밋 `bdf99863`(2026-07-09). 그 트리를 직접 떠 보면(`git show bdf99863:Sources/WapleRender/SceneRendererResources.swift | grep -B6 -A6 'buildHandPortEffect(eff'`) 이미 :100-110 이 translated-우선 + 같은 주석이다 — 즉 **작성 시점부터 거짓**이다. 자산 실측: `for n in opacity tint pulse waterripple scroll waterwaves shake; do ls Sources/WapleRender/Resources/WEAssets/effects/$n; done` → 7/7 이 `shaders/` 보유(동봉 WEAssets 모집단) → 렌더러는 전건 번역 경로를 탄다. 도수: `AUDIT-FULL-2026-08-31.md:3229` 의 실제 --deep 실행 출력 "effect instances referenced by scenes: 24 · resolved via hand-port stock effect: 22" · 같은 블록 "GLSL translate: 6/6 (100.0%)".
- 영향: deep-compat 스캐너가 스톡 이펙트 7종에 대해 GLSL→MSL 번역·Metal 컴파일 경로를 **한 번도 태우지 않는다**. 그 감사가 "가장 넓은 실물 파이프라인 검증" 이라 부른 실행에서 이펙트 인스턴스 24 중 22(91.7%)가 hand-port 로 집계돼 translate 분모가 6 이 됐다 — "6/6 100%" 는 건너뛴 22를 제외한 분모다. 같은 파일 :555-560 이 "스캐너가 안 따라오면 렌더러가 실제로 컴파일하는 것과 다른 셰이더를 검사하는 오라클이 된다" 를 다른 축에서 이미 경고한다.
- 모집단: 동봉 WEAssets(scene.json 171 + gifscene.json 1 = 172씬) 기준으로 7종 전부 shaders/ 보유. 22/24 도수는 그 감사가 설치본 개발루트(defaultprojects 19 프로젝트 + assets)에서 돌린 실행. 워크샵 코퍼스는 이 머신에 없어 미측정.
- 기지 대조: AUDIT-FULL/r2/r3 · lane01~16 · sweep-2026-08-19 · full/swarm-2026-08-26 전수 grep(`scanEffects|translateAttempt|effectHandPort|resolved via hand-port`)에서 유일 히트는 AUDIT-FULL-2026-08-31.md:3229 의 리포트 출력(발견 아님). full-audit-2026-08-26.md:264 는 "hand-port **이름 집합**" 을 기각했는데 그건 다른 주장이고 나도 재확인했다(handPortNames 7종 == EffectShaders.frags 키 7종, 일치). lane11-compat.md:221 은 이 파일을 "PR #8 이 안 건드렸다 — 이번 라운드 재탐색 생략" 으로 명시 제외했다.

### 🟡 `Sources/WapleCompatCore/DeepScan.swift:911`
**DeepScan 주석이 "check_lenient_json_reach.py 의 WIRED 표에 이 파일이 없다" 고 적는데, 같은 커밋이 그 표에 넣었다**
- 근거: 주석 :911-913 "`check_lenient_json_reach.py` 의 `WIRED` 표에 **이 파일이 없다** — 그 게이트는 코어·렌더의 6파일만 세므로 … 항목 추가안은 보고서로 넘긴다". 실제 표: `scripts/spec/check_lenient_json_reach.py:56-73` 의 WIRED 는 **8항목**이고 `:68` 이 `"Sources/WapleCompatCore/DeepScan.swift": 5` 다. 하한 5도 만족한다 — `grep -n 'AssetJSON\.\(dictionary\|object\)(' Sources/WapleCompatCore/DeepScan.swift` → 602·683·689·693·916 = 5건. 출생 대조: `git log -S '"Sources/WapleCompatCore/DeepScan.swift": 5' -- scripts/spec/check_lenient_json_reach.py` 와 `git log -S 'WIRED` 표에 이 파일이 없다' -- Sources/WapleCompatCore/DeepScan.swift` 가 **둘 다 95a902e8**(2026-08-21)이고, `git show 95a902e8 -- scripts/spec/check_lenient_json_reach.py` 가 그 엔트리 추가 hunk 를 보여준다 — 같은 커밋이 표에 넣으면서 소스에는 "없다" 고 적었다.
- 영향: 정본 주석이 이미 닫힌 갭을 열린 것으로 서술하고 미완 작업("항목 추가안은 보고서로 넘긴다")을 광고한다. 다음 세션이 이 문장을 믿으면 이미 있는 엔트리를 다시 추가하거나, "게이트가 이 파일의 관용-파스 공백을 못 잡는다" 는 거짓 전제로 스캐너 회귀를 놓친다.
- 기지 대조: AUDIT-FULL/r2/r3 · lane 18 · sweep/full/swarm 전수 grep(`lenient_json|WIRED`) → 히트 2건 모두 AUDIT-FULL-2026-08-31.md:434-435 의 `check_cited_address_census.py` 배선 표로 무관. lane11-compat.md:221 이 이 파일을 재탐색 제외했다.

### 🟡 `Sources/WapleRender/SceneRendererFrameEncoder.swift:403`
**lane05 의 SceneRendererFrameEncoder 좌표-드리프트 열거가 불완전 — 미열거 5자리**
- 근거: lane05-render-core.md:163-171 이 이 파일에서 6자리를 열거한다(:405·:478·:1606·:2045·:2514·:2755). 전 줄 정독으로 **같은 부류 5자리를 추가 확인**했고, 각각 인용 대상 줄을 직접 떠서 대조했다:
· `:403` "isFrameBuffer 는 사전계산 불가, :1485" → `sed -n '1485p'` = `let scriptUpdateKeys = Set(...)`. 실제 자리는 `:2505` `if layer.effects.isEmpty || layer.isFrameBuffer { out.append(base); continue }`.
· `:839` "customLayerQuadInterleaved 는 … (SceneRenderer.swift:889)" → `sed -n '885,893p' SceneRenderer.swift` = AnimEventTimeline 블록. 실제 조립부는 `SceneRenderer.swift:2234`(`grep -n customLayerQuadInterleaved`).
· `:1221` "encodePointShadows:1271 도 같은 식으로 maximumLights*6 개를 만든다" → `grep -rn 'func encodePointShadows' Sources/` = `SceneRenderer3D.swift:1423`. 같은 파일 :1271 은 `nextRPD.depthAttachment.loadAction = .load`.
· `:2188` "F530-sweep: 이미지 레이어(:1450)와 동형" → `sed -n '1450p'` = `func pushLiveSceneLayers() {`. 실제 짝은 `:1924` `var mode = Int32(clamping: layer.colorBlendMode)`.
· `:2395` "ParticleSystem.sheetFrameIndex(:50) 의 Int.max 가드와 동형" → `grep -n 'func sheetFrameIndex' Sources/WapleCore/ParticleSystem.swift` = **:345**(Int.max 가드 :348). :50 은 `EventValueInput` 열거.
- 영향: lane05 의 목록은 수정자가 그대로 집어 드는 작업 목록이다. 6자리만 고치면 같은 파일에 5자리가 남고, "이 파일은 정리됐다" 는 오판이 붙는다. 다섯 자리 모두 근거를 따라가면 무관한 코드에 착지해 다음 독자를 오도한다.
- 기지 대조: lane05-render-code.md:163-171 목록과 겹치지 않음(직접 대조). 다섯 자리 문자열/좌표를 AUDIT-FULL 3종 · lane 18개 · sweep · full/swarm 에 전수 grep 해 무관 히트만 확인(`:403`은 sweep:481 의 다른 파일, `:1221`은 lane05:165 의 SceneRenderer.swift 자기인용, `encodePointShadows`는 lane06:204 의 다른 주제). 부류로는 기지 M10/r3-계통이다: `:403`·`:2188` 은 파일명 없는 자기참조라 **O25(82파일 416자리, 표본 1건만 검증) 모집단 안**이며 그 미검증분 중 2자리를 확정한 것이고, `:839`·`:2395` 는 교차파일 인용(M54 부류), `:1221` 은 함수명+줄 형태다. **출생 시점은 pickaxe 하지 않았으므로 '작성 시점부터 틀렸다' 를 주장하지 않는다** — 평범한 사후 드리프트로만 보고한다.

### 🟡 `Sources/WapleCore/AudioSpectrum.swift:295`
**AudioSpectrum 주석이 `binCount` 수정 뒤에도 옛 값(32 kHz → B=940)을 현재형으로 남겼다 — 같은 파일 20줄 위가 그 값을 폐기한 이유를 적고 있다**
- 근거: ① `binCount(fftLength:sampleRate:)`(:263-279)와 `engineFFTLength`/`engineTopFrequency`/`bandOfBin` 을 float32(struct.pack 'f') 충실 포팅해 python3 로 재계산했다. fftSize 는 유일 호출부 `SystemAudioSpectrumProvider.swift:46 private let fftSize = 2048` 고정이고 :176 이 실측 sampleRate 를 넘긴다.
   32 kHz → engineFFTLength=1920 · engineTopFrequency=10650.0 · B=**683**
   96 kHz → engineFFTLength=4179 · engineTopFrequency=14679.11 · B=**314**
   (상수 `topFrequency` 를 쓰면 32 kHz 에서 940 — 즉 940 은 **수정 전** 값이다.)
② `bandOfBin` 포팅으로 1:1 클램프 구간 길이를 재현: 622→30 · 623→29 · 627→29 · 640→29 · 683→**29** · 688→29 · 689→28 · 314→**37** · 940→26. 주석이 든 실측표는 전건 재현됐다.
③ `git log -S` 로 출생 특정: 문장은 `7b09975a`(2026-08-20, `binCount` 가 상수 `topFrequency` 를 쓰던 시절)에서 태어나 그때는 참이었다. 다음날 `badbe68f`(2026-08-21)가 `git show badbe68f -- Sources/WapleCore/AudioSpectrum.swift` 기준 `-  let raw = (topFrequency / binWidth).rounded()` → `+  let raw = (engineTopFrequency(sampleRate:) / binWidth).rounded()` 로 바꾸고 :272-275 에 "32 kHz 에서 상수를 쓰면 B=940 이 되어 … 64밴드가 통째로 밀린다" 를 새로 적었으면서 **:295 는 손대지 않았다.**
④ 잠그는 테스트 없음: `Tests/WapleCoreTests/AudioSpectrumWEParityTests.swift` 에 32000/940 grep 0건(:105-123 은 48 kHz 만 본다).
(빌드·테스트는 브리핑 금지대로 돌리지 않았다.)
- 영향: 실동작 파손은 없다 — 코드는 옳고 주석만 거짓이다. 영향은 두 가지다. (1) :295 가 :272-275 와 같은 파일 안에서 정면 모순한다(하나는 "940 이 되니 그래서 안 쓴다", 다른 하나는 "32 kHz 에서 B=940 이라 규약이 깨진다"). (2) 실제로는 32 kHz 에서 B=683 이라 하위 29밴드 1:1 규약이 **유지**되는데, 주석은 깨진다고 말한다 — 뒷사람이 32 kHz 레인을 예외 처리하려 들 근거가 된다. 같은 문장의 96 kHz(B=314 → 37) 절반은 지금도 참이라 통째로 거짓이 아니어서 더 안 잡힌다. PR #8 이전 커밋의 "반만 고친 수정" 부류다.
- 모집단: 해당 없음 — 코퍼스 도수가 아니라 산술(포팅 재계산)이다.
- 기지 대조: 선행 3종 + docs/ 전수에 `B=940`·`940` grep → AudioSpectrum 관련 0건(잡히는 940 은 전부 `2,940`(에셋 수)·`1927-1940`(줄 범위)). r3 M11 은 같은 파일 **:40**(48 kHz 밴드경계 이동 0.92빈)이고 이 문장과 다른 자리·다른 주장이다. r1 M20 은 구조체 오프셋 인용. lane07-media.md·lane14-docs.md 의 AudioSpectrum 항목도 :40 축과 게인 축뿐이다.

### 🟡 `Sources/WapleRender/Mesh3DShaders.swift:599`
**Mesh3DShaders 의 "이 주석을 따르는 형제" 열거가 **존재한 적 없는 `mf_skinned*`** 를 가리키고, 실제로 같은 블록을 복제한 `mf_refract`·`mf_reflect` 둘을 빠뜨렸다(출생 시점부터)**
- 근거: ① 현 파일의 fragment 함수는 `mf_main`(:544) · `mf_normal`(:624) · `mf_refract`(:735) · `mf_reflect`(:820) 넷과 `sf_cutout`(:140) · `f_spriteframe` 없음 — `grep -n "fragment float4"` 로 확인. `mf_skinned` 는 `grep -rn "mf_skinned" Sources/ Tests/ docs/ AUDIT-FULL-*.md` → **소스의 그 주석 한 줄 말고 0건**.
② 반구 앰비언트 블록(`mix(frame.skylight, frame.ambient, clamp(dot(N,(0,1,0))*0.5+0.5,0,1))`)은 실제로 **네 자리**에 복제돼 있다: :600-604(mf_main) · :715-719(mf_normal) · :794-798(mf_refract) · :873-877(mf_reflect). 주석이 이름 댄 둘 중 하나(`mf_normal`)만 맞고, 빠진 둘이 진짜 형제다.
③ 출생 특정(r3 §4.1 규약대로 파일 이력이 아니라 문자열 pickaxe): `git log --oneline -S'아래 mf_normal/mf_skinned* 의 같은 블록도' -- Sources/WapleRender/Mesh3DShaders.swift` → `f0fcc99c`(2026-08-21) 단일 커밋. 그 트리에서 `git show f0fcc99c:… | grep -n "fragment float4"` 하면 이미 `mf_main:538 · mf_normal:618 · mf_refract:729 · mf_reflect:814` 로 지금과 같은 넷이다 — 즉 **작성 시점에도 `mf_skinned*` 는 없었고 빠진 둘은 이미 있었다.** 사후 드리프트가 아니다.
- 영향: 실동작 영향 0(주석이다). 유지보수 영향은 실질적이다 — 이 주석은 WE `model_vertex_v1.h:207-210` 의 인자 순서(법선이 위면 `ambientcolor`, 아래면 `skylightcolor` — 이름 직관과 반대)를 설명하는 **단일 근거**이고, "아래 X/Y 의 같은 블록도 이 주석을 따른다"로 적용 범위를 스스로 선언한다. 그 선언이 없는 함수를 가리키고 있는 함수 둘을 빠뜨리므로, `mf_refract`/`mf_reflect` 의 `mix(skylight, ambient, …)` 를 "인자가 뒤바뀐 것 같다"고 정리하려는 다음 사람에게 근거가 연결되지 않는다. 네 사본을 묶는 유일한 실이 끊겨 있다.
- 기지 대조: 선행 3종 + `docs/audit-r2-lanes/`(lane06-3d-bloom · lane12-tests · r3-recover-render3d 포함) + sweep/full/swarm 문서 전수에 `mf_skinned` grep **0건**. r1 H5/r2 H1(라이트 forward 열) · r3 M39(cameraFrame.fov 세 번째 소비자)는 같은 파일군이지만 다른 자리·다른 주장이다. 이 파일의 WE 인용(common_pbr.h:6/9-16/23/36, common_pbr_2.h:263-266·277·284-311·294/305/342/353·317-363·355·361·372, model_vertex_v1.h:207-210, generic*.vert 4곳, generic4.frag:123/132/159/166)은 전건 재확인 결과 정확했다 — 무효한 것은 이 열거 하나다.

### 🟡 `Sources/WapleRender/VideoRenderer.swift:259`
**VideoRenderer 가림 옵저버의 `player?.rate != 0` 가드가 F840 절전 게이트를 뚫는다 — 형제 WebRenderer 는 그 가드가 없고 회귀 테스트까지 있다**
- 근거: **코드 트레이스만 — `swift build`/`swift test` 금지 조건이라 실행하지 않았다.**

결정적 경로(:256-262 옵저버 · :343 pause · :347-351 resume · :341 isEffectivelyPaused):
1. `pause()` → `pausedManually=true`, `player.pause()` → `rate == 0` (AVPlayer.pause() 가 rate 를 동기 0 으로 만든다는 가정에 의존).
2. 창 가림 알림 도착 → `if win.occlusionState.contains(.visible)` 거짓 → `else if self.player?.rate != 0` 에서 `0 != 0` 이 **거짓** → 블록 미실행. `pausedByOcclusion` 은 false 로 남고 `player.pause()` 도 안 불린다.
3. `resume()` → `pausedManually=false` → `guard !isEffectivelyPaused` 가 `false||false` 라 통과 → `player.play()`.
4. 옵저버는 occlusion **상태 변화**에만 뜨므로 자가 교정이 없다. 나중에 visible 로 돌아와도 `if self.pausedByOcclusion(=false)` 라 아무 일도 안 한다.

형제 대조:
- `Sources/WapleRender/WebRenderer.swift:811-816` `occlusionChanged(visible:)` 는 `guard pausedByOcclusion != occluded` 뿐, rate 가드가 없다 — 가림 상태 자체를 추적한다.
- `Tests/WapleRenderTests/WebRendererOcclusionTests.swift:51-56` 가 바로 이 순서(수동 pause → 가림 → 복귀 → resume)를 잠근다. `VideoRenderer` 에는 대응 테스트가 0건(`grep -rn "pausedByOcclusion" Tests/` → WebRendererOcclusionTests.swift:46 한 줄뿐).
- 문서화된 계약: `docs/history/plans/2026-07-14-web-hard-pause.md:16` "Manual resume while occluded must not resume JS, audio capture, or the media poller." VideaRenderer 의 F840 주석(:344-346)도 같은 취지를 적는데 구현이 절반이다.

**같은 파일이 스스로 이 신호를 못 믿는다고 적는다** — `:387-388`: *"순간 상태(`rate`)가 아니라 **의도**를 답한다 — `rate` 는 루프 이음매·seek 중에 0 을 스쳐서…"*. 그 논리대로면 가림 알림이 루프 이음매에 겹치면 **수동 pause 없이도** 게이트가 통째로 빠진다(경로 2 — 타이밍 의존이라 **미검증**, 부차적으로만 든다).
- 영향: 가려진 창에서 AVPlayer 가 계속 디코드한다(F840 이 명시한 절전 목적이 그 구간 동안 무효). 픽셀·오디오 오류는 없고 전력/발열만 손해라 medium 으로 둔다.

도달 범위는 정직하게 좁다: `applyPause`(AppDelegate.swift:1207-1220)가 resume 뒤 `policyPauseState.reset(); applyPlaybackPolicy()` 를 부르므로, 가리는 창이 maximized/fullscreen 이고 WE 기본 정책(둘 다 pause)이면 다음 정책 적용이 다시 멈춘다. 남는 실도달은 ① Space 전환으로 인한 가림 ② maximized/fullscreen 마스크에 안 걸리면서 창을 완전히 덮는 경우 ③ 사용자가 그 축을 run 으로 바꾼 경우. 그리고 위 2차 경로(루프 이음매)는 사용자 조작이 아예 필요 없다.
- 기지 대조: 선행 3종 + 16레인 + sweep/full/swarm 에 `pausedByOcclusion` **0건**(`grep -rc pausedByOcclusion AUDIT-FULL-2026-08-31{,-r2,-r3}.md docs/audit-r2-lanes/*.md docs/sweep-2026-08-19.md docs/full-audit-2026-08-26.md docs/swarm-audit-2026-08-26.md` → 합 0). `occlusion|가림|절전` 은 4파일에 8줄 있으나 전부 다른 자리다 — lane05-render-core.md:215-234 는 §3 에서 **SceneRenderer + AppDelegate pauseGate** 두 상태기계의 경합만 보고 "AppDelegate 자체의 상세 감사는 다른 레인 소관" 이라 명시하며 VideoRenderer/WebRenderer 옵저버는 다루지 않는다. lane07-media 는 이 파일의 음량/배속 축(L7-1)만, full-audit-2026-08-26:62 는 `isFinderDesktopHost`. r3 H1/M14 도 음량 축이다. 신규.

### 🟡 `Sources/WapleRender/TexDecoder.swift:258`
**TexDecoder r8 도수 "파티클 텍스처 60개 중 56개" 가 실측 164개 중 51개 — 두 수가 센서스의 다른 행에서 왔다**
- 근거: TEXV0005 헤더 offset 18 의 format i32 를 직접 파스(TexImage.swift:562 `i32(18)` 과 같은 규약). python3 로 동봉 `WEAssets/materials/particle/**/*.tex` 전수: 164파일 = {fmt0(lz4RGBA):56, fmt8(rg88):51, fmt9(r8):51, fmt4(bc3):6}. 설치본 `assets/materials/particle` 도 동일 164/{0:56,8:51,9:51,4:6}. 동봉 전체 .tex 311개의 fmt9 총수는 **60** 이고 그중 51 만 materials/particle 아래다(나머지 9 = materials/gradient 4 · materials/util/fur 1 · effects/{cloudmotion,shimmer×2,depthparallax} preview 마스크 4). 같은 수를 TexImage.swift:969 가 "동봉 311 + 설치 projects/ 129 = 440건: 0×257 · 4×72 · **9×60** · 8×51" 로 옳게 적고, 내 설치본 전수 계수가 그 네 값과 바이트 일치했다. 주석의 카테고리 목록 중 `rain` 은 두 코퍼스 어디에도 디렉터리로 없다(rain 파일은 water/·nature/ 에 산재). 스테일 아님: `git ls-tree -r <c> -- Sources/WapleRender/Resources/WEAssets` 로 출생 커밋 fb6da9db(2026-08-19, "r8 텍스처를 (v,v,v,v) 로 편다")에서도 materials/particle=164 · 전체=311.
- 영향: 수정 자체의 근거(r8 이 파티클에 흔하다 · (v,v,v,255) 가 알파 마스킹을 죽였다)는 유효하다 — shape/ 43개 중 39개가 r8. 다만 "93%가 r8" 로 읽히는 문장이 실제로는 31%(51/164)라, 이 도수를 인용해 다른 포맷의 우선순위를 정하면 어긋난다. 60 과 56 이 각각 '동봉 전체 r8 총수' 와 '같은 디렉터리의 lz4RGBA 수' 라 센서스 표의 행을 옮겨 적은 형태로 보인다.
- 모집단: 동봉 WEAssets/materials/particle 164 .tex (설치본 assets/materials/particle 사본도 동일) · 동봉 전체 .tex 311
- 기지 대조: AUDIT-FULL 3종 · AUDIT.md · BACKLOG.md · docs/**(history·re·audit-r2-lanes 포함 225개 .md) 전수에서 'ibuf' '60개 중 56' '56개가 r8' 0건. `TexDecoder.swift:228-282` 인용(docs/audit-fixplan-2026-08-20.md:240)은 채널 배치 주제로 무관, `:163` 인용은 REFRACT 주석 스테일 건.

### 🟡 `Sources/WapleRender/SceneRenderer3D.swift:17`
**GPU3DMesh 독트링 "ibuf 는 u16" — 실제는 u32. 폭을 넓힌 커밋이 드로우콜 4자리만 고치고 이 독트링은 안 고쳤다**
- 근거: `grep -n indexType Sources/WapleRender/SceneRenderer3D.swift` → :1587 :1896 :1955 :2045 전건 `.uint32`. `Model3D.swift:198 public let indices: [UInt32]`. 출생 대조(문자열 pickaxe): `git log -S 'ibuf 는 u16' ` → 4cb624c3(2026-07-03) 최초, 그 트리의 `SceneRenderer.swift:855` 는 `indexType: .uint16` 이라 **작성 시점엔 참**이었다. `git log -S 'indexType: .uint32'` · `git log -S 'public let indices: [UInt32]'` → 둘 다 c69f93ce("MDLV 인덱스 폭이 정점 수를 따르게 한다 — u32 메시 17개가 파괴 렌더 중이었다")에서 함께 바뀌었고 그 커밋이 이 독트링만 남겼다.
- 영향: 인덱스 버퍼 원소 폭은 `makeBuffer(length:)`·`indexType`·stride 계산의 계약이다. 구조체 헤더만 읽고 u16 으로 계산하면 길이가 2배 어긋난다. 실동작 파손은 없으나(코드는 전부 u32) '반만 고친 수정' 의 전형이고, 같은 커밋이 고친 다른 자리와 문서가 갈렸다.
- 기지 대조: AUDIT-FULL 3종 · docs 전수에 'ibuf' · 'u16' 0건. docs 의 `SceneRenderer3D.swift:N` 범위 인용 41자리 중 최소가 :105 라 :17 은 어느 범위에도 안 덮인다.

### 🟡 `Sources/WapleRender/SceneRenderer3D.swift:1180`
**builtinMeshShaderWhitelist 주석이 `shimmering_particles` 를 a_Normal 확장의 수혜자로 세는데 그 셰이더는 a_Normal 을 한 줄도 선언하지 않는다 (그리고 '8건' 인데 7개만 나열)**
- 근거: 주석: "저작레인 8건(`audiophile` · `demon_core` · `dna_fragment` · `fantasticcar` · `ricepod` · `techno` · `shimmering_particles`)은 pkg 안 셰이더라 게이트와 무관하게 수혜를 받는다" — 나열은 **7개**다. 설치본 실측(`grep -c 'attribute.*a_Normal'`): audiophile/{audiophile,grid}.vert · demon_core/core.vert · dna_fragment/dna.vert · fantasticcar/{car,grid}.vert · ricepod/ricepod.vert · techno/technohex.vert = 8파일 전건 a_Normal 선언 1. 반면 `projects/defaultprojects/shimmering_particles/shaders/particle.vert` 의 attribute 선언은 a_Position · a_TexCoordVec4 · a_Color · a_TexCoordVec4C1 · a_TexCoordC2 뿐이고 **a_Normal 0건**이다. 이 주석이 인용한 정본 `docs/re/shader-uniforms.md:1074-1076` 의 "저작레인 8건" 목록은 파일 8개를 나열하며 shimmering_particles 를 **뺀다**. 같은 문서 §7.7 "일부러 안 넣은 것 — `a_Color`·`a_Tangent4`·스키닝" 이 particle.vert 가 쓰는 attribute 를 명시적으로 제외 대상으로 못박는다. 출생 대조: `git log -S 'shimmering_particles' -- Sources/WapleRender/SceneRenderer3D.swift` → bdf7a4e4, 그 문서 목록(`git log -S '§7.6 이 센 저작레인 8건'`)도 **같은 커밋** → 작성 시점부터 코드 주석이 자기가 인용한 목록과 갈렸다.
- 영향: a_Normal 화이트리스트 확장의 도달 범위를 실제보다 넓게 서술한다. shimmering_particles 는 제외된 attribute만 쓰므로 이 변경 뒤에도 MSL 컴파일 실패 → 스톡 폴백이고, 그 셰이더가 여전히 폴백인 사실이 주석에 가려진다. 후속 라운드가 '이미 수혜 대상' 으로 보고 건너뛰게 된다.
- 모집단: 설치본 projects/defaultprojects 저작 .vert (동봉 WEAssets 에는 defaultprojects 셰이더가 없다)
- 기지 대조: AUDIT-FULL 3종 · docs 225개 .md 전수 grep 'shimmering_particles' → AUDIT-FULL-2026-08-31.md:2402 한 건뿐이고 그건 `particle.vert:98 mRotation = CAST3X3(1.0)` 로 무관. r3-recover-render3d.md 는 이 파일의 다른 자리(R-1 Mesh3DShaders:610 · lane06 F6-2)만 다룬다. 주: fantasticcar/car.vert 의 `a_Tangent4` 본문 참조는 `#if NORMALMAP` 안(car.vert:28-30)이라 조건부이므로 이 발견에서 제외했다.

### 🟡 `Sources/WapleCore/EffectManifest.swift:503`
**EffectManifest 가 같은 '동봉 effect.json' 모집단을 128 · 122 · 101 세 값으로 적는다 (셋 다 실재하지만 서로 다른 집합)**
- 근거: 실측: `find Sources/WapleRender/Resources/WEAssets -name effect.json | wc -l` = **128**, 설치본 135(합 263). python3 로 엄격 JSON 파스 실패 = **27**(1건 non-preview 트레일링 콤마 + 26 preview `//` 주석 — 주석 :504 의 분류와 정확히 일치), CRLF = 128/128. 파일 내부 세 표기: :28-29 "effect.json **128개**"(정확) / :503·:513·:517·:518 "**122개** 중 27개가 … 25/122 … 26/122 … 0/122" / :561 "동봉 자산 **101개** effect.json 의 최대가 한 자릿수". 122 = `WEAssets/effects/` 하위트리만 센 값이다(전체 128 − presets/fern·presets/lightshafts×3·scenes/particleelementpreviews×2 의 6파일). 101 = 128 − 27 = 엄격 파스 통과분이다. 어느 쪽도 라벨이 없다. 스테일 아님: `git ls-tree -r <c> -- .../WEAssets | grep -c 'effect\.json$'` 이 최초 동봉 4e882a9d(2026-07-31)부터 HEAD 까지 **전 구간 128 불변**, 122 출생 fafcd21a·f959e6e0 · 101 출생 1cd54384 시점도 전부 128.
- 영향: 같은 파일이 같은 이름의 모집단을 세 갈래로 적어 어느 수치가 규약인지 판별 불가. :561 의 101 은 `maxFBOs = 64` 상한의 근거이고 :503 의 122 는 관용 파서 도입의 근거라 둘 다 유지보수 판단에 인용된다. docs/re/material-blend.md:279 는 같은 코퍼스를 "effect.json **128개**" 로 옳게 적어 리포 내부 3중 불일치가 된다.
- 모집단: 동봉 WEAssets effect.json 128 · 설치본 wallpaper_engine effect.json 135 (합 263)
- 기지 대조: AUDIT-FULL 3종 · docs 전수에서 이 불일치를 결함으로 짚은 곳 0건. '122개' 를 인용만 한 곳 둘(docs/full-audit-2026-08-26.md:59 · docs/history/parity-sweep-2026-08-19.md:42)은 같은 수를 그대로 옮겼을 뿐이다. r3 O11(:541)은 bind/fbos 배열 캐스트 건으로 무관, `EffectManifest.swift:7-88` 인용(docs/re/shader-combos.md:551)은 conditions 평가기 규약 건.

### 🟡 `Sources/WapleCore/WebCompatPatch.swift:151`
**WebCompatPatch 의 근거 진술 둘이 동봉 zcompat 자산에 반증된다 — '동봉 5건 전부 소문자' 와 'needle 최대 63바이트'**
- 근거: 동봉 `WEAssets/zcompat/web/*.json` 5파일 · 액션 17개 전수 파스(python3). ① :151-152 "소문자화 … 동봉 5건은 전부 소문자라 이 선택으로 달라지는 항목은 없다" → 4개 파일(780658164 · 780662613 · 780675904 · 854685299)의 액션 `file` 이 `index_files/index.min.js.**D**ownload` 로 대문자 D 를 포함한다(17액션 중 4). 같은 리포의 `docs/re/web-wallpaper-bridge.md:161`·`:172` 가 그 경로를 대문자 그대로 표로 기록한다. ② :193 "needle 이 짧고(**동봉 최대 63바이트**)" → 실측 최대 **68바이트**(784979889.json 의 `renderer = new THREE.WebGLRenderer({alpha: true, antialias: true });`). 자산 불변 확인: `git log --oneline -- Sources/WapleRender/Resources/WEAssets/zcompat/` → 커밋 1건(4e882a9d, 최초 동봉)뿐. 확인된 참: :56 "전건 `/` 구분자" ✅ · :167-168 "5건 중 4건이 texImage2D 형태" ✅(파일 4/5 · 액션 16/17).
- 영향: ①은 소문자화 규약의 무영향 논증을 무너뜨린다 — 실제로는 그 대문자 때문에 소문자화가 필요하고(코드는 양쪽을 정규화하므로 동작은 정상), '동봉엔 영향 없음' 을 믿고 정규화를 걷어내면 4개 워크샵 항목의 패치가 조용히 안 걸린다. ②는 스캔 비용 논증의 상한이 실제보다 작다. 출생 시점은 주장하지 않는다 — 자산이 불변이라 현행 거짓만 확정했다.
- 모집단: 동봉 WEAssets/zcompat/web 5 JSON · 액션 17
- 기지 대조: AUDIT-FULL 3종 · AUDIT.md · BACKLOG.md · docs 225개 .md 전수에서 '63바이트' '전부 소문자' 0건, `WebCompatPatch.swift:` 범위 인용은 lane07-media.md:173 의 `:123-126`(sanitizedProjectID) 한 자리뿐. **docs/full-audit-2026-08-26.md:235 가 이 파일을 "주석의 산식·근거와 구현이 일치했다" 로 닫았으므로 그 판정의 반례다.**

### 🟡 `Sources/WapleRender/BaseAssetsSettings.swift:6`
**BaseAssetsSettings 타입 헤더가 '앱이 기본 에셋 팩을 번들하지 않으므로 사용자가 지정해야 한다' 고 적는데 같은 파일이 동봉 폴백을 구현한다**
- 근거: 헤더 :6 "기본 nil — 앱이 기본 에셋 팩을 번들하지 않으므로(공개 배포 + 저작권), 사용자가 지정해야 한다." ↔ 같은 파일 :49-50 "앱 번들에 동봉된 WE 2.8.42 공유 에셋. 해석 순서상 마지막 폴백이다" · :60-83 `bundledAssetsDirectory` · :91-99 `searchRoots` 가 항상 동봉본을 덧붙임. 실물 동봉량 실측: `Sources/WapleRender/Resources/WEAssets` 에 .tex 311 · *.json 1,698 · effect.json 128. 출생 대조(pickaxe): `git log -S '앱이 기본 에셋 팩을 번들하지 않으므로'` → 4600bd44(원 기능 커밋, 동봉 이전), 동봉은 4e882a9d(2026-07-31) · 배선은 2a3a3385 → **사후 드리프트**(작성 시점엔 참).
- 영향: 타입 헤더만 읽으면 '동봉 폴백 없음 · 사용자 지정 필수' 로 오독한다. 실제로는 AppDelegate:205-218 이 동봉본을 포함한 roots 를 세고 "유효 N/M" 을 찍으며, 사용자가 아무것도 지정하지 않아도 씬이 그려진다. M22(이미 고쳐진 결함을 현재형으로 적은 주석)와 같은 계통.
- 기지 대조: r3 M36 은 `:8`(UserDefaults 주입 시임) · O20 은 `:17`(게터/세터 비역) 로 다른 자리. AUDIT-FULL-2026-08-31.md:346 과 lane04-glsl.md:125-129 는 searchRoots 의 동봉 폴백을 정확히 서술하면서도 이 헤더 모순은 안 짚었다. docs 전수 '번들하지 않' 0건. `BaseAssetsSettings.swift:7-29` 인용은 2026-07-14 plan 파일의 수정 대상 목록(감사 발견 아님).

### 🟡 `Sources/WapleRender/SceneRendererResources.swift:848`
**출력 패스 가드를 `command:"swap"` 패스가 무력화한다 — 형제 라우터는 명시 제외하는데 가드만 안 한다**
- 근거: (1) 읽기: `:848 guard passes.contains(where: { $0.target == nil }) else { return nil }` 주석 `:847` = "출력(타깃 없는 패스)이 하나도 없으면 화면에 아무것도 못 쓴다 → 폴백". `makeSwapPass`(:955-968)가 만드는 TranslatedPass 는 `target: nil, swapPair: (src,tgt)` 다.
(2) 형제: `grep -rn 'target == nil|\.target != nil' Sources/WapleRender/*.swift` → 소비처 2곳. `EffectChainRouting.plan:2648` 은 `passes.filter { !$0.hasFBOTarget && !$0.isSwap }.count` 이고 :2647 주석이 "swap 패스도 target == nil 이라(makeSwapPass) 반드시 제외한다" 라고 명시. :848 에는 그 제외가 없다.
(3) 순서: `git log --oneline -S '출력(타깃 없는 패스)이 하나도 없으면' -- .../SceneRendererResources.swift` → 3143368a(갓클래스 3분할). `git log --oneline -S 'makeSwapPass' -- 같은 파일` → 93faaa00 · 919e1a82. 가드가 swap 도입보다 앞선다(미개정 형제).
(4) dst 미클리어 확인: `applyEffect` handPort 갈래는 `:2547 loadAction = .clear` 인데 translated 갈래(:2567-)에는 dst 클리어가 없고, dst 를 주는 `pooledOffscreen`(FrameEncoder:367-392)은 체크아웃 경로(:378-382)에서 기존 텍스처를 그대로 돌려준다(클리어 없음).
(5) 도달 실측: 동봉 effect.json 전수 파스(python, 트레일링 콤마 허용) → 128건 중 `command:"swap"` 보유 2건(effects/fluidsimulation + 그 preview 사본)이고 둘 다 패스 17(fluidsimulation_combine)이 `target=null` 인 진짜 출력 패스라 현 도달 0.
- 영향: 셰이더 패스가 전부 이름 있는 fbo 를 타깃으로 하고 swap 패스가 하나라도 있는 매니페스트(저작 오류, 또는 X-⑪ `conditions` 가 유일한 출력 패스를 :785-788 에서 걷어낸 경우)에서 가드가 뚫린다. 그러면 `EffectChainRouting.plan` 의 `outputTotal` 이 0 이라 어떤 라우트도 `.output` 이 되지 않고, dst 로 지정된 풀 텍스처에 아무 패스도 그리지 않은 채 체인이 끝난다. dst 는 클리어되지 않으므로 그 프레임의 레이어에 풀 이전 사용자의 내용이 그대로 합성된다(= 조용한 오답). 가드의 존재 이유가 정확히 이 상황을 막는 것이므로 게이트 무력화다.
- 모집단: 동봉 effect.json 128건(그중 swap 보유 2건)
- 기지 대조: AUDIT-FULL-2026-08-31 / -r2 / -r3 색인 · docs/audit-r2-lanes/ 18개(lane05·lane06·lane07 포함) · sweep-2026-08-19 · full-audit-2026-08-26 · swarm-audit-2026-08-26 · r3 §4.1 기각표 전부 grep(`makeSwapPass`, `848`, `swap.*가드/패스`) → 0건. docs/re/fluid-simulation.md:1214-1215·1837 은 swap 지원 사실만 적고 이 가드를 언급하지 않는다.

### 🟡 `Sources/Waple/Shell/LibrarySection.swift:43`
**`LibrarySection` 의 "쓰기 주체가 둘" 근거가 UI 개편으로 거짓이 됐고, 그 결과 `selection(for:)` 의 nil 분기 셋이 프로덕션 도달 불가가 됐다**
- 근거: (1) 문면 `:40-48`: "사이드바만 필터를 쓰는 게 아니다. 툴바 필터(종전 `FilterSidebarView`)도 같은 `criteria.types`·`favoritesOnly` 를 쓴다 … 그래서 선택은 저장하지 않고 상태에서 매번 유도한다".
(2) 실측 `grep -rn 'criteria\.types|favoritesOnly' Sources Tests` → 프로덕션 쓰기는 `LibrarySection.applying:73-74` 한 곳뿐. 후속 툴바 필터 `FilterPopover` 는 `tags`/`ratings` 만 쓴다(:75-76, :94-95)이고, 그 파일 자신의 :9-16 이 "유형과 즐겨찾기는 사이드바 항목으로 승격했다" 고 적는다.
(3) 출생 pickaxe `git log --oneline -S '툴바 필터(종전 `FilterSidebarView`)도 같은' -- Sources/Waple/Shell/LibrarySection.swift` → 79d2a81d(2026-08-17). 그 트리의 `git show 79d2a81d:Sources/Waple/Surfaces/Installed/FilterSidebarView.swift | grep -n 'types|favoritesOnly'` → `:11 Toggle("즐겨찾기만", isOn: $viewModel.criteria.favoritesOnly)` · `:18 Toggle(t.label, isOn: binding(for: t, in: \.types))` — 작성 시점엔 참이었다.
(4) `git log --oneline --diff-filter=D -- .../FilterSidebarView.swift` → fed99448 "필터 사이드바를 툴바 팝오버로 대체한다"(2026-08-17)가 그 쓰기 주체를 삭제하면서 이 근거는 갱신되지 않았다.
(5) 귀결 확인: `types(for:)`(:103-110)는 `[]`/단원소만 낸다 → `selection(for:)` 의 `:89`(favoritesOnly + 비어있지 않은 types), `:93`(types.count != 1), `:99`(`.all` 이 집합에 들어옴) 세 nil 분기 전부 프로덕션 도달 불가. 직접 주입해 타는 곳은 `Tests/WapleAppTests/ShellNavigationTests.swift:108,127,134` 뿐이다. `Sources/Waple/Shell/SidebarView.swift:56-59` 는 단일 선택 `List(selection:)` 태그라 다중 유형 상태 자체를 만들 수 없다.
- 영향: 유도(derive) 설계를 정당화하는 유일한 근거가 사실이 아니게 됐다 — 지금은 쓰기 주체가 하나뿐이라 "화면이 거짓말한다"는 위험 자체가 없다. 다음 사람이 이 주석을 신뢰해 두 방향 동기화를 유지·확장하거나, 반대로 nil 분기를 살아 있는 방어로 오인한다. 같은 개편이 남긴 자매 잔재 둘도 함께 죽었다: `Sources/Waple/LibraryFiltering.swift:65` 의 "감사 V07 전체 선택 = 무필터" superset 단축(도입 1148e2eb 2026-07-26 — 당시엔 3종 토글로 도달 가능)과, `Tests/WapleAppTests/AppUIV07RegressionTests.swift:17` 의 "사이드바 유형 토글은 scene/video/web 3종" 이라는 서술(그런 토글은 더 이상 없다).
- 기지 대조: AUDIT-FULL 3종 색인 · docs/audit-r2-lanes/ 전 18파일 · sweep-2026-08-19 · full-audit-2026-08-26 · swarm-audit-2026-08-26 · r3 §4.1 기각표에 `LibrarySection`/`FilterPopover`/`criteria.types` 문자열 0건. r3 M24(`LibraryFiltering.swift:47` 폴더 선택 시 태그·등급 무필터 붕괴)는 같은 파일의 **다른** 줄·다른 기전이라 별건.

### 🟡 `Sources/Waple/Surfaces/Workshop/WorkshopTabView.swift:27`
**`loadMore` 실패 인용 `:174-176` 이 지금은 정반대로 동작하는 블록(`search()` 의 catch)을 가리킨다**
- 근거: (1) 문면 `:26-27`: "캡션 자체는 남긴다: `loadMore` 실패(:174-176)는 `searchFailed` 를 안 세우고 `results` 도 안 비우므로 그 분기가 캡션의 존재 이유다."
(2) `sed -n '167,203p' Sources/Waple/Surfaces/Workshop/WorkshopViewModel.swift` → `:174-176` 은 `search()` 의 catch 꼬리(`?? String(format: NSLocalizedString("검색 실패: %@"…)` / `error.localizedDescription)` / `}`)이고, 그 블록은 바로 위 `:171 results = []` · `:172 searchFailed = true` 를 실행하는 블록이다 — 주석의 주장과 정확히 반대다. `loadMore` 는 `:180` 에서 시작하고 그 실패 처리는 `:196-202`(핵심 `:199-201`)다.
(3) 출생 pickaxe `git log --oneline -S '`loadMore` 실패(:174-176)' -- .../WorkshopTabView.swift` → 03006e46. 그 트리에서 `git show 03006e46:.../WorkshopViewModel.swift | sed -n '165,205p'` 로 세면 :174-176 은 `loadMore` 안의 `// page 는 append 가…` 주석 두 줄 + `let nextPage = page + 1` 이고 catch 는 :185-191 이었다 — 출생 시에도 실패 처리 블록을 가리키지 않았다(다만 최소한 `loadMore` 안이기는 했다).
- 영향: 인용을 따라간 사람이 `search()` 의 실패 처리에 도착해 "searchFailed 를 세우고 results 를 비운다"는 정반대 사실을 보게 된다. 주석의 결론(loadMore 실패는 `searchFailed`/`results` 를 건드리지 않아 `:28` 캡션 분기가 필요하다)은 실제 `:197-201` 로 여전히 참이므로 코드 결함은 아니고, 좌표만 무효다. 이 캡션 분기는 `vm.searchFailed` 가 거짓인 상태의 유일한 오류 표면이라 근거가 흐려지면 다음 정리에서 통째로 지워질 위험이 있다.
- 기지 대조: AUDIT-FULL 3종 · docs/audit-r2-lanes/ 전체 · sweep · full-audit · swarm · r3 §4.1 에 `WorkshopTabView`/`loadMore` 0건. r3 M10 계통(주석 자기 인용 드리프트)과 같은 부류이나 좌표·파일이 기지 목록 어디에도 없다.

### 🟡 `Sources/WapleCore/GLSLTranslator.swift:174`
**"정확일치 조회 자리가 둘" 이라는 도수가 실제로는 넷 — 콤보 키 접기 수정이 같은 게이트 3자리 중 1자리에만 걸렸다**
- 근거: (1) 문면 `GLSLTranslator.swift:173-176`: "다만 렌더 계층에는 반환 딕셔너리를 **정확일치로 조회**하는 자리가 **둘** 남아 있어, 이 함수를 `public` 으로 노출해 렌더 계층이 **딕셔너리별로** 접게 하는 것이 정본이다". 짝 주석 `SceneRendererResources.swift:1106-1116` 이 그 둘을 ①`combos["DIRECTDRAW"] == 1` ②`samplerCombos`/`formatComboSlots` 게이트로 열거하고, 접기는 `:1117-1119`(`uppercasedComboKeys(matCombos)` + `uppercasedComboKeys(scenePass.combos)`)에만 적용됐다.
(2) 실측 `grep -n 'samplerCombos|formatComboSlots|uppercasedComboKeys' Sources/WapleRender/*.swift Sources/WapleCore/*.swift` → 같은 모양의 `samplerCombos(frag) where combos[comboName] == nil` 게이트가 **세 곳**이다: `SceneRendererResources.swift:1120`(접힌 dict) · `SceneRendererResources.swift:1818` `buildCustomLayerShader`(`var combos = layer.materialCombos` — 미접기) · `SceneRenderer3D.swift:1221` `buildCustomMeshShader`(`var combos = mat.customCombos` — 미접기). 두 census 어디에도 뒤 두 자리가 없다.
(3) 발산 조건(코드 추적): 저작 키가 소문자이고 값이 0 이며 그 슬롯에 텍스처가 바인드된 경우 — 접힌 쪽은 `combos["X"] = 0` 을 보고 게이트를 건너뛰어 0 을 유지하지만, 미접힌 쪽은 `combos["x"]=0` 뿐이라 게이트가 nil 을 보고 `combos["X"]=1` 을 심는다. 그 뒤 `translate:187 uppercasedComboKeys` 의 충돌 규약(:207-212 대문자 우선)에서 1 이 이겨 저작자가 끈 콤보가 켜진다.
(4) 모집단 실측(python, 동봉 `Sources/WapleRender/Resources/WEAssets/**/*.json` 재귀 + 트레일링 콤마 허용): 1,671 파일 파스 성공 / 27 실패. 모든 `combos` 딕셔너리에서 키 출현 200회·48종, 그중 비-대문자는 3종뿐(`version` 6 · `vertexcolor` 2 · `spritesheet` 1)이고 **값이 0 인 것은 0건** → 동봉 코퍼스 도달 0.
- 영향: 소스 주석이 코드베이스에 대해 선언한 도수("둘")가 거짓이라, 이 규약을 이어받는 사람이 두 자리만 확인하고 끝낸다. 실제 동작 발산은 저작 키 소문자 + 값 0 + 슬롯 바인드가 겹칠 때이고 동봉 코퍼스 도달은 0 이다(워크샵 코퍼스는 이 머신에 없어 미측정 — `docs/history/parity-sweep-2026-08-19.md:123` 이 별도 모집단에서 "콤보 저작 46/61 소문자" 를 적어 두었으므로 워크샵 쪽 도달은 열려 있다고 봐야 한다).
- 모집단: 동봉 WEAssets JSON 1,671 파스 성공 / 27 파스 실패 · combos 키 200회·48종
- 기지 대조: AUDIT-FULL 3종 색인(r3 M7/M8 은 같은 파일이지만 각각 `:2134` 캡처 파라미터 타입 사다리와 `GLSLTypeAdapter:568` shim 인용이라 별건) · docs/audit-r2-lanes/lane04-glsl.md 전문 · sweep-2026-08-19 · full-audit · swarm · r3 §4.1 에 `uppercasedComboKeys`/`buildCustomLayerShader`/`buildCustomMeshShader`/`1818` 0건. docs/re/shader-combos.md §969-991(G3 착지)은 번역기 진입 접기만 적고 렌더 계층 게이트 census 를 다루지 않는다.

### ⚪ `Sources/WapleLibrary/ZipImporter.swift:62`
**ZipImporter: `terminationHandler` 를 `p.run()` 이후에 설치한다 — 그 사이에 끝난 프로세스는 300초 타임아웃 오탐이 될 수 있다**
- 근거: `dittoExtract`(:47-56)가 `try p.run()`(:53) 을 먼저 하고 `waitForExitOrKill`(:54) 안에서야 `p.terminationHandler = { _ in exited.signal() }`(:62) 을 건다. 핸들러 설치 전에 ditto 가 종료하면 세마포어가 영영 신호를 못 받고 `exited.wait(timeout: .now() + 300)` 가 `.timedOut` 을 돌려 SIGTERM → SIGKILL → `ZipImportError.extractionTimedOut` 로 간다. 코드 독해만 했고 재현은 돌리지 않았다(레이스 창이 마이크로초 단위 · 이 라운드는 빌드/테스트 금지).
- 영향: 발동하면 정상 zip 가져오기가 5분 멈춘 뒤 "해제 타임아웃" 으로 실패하고, 직렬 importQueue 가 그동안 막힌다. 창이 아주 좁아 실사용 발현 가능성은 낮다고 본다 — 확정하지 못했으므로 observation 이다. 고치려면 `run()` 전에 핸들러를 걸거나 설치 직후 `p.isRunning` 을 한 번 확인하면 된다.
- 기지 대조: 선행 3감사에서 `waitForExitOrKill`/`terminationHandler` grep 0건. V06 이 만든 타임아웃 자체는 기지이나 이 설치 순서는 언급 없음.

### ⚪ `Sources/WapleLibrary/PlaylistStore.swift:20`
**PlaylistStore: intervalMinutes 는 세터만 `max(1,·)` 클램프이고 디코드 경로엔 클램프가 없다**
- 근거: 세터 `set { model.intervalMinutes = max(1, newValue) }`(:48) 과 커스텀 디코더 `intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 30`(:20) 의 비대칭. 손으로 `{"intervalMinutes": 0}` 을 넣은 playlist.json 은 0 그대로 살아 소비처로 나간다. 도달(그런 파일이 실제로 생기는 경로)은 재지 않았다.
- 영향: 영속 파일을 직접 편집하지 않는 한 발생하지 않으므로 실사용 위험은 낮다. 다만 "입력 정규화는 한 자리" 규약이 절반만 지켜진 형태라, 소비처가 0/음수 간격을 가정하지 않는다면 잠복 위험이다.
- 기지 대조: 선행 3감사에서 PlaylistStore 관련 항목 없음.

### ⚪ `Sources/WapleRender/OggVorbis/VorbisCodebook.swift:102`
**Vorbis 코드북 F840 패킷-크기 게이트가 `multiplicands` 만 덮는다 — lookup_type 1 의 `vqFlat`(최대 67MB)은 패킷 크기와 무관하게 할당된다**
- 근거: 파이썬으로 가드 전부를 산술 재현했다(실행 결과, 빌드 금지라 실행 검증은 못 했다):
  entries=2^20 · dimensions=16 → :52 가드 `entries <= 1<<20` ✔ · `dimensions*entries <= 1<<24`(=16777216) ✔ (둘 다 등호로 통과)
  ordered 분기(:68-82): `currentLength=20`, `bits=ilog(2^20)=21`, `number=2^20` 한 번으로 전 엔트리를 길이 20 으로 채운다 → 길이 섹션이 수십 비트
  buildTrie: 완전 이진트리 노드 2^21-1 = 2,097,151 < 캡 `1<<21`(2,097,152) → **정확히 통과**(Int32 3배열 ≈ 25.2MB)
  lookup1Values(2^20,16)=2 → multiplicands 는 Double 2개(16바이트)라 :102 가드를 자명하게 통과
  reconstructVQ(:203) `out = [Float](count: entries*dimensions)` = 16,777,216 Float = **67.1MB**, 루프 16.7M 회
소비 경로: SceneAudioPlayer.swift:251 `OggVorbisDecoder.decode(raw)` — 씬 패키지 동봉 ogg(워크샵 = 신뢰 경계 밖).
- 영향: F840 주석(:97-100)은 "남은 비트로 lookupValues×valueBits 를 채울 수 없으면 어차피 EOP 이므로 지금 거절한다" 로 할당 폭발을 닫았다고 선언하는데, 그 게이트가 묶는 것은 `multiplicands` 뿐이다. 형제 lookup_type 2 는 `lookupValues == entries*dimensions` 라 우연히 vqFlat 까지 패킷에 묶이지만, lookup_type 1 은 `lookupValues` 가 작아 vqFlat 이 풀린다. VorbisDecoder.swift:158 의 `totalCells <= 1<<24` 총량 캡이 상한을 ~67MB 로 막아 주므로 무한은 아니다 — 다만 그 캡은 **코드북을 다 만든 뒤** 검사하고, 트라이 노드는 세지 않아 코드북 16개면 트라이만 ~400MB 다.
- 기지 대조: 선행 감사 3종 + docs/audit-r2-lanes/** 에 `VorbisCodebook` 문자열 0건. docs/full-audit-2026-08-26.md:248 은 정반대로 "Ogg/Vorbis 비트·코드북 파서의 DoS 가드·OOB 방어가 일관되게 방어되어 있다" 로 통과시켰다 — 이 관찰은 그 판정의 반례 후보다. 미확정으로 두는 이유: 빌드·실행이 금지라 실제 할당·소요시간을 재지 못했고, 총량 캡 때문에 무한이 아니다.

### ⚪ `Sources/WapleCore/ParticleSystem.swift:3140`
**파일명 없는 자기참조 `:N` 인용 8자리가 전부 무효(두 파일)**
- 근거: 각 자리를 sed 로 펼쳐 대조했다.
  ParticleSystem.swift:3140 "루트 maxCount 와 같은 상한을 건다(**:1032-1037**)" → 1032-1037 은 RemapSpec.flags 주입기 x86 서술. 실제 루트 상한은 :3103-3120.
  :3445 "상한 포화는 sheetFrameIndex(**:52**)와 동형" → :52 는 `EventValueInput.init?(weName:)`. `grep -n "func sheetFrameIndex"` → **345**.
  :1376 "파티클 규약은 문자열 스칼라 거부·언랩 없음(**:1115** 헬퍼 주석)" → 1113-1117 은 `RemapSpec.component` 계산 프로퍼티. 헬퍼 주석은 :3367.
  :2461 "movement(위 **497-498행**)의 선형 drag 와 대칭" → 497-498 은 vortex xmm2 서술. `case "movement"` 는 :2424.
  :439 "선형 movement(위 **61행**)와 대칭인 drag" → :61 은 `case "multiplycoloropacity"`. `case movement` 는 :433.
  ShaderPreprocessor.swift:100 "조건부 평가 전에 include 를 무조건 인라인하므로(위 **line 19**)" → :19 는 engineDirectives 배열 리터럴. 인라인은 :69.
  :144 "`preprocessStrict`(**:20-22**)가 자기 입력만 CRLF 정규화" → preprocessStrict 는 :33-97.
  :393 "GLSLTranslator 는 파스된 선언·함수만 조립해 방출한다 — **:2059**" → GLSLTranslator.swift:2059 는 헬퍼 캡처 수집 루프. MSL 조립·반환은 :632-641.
- 영향: 전부 "이 판단의 근거는 저기 있다" 를 가리키는 자리다. 개별 영향은 작지만 밀도가 높고(두 파일에 8자리), 이 리포의 주석이 근거를 줄로 다는 관행 위에 얹혀 있어 다음 라운드가 그대로 다시 밟는다.
- 기지 대조: r3 O25("파일명 없는 자기참조 :N 인용이 82파일 416자리 — 표본 1건 무효 확인, **나머지 414 미검증**")의 모집단 안이다. 새 부류가 아니라 그 414 중 8자리를 실제로 펼쳐 무효를 확정한 것이라 observation 으로 내린다. r2 lane04 F2 가 같은 파일의 `:261`·`:401` 을 이미 다뤘고 여기 8자리는 그와 겹치지 않는다.

### ⚪ `Sources/WapleRender/SceneRenderer.swift:2739`
**captureFrames 의 라이브 상태 save/restore 집합이 encodeDrawPlan 이 실제로 변이시키는 상태보다 좁다 — lane05 가 "문제없음" 으로 센 5항목 밖이 통째로 빠져 있다**
- 근거: 코드 경로 정독(재현 실행 안 함 — `swift build`/`swift test` 금지). 저장·복원 대상은 다섯뿐이다: `pointerTargets`/`hoverTargets`/`pendingInteractionGeometry`(:2739-2748, `preserveLiveInteraction` 게이트) + `parallaxFocus`/`parallaxPosition`(:2750-2757). 3D 가지는 sim/`particle3DClock` 도 되돌린다(:2764-2773, 감사 I1). 그러나 캡처 루프가 지나며 변이시키는 나머지 인스턴스 상태는 되돌리지 않는다 — `particleScriptVisible(_:time:)`(:2841)이 쓰는 `scriptParticleVisible`·`scriptParticleEmissionPaused`, `encodeLayer`/`encodeText` 가 쓰는 `scriptVisible`·`scriptTextVisible`·`liveLayerStates`·`puppetCascadePhase`/`puppetCascadeLastTime`, 그리고 `pushLiveSceneLayers()`(:2893)를 통해 공유 `sceneScript` JSContext 자체. 이 셋의 존재는 teardown(:3013-3021)이 같은 목록을 stale 방지로 지우는 것으로 확인된다. 도달성 실측: 프로덕션 호출부 3곳(`AppDelegate.swift:1544` · `ProfilePipeline.swift:319,326`)은 전부 **전용 캡처 인스턴스**를 새로 만들고 `defer { renderer.teardown() }` 로 버린다(`sed -n '1500,1548p' Sources/Waple/AppDelegate.swift` 확인) — 즉 현재 프로덕션에서 라이브 인스턴스가 captureFrames 를 부르는 경로는 0건이고, `preserveLiveInteraction` 가드 자체가 프로덕션 미도달이다.
- 영향: 지금은 무해하다(도달 0). 다만 :2732-2738 의 주석이 "라이브 창에 붙은 인스턴스에서도 진단/썸네일용 캡처 API를 부를 수 있다" 를 계약으로 선언하고 그 계약을 세 배열로만 지키므로, 그 경로를 실제로 여는 순간(썸네일 재생성 등) 라이브 씬의 스크립트 상태가 캡처 시각으로 앞당겨진다. 감사 I1 이 sim 상태에 대해 고친 것과 정확히 같은 부류의 잔여분이다.
- 기지 대조: `lane10`/`lane05` 대조 완료. `docs/audit-r2-lanes/lane05-render-core.md:291-293`(「확인했지만 문제없던 것」 7번)이 이 자리를 **명시적으로 clean 으로 판정**했는데, 열거한 것이 pointer/hover/pending 3배열 + focus/position 2상태뿐이고 스크립트 캐시군은 검사 범위에 없다. `grep -rn "preserveLiveInteraction|scriptParticleEmissionPaused|liveLayerStates|puppetCascadePhase" AUDIT-FULL-2026-08-31*.md docs/audit-r2-lanes/*.md` → lane05:124,291 두 줄뿐. 신규.

### ⚪ `Sources/WapleCore/ScenePBRLighting.swift:704`
**볼류메트릭 반경 감쇠의 GPU/CPU 두 벌 중 GPU 쪽에만 exponent 클램프가 있다 — "비트로 대조" 를 목적으로 둔 쌍의 한쪽만 방어됨**
- 근거: 정독 + 손계산. GPU 경로: `VolumetricLightPass.swift:228` `let exponent = max(0, light.exponent)` 로 클램프한 뒤 `lightParams.y` 에 실어 MSL `pow(saturate(1.0 - dist*invHull), u.lightParams.y)`(:378)에 넣는다. CPU 정본 `SceneWEVolumetricMath.radialFalloff(distance:hullRadius:exponent:)`(:704-710)은 exponent 를 **생값으로** 받아 `base>0` 이면 `powf(base, exponent)`. 음수 지수에서 갈린다 — exponent=-2, base=0.5 이면 GPU 는 `pow(0.5, 0)=1`, CPU 는 `powf(0.5,-2)=4`. base<=0 인 헐 경계에서만 양쪽 다 1 로 일치한다(:708 의 `exponent <= 0 ? 1 : 0`). 소비처 실측: `grep -rn "radialFalloff" Sources/ Tests/` → 프로덕션 소비 0건, `Tests/WapleCoreTests/SceneVolumetricMathTests.swift` 만 호출. 파스는 무클램프(`SceneDocument` 의 `volumetricsexponent` 폴백 1).
- 영향: 렌더 영향 없음(CPU 함수는 테스트 전용). 문제는 이 파일이 그 두 벌을 둔 이유를 "두 벌을 비트로 대조"(:700-703 · :740-741)로 못박아 두었는데, 한쪽에만 게이트가 있어 그 대조가 exponent<0 구간에서 성립하지 않는다는 것이다. 클램프를 GPU 호출부(:228)가 아니라 두 벌이 공유하는 산술 정본에 두면 비대칭이 사라진다.
- 모집단: volumetricsexponent 저작 도수: 27건/11씬(워크샵 코퍼스, `spec/corpus/scene-schema.json` 인용 — 이 머신에 코퍼스 없어 재측정 불가). 실측 범위 1.0~3.04 로 음수 표본 0. 설치본/동봉 186씬은 castvolumetrics 0건이라 게이트 자체가 안 열린다
- 기지 대조: 선행 3종 + docs/ 대조: `grep -rn "radialFalloff|exponent 클램프|max(0, light.exponent)" AUDIT-FULL-2026-08-31*.md docs/audit-r2-lanes/*.md docs/sweep-2026-08-19.md docs/full-audit-2026-08-26.md docs/swarm-audit-2026-08-26.md` → **0건**. `docs/sweep-2026-08-19.md:389`(3-9)은 종전 `pow(intensity, exponent)` NaN 항목이라 대상(밑이 intensity)과 기전(NaN)이 다르고, 지금 코드에는 그 식 자체가 없다. `r3-recover-render3d.md` R-6(포그 미이식)·lane06 F6-4(radius 인용)와도 별건.

### ⚪ `Sources/WapleCompatCore/DeepScan.swift:208`
**F681 ogg 예산 doc 주석이 assetLoadTimeoutSeconds 에 붙어 있고 oggDecodeTimeBudget 은 무주석**
- 근거: :208-211 이 "F681: ogg 디코드 누적 시간 예산(초) … WAPLE_DEEP_OGG_BUDGET 환경변수로 오버라이드 가능" 인데, 바로 다음 :212-213 이 "AVAsset 로드 한 건의 상한 …" 이고 :214 가 `static let assetLoadTimeoutSeconds: Double = 5` 다. 즉 6줄 doc 블록 전체가 `assetLoadTimeoutSeconds` 에 부착되고, 그 doc 이 실제로 설명하는 `oggDecodeTimeBudget`(:216)은 주석이 없다. 원인 재현: `git show 1cd54384 -- Sources/WapleCompat/DeepScan.swift | grep -B6 -A6 'assetLoadTimeoutSeconds: Double = 5'` → `@@ -180,6 +180,10 @@` hunk 가 F681 주석 **한복판에** 선언 2줄+빈줄을 삽입한다. 삽입 전(`git show 1cd54384^:Sources/WapleCompat/DeepScan.swift`)에는 :182 주석 바로 다음이 :183 `static let oggDecodeTimeBudget` 이었다.
- 영향: `assetLoadTimeoutSeconds`(5초 AVAsset 상한)의 doc 첫 4줄이 전혀 다른 상수(120초 ogg 디코드 예산, 환경변수 오버라이드)를 설명한다. 편집기 QuickHelp·문서 생성기가 그대로 보여준다. 실동작 영향은 없다.
- 기지 대조: r3 O10(`ParticleSimulator.swift:1856` — oscPositionOffset doc 이 applyBoids 헤더로 붙음)과 **같은 부류·다른 자리**. DeepScan 관련 선행 언급(sweep:96/170/177/303/382/388/390/396/533/535/539, full-audit:126/199/264, lane11:6/197/221)을 전수 확인했고 이 항목은 없다.

### ⚪ `Sources/WapleRender/SceneRendererFrameEncoder.swift:450`
**r3 §4.3 미판정 확정: copyBackground:false 컴포지션 레이어의 colorBlendMode dst 가 acc 스냅샷이 아니라 투명 클리어다**
- 근거: 전 줄 정독으로 경로를 이었다. `runFrameBufferLayer`(:407-476): :413 `snap = pooledOffscreen(...)`; :429 `if layer.copyBackground { blit acc → snap }`; :433-449 `else` 가지는 acc 를 **별도** `auxSnap` 으로 블릿해 `fullFrame` 에만 싣고(:436-441), `snap` 은 `loadAction=.clear`, `clearColor=(0,0,0,0)` 로 비운다(:442-448). 그 직후 :450 `backdrop = snap` — 곧 copyBackground:false 에서 `backdrop` 은 투명 텍스처다. :471 `let blendSnapshot: MTLTexture? = (layer.colorBlendMode != 0 && srcTex !== backdrop) ? backdrop : nil` 가 그것을 `encodeLayer` 의 f_blend dst 로 넘긴다(:1920-1925 가 `setFragmentTexture(blendSnapshot, index: 1)`). 자기 주석 :404-406 은 "효과 체인 실행 전 acc 스냅샷을 blendSnapshot 으로 보존해" 라고 적는다 — 그 가지에서는 acc 스냅샷이 아니다. 실제 acc 스냅샷(auxSnap)은 aux 슬롯 전용으로만 쓰인다(:456 fullFrameSnapshot).
- 영향: `_rt_` 컴포지션 레이어가 `copybackground:false` + `colorblendmode != 0` 을 동시에 저작한 경우, 셰이더 블렌드의 dst 가 씬 컬러가 아니라 완전 투명이 되어 multiply/screen/overlay 계열이 전부 틀린 결과를 낸다. 동봉 도달은 0 이다(r3 M12 §4.2 의 정정 실측: 동봉에서 `_rt_` + colorBlendMode 값≠0 인 씬 0건).
- 모집단: 동봉 WEAssets 172씬 기준 도달 0(r3 §4.2 M12 정정 실측 인용). 워크샵 코퍼스 미측정.
- 기지 대조: r3 §4.3 **미판정** 항목(`SceneRendererFrameEncoder.swift:450`)과 동일 자리다. 그 표가 남긴 두 미결 중 기전을 확정했고, "내부 중복 여부 미확인" 에 대해서는 lane01~16 전수 grep 으로 다른 레인의 독립 검출이 없음을 확인했다. 새 발견이 아니라 **미판정의 판정**으로만 올린다.

### ⚪ `Sources/WapleLibrary/LibraryStore.swift:218`
**r3 §4.3 미판정(LibraryStore zip try?)은 기지다 — 다만 "손상 zip 로그 0건" 절반은 선행 문서에 없다**
- 근거: 기지 대조: `docs/full-audit-2026-08-26.md:195` 가 같은 자리(당시 `:215`)를 "extractionTimedOut 이 try? 로 삼켜져 타임아웃이 '배경 없습니다' 메시지로 위장" 으로 이미 적었다(같은 문서 :264 요약의 항목 (3)). 새 절반의 근거: `ZipImporter.dittoExtract`(:47-56)는 **비-0 종료를 throw 하지 않고 `false` 를 반환**하고(`return p.terminationStatus == 0`), :51-52 가 stdout/stderr 를 `FileHandle.nullDevice` 로 버린다. `extractZipToTemp`(:217-221)는 `(try? extract(zipURL, temp)) == true` 로 받고 로그를 남기지 않는다. 타임아웃 경로만 `ZipImporter.swift:72` 에 로그가 있다. 사용자에게 뜨는 문구는 `Sources/Waple/LibraryViewModel.swift:354` "zip 에서 가져온 배경이 없습니다. project.json 이 포함돼 있는지 확인하세요." 다.
- 영향: 손상/미지원 zip 은 리포 전체에서 로그가 한 줄도 안 남고 사용자에게는 **다른 원인**(project.json 부재)을 가리키는 안내만 뜬다. 같은 파일의 형제 실패 경로(:285·:292·:303·:306)는 전부 NSLog 를 남긴다 — 해제 단계만 침묵한다.
- 기지 대조: r3 §4.3 미판정 행과 동일 자리이고, 그 행 자체가 `docs/full-audit-2026-08-26.md:195` 의 **중복**이다(r3 §4.1 이 경고한 "대조 범위를 AUDIT-FULL 2종으로만 잡아 생긴 거짓 신규" 와 같은 형태). 병합 시 신규로 승격하지 말 것. 증분은 "손상 zip = throw 아님 = 로그 0건" 한 축뿐이다.

### ⚪ `Sources/WapleCore/RemapOperation.swift:39`
**RemapOperation 주석은 "정확한 나눗셈을 쓴다" 인데 코드는 역수 곱이다(무작위 float32 26%에서 1 ulp 차)**
- 근거: 주석 :39-41 "**[의도적 이탈] 역수.** 실물은 `rcpps`… 여기서는 정확한 나눗셈을 쓴다". 코드 :54-56 `normalize` 는 `(raw - lo) * (1 / inputSpan(min: lo, max: hi))` — 역수를 먼저 반올림한 뒤 곱한다. 실측(python3, struct 로 float32 왕복): 무작위 (raw, lo, hi) 20만 조에서 `f32(f32(raw-lo)*f32(1/span))` 과 `f32(f32(raw-lo)/span)` 이 **52,082건(26.0%)** 갈렸고 전부 1 ulp 다(예: raw=5.27549219 lo=-7.31271505 hi=6.94867468 → 0.882677495 vs 0.882677436). 잠금 테스트는 `Tests/WapleCoreTests/RemapOperationTests.swift:19-33` 이 `accuracy: 1e-6` 이라 이 차이를 고정하지 않는다. 출생: `git log -S '여기서는 정확한 나눗셈을 쓴다'` 와 `git log -S '(raw - lo) * (1 / inputSpan(min: lo, max: hi))'` 가 **둘 다 c2f4f3b0**(2026-08-21) — 주석과 코드가 같은 커밋에서 갈렸다.
- 영향: 실동작 파손은 없다(역수 곱도 결정적이고 IEEE 정의라 주석의 목적인 '헤드리스 결정성'은 달성). 문제는 서술이다 — 이 리포는 같은 축을 다른 곳에서 반대로 못박는다: `ScenePBRLighting.swift:700-703`(`SceneWEVolumetricMath.radialFalloff`)이 "역수 곱으로 적는다 … 여기서만 `distance / hullRadius` 로 나누면 마지막 자리가 GPU 와 갈린다" 다. 두 파일이 같은 연산에 대해 반대 문장을 갖고 있어, 나중에 주석을 믿고 `/ span` 으로 '정정'하면 26% 입력에서 값이 움직인다.
- 기지 대조: 선행 5문서 전수 grep(`RemapValueMath|정확한 나눗셈`) → 히트 1건은 `docs/full-audit-2026-08-26.md:107` 로 "동작은 RemapValueMath 가 정본"(ParticleSimulator 와의 소비처 판정)이라 다른 주제. 해당 없음.

### ⚪ `Sources/Waple/DesktopVisibilityMonitor.swift:163`
**DesktopVisibilityMonitor 스냅샷 기본값 주석의 방향이 alpha 에 대해 반대다**
- 근거: 주석 :163 "값 부재는 '가리지 않음' 쪽으로 안전 기본값(layer=max, alpha=1)". 판정부 :112 `guard w.layer == 0, w.alpha > 0.05, area(w.bounds) > 12_000 else { return false }`. `layer = … ?? Int.max`(:167)는 `layer == 0` 을 못 지나므로 실제로 '가리지 않음' 쪽이 맞다. 그러나 `alpha = … ?? 1`(:168)은 `alpha > 0.05` 를 **통과**시켜 차단 후보로 만든다 — 주석이 말한 방향의 반대다. 출생: `git log -S "값 부재는 '가리지 않음' 쪽으로 안전 기본값" -- Sources/Waple/DesktopVisibilityMonitor.swift` → `ae64089f`(2026-07-06) 단일 커밋이고 `git show ae64089f:…` 의 :75-80 이 현재와 동일 — 출생 시점부터 같은 서술이다.
- 영향: 실동작 영향은 사실상 0 이다(CGWindowList 는 `kCGWindowAlpha` 를 항상 채우므로 이 기본값 도달을 관측하지 못했다 — 이 머신에서 실행 측정은 하지 않았다). 남는 것은 두 기본값의 방향이 갈리는데 주석이 하나로 묶어 말한다는 점이고, 자동 일시정지 판정을 손볼 때 잘못된 전제가 된다.
- 기지 대조: 선행 5문서에서 이 파일 언급은 `lane08-app.md:181`(좌표 플립 확인 — 문제없음 기록)과 `docs/full-audit-2026-08-26.md:63` M3(`isFinderDesktopHost` 95% 예외, 현재도 미해소)뿐이다. alpha 기본값 축은 없다.

### ⚪ `Sources/Waple/DesignSystem/Components/Badges.swift:13`
**Badges.swift 의 "실측: 사용자 대면 문자열 42건 중 40건" 이 모집단을 밝히지 않고, 작성 시점 트리에서 42 에 해당하는 모집단을 찾지 못했다**
- 근거: 출생 커밋 `28b1a5b4`(2026-08-17, `git log -S'사용자 대면 문자열 42건 중 40건이 이 병이다'`)의 트리를 `git archive` 로 펼쳐 후보 모집단 넷을 실제로 셌다:
  · `Text(<식별자>)`(비현지화 오버로드가 붙는 형태) — `grep -rhoE 'Text\([a-zA-Z_][A-Za-z0-9_.?]*\)' Sources/Waple` = **27**
  · `Resources/en.lproj/Localizable.strings` 키 = **128**(부모 커밋도 128)
  · Sources/Waple 의 한글 포함 문자열 리터럴 = **373**
  · `NSLocalizedString(` = **15**
어느 것도 42 가 아니고, 42 를 낳는 정의를 리포에서 찾지 못했다(`grep -rn "42건\|40건" Sources/ docs/ AUDIT-FULL-*.md` → 무관 히트만).
- 영향: 반증은 못 한다 — 주석이 모집단을 안 밝혔으므로 "42" 를 낼 정의가 어딘가 있었을 수 있다. 확정할 수 있는 것은 **모집단 미표기**뿐이고, 그 자체가 이 리포의 규약 위반이다(브리핑 「도수를 적으면 모집단을 반드시 밝혀라」, r3 「모집단이 없는 도수는 쓰지 않았다」). 이 수는 `TypeBadge.label` 이 `String` 이 아니라 `Text` 인 **설계 결정의 유일한 정량 근거**로 서 있어서, 뒤집으려는 사람이 대조할 기준이 없다. 실동작 영향 0.
- 모집단: 미정의 — 주석 자체가 모집단을 밝히지 않는다. 위 넷은 내가 잰 후보 모집단이다(설치본/동봉 코퍼스와 무관, 리포 소스 트리 @28b1a5b4).
- 기지 대조: `Badges` 는 선행 감사 3종·`docs/audit-r2-lanes/` 18레인·sweep/full/swarm 어디에도 **언급 0건**이다(라운드 시작 시 22파일 전건 대조로 확인). 현지화 계열 기지 발견 — r2 H15/H16/H17 · r3 M23/M68 — 은 전부 다른 파일(접근성 게이트·SettingsView·SceneRenderSettingsTests·WebInputProxyView)이다.

### ⚪ `Sources/WapleRender/TextScriptEngine.swift:2285`
**파일명 없는 자기참조 `:N` 인용 중 **작성 시점부터 무효**였던 것 2건 확인(r3 O25 가 미검증으로 남긴 414자리에서)**
- 근거: ① `TextScriptEngine.swift:2285` — "벡터는 `"r g b"` 문자열도 배열도 Vec 도 받는다 — Vec3/Vec2 생성자가 셋 다 삼킨다(**:1729**)". 현재 :1729 는 `for (i = 0; i < __timeoutQueue.length; …)`(타이머 선형 스캔). `git log -S'셋 다 삼킨다(:1729)'` → 출생 `e18f6cf8`(2026-08-21) 단일 커밋이고 부모에는 문자열이 0건. 그 트리에서 `grep -n` 하면 주석은 :2163, `__WapleVec3` 는 **:1756**, `__WapleVec2` 는 **:1788**, 그리고 :1729 는 `function __setRuntime(t) {` 이었다. 외부 해석(`lib.sceneScript.d.ts:1729`)도 성립하지 않는다 — 실물 d.ts 의 1729 는 `controlpoint7: Vec3;` 다.
② `Sources/Waple/Shell/NowPlayingBar.swift:264` — "두 문자열이 각각 :225 `Section("음량")` 과 **:263** `.help("동영상 음량 · 배속")` 에서 우연히 추출된다". `git log -S'과 :263 `.help('` → 출생 `fb4786d2`(2026-08-25). 그 트리에서 `.help("동영상 음량 · 배속")` 는 **:276** 이고 :263 은 그 주석 자신의 첫 줄이었다. 같은 문장의 짝인 `:225`(`Section("음량")`)는 출생 시점에도 지금도 정확하다 — 한 문장 안에서 한쪽만 틀린 비대칭이다.
(대조로, 같은 부류로 의심한 `TextScriptEngine.swift:1368`(`stripModuleSyntax(:485)`)은 출생 `3854bc8f` 트리에서 :485-486 이 정확히 그 정규식-시작 휴리스틱이었다 — 평범한 사후 드리프트라 여기서 뺐다.)
- 영향: 실동작 영향 0. 값어치는 분류에 있다 — r3 §4.1 이 기각한 3건은 전부 "작성 시점부터 틀렸다"가 pickaxe 로 무너진 경우였고, 그래서 이 부류는 **검증되면 사후 드리프트(M10/M54)와 다른 처방**을 받는다: 드리프트는 좌표 재생성으로 고쳐지지만 이 둘은 재생성해도 원래 가리키려던 대상이 무엇인지 코드에 없다(특히 `:1729` 는 내부/외부 어느 해석으로도 대상이 없다). 두 자리 모두 문장이 "근거는 저기 있다"로 논증을 끝내므로 근거 사슬이 끊긴 상태다.
- 기지 대조: r3 **O25**(`WapleCore/SceneDocument.swift:164`)가 "파일명 없는 자기참조 `:N` 인용이 82파일 416자리 — 표본 1건 무효 확인, **나머지 414 미검증**" 으로 모집단만 세어 뒀다. 이 둘은 그 414 안에 있으므로 **모집단은 기지**이고, 새로운 것은 (a) 두 자리의 개별 검증과 (b) O25 가 다루지 않은 "출생 시점부터 무효" 속성이다. r1 M10 · r3 M6/M18/M54/M55/M56/M62 는 전부 다른 파일이거나 사후 드리프트 판정이다. 병합 시 O25 의 하위 항목으로 붙이는 것이 맞다.

### ⚪ `Sources/WapleCore/Model3D.swift:1252`
**Model3D.inferStride 가 인덱스 폭을 u16 로 고정 — 본경로는 2026-08-20 에 `gateWord & 1` 로 바뀌었는데 추론 경로만 옛 가정에 남았다**
- 근거: 본경로 `:762` `let iWidth = (gateWord & 1) == 0 ? 2 : 4` 와 그 근거 주석 `:746-761`(*"폭은 정점 수가 정하는 게 아니라 포맷이 자기기술한다"* — GPU 업로드 `0x1401d7760` 의 `lea r9d,[r10*2+2]`).

형제 `inferStride`(:1252-1268)는 여전히 u16 전용이다: `:1253` `iSizeU % 2 == 0` · `:1259-1262` `while k+1 < end { v = bytes[k] | bytes[k+1]<<8; k += 2 }`. 함수 doc(:1250-1251)도 *"인덱스 블롭(u32 크기 + u16 인덱스)"* 이라 코드와는 일치하지만 본경로 규칙과는 갈린다.

산술 검증(계산으로 확인, 실행 아님): u32 인덱스 블롭을 u16 쌍으로 읽으면 값 v 가 (lo, hi) 로 쪼개진다. 모든 v < 65536 이면 hi 는 전부 0 이라 `maxIdx = max(v)` 로 **결과가 우연히 맞다**. v ≥ 65536 이 하나라도 있으면 maxIdx 가 65535 로 상한을 먹어 `count = maxIdx+1` 과소 → `s = vSize/count` 과대.

호출 조건도 좁다: `:698` `if vSize % stride != 0` — `vertexLayout(for:)`(:534-556)이 nil(위치 채널 부재/미지 비트만)이거나 테이블 stride 가 vSize 를 안 나눌 때만 탄다. 설치본 45메시는 플래그 0x09/0x0b/0x0f/0x27 이라 전건 테이블로 해결된다(그 검산 6종을 손계산으로 재현했고 전건 일치).
- 영향: `gateWord bit0` 이 선 u32-인덱스 메시가 동시에 테이블 미해결(손상/미지 변종)일 때만 발현. s 가 (20...96) 밖으로 나가면 `Model3D.parse` 가 nil 을 돌려 **모델이 통째로 안 그려지고**, 우연히 범위 안이면 잘못된 stride 로 정점을 오독한다. 설치본/동봉 도달 0 — 워크샵 대형 메시(정점 65536 초과)에서만 갈리는 잠복 구멍이다.
- 모집단: 설치본 .mdl 28파일 45메시(도달 0) / 동봉 코퍼스
- 기지 대조: `inferStride` 를 선행 3종 + 16레인 + sweep/full/swarm 에 grep → **0건**. 인접한 r3 M3(`spec/formats/mdl-deep.json:565` 의 `indexWidth` 인용이 `Model3D.swift:577` 빈 줄을 가리킴, 실제 762)는 **정본 문서의 좌표 드리프트**이지 추론 경로 자체를 보지 않았다. lane02-core-binary 는 Model3D 의 리싱크·본수 상한·인덱스 상한만 다룬다. 신규.

### ⚪ `Sources/WapleCore/ParticleSimulator.swift:1352`
**applyAttract 헤더가 "두 핸들러는 블렌드 가중 곱 하나만 다르다 · 1:1 로 옮긴 것" 이라 적고 의사코드에 `step *= w` 를 담는데, 구현에 그 항이 없다**
- 근거: 주석 `:1343-1354` 는 *"실물 VM base 핸들러 op 0x0a @0x140241554 / **가중 변형 op 0x20** @0x14024172d 를 **1:1 로 옮긴 것** — 두 핸들러는 블렌드 가중 곱 하나만 다르다"* 라고 선언하고, 그 안의 의사코드 :1352 가 `step *= w ; 0x1402418e9 (블렌드 창, 기본 w ≡ 1)` 을 포함한다.

구현 `:1373-1393` 에는 `w` 가 없다: `var step = (1 - dist/a.threshold) * a.scale * dtScaled` → `if (a.flags & 2) != 0, dist < step { step = dist }` → `vel += (d/dist)*step`. `attractors` 튜플(:165-166, :341-343, :414-415)에도 blend 필드가 없다 — 같은 파일의 형제 넷(`oscPosBlend` :154 · `oscAlphaBlend` :153 · `turbulences[].blend` :196 · `velocityCaps[].blend` :198)은 `def.operatorBlends[opIdx]`(:328)를 받아 실제로 곱한다.

동봉 코퍼스 실측(python 으로 WEAssets 전 json 파스): `blendin*`/`blendout*` 을 단 오퍼레이터는 turbulence 4 · capvelocity 3 · oscillatealpha 5 · oscillateposition 2 · remapvalue 2 · **controlpointattract 1** = 17건. 그 controlpointattract 1건은 `presets/lightning/previewthunderbolt/…/thunderbolt_fizzle.json` 의 `{"blendinstart": 0}` 뿐이라 BACKLOG D9 의 활성화 게이트 `(bie > 0.01 || bos < 0.99)` 에서 탈락한다(bie 기본 0, bos 기본 1.0) → 실제로 w ≡ 1.
- 영향: 현 코퍼스에서 화면 차이는 0(게이트 탈락). 남는 것은 **주석이 코드보다 더 많은 것을 주장한다**는 사실 — 다음 라운드가 "controlpointattract 의 블렌드 창은 이미 옮겨졌다" 로 읽고 건너뛸 수 있다. 형제 넷이 같은 자리에서 `bw` 를 받는데 여기만 안 받으므로 저작 씬이 그 키를 쓰기 시작하면 조용히 무시된다.
- 모집단: 동봉 코퍼스(WEAssets) — 289 파티클 시스템 / blend 키 보유 오퍼레이터 17건
- 기지 대조: `applyAttract`/`controlpointattract` 를 선행 3종 + 16레인 + sweep/full/swarm 에 grep → **0건**. **갭 자체는 기지다** — `BACKLOG.md:374-429`(D9)가 controlpointattract(op 0x20)를 G-C2-03 대상 13종에 넣고 "Waple 현황은 1/11 부분 구현"·도달표(controlpointattract 1건, 게이트 탈락)를 이미 적는다. **신규는 갭이 아니라 주석 쪽이다**: 이 doc 블록이 "1:1 이식 · 두 핸들러는 w 곱 하나만 다르다" 라고 단언하면서 그 w 줄(:1352)을 구현이 갖지 않는다는 것. BACKLOG 는 코드가 아니라 계획 문서라 이 주석의 거짓을 덮지 않는다.

### ⚪ `Sources/WapleCore/SceneGeometry.swift:130`
**`cameraparallaxdelay` 코퍼스 도수 176/175 가 두 파일에서 전치돼 있다 (176 은 설치본 파일 수, 175 는 그중 0.1 값 수)**
- 근거: SceneGeometry.swift:130-131 "코퍼스 도달은 `0.1` **176건** · `1` 1건뿐이라 (동봉 168 + 설치본 **175** 씬 기준)" · 같은 문장의 짝이 ParallaxController.swift:64 "동봉·설치본 도달은 `0.1` 이 **176건** · `1` 이 1건뿐이고 3 이상은 0건". 실측: `grep -rl cameraparallaxdelay` → 동봉 **168 파일**(전건 0.1) · 설치본 **176 파일**. `grep -rho 'cameraparallaxdelay"[^,}]*'` 값 센서스(양쪽 합) = 0.1 171 + 0.10000000149011612 169 + 0.10000000000000001 2 + '1' 1 → 0.1 계열 합 **342**. 즉 176 은 설치본 파일 수이고 175(=176−1)가 그중 0.1 값 수다.
- 영향: 결론(delay ≥ 3 저작 0건 → 발산 구간 도달 없음)은 양쪽 파일 모두에서 유효하다. 다만 '0.1 176건' 이라는 도수 자체는 어느 모집단에서도 성립하지 않고, 같은 잘못된 수가 두 파일에 복제돼 있어 한쪽만 고치면 갈린다.
- 모집단: 동봉 WEAssets 168 파일 + 설치본 wallpaper_engine 176 파일(cameraparallaxdelay 보유 기준)
- 기지 대조: AUDIT-FULL 3종 · docs 225개 .md 전수 '176건' 0건. `SceneGeometry.swift:` 인용 범위(65-88 · 107-118 · 138 · 138-140 · 163-166 · 190)와 `ParallaxController.swift:25-27` 어느 것도 :130 / :64 를 안 덮는다.

### ⚪ `Sources/WapleRender/SceneRenderer3D.swift:1286`
**buildCustomMeshShader 의 albedoName 이 '첫 non-null' 구규약을 그대로 쓴다 — 같은 파일이 그 규약을 결함으로 지목하고 슬롯 0 전용으로 고친 뒤에도**
- 근거: 코드: `let albedoName: String? = mat.customTextures.first { $0 != nil } ?? nil` 뒤 :1287-1288 이 그 이름으로 `texWrap[0]`·`texFilter[0]`(슬롯 0 샘플러 상태)을 정한다. 같은 파일 :862-864 가 "③: 종전 '첫 non-null 문자열' 규약은 슬롯을 무시해 textures[0]=null 인 재질에서 노멀맵이 알베도로 승격되는 결함이 있었다" 라고 적고 :906 에서 `(p0["textures"] as? [Any])?.first as? String` 으로 슬롯 0 전용으로 고쳤다. 재현은 코드 독해로 결정된다(빌드/테스트 금지 규약이라 실행 재현은 안 했다): `textures:[null,"foil_silver_normal"]` 이면 loadMesh3DMaterial 의 texName 은 nil → resolveTexture 흰 1×1, 그런데 :1286 은 "foil_silver_normal" 을 골라 그 `.tex` 의 clampuvs/nointerpolation 플래그를 슬롯 0 에 싣는다.
- 영향: 발현 조건(textures[0] == null)에서 슬롯 0 의 실제 텍스처는 흰 1×1 이라 clamp/repeat·nearest/linear 가 시각적으로 동일해 관측 가능한 차이가 없다. 실동작 영향이 아니라 '같은 커밋이 규약을 고치면서 이 자리는 안 고쳤다' 는 유지보수 위험으로만 보고한다.
- 기지 대조: AUDIT-FULL 3종 · docs 전수 '첫 non-null' · 'albedoName' 0건. docs 의 `SceneRenderer3D.swift:N` 범위 인용 41자리 중 :1169 다음이 :1460-1461 이라 :1286 은 안 덮인다.

### ⚪ `Sources/WapleCore/PointerHit.swift:314`
**`g_PointerState` 소비처 인용이 preview 사본 두 건에서 어긋난다(게인·줄번호)**
- 근거: (1) 문면 `:313-315`: "동봉 셰이더 4파일이 전부 `.z` **만** 읽는다(`cursorripple_apply_force.frag:83` 이 `× 5.0`, `fluidsimulation_vorticity.frag:198` 이 게인 1 — 각 preview 사본 포함)."
(2) 실측 `grep -rln g_PointerState Sources/WapleRender/Resources/WEAssets` → 정확히 4파일. 각 파일 `grep -n g_PointerState`:
 · effects/cursorripple/shaders/effects/cursorripple_apply_force.frag:83 `… + g_PointerState.z * 5.0)` ✅ 인용대로
 · effects/fluidsimulation/shaders/effects/fluidsimulation_vorticity.frag:198 `… + g_PointerState.z)` ✅ 인용대로
 · effects/cursorripple/**preview**/shaders/effects/cursorripple_apply_force.frag:83 → `… + g_PointerState.z); // * g_PointerState.z;` — 게인이 5.0 이 아니라 **1**
 · effects/fluidsimulation/**preview**/shaders/effects/fluidsimulation_vorticity.frag:**197** — 198 이 아니다
(3) 주 주장("`.z` 만 읽는다")은 4파일 전건 참임을 확인했다. 어긋난 것은 "각 preview 사본 포함" 이 끌고 들어온 게인·줄번호 귀속뿐이다.
- 영향: `PointerButtonState.clickImpulse`(= `.z` 만 1프레임 임펄스) 규약의 근거로 이 네 자리를 다시 여는 사람이 preview 사본에서 인용과 다른 값을 보게 된다. 실경로는 preview 가 아닌 두 파일이라 실동작 영향은 없다. 확정 판정이 아니라 "인용 범위 표현이 과하다"는 관찰로 올린다 — 문장을 "두 정본 파일 기준" 으로 좁히면 해소된다.
- 모집단: 동봉 WEAssets 중 `g_PointerState` 참조 4파일(정본 2 + preview 사본 2)
- 기지 대조: AUDIT-FULL 3종 · docs/audit-r2-lanes/ 전체(PointerHit 문자열 0건 — 이 파일은 선행 감사 어디에도 등장하지 않는다) · sweep · full-audit · swarm · r3 §4.1 → 0건.
