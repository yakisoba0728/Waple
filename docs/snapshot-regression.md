# 씬 픽셀 스냅샷 회귀 파이프라인

파스·디코드·컴파일 검증(`WapleCompat --deep`)은 "무엇이 지원되는가"를 지키지만,
**"그려지는 픽셀이 변하지 않았는가"**를 지키는 게이트는 없었다. 포워드 라이팅 등
위험한 렌더 작업 전에 이 스냅샷 회귀 게이트를 통과시켜 시각 회귀를 조기 검출한다.

대상은 **scene 170종**(2D/3D/파티클/텍스트 — Metal 오프스크린 경로). web 은
제외(WebKit 비결정, 범위 밖). 비디오-백드 씬(`type=scene` 이지만 내부가 mp4 텍스처 →
mount 가 VideoRenderer 에 위임)은 과거 캡처 시 픽셀이 없어 `empties` 로 자동 제외됐으나,
이제 추출 mp4 에서 고정 t 프레임을 **정확 디코드**(AVAssetImageGenerator, tolerance=0 →
셀프체크 2× 결정성)해 `entries` 로 캡처된다(H1 수정, `VideoTextureExtractor.captureFramePNG`).
단, 이 프레임은 비디오 콘텐츠 자체이며 씬 오버레이(clock/logo 등)는 포함하지 않는다 —
VideoRenderer 위임이 다른 레이어를 그리지 않기 때문(전체화면 비디오 근사). 다음 베이스라인
재생성부터 이 24종이 `entries` 에 포함된다(기존 `--compare` 는 베이스라인 `entries` 만 캡처하므로 무영향).

## 도구

- `WapleCompat --capture` / `--compare` (`Sources/WapleCompatCore/SnapshotPipeline.swift`,
  `SnapshotCompare.swift`) — 캡처/비교 드라이버. 렌더러(`SceneRenderer`)는 공개 API 호출만.
- `WapleSnapshot` (`Sources/WapleSnapshot/Snapshot.swift`) — GPU 무의존 순수 코어:
  매니페스트 스키마, diff 메트릭, 임계 판정, 해시. 유닛 테스트(`Tests/WapleSnapshotTests`).

헤드리스 마운트·프레임 캡처는 기존 테스트 인프라(`RealPackagesGroundTruthTests`,
`SceneRenderer.captureFrames`)와 같은 렌더 API를 재사용한다 — 렌더러 수정 없음. 다만 두 하네스의
판정 규약까지 같은 것은 아니다. SnapshotPipeline은 기본 256×144이며 Date·Math.random·포인터를
모두 고정하지만, RealPackagesGroundTruthTests는 640×360이고 Date·포인터만 고정한다. 따라서 두
산출물의 픽셀 값이나 결정성 판정을 서로의 기준선으로 직접 사용하면 안 된다.

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

**[2026-08-02 갱신] 판정에 쓰는 기준선은 리포에 커밋한다** — `spec/golden/snapshot/`.
커밋된 골든이 0건이라 하드 오라클이 "마운트 무크래시 + PNG 존재" 뿐이던 것이 F402/F403 이었고,
그걸 닫은 게 이 디렉터리다. HEAD 에는 **현행 + 이식 전 이력 둘만** 둔다(하나가 11MB).
중간 기준선은 커밋 이력에서 꺼낸다.

작업 중 만드는 임시 캡처(A/B, 프로브)는 여전히 리포 밖에 둔다 — 예: `~/Downloads/waple-*`.

## 결정성

씬은 시간/랜덤/오디오 반응 함수라 프레임이 매 실행 달라질 수 있다. 파이프라인은
**고정 조건 + 자기 일관 측정**으로 결정성을 확보·검증한다.

**① 고정 조건**(캡처 시 강제):
- 시각 `t=6.0` 고정 주입 (인트로 페이드가 끝난 정상상태 — GT 규약과 동일)
- `pause()` 로 라이브 오디오 캡처·시차 정지
- `setSpectrum(.silent)` 로 오디오-반응 효과를 무신호로 고정 (Screen Recording 권한
  유무와 무관하게 재현 — 머신 간 베이스라인 안정)
