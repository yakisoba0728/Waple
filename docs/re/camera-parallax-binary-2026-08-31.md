# Camera parallax binary revalidation (2026-08-31)

## 결론

Wallpaper Engine의 camera parallax는 한 개의 전역 포인터 오프셋이 아니라, 같은 `focus`
상태에서 갈라지는 두 출력이다.

1. `g_ParallaxPosition = clamp01(focus / projectionSize)`라는 별도 `vec2` 유니폼
2. 정사영 드로우에서 `(root.origin - focus) * amount * root.parallaxDepth`로 만든
   오브젝트별 평행이동

`mouseInfluence == 0`은 두 번째 출력을 끄지 않는다. 포인터 성분만 중앙으로 강제하므로
`focus = projectionCenter + eye.xy`가 되고, root가 그 초점에서 떨어져 있으면 여전히 움직인다.
`parallaxDepth`도 clamp하지 않는다. 0은 고정, 음수는 방향 반전이다.

이번 재검증에서 구현 전에 특히 주의해야 할 비대칭도 확인했다.

- 실제 **드로우** 경로는 parent 포인터를 끝까지 따라가 최상위 root의 origin/depth를 쓴다.
- 포인터 **interaction/hit geometry** 경로는 현재 image(type 1)/text(type 4) 자신의 origin/depth를 쓴다.
  그 수식 앞에는 parent walk가 없다.

따라서 바이너리 충실도가 목표라면 드로우용 root offset을 interaction에 그대로 공유하면 안 된다.
다만 solid image/text 중 실제 interaction 대상이 parent를 가진 실물 사례의 교집합은 현재 보존된 코퍼스
요약만으로 계산할 수 없어, 이 비대칭의 실물 도달 수는 미확정이다.

## 조사 대상과 방법

- 기준 바이너리: [`wallpaper64.exe`](../../../Waple-wallpaper-source/wallpaper_engine/wallpaper64.exe)
  - PE32+ x86-64, 5,360,112 bytes
  - SHA-256: `40e2ce021e9352324fadb3b8f72b8ba2a7ee95b71cc571d5b9f84be75cd993b0`
  - 짝 저장소 커밋: `1fac2a0cc04335d876a860990208b29cf8713fb0`
- 함수 경계와 의사코드: [`analysis/decompiled/all`](../../../Waple-wallpaper-source/analysis/decompiled/all)
- 주소 재검증: `pefile`로 VA를 RVA로 변환한 뒤 Capstone x86-64로 바이너리 바이트를 직접
  디스어셈블했다. 아래 주소는 의사코드 줄 번호가 아니라 PE 가상주소다.
- 실물 자산 대조:
  [`depthparallax preview scene`](../../../Waple-wallpaper-source/wallpaper_engine/assets/effects/depthparallax/preview/scene.json),
  [`depthparallax.vert`](../../../Waple-wallpaper-source/wallpaper_engine/assets/effects/depthparallax/shaders/effects/depthparallax.vert)
- 워크샵 측정 대조:
  [`spec/corpus/scene-schema.json`](../../spec/corpus/scene-schema.json), 생성기
  [`scripts/spec/measure_scene_schema.py`](../../scripts/spec/measure_scene_schema.py)
- 오브젝트 type/히트 경로 대조:
  [`spec/engine/scene-objects.json`](../../spec/engine/scene-objects.json), 생성기
  [`scripts/spec/measure_scene_objects.py`](../../scripts/spec/measure_scene_objects.py)

## 1. 씬 필드와 게이트

[`FUN_140199780`](../../../Waple-wallpaper-source/analysis/decompiled/all/0000000140199780__FUN_140199780.c)은
JSON 키를 다음 씬 필드에 등록한다.

| JSON 키 | scene offset | 근거 주소 |
| --- | ---: | ---: |
| `cameraparallax` | flags `+0xe0` bit 8 (`0x100`) | offset 등록 `0x14019b0e5`; 핸들러 `FUN_14019c850` 줄 19–25 |
| `cameraparallaxamount` | `+0x334` | `0x14019b189` |
| `cameraparallaxdelay` | `+0x338` | `0x14019b20d` |
| `cameraparallaxmouseinfluence` | `+0x33c` | `0x14019b292` |

