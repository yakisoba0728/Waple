# 작업 인계 — 윈도우 → macOS (2026-08-01)

이 문서 하나로 **작업을 이어받을 수 있게** 쓴다. 프로젝트 전반은 [AGENTS.md](../AGENTS.md),
할 일 목록은 [BACKLOG.md](../BACKLOG.md), **확정된 사실은 [`spec/`](../spec) 이 정본**이다.

브랜치 `feat/we-engine-port-design`. 전부 푸시돼 있고 작업 트리는 깨끗하다.

---

## 0. 맥에 앉자마자 붙여넣을 프롬프트

```
~/Desktop/Waple 에서 feat/we-engine-port-design 브랜치를 pull 하고
docs/mac-handoff-2026-08-01.md 를 처음부터 끝까지 읽어줘.
읽고 나서 §4 "다음 작업" 의 (a) 비결정 판별부터 시작한다.
확정 사실은 spec/ 이 정본이고, 산문이나 커밋 메시지를 근거로 삼지 마라.
```

---

## 1. 왜 옮기는가 · 무엇을 옮기는가

역할 분담이 이랬다.

| | 윈도우 | 맥 |
| --- | --- | --- |
| WE 설치본(셰이더·머티리얼·바이너리·로케일·API 정의) | **있음** | 일부만 |
| 워크샵 코퍼스 | 50GB 전체(씬 162) | 큐레이션 170종 |
| Swift 툴체인 · Metal | **없음** | 있음 |
| 빌드 · 테스트 · 골든 캡처 | 불가 | 가능 |

측정 단계는 대부분 끝났고 지금은 **구현·검증 단계**다. 그건 맥에서만 돌아간다.
윈도우에서만 되던 측정에 필요한 입력은 합쳐 **약 14MB** 뿐이다.

### 복사할 것

`Z:\SteamLibrary\steamapps\common\wallpaper_engine\` 기준. 전부 읽기 전용 참조다.

| 경로 | 크기 | 왜 필요한가 |
| --- | --- | --- |
| `wallpaper64.exe` | 5.2MB | 문자열·기본값·심볼 측정 (`scripts/re/`, `measure_*`) |
| `locale/ui_en-us.json` | ~1MB | 에디터 UI 라벨 3,332개 |
| `ui/dist/monaco/autocomplete/lib.sceneScript.d.ts` | 420KB | **WE 배포 API 정의** — 속성 의미 설명이 들어 있다 |
| `assets/` | 81MB | 셰이더·머티리얼. 맥에 이미 있을 수 있음(아래 확인) |

**GitHub 를 경유하지 마라.** `wallpaper64.exe` 는 유료 상용 제품의 실행 파일이고 이 리포는
공개다. Tailscale `scp` 같은 직접 전송을 쓸 것.

```bash
mkdir -p ~/we-ref/ui/dist/monaco/autocomplete ~/we-ref/locale
# scp 로 위 4개를 같은 상대경로에 배치
export WE_ROOT=~/we-ref
export WE_WORKSHOP=~/Downloads/wallpaper_dev/backgrounds
```

`assets/` 가 이미 있는지 확인 — 있으면 복사 불필요:

```bash
ls ~/Downloads/wallpaper_dev/assets/shaders/hdr_downsample.frag \
   ~/Downloads/wallpaper_dev/assets/materials/util/hdr_upsample.json