- 파티클 시드는 렌더러가 상수(`0x9E3779B9 &+ index`)로 고정 → 마운트마다 동일
- JS `Date`를 `2024-01-01 12:00:00 UTC`에 고정
- JS `Math.random()`을 `0xC0FFEE_1038` 시드로 고정
- 포인터 UV를 화면 중앙 `(0.5, 0.5)`에 고정
- `nowPlayingProvider` 스텁으로 미디어 폴링(osascript) 차단
- `fitMode` 핀(`.fill`), 씬 sound 레이어는 헤드리스(window==nil)라 자동 스킵

**② 자기 일관 측정**: `--capture` 는 프레임을 낸 씬을 **독립 재마운트로 2회 캡처**해
self-diff 를 잰다. `selfConsistent` 임계 초과 씬은 `deterministic:false` + 사유를
매니페스트에 기록(비교 시 관대 임계). empty/실패 씬은 1×(자기 diff 무의미).

**③ 측정 결과**(코퍼스 460종 중 scene 170, H1 수정 이전): 캡처 146 / empty 24 / fail 0.
캡처된 146종 **전부 결정**(self-diff maxAbsDiff=0), **비결정 0**. 고정 조건이
잔여 비결정(JS `Math.random`/wall-clock 등)을 남기지 않음을 실측 확인.
H1 수정 후 비디오-백드 24종도 프레임을 낸다(다음 재생성 시 대부분 `empties`→`entries`).
표본 3종은 empty→비단색 콘텐츠+같은-머신 결정성 실측(`VideoBackedSceneCaptureTests`),
나머지는 동일 브랜치를 타되 개별 디코드 미검증 — 디코드 불가 페이로드는 graceful 하게 empty
로 폴백하므로 최악도 무회귀(≤ 기존 empties). 주의: 이 24종 픽셀은 AVFoundation(H.264)+CG
스케일 산출이라 **머신 간** 재현이 Metal 경로만큼 보장되진 않는다 — 코디네이터가 이들을 포함해
베이스라인을 재생성한 뒤 `strict` 가 머신 간 불안정하면 `lax` 버킷으로 내려야 한다(관측 전 선반영 불필요).

## 임계

`WapleSnapshot` 의 `DiffThreshold`(채널차 0..255 기준):

| 임계 | meanAbsDiff | fracExceeding | 용도 |
|---|---|---|---|
| `strict` | ≤ 1.5 | ≤ 0.004 | 결정 씬 회귀 게이트(사실상 픽셀 동일) |
| `lax` | ≤ 14.0 | ≤ 0.20 | 비결정 버킷(자기-diff 수준 변동 허용) |
| `selfConsistent` | ≤ 0.5 | ≤ 0.002 | 자기-일관 판정(같은 빌드 2회) |

`fracExceeding` = 픽셀당 4채널 중 최대차가 `perPixelThreshold`(기본 16)를 넘는 픽셀 비율.

## 성능 (실측)

> ⚠️ **시간을 비교할 때는 빌드 구성과 캡처 구성을 함께 봐야 한다.** 아래 두 실측은
> 둘 다 유효하지만 조건이 다르다 — 이 표기가 없어서 실제로 한 번 오독이 있었다.

| 측정 | 빌드 | 구성 | 소요 | 씬당 |
| --- | --- | --- | --- | --- |
| 기존 | **release** | 146 캡처 + 24 empty | **≈611s (10.2분)** | 4.2s |
| `baseline-81098bb` (2026-07-31) | **debug** | **170 캡처 + 0 empty** | **1,694s (28.2분)** | 10.0s |
| `baseline-31fecaa` (2026-08-02, **이력**) | **release** | **170 캡처 + 0 empty** | **165s (2.8분)** | 1.0s |

