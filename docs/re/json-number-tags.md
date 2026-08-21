# JSON 타입 태그와 숫자 자리 — 불리언은 어디서 숫자가 되는가

**조사일 2026-08-21 · WE 2.8.42 `wallpaper64.exe` (imagebase `0x140000000`)**
**대상: jsoncpp 값 접근자 `0x140084ac0`–`0x140086400` · 타입 술어 `0x140088800`–`0x1400888c0` ·
파티클 디스패처 `0x1401c5490`–`0x1401d152c` · 씬 general `0x140181af0`–`0x140182f84` ·
씬 루트 `0x140186c90`–`0x140188816` · 이펙트 매니페스트 `0x1401e7170`–`0x1401e8a9d`**

발단은 커밋 `2642488`(프로퍼티 애니)이다. 그 커밋은 애니 경로의 숫자 자리들이 전부
`dec eax; cmp eax,2; ja` 로 태그 1..3 만 받는데 리눅스 Foundation 이 JSON `true` 를 `NSNumber`
로 줘서 `strictFloat(true) == 1.0` 이 되는 것을 잡고, **그 경로에만** 게이트를 달았다.
(이번 전수도 그 구간의 게이트 **9개**를 그대로 재현했다 — `0x1401a8e78`·`0x1401a8e89`·
`0x1401a9056`·`0x1401a906d`·`0x1401a90e1`·`0x1401a90f8`·`0x1401a9515`·`0x1401a9718`·`0x1401a9728`.
`2642488` 이 적은 VA 는 같은 게이트의 **태그 적재** 주소이고 여기 적은 것은 `dec` 주소다.)
이 문서는 그 발견을 저장소 전체로 확장해 전수 대조한 결과다.

## 0. 결론

**결론은 "전역으로 막아라" 가 아니다. 정반대다.**

| 사실 | 근거 |
| --- | --- |
| jsoncpp 의 숫자 접근자는 **전부 태그 5(boolean)를 받는다** | `asFloat 0x140086220` · `asInt 0x140085f70` · `asUInt 0x140085ee0` · `asInt64 0x140086000` |
| `asFloat(true)` = **1.0f**, `asFloat(false)` = 0.0f | `0x140086243 cmp byte [rcx],0` → `0x140086248 movss xmm0,[0x140492704]`(1.0f) / `0x1400862ad xorps` |
| `asInt(true)` = **1**, `asInt(false)` = 0 | `0x140085f95 cmp byte [rcx],al; setne al` |
| 태그 4(string)·6(array)·7(object)만 **abort** 한다 | `0x1400862b8` → `"Value is not convertible to float."`(`0x140478868`) → `0x1402c97e4` |
| 태그를 1/2/3 으로 좁히는 것은 **호출부**뿐이다 | `Json::Value::isNumeric()` `0x140088880` |
| 그 게이트는 **소수다** — `asFloat` 243 호출 · `asInt` 79 호출에 대해 게이트는 **93** 자리 | 아래 §2 |
| 파티클 디스패처에서는 `asFloat` 170 · `asInt` 59 중 게이트가 **6개**뿐 | §3 |

즉 **`strictFloat(true) == 1.0` 은 대부분의 자리에서 버그가 아니라 실물과의 정합**이다.
`strictFloat`/`strictInt` 를 전역으로 불리언 거부로 바꿨다면 파티클 경로 223자리가 실물과 갈렸을 것이다
(그리고 기존 회귀 테스트 `ParticleExtendedKeysTests.testOperatorInputRangeParsed`(`:897`) —
`"inputrangemax":true → (1,1,1)` — 이 즉시 깨진다).

그래서 이번 라운드는 **새 함수 + 게이트가 실재하는 자리만 전환**을 택했다.
`Sources/WapleCore/JSONNumerics.swift` 에 `isJSONNumeric` / `numericFloat` / `numericInt` 를 추가하고
**게이트가 실측된 자리만** 바꿨다 — 파티클 def 최상위 4자리(`starttime`·`flags`·`sequencemultiplier`·
`maxcount`)와 `rotationrandom.min/max` 2자리. 관용 폭 순서는 `numeric* ⊂ strict* ⊂ lenient*` 다.
반대로 **게이트가 없다고 확인된 `exponent` 7자리는 관용으로 되돌렸다**(§3.2).

**코퍼스 도달은 0이다.** 동봉+설치본 JSON **3,655개**(WEAssets 1,698 + `assets` 1,698 + `projects` 259,
그중 **63개는 JSONC** 라 `json.load` 로는 조용히 빠진다 — 관용 파서로 다시 읽었고 파스 실패 0)에서
불리언 값을 가진 키는 **66종**뿐이다. 이걸 두 방향으로 교차했다:

* Waple 이 숫자로 읽는 **키 이름** 113종(파티클 109 · 애니 4 · 이펙트 2, 중복 제거)과의 교집합 → `value` 하나.
* `SceneDocument` 의 `float`/`intVal`/`uintField`/`floats` 호출부에서 **리터럴 키로 읽는 이름**과의 교집합
  → 역시 `value` 하나(`constantshadervalues[k].value`).

그 `value` 18건은 **전부 진짜 불리언 자리**다:
`objects[].visible.value` **9건**(shimmering_particles 5 · dino_run 4),
`objects[].effects[].visible.value` **1건**(dino_run),
`general.properties.<name>.value` **6건**(불리언 사용자 프로퍼티 — corsair_o_tron 3 · dino_run 3),
`templateoptions[].options[].value` **2건**(templates/gif).
`constantshadervalues` 밑에도, 애니 키프레임 `value` 에도, 파티클 숫자 키에도 **0건**이다.

따라서 이 라운드 전체가 **워크샵 대비 잠복 방어**이지 실측 콘텐츠 버그 수정이 아니다.
(범위 한계: `SceneDocument` 의 `float`/`intVal` 125자리 중 상당수는 키 이름을 변수로 받아
정적 grep 으로 전수할 수 없다. 위 교차는 **리터럴 키만** 덮는다.)

---

## 1. 타입 술어와 값 접근자 — 명령 단위

`Json::Value` 의 타입 태그는 `[value+8]` 의 바이트다(0 null · 1 int · 2 uint · 3 real ·
4 string · 5 boolean · 6 array · 7 object).

술어 4종은 전부 `.pdata` 가 없는 리프다(그래서 `primary()` 가 `None` 을 준다 — 앞뒤 `int3` 사이를
직접 떠야 한다):

```
0x140088880  8b4108      mov   eax, [rcx+8]     ; isNumeric()
0x140088883  0fb6c0      movzx eax, al
0x140088886  ffc8        dec   eax
0x140088888  83f802      cmp   eax, 2
0x14008888b  0f96c0      setbe al
0x14008888e  c3          ret
0x140088890  80790804    cmp   byte [rcx+8], 4  ; isString()
0x1400888a0  80790806    cmp   byte [rcx+8], 6  ; isArray()
0x1400888b0  80790807    cmp   byte [rcx+8], 7  ; isObject()
```

`2642488` 이 애니 경로에서 본 `dec eax; cmp eax,2; ja` 는 **바로 이 술어의 인라인 전개**다.
같은 판정이 out-of-line 호출로도, 인라인으로도 나온다 — 두 형태를 모두 세어야 전수가 된다.

`asFloat` (`0x140086220`) 의 태그 분기:

| 태그 | 동작 | VA |
| --- | --- | --- |
| 0 null | `xorps xmm0,xmm0` → 0.0f | `0x1400862ad` |
| 1 int | `cvtsi2ss xmm0, [rcx]` | `0x1400862a0` |
| 2 uint | 부호 처리 후 `cvtsi2ss`(+`addss` 보정) | `0x140086268`–`0x140086291` |
| 3 real | `cvtpd2ps` | `0x140086258` |
| **5 boolean** | `cmp byte [rcx],0` → 0 이면 0.0f, 아니면 **`movss xmm0,[0x140492704]` = 1.0f** | `0x140086243`–`0x140086248` |
| 4/6/7 | `JSON_ASSERT` → abort | `0x1400862b8`–`0x1400862f1` |

