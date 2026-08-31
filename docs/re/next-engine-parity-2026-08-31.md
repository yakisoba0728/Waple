# 다음 엔진 패리티 타깃 조사 — 2026-08-31

> **구현 후 정정(2026-08-31).** 이 문서의 “현재 Waple” 서술과 3.2~3.3은 패치 전
> 스냅샷이다. focus/smoothing, 독립 `g_ParallaxPosition`, 정적 최상위 root 렌더 이동,
> leaf 기준 interaction, headless 전진, ortho-hybrid model 배선은 착지했다. 후속 바이너리
> 재검증에서 interaction은 draw root가 아니라 **현재 leaf**를 쓴다는 비대칭도 확인했다.
> 정확한 최신 근거와 구현 계약은
> [`camera-parallax-binary-2026-08-31.md`](camera-parallax-binary-2026-08-31.md)가 정본이다.
> 아직 남은 것은 동적 root/leaf frame-state, text hover, camera/path/shake가 반영된 `eye.xy`다.
>
> **후속 구현 정정(2026-08-31).** 아래 2순위 around는 같은 날 PE 명령열 재검증 뒤
> `MapSequenceAroundSolver`로 배선됐다. 3순위도 정적·동적 instance override 각도가
> emitter와 opid 13 around 경로에 모두 배선됐고, emitter `controlpoint` 위치 이동도 해소됐다.

## 결론

다음 구현 타깃으로 **Wallpaper Engine의 정확한 camera-parallax 출력 파이프라인**을 권한다.
한 프레임에서 함께 만들어지는 두 결과를 한 패치로 연결해야 한다.

1. 시차 초점에서 계산한 별도 셰이더 유니폼 `g_ParallaxPosition`
2. 정사영 씬의 각 렌더 오브젝트에 적용하는, 최상위 부모(root) 기준 평행이동

조사 당시 Waple에는 바이너리 산식을 옮긴 순수 함수와 단위 테스트가 이미 있었지만, 실제
`SceneRenderer`는 전역 NDC 근사를 사용하고 `g_ParallaxPosition`을 포인터 UV에
별칭 처리했다. 워크샵 측정 모집단에서는 162씬 중 56씬이 `cameraparallax`를 켠다. 162씬 중
155씬이 정사영이므로, 교집합을 아직 따로 세지 않았어도 **최소 49씬**은 오브젝트 이동 경로에
확실히 도달한다. 나머지를 포함한 56씬 전부는 유니폼 갱신 경로에 도달한다.

이 문서는 Waple HEAD `70a8a708` 위 2026-08-31 작업 트리와 sibling HEAD `1fac2a0c`를
조사한 스냅샷이다. 기존 `docs/re`는 탐색 인덱스로만 사용했고, 아래 판정은 원본 PE,
그 PE에서 생성한 디컴파일 C, 실제 에셋, 현재 소스·테스트·spec에서 다시 확인했다.

## 후보 순위

| 순위 | 후보 | 실제 도달 | 현재 준비도 | 판정 |
| ---: | --- | --- | --- | --- |
| **1** | **정확한 camera-parallax 2출력 배선** | 워크샵 `cameraparallax=true` 56/162씬; 그중 오브젝트 이동은 최소 49씬, 유니폼은 56씬 | 정확 산술·순수 테스트 존재. 렌더 상태, root anchor, EngineU 배선만 남음 | **권장** — 도달 범위와 픽셀 영향이 가장 큼 |
| ~~2~~ | `mapsequencearoundcontrolpoint` 시뮬레이터 배선 | 설치 에셋 7파일; 미러를 접으면 preset 3종 + 원소 preview 1종 | **구현·검증 완료** — 위치/속도/CP frame/RNG/state | **해소 2026-08-31** |
| ~~3~~ | `instanceoverride.controlpointangleN` 런타임 소비 | `angle1` 6오브젝트, `angle2` 1오브젝트; 비영·키프레임 실재 | **구현·검증 완료** — 정적/동적 각도→emitter+around, 캡처 reset 포함 | **해소 2026-08-31** |
| ~~4~~ | `instanceoverride.controlpointN` 런타임 소비 | 직접 파스 1오브젝트; maintain-between 프리뷰 키프레임 | **구현·검증 완료** — direct/baked 소비자·자식 live CP·캡처 reset | **해소 2026-08-31** |

