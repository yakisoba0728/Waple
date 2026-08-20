# 전수 감사 수정 계획 (2026-08-20)

Opus 에이전트 20개를 병렬로 굴려 구현·바이너리·원본 프로그램을 다시 대조한 결과를 한 곳에
모은다. **에이전트 보고는 근거이지 결론이 아니다** — 이 문서에 "확인" 으로 올린 것은 전부
`wallpaper64.exe` 에서 직접 재확인한 것이고, 재확인하지 않은 것은 §4 에 그대로 남긴다.

바이너리: `440072bd-wallpaper64.exe` (설치본 `bin/wallpaper64.exe` 와 md5 동일).
도구: `scratchpad/wpe.py`(UNWIND CHAININFO 귀속) · `vdis2.py` · `vcheck.py`(독립 PE 리더).
`pe.py`/`disasm.py`/`pdata.py` 는 불안정 — 쓰지 말 것.

---

## 0. 이 라운드가 다시 확인한 것 — 에이전트끼리 갈린 자리

두 에이전트가 **정반대**를 보고한 지점이 하나 있었고, 바이트로 갈랐다.

`reducemovementnearcontrolpoint` 의 퇴화 역폭(`distanceouter == distanceinner`)에 실리는
`xmm15` 의 값:

| 보고 | 근거로 든 기입 | 판정 |
|---|---|---|
| A: −0.0 | `movss xmm15, [0x140492ff0]` @0x1401c5bac | **오답** |
| B: (1,1,1,1) | `movdqa xmm15, [0x140492e30]` @0x1401cb184 | **정답** |

두 기입이 **둘 다 실재한다.** 갈리는 것은 어느 쪽이 지배하느냐다:

- 0x1401cb184 는 **오퍼레이터 루프 프리헤더**다(루프 진입 `jmp 0x1401cb1a9` 직전).
- 백에지는 `0x1401cc476 jne 0x1401cb1a0` 이고, 루프 본문(0x1401cb1a9–0x1401cd3a7) 안에
  xmm15 기입이 **0건**이다.
- 0x1401c5bac 은 같은 함수의 **이미터 구간**이라 프리헤더가 덮어써 죽는다.
- `movaps xmm15, [rsp+0x2230]` @0x1401cc4a0 은 백에지 **뒤**의 복원이다
  (0x1401c552b 프롤로그 저장과 짝).

교차 확인: 자매 원소 `vortex` 의 같은 분기(0x1401cdcd1)도 같은 xmm15 를 읽고, 그쪽은 이미
1.0 으로 고쳐져 있었다. 한 레지스터를 두 원소가 달리 읽을 수는 없다.

**교훈**: "이 레지스터에 이 상수를 심는 명령이 있다" 는 근거가 아니다. **지배 관계**를 봐야
한다 — 같은 함수 안에서 앞 구간의 기입은 루프 프리헤더에 덮인다.

---

## 1. 착지 완료 (전부 이 문서 기준으로 재확인함)