[`FUN_140186c90`](../../../Waple-wallpaper-source/analysis/decompiled/all/0000000140186c90__FUN_140186c90.c)의
`orthogonalprojection` 파서는 width/height가 둘 다 0이 아니면 `scene+0xe0` bit 3 (`0x8`)을
세운다(디컴파일 줄 359–377). 따라서 뒤의 `flags & 0x108 == 0x108` 비교는
`cameraparallax && orthographic`이다.

게이트는 출력마다 다르다.

| 출력 | 바이너리 게이트 | 의미 |
| --- | --- | --- |
| focus 및 `g_ParallaxPosition` | `test [scene+0xe0], 0x100` @ `0x140189b42` | parallax가 켜져 있으면 정사영 여부와 무관하게 갱신 블록 진입 |
| 드로우 평행이동 | `(flags & 0x108) == 0x108` @ `0x14018ab08`–`0x14018ac8b` | parallax + 정사영에서만 전용 드로우 분기 |
| interaction offset | bit 8과 bit 3을 각각 검사 @ `0x140189f17`–`0x140189f2c` | 역시 parallax + 정사영에서만 계산 |

즉 3D/perspective 씬에서는 오브젝트 평행이동이 없지만, parallax 플래그가 켜졌다면 유니폼
갱신 블록 자체는 실행된다. 그 블록 안에서 render-state flags `0x200200`이 하나라도 켜져 있으면
mouse influence를 0으로 강제한다. `0x200`과 `0x200000` 각각의 사용자 수준 의미는 이번 범위에서
이름까지 확정하지 못했다.

## 2. focus의 정확한 산술과 좌표계

핵심은 [`FUN_1401891a0`](../../../Waple-wallpaper-source/analysis/decompiled/all/00000001401891a0__FUN_1401891a0.c)의
`0x140189b42`–`0x140189c79`다. 상수 바이트도 직접 확인했다.

- `DAT_1404926c0 = 0.5f`
- `DAT_140492704 = 1.0f`
- `DAT_140492830 = 3.0f`
- `DAT_140492868 = 10.0f`

기호는 다음과 같다.

- `W = scene[+0x354]`, `H = scene[+0x358]`
- `eye = scene[+0xf0,+0xf4]` — 이 프레임의 카메라/경로/shake 적용 뒤 eye.xy
- `pointerStored = renderState[+0x8c,+0x90]`
- `I = scene[+0x33c]`, 단 `(renderState.flags & 0x200200) != 0`이면 `I = 0`
- `D = scene[+0x338]`, `dt = FUN_1401891a0`의 두 번째 인자

바이너리 순서 그대로 쓰면:

```text
mx = clamp01(pointerStored.x)
my = clamp01(1 - pointerStored.y)

if renderState.flags & 0x800:
    mx = 1 - mx

target.x = eye.x + W * (0.5 * (1 - I) + mx * I)
target.y = eye.y + H * (0.5 * (1 - I) + my * I)

if D <= 0:
    focus = target
else:
    alpha = min(1, 10 * (1 - D / 3) * dt)
    focus = previousFocus + (target - previousFocus) * alpha
```

근거 주소:

| 범위 | 관측 |
| --- | --- |
| `0x140189b67`–`0x140189b7a` | flags `0x200200`이면 influence 0, 아니면 `scene+0x33c` |
| `0x140189b7e`–`0x140189ba8` | X clamp, `1-Y` 뒤 Y clamp |
| `0x140189bac`–`0x140189bbf` | flags bit 11 (`0x800`)일 때 입력 X 반전 |
| `0x140189bbf`–`0x140189c24` | projection center, mouse influence, eye.xy의 합 |
| `0x140189c0d`–`0x140189c2c` | delay가 0 이하이면 smoothing 생략 |
| `0x140189c2e`–`0x140189c4d` | `alpha = min(1, 10*(1-D/3)*dt)` |
| `0x140189c51`–`0x140189c79` | previous에서 target으로 alpha 보간 |

중요한 경계 성질:

- alpha에는 **하한 clamp가 없다**. `D > 3`이면 음수가 될 수 있다.
- focus와 layer offset에는 크기 상한이 없다.
- `I = 0`은 `target = projectionCenter + eye.xy`이지 `offset = 0`이 아니다.
- 입력 Y만 `1-y`로 뒤집힌다. X mirror flag `0x800`은 입력 focus 계산과 최종 유니폼 X에
  각각 별도로 적용된다.

