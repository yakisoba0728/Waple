# 레인 3 — 파티클 시뮬레이션 (PR #8 `b883386e` 검증)

대상: `Sources/WapleCore/ParticleSimulator.swift`(+586) · `ParticleSystem.swift`(±231) ·
`ParticleControlPointFrame.swift` · `Sources/WapleRender/ParticleShaders.swift`
읽기 전용 · 빌드 없음. 코퍼스 계수는 전부 리포 동봉본
(`Sources/WapleRender/Resources/WEAssets/**/*.json`, 1,698 파일)에서 직접 셌다.

---

## 1. 최우선 임무 판정 — H3 / H4

### ✅ H3 (`alphafade.fadeouttime`) — **완전히 고쳐졌다. 경계값도 옳다.**

- 자리: `Sources/WapleCore/ParticleSimulator.swift:2482-2491`
- 재현: `git show b883386e -- Sources/WapleCore/ParticleSimulator.swift | grep -n -A12 'func fadeFactor'`
- 정본 대조: `AUDIT-FULL-2026-08-31.md:474-540` 이 디스어셈블에서 유도한 식은
  `f = (t < fin) ? t/fin : (fout < t) ? (1-t)/(1-fout) : 1`.
  새 코드는 **분기 순서까지 그대로**다(fade-in 우선 → fade-out → 1).
- 경계값 전수(`n`은 `ParticleSimulator.swift:1783`의 `p.lifetime > 0 ? min(1, age/lifetime) : 1`
  이라 항상 `[0,1]`):

  | 케이스 | 결과 | 판정 |
  | --- | --- | --- |
  | `fout = 0` | `0 < n` → `(1-n)/1` = 수명 전체 선형 페이드 | WE 와 동일(시작점 0) ✅ |
  | `fout = 1` | `1 < n` 거짓 → 항상 1 | WE 도 `cmpltps` 가 거짓이라 1 ✅ |
  | `fout > 1`(수명 초과) | 항상 1 | ✅ |
  | `fin = 0` | `n < 0` 거짓 → 첫 분기 미진입 | ✅ |
  | `fin > fout`(겹침) | `n < fin` 구간에서 fade-in 이 승 | 정본 3분기 select 순서와 일치 ✅ |
  | `fout` 부재(기본 0.5) | 구식과 수치 동일 | 회귀 0 ✅ |
  | 수명 0/음수 | `n = 1` → `fout < 1` → 0 | 구식과 동일 ✅ |
  | 0 분모 | **없음**. `n/fin` 은 `n < fin` 이 `fin > n ≥ 0` 을 보장, `1-fout` 은 `fout < n ≤ 1` 이 `fout < 1` 을 보장 | ✅ |

- `t < fadeout` 구간 알파 1 확인: `fin ≤ n ≤ fout` 이면 `return 1` — 정본 표
  (`fin=0.2, fout=0.8` 에서 t=0.5·0.7 → 1.000)와 일치.
- 도수 재측정(내가 다시 셈): 동봉 코퍼스 `alphafade` **250** · `fadeouttime` 부재 **138** ·
  명시 ≠0.5 **110** — 정본 250/110/138 과 **전건 일치**. M13/M10 부류 재발 없음.

### ⚠️ H4 (oscillate 진폭 난수) — **size·alpha 는 정확히 고쳤다. 그러나 "3종/61건 전건"은 사실이 아니다.**

- 고친 자리: `ParticleSimulator.swift:1797`(size) · `:1816`(alpha)
  → `smin + p.sharedRandom * (smax - smin) * osc01`, `osc01 = 0.5*(1+sin θ)`.
  `AUDIT-FULL-2026-08-31.md:558-585` 가 `0x14024123a`–`0x140241381` 에서 유도한
  `factor = scalemin + r·(scalemax−scalemin)·0.5·(1+sin)` 과 **항 단위로 동일**. ✅