| # | 무엇이 거짓이었나 | 실측 | 도달 |
|---|---|---|---|
| A1 | `applyBoids` 의 `guard particles[j].lifetime != 0` 이 "실물 재현" 이라 적혀 있었다 | Waple 에서 **설 수 없는 가드**다. `lifetimeRandom` 이 `max(0.0001, ·)` 로 바닥을 깔고(:923) 배열은 매 스텝 압축된다. 실물이 그 마스크를 두는 이유는 고정 슬랩의 **빈 슬롯**(lifetime 0)을 거르기 위해서다 | 0 (핫루프 비용만 남았다) |
| A2 | `reducemovement` 퇴화 역폭 = −0.0 (t 를 0 으로 죽인다) | **1.0** — inner 에서 시작하는 **폭 1 램프** (§0) | 퇴화 저작 씬 |
| A3 | `vortex`(v1)가 `centerforce` 를 파스해 **힘으로 썼다** (주석은 "v1 에 없다" 고 적어 놓고) | `"centerforce"`@0x14048f9f8 의 lea 는 전 바이너리 2곳뿐이고 둘 다 v2 다(주입기 0x1401bf5f5 ∈ 0x1401bf2d0 · ctor 0x1401ce07a) | `centerforce` 저작 v1 씬 |
| A4 | `vortex`/`vortex_v2` 가 `variablestrength`·`reductioninner`·`reductionouter` 를 "파스·보존" 했다 | 전자는 주입기 0x1401be2a0·ctor 0x1401ccf0b = **mdtcp 전용**, 후자 둘은 0x1401be810·0x1401cd252/0x1401cd285 = **rmncp 전용**. 소비처 0인 죽은 페이로드라 연관값째 제거(12 → 9) | 0 |
| A5 | mdtcp `variablestrength = 0` → `s = dt·min(1,0.025/dt)^0.7` ("매우 느린 수렴") | **s = 1.0** — 반지름 구면으로 즉시 투영. `xmm2` 는 핸들러 인자가 아니라 **op 디스패치 프리앰블의 상수 1.0**(`movss xmm2,[0x140492704]`@0x14023fd77 → `jmp rax`@0x14023fdc7 까지 재대입 없음) | 키를 뺀 씬(동봉 3건은 전부 vs=5) |
| A6 | `sizerandom` 부재 기본 1/1 | ortho **5.0/50.0**(0x1401b9e96 / 0x1401b9f6a), 원근 0.001/1.0 | 부재 씬(동봉 287건은 전건 명시) |
| A7 | `velocityrandom` 부재 기본 (0,0,0) = "속도 없음" | ortho **"-32 -32 0"/"32 32 0"**, 원근 "-1 -1 -1"/"1 1 1" (0x1401bac6d / 0x1401bac93) | 부재 씬(동봉 120건은 전건 명시) |
| A8 | rope/ropetrail 확장 키 여섯을 두 렌더러가 똑같이 읽는다 | **읽는 키가 다르다** — `uvsmoothing` 은 rope 전용, `fade*`/`segments` 는 ropetrail 전용 (핸들러 구간별 lea 전수) | rope 25 · ropetrail 18 |
| A9 | `fadealpha`/`fadesize`/`uvscrolling`/`uvsmoothing` 이 `Float?` | **불리언 체크박스**(주입 태그 5, 소비는 비트 세팅). 동봉 자산도 전건 JSON 리터럴 | 위와 같음 |
| A10 | 렌더러 부재 기본이 전부 0/nil | spritetrail 0.05/10.0 · rope subdivision 4 · rope uvsmoothing **true** · ropetrail 1.0/4/1 · uvscale 1 | length 부재 13 · maxlength 11 · subdivision 11 · uvsmoothing 13 · segments 14 |
| A11 | 도수 인용에 범위 라벨이 없어 35 vs 34 로 갈렸다 | `spec/assets/particle-corpus.json` 이 all/unique 두 범위를 함께 재고 게이트가 매 실행 대조 | 문서 전반 |
| A12 | `ParticleSystem.swift.orig`(91KB)가 커밋돼 있었다 — `.swift` 가 아니라 Swift 관문 셋이 전부 건너뛰었다 | 삭제 + `check_stray_artifacts.py` | — |

### 눈에 보이는 변경 — Mac 골든 재검토 필요

A10 의 spritetrail 부분은 **그림이 달라진다.** 여기서 H3 핫픽스를 되돌렸는데, 근거가 하나 더
있어서 적어 둔다 — **WE 가 해당 셰이더 원문을 동봉한다**(`assets/shaders/common_particles.h`):

```glsl
float trailLength = length(localVelocity);
localVelocity /= trailLength;
up = localVelocity * max(g_RenderVar0.z, min(trailLength * g_RenderVar0.x, g_RenderVar0.y));
```
그리고 `ComputeParticlePosition` 이 두 축 모두에 `positionAndSize.w`(= size)를 곱한다. 비-트레일
경로에서 `up` 이 단위벡터이므로 **트레일 `up` 의 크기가 곧 size 배수**이고,
`g_RenderVar0 = (length, maxlength, minlength)` 다. 즉 계약은
`stretch = max(minlength, min(speed·length, maxlength))` 로 확정된다.

H3 는 `length` 부재를 "신장 미정의" 로 보고 항등 1 을 돌려줬다. 그 전제가 틀렸다(주입기가
0.05 를 심는다). H3 가 관측한 회귀(rain_on_the_glass 흰 스미어)의 실제 원인은 그 **직전**
폴백 `mul = 1` → `s = speed`(수백)였고, `s = speed·0.05` 는 그보다 20배 작다 — H3 는 한 번도
시험되지 않은 값을 두고 반대편 극단으로 넘어간 것이다. 다만 `maxlength = 6` 인 그 프리셋은
실물에서도 speed 120 부터 포화하므로 **WE 자신이 굵은 스트릭을 그린다**. H3 가 "명백한 회귀" 로
판정한 비교 대상은 WE 가 아니라 Waple 의 옛 리본 구현이었다.