`asInt`(`0x140085f70`)·`asUInt`(`0x140085ee0`)·`asInt64`(`0x140086000`)도 태그 5 에서
`cmp byte [rcx],al; setne al` 로 **0/1** 을 낸다(`0x140085f95` · `0x140085f05` · `0x140086025`).
태그 3 은 셋 다 `cvttsd2si`(0 방향 절삭)다.

> **부수 사실.** 실물은 숫자 자리에 **문자열이 오면 죽는다**(태그 4 → `JSON_ASSERT_MESSAGE` → abort).
> Waple 의 `strict*` 가 문자열에 nil 을 돌려주는 것은 실물보다 관대한 **의도된 하드닝**이다.

## 2. 게이트 전수 — `.text` 전역

`.text` 를 바이트 스캔해 `e8 rel32` 호출 대상을 센 값(전수, 중복 없음):

| 대상 | 호출 수 |
| --- | --- |
| `asFloat 0x140086220` | **243** |
| `asInt 0x140085f70` | **79** |
| `asBool 0x140086300` | 148 |
| `asString 0x140085cc0` | 193 |
| `find 0x140087490` | 507 |
| `operator[] 0x140087640` | 552 |
| **`isNumeric 0x140088880`** | **12** |
| `isString 0x140088890` | 50 |
| `isArray 0x1400888a0` | 30 |
| `isObject 0x1400888b0` | 42 |

인라인 전개는 **모든 `.pdata` 프래그먼트 체인을 시작에서 선형 디스어셈블**해
`cmp r32,2` 를 전부 모은 뒤, 그 앞 4명령 안의 `dec r32`/`sub r32,1` 과 다시 그 앞 8명령 안의
`[reg+8]` 태그 적재를 짝지어 뽑았다. 후보 **89** 중 실제 게이트는 **81** 이다.

빠지는 8은 전부 **접근자 본체의 태그 스위치**다 — `asUInt 0x140085efe` · `asInt 0x140085f8e` ·
`asInt64 0x14008601e` · `asUInt64 0x1400860de` · `asDouble 0x14008616e` · `asFloat 0x14008623e` ·
`asBool 0x14008631e` · 그리고 `0x14022b0f2`(인라인 전개된 `asInt64`). 이들은 모양이
`test edx,edx; je` → `sub edx,1; je` ×3 → `cmp edx,2` 라 **태그 적재와 `cmp` 사이에 조건 분기가 있다**.
게이트에는 없다 — 그게 둘을 가르는 판정이다.

> **[2026-08-21 재전수] 종전 78 은 3자리 적은 값이었다.** `dec` 와 `cmp` 사이에 스필 `mov` 가
> 끼어든 자리를 좁은 역방향 창이 놓쳤다:
>
> | 게이트(`cmp`) | `dec` | 태그 적재 | 사이에 낀 것 | 귀속 키 |
> | --- | --- | --- | --- | --- |
> | `0x1401a4b23` | `0x1401a4b17` | `0x1401a4b0b` `movzx eax,[r8+8]` | `mov r14,[rcx+8]` · `mov rdi,rdx` · `mov rbx,rcx` | 바인더 인자(§2.4) |
> | `0x1401fcc6c` | `0x1401fcc5d` | `0x1401fcc59` `movzx eax,[rbx+8]` | `mov [rsp+0x80],rbp` · `mov [rsp+0x58],rdi` | `animation` |
> | `0x14022310a` | `0x1402230fe` | `0x1402230fa` `movzx eax,[rbx+8]` | `mov [rsp+0x58],rsi` · `mov [rsp+0x50],rdi` | `animation` |
>
> 다른 lowering 도 함께 훑었다 — `add r32,-1` + `cmp ,2` 1건(`0x1400a6de0`)과
> `lea r32,[r-1]` + `cmp ,2` 9건은 **전부 태그 적재가 없는 오탐**이라(직접 확인:
> `0x1400a6de0` 은 루프 카운터, `0x1400be115` 는 문자 분류) 게이트가 아니다.

> **주의(직접 당했다).** 후보 주소에서 **거꾸로** 디스어셈블하면 정렬이 어긋나 게이트를 놓친다.
> `0x1401a9056` 은 태그 적재(`0x1401a904c`)와 `dec` 사이에 `mov r13d,1` 이 끼어 있는데,
> `va-24` 에서 시작하면 잡히고 `va-40` 에서 시작하면 사라졌다. 반드시 함수 시작에서 선형으로 떠라.

**총 93자리**(out-of-line 12 + 인라인 81). 게이트가 실제로 무엇을 지키는지는 접근자로 갈린다 —
게이트를 통과한 경로(`ja` 면 fallthrough, `jbe` 면 분기 대상)를 따라가 첫 접근자를 잡은 결과:

| 접근자 | 자리 |
| --- | ---: |
| `asFloat` | **42** |
| **`asUInt`** | **35** |
| `asInt64` | 4 |
| `asInt` | 2 |
| `asBool` | 2 |
| `asString` | 1 |
| 접근자가 아닌 호출(하위 파서 등) | 5 |
| 판정 불가(분기 모양이 다름) | 2 |

**`asUInt` 가 두 번째로 많다는 것이 이번 라운드의 핵심 발견**이다. 그 자리들은 하위 32비트로
잘리는데(§1) Waple 의 사다리에는 그 폭을 재현하는 헬퍼가 없었다 — §8 에서 채웠다.
`asFloat`+`asInt` 322 호출과 대조하면 **게이트가 붙은 자리가 소수**라는 것이 요지다.

게이트가 모여 있는 함수(파서별):

| 함수 | 게이트 | 무엇 | Waple 도달 |
| --- | --- | --- | --- |
| `0x14012e710–0x1401307e4` | 9 | 모니터 배치(`absx`/`absy`/`relx`/`rely`) | 없음 |
| `0x140181af0–0x140182f84` | 9 | 씬 `general` 정렬/색보정 `.value` | 없음(§2.1) |
| `0x1400ffcb0–0x1401006a7` | 8 | 설정/프리셋 적용 — `alignmentposition/x/y/z.value` + `wec_con/brs/sa/hue.value`(§2.1 과 **같은 키 집합**) | 없음 |
| `0x1401a8ce0–0x1401a940c` | 6 | **프로퍼티 애니** 키프레임(`value`·`frame`·핸들 x/y 4) | `2642488` 이 닫음 |
| `0x1401c5490–0x1401d152c` | 6 | **파티클 디스패처** — §3 | **이번에 6자리 전부 닫음** |
| `0x140021e50–0x14002f0ac` | 5 | 플레이리스트/프로필 설정 | 없음 |
| `0x140070dd0–0x140071c24` | 4 | 창 배치(`width`/`height`) | 없음 |
| `0x14012a270–0x14012a69a` | 4 | 정렬 프리셋 | 없음 |
| `0x140186c90–0x140188816` | 3 | 씬 루트 `refreshdelay` · `orthogonalprojection.width/height` | **미닫힘 — §6·§7** |
| `0x1401a96b0–0x1401a98a8` | 2 | 애니 `length`/`fps` | `2642488` 이 닫음 |
| `0x1401fac50–0x1401fb498` | 2 | 레이어(`usertexturereference` 계열) `width`/`height` | 미상 — §6 |
| `0x1401556e0–0x140155fbb` | 2 | 텍스처 참조 `width`/`height` | 없음 |
| `0x140075a90`·`0x140118b00`·`0x140119ca0` | 각 2 | 플레이리스트 설정 · `presetproperties`/`audioprocessing` | 없음 |
| `0x1401fcc20–0x1401fd32b` · `0x1402230c0–0x140223801` | 각 2 | `animation` · `index`(**이번에 새로 찾은 자리 2 포함**) | 미상 — §6 |
| 그 외 단발 **24개** | 각 1 | `0x1401e7ea7` 이펙트 `bind[].index`(일치) · `0x1401e6687` 이펙트 **`condition.value`**(종전 "`combos` 좌변" 은 오귀속 — §2.2) · `0x1401a9515` 애니 `events[].frame` · `0x1401de4e0` `parent` · `0x14019939e` 카메라 경로 `timestamp` · 설정/UI 파서 다수 | 대부분 없음 |

