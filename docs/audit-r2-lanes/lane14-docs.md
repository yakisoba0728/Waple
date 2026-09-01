# 레인 14 — 문서·정본 ↔ 코드 드리프트 (HEAD `b883386e`, 2026-08-31)

전제: 읽기 전용. 빌드·테스트 미실행. 모든 수치는 `grep`/`wc`/`sed`/`git`/`python3` 단발로 재계산했다.

---

## 🟠 L14-1 — PR #8 이 NOTICE 의 폰트 개수를 맞추려고 **실제로 근거가 없는 폰트 한 종을 목록에서 지웠다**

- **자리**: `NOTICE:32-35` (§0.1 「동봉본 안의 서드파티 폰트」)
- **PR #8 이 한 일**:
  ```bash
  git show b883386e -- NOTICE
  # -**나머지 11종은 이 리포 안에 라이선스 근거가 없다** — `8bitOperatorPlus8-Regular.ttf`,
  # +**나머지 11종은 이 리포 안에 라이선스 근거가 없다** —
  ```
  종전 목록은 이름 **12개**를 열거하면서 라벨은 "11종" 이었다(라벨이 틀리고 목록은 옳았다).
  PR #8 은 그 불일치를 **목록에서 이름 하나를 지워서** 닫았다.
- **근거/재현**:
  ```bash
  # 그 폰트는 지금도 동봉돼 있다
  git ls-files 'Sources/WapleRender/Resources/WEAssets/fonts/*'
  #   8bitOperatorPlus8-Regular.ttf   ← 실재
  # 폰트 파일 15종(.ttf 11 + .otf 4), 라이선스 텍스트 4종(.txt)
  git ls-files Sources/WapleRender/Resources/WEAssets | grep -icE '\.(ttf|otf|ttc)$'   # 15
  # 정본도 같다: spec/assets/inventory.json → assets.dirBreakdown.fonts = {files:19}
  #   (15 폰트 + 4 텍스트), extensionBreakdown .ttf 11 · .otf 4
  # 그 폰트를 이름으로 덮는 라이선스 텍스트는 없다
  ls Sources/WapleRender/Resources/WEAssets/fonts/*.txt
  #   monof_tt-be11.txt · RobotoMono-Regular License.txt · SIL Open Font License.txt · twemojimozilla.txt
  ```
- **산수가 애초에 틀렸다**: NOTICE 의 표는 텍스트 4건 중 `SIL Open Font License.txt` 를
  **"OFL 계열"**(폰트 이름 없음)에 매핑한다. 즉 **이름으로 덮이는 폰트는 3종**
  (`Monofur-PK7og.ttf` · `RobotoMono-Regular.ttf` · `TwemojiMozilla.ttf`)이다.
  `15 − 4 = 11` 은 "텍스트 개수" 를 "폰트 개수" 에서 뺀 것이라 성립하지 않는다.
  이름 근거가 없는 폰트는 **12종**이고, PR #8 이후 목록은 11종만 적는다.
- **왜 문제인가**: 이건 재배포 시 확인해야 할 **법적 고지 문서**다. PR #8 이후
  `8bitOperatorPlus8-Regular.ttf` 는 동봉돼 있으면서 "근거 없음" 목록에도 없어
  독자가 그것을 근거 있는 4건 중 하나로 읽게 된다. 게다가 같은 문단은
  `NotoSans-Regular.ttf` 를 **OFL 전문이 트리에 있는데도** "근거 없음" 으로 남겨 두고
  그 이유를 명시한다("OFL §2 가 요구하는 저작권 고지가 없다") — 8bitOperatorPlus8 도
  OFL 계열이므로 **같은 근거로 목록에 남아 있어야 한다**. 처리가 서로 반대다.
- **부수**: 이 리포는 모든 정정에 툼스톤(`[정정 YYYY-MM-DD]`)을 붙이는 규약인데,
  이 삭제만 툼스톤 없이 들어갔다. 삭제 사유가 문서에 남지 않았다.
- **심각도 주석**: 내용 자체는 브리핑 루브릭의 🟡(문서 거짓)이지만 **PR #8 이 새로 심은 회귀**이고
  대상이 법적 고지라 🟠 로 올린다. 실동작(픽셀·게이트)에는 영향이 없다.