렌더 회귀 테스트의 실측치가 이 계약을 그대로 확인해 준다 — sizePx 100 · maxlength 6 에서
speed 10 → 25px(= 100·0.5·0.5), speed 800 → 300px(= 100·0.5·6). 손계산과 일치한다.

**그래도 골든은 사람이 봐야 한다** — 동봉 44건 중 `length` 부재 13 · `maxlength` 부재 11 의
그림이 바뀐다. 근거가 바이트와 WE 동봉 셰이더 원문 둘이라 관측 판단보다 우선하지만, 화면 확인은
Mac 세션 몫이다.

**교훈 하나**: WE 는 `assets/shaders/` 에 GLSL 원문을 그대로 동봉한다. 디스어셈블로 못 찾는
지오메트리·필터 계약이 거기 평문으로 있을 수 있다 — x86 을 파기 전에 셰이더를 먼저 grep 하라.

반대로 rope 의 `trailSampleCount` 는 **일부러 바꾸지 않았다** — `subdivision` 을 히스토리
샘플 수로 쓰는 매핑(F629)에 WE 근거가 없기 때문이다. 근거 없는 매핑에 새로 확정된
기본값(4)을 흘리면 부재 11건의 샘플이 16 → 4 로 줄어든다. 리본 지오메트리를 실측할 때까지
대역값 16 을 유지한다.

---

## 2. 다음 착지 대상 (근거 등급별)

### 2-A. 바이트로 확정됐고 도달이 있는 것

**B2·B3·B4·B6·B7·B8 은 착지했다**(각 행의 `[착지]`). 남은 것은 B1(골든 재베이스라인과
묶여야 함)과 B5(비트 의미 미측정)뿐이다.

| # | 항목 | 실측 | 비용 |
|---|---|---|---|
| B1 | `positionoffsetrandom` 이 **layerimage 의 키**(`offsetmin`/`offsetmax`)로 파스된다 — 실물 키는 `directions`·`sign`·`scale`·`distance`·`timescale`·`octaves` | 동봉 5/5 인스턴스가 `distance`/`scale`/`timescale` 만 쓴다 → **전건 무동작 오프셋**이면서 RNG 를 3회 소모해 난수열까지 민다 | 중 — RNG 시퀀스가 바뀌므로 **골든 재베이스라인과 반드시 묶어야** 한다 |
| B2 | `audioprocessingexponent` 기본 1 → **2.0**, `audioprocessingfrequencyend` 기본 15 → **1** | 주입기 0x1401c1e20 | 소 · **[착지]** |
| B3 | 파티클 오디오 축약이 **MAX** 인데 Waple 은 평균(`sum/(fmax−fmin+1)`) | 셰이더 경로(`CreateAudioResponse`)는 평균이 맞고 **파티클 경로만** MAX | 소 — 두 경로를 갈라야 한다 · **[착지]** |
| B4 | 컨트롤포인트가 `id` 로 인덱싱된다 | 실물은 `for i in 0..<8` **배열 위치**가 슬롯이고 `"id"` 를 읽지 않는다. 동봉은 전건 `id == index` 라 도달 0이지만, `id` 없는 CP 를 Waple 은 통째로 버린다 | 소 · **[착지]** |
| B5 | `controlpoint[].flags`(비-0 41건) · `parentcontrolpoint`(17건) 미파스 | 주입·저장은 확정. **비트 의미는 미측정** — 파스·보존까지만 | 소 |
| B6 | `maxcount` 부재 기본 100 | 실물은 주입기가 없고 `isNumeric` 실패 시 **0** | 소(도달 0) · **[착지]** |
| B7 | 자식 `maxcount` 부재 기본 `trigger == .always ? 1 : 루트값` | 실물은 상수 **10**(0x1401c16f5). 동봉 자식 선언의 72%가 생략 | 소 · **[착지]** |
| B8 | `renderer` 키 부재 → `.unsupported("none")` | 실물은 `isArray` 실패 시 `{name:"sprite"}` 를 **주입**한다. 빈 배열 `[]` 은 isArray 를 통과해 렌더러 0개 — 두 경우가 다르다 | 소 · **[착지]** |

### 2-B. 인용 규약 — `.rdata` 파일 오프셋을 RVA 로 적은 곳

