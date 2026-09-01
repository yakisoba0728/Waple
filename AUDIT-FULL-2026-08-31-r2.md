# 전체 감사 라운드 2 — Waple + Waple-wallpaper-source (2026-08-31, PR #8 직후)

> **지시**: 두 리포 전체 확인 · **수정 금지 — 발견만 기록**
> **대상 트리**: Waple `b883386e`(main, 작업 트리 깨끗) · RE 저장소 `1fac2a0c` + **미커밋 14파일**
> **구성**: 병렬 read-only 에이전트 16레인 + 오케스트레이터 검증. 코드 변경 0건.
> **이 문서만 새로 추가됐다** — 이 라운드는 기존 파일을 한 줄도 고치지 않았다.

## 0. 이 라운드가 왜 다른가

직전 감사(`AUDIT-FULL-2026-08-31.md`, 3,571줄)가 **같은 날** 끝났고 그 발견을 고친
**PR #8(`b883386e`)이 방금 병합됐다.** PR #8 은 작은 수정이 아니다 —
`SceneRendererFrameEncoder +785` · `SceneRenderer ±676` · `ParticleSimulator +586` ·
`AppDelegate ±356` · `SceneDocument ±298` · `ci.yml ±288` 등 48파일 규모다.

**그 수정 자체는 어떤 감사도 받지 않았다.** 그래서 이 라운드는 리포를 처음부터 다시 훑는 대신
**PR #8 이 (a) 주장한 결함을 실제로 고쳤는지 (b) 새 결함을 심었는지**에 무게를 뒀다.

결론부터: **PR #8 의 엔진 수정은 대체로 옳지만, 세 부류의 계통적 실패가 있다.**

| 부류 | 실측 |
| --- | --- |
| **반만 고친 수정** — 주장과 실제가 갈린다 | H6·M13·M19·M25·M22·스냅샷 축·oscillate 도수 등 **7건** |
| **새로 심은 실동작 결함** | 🔴 1 · 🟠 9 — H3·H4·H5·H6·H7·H10·H11·H12·H13 |
| **자기 diff 가 밀어낸 줄 번호 인용**(M10 재발) | **6레인이 독립적으로 검출** — 최소 20자리 |

세 번째가 특히 계통적이다. PR #8 은 대형 파일을 크게 고치면서 **자기 hunk 가 삽입한 오프셋만큼
밀린 줄 번호**를 새 주석에 적었다. 레인 1·2·3·4·5·11 이 서로 모르는 채 같은 부류를 잡았고,
레인 4 는 밀린 양이 **정확히 자기 hunk 의 +8** 임을 보였다. 직전 감사가 M10 으로 지목한
바로 그 결함이 같은 PR 안에서 재생산됐다.

### 발견 색인

