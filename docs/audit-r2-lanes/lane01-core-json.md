# 레인 1 — WapleCore JSON·프로젝트 파서 계층 (HEAD `b883386e`, 읽기 전용)

담당 13파일 중 PR #8 이 손댄 것은 `SceneDocument.swift`(±298) · `WallpaperProperties.swift`(±8) ·
`SceneGeometry.swift`(±3) 셋뿐이다(`git show b883386e --stat -- Sources/WapleCore/`).
`JSONNumerics.swift` · `ProjectJSONParser.swift` · `AssetJSON.swift` 등은 **무변경**이다.

---

## 발견

### [🟡] 텍스트 `perspective` 신설 필드의 근거 VA 두 자리가 **이미지 오브젝트 코드**를 가리킨다 (PR #8 신규)
- 자리: `Sources/WapleCore/SceneDocument.swift:434-437`(선언 주석) · `:2644-2646`(파스 자리)
- 근거/재현:
  1. `0x140184f0c` 는 `FUN_140184f00`(248바이트 = `0x140184f00`–`0x140184ff7`) 안이다. 그 함수 전문에
     `+0x120` 도 `& 0x80` 도 **없다** — `tanf(fov)` 로 레이어 원근 뷰행렬을 만드는 순수 계산이고,
     같은 리포가 `SceneGeometry.swift:190·192·209·230` 에서 바로 그 용도(`0x140184f43`/`0x140184f4c`/
     `0x140184f6f`)로 인용한다.
     `sed -n '1,25p' ../Waple-wallpaper-source/analysis/decompiled/all/0000000140184f00__FUN_140184f00.c`
  2. 실제 bit7 게이트는 `FUN_1401ed0d0` 의 `(*(byte *)(plVar9 + 0x24) & 0x80)` 세 자리다(디컴파일 줄
     121·156·176 — `0x24 × 8 = +0x120`, `0x80` = bit7). 그런데 그 함수는 **이미지 디스크립터의 콜백**이다:
     `FUN_1401ee520`(이미지 표, 반환 `&DAT_1404e8360`) 말미가 `*(code **)(local_48[0] + 0x30) = FUN_1401ed0d0;`
     로 심는다. `tail -25 .../00000001401ee520__FUN_1401ee520.c`
  3. `"perspective"` 를 등록하는 디스크립터 등록기는 **둘뿐**이다 —
     `grep -rl '"perspective"' ../Waple-wallpaper-source/analysis/decompiled/all/`
     → `FUN_1401ee520`(image: color·alpha·brightness·visible·perspective·castshadow·copybackground·
     nointerpolation·clampuvs·ledsource) · `FUN_140227470`(model: visible·perspective·castshadow·**rootmotion**).
     둘 다 `*(undefined4 *)(lVar + 0x34) = 0x120` 로 멤버 오프셋 `+0x120` 을 심는다.
  4. **텍스트 등록기 `FUN_140258ca0`**(반환 `&DAT_1404e88e0`, 키 24개: backgroundbrightness·opaquebackground·
     limitwidth·limitrows·limituseellipsis·blockalign·backgroundcolor·pointsize·padding·spacing·maxwidth·
     outline·dropshadow·… )에 `perspective` 는 **없다**. **공통 오브젝트 등록기 `FUN_1401e0530`**
     (반환 `&DAT_1404e8250`, 키 6개: origin·scale·angles·sortorder·solid·disablepropagation)에도 **없다**.
     `grep -o 'FUN_14000f880([^,]*,"[a-z0-9_]*"' <파일> | sed 's/.*,"//'`
- 왜 문제인가: 주석은 `perspective` 를 "공통 오브젝트 플래그" 로 단정하고 그 근거로 두 VA 를 다는데,
  하나는 플래그 검사를 담지 않은 행렬 함수이고 다른 하나는 이미지 표의 콜백이다. 등록 코퍼스는
  image/model 전용을 가리킨다. 동봉 `presets/clock/preview3dclock/scene.json` 의 텍스트 오브젝트
  `"3D Clock"`(id 8, `perspective:true`, `origin.z=0`, angles 정적 0 + **스크립트가 x/y 회전을 돌린다**)
  단 하나가 이 배선을 탄다 — WE 가 텍스트에서 이 키를 안 읽는다면 그 씬만 WE 와 다른 그림이 된다.
  (실동작 판정은 아래 「의심 S1」 — 표 상속 여부를 확정 못 했다.)