- **기지 목록 대조**: 해당 없음 (AUDIT-FULL 의 M-목록에 NOTICE 폰트 항목이 없다).
- **부수 확인(문제없음)**: `2,940 파일 / 75.8MB` 는 **정확하다** —
  `git ls-files -z … | xargs -0 stat -f %z | awk` = **79,515,997 바이트 = 75.83MB**,
  `spec/assets/inventory.json` 의 `assets.totalBytes` 와 바이트 단위로 일치.

---

## 🟡 L14-2 — `AGENTS.md` 가 "소스 두 자리가 폐기된 VA 이름을 가리킨다" 고 적는데, HEAD 소스에 그 이름은 **0건**이다

- **자리**: `AGENTS.md:617-620`
- **문면**: *"(`Model3D.swift:110`·`ProjectJSONParser.swift:208` 이 rich header 주입본 시절 이름
  `FUN_140261950` 을 가리킨다. 참 VA 는 `FUN_140261880`). … **여기 두 번 적어서 또 썩었다.**"*
- **근거/재현**:
  ```bash
  grep -rn "FUN_140261950" Sources/          # 0건
  sed -n '110p' Sources/WapleCore/Model3D.swift
  #   /// 짝 저장소 `analysis/decompiled/all/0000000140261880__FUN_140261880.c`)   ← 참 VA. 이미 교정됨
  sed -n '208p' Sources/WapleCore/ProjectJSONParser.swift
  #   ///   FUN_140086eb0(param_1,"playbackfocus","") — 짝 저장소                  ← MDL 과 무관
  ```
  `FUN_140261950` 잔존 자리는 **Tests 2파일(전부 명시적 툼스톤)과 docs 뿐**이고 Sources 는 깨끗하다.
  `Model3D.swift` 는 `:117` 에서 스스로 *"사라진 게 아니라 이름이 바뀌었다"* 라고 이미 기록한다.
- **왜 문제인가**: AGENTS.md 는 "코드를 만지기 전에" 필독으로 지정된 문서다. 여기 적힌
  "부채가 남아 있다" 는 서술이 이미 갚은 부채를 다시 갚게 만든다 — 이 문서가 바로 그
  문단에서 자기 손으로 경고한 실패 양상("여기 두 번 적어서 또 썩었다")이 그대로 재발했다.
- **기지 목록 대조**: 해당 없음. AUDIT-FULL 의 M10 은 *소스 주석*이 자기 diff 로 밀린 줄을
  인용하는 부류이고, 이건 **AGENTS.md 가 소스의 내용 자체를 틀리게 기술**하는 것이다.

---

## 🟡 L14-3 — `docs/README.md` 의 「드리프트 실측」 표 3건이 **3/3 전부 다시 틀렸다** — PR #8 이 그 파일을 편집하면서 두 줄 위를 확인하지 않았다

- **자리**: `docs/README.md:61-65`
- **문면**: *"대표 3건(**이번에 실제 값으로 고쳤다**)"* 로 시작하는 표.
- **근거/재현**:

  | 표의 문면 | 표가 적은 "실제" | HEAD 실측 | 재현 |
  | --- | --- | --- | --- |
  | `re/material-blend.md` `SceneRendererResources.swift:488` | **552** | **563** | `grep -n 'blendAdditive: layer.blendMode == "additive"' Sources/WapleRender/SceneRendererResources.swift` |
  | `re/material-blend.md` `SceneRenderer3D.swift:781` | **806** | **911** | `grep -n 'additive = blend == "additive"' Sources/WapleRender/SceneRenderer3D.swift` |
  | `re/bundled-key-coverage.md` `SceneDocument.swift:981` | **4052** | **4158** | `grep -n 'out.lightConfig = SceneLightConfig' Sources/WapleCore/SceneDocument.swift` |

  (원본 `docs/re/material-blend.md:459`·`:461`, `docs/re/bundled-key-coverage.md:443` 도 같은 값이라
  같이 무효다 — 세 자리 다 `[줄번호 재측정 2026-08-28]` 이라고 명시돼 있다.)
