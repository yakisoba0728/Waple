# 파티클 이미터 `controlpoint` 바이너리 패리티 — 2026-08-31

## 결론

**구현 완료(2026-08-31).** 이 문서가 고른 독립 슬라이스
**`sphererandom`/`boxrandom` 이미터의 `emitter[].controlpoint` 파스와 spawn 프레임 적용**은
TDD로 착지했다.

원본 Wallpaper Engine은 이미터가 지정한 CP의 **현재(active) 4×4**를 읽어, 이미터가 만든
로컬 변위를 그 기저로 회전한 뒤 CP 평행이동과 이미터 `origin`을 더한다. 초기속도 방향도 같은
기저를 타지만 평행이동은 타지 않는다. 패치 전 Waple은 키를 파스하지 않고 CP 위치·회전을
spawn에서 전혀 읽지 않아, 보존 자산 `Dripping water`의 두 방출구가 CP1/CP2의 `±22 px`와
`∓30°`를 잃고 같은 로컬 원점에 겹쳤다. 현재는 `ParticleSystemDef.emitterControlPoints`와
`ParticleSimulator.spawn`이 이 정적 active frame을 소비한다.

이 슬라이스는 `mapsequencearoundcontrolpoint`(opid 13), camera/parallax, pointer와 독립이다.
opid 13과 CP 회전 산술은 별도 레인에서 먼저 착지했고, 이 라운드는 그 프레임의 **spawn 소비자**만
추가했다. 동적 object-world/parent/pointer 합성은 여전히 후속이다.

착지한 표면은 다음과 같다.

- `ParticleSystemDef.emitterControlPoints`: 이미터 병렬 공개 보존 배열, CP0 기본과 unsigned 7-clamp.
- `ParticleSimulator.spawn`: sphere/box 위치와 초기속도 방향에 row-vector 3×3을 적용하고,
  CP row3·emitter origin은 위치에만 후가산한다. CP0 local-space의 basis 예외도 보존한다.
- `ParticleEmitterControlPointTests`: 공개 `parse → step` RED, sphere/box·CP0·authored-angle inert·
  6선언/4파일 코퍼스·부모부착 live frame까지 8건.
- 같은 프레임 경계에서 드러난 typed override의 `x == FLT_MAX` 미지정 결함도
  `ParticleControlPointMath.isUnspecified`로 닫고 3건의 독립 테스트를 붙였다. NaN은 지정값이다.

조사 스냅샷은 Waple `70a8a708b459` 위 2026-08-31 작업 트리와 sibling
`Waple-wallpaper-source` `1fac2a0cc043`이다. 1차 자료는 다음 PE다.

- [`wallpaper64.exe`](../../../Waple-wallpaper-source/wallpaper_engine/wallpaper64.exe)
  - PE32+ x86-64, 5,360,112 bytes, image base `0x140000000`
  - SHA-256 `40e2ce021e9352324fadb3b8f72b8ba2a7ee95b71cc571d5b9f84be75cd993b0`
- 이미터 팩토리/파서:
  [`FUN_1401c5490.c`](../../../Waple-wallpaper-source/analysis/decompiled/all/00000001401c5490__FUN_1401c5490.c)
- 구 기본값 주입기:
  [`FUN_1401b9100.c`](../../../Waple-wallpaper-source/analysis/decompiled/all/00000001401b9100__FUN_1401b9100.c)
- 박스 기본값 주입기:
  [`FUN_1401b9520.c`](../../../Waple-wallpaper-source/analysis/decompiled/all/00000001401b9520__FUN_1401b9520.c)
- spawn 런타임:
  [`FUN_1402378a0.c`](../../../Waple-wallpaper-source/analysis/decompiled/all/00000001402378a0__FUN_1402378a0.c)
- 씬 CP override:
  [`FUN_14022bd40.c`](../../../Waple-wallpaper-source/analysis/decompiled/all/000000014022bd40__FUN_14022bd40.c)

판정은 **[확정]**이다. 단, 파서 레코드와 런타임 레코드 사이 `+0x10` 차이를 “헤더”라고
부르는 것만 **[추정]**이다. 양쪽의 필드 오프셋과 소비 산식은 직접 관측했지만 그 복사 함수는
아직 짚지 않았다.

## 1. 파서 계약

