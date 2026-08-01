# macOS 로 작업 이관 — 2026-08-01

이 문서는 **윈도우에서 하던 작업을 맥에서 이어받는 방법**만 담는다.
프로젝트 전반은 [AGENTS.md](../AGENTS.md), 할 일은 [BACKLOG.md](../BACKLOG.md),
확정된 사실은 [`spec/`](../spec) 이 정본이다.

## 왜 이관하는가

지금까지의 역할 분담이 이랬다.

| | 윈도우 | 맥 |
| --- | --- | --- |
| WE 설치본(셰이더·머티리얼·바이너리·로케일) | **있음** | 일부만 |
| 워크샵 코퍼스 | 50GB 전체(씬 162) | 큐레이션 170종 |
| Swift 툴체인 · Metal | **없음** | 있음 |
| 빌드 · 테스트 · 골든 캡처 | 불가 | 가능 |

측정 단계는 대부분 끝났고 지금은 **구현·검증 단계**다. 그 단계는 맥에서만 돌아간다.
윈도우에서만 되던 측정에 필요한 입력은 전부 합쳐 **약 14MB** 라 그냥 복사하면 된다.

## 1. 맥으로 복사할 것 (약 14MB)

`Z:\SteamLibrary\steamapps\common\wallpaper_engine\` 기준. 전부 **읽기 전용 참조**다.

| 경로 | 크기 | 왜 필요한가 |
| --- | --- | --- |
| `wallpaper64.exe` | 5.2MB | 문자열/기본값/심볼 측정. `measure_engine_symbols.py`, `measure_particle_fields.py` 등 |
| `locale/ui_en-us.json` | ~1MB | 에디터 UI 라벨. bit4 = "Perspective rendering" 판독 근거 |
| `ui/dist/monaco/autocomplete/lib.sceneScript.d.ts` | 420KB | **WE 배포 API 정의**. perspective 의미 확정 근거 |
| `assets/` | 81MB | 셰이더·머티리얼. 맥에 이미 있을 수 있음(아래 확인) |

맥에서 이렇게 배치하고 환경변수를 맞춘다:

```bash
mkdir -p ~/we-ref/ui/dist/monaco/autocomplete ~/we-ref/locale
# (위 4개를 같은 상대경로로 복사)
export WE_ROOT=~/we-ref
export WE_WORKSHOP=~/Downloads/wallpaper_dev/backgrounds
```

`assets/` 가 이미 있는지 확인:

```bash
ls ~/Downloads/wallpaper_dev/assets/shaders/hdr_downsample.frag \
   ~/Downloads/wallpaper_dev/assets/materials/util/hdr_upsample.json