### 2.1 같은 블록 안에서도 키마다 다르다 (브리프 함정 8의 교과서 사례)

씬 `general` 색보정 블록(`0x140181f30`–`0x140182660`)은 전부 `{"<key>": {"value": X}}` 모양인데
게이트는 **키마다 다르다**:

| 키 | 게이트 | 접근자 |
| --- | --- | --- |
| `alignment.value` | **없음** | `asUInt 0x140181fba` — 불리언 1/0 을 받는다 |
| `alignmentposition.value` | `0x140182007` | `asFloat 0x140182027` |
| `alignmentx/y/z.value` | `0x140182072` · `0x1401820dd` · `0x140182148` | `asFloat` |
| `alignmentfliph.value` | 태그 5 전용 | `asBool 0x1401821ce` |
| `wec_e.value` | 태그 5 전용 | `asBool 0x140182380` |
| `wec_con/brs/sa/hue.value` | `0x1401823cd` · `0x140182438` · `0x1401824a3` · `0x14018251f` | `asFloat` |
| `wcc_v.value` | 태그 4 전용 | `asString 0x1401825af` |
| `wcc_amt.value` | `0x140182606` | `asFloat 0x140182626` |

**같은 함수, 같은 모양, 인접한 키인데 `alignment` 만 게이트가 없다.** 키 이름이나 문맥으로
추정하면 반드시 틀린다 — 자리마다 떠야 한다.

(이 키들은 **Waple 이 하나도 읽지 않는다** — `alignment*`/`wec_*`/`wcc_*` 전수 grep 0건. 도달 없음.)

### 2.2 게이트 93자리 전건 귀속 — 어느 키가 게이트를 받는가

**이 표가 이 저장소에서 "어디까지 관용을 허용할지" 를 정하는 유일한 근거다.**

귀속 방법(역방향 디스어셈블은 한 번도 하지 않았다):

1. 게이트가 든 `.pdata` 프래그먼트 체인을 **시작에서 선형으로** 디코드해 명령 배열을 만든다.
2. 그 배열 위에서 태그를 적재한 베이스 레지스터를 **역방향 def-use** 로 따라간다
   (`mov r,r` 는 계속 따라가고, 스택 스필은 같은 슬롯에 저장한 명령까지 되짚는다).
3. 정의가 `call find`(`0x140087490`) / `operator[](char*)`(`0x140086de0`) /
   `operator[](const string&)`(`0x140087640`) 면 **그 호출의 `rdx`** 를 다시 역추적해 키 문자열을 얻는다.
   `find` 가 null 을 주면 실물이 `0x140084ac0`(null 싱글턴)로 갈아타므로 그 분기도 넘어간다.
4. `operator[](const string&)` 는 인자가 `std::string` 임시라 `rdx` 가 스택을 가리킨다 —
   **그 호출 직전의** `0x1400170d0`(임시 생성) 호출의 `rdx` 를 쓴다. 앵커가 "그 호출" 이라
   브리프 함정 16(다음 키를 미리 싣는 `lea`)에 걸리지 않는다.
5. 부모 키가 있으면(`x["a"]["value"]` 꼴) 수신자 `rcx` 를 같은 방법으로 되짚어 **경로**로 적는다.

교차 검증: 이 파이프라인이 §2.1 의 손으로 뜬 표(9자리)와 §3.1 의 파티클 6자리를
**전건 일치**로 재현했다.

> **주소 규약 주의.** 아래 표의 "게이트 VA" 는 `cmp reg,2` 의 주소다. §2.1·§3.1 과 커밋
> `2642488` 은 같은 게이트를 **`dec` 주소**로 적었다(보통 2바이트 앞이지만, 스필이 끼면
> 더 멀다 — `0x1401a4b17` 의 `cmp` 는 `0x1401a4b23` 로 12바이트 뒤다). 두 표를 대조할 때
> 주소가 안 맞으면 먼저 이 규약 차이를 의심해라.