### 1.1 부재 기본은 두 이미터 모두 `0`

`sphererandom` 주입기 `FUN_1401b9100`의 꼬리:

```text
0x1401b9499  xor  r8d, r8d                       ; default = 0
0x1401b949c  lea  rdx, [0x14048f540]             ; "controlpoint"
0x1401b94a6  call 0x1401d7be0                   ; integer default injector
```

`boxrandom` 주입기 `FUN_1401b9520`의 꼬리도 같다.

```text
0x1401b98b1  xor  r8d, r8d                       ; default = 0
0x1401b98b4  lea  rdx, [0x14048f540]             ; "controlpoint"
0x1401b98be  call 0x1401d7be0
```

따라서 키 부재는 “CP 없음”이 아니라 **CP0**이다. 원본의 `Json::Value::asUInt`
`0x140085f70`도 null이면 0을 돌려주지만, 정상 경로에서는 그 전에 주입기가 정수 노드 0을 만든다.

### 1.2 `asUInt` 뒤 unsigned `min(raw, 7)`

구 파서:

```text
0x1401c5fb9  lea   rdx, "controlpoint"
0x1401c5ff7  call  0x140085f70                   ; Json::Value::asUInt
0x1401c5ffc  mov   ecx, 7
0x1401c6008  cmp   eax, ecx
0x1401c600a  cmovb ecx, eax                      ; eax <u 7 일 때만 raw 채택
0x1401c600d  mov   [rsi+0xe0], ecx
```

박스 파서:

```text
0x1401c6889  lea   rdx, "controlpoint"
0x1401c6903  call  0x140085f70
0x1401c6908  mov   ecx, 7
0x1401c6910  cmp   eax, ecx
0x1401c6912  cmovb ecx, eax
0x1401c6915  mov   [rsi+0x98], ecx
```

`asUInt` 자체도 확인했다. null은 0, int/uint는 하위 32비트를 그대로 돌려준다
(`0x140085f7b`–`0x140085fb9`). 따라서 숫자 입력의 닫힌 매핑은 다음과 같다.

| JSON 값 | 저장 CP |
| ---: | ---: |
| 부재 | `0` |
| `0 ... 6` | 원값 |
| `7` | `7` |
| `8` 이상 | `7` |
| 음수 | `7` |

마지막 행은 signed clamp가 아니다. 예를 들어 정수 `-1`은 하위 32비트
`0xffffffff`가 되어 unsigned 비교에서 7보다 크므로 7이 남는다. 문자열/배열/객체는 원본
`asUInt`의 “Value is not convertible to UInt” assert 경로이며, 이 문서의 호환 입력 범위에는
정상 숫자만 포함한다.

### 1.3 구/박스별 관측 오프셋

| 이미터 | 파서가 쓰는 `rsi` 기준 | 런타임 arm/tag | 런타임이 읽는 `r15` 기준 | 관측 차이 |
| --- | ---: | --- | ---: | ---: |
| `sphererandom` | `+0xe0` (`0x1401c600d`) | `al == 1` (`0x140237c18`) | `+0xf0` (`0x140237c27`) | `+0x10` |
| `boxrandom` | `+0x98` (`0x1401c6915`) | `al == 2` (`0x14023847f`) | `+0xa8` (`0x14023848e`) | `+0x10` |

각 오프셋은 직접 관측값이다. 두 타입 모두 정확히 `+0x10` 이동하므로 런타임 레코드 앞에
16-byte 헤더가 붙는 모양이지만, **복사 지점을 못 찾았으므로 헤더 해석은 추정**으로 남긴다.
구 arm은 `directions`/`sign`/반경 벡터를, 박스 arm은 두 코너와 박스 전용 속도 필드를 함께
읽으므로 tag 귀속은 문자열 인접만으로 한 추정이 아니다.

## 2. 런타임 CP 레코드와 적용식

두 arm은 시스템 `[sys+0x400]`에서 CP 배열을 얻고 `cp * 0xd0`으로 슬롯을 고른다.

