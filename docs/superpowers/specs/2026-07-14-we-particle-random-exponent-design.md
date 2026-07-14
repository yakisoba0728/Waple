# WE 파티클 Random Initializer Exponent 설계

## 배경

Wallpaper Engine 파티클의 random initializer 7종은 선택적인 `exponent` 필드로 균등 난수의 분포를 성형한다. Waple은 `alphaRandom`에서만 이 필드를 파싱하고 `pow(raw, exponent)`를 적용하며, 다음 6종에서는 필드를 버리고 균등분포로 처리한다.

- `lifetimeRandom`
- `sizeRandom`
- `colorRandom`
- `velocityRandom`
- `rotationRandom`
- `angularVelocityRandom`

WE 분석 근거상 JSON 필드 이름과 7종 공통 스키마, 실제 코퍼스 사용은 확인됐다. 다만 네이티브 RNG 구현, 시드, 소비 순서와 벡터 3성분이 난수를 공유하는지는 확인되지 않았다. 따라서 이번 작업은 Waple의 기존 RNG 구조를 유지하면서 빠진 분포 성형만 추가한다.

## 목표

- 위 6개 initializer가 JSON의 숫자형 `exponent`를 보존한다.
- `exponent`를 최종값이 아니라 균등 난수 보간계수 `t`에 적용한다.
- 기존 `alphaRandom`과 같은 곡선 및 비정상 exponent 처리 규약을 공용화한다.
- exponent가 없을 때 기존 출력과 RNG 소비 순서를 유지한다.
- color 그라디언트와 velocity/rotation 스프레드라는 현재 Waple의 시각적 특성을 보존한다.
- 파서부터 시뮬레이터 결과까지 결정적 unit test로 검증한다.

## 비목표

- WE의 RNG 알고리즘, 시드, 비트정확 소비 순서를 추측하거나 교체하지 않는다.
- `turbulentVelocityRandom`에 일반 `exponent`를 추가하지 않는다. 이 initializer의 스키마는 별도다.
- vector initializer를 모두 공유 난수 또는 모두 축별 난수로 통일하지 않는다.
- `sizeChange`/`colorChange.endtime`, 동일 타입 operator 다중 적용, operator 배열 순서는 변경하지 않는다.
- 렌더 셰이더, 파티클 렌더러, GT 스냅샷이나 전수 코퍼스를 변경하지 않는다.

## 검토한 접근

### A. 기존 난수 구조 보존 + 공용 exponent 헬퍼 — 채택

6개 enum case에 기본값 `1`인 exponent를 추가하고, 파서가 값을 전달한다. 시뮬레이터는 기존 난수 draw마다 `pow(raw, exponent)`를 적용한다.

장점은 root-cause만 수정하고 기존 시각 특성, draw 횟수, 고정 시드 테스트를 보존한다는 점이다. WE에서 미확정인 vector 난수 공유 정책을 새로 추측하지 않는다.

### B. 모든 vector initializer에 공유 난수 1개 — 기각

색상은 min→max 그라디언트에 적합하지만 velocity와 rotation도 한 직선 위 값만 만들게 된다. 파티클 방향·회전 스프레드를 축소하고 기존 결과를 불필요하게 바꾼다.

### C. 모든 vector initializer에 축별 난수 또는 정책 플래그 — 기각

color가 RGB 박스 전체에 흩어져 기존 그라디언트 판정과 어긋난다. initializer별 플래그는 WE에 해당 스키마 근거가 없고 현재 결함 수정에 필요하지 않은 과설계다.

## 설계

### 데이터 모델과 파싱

`Initializer`의 6개 case에 `exponent: Float = 1` associated value를 추가한다. 기본 associated value를 사용해 기존 Swift 생성식은 그대로 컴파일되고 기존 의미도 유지한다.

```swift
case lifetimeRandom(min: Float, max: Float, exponent: Float = 1)
case sizeRandom(min: Float, max: Float, exponent: Float = 1)
case colorRandom(min: Vec3, max: Vec3, exponent: Float = 1)
case velocityRandom(min: Vec3, max: Vec3, exponent: Float = 1)
case rotationRandom(min: Vec3, max: Vec3, exponent: Float = 1)
case angularVelocityRandom(min: Vec3, max: Vec3, exponent: Float = 1)
```

각 JSON 파서 분기는 `pexponent(i["exponent"]) ?? 1`을 전달한다. `pexponent`는 `JSONSerialization`의 boolean이 `NSNumber`/`Double`로 둔갑하는 브리지를 `CFBooleanGetTypeID`로 먼저 배제한 뒤 기존 `pfloat`의 유한 숫자 검사에 위임한다. 따라서 필드 부재, boolean, 문자열, NaN/무한대 등은 `1`로 폴백한다. 기존 min/max 기본값과 회전 단위(라디안, 라디안/초)는 바꾸지 않는다.

### 분포 성형

기본 수식은 다음과 같다.

```text
raw   = uniform [0, 1)
t     = exponent == 1 ? raw : pow(raw, max(0.0001, exponent))
value = min + (max - min) * t
```

시뮬레이터 내부에 particle initializer 전용 공용 헬퍼를 둔다. `SplitMix64`의 일반 API는 확장하지 않는다.

- `randomFactor(exponent:)`: 난수를 정확히 한 번 소비하고 성형된 `t`를 반환한다.
- `randomRange(_:_:exponent:)`: signed span `(max - min)`에 `t`를 적용한다.
- `exponent == 1`은 `powf`를 우회해 기존 균등 산술을 보존한다.
- 0 이하의 exponent는 기존 `alphaRandom`과 동일하게 `0.0001`로 clamp한다. 이는 WE 네이티브 범위가 아니라 Waple의 기존 호환 정책이다.
- min/max는 정렬하지 않는다. 역방향 endpoint도 그대로 보간한다.

