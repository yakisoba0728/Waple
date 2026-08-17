# spec/golden/snapshot/ — 커밋된 스냅샷 기준선

지금까지 이 리포에는 **커밋된 골든이 하나도 없었다**(BACKLOG F402/F403). 기준선이
처분성 `/tmp/waple_gt` 에 저장되고 드리프트는 `NSLog` 경고로만 남았으며, 하드 오라클이
"마운트 무크래시 + PNG 존재" 뿐이라 **완전히 검은 프레임도 통과**했다.

여기가 그 안전망이다. 변경이 무엇을 바꿨는지 판정하는 기준이 된다.

## 🛑 2026-08-17 — 재베이스라인 **의도적 보류 중**. 게이트 FAIL 33종은 정상이다

지금 `golden-gate.sh` 를 돌리면 **FAIL 33 / PASS 137** 이 나온다. 이건 회귀 감지가 아니라
**아직 굳히면 안 되는 상태**다. 게이트가 빨갛다는 이유로 재베이스라인하지 마라.

경위: `mul` 인자 순서 전치를 고쳤고(`(a*b)` → `(b*a)`), 그 수정 자체는 확정이다 —
`squareToQuad` 코너 항등이 오차 0 으로 맞고 lightshafts 19패스의 `fx≡0` 이 풀렸다.
**그런데 그 수정이 상류 결함 2건을 노출시켰고, 그 결과 일부 씬이 육안으로 나빠졌다.**

WE 실기 레퍼런스 3원 대조(WE / 수정 전 / 수정 후)로 확인한 것:

| 씬 | 판정 |
| --- | --- |
| `3299228616` | **악화.** WE 실기에는 무지개 덩어리가 **없다**. 수정 전 기준선이 WE 에 더 가깝고, 수정 후엔 홍채색 덩어리가 화면 중앙 고양이를 덮는다 |
| `3404976219` | **악화.** 화면 오른쪽 절반이 백색으로 날아간다 |
| `3521337568` | **악화.** 흰 덩어리가 새로 생긴다 |
| `3558034522` | 판정 애매 — 전체가 뿌옇게 뜬다 |
| `3460973721` | **개선**(대조군). 비어 있던 상단에 하강 광선이 생기고 작성자 워크샵 프리뷰와 위치·각도가 맞는다 |

원인은 `mul` 이 아니라 그것이 가리고 있던 둘이다:
1. **부모 가시성 전파** — `3299228616` 의 lightshafts 쿼드 6개가 언어 변형 부모에 매달려 있고
   부모 중 `visible=true` 는 하나뿐인데 6개를 다 그린다(기존 추적 98건/18씬).
2. **이펙트 캐리어 quad 의 풀스크린 승격** — `SceneDocument.effectQuadLayer` 가 origin/scale/angles
   를 폐기한다. `3404976219` 의 쿼드 origin 은 화면 밖인데 전화면에 칠한다.
   선행 조건인 WE `shape:quad` 기본 크기가 미확정이다.