| CP record offset | 내용 | 구 로드 | 박스 로드 |
| ---: | --- | --- | --- |
| `+0x00` | active row 0 | `0x140237c4e`–`0x140237c86` | `0x1402384d8`/`0x1402384f6`/`0x140238502` |
| `+0x10` | active row 1 | `0x140237c42` | `0x1402384c8` |
| `+0x20` | active row 2 | `0x140237c48` | `0x1402384cd` |
| `+0x30` | active row 3, 평행이동 | `0x140237c54` | `0x1402384c2`/`0x1402384d2`/`0x1402384ea` |

이것은 base 행렬 `+0x80 ... +0xb0`이 아니라 매 프레임 합성된 **active 행렬**이다. 현재 Waple의
[`CPMatrix4`](../../Sources/WapleCore/ParticleControlPointFrame.swift)는 같은 row-major,
row-vector 규약을 이미 공개한다. 씬 `instanceoverride.controlpointangleN`이 만드는 회전도
`ParticleControlPointMath.rotation`에 원본 식으로 보존돼 있다.

### 2.1 공통 affine 식

`M`의 행을 `r0 ... r3`, 이미터가 기존 분포 산식으로 만든 로컬 변위를 `d`, JSON 이미터의
`origin`을 `o`라 하자. 3-vector payload의 패딩 lane은 0이므로 원본의 4-row SSE 식은 다음
affine 식으로 닫힌다.

```text
R(d) = d.x * r0.xyz + d.y * r1.xyz + d.z * r2.xyz
gate = (system.flags & 1) != 0 || controlpoint != 0
q    = gate ? R(d) : d

position = q + r3.xyz + o
```

구 arm은 벡터화된 원형을 그대로 보여 준다. `0x140237f29`–`0x140237f63`이
`d.x*r0 + d.y*r1 + d.z*r2 + d.w*r3`을 만들고, `d.w == 0`인 뒤
`0x140237f68`–`0x140237fad`이 `r3 + origin`을 더해 SoA 위치
`[sys+0x2b0/0x2b8/0x2c0]`에 저장한다. 박스 arm은 같은 식을 scalar로 펼친다:
`0x14023890d`–`0x140238963`이 3×3, `0x140238967`–`0x140238997`이
`r3 + origin`의 덧셈과 저장이다.

중요한 비대칭은 두 가지다.

1. **`origin`은 회전하지 않는다.** 먼저 `R(d)`를 만든 뒤 `r3 + origin`을 더한다.
2. **평행이동은 gate 밖이다.** CP0이고 local-space 시스템이라 3×3을 건너뛰어도 `r3`은
   여전히 위치에 더한다. `gate`를 전체 CP 적용 여부로 사용하면 틀린다.

두 arm의 gate도 독립적으로 같은 명령을 가진다.

```text
; sphere
0x140237cc6  and eax, 1                        ; system.flags bit0
0x140237cce  or  eax, edx                      ; edx = CP id
0x140237ce3  setne r12b

; box
0x140238507  movzx eax, byte [rsi+0x20]
0x140238510  and   eax, 1
0x14023851f  or    eax, edx
0x14023852d  setne [gate]
```

### 2.2 초기속도 방향

위치 변위가 비퇴화이면 두 arm 모두 `q`를 정규화해 기존 speed stage에 넘긴다. 위치가 거의 0이면
별도 로컬 fallback 방향을 샘플하고, gate가 켜졌다면 그 방향에도 같은 3×3을 적용한 뒤 정규화한다.

- 구: fallback 기저 적용 `0x14023809b`–`0x1402380d2`, 정규화/속도/저장
  `0x1402380d5`–`0x14023817f`
- 박스: 위치에서 `r3+origin`을 빼 방향을 회수 `0x14023899d`–`0x1402389c8`, fallback 기저 적용
  `0x140238a9c`–`0x140238af4`, 정규화/속도/저장 `0x140238afd`–`0x140238bd4`

따라서 CP 평행이동과 이미터 `origin`은 속도에 들어가지 않는다. 구현 경계에서는 기존
speed sampling을 바꾸지 않고 **그 직전 방향만 CP 3×3으로 변환**해야 한다. `boxrandom`의
fallback/속도 방향은 Waple에 이미 별도 근사가 있으므로, 이 슬라이스가 박스 초기속도 전체를
원본과 같다고 과장해서는 안 된다. 다만 CP 기저 적용 위치는 위 VA로 확정됐다.

## 3. 패치 전 차이와 현재 착지

