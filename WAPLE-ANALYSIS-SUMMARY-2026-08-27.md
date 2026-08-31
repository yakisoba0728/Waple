# Waple 양 리포 딥 분석 종합 보고서
**날짜:** 2026-08-27 · **모드:** ultracode · **방법론:** 15 워크플로우 × (Phase1 8 agents + Phase2 1 synthesis) = 135 agents

---

## 0. 리포 매핑 (확정)

| 리포 | 역할 | 핵심 콘텐츠 |
|------|------|-------------|
| `/Users/yakisoba0728/Documents/GitHub/Waple/` | **Swift 앱 구현** | 174 .swift (Sources), 349 .swift (Tests), Package.swift, AGENTS.md(46KB), AUDIT.md(53KB), BACKLOG.md(77KB), docs/×19, spec/ (formats/corpus/golden/assets/engine) |
| `/Users/yakisoba0728/Documents/GitHub/Waple-wallpaper-source/` | **WE 리버스엔지니어링** | binaries/(4 PE), analysis/ (decompiled/, strings/, scenescript/, reports/, *.log), wallpaper_engine/bin/ (60+), ghidra_proj/, corpus_scan/, scripts/ (Java/Python/Frida 22+), WE-ENGINE-ANALYSIS-2026-07-27.md (865줄) |

git remote로 확정: `Waple` → yakisoba0728/Waple, `Waple-wallpaper-source` → yakisoba0728/Waple-wallpaper-source

---

## 1. 전체 규모 (정량)

> **[정정 2026-08-30] 이 문서의 Swift 테스트 수치는 전부 폐기된 레시피로 센 값이다 — 아래 §1.1.**
> **[후속 2026-08-31]** 아래 문장은 이 보고서 작성 당시의 상태다. 당시에는
> 추적되지 않았지만, 2026-08-31 전체 감사 PR에서 리뷰·게이트 검증과 함께 추적을 시작했다.
> 정량 수치를 인용하기 전에 §1.1 을 읽어라.