- **PR #8 과의 관계**: PR #8 은 `docs/README.md` 를 실제로 편집했고(`:110-113` 「후속 2026-08-31」
  블록 추가), 같은 파일 **50줄 위**의 실측 표는 재검증하지 않았다. 세 대상 파일은 전부
  PR #8 이 크게 고친 파일이다(`SceneRendererResources +79` · `SceneRenderer3D ±245` · `SceneDocument ±298`).
- **왜 문제인가**: 이 표는 "인용은 드리프트한다" 규약의 **근거 예시**로 쓰인다. 규약 자체는
  옳지만, 예시가 3/3 틀리면 독자가 "552 로 가면 된다" 로 읽고 다시 엉뚱한 줄을 읽는다.
  같은 절이 *"줄번호 전수 갱신은 하지 않는다"* 를 선언하므로 **표를 지우거나 식별자 grep 으로
  바꾸는 것**이 규약과 정합한다 — 지금 형태는 규약이 금지한 짓을 규약 옆에서 하고 있다.
- **기지 목록 대조**: 해당 없음.

---

## 🟡 L14-4 — `BACKLOG.md` 의 `파일:줄` 인용 전수 대조: **28건 중 21건 무효(75%)** — 그중 **살아 있는 항목 3건**이 엉뚱한 줄을 가리킨다

`docs/README.md` 가 선언한 드리프트 면책은 **`docs/re/**` 에 한정**된다. BACKLOG 는 그 면책 밖이고,
이 리포가 "무엇을 할지 찾을 때" 읽으라고 지정한 원장이다.

- **재현**:
  ```bash
  grep -noE '[A-Za-z0-9_+]+\.(swift|m|h):[0-9]+(-[0-9]+)?' BACKLOG.md
  # 각 자리를 sed -n '<N>p' <파일> 로 열고, 인용문이 함께 적은 식별자를 grep 으로 재탐색
  ```

### 살아 있는(열린) 항목의 무효 인용 — 우선순위 높음

| BACKLOG | 인용 | 인용이 주장하는 것 | HEAD `:N` 의 실제 내용 | 진짜 자리 |
| --- | --- | --- | --- | --- |
| `:448` 잠재결함 **열린 항목** | `GLSLTranslator.swift:155` | "GLSL 공용 헬퍼의 스테이지별 하위 헬퍼 호출 리네임 누락" | `static func _resetTranslationMemoForTesting() {` (테스트 리셋 함수) | 미상 |
| `:192` D3 **열린 항목** | `SceneRenderer3D.swift:1043` | "화이트리스트는 `generic{,2,3,4}` 4종뿐" | `customShader: customShader, customCombos: customCombos,` | **1184** (`builtinMeshShaderWhitelist`) |
| `:490` wind/gravity **열린 항목** | `SceneDocument.swift:861-865` | "wind/gravity 파스·보존 전용 필드" | `public var attachment` / `order` 문서 주석 | **1565**(선언 주석) · **4147**(`out.windEnabled = …`) |

### 나머지 전수