| id | 심각도 | 요지 | 재현 |
| --- | --- | --- | --- |
| **C1** | 🔴 | 파티클 자식 CP 피드와 이미터 CP 평행이동이 겹쳐 **부모 위치를 2회 가산**(동봉 `thunderbolt.json`, 최대 450px). PR #8 이전엔 1회 | 코드 + 동봉 코퍼스 |
| **H1** | 🟠 | **WE 는 라이트 forward 로 모델행렬 열 0 을 쓴다. Waple 은 열 2.** 모든 `lspot`/`ldirectional` 광축이 90° 어긋난다 | 디스어셈블(아래 재현) |
| **H2** | 🟠 | 기지 **H6 이 반만 고쳐졌다** — `PuppetModel` 이 클립 `flags` 를 안 읽어 192B 레코드를 못 건너뛰고, 이미 파싱한 클립까지 전부 폐기 | 정본 + 코드 |
| **H3** | 🟠 | 부 화면 재생목록이 스테일 전역 선택 때문에 **전 후보 실패 → 매초 반복**, 사용자 통지 0 | 코드 경로 |
| **H4** | 🟠 | `g_ParallaxPosition` 신설 슬롯의 유일한 기록자가 `parallaxEnabled` 뒤 — `cameraparallax:false` 씬은 평생 (0,0) → 셰이더 `*2−1` 로 **최대 편향 고정**(중립은 0.5) | 코드 + 인트리 셰이더 |
| **H5** | 🟠 | `parallaxFocus` 마운트 기본이 화면 중앙이 아니라 (0,0) — 시작 상태가 "무이동"에서 "최대 편향"으로 뒤집혔다(1920px·amount 0.5 기준 480px) | 코드 |
| **H6** | 🟠 | `orthographicScene` 게이트가 마운트(전건 `.unhittable`)와 프레임 승격(게이트 없음)에서 갈린다 — projection-0 씬은 커서 훅 0, 애니 레이어만 첫 프레임에 부활 | 코드 |
| **H7** | 🟠 | 자식 파티클의 `previousRuntimeControlPoints` 가 부모 피드 종료 시 **얼어붙어** 낡은 선분이 매 프레임 재적용 → 초당 ~280px 발산 | 코드 + 수치 시뮬 |
| **H8** | 🟠 | F820(음량/배속 라이브 반영)이 `videoFallback` 경로 누락 — ffmpeg 부재 + webm 이면 **음량 메뉴가 아무 일도 안 하는데 체크마크만 옮겨간다** | 코드(아래 재현) |
| **H9** | 🟠 | 테스트 타깃 하나를 통째로 `XCTSkip` 하면 **세 게이트가 전부 초록**(존재 게이트가 스킵과 통과를 구별 못 한다) | 실물 로그(아래 재현) |
| **H10** | 🟠 | PR #8 신규 테스트가 **빈 배열끼리 비교**한다 — 잠근다고 주장한 클램프 호출을 지워도 초록 | 코드(아래 재현) |
| **H11** | 🟠 | `NOTICE` 가 폰트 목록 불일치를 **번들에 실재하는 폰트를 목록에서 지워서** 닫았다 | `git ls-files`(아래 재현) |
| **H12** | 🟠 | 스냅샷 셀프체크 수정이 **무효한 축을 골랐다** — 정본은 변동 축이 프로세스가 아니라 **세션**이라고 이미 확정 | 정본 대조 |
| **H13** | 🟠 | 스냅샷 helper 가 못 뜨면 기준선 **전건이 `lax`** 로 내려가고 exit 0(mean 1.5→12.75, frac 50×) | 코드 |
| **H14** | 🟠 | 베이스라인 `entries` 가 비면 `--compare` 가 0종 비교 후 exit 0(90% 하한이 `0 < 0` 으로 사문) | 코드 |
| **H15** | 🟠 | 접근성 게이트 2종이 각각 `Button { } label: { }` 표기와 **자식 오버레이 라벨**로 면제된다 — 지키는 메뉴 10개 중 2개가 이미 면제 중 | 파서 포트 + 돌연변이 |
| **H16** | 🟠 | **Tab 키만 쓰는 사용자는 인스펙터에 도달할 수 없다**(속성 편집기·모니터 할당·폴더·재생목록·제거 전부) | 코드 경로 |
| **H17** | 🟠 | `WebInputProxyView.swift:80` 한국어 리터럴이 `NSString.draw` 경로라 현지화 스캐너 4패턴 전부를 빠져나간다. 소스 주석의 "이 한 건뿐" 은 구멍 있는 패턴 자체로 잰 자기확인 | grep |
| **H18** | 🟠 | `package-app.sh:105` 의 `codesign --deep --identifier` 가 중첩 `Waple.saver` 식별자를 덮어쓴다(`--deep` 은 macOS 13 부터 서명 용도 폐기) | `man codesign` + 스크립트 |
| **H19** | 🟠 | `ZipImporter` 에 압축폭탄·여유공간 상한 0건 — 방어는 300초 *시간* 상한뿐 | `grep availableCapacity` = 0 |
| **H20** | 🟠 | `.corrupt-*` 백업을 **읽거나 알리는 코드가 리포 전체에 0건** — "복구 가능" 주석에 출구가 없다 | grep |

🟡 는 61건이다. 계통별 요지는 §4 에 묶었고, **레인별 원문(발견마다 `파일:줄` + 재현 명령,
합계 3,890줄)은 `docs/audit-r2-lanes/` 에 그대로 보존했다** — §4 의 한 줄 요약으로는 수정에
착수할 수 없기 때문이다(예: "BACKLOG 인용 21건 무효" 의 그 21건 목록은 `lane14-docs.md` 에 있다).

## 1. 기반 실측 (오케스트레이터 직접 측정)