## 3. `g_ParallaxPosition`은 포인터와 다른 유니폼이다

[`FUN_140002860`](../../../Waple-wallpaper-source/analysis/decompiled/all/0000000140002860__FUN_140002860.c)
디컴파일 줄 1108–1114는 다음 연속 ID를 등록한다.

| ID | 이름 |
| ---: | --- |
| 104 | `g_PointerPositionLast` |
| 105 | `g_PointerPosition` |
| 106 | `g_PointerState` |
| **107** | **`g_ParallaxPosition`** |

바이너리 dispatch 표 `0x1400daaac`/`0x1400da984`를 따라가면 ID 107은
`0x1400d9e90`으로 간다. 그 핸들러는 `renderState+0x9c`의 qword를 그대로 유니폼 목적지에
복사한다(`0x1400d9e90`–`0x1400d9ea1`). 즉 두 float가 별도 상태로 공급된다.

focus 저장 직후 `FUN_1401891a0`은 다음을 계산한다.

```text
g_ParallaxPosition.x = clamp01(focus.x / W)
g_ParallaxPosition.y = clamp01(focus.y / H)

if renderState.flags & 0x800:
    g_ParallaxPosition.x = 1 - g_ParallaxPosition.x
```

주소는 `0x140189c90`–`0x140189cea`, 저장 위치는 render state `+0x9c/+0xa0`다.
이 블록에는 W/H가 0일 때의 명시적 보호가 없다.