순위의 기준은 `근거 확실성 × 실제 코퍼스 도달 × 시각 영향 × 현재 구현 가능성`이다.
2·3순위도 추측 항목이 아니라 원본 바이너리와 실에셋에서 닫힌 후보지만, 1순위보다 모집단이 작다.

## 1순위: 정확한 camera-parallax 파이프라인

### 1. 원본 엔진의 프레임 데이터 흐름

조사한 원본은 sibling의
[`wallpaper64.exe`](../../../Waple-wallpaper-source/wallpaper_engine/wallpaper64.exe)이며
SHA-256은 `40e2ce021e9352324fadb3b8f72b8ba2a7ee95b71cc571d5b9f84be75cd993b0`,
image base는 `0x140000000`이다.

#### 1.1 초점과 `g_ParallaxPosition`: `Scene::updateCamera`

디컴파일 단위는
[`FUN_1401891a0.c`](../../../Waple-wallpaper-source/analysis/decompiled/all/00000001401891a0__FUN_1401891a0.c)다.

| VA | 읽기/쓰기 | 의미 |
| --- | --- | --- |
| `0x140189b42` | `test [scene+0xe0], 0x100` | `cameraparallax` bit8 게이트. 꺼지면 블록 전체를 건너뜀 |
| `0x140189b67` | `test [renderState+0x118], 0x200200` | 강제 중앙 조건이면 mouse influence를 0으로 만듦 |
| `0x140189b8d`–`0x140189bac` | `renderState+0x8c/+0x90` | 포인터를 `[0,1]`로 clamp, Y는 `1-y`, 필요하면 X mirror |
| `0x140189bd5`–`0x140189c24` | scene `+0x33c`, `+0x354/+0x358`, `+0xf0/+0xf4` | 중앙↔포인터 보간 뒤 런타임 eye.xy를 더해 목표 초점을 만듦 |
| `0x140189c0d`–`0x140189c75` | scene `+0x338`, `+0x340/+0x344` | delay 기반으로 이전 초점에 수렴 |
| `0x140189c79`/`0x140189c84` | scene `+0x340/+0x344` | 새 초점 저장 |
| `0x140189c90`–`0x140189cc6` | renderState `+0x9c/+0xa0` | 초점을 투영 크기로 정규화하고 clamp하여 `g_ParallaxPosition` 저장 |
| `0x1400d9e90`–`0x1400d9ea1` | renderState `+0x9c` → 셰이더 상수 목적지 | 유니폼 핸들러가 vec2 8바이트를 그대로 복사 |

이름 연결도 PE 안에서 닫힌다. 유니폼 등록기
[`FUN_140002860.c`](../../../Waple-wallpaper-source/analysis/decompiled/all/0000000140002860__FUN_140002860.c)는
`0x140003f0f`에서 id `0x6b`(107)를 놓고 `0x140003f17`에서 문자열
`g_ParallaxPosition`을 등록한다. 그 id의 핸들러가 위 `0x1400d9e90`이고, 거기서
`mov rcx,[renderState+0x9c]` 뒤 목적지에 8바이트를 쓴다. 따라서 `+0x9c`의 이름은 추론이 아니다.

원본의 닫힌 식은 다음과 같다. `pointer`는 포인터 UV, `(W,H)`는 정사영 크기, `eye`는
이미 shake가 더해진 런타임 카메라 위치다.

```text
mx = clamp01(pointer.x)
my = clamp01(1 - pointer.y)
target.x = W*0.5*(1-influence) + W*mx*influence + eye.x
target.y = H*0.5*(1-influence) + H*my*influence + eye.y

if delay <= 0:
    focus = target
else:
    alpha = min(1, 10*(1-delay/3)*dt)   // 하한 clamp는 없음
    focus = previous + (target-previous)*alpha

g_ParallaxPosition = clamp01(focus / (W,H))
```

따라서 `mouseInfluence=0`은 “시차 없음”이 아니다. 초점이 캔버스 중앙에 고정될 뿐이고,
아래 오브젝트 이동은 그대로 남는다. 이 성질이 현재 Waple을 가장 간단히 실패시키는 오라클이다.

#### 1.2 실제 렌더 이동: `FUN_14018aac0`

실제 드로우 함수는
[`FUN_14018aac0.c`](../../../Waple-wallpaper-source/analysis/decompiled/all/000000014018aac0__FUN_14018aac0.c)다.
이 함수가 hit-test가 아니라 렌더 경로임은, 오브젝트별 행렬 스택을 복사한 뒤 vtable `+0x50`을
호출하는 `0x14018b00c`–`0x14018b170` 데이터 흐름으로 확인된다.

