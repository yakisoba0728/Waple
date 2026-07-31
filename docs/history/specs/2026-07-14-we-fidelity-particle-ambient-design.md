# WE 파티클 회전·2D Ambient 충실도 교정 설계

## 배경

Wallpaper Engine 2.8.0.42 분석에서 두 가지 결정적 불일치가 확인됐다.

1. `rotationrandom`과 `angularvelocityrandom`의 JSON 값은 이미 라디안과 rad/s인데, Waple은 적용 시 다시 `π / 180`을 곱한다. 이 때문에 회전 범위가 약 57.3배 축소된다.
2. WE의 2D `genericimage4`는 ambient에 `g_LightAmbientColor`만 사용하지만, Waple은 `(ambient + skylight) / 2`를 사용한다.

두 문제 모두 현재 코드에 남아 있으며 WE 근거가 확정적이다. 이번 작업은 이 두 문제만 작은 충실도 슬라이스로 교정한다.

## 목표

- 파티클 회전 및 각속도 initializer의 값을 JSON 라디안 단위 그대로 사용한다.
- 2D 포워드 라이팅의 ambient 항을 `ambientColor` 단독으로 계산한다.
- 단위 테스트와 렌더 테스트로 두 동작을 고정한다.
- 기존 전체 테스트와 스냅샷 비교로 의도하지 않은 회귀가 없는지 확인한다.

## 비목표

- 파티클 `exponent`, `sizechange`/`colorchange.endtime`, 다중 operator 합성은 변경하지 않는다.
- Cook–Torrance PBR, 정확 감쇠, bloom, ACES, web 강제정지, 3D 파티클은 다루지 않는다.
- `skylightColor` 파싱이나 3D 헤미스피어 ambient 데이터 모델은 제거하지 않는다.

## 설계

### 파티클 회전 단위

`Initializer.rotationRandom`과 `Initializer.angularVelocityRandom`의 단위 계약을 각각 radians와 radians/s로 명시한다. `ParticleSimulator.apply(_:to:)`는 JSON에서 파싱된 min/max 범위로 난수를 생성한 값을 변환 없이 `rotation`과 `angularVel`에 저장한다.

파서의 숫자 처리와 RNG 소비 순서는 바꾸지 않는다. 따라서 수정 전후 차이는 잘못된 도→라디안 변환 제거에만 한정된다.

### 2D ambient

`SceneLight3D.forwardUniforms`는 2D `f_lit` 전용 팩이다. 여기서 `ambientTerm`을 `ambientColor`와 동일하게 설정한다. `skylight` 인자는 호출 호환성과 향후 3D 용도를 위해 유지하되 2D ambient 계산에는 사용하지 않는다.

관련 주석과 테스트 오라클도 `genericimage4`의 flat ambient 계약에 맞춘다. 3D 라이팅 데이터와 `packUniforms`에는 영향을 주지 않는다.

## 테스트 설계

### 파티클 단위 테스트

- min=max=`2π`인 `rotationRandom`을 적용했을 때 결과 rotation이 `2π`인지 확인한다.
- min=max=`π`인 `angularVelocityRandom`을 적용했을 때 결과 angular velocity가 `π`인지 확인한다.
- JSON 파싱부터 simulator 적용까지 연결해 파서가 원값을 보존하는 것도 함께 검증한다.

고정 min/max를 사용하므로 RNG 알고리즘과 무관하게 결정적으로 검증된다.

### Ambient 단위·렌더 테스트

- `ambient != skylight`인 입력에서 `forwardUniforms().ambientTerm == ambient`인지 확인한다.
- ambient는 같고 skylight만 다른 두 합성 2D 씬을 렌더해 결과 픽셀이 동일한지 확인한다.
- 기존 라이트 색·공간 감쇠·무라이트 무회귀 테스트는 유지한다.

### 회귀 검증

1. 변경 전 현재 HEAD로 스냅샷 기준선을 생성한다.
2. 관련 `WapleCoreTests`와 `WapleRenderTests`를 실행한다.
3. 전체 `swift test`를 실행한다.
4. 변경 후 스냅샷을 변경 전 기준선과 비교한다. 차이가 난 씬은 회전 파티클 또는 2D `LIGHTING` 사용 여부와 대조해 의도된 변화인지 판정한다.

## 오류 처리와 호환성

새로운 실패 경로나 외부 API 변경은 없다. enum case의 연관값 형태도 유지하므로 소스 호환성 영향은 주석과 내부 의미 교정에 한정된다. 기존 스냅샷의 시각 차이는 회귀가 아니라 의도된 WE 충실도 교정으로 기록한다.

## 변경 경계

예상 수정 파일은 다음으로 제한한다.

- `Sources/WapleCore/ParticleSystem.swift`
- `Sources/WapleCore/ParticleSimulator.swift`
- `Sources/WapleCore/SceneDocument.swift`
- 관련 `Tests/WapleCoreTests`와 `Tests/WapleRenderTests`

사용자 작업인 `.vscode/launch.json`은 건드리지 않는다.