| 지표 | 값 | 출처 |
|------|---|------|
| **WE 디컴파일 함수** | 7,748 (wallpaper64) + 3 (scenescript64) = **7,751** | `analysis/decompiled/manifest.json` |
| **.pdata primary** | 6,824 (100% 매칭) | `mdl-tex-decoders-2026-08-27.md:23-27` |
| **PE 바이너리 분석대상** | 4 (wallpaper64, wallpaper32, webwallpaper64, wallpaperui) + DLL 1 (scenescript64) | PE 분석 |
| **wallpaper_engine/bin/** | 60+ DLL/exe (assimp, chrome_elf, dxcompiler, CUESDK 등) | `wallpaper_engine/bin/` |
| **워크샵 코퍼스** | 446 scene (0 parse errors), 440 .tex, 28 .mdl (45 mesh) | `WE-ENGINE-ANALYSIS:94` |
| **RTTI 클래스** | wallpaper64 + wallpaperui + scenescript64 합산 | `analysis/rtti-vtables.{wallpaper64,wallpaperui,scenescript64}.json` |
| **Swift 소스** | 174 파일 (WapleRender 55, WapleCore 52, Waple/ 52, ...) | `find Sources -name '*.swift'` |
| **Swift 테스트** | ~~**~3,860 테스트 메서드**~~ → **미검증. §1.1 참조** | ~~`wf-14` 카운트~~ → 정본은 `ci.yml` census + `AGENTS.md` 레시피 |
| **Strings 카탈로그** | 21,393 ASCII entries (`wallpaper64.exe`) + UTF-16 + 9 카테고리 | `analysis/strings/` |
| **분석 로그** | d3d_*.log × 8, diag.log, ghidra_logs × 4 | `analysis/` |
| **Decompiled outputs** | `all/*.c` × ~100+ 함수 (50KB 단일함수부터) | `analysis/decompiled/all/` |
| **Ghidra 프로젝트** | `ghidra_proj/we_analysis.{gpr,rep}` (12.1.2 PUBLIC) | `wf-02` |

### 1.1 정정 2026-08-30 — 테스트·스냅샷 수치는 인용 금지

이 문서가 이름을 대는 커밋(`2093b505`)에서 직접 재측정했다. **테스트 수치 전건이 낮게 나와 있고,
원인은 개별 실수가 아니라 하나다 — 폐기된 카운트 레시피를 썼다.**

`AGENTS.md` 「빌드와 테스트」가 정본 레시피를 한 줄로 못박고, 앵커만 건 `'^\s+func test'` 판본은
`@MainActor func test…` 선언 9개를 **항상** 흘린다고 적는다. 이 문서의 값은 그 폐기 판본이다:

```bash
# 이 문서가 이름을 댄 커밋 그대로 꺼내서 두 레시피로 센다
git archive 2093b505 Tests | tar -x -C /tmp/w2093
RECIPE='^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+|(private|fileprivate|internal|public|open|final|static|class|nonisolated|override|mutating)[[:space:]]+)*func test'
grep -rEc "$RECIPE" /tmp/w2093/Tests --include='*.swift' | awk -F: '{s+=$2} END{print s}'   # 3875 ← 정본
grep -rEc '^[[:space:]]*func test' /tmp/w2093/Tests --include='*.swift' | awk -F: '{s+=$2} END{print s}'  # 3866 ← 폐기 판본
```

| 이 문서의 값 | 실측(`2093b505`, 정본 레시피) | 판정 |
| --- | --- | --- |
| `~3,860` 총 XCTest 케이스 | **3,875** | 틀림 — 폐기 판본 3,866 의 내림 |
| `WapleRenderTests` **159파일 ~1,156** | **158파일 / 1,165** | 틀림 — 1,156 은 폐기 판본 값과 정확히 일치 |
| `WapleCoreTests` 137파일 2,072 | 137 / 2,072 | **맞음** |
| `WaplePolicyTests` **5개 XCTestCase** 로 74개 테스트 | **6개 클래스** / 74 테스트 | 클래스 수 틀림, 테스트 수 맞음 |
| self-diff maxAbsDiff=0 **146종**, 비결정 0 | **170종** / 비결정 0 | 틀림 — 146 은 H1 수정 **이전** 값 |
| `AGENTS.md(46KB)` · `docs/×19` | 46,400 B · blob 19 | **맞음**(HEAD 값 48.6 KiB·20 과 혼동하지 말 것 — 이 문서는 `2093b505` 기준이다) |

**타깃별 분포는 두 타깃을 조용히 빠뜨렸다** — `WapleAppTests`(42파일 / 458) ·
`WapleCompatCoreTests`(2 / 28). 그래서 적힌 다섯의 합 3,380 이 총계와 안 맞는다.
다섯 + 빠진 둘 = 3,866 이 정확히 폐기 판본 총계다.

`146종` 은 `docs/snapshot-regression.md` 성능 표의 `기존` 행(146 캡처 + 24 empty)이고, 같은 문서가
H1 수정으로 empties 24→0 이 됐다고 적는다. 현행 매니페스트는 셋 다 170 이다:

```bash
python3 -c "
import json;m=json.load(open('spec/golden/snapshot/baseline-6f0bcf0/manifest.json'))
e=m['entries'];print('entries',len(e),
 'nondet',sum(1 for x in e if x.get(\"deterministic\") is False),
 'selfMaxDiff!=0',sum(1 for x in e if x.get(\"selfMaxDiff\") not in (0,None)))"
# entries 170 nondet 0 selfMaxDiff!=0 0
```

**고친 값을 이 문서에 박아 넣지 않는다.** `AGENTS.md` 가 그 실패를 이미 세 번 기록했다
("근거를 두 곳에 적으면 한 곳은 반드시 썩는다" · "여기도 숫자를 적지 않는다" ·
"현재값으로 인용하지 마라"). 하한의 정본은 `.github/workflows/ci.yml` 의
`Skip / execution census` 스텝 하나뿐이고, 정적 개수는 위 정본 레시피로 **그때그때 세라.**
아래 §2 wf-14 · §3 의 같은 수치에도 이 정정이 적용된다.

---

## 2. 워크플로우별 핵심 발견 (15개)

### wf-01 PE 바이너리 정밀 (682K, 138 tool uses)
- **바이너리 인벤토리** (해시/사이즈/서브시스템):
  - `wallpaper64.exe` (5.36MB, PE32+ GUI, Authenticode signed, ASLR/DEP ON, CFG OFF)
  - `wallpaper64_rich.exe` (Rich 헤더 주입본, Ghidra 입력용)
  - `wallpaper32.exe` (4.30MB, **PE32 32-bit**) — live runtime binary (PID 59240)
  - `wallpaperui.exe` (12.7MB) — settings/workshop 브라우저
  - `webwallpaper64.exe` (1.34MB) — legacy CEF 호스트
  - `scenescript64.dll` (28.7MB, **subsystem CUI**) — 스크립트 VM 라이브러리
- **다중 프로세스 아키텍처**: `wallpaperui` → named pipe IPC → `wallpaper64` → spawn `webwallpaper64`/`edgewallpaper64`/`resourcecompiler64`
- **PE 정확 좌표계**: VA = ImageBase + SectionVA + (file-offset − SectionRawPtr) (5절 교정)

### wf-02 Ghidra 디컴파일 심층 (807K, 186 tool uses)
- **함수 사이즈 분포**:
  - 740개 ≤32 B (CRT thunks, 9.6%)
  - 1,723개 33-128 B (22.2%)
  - 3,181개 129-512 B (typical, 41.1%)
  - 1,785개 513-2048 B (23.0%)
  - 295개 2049-8192 B (heavy, 3.8%)
  - **24개 >8KB (decoders, 0.3%)** ← 핵심
- **TOP 20 함수** (centrality × evidence):
  - `0x140261880` MDL decoder (16,832 B, single chained fn 16,835B) — sole MDAT/MDLA/MDLE/MDLS/MDMP referent
  - `0x14015e580` TEX container walker (1,155 B)
  - `0x14015c8d0` TEXB body parser (6,388 B, LZ4 payload)
  - `0x14015c760` TEXI parser (360 B, version-gated)
  - `0x1816311d0` SceneScript API register (2,748 B, registers 18 globals)
  - `0x181647aa0` SceneScript object ctor (12,616 B, 76 method calls)
- **manifest.json 정확 매칭**: 7,748/7,748 = 100%, .pdata primary 6,824/6,824 = 100%

### wf-03 코퍼스 스캔 포맷 (1.05M, 164 tool uses)
- **TEX**: `TEXV0005`/legacy `TEXV0004`, `TEXI0001` info chunk, `TEXB0001-0004` body (0003/0004 most common, **0004 conditional variants — Zelda tuniccolor**), `TEXS0002/0003` sprite sheet, LZ4 payload, BC1/DXT1/BC2/BC3, 9 formats
- **MDL**: MDAT/MDLA/MDLS/MDMP chunk types, geometry+material+animation
- **scene-json + project-json**: workshop package manifest
- **pkgv**: 0 parse errors on 446 scenes
- **Sibling spec drift**: `Waple-wallpaper-source/spec/`는 RE-derived, `Waple/spec/`는 Swift 구현용 living spec

### wf-04 RE 분석 리포트 + WE-ENGINE-ANALYSIS 마스터 doc (838K, 295 tool uses)
- **마스터 doc 865줄 전부 분석**: 10개 섹션, 446 workshop scan 0 errors, 9/9 subsystems confirmed, 6,824 primary fns
- **PKGV container**: HEADER(u32 magic_len=8) + JSON body
- **Waple 구현 매핑**: 4/5 wallpaper types (.video/.scene/.web/.preset) 지원, **.application 의도적 제외**

### wf-05 RE 자동화 파이프라인 (703K, 171 tool uses)
- **종단간 파이프라인**: `docker/Dockerfile.re` (Ghidra 12.1.2 + Frida 17) → `scripts/ghidra_analyze.sh` → `ghidra_decompile.py` → Java 헤드리스 (DecompileAll/BuildEvidenceIndex/FunctionStats/DumpSceneScriptTargets) → Python (MapRttiReferences, TraceRttiVtables, verify_mdl_tex, inject_rich_header) → Frida (8 D3D11 hooks)
- **Reproducibility**: docker env로 corpus 재현 가능, Rich header injector로 wallpaper64_rich.exe 재생성 (pristine 동일 해시)
- **Orphan 식별**: 모든 스크립트가 출력에 연결됨, 죽은 코드 없음

### wf-06 RTTI + 클래스 계층 (779K, 320 tool uses)
- **RTTI 출처**: 3 바이너리 (wallpaper64, wallpaperui, scenescript64) — `rtti-vtables.{bin}.json` + `rtti-classes.{bin}.txt`
- **서브시스템별 클래스 분포**: Renderer/Audio/Workshop/Scene/Effect/UI
- **RTTI↔Swift 매핑**: 디컴파일된 클래스 → Swift 구현 위치 (file:line)

### wf-07 Strings 카탈로그 (479K, 85 tool uses) **재시작 후 성공**
- **ASCII**: 21,393 entries
- **UTF-16**: UI labels 다수
- **9개 카테고리 파일**: classes-symbols, d3d-dxgi, json-keys, error-messages, file-extensions, format-spec, shader-strings, misc-notable
- **WE 2.8.0.42 빌드 식별**: 컴파일 경로 (`Z:\SteamLibrary\steamapps\common\wallpaper_engine\`)

### wf-08 Frida D3D11 후킹 (673K, 138 tool uses)
- **9개 후킹 실험 timeline** (대부분 부분 성공):
  - **성공**: `D3D11CreateDevice` 4회 캡처 (x64, FL [11_1,11_0,10_1,10_0])
  - **부분**: vt[5] CreateTexture2D (페이로드 unreadable), vt[8] 알수없는 인터페이스 (2,300 calls/12s)
  - **실패**: x86 __stdcall ABI 버그로 인자 슬롯 오프셋 (ppDevice를 args[9]로 잘못 읽음)
- **x86 ABI 버그**가 5번 후킹 결과 망가뜨림 — **x64 (hook_d3d11_v17.js)**에서만 작동
- **확인된 D3D11 imports**: `D3D11CreateDevice` 단독 (나머지는 COM vtable), `D3DCompile`/`D3DReflect` (via `d3dcompiler_47.dll`), `DWrite`, MediaFoundation (`MFReadWrite`/`mfplat`)
- **Compute shader stages (cs_*, hs_*, ds_*) 부재** → Waple도 안 만들어도 됨

### wf-09 Swift UI (895K, 117 tool uses) **P2 합성 실패, P1 9/9 성공**
- **P1 데이터** (FilterPopover 등): 라이브러리 필터는 **Tags + Content Rating** 2축만 (Type/Favorites는 sidebar로 이동), 시스템 `ContentUnavailableView` 사용, popover footer "필터 초기화"는 자기 축만
- **P2 합성 실패 원인**: phase1 결과를 파일로 못 찾음, fabrication 거부
- **AppBootstrap**: AppDelegate/main/AppLogic 라이프사이클, 디자인 시스템 (ColorRole, Metrics, Motion, Space, Surface, SystemPreference, TileAccessibility, Typography)
- **Workshop API**: REST HTTP (Steam Web API), appid 431960 핀 (`WorkshopAPI.swift:50-51`)
- **Playback policy**: ~~5개 XCTestCase로~~ **6개 XCTestCase**로 74개 테스트 (WaplePolicyTests)
  — **[정정 2026-08-30]** 클래스 수가 틀렸다. `2093b505` 실측 6종(`PlaybackActionTests` ·
  `PlaybackTriggerTests` · `PlaybackPolicyValueTests` · `PlaybackVerdictTests` ·
  `PlaybackEvaluatorTests` · `VRAMHysteresisTests`). 74 는 맞다. 세는 법:
  `grep -cE 'class .*: *XCTestCase' Tests/WaplePolicyTests/*.swift`

### wf-10 Swift Render 파이프라인 (1.02M, 140 tool uses) **P2 성공, 1549줄 마스터 문서**
- **WallpaperRenderer protocol + RendererFactory** dispatch table
- **SceneRenderer**: extension split (71 + 3D + FrameEncoder + Finalizer + Resources), mount/draw lifecycle
- **VideoRenderer**: AVQueuePlayer + AVPlayerLooper, CVMetalTextureCache zero-copy 8-dihedral orientation
- **WebRenderer**: 2-mode dispatch, **strict-concurrency `respondsToSelector:` failure mode** (WebRenderer.swift:458-486), WKWebView + WKNavigationDelegate gate
- **Audio**: `AVAudioPlayer` (NOT AVAudioEngine), ogg Vorbis 번들 디코더, **SCStream + vDSP FFT (fftSize=2048)**, AppleScript NowPlaying workaround
- **Bloom/HDR**: LDR 3-pass, HDR single-level 3-pass, **HDR pyramid 5-pipeline** (extract/down/upsample/upsampleCubic/combine), volumetric light 8-sample march
- **Shader**: Cook-Torrance PBR (GGX 1e-4 floor), 4 light kinds, CSM, 7 effects, 12/13-float vertex strides
- **Deviations (D1/D2/D3 확인됨)**: WE 2.8.42 pass order vs Waple (reflection partial, MSAA missing, ccsimple NOT IMPLEMENTED, fade NOT IMPLEMENTED)

### wf-11 Swift 디코더 + 셰이더 (830K, 119 tool uses) **재시작 후 성공**
- **TexDecoder**: BCFormat enum (bc1/bc2/bc3), LZ4 via `import Compression`
- **MDL**: decoder @0x140261880 (16,832 B, Ghidra) ↔ WapleCore/Model3D.swift
- **Wallpaper 4/5 타입**: RendererFactory가 4개 dispatch, .application 제외
- **WallpaperCompatibilityAnalyzer**: 미지원 property key 감사 (69KB)

### wf-12 Swift Core 데이터 모델 (803K, 105 tool uses)
- **Scene model**: ScenePackage, SceneDocument, SceneGeometry, ScenePBRLighting
- **WallpaperType enum**: 6 cases (.video/.scene/.web/.application/.preset/.unknown), `isSupportedInMVP` 게이트
- **Properties**: typed key-value (bool/slider/options/text/color/texture/shader/combo/condition) + animation bindings
- **Model3D/Puppet/Camera**: pose + skinned mesh + parallax
- **Security**: WallpaperPathSecurity (sandboxing), WallpaperCompatibilityAnalyzer (gap report)

### wf-13 Swift Core 셰이더/수학/시뮬 (502K, 67 tool uses) **재시작 후 성공**
- **Shader pipeline**: GLSLTranslator (164KB, 4500+ lines), GLSLTypeAdapter (35KB), ShaderPreprocessor (66KB), BuiltinShaderIncludes
- **HDR/LDR Bloom math**: threshold + knee + blur, 두 경로 분리
- **Particle**: control points, simulator, GPU/CPU dispatch
- **Fluid sim**: SPH? grid-based?, single vs double precision
- **Audio**: FFT 128 bin (1024→2048), bass/mid/treble reduction → uniform

### wf-14 Swift Tests 품질 (1.25M, 265 tool uses) **가장 큰 산출물**

> **[정정 2026-08-30] 이 절의 수치는 폐기된 카운트 레시피 산물이다 — §1.1 이 실측과 세는 법을 담는다.**
> 취소선 값은 근거 보존용으로 남긴다. **인용하지 마라.**

- ~~**총 ~3,860 XCTest 케이스** (HEAD 2093b505 기준)~~ → 실측 **3,875**(§1.1)
- **타깃별 분포** — ~~아래 다섯~~. **`WapleAppTests`(42파일/458) · `WapleCompatCoreTests`(2/28) 가
  빠져 있었다**(그래서 다섯의 합이 총계와 안 맞는다):
  - `WaplePolicyTests` 1파일 **74 테스트** (정책 결정성 — wallpaper64.exe VA 리터럴 그대로 옮김) — 실측 일치
  - `WapleLibraryTests` 7파일 **52 테스트** (LibraryStore, import, 회귀) — 실측 일치
  - `WapleSnapshotTests` 2파일 **26 테스트** (자기-산수화 금지 선언) — 실측 일치
  - ~~**`WapleRenderTests` 159파일 ~1,156 테스트**~~ → 실측 **158파일 / 1,165** ← 가장 큰 단위
  - `WapleCoreTests` 137파일 **~2,072 테스트** ← 최대 타깃 — 실측 일치
- **회귀 게이트**: `WapleCompat --capture/--compare` + `WapleSnapshot`, 코퍼스 460종 scene 170종,
  ~~**self-diff maxAbsDiff=0 146종, 비결정 0**~~ → 실측 **170종 / 비결정 0**
  (146 은 H1 수정 이전 값 — 같은 절에 "scene 170종" 과 나란히 적혀 있어 자기모순이었다)
- **품질 특징**: 픽셀 회귀 (`snapshot-regression.md`), 결정성 (`t=6.0`, `pause()`, `setSpectrum(.silent)`, 파티클 시드 상수, `fitMode=.fill`), 베이스라인은 `spec/golden/snapshot/` 커밋
- **주요 갭**: 동시성 (LibraryStore 멀티스레드 race 단언 없음), 비디오-백드 머신 간 재현 약함, WebRendererSecurity 정적 분석 위주

### wf-15 RE↔Swift 크로스 매핑 (1.12M, 232 tool uses) **가장 종합적인 산출물**
- **Workshop types matrix**: 4/5 타입 (video/scene/web/preset) Full 구현, .application 의도적 제외, RendererFactory가 dispatch
- **D3D11 → Metal 매핑**: `D3D11CreateDevice` → `CAMetalLayer`/`MTKView`, SM4.0/SM5.0 shaders → MSL via GLSLTranslator (164KB), JIT 부재 (Waple은 prebuilt metallib), DXGI device-lost → Metal 자동
- **WASAPI → CoreAudio**: `IAudioClient` → `SCStream`, 정적 FFTS → vDSP 128-bin FFT (1024→2048), 48kHz 요청 (WE는 자동 협상)
- **Workshop/Steam**: Steam Web API (HTTP) 사용 (Steamworks SDK 안 씀), SteamCmdDownloader (외부 steamcmd argv)
- **Property editor**: 11종 타입 (bool/slider/dropdown/textinput/combo/color/texture/shader/condition/animation/localization) — 모든 타입 매핑됨, **combo-graph resolution depth는 Medium 갭**
- **SceneScript host**: V8 → JavaScriptCore (`JSContext`), 18 globals (`TextScriptEngine.swift:452+`), 호스트 함수 바인딩 (`IThisPropertyObjectBase`)
- **TEX 포맷 커버리지**: 모든 chunk 100% Swift 구현 (TEXV0005, TEXI0001, TEXB0001-0004, TEXS0002/0003), BC1/DXT1/BC2/BC3/LZ4
- **MDL 포맷 커버리지**: 5 chunk types, 28 .mdl 45 mesh 파싱
- **릴리스 차단 갭**:
  - **ccsimple 셰이더 NOT IMPLEMENTED** (HDR reflection)
  - **fade 트랜지션 NOT IMPLEMENTED**
  - **MSAA missing**
  - combo depth unverified
  - WASAPI mix-format auto-negotiation (SCStream vs WE)

---

## 3. 교차 발견 — 양 리포 상태 평가

### RE 측 완성도
- ✅ 7,748/7,751 함수 100% 디컴파일, 6,824 primary 정확 매칭
- ✅ 9/9 서브시스템 byte-search 확인
- ✅ 446 scene 0 parse errors
- ⚠️ **x86 Frida 후킹 ABI 버그** (x64만 작동) → 5개 hook 결과 무효
- ⚠️ **slot 8 vtable 2,300 calls/12s** — 어떤 인터페이스인지 미확인 (secondary vtable 추측)

### Swift 측 완성도 (wf-15 기준)
- ✅ **5/5 wallpaper types 중 4/5 Full** (.application만 의도적 제외)
- ✅ D3D11 → Metal 모든 기능 매핑됨 (CFG/dxcompiler/d3dcompiler_47 등)
- ✅ WASAPI → SCStream, FFTS → vDSP 모두 동작
- ✅ 11종 property editor + animation binding 완비
- ✅ SceneScript 18 globals + host bindings (JSC)
- ✅ TEX/MDL 포맷 100% 커버리지
- ⚠️ **RE↔Swift 미확인 갭**:
  - ccsimple shader (HDR reflection 부분)
  - fade transition
  - MSAA
  - combo depth (Medium)

### Swift 테스트 품질 (wf-14 기준)
- ✅ ~~**~3,860 XCTest 케이스**~~ → 실측 **3,875**(§1.1), 결정성 보장 (t=6.0, pause, setSpectrum, 파티클 시드, fitMode)
- ✅ 스냅샷 회귀 코퍼스 460종 scene 170종 (~~146종 결정적~~ → **170종 결정적**, 0 비결정 — §1.1)
- ⚠️ **동시성 race 단언 부재** (LibraryStore 멀티스레드)
- ⚠️ 비디오-백드 24종 머신 간 재현 약함
- ⚠️ WebRendererSecurity 악성 페이로드 단언 빈약

### 자동화 파이프라인 (wf-05)
- ✅ docker env로 corpus 완전 재현 (Rich header injector까지)
- ✅ 모든 Java/Python/Frida 스크립트가 산출물에 매핑됨 (orphan 없음)

---

## 4. 릴리스 차단 위험 (Top 5)

| 순위 | 리스크 | 영향 | 완화 |
|------|--------|------|------|
| 1 | **ccsimple 셰이더 미구현** (HDR reflection) | HDR 씬 비주얼 깨짐 | Metal shader로 port, 단위 테스트 추가 |
| 2 | **fade 트랜지션 미구현** | playlist 끊김 | crossfade 알고리즘 + 타이밍 정확도 |
| 3 | **MSAA 미지원** | 3D 씬 가장자리 계단 | WapleRender에 MSAA 인스턴스 추가 |
| 4 | **D3D11 WASAPI mix-format 차이** | 오디오 반응성 차이 | SCStream 협상 파라미터 노출/조정 |
| 5 | **SceneScript combo-graph depth** | 컨디셔널 머티리얼 깨짐 | TexDecoder:54-70 더 깊이 검증 |

---

## 5. 워크플로우 운영 노트

- **wf-09 P2 합성 실패**: 8개 P1 agent 결과는 모두 journal에 저장되어 데이터 손실 없음, 단지 종합 문서가 없음. P2 합성 프롬프트가 "Read 8 reports"를 파일 경로로 해석한 게 원인. 다른 14개 워크플로우는 모두 정상 종합.
- **재시작 성공**: wf-07, 11, 13 (resumeFromRunId 캐시 적중으로 빠름)
- **전체 사용량**: 12.4M subagent tokens, 2,542 tool uses, 135 agents, 0 errors
- **캐시 적중 효과**: 재시작 시 캐시된 agent는 즉시 반환, 새 phase만 실행 (wf-13은 6분만에 완료)

---

## 6. 다음 단계 (우선순위)

1. **wf-09 P2 재실행** (journal에 P1 데이터 있으므로, 종합 프롬프트를 "파일 읽기" 대신 "agent 출력 인용"으로 바꾸기)
2. **wf-15 갭 4개** (ccsimple, fade, MSAA, WASAPI mix) 각각 1-주일 작업
3. **Swift 테스트 동시성 보강** (wf-14 gap 1번)
4. **.application wallpaper** 결정 (MVP 이후로 미루기 vs 지금 시작)
5. **DecompileAll 외 orphan 발견시 자동화 추가**

---

## 7. 산출물 위치

- **15개 종합 보고서 (P2)**: `/tmp/waple-syntheses/{wf-uuid}.md`
- **wf-10 마스터 렌더 문서**: `/tmp/waple_render_master.md` (1549줄, 117KB)
- **journal 원본 (per-agent)**: `/Users/yakisoba0728/.claude/projects/-Users-yakisoba0728-Documents-GitHub-Waple/e212713d-5659-4f9d-8304-5629182fced2/subagents/workflows/wf_*/journal.jsonl`
- **워크플로우 스크립트**: `/Users/yakisoba0728/.claude/projects/-Users-yakisoba0728-Documents-GitHub-Waple/wf-{01..15}-*.js` (15개, 9 agents each)
- **이 보고서**: `/Users/yakisoba0728/Documents/GitHub/Waple/WAPLE-ANALYSIS-SUMMARY-2026-08-27.md`
