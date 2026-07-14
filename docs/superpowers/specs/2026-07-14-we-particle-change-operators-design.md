# WE 파티클 Change Operator 충실도 교정 설계

## 배경

Waple의 `sizechange`, `colorchange`, `alphachange` 구현에는 세 종류의 불일치가 있다.

1. `sizechange`와 `colorchange`는 JSON의 `endtime`을 파싱하지 않고 항상 수명 끝까지 보간한다.
2. `alphachange`만 `starttime`과 `endtime`을 절대 초로 계산한다. 세 연산 모두 실제로는 파티클 수명에 대한 비율을 사용한다.
3. 시뮬레이터가 같은 타입의 첫 번째 연산만 보존해 이후 연산을 버린다.

Wallpaper Engine 공식 문서는 세 연산의 `starttime`과 `endtime`을 수명에 대한 비율로 정의한다.

- <https://docs.wallpaperengine.io/en/scene/particles/component/operator.html#size-change>

`wallpaper64.exe`의 파서와 실행부도 같은 동작을 확인한다.

- 세 연산 모두 `age / lifetime`을 시간 입력으로 사용한다.
- 시작·종료 비율 사이에서 선형 보간하고 계산된 진행도만 `[0, 1]`로 제한한다.
- 공통 기본값은 `starttime=0`, `endtime=1`, `startvalue=1`, `endvalue=0`이다.
- 파서가 연산을 JSON 순서대로 직렬화하고 실행부가 현재 size, RGB, alpha에 각 결과를 곱한다.

따라서 이 작업은 추정 기반 호환 정책이 아니라 공식 문서와 네이티브 실행부가 함께 뒷받침하는 결정적 충실도 교정이다.

## 목표

- 세 change operator가 같은 수명 비율 시간 모델을 사용한다.
- `sizechange`와 `colorchange`의 `endtime`을 보존한다.
- 같은 타입의 모든 연산을 JSON 순서대로 곱셈 합성한다.
- 세 연산의 누락 필드 기본값을 네이티브와 일치시킨다.
- `endtime > 1`을 저작된 값 그대로 유지해 사망 시점의 미완성 보간을 재현한다.
- 빠른 영향 테스트만으로 파서와 시뮬레이터 계약을 고정한다.

## 비목표

- change operator 이외의 first-wins 연산을 함께 고치지 않는다.
- 파티클 RNG, initializer, emitter, renderer 또는 셰이더를 변경하지 않는다.
- 잘못 저작된 비율을 `[0, 1]`로 정규화하거나 자동 수정하지 않는다.
- 전수 테스트, 렌더 코퍼스, GT 스냅샷 재생성을 실행하지 않는다.
- 기존 동작을 선택하는 호환 플래그를 추가하지 않는다.

## 검토한 접근

### A. 네이티브 동작 전체 이식 — 채택

세 연산의 시간 모델, 기본값, 다중 합성을 함께 교정한다. 공식 문서와 네이티브 실행부가 일치하며 이미 알려진 오류를 모두 제거한다.

### B. 비율만 교정하고 기존 기본값·first-wins 유지 — 기각

시간 단위 오류만 줄지만 누락 필드와 중복 연산의 결과는 계속 WE와 달라진다. 확정된 오류를 남기는 부분 수정이다.

### C. 기존 동작과 새 동작을 호환 플래그로 병존 — 기각

기존 동작이 별도 포맷이나 버전의 유효한 의미라는 근거가 없다. 설정과 테스트 분기만 늘어나는 과설계다.

## 데이터 모델과 파싱

`ParticleOperator.sizeChange`와 `.colorChange`에 기본값 `1`인 `endTime` 연관값을 끝에 추가한다. 기존 생성 호출의 소스 호환성을 가능한 한 보존하기 위해 기존 연관값의 순서는 바꾸지 않는다.

```swift
case sizeChange(
    startTime: Float,
    startValue: Float,
    endValue: Float,
    endTime: Float = 1
)
case colorChange(
    startTime: Float,
    startValue: Vec3,
    endValue: Vec3,
    endTime: Float = 1
)
```

`alphaChange`의 타입 형태는 유지한다. 세 파서 분기는 다음 공통 기본값을 적용한다.

| 필드 | 기본값 |
|---|---:|
| `starttime` | `0` |
| `endtime` | `1` |
| `startvalue` | `1` 또는 RGB `(1, 1, 1)` |
| `endvalue` | `0` 또는 RGB `(0, 0, 0)` |

파서가 이미 `operators` 배열 전체와 원래 순서를 보존하므로 JSON 모델이나 저장 형식의 추가 변경은 없다.

## 시뮬레이션

### 공통 시간 함수

살아 있는 파티클의 정규화 나이를 다음처럼 계산한다.

```text
n = age / lifetime
```

각 operator의 보간 진행도는 다음과 같다.

```text
if endTime == startTime:
    t = n >= startTime ? 1 : 0
else:
    t = clamp((n - startTime) / (endTime - startTime), 0, 1)
```

`startTime`과 `endTime` 자체는 제한하지 않는다. 따라서 `endTime=3`이면 `n=1`인 사망 시점에도 진행도는 1/3 지점에 머물 수 있다. `endTime == startTime`은 0으로 나누지 않고 시작 시점에서 즉시 끝값으로 전환한다.