| 항목 | 값 |
| --- | --- |
| Xcode / Swift | 27.0 Beta 5 / **6.4** (`swift test` 실행 가능) |
| 실물 코퍼스 | **없다** — `WAPLE_REAL_PKGS` 미설정, `~/Downloads/wallpaper_dev` 부재 |
| `swift test` | **실패 0 · 스킵 63 · 실행 4,016** (2분 45초, 7번들 26+1221+74+54+2135+30+476) |
| 정적 개수(정본 레시피) | **4,016** — 실행값과 정확히 일치(13번째 연속) |
| `xctest-census.py` 판정 | **4,016** — `ci.yml` 하한과 동일(**여유 0**) |
| Waple 작업 트리 | 깨끗(추적되지 않은 파일 0 — 기지 M1 해소) |
| RE 저장소 | HEAD `1fac2a0c`(2026-08-28) + **미커밋 14파일 +982/−106** |

> **기지 C1 은 닫혔다.** census 게이트가 `tail -1` 로 마지막 번들만 읽던 결함을
> `scripts/dev/xctest-census.py` 가 대체했고, 같은 로그를 세 방법(스크립트·정적 grep·번들 수동 합산)
> 으로 세어 전부 4,016 이 나왔다. 다섯 양상(클래스 소계·`All tests` 중첩·0건 번들·필터 실행·
> 단일 병합 번들) 처리도 합성 로그로 확인했다.

## 2. 🔴 C1 — 파티클 자식 시스템이 부모 위치를 두 번 더한다

- **자리**: `Sources/WapleCore/ParticleSimulator.swift:1219`·`:1251`(이미터 CP 평행이동) ↔ `:1262`(`emitOrigin` 가산) ↔ `:965`(자식 CP 피드)
- **기전**: 스폰 경로가 `p.pos = s3(origin) + frame.translation + framedDisplacement` 를 계산한 뒤
  `:1262` 에서 `p.pos += emitOrigin` 을 더한다. `frame.translation` 은 이미터가 참조하는 CP 의
  평행이동인데, `applyParentControlPointFeed`(`:987`)가 그 CP 슬롯을 **부모 파티클 위치로 덮는다.**
  `emitOrigin` 도 같은 부모 파티클 위치다 — 그래서 같은 값이 두 번 들어간다.
- **도달**: 동봉 `thunderbolt.json` → `thunderbolt_child_spawner`(`eventfollow` · `flags 1` ·
  `startIndex null→0`). 자식 CP0 이 부모 파티클 0번 위치로 덮이고, 그 spawner 이미터가 CP0 기본이다.
  CP1 이 `0 -450 0` 이라 **최대 450px** 어긋난다.
- **PR #8 이전에는 1회**였다. `frame.translation` 항이 이 PR 에서 들어왔다.

## 3. 🟠 H1 — 라이트 forward 열 인덱스 (직전 감사 미해결 #1 의 해소)

직전 감사는 이 축을 **미결로 남겼다**: *"WE 가 `L` 을 만들 때 모델행렬의 어느 열을 쓰는지 기록이
없다(정본·`docs/re` 에 0건). 다음 라운드가 팩커를 특정하려면 셰이더 상수버퍼 기록 자리를 찾아야 한다."*

**그 팩커를 특정했다: `FUN_140190c80`(V1 PBR 라이트 패커).**

```
$ python3 <capstone> binaries/wallpaper64.exe 0x140190c80 0x2400   # 함수 선두에서 정렬
directional:
  0x140191095  xorps xmm9, xmm9            ← s = 0
  0x140191162  xor   r8d, r8d              ← column index = 0
  0x1401911a6  call  0x14019d3e0           ← glm::column(mat4, 0)
  0x1401911db~ea  4× subss                 ← vec4(s) − column0
  0x140191208/15/24  store → g_LDirectional_Direction[i].xyz, .w=0
spot:
  0x140192dfa  mov   r8d, 3                ← column(M,3) = 월드 원점 → g_LSpot_Origin
  0x140192e79  xor   r8d, r8d              ← column(M,0) 무부호변경 → g_LSpot_Direction
```

`FUN_14019d3e0` 이 `glm::column` 임은 디컴파일 본문이 확정한다 —
`puVar1 = param_2 + (longlong)param_3 * 0x10`(16바이트 연속 = 열우선의 한 열)이고 어서션이
`D:\dev\we\windows\src\lib\include\glm\gtc\matrix_access.inl` · `index >= 0 && index < m.length()` 다.