중요한 세부는 **leaf 자신의 origin/depth가 아니라 최상위 부모의 값을 쓴다**는 점이다.

| VA | 동작 |
| --- | --- |
| `0x14018ab08`, `0x14018ac84` | scene flags를 `0x108`과 비교: bit8 `cameraparallax` **그리고** bit3 정사영일 때만 전용 드로우 분기 |
| `0x14018b047`–`0x14018b060` | 현재 오브젝트의 parent 포인터 `+0x180`을 끝까지 따라가 root 선택 |
| `0x14018b062`/`0x14018b06b` | root `+0x128/+0x12c`에서 origin.xy 읽기 |
| `0x14018b074`–`0x14018b094` | scene `+0x334` amount와 `(rootOrigin-focus)` 곱하기 |
| `0x14018b099`/`0x14018b0a2` | root `+0x170/+0x174`의 `parallaxDepth.xy`를 성분별 곱하기 |
| `0x14018b0ab`/`0x14018b0b9` | 결과를 현재 drawable `+0x178/+0x17c`에 저장 |
| `0x14018b118`–`0x14018b14e` | 현재 render matrix 평행이동에 결과를 합성 |
| `0x14018b16a`–`0x14018b170` | 오브젝트 vtable `+0x50` draw 호출 |

```text
root = topmostParent(drawable)
offset.x = (root.origin.x - focus.x) * cameraParallaxAmount * root.parallaxDepth.x
offset.y = (root.origin.y - focus.y) * cameraParallaxAmount * root.parallaxDepth.y
offset.z = 0
```

즉 같은 root 아래 자식들은 **같은 시차 평행이동**을 받는다. leaf의 `parallaxDepth`를 각각
곱하면 원본과 다르다. 포인터 경로도
[`FUN_140189e10.c`](../../../Waple-wallpaper-source/analysis/decompiled/all/0000000140189e10__FUN_140189e10.c)의
`0x14018a0a9`–`0x14018a11b`에서 같은 scene focus/amount와 공통 오브젝트 depth 슬롯을 사용한다.
따라서 렌더와 hover/click geometry는 같은 최종 이동을 공유해야 한다.

#### 1.3 `parallaxDepth`의 공통 타입과 기본값

공통 오브젝트 디스크립터
[`FUN_1401e0530.c`](../../../Waple-wallpaper-source/analysis/decompiled/all/00000001401e0530__FUN_1401e0530.c)는
`0x1401e082f`에서 문자열 `parallaxDepth`를 잡고, `0x1401e0848`에서 멤버 오프셋 `0x170`,
`0x1401e085a`에서 타입 태그 `1`(vec2)을 등록한다. 공통 오브젝트 생성자
[`FUN_1401ddbb0.c`](../../../Waple-wallpaper-source/analysis/decompiled/all/00000001401ddbb0__FUN_1401ddbb0.c)는
`0x1401ddce1`/`0x1401ddcec`에서 `+0x170/+0x174`를 각각 `1.0`으로 초기화한다.

이 규약은 image/text/particle에만 따로 붙은 타입별 옵션이 아니라 공통 root 속성이다.

#### 1.4 별도 유니폼의 실제 소비자

원본 설치 에셋의
[`depthparallax.vert`](../../../Waple-wallpaper-source/wallpaper_engine/assets/effects/depthparallax/shaders/effects/depthparallax.vert)는
`g_ParallaxPosition * 2 - 1`을 투영축에 사용하고,
[`preview depthparallax.frag`](../../../Waple-wallpaper-source/wallpaper_engine/assets/effects/depthparallax/preview/shaders/effects/depthparallax.frag)는
깊이 매핑 좌표와 fake view direction에 같은 유니폼을 사용한다.

그 프리뷰의
[`scene.json`](../../../Waple-wallpaper-source/wallpaper_engine/assets/effects/depthparallax/preview/scene.json)은
`cameraparallax=true`, amount `0.5`, delay `0.1`, influence `1.0`이고 유일한 이미지 root의
`parallaxDepth`는 `(0,0)`이다. 따라서 이 실에셋은 오브젝트 이동은 일부러 막고 **유니폼 출력만**
쓰는 양성 대조다. `g_ParallaxPosition`을 포인터와 같은 값으로 보내면 delay/강제 중앙/eye가
반영되지 않아 효과 자체가 원본과 갈린다.