- **난수 안정성 — 문제 없다(질문 2 의 답).** 난수는 `SplitMix64` 를 파티클 id 로 재유도하는
  방식이 **아니라**, 스폰 시 1회 뽑아 파티클에 저장한다: `ParticleSimulator.swift:1277`
  `p.sharedRandom = rng.nextFloat()`(무조건 실행, 이니셜라이저 디스패치 앞).
  `display(_:)`(`:1781`)는 **`mutating` 이 아니다** — `rng.nextFloat()` 는 mutating 이라
  이 경로에서 난수를 뽑는 것이 타입 수준에서 불가능하다. 그래서 진폭이 프레임마다 떨 수 없다.
  재현: `awk 'NR>=1780 && NR<=1860 && /rng\./ {print NR": "$0}' Sources/WapleCore/ParticleSimulator.swift` → 0건.
- **3종 중 하나(oscillateposition)는 이 PR 이 손대지 않았고, 손댈 필요도 없었다** —
  진폭 난수가 **PR 이전부터 이미 들어 있었다**:
  - 현재: `ParticleSimulator.swift:1303` `p.oscPosScale = lerp(o.smin, o.smax, r)`
  - PR 이전: `git show b883386e^:Sources/WapleCore/ParticleSimulator.swift | sed -n '1066p'` → **동일 코드**
  즉 `AUDIT-FULL-2026-08-31.md:576` 의 "`r` 이 **주파수·위상에만** 쓰이고 진폭에는 안 들어간다"
  는 size/alpha 에만 참이고 position 에는 **거짓**이다. → 아래 F3 참조.

---

## 2. 발견

### 🔴 F1 — 이미터 CP 평행이동이 자식 CP 피드와 겹쳐, 동봉 `thunderbolt` 체인의 자식이 **부모 위치를 두 번 더한다**

- 자리: `Sources/WapleCore/ParticleSimulator.swift:1219`(sphere) · `:1251`(box)
  `p.pos = s3(origin) + frame.translation + framedDisplacement`
  ↔ `:1262` `p.pos += emitOrigin`
  피드: `:965` `applyParentControlPointFeed(cpFeed, parentParticles: particles)`
  → `:984-996` `runtimeControlPoints[item.slot] = 부모 파티클 위치`
- 재현(리포 동봉 자산만으로 확정):
  ```
  python3 -c "import json;j=json.load(open('Sources/WapleRender/Resources/WEAssets/presets/lightning/particles/presets/thunderbolt.json'));print(j['children'][0]);print(j['emitter'])"
  # → {'type':'eventfollow','flags':1,'controlpointstartindex':None, 'name':'…/thunderbolt_child_spawner.json', …}
  python3 -c "import json;j=json.load(open('Sources/WapleRender/Resources/WEAssets/presets/lightning/particles/presets/thunderbolt_child_spawner.json'));print(j['emitter']);print(j['controlpoint'][0])"
  # → emitter: [{'name':'sphererandom','controlpoint' 키 없음 → CP0}]  ·  cp[0].flags = 0
  ```
  체인 추적:
  1. `stepChildren`(`:956-966`) — `type: eventfollow` 라 `insts[i].sim.emitOrigin = 부모 파티클 위치`.
  2. 같은 링크가 `flags: 1`(`feedsControlPoints`)이고 `controlpointstartindex: null → 0`.
     `ParticleControlPointFrame.swift:605-627` 의 `childControlPointFeed(startIndex: 0, …)` 가
     자식 CP0(flags 0 → `overrideBlockMask 0x10005` 통과)에 **부모 파티클 0번의 위치**를 넣는다.
     (자식 CP1 은 flags 4 = `parentAttached` 라 마스크에 걸려 slot 이 더 안 올라간다 → 피드는 1건.)
  3. spawner 의 유일한 이미터는 `controlpoint` 키가 없어 CP0 → `emitterControlPointFrame`(`:1179-1193`)
     이 `translation = runtimeControlPoints[0]` 를 **무조건** 더한다.
  4. 결과: `p.pos = 0 + thunderbolt.particles[0].pos + 0`, 그 뒤 `:1262` 가
     `+= 이 인스턴스의 부모 파티클 위치` → **부모 위치 2회 가산**, 게다가 3번은 인스턴스와
     무관한 **항상 0번 파티클**이다.
  PR 이전에는 `p.pos = origin + dir*dist` 뿐이라 `emitOrigin` 1회만 더해졌다(정상).