- 기지 목록 대조: 해당 없음(PR #8 이 새로 심은 주석·필드).

### [🟡] PR #8 이 반증한 파서 계약을 그대로 인용하는 주석 + 줄 번호 2건 드리프트
- 자리: `Sources/WapleRender/SceneRendererResources.swift:363-366`
- 근거/재현:
  - 그 주석은 "projection 이 0인 씬(**파서는 명시적 0을 그대로 통과시킨다**, `SceneDocument.swift:729-730`)"
    이라고 적는다. ① `SceneDocument.swift:725-731` 은 지금 `SceneQueue.queueMode` 의 `?? "random"` 설명이다
    (`sed -n '725,733p' Sources/WapleCore/SceneDocument.swift`). ② 주장 자체가 PR #8 로 **거짓**이 됐다 —
    `SceneDocument.swift:1856-1860` 이 `width==0 || height==0` 을 1920×1080 으로 접고,
    `Tests/WapleRenderTests/SceneRenderFixRegressionTests.swift:333` 이 `XCTAssertFalse(doc.orthographic,
    "0×0은 유효한 정사영 크기가 아니라 viewport fallback이다")` 로 그 새 계약을 못 박는다.
  - 같은 주석의 "`SceneRenderer.swift:1122`(projW/projH 인스턴스 프로퍼티)" — `:1122` 는
    `var videoLayersLive = false` 다. 실제 자리는 `SceneRenderer.swift:1419-1420`
    (`grep -n "var projW\|var projH" Sources/WapleRender/SceneRenderer.swift`).
- 왜 문제인가: 이 주석은 `max(1, ·)` 클램프가 왜 필요한지의 유일한 설명인데, 그 근거(파서가 0 을 흘린다)가
  이제 성립하지 않는다. 다음 사람이 클램프를 "이미 파서가 막는다"며 걷어낼 수 있고, 인용 두 자리는 모두
  0 hits 로 착지한다. 파일은 WapleRender 지만 인용 대상이 내 레인의 파서 계약이라 여기 올린다.
- 기지 목록 대조: **M10(주석이 밀린 줄 번호 인용)의 재발**.

### [🟡] 게이트 철회의 유일한 근거 문서에서 비둘기집 산수가 틀렸다(13 vs 11)
- 자리: `Waple-wallpaper-source/corpus_scan/scene-json-schema.md:196`
  ("…forces at least **30** pre-v3 scenes … and at least **13** pre-v4 scenes carrying wind/gravity")
- 근거/재현: `python3 -c "import json;d=json.load(open('spec/corpus/scene-schema.json'));
  print(d['entries'][0]['value']['version'], d['entries'][1]['value']['windenabled'])"`
  → population `{5:63, 1:33, 4:32, 3:31, None:3}` = 162, `windenabled.n = 109`.
  v≥4 = 63+32 = 95, version 부재 3 → pre-v4 가 **아닌** 씬 98 → `109 − 98 = 11`.
  13 은 어느 가정으로도 안 나온다(부재 3 을 키 보유로 보면 11, 미보유로 보면 14).
  13 은 같은 문단의 **`bloomtint` pre-v3 하한**(142−129)과 같은 값이라 전치(transposition)로 보인다.
  Waple 쪽 묘비 `Sources/WapleCore/SceneDocument.swift:4072` 는 **11 로 정확히** 적었다.
- 왜 문제인가: PR #8 이 `versionGatedGeneral` 을 삭제한 유일한 근거가 이 줄이다(같은 묘비 `:4050-4058`).
  근거 문서의 수와 소비자 쪽 수가 어긋나면 다음 감사자가 재현에 실패하고 철회 자체를 의심하게 된다.
  (Waple 쪽 14개 도수·30/13/1/11 은 전부 정본과 일치함을 확인했다 — 아래 「문제없던 것 ③」.)
- 기지 목록 대조: **M22(비둘기집 하한 산수)와 같은 부류**이지만 자리가 다르다(짝 저장소 정정문).

### [⚪] `WallpaperProperties.parseInt` 의 F530 `safeInt` 가드는 JSON 입력에서 도달 불가
- 자리: `Sources/WapleCore/WallpaperProperties.swift:219-229`
- 근거/재현: `JSONSerialization` 은 모든 JSON 숫자를 `NSNumber` 로 준다 — **같은 파일 `:199-202`** 가
  바로 그 사실에 기대어 M3 을 고쳤다. 따라서 첫 분기 `if let n = raw as? NSNumber`(:220)가 항상 먼저 잡고,
  주석(`:224-226`)이 "`{"value": 1e300}` 하나로 맨 `Int(d)` 가 트랩했다 … `check_int_narrowing.py` 의 R1 이
  잡아냈다" 고 적은 `if let d = raw as? Double { return safeInt(d) }`(:227)에는 JSON 입력이 못 온다.
  `1e300` 은 `n.intValue` 로 내려가 플랫폼 정의 포화값이 되고 nil 이 **아니다**.
- 왜 문제인가: 트랩은 없으니 실동작 파손은 아니다. 다만 이 리포가 F530 스윕에서 스스로 진단한 지배적
  실패 방식("가드가 넷인데 아무도 안 거친다")이 그 진단을 인용한 주석 바로 밑에 남아 있다.
  소비처가 편집 UI 메타(`WallpaperProperty.index`)뿐이라 ⚪.
- 기지 목록 대조: 해당 없음(PR #8 무관, 기존 코드).

### [⚪] `PropertyAnimation.swift:771` 의 맨 `as? Bool` 은 바로 위 주석의 선언과 다르다
- 자리: `Sources/WapleCore/PropertyAnimation.swift:765-771`
- 근거/재현: 주석은 "WE 는 `relative` **키의 존재만** 본다(0x1401a53a3) … Waple 은 **bool 을 읽는다**" 인데
  구현은 `(a["relative"] as? Bool) ?? false` 라 `NSNumber(0/1)` 둔갑을 그대로 받는다 —
  `{"relative": 1}` → true, `{"relative": 0}` → **false**(WE 는 키가 있으니 true), `{"relative": 2}` → false.
  같은 파일 `:546`·`:560` 은 인접 bool 키에 `EffectManifest.isJSONBool` 게이트를 건다(자기 파일 내 불일치).
- 왜 문제인가: 설치본 도달 1건(값 true)이라 실피해 0. 파일 자신의 규약과 어긋나는 자리라 기록만 한다.
- 기지 목록 대조: 해당 없음.

---

## 의심 (확인 못 함 — 발견으로 올리지 않는다)

- **S1 텍스트 `perspective` 의 실동작.** 위 🟡 F1 의 등록 코퍼스는 "텍스트는 `perspective` 를 안 읽는다" 를
  가리키지만, 텍스트 표(`DAT_1404e88e0`)가 이미지 표(`DAT_1404e8360`)를 **상속**하는지 확정하지 못했다.
  근거: 텍스트 표에는 `color`/`alpha`/`visible` 도 없는데 텍스트 오브젝트는 실제로 그 셋을 저작한다 —
  즉 어딘가에서 표가 합쳐질 가능성이 남는다. `analysis/rtti-vtables.json` 의 `vtables` 가 **빈 딕셔너리**라
  클래스 계층으로 못 갈랐고, 두 전역은 서로를 참조하지 않는다. 가르는 방법: 적용 루프 `0x1401731d0` 이
  오브젝트 타입별로 어느 표들을 훑는지 디스어셈. 실피해 상한은 동봉 1 오브젝트(`preview3dclock` "3D Clock").
- **S2 combo 기본값이 문자열인데 옵션 값이 숫자인 저작 → Picker 무선택.**
  `Sources/Waple/PropertyEditorView.swift:236-244` 가 `Picker(selection:)` = `props[i].value` 와
  `.tag(opt.value)` 를 `PropertyValue` **완전 일치**로 맞추므로 `.string("0")` vs `.number(0)` 이면 무선택이다.
  PR #8 의 회귀는 **아니다**(종전에도 `.string("0")` vs `.bool(false)` 로 똑같이 어긋났다).
  도수를 못 쟀다 — 동봉 `project.json` 170개는 프로퍼티 161개가 **전건 `color`** 라 combo 도달 0
  (`python3` 전수 워크), 설치본/워크샵 코퍼스는 이 컨테이너에 없다.
  `WallpaperProperties.swift:124` 주석은 combo `value` 가 "전건 문자열", options 원소 값 타입은 미기록이다.
- **S3 음수 `orthogonalprojection.width/height`.** `SceneDocument.swift:1858` 의 `w != 0 && h != 0` 은 음수를
  통과시켜 `orthographic=true` + `projectionWidth=-1` 을 만든다(WE 도 `(int)-1.0f` 를 굽는다 —
  `FUN_140186c90` 줄 372-373 은 `== 0.0` 만 본다). 렌더러는 `max(1,·)` 로 접으므로(`SceneRenderer.swift:2002`,
  `SceneRendererResources.swift:367`) 크래시는 없고 1×1080 정사영이 된다. 코퍼스 도달 0(정본에 음수
  projection 항목 자체가 없다). 신뢰 경계 밖 잠복.
- **S4 `AssetJSON.relaxed` 의 트레일링 콤마 스캐너가 주석을 못 건너뛴다.**
  `AssetJSON.swift:133-142` 의 `j` 전진은 공백/개행만 넘으므로 `[1, // x\n]` 는 콤마가 남아 관용 파스도 실패한다.
  동봉+설치본 합집합 2,143 파일 도달 0(같은 파일 `:85-89` 의 블록 주석 실측과 같은 모집단). 무변경 파일.

---

## 확인했지만 문제없던 것 (다음 라운드 시간 절약용)

1. **M3(JSON `0`/`1` → `bool` 오타입)은 실제로 고쳐졌다 — 반만 고친 게 아니다.**
   `WallpaperProperties.swift:198-206` 이 숫자 검사를 bool **앞**으로 옮겼고, `:161` 이 옵션 값에도 실제 `type`
   을 넘긴다(종전 `type: ""`). `Tests/WapleCoreTests/WallpaperPropertiesTests.swift:184`·`:210` 두 건이
   `AssetJSON → WallpaperProperties.parse(folderURL:) → ProjectJSONParser.presetOverrides → applying(overrides:)`
   실경로로 `.number(0)`/`.number(1)` 과 Picker tag 일치를 잠근다. 같은 기전의 다른 자리도 전건 닫혀 있다:
   `ProjectJSONParser.swift:246-250`(숫자 우선) · `ProjectJSONParser.swift:258-272`(CFBoolean 선배제) ·
   `SceneDocument.weBool` `:3820-3824`(CFBoolean 한정) · `UserPropertyStore.swift:41-43` ·
   `EffectManifest.isJSONBool` · `JSONNumerics.isJSONNumeric`(`:170-175`).
   `WapleCompatCore/DeepScan.swift:337-342` 는 자체 파스 없이 `WallpaperProperties.parse` 에 위임하므로 자동 상속이다.
   옵션에 `type` 을 넘기게 된 변경의 부작용도 도달 0이다 — 옵션을 가진 타입은 `combo` 뿐이고 combo 는
   여전히 `default:` 가지로 간다.
2. **`orthographic` 게이트 신설(`SceneDocument.swift:1856-1860`, `:1887`)은 실물과 일치한다.**
   `FUN_140186c90` 디컴파일 줄 359-377(짝 저장소):
   `auto` 는 **태그 5(booleanValue)이고 `asBool` 참일 때만** `flags |= 0x18`; 아니면 width/height 가
   **둘 다** 태그 1..3 일 때만 저장하고 `width==0.0 || height==0.0` 이면 `flags &= 0xfffffff7`(bit3 clear),
   아니면 `flags |= 8`; 둘 중 어느 가지도 안 타면 비트를 **안 건드려** 생성자 기본(ctor `0x26` → bit3 clear)이 남는다.
   Waple 의 `weBool`(태그 5 엄격, `:3820-3824`)이 `auto` 검사와 1:1 이고, `numericInt`(태그 1/2/3 게이트)가
   width/height 검사와 1:1 이다. 동봉 **172씬 전수** 실측(`scene.json` 171 + `gifscene.json` 1 — 파일명을 `scene.json` 으로 좁히면
   1건이 샌다, `docs/re/camera-motion.md:688`): `{width,height}` 166×256² + 640² + 600², `{auto:true}` **2**,
   부재 1, `null` 1 → 비숫자·0 width/height **0건**이라 값이 달라지는 씬 **0건**. `camera3D` 게이트 이동도 같은 이유로 무회귀
   (동봉 **169**씬이 ortho dict + camera 를 **동시에** 갖는다 — 게이트가 틀렸다면 전부 3D 로 새었을 것이다).
3. **`versionGatedGeneral` 묘비의 산수는 정본과 자릿수까지 맞는다**(`SceneDocument.swift:4060-4076`).
   `spec/corpus/scene-schema.json`: population `{5:63,1:33,4:32,3:31,None:3}`=162 · hdr/zoom/bloomhdr{strength,
   threshold,feather,scatter} 159 · bloomhdriterations 157 · bloomtint 142 · perspectiveoverridefov 130 ·
   wind/gravity 5키 109 — 전부 일치. 파생 하한 30(=159−129) · 13(=142−129) · 1(=130−129) · 11(=109−98) 재현됨.
   철회 커밋도 실재한다: `git -C ../Waple-wallpaper-source merge-base --is-ancestor 0bb963ed HEAD` → 참,
   `corpus_scan/scene-json-schema.md:191-201` 이 취소선 + `[CORRECTED 2026-08-28]` 정정문.
4. **camerashake·parallaxdelay·shake 수식·fov 클램프 주장 전건 확인.**
   camerashake 동봉 **0/168**(172문서 전수: `false` 168 · 부재 4 · `true` **0**) — 종전 "활성 13/168" 은 워크샵 162씬 표
   (canon `camerashake.values {False:150, True:12}` + dict 14)를 동봉 분모에 붙인 **모집단 혼합**이었고
   PR #8 이 이를 `docs/re/camera-motion.md:33·695·718·827`(C-7) 과 같은 값으로 고쳤다.
   `2D = amplitude·orthoHeight/100` · `3D = amplitude·0.1` · `roughness³` 지수 · `speed²` 위상 →
   `SceneGeometry.swift:65-88` 과 일치. `parallaxDelay` 주석의 `min(1, 10·(1−delay/3)·dt)` →
   `SceneGeometry.swift:138-140` 과 일치. `[0.1,179.9]` 클램프는 **정적·동적 쿼드 양쪽**에서 소비 직전에
   걸린다(`SceneRendererFrameEncoder.swift:644·677·725·872`, `quadVertices`/`quadProjectiveDepth` 진입부).
5. **`cameraParallaxRootsByOrder`(`SceneDocument.swift:1776-1797`)는 RE 문서의 비대칭을 지킨다.**
   `docs/re/camera-parallax-binary-2026-08-31.md:180-207` — 드로우 평행이동은 root(`0x14018b047`–),
   interaction 은 current(`0x14018a0a9`–, parent walk 없음). 렌더러가 둘을 따로 든다
   (`SceneRenderer.swift:2208-2209`, leaf 소비 `:667`·`:682`). cycle 은 `visited` 로 방어(실물엔 없는 하드닝),
   `order` 키는 `enumerated()` 산이라 `Dictionary(uniqueKeysWithValues:)` 가 트랩하지 않는다.
   워크샵 정본: `duplicateObjectIds` 0 · `danglingParentIds` 0 · `selfParent` 0 · `objectsWithoutId` {}.
6. **정수 좁힘·배열 인덱스는 내 레인 13파일에서 전건 가드 통과.**
   `grep -n "\bInt(\|Int32(\|UInt32(\|Int8(\|UInt16("` 후 남는 자리는 `JSONNumerics` 의 `safeInt`/`wrapInt32`/
   `wrapUInt32` **본체**와 `SceneDocument.swift:2076` 의 `Int(text[range])`(String→`Int?`)뿐이다.
   `safeInt`(:79-82)·`wrapInt32(Double)`(:267-272)·`wrapUInt32(Double)`(:300-305)의 경계식은 재검산해도 맞다.
   `obj["parallaxDepth"]` 의 camelCase 도 코퍼스대로다(테스트 픽스처 전건 camelCase).
