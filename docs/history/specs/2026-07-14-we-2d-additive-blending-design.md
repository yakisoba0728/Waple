# WE 2D Additive 블렌딩 설계

## 배경

Wallpaper Engine 머티리얼의 `passes[0].blending`은 고정기능 GPU 블렌드 상태다. Waple은 이 값을 `SceneLayer.blendMode`까지 파싱하지만 2D GPU 레이어와 드로우 파이프라인으로 전달하지 않는다. 그 결과 `additive` 머티리얼도 항상 premultiplied alpha-over로 그려진다.

Waple의 파티클과 3D 메시 경로에는 이미 additive 파이프라인이 있다. 두 경로 모두 premultiplied source에 대해 RGB와 alpha의 source factor를 `.one`, destination factor를 `.one`으로 사용한다. 이번 작업은 같은 규약을 일반 2D 이미지 레이어에 좁게 적용한다.

## 목표

- 일반 2D 이미지 레이어의 `blending: "additive"`를 GPU 드로우까지 보존한다.
- 기존 `f_main`의 straight-alpha → premultiplied-alpha 변환을 그대로 사용한다.
- additive 레이어만 `source + destination` 고정기능 블렌딩으로 그린다.
- 기존 특수 렌더 경로와 non-additive 머티리얼의 출력을 유지한다.
- 작은 픽셀 오라클과 관련 테스트만 실행해 빠르게 검증한다.

## 비목표

- `normal`과 `translucent`의 WE 네이티브 차이는 규명하거나 변경하지 않는다. 둘 다 현재 alpha-over 동작을 유지한다.
- `alphatocoverage`를 구현하거나 additive로 폴백하지 않는다.
- lit 레이어, `colorBlendMode`, framebuffer composition에 material additive를 중첩하지 않는다.
- 블렌드 모드 전체를 새 enum이나 파이프라인 캐시로 일반화하지 않는다.
- 셰이더 수식, 레이어 순서, 텍스처 알파 형식, 파서의 first-pass 규칙을 변경하지 않는다.

## 검토한 접근

### A. 전용 2D additive 파이프라인 — 채택

기존 `v_main`/`f_main`과 누적 버퍼 포맷을 재사용하고 destination blend factor만 `.one`으로 바꾼 파이프라인을 하나 추가한다. `GPULayer`에는 additive 여부만 전달한다.

장점은 변경 범위가 작고 파티클·3D의 검증된 패턴과 동일하며, 픽셀 테스트가 직접적이라는 점이다. 현재 확정된 `additive`만 표현하므로 불확실한 모드를 실수로 활성화하지 않는다.

### B. material blend enum과 파이프라인 캐시 — 보류

모든 material blending을 내부 enum으로 바꾸고 모드별 파이프라인을 캐시할 수 있다. 향후 `alphatocoverage` 확장에는 유리하지만, 현재 의미가 확정되지 않은 `normal`/`translucent`와 MSAA 설계까지 끌어들인다.

### C. framebuffer 스냅샷 기반 셰이더 합성 — 기각

destination을 복사한 뒤 셰이더에서 더할 수도 있다. 그러나 고정기능 블렌딩으로 충분한 작업에 추가 텍스처와 패스가 필요하고, 이미 destination을 포함하는 `f_blend` 경로와의 중복 위험이 있다.

## 설계

### 데이터 흐름

기존 파싱 경계는 유지한다.

1. `SceneDocument.parseLayer`가 `passes[0].blending`을 `SceneLayer.blendMode`에 저장한다.
2. `SceneRenderer.buildLayers`가 `layer.blendMode == "additive"`를 `GPULayer.blendAdditive`에 저장한다.
3. `encodeLayer`가 일반 `f_main` 분기에서만 이 플래그를 읽어 additive 또는 기존 over 파이프라인을 선택한다.

`GPULayer`에는 raw 문자열 대신 `Bool`을 저장한다. 렌더 핫 경로에서 문자열 비교를 피하고 이번 작업의 지원 범위를 명확히 제한하기 위해서다. 이름은 기존 `GPUParticleSystem.blendAdditive`와 맞춘다.

`SceneLayer.blendMode`의 주석도 실제 소비 범위에 맞춰 갱신한다. 이는 동작 변경이 아니라 구현 후 "2D 경로는 무시"라고 남게 될 낡은 설명을 제거하는 작업이다.