셰이더가 확증한다 — `wallpaper_engine/assets/shaders/generic3.frag:118`:
```glsl
light += ComputePBRLight(normal, g_LDirectional_Direction[l].xyz, viewVector, …);
```
`common_pbr_2.h:317` 의 그 인자는 `L`(표면→광원)이므로 `L = −col0`, **forward = +col0** 로 일관된다.

**Waple 은 `Scene3DLighting.swift:355-357` 에서 `worldMatrix.columns.2`(+Z)를 쓴다.**
부호 규약은 자기 셰이더 안에서 정확히 되돌려진다(`Mesh3DShaders.swift:297` 의 `-light.axis.xyz`) —
**틀린 것은 열 인덱스 하나다.** `angles=(0,0,0)` 라이트에서 WE 는 `L=(-1,0,0)`, Waple 은 `L=(0,0,-1)`.

**정당화 주석의 반박**: `Scene3DLighting.swift:306-309` 이 근거로 든 WE 스크립트 API
`lib.sceneScript.d.ts` 의 `Mat4.forward() = "(Blue axis)"` 는 참이지만 **패커를 구속하지 않는다** —
V1 패커는 `forward()` 를 부르지 않고 `glm::column(m, 0)` 을 직접 부른다.

> **직전 감사의 기각을 뒤집는 것이 아니라 완성하는 것이다.** 그 감사는 워크플로가 올린
> "col0" 주장을 **좌표를 확인할 수 없어서** 기각했고, 부호 규약 화해는 옳게 해냈다.
> 이번에 그 좌표가 나왔다. 부호 결론은 그대로 유효하고 열 인덱스만 바뀐다.

- **같이 고쳐야 하는 자리**: `Tests/WapleRenderTests/Scene3DLightingTests.swift:271` ·
  `Tests/WapleCoreTests/SceneForwardLightKindTests.swift:6·37·48·103` 이 현재 규약을 잠그고 있다.
  `spec/` 에는 열 규약 기록이 **0건**이라 정본 수정도 함께 필요하다.
- **도달**: `docs/re/scene-lighting.md:750` 기준 워크샵 코퍼스 `ldirectional` 5 · `lspot` 5.

## 4. 계통별 🟡 (61건)

### 4.1 자기 diff 가 밀어낸 줄 번호 — 6레인 독립 검출
PR #8 이 새로 쓴 주석이 **자기 커밋의 pre-image 줄**을 가리킨다.
- 레인 4: `GLSLTranslator.swift:1527/1529/1717` → `:1640-1646` 인용, 실제 `:1648-1654`(**정확히 +8** =
  자기 hunk 삽입량). 따라가면 `g_LightAmbientColor` 가 아니라 `g_TexelSize` 블록에 도착.
  `ShaderPreprocessor.swift:638`(`:261`→실제 `:279`) · `:647`(`:401`→`:428`).
- 레인 5: `SceneRenderSettings.swift:58-59` 의 fitMode 소비처 5곳 중 4곳 무효(919/2433/2623/
  `VideoRenderer:200` → 992/2591/2826/215). **부모 커밋에서는 정확했다.**
- 레인 2: `TexImage.swift:64`(`:1834`→**2407**) · `:214`(`:38`→**117**).
- 레인 1: `SceneRendererResources.swift:363-366` 이 인용한 `SceneDocument.swift:729-730` 은 지금
  `queueMode` 설명이고, 그 주장 자체도 PR #8 이 반증했다.
- 레인 3: 4건 · 레인 11: `main.swift:167-169` 의 `--deep(:142)` 가 자기 +11 줄에 밀려 153.
- 레인 14 전수: **BACKLOG 의 `파일:줄` 28건 중 21건(75%) 무효**, 그중 19건이 PR #8 대형 수정 파일.
  살아 있는 열린 항목 3건이 엉뚱한 줄을 가리킨다.

### 4.2 반만 고친 수정
- **H6**(§H2) · **M13**: `HDRBloomPass.swift:5` 는 고쳤는데 **게이트를 실제로 소유한**
  `SceneRenderer.swift:1165` 에 "코퍼스 8" 이 그대로(정본은 3). PR #8 의 동기화 목록에 그 파일이 없다.
- **M25**: 정본만 고치고 `docs/re/shader-uniforms.md:820` 이 폐기된 `0x1404875f3` 를 계속 제시.
- **M22**: Waple 은 11 로 고쳤는데 짝 저장소 `corpus_scan/scene-json-schema.md:195` 는 "at least 13".
- **M19**: 정정이 짝 저장소 **미커밋 트리에만** 존재 — clone/CI 는 여전히 `[UNRESOLVED]` 를 본다.
  형제 `analysis/reports/mdl-tex-decoders-2026-08-27.md:144/322/557` 에도 3자리 잔존.
