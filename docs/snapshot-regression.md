# 씬 픽셀 스냅샷 회귀 파이프라인

파스·디코드·컴파일 검증(`WapleCompat --deep`)은 "무엇이 지원되는가"를 지키지만,
**"그려지는 픽셀이 변하지 않았는가"**를 지키는 게이트는 없었다. 포워드 라이팅 등
위험한 렌더 작업 전에 이 스냅샷 회귀 게이트를 통과시켜 시각 회귀를 조기 검출한다.

대상은 **scene 170종**(2D/3D/파티클/텍스트 — Metal 오프스크린 경로). video/web 은
제외(AVFoundation/WebKit 비결정, 범위 밖). 비디오-백드 씬(`type=scene` 이지만 내부가
mp4 텍스처 → AVFoundation 위임)은 캡처 시 픽셀이 없어 `empties` 버킷으로 자동 제외된다.

## 도구

- `WapleCompat --capture` / `--compare` (`Sources/WapleCompat/SnapshotPipeline.swift`,
  `SnapshotCompare.swift`) — 캡처/비교 드라이버. 렌더러(`SceneRenderer`)는 공개 API 호출만.
- `WapleSnapshot` (`Sources/WapleSnapshot/Snapshot.swift`) — GPU 무의존 순수 코어:
  매니페스트 스키마, diff 메트릭, 임계 판정, 해시. 유닛 테스트(`Tests/WapleSnapshotTests`).

헤드리스 마운트·프레임 캡처는 기존 테스트 인프라(`RealPackagesGroundTruthTests`,
`SceneRenderer.captureFrames`)와 **같은 규약**을 재사용한다 — 렌더러 수정 없음.

## CLI

```
# 베이스라인 생성(자기-일관 셀프체크 포함 → 결정/비결정 자동 분류)
WapleCompat --capture <outDir> [--label <name>] [<corpusRoot>]

# 현재 빌드를 캡처해 베이스라인과 픽셀 diff (회귀 게이트)
WapleCompat --compare <baselineDir> [<corpusRoot>]
```

- `<corpusRoot>` 기본값 `~/Downloads/wallpaper_dev`. 씬은 `<corpusRoot>/backgrounds/*/`
  중 `scene.pkg`|`gifscene.pkg` 를 가진 폴더.
- `--label` 기본값 = cwd 의 git 단축 sha. 산출물은 `<outDir>/<label>/`.
- base-assets(공유 셰이더 `common.h`)는 `WAPLE_BASE_ASSETS` 또는 `<corpusRoot>/assets`.
- 종료코드: `--compare` 는 **결정 씬 FAIL 또는 렌더→무픽셀 회귀**가 있으면 1, 아니면 0.
  `--capture` 는 마운트 실패가 있으면 1.

### 산출물 레이아웃

```
<outDir>/<label>/
  manifest.json         # gitSHA, label, thumb 크기, 고정 t, entries[], empties[], failures[]
  thumbs/<sceneId>.png  # 256×144 씬별 썸네일(캡처 프레임)
```

`manifest.json` 의 `entries[]` 각 항목: `id, width, height, hash(FNV-1a),
meanLuma, deterministic, selfMaxDiff, note?`.

## 베이스라인 저장 위치

리포 밖(코퍼스·머신 종속 산출물). 권장:

```
~/Downloads/wallpaper_dev/.waple-snapshots/<git-sha 또는 label>/
```

리포에는 **도구 + 이 문서만** 둔다. 베이스라인은 재생성 가능한 산출물이다.

## 결정성

씬은 시간/랜덤/오디오 반응 함수라 프레임이 매 실행 달라질 수 있다. 파이프라인은
**고정 조건 + 자기 일관 측정**으로 결정성을 확보·검증한다.

**① 고정 조건**(캡처 시 강제):
- 시각 `t=6.0` 고정 주입 (인트로 페이드가 끝난 정상상태 — GT 규약과 동일)
- `pause()` 로 라이브 오디오 캡처·시차 정지
- `setSpectrum(.silent)` 로 오디오-반응 효과를 무신호로 고정 (Screen Recording 권한
  유무와 무관하게 재현 — 머신 간 베이스라인 안정)
- 파티클 시드는 렌더러가 상수(`0x9E3779B9 &+ index`)로 고정 → 마운트마다 동일
- `nowPlayingProvider` 스텁으로 미디어 폴링(osascript) 차단
- `fitMode` 핀(`.fill`), 씬 sound 레이어는 헤드리스(window==nil)라 자동 스킵

**② 자기 일관 측정**: `--capture` 는 프레임을 낸 씬을 **독립 재마운트로 2회 캡처**해
self-diff 를 잰다. `selfConsistent` 임계 초과 씬은 `deterministic:false` + 사유를
매니페스트에 기록(비교 시 관대 임계). empty/실패 씬은 1×(자기 diff 무의미).

**③ 측정 결과**(코퍼스 460종 중 scene 170): 캡처 146 / empty 24 / fail 0.
캡처된 146종 **전부 결정**(self-diff maxAbsDiff=0), **비결정 0**. 고정 조건이
잔여 비결정(JS `Math.random`/wall-clock 등)을 남기지 않음을 실측 확인.

## 임계

`WapleSnapshot` 의 `DiffThreshold`(채널차 0..255 기준):

| 임계 | meanAbsDiff | fracExceeding | 용도 |
|---|---|---|---|
| `strict` | ≤ 1.5 | ≤ 0.004 | 결정 씬 회귀 게이트(사실상 픽셀 동일) |
| `lax` | ≤ 14.0 | ≤ 0.20 | 비결정 버킷(자기-diff 수준 변동 허용) |
| `selfConsistent` | ≤ 0.5 | ≤ 0.002 | 자기-일관 판정(같은 빌드 2회) |

`fracExceeding` = 픽셀당 4채널 중 최대차가 `perPixelThreshold`(기본 16)를 넘는 픽셀 비율.

## 성능 (release, M-series, 실측)

- `--capture`(셀프체크 2×): 146 캡처 + 24 empty, **≈611s (10.2분)**. 베이스라인 생성은
  드물게 수행(코디네이터).
- 1× 캡처 패스: **≈360s (6.0분)**. 느린 꼬리는 대용량 비디오-백드 pkg(52–679MB)가
  차지 — 이들은 empty 로 제외되지만 마운트 로드 비용은 발생.
- `--compare`: 베이스라인 `entries`(146)만 1회 캡처 → 비디오-백드 empty 24종은
  건너뛰므로 게이트가 더 빠름. 피크 RSS ≈3.9GB.

## 재베이스라인

고정 조건 상수(`t`, `fitMode`, thumb 크기)나 렌더러가 의도적으로 바뀌면 베이스라인을
재생성한다: `--capture` 를 새 `--label` 로 다시 실행. 최종 베이스라인은 관련 브랜치
머지 후 코디네이터가 생성한다.