| 인용 | 판정 | 진짜 자리 |
| --- | --- | --- |
| `GLSLTranslator.swift:104` `("a_Normal", .vec3, 2)` | ✅ 정확 | 104 |
| `MediaPoller.swift:40` `t.fire()` | ✅ 정확 | 40 |
| `FFmpegConverter.swift:68` `maxCachedConversions = 8` | ✅ 정확 | 68 |
| `GoldenBaselineOracleTests.swift:29` `currentLabel = "baseline-6f0bcf0"` | ✅ 정확 | 29 |
| `HDRBloomPass.swift:46` (BACKLOG 자기 정정이 "blend 와 무관한 W-20 문장" 이라고 적음) | ✅ 서술대로 | 46 |
| `PropertyEditorView.swift:55` | — 툼스톤(2026-07-13 당시 값이라고 자백) | — |
| `SceneRenderer.swift:964` `accPixelFormat` 대입부 | ✗ (BACKLOG 가 "grep 권장" 으로 자기면책) | **1193** |
| `TextRasterizer.swift:114` pointSize 축소 재시도 | ✗ | **147** |
| `TextRasterizer.swift:117` `guard reduced > 0, reduced < pointSize` | ✗ | **148** |
| `GLSLTranslator.swift:1695` `g_Color4` 등재 | ✗ | **1723** |
| `SceneRenderer3D.swift:1039-1042` a_Normal 무조건 참조 주석 | ✗ | **1169-1172** |
| `SceneRenderer3D.swift:1070-1073` 자기정정 주석 | ✗ | **1178** |
| `SceneRenderer3D.swift:1145` 정점 디스크립터 배선 | ✗ | **1250·1256** |
| `GLSLTranslator.swift:1797` "VIn 은 a_Position/a_TexCoord 만" | ✗ | **110** (`alwaysLoadedVertexAttributes`) |
| `GLSLTranslator.swift:1808` `EngineU`(320B) | ✗ | **2222** |
| `SceneRenderer.swift:1385` `currentSpectrum` 초기값 `.silent` | ✗ | **1525** |
| `SceneRenderer.swift:1421` mount 의 `parallaxEnabled \|\| hasEffects` 모니터 기동 | ✗ | **1263**(주석) |
| `SceneRenderer.swift:1535` pointerUV 콜백 | ✗ (실제 1535 = `var audioProvider`) | — |
| `SceneRenderer.swift:2151` `if hasAudio, container.window != nil` | ✗ (주석 산문) | — |
| `SceneRenderer.swift:2170`·`:2178` `SystemAudioSpectrumProvider.onFrame` 둘 | ✗ (둘 다 주석 산문) | **2316·2324** |
| `SceneRenderer.swift:2375` `draw(in:)` 의 `pointerButton.endFrame()` | ✗ | **2529** |
| `SnapshotPipeline.swift:249` `pinRenderSettings` | ✗ | **404** |
| `SceneRendererFrameEncoder.swift:53` `g_PointerPosition` 피드 | ✗ (1줄 밀림) | **54** |
| `ShaderPreprocessor.swift:38-40` 콤보 전처리 | ~ 부분 일치(`:39` = `var defines = combos`) | 39 |

- **왜 문제인가**: 21건 중 **19건이 PR #8 이 크게 고친 파일**(`SceneRenderer ±676` ·
  `SceneRendererFrameEncoder +785` · `SceneRenderer3D ±245` · `SceneDocument ±298` ·
  `GLSLTranslator +94` · `SnapshotPipeline ±113`)을 가리킨다. PR #8 이 코드를 옮기면서
  BACKLOG 를 한 줄도 안 따라갔다. 특히 **열린 항목 3건**은 착수하는 사람이 첫 걸음에서
  엉뚱한 코드를 읽게 되고, 그중 `GLSLTranslator.swift:155` 는 **진짜 자리를 못 찾았다**
  (인용이 식별자를 함께 적지 않아 `docs/README.md` 의 "식별자로 grep" 우회로도 막혔다).
- **기지 목록 대조**: 해당 없음. M10 은 소스 주석 6자리, M21 은 정본 evidence ref 5건이고
  BACKLOG 는 그 두 모집단 어디에도 없다. AUDIT-FULL 이 잰 셰이더 인용 드리프트율 3/634(0.5%)와
  대비되는 값이다 — **BACKLOG 는 75%**(28건 중 21건).

---

## 🟡 L14-5 — 현행(색인된) 문서 4곳의 **파일 줄수 인용**이 낡았다 — 셋은 PR #8 이 밀어냈다

- **자리·근거**:

  | 자리 | 인용 | HEAD `wc -l` | 밀린 양 | PR #8 |
  | --- | --- | --- | --- | --- |
  | `docs/dev/linux-typecheck.md:350` | `Sources/Waple/AppDelegate.swift`(**1,386**줄) | **1,921** | +535 | `AppDelegate.swift ±356` |
  | `docs/re/fluid-simulation.md:1824` | `SceneRendererFrameEncoder.swift`(**2,358**줄) | **2,946** | +588 | `+785` |
  | `docs/re/fluid-simulation.md:1823` | `SceneRendererResources.swift`(**2,501**줄) | **2,683** | +182 | `+79` |
  | `docs/re/fluid-simulation.md:1822` | `EffectManifest.swift`(**564**줄) | **750** | +186 | 무관 |

  ```bash
  wc -l Sources/Waple/AppDelegate.swift Sources/WapleRender/SceneRendererFrameEncoder.swift \
        Sources/WapleRender/SceneRendererResources.swift Sources/WapleCore/EffectManifest.swift
  ```
