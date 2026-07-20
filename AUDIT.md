# Waple 코드베이스 감사 리포트

> 생성일 2026-07-06 · 다중 에이전트 병렬 감사(탐색 22개, read-only) · **코드 미수정 — 실행 항목만 정리** · verify 단계 없음
> 상태: 완료 (탐색 22/22 반영)

## 개요

Waple 전 코드베이스(WapleCore · WapleRender · WapleLibrary · Waple 앱 · WapleSaver + Tests + 빌드/문서)를 서브시스템 16개 + 횡단 관심사 6개로 나눠 22개 탐색 에이전트가 병렬 감사했다. 각 에이전트는 배정 파일을 정독하고 grep으로 사용처를 검증한 뒤 발견을 보고했다. 본 리포트는 그 결과를 5개 실행 카테고리로 종합·중복제거·우선순위화한 것이다. **어떤 코드도 변경하지 않았다.**

역공학 프로젝트 특성상 `ponytail:`·`실측/실물 <워크샵ID>` 주석으로 정당화된 의도적 단순화가 많고, 직전 커밋(`578ee8e`)이 실버그 8건을 이미 정리했다. 따라서 뻔한 결함보다 **미묘한 실이슈·신뢰경계 방어 공백·UX 계층 부재**에 집중했다.

## 핵심 요약

- **파티클 위치 적분 결함(단일 근본 원인, high)**: 위치 적분이 `for m in movements` 루프 안에 있어 — movement 오퍼레이터가 **0개면 velocity가 죽고**(정지 렌더), **2개 이상이면 위치가 중복 적분**된다. 한 줄 이동으로 3건 동시 해소.
- **신뢰경계 방어 공백(high)**: 신뢰 불가 `.mdl`의 정점 인덱스가 `vCount` 검증 없이 `drawIndexedPrimitives`로 직행 → GPU 정점 OOB 참조. 파서 강건성은 전반적으로 매우 높은데 이 한 곳만 뚫려 있다.
- **가림 시 정지(절전) 정책의 이중 구현·비대칭(high~medium)**: `SceneRenderer.pause()`가 MTKView 애니메이션 타이머를 안 멈추고, AppDelegate 폴링과 각 렌더러의 occlusion 옵저버가 `pausedManually` 한 플래그를 두고 경합한다. 두 상태기계를 하나로 통일해야 한다.
- **동영상 설정 변경 = 전체 재장착(high)**: 볼륨/배속을 바꾸면 `apply()`가 렌더러를 통째로 스왑해 mkv/webm은 매번 재변환·재장착되고 재생이 리셋된다. 라이브 반영으로 바꿔야 한다.
- **앱 전역 피드백 계층 부재(high UIUX)**: 모든 성공/실패가 `notify()`→`NSLog`로만 흘러 GUI에서 완전히 비가시적이다(코드베이스에 `NSAlert`/알림 0건). 이 한 함수를 가시화하면 다수의 UX 구멍이 자동 해소된다.
- **최초 실행 온보딩 전무 + 조용한 저하(high UIUX)**: 첫 실행 안내가 없고, base-assets 미설정 시 씬이 조용히 깨지며(`return nil`), ffmpeg 부재도 로그만 남긴다.
- **번역기 조용한 오역(medium)**: `#if defined(NAME)` 미지원(항상 false)과 `M_PI_2`→2π(표준 π/2와 반대) — 폴백도 안 타고 "조용히 틀린 그림"이 될 수 있다.
- **위생 부채**: 테스트 스캐폴딩(`i32`/`encodePkg`/`solidTex`)·LE 정수 리더·JSON 언랩 헬퍼·cstring 파서가 다수 파일에 중복. LICENSE 파일 부재. `.saver` 소스가 `swift test` 커버리지 밖.
- **UI는 기능 위주의 정적 SwiftUI**: 호버·선택·적용에 모션이 전무하고 메뉴바 아이콘은 고정 이모지. 인플레이스 애니메이션·`Form(.grouped)`·상태 반영 아이콘으로 체감 품질을 크게 올릴 여지가 크다.

## 우선순위 인덱스 (critical · high)