- 왜 문제인가: `thunderbolt` 는 CP1 이 `"0 -450 0"` 이고 파티클이 CP0–CP1 선분에 매핑되므로
  최대 450px 어긋난 자리에서 자식 spawner(그리고 그 밑 `thunderbolt_beam_child` 빔 전체)가
  방출된다. 동봉 프리셋 `presets/lightning`(+ `previewthunderbolt` 사본)이 눈에 띄게 깨진다.
  이미터 CP 배선 자체(6선언 도달)는 `controlpoint[0].offset` 이 코퍼스 **전건 0** 이라 무해한데,
  자식 CP 피드가 그 CP0 을 **런타임에 부모 위치로 덮으면서** 이미터 경로와 충돌한다.
- 기지 목록 대조: 해당 없음(PR #8 이 새로 심었다).

### 🟠 F2 — 부모 피드가 끊기면 `previousRuntimeControlPoints` 가 얼어붙어, `maintaindistancebetweencontrolpoints` 가 **매 프레임 파티클을 밀어낸다**

- 자리: `ParticleSimulator.swift:1024-1028`(`beginExternalControlPointUpdate`) ·
  `:621`(`updateControlPointPositionAnimations` 의 `guard … isEmpty else { return }` —
  **`capturePrevious` 보다 먼저 빠져나간다**) · `:879-914`(mdistBetween 일반형 분기)
- 재현/추적:
  - `previous` 를 갱신하는 자리는 둘뿐이다: (a) CP 위치 애니메이션이 **있을 때만** 도는
    `:622` 의 `if capturePrevious`, (b) 외부 CP 쓰기가 **있을 때만** 도는 `:1024`.
  - `applyParentControlPointFeed`(`:987`)는 `guard !feed.isEmpty else { return }` 로
    피드가 비면 (b)를 호출하지 않는다. `childControlPointFeed` 는 부모 파티클이 0이면 `[]` 다
    (`ParticleControlPointFrame.swift:612` `while particle < parentLifetimes.count`).
  - 동봉 도달: `thunderbolt_child_spawner` → `thunderbolt_beam_child`(`flags:1`,
    `controlpointstartindex:1`). beam_child 는 `maintaindistancebetweencontrolpoints` 를 갖고
    CP 애니메이션도 `parentAttached`(flags 4) CP도 **없다**. spawner 의 이미터는
    `instantaneous:1, rate:0` 이라 버스트 1개뿐 — 그 파티클이 죽으면 피드가 영구히 빈다.
  - 그 시점부터 `previous ≠ current` 가 고정되어 일반형이 매 프레임 재적용된다. 수치 확인:
    ```
    a=(0,0,0) b=(100,50,0)  ap=(0,0,0) bp=(90,40,0)   # 얼어붙은 직전 선분
    p0=(50,25,0) (현재 선분 위)  →  1프레임: (55.7,30.7,0) … 20프레임: (62.5,134.5,0)
    ```
    (`pos = a + frac·len·u + perp`, `perp` 는 낡은 `prevU` 기준이라 멱등이 아니다.)
    60fps 기준 초당 ~280px 씩 **선분 밖으로** 밀린다 — 이 오퍼레이터의 목적(선분 안 구속)의 정반대.
- 왜 문제인가: 자식 시스템이 부모보다 오래 사는 흔한 배치에서 파티클이 화면 밖으로 발산한다.
  `previous` 를 매 `_step` 시작에 **무조건** 캡처했다면(= `:621` guard 를 `capturePrevious`
  뒤로 옮기거나 `_step` 에서 직접 캡처) 발생하지 않는다.
- 기지 목록 대조: 해당 없음(PR #8 이 새로 심었다).
- 주의: `previous`/`current` 가 같은 정적 CP 시스템은 `:895-899` 축약형 fast path 로 빠져
  **PR 이전과 비트 동일**이다 — 회귀는 피드/애니메이션이 켜진 시스템에 한정된다.

### 🟡 F3 — 정본 `AUDIT-FULL-2026-08-31.md` 의 H4 도달 "61건 전건"이 17건 과장이고, PR #8 은 44건만 고치고 그 차이를 기록하지 않았다

- 자리: `AUDIT-FULL-2026-08-31.md:558-585`(특히 `:576`, `:581-585`) ↔
  `ParticleSimulator.swift:1303` · `:1797` · `:1816`
- 재현:
  ```
  git show b883386e^:Sources/WapleCore/ParticleSimulator.swift | sed -n '1066p'
  #   p.oscPosScale = lerp(o.smin, o.smax, r)      ← PR 이전에도 r 이 진폭에 있었다
  git show b883386e -- Sources/WapleCore/ParticleSimulator.swift | grep -c 'oscPosScale'   # → 0 (미변경)
  ```
  동봉 코퍼스 계수(직접 셈): oscillatealpha **36** · oscillatesize **8** · oscillateposition **17** = 61.
  이 PR 이 실제로 바꾼 것은 36+8 = **44** 이고, 나머지 17 은 **원래 결함이 아니었다**.
- 부수 모순: 두 RE 독해가 트리 안에서 충돌한다.
  - `AUDIT-FULL:586-588` — "alpha·position 변종은 **같은 구조의 형제 핸들러**"(= `smin + r·span·0.5·(1+sin)`)
  - `ParticleSimulator.swift:1991-1995` — position 핸들러는 `scale·(sinθ(t)−sinθ(t−dt))` 를
    **누적**한다(`subps xmm6,[rbp+0xf0]`@0x140240595 · `addps`@0x140240775) → DC 오프셋 없음
  둘은 동시에 참일 수 없는데, PR #8 은 size/alpha 만 전자로 옮기고 후자를 남긴 채
  어느 쪽 주석에도 이 충돌을 적지 않았다.
- 왜 문제인가: 다음 라운드가 "H4 는 61건 전건 해결" 로 읽고 넘어가면, position 이
  형제와 다른 수식 위에 있다는 사실이 계속 묻힌다(H3 이 6개월 묻혔던 것과 같은 구조).
- 기지 목록 대조: H4 의 **정정**(재보고 아님).

### 🟡 F4 — `Initializer.mapSequence` 주석의 "`flags & 1` 은 **10선언**" 이 실측 **8**과 다르다 (PR #8 이 그 줄을 고치면서 남겼다)

- 자리: `Sources/WapleCore/ParticleSystem.swift:191`(도수) · `:189-190`(대조 근거)
  (`git show b883386e -- Sources/WapleCore/ParticleSystem.swift` 에서 이 hunk 를 손봤다)
- 재현:
  ```
  python3 - <<'PY'
  import json,glob,collections
  c=collections.Counter()
  for p in glob.glob("Sources/WapleRender/Resources/WEAssets/**/*.json",recursive=True):
      try: j=json.load(open(p,encoding='utf-8-sig'))
      except Exception: continue
      if not isinstance(j,dict): continue
      for i in (j.get("initializer") or []):
          if i.get("name")=="mapsequencebetweencontrolpoints": c[str(i.get("flags"))]+=1
  print(dict(c))   # {'7':3,'4':2,'None':2,'15':2,'19':1,'23':1,'3':1}  합 12
  PY
  ```
  `flags & 4` = 7×3 + 4×2 + 15×2 + 23×1 = **8** ✅(주석과 일치)
  `flags & 1` = 7×3 + 15×2 + 19×1 + 23×1 + 3×1 = **8** ❌(주석은 10)
  같은 주석이 인용하는 저작 분포 `4×2 · 7×3 · 3×1 · 15×2 · 23×1 · 19×1` 의 합이 정확히 **10**이다 —
  "flags 를 저작한 선언 수 10" 을 "flags&1 인 선언 수" 로 옮겨 적은 것으로 보인다.
  `flags` 부재 기본은 0 이다(`ParticleSystem.swift:2313` `injectedInt(i, "flags", 0)`),
  그러니 부재 2건을 1 로 세는 경로도 없다 — 공교롭게 같은 주석이 경고하는 **함정 16**
  ("인접 `lea` 로 귀속하면 기본이 1 로 잘못 읽힌다")과 같은 종류의 실수다.
- 기지 목록 대조: 해당 없음(M13 "낡은 도수" 와 같은 부류의 신규 건).

### 🟡 F5 — M10(주석의 줄번호 드리프트) 재발 — PR #8 이 파일을 +586줄 밀면서 4건을 그대로 뒀다

| 인용 자리 | 주석이 가리키는 줄 | 실제 자리 |
| --- | --- | --- |
| `ParticleSimulator.swift:911`, `:915` | "선형 movement(위 **280-283행**)" | 선형 movement 적분은 **764-770** |
| `ParticleSimulator.swift:1856-1857` | "`_step` **291행** · `spawn` **404행**" | 각각 **926** · **1333** |
| `ParticleSimulator.swift:532` | "`SceneRenderer3D:1096` / `SceneRenderer:1451`" | `step(0)` 재방출은 **SceneRenderer3D:2409** · **SceneRenderer:2886** |
| `ParticleSystem.swift:2323` | "`ParticleSimulator:1437` 의 `for _ in 0..<octaves`" | **1754** |

- 재현: `sed -n '280,283p;764,770p' Sources/WapleCore/ParticleSimulator.swift` ·
  `grep -n "for _ in 0..<octaves" Sources/WapleCore/ParticleSimulator.swift` ·
  `grep -n "step(0)" Sources/WapleRender/SceneRenderer*.swift`
- 앞의 둘은 PR 이전에도 이미 밀려 있었고(`git show b883386e^:… | sed -n '801p;1538p'`),
  PR #8 이 그 주변을 편집하면서 더 벌렸다.
- 기지 목록 대조: **M10 의 재발**.

### ⚪ F6 — `applyMapSequenceAround` 의 "RNG 소비 길이가 계약"이라는 주석과 코드가 어긋난다

- 자리: `ParticleSimulator.swift:1552-1562`
  ```swift
  guard mapSequenceAroundSolvers.indices.contains(index),
        def.mapSequenceAround.indices.contains(index) else { return }   // ← 드로 전에 return
  guard runtimeControlPoints.indices.contains(spec.controlPoint) else { return }
  // 원본 호출 순서가 z → x → y다. speed가 전부 0이어도 세 호출은 생략하지 않는다.
  // … 소비 길이가 계약이다.
  let randomZ = rng.nextFloat() …
  ```
  가드가 걸리면 3드로가 **통째로 생략**돼 "소비 길이 계약"이 깨진다. 파서 산출 def 에서는
  `mapSeqClampCP` 가 항상 0..7 을 주므로 실무 도달은 0 — 그래서 ⚪(주석/코드 불일치)로만 올린다.

### ⚪ F7 — `fadeFactor` 의 두 내부 가드는 도달 불가(사문)

- 자리: `ParticleSimulator.swift:2484` `fin != 0` · `:2488` `span != 0`
- `n ∈ [0,1]` 이므로 `n < fin` 은 `fin > 0` 을, `fout < n` 은 `fout < 1` → `span > 0` 을 각각 함의한다.
  동작에는 영향 없다.

### ⚪ F8 — `ParticleSystem.swift:2305` 의 "페이로드 전문(**파스·보존 전용**)" 이 남아 있다

- 같은 PR 이 형제 `around` 분기(`:2286`)는 "선언별 런타임 페이로드"로 고쳤고,
  `MapSequenceBetweenSpec` 본문 주석도 "시뮬이 소비한다"로 바꿨는데 **between 파스 자리만** 안 고쳤다.
  재현: `grep -n "파스·보존 전용" Sources/WapleCore/ParticleSystem.swift`

### ⚪ F9 — `stepChildren` 이 링크마다 매 스텝 `particles.map(\.lifetime)` 배열을 새로 할당한다

- 자리: `ParticleSimulator.swift:943-947` — 핫루프 안의 O(N) 할당. `feedsControlPoints` 링크에만
  걸리고 동봉 도달이 4링크라 실측 영향은 작다. 관찰만.

---

## 3. 의심(확인 못 함 — 발견으로 올리지 않는다)

- **S1** `emitterControlPointFrame`(`:1179-1193`)의 게이트 `simulatesInWorldSpace || slot != 0`
  는 **3×3 기저에만** 걸고 평행이동은 무조건 적용한다. `docs/re/particle-control-points.md:285-310`
  의 이미터 VM 발췌에는 그 게이트(arm 선택의 `cmp al,1`)가 무엇을 가리키는지 적혀 있지 않아,
  "CP0·로컬공간에서도 row3 를 더하는 것"이 실물인지 확인하지 못했다.
  동봉 코퍼스는 `controlpoint[0].offset` 이 **전건 0**이라 F1 경로(런타임 피드) 밖에서는
  차이가 안 난다. 근거 문서는 `docs/re/particle-emitter-controlpoint-binary-2026-08-31.md`.
- **S2** `applyParentControlPointFeed` 는 **살아 있는 부모 파티클 순서**로 슬롯을 배정한다
  (`ParticleControlPointFrame.swift:612-625`). 부모 파티클 하나가 죽으면 그 뒤 전원이 한 칸씩
  당겨져 CP 가 불연속 점프한다. WE 의 파티클 배열 압축 규약(순서 보존 shift vs swap-remove)을
  못 짚어 결함인지 판정 불가.
- **S3** `refreshMapSequenceBetweenSteps`(`:1580`, 호출 `:523`)가 매 `_step` 에 `step` 을 양수로 되쓰므로
  `advance(mirror:)` 의 부호 반전이 프레임 경계를 못 넘는다. 동봉 도달 2선언
  (thunderbolt flags 23 · beam_child flags 19)이 **둘 다 `limitbehavior` 미저작 → mirror=false**
  라 실제 차이는 0. 주석은 이것이 실물 동작이라 주장하지만 별도 확인은 못 했다.

---

## 4. 확인했지만 문제없던 것 (다음 라운드 시간 절약용)

1. **H3 는 완결이다** — 정본 식·분기 순서·경계 8종·0 분모 전부 통과. 도수 250/110/138 재측정 일치.
2. **H4 의 난수 안정성은 문제없다** — `sharedRandom` 은 스폰 시 1드로 저장이고
   `display()` 경로에 RNG 가 없다. 진폭 떨림은 구조적으로 불가능.
3. **위치 적분 중복/정지 이력(F431/F439)은 재발하지 않았다** — `movements` 루프(`:763-770`)와
   `angulars` 루프(`:914-920`) 모두 PR 이 손대지 않았고, 회전 적분은 여전히 루프 밖 1회다.
4. **정적 CP 시스템은 비트 동일** — mdistBetween(`:895-899`) · `liveControlPointTarget`(`:1362-1371`)
   둘 다 `current == base` 일 때 원본 값을 그대로 반환하는 fast path 가 있다.
   동봉 코퍼스에서 CP 를 런타임에 움직이는 시스템은 thunderbolt 체인 3파일(+preview 사본)뿐이다.
5. **`bakeControlPointTargets` 의 vortex 비멱등 재베이크는 실제로 막혔다** —
   `ControlPointBinding.authoredOffset`(`ParticleSystem.swift:1727-1733`)이 첫 bake **전** 값을
   보존하므로 자식 재베이크가 `oldCP + offset + newCP` 로 누적되지 않는다.
6. **수명 0/음수·방출률·`Float` 누적**은 PR 이 손대지 않았다(`n` 계산·emit 루프·`time += dt` 무변경).
   레인 범위에서 새 결함 없음.
7. **`ParticleMapSequenceOracleTests.swift` 는 실재한다**(`Tests/WapleCoreTests/`) — 유령 인용 아님.
   `ParticleEmitterControlPointTests.swift` · `ParticleControlPointFrameTests.swift` 도 신설돼 있다.
8. **`ParticleShaders.swift`(±4) · `SimplexNoise.swift` · `SplitMix64.swift`** — 셰이더는 소스 문자열 안 **주석 2줄 교체**(`v_particle` 의 parallaxDepth 설명)뿐이고 뒤 둘은 PR #8 이 건드리지 않았다(`git show --stat b883386e` 에 부재).