`alphaRandom`도 같은 헬퍼를 사용하되 결과는 기존과 같아야 한다.

### Vector 난수 정책

> **[보존/추측]** WE가 vector 3성분에 공유 난수 1개를 쓰는지 성분별 난수 3개를 쓰는지는 확인되지 않았다. 이번 구현은 현재 Waple 구조를 보존한다.

- `colorRandom`: 공유 `t` 1개로 RGB를 함께 보간한다. min↔max 색 라인 위의 그라디언트를 유지한다.
- `velocityRandom`, `rotationRandom`, `angularVelocityRandom`: 축별 `t` 3개를 독립적으로 뽑는다. 방향·회전 박스 스프레드를 유지한다.
- `lifetimeRandom`, `sizeRandom`, `alphaRandom`: 스칼라이므로 `t` 1개를 뽑는다.

RNG draw 횟수는 initializer 하나당 각각 `1/1/1/1/3/3/3`으로 유지한다. min과 max가 같아도 draw를 생략하지 않는다. 이는 뒤에 오는 initializer와 child system의 결정적 시퀀스를 보존하기 위한 계약이다.

### TRADEOFFS와 A/B 관찰 조건

현재 정책은 확정된 WE 네이티브 구현이 아니라, 확인 불가능한 부분에서 기존 호환성을 우선한 선택이다.

```text
[보존/추측] color=공유 난수 1개, velocity/rotation/angularVelocity=축별 난수 3개.
exponent는 각 기존 난수 t에 적용한 뒤 min→max를 보간한다.
colorRandom만 A/B 관찰 대상으로 두며, WE 실화면에서 그라디언트가 아닌 RGB 박스형 분산이
확인될 때 color를 축별 3개로 전환한다. 그 전에는 현재 정책을 유지한다.
```

관찰 조건이 충족되더라도 다른 vector initializer를 함께 바꾸지 않는다. color만 별도 설계와 회귀 테스트를 거쳐 변경한다.

### 오류 및 호환 처리

- exponent 부재 또는 비유한/비숫자 값: `1`로 폴백한다.
- exponent `<= 0`: 샘플 시 `0.0001`로 clamp한다.
- endpoint 역전: 정렬하지 않고 signed span으로 보간한다.
- `exponent == 1`: 기존 raw 난수와 산술을 유지한다.
- enum case arity는 늘어나므로 외부 pattern match에는 소스 호환 변경이지만, 저장 형식이나 `Codable` migration은 없다. 저장소 내부 pattern match는 전부 갱신한다.

## 테스트 설계

파서→시뮬레이터를 한 번에 통과하는 고정 시드 unit test 두 개와 파서/RNG 경계 테스트 두 개를 `ParticleSystemTests`에 둔다. 주 fixture는 zero-extent box emitter의 instantaneous 1개 스폰과 7종 initializer를 순서대로 포함한다.

1. **기본 exponent 무회귀**
   - 모든 `exponent` 키를 생략한다.
   - seed `7`, `step(0)` 결과가 현재 선형 샘플 값과 동일한지 확인한다.
   - 파서 기본값 `1`, 기존 draw 순서와 산술 보존을 고정한다.

2. **exponent 2 곡선**
   - 7종 모두 `"exponent": 2`를 지정한다.
   - seed `7`, `step(0)`의 각 scalar/vector 값이 동일 raw의 제곱 곡선과 맞는지 확인한다.
   - 수정 전에는 새 6종만 선형값으로 실패하고, 이미 지원되는 alpha assertion은 통과해야 한다.
   - color의 세 채널 동일값과 vector의 축별 서로 다른 값을 함께 고정한다.

3. **비숫자·비유한 폴백**
   - 실제 `JSONSerialization`을 통과한 boolean과 직접 파서 dictionary에 주입한 문자열, NaN, 무한대를 7종 모두에 넣는다.
   - 모든 exponent가 `1`로 파싱되는지 확인한다.

4. **고정 범위 RNG 소비**
   - min=max인 initializer 뒤에 가변 sentinel initializer를 둔다.
   - 고정 범위도 난수를 소비해 sentinel이 다음 draw를 사용하는지 seed `7`로 확인한다.

GREEN 후에는 다음 두 클래스만 실행한다.

```bash
swift test --filter ParticleSystemTests
swift test --filter ParticleSimulatorTests
```

전체 `swift test`, 렌더 코퍼스, GT 스냅샷 재생성은 실행하지 않는다.

## 성공 기준

- 6개 누락 initializer가 exponent를 파싱하고 분포에 적용한다.
- exponent 2는 동일 raw 대비 min 쪽으로 편향된다.
- exponent 생략은 기존 값과 RNG draw 순서를 유지한다.
- alphaRandom의 기존 곡선과 clamp가 유지된다.
- color는 공유 1 draw, velocity/rotation/angular velocity는 축별 3 draw를 유지한다.
- min/max 역전, 라디안 단위, color 0–255 정규화가 바뀌지 않는다.
- 두 관련 unit-test 클래스만 통과한다.

## 변경 경계

- `Sources/WapleCore/ParticleSystem.swift`
- `Sources/WapleCore/ParticleSimulator.swift`
- `Tests/WapleCoreTests/ParticleSystemTests.swift`
- 필요할 때만 `Tests/WapleCoreTests/ParticleSimulatorTests.swift`

렌더러, `SplitMix64`, operator, 사용자 파일 `.vscode/launch.json`은 수정하지 않는다.