### 2. 실제 코퍼스 도달

워크샵 전수 측정의 정본은
[`spec/corpus/scene-schema.json`](../../spec/corpus/scene-schema.json)이며 생성기는
[`measure_scene_schema.py`](../../scripts/spec/measure_scene_schema.py)다.

| 측정 | 값 | 해석 |
| --- | ---: | --- |
| scene 총수 | 162 | 측정 모집단 |
| 정사영 scene | 155 | 비정사영은 7뿐 |
| `cameraparallax=true` | 56 | 유니폼 경로 확정 도달 |
| 정사영 ∩ parallax 하한 | **49** | `56 - 7`; 원시 교집합 행이 없어 쓸 수 있는 보수적 하한 |
| image `parallaxDepth` 저작 | 1,573 objects / 121 scenes | 공통 속성이 광범위하게 저작됨; 활성 교집합은 spec에 없음 |
| text `parallaxDepth` 저작 | 956 / 1,597 objects, 77 scenes | 파서·렌더 소비 중요도를 보이는 저작 밀도 |
| parallax 활성 56씬 안 text | 675 | 269 depth 0, 184 음수, 29 기타 양수, 48 정확히 1, 145 미저작 |

마지막 행의 비기본 local depth는 482개(`269+184+29`)다. 다만 원본 렌더는 root의 depth를
사용하므로, 기존 spec의 “482개가 전부 실효”라는 해석은 상한으로 읽어야 한다. 현재 생성기는
text leaf의 parent 체인을 따라 root depth를 다시 세지 않는다. 이 보고서는 확인하지 않은
교집합을 정확한 영향 수로 과장하지 않는다.

그래도 기능 도달 자체는 보수적으로 최소 49씬이고, sibling/bundled `depthparallax` 프리뷰가
유니폼 gap의 직접 양성 대조이므로 “실코퍼스에 닿는가”는 닫혀 있다.

### 3. 현재 Waple의 정확한 gap

#### 3.1 산술은 이미 있으나 production이 호출하지 않는다

[`SceneGeometry.swift`](../../Sources/WapleCore/SceneGeometry.swift)의 `SceneCameraMath`에는
다음 순수 함수가 원본 식 그대로 존재한다.

- `parallaxFocus`
- `parallaxAlpha`
- `parallaxSmoothed`
- `parallaxLayerOffset`
- `parallaxUniform`

[`CameraMotion.swift`](../../Sources/WapleCore/CameraMotion.swift)의 `CameraMotion.frame`도
shake → FOV clamp → focus/uniform 순서를 표현한다. 닫힌 식 검증은
[`SceneGeometryCameraMathTests.swift`](../../Tests/WapleCoreTests/SceneGeometryCameraMathTests.swift)와
[`CameraMotionPathTests.swift`](../../Tests/WapleCoreTests/CameraMotionPathTests.swift)에 있다.

남은 문제는 산술이 아니라 **production state와 draw data flow**다.

#### 3.2 구현 전 live renderer는 origin과 root를 잃은 전역 NDC 근사였다

구현 전 `SceneRenderer.updateParallax`는 다음 값을 모든 drawable에 공통으로 만들었다.

```swift
let s = parallaxAmount * parallaxMouseInfluence * maxShift // maxShift = 0.1
targetCameraOffset = normalizedPointerOffset * s
```

이 값은 다음 점에서 원본과 다르다.

- `mouseInfluence`를 중앙↔포인터 초점 보간이 아니라 전체 이동의 gain으로 사용한다.
- `mouseInfluence=0`이면 이동이 0이 되어, 원본의 중앙 초점 기준 정적 scale-out이 사라진다.
- drawable/root origin 항이 없다.
- parent chain의 최상위 root origin/depth가 아니라 leaf별 depth를 사용한다.
- 근거 없는 `maxShift=0.1` 상한/스케일이 들어간다. 원본 오프셋에는 상한 clamp가 없다.

[`QuadShaders.swift`](../../Sources/WapleRender/QuadShaders.swift)는 그 하나의 `cameraOffset`을
`parallaxDepth`와 곱하고, [`SceneRendererFrameEncoder.swift`](../../Sources/WapleRender/SceneRendererFrameEncoder.swift)는
image와 particle에는 leaf depth를 넘기며 text에는 `(1,1)`을 하드코딩한다. text 파서 자체는 현재
[`SceneDocument.parseText`](../../Sources/WapleCore/SceneDocument.swift)에서 `parallaxDepth`를 이미
읽는다. 따라서 `scene-schema.json`의 `waple: null`/“미파싱” 표시는 현재 작업 트리보다 낡았고,
남은 gap은 소비 쪽이다.