| 함수 | 게이트 수 | 게이트 VA(`cmp reg,2`) | 귀속 키 | 접근자 |
| --- | ---: | --- | --- | --- |
| `0x14001c0a0`–`0x14001c994` | 1 | `0x14001c344` | `order` | asUInt |
| `0x14001dd30`–`0x14001de77` | 1 | `0x14001ddb9` | `monitor` | asUInt |
| `0x14001e530`–`0x14001e959` | 1 | `0x14001e905` | `login` | asUInt |
| `0x140021e50`–`0x14002f0ac` | 5 | `0x140026549` (out-of-line) | `<stack string @rsp+0x40>.location` | call 0x140084dd0 |
|  |  | `0x14002884b` (out-of-line) | `settings.transitiontime` | call 0x140016fa0 |
|  |  | `0x140028ee4` (out-of-line) | `layout` | asUInt |
|  |  | `0x14002cb48` (out-of-line) | `location` | asString |
|  |  | `0x14002cc24` (out-of-line) | `<stack string @rsp+0x40>.location` | asUInt |
| `0x140040470`–`0x140041211` | 1 | `0x140040db5` | `version` | asUInt |
| `0x140046f20`–`0x1400483be` | 1 | `0x14004764a` | `audioinputthreshold` | call 0x140086ca0 |
| `0x140055320`–`0x14005613e` | 1 | `0x1400555e6` | `plugindelay` | asFloat |
| `0x140061280`–`0x140061943` | 1 | `0x1400612fb` | `position` | asFloat |
| `0x14006a490`–`0x14006c239` | 1 | `0x14006a56b` (out-of-line) | `layout` | asUInt |
| `0x140070dd0`–`0x140071c24` | 4 | `0x14007105f` | `x` | asUInt |
|  |  | `0x140071081` | `y` | asUInt |
|  |  | `0x140071096` | `width` | asUInt |
|  |  | `0x1400710c1` | `height` | asUInt |
| `0x140075790`–`0x140075a8f` | 1 | `0x140075a4c` | `transitiontime` | asUInt |
| `0x140075a90`–`0x140076bdb` | 2 | `0x140075b56` | `settings.delay` | asFloat |
|  |  | `0x14007628d` | `daytimeend` | asFloat |
| `0x1400ffcb0`–`0x1401006a7` | 8 | `0x140100103` | `alignmentposition.value` | asFloat |
|  |  | `0x140100170` | `alignmentx.value` | asFloat |
|  |  | `0x1401001dd` | `alignmenty.value` | asFloat |
|  |  | `0x14010024a` | `alignmentz.value` | asFloat |
|  |  | `0x140100362` | `wec_con.value` | asFloat |
|  |  | `0x1401003f9` | `wec_brs.value` | asFloat |
|  |  | `0x140100490` | `wec_sa.value` | asFloat |
|  |  | `0x140100527` | `wec_hue.value` | asFloat |
| `0x14010a520`–`0x14010b86c` | 1 | `0x14010a7fa` | `order` | asUInt |
| `0x140113c80`–`0x1401151d8` | 1 | `0x140114ddf` | `volume.value` | asFloat |
| `0x140115280`–`0x1401154b1` | 1 | `0x14011531c` | `volume.value` | asFloat |
| `0x140118b00`–`0x140118f7f` | 2 | `0x140118b85` | `wproperties.schemecolor.order` | asUInt |
|  |  | `0x140118c7d` | `wproperties.audioprocessing.order` | asUInt |
| `0x140119ca0`–`0x14011a0ee` | 2 | `0x140119d00` | `schemecolor.order` | asUInt |
|  |  | `0x140119df8` | `audioprocessing.order` | asUInt |
| `0x14012a270`–`0x14012a69a` | 4 | `0x14012a4dd` | `alignmentposition.value` | asFloat |
|  |  | `0x14012a549` | `alignmentx.value` | asFloat |
|  |  | `0x14012a5b5` | `alignmenty.value` | asFloat |
|  |  | `0x14012a621` | `alignmentz.value` | asFloat |
| `0x14012e710`–`0x1401307e4` | 9 | `0x14012ee51` | `<rdx by mov @0x14012ee23>.location` | asUInt |
|  |  | `0x14012f155` | `<rdx by mov @0x14012f106>.location` | asUInt |
|  |  | `0x14012f160` | `<rdx by mov @0x14012f106>.timestamp` | asUInt |
|  |  | `0x14012fae7` | `<rdx by cmova @0x14012fa25>.location` | asUInt |
|  |  | `0x14012faf6` | `<rdx by cmova @0x14012fa25>.absx` | asUInt |
|  |  | `0x14012fb06` | `<rdx by cmova @0x14012fa25>.absy` | asUInt |
|  |  | `0x14012fb17` | `<rdx by cmova @0x14012fa25>.relx` | asUInt |
|  |  | `0x14012fb27` | `<rdx by cmova @0x14012fa25>.rely` | asUInt |
|  |  | `0x1401302f0` | `<rdx by mov @0x1401301d3>.timestamp` | call 0x1400856e0 |
| `0x14013d170`–`0x14013d598` | 1 | `0x14013d2e1` | `<rdx by cmova @0x14013d2c2>` | asUInt |
| `0x1401556e0`–`0x140155fbb` | 2 | `0x1401559bc` | `usertexturereference.width` | asUInt |
|  |  | `0x1401559d2` | `usertexturereference.height` | asUInt |
| `0x140181af0`–`0x140182f84` | 9 | `0x140182009` | `alignmentposition.value` | asFloat |
|  |  | `0x140182074` | `alignmentx.value` | asFloat |
|  |  | `0x1401820df` | `alignmenty.value` | asFloat |
|  |  | `0x14018214a` | `alignmentz.value` | asFloat |
|  |  | `0x1401823cf` | `wec_con.value` | asFloat |
|  |  | `0x14018243a` | `wec_brs.value` | asFloat |
|  |  | `0x1401824a5` | `wec_sa.value` | asFloat |
|  |  | `0x140182521` | `wec_hue.value` | asFloat |
|  |  | `0x140182608` | `wcc_amt.value` | asFloat |
| `0x140186c90`–`0x140188816` | 3 | `0x1401874cc` | `general.refreshdelay` | asUInt |
|  |  | `0x140187578` | `general.orthogonalprojection.width` | asUInt |
|  |  | `0x140187587` | `general.orthogonalprojection.height` | asUInt |
| `0x140198e20`–`0x14019957b` | 1 | `0x1401993a0` | `timestamp` | asFloat |
| `0x1401a38f0`–`0x1401a3bde` | 1 | `0x1401a3937` | `id` | asInt64 |
| `0x1401a4930`–`0x1401a49f0` | 1 | `0x1401a49b7` | `value` | asUInt |
| `0x1401a4b00`–`0x1401a4bb8` | 2 | `0x1401a4b23` | `param-or-unknown` | asFloat |
|  |  | `0x1401a4b7d` | `value` | asFloat |
| `0x1401a89a0`–`0x1401a8c04` | 1 | `0x1401a8a68` | `value` | asFloat |
| `0x1401a8ce0`–`0x1401a940c` | 6 | `0x1401a8e7a` | `value` | asBool |
|  |  | `0x1401a8e8b` | `frame` | asBool |
|  |  | `0x1401a9058` | `back.x` | asFloat |
|  |  | `0x1401a906f` | `back.y` | asFloat |
|  |  | `0x1401a90e3` | `front.x` | asFloat |
|  |  | `0x1401a90fa` | `front.y` | asFloat |
| `0x1401a9410`–`0x1401a96ac` | 1 | `0x1401a9517` | `frame` | asFloat |
| `0x1401a96b0`–`0x1401a98a8` | 2 | `0x1401a971a` | `length` | None |
|  |  | `0x1401a972a` | `fps` | None |
| `0x1401c5490`–`0x1401d152c` | 6 | `0x1401c56b5` (out-of-line) | `starttime` | asFloat |
|  |  | `0x1401c56d8` (out-of-line) | `flags` | asInt |
|  |  | `0x1401c574d` (out-of-line) | `sequencemultiplier` | asFloat |
|  |  | `0x1401c577f` (out-of-line) | `maxcount` | asInt |
|  |  | `0x1401c8d67` (out-of-line) | `min` | asFloat |
|  |  | `0x1401c8e90` (out-of-line) | `max` | asFloat |
| `0x1401de470`–`0x1401de741` | 1 | `0x1401de4e2` | `parent` | asInt64 |
| `0x1401e63b0`–`0x1401e6976` | 1 | `0x1401e6689` | `<rdx by cmova @0x1401e65bc>.value` | asUInt |
| `0x1401e7170`–`0x1401e8a9d` | 1 | `0x1401e7ea9` | `index` | call 0x1401e63b0 |
| `0x1401fac50`–`0x1401fb498` | 2 | `0x1401fad93` | `width` | asFloat |
|  |  | `0x1401fadd0` | `height` | asFloat |
| `0x1401fcc20`–`0x1401fd32b` | 2 | `0x1401fcc6c` | `animation` | asInt64 |
|  |  | `0x1401fd258` | `index` | asUInt |
| `0x1402230c0`–`0x140223801` | 2 | `0x14022310a` | `animation` | asInt64 |
|  |  | `0x140223732` | `index` | asUInt |

읽는 법:

* `<stack string @…>` · `<rdx by …>` 는 **키가 런타임에 만들어지는 자리**다(모니터 ID·문자열 조합).
  정적으로 귀속할 수 없다 — 못 했다고 적는다. 93 중 **11자리**(`0x14012e710` 함수의 9 중 부모가
  모니터 ID 인 것들 · `0x14013d2e1`(`0x1404210f0` memcpy 로 만든 키) · `0x1401e6689` 의 부모)가 그렇다.
  다만 **자기 자신의 마지막 마디**는 전부 확정됐다.
* `0x1401a4b23` 하나만 키를 못 붙였다 — §2.4 의 리플렉션 바인더라 값이 **함수 인자로** 들어온다.
* `접근자` 칸의 `call 0x…` 는 게이트 통과 후 바로 하위 파서로 들어가는 자리다.

### 2.3 게이트가 **하나도 없는** 파서들 (여기서 관용을 유지해야 정합이다)

키 문자열의 `lea` xref → 감싸는 `.pdata` 함수 → 그 함수 안의 게이트 수로 확인했다:

| 파서 | 함수 | 게이트 | 확인에 쓴 키 |
| --- | --- | --- | --- |
| 머티리얼 | `0x140154480–0x140155668` · `0x1401577e0–0x1401580e2` · `0x140206ae0–0x1402076dc` · `0x140209540–0x14020adfa` | **0** | `constantshadervalues` · `cullmode` · `depthtest` · `blending` |
| 씬 오브젝트 | `0x1401e0530–0x1401e1389` · `0x1401ee520–0x1401ef118` | **0** | `angles` · `copybackground` |
| 인스턴스 오버라이드 | `0x14022af30–0x14022b92a` | **0** | `instanceoverride` |
| 파티클 자식/인스턴스 | `0x1401d13cc`(asFloat) · `0x1401d13f2`(asInt) 부근 | **0** | `probability` · `maxcount` |