# 둘 다 있으면 assets 복사 불필요 — WE_ROOT 를 그 상위로 잡으면 된다
```

**코퍼스는 옮기지 마라.** 50GB 고, 맥의 170종이 오히려 윈도우가 본 162종보다 넓다.
다만 두 표본이 **다르다**는 걸 기억할 것 — 아래 "함정" 참조.

## 2. 이미 git 에 있는 것 (복사 불필요)

- `spec/` — 정본 349확정 / 17보고 / 12추정. **여기 있는 건 근거와 함께 확정된 것이다.**
- `scripts/spec/` — 정본 생성기 18개. `python scripts/spec/validate.py` 로 무결성 검사.
- `scripts/mac-session/` — 검증 스크립트 3개(아래).
- `docs/` — 이력과 설계.

브랜치: `feat/we-engine-port-design` (HEAD `5c623ce`). 전부 푸시돼 있다.

## 3. 현재 상태 — 항목별

| 항목 | 도달 | 상태 |
| --- | --- | --- |
| 임베디드 PNG/JPEG mip 체인 | 146씬 | **완료·맥 검증됨**. 빌드/테스트/프로브/골든 전부 통과 |
| `_rt_imageLayerComposite_` 정적 치환 | 25씬 | **반증으로 닫음**. 가설 셋 전부 코퍼스로 사망. `doNotReopen` |
| 파티클 flags bit4 (원근 렌더) | 70씬 | 측정·의미 확정, **공식 미확정** → 미착수 |
| HDR 블룸 필터 모양 | 7씬 | WE 셰이더 대조 완료, **전체 교체 단위**로 미착수 |
| 캡처 비결정 | ? | **간헐적**. 1회 관측(29종) 후 통제 재현 실패(0/170) |
| 순백 클리핑 | 3씬 | 미착수 |
| 파티클 미읽기 필드 | 70씬 | 측정 완료, 미착수 |

### 즉시 할 수 있는 것

**(a) 비결정 판별 한 라운드** — 가장 먼저 할 일. 골든이 신뢰돼야 나머지 결과를 읽을 수 있다.

```bash
rm -rf ~/Downloads/waple-nondet
# runB 직전에 전 스위트를 끼워 부하를 준다(첫 관측 조건 재현)
bash scripts/mac-session/probe-nondeterminism.sh   # runA 만 뜬 뒤 중단해도 됨
swift test -c release                              # 부하
bash scripts/mac-session/probe-nondeterminism.sh   # runB
```
29 가 재등장하면 부하/상태 의존으로 확정된다. 안 나오면 첫 관측이 다른 조건이었다는 뜻이고,
그때는 첫 관측의 두 캡처가 정확히 무엇이었는지부터 되짚어야 한다.

**(b) 3394601417 GT 재베이스라인** — 비결정이 정리된 **뒤에**.
이 씬의 밝기 하락(0.194배)은 버그가 아니라 정답이다
(`spec/formats/tex-embedded-mips.json` → `format.tex.embedded.mipDarkeningIsAlphaCoverage`).
**게이트 문턱을 낮추지 마라** — 같은 문서의 `doNotWeakenGate`.

**(c) HDR 블룸 교체** — `spec/engine/hdr-bloom.json` 에 WE 구조와 차이 5건이 있다.
넓히는 오차(W1·W2)와 좁히는 오차(N1·N2)가 **상쇄되고 있어서** 하나씩 고치면 회귀한다.
필터 체인을 한 번에 갈고 재베이스라인하는 게 한 단위다(`doNotFixPiecemeal`).

## 4. 함정 — 이걸 모르면 검증했다고 착각한다

1. **코퍼스 표본이 두 개다.** 윈도우 162씬 ≠ 맥 170씬. `spec` 의 씬 ID 목록은
   윈도우 기준이라 맥에서 부분집합이 된다. 실제로 이것 때문에 정당한 변화 7종이
   "조사 대상" 으로 잘못 떴다. `verify-embedded-mips.sh` 는 이제 기대 집합을
   **실행 시점 코퍼스에서 산출**한다 — 새 스크립트를 쓸 때도 그렇게 할 것.

2. **커밋된 골든 기준선은 debug 캡처다.** release 와는 코드 변경 없이도 30종이 어긋난다.
   의도적 픽셀 변경을 대조하려면 **구현 전 release 기준선**을 따로 떠야 한다.

3. **셀프체크(`deterministic`)를 믿지 마라.** 2차 캡처가 같은 프로세스라
   프로세스 간 변동을 구조적으로 못 잡는다(`spec/golden/gate-analysis.json` →
   `oracle.gate.selfCheckIsIntraProcess`). 값이 0 이어도 "변동이 없다" 가 아니라
   "이 방법으로는 못 본다" 이다.

4. **`swift test` 가 전부 통과해도 코퍼스가 없으면 아무것도 검증 안 됐다.**
   실물 테스트는 코퍼스 부재 시 스스로 스킵하고, 스킵은 실패로 안 잡힌다.
   프로브의 `embedded=` 같은 **양성 대조 수치**를 반드시 함께 볼 것.

5. **`spec/` 에 없는 건 확정이 아니다.** 산문·커밋 메시지에만 있는 주장은 인계 과정에서
   사라진다. 새로 확정한 게 있으면 생성기를 만들어 `spec/` 에 착지시킬 것.

## 5. 윈도우가 계속 필요한 작업

`WE_ROOT` 를 복사해 가면 대부분 맥에서도 돌지만, 아래는 윈도우가 편하다:

- `resourcecompiler64.exe` 를 **실행**하는 측정(`measure_tex_deep.py --oracle`) — Wine 필요
- 50GB 전체 코퍼스를 대상으로 한 전수 스캔(맥은 170종만 보유)

둘 다 지금 당장 필요한 항목은 없다.