헤드리스 [`captureFrames`](../../Sources/WapleRender/SceneRenderer.swift)는 `camOff=(0,0)`을
고정한다. 그러므로 현재 스냅샷 회귀 스위트는 active parallax scene을 렌더해도 이 구조적 gap을
관측하지 못한다.

#### 3.3 구현 전 `g_ParallaxPosition`은 포인터 별칭이었다

구현 전 [`GLSLTranslator.engineReplacement`](../../Sources/WapleCore/GLSLTranslator.swift)는
두 이름을 모두 `eng.timeAndPad.yz`로 번역했다.

```swift
g_PointerPosition  -> eng.timeAndPad.yz
g_ParallaxPosition -> eng.timeAndPad.yz
```

[`SceneRenderer.engineUniform`](../../Sources/WapleRender/SceneRendererFrameEncoder.swift)의
`EngineU`에도 parallax 전용 vec2가 없다. 원본은 포인터 `renderState+0x8c`와 parallax
`renderState+0x9c`를 별도 필드로 보유하므로 이 별칭은 데이터 모델 단계에서 틀리다.

### 4. 구현 전 권장 경계

이 조사에서는 production/test 코드를 수정하지 않았다. 다음 패치의 경계는 아래처럼 잡으면 된다.

1. **프레임 상태를 focus 단위로 교체**
   - `cameraOffset/targetCameraOffset` 전역 NDC 상태를 `focus/targetFocus/parallaxUniform`으로 교체한다.
   - live draw와 `captureFrames`가 같은 `advanceParallax(pointer, dt)`를 호출하게 한다.
   - delay가 있는 headless timeline은 particle warm-up처럼 0→t를 결정적 step으로 전진시킨다.

2. **root anchor를 보존·해결**
   - 공통 object ID/parent 그래프에서 각 drawable의 최상위 root ID를 해소한다.
   - root의 현재 origin과 `parallaxDepth`를 draw 시점에 읽는다. 정적 mount 시점 leaf 값으로
     접으면 root의 property animation/script 변화를 놓친다.
   - `SceneNode3D`는 현재 `parallaxDepth`를 저장하지 않으므로 공통 기본 `(1,1)`과 JSON 파스를 추가한다.
   - ID 중복 승자는 기존 `SceneDocument.claimObjectID` 규약을 재사용한다.

3. **draw별 이동을 계산**
   - 정사영 + parallax 활성일 때만 `SceneCameraMath.parallaxLayerOffset(rootOrigin, focus, amount, rootDepth)`를
     계산해 scene-pixel→NDC 변환한다.
   - image/text/particle와 custom layer matrix에 같은 값을 쓴다.
   - **후속 정정:** hover/click quad는 render root가 아니라 현재 image/text leaf의 raw
     origin/depth 이동을 쓴다.
   - perspective 3D drawable에는 이동을 적용하지 않되, 정사영 씬의 hybrid model은 적용한다.

4. **EngineU에 독립 유니폼 추가**
   - `EngineU`에 정렬된 `float4 parallaxAndPad`를 추가하고 `.xy`를 사용한다.
   - `engineUniform` packing, GLSLTranslator의 방출 struct, 2D/3D custom shader buffer 길이 테스트를
     한 번에 갱신한다.
   - `g_ParallaxPosition`을 `eng.parallaxAndPad.xy`로 번역한다. `g_PointerPosition`은 기존 슬롯을 유지한다.

5. **text의 하드코드와 interaction을 함께 검증**
   - root가 text 자신인 경우에만 authored text depth가 직접 root depth가 된다.
   - parent가 있는 leaf에서는 바이너리 자체가 render(root)와 hit(leaf)를 다르게 계산한다. 두 경로를
     하나의 root helper로 합치지 말고 각각의 원본 계약을 독립 테스트한다.

### 5. 정확한 red/green 오라클

#### 5.1 CPU bridge: `mouseInfluence=0`이 여전히 이동한다

합성 2D scene을 `W=200`, `H=100`, amount `0.5`, delay `0`, influence `0`으로 만든다.
포인터 위치와 무관하게 원본 focus는 `(100,50)`이다.