- **왜 문제인가**: `docs/dev/linux-typecheck.md` 는 `docs/README.md:19` 가 **현행 문서**로
  싣는 "맥이 없을 때의 유일한 그물" 이고, 그 줄수는 「커버 밖 넷」 표에서 **제외 범위의 크기**를
  독자에게 알리는 수치다. 실제 제외 범위가 1.4× 커졌는데 표는 종전 값을 말한다.
  `docs/README.md` 의 드리프트 면책은 `파일:줄` **인용**에 대한 것이지 **줄수 통계**에는 적용되지 않는다
  (줄수는 식별자 grep 으로 우회할 수 없다).
- **같은 표의 나머지는 정확했다**: `Sources/Waple/main.swift`(47줄) ✅ ·
  `AppDelegate.swift:11` 의 `ScreenCountBaseline` ✅ · `APP_EXCLUDED`/`APP_TEST_EXCLUDED` 는
  `scripts/dev/linux-render-typecheck.sh:172·176` 에 실재 ✅.
- **기지 목록 대조**: 해당 없음.

---

## 🟡 L14-6 — `BACKLOG.md` 가 **최신 감사를 한 번도 참조하지 않는다** — PR #8 이 미해결로 남긴 발견에 대응하는 항목이 0건

- **자리**: `BACKLOG.md:29` (*"상세 근거는 [AUDIT.md](AUDIT.md)(감사 리포트, **2026-07-06** — 이력)와
  [docs/README.md](docs/README.md) 참조"*) 및 문서 전체.
- **근거/재현**:
  ```bash
  grep -c "AUDIT-FULL" BACKLOG.md            # 0
  grep -c "AUDIT-FULL" AGENTS.md README.md   # 0 · 0
  grep -c "AUDIT-FULL" docs/README.md        # 2   ← "최신 감사" 로 싣는 유일한 자리
  for id in H5 M8 M11 M12 M19 M22 M24 M25 M26; do printf "%s:" $id; grep -c "\b$id\b" BACKLOG.md; done
  # 전부 0
  ```
- **미해결이 확인된 예 (H5, Swift 6 전환)**:
  ```bash
  head -1 Package.swift                       # // swift-tools-version:5.9  → 언어 모드는 여전히 Swift 5
  grep -n "고유 진단은 25자리" .github/workflows/ci.yml
  # ci.yml:126  [2026-08-31] 깨끗한 Xcode 27/Swift 6.4 빌드에서 Sources 고유 진단은 25자리다
  ```
  즉 감사가 🟠 로 올린 "Swift 6 전환 잔여 진단"(32 → 25 로 줄었을 뿐 전환은 미착수)이
  **CI 주석에만 살아 있고 BACKLOG 원장에는 항목이 없다.**
- **왜 문제인가**: BACKLOG 머리말이 이 문서를 "무엇을 할지 찾을 때" 보는 자리로 규정하고
  섹션 표로 "지금 열려 있는 것" 을 제공한다. 3,571줄짜리 최신 감사의 미해결분이 그 표에
  한 줄도 없으면, 다음 라운드는 BACKLOG 를 읽고 잔여를 실제보다 작게 본다 —
  섹션 표 `BACKLOG.md:21` 의 「잠재 결함」 행은 "주요 잔여" 로 두 항목만 싣고,
  그 두 항목이 곧 그 섹션의 열린 전부다. PR #8 이 감사 문서 자체는 리포에 넣었으므로
  기록은 남았지만 **원장으로는 연결되지 않았다.**
- **참고(과잉보고 방지)**: PR #8 이 실제로 닫은 것은 확인했다 — M23(`measure_workshop_shaders.py:212`
  `PYTHON_RECURSION_FLOOR` 추가) · M8(`WapleSaverView.m` `reloadContentIfNeeded` + 파일 identity) ·
  M15(AGENTS 의 "단언 15건" 삭제) · M6(제품화 표 요약행 교체) · M5(README `:61`→`:78`) ·
  H3/H4(`ParticleSimulator`) · H8(`SceneLight3D.WEDefaults`). 위 지적은 **닫지 않은 것**에 대한 것이다.