`.rdata` 는 rva 0x426000 / rawptr 0x424e00 이라 **파일 오프셋 + 0x1200 = RVA** 다. 리포
주석은 두 규약을 똑같은 `@0x48XXXX` 표기로 섞어 쓴다. 감사에서 **27건**이 파일 오프셋을 RVA
로 적은 것으로 확인됐고(대표: `@0x48e9b0` 을 RVA 로 읽으면 `"winddirection"`), 이번 라운드에
렌더러 블록과 vortex 블록은 정정했다. 남은 자리와 처방:

- `ParticleSystem.swift` 52·57·276·296·321·652·653·674·692·693·694·762·1267·1474
- `ParticleSimulator.swift` 106·758
- `ParticleExtendedKeysTests.swift` 6·10·11 · `EngineDefaultFixRegressionTests.swift` 41·42·55·72
- `ParticleSceneFixRegressionTests.swift` 45·420 · `ParticleAudioTests.swift` 28
- `AudioSpectrum.swift` 55/60/65 — 필드 오프셋이 8 작다(+0xEC/+0xF0/+0xF4/+0xF8)
- `Model3D.swift:58` RVA 오기

**[착지] 처방은 개별 정정이 아니라 게이트다.** `scripts/dev/check-rdata-citations.py` 가
각 `@0x4XXXXX` 인용에 대해 직접 해석과 `+0x1200` 해석의 C 문자열을 둘 다 읽어 주변 산문과
대조한다. 바이너리를 요구하므로 CI 게이트가 아니라 로컬 도구이고, `WE_BINARY` 가 없으면
검사하지 않았다는 사실을 화면에 찍는다.

그 도구로 재보니 위 목록은 부분집합이었다 — **Sources/Tests 의 32건이 전건 오프셋**이었다.
전부 +0x1200 로 옮기고 옮긴 뒤 각 주소가 정말 그 키를 가리키는지 다시 읽어 확인했다(19건은
주변 산문에 키 이름이 그대로 있어 자동 확인, 나머지는 `직접=` 열로 육안 확인). 두 건은
오프셋 오류에 더해 주소까지 어긋나 있었다(`minperiodicdelay`/`maxperiodicdelay` — 물음표가
붙은 추정에 클러스터 주소를 갖다 붙인 것, 실측 @0x48f3f0 / @0x48f408).

### 2-C. 관문 자체의 구멍 (감사가 게이트를 겨눈 결과)

**C1–C8 전건 착지**(C1·C2·C3·C4·C6 은 처방 중 일부만 — 행마다 안 한 것을 명시했다).