`startTime > endTime`도 교환하거나 거부하지 않는다. 음의 분모를 그대로 사용하므로 `n <= endTime`에서는 끝값, `endTime...startTime`에서는 끝값→시작값 역방향 보간, `n >= startTime`에서는 시작값이 된다. 이는 네이티브의 signed reciprocal과 clamp 동작을 의미론적으로 재현한다.

### 다중 연산 합성

시뮬레이터의 단일 optional 캐시를 타입별 배열로 교체한다. 초기화 중 JSON 순서대로 모든 change operator를 배열에 추가한다. 표시값 계산에서는 각 factor를 현재 값에 순서대로 곱한다.

```text
size  = initialSize
for op in sizeChanges:
    size *= lerp(op.startValue, op.endValue, progress(op))

color = initialColor
for op in colorChanges:
    color.rgb *= lerp(op.startValue, op.endValue, progress(op))

alpha = initialAlpha
for op in alphaChanges:
    alpha *= lerp(op.startValue, op.endValue, progress(op))
```

RGB 보간과 곱셈은 성분별이다. 소스 순서를 유지해 네이티브 실행 순서와 부동소수점 연산 순서도 보존한다. 기존 `alphafade`, `oscillatealpha`, `oscillatesize` 등 다른 곱셈 계열 효과와의 결합 구조는 바꾸지 않는다.

## 오류 및 경계 처리

- 누락 필드는 네이티브 기본값으로 폴백한다.
- `endTime > 1`은 클램프하지 않아 사망 시 미완성 상태를 허용한다.
- `startTime < 0` 또는 `endTime < 0`도 저작값을 보존하고 계산된 `t`만 제한한다.
- 보간된 change factor에는 별도 클램프를 추가하지 않는다. 기존 표시 파이프라인의 최종 alpha `[0, 1]` 제한은 다른 alpha 효과와 공유하는 범위 밖 계약이므로 유지한다.
- `endTime == startTime`은 시작 시점의 step 전환으로 처리한다.
- `startTime > endTime`은 signed span을 유지해 끝값→시작값으로 역보간한다.
- 기존 숫자 파서의 비유한 값 처리 규약을 유지한다.
- change operator가 없으면 현재 출력과 RNG 소비에 변화가 없다.

## 테스트 설계

전체 테스트와 렌더 코퍼스 대신 다음 세 테스트 클래스만 실행한다.

```bash
swift test --filter ParticleSystemTests
swift test --filter ParticleSimulatorTests
swift test --filter ParticleStageATests
```

테스트는 다음 계약을 고정한다.

1. `sizechange`와 `colorchange`의 명시적 `endtime` 파싱.
2. 세 연산의 공통 누락 필드 기본값 `0/1/1/0`.
3. 수명이 다른 fixture에서도 같은 정규화 나이에 같은 보간 결과가 나오는지 확인.
4. `endtime > 1`일 때 사망 직전에도 끝값에 도달하지 않는지 확인.
5. `endtime == starttime`의 step 처리와 `starttime > endtime`의 역보간.
6. 같은 타입 size/color/alpha 연산 두 개가 첫 번째 또는 마지막 값으로 덮이지 않고 곱셈 합성되는지 확인.
7. 기존의 절대 초를 고정한 alphaChange 테스트와 주석을 수명 비율 오라클로 교체.

## 문서 정정

이전 F4 보고서의 “절대 초” 판정은 비율값과 수명(초)을 같은 단위로 비교한 오류다. 구현과 함께 다음 기록을 정정한다.

- `analysis/WE-2.8-FINAL-KR.md`의 M4
- `analysis/build/WE-2.8-fidelity-KR.md`의 X5
- `analysis/WE-2.8-TRADEOFFS-KR.md`의 파티클 결정
- `analysis/build/F4-particle-sim-exact.md`의 정정 주석과 관련 결론
- 위 원본을 합친 `analysis/WE-2.8-COMPLETE-KR.md`의 대응 구간

정정 문구는 “세 operator 모두 수명 비율, alphaChange 절대 초 계산은 Waple 버그, 누락 `endtime`은 1, 1 초과는 수명 내 미완성, 다중 연산은 순서대로 곱셈”을 공통 기준으로 삼는다.

## 변경 경계

예상 코드와 테스트 변경은 다음으로 제한한다.

- `Sources/WapleCore/ParticleSystem.swift`
- `Sources/WapleCore/ParticleSimulator.swift`
- `Tests/WapleCoreTests/ParticleSystemTests.swift`
- `Tests/WapleCoreTests/ParticleSimulatorTests.swift`
- `Tests/WapleCoreTests/ParticleStageATests.swift`
- 위 문서 정정 대상

사용자 소유 변경인 `.vscode/launch.json`은 건드리거나 커밋하지 않는다.

## 성공 기준

- 세 change operator가 공식 문서와 네이티브 실행부의 동일한 비율 수식을 사용한다.
- 네이티브 기본값과 같은 타입 다중 곱셈이 테스트로 고정된다.
- `endtime > 1`, 0-길이 구간, 역방향 구간이 결정적으로 처리된다.
- 지정한 세 테스트 클래스만 통과한다.
- 문서의 기존 절대 초 판정이 정정되고 합본에도 동기화된다.