| root | origin | depth | 원본 offset | 최종 center |
| --- | --- | --- | --- | --- |
| A | `(50,50)` | `(1,1)` | `(-25,0)` | `(25,50)` |
| B | `(150,50)` | `(1,1)` | `(+25,0)` | `(175,50)` |

현행 Waple은 `parallaxMouseInfluence`를 displacement에 곱하므로 두 offset 모두 0이다. 따라서
production bridge를 직접 호출하는 테스트는 수정 전 확실히 RED이고, 순수 산식을 테스트 안에서
복제하지 않아도 된다.

#### 5.2 root ancestry 오라클

root image/node를 origin `(50,50)`, depth `(0,0)`으로 두고, 그 아래 text leaf에는 서로 다른
origin과 depth `(-1,2)`를 둔다. 기대 이동은 **0**이다. 다음 대조에서는 root depth를 `(1,1)`,
leaf depth를 `(0,0)`으로 바꾸고 root 식의 `(-25,0)`이 leaf에도 그대로 적용되는지 본다.

이 두 케이스가 없으면 leaf depth를 곱하는 구현도 단순 scene에서는 녹색이 될 수 있다.

#### 5.3 GPU pixel 오라클

200×100 BGRA target에 10×10 불투명 quad 두 개를 위 A/B root에 놓는다. `delay=0`으로 시간 오차를
없애고 다음을 assert한다.

- alpha/luma가 x≈25와 x≈175에 존재한다.
- 이전 위치 x≈50와 x≈150에는 존재하지 않는다.
- normal text와 `colorBlendMode != 0` text 두 경로가 같은 root offset을 받는다.
- root text depth `(0,0)`은 고정되고, `(-1,0)`은 X 방향을 반전한다.

#### 5.4 독립 유니폼 오라클

`W=H=600`, pointer UV `(0.25,0.75)`, influence `1`, delay `0`, eye `(0,0)`이면 Y flip 뒤
focus는 `(150,150)`, `g_ParallaxPosition`은 정확히 `(0.25,0.25)`다. 동시에
`g_PointerPosition`은 `(0.25,0.75)`이므로 두 슬롯이 달라야 한다.

- 생성 MSL에서 `g_ParallaxPosition`이 `eng.parallaxAndPad.xy`를 참조하는지 검사한다.
- `engineUniform`의 packing offset과 전체 float count를 직접 검사한다.
- bundled `depthparallax` 프리뷰 또는 두 유니폼의 차이를 색으로 내는 합성 shader를 렌더해
  alias가 남아 있으면 픽셀 테스트가 실패하게 한다.

#### 5.5 게이트와 상태 오라클

- `cameraparallax=false`: focus와 유니폼을 갱신하지 않고 오브젝트 이동 0.
- 3D: 유니폼은 갱신하지만 오브젝트 parallax translation은 0.
- depth 0 고정, 음수 depth 방향 반전, 미저작 root depth `(1,1)`.
- delay `0.1`에서 `alpha=min(1,10*(1-delay/3)*dt)`; 지수 시상수 구현 금지.
- live draw와 sorted headless capture times가 같은 focus state를 만든다.

### 6. 왜 이 둘을 한 패치로 묶어야 하는가

오브젝트 이동만 고치면 bundled `depthparallax` 프리뷰는 root depth 0이라 아무 변화가 없고,
유니폼 alias가 그대로 남는다. 반대로 유니폼만 고치면 워크샵의 최소 49개 정사영 parallax scene에서
root 중심 scale-out이 계속 전역 포인터 이동으로 남는다. 두 출력은 원본의 같은 focus state에서
갈라지는 형제이므로 하나의 production seam과 하나의 frame-state 테스트군으로 닫는 것이 맞다.

## 해소(2026-08-31): `mapsequencearoundcontrolpoint` 런타임 배선

조사 당시에는 파스 전용이었지만, 현재 [`ParticleSimulator.swift`](../../Sources/WapleCore/ParticleSimulator.swift)의
`MapSequenceAroundSolver`와 `applyMapSequenceAround`가 선언별 상태를 보존해 production spawn에서 소비한다.

원본 분기는
[`FUN_14023b340.c`](../../../Waple-wallpaper-source/analysis/decompiled/all/000000014023b340__FUN_14023b340.c)의
opid 13 `0x14023c4cf`–`0x14023ca93`이다. 이 분기는 CP 위치를 빼고 axis 방향 성분을 보존한 뒤,
회전한 두 직교 기저로 반경을 재배치하고 speed min/max의 세 성분에 난수 세 개를 섞어 속도에
가산한다. 끝의 `0x14023ca02`–`0x14023ca8b`가 선언 자체의 `step/t`를 갱신하므로 상태는
파티클별이 아니라 **선언별**로 다음 spawn까지 이어져야 한다.