즉 **머티리얼 상수·씬 오브젝트 트랜스폼·인스턴스 오버라이드의 숫자 자리는 실물도 불리언을 1/0 으로 읽는다.**
Waple 의 `lenientFloat`/`lenientInt`(그리고 `SceneDocument.float`/`intVal`)가 그 자리에서 불리언을
통과시키는 것은 **정합**이다. (문자열까지 받는 것은 실물보다 관대한 별개의 하드닝 — 실물은 태그 4 에서 abort 한다.)

### 2.4 리플렉션 바인더 두 개 — "스칼라 또는 `{value:…}`" 가 **한 자리에서** 갈린다

새로 찾은 게이트 `0x1401a4b23` 이 이 구조를 드러냈다. 두 작은 함수가 있다:

| 함수 | 시그니처(관측) | 직접 경로 | `.value` 경로 |
| --- | --- | --- | --- |
| `0x1401a4930`–`0x1401a49f0` | `(rcx=바인더, rdx=디스크립터, r8=Json::Value*)` | 인라인 태그 스위치 — 태그 1/2 `mov eax,[r8]`(`0x1401a4969`, **32비트**) · 태그 3 `cvttsd2si eax`(`0x1401a4962`) · **태그 5 는 아무것도 안 한다** | `find("value")`(`0x1401a499c`) → 게이트 `0x1401a49b7` → `asUInt`(`0x1401a49bc`) |
| `0x1401a4b00`–`0x1401a4bb8` | 〃 | 게이트 `0x1401a4b23` → `asFloat`(`0x1401a4b2b`) | `find("value")`(`0x1401a4b62`) → 게이트 `0x1401a4b7d` → `asFloat`(`0x1401a4b82`) |

착지 주소가 둘 다 `[r14 + rbp]` 인데 `r14 = [rcx+8]`(대상 객체), `rbp = [rdx+4]`(필드 오프셋)다 —
즉 **키는 디스크립터가 정하고 이 자리에서는 정적으로 알 수 없다**. `.pdata` 말고는 참조가 없어
(32비트 RVA 스캔 결과 `0x1404fb928`/`0x1404fb940` 두 개뿐이고 그건 자기 `.pdata` 행이다)
호출은 간접이다.

읽어 낼 수 있는 계약은 셋이다.

1. **한 프로퍼티는 스칼라로도, `{"value": X, "animation": …}` 로도 쓸 수 있고 두 경로 모두 게이트가 있다.**
   Waple 의 `unwrapValue` + `numeric*` 조합이 이 구조와 같은 모양이다.
2. `.value` 경로는 `[rcx+0x10] != 0` 이고 원값이 **태그 7(object)** 일 때만 탄다
   (`0x1401a4b4b cmp byte [rsi+8],7`). 즉 **스칼라를 쓰면 `.value` 를 아예 안 본다.**
3. **int 판(`0x1401a4930`)의 직접 경로는 태그 5 에서 아무 스토어도 하지 않는다** —
   0 이 아니라 **생성자 기본값이 남는다**(브리프 함정 15). 게이트를 "실패하면 0" 으로
   뭉뚱그리면 여기서 틀린다.

## 3. 파티클 경로 — 게이트는 6자리뿐

파티클 def 파서는 `0x1401c5490`–`0x1401d152c` 한 덩어리다(`.pdata` 조각 9개, `merged()` 로 병합).
그 안에서:

* `asFloat` **170** 호출 중 게이트가 붙은 것 **4**
* `asInt` **59** 호출 중 게이트가 붙은 것 **2**
* 인라인 게이트 **0** — 전부 `call isNumeric` 형태다

지배적 패턴은 게이트가 **없는** 이 모양이다:

```
lea  rdx, "<key>"          ; 키 문자열
call 0x1400170d0           ; std::string 임시 생성
mov  rcx, <Json::Value*>
call 0x140087640           ; operator[](const string&)
mov  rcx, rax
call 0x140086220           ; asFloat  ← 태그 검사 없음
```

예: `distancemin` `0x1401c5f12` · `distancemax` `0x1401c5f46` · `speedmin` `0x1401c5f79` ·
`exponent` `0x1401c720f`.

### 3.1 게이트가 있는 6자리 (def 최상위 4 + `rotationrandom.min/max`)

진입부가 키 6개를 먼저 `operator[]` 로 뽑아 레지스터에 담은 뒤 한꺼번에 읽는다.
**키 문자열 `lea` 는 언제나 *다음* 키를 미리 싣는다** — 순진하게 인접 `lea` 를 귀속시키면
한 칸씩 밀린다(브리프 함정 16). 실제 귀속:

| `operator[]` | → 레지스터 | 키 |
| --- | --- | --- |
| `0x1401c5564` | rbx | `material` |
| `0x1401c558d` | rdi | `starttime` |
| `0x1401c55b6` | r14 | `animationmode` |
| `0x1401c55df` | r15 | `sequencemultiplier` |
| `0x1401c5608` | rsi | `flags` |
| `0x1401c5631` | r12 | `maxcount` |

소비:

| 키 | 게이트 | 접근자 | 착지 | **게이트 실패 시** |
| --- | --- | --- | --- | --- |
| `starttime` | `call 0x1401c56b5` | `asFloat 0x1401c56c5` | `[r13+0x10]` | `xorps xmm0,xmm0`(`0x1401c56cc`) → **0.0** |
| `flags` | `call 0x1401c56d8` | `asInt 0x1401c56e4` | `[r13+8]` | `xor ecx,ecx`(`0x1401c56ee`) → **0** |
| `sequencemultiplier` | `call 0x1401c574d` | `asFloat 0x1401c5759` | `[r13+0x14]` | `movss xmm10,[0x140492704]`(`0x1401c5769`) → **1.0** |
| `maxcount` | `call 0x1401c577f` | `asInt 0x1401c578b` | `[r13]` | `xor r15d,r15d`(`0x1401c5795`) → **0** |
| `rotationrandom.min` | `call 0x1401c8d67` | `asFloat 0x1401c8d73` | `[rbp+0xe8]` | `isString` 재시도(`0x1401c8d85`), 그것도 실패면 값 미저장 |
| `rotationrandom.max` | `call 0x1401c8e90` | `asFloat 0x1401c8e9c` | 〃 | 〃 |

`sequencemultiplier` 가 브리프 함정 15 그대로다 — **게이트 실패는 0 이 아니라 1.0**이다.
"태그 게이트를 달았으니 실패하면 0" 으로 뭉뚱그리면 재생 배속이 0 이 된다.

`flags` 에는 별건이 하나 더 있다: 게이트 통과 후 `movzx ecx, al`(`0x1401c56e9`)로 **하위 1바이트만**
가져간다. 즉 실물의 def `flags` 는 0..255 로 잘린다. Waple 은 자르지 않는다 — **[미해결]**,
동봉 코퍼스 도달 0건이라 이번엔 손대지 않았다(§6).

### 3.2 게이트가 **없는** 자리 — 여기서 관용을 유지하는 것이 정합이다

| 키/자리 | VA | 근거 |
| --- | --- | --- |
| 초기화자 `exponent` ×7 | `0x1401c720f`(lifetime) · `0x1401c73e6`(size) · `0x1401c7798`(color) · `0x1401c8011`(alpha) · `0x1401c82df`(velocity) · `0x1401c901b`(rotation) · `0x1401c967f`(angularvelocity) | 일곱 전부 `op[]` 직후 `mov rcx,rax; call asFloat` |
| 오퍼레이터/컨트롤포인트 `flags` | 디스패처 내부, 게이트 목록에 없음 | def 최상위와 **다른 규약** |
| children `probability`/`maxcount` | `0x1401d13cc`(asFloat) · `0x1401d13f2`(asInt) | `op[](char*) 0x140086de0` 직후 바로 접근자 |
| 이미터 `rate`/`distance*`/`speed*` 등 | 위 §3 예시 | 〃 |