| # | 게이트 | 구멍 | 처방 |
|---|---|---|---|
| C1 | `specfmt.dump` 축소 가드 | **부분 축소를 전건 통과**시킨다: dict 는 `for k in old if k in new` 라 사라진 키를 순회조차 않고, list 는 `zip` 이라 꼬리를 안 보고, 타입 변경(list→int, int→null)은 `isinstance` 쌍에 안 걸린다. 커밋된 정본을 40KB→8KB 로 깎아도 통과한다 | 키 소멸·**형 변경**을 축소로 판정(길이 축소는 갭 목록이 줄어드는 정상 동작이라 일부러 제외). `shrink_report` 는 `entries` 부재를 `[]` 가 아니라 **거부**. 양성 대조에 그 세 형태 추가(없으면 이 수정도 다시 썩는다) · **[착지]** |
| C2 | `check_spec_shrink_guard.py` | 양성 대조 7건이 전부 `→0`/`→빔` 모양이라 C1 의 사각을 **인증**한다. 관문 우회 탐지도 리터럴 `json.dump(` 하나뿐이라 `Path(p).write_text(json.dumps(...))` 가 샌다 | 부분 축소 5종을 양성 대조에, 실사 대조에 두 건 추가. 우회 탐지에 `write_text(json.dumps` · `.write(json.dumps` · 공백 낀 `json.dump (` 추가 · **[일부 착지]** — `ast` 기반은 아니다 |
| C3 | `check_int_narrowing.py` | GUARDS 를 **줄 전체**에서 찾아 같은 줄 주석에 가드 이름만 있으면 면제된다. R4 는 총수라 정직한 수정으로 카운트를 낮춘 뒤 위험한 좁힘을 끼워 넣을 수 있다 | 줄 끝 주석을 잘라내고(문자열 안 `//` 는 보존) R1 을 방향 무관으로 · **[일부 착지]** — 호출 단위 판정과 R4 파일별 딕셔너리는 안 했다(기준선 343 불변 확인) |
| C4 | `check_swift_enum_patterns.py` | 이름 중복 제외가 **원격 스위치**다 — 아무 데나 `enum __Decoy { case translated(a: Int) }` 를 두면 그 위반이 사라진다. 지금도 `velocity`/`speed` 2종이 제외돼 있고 그 이름을 쓰는 패턴이 6곳 | 제외된 이름을 화면에 찍고 기준선 `{velocity, speed}` 로 고정(늘면 실패) · **[일부 착지]** — `타입명.케이스명` 정규화는 안 했다. 그 둘의 사각지대는 그대로 남아 있다 |
| C5 | `check_effect_texture_resolution.py` | **0바이트 PNG 가 통과**하고, 머티리얼 JSON 파스 실패는 조용히 스킵되며, 참조 수 하한이 없어 세 파일을 다 깨면 `참조 0건 전건 해석` rc=0 | 파스 실패를 실패로, 참조 수 하한, PNG 시그니처+IHDR 확인 · **[착지]** — 0바이트/시그니처/IHDR 0x0 · 머티리얼 파스 실패 보고 · 참조 수 하한(MIN_REFS 3). 음성 대조 4건 추가 |
| C6 | `validate.py` | 근거 ref 의 **줄 번호를 검증하지 않는다** — 153줄 파일에 `:204` 를 달아도 오류 0. `entries: []` 도 통과 | 줄 번호가 파일 길이를 넘으면 오류(+ 유닛 2건) · **[일부 착지]** — 문서별 `entries` 최소 개수 기준선은 안 했다(`entries: []` 는 축소 가드가 막는다) |
| C7 | `ci-status.py` | `⚠ CI 없음인데 코드 변경`·`실행 없음`·release 레인 숨은 테스트 실패가 전부 **rc=0** 이라 `until` 관용구가 그 자리에서 성공으로 빠진다 | 그 셋을 rc=1 로, `--tests` 일 때 테스트 실패를 rc 에 반영 · **[착지]** |
| C8 | `measure_mdl_deep.py`·`measure_render_pass.py` | 자기 입력 가드가 없어 부분 입력에서 **끝까지 돌아 쓰기까지 간다** — 유일한 방어선이 C1 의 축소 가드다 | 다른 11개처럼 입력 도수 검사 추가 · **[착지]** — mdl_deep 은 WE_WORKSHOP 부재를, render_pass 는 d3d11.h 부재를 각각 자기 자리에서 거부한다 |

### 2-D. 생성기 자체의 버그 (재실행해도 그대로 재생산된다)

- `measure_oracle_gate.py` 143/338/371/587: 줄 번호는 `Snapshot.swift` 에서 뽑는데 문자열은
  `COMPARE_SWIFT` 를 붙인다 → 확정 3건이 **153줄 파일의 204행**을 가리킨다.
- `measure_render_state.py:390`: `material.jsonDialect.strictFailures` 를 31건이라 적었는데
  그 항목은 27건이다(31 은 다른 모집단).
- `format.mdl.compilerOptionMapping` 주의문: "빈 `{}` json" 은 실물에 0건이다. flow/glow(0x9)·
  camera/sphere(0x0f)는 **옵션 json 자체가 없다**.
- `engine.particle.systemFlagsUnused.consumeSite`: `SceneRenderer3D.swift:2050` → 실제 **2183**.
- `engine.particle.handoffClaimCorrected` → `…flagBitMeaning.notVerified` 끊긴 참조.

---

## 3. 도달 0 — 손대지 말 것

- **`collisionbox` 구현 금지.** 실물 점프테이블의 op 0x17 이 VM 의 명령어 전진 라벨
  (0x140240279)을 가리킨다 = WE 자신이 no-op 이다. 구현하면 오히려 어긋난다.
- `*.locktransforms` · `sound.muteineditor` · `general.camerapreview`/`norecompile` ·
  `controlpoint[].locktopointer` — **런타임 바이너리에 문자열 자체가 없다**(에디터 전용).
- 머티리얼 오탈자 키 `depthwriting`/`depthtesting`/`culling` — 실물에 없다. 안 읽는 게 정답.
- `image/text/shape.castshadow`(5568객체 전건 false) · `text.spacing`(전건 `"0 0"`) ·
  `emitter.cone`(전건 0) · `children.angles`(전건 `"0 0 0"`).