### 파이프라인

`layerAdditivePipeline`을 기본 2D `pipeline` 옆에서 생성한다.

- vertex function: `v_main`
- fragment function: `f_main`
- pixel format: `accPixelFormat`
- RGB/alpha operation: `.add`
- RGB/alpha source factor: `.one`
- RGB/alpha destination factor: `.one`

`f_main`은 샘플 색의 RGB에 alpha를 한 번 곱하므로 파이프라인에서 추가 premultiply를 하지 않는다. `accPixelFormat`을 사용해 LDR `.bgra8Unorm`과 HDR 누적 포맷 양쪽에서 pipeline/attachment 불일치를 방지한다.

### 파이프라인 선택 우선순위

기존 특수 경로를 보존하며 다음 순서를 사용한다.

1. lit `f_lit`
2. object `colorBlendMode`의 `f_blend`
3. framebuffer composition의 `f_compose`
4. material additive의 `f_main` + `layerAdditivePipeline`
5. 기본 premultiplied over의 `f_main` + `pipeline`

따라서 additive와 특수 경로가 동시에 표시된 레이어는 현재 특수 경로를 유지한다. 목적은 일반 2D 이미지에서 확정된 결함만 수정하는 것이며, 조합 의미가 확인되지 않은 경로를 추측해 바꾸지 않는 것이다.

### 오류 처리와 수명주기

`layerAdditivePipeline` 생성 실패는 mount 전체 실패로 승격하지 않는다. 기존 선택형 파이프라인과 같이 optional로 만들고, additive 드로우 시 생성돼 있지 않으면 기본 over 파이프라인으로 폴백한다.

`teardown()`은 `layerAdditivePipeline`을 `nil`로 초기화해 renderer 재사용 시 이전 디바이스 상태가 남지 않게 한다. 외부 API와 저장 형식은 바뀌지 않는다.

## 테스트 설계

### 핵심 픽셀 오라클

불투명 초록 배경 `(0, 1, 0, 1)` 위에 alpha 0.5의 빨강 레이어 `(1, 0, 0, 0.5)`를 그린다. `f_main`의 premultiplied source는 `(0.5, 0, 0, 0.5)`다.

- additive 기대 RGB: `(0.5, 1.0, 0.0)`
- 기존 over 기대 RGB: `(0.5, 0.5, 0.0)`

중앙 픽셀을 허용 오차와 비교한다. 이 테스트는 파싱, `GPULayer` 전달, 파이프라인 선택과 blend factor를 한 번에 검증하며 수정 전에는 실패해야 한다.

### 무회귀 테스트

- `normal`, `translucent`, blending 키 생략은 기존 over 결과를 유지한다.
- `hdr: true`인 작은 additive fixture를 한 번 렌더해 additive 파이프라인이 HDR의 `accPixelFormat`과 호환되는지 확인한다. 정확한 ACES 색 곡선은 이 테스트의 대상이 아니며 additive 채널 관계와 렌더 성공만 본다.

테스트는 신규 material-blending 테스트 클래스와 직접 관련된 기존 composite 테스트만 실행한다. 전체 `swift test`와 전수 코퍼스 캡처는 실행하지 않는다.

## 성공 기준

- 일반 2D additive fixture가 alpha-over가 아니라 premultiplied source와 destination의 합을 출력한다.
- `normal`, `translucent`, 생략 모드의 기존 픽셀 결과가 유지된다.
- LDR과 HDR fixture 모두 pipeline format 오류 없이 렌더된다.
- lit, object `colorBlendMode`, framebuffer compose의 선택 우선순위가 바뀌지 않는다.
- 관련 타깃 테스트만 통과한다.

## 변경 경계

예상 수정 파일은 다음으로 제한한다.

- `Sources/WapleCore/SceneDocument.swift`의 `blendMode` 계약 주석
- `Sources/WapleRender/SceneRenderer.swift`
- `Sources/WapleRender/SceneRendererResources.swift`
- `Sources/WapleRender/SceneRendererFrameEncoder.swift`
- `Tests/WapleRenderTests`의 2D material blending 관련 테스트

사용자 작업인 `.vscode/launch.json`은 수정하거나 커밋하지 않는다.