| 단계 | 패치 전 | 현재 착지 |
| --- | --- | --- |
| 표현 | `.sphere`/`.box`에 CP id도 병렬 배열도 없음 | enum ABI를 넓히지 않고 공개 `emitterControlPoints` 병렬 배열 추가 |
| 파스 | 두 case가 `controlpoint`를 읽지 않음 | 두 case 모두 CP0 기본 + `ParticleControlPointLimits.clampIndex`; layerimage 폴백은 CP0 정렬만 유지 |
| spawn | `origin + local`, 마지막에 Waple 자식 `emitOrigin`만 더함 | active CP translation/rotation을 sphere/box 위치·속도에 적용, `emitOrigin`은 종전처럼 마지막 |
| 테스트 seam | CP 산술 타입만 존재 | 기존 공개 `ParticleSystemDef.parse → ParticleSimulator.step` 경로가 독립 기대값을 직접 관측; 내부 중복은 private frame/basis helper 둘로 제한 |

### 3.1 기존 장부와의 대조

- [`docs/re/particle-control-points.md`](particle-control-points.md) §4.3은 두 parser/runtime
  offset과 CP 4×4 로드를 이미 찾았고, §11/§12는 `+0x10` 복사 지점을 미해결로 남긴다. 다만
  구/박스의 닫힌 spawn 식, 공개 RED, dripping-water의 파일별 도달을 한 구현 단위로 묶지는 않았다.
  이 문서는 그 다음 행동을 고르는 보충 정본이다.
- [`BACKLOG.md`](../../BACKLOG.md) D6는 파스·`controlPointFrameAngles`·opid 13·emitter spawn과
  `{animation:…}`의 per-step live frame 평가까지 닫혔다. 최초 sim과 2D/3D 캡처 재생성도 같은
  트랙을 전달한다. `controlpointN` 위치도 live 배열과 binding target 이동분 합성으로 닫혔다.
- [`next-engine-parity-2026-08-31.md`](next-engine-parity-2026-08-31.md)는 당시 camera/parallax를
  1순위, around를 2순위, CP angle 소비를 3순위로 뒀다. camera와 around가 별도 레인에서 착지한
  현재에는, 실제 CP1/2를 명시하는 emitter 6선언이 서로 충돌하지 않는 다음 consumer다.

실제로 사용한 구현 경계는 다음과 같다.

1. 이미터와 1:1인 공개 보존 배열(예: `emitterControlPoints`)에
   `ParticleControlPointLimits.clampIndex(pint(...) ?? 0)`을 넣는다. 기존
   `emitterSpeed`/`boxDistanceMin`과 같은 병렬 관례면 enum pattern 전수 변경을 피할 수 있다.
2. 새 공개 helper API는 만들지 않았다. 이미 존재하는 공개 `parse → step` 경로에 고정 sphere와
   퇴화 box 입력을 넣어 4×4 순서·translation 누출을 직접 잠그고, production 중복은 private
   `emitterControlPointFrame`/`applyEmitterBasis`로만 모았다.
3. `spawn`은 `runtimeControlPoints[cp]`와 `runtimeControlPointFrameAngles[cp]`를 읽어
   현재 live 프레임을 만든다. 정적·키프레임 instance override와 자식 피드의
   동적 평행이동·회전이 모두 이 런타임 배열을 통해 emitter에 도달한다.
4. **`def.controlPointAngles`를 사용하지 않는다.** 파티클 `.json`의
   `controlpoint[].angles`는 파스되지만 원본 CP 생성자 `FUN_14022c3c0`가 읽지 않아 base 회전은
   항등이다. 살아 있는 회전은 씬 `instanceoverride.controlpointangleN`에서 분리한
   `controlPointFrameAngles`뿐이다.
5. Waple 전용 자식 인스턴스 `emitOrigin`은 기존처럼 마지막에 유지한다. 이것을 원본 이미터
   `origin`과 합쳐 회전시키면 안 된다.

동적 object-world/parent/pointer 합성까지 완전한 active 4×4로 올리는 일은 후속 범위다. 아래
실자산은 정적 instance override의 translation/rotation만 쓰므로 이 슬라이스에서 재현 가능하다.

## 4. 보존 자산 도달

Sibling의 설치 `assets/` 전체 JSON을 읽어 `emitter[]` 직속 `controlpoint`를 센 결과:

- **6 선언 / 4 물리 파일 / 2 고유 파일 바이트**
- CP1 4건, CP2 2건
- 전부 `sphererandom`; `boxrandom` 저작은 0건

| 파일 | emitter index | 값 |
| --- | ---: | ---: |
| [`presets/water/particles/presets/dripping_water.json`](../../../Waple-wallpaper-source/wallpaper_engine/assets/presets/water/particles/presets/dripping_water.json) | 0, 1 | CP1, CP2 |
| [`presets/water/particles/presets/dripping_water_droplets.json`](../../../Waple-wallpaper-source/wallpaper_engine/assets/presets/water/particles/presets/dripping_water_droplets.json) | 1 | CP1 |
| [`previewdrippingwater/.../dripping_water.json`](../../../Waple-wallpaper-source/wallpaper_engine/assets/presets/water/previewdrippingwater/particles/presets/dripping_water.json) | 0, 1 | CP1, CP2 |
| [`previewdrippingwater/.../dripping_water_droplets.json`](../../../Waple-wallpaper-source/wallpaper_engine/assets/presets/water/previewdrippingwater/particles/presets/dripping_water_droplets.json) | 1 | CP1 |

두 번째 둘은 preview mirror라 내용 중복이다. 그러나 실제 도달은 preview scene 하나로 바로 닫힌다.
[`previewdrippingwater/scene.json`](../../../Waple-wallpaper-source/wallpaper_engine/assets/presets/water/previewdrippingwater/scene.json)의
`Dripping water` 오브젝트는 다음 override를 싣고 위 particle을 참조한다.

```json
{
  "controlpoint1": "22.00000 0.00000 0.00000",
  "controlpoint2": "-22.00000 0.00000 0.00000",
  "controlpointangle1": "0.00000 0.00000 -0.52360",
  "controlpointangle2": "0.00000 0.00000 0.52360"
}
```

파티클 본문은 `flags: 1`이고, CP1/2 descriptor의 `flags` 값은 decimal `16`이다. 이것은
**bit4 (`0x10`)이지 bit16 (`0x10000`)이 아니므로** scene override 차단 마스크 `0x10005`에
걸리지 않는다. 즉 두 translation과 두 rotation은 실제 active frame에 도달한다.

패치 전 Waple 결과는 두 구 이미터가 모두 로컬 원점 주변에서 방출됐다. 현재는 원본처럼 CP1 중심
`(+22, 0)`에서 −30°, CP2 중심 `(-22, 0)`에서 +30°인 정적 override 프레임에 로컬 변위와
초기속도 방향이 도달한다. 아래 코퍼스 테스트가 네 물리 파일의 파서 도달을 별도로 고정한다.

`boxrandom`은 보존 자산 양성 대조가 0건이므로 합성 테스트만 추가한다. 바이너리 arm과 오프셋은
확정됐지만, 자산 도달을 구와 같은 수로 보고하면 안 된다.

## 5. 공개 RED/GREEN과 독립 기대값

정식 XCTest의 최초 RED는 다음과 같았다.

- sphere: `P=(2,0,0), V=(4,0,0)`로 독립 기대값과 **4개 단언 실패**.
- box: CP를 건너뛴 `P=(5,4,0)`와 무회전 속도로 **4개 단언 실패**.
- typed override sentinel: 위치/각도 `FLT_MAX`가 그대로 복사돼 **3개 단언 실패**;
  같은 실행의 NaN 양성 대조는 통과.

구현 뒤 관련 11개 테스트는 모두 GREEN이다(이미터 8 + sentinel 3).

### 5.1 패치 전 코드에서 바로 실패했던 최소 통합 입력

이 테스트는 새 필드에 접근하지 않는다. 패치 전 공개 API
`ParticleSystemDef.parse` → `ParticleSimulator.step`만 사용하므로 **패치 전에도 컴파일되고,
당시 결과값에서 실패**했다.