---

## 4. 아직 내가 재확인하지 않은 에이전트 보고

아래는 **근거가 제시됐으나 이 문서를 쓰는 시점에 내가 바이트로 되짚지 않은** 것들이다.
착수 전에 §0 의 교훈(지배 관계 확인)을 적용해 각각 재확인해야 한다.

- **turbulence 가 위치가 아니라 속도에 더한다** — **재확인 완료(2026-08-20).** 핸들러
  프리앰블이 `rcx/rdx/r8 = [sys+0x2b0/0x2b8/0x2c0]`(위치, 노이즈 좌표용 읽기 전용)과
  `r15/r12/r13 = [sys+0x2c8/0x2d0/0x2d8]`(속도)을 각각 잡고(0x1402429dd–0x140242a05),
  꼬리 0x140242d3a–0x140242d54 가 **속도 쪽에만** `addps` → `movups` 한다. Waple 의 위치
  이류는 발산이 맞다.
  **아직 안 고쳤다 — 배수 사슬이 절반만 추적됐기 때문이다.**
  `xmm11 = 파티클별난수 × (speed × audioResponse)`(0x140242a60·0x140242a75, 오디오는
  0x14022a8a0 = 구간 MAX)까지는 확실하고, 진입 시 xmm8 로 들어온 dtScaled 가 어디서
  곱해지는지가 미확정이다. 속도 누적은 매 프레임 쌓이므로 배수를 틀리면 발산한다 —
  배수 확정 + 화면 확인이 가능한 라운드에서 함께 옮긴다. 거짓 주석(`vel 미누적 → 유계`)은
  양쪽(`ParticleOperator.turbulence` · `ParticleSimulator` 적용부)에서 걷어냈다.
  도달 22 인스턴스(활성 페이드 창 4건 포함, thunderbolt 계열).
- **oscillateposition 이 절대 오프셋이 아니라 프레임별 증분**(`sin θ − sin θ'` 을 위치 배열에
  누적). 가중이 변하는 구간에서 갈린다.
- **오실레이터 위상식** — 실물 인자가 `(phase + age초)·freq` 이고 파티클별 난수 **하나**가
  freq·phase·scale 을 동시에 만든다는 보고. Waple 은 `2π·f·(age/lifetime)+φ` 에 파라미터마다
  독립 난수다.
- **boids 안쪽 루프도 N-스트라이프 서브샘플**이고 꼬리 레인을 자르지 않는다는 보고.
- **movement(op 0x01) 안에 위치 적분이 있다** → movement 뒤 오퍼레이터는 이번 프레임 변위에
  기여하지 않는다는 보고. 사실이면 스텝 순서 전반이 바뀐다.
- **dtScaled 사용처 7곳**(movement drag · angular drag · attract scale · turbulence · vortex ·
  vortex_v2 · boids)에 Waple 은 생 dt 를 쓴다는 보고. 40fps 이상에서는 동일.
- **`.mdl` 인덱스 폭이 gateWord bit0 으로 자기기술된다** — **재확인·착지(2026-08-20).**
  업로드 경로 0x1401d7760 이 `movzx ecx,byte[rdi+0x18]`(0x1401d784c) → `and cl,1` →
  `lea r9d,[r10*2+2]`(0x1401d7870) → `idiv r9d` 로 폭을 만들고, 소비처 0x14009a98d 가 같은
  비트로 `0x39(R16_UINT)`/`0x2a(R32_UINT)` 와 ByteWidth 를 고른다. 정점 수는 안 들어간다.
  Waple 의 `vCount > 65535 ? 4 : 2` 를 `2 + 2·(gateWord & 1)` 로 바꿨다.
  설치본 28파일 45메시 파스 결과가 **바이트 동일**(gateWord 전건 0 · 최대 정점 10,995)이라
  회귀 없이 규칙만 옳아졌다. 두 규칙을 가르는 두 케이스(비트 선 작은 메시 / 비트 없는 큰 메시)를
  `Model3DIndexWidthTests` 에 새로 넣었다.
  **남은 것**: 정본 `spec/formats/mdl-deep.json` `format.mdl.indexWidth` 의 규칙 문장이 아직
  옛 것이다. 생성기(`measure_mdl_deep.py`)는 고쳤지만 재생성에 `WE_WORKSHOP` 이 필요해 이
  컨테이너에서는 못 돌린다 — 코퍼스가 있는 곳에서 재생성할 것.