동봉 [`depthparallax.vert`](../../../Waple-wallpaper-source/wallpaper_engine/assets/effects/depthparallax/shaders/effects/depthparallax.vert#L44)는
`g_ParallaxPosition * 2 - 1`을 사용한다. 따라서 `(0.5,0.5)`가 셰이더의 중립 중앙이라는
바이너리 정규화를 자산도 독립적으로 확인한다.

## 4. 드로우 경로: 최상위 root 기준

[`FUN_14018aac0`](../../../Waple-wallpaper-source/analysis/decompiled/all/000000014018aac0__FUN_14018aac0.c)의
정사영+parallax 분기는 각 drawable을 그리기 직전에 다음 일을 한다.

```text
root = drawable
while root.parent != nil:
    root = root.parent

offset.x = (root.origin.x - focus.x) * amount * root.parallaxDepth.x
offset.y = (root.origin.y - focus.y) * amount * root.parallaxDepth.y
offset.z = 0
```

| 주소 | 관측 |
| --- | --- |
| `0x14018b047`–`0x14018b060` | `+0x180` parent를 nil까지 따라감 |
| `0x14018b062`/`0x14018b06b` | 최상위 root `+0x128/+0x12c` origin.xy |
| `0x14018b074`–`0x14018b094` | `scene+0x334` amount와 `root.origin-focus` |
| `0x14018b099`/`0x14018b0a2` | root `+0x170/+0x174` depth.xy |
| `0x14018b0ab`–`0x14018b149` | drawable의 임시 matrix에 XYZ translation 적용; Z 입력은 0 |

따라서 같은 최상위 root 아래 모든 descendant는 leaf 자신의 origin/depth가 아니라 **같은 root
offset**을 받는다. parent chain에는 cycle 방어가 보이지 않는다. 보존된 워크샵 측정에는
`duplicateObjectIds=0`, `danglingParentIds=0`, `selfParent=0`이지만 더 긴 cycle의 전수 검사는
측정 항목에 명시돼 있지 않다.

## 5. interaction/hit 경로: 현재 오브젝트 기준

[`FUN_140189e10`](../../../Waple-wallpaper-source/analysis/decompiled/all/0000000140189e10__FUN_140189e10.c)은
interaction 후보를 훑으면서 `solid` bit 13 (`0x2000`)을 먼저 검사하고, vtable type이
1(image) 또는 4(text)이면 현재 오브젝트를 `rdx`에 둔다
(`0x14018a02d`–`0x14018a053`). parallax+정사영일 때 계산하는 식은 드로우와 같은 모양이지만
주소의 기준이 다르다.

```text
offset.x = (current.origin.x - focus.x) * amount * current.parallaxDepth.x
offset.y = (current.origin.y - focus.y) * amount * current.parallaxDepth.y
offset.z = 0
```

근거는 `0x14018a0a9`–`0x14018a115`다. 이 범위 앞에는 `current+0x180` parent walk가 없다.
계산된 XYZ는 `0x14018a235`에서
[`FUN_14019dbb0`](../../../Waple-wallpaper-source/analysis/decompiled/all/000000014019dbb0__FUN_14019dbb0.c)에
넘어간다. 그 함수는 디컴파일 줄 115–119에서 이 벡터를 오브젝트 변환의 translation에 더한 뒤,
줄 120–149에서 quad/geometry 교차 결과를 계산한다.

확정 가능한 것은 “드로우는 root, 이 interaction geometry 호출은 current”라는 바이너리
비대칭이다. 아직 확정하지 못한 것은 다음 한 가지다.

- parent가 있고 solid인 image/text interaction 객체가 162씬 코퍼스에 실제 몇 개 있는지

후자를 확인하기 전까지는 이 비대칭을 dead branch로 단정해서도, 반대로 모든 hover/click에
영향한다고 과장해서도 안 된다.

## 6. `parallaxDepth`의 타입, 기본값, 범위

[`FUN_1401e0530`](../../../Waple-wallpaper-source/analysis/decompiled/all/00000001401e0530__FUN_1401e0530.c)은
origin/scale/angles와 같은 공통 레이어 디스크립터에서 `parallaxDepth`를 offset `+0x170`,
2성분 타입으로 등록한다(디컴파일 줄 163–207; 핵심 주소 `0x1401e082f`–`0x1401e0861`).

공통 레이어 생성자 [`FUN_1401ddbb0`](../../../Waple-wallpaper-source/analysis/decompiled/all/00000001401ddbb0__FUN_1401ddbb0.c)의
실제 명령은 다음과 같다.

```text
0x1401ddce1  mov dword ptr [r14+0x170], 0x3f800000
0x1401ddcec  mov dword ptr [r14+0x174], 0x3f800000
```

즉 미저작 기본값은 정확히 `(1.0, 1.0)`이다. 두 소비 경로 모두 multiply만 하고 clamp하지
않으므로 0과 음수가 의도대로 보존된다.

워크샵 162씬 측정도 이 속성이 예외가 아님을 보여 준다.

| 측정 | 값 |
| --- | ---: |
| image `parallaxDepth` 저작 | 1,573 objects / 121 scenes |
| text 저작 | 956 / 77 scenes |
| particle 저작 | 321 / 75 scenes |
| node 저작 | 191 / 40 scenes |
| 음수 depth | text 321, image 265, node 74, particle 74, shape 2 |
| 0 depth | image 920, text 515, particle 94, node 73, light 27, shape 7 |

출처는 `scene.objects.keysByType`과 `scene.anomalies`이며 모집단/생성법은 같은 spec 파일에
기록돼 있다.

## 7. 실물 도달 범위와 양성 대조

워크샵 요약의 모집단은 162씬이며 parse error는 0이다.

- `cameraparallax=true`: 56씬
- `orthogonalprojection` dict: 155씬
- 3D(camera+fov): 7씬

현재 spec은 두 집합의 교집합 ID를 보존하지 않는다. 따라서 오브젝트 이동 경로의 확정 도달은
포함배제 원리로 **최소 49씬**(`56 + 155 - 162`)이다. 유니폼 경로는 parallax가 켜진 56씬
전부에 진입한다. 49를 정확한 교집합 수로 인용하면 안 된다.

동봉 [`effects/depthparallax/preview/scene.json`](../../../Waple-wallpaper-source/wallpaper_engine/assets/effects/depthparallax/preview/scene.json)은
특히 좋은 양성 대조다.

- `cameraparallax=true`
- amount `0.5`, delay `0.1`, mouse influence `1.0`
- orthographic 600×600
- 유일한 image root의 `parallaxDepth=(0,0)`
- vertex shader는 `g_ParallaxPosition`을 직접 소비

따라서 이 실물은 오브젝트 translation은 0으로 고정하면서 **유니폼 출력만** 의도적으로
사용한다. `g_ParallaxPosition`을 포인터 UV와 alias하거나, depth가 0이라는 이유로 parallax 상태
갱신 자체를 생략하면 이 대조를 통과하지 못한다.

## 8. 구현 시 지켜야 할 관측 계약

조사 시점에 바이너리에서 바로 유도한 최소 계약은 다음과 같다. 같은 날 구현·회귀 테스트까지
착지했으며, 아래 목록은 이후 변경에서도 지켜야 할 규약으로 남긴다.

1. `g_PointerPosition`과 `g_ParallaxPosition`은 독립 슬롯이어야 한다.
2. focus는 scene-pixel 단위로 유지하고, 유니폼에서만 W/H로 나눈다.
3. `mouseInfluence=0`에서도 root translation 식을 실행한다.
4. 드로우 offset은 leaf가 아니라 최상위 root의 **현재** origin/depth로 계산한다.
5. 3D에서는 오브젝트 translation을 적용하지 않지만, parallax uniform 갱신을 같은 이유로
   없애면 안 된다.
6. depth 0, 음수, 1 초과와 delay 3 초과를 임의 clamp하지 않는다.
7. interaction은 바이너리 관측상 current-object 기준이다. draw와 하나의 root-offset helper로
   합치려면 먼저 solid image/text와 parent의 교집합을 실물 코퍼스에서 검증해야 한다.

### 8.1 구현 상태(2026-08-31)

- `SceneCameraMath`가 focus, delay alpha, root/current object offset, parallax 유니폼 좌표를 순수 산술로 보존한다.
- `SceneRenderer`는 `g_PointerPosition`과 `g_ParallaxPosition`을 별도 상태·유니폼 슬롯으로 유지한다.
- draw는 최상위 root, pointer/hover는 현재 leaf를 쓴다. draw 순서에서 이미 평가된 root와
  child보다 뒤에 선언된 일반 image root의 순수 origin keyframe은 **현재 프레임** 값을 읽고,
  pointer/hover는 표시 encode가 확정한 현재 leaf 변환을 읽는다.
- 남은 순서 한계: child보다 뒤에 있는 root의 origin JS·text root·attachment/puppet root를 현재
  프레임에 맞추려면 2D도 3D처럼 script update와 draw를 분리해야 한다. JS만 앞당기면 앞선
  오브젝트의 `shared` side effect 순서를 깨고 stateful update를 이중 평가하므로, 현재 구현은 그런
  root를 raw descriptor로 폴백한다. 보존된 실자산의 유일한 parallax scene에는 이 조합이 없다.
- 부모 체인·중복 ID(first-wins)·순환 방어, depth 0/음수, `mouseInfluence=0`, delay 경계와
  동봉 `depthparallax` 양성 대조를 Core/Render 테스트로 고정했다.
- 원근 object-space 변환과 표시 프레임 pointer geometry도 같은 프레임 상태를 공유하되,
  3D에는 정사영 전용 object translation을 적용하지 않는다.

## 재현 명령

```bash
shasum -a 256 \
  /Users/yakisoba0728/Documents/GitHub/Waple-wallpaper-source/wallpaper_engine/wallpaper64.exe

rg -n 'g_ParallaxPosition|cameraparallax|parallaxDepth' \
  /Users/yakisoba0728/Documents/GitHub/Waple-wallpaper-source/analysis/decompiled/all

python3 - <<'PY'
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_64

p = '/Users/yakisoba0728/Documents/GitHub/Waple-wallpaper-source/wallpaper_engine/wallpaper64.exe'
pe = pefile.PE(p)
base = pe.OPTIONAL_HEADER.ImageBase
md = Cs(CS_ARCH_X86, CS_MODE_64)
md.skipdata = True

for start, end in [
    (0x140189b42, 0x140189cf3),  # focus + uniform
    (0x14018a0a9, 0x14018a260),  # interaction offset + geometry call
    (0x14018b047, 0x14018b153),  # draw root walk + matrix translation
    (0x1401ddc60, 0x1401ddd40),  # common layer defaults
]:
    print(f'===== {start:#x}-{end:#x}')
    data = pe.get_data(start - base, end - start)
    for insn in md.disasm(data, start):
        print(f'{insn.address:#x}: {insn.mnemonic:8} {insn.op_str}')
PY
```