**종전 Waple 의 `pexponent` 는 여기서 틀려 있었다.** 그 헬퍼는 JSON 불리언을 배제했는데,
`exponent` 일곱 자리는 게이트가 없으므로 실물은 `{"exponent":false}` 를 **0.0** 으로 읽는다.
Waple 은 nil → `?? 1` 로 1.0 이었다. 이번에 `pexponent = pfloat` 로 되돌렸다.
(반대 방향 divergence — "불리언은 숫자가 아니다" 를 자리 확인 없이 일반화한 결과다.)

### 3.3 `rotationrandom.min/max` — 게이트를 뜨다가 함께 나온 실측 버그

이 두 자리는 파티클 디스패처에서 **초기화자 쪽 유일한 게이트**다. 세 갈래로 갈린다:

| 태그 | 동작 | VA |
| --- | --- | --- |
| 1/2/3 숫자 | `asFloat` → **z 성분에만** 쓴다 | `min` `movss [rbp+0xe8]`(`0x1401c8d78`) · `max` `movss [rbp+0x3d8]`(`0x1401c8ea1`) |
| 4 문자열 | `"x y z"` 를 임시 3성분 버퍼(`[rbp+0x278]`/`[rbp+0x284]`)에 풀고 통째로 복사 | 복사 `movsd [rbp+0xe0] ← [rbp+0x278]` + `mov [rbp+0xe8] ← [rbp+0x280]`(`0x1401c8e71`–`0x1401c8e87`) |
| 그 외 | 아무것도 안 쓴다 → 진입부 0-초기화(`0x1401c8cf9`·`0x1401c8d09`, `xmm1 = xmm13 = 0`) 그대로 | — |

**숫자 분기가 z 성분 전용이라는 것이 결정적이다.** 문자열 복사가 `[rbp+0x278+8]`(= 3번째 성분)을
`[rbp+0xe8]` 로 옮기므로, 목적지 벡터의 레이아웃은 `+0xe0` = x · `+0xe4` = y · `+0xe8` = z 이고
숫자 분기는 그중 **z 만** 건드린다. x·y 는 0 으로 남는다. 2D 회전이 z 축인 것과 일치한다.

종전 Waple 은 `pvec3`(문자열 전용)만 썼다 — **숫자 저작이 통째로 버려졌다.**
동봉 도달 **2건**(+ 설치본 사본 2 = 파일 4개):
`presets/lightshafts/particles/presets/light_shafts_1.json` 과 그 프리뷰 사본
`presets/lightshafts/previewlightshafts1/particles/presets/light_shafts_1.json`,
둘 다 `rotationrandom {min: -0.4, max: -0.3}`. 종전에는 그 값이 무시되고 부재 기본
`max (0,0,2π)` 가 서서 **빛줄기가 좁은 −0.4…−0.3 rad 밴드 대신 풀턴 랜덤으로 돌고 있었다.**
(전수: `rotationrandom` 인스턴스 189개 중 `min` 문자열 24 · 숫자 4, `max` 문자열 53 · 숫자 4.)

`injectedVec3ZScalar` 로 고쳤다 — 부재면 주입 상수, **있는데 못 읽히면 0 벡터**(주입은 부재에만
일어난다는 기존 `injectedVec3` 규약 그대로). 숫자 분기는 게이트 뒤에 있으므로 `numericFloat` 를 쓴다.

## 4. Waple 쪽 전수 — 어디서 숫자를 읽는가

`Sources/` 전수(정의 자체는 제외):

| 헬퍼 | 호출부 |
| --- | --- |
| `strictFloat` | `ParticleSystem.swift` 5 · `PropertyAnimation.swift` 1 |
| `strictInt` | `ParticleSystem.swift` 3 |
| `lenientFloat` | `WallpaperProperties.swift` 3 · `SceneDocument.swift` 3 |
| `lenientInt` | `Waple/WorkshopAPI.swift` 3 · `SceneDocument.swift` 1 |
| `safeInt(Double)` | `WapleRender` 11 · `EffectManifest` 7 · `AudioSpectrum` 5 · 그 외 4 |
| `stringVec3`/`floatList` | `ParticleSystem.swift` 1 · `SceneDocument.swift` 7 |

`strict*` 호출부가 적어 보이는 것은 **파일별 얇은 래퍼를 한 겹 거치기 때문**이다. 실제 자리 수:

| 파일 | 래퍼 | 자리(이번 변경 **후**) |
| --- | --- | --- |
| `ParticleSystem.swift` | `pfloat`(= `strictFloat`) | 40 (변경 전 42) |
| | `injected`(부재 시 상수 주입 + `pfloat`) | 90 |
| | `pint`(= `strictInt`) | 32 (변경 전 34) · `injectedInt` 5 |
| | `pvec3` 22 · `pvec3OrScalar` 10 · `injectedVec3` 10 · `injectedVec3OrScalar` 5 |
| | **`numericFloat` 2 · `numericInt` 2 · `injectedVec3ZScalar` 2**(신규 게이트 자리) |
| | `pexponent`(= `pfloat`, 게이트 없음 확정) | 7 |
| | `pbool` | 6 |
| `SceneDocument.swift` | `float`(= `lenientFloat ∘ unwrapValue`) | 86 |
| | `intVal`(= `lenientInt ∘ unwrapValue`) | 39 |
| | `floats` 9 · `uintField` 10 · `weBoolOpt` 4 |
| `PropertyAnimation.swift` | 지역 `f`(= `isJSONBool` 게이트 + `strictFloat`) | `2642488` 이 이미 닫음 |
| `EffectManifest.swift` | 사설 `safeInt`(= `isJSONBool` 게이트 + `safeInt`) | 7 |

(표의 수는 **정의 줄을 뺀 호출부**다. `SceneDocument` 수치는 2026-08-21 기준이고 다른 에이전트가
동시에 손대고 있어 병합 시점에는 달라질 수 있다.)

숫자로 읽는 **키 이름**은 113종이다(파티클 109 · 애니 4 · 이펙트 2, 중복 제거).

### 4.1 이미 저장소에 있던 관례

`CFGetTypeID(n) == CFBooleanGetTypeID()` 판정은 이미 여러 파일에 있다 —
`ProjectJSONParser` · `TexImage` · `WallpaperProperties` · `SceneDocument` ·
`WapleRender/UserPropertyStore` · `Waple/WorkshopAPI`(2026-08-21 기준 코드 14자리 + 주석 1).
`EffectManifest.isJSONBool` 은 같은 판정을 `objCType == "c"` 로 한다.
`ParticleSystem` 에 있던 유일한 사본(`pexponent`)은 이번에 없어졌다 — 그 자리가 게이트가
아니었기 때문이다(§3.2).
리눅스에는 `CFGetTypeID` 가 없어서 `scripts/dev/linux-shim/corefoundation.swift` 가
**`objCType == "c"` 로 대역**한다 — 즉 두 형태는 리눅스에서 동일하고, `objCType` 쪽만 시임 없이 선다.
새로 넣은 `isJSONNumeric` 은 `objCType` 형태를 쓴다.

## 5. 리눅스 실측 (macOS 는 단정하지 않는다)

`/opt/swift/usr/bin/swiftc`, swift-corelibs-foundation:

| 입력 | 런타임 타입 | `objCType` | `as? Double` | `as? Int` | `is Bool` |
| --- | --- | --- | --- | --- | --- |
| `JSONSerialization` 의 `true` | `__NSCFBoolean` | `c` | **1.0** | **1** | true |
| `JSONSerialization` 의 `false` | `__NSCFBoolean` | `c` | **0.0** | **0** | true |
| `JSONSerialization` 의 `3` | `NSNumber` | `i` | 3.0 | 3 | false |
| `JSONSerialization` 의 `2.5` | `NSNumber` | `d` | 2.5 | 2 | false |
| **Swift 리터럴 `true`** | `Bool` | `c`(브리지 후) | **nil** | **nil** | true |
| `NSNumber(value: 1)` | `NSNumber` | `i` | 1.0 | 1 | **true** |

세 가지가 중요하다.

1. `2642488` 의 실측(`strictFloat(json true) == Optional(1.0)`)이 재확인됐다.
2. **Swift 딕셔너리 리터럴로는 이 경로가 재현되지 않는다.** `["k": true]` 의 값은 `Bool` 로 남아
   `as? Double` 이 nil 이다. 이 계약을 테스트로 잠그려면 **반드시 `JSONSerialization` 을 거쳐야 한다**
   (`TestSupport.json(_:)`). 리터럴로 쓴 테스트는 고쳐도 안 고쳐도 통과하는 유령 테스트가 된다.
3. `NSNumber(value: 1) is Bool` 이 **true** 다. 그래서 `v as? Bool` 로는 불리언을 가릴 수 없고
   `objCType`/`CFBoolean` 이 유일한 판정이다.

**macOS 는 단정하지 않는다.** `NSNumber` 동적 캐스트 규칙이 Darwin 과 corelibs 에서 다를 수 있고,
이 세션에서 macOS 를 실행할 수단이 없다. 다만 `isJSONNumeric` 은 세 갈래(NSNumber → `objCType`,
Swift `Bool`, Swift `Int`/`Double`)를 모두 덮으므로 **브리지 여부와 무관하게** 같은 답을 낸다.

## 6. [미해결] / 넘길 것

1. **(해소)** `SceneDocument.orthogonalprojection.width/height` 게이트 — 2026-08-21 에
   `numericInt` 로 닫혔다(`SceneDocument.swift` `orthoSize`). **남은 차이는 폭이다**:
   실물은 게이트 뒤에 `asUInt`(`0x14018758f`)를 부르므로 음수 저작이 32비트로 감기는데
   `numericInt` 는 64비트 그대로다. `numericUInt32` 로 바꾸는 패치안은 §7.
   동봉·설치본 코퍼스 도달 **0건**(불리언·문자열·음수 `width`/`height` 모두 0).
2. **파티클 def `flags` 의 1바이트 절삭**(`movzx ecx, al` `0x1401c56e9`). 실물은 0..255,
   Waple 은 무제한. 코퍼스 도달 0건이라 이번에 바꾸지 않았다 — 바꾸려면 `def.flags` 소비처
   (`worldspace` bit0 · `perspective` bit2)까지 같이 봐야 한다.
3. **(이번에 함께 고쳤음)** `rotationrandom.min/max` 의 숫자 분기 — §3.3. 남은 미확정은
   `pvec3OrScalar`(3축 브로드캐스트)를 쓰는 **다른** 자리들(`remapinitialvalue.min/max` ·
   `outputrange*` · `distancemax`)이 정말 브로드캐스트가 맞는지다. 그쪽은 게이트가 없어
   이번 임무 범위 밖이었고 확인하지 않았다.
4. **`EffectManifest` fbo `scale`/`width`/`height`/`fit` 은 실물이 게이트 없이 `asUInt` 로 읽는다**
   (`0x1401e77dd` · `0x1401e77ff` · `0x1401e782f` · `0x1401e7852`). Waple 의 사설 `safeInt` 는
   불리언을 거부한다 — 실물보다 **엄격한 의도된 하드닝**이고 코드 주석이 그렇게 적고 있다.
   버그가 아니라 정책이므로 그대로 둔다. 여기 적어 두는 것은 다음 스윕이 "누락" 으로 오인하지 않게 하기 위함이다.
   (같은 함수의 `bind[].index` 는 게이트가 **있고**(`0x1401e7ea7`) Waple 도 막고 있어 일치한다.)
5. **(부분 해소)** 종전 "어느 리더인지 미상" 이던 단발 게이트들의 **소속 함수**를 문자열
   전수로 확정했다(각 함수의 `.rdata` 문자열 `lea` 를 전부 뜬 것):

   | 게이트(`cmp`) | 함수 | 그 함수가 쥔 키 전부 | 판정 |
   | --- | --- | --- | --- |
   | `0x1401de4e2` | `0x1401de470–0x1401de741` | `parent` · `attachment` | 오브젝트 부모 결선 |
   | `0x1401993a0` | `0x140198e20–0x14019957b` | `paths` · `transforms` · `disabled` · `duration` · `eye` · `center` · `up` · `zoom` · `timestamp` | **카메라 경로** — 게이트는 `timestamp` |
   | `0x1401fad93`/`0x1401fadd0` | `0x1401fac50–0x1401fb498` | `material` · `width` · `height` · `fullscreen` · `nopadding` · `autosize` · `passthrough` · `solidlayer` · `projectlayer` · `instanced` · `size` · `instance` · `usertexturereference` | **이펙트 패스/레이어** — `width`/`height` 를 `asFloat` 로 읽는다 |
   | `0x1401e6689` | `0x1401e63b0–0x1401e6976` | `value` · `op` · `ge` · `gt` · `le` · `lt` | **이펙트 `condition`** — `{"value":N,"op":"ge|gt|le|lt"}` 의 우변 |
   | `0x1401fcc6c`/`0x1401fd258` · `0x14022310a`/`0x140223732` | `0x1401fcc20–0x1401fd32b` · `0x1402230c0–0x140223801` | `animation` · `autosort` · `index` | 두 함수가 **같은 키 셋**을 읽는다(브리프 함정 2 — 리더가 둘) |

   **`0x1401e6687` 을 "`combos` 좌변" 이라고 적은 종전 문장은 오귀속이다.** 그 자리는
   `find("value")`(`0x1401e6618`) 결과의 태그를 보고 `asUInt`(`0x1401e6696`)로 읽는다.
   바로 앞에서 형제 키 `op` 를 `asString` 으로 읽는 것(`0x1401e665a`)이 결정적 근거다.

   **[미해결] 남은 것**: (a) `parent` 는 씬에 `"35"` 문자열 사례가 있어 **리더가 둘일 가능성**을
   여전히 배제하지 못했다. (b) `autosort` 는 동봉·설치본 3,655 JSON 전수에 **0건**이라 그 두
   함수가 어느 스키마를 읽는지 확정하지 못했다. (c) `0x14013d2e1` 의 키는 `0x1404210f0`(memcpy)로
   **런타임에 조립**되므로 정적 귀속이 불가능하다.

## 7. 넘기는 패치안 (`Sources/WapleCore/SceneDocument.swift` — 다른 소유)

세 자리다. 전부 **폭**(`asUInt` 32비트)이 어긋난 것이고, 동봉·설치본 코퍼스 도달은 0이다.

### 7.1 정사영 크기 — `numericInt` → `numericUInt32`

`SceneDocument.swift` `orthoSize`(2026-08-21 기준 `:1640` 부근):

```swift
-            guard let w = numericInt(proj["width"]), let h = numericInt(proj["height"]) else { return nil }
+            // 게이트 뒤 접근자는 `asUInt`(`0x14018758f`)라 값이 **하위 32비트로 감긴다**.
+            // `numericInt` 는 64비트라 음수 저작에서만 갈린다({"width":-1} → 실물 4294967295).
+            guard let w = numericUInt32(proj["width"]), let h = numericUInt32(proj["height"]) else { return nil }
```