- **기지 목록 대조**: 해당 없음(M6·M18 은 BACKLOG 개별 항목의 판정 오류이고, 이건 원장 연결 부재다).

---

## 🟡 L14-7 — 셰이더 인용 2건이 **범위 안이지만 다른 줄을 가리킨다** — AUDIT-FULL 의 M5 전수 스윕이 못 본 부류

M5 의 634건 스윕은 **줄 번호가 파일 길이 안인지**만 봤다(감사 §M5: *"실물 셰이더의 줄 수와 대조했다"*).
내용 대조로 다시 돌리자 2건이 나왔다. 동봉 셰이더는 고정 아티팩트(WE 2.8.42)라 **드리프트가 아니라
처음부터 틀린 것**이다.

- **자리 1**: `Sources/WapleRender/SceneRenderer3D.swift:950`
  ```
  // M6(⑥): REFLECTION 콤보(WE 기본 0 — generic4.frag:3 [COMBO] default:0).
  ```
  ```bash
  grep -n 'COMBO' Sources/WapleRender/Resources/WEAssets/shaders/generic4.frag | head -4
  # 3: …"combo":"FOG","default":1        ← 인용이 가리키는 줄
  # 4: …"combo":"REFLECTION","default":0 ← 진짜 자리
  ```
  주장(REFLECTION 기본 0)은 **옳고** 줄만 1 어긋난다. `:3` 을 읽으면 `default:1` 이 나와
  근거가 정반대로 읽힌다.

- **자리 2**: `Sources/WapleRender/ParticleShaders.swift:137`
  ```
  // (genericparticle.frag:84 `DecompressNormalWithMask(texSample2D(g_Texture1, v_TexCoord.xy))`).
  ```
  ```bash
  sed -n '84p;86p' Sources/WapleRender/Resources/WEAssets/shaders/genericparticle.frag
  # 84: (빈 줄)
  # 86: 	vec4 normal = DecompressNormalWithMask(texSample2D(g_Texture1, v_TexCoord.xy));
  ```
  2줄 밀림.

- **왜 문제인가**: 둘 다 "실물 셰이더 원문이 근거" 라고 주장하는 자리다. 인용을 따라가면
  근거가 없거나(빈 줄) 반대 값(`default:1`)이 나온다. M5 가 "631건은 범위 안" 으로 닫았기
  때문에 이 부류는 아직 한 번도 검사된 적이 없다.
- **재현 스크립트**(이번에 쓴 것): 각 `<name>.(frag|vert|h):N` 인용에 대해 인용문 주변 ±90자에서
  `g_*`/대문자 토큰을 뽑아 실제 줄 본문에 하나도 없으면 의심으로 표시. 17건 중
  15건은 거짓 양성(토큰이 산문에만 있음)이고 위 2건이 진짜였다.
- **기지 목록 대조**: **M5 의 미검출분**(같은 자리 부류, 다른 검사 축).

---

## ⚪ 관찰 (발견으로 올리지 않음)

- `docs/README.md:31` *"`docs/re/` 는 33개 문서"* — 지금 **36개**(PR #8 이 3건 추가:
  `camera-parallax-binary-2026-08-31.md` · `next-engine-parity-2026-08-31.md` ·
  `particle-emitter-controlpoint-binary-2026-08-31.md`). 다만 그 문장은 `[2026-08-25]` 툼스톤
  안이고 `git ls-tree b883386e^ docs/re | wc -l` = 33 이라 **작성 시점 값으로는 옳았다.**
  같은 절 `:32` 의 *"소스와 테스트가 191곳에서 인용"* 도 지금은 **196**(`grep -rn "docs/re/" Sources Tests | wc -l`).
- `README.md:155-156` — 코드블록의 `Tests/` 설명이 *"— the one canon"* 에서 끊긴다.
  `git log -L 153,158:README.md` 로 보면 `bfa0f130` 이 숫자를 정본 포인터로 바꾸며 의도적으로
  적은 동격구로 읽을 수 있어 결함으로 올리지 않는다.