설치 에셋의 물리 파일은 7개다. preset/preview 미러를 접으면
[`dna.json`](../../../Waple-wallpaper-source/wallpaper_engine/assets/presets/abstract/particles/presets/dna.json),
[`magic_trinity.json`](../../../Waple-wallpaper-source/wallpaper_engine/assets/presets/magic/particles/presets/magic_trinity.json),
[`starcircle.json`](../../../Waple-wallpaper-source/wallpaper_engine/assets/presets/stars/particles/presets/starcircle.json)
세 preset과 원소 preview 하나다. 특히 `magic_trinity`의 speed `Y=10...100`도 이제 반경 방향
affine으로 적용된다.

구현 오라클은 CP=원점, axis `(0,0,1)`, bounds `0...1`, count 4, 초기 위치 `(10,0,0)`인
burst와 순수 solver의 고정 난수 입력으로 다음을 단언한다.

- 위치가 모두 반경 10을 보존하고, 선언의 `t = 0, .25, .5, .75, 1` 순서로 원을 돈다.
- repeat의 다섯 번째 spawn은 `t=1` 끝점을 쓴 뒤 `fmod(1.25,1)=0.25`로 감기고,
  mirror는 `t=0.75`, 음의 step으로 반사되는지 본다.
- RNG 세 draw를 고정했을 때 speed min/max의 X/Y/Z 기여가 원본 명령 순서와 일치한다.
- speed가 0이어도 RNG 세 draw를 소비해 뒤 이니셜라이저의 스트림 위치가 보존되는지 본다.
- authored `controlpoint[].angles`는 inert이고 정적 scene override 각도만 CP 3×3에 도달하는지 본다.

표적 `ParticleMapSequenceOracleTests`는 41건 전부 통과했다. 남은 around 관련 불명점은 본 위치/속도
핸들러가 아니라 보조 스트림 opcode 3/10의 producer 필드 의미다.

## 해소: `instanceoverride.controlpointN` / `controlpointangleN` 런타임 소비

씬 파서는 [`ParticleInstanceOverride.controlPointAngles`](../../Sources/WapleCore/ParticleSystem.swift)를
보존하고, [`ParticleControlPointFrame.swift`](../../Sources/WapleCore/ParticleControlPointFrame.swift)는
원본의 `Rz·Ry·Rx` 회전과 override gate를 순수 함수로 옮겼다. raw authored angles와
실제 CP frame 각도를 분리한 `controlPointFrameAngles`를 이미터와 opid 13이 읽는다.
`controlpointangleN` 키프레임은 `ParticleSimulator` 내부 시계에서 매 서브스텝 평가되고,
`GPUParticleSystem.freshSimulator()`가 최초 생성·2D/3D 캡처/seek 재생성에 같은 트랙을 전달한다.

원본 CP 갱신
[`FUN_14022bd40.c`](../../../Waple-wallpaper-source/analysis/decompiled/all/000000014022bd40__FUN_14022bd40.c)는
`0x14022bf53`–`0x14022c069`에서 sin/cos로 CP `+0x80/+0x90/+0xa0`의 회전 3행을 쓴다.
그 프레임은 emitter VM
[`FUN_1402378a0.c`](../../../Waple-wallpaper-source/analysis/decompiled/all/00000001402378a0__FUN_1402378a0.c)의
두 emitter arm과 위 around 분기 `0x14023c524`–`0x14023c5a5`가 실제 소비한다. 즉 각도는 CP 위치를
회전시키는 값이 아니라 **방출·around 기저를 회전시키는 값**이다.

설치/동봉 에셋에는 `controlpointangle1` 6오브젝트와 `controlpointangle2` 1오브젝트가 있다.
[`previewdrippingwater/scene.json`](../../../Waple-wallpaper-source/wallpaper_engine/assets/presets/water/previewdrippingwater/scene.json)은
두 CP를 각각 `−0.52360/+0.52360`rad로 벌리고,
[`previewvortexorb/scene.json`](../../../Waple-wallpaper-source/wallpaper_engine/assets/presets/magic/previewvortexorb/scene.json)은
angle1을 키프레임으로 움직인다.