> **[정정 2026-08-30] 이 표의 마지막 행은 `현행` 이라고 적혀 있었다 — 트리에 없는 라벨이다.**
> 종전: ~~`| baseline-31fecaa (2026-08-02, 현행) | …`~~
>
> `spec/golden/snapshot/` 에 실재하는 것은 `baseline-6f0bcf0` · `baseline-81098bb` ·
> `nondet-2026-08-01` 셋이고 `31fecaa` 는 없다. 같은 사실을 sibling 정본이 이미 적는다 —
> `spec/golden/snapshot/README.md` 가 `31fecaa` 를 "**HEAD 에 없다**" 목록에 넣는다.
> **이 문서 안에서도 모순이었다**: 위 「베이스라인 저장 위치」가 "HEAD 에는 **현행 + 이식 전 이력
> 둘만** 둔다" 고 적으므로, 두 줄을 함께 읽으면 존재하지 않는 디렉터리를 가리킨다.
> `현행` 은 기준선 문서에서 절대 낡아서는 안 되는 단어다.
>
> **왜 썩었나.** `88c195e8`(2026-08-02, "오라클을 baseline-31fecaa 로 옮긴다")이 이 태그를 썼고,
> 그 뒤 네 번의 재베이스라인이 지나가는 동안 이 문서는 갱신되지 않았다.
>
> **그래서 라벨 값을 여기 다시 적지 않는다** — 중복이 썩은 원인이다. 판정 라벨의 단일 출처는
> 코드다: `Tests/WapleRenderTests/GoldenBaselineOracleTests.swift` 의 `GoldenBaseline.currentLabel`.
> ```bash
> grep -n 'static let currentLabel' Tests/WapleRenderTests/GoldenBaselineOracleTests.swift
> ls spec/golden/snapshot/     # 트리에 실재하는 라벨
> ```
> 위 행은 그대로 유효한 **2026-08-02 release 빌드 성능 실측**이므로 지우지 않고 `이력` 로 강등했다
> (아래 캐시 경고도 그 측정에 정확히 스코프된 것이라 그대로 둔다).

debug 오버헤드가 씬당 2.4배다. `empties` 가 24 → 0 으로 바뀐 것은 H1 수정으로
비디오-백드 씬이 `entries` 에 들어왔기 때문이지 성능 변화가 아니다.

`baseline-31fecaa` 의 1.0s/씬은 **mp4 캐시가 더워진 상태**의 값이다(같은 세션에서 이미 여러 번
전 코퍼스를 떴다). 찬 캐시에서는 대용량 비디오-백드 pkg 추출이 다시 들어가므로 그대로 비교하면
안 된다 — 기준선 생성 소요를 인용할 때는 캐시 상태를 함께 적을 것.

- 1× 캡처 패스(release): **≈360s (6.0분)**. 느린 꼬리는 대용량 비디오-백드 pkg(52–679MB)가
  차지 — mp4 추출·로드 비용이 크다(H1 후 프레임 디코드는 추가되나 1프레임이라 경미).
- `--compare`: 베이스라인 `entries` 만 1회 캡처. 피크 RSS ≈3.9GB.
- **기준선 생성은 `-c release` 로 돌릴 것.** 안 붙이면 debug 로 떨어져 2.8배 걸린다.

## 커밋된 기준선

`spec/golden/snapshot/` 에 있다. 이전에는 커밋된 골든이 0건이라 하드 오라클이
"마운트 무크래시 + PNG 존재" 뿐이었고 검은 프레임도 통과했다(F402/F403).
읽을 때 주의할 것은 [spec/golden/snapshot/README.md](../spec/golden/snapshot/README.md) 참조 —
특히 **비디오-백드 24종의 머신 간 재현 불가**(strict 불일치는 회귀가 아니라 예고된 현상,
대응은 lax 강등). 셀프체크 비결정은 현행 기준선에서 **0종**이다(이식 전 기준선은 1종:
`3363252053`). 다만 그 필드는 같은 프로세스 안 2회 캡처만 재므로, 세션 간 재현성은
`rebaseline-golden.sh` 의 커서-이동 게이트가 따로 본다.

## 재베이스라인

고정 조건 상수(`t`, `fitMode`, thumb 크기)나 렌더러가 의도적으로 바뀌면 베이스라인을
재생성한다: `--capture` 를 새 `--label` 로 다시 실행. 최종 베이스라인은 관련 브랜치
머지 후 코디네이터가 생성한다.