- **oscillate 도수**(동봉 코퍼스 계수 36+8+17=61): 정본의 "61건 전건" 은 **17건 과장**이다. `oscillateposition` 은 PR 이전부터
  진폭에 난수가 있었다(`p.oscPosScale = lerp(smin,smax,r)`). 실제 해당은 44건.
- **M21/M16 잔여**: `measure_workshop_shaders.py` 가 새로 쓴 `:914/:922/:891/…` 이 전부 pre-image 값.

### 4.3 정본·문서 드리프트
- `ci.yml:295`(PR #8 이 **새로 추가한 줄**)이 낡은 Metal census 77/324/575 재인용 —
  실측 **82/364/627**. 부모 커밋에서는 77/324/575 가 정확히 재현되므로 **PR #8 이 썩혔다.**
  같은 파일 `:419` 가 "값만 적으면 반드시 썩는다" 고 써 둔 자리다. (레인 12·13 독립 검출)
- `docs/README.md:61-65` 의 "이번에 실제 값으로 고쳤다" 표가 **3/3 다시 틀렸다**(552→563, 806→911, 4052→4158).
- `AGENTS.md:617-620` 이 인용한 `FUN_140261950` 은 `grep -rn … Sources/` = **0건**(이미 참 VA 로 교정됨).
- `README.md:46` 의 HDR 피라미드 "±0.5 source texels" 는 `b19db5b1`(08-21)이 ±1.0 으로 고친 뒤 미갱신.
- `spec/binaries-fingerprint.json` 미재생성 — 246/341/1211 → **245/340/1210**(원인: `mul-convention.json`
  evidence 1건 삭제). 값이 동적이라 리터럴 게이트가 못 잡고, 같은 자리 `population` 은 1,203 하드코딩.
- README "~99.9% 컴파일" 은 2026-07-06 도입 후 무갱신, 트리에 근거 0건.
- BACKLOG 가 `AUDIT-FULL-2026-08-31` 을 **0회** 참조 — 미해결분(H5 등)에 대응하는 항목 0건.
- BACKLOG 가 새로 넣은 "창 닫힘 오류 알림" 은 **이미 해소된 것**이고 근거 문장 `:461` 이 거짓.
- 셰이더 인용 2건이 범위 안이지만 다른 줄(`generic4.frag:3` · `genericparticle.frag:84`) —
  기지 M5 는 범위만 봐서 미검출.

### 4.4 RE 저장소
- `analysis/parse_pe.py:237-243` 이 `IMAGE_TLS_DIRECTORY64` 에 **없는 7번째 필드**를 읽어 구조체 밖
  바이트를 `characteristics` 로 쓴다(정본 `1`, 실제 `0x500000`). 옛 `pe_parse.py:175` 는 옳다 — **회귀**.
- `pe-structure.md:165/229-230` 의 delay-load "4개" 는 널 종결자를 센 것(실제 **3개**). 같은 표의
  IMPORT 행은 종결자를 옳게 뺐다.
- `pe-structure.md:224-226` 의 TLS 좌표 3개가 바이너리·형제 JSON 양쪽과 어긋난다(콜백 배열 실제
  `0x140426DA0`, 문서 `0x140492980`).
- `rtti-references.json` 의 유일 좌표가 **폐기된 결함 주입본** 기준이라 재현 불가.
- `WE-ENGINE-ANALYSIS:782` 의 오퍼레이터 VM 범위가 Waple 정본보다 **874B 짧다**.
- `.tex` 전수가 4,679 / 4,991 / 5,120 **세 값**으로 갈린다. 생성기가 "정본과 갈려 있다" 고 자백하는데
  정본에는 표시 0건.
- `measure_effect_fbo_audio.py:513` 이 입력 0 으로 정본을 다시 쓰고 **rc=0**(형제 18개는 rc=1·무쓰기).

### 4.5 게이트의 실효
- 동시성 진단 census 는 **상한 25 만** 있고 하한·패턴 생존 확인이 없어 grep 0건이 초록.
- 세이버 수명주기 테스트가 소스 grep 이고 **게이트를 뒤집어도 통과**한다(M8 수정의 행위 커버리지 0).
- 단언 0 테스트가 **추적 파일에 2건 더** 있다(`SingleSceneProbeTests`·`ThreeDV3CaptureTests`) —
  CI 가 게이트 env 를 어디서도 안 세팅해 **영구 스킵**인데 여유 0 인 하한 4,016 에 집계된다.
  직전 감사의 "1건 / 3,886" 은 이 둘을 놓쳤다.

## 5. 검증한 재현 (오케스트레이터 직접)

```bash
# H11 — 목록에서 지워진 폰트가 실재한다
git ls-files 'Sources/WapleRender/Resources/WEAssets/fonts/' | grep 8bit
#   → Sources/WapleRender/Resources/WEAssets/fonts/8bitOperatorPlus8-Regular.ttf
sed -n '34,40p' NOTICE   # "나머지 11종" 목록에 그 이름이 없다

# 산수도 애초에 틀렸다: 동봉 폰트 15 · 라이선스 텍스트 4 중 이름으로 폰트를 특정하는 것은 3
# (`SIL Open Font License.txt` 는 폰트 이름이 없다) → 근거 없는 폰트는 11 이 아니라 12.

# H9 — 스킵도 존재 게이트의 정규식에 걸린다
grep -m1 "' skipped (" test-full.log
#   → Test Case '-[WapleRenderTests.FFmpegConverterTests testConvertRoundtrip]' skipped (...)
#   게이트: re.findall(r"Test Case '-\[[A-Za-z0-9_]+\.([A-Za-z0-9_]+) ", log)  ← 그대로 매치
#   `Test Suite 'ForwardLightingGateProbeTests' passed` 도 전건 스킵에서 찍힌다.
#   executed 는 스킵 포함이라 하한 통과, 스킵 상한 100 에 여유 37 → 26·30 짜리 타깃이 들어간다.

# H10 — 빈 배열끼리 비교
sed -n '221,233p' Tests/WapleRenderTests/ScenePerspectiveOverrideFovRenderTests.swift
#   XCTAssertTrue(capped.isEmpty, …) 로 스스로 빈 것을 단언한 뒤
#   XCTAssertEqual(over, capped) / XCTAssertEqual(nan, capped)  ← [] == []

# H8 — videoFallback 은 필터에 안 걸린다
grep -n "compactMap { \$0 as? VideoRenderer }" Sources/Waple/AppDelegate.swift   # :653
grep -n "mountedVolume" Sources/WapleRender/WebRenderer.swift                    # :58 :175 :178 :355
#   RendererFactory.swift:49-51 → ffmpeg 부재 + webm ⇒ WebRenderer(mode:.videoFallback)
```

## 6. 기지 발견의 현재 상태

| 기지 | 상태 |
| --- | --- |
| C1 census 게이트 | ✅ **해소** — 3방법 검산 4,016 일치 |
| H1 `ZZTempSqrtVerify` | ✅ 해소(단, 같은 부류 2건 잔존 → §4.5) |
| H2 인용 census 게이트 | ✅ 해소 — `check_cited_address_census.py` 추적·`spec.yml:177` 배선·rc=0 |
| H3 `alphafade` | ✅ **완결** — 3분기 식이 정본과 분기 순서까지 일치, 경계 8종 통과. 도수는 **동봉 코퍼스**에서 재계수해 250/110/138 로 정본과 일치(워크샵 코퍼스 460종은 이 머신에 없다 — §7-1) |
| H4 oscillate | 🟡 **44/61** — 수식은 정확하나 정본 도수가 17건 과장. **동봉 코퍼스** 계수 alpha 36·size8·position17=61 중 position 은 PR 이전부터 난수가 있었다 |
| H5 Swift 6 진단 | ⚪ 늘지 않았다(정적 판정: `@MainActor` 20→20, `@unchecked Sendable` 4→4) |
| H6 `PuppetModel` MDLA | 🟠 **반만** — §H2 |
| H7 `particle-fields.json` | ✅ 해소 — 전용 게이트 rc=0 |
| H8 `parseLight` 기본값 | ✅ **여섯 값 전부** 고쳐졌다(`exponent` 2.0 을 `0x14019049e` 바이트로 재확인) |
| M3 숫자→bool 오타입 | ✅ **완전 해소** — 같은 기전의 나머지 5자리도 전건 닫힘, 실경로 테스트 2건이 잠금 |
| M4 재측정 스크립트 | ✅ 해소 — 40개 전부 무코퍼스 트레이스백 **0건**(종전 18) |
| M7 · M26 | ✅ 해소 |
| M11 정본 근거 검증 범위 | ✅ 해소 — `validate.py:104` `we_ref_path` 신설, 661/1,211 → **261/1,210** |
| M12 `CAST3X3`·`g_Bones` | ✅ 해소(모집단 분리·48) |
| M1 미추적 문서 | ✅ 해소(Waple 트리 깨끗) |
| M13 · M19 · M21 · M22 · M25 | 🟡 **반만** — §4.2 |
| M8 세이버 | 🟡 수정됐으나 **행위 커버리지 0** — §4.5 |

## 7. 검증 경계 — 이 라운드가 확인하지 못한 것

1. **실물 코퍼스 460종.** 이 머신에 없다. 도달 도수는 **동봉 코퍼스**와 정본 기록에 의존했다.
   C1 의 450px 도 동봉 `thunderbolt.json` 기준이다.
2. **픽셀 회귀.** `WapleCompat --capture/--compare` 를 돌리지 않았다. H1(라이트 열)·C1·H4·H5 가
   170씬 골든에 내는 diff 는 미확인이다.
3. **CI 실행.** `macos-26` 러너 실측은 없다. H9 는 이 맥의 실물 로그로 게이트 정규식을 재생한 결과다.
4. **Windows 동적 분석 · 서명/공증 실행.** H18 은 `man codesign` 과 스크립트 독해다.
5. **Swift 6 언어 모드 실제 전환.** 수정 금지 지시에 저촉돼 시도하지 않았다.
6. **빌드·테스트 재실행 없이 판정한 레인이 있다.** 16레인 전부 읽기 전용이었고, 기준 실행은
   오케스트레이터가 한 번만 돌렸다(4,016/0/63).

## 8. 이 감사가 손대지 않은 것

- **기존 파일 수정 0건.** 두 저장소 모두 16레인 종료 후 재확인했다:
  Waple 은 `?? AUDIT-FULL-2026-08-31-r2.md` 와 `?? docs/audit-r2-lanes/` **둘 다 신규 추가분뿐**이고
  추적 파일의 변경은 0건이다. RE 저장소는 감사 **이전과 정확히 같은 14파일**(+982/−106)이고
  이 라운드가 더한 변경은 없다.
- **새로 추가한 것 둘 다 아직 추적되지 않은 상태다** — 직전 감사의 M1 이 지목한 바로 그 조건이므로
  수정 PR 과 함께 커밋할 것.
- **커밋·푸시·스태시 0건.** RE 저장소의 미커밋 14파일도 그대로 뒀다.
- 레인 16 이 재현 과정에서 `spec/engine/effect-fbo-audio.json` 의 **mtime 만** 바꿨다
  (내용 바이트 동일, `git status` 깨끗).

## 9. 권고 순서

1. **C1 · H1** — 픽셀이 실제로 틀린다. H1 은 테스트 5자리와 `spec/` 기록 신설이 함께 간다.
2. **H2 · H4 · H5 · H6 · H7 · H3 · H8** — 실동작 결함. H4/H5 는 한 줄짜리 중립값 수정이다.
3. **H9 · H10 · H12 · H13 · H14** — 게이트가 거짓 초록을 낸다. 다음 라운드의 판정 근거가 여기 걸려 있다.
4. **H11** — 라이선스 고지. 재배포 전에 닫아야 한다.
5. **§4.1 줄 번호 20자리** — 기계적이지만, 이 리포가 M10 으로 이미 한 번 지목한 결함의 재발이다.
   개별 수정보다 **줄 번호 인용 자체를 심볼명으로 바꾸는 규약**을 세우는 편이 싸다.
6. **RE 저장소 미커밋 14파일** — 3일째 백업도 CI 도 없다. M19 정정이 거기 갇혀 있어
   clone 하는 쪽은 아직 `[UNRESOLVED]` 를 본다.

---

**구성**: 16 read-only 레인 — Core JSON · Core 바이너리 · 파티클 · GLSL→MSL · 렌더 파이프라인 ·
3D/블룸 · 미디어 · 앱 계층 · UI · 라이브러리/세이버 · 호환성 CLI · 테스트 오라클 · CI/게이트 ·
문서 드리프트 · RE 도구 · 정본 무결성. 상위 발견은 오케스트레이터가 디스어셈블·로그·grep 으로 재현했다.