오라클은 z축 `π/2` override를 CP1에 주고 고정 RNG로 같은 emitter를 두 번 spawn하는 production
bridge다. angle 0 대조의 기저 X 방향이 회전 케이스에서 Y 방향이 되어야 하고, 위치 row는 동일해야 한다.
동시에 `flags & 0x10005` CP에서는 회전 override가 무시되는 음성 대조와, 정적 `±π/6` 및 키프레임
`π/2` 두 시점의 particle centroid 방향을 검사하면 파스만 된 가짜 녹색을 막을 수 있다.

구현 테스트는 이미터와 opid 13 양쪽, relative base 비누적, block mask, `0x10` 허용 대조를 잠근다.
다만 `previewvortexorb`의 실제 파티클은 emitter CP0이고 around 선언이 없어 angle1 트랙과 소비처의
교집합이 0이다. 따라서 이 수정은 워크샵/일반 입력의 엔진 호환성 결함을 닫지만 해당 번들 씬의
픽셀을 바꾸지는 않는다.

위치 트랙은 같은 시계에서 live CP 배열을 갱신한다. emitter·mapsequence-between/around·remap CP 입력·
maintain-between은 배열을 직접 읽고, attract·maintain-to·vortex·reduce는 정적 target에
`runtimeCP - defCP`를 합성한다. 이 방식은 vortex authored offset을 보존하며 정적 CP에서는 원본
target을 그대로 반환한다. flags&4 자식은 `parentcontrolpoint`로 매핑한 부모 live 위치/각도를 받고,
재베이크는 binding에 보존한 authored offset을 써 멱등이다. 동봉 maintain-between 프리뷰의
`controlpoint1` 키프레임은 이제 실제 선분 제약에 도달한다.

## 제외한 낡은 후보

- `perspective:true` / `perspectiveoverridefov`는 현재 작업 트리에서 이미
  [`SceneCameraMath.layerPerspectiveScale`](../../Sources/WapleCore/SceneGeometry.swift)을
  [`SceneRenderer.quadVertices`](../../Sources/WapleRender/SceneRendererFrameEncoder.swift)가 소비하고,
  [`ScenePerspectiveOverrideFovRenderTests.swift`](../../Tests/WapleRenderTests/ScenePerspectiveOverrideFovRenderTests.swift)가
  생겼다. BACKLOG의 미구현 표기만 보고 다시 고칠 항목이 아니다.
- text `parallaxDepth` “미파싱”도 현재 `SceneDocument.parseText`에는 이미 착지했다. 남은 것은
  text leaf를 그대로 곱하는 것이 아니라 **원본 root anchor 규약으로 렌더·interaction을 배선하는 일**이다.
- `mapsequencebetweencontrolpoints`와 `mapsequencearoundcontrolpoint`는 현재
  `ParticleSimulator.spawn`이 선언별 solver를 호출한다. `.mapSequence` switch의 방어 no-op만 보고
  두 분기를 미구현으로 세면 안 된다.
- `remapvalue.flags`도 현재 `parseOperators.extKeys`에 들어가 rain speed의 Ex 경로와 bit1 clamp를
  보존한다. 이 보고서를 쓰는 동안 작업 트리가 전진해 후보에서 제외했다.
- ambient/skylight custom-shader EngineU feed는 파스와 stock 3D 소비는 존재하지만, 번역 셰이더가
  실제로 그 값을 읽는 workshop 교집합이 현재 spec에 없다. 영향 범위를 추정해야 하므로 위 세 후보보다 뒤다.

## 구현 완료 판정

다음 조건을 모두 만족해야 1순위가 끝난다.

- production draw/capture가 `SceneCameraMath`의 focus/smoothing/uniform을 실제 호출한다.
- root parent가 있는 image/text/particle의 pixel 위치가 원본 root formula와 일치한다.
- `g_PointerPosition`과 `g_ParallaxPosition`이 EngineU에서 독립 슬롯이다.
- bundled `depthparallax` 프리뷰가 독립 유니폼 경로를 실제 소비한다.
- hover/click geometry가 draw root가 아닌 현재 image/text leaf offset을 쓴다.
- 2D/3D, depth 0/음수/기본, influence 0/1, delay 0/양수, live/headless 대조가 모두 녹색이다.

정적 경로는 위 조건으로 검증됐다. 전체 완료로 세려면 동적 root/leaf frame-state, text hover,
camera/path/shake `eye.xy` 교집합까지 별도 오라클로 닫아야 한다.