| 항목 | 카테고리 | 심각도 | 위치 |
| --- | --- | --- | --- |
| 파티클: movement 루프 안 위치 적분(0개→정지/2개+→중복) | 버그 | high | ParticleSimulator.swift:247-251 |
| .mdl 정점 인덱스 OOB → GPU 폴트 | 버그 | high | Model3D.swift:193-195 |
| SceneRenderer pause/resume가 MTKView 타이머 미제어(절전 무산) | 버그 | high | SceneRenderer.swift:620-624 |
| 3D 빌보드 per-frame device.makeBuffer 신규 할당 | 버그(성능) | high | SceneRenderer3D.swift:512 |
| 볼륨/배속 변경 시 mkv/webm 전체 재변환·재장착(재생 리셋) | 버그 | high | AppDelegate.swift:176,183 |
| ffmpeg 완료 콜백 vs teardown 경쟁 → 유령 레이어/오디오 | 버그 | high | VideoRenderer.swift:37-45 |
| combo Picker 값-타입 불일치 → 무선택 표시 | 버그 | high | PropertyEditorView.swift:74 |
| notify가 NSLog만 → 앱 전역 오류·성공 비가시 | UIUX | high | AppDelegate.swift:436-438 |
| 최초 실행 온보딩 전무 + base-assets/ffmpeg 조용한 저하 | UIUX | high | AppDelegate.swift:44-153, BaseAssetsSettings.swift:10-28 |
| `.saver` 소스가 swift test/CI 커버리지 밖 | 버그(빌드) | high | scripts/package-app.sh:37-41 |
| VideoRenderer↔AppDelegate 이중 occlusion 상태 충돌 | 버그 | medium | VideoRenderer.swift:86-97, AppDelegate.swift:355-368 |
| 순수 3D 애니 씬이 가림(occlusion) 중에도 계속 렌더(배터리) | 버그 | medium | SceneRenderer.swift:490 |
| `#if defined(NAME)` 미지원 → 항상 false | 버그 | medium | ShaderPreprocessor.swift:249-306 |
| `M_PI_2`→2π (표준 π/2와 반대, 조용한 오역) | 버그 | medium | GLSLTranslator.swift:650 |
| evaluateVec 2원소 반환 경로 부재 → 2D scale 스크립트 무시 | 버그 | medium | TextScriptEngine.swift:164-172 |
| FFmpeg `converted/` 캐시 무한 증가(evict 없음) | 버그 | medium | FFmpegConverter.swift:29-39 |
| PuppetModel 2D 경로 Latin-1 디코드 → CJK 경로 mojibake | 버그 | medium | PuppetModel.swift:99,151,179 |
| 라이브러리 엔트리 삭제 경로 부재 → playlist/monitor orphan id 잔존 | 버그 | medium | LibraryStore.swift(remove 없음) |
| import 동기 실행 + 로딩 상태 부재(대용량 폴더서 앱 얼어붙음) | UIUX | medium | LibraryViewModel.swift:69-75 |
| textinput 포커스 이탈 시 변경 유실 | 버그 | medium | PropertyEditorView.swift:98-101 |
| 그리드 타일 접근성 라벨/버튼 trait 부재(VoiceOver 불가) | UIUX | medium | LibraryView.swift:54-109 |
| 테스트 스캐폴딩 i32/encodePkg/solidTex 14/8/7파일 중복 | 리팩토링 | medium | Tests/WapleRenderTests/** |
| LICENSE 파일 부재(README "미정") | 문서 | medium | (repo root) |

---

## 1. 오류 및 버그 수정 (Bugs & Correctness)

### WapleCore — 파티클

**파티클 위치 적분이 `for m in movements` 루프 안에 있음 (단일 근본 원인, 3증상)**
- 파일: ParticleSimulator.swift:247-251 · 심각도: high · 작업량: small
- 무엇/왜: 위치 적분 `pos += vel * speedFactor * dt`가 movement 루프 내부에 있다. ① movement 오퍼레이터가 **2개 이상**이면(파싱이 `mv.append`로 전부 수집) 한 스텝에서 위치가 N번 더해지고, 각 반복이 직전 gravity 누적 vel을 써 단순 N배보다 크다. ② movement가 **0개**면 velocityRandom 초기속도·remapValue `.velocity` 덮어쓰기(:241)가 위치를 못 움직여 등속 이동 파티클이 정지 렌더된다. ③ `.speed` remap 배수도 movement 없으면 버려지고 복수면 중복 적용된다.
- 권장 조치: gravity/drag 누적은 movement 루프에서 유지하되, **위치 적분 1회를 루프 밖에서** 수행(turbulence 이류가 이미 :257에서 루프 밖인 것과 대칭). 세 증상이 동시 해소된다.

**진동/remap 게이트가 음수 scale에서 무음 처리**
- 파일: ParticleSimulator.swift:456,462 · 심각도: medium · 작업량: small
- 무엇/왜: `if p.oscAlphaScale > 0`/`oscPosScale > 0` 게이트가 음수 scale 범위에서 진동을 통째로 끈다. oscillatePosition은 음수 진폭도 유효한 왕복이다(부호=위상). WE가 음수 scale을 안 쓰면 low.
- 권장 조치: 게이트를 `!= 0`로 바꾸거나 스폰 시 abs 정규화.

### WapleCore — 3D/퍼펫/텍스처

**`.mdl` 정점 인덱스가 `vertexCount` 검증 없이 GPU로 직행 → 정점 OOB (신뢰경계)**
- 파일: Model3D.swift:193-195 (동형 PuppetModel.swift:137-139) · 심각도: high · 작업량: small
- 무엇/왜: 인덱스 블롭 UInt16이 `vCount` 미만인지 미검사. 반환 indices가 SceneRenderer3D.swift:472의 `drawIndexedPrimitives(.uint16)`로 그대로 전달돼, 조작된 파일이 초과 인덱스를 담으면 셰이더가 정점버퍼 밖을 읽는다(Metal에선 크래시보단 쓰레기 삼각형이나 미정의 동작). `boneIndices`는 렌더러가 clamp하는데 정점 인덱스엔 방어가 없다. 파서의 나머지(모든 크기/오프셋)는 엄격히 검증하는 것과 대비.
- 권장 조치: 파스 시 `indices.max() < vertices.count` 1회 확인, 위반 메시는 스킵(기존 "실패=nil/스킵" 규약과 동일). 공통 경로라 파서에서 한 번 막는 게 근원 차단.

**PuppetModel 2D 경로 cstring이 Latin-1 → CJK 머티리얼 경로 mojibake → 흑화면**
- 파일: PuppetModel.swift:99,151,179 · 심각도: medium · 작업량: small
- 무엇/왜: 2D(`parseV0013`) cstring이 `Character(UnicodeScalar(bytes[o]))` 바이트별 누적=Latin-1이라 UTF-8 CJK가 깨진다. Model3D는 이 함정을 명시 회피하고 이유를 주석(:118-120)으로 남겼는데(“太空球” pkg 조회 실패), 2D 퍼펫도 material 경로로 pkg를 조회하므로(:80) CJK 이름이면 흑화면.
- 권장 조치: 세 곳을 `String(decoding: bytes[start..<o], as: UTF8.self)`로 통일(공통 헬퍼 권장 — 리팩토링 §2 참조).

**`inferStride` 추론값이 `vSize`를 정확히 안 나눠 후속 오프셋 밀림**
- 파일: Model3D.swift:160,339-341 · 심각도: medium · 작업량: small
- 무엇/왜: `inferStride`는 `vSize % count == 0`만 보장(count=maxIdx+1은 하한 추정), `vSize % stride == 0`은 미보장. 잔여 발생 시 `o += vSize` 뒤 인덱스 블롭 오프셋이 어긋나 후속 파싱이 조용히 실패.
- 권장 조치: 반환 직후 `vSize % stride == 0` 재검증(위반 시 nil).

**애니 리싱크 스캔이 트레일러 바이트를 헤더로 오인 가능**
- 파일: Model3D.swift:307-314 · 심각도: low · 작업량: medium
- 무엇/왜: 헤더 매직 없는 포맷을 `o+d`(0..256) 슬라이딩으로 리싱크하는데, `tryHeader`(cstring+fps∈(0,240]+boneCount)가 트레일러 바이트열에 우연 매칭될 수 있다(fps를 float 비트로 재해석). 정상 헤더가 256B 밖이면 조용히 종료→애니 누락.
- 권장 조치: 리싱크 후보에 “직후 첫 본 트랙크기 `u32 % 36 == 0` && 범위 이내” 추가 검증.

### WapleCore — 씬 파싱 / GLSL

**`world()` 부모 체인 합성이 부모 미해결 시 로컬 좌표를 월드로 오인(silent-degrade)**
- 파일: SceneDocument.swift:559-568 · 심각도: medium · 작업량: small
- 무엇/왜: `parentOf[id]`는 있으나 `world(pid)`가 nil(부모가 드롭됐거나 id==0)이면 로컬 좌표를 그대로 월드로 반환한다. 주석(:531-533)이 설명하는 “背景→(0,0) 흑화면” 실패 모드가 이것인데, 순환 가드와 달리 경고 로그 없이 조용히 어긋난다.
- 권장 조치: 좌표 폴백은 유지하되 “부모 있으나 해결 불가” 분기에 `WapleLog.warn` 추가(디버깅 비용 급감).

**콘텐츠 키+정적 invisible+id-무-스크립트 3D 오브젝트가 parent 체인에서 유실**
- 파일: SceneDocument.swift:305 · 심각도: low · 작업량: small
- 무엇/왜: 정적 invisible + visible 스크립트 없는 model/light는 :305에서 드롭되고 `parseNode`에도 못 가서, 다른 오브젝트의 부모일 때 그 트랜스폼이 사라진다. 실물에서 invisible 메시가 부모인 사례 미확인이라 low.
- 권장 조치: 정적 invisible이어도 트랜스폼은 보존(nodes3D 병행 등록 또는 렌더 스킵 플래그).

**`#if defined(NAME)` 연산자 미지원 → 항상 false**
- 파일: ShaderPreprocessor.swift:249-306(ExprEval) · 심각도: medium · 작업량: small
- 무엇/왜: `#ifdef`/`#ifndef`는 처리하나 `#if defined(FOO)`/`defined FOO`는 `defined`를 일반 식별자(=0)로 읽고 뒤 `(FOO)`를 소비 못 해 **항상 false**. 해당 분기가 소실되거나 `#else`만 방출된다. `defined(A)||defined(B)`도 전부 깨짐.
- 권장 조치: ExprEval에 `defined` 처리 추가(다음 `(ident)`/`ident`를 읽어 `defines[name] != nil ? 1 : 0`), 또는 전처리서 `defined(X)`→0/1 사전 치환.

**`M_PI_2` 매크로가 2π로 매핑 — C/GLSL 표준(π/2)과 반대**
- 파일: GLSLTranslator.swift:650 · 심각도: medium · 작업량: small
- 무엇/왜: `"M_PI_2": "6.28318530718"`(2π). 표준·다수 GLSL 관용에서 `M_PI_2`는 π/2다(같은 사전 `M_PI_HALF`가 이미 π/2). 근거 주석·테스트 없음. 표준 의미로 쓴 셰이더가 있으면 각도·주기가 4배 어긋나 조용히 틀리고 폴백도 안 탄다.
- 권장 조치: WE 실물에서 사용례 1건 확인해 의미 확정. 확신 없으면 매핑 제거(미치환→컴파일 실패→폴백)가 “조용히 틀림”보다 안전.

**fragment `return\n;`(개행 삽입형)이 bare-return 리라이트에서 누락**
- 파일: GLSLTranslator.swift:688 · 심각도: low · 작업량: small
- 무엇/왜: `rewriteBareReturns`가 `return` 뒤 공백/탭만 스킵해 개행 후 `;`를 놓친다 → `return;` 유지 → `ef_main`(float4 반환) MSL 컴파일 실패 → 불필요 폴백(결과는 안전).
- 권장 조치: 스킵 문자에 `\n`,`\r` 추가.

### WapleRender — 렌더러 수명주기 / 성능

**SceneRenderer pause/resume이 MTKView 애니메이션 타이머를 제어하지 않음 → 절전 정책 반쪽**
- 파일: SceneRenderer.swift:620-624 · 심각도: high · 작업량: small
- 무엇/왜: `pause()`가 `videoRenderer?.pause(); sceneAudio?.pause()`만 하고 `mtkView.isPaused`를 안 건드린다. 애니메이션 씬은 30fps 연속 렌더라, AppDelegate 가림-정지(`renderers.forEach{pause()}`)가 불려도 `draw(in:)`가 계속 돈다. draw 내부 가드는 `view.window?.occlusionState`(AppDelegate의 `DesktopVisibilityMonitor`와 다른 판정)를 봐서, 두 판정이 어긋나면 GPU 인코딩이 멈추지 않는다. VideoRenderer/WebRenderer는 각자 occlusion 옵저버가 있는데 SceneRenderer만 없어 pause 대칭성이 깨진다.
- 권장 조치: `pause()`에서 연속 모드면 `mtkView.isPaused = true`, `resume()`에서 복원. mount의 연속-렌더 판정(`hasEffects || ... || has3DScripts`)을 Bool로 저장해 재사용하면 resume의 `needsDisplay` no-op 문제(:622)도 함께 해결(아래 항목).

**resume()의 `needsDisplay`가 연속 모드에서 no-op**
- 파일: SceneRenderer.swift:621-624 · 심각도: medium · 작업량: small
- 무엇/왜: 위를 고쳐 pause에서 isPaused=true로 만들면, 연속 모드(`enableSetNeedsDisplay=false`)에서 resume의 `needsDisplay=true`는 무효라 재개 실패. pause/resume 쌍이 정적 씬에서만 정합적이다.
- 권장 조치: resume에서 씬 종류 판별 — 연속이면 `isPaused=false`, 온디맨드면 `needsDisplay=true`.

**순수 3D 애니 씬이 데스크탑 가림 중에도 계속 렌더 — draw 가드 조건 비대칭**
- 파일: SceneRenderer.swift:490 (vs :413) · 심각도: medium · 작업량: small
- 무엇/왜: 프레임 스킵 가드(:490)가 `hasEffects || hasParticles || hasScriptedText || hasAnimations`만 보고 `has3DScripts`를 빠뜨린다. 연속 렌더를 켜는 조건(:413)은 `... || has3DScripts`를 포함하므로, **카메라 스크립트/스키닝 애니만 있는 순수 3D 씬**(태양계 궤도·젤다 fov — 네 플래그 전부 false, `has3DScripts`만 true)은 :413에서 30fps로 돌지만 :490 가드가 발동하지 않아 창이 완전히 가려져도 매 프레임 `encode3D`를 계속 실행한다(2D 씬은 절전되는데 3D 애니만 예외로 샘). :413↔:490 조건 비대칭이 근본 원인.
- 권장 조치: :490 조건에 `|| has3DScripts` 추가(is3D 분기보다 앞이라 3D 경로도 커버). 위 pause/resume 항목과 함께 “연속 렌더 여부”를 Bool 하나로 저장해 두 곳이 같은 소스를 참조하게 하면 재발 방지.

**3D 빌보드가 매 프레임 `device.makeBuffer` 신규 할당**
- 파일: SceneRenderer3D.swift:512 · 심각도: high · 작업량: small
- 무엇/왜: `encodeBillboard`가 6정점 버퍼를 매 프레임 힙 할당한다. 같은 파일의 본행렬·2D 파티클/쿼드/스킨은 전부 `DynamicVertexBuffer`(3슬롯 링)로 재사용하는데 빌보드만 누락. 태양계처럼 빌보드 다수 씬은 30fps×N개 단명 MTLBuffer 할당 + in-flight 프레임 경합 위험.
- 권장 조치: `Billboard3D`에 `DynamicVertexBuffer` 추가, :512를 `bb.scratch.load(verts, device:)`로 교체(정점이 카메라 회전으로 매 프레임 바뀌므로 3슬롯 링이 정확히 이 용도).

**`Scene3DMath.perspective`가 near/far 유효성 미검증**
- 파일: Scene3DMath.swift:21 · 심각도: low · 작업량: small
- 무엇/왜: `zz = farZ / (nearZ - farZ)`에서 `nearZ == farZ`(0 분모)·`nearZ <= 0`이면 Inf/NaN 행렬이 나와 `viewProj * w.matrix` → `drawIndexedPrimitives`까지 오염 좌표가 전파된다. fov는 스크립트 경로에서 `f > 0` 가드가 있으나 near/far는 파스값을 그대로 신뢰. 코퍼스가 정상값이라 실물 반례 가능성 낮아 low.
- 권장 조치: 파서가 near/far를 보증하면 `ponytail: near/far는 파서 검증(양수·near<far)` 주석만, 미보증이면 진입부에 `far > near > 0` 최소 클램프.

### WapleRender — 동영상

**볼륨/배속 변경이 렌더러 전체 스왑 → mkv/webm 매번 재변환·재장착**
- 파일: AppDelegate.swift:176,183 → VideoRenderer.swift:37 · 심각도: high · 작업량: medium
- 무엇/왜: 볼륨/배속 메뉴가 `apply(folderURL:)`로 렌더러를 teardown→재mount한다. mp4는 깜빡임 정도지만 미지원 컨테이너는 매번 `FFmpegConverter.convert`를 재호출(캐시 히트여도 teardown→비동기 대기→재장착)해 **재생이 처음부터 리셋되고 한 프레임 검은 화면**이 뜬다. 배속을 한 칸씩 움직이면 그때마다 리셋.
- 권장 조치: `VideoRenderer.applyVolume/applyRate(id:)`를 두고 AppDelegate가 현재 렌더러의 `queue.volume`/`defaultRate`만 갱신(mp4 경로처럼 라이브 반영). fit-mode만 재적용 불가피하고 볼륨/배속은 아니다.

**ffmpeg 완료 콜백 vs teardown 경쟁 → 소유자 없는 유령 재생**
- 파일: VideoRenderer.swift:37-45 · 심각도: high · 작업량: small
- 무엇/왜: 취소 신호가 `self.container == nil` 하나인데, 완료 콜백 `attachPlayer`가 `self.container = container`를 다시 세팅한다(:83). teardown이 :38 통과 후~:43 전에 끼면 정리된 렌더러에 새 AVPlayer·레이어·옵저버가 붙고, RendererSwap이 이 참조를 이미 버려 다시는 teardown되지 않는다(누수 + 안 보이는 오디오).
- 권장 조치: teardown 여부를 별도 불리언(`cancelled`)으로 명시하고 콜백 진입 시 확인. `container` 단일 필드가 취소·장착 의미를 겸하는 게 근본 원인.

**`converted/` 캐시가 무한 증가(evict 없음)**
- 파일: FFmpegConverter.swift:29-39 · 심각도: medium · 작업량: medium
- 무엇/왜: VideoTextureExtractor는 `evictOldest(keep:8)` 상한이 있는데, FFmpegConverter의 `converted/`는 정리 로직이 전혀 없다. mkv/avi/webm을 여러 개 변환하면 각 원본당 수백 MB mp4가 영구 잔존.
- 권장 조치: `VideoTextureExtractor.evictOldest(in:keep:)`를 그대로 재사용해 `run`의 캐시 이동 직후 한 줄 추가(중복 구현 말 것).

**VideoRenderer↔AppDelegate 이중 occlusion 상태**
- 파일: VideoRenderer.swift:86-97, AppDelegate.swift:355-368 · 심각도: medium · 작업량: medium
- 무엇/왜: VideoRenderer는 mount 시 항상 자체 occlusion 옵저버로 pause/play하고, AppDelegate는 옵션 켜지면 1초 폴링으로 같은 렌더러를 pause/resume한다. 두 경로의 “가림” 판정 기준이 다르고(창 occlusionState vs CGWindowList), `pausedManually`/`pausedByOcclusion` 플래그를 공유해 “수동 정지”와 “가림 정지”가 의미상 섞인다. 화면 구성 변경과 겹치면 복귀가 폴링·옵저버 경합에 의존.
- 권장 조치: 정책을 한 곳으로 통일(권장: 렌더러 자체 옵저버로 일임하고 AppDelegate 폴링 제거, 또는 그 반대). 유지 시 최소한 두 판정을 정렬하고 정지 사유를 분리.

### WapleRender — 스크립트/오디오

**evaluateVec가 2원소 객체를 반환 못 해 2D scale 스크립트가 조용히 무시됨**
- 파일: TextScriptEngine.swift:164-172 · 심각도: medium · 작업량: small
- 무엇/왜: `evaluateVec` 반환 파싱이 스칼라(1) 또는 완전 x/y/z(3)만 낸다. 호출부 SceneRenderer3D.swift:105는 2D scale에서 `evaluateVec([s.x,s.y,1])`을 넘기고 `v.count >= 2`를 기대하지만, 2원소는 절대 반환되지 않는다. shims의 `Vec2`(x,y만)로 자연스럽게 `return new Vec2(...)`하면 z 부재로 nil → scale 애니가 조용히 무시. `>= 2` 가드는 도달 불가 죽은 조건.
- 권장 조치: 객체 반환 시 z 부재를 허용(x/y만이면 2원소 반환)하도록 완화.

**L/R 채널 독립 정규화로 스테레오 밸런스 소실**
- 파일: SystemAudioSpectrumProvider.swift:125-126 (유틸 AudioSpectrum.swift:24) · 심각도: low · 작업량: small
- 무엇/왜: `AudioSpectrum.spectrum`은 올바른 단일 배열 정규화기지만, 라이브 캡처가 L·R을 각각 통과시켜 두 채널이 다른 스케일로 정규화된다 → 조용한 채널이 무관하게 peak=1까지 증폭돼 좌우 밸런스가 깨진다. AudioResponse mode=3/좌우 편향 효과 왜곡.
- 권장 조치: 채널별 비닝 후 `max(lMax,rMax)` 공통 최댓값으로 한 번에 정규화(코어 유틸 불변, 호출 규약만).

**SceneAudioPlayer.resume()이 자연 종료된 비-loop 사운드를 되살림**
- 파일: SceneAudioPlayer.swift:42 · 심각도: low · 작업량: small
- 무엇/왜: `resume()`이 `!isPlaying`인 모든 플레이어를 무조건 play한다. single/random 사운드가 자연 종료된 뒤 잠자기→깨어남으로 pause→resume되면 일회성 사운드가 재생된다. 코퍼스 다수가 loop라 우선순위 낮음.
- 권장 조치: pause 시 “재생 중이던” 집합을 기록해 그 집합만 resume.

### WapleRender — 셰이더/디코더

**BC1/2/3 팔레트 색 보간이 정수 내림 → 표준 대비 최대 1~2/255 하향 편향**
- 파일: DXT5Decoder.swift:5,92 · 심각도: low · 작업량: small
- 무엇/왜: `lerp3=(x*(3-t)+y*t)/3` 정수 나눗셈이 항상 내림. 표준/GPU는 반올림. 그라디언트에서 미세 밴딩·하향 편이 누적(태양계 fmt6/7 텍스처가 이 경로).
- 권장 조치: 반올림 원하면 분자에 `+1`. GT가 이미 수용했으면 `ponytail:` 주석만.

### WapleLibrary

**엔트리 삭제 경로 부재 → playlist/monitor에 orphan id 영구 잔존**
- 파일: LibraryStore.swift(remove 없음), PlaylistStore.swift, MonitorAssignmentStore.swift · 심각도: medium · 작업량: medium
- 무엇/왜: 라이브러리 엔트리 삭제 API가 없어, 재가져오기/폴더 이동으로 배경이 사라져도 그 id를 참조하는 `PlaylistStore.ids`·`MonitorAssignmentStore.map`이 청소되지 않는다. 소비 측은 방어돼 크래시는 없으나 설정 파일에 죽은 id가 쌓이고 재생목록 UI에 유령 항목이 남는다.
- 권장 조치: 삭제 기능 추가 시 `LibraryStore.remove(id:)`가 두 스토어의 해당 id도 정리(또는 시작 시 orphan 프루닝). 그 전까지는 재생목록 조회를 `entries`로 필터.

**손상 백업 파일명이 초 해상도 → 같은 초 재손상 시 백업 덮어쓰기**
- 파일: MonitorAssignmentStore.swift:8, LibraryStore.swift:59 · 심각도: low · 작업량: small
- 무엇/왜: 백업 확장자가 `corrupt-<초>`라 존재 확인 없이 `moveItem`. 같은 초 두 번 손상 시 두 번째 `moveItem`이 실패(로그만)하고 원본을 덮어써 손실. 극히 드묾.
- 권장 조치: 목적지 존재 시 밀리초/UUID 접미사, 또는 moveItem 실패 시 덮어쓰기 스킵(공유 헬퍼 한 곳 수정).

### Waple 앱 / 화면보호기

**화면보호기 disable이 오래된 backupKey를 덮어쓸 수 있음**
- 파일: ScreenSaverController.swift:98, ScreenSaverLogic.shouldBackup · 심각도: low · 작업량: small
- 무엇/왜: `shouldBackup`이 `!= saverName`만 보고 “기존 백업 존재 여부”는 안 봐서, 특정 사이클에서 사용자 화면보호기 A를 백업한 뒤 disable 없이 다시 enable될 때 현재 선택 B로 A 백업을 덮어써 A 복원 불가.
- 권장 조치: `shouldBackup`에 “기존 backupKey 있으면 덮어쓰지 않음” 조건 추가.

**WapleSaverView `showMessage:` 재호출 시 이전 CATextLayer 미제거**
- 파일: WapleSaverView.m:120 · 심각도: low · 작업량: small
- 무엇/왜: 매번 새 CATextLayer를 addSublayer하고 기존 것을 superlayer에서 안 뗀다. 현재 호출 경로가 항상 `tearDownContent` 직후라 실누수는 아니나 방어 없음.
- 권장 조치: `showMessage:` 시작에서 기존 messageLayer `removeFromSuperlayer`.

### 멀티모니터

**시차/포인터 오프셋이 항상 주모니터 프레임 기준으로 정규화 + 모니터 수만큼 전역 모니터 중복 등록**
- 파일: ParallaxController.swift:25-27,12-18 · 심각도: low · 작업량: medium
- 무엇/왜: `emit()`이 `NSScreen.main?.frame` 고정이라 보조 모니터 씬의 시차/`g_PointerPosition` UV가 커서 위치와 무관하게 가장자리에 붙박인다. 또 화면마다 SceneRenderer가 각자 전역 `.mouseMoved` 모니터를 걸어 마우스무브당 N배 작업.
- 권장 조치: 오프셋을 렌더러 창이 놓인 화면 기준으로. 단일 모니터 지원 의도면 `ponytail:` 주석 명시. (앱 레벨 단일 ParallaxController 공유가 근본 해법.)

### 빌드

**`.saver` 소스(`WapleSaverView.m`)가 `swift test`/CI 커버리지 밖**
- 파일: scripts/package-app.sh:37-41, WapleSaver/WapleSaverView.m · 심각도: high · 작업량: medium
- 무엇/왜: `.m`이 어느 SPM 타깃에도 없고 `package-app.sh`의 `clang -bundle`만 컴파일한다. `swift build`/`test`가 이걸 안 건드려 문법 오류·프레임워크 링크 실패가 패키징 전까지 드러나지 않는다. README는 화면보호기를 지원 기능으로 명시하는데 이 경로만 CI 신호 전무.
- 권장 조치: CI(또는 package 스크립트)에 `.m` clang 컴파일-only 스텝 추가로 조기 포착. 여력 되면 별도 사전빌드 타깃으로 승격.

### combo/color 편집 정확성

**combo Picker 값-타입 불일치 → 무선택 렌더**
- 파일: PropertyEditorView.swift:74 · 심각도: high · 작업량: small
- 무엇/왜: combo 옵션 value는 `parseValue(_, type:"")`, 프로퍼티 본체 value는 `parseValue(_, type:type)`로 파싱된다. project.json에서 옵션 value가 숫자(`0`)인데 저장값이 문자열(`"0"`)이면 `PropertyValue` Equatable 비교 실패 → Picker가 어떤 tag와도 안 맞아 빈 선택으로 렌더돼 사용자가 현재 값을 못 본다. WE 콘텐츠는 옵션값 타입이 제각각이라 실제 발생 가능.
- 권장 조치: 옵션 파싱을 본체와 동일 정규화하거나 Picker 매칭을 값의 문자열 표현으로 비교.

**textinput이 Enter 없이는 커밋 안 됨 → 포커스 이탈 시 유실**
- 파일: PropertyEditorView.swift:98-101 · 심각도: medium · 작업량: small
- 무엇/왜: 다른 컨트롤은 즉시 커밋인데 textinput만 `.onSubmit`(Enter)에서만 저장. Enter 없이 다른 필드 클릭/닫기 시 유실되고, 즉시-반영 UX라 사용자는 Enter 필요를 알 수 없다.
- 권장 조치: `@FocusState`/`onDisappear`로 포커스 상실 시에도 flush, 또는 즉시 커밋으로 통일.

**ColorPicker sRGB/리니어 색공간 왕복 손실 가능**
- 파일: PropertyEditorView.swift:82-94 · 심각도: low · 작업량: medium
- 무엇/왜: 읽기 `Color(red:green:blue:)`(SwiftUI 기본 공간)와 쓰기 `NSColor(c).usingColorSpace(.sRGB)`(감마 인코딩) 사이 색공간 불일치로 편집→저장→재로딩 시 색이 미세하게 어긋날 수 있다. WE 값이 리니어인지 sRGB인지 확인 필요.
- 권장 조치: WE 색상 규약 확정 후 읽기/쓰기 변환 일치.

---

## 2. 리팩토링 및 아키텍처 (Refactoring & Architecture)

**LE 정수 리더가 다수 파일에 중복(경계검사 규칙 분기 위험)**
- 파일: Model3D.swift:113,255,325 · PuppetModel.swift:88 · ScenePackage/TexImage/ArtworkColors/DXT5Decoder · 심각도: low · 작업량: small~medium
- 무엇/왜: LE u32 리더가 Model3D 한 파일에 3벌(반환형 제각각) + PuppetModel 1벌, 인라인 시프트가 6곳. `.mdl`/pkg 오프셋 리더가 국소 재정의라 경계검사가 갈릴 수 있다.
- 권장 조치: WapleCore에 `readU32LE(at:)`(경계검사 포함) 하나를 두고 mdl/pkg 파서 대체(성능 민감 DXT 인라인은 유지).

**cstring 파서 5중 중복(UTF-8 2벌 + Latin-1 3벌 — mojibake 버그의 온상)**
- 파일: Model3D.swift:118-127,260-265 · PuppetModel.swift:98-101,151,177-183 · 심각도: low · 작업량: medium
- 무엇/왜: null-terminated 읽기가 5벌, 그중 3벌이 Latin-1이라 §1의 CJK 버그를 낳는다.
- 권장 조치: `readCString(at:)`(UTF-8 고정) 한 벌로 통합 → 버그 자동 소멸.

**JSON 딕셔너리 언랩 idiom이 12개 파일에 산재(관용 규칙 커버리지 불일치)**
- 파일: WallpaperProperties.swift:56(dbl), SceneDocument.swift:751-777(unwrap/float/intVal/vec2/vec3), ParticleSystem/EffectManifest/PropertyAnimation/SceneRenderer3D/UserPropertyStore · 심각도: low · 작업량: medium
- 무엇/왜: NSNumber/문자열 관용 언랩이 파일마다 국소 재구현. “문자열 숫자 관용”이 `SceneDocument.float`엔 있고 `WallpaperProperties.dbl`엔 없는 등 커버리지가 갈린다.
- 권장 조치: WapleCore에 얇은 JSON 접근 자유함수(`double/int/string/unwrap`) 몇 개로 수렴(인터페이스/제네릭 불필요 — YAGNI).

**손상 스토어 load 규약이 3벌 복제**
- 파일: LibraryStore.swift:35-54, MonitorAssignmentStore.swift:27-33, PlaylistStore.swift:18-25 · 심각도: low · 작업량: medium
- 무엇/왜: “파일없음=정상 / 읽기실패=corrupt / 디코드실패=corrupt” 3분기가 각 스토어에 재작성. 백업 헬퍼는 공유했지만 로드는 미공유라 규약 드리프트 위험. 게다가 `LibraryStore.save()`는 공유 `backupCorruptStoreFile`을 안 쓰고 백업 로직을 인라인 중복.
- 권장 조치: `readStoreFile(_ url:, _ corrupt: inout Bool) -> Data?` 공유 헬퍼 + `LibraryStore.save()`를 `backupCorruptStoreFile` 호출로 교체.

**예외 핸들러 저장/복원 5중 중복(TextScriptEngine)**
- 파일: TextScriptEngine.swift:104-173 · 심각도: low · 작업량: small
- 무엇/왜: callHook/evaluate/evaluateBool/evaluateVec가 동일 6줄 보일러플레이트를 복사. 공유 컨텍스트 핸들러 오귀속 방지 규약이라 회귀 위험.
- 권장 조치: `withExceptionCapture<T>(_ tag:, _ body:) -> T?` 하나로 감싸고, `setRuntime`도 태워 §1의 핸들러 미적용 문제까지 해결.

**DXT 디코더 헬퍼(`u16`/`color565`)가 3함수에 로컬 중복**
- 파일: DXT5Decoder.swift:16,74,124 · 심각도: low · 작업량: small
- 권장 조치: `lerp3`처럼 `private static`으로 승격해 1벌로.

**TexImage.parse 초반 `i32`가 무경계(현재만 안전)**
- 파일: TexImage.swift:51-56 · 심각도: low · 작업량: small
- 무엇/왜: 다른 두 i32와 달리 경계검사가 없고 `b.count > 42` 암묵 불변식에만 의존. 헤더 확장 시 조용히 OOB.
- 권장 조치: `guard o+4 <= b.count` 추가(다른 파서와 일관).

**강등 const 주입이 헬퍼 전이 폐쇄를 무시**
- 파일: GLSLTranslator.swift:166-184 · 심각도: low · 작업량: medium
- 무엇/왜: 엔진/머티리얼 참조 const를 본문에 직접 이름이 나오는 헬퍼에만 주입. A→B 호출에서 const가 B에만 있으면 A 시그니처가 어긋날 잠재. 현재 실물(radial_blur 단일 헬퍼)은 무사.
- 권장 조치: const 주입을 캡처 전이 폐쇄 이후로 미루거나 호출 그래프 반영.

**과대 파일 잔존: GLSLTranslator(1103) / SceneDocument(778) / SceneRenderer(648)**
- 심각도: low · 작업량: large
- 무엇/왜: SceneDocument는 이미 갓함수 분해됨(양호). GLSLTranslator 본체는 미분할로 최대 덩어리.
- 권장 조치: 강제 아님(YAGNI). 손댈 일 생기면 렉서/식-변환/문-변환 단위 분할 고려.

**예약어 리네임 사전에 파라미터 충돌 회피가 하드코딩(실물마다 증식)**
- 파일: GLSLTranslator.swift:77-85 · 심각도: low · 작업량: medium
- 무엇/왜: 방출 파라미터명(`p`,`eng`,`smp`,`vin`)과의 충돌까지 소스 식별자를 리네임. 방출명 변경 시 동기화 필요, 새 충돌마다 목록 증가.
- 권장 조치: 방출 파라미터에 충돌 불가 프리픽스(`_we_p`) 사용 → 이 클래스 소멸.

**`AudioResponse.compute` 잉여 가드 / `spectrum` 기본 binCount 불일치**
- 파일: AudioResponse.swift:22-23, AudioSpectrum.swift:24 · 심각도: low · 작업량: small
- 권장 조치: 항상 참인 `a < left.count` 가드 정리(또는 비대칭 입력 의도 주석), `spectrum` 기본값을 실제 쓰이는 64로.

---

## 3. 데드코드 삭제 (Dead Code)
> 전수 데드코드 스윕(`swift build` 경고 0건 교차확인) + 서브시스템 에이전트 사용처 grep으로 검증한 항목. 도달불가 코드 수준의 데드는 없음 — 아래는 미사용 심볼·파라미터·obsolete 잔재.

**미사용 파라미터 묶음 (전부 호출부에서 넘기지만 본문 미참조)**
- 파일: TexImage.swift:102 (`parseMip`의 `decodeW`/`decodeH`), SceneRendererFrameEncoder.swift:478 (`buildDisplayTextures`의 `queue`), GLSLTranslator.swift:1068 (`matchWord`의 `name`) · 심각도: low · 작업량: small
- 무엇/왜: `parseMip`은 넘겨받은 decodeW/H 대신 파일에서 직접 읽은 `w`/`h`만 쓴다. `buildDisplayTextures`는 `device`/`cb`만 쓰고 `queue` 미참조(호출부 2곳이 전달). `matchWord`는 실질 "is-word-start" 판정기라 `name` 미참조(호출 3곳이 각자 전방 일치 수행). (주의: TextScriptEngine.swift:192의 동명 로컬 `matchWord`는 `word`를 실제 사용 — 별개, 데드 아님.)
- 권장 조치: 세 파라미터를 시그니처·호출부에서 함께 제거.

**`symbolMap`의 `stage` 파라미터 + `private enum Stage` — frag/vert가 동일 맵을 받음**
- 파일: GLSLTranslator.swift:640-641 · 심각도: low · 작업량: small
- 무엇/왜: `symbolMap(materials:stage:)` 본문이 `materials`만 쓰고 `stage`는 미참조 → 호출부 두 곳(`.fragment` :103, `.vertex` :104)이 **동일 맵**을 받는다. `private enum Stage`(:640)는 이 파라미터 전용으로만 존재(다른 "Stage" 등장은 전부 주석의 파이프라인 단계 명칭).
- 권장 조치: `stage` 파라미터 + `Stage` enum 삭제, 호출 2곳 통합.

**obsolete: `WAPLE3D_*` 구 env 병행 인식** — 해소됨(2026-07 재검증으로 항목 정정)
- 파일: SceneRenderer3D.swift:277 (정의 SceneRenderer.swift:818) · 심각도: low · 작업량: —
- 무엇/왜: 구명 병행 인식은 이미 제거됐다 — `debugFlag("WAPLE_3D_BINDPOSE")` 단일 인자 호출만 남아 있고 리포 전체 `WAPLE3D_` grep 0건(이 항목 자체 제외). spec(specs/2026-07-04-waple-3d-design.md:107)도 신규명 `WAPLE_3D_BINDPOSE` 를 문서화하므로 문서와의 충돌도 없다. (이전 서술은 구명 잔존 + spec 의 구명 문서화라는 이중 역스테일 전제였다.)
- 권장 조치: 추가 조치 불필요.


**`SystemAudioSpectrumProvider.floatSamples(from:)` — stereoSamples로 완전 대체됨**
- 파일: SystemAudioSpectrumProvider.swift:133-171 · 심각도: low · 작업량: small
- 무엇/왜: 첫 채널만 추출하던 구버전. 실제 캡처 경로는 `stereoSamples`만 사용, 어디서도 호출 안 됨(약 40줄, stereoSamples와 대부분 중복).
- 권장 조치: 테스트 참조만 grep 확인 후 삭제.

**`DesktopWindowController.contentViews` — 미사용**
- 파일: DesktopWindowController.swift:18 · 심각도: low · 작업량: small
- 무엇/왜: `screenViews`(키+뷰)로 대체됐고 전 소스·테스트에서 호출 0건.
- 권장 조치: 삭제(SPM 내부 모듈 소비만 존재).

**`WebRenderer.clickMonitor` — 선언·teardown만 있고 할당 없음**
- 파일: WebRenderer.swift:16,214-215 · 심각도: low · 작업량: small
- 무엇/왜: 바탕화면 직접 클릭 전달이 제거되며(:104-105 주석) 프로퍼티/정리만 남은 잔재. 항상 nil.
- 권장 조치: 프로퍼티와 teardown 해제 3줄 삭제.

**`wallpaperRequestRandomFileForProperty` — 콜백 영원히 미호출(비기능 스텁)**
- 파일: WallpaperBridgeJS.swift:60-62, WebRenderer.swift:145-150 · 심각도: low · 작업량: medium
- 무엇/왜: 브리지가 `{type:'randomFile'}`만 보내는데 `didReceive`는 `mediaListen`만 처리 → 메시지 버려짐, 콜백 미호출. JS 표면상 API가 존재하는 듯 보여 진단 어려움.
- 권장 조치: 미지원이면 정의 자체 제거(`typeof` 우회 graceful), 지원하려면 `didReceive`에 케이스 추가.

**`engine.frameTime`(카멜) shim + `frametime` 고정 0.016 미갱신**
- 파일: TextScriptEngine.swift:352 · 심각도: low · 작업량: small
- 무엇/왜: `frameTime` 카멜은 실물 표기가 소문자로 확정됐다면 표면 축소 가능. 둘 다 0.016 고정이라 프레임시간 의존 스크립트는 항상 60fps 가정값.
- 권장 조치: 의도면 `ponytail:` 천장 명시, `frameTime` 카멜 제거 검토.

**`WallpaperProperty.condition` — 파싱만 되고 UI 미소비**
- 파일: WallpaperProperties.swift:66(파싱), PropertyEditorView 미사용 · 심각도: low · 작업량: medium
- 무엇/왜: 조건부 표시/숨김 조건이 파싱·저장되나 편집기는 모든 속성을 무조건 나열 → 무효 조합 노출. 실버그라기보다 미구현이나 편집 UX에 직접 영향.
- 권장 조치: condition 평가해 비활성 속성 숨김/dim, 당장 부담이면 `ponytail:` 미구현 주석.

**`turbulentVelocityRandom`의 scale/offset 미사용**
- 파일: ParticleSystem.swift:36,231-232 · ParticleSimulator.swift:408 · 심각도: low · 작업량: small
- 권장 조치: 무영향이면 파싱에서 드롭, 아니면 apply에서 사용. 최소 의도 주석.

**`assignment`/`replaceIdentifiers`의 `start`/`_ = start` 죽은 변수 + 오해 주석**
- 파일: GLSLTypeAdapter.swift:192,211 · GLSLTranslator.swift:990,994 · 심각도: low · 작업량: small
- 무엇/왜: `assignment` 주석은 “위치 복원”이라지만 실제 복원 안 함, `start`는 미사용.
- 권장 조치: 죽은 변수 제거 + 주석을 실제 동작에 맞게 수정.

**`SceneEffect.audioMode` 소비처 재확인 필요**
- 파일: SceneDocument.swift:25 · 심각도: low · 작업량: small
- 무엇/왜: grep상 정의부 외 참조 미검출. 렌더러 오디오 경로에서 실제 쓰는지 확인 필요(passList/constants/constantScripts는 소비 확인됨).
- 권장 조치: 미사용이면 제거, 예정이면 `ponytail:` 주석.

---

## 4. UI/UX 수정 및 개선 (UI/UX)

**모든 사용자 피드백이 `NSLog`로만 흘러 GUI에서 완전히 비가시(앱 최상위 결함)**
- 파일: AppDelegate.swift:436-438 · 심각도: high · 작업량: small
- 무엇/왜: `notify()`가 NSLog만 호출하는데 이게 앱의 **유일한** 피드백 경로다 — import/적용/미지원/정지배경/로그인/화면보호기 실패가 전부 여기로 모인다. 코드베이스에 `NSAlert`/`UNUserNotification` 0건(grep 확인). “적용했는데 아무 일도 안 일어남 + 이유도 안 보임”이 모든 실패의 기본 UX.
- 권장 조치: 오류는 `NSAlert`, 성공/정보는 `UNUserNotificationCenter` 배너로 승격(NSLog 병행 유지). **이 한 함수만 고치면 아래 다수가 자동 해소.**

**최초 실행 온보딩 전무 + base-assets/ffmpeg 조용한 저하**
- 파일: AppDelegate.swift:44-153, BaseAssetsSettings.swift:10-28 · 심각도: high · 작업량: medium
- 무엇/왜: `firstLaunch` 트리거 전무. 첫 실행 시 메뉴바 아이콘만 뜨고 라이브러리 창도 자동 오픈 안 됨. base-assets 미설정이면 씬이 `SceneRenderer.swift:302`에서 조용히 `return nil`(“씬 개판” 실증과 일치), ffmpeg 부재도 로그만.
- 권장 조치: 첫 실행 감지 후 라이브러리 자동 오픈 + base-assets/ffmpeg 설정 유도. 씬 적용 시 base-assets가 nil이면 안내(notify 채널 재사용). 최소안: 빈 상태 텍스트에 설정 힌트 한 줄.

**전용 환경설정 창 부재 — 설정이 메뉴바에 흩어짐**
- 파일: AppDelegate.swift:48-119 · 심각도: medium · 작업량: large
- 무엇/왜: 화면맞춤·음량/배속·재생목록·가림정지·화면보호기·로그인·base-assets 경로가 메뉴바에 평면 나열. `⌘,` 바인딩도, 현재 base-assets 경로 확인 UI도 없다.
- 권장 조치: SwiftUI `Settings` scene 또는 별도 환경설정 창으로 통합 + `⌘,`. 현재 base-assets/ffmpeg 상태 표시.

**동영상 설정·웹 조작 메뉴가 비해당 배경에서 무반응(조건 비활성화 누락)**
- 파일: AppDelegate.swift:62-80,172-184,104-105,197-203 · 심각도: medium · 작업량: small
- 무엇/왜: “동영상 설정”이 씬/웹 배경에서 no-op(주석이 인정), “웹 조작 창”이 웹 아닐 때 안 보이는 notify로 끝. 재생목록 서브메뉴는 `isEnabled=false` 힌트 패턴이 있는데 여기엔 없다.
- 권장 조치: 현재 배경 타입에 따라 해당 서브메뉴를 `isEnabled=false`(회색)로. `updateVideoMenuStates()`가 이미 타입을 아는 위치라 배선 저렴.

**import 동기 실행 + 로딩 상태 부재 → 대용량 폴더서 앱이 얼어붙은 듯**
- 파일: LibraryViewModel.swift:69-75, LibraryView.swift:27 · 심각도: medium · 작업량: medium
- 무엇/왜: `store.importParent(url)`가 메인스레드 동기(수백 폴더 + project.json 파싱). 진행 표시 없이 멈춘 듯 보이고, 성공 피드백도 없다.
- 권장 조치: import를 백그라운드로, 진행 인디케이터(“N개 발견”). 최소안: 버튼 비활성화 + 스피너 라벨.

**부분 import 실패가 사용자에게 미전달**
- 파일: LibraryViewModel.swift:70-74, LibraryStore.swift:98-118 · 심각도: low · 작업량: small
- 무엇/왜: `importParent`가 `try? importFolder`로 실패를 삼키고, 뷰모델은 `imported.isEmpty`일 때만 알림. 5개 중 3개만 들어온 이유를 알 수 없다.
- 권장 조치: 시도/성공 수(또는 실패 폴더명) 반환해 부분 실패 안내.

**빈 상태 CTA 약함 / 에러가 인라인 표시 없음**
- 파일: LibraryView.swift:31-35, LibraryViewModel.swift:73,81,87-88 · 심각도: low · 작업량: small~medium
- 권장 조치: `ContentUnavailableView`(아이콘+제목+“폴더 가져오기” 버튼). 폴더 유실 타일엔 인라인 badge(“경로 유실”).

**그리드 타일 접근성 라벨/버튼 trait 부재(VoiceOver 사실상 불가) + 키보드 내비 없음**
- 파일: LibraryView.swift:54-109,37-45 · 심각도: medium · 작업량: medium~large
- 무엇/왜: `onTapGesture` 커스텀 뷰라 버튼 역할·힌트·라벨이 없어 스크린리더가 제목·지원여부·선택상태를 못 읽는다. 컨텍스트 메뉴(우클릭)만 있는 기능도 보조기술 접근 어려움. 키보드 포커스/Enter 적용 불가.
- 권장 조치: 타일을 `Button` 또는 `.accessibilityElement`+`.accessibilityLabel/Value`+`.isButton`/`.isSelected`. “폴더 가져오기”에 `.keyboardShortcut`.

**핵심 기능이 우클릭 컨텍스트 메뉴에만 있어 발견성 낮음**
- 파일: LibraryView.swift:78-104 · 심각도: low · 작업량: medium
- 무엇/왜: 속성편집·재생목록·모니터별 적용·조작창이 전부 우클릭에만. 좌클릭은 전체 적용뿐이라 우클릭 안 하면 앱 기능 대부분을 못 찾는다.
- 권장 조치: 타일 hover 시 ⋯ 액션 버튼 또는 선택 시 하단 액션 바. 재생목록 토글은 타일 상시 아이콘.

**웹 배경 상호작용 경로 안내 부재**
- 파일: WebRenderer.swift:104-106, AppDelegate.swift:197-203 · 심각도: medium · 작업량: small
- 무엇/왜: 데스크탑 웹은 실이벤트를 의도적으로 안 받고 유일한 상호작용이 조작 창(⌘i)인데, 웹 적용 시 그 안내가 없다.
- 권장 조치: 웹 적용 성공 시 “이 배경은 조작 창(⌘i)에서 상호작용” 배너, 메뉴 항목은 웹 아닐 때 비활성.

**하드코딩 한국어 문자열 40+개, 현지화 인프라 전무**
- 파일: AppDelegate/LibraryView/PropertyEditorView/LibraryViewModel/WebRenderer:118 · 심각도: low · 작업량: large
- 무엇/왜: `NSLocalizedString`/String Catalog 0건. 배포 대상이 넓어지면 영어권 사용 불가.
- 권장 조치: `String(localized:)` + `.xcstrings`(en/ko). notify 가시화·온보딩 문구를 새로 쓸 때 처음부터 감싸면 마이그레이션 비용 절감.

**미지원 속성 타입(file 등)이 흔적 없이 사라짐**
- 파일: PropertyEditorView.swift:106 · 심각도: low · 작업량: small
- 무엇/왜: `default: EmptyView()`라 목록에 있는 속성이 편집기에서 사라져 “왜 이 옵션이 없지?” 혼란.
- 권장 조치: 회색 “이 유형은 아직 편집 미지원” 플레이스홀더.

**속성편집 “초기화”가 “닫기”와 시각적으로 동등(파괴적 액션 미강조)**
- 파일: PropertyEditorView.swift:13-43 · 심각도: low · 작업량: small
- 권장 조치: 초기화에 `role:.destructive` 또는 확인 단계, 닫기를 기본 액션으로 위계화 + 컨트롤 그룹핑(§5와 연계).

---

## 5. UI 애니메이션 및 디자인 (Animation & Visual Design)
> 현재 UI는 정적 SwiftUI(전환·호버·모션 0), 메뉴바는 고정 이모지 `"🖼"`, 웹 조작창은 `NSView.draw` 직접 그리기. 모든 제안은 기존 로직·데이터 흐름을 그대로 재사용하는 인플레이스 변경.

**그리드 타일 호버 리프트 + 선택 스프링 (체감 최대, 우선)**
- 파일: LibraryView.swift:54,105-108 · 심각도: medium · 작업량: small
- 무엇/왜: 호버·선택·적용 피드백 전무, 선택 테두리가 즉시 튀어 딱딱.
- 권장 조치: `@State hoveredId` + `.onHover`, 호버 시 `.scaleEffect(1.03)` + `.shadow` 강화, 선택 테두리를 `.animation(.spring(response:0.3,dampingFraction:0.7), value: selectedId)`로 감싸기, 탭 시 0.97→1.0 펄스.

**그리드 staggered 등장 + 정렬 애니메이션**
- 파일: LibraryView.swift:38 · 심각도: low · 작업량: medium
- 권장 조치: 타일에 `.transition(.opacity.combined(with:.scale(0.9)))` + index 기반 `.delay`(상한 ~20개), `ForEach(id:\.id)`라 삽입/삭제 리플로우 자동 보간.

**속성편집을 `Form(.grouped)`로 격상 + 라이브 적용 확정 피드백**
- 파일: PropertyEditorView.swift:31-39,52-55 · 심각도: medium · 작업량: small~medium
- 무엇/왜: 평면 VStack 나열이라 타입 혼재로 스캔 어려움. commit 후 시트 안에 확인 신호 없음.
- 권장 조치: `ScrollView{VStack}`→`Form{}`.`.formStyle(.grouped)`(네이티브 섹션 카드 공짜, `control(for:)` 재사용). commit 시 라벨 옆 “적용됨” 체크 페이드(macOS14+ `.symbolEffect(.bounce)`).

**메뉴바 아이콘에 상태 반영(재생/일시정지/전환)**
- 파일: AppDelegate.swift:46 · 심각도: medium · 작업량: medium
- 무엇/왜: 고정 이모지라 가림 정지·재생목록 전환·재생 타입이 안 드러남.
- 권장 조치: SF Symbol 템플릿 이미지(`NSImage(systemSymbolName:)`)로 교체, 상태 전이점(`checkOcclusion`/`resumeFromOcclusion`/`advancePlaylist`)에서 심볼 스왑하는 `updateStatusIcon()` 추가, 전환 순간 `NSAnimationContext` 알파 페이드.

**빈/에러/로딩 상태 디자인 통일**
- 파일: LibraryView.swift:31-35, PropertyEditorView.swift:26-29 · 심각도: medium · 작업량: medium
- 권장 조치: `ContentUnavailableView`(아이콘+CTA), import 중 `ProgressView` 오버레이, 에러는 `@Published lastError`→상단 배너 `.transition(.move(edge:.top))`(§4 notify 가시화와 연계).

**웹 조작 창 로딩·미러 페이드**
- 파일: WebInputProxyView.swift:43-54,46 · 심각도: low · 작업량: small
- 무엇/왜: 첫 스냅샷 전 생문자열이 좌하단(위치도 어색), 로딩→첫 프레임 전환이 툭 끊김.
- 권장 조치: 로딩 텍스트 중앙 정렬 + `NSProgressIndicator`(spinning), 첫 이미지 도착(`nil→non-nil`)에 `NSAnimationContext` 레이어 알파 0→1 페이드(NSView라 Core Animation이 정석).

**미지원 타일 배지·비활성 디자인 격상**
- 파일: LibraryView.swift:63-73 · 심각도: low · 작업량: small
- 권장 조치: 배지에 SF Symbol(`Label`: 지원 `checkmark.circle.fill`, 미지원 `clock.badge`), 배경 `.ultraThinMaterial`, 미지원 타일 `.saturation(0.3)`+`.opacity(0.6)`로 비활성 명시.

**소형 디자인 시스템(상수 enum 1개)**
- 파일: 신규 DesignSystem.swift 제안(현재 매직넘버 산재: cornerRadius 8/4, spacing 16/12/6) · 심각도: low · 작업량: small
- 무엇/왜: 코너·간격이 뷰마다 하드코딩돼 의도/우연 불명.
- 권장 조치: `enum Layout { static let tileCorner: CGFloat = 12; ... }` 수준 상수 모음 하나. **ponytail 주의**: 풀 토큰 시스템/ThemeProvider는 4파일 앱에 과함 — 상수 enum이면 충분.

**시트 등장/닫기·초기화 전환 다듬기**
- 파일: LibraryView.swift:48-50, PropertyEditorView.swift:18-22 · 심각도: low · 작업량: small
- 권장 조치: `.sheet` 기본 유지, 닫기/초기화 상태변경을 `withAnimation`으로 감싸 콘텐츠 전환·값 리셋이 슬라이더에 스프링 반영.

---

## 부록: 방법론 및 커버리지

- **탐색 22 에이전트** (read-only, 각자 배정 파일 정독 + grep): WapleCore 5(씬파서·GLSL·파티클·3D/tex·유틸), WapleRender 8(씬코어·프레임/3D·셰이더/디코더·오디오/미디어·비디오·웹·스크립팅·서포트), WapleLibrary 1, Waple 앱 2(델리게이트/통합·SwiftUI UI), 횡단 6(데드코드 스윕·동시성/메모리·에러/성능·앱 UX·애니메이션/디자인·테스트/빌드/문서/아키텍처).
- **22/22 완료**. 프레임 인코더·3D 심화 에이전트가 인코더 분할 정확성(컴포지션/블렌드 인코더 교체 계약, 과거 복제 루프 발산 회귀의 구조적 제거)·오프스크린 풀 aliasing·3D 좌표/와인딩 규약을 견고로 확인했고, 신규 버그 2건(3D 가림 렌더 누수 :490, perspective near/far 미검증)을 추가했다. 데드코드 전수 스윕은 `swift build` 경고 0건과 교차해 도달불가 코드 부재를 확인하고 미사용 심볼·파라미터를 증거 기반으로 정리했다(이름-충돌 심볼은 놓칠 수 있다는 방법 한계 명시).
- **강점(수정 불필요, 참고)**: 바이너리 파서 강건성(차원 16384 클램프, DoS 상한 512MB/4096, 정수 오버플로 가드, 픽셀 루프 경계검사), `SystemAudioSpectrumProvider`의 generation 기반 고아 스트림 방지, `WallpaperSchemeHandler`의 경로 탈출·심링크 격리 + use-after-stop 방어, teardown↔deinit 대칭성과 `[weak self]` 규율, 효과 폴백 체인(translated>hand-port>skip), BC1/2/3·블렌드 32모드 수식 정확성, premult/straight 파이프라인 일관성.
- **비-이슈로 확인**: 비-보안스코프 북마크(앱이 비샌드박스라 정상), `intervalMinutes` 이중 클램프, `PropertyControl.sliderRange` 방어적 클램프, `PreviewImageCache`, 사양서의 “미구현” 표기(대부분 정직한 스테일 노트 — README의 32모드/523테스트 문구는 정확).