```swift
func testSphereEmitterUsesLiveControlPointFrame() {
    let emitter: [String: Any] = [
        "name": "sphererandom",
        "controlpoint": 1,
        "origin": "0 0 0",
        "directions": "1 0 0",
        "sign": "1 0 0",
        "distancemin": 2,
        "distancemax": 2,
        "speedmin": 4,
        "speedmax": 4,
        "rate": 0,
        "instantaneous": 1
    ]
    let lifetime: [String: Any] = ["name": "lifetimerandom", "min": 100, "max": 100]
    let renderer: [String: Any] = ["name": "sprite"]
    let source: [String: Any] = [
        "flags": 1,
        "emitter": [emitter],
        "initializer": [lifetime],
        "renderer": [renderer],
        "maxcount": 1
    ]
    var override = ParticleInstanceOverride()
    override.controlPoints[1] = Vec3(x: 22, y: 0, z: 0)
    override.controlPointAngles[1] = Vec3(x: 0, y: 0, z: -Float.pi / 6)

    let def = ParticleSystemDef.parse(source, material: nil, instanceOverride: override)
    var sim = ParticleSimulator(def: def, seed: 1)
    let p = sim.step(0)[0]

    XCTAssertEqual(p.pos.x, 23.7320508, accuracy: 1e-5)
    XCTAssertEqual(p.pos.y, -1, accuracy: 1e-5)
    XCTAssertEqual(p.pos.z, 0, accuracy: 1e-5)
    XCTAssertEqual(p.vel.x, 3.4641016, accuracy: 1e-5)
    XCTAssertEqual(p.vel.y, -2, accuracy: 1e-5)
    XCTAssertEqual(p.vel.z, 0, accuracy: 1e-5)
}
```

기대값은 production helper를 호출해 다시 계산하지 않는다. z축 `-π/6`의 row0은
`(√3/2, -1/2, 0)`이므로 독립적으로:

```text
P = (22, 0, 0) + 2 * (√3/2, -1/2, 0)
  = (23.7320508, -1, 0)

V = 4 * (√3/2, -1/2, 0)
  = (3.4641016, -2, 0)
```

패치 전 코드는 CP key와 override를 spawn에서 읽지 않아 각각 `P=(2,0,0)`, `V=(4,0,0)`을 냈다.
2026-08-31 패치 전 `WapleCore.o`에 위 공개 입력을 그대로 링크해 실행한 실측 출력도
`2.0 0.0 0.0 4.0 -0.0 0.0`이었다(부호 0은 수치상 0).
따라서 테스트가 빨간 이유가 난수나 floating-point 오차가 아니라 누락된 데이터 흐름 하나로
격리된다. `directions="1 0 0"`과 `sign="1 0 0"`, 고정 반경/속도가 임의 seed에서도 로컬 +X를
강제한다.

### 5.2 파서와 순수 seam 오라클

구현 테스트는 다음을 별도로 잠근다.

1. 공개 보존 배열에 입력 `[부재, 6, 7, 8, -1]`이 `[0, 6, 7, 7, 7]`로 남는다.
   구/박스 각각 하나씩 넣어 병렬 배열 정렬도 확인한다.
2. 순수 frame seam에서 translation은 position에만 들어가고 direction에는 들어가지 않는다.
3. emitter `origin=(3,4,0)`은 회전 뒤 더해진다. 위 입력이면
   `P=(26.7320508,3,0)`이지 origin까지 회전한 값이 아니다.
4. CP0 + local-space는 basis를 건너뛰되 row3 translation은 더한다.
5. 파티클 `.json` `controlpoint[].angles`만 지정한 경우는 identity, 같은 값을 scene
   `instanceoverride.controlpointangleN`으로 지정한 경우만 회전한다.

### 5.3 `boxrandom` 합성 RED

보존 자산 도달은 없지만 바이너리의 tag 2 arm을 회귀시키려면 로컬 박스를 점으로 퇴화시킨다.

```json
{
  "flags": 0,
  "emitter": [{
    "name": "boxrandom",
    "controlpoint": 1,
    "distancemin": "2 0 0",
    "distancemax": "2 0 0",
    "speedmin": 0,
    "speedmax": 0,
    "rate": 0,
    "instantaneous": 1
  }],
  "renderer": [{"name": "sprite"}],
  "maxcount": 1
}
```

CP1 translation `(10,20,0)`, angle `+π/2`일 때 독립 기대 위치는 `(10,22,0)`이다.
패치 전 Waple은 `(2,0,0)`을 냈다. 시스템 flags가 0이어도 `cp=1`이므로 basis gate가 켜진다는
조건도 함께 잠긴다. speed를 0으로 둬 기존 box velocity 근사와 이 CP 위치 슬라이스를 분리한다.