**둘을 고친 뒤에 한 번에 다시 뜬다.** 지금 뜨면 `9a50467`("종전 기준선이 파괴 렌더를 기준으로
삼고 있었다")에서 고친 실수를 그대로 반복하는 것이다 — 그때도 수치는 통과였고 육안이 아니었다.

**교훈**: 수치만으로 "개선" 을 판정하지 마라. 이번에 앞선 단위가 정확히 그래서 틀렸다.
mean/max/frac 은 무엇이 **바뀌었는지**만 말하고 어느 쪽이 **맞는지**는 말하지 않는다.

## `baseline-7075b74` — **현행 기준선**(2026-08-16, 2차)

판정은 이걸 기준으로 한다(`GoldenBaseline.currentLabel`). `baseline-81098bb` 는 이식 전 이력이다.

| 항목 | 값 |
| --- | --- |
| gitSHA | `7075b74` (main, Sources 청결) |
| 빌드 | **release** |
| entries / empties / failures | **170 / 0 / 0** |
| meanLuma 범위 | 0.00149 ~ 0.86892 |
| 셀프체크 비결정 | 0종 (⚠️ 아래 경고) |
| 완전 검정 프레임 | 0장 |
| 캡처 | `rebaseline-golden.sh` · 커서 이동 후 재캡처 **상이 0종** |

**왜 다시 떴는가**: 2026-08-16 오후~밤의 결함 수정 9건이 의도적으로 픽셀을 바꿨다 —
파티클 오브젝트 scale(위치에만 곱한다) · 가시성 전파에 파티클 포함 · `thisLayer.play/pause/stop` ·
`angles` 스크립트 단위(도) · 3D 카메라를 카메라 오브젝트로 · 레거시 레인 스페큘러 제거 ·
DIRECTDRAW 알파 이중 곱 제거. 근거는 각 커밋과 `docs/we-parity-2026-08-16.md` 에 있다.

### ⚠️ `3706286085` 은 이 기준선에서 `deterministic=true` 로 박혔지만 실제로는 아니다

이 씬은 **3D 메시 mip LOD 보간**이 제출마다 재현되지 않아 간헐적으로 1~2픽셀이 ±1~3 흔들린다
(`spec/golden/nondeterminism.json` → `oracle.nondet.meshMipLodResidual`). 규명 근거:
같은 프로세스·같은 마운트에서 20회 재렌더해도 갈리고, CPU 입력(유니폼·정점·인덱스·텍스처 전 mip·
섀도우 아틀라스·**깊이 버퍼 전체**)은 비트동일하며, 서브메시 37·38 을 **각각 단독**으로 그리면
39/39 동일한데 **둘을 같이 그리면 35/39 가 상이**하다. `mip_filter::nearest` 로 바꾸면 16렌더 전부
비트동일해진다.

즉 셀프체크가 `selfMaxDiff` 를 0 으로 기록할 확률이 절반쯤이고, **이 기준선은 그 절반에 걸린
캡처다.** 따라서 `golden-gate.sh` 가 이 씬 하나를 `mean≈0.0x max≤3` 으로 간헐 FAIL 시킬 수 있다.
**그건 회귀가 아니다** — `scripts/mac-session/probe-scene-repeat.sh` 로 반복 캡처해 확인하라.

임계를 낮추거나 이 씬을 게이트에서 빼는 것으로 해결하지 마라. 근본 해결은 mip 필터 규약을
WE 정본으로 확정하는 것이고, 그건 렌더 충실도 결정이라 별도 근거가 필요하다.

---

## `baseline-618d16f` — 이력(2026-08-16 1차, **HEAD 에 없음**)

판정은 이걸 기준으로 한다(`GoldenBaseline.currentLabel`). 아래 `baseline-81098bb` 는 이력이다.

**HEAD 에는 기준선을 둘만 둔다** — 현행 + 이식 전 이력. 그 사이의 중간 기준선
(`baseline-f3a17da` 포인터 핀 직후, `baseline-31fecaa` HDR 블룸 교체 직후)은 커밋 이력에
남아 있으므로 필요하면 거기서 꺼낸다(하나가 11MB 라 전부 쌓으면 리포가 비대해진다).

| 항목 | 값 |
| --- | --- |
| gitSHA | `618d16f` (main, Sources 청결) |
| 빌드 | **release** |
| entries / empties / failures | **170 / 0 / 0** |
| meanLuma 범위 | 0.00149 ~ 0.86892 |
| 셀프체크 비결정 | **0종** |
| 완전 검정 프레임 | 0장 |
| 캡처 | `scripts/mac-session/rebaseline-golden.sh` · 각 217s / 204s · **커서 이동 후 재캡처 상이 0종** |

⚠️ **`3706286085` 은 이 기준선에서도 잔여 비결정이 있다 — 상이 0종은 간헐성 덕에 운이 좋았던 것이다.**
실행마다 50~80% 확률로 1~14 픽셀(채널당 최대 3)이 갈린다. 원인은 3D 메시 패스의 mip 보간이고
정렬·핀·클리어로 고칠 수 있는 것이 아니다 — 전문은 `spec/golden/nondeterminism.json` →
`oracle.nondet.meshMipLodResidual`, 재현은 `scripts/mac-session/probe-scene-repeat.sh`.
이 씬의 strict 불일치 1건은 회귀 판정에서 그렇게 읽어야 한다.

**왜 다시 떴는가**: `c69f93c`(MDLV 인덱스 폭이 정점 수를 따르게 한 수정) 때문이다. 종전 기준선
`31fecaa` 는 그 수정 **이전**이라, u32 인덱스 메시를 가진 씬 2종에 대해 **파괴 렌더를 기준으로
삼고 있었다**:

| 씬 | 종전 기준선(31fecaa) | 현재 |
| --- | --- | --- |
| `3589454154` | 陨石(정점 3,144,456)이 정점 0 을 향한 슬리버 부채꼴로 찢어져 있었다 | 깨끗한 소행성 실루엣 |
| `3706286085` | FBX3 스테이지가 없어 소닉만 있는 검은 화면 | 건물·간판·색이 있는 시가지 |

발견 경로가 이 리포의 교훈을 하나 담고 있다 — `WapleCompat --compare` 를 **처음으로 자동 경로에
배선한 그 실행에서** 이 2종이 잡혔다(`618d16f`, PASS 168 / FAIL 2, 3위 편차 mean 0.05). 게이트가
없던 동안에는 아무도 못 봤다. GT 테스트는 luma 절반 하락만 하드 실패라 **"없던 게 생긴" 쪽을
구조적으로 못 잡는다.**

`3706286085` 이 `oracle.nondet.unstableSet` 29종 안에 있는 것은 우연이다. 세션 잡음이 아니라
스테이지가 나타난 것임을 육안 대조가 보여준다.

---

## `baseline-31fecaa` — 이력(2026-08-02, **HEAD 에 없음**)

판정은 이걸 기준으로 한다(`GoldenBaseline.currentLabel`). 아래 `baseline-81098bb` 는 이력이다.

**HEAD 에는 기준선을 둘만 둔다** — 현행 + 이식 전 이력. 그 사이의 중간 기준선
(예: 포인터 핀 직후의 `baseline-f3a17da`)은 커밋 이력에 남아 있으므로 필요하면 거기서 꺼낸다
(하나가 11MB 라 전부 쌓으면 리포가 비대해진다).

| 항목 | 값 |
| --- | --- |
| gitSHA | `31fecaa` (feat/we-engine-port-design, Sources 청결) |
| 빌드 | **release** (아래 ① 참고 — 이식 전 기준선은 debug 였다) |
| entries / empties / failures | **170 / 0 / 0** |
| meanLuma 범위 | 0.00149 ~ 0.86892 |
| 셀프체크 비결정 | **0종** (이식 전 기준선의 유일한 비결정 3363252053 도 지금은 자기일관) |
| 완전 검정 프레임 | 0장 |
| activeDebugGates | `[]` |
| 캡처 | `scripts/mac-session/rebaseline-golden.sh` · 각 165초 |

**왜 다시 떴는가**: ① 캡처가 **실제 마우스 커서 위치**를 픽셀에 굽고 있었다 —
`mount` 가 마우스 모니터를 켜면 그 순간의 커서가 `g_PointerPosition` 으로 들어갔고, 그래서
세션이 갈리면 170종 중 29종이 다른 값을 냈다(`spec/golden/nondeterminism.json` →
`oracle.nondet.rootCause`). 포인터를 핀했다(f3a17da).
② 그 다음 **HDR 블룸 필터 체인을 WE 평문 구조로 교체**했다(31fecaa) — 9씬의 헤일로 모양이
바뀌었다(에너지 보존, meanLuma 배율 0.95~1.10). 이 기준선은 둘 다 반영한 상태다.

**설치 게이트**: 두 캡처를 뜨되 **사이에 커서를 옮기고**, 비트동일할 때만 설치한다.
이번 설치에서 상이 **0종**이었다(수정 전 같은 대조는 28~29종이었다). 재생성도 같은 스크립트로:

```bash
bash scripts/mac-session/rebaseline-golden.sh
```

## `baseline-81098bb` — 최초 기준선(이력)

WE 엔진 이식 작업(공유 에셋 동봉 + 유니폼 규약 교정)을 **시작하기 전** 상태다.

| 항목 | 값 |
| --- | --- |
| gitSHA | `81098bb` (main, 작업 트리 청결) |
| 캡처 시각 | `captureTime: 6` (고정) |
| entries / empties / failures | **170 / 0 / 0** |
| 완전 검정 프레임 | **0장** (PIL `getbbox()` · manifest `meanLuma==0` · 컨택트 시트 육안, 3중 확인) |
| meanLuma 범위 | 0.0021 ~ 0.8704 |
| 결정성 | 결정 **169** / 비결정 **1** |
| activeDebugGates | `[]` |
| 캡처 환경 | macOS, Apple M5, Swift 6.4 / Xcode 27.0 |
| 코퍼스 | scene.pkg **170종** |
| 소요 | **1,694초 (28.2분)** — **debug 빌드** |

## 읽을 때 반드시 알아야 할 것 셋

**① 이 기준선은 debug 빌드다.**
`docs/snapshot-regression.md` 의 기존 실측 ≈611초는 **release** 이고 구성도 달랐다
(146 캡처 + 24 empty). 이번은 debug + 170 캡처다. 씬당으로 보면 4.2s(release) vs
10.0s(debug)로 2.4배다. **시간을 비교할 때 빌드 구성을 맞춰야 한다.**

**② 비디오-백드 24종은 머신 간 재현이 보장되지 않는다.**
`empties: 0` 은 H1 수정 이후 비디오-백드 씬이 `entries` 에 처음 들어온 결과다. 이들은
AVFoundation 산출이라 다른 머신에서 `--compare` 하면 strict 불일치가 날 수 있다.
**그건 회귀가 아니라 예고된 현상이고, 대응은 lax 강등이다.**

**③ 비결정 씬 1종.**
`3363252053` — 파티클·광원이 많은 3D 씬. `selfMaxDiff=189`, self-diff mean 5.27 /
frac 0.1559 로 `deterministic:false` 로 기록됐다. 나머지 169종은 `selfMaxDiff=0`
(2회 재마운트 픽셀 완전 동일)이다. 이 씬은 회귀 판정에서 제외하거나 별도 임계를 쓴다.

## 재생성

```bash
export WAPLE_REAL_PKGS=<코퍼스>/backgrounds
export WAPLE_BASE_ASSETS=<코퍼스>/assets
swift run -c release WapleCompat --capture <출력디렉터리> --label <라벨> <코퍼스루트>
```

**macOS 는 GUI 로그인 세션 밖에서 Metal 을 주지 않는다.** SSH 로 돌리면 GPU 작업이
실패가 아니라 **조용히 스킵**된다. 반드시 `launchctl asuser $(id -u) ...` 로 감쌀 것.

코퍼스가 실제로 잡혔는지는 센티넬로 확인한다 — `TexVariantDecodeCorpusTests`(1건),
`PuppetBlendRealSceneTests`(2건). 스킵되면 코퍼스 미발견이다.

## 구성

```
baseline-81098bb/
├── manifest.json   씬별 hash · meanLuma · selfMaxDiff · deterministic (검증 계약)
├── thumbs/         170장 256×144 PNG (시각 diff 용)
└── sentinel.log    코퍼스 접근 확인 로그
```

`manifest.json` 이 **기계 검증의 계약**이고, `thumbs/` 는 사람이 무엇이 바뀌었는지
보기 위한 것이다. 캡처 전문 로그(2.9MB)는 커밋하지 않는다.