- **`.png` 폴백이 `.tex-json` 의 `format` 을 버려 refraction 이 잘못 렌더된다**는 보고
  (`TEXnFORMAT` 콤보 미정의 → `normal.wy` 분기).
- **`sprite` 오브젝트 타입**(WE 의 9번째 레이어 종류)이 로그도 없이 사라진다는 보고.
- **JS 심의 로드 순서 문제** — WE 순서(baseclasses 나중)에서 `shared.camera` 와
  `MediaPlaybackEvent` 가 진다는 보고. `check_js_shim_baseclasses.py` 는 그 순서를 시험하지
  않는다.

---

## 4-bis. 내가 쓴 수정이 거짓이었던 자리 — `TEXnFORMAT`

이 라운드에서 **내가 작성한 미커밋 변경 하나가 두 겹으로 거짓**이었다. 감사가 겨눠야 하는 것이
남의 코드만이 아니라는 실례라 기록해 둔다.

거짓 ①: **주석은 맞는 규칙, 코드는 다른 규칙.** 주석에 "`"formatcombo":true` 가 붙은 슬롯이
그 값을 받는다" 라고 적어 놓고, 코드는 `samplerCombos`(= `"combo"` 어노테이션)를 돌았다.
실측: 동봉 17파일의 `formatcombo` 슬롯은 {1:12, 2:5, 4:5, 8:1} 이고 `"combo"` 를 겸한 것은
슬롯 1 의 11건뿐이다. 정작 고치려던 `effects/refraction/shaders/effects/refract.frag:8` 에는
`"combo"` 가 없다 — **한 번도 안 걸리는 수정**이었다. `parse` 도 통과하고 CI 도 초록이었을 것이다.

거짓 ②: **전제가 틀렸다.** "`.tex` 헤더의 format 을 그대로 `TEXnFORMAT` 에 심으면 된다" 고 봤는데,
`TexDecoder._decodeMip`(TexDecoder.swift:228-282)은 GPU 네이티브 포맷을 올리지 않고 전부 CPU 에서
RGBA8 로 펴면서 **채널 배치를 이미 WE 셰이더의 변환 *후* 모양으로 맞춰 둔다**:

    r8(9)   → (v,v,v,v)        `ConvertTexture0Format` 의 `vec4(1,1,1,.r)` 자리에 값이 온다
    rg88(8) → (b0,b0,b0,b1)    `.rrrg` 를 **디코드가 이미 적용**한 모양

그래서 `.tex` 로 온 rg88/r8 에 코드를 심으면 셰이더가 변환을 **두 번** 건다
(`.rrrg` 재적용 → `(b0,b0,b0,b0)`, 알파 소실). **지금의 "정의 없음 = 0" 이 그 경로에선 맞는 값**이다.

착지한 것: 슬롯 판정을 `GLSLTranslator.formatComboSlots`(신규)로 바꾸고, 값은 **컴파일된 `.tex` 가
없어 소스 폼(.png)으로 해석되는 텍스처에만** 준다(`sourceFormTexFormatCode`). 코드 0 은 미정의와
같은 값이라 아예 심지 않는다 — 파이프라인 변형 캐시 키가 안 갈린다.

도달(실측, 동봉 전수): **`effects/refraction` 슬롯 1 한 곳**. lightshafts 슬롯 2 의
`gradient_iridescent` 는 rgba8888=0 이라 무변화, waterripple/waterflow 는 `formatcombo` 자체가 없고
노멀맵을 `.xyz*2-1` 로 직접 읽어 오늘도 정확하다. 게이트 `check_tex_format_map.py` 의 G 항목이
이 집합을 못박는다.

게이트: `scripts/spec/check_tex_format_map.py` — ①`FORMAT_*` enum ②`tex-json`↔`tex` 272쌍
③Swift 리터럴의 삼자 정합 + D 이름유추 배반집합(`rgb888`→0) + E 디코더 정규화 존치
+ F 슬롯 판정 기준 + G 도달 집합.

### 남은 것 (측정은 끝났고 처방이 없다)

