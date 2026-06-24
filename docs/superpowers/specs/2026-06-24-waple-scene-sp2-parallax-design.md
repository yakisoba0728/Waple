# Waple — Scene SP2: 마우스 패럴랙스/깊이 (설계 문서)

- 작성일: 2026-06-24
- 상태: 설계 확정(자율 진행)
- 선행: SP1/SP1.5 병합(main). `SceneRenderer`(Metal 이미지 컴포지터)·`SceneDocument`·`QuadShaders` 존재.
- 범위: 마우스 기반 패럴랙스만. 자동 드리프트·셰이크·perspective는 별도.

---

## 1. 개요 / 목표
SP1이 렌더하는 다층 정적 씬에 **마우스 기반 깊이 패럴랙스**를 추가해 2.5D 깊이감을 준다.
각 레이어는 `parallaxDepth`에 비례해 마우스 오프셋만큼 이동한다.

## 2. 정찰 결과
- 각 object: `parallaxDepth` "x y"(예 `2958411739` = "1 1"; 다층 씬은 레이어마다 다른 값으로 깊이 표현).
- `general`: `cameraparallax`(bool), `cameraparallaxamount`(예 0.5), `cameraparallaxmouseinfluence`(예 0.5).
- 비디오-텍스처 씬(AVPlayer 경로)·단일 레이어 씬은 패럴랙스 무관.

## 3. 설계 (접근 a)
- **셰이더 유니폼 오프셋 + 마우스 온디맨드 드로우**: 전역 마우스 모니터로 화면 중심 대비 정규화 오프셋
  계산 → 버텍스 셰이더가 `pos.xy += cameraOffset * layer.parallaxDepth`. 마우스 이동 시에만 `needsDisplay`
  (연속 루프 없음 → 가림 스로틀링 무관). 마우스 전역 모니터는 권한 불필요.
- 보류: 자동 드리프트(타이머 필요), 카메라 셰이크, perspective, 화면별 오프셋.

## 4. 컴포넌트
| 컴포넌트 | 위치 | 검증 |
|---|---|---|
| `SceneLayer.parallaxDepth: Vec2`(기본 (1,1)) + `SceneDocument.parallaxEnabled/Amount/MouseInfluence` | WapleCore | **TDD** |
| `ParallaxController` (전역 `.mouseMoved` 모니터 → 정규화 오프셋 콜백; 순수 매핑 함수 분리) | WapleRender | **TDD**(매핑) + 수동(모니터) |
| `QuadShaders` 버텍스: `cameraOffset`(buffer1) + `parallaxDepth`(buffer2) 유니폼, `pos += offset*depth` | WapleRender | 빌드 |
| `SceneRenderer` (per-layer depth 저장, cameraOffset 유니폼 전달, 마우스 시 redraw, parallax 비활성 씬은 정적) | WapleRender | 수동 |

### 매핑(순수, TDD)
`ParallaxController.normalizedOffset(mouse: CGPoint, screenFrame: CGRect) -> CGPoint` —
중심=0, 가장자리=±1, 화면 밖은 클램프.

## 5. 데이터 흐름
마우스 이동 → `ParallaxController`가 정규화 오프셋 → `SceneRenderer`가
`cameraOffsetNDC = normalized * amount * mouseInfluence * MAX_SHIFT` 계산·유니폼 설정·`needsDisplay` →
셰이더가 레이어별 `offset*depth` 이동.

## 6. 좌표/스케일 게이트 (실측 튜닝)
- `MAX_SHIFT`(NDC, 예 0.04)·부호·Y축 방향은 **실측 튜닝**(WE `amount`/`mouseinfluence` 매핑).
- 검증: 다층 씬에서 두 cameraOffset(좌/우)을 주입해 레이어들이 깊이에 비례해 어긋나게 이동하는지 스크린샷 비교.

## 7. 에러/강등
- `cameraparallax==false` 또는 단일 레이어 → 정적(오프셋 0, 정상).
- 비디오-텍스처 씬 → VideoRenderer 경로(패럴랙스 미적용).
- 마우스 정보 없음 → 오프셋 0(정적).

## 8. 테스트
- **TDD**: `SceneLayer.parallaxDepth` 파싱(기본 (1,1)), `SceneDocument` parallax 필드,
  `ParallaxController.normalizedOffset` 매핑(중심 0, 가장자리 ±1, 클램프).
- **수동/자율 게이트**: 다층 씬에 좌/우 오프셋 주입 → 레이어 상대 이동 스크린샷 비교(깊이 패럴랙스 확인).

## 9. 범위 밖
- 자동 드리프트, 카메라 셰이크, perspective 패럴랙스, 화면별 오프셋, 깊이맵.
- BC3/효과/파티클/오디오(SP3+).