```

**코퍼스 50GB 는 옮기지 마라.** 맥의 170종이 윈도우가 본 162종보다 오히려 넓다.
다만 두 표본이 **다르다** — §5 함정 1 참조.

---

## 2. 작업 방식 — 이걸 안 지키면 같은 실수를 반복한다

이 저장소는 `spec/` 을 정본으로 쓴다(현재 확정 349 / 보고 17 / 추정 12, 오류 0).
규칙은 [`spec/README.md`](../spec/README.md) 에 있고, 실제로 지켜야 하는 건 이 셋이다.

1. **확정에는 재현 스크립트가 있어야 한다.** 근거가 스크래치패드 경로를 가리키면
   다른 사람이 재현할 수 없다 — 이번에 실제로 그런 항목이 하나 있었고 고쳤다.
   새로 확정하면 `scripts/spec/measure_*.py` 를 만들고 `validate.py` 를 통과시킬 것.

2. **부정 결론은 표본 설계를 먼저 검사한다**(`spec/README.md` 규칙 5).
   "X 가 없다" 는 결론은 **X 를 찾을 수 있는 표본이었는지** 먼저 확인해야 한다.
   그래서 측정 스크립트마다 **양성 대조**를 넣는다 — 예: 임베디드 텍스처를 0개 찾으면
   "저장 mip 이 없다" 가 아니라 "필터가 깨졌다" 로 판정하고 즉시 실패한다.

3. **오라클을 강화했으면 일부러 깨뜨려 잡히는지 확인한다.**
   이 저장소에서 안전망이 조용히 무력했던 사건이 여러 번이다.

---

## 3. 이번 세션에서 확정/반증/정정한 것

인계에서 가장 잘 사라지는 게 **"안 해도 되는 일" 과 "내가 틀렸던 것"** 이라 먼저 적는다.

### 완료 — 임베디드 PNG/JPEG mip 체인 (146씬)

`TexImage.parse` 가 `.embeddedImage` 분기에서 **이미 파싱한 mip 체인을 버리고** 있었다.
근거는 "인코딩 이미지는 저장 mip 이 없다" 는 **거짓 전제 주석**이었다.

코퍼스 4,991개 전수: 임베디드 796개 중 **701개가 mipCount>1**, level>0 페이로드
2,432개 전부 시그니처 정상 + 치수가 정확히 `(imgW>>L, imgH>>L)`, 불일치 0.

맥 검증 통과 — 빌드 OK, 프로브 `embedded=728 / failures=0`, 골든은 기대 집합 안에서만 변화.
**이 항목은 끝났다.**

### 반증으로 닫음 — `_rt_imageLayerComposite_` 흰 삼각형 (25씬)

가설 셋을 세우고 셋 다 코퍼스로 죽었다(참조 미해결 / 가시성 카브아웃 / 좌표계 불일치).
2902406982 은 소비자·소스가 **둘 다 1000×1000** 이고 소스에 이펙트가 0개다.
정적 치환을 고쳐도 흰 삼각형은 안 없어진다. `spec/engine/composite-refs.json` 에
`doNotReopen` 을 박았다 — **다시 열려면 화면 근거를 먼저 가져올 것.**

### 재구성됨 — 파티클 "기본값 테이블" → flags bit4 (70씬)

인계 산문이 "기본값 테이블 부재로 최대 114씬" 이라고 했는데 **문제의 모양이 달랐다**.
위험이 두 갈래인데 산문이 섞고 있었다:

- Waple 이 **안 읽는** 필드 → 위험 크기 = **명시된** 인스턴스 수
- `?? X` 로 읽는 필드 → 위험 크기 = **생략된** 인스턴스 수

생략률로 한 줄에 세우면 앞엣것이 뒤집힌다(안 읽는 필드는 생략이 많을수록 안전하다).
다시 세어 보니 최대 갭은 기본값이 아니라 **시스템 `flags` bit4**(70씬 저작, 파스만 하고 미소비)였고,
가장 생략이 잦은 `exponent` 는 **현재 값이 맞다**.

bit4 의미도 갈렸다 — 셰이더에 z 기반 크기 항이 **없고**, WE 배포 API 정의가
"perspective rendering instead of flat rendering, **including in 2D scenes**" 라고 적어 뒀다.
즉 **크기 공식이 아니라 투영 교체**다. FOV 출처는 `general.perspectiveoverridefov`.

**남은 미지수**: 카메라 eye 거리 규약, `perspectiveoverridefov` 부재 시 기본값(bit4 씬 5종 해당).
`spec/engine/particle-fields.json` 에 `doNotGuessFormula` 를 박았다.

### 대조 완료 — HDR 블룸 (7씬)

WE 가 블룸 셰이더를 평문 배포해서 RE 도 캡처도 필요 없었다.
임계 수식과 파라미터 기본값(scatter 1.619 · feather 0.1 · threshold 1.0 · strength 2.0 ·
iterations 8)은 **Waple 이 맞다**. 갈리는 건 **필터 모양**이고 오차 부호가 반대다 —
W1·W2 는 넓히고 N1·N2 는 좁혀서 서로 상쇄되고 있다.
`spec/engine/hdr-bloom.json`, `doNotFixPiecemeal`.

### 내가 정본에 틀리게 적었다가 고친 것 두 건

- **"임계 극성이 반대다"** → 틀렸다. `SnapshotCompare.swift:85` 의
  `deterministic ? .strict : .lax` 는 **설계대로 맞다**. 결함은 극성이 아니라 **분류**다.
  그 문장을 믿고 그 줄을 뒤집으면 정상 동작을 깨뜨린다.
- **"비결정 29종"** → 통제 재현 실패(0/170). 수치를 철회했다. 아래 참조.

---

## 4. 다음 작업 — 이 순서로

### (a) 비결정 판별 — **끝났다(2026-08-01 심야)**

정본: [`spec/golden/nondeterminism.json`](../spec/golden/nondeterminism.json).
재현: `python scripts/spec/measure_nondeterminism.py`(커밋된 매니페스트 8개로 재계산) ·
`bash scripts/mac-session/probe-session-nondeterminism.sh`(다시 떠서 축을 재확인, ~12분).

결론: 축이 "실행 간" 이 아니라 **"세션 간"** 이었다.

- **같은 세션 안에서는 완전히 재현된다** — 전 코퍼스 3회, 단건 반복, 사이에 전 코퍼스 캡처를
  끼워도 전부 비트동일. 그래서 **한 세션 안에서 뜬 A/B 대조는 신뢰할 수 있다.**
- **세션이 갈리면 29종이 갈린다.** 네 세션 대조에서 정확히 29종, 그중 17종은 네 값이 전부 다르다.
  전부 임베디드-mip 수정 영향권(123종) 안이고 정렬 인덱스 49 이상이다. 씬 목록은 정본에 있다.
- **발산은 첫 프레임(t=0)에 이미 있다** — 연속한 두 상태(D·E)에서 29종을
  `WAPLE_CAPTURE_TIME=0,0.1,1,6` 으로 떠 보니 t=0 에서 26/29 가 다르다. 즉 파티클·스크립트
  누적이 아니라 **마운트/로드된 것 자체**가 세션마다 다르다. 게다가 두 상태의 로드 NSLog 는
  **한 줄도 다르지 않다** — "무엇을 로드했나" 가 아니라 "로드된 결과" 가 갈린다.
- **원인: 캡처가 실제 마우스 커서 위치를 픽셀에 굽는다**(`oracle.nondet.rootCause`, `확정`).
  `SceneRenderer.mount` 는 `parallaxEnabled || hasEffects` 면 마우스 모니터를 켜고, 그 콜백이
  `pointerUV`(→ 이펙트 유니폼 `g_PointerPosition`)를 라이브 커서로 채운다.
  `SnapshotPipeline.pinRenderSettings` 는 시각·오디오·난수·fitMode·베이스에셋은 핀하는데
  **포인터는 안 핀한다.** 커서만 옮겨 가며 같은 씬을 뜨면 위치마다 다른 해시가 나오고,
  같은 위치로 돌아오면 그 값이 그대로 재현된다(`scripts/mac-session/probe-pointer-uniform.sh`).
  1포인트 차이도 값을 바꾼다. "상태가 30분~1시간마다 바뀐다" 는 것의 정체는 **사람이 마우스를
  건드린 것**이고, "상태 F 가 어제 상태 C 와 29종 전부 비트동일" 은 커서가 같은 자리로 돌아온 것이다.
- 배제된 것(전부 실측): 임베디드 mip 수정 자체·Metal 셰이더 캐시·부하 개입·단건 대 순차·
  TZ·CWD·바이너리 동일성·디스크 입력·절전/재부팅.
- **수정 완료(2026-08-02)**: `SceneRenderer.capturePointerUV` 를 두면 마우스 모니터를 아예 켜지
  않고 포인터를 그 값으로 고정한다. 스냅샷 파이프라인과 GT 하네스가 중앙(0.5,0.5)으로 핀한다.
  **기동 지점이 셋이라 한 곳만 막으면 샌다** — 첫 수정 후에도 커서 의존이 그대로였고, 새던 곳은
  mount 의 두 번째 게이트(cursorMove·호버)였다. 지금은 `startPointerMonitor()` 로 모았고
  `updateParallax` 에도 이중 안전망이 있다. 검증: 커서 네 위치 전부 같은 해시
  (수정 전엔 위치마다 달랐다) + 유닛 회귀 `CapturePointerPinTests`(핀 분기를 지우면 깨지는 것까지 확인).

반증된 것(위 문서 이전 판이 적어 뒀던 것): 부하/씬 간 상태 누수 가설과
`probe → swift test → probe` 판별 실험. 그 배치는 축이 어긋난다 — 게다가
`probe-nondeterminism.sh` 는 한 번 호출에 runA·runB 를 **둘 다** 떠서 부하가 사이에 끼지 않는다.

구조적 사실은 그대로다: 셀프체크가 2차 캡처를 **같은 프로세스**에서 떠서 이 변동을
**측정할 수 없다**(`spec/golden/gate-analysis.json` → `oracle.gate.selfCheckIsIntraProcess`).
고치려면 2차 캡처를 별도 프로세스로 돌리거나 교차 실행 재현성을 별도 필드로 둔다.

### (b) `3394601417` GT 재베이스라인 ← **여기서 시작**

이 씬의 밝기 하락(0.0600 → 0.0116, 0.194배)은 **버그가 아니다.**
WE 자신의 저장 mip 이 원래 그렇다 — 코퍼스 140개 텍스처 측정에서 순수 색은 중앙 0.99 로
유지되고 **알파(커버리지)만** 떨어진다(최저 0.038, 절반 아래 하락의 주도 요인 알파 11 · 색 0).
투명 배경 위 가는 밝은 선을 축소하면 커버리지가 평균되는 것 — 밉맵의 정의다.

```bash
python scripts/spec/measure_mip_luma.py --scene 3394601417   # 레벨별 알파/색 확인
```

**게이트 문턱을 낮추지 마라**(`doNotWeakenGate`). 게이트는 제 일을 했고, 대응은 재베이스라인이다.

(a) 가 이 항목의 선행이었는데 **해제됐다**: `3394601417` 은 불안정 29종에 **없다**.
다만 새 기준선은 어차피 다음 세션부터 세션 간 대조가 되므로, 29종은 새 기준선에서도
잡음으로 남는다 — 재베이스라인이 그걸 만드는 게 아니라 이미 있는 것이다.

### (c) HDR 블룸 필터 교체 — 한 단위로

`spec/engine/hdr-bloom.json` 에 WE 구조와 차이 5건(W1·W2·N1·N2·S1)이 있다.
**하나씩 고치면 회귀한다** — 넓히는 오차와 좁히는 오차가 상쇄되고 있어서, blur13 만 빼면
WE 보다 훨씬 뾰족해지고 합성 4탭만 더하면 더 번진다.
필터 체인 전체 교체 + 재베이스라인이 한 커밋 단위다.

### 이후 후보

파티클 bit4 구현(공식 확정 선행) · 순백 클리핑 3씬 · 파티클 미읽기 필드 29종/187건/70씬.

---

## 5. 함정 — 이걸 모르면 검증했다고 착각한다

1. **코퍼스 표본이 두 개다.** 윈도우 162 ≠ 맥 170. `spec` 의 씬 ID 목록은 윈도우 기준이라
   맥에서 부분집합이 된다. 실제로 이것 때문에 **정당한 변화 7종이 "조사 대상" 으로 잘못 떴다.**
   `verify-embedded-mips.sh` 는 이제 기대 집합을 **실행 시점 코퍼스에서 산출**한다.
   새 스크립트도 그렇게 할 것.

2. **커밋된 골든 기준선은 debug 캡처다.** release 와는 코드 변경 없이도 30종이 어긋난다.
   의도적 픽셀 변경을 대조하려면 **구현 전 release 기준선**을 따로 떠야 한다.

3. **셀프체크(`deterministic`)를 믿지 마라.** 0 이어도 "변동 없음" 이 아니라
   "이 방법으로는 못 본다" 이다. 실제로 못 보는 분량이 재어져 있다 — **세션 간 29종**.

7. **세션을 건너뛴 캡처 대조에는 29종의 잡음이 섞인다**(`spec/golden/nondeterminism.json`).
   같은 세션 안에서 뜬 A/B 는 안전하다. 구현 전후를 비교할 거면 **한 세션 안에서 둘 다 떠라.**

8. **`WAPLE_CAPTURE_TIME` 을 여러 개 주면 t=6 프레임이 단독 캡처와 달라진다** — 캡처 루프가
   프레임 간 스크립트/파티클 연속성을 유지하기 때문이다(의도된 설계). 진단 프레임은 같은
   `WAPLE_CAPTURE_TIME` 끼리만 비교할 것. 덤으로 부가 프레임 파일명이 `%.1f` 라
   `0` 과 `0.033` 이 같은 파일로 충돌한다.

4. **`swift test` 전부 통과 ≠ 검증됨.** 실물 테스트는 코퍼스 부재 시 스스로 스킵하고
   스킵은 실패로 안 잡힌다. 프로브의 `embedded=` 같은 **양성 대조 수치**를 반드시 함께 볼 것.

5. **`spec/` 에 없는 건 확정이 아니다.** 산문·커밋 메시지에만 있는 주장은 인계에서 사라진다.

6. **테스트 수 기준값은 2,143**(코퍼스 있음, 2026-08-01 실측). **번들 합**으로 세야 한다 —
   클래스 단위 소계까지 더하면 6,000대로 부풀어 무의미해진다.

---

## 6. 도구 지도

| 위치 | 용도 |
| --- | --- |
| `scripts/spec/measure_*.py` | 정본 생성기·측정 도구 23개 → 정본 문서 28개(`spec/**/*.json`) |
| `scripts/spec/validate.py` | 정본 무결성(근거 유무·상호 참조·헤지 표현) 검사 |
| `scripts/re/xref.py` · `disasm.py` | exe 정적 분석. 함정은 [README](../scripts/re/README.md) |
| `scripts/mac-session/*.sh` | 검증·프로브 스크립트 3개 |

**RE 는 마지막 수단이다.** WE 는 아래를 평문 배포하고 그게 디스어셈보다 나은 1차 출처다 —
파티클 bit4 도 결국 이쪽으로 갈렸다.

| 위치 | 담긴 것 |
| --- | --- |
| `assets/shaders/*.frag,.vert,.h` | 픽셀 수식 전문(블룸 피라미드·파티클 정점·PBR) |
| `assets/materials/util/*.json` | 패스 콤보·블렌딩 규약 |
| `ui/dist/monaco/autocomplete/lib.sceneScript.d.ts` | WE 배포 API 정의 |
| `locale/ui_en-us.json` | 에디터 UI 라벨 |
| `assets/presets/**/*.json` | WE 팀 저작물 — A/B 대조군으로 쓸 수 있다 |

---

## 7. 윈도우가 계속 필요한 것

- `resourcecompiler64.exe` 를 **실행**하는 측정(`measure_tex_deep.py --oracle`) — 맥은 Wine 필요
- 50GB 전체 코퍼스 전수 스캔(맥은 170종만 보유)

둘 다 지금 대기 중인 항목엔 없다.