· **rg88 `.tex` 노멀맵의 x/y 뒤바뀜.** Waple 의 `(b0,b0,b0,b1)` 배치에서 `wy` 분기는 (b1,b0) 을
  읽는다 — WE 네이티브 `rg` 분기의 (b0,b1) 과 **전치**다. 어느 `TEXnFORMAT` 값으로도 못 고친다
  (`rg` 는 (b0,b0) 로 더 나쁘다). 실측 도달: 동봉 0건 · `defaultprojects` 0건(거기 노멀맵 10건은
  전부 DXT5). `smoke2normal.tex`(format 8) 는 어느 머티리얼도 안 묶는다. 다만
  `shaders/declarations.json:87-92` 가 노멀맵 임포트 **에디터 기본값**을 `rg88n` 으로 두므로
  워크샵 노출은 **미측정**이다. 손대는 순간 파티클/마스크 경로가 같이 흔들리므로 처방 전에
  워크샵 코퍼스 측정이 먼저다.
· **손번역 MSL 경로는 이미 맞다.** `mf_normal`/`mf_refract`/`pf_refract`/`f_refract` 는
  `normalMapFormatCode`(SceneRendererResources.swift:1768)로 3분기를 명시 구현하고 있고,
  `(b0,b0,b0,b1)` 전제에서 채널 대수가 WE 와 일치한다. 이번 수정은 **번역 GLSL 이펙트 패스**
  경로만 건드린다 — 겹치지 않는다.
· **`genericimage4.frag:112`** 는 노멀을 `.xy*2-1` 로 분기 없이 읽는다(어노테이션은 `rg88`).
  Waple 배치에선 (b0,b0) 이라 y 가 소실된다. 동봉·기본프로젝트 도달 0건, 워크샵 미측정.

## 4-ter. 이번 라운드 에이전트 보고 — 재확인 결과

· **`sprite` 오브젝트 종류 — 참, 도달 1건.** WE 오브젝트 팩토리(`0x14018ff60`)의 9번째 분기가
  맞고(`0x1401902d7`, 전용 `0x270` 클래스), Waple 의 `SceneDocument.swift:1068-1075` 에는 `else`
  가 없어 **조용히 버린다**. 실측 도달: 설치본 `ricepod.json` 의 `sun` **1건**, 동봉 0건.
  (다른 2건은 `"sprite": null` 이라 WE 도 Waple 도 똑같이 거른다.) 심각도 낮음 — 로그부터.
· **JS shim 적재 순서 — 절반 거짓.** WE 의 실제 순서가 `baseclasses.js` **마지막**인 것은 맞다
  (`0x18164a3c4`, 그 뒤 사이트들이 `_Vec2.._Mat4` 를 회수하므로 인과로도 확정). 그러나
  **Waple 은 `baseclasses.js` 를 아예 적재하지 않는다** — `Sources/` 어디에도 로더가 없고 리소스로만
  동봉된다. 두 시나리오 모두 오늘은 도달 불가다. 게다가 `shared.camera` 는 방향이 반대였다:
  WE 의 `shared` 는 `baseclasses.js:1457` 의 `{}` 라 **"잃는 쪽"이 곧 WE 동작**이고, Waple 의
  `TextScriptEngine.swift:2413` 씨앗이 이탈이다. 도달: 동봉 171씬 0건 · 설치본 184씬 0건.
  로더를 언젠가 배선한다면 그때는 shim 을 **먼저** 올려야 한다(`createScriptProperties` 의
  `_config` 키 회귀 + 상태 없는 `MediaPlaybackEvent` 를 피하려면 — WE 순서와 의도적으로 다르다).

## 5. 방법론 — 이번 라운드가 다시 확인한 함정

1. **`.pdata` 조각 ≠ 함수.** 인접 병합은 과병합한다. `UNW_FLAG_CHAININFO` 로 primary 에 귀속하라.
2. **같은 원소에 핸들러가 둘.** 할당기가 잠정 opcode 를 찍고, 페이드 창 게이트를 통과할 때만
   공용 파서(0x1401c2a40)가 ext 로 덮는다. 한쪽만 보고 "다른 원소" 라 판단하지 마라.
3. **주입 ≠ 소비.** 주입기가 심어도 핸들러가 게이트로 막을 수 있다(vortex ring 은 `flags & 4`).
4. **호출 사이트가 아니라 `mov r9d, imm` 을 세라.** 두 원소가 공용 꼬리로 `jmp` 한다.
5. **레지스터 상수는 지배 관계로 판정하라.** 같은 함수 앞 구간의 기입은 루프 프리헤더에 덮인다(§0).
6. **도수는 범위 라벨과 함께.** `all`(전수) / `unique`(sha256 중복 제거) 는 동봉 트리에서 거의
   두 배 차이가 난다. `spec/assets/particle-corpus.json` 을 인용하라.