- `README.md:71` *"CI builds on Swift 6.3.2 and development on 6.4"* — 로컬은 Xcode 27.0 Beta 5 /
  Swift 6.4 로 README 서술과 정합. CI 쪽 6.3.2 는 이 환경에서 검증 불가(러너 로그 필요).
  `ci.yml:87` 은 `runs-on: macos-26`(기본 Xcode 26.x)이라 모순은 아니다.

---

## 확인했지만 문제없던 것 (다음 라운드의 시간을 아끼려고 적는다)

1. **문서 색인 무결성 — 구멍 0.** `docs/README.md` 가 색인하지 않은 `docs/` top-level 파일 **0건**,
   색인하지 않은 `docs/re/**` 파일 **0건**(브리핑의 세는 법 그대로 재실행). 기지 M1 은 재발하지 않았다.
   `docs/history/` 개수도 정합: `plans 29 + specs 37 + 직속 5 = 71` = `docs/README.md:89`·`history/README.md:3` 의 71.
2. **테스트 개수 정본 레시피의 불변식 3건이 전부 성립한다.** 현재 트리 실측:
   정본 레시피 **4,016** · 앵커 없는 `'func test'` **4,016**(AGENTS 가 "같은 값" 이라고 적은 대로) ·
   `'^\s*func test'` **4,007**(AGENTS 가 "언제나 정확히 9 를 흘린다" 고 적은 대로).
   `ci.yml:782` 하한 4,016 · `BACKLOG.md:3` 4,016 · `Tests/` 타깃 7개(`README.md:155` 와 일치) — 전부 정합.
   AGENTS 의 래칫 로그가 3,875 에서 멈춘 것은 그 문서가 스스로 "값은 스냅샷, 게이트는 ci.yml" 로
   규정하므로 결함이 아니다.
3. **동봉 에셋 통계 정확.** 2,940 파일 / 79,515,997 바이트(75.83MB) — README:91 · NOTICE:9·127 ·
   AGENTS:638 · `spec/assets/inventory.json` 네 곳이 바이트 단위로 일치. `lut/*` **28개**도 README:38 과 일치.
4. **README 기능 매트릭스는 PR #8 이후에도 유효하다.** `type3D` 소비처 **0건**(`grep -rn type3D Sources/`)
   → Textures 🟡 유지 정당. `hdr_downsample.frag:78` = `albedo *= 0.25 * g_BloomScatter;` **정확**
   (PR #8 이 M5 를 제대로 고쳤다). 파티클 alphafade/oscillate 와 `parseLight` 기본값 수정은
   🟡/✅ 판정을 바꾸지 않는 정확도 수정이라 매트릭스 갱신 불필요.
5. **AGENTS.md 인용 6건 중 5건 정확**: `Package.swift:59`(의존 4개 열거) ✅ ·
   `AudioResponse.swift:2`(`import simd`) ✅ · `Package.swift:39-45`(리눅스 경고 실측) ✅ ·
   `GoldenBaselineOracleTests.swift:80`(해당 테스트 함수 선언, 단언은 :83 — 허용 범위) ✅.
   틀린 하나가 L14-2 다.
6. **BACKLOG 의 셰이더 인용 4건 전부 정확**: `generic.vert:6`(`g_EyePosition`) ·
   `generic.vert:7`(`g_LightsPosition[4]`) · `generic.frag:4`(`g_LightsColorRadius[4]`) ·
   `hdr_downsample.frag:61,78`(선언·본문 둘 다). `Scene3DLighting.swift:50` 의
   `generic2.frag:79-81` 도 `#if HDR / albedo.rgb *= g_Brightness / #endif` 로 정확.
7. **NOTICE §0.1 을 뺀 나머지 NOTICE 절은 대조 항목 없음**(RePKG MIT 등 외부 고지 원문).
8. **`AUDIT.md`(2026-07-06) · `WAPLE-ANALYSIS-SUMMARY-2026-08-27.md` 는 자기 날짜를 명시한
   이력 문서**라 현행 수치와의 차이를 드리프트로 보지 않았다. 다만 BACKLOG:29 가 "상세 근거" 로
   `AUDIT.md` 만 가리키는 것은 L14-6 에 포함했다.