### 7.2 `lightconfig.*` — 게이트가 **없는** 자리인데 불리언을 막고 있다

`SceneDocument.swift:1264` 의 사설 `uintField` 는 `CFBooleanGetTypeID` 로 불리언을 걸러
0 을 돌려준다. 그런데 `general.lightconfig` 를 읽는 `0x140186c90` 함수의 게이트는 **3자리뿐**이고
(`refreshdelay`·`orthogonalprojection.width`·`…height`) `point`/`spot`/… 자리에는 없다 —
`0x140187775` 에서 `find` 로 꺼내 곧장 `asUInt` 로 읽는다. 즉 실물은 `{"point":true}` 를 **1** 로
읽는다. 도달: 동봉 `lightconfig` 2씬 모두 값이 정수라 **0건**.

```swift
-    private static func uintField(_ v: Any?, mask: Int) -> Int {
-        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return 0 }
-        let d = n.doubleValue
-        guard d.isFinite, d >= 0, d <= 4294967295, d == d.rounded(.towardZero),
-              let i = safeInt(d) else { return 0 }
-        return i & mask
-    }
+    /// 실물은 이 자리에 **게이트가 없다** — `0x140187775` 의 `find` 직후 바로 `asUInt`
+    /// (`0x140085ee0`)다. 그래서 불리언은 0/1 로 들어오고(`0x140085f07 setne`), 음수는
+    /// 하위 32비트로 감긴다. `strictUInt32` 가 그 규약 그대로다.
+    private static func uintField(_ v: Any?, mask: Int) -> Int {
+        (strictUInt32(v) ?? 0) & mask
+    }
```

`strictUInt32` 는 같은 모듈(`WapleCore`) 내부 자유함수라 import 없이 보인다.
`d == d.rounded(.towardZero)`(소수는 0) 규약이 `cvttsd2si`(0 방향 절삭)로 바뀌는 것도
실물 쪽이 맞다 — `{"point":1.5}` 는 실물이 1 이다.

### 7.3 `general.properties.<name>.order` — **[미해결]**, 리더가 둘이다

네이티브는 `0x140118b85`·`0x140119d00` 에서 게이트 + `asUInt` 로 읽는다. 그래서
`order: -2` 는 **4294967294** 가 되어 맨 뒤로 간다. 실측 도달 있음 —
설치본 `projects/defaultprojects/eagleflag/project.json` 의 `flagcolor1.order = -2` ·
`flagcolor2.order = -1`(동봉 WEAssets 에는 0건).

그런데 `WallpaperProperties.swift:138`–`143` 이 이미 적고 있듯 **브라우저 UI 는 JS
`sort((a,b) => a.order - b.order)` 로 음수를 정상 처리**한다. 어느 리더가 화면을 정하는지
(브리프 함정 2 — 핸들러가 둘)를 이 라운드에 확정하지 못했다. **확정 전에는 고치지 마라** —
`parseNumber` 를 `strictUInt32` 로 바꾸면 eagleflag 의 두 색 프로퍼티가 목록 맨 뒤로 간다.

---

## 8. 사다리 커버리지 — 실물 셋을 다 덮는가 (2026-08-21 추가)

`Sources/WapleCore/JSONNumerics.swift` 의 사다리는 **관용 폭** 한 축만 다뤘다:
`numeric* ⊂ strict* ⊂ lenient*`. §2.2 의 전건 귀속을 놓고 실물 셋을 세어 보면 축이 하나 더 있다 —
**값의 폭**이다.

| # | 실물 조합 | 자리 수 | Waple 대응 | 판정 |
| --- | --- | ---: | --- | --- |
| A | 게이트 + `asFloat` | 42 | `numericFloat` | 덮는다 |
| B | 게이트 + `asInt64` | 4 | `numericInt` | 덮는다(둘 다 64비트) |
| C | 게이트 + `asInt`(32비트 반환) | 2 | `numericInt` | 폭만 다름 — 도달 0(아래) |
| D | **게이트 + `asUInt`(하위 32비트)** | **35** | **없었다** | **이번에 `numericUInt32` 추가** |
| E | 게이트 없음 + `asFloat` | 201 (243−42) | `strictFloat` | 덮는다(불리언 1/0 포함) |
| F | 게이트 없음 + `asInt` | 77 (79−2) | `strictInt` | 폭만 다름 |
| G | 게이트 없음 + **`asUInt`** | 다수(예: `general.alignment.value` `0x140181fba` · `general.lightconfig.*` `0x140187775` 이후 · 이펙트 fbo `scale`/`width`/`height`/`fit`) | **없었다** | **이번에 `strictUInt32` 추가** |
| H | 씬의 문자열 숫자 관용(실물은 태그 4 에서 abort) | — | `lenientFloat`/`lenientInt` | 의도적 하드닝 |

즉 **구멍은 `asUInt` 하나였고, 그게 게이트 93자리 중 35(38%)를 차지한다.**

### 8.1 폭이 실제로 값을 바꾸는 경우 — 코퍼스 실측

범위: **동봉 WEAssets 1,698 + 설치본 `wallpaper_engine/assets` 1,698 + 설치본
`wallpaper_engine/projects` 259 = 3,655 파일**(워크샵 코퍼스는 이 컨테이너에 없다).
JSONC 63건은 관용 파서로 다시 읽었다. 숫자 리터럴 **33,753**개 · 불리언 **3,958**개.

| 측정 | 값 |
| --- | ---: |
| Int32 범위 밖 **정수** | **0** |
| `\|x\| ≥ 2^31` 인 **실수** | **0** |
| **음수 정수** | **131** |

따라서 32비트 절삭이 값을 바꾸는 경우는 **음수뿐**이다. 그 131개가 붙는 키(끝 두 마디 기준):
`back.x` 52 · `operator[].scale` 44 · `speedmax`/`speedmin` 각 6 · `outputrangemin` 6 ·
`timescale` 4 · `speedinner`/`speedouter` 각 4 · `distance` 2 ·
**`general.properties.flagcolor1.order` 1 · `flagcolor2.order` 1**(설치본
`projects/defaultprojects/eagleflag/project.json`) · 로케일 문자열 1.

그중 `asUInt` 로 읽히는 자리는 **`order` 둘뿐**이다(`scale` 은 파티클 오퍼레이터라 `asFloat`).
그래서 §7.3 이 이 라운드의 유일한 "도달 있는" 폭 차이이고, 리더가 둘이라 **미해결**로 남겼다.

### 8.2 넣은 것

```swift
func wrapUInt32(_ i: Int) -> Int          // 태그 1/2 — mov eax,[rcx] (0x140085f1e)
func wrapUInt32(_ d: Double) -> Int?      // 태그 3 — cvttsd2si eax (0x140085f12), 범위 밖은 nil
func strictUInt32(_ v: Any?) -> Int?      // 게이트 없음 — 불리언 0/1 (0x140085f07)
func numericUInt32(_ v: Any?) -> Int?     // 게이트 있음 — isNumeric 통과분만
```

`lenientUInt32` 는 **일부러 넣지 않았다** — 실물은 태그 4 에서 abort 하고 Waple 에도 `asUInt`
자리를 문자열로 읽는 호출부가 없다. 호출부는 하나도 바꾸지 않았다(§7 이 넘기는 패치안).

**범위 밖 실수를 nil 로 돌려주는 것은 의도적 하드닝이다.** x86 `cvttsd2si` 는 결과가 32비트에
안 들어가면(NaN·±Inf 포함) "integer indefinite" `0x80000000` 을 내는데, 그건 MXCSR invalid
마스크에 달린 값이고 이 컨테이너에서 실행으로 확인할 수단이 없다(**추정**). 값을 지어내는 대신
`safeInt`/`safeFloat` 와 같은 규약으로 거절한다 — 위 실측대로 도달 0건이다.