## 6. 재현 명령

```bash
SRC=/Users/yakisoba0728/Documents/GitHub/Waple-wallpaper-source
shasum -a 256 "$SRC/wallpaper_engine/wallpaper64.exe"
file "$SRC/wallpaper_engine/wallpaper64.exe"

# 기본값 주입기
WE_ROOT="$SRC/wallpaper_engine" python3 scripts/re/disasm.py 0x1401b9420 288
WE_ROOT="$SRC/wallpaper_engine" python3 scripts/re/disasm.py 0x1401b9810 220

# 파서 offset/clamp
WE_ROOT="$SRC/wallpaper_engine" python3 scripts/re/disasm.py 0x1401c5f85 170
WE_ROOT="$SRC/wallpaper_engine" python3 scripts/re/disasm.py 0x1401c6880 180

# 런타임 sphere/box frame
WE_ROOT="$SRC/wallpaper_engine" python3 scripts/re/disasm.py 0x140237c18 480
WE_ROOT="$SRC/wallpaper_engine" python3 scripts/re/disasm.py 0x140237ef0 850
WE_ROOT="$SRC/wallpaper_engine" python3 scripts/re/disasm.py 0x14023847f 430
WE_ROOT="$SRC/wallpaper_engine" python3 scripts/re/disasm.py 0x140238900 1000

# Waple 구현 표면
rg -n 'case sphere|case box|case "sphererandom"|case "boxrandom"|func spawn' \
  Sources/WapleCore/ParticleSystem.swift Sources/WapleCore/ParticleSimulator.swift
```

자산 전수 카운트는 JSON을 파싱해 `emitter[]` 직속 키만 센다. 문자열 grep은 주석이나 다른
`controlpoint` 소유자를 섞으므로 근거로 쓰지 않는다.

```bash
python3 - <<'PY'
import hashlib, json
from pathlib import Path
root = Path('/Users/yakisoba0728/Documents/GitHub/Waple-wallpaper-source/wallpaper_engine/assets')
hits = []
for path in root.rglob('*.json'):
    try:
        doc = json.loads(path.read_text())
    except Exception:
        continue
    if not isinstance(doc, dict):
        continue
    for index, emitter in enumerate(doc.get('emitter', []) or []):
        if isinstance(emitter, dict) and 'controlpoint' in emitter:
            hits.append((path.relative_to(root), index, emitter.get('name'),
                         emitter['controlpoint'], hashlib.sha256(path.read_bytes()).hexdigest()))
print('declarations', len(hits),
      'physical_files', len({str(x[0]) for x in hits}),
      'unique_file_bytes', len({x[4] for x in hits}))
for row in hits:
    print(*row[:4], sep='\t')
PY
```

기대 출력은 `declarations 6 physical_files 4 unique_file_bytes 2`이고, 여섯 행의 name은 전부
`sphererandom`, CP 분포는 `1` 네 건과 `2` 두 건이다.

## 7. 완료 판정과 남은 경계

이 슬라이스의 완료 조건 네 가지는 모두 충족됐다.

1. 구/박스의 부재 기본과 unsigned 7-clamp가 공개 상태에 보존된다.
2. 공개 parse→step seam이 row-vector 순서, origin 후가산, translation 비속도 규약을 잠근다.
3. 공개 parse→sim 통합 RED가 위 독립 수치를 낸다.
4. preview dripping-water의 CP1/CP2가 서로 다른 translation/rotation에 도달하고,
   동봉 네 파일의 `[1,2]/[0,1]` 파서 배열이 고정된다.

후속으로 남는 것은 active CP의 **동적** object-world/parent/pointer 행렬 합성과 box 방향 근사의
원본화다. 이것들은 이 문서의 static instanceoverride 양성 대조를 막지 않으며, 이번 슬라이스에
섞으면 검증 가능한 한 행동의 범위를 넘어간다. 파서↔런타임 레코드의 `+0x10` 복사 지점도 장부상
미해결이지만, 양쪽 필드와 소비 결과가 독립적으로 닫혀 있어 구현을 막는 불확실성은 아니다.
