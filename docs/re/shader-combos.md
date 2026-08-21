# 셰이더 콤보 / 퍼뮤테이션 시스템 복원

**측정일 2026-08-21 · WE 2.8.42 · `wallpaper64.exe`(imagebase `0x140000000`)**

대상은 WE 가 GLSL 소스를 **변형(퍼뮤테이션)해 컴파일**하는 경로 전체다 —
`// [COMBO]` 선언 · 머티리얼/씬의 `combos` · `#define` 주입 · `#if` 식 평가 ·
`#include` 해석 · 디스크 퍼뮤테이션 캐시 · 유니폼 주석(usershadervalues).

코퍼스는 두 트리다. **동봉**(`Sources/WapleRender/Resources/WEAssets/`)은 WE 설치본
`assets/` 와 **바이트 동일**(`diff -rq` 0건)이고, 여기에 설치본 전용 `projects/`
(WE 기본 배경 13씬)를 더한 것을 "설치본 전수"라 쓴다. 워크샵 pkg 는 이 컨테이너에 없다.

이웃 문서와의 경계: 엔진이 제공하는 `g_*` 유니폼 140종은 `docs/re/shader-uniforms.md` 가
다룬다. 이 문서는 **저작자가 만드는 쪽** — 콤보와 `material` 주석이 붙은 사용자 값 — 이다.
`.dxs` 퍼뮤테이션 캐시(§6)는 다른 문서에서 다룬 적이 없다.

재현 절차는 부록 A, 인용한 함수 범위는 부록 B.

---

## 0. 다섯 줄 요약

1. **`combos` 는 `{이름: 정수}` 딕셔너리 하나뿐이다.** 기본값 출처는 **셰이더 평문의
   `// [COMBO] {...}` 주석**이고, 런타임이 그 JSON 에서 실제로 읽는 키는 **`combo` 와
   `default` 둘뿐**이다(`0x14016db7c` / `0x14016dc2f`). `type`·`options`·`material`·
   `require` 는 **에디터 전용**이라 `wallpaper64.exe` 에 문자열조차 없다.
2. **머티리얼 패스의 `combos` 키는 엔진이 무조건 대문자로 바꾼다**(`0x140154599` 의
   `toupper` 루프). 바이너리 전체에서 `toupper` 호출부는 두 곳뿐이고 콤보 경로는 이
   한 곳이다. Waple 은 "선언된 `[COMBO]` 이름과 대소문자 무시 매칭"으로 근사하는데,
   설치본 실측 **소문자 저작 15종·56회 중 14종이 어떤 셰이더에서도 `[COMBO]` 선언이
   없어** 그 근사로는 안 맞았다. **[2026-08-21 착지]** `GLSLTranslator.translate` 진입에서
   무조건 대문자화로 바꿨다(§8-G3). 저작 자리 기준으로 다시 세니 종전 규약이 접던 것은
   **56건 중 0건**이었다.
3. **주입은 텍스트다** — 콤보마다 `#define <NAME> <10진값>\n` 을 소스 앞에 붙인다
   (`0x14016c400`). 값 0 도 붙으므로 **명시 0 인 콤보는 `#ifdef` 에서 참**이다.
4. **`#if` 식은 C 정수식 전문법이다** — `% & | ^ ~ << >> defined() 16진리터럴` 전부
   지원하고 우선순위 사슬도 C 와 같다(렉서 `0x140166a90`, 진입 `0x140167e10`, 사슬은
   `0x1401670c0`…`0x140167c00` — §3.7 표). 산술 폭은 **32비트**다.
   Waple 의 `ExprEval` 은 그중 8종을 명시 거부해 셰이더를 통째로 폴백시켰다.
   **[2026-08-21 착지]** 8종을 전부 평가하도록 넓혔다(§8-G2). 동봉 1,634개 `#if/#elif`
   식에서 그 8종은 **0회**라 회귀 폭 0(717 구성 MSL 지문 전건 동일), 워크샵에서만 효과가 있다.
5. **디스크 퍼뮤테이션 캐시가 실재한다** — `<pkg>/shaders/blobsSM40/<sha1 40자>.dxs`,
   매직 `SHDV0069`. 동봉 도달 **5건**(`assets/scenes/videoplayer/shaders/blobsSM40/`).
   키는 SHA-1(백엔드 정수 ‖ 셰이더 이름 ‖ 값≠0 콤보의 이름+값 ‖ 텍스처 콤보 블록).

---

## 1. `// [COMBO]` 선언 — 스캐너와 스키마

### 1.1 스캐너는 줄머리 완전일치다

선언 스캔은 `0x14016ce60`–`0x14016e0c8` 이 한다(이하 **DECL**). 줄 단위로 돌면서:

| 주소 | 명령 | 뜻 |
|---|---|---|
| `0x14016da10`–`0x14016da2a` | `memcmp(line, "// [", 4)` | 줄이 **정확히** `// [` 로 시작해야 한다 |
| `0x14016da37`–`0x14016da62` | `memcmp(line+4, "COMBO]", 6)` | 그 다음이 `COMBO]` |
| `0x14016da9f` | JSON 파서 호출(`0x1401668f0`) | `// [COMBO]` **뒤부터** 파스 |
| `0x14016de18`–`0x14016de3d` | `memcmp(line+4, "PASS]", 5)` | `// [PASS]` 분기 |

문자열 실물은 `.data` 의 전역 `std::string` 세 개다 — `0x1404dfd00`=`"// ["`,
`0x1404dfcc0`=`"COMBO]"`, `0x1404dfce0`=`"PASS]"`.

**선행 공백도, `//[COMBO]` 도, `// [ COMBO]` 도 안 걸린다.** 설치본 전수에서
`[COMBO]`/`[PASS]` 가 등장하는 313줄이 **313/313 전건** 이 규약을 지킨다.

그래서 자산에 있는 아래 세 줄은 **엔진이 읽지 않는다**(저자가 이름을 바꿔 꺼 둔 것):

| 파일:줄 | 원문 |
|---|---|
| `effects/waterflow/shaders/effects/waterflow.frag:2` | `// [OFF_COMBO] {"…","combo":"POSITION",…}` |
| `effects/waterripple/shaders/effects/waterripple.frag:2` | `// [COMBO_OFF] {"…","combo":"SPECULAR",…}` |
| `shaders/generic3.frag:7` | `// [COMBO_DISABLED] {"…","combo":"DOUBLESIDEDLIGHTING",…}` |

### 1.2 런타임이 읽는 키는 두 개다

`[COMBO]` 줄의 JSON 에서 DECL 이 꺼내는 것:

| 키 | 읽는 주소 | 규약 |
|---|---|---|
| `combo` | `find` `0x14016db7c` → `asString` | 콤보 이름. 레코드 `+0x30` 에 저장 |
| `default` | `find` `0x14016dc2f` → `isIntegral` `0x14016dd15` → `asInt` `0x14016dd21` | 정수. `isIntegral` 이 거짓이면 `0`(`0x14016dd2b`). 레코드 `+0x50` |

`0x1400886e0` 은 jsoncpp `isIntegral()` 이다(타입 태그 1=int·2=uint 즉시 참, 3=real 은
정수값·범위 검사, 그 외 거짓). 따라서 **`"default": 1.5` → 0**, **`"default": "1"` → 0**,
**`"default": true` → 0**, **키 부재 → 0** 이다.

나머지 키(`material`·`type`·`options`·`require`)를 읽는 코드는 `wallpaper64.exe` 에 없다.
근거는 두 겹이다 — (a) DECL 안의 `Json::Value::find` 호출은 **7개뿐**이고 그 키가
`material`·`default`·`combo`·`combo`·`formatcombo`·`combo`·`default` 다(§7.1 이 앞 다섯
개를 쓴다), (b) **문자열 자체가 없다**:

| 문자열 | `wallpaper64.exe` |
|---|---|
| `combos` `usershadervalues` `constantshadervalues` `usertextures` `keepaspect` `usertexturereference` `formatcombo` `components` `material` `conversion` `combo` | 있다 |
| `options` `imageblending` `audioprocessingoptions` `range` `label` `group` `hidden` `linked` `nobindings` `nonremovable` `paintdefaultcolor` `painttexturescale` `requireany` `attachmentproject` `attachmentangles` | **런타임 소비처 없음**(§9 배제한 가설 참조) |

### 1.3 설치본 전수

셰이더 파일(`.frag`/`.vert`/`.geom`/`.h`) 동봉 **502개**(effects 346 · shaders 136 ·
presets 8 · scenes 8 · zcompat 4), 설치본 `projects/` 90개 추가.

`[COMBO]` 줄 **331건 / JSON 파스 실패 0건**. 키 도수:

| 키 | 건수 | 런타임이 읽나 |
|---|---|---|
| `combo` | 331 | ✅ |
| `material` | 318 | ❌ 에디터 |
| `default` | 316 | ✅ |
| `type` | 268 | ❌ 에디터 |
| `options` | 84 | ❌ 에디터 |
| `require` | 25 | ❌ 에디터 |

`type` 값: `options` 193 · `imageblending` 52 · `audioprocessingoptions` 2 · 부재 63(동봉만).
`options` 값 형태: **딕셔너리 76건**(`{"로컬키":정수}`), **정수 배열 8건**(`[0,1,2,3]`).
`default` 값: 전건 정수 아니면 부재 — 정수 316건(0~3 이 277건, 그 밖 `31`·`32`·`30`·`22`·
`12`·`9`·`7`·`5`·`4`), 부재 15건.

`require` 는 **문자열 식이 아니라 `{콤보:정수}` 딕셔너리**다(AND). 전수 25건:
`{"LIGHTING":1}` 12 · `{"DIRECTDRAW":0}` 8 · `{"WRITEALPHA":0}` 2 · `{"TRANSFORMUV":1}` 2 ·
`{"RAYMODE":2}` 1. 짝인 `requireany:true` 8건은 "AND 를 OR 로 바꿈"이지만 **둘 다
에디터 전용**이다(§4.4).

콤보 이름은 **81종 전부 대문자**(소문자·혼합 0종). 내역은 `[COMBO]` 선언 68종 +
샘플러/`components` 주석의 `combo` 13종(`COLLISIONMASK` `DOUBLEBUFFERED` `DYEEMITTER`
`EMISSIVE_MAP` `MASK` `METALLIC_MAP` `NORMALMAP` `OFFSET` `OPACITYMASK` `PBRMASKS`
`REFLECTION_MAP` `ROUGHNESS_MAP` `TIMEOFFSET`).

`[COMBO]` 2개 이상인 셰이더 **64개**. 최다는 `assets/shaders/foliage4.frag` 8개와
`assets/zcompat/scene/shaders/2084198056/Simple_Audio_Bars.frag` 8개, 그다음
`effects/fluidsimulation/shaders/effects/fluidsimulation_combine.frag` 6 ·
`shaders/chroma4.frag` 6 · `shaders/fur4.frag` 6 · `shaders/generic4.frag` 6.

### 1.4 스캔 시점 — 인클루드 **뒤**, 스테이지 **합집합**

DECL 의 유일한 호출자 `0x1401a5c40` 안에서 순서가 못 박혀 있다:

```
0x1401a6ef3  call 0x140162100   ; vert 의 #include 해석
0x1401a6f30  call 0x140162100   ; frag 의 #include 해석
0x1401a6f60  call 0x14016ce60   ; DECL(vert)  ─┐ 출력 컨테이너 3개가 같은 주소
0x1401a6f76  call 0x14016ce60   ; DECL(frag)  ─┘ ([rbp-0x10]/[rbp+0x30]/[rbp+0x70])
```

즉 **헤더 안의 `[COMBO]` 도 보이고**, 선언 집합은 **vert ∪ frag** 다.
동봉 헤더 14개(`shaders/*.h` 12 + `shaders/base/*.h` 2)에 `[COMBO]` 는 **0건**이라
첫 번째 성질의 실측 도달은 0 이다. 두 번째는 Waple `GLSLTranslator.swift:171-176` 이
같은 합집합을 취한다.

### 1.5 `// [PASS]`

`// [PASS] shadow shadowcasterfoliage4` 꼴. DECL 이 두 번째 토큰을 `"shadow"`
(`0x14048d0d8`)와 비교하고(`0x14016de6f`–`0x14016de79`) 세 번째 토큰을 그림자 패스
셰이더 이름으로 쓴다. 동봉 3건뿐 — `shaders/foliage4.frag:2`(→`shadowcasterfoliage4`) ·
`shaders/chroma4.frag:2`(→`shadowcaster`) · `shaders/fur4.frag:2`(→`shadowcasterfur4`).
Waple 은 이 선언을 읽지 않는다(그림자 패스는 `Mesh3DShaders` 네이티브 경로).

---

## 2. 콤보 값의 출처와 병합

### 2.1 `combos` 스키마 — 딕셔너리 하나

머티리얼 패스든 이펙트 패스든 형태가 같다:

```json
"passes": [{ "shader": "...", "combos": { "LIGHTING": 1, "BLENDMODE": 2 } }]
```

파서는 `0x140154480`–`0x140155668`(호출자 `0x1401515b0` 의 두 자리 — 씬 인라인 패스
`0x140151970`, 머티리얼 JSON 로드 `0x1401519c2`). `combos` 조회는 `0x1401544da`,
타입 태그 7(object) 아니면 통째로 버린다(`0x140154500`).

**값 타입**: 멤버를 순회하며 정수로 읽는다. 실측 코퍼스는 전건 정수다 —
설치본 전수 `combos` 사용 262회 중 비정수 값 0건.

### 2.2 키는 **무조건 대문자로 바뀐다** (`0x140154599`)

```
0x14015458c  mov  r13, rax           ; 새 버퍼
0x140154592  mov  rsi, r12           ; 원본 키 시작
0x140154595  movsx ecx, byte [rsi]
0x140154598  call 0x1402bfb48        ; toupper
0x1401545a0  mov  [r14], al
0x1401545aa  jne  0x140154595        ; 키 끝까지
```

`0x1402bfb48` 이 `toupper` 라는 근거는 본문이다 — `lea eax,[rcx-0x61]` +
`cmp eax,0x19` + `add ecx,-0x20`(= `'a'..'z'` 만 −0x20). 그리고 **바이너리 전체에서
이 함수를 부르는 곳은 두 함수뿐**이고(`0x14003dd40` 는 로케일 코드로 콤보와 무관),
콤보 경로는 `0x140154599` 단 하나다.

이펙트 **인스턴스** 레벨 `combos`(`objects[].effects[].combos`, `conditions` 의 좌변)는
`0x1401e731c` 에서 따로 읽히고 **대문자화하지 않는다**. 즉 대문자화는 "셰이더로 주입되는
패스 콤보"에만 걸린다.

### 2.3 저작 전수와 "선언 없는 콤보"

설치본 전수(`assets/` + `projects/`) `combos` 키 **66종 / 262회**. 그중 **소문자·혼합
15종 / 56회**:

| 키 | 회 | 첫 저작 자리 |
|---|---|---|
| `version` | 17 | `assets/materials/util/solidlayer_instance.json` |
| `spritesheet` | 11 | `assets/scenes/gifs/materials/background.json` |
| `normalmap` | 9 | `projects/defaultprojects/arsenal/materials/pistols/Pistol0101_D.json` |
| `lightmap` | 6 | 〃 |
| `vertexcolor` | 2 | `assets/materials/util/flatalphavertexcolor.json` |
| `detailinalpha` | 2 | `projects/defaultprojects/arsenal/…/planks.json` |
| `selfillum` `dots` `specularalpha` `maskpaintcolor` `metal` `paintwork` `clouds` `rays` `reflection` | 각 1 | `projects/defaultprojects/{ricepod,retro,fantasticcar,techno,arsenal}/…` |

동봉 `assets/` 만 보면 소문자는 3종 9회(`version` 6 · `vertexcolor` 2 · `spritesheet` 1).

그리고 **저작됐지만 어떤 셰이더도 `[COMBO]`/샘플러 주석으로 선언하지 않은 콤보가 37종**이다
(`BICUBIC` `BLOOM` `BLUR` `CLEARALPHA` `COLORFONT` `COMBINEDBG` `DIRECTDRAW` `DISPLAYHDR`
`DYE` `ENABLEMASK` `FULLSCREEN` `GRADIENT_FADE` `LINEAR` `MSDF` `PINCH` `SPIN` `SPRITESHEET`
`TEX1FORMAT` `TINT` `UPSAMPLE` `USERCOLORBLEND` `VERSION` `VERTICAL` `WORLDBLUR` + 소문자 13).
**선언은 기본값 공급과 에디터 UI 용일 뿐, 주입의 조건이 아니다** — 엔진은 맵에 있는 것을
그대로 `#define` 한다.

### 2.4 텍스처 슬롯 유래 콤보

두 번째 주입원은 텍스처 바인딩이다(`0x14016c800`, §3.3). 두 갈래다:

* 슬롯 주석의 `"combo"` — 그 슬롯에 텍스처가 묶여 있으면 `#define <combo> 1`.
  DECL 이 `0x14016d3e4` 에서 읽는다. 동봉 도수 94.
* 슬롯 주석의 `"components"` — 마스크 텍스처의 **채널별** 서브콤보. DECL 이 배열을
  `0x140086de0`(`0x14016d634`)로 잡고 원소마다 `combo` 를 `0x14016d72c` 로 읽는다.
  방출부(`0x14016c8d9`)가 텍스처 플래그의 비트 `0x100000 << i` 를 보고 채널 i 가 살아
  있을 때만 `#define <components[i].combo> 1` 한다. 동봉 8건, 전건 `PBRMASKS` 의
  `METALLIC_MAP`/`ROUGHNESS_MAP`/`REFLECTION_MAP`/`EMISSIVE_MAP`.
  `label` 은 읽지 않는다.

### 2.5 `TEXnFORMAT`

세 번째 주입원. 이름을 **런타임에 조립**한다(`0x1401a5c40` 안):

```
0x1401a695d  cmp byte [rbx+0x80], 0     ; 슬롯 주석의 formatcombo 플래그
0x1401a6976  call 0x140053e40           ; to_string(slot)
0x1401a697e  lea rdx, "TEX"             ; 0x14048ee70
0x1401a6992  lea rdx, "FORMAT"          ; 0x14048ee98
0x1401a69e4  mov [rax], edi             ; 값 = 실제 로드된 텍스처의 포맷 enum([tex+0x18])
```

`formatcombo` 자체는 DECL 이 `0x14016d94c` → `asBool` `0x14016d9ae` 로 읽는다.
**값이 0 이어도 심는다** — Waple 은 `code != 0` 으로 거른다(§8-G6).

동봉 `formatcombo:true` 23건. 실제로 0 이 아닌 코드가 붙는 자리는
`effects/refraction/shaders/effects/refract.frag:8`(슬롯 1) 한 곳이다.

### 2.6 병합 순서 — [미해결]

`[COMBO]` 기본값 · 머티리얼 `combos` · 씬 오버라이드 `combos` · 텍스처 유래 콤보를
**어느 순서로 한 맵에 합치는지**의 코드 자리는 못 짚었다. DECL 은 이름·기본값을 자기
레코드에 넣고(`0x14016dd6f`), `#define` 방출기는 이미 완성된 리스트를 받는다.
관측 가능한 계약(기본값이 적용되고, 저작값이 이긴다)은 자산 쪽에서 강제된다 —
`BLENDMODE` 기본 31, `WRITEALPHA` 기본 1, `POINTEMITTER` 기본 1 같은 **0 이 아닌
기본값 39건**이 저작 없이도 성립해야 그림이 맞는다. Waple `resolvePassCombos`
(`SceneRendererResources.swift:1016-1078`)가 같은 계약을 구현하고 있고 그 결과가
동봉 자산에서 검증되므로 여기서는 순서만 미확정으로 남긴다.

---

## 3. `#define` 주입

### 3.1 고정 프리앰블

`0x1400d5070`–`0x1400d7034`(컴파일 진입)가 소스 앞에 붙이는 것:

| 자리 | 내용 |
|---|---|
| `0x1400d5266` | `"#define HLSL 1\n#define HLSL_SM40 1\n"` (`0x140486898`) |
| `0x140162e02` | `"#define GS_ENABLED 1\n"` (`0x14048b998`) — 디바이스 능력 비트 `[dev+0x118]>>3 & 1` 일 때만 |
| `0x14016b100`–`0x14016b161` | 전처리기가 정의 맵에 `SHADERVERSION = "69"` 를 **1개** 넣는다(`0x14048d068`+`0x14048d078`) |

`SHADERVERSION` 초기 맵이 정확히 1항목이라는 근거는 삽입 루프의 종료 비교
`lea rax,[rbp+0x70]` / `jne 0x14016b1f0`(`0x14016b410`–`0x14016b42f`) 와 소멸 루프
`mov edi,1`(`0x14016b435`)이다 — stride `0x40`, 범위 `rbp+0x30`..`rbp+0x70` = 1회전.

### 3.2 값 있는 콤보 → `#define NAME <10진>\n` (`0x14016c400`–`0x14016c7fe`)

노드 레이아웃: `+0x00` 다음 포인터 · `+0x10` 이름(MSVC `std::string`, 크기 `+0x20`,
용량 `+0x28`) · `+0x30` **uint32 값**.

```
0x14016c443  "#define " 붙임 (8바이트)
0x14016c476  이름 붙임
0x14016c49c  0x20(공백) 한 글자
0x14016c5c5  [node+0x30] 을 10진 문자열로 (두자리 테이블 0x140474390)
0x14016c6a2  0x0a(개행)
0x14016c6a8  다음 노드
```

**값 0 을 거르지 않는다.** 그래서 `"combos":{"X":0}` 은 `#define X 0` 이 되고
`#ifdef X` 는 **참**이다. (값 0 을 거르는 것은 §6.2 의 캐시 키 계산뿐이다.)

방출 순서는 컨테이너 순회 순서 그대로다 — 정렬 여부는 **[미해결]**. 텍스트 전처리라
같은 이름이 두 번 나오면 뒤가 이긴다.

### 3.3 텍스처 콤보 → `#define NAME 1\n` (`0x14016c800`–`0x14016c984`)

`0x14048d0b4` = `" 1\n"`. 슬롯 레코드마다 (a) `+0x40` 문자열이 비어 있지 않으면
그 이름으로(`0x14016c872`–`0x14016c8ab`), (b) `+0x88`..`+0x90` 벡터(stride 0x40)를 돌며
`(0x100000 << i) & [tex+0x1c]` 이면 그 원소 이름으로(`0x14016c8e3`–`0x14016c930`) 방출.
값은 **항상 1**.

### 3.4 전처리기 지시문 전수 (`0x14016b0e0`–`0x14016c3f8`)

줄 인식은 정규식 `^\s*#\s*([a-z]+)\b\s*(.*)`(`0x14048d048`)이다 — **`#include` 와 달리
선행 공백과 `# if` 를 허용**한다. 이후 첫 캡처를 `memcmp` 로 가른다:

| 지시문 | 비교 주소 | 동봉 도수 |
|---|---|---|
| `define` | `0x14016b8e3` | 203 |
| `ifdef` | `0x14016bd26` | 68 |
| `ifndef` | `0x14016bde0` | 6 |
| `else` | `0x14016be73` | 307 |
| `endif` | `0x14016bf30` | 1657 |
| `if` | `0x14016bf9e` → 식 평가 `0x14016bfbc` | 1583 |
| `elif` | `0x14016c00b` → 식 평가 `0x14016c080` | 51 |
| `require` | `0x14016c0ec` → `0x140169140` | **8** |
| `undef` | `0x14016c201` | 1 |

**이 9종이 전부다.** `#version`·`#extension`·`#pragma`·`#error`·`#line` 은 없다(=
지시문으로 인식되지 않고 그대로 남는다).

### 3.5 `#require` — 지시문이 아니라 **코드 생성기**다

`#require LightingV1` 은 엔진에게 라이팅 유니폼 배열과 `PerformLighting_V1` 함수를
**문자열로 조립해 삽입**하라는 요청이다. 생성기는 `0x140169140`–`0x14016b0d4`(8,084 B),
이름 비교는 `0x1401691f8`(`"LightingV1"` = `0x14048be90`). 조각 문자열은
`0x14048be80` 부터 — `uniform vec4 g_LPoint_Color[`, `g_LSpot_Exponent[`,
`g_LSpot_Direction[`, `g_LSpot_Origin[`, `g_LDirectional_Color[`, `g_LDirectional_Direction[`,
`g_LTube_OriginA[`/`OriginB[`/`Color[`, `g_LFeature_ShadowProjection[`,
`g_LFeature_ShadowPointProjection[` … 그리고 본문 머리
`vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector, vec3 specularTint, vec3 ambient, float roughness, float metallic)` (`0x14048c070`).
배열 길이는 씬의 실제 라이트 개수로 채워진다.

동봉 도달 8건 — 그중 **6건이 조건부 밖(depth 0)** 이다:

| 파일:줄 | 중첩 깊이 |
|---|---|
| `effects/fluidsimulation/shaders/effects/fluidsimulation_combine.frag:52` | 0 |
| `shaders/foliage4.frag:74` · `chroma4.frag:86` · `fur4.frag:80` · `genericimage4.frag:90` · `generic4.frag:75` | 0 |
| `shaders/genericparticle.frag:68` · `genericropeparticle.frag:56` | 1 |

`#undef` 1건은 `shaders/genericparticle.frag:64`(`#undef DOUBLESIDEDLIGHTING`, depth 2).

#### 3.5.1 [2026-08-21 확정] 호출 규약 — 게이트·삽입 위치·미지의 이름

디스패처 쪽(`0x14016c0d2`–`0x14016c1e2`)을 끝까지 읽었다. 종전 절이 "삽입한다"까지만
적고 넘어간 것들이 전부 관측 가능한 계약이다.

**① 호출.** 이름 길이 7 + `memcmp "require"`(`0x14016c0ec`) → 빈 `std::string` 을 스택에
만들고(`0x14016c100`–`0x14016c11a`, SSO: size 0 @`[rbp+0x20]`, cap 0xf @`[rbp+0x28]`)
`0x140169140(요청이름, 매크로맵, &out)` 호출(`0x14016c127`).

**② 생성기가 빈 문자열을 돌려주는 조건이 셋이다** — 전부 `0x14016b0b2`(= `out` 을 손대지
않고 바로 에필로그)로 점프한다:

| 조건 | 판정 자리 |
|---|---|
| 요청 이름 길이 ≠ 10 | `0x1401691eb` (`cmp r8, 0xa`) |
| `memcmp "LightingV1"` 불일치 | `0x1401691f5` → `0x1401691ff` |
| 매크로맵에 **`LIGHTING` 이 없다** | 조회 `0x1401691b8`(`"LIGHTING"`=`0x140486930`) → `0x14016920c` `cmp rbx, r12` |
| `LIGHTING` 의 값 문자열을 정수로 읽어 **0** | `0x140169223` → `0x14016922a` `test eax,eax; je` |

즉 **`#require` 는 `LIGHTING` 콤보가 켜져 있을 때만 코드를 만든다.** 이름이 다르면
(`#require Whatever`) 조용히 아무것도 안 한다 — 에러도 경고도 없다.

**③ 삽입 위치는 "그 줄 자리"다, 파일 머리가 아니다.** 결과가 비어 있지 않으면
(`0x14016c12c` `cmp qword [rbp+0x20], 0`) 출력 버퍼(`[rbp+0x260]`)에 대해
`std::string::insert(줄시작오프셋, 생성문자열)`(`0x14016c15c` → `0x1400f9070`)을 부른다.
줄 시작 포인터 `[rbp-0x68]` 와 커서 `[rsp+0x70]` 를 데이터 포인터 기준 인덱스로 바꿨다가
(`0x14016c144`/`0x14016c159`) 삽입 길이만큼 밀어 되돌린다(`0x14016c16a`–`0x14016c18c`).

**자산이 이 사실을 독립적으로 증언한다**: 생성 코드가 쓰는 `COOKIE_SAMPLER` 를
8개 소비처가 전부 **`#require` 줄보다 앞에서** `#define` 한다
(`fluidsimulation_combine.frag:17` < `:52`, `foliage4.frag:30` < `:74`,
`genericparticle.frag:51` < `:68` …). 파일 머리에 주입한다면 그 매크로가 아직 없다.

**④ 지시문 줄은 언제나 소비된다.** require 분기는 `bl = 1`(`0x14016c1cc`)을 세우고 공통
꼬리(`0x14016bbb7`)로 간다. 거기서 `memset(줄시작, ' ', 줄끝-줄시작)`
(`0x14016bc63`–`0x14016bc71`, `0x1404217a0`=memset)로 **줄을 지우는 대신 공백으로 덮는다**
— 줄 번호를 보존하는 방식이다. 주입이 있었으면 위 ③ 에서 포인터가 이미 밀렸으므로
주입된 텍스트는 안 지워진다.

**⑤ `#require` 에는 emitting 가드가 없다.** 형제 `#define`(`0x14016b8f7`)·
`#undef`(`0x14016c215`)는 `test r13b, r13b` 로 비활성 분기를 건너뛰는데 require 경로에는
그 검사가 없다 — **거짓 `#if` 안의 `#require` 도 생성기를 부른다.** 동봉의 depth 1 두 건
(`genericparticle.frag:68` · `genericropeparticle.frag:56`)은 `#if LIGHTING` 안이라 관측
차이가 없다(가드가 있었어도 `LIGHTING==0` 이면 ② 에서 어차피 빈 문자열).

**⑥ 생성 내용 전수**(문자열은 전부 `0x14048b…`–`0x14048c…`, 방출 순서):
`uniform vec4 g_LPoint_Color[`/`g_LPoint_Origin[`(`0x140169573`/`0x1401695e3`) →
`g_LSpot_Color[`/`Origin[`/`Direction[`/`Exponent[`(`0x140169671`–`0x140169792`) →
`g_LTube_Color[`/`OriginA[`/`OriginB[`(`0x140169822`–`0x1401698fa`) →
`g_LDirectional_Color[`/`Direction[`(`0x140169987`/`0x1401699d0`) →
`uniform mat4 g_LFeature_ShadowProjection[` · `vec4 g_LFeature_ShadowProjectionTransform[` ·
`vec4 g_LFeature_ShadowPointProjection[` · `…PointProjectionTransform[`
(`0x140169a42`–`0x140169b3b`) → 본문 머리 `vec3 PerformLighting_V1(...)`(`0x14048c070`,
`0x140169bb2`) → 라이트마다 `{ const uint i = <n>u; … }` **언롤 블록** → `return light;\n}`
(`0x14016b0a3`).

배열 길이와 언롤 횟수는 매크로맵에서 읽는다 — `LIGHTS_POINT`(`0x140487630`, 12자 SSO
`movsd`+`mov dword` 로 스택에 조립 @`0x140169258`/`0x140169266`) ·
`LIGHTS_DIRECTIONAL`(`0x1404877e8`) · `LIGHTS_POINT_SHADOW`(`0x140487948`) ·
`LIGHTS_SPOT_SHADOW`(`0x140487878`) · `LIGHTS_SPOT_COOKIE`(`0x140487890`) ·
`LIGHTS_SPOT_SHADOW_COOKIE`(`0x1404877c8`) · `LIGHTS_DIRECTIONAL_SHADOW`(`0x140487828`).
그림자/쿠키 유무로 블록 본문이 갈린다(예: 그림자 포인트 = `CalculateProjectedCoordsPoint`
+ `PerformPointShadowMapping` + `ComputePBRLightShadow(..., shadowFactor)`,
비그림자 = 같은 호출에 `1.0`; 디렉셔널 그림자는 3-캐스케이드 `mix` 조립).
호출되는 헬퍼는 전부 `shaders/common_pbr_2.h` 에 있다 — `ComputePBRLightShadow`(:256) ·
`ComputePBRLightShadowInfinite`(:317) · `PointSegmentDelta`(:9) · `PerformShadowMapping`(:44) ·
`CalculateProjectedCoords`(:118) · `…Cascades`(:131) · `…Point`(:149). 그래서 8개 소비처가
전부 `#require` 앞에서 `#include "common_pbr_2.h"` 한다.

### 3.6 미정의 콤보 참조 = 0, `defined()` 지원

식 평가의 원자 파서는 `0x140167c00`–`0x140167e0c` 다.

* 식별자 토큰(코드 2)이 길이 7 이고 `"defined"` 이면(`0x140167ca1`–`0x140167cba`:
  `"defi"`+`"ne"`+`"d"` 3단 비교) `defined X` / `defined(X)` 를 처리해 정의 여부를
  `0x1401669a0` 으로 조회한다.
* **그 밖의 식별자는 `xor edi, edi`(`0x140167dbe`) — 즉 0** 이다. 정의된 매크로는
  식 평가 전에 텍스트 치환되므로 여기 오는 식별자는 곧 "미정의"다. C 와 같다.

동봉 코퍼스에서 `defined` 는 **0회**다(`common_pbr_2.h` 의 1회는 주석 안 영어 단어).

### 3.7 `#if` 식 문법 전수 — 렉서 토큰표 (`0x140166a90`–`0x1401670ba`)

| 토큰 | 코드 | 인식 주소 |
|---|---|---|
| 수 리터럴(10진/16진 `0x`, 접미 `u`/`f`/`l`) | 1 | `0x140166f92`(`'0'`) · `0x140167058`/`68`/`78` |
| 식별자 | 2 | `0x140166ba1`(`'_'` 포함) |
| `(` `)` | 3 · 4 | `0x140166dcf` · `0x140166ddf` |
| `!` `!=` | 5 · 7 | `0x140166e5f` |
| `==` | 6 | `0x140166e89` |
| `<` `<=` `<<` | 8 · 9 · 0x17 | `0x140166ea4` |
| `>` `>=` `>>` | 0xa · 0xb · 0x18 | `0x140166ee5` |
| `&&` `&` | 0xc · 0x13 | `0x140166f26` |
| `\|\|` `\|` | 0xd · 0x14 | `0x140166f4f` |
| `+` `-` `*` `/` `%` | 0xe · 0xf · 0x10 · 0x11 · 0x12 | `0x140166def`…`0x140166e2f` |
| `^` `~` | 0x15 · 0x16 | `0x140166e4f` · `0x140166e3f` |
| 그 외 문자 | 0x19 | `0x140166f78` |

주석(`//`, `/* */`)도 렉서가 건너뛴다(`0x140166aff`–`0x140166b28`).

**[2026-08-21 정정·확장] 파서 사슬을 단계별로 확정했다.** 종전 서술(`0x140167e10`(||) →
`0x140167390`(&&) → … → `0x140167ad0`(단항/곱나눗))은 중간이 "…" 로 비었고 마지막 두 단계의
이름이 틀렸다(`0x140167ad0` 은 단항이 아니라 **가감**, `0x140167b80` 이 곱나눗). 실제 사슬은
**C 와 완전히 같다** — 각 함수가 자기 토큰만 보고 다음 단계를 부른다(컴파일러가 아래 단계를
인라인해 놓아 한 함수 안에 여러 `cmp` 가 보이지만, 진입 시 첫 호출이 그 함수의 "다음 단계"다):

| 단계(느슨→촘촘) | VA | 토큰 판정 |
|---|---|---|
| `\|\|` | `0x1401670c0`→`0x1401670d0` | 0xd |
| `&&` | `0x140167390` | `cmp [rbx+8], 0xc` |
| `\|` | `0x140167520` | `cmp [rbx+8], 0x14` |
| `^` (같은 함수에 `&` 루프 인라인) | `0x1401675e0` | `cmp eax, 0x15` @`0x14016761a` |
| `&` | 〃 | `cmp eax, 0x13` @`0x1401675f7` |
| `==` `!=` | `0x140167680` | `lea edx,[rbp-6]; cmp edx,1` @`0x1401676a9` |
| `<` `<=` `>` `>=` | `0x140167850` | `lea ecx,[rbx-8]; cmp ecx,3` @`0x1401676d7` |
| `<<` `>>` | `0x1401679d0` | `lea edx,[r13-0x17]; cmp edx,1` @`0x1401679f4` |
| `+` `-` | `0x140167ad0` | `lea ecx,[rbp-0xe]; cmp ecx,1` @`0x140167a17` |
| `*` `/` `%` | `0x140167b80` | `lea eax,[rdi-0x10]; cmp eax,2` @`0x140167ba3` |
| 단항·원자 | `0x140167c00` | `!`(5)@`0x140167c10` · `~`(0x16)@`0x140167c17` · `-`(0xf)@`0x140167c20` · `+`(0xe)@`0x140167c29` · 수(1) · 이름(2) · `(`(3)@`0x140167d48` |

`0x140167e10` 은 사슬의 한 단계가 아니라 **`#if`/`#elif` 진입점**(디스패처가 `0x14016bfbc`/
`0x14016c080` 에서 부른다)이다.

**산술 폭은 32비트다.** 전 구간 `eax`/`esi` — `imul ebx,ecx`(`0x140167bc2`) ·
`cdq; idiv ecx`(`0x140167bd2`) · `and esi,eax`(`0x140167610`) · `xor esi,edi`(`0x14016765a`) ·
`not eax`(`0x140167e04`) · `neg eax`(`0x140167de2`). 세 가지 가드가 특히 관측 가능하다:

* **0 나눗셈은 트랩이 아니라 0.** `/`(`0x140167bcc`)·`%`(`0x140167bdc`) 둘 다
  `test ecx,ecx; je 0x140167be9`(`xor ebx,ebx`)로 빠진다 — `idiv` 를 아예 안 돈다.
* **시프트량은 부호 없는 비교로 31 초과면 결과 0.** `cmp ebp,0x1f; ja 0x140167aaa`
  (`xor r15d,r15d`) @`0x140167a8e`. 음수 시프트량도 u32 로는 > 0x1f 라 0 이다.
  통과하면 `shl`(`<<`) / **`sar`**(`>>`, 산술) 이다(`0x140167a98`–`0x140167aa1`).
* **미정의 이름·미지 문자는 0**, 그리고 **파서는 잔여 토큰을 그냥 버린다**(관용).

**수 리터럴 문법**(`0x140166f90`–`0x14016708b`):
`'0'` 뒤 `add al,0xa8; test al,0xdf`(`0x140166f9c`)로 `x`/`X` 를 가려 16진 분기 →
`esi = esi*16 + digit`(`shl esi,4` @`0x140166fe7`), 아니면 10진 `esi = esi*10 + digit`
(`0x140167007`–`0x140167019`). 그 다음 **`.` 이 오면 소수부를 읽고 버린다**
(`0x140167021`–`0x140167046` — `esi` 를 안 건드린다. 즉 `#if 1.5` 는 **1**). 마지막으로
`tolower(c) ∈ {u, f, l}` 접미를 **여러 개** 소비한다(`0x140167058`/`68`/`78`).
접미가 아닌 글자가 붙으면(`1e5`) 수는 거기서 끝나고 나머지는 **식별자 토큰**이 된다.

**삼항 `?:` 는 없다** — `?`/`:` 는 코드 0x19 로 떨어진다.

**동봉 실측 — 등장 vs 미등장.** `#if`/`#elif` 식 **1,634건** 기준:

| 구문 | 등장 | 파일 |
|---|---|---|
| `==` | 675 | 187 |
| `\|\|` | 129 | 39 |
| `<` `>` `<=` `>=` | 53 | 9 |
| `&&` | 43 | 18 |
| 괄호 | 18 | 14 |
| `!=` | 6 | 5 |
| 단항 `!` | 1 | 1 |
| **`%` · 단일 `&` · 단일 `\|` · `^` · `~` · `<<` · `>>` · 16진 리터럴 · 접미 리터럴 · `?:` · `defined`** | **0** | 0 |

즉 **문법상 가능한데 동봉 코퍼스에 한 번도 안 나오는 것이 11종**이다. 이게
§8-G2 의 위험 등급을 정한다.

---

## 4. `conditions` — FBO·패스·바인드 게이트

### 4.1 문법은 딕셔너리 배열이다 (문자열 식이 아니다)

```json
"conditions": [ { "LIGHTING": 1 } ]
"conditions": [ { "POINTEMITTER": { "op": "ge", "value": 1 } } ]
```

평가기는 `0x1401e63b0`–`0x1401e6976`. 규약은 이미 `Sources/WapleCore/EffectManifest.swift:7-88`
이 명령 주소까지 달아 확정해 뒀고, 이번 재검증에서 **정정할 것을 못 찾았다**. 요지만
옮기면: 맨몸 값은 `==`(`>=` 아님, `0x1401e68c3`+`0x1401e68ca`) · 명명 연산자는
`ge`/`gt`/`le`/`lt` 4종 + 등호 폴백(`0x1401e67b7`) · 누산은 전부 AND(6지점 전건 `cmov`)
· 배열이 아니면 true(fail-open, `0x1401e63d1`) · 우변 비정수는 조건 통째 무시,
좌변 비정수는 0.

**`COMBO==1`·`&&`·`||`·`!`·괄호 같은 문자열 식 문법은 이 경로에 존재하지 않는다.**
파서가 문자열을 받는 자리 자체가 없다(우변 태그 4는 `0x1401e65fe` 에서 스킵).

### 4.2 등장 / 미등장

설치본 전수(`assets/`+`projects/`, 관대 JSON 복구 포함 1,957 파일):

| 경로 | 건수 |
|---|---|
| `passes[].conditions` | 2 |
| `passes[].bind[].conditions` | 4 |
| `fbos[].conditions` | 2 |
| **보유 파일** | `assets/effects/fluidsimulation/effect.json` 4 + 그 preview 사본 4 |

**값 형태는 8/8 전건 맨몸 정수**다. `{"op":…,"value":…}` 형태는 `conditions` 에
**한 번도 등장하지 않는다**(문법상 가능·미등장). `op` 문자열이 자산에 나오는 자리는
`gizmos[].condition` 14건뿐이고 전건 `"ge"` — `gt`/`le`/`lt` 는 코드에만 있고
자산 도달 0 이다.

### 4.3 `gizmos[].condition` 은 **다른 문법**이다

에디터 기즈모 표시 조건이고 형태가 `{"POINTEMITTER":{"op":"ge","value":1}}` 인
**단수 `condition`, 배열 없음**이다. 보유 파일 10+(fluidsimulation · waterwaves ·
watercaustics · cursorripple · clouds · waterripple · reflection …). 런타임 렌더에는
쓰이지 않으므로 Waple 이 안 읽는 것이 맞다.

### 4.4 셰이더 주석의 `require`/`requireany` 도 다른 문법이다

`{콤보:정수}` AND 딕셔너리(+`requireany:true` 면 OR). §1.2 대로 두 문자열 모두
`wallpaper64.exe` 에 없다 — **에디터 전용 UI 게이트**다. 자산 도달: `require` 45
(COMBO 줄 25 + 유니폼 주석 20), `requireany` 8.

### 4.5 또 다른 조건식 — 프로퍼티 UI (혼동 주의)

`0x140488c78` 에 `alignment.value<2&&check` 라는 **문자열 식**이 있다. 이건 `project.json`
`general.properties[].condition`(브라우즈/속성 UI) 계열이고 셰이더 콤보와 무관하다.
Waple 은 이 문법을 `PropertyConditionEvaluator.swift` 에서 따로 다룬다 — 두 체계를
합치면 안 된다.

---

## 5. `#include` 해석 (`0x140162100`–`0x140162ab9`)

| 성질 | 실측 |
|---|---|
| 인식 | `memcmp(line, "#include", 8)`(`0x1401622f4`) — **줄머리 완전일치**. 선행 공백 불가 |
| 이름 | 첫 `"` 와 그다음 `"` 사이(`0x140162363`·`0x1401623af`, 구분자 `0x22`). `<…>` 형식 없음 |
| 검색 경로 | **`shaders/` 접두 하나뿐**(`0x140162659` 가 `0x14048b9b0`=`"shaders/"` 를 SSO 로 적재해 이름 앞에 붙임) |
| 재귀 | `0x1401626a1` 에서 자기 자신 호출 |
| 순환 방지 | **include-once**. 이미 인라인한 이름 리스트를 선형 탐색해(`0x1401624b0`–`0x1401624f4`, `memcmp`) 걸리면 그 줄을 **건너뛴다**(`0x14016250d` → `0x1401627a4`). 깊이 카운터는 없다 |
| 범위 | 스테이지마다 리셋(SHC `0x140162ee0`/`0x140162f2e` 이 컨테이너를 새로 만든다) |

동봉 `#include` **228회 / 이름 14종**:
`common.h` 72 · `common_blending.h` 56 · `common_perspective.h` 24 · `common_fragment.h` 19 ·
`common_vertex.h` 14 · `common_pbr_2.h` 9 · `common_fog.h` 8 · `common_blur.h` 7 ·
`base/model_vertex_v1.h` 5 · `common_pbr.h` 4 · `common_particles.h` 4 ·
`base/model_fragment_v1.h` 3 · `common_foliage.h` 2 · `common_composite.h` 1.
**전건 선행 공백 없음**(0/228). 서브디렉터리는 `base/` 하나.

헤더가 헤더를 부른다: `common_composite.h` → `common.h`+`common_blending.h`,
`common_pbr.h` → `common.h`, `common_pbr_2.h` → `common.h`,
`base/model_fragment_v1.h` → `common_fragment.h`, `base/model_vertex_v1.h` → `common_vertex.h`.

**include-once 가 없었다면 중복 인라인이 나는 셰이더는 동봉 169개(인클루드 보유) 중 0개**다
— 같은 파일에서 같은 헤더를 두 번 쓰는 자산이 없다. 즉 이 성질의 실측 도달은 0 이고,
워크샵 잠복 항목이다(§8-G4).

---

## 6. 퍼뮤테이션 캐시

### 6.1 디스크 캐시가 있다 — `.dxs`

경로 조립은 `0x1400d5070` 안:

```
0x1400d5279  ".dxs"        (0x1404868d4)
0x1400d528b  "blobsSM40/"  (0x1404868c8)
0x140163124  call 0x14016c990   ; SHA-1 hex 40자
0x14016313c/0x14016314c  "shaders/" + "blobsSM40/" + <sha1> + ".dxs"
```

**동봉 도달 5건** — `assets/scenes/videoplayer/shaders/blobsSM40/*.dxs`
(`011d928b…` 2,887 B · `1aa4fb0a…` 3,670 B · `381e2d24…` 3,670 B · `4889eab2…` 3,072 B ·
`be980a71…` 1,610 B). 파일명이 곧 SHA-1 40자다.

파일 포맷(5/5 전건 동일):

```
0x00  "SHDV0069"        매직 8바이트
0x08  0x00              1바이트
0x09  uint32 size1      DXBC(정점) 길이
0x0d  DXBC blob1
      8바이트 0x00
      uint32 size2      DXBC(프래그먼트) 길이
      DXBC blob2
      꼬리 61~222 B     [미해결] — 반사/유니폼 테이블로 보이나 구조 미확정
```

### 6.2 캐시 키 = SHA-1 (`0x14016c990`–`0x14016cd95`)

SHA-1 초기화 `0x14016c9ae`–`0x14016c9ef`, 블록 압축 `0x1400802f0`. 입력을 넣는 순서:

| 순서 | 내용 | 주소 |
|---|---|---|
| ① | **int32** — 디바이스 가상함수 `[[dev+0x1518]]+0x30` 의 반환(백엔드/셰이더모델 식별자로 보인다, 정체 **[미해결]**) | 준비 `0x14016310c`, 해싱 `0x14016ca26` |
| ② | 셰이더 이름 문자열 | `0x14016ca05` 로 복사 후 `0x14016cb20`~ |
| ③ | 콤보 시퀀스(`0x14016cbdf` 가 만든 목록)를 돌며 **값이 0 이 아닌 것만**(`0x14016cbf8` `cmp dword [rsi+0x20], 0` → skip) 이름 문자열 + int32 값 | `0x14016cc1e`, `0x14016cc3b` |
| ④ | `[r12+8]≠0` 이고 `[rbp+0x7f]≠0` 이면 §3.3 텍스처 `#define` 블록 문자열 통째로 | `0x14016cd43` → `0x14016cd5f` |

**값 0 콤보가 키에서 빠진다**는 게 요점이다 — `X=0` 과 `X` 미지정은 같은 blob 을 쓴다
(주입 텍스트는 다르지만 `#ifdef` 만이 그 차이를 볼 수 있고, 자산이 그 조합을 안 쓴다).

### 6.3 전처리 결과 캐시 — mtime + 매직 게이트 (`0x140162ac0`–`0x140163693`)

컴파일 전에 캐시 파일이 최신인지 본다:

```
0x140163336–0x14016337b  vert/frag 원본의 mtime 최대값(maxsd)
0x140163390–0x1401633f3  인클루드된 헤더 전부에 "shaders/" 를 붙여 mtime 최대값 갱신
0x1401634c8–0x1401634f9  캐시 파일 첫 8바이트를 읽어 memcmp("SHDV0069")
0x1401634fd              불일치면 캐시 mtime = -1.0 (항상 낡음)
0x14016353c–0x140163573  캐시가 더 새것이면 전처리 3회(vert/frag/geom)를 통째로 건너뛴다
```

즉 무효화 축은 **(a) 원본·헤더 mtime, (b) 매직 문자열** 두 개다. 콤보 조합은
**파일명(SHA-1)** 이 가른다.

### 6.4 메모리 캐시

같은 프로세스 안의 중복 컴파일 회피는 확인하지 못했다 — **[미해결]**.

---

## 7. `usershadervalues` — 사용자 속성 → 유니폼

### 7.1 셰이더 측: 유니폼 꼬리 주석

형태는 `uniform <타입> <이름>; // { … }` 이고, 선언 파스에 정규식
`(\w+)\s*(\[[\d\w\s]+\])?\s*;`(`0x14048b9d0`)과
`^uniform[\s]+(sampler[\w]*)[\s]+g_Texture([\d]+)`(`0x14048d100`)를 쓴다.
후자가 **텍스처 슬롯 번호를 유니폼 이름에서 뽑는다** — 슬롯은 `g_TextureN` 의 N 이지
선언 순서가 아니다.

**런타임이 읽는 주석 키는 7개뿐**이다:

| 키 | 읽는 함수·주소 | 용도 |
|---|---|---|
| `material` | DECL `0x14016d209`, 바인더 `0x1401636a0` 의 `0x14016381b` | 사용자 속성 이름(= `usershadervalues` 의 우변) |
| `default` | DECL `0x14016d38f`, 바인더 `0x1401639c3` | 기본값. 문자열이면 공백/콤마 구분 성분 |
| `combo` | DECL `0x14016d3e4` | 텍스처 슬롯이 묶이면 켜는 콤보 |
| `components[].combo` | DECL `0x14016d634`/`0x14016d72c` | 채널별 서브콤보 |
| `formatcombo` | DECL `0x14016d94c`(+`asBool` `0x14016d9ae`) | `TEXnFORMAT` 주입 여부 |
| `conversion` | 바인더 `0x140163c09` | 값 변환. **`rad2deg`(`0x140163cb2`)와 `startdelta`(`0x140163cdf`) 2종뿐** |
| `type` | 바인더 `0x140163e3d` | **`color`(`0x140163ee3`) 하나만 비교**한다 |

바인더는 GLSL 타입도 본다 — `vec2`(`0x140163df9`) `vec3`(`0x140163d59`)
`vec4`(`0x140163dac`) `sampler`(`0x1401637fb`).

`label` `range` `group` `hidden` `linked` `direction` `nobindings` `nonremovable`
`position` `order` `int` `mode` `paintdefaultcolor` `painttexturescale`
`attachmentproject` `attachmentangles` `require` `requireany` `format` 는 **에디터 전용**이다.

### 7.2 타입 전수 (설치본 `assets/` 기준)

`uniform` 선언 **2,311건 / 파스 실패 0**. GLSL 타입 분포:
`float` 782 · `sampler2D` 514 · `vec4` 326 · `vec2` 253 · `mat4` 227 · `vec3` 165 ·
`mat4x3` 11 · `sampler2DComparison` 9 · `mat3` 8 · `uint` 7 · `sampler3D` 1 ·
`sampler2DBackBuffer` 1.

주석 보유 1,487건, 그중 `material` 키를 가진 **사용자 값 1,180건**:

| GLSL 타입 | `type` | 건수 | 의미 |
|---|---|---|---|
| `float` | (없음) | 660 | 스칼라(슬라이더). `range:[a,b]` 로 범위 |
| `vec2` | (없음) | 224 | 2성분 |
| `sampler2D` | (없음) | 176 | 사용자 텍스처 슬롯 |
| `vec3` | `color` | 101 | **색** — 유일한 `type` 값 |
| `vec4` | (없음) | 13 | 4성분 |
| `vec3` | (없음) | 6 | 색이 아닌 3성분(방향 등) |

**`bool`·`int` 전용 유니폼 타입은 없다.** 정수·불리언 성격의 값은 (a) 콤보로 올라가거나
(b) `float` 유니폼에 `"int":true` 주석(4건, 에디터 전용 스피너 힌트)으로 표시된다.

`default` 값 형태(사용자 값 1,180 기준): `float` 350 · `int` 298 · 문자열 2성분 224 ·
부재 130 · 문자열 3성분 108 · 문자열 1성분 58 · 문자열 4성분 11 · 빈 문자열 1.
즉 **다성분 기본값은 따옴표 안의 공백/콤마 구분 수열**이다(`"0.315, 0.135, 0.1125"`).
바인더가 `inf`/`nan`/`nan(ind)`/`nan(snan)` 문자열도 처리한다(`0x140163ab9`–`0x140163af4`).

범위·스텝 메타: `range` 643건 — **전건 2원소 배열**(float 329 / int 314). 별도의 `step`
키는 자산·바이너리 어디에도 없다. 로컬라이즈 키는 `label`(847) / `group`(227) /
`material`(1,179) 이 전부 `ui_editor_properties_*` 계열 문자열이다.
철자 사고 `"range:"`(콜론 포함) 4건이 자산에 있다 — 에디터 전용이라 무해하다.

샘플러 주석 키 도수(483건 기준): `hidden` 268 · `material` 176 · `label` 175 ·
`default` 165 · `mode` 119 · `combo` 94 · `paintdefaultcolor` 65 · `require` 29 ·
`formatcombo` 23 · `format` 15 · `nonremovable` 10 · `components` 8 · `requireany` 8 ·
`painttexturescale` 6. `mode` 값 전수: `opacitymask` 93 · `rgbmask` 15 · `flowmask` 6 ·
`normal` 3 · `depth` 2 (전부 에디터 페인트 도구용).

### 7.3 머티리얼 측: `usershadervalues` / `usertextures`

```json
{"passes":[{"shader":"fade","usershadervalues":{"schemecolor":"tint"}}]}
```

좌변이 **엔진/사용자가 공급하는 값의 이름**, 우변이 **셰이더 주석의 `material` 이름**이다.
위 실물(`assets/materials/util/fade.json`)에서 `tint` 는 `shaders/fade.frag:6` 의
`uniform lowp vec3 color; // {"material":"tint","default":"0.315, 0.135, 0.1125"}` 를 가리킨다.
파스 자리는 `0x140154fd3`(같은 머티리얼 패스 파서 안). 동봉 도달 **1건**.

같은 파서가 읽는 형제 키(**VA 는 `lea` 의 명령 시작 주소다** — 종전엔 `usertextures`/
`keepaspect` 두 건만 disp32 필드 주소를 적어 관례가 어긋나 있었다. 2026-08-21 통일):
`constantshadervalues` `0x140154651` ·
`usertextures` `0x140154685` · `usertextures[].keepaspect` `0x140154871` ·
`textures`/`usertexturereference`(`0x1401556e0` 계열) · `shader` `0x140154cea`.
`keepaspect` 규약(태그 5 boolean 만, 부재 시 false, 레코드 `+0x30`)과 동봉 도달 1건
(`assets/scenes/videoplayer/materials/background.json`)은
`Sources/WapleCore/SceneDocument.swift:167-188` 이 이미 확정해 뒀다 — 재검증에서
정정할 것이 없었다.

---

## 8. Waple 갭 — 우선순위 순

### G1 (P0·**착지 2026-08-21**) `#require` — 소비까지. 주입은 [미해결]

**[정정] 종전 서술의 피해 판정이 틀렸다.** 이 절은 "`#require LightingV1` 줄이 그대로 MSL 로
방출 → Metal 전처리기가 `invalid preprocessing directive` 로 죽는다" 고 적었다. **MSL 에는 안
간다.** `GLSLTranslator` 의 조립부(`GLSLTranslator.swift:2059`)는 파스된 유니폼·varying·함수만
문자열로 엮어 내보내므로, 전처리를 통과한 **인식 불가 최상위 줄은 어디에도 안 실리고 조용히
사라진다**. 실측으로 확인했다 — 동봉 239쌍 × 3구성(기본값/allOn/allOff) = 717 구성의 방출
MSL 에서 `^\s*#\s*require` 는 **0건**이다. 그래서 아래 "린트에 `require` 를 넣어라" 도
그 자체로는 안 문다(넣었지만 동봉 도달 0 — 잠복 게이트다).

진짜 갭은 더 좁다: **`LIGHTING != 0` 일 때 실물이 주입하는 코드가 없다**(§3.5.1-②). 그 구성
12개(8 셰이더 × 도달 구성)에서 `PerformLighting_V1` 호출부가 미정의로 남아 MSL 컴파일이 실패한다
— 이건 종전에도 그랬고 지금도 그렇다. `GLSLBundledShaderRegressionTests.knownGaps["엔진 주입 함수"]`
가 그 8건을 이미 이름으로 들고 있다.

**착지한 것**: `ShaderPreprocessor` 에 `#require` 분기를 추가해 **줄을 소비**한다(실물의 공백
memset 과 같은 결말, §3.5.1-④). `LIGHTING` 게이트가 열려 있는데 주입을 못 하는 자리에서는
`WapleLog.warn` 을 남긴다 — 실물과 갈리는 지점을 조용히 두지 않기 위해서다.

**"제거만으로 충분한가" 판정**: `LIGHTING == 0`(GLSL 번역 레인을 타는 유일한 동봉 도달
`fluidsimulation_combine` 의 선언 기본값)에서는 **실물도 주입하지 않으므로 소비가 정확히
일치한다**. `LIGHTING != 0` 에서는 호출부가 남아 **컴파일이 확정 실패 → 이펙트 폴백**이다.
즉 소비만으로 "조용히 틀린 그림"이 되는 경로는 없다. 반대로 **주입을 어설프게 하면** 그때
조용히 틀린다 — `LIGHTS_*` 를 시딩하지 않은 채 생성기를 흉내내면 길이 0 배열 +
`return CAST3(0.0)` = 검은 라이팅이 되고, 컴파일은 성공한다.

**[미해결] 주입 미구현.** 하려면 (a) `LIGHTS_POINT`/`LIGHTS_SPOT`/`LIGHTS_TUBE`/
`LIGHTS_DIRECTIONAL`(+ `_SHADOW`/`_COOKIE` 변형) 매크로를 씬 `general.lightconfig` 로 시딩하고,
(b) `g_LPoint_*`/`g_LSpot_*`/`g_LTube_*`/`g_LDirectional_*`/`g_LFeature_*` 유니폼 **배열**을
렌더러가 채워야 한다. (b) 는 `WapleRender` 의 유니폼 빌더 소관이라 이 레인 밖이다.

#### 검토한 선택지 셋과 판정

| | 선택지 | 판정 |
|---|---|---|
| 1 | `#require LightingV1` 을 **Waple 손-포팅 라이팅 함수 선언으로 치환** | **불가.** Waple 의 손-포팅은 GLSL 텍스트가 아니라 **네이티브 MSL** 이다(`WapleRender/Mesh3DShaders.swift` 의 `pbrDirect`/`mf_main`). 시그니처도 유니폼 모델도 다르다 — `Scene3DLighting.Light` 구조체 버퍼 + `maximumLights = 8` 캡이고, 실물이 요구하는 `g_LPoint_Color[N]` 류 **배열 유니폼이 없다**. `GLSLTranslator` 의 유니폼 모델은 배열을 스칼라 머티리얼 슬롯으로 접으므로(같은 이유로 `g_MorphOffsets[12]` 도 못 싣는다 — 회귀 테스트 `knownGaps` 주석) 치환할 대상 자체가 존재하지 않는다. |
| 2 | 지시문은 소비하고 **`knownGaps` 로 명시 등록** | **채택.** 이미 등록돼 있었다 — `knownGaps["엔진 주입 함수"]`(선언 기본값 4건) / `knownGapsSweep`(스윕 8건)이 `XCTAssertEqual(ids, …)` 로 **양방향** 고정한다. 여기에 (i) 게이트 조건을 주석으로 확정하고, (ii) `LIGHTING != 0` 에서 호출부가 MSL 에 **살아남는지** 를 명시 단정으로 추가했다(`testLightingCallSiteSurvivesSoTheFailureStaysLoud`), (iii) 게이트가 열린 자리에서 `WapleLog.warn` 을 낸다. |
| 3 | `preprocessStrict` **거부** | **미채택.** 관측 결과가 2 와 동일하다 — 거부해도, 미정의 호출로 MSL 컴파일이 실패해도 결말은 **폴백 + 로그**다. 반면 비용은 크다: `testEveryBundledShaderPairTranslatesAtDeclaredCombos` 의 "동봉 전건 번역 성공" 불변식이 선언 기본값에서 4건 깨져 예외 목록이 필요해지고, 이 갭을 표현하던 `knownGaps` 두 집합이 통째로 무의미해진다. 강한 불변식을 약화시켜 이미 표현된 사실을 다시 말하는 셈이다. |

**"소비만 하면 조용히 틀린 그림" 인가 — 아니다.** 근거 둘.
* 소비는 **오늘의 방출물에 대해 무동작**이다. 도입 전후 717 구성의 MSL 지문이 전건 동일하다.
  `#require` 줄은 종전에도 MSL 에 안 갔다(조립부가 안 싣는다). 즉 소비가 새 오답을 만들 수 없다.
* `LIGHTING != 0` 에서 `PerformLighting_V1(...)` **호출부는 그대로 남는다** → Metal 컴파일 확정
  실패 → 폴백. 조용한 오답이 되는 쪽은 그 반대다 — 호출부까지 지우거나, `LIGHTS_*` 시딩 없이
  생성기를 흉내내(길이 0 배열 + `return CAST3(0.0)`) **컴파일에 성공하는 검은 라이팅**을 만드는 것.
  그래서 "호출부가 살아 있어야 한다" 를 테스트로 못 박았다.

**곁가지 확인**: `Sources/WapleRender/Scene3DLighting.swift:13` 의 "엔진이 `#require LightingV1`
(generic4.frag:75)로 주입하는 `PerformLighting_V1` → `common_pbr_2.h:256 ComputePBRLightShadow`"
는 **맞다**(§3.5.1-⑥ 의 방출 문자열이 정확히 그 함수를 부른다). 다만 그 서술에 빠진 조건이
하나 있다 — 주입은 **`LIGHTING` 콤보가 0 이 아닐 때만** 일어난다. `generic4` 는
`[COMBO] LIGHTING default 1` 이라 기본 구성에서 게이트가 열리므로 서술 자체는 성립한다.

**게이트**: 회귀 린트의 "전처리 잔재" 패턴에 `require`(와 `undef`·`pragma`·`error`·`line`)를
추가했다 — 다만 위 이유로 동봉 도달 0. 대신 **전처리 출력을 직접 보는 게이트**를 새로 넣었다
(`testNoEngineDirectiveSurvivesPreprocessing` — WE 9종 지시문이 전처리를 통과하면 실패).
되돌림 실측: `#require` 소비를 빼면 그 게이트가 6 파일, 짝인
`ShaderPreprocessorRequireTests.testAllBundledRequireFilesLoseTheDirective` 가 14 조합을 잡는다
(합계 5 테스트 케이스 / 23 단정).

### G2 (P0·**착지 2026-08-21**) `#if` 식 문법 8종 — 평가기 확장

`ExprEval` 을 §3.7 의 실물 사슬과 같게 넓혔다: `%` · 단일 `&`/`|`/`^` · 단항 `~` ·
`<<`/`>>` · 16진(`0x`/`0X`) · 접미(`u`/`f`/`l`, 반복 가능) 리터럴, 그리고 단항 `+`.
우선순위는 실물 그대로 `|| → && → | → ^ → & → ==/!= → 비교 → 시프트 → +- → */% → 단항`
— 종전에는 `==`/`!=` 와 비교가 **한 단계로 뭉쳐 좌결합**이었다(`2 == 1 < 1` 이 실물 0, 종전 1).
32비트 규약도 같이 옮겼다: 비트·시프트·`~` 는 `Int32` 절단, 시프트량 >31·음수면 0,
0 나눗셈/나머지는 0, 리터럴 누적은 32비트 랩(`0xFFFFFFFF` = −1).
`#define X 0x10` / `1u` / `(0x10)` 도 이제 `#if` 평가값으로 등록된다.

**거부 규약은 유지**했다 — 남은 거부는 삼항 `?:`(실물에도 없다) · 잔여 토큰(실물은 관용,
우리는 "오역보다 폴터") · 소수 리터럴(**[미해결]** — 실물은 소수부를 버리고 1.5→1,
§3.7. 흉내내지 않았다).

회귀 폭: 동봉 등장 0회라 **717 구성의 MSL 지문이 변경 전후 전건 동일**(FNV-1a 비교).
되돌림 실측 7 테스트 케이스 / 31 단정.

### G3 (P1·**착지 2026-08-21**) 콤보 키 정규화 — 무조건 대문자화

**[정정] 종전 절의 "선언이 있는 것은 `reflection`→`REFLECTION` 하나뿐" 은 집계 단위가 틀렸다.**
`canonical()` 은 **그 패스가 쓰는 셰이더의** 선언 집합만 본다. 저작 자리별로 다시 세면
소문자 저작 **56건 중 종전 규약이 접던 것은 0건**이다 — `planks.json` 의 `reflection` 도
셰이더가 `generic` 이라 `[COMBO] REFLECTION` 이 없다(선언은 `generic4` 계열에 있다).

착지: `GLSLTranslator.translate` 진입에서 콤보 키를 `uppercased()` 로 접는다
(`GLSLTranslator.uppercasedComboKeys`). 실물의 접기 자리는 JSON 파스(`0x140154599`)지만
Waple 의 대응 자리 `SceneRendererResources.resolvePassCombos` 는 이 레인 밖이라, 관측 대상인
**주입 직전**에서 접었다 — 결과는 같고 메모 키도 함께 정규화된다.

**이 자리가 오히려 넓다.** `resolvePassCombos` 를 타는 것은 이펙트 패스 하나뿐이고,
`GLSLTranslator.translate` 호출부는 넷이다 — 이펙트 패스(`SceneRendererResources.swift:766`) ·
**커스텀 레이어 셰이더**(`:1699`) · **커스텀 메시 셰이더**(`SceneRenderer3D.swift:1084`) ·
스캐너(`WapleCompatCore/DeepScan.swift:534`). 뒤 셋은 `layer.materialCombos`/`mat.customCombos`
를 **정규화 없이 그대로** 넘기던 자리라 종전 `canonical()` 근사가 아예 닿지 않았다.
충돌 규약은 **대문자 철자 우선**(실물 `#define` 방출 순서 §3.2 → §3.3, 뒤가 승. Waple 에서
텍스처 유래 키는 셰이더 어노테이션 철자 = 전건 대문자).
**[미해결]** `resolvePassCombos.canonical()` 은 이제 잉여다 — 제거는 별건.

**바뀌는 자리 전수.**

* **셰이더 파일(.vert/.frag 쌍) 번역 결과: 0건.** 동봉 `[COMBO]` 선언 67종 · 샘플러
  `combo` 어노테이션 9종 · `components.combo` 5종이 **전부 대문자**라 접기가 무동작이다.
  717 구성 MSL 지문 전건 동일(위 G2 와 같은 측정). 회귀 테스트도 `parseComboDefaults` 로
  콤보를 만들므로 스윕은 이 변경을 못 본다 — 그래서 계약을 `ShaderPreprocessorRequireTests`
  의 G3 절이 따로 든다(되돌림 2 테스트 케이스 / 4 단정).
* **머티리얼 JSON(저작 키): 동봉 9건 중 5건이 실제로 그림을 바꾼다.**

  | 동봉 파일 | 셰이더 | 키:값 | 셰이더가 대문자 이름을 참조? |
  |---|---|---|---|
  | `materials/util/solidlayer_instance.json` | `genericimage2` | `version:2` | ✔ `#ifndef VERSION`(frag:7, :68) |
  | `materials/util/solidlayer_instance_depthtest.json` | `genericimage2` | `version:2` | ✔ 〃 |
  | `materials/util/flatalphavertexcolor.json` | `flat` | `vertexcolor:1` | ✔ `#ifdef VERTEXCOLOR`(vert:7,:13 · frag:10) |
  | `materials/util/gizmovertexcolor.json` | `flat` | `vertexcolor:1` | ✔ 〃 |
  | `scenes/gifs/materials/background.json` | `genericimage` | `spritesheet:1` | ✔ `#if SPRITESHEET`(vert:29) |
  | `materials/util/solidlayer_instance_3.json` · `_4` · `_depthtest_3` · `_depthtest_4` | `genericimage3`/`4` | `version:2` | ✘ 참조 없음 → 무변화 |

  실효 도달은 그보다 더 좁다: 앞 넷은 동봉 자산 어디에서도 **참조되지 않는다**(엔진이 이름으로
  집는 내부 머티리얼). 다섯째 `gifs` 만 씬 체인(`gifscene.json` → `models/background.json`)에
  있는데, Waple 은 SPRITESHEET 를 이미 **네이티브 레인**에서 처리한다
  (`SceneDocument.swift:3197` 이 대소문자 무시로 읽어 `layer.spritesheet` → `resolveTextureWithFrames`).
  `genericimage2` 의 `#else` 가지가 쓰는 `g_Color4` 는 `GLSLTranslator.engineNeutralDefault`
  에 이미 (1,1,1,1) 중립값이 있어(`GLSLTranslator.swift:1494`) 두 가지가 기본값에서 동형이다.
* **설치본(`assets/` + `projects/`) 저작 전수: 56건 중 52건이 그림을 바꾼다.**
  `genericimage2`/`version` 13 · `generic`/`lightmap` 6 · `generic`/`normalmap` 5 ·
  `genericimage2`/`spritesheet` 9 · `car`/`normalmap` 4 · `genericimage`/`spritesheet` 2 ·
  `generic`/`detailinalpha` 2 · `flat`/`vertexcolor` 2 · 나머지 각 1
  (`car`/{`metal`,`paintwork`,`maskpaintcolor`,`specularalpha`} · `generic`/`reflection` ·
  `retro`/`dots` · `ricepod`/`selfillum` · `technoorbit`/{`clouds`,`rays`}).
  안 바뀌는 4건은 셰이더가 그 이름을 `#if*` 로 안 보는 경우다.
  **위험 고지**: 이 52건은 대부분 모델 머티리얼이라, 켜진 가지가 요구하는 텍스처 슬롯이
  실제로 묶여 있어야 그림이 좋아진다(저작자가 콤보를 켠 이유가 그것이므로 정상 경로다).
  다만 `flat`+`VERTEXCOLOR` 는 `a_Color` 정점 속성을 요구하는데 Waple 소스에 그 속성 이름이
  **한 번도 안 나온다** — 기즈모 전용이라 도달 0 이지만 규약 차이로 적어 둔다. **[미해결]**


### G4 (P2) `#include` include-once 부재

`ShaderPreprocessor.swift:138-159` 는 깊이 16 캡만 두고 **중복 인라인을 막지 않는다**.
WE 는 이름 기준 include-once(`0x1401624b0`–`0x14016250d`)다. 헤더에 함수 정의가 있으면
중복 인라인은 MSL `redefinition` 에러다. 동봉 도달 0건(§5)이라 P2.

또 Waple 의 인클루드 클로저(`SceneRendererResources.swift:665-671`, `:1677-1683`)는
`shaders/<h>` **와** 맨 `<h>` 를 둘 다 본다. WE 는 `shaders/<h>` 하나뿐이다 —
관대한 방향의 차이라 회귀는 없지만 규약 차이로 적어 둔다.

* 착지: `inlineIncludes` 에 `inout Set<String> seen` 을 붙여 이름 중복을 스킵.

### G5 (P2) 디스크 퍼뮤테이션 캐시 없음

Waple 은 `GLSLTranslator` 의 **인메모리 메모이즈**(`GLSLTranslator.swift:76-133`,
키 = raw v/f + 인라인 소스 + 정규화 combos)만 있고, MSL→`MTLLibrary` 컴파일은
매번 `device.makeLibrary(source:)` 다(`SceneRendererResources.swift:1568`, `:1640`,
`SceneRenderer3D.swift:1091`). 프로세스를 다시 띄우면 전부 재컴파일이다.
WE 는 `<pkg>/shaders/blobsSM40/<sha1>.dxs` 로 **디스크에 남긴다**.
정확성 문제는 아니고 콜드 스타트 비용이다.

* 착지: `MTLBinaryArchive` 또는 `.metallib` 를 §6.2 와 같은 키(SHA-256 등)로
  캐시 디렉터리에 남긴다. 매직+버전 문자열을 앞에 두는 것(WE 의 `SHDV0069`)이
  포맷 바뀜에 대한 값싼 방어다.

### G6 (P3) 작은 규약 차이 — 회귀 없음

| 항목 | WE | Waple | 판단 |
|---|---|---|---|
| `[COMBO]` 줄 인식 | 줄머리 `// [COMBO]` 완전일치 | `line.contains("[COMBO]")` (`ShaderPreprocessor.swift:131`) | Waple 이 관대. `[OFF_COMBO]`/`[COMBO_OFF]`/`[COMBO_DISABLED]` 는 부분문자열이 `[COMBO]` 와 안 맞아 오탐 0 |
| `"default": 1.5` | `isIntegral` 거짓 → **0** | `jsonInt`(`:488-499`)가 `1` 을 뽑는다 | 자산 도달 0(316/316 정수 또는 부재) |
| `"default": "1"` | 태그 4 → **0** | `jsonInt` 가 `1` | 자산 도달 0 |
| `TEXnFORMAT` 값 0 | 그래도 주입 | `code != 0` 필터(`SceneRendererResources.swift:1068-1077`) | `#if` 값은 동일. `#ifdef TEXnFORMAT` 만 갈리고 자산 도달 0 |
| 슬롯 번호 | `g_TextureN` 의 N | 동일(`GLSLTranslator.samplerCombos`) | 일치 |
| 라이팅 생성기 범위 인용 | `0x140169140`–`0x14016b0d4` | `ScenePBRLighting.swift:221` 이 `0x140168000–0x14016b154` | 상한이 전처리기(`0x14016b0e0`) 안까지 넘어간다. **[2026-08-21 재확인]** `primary(0x140169140)` = `(0x140169140, 0x14016b0d4)`, `primary(0x14016b0e0)` = `(0x14016b0e0, 0x14016c3f8)` — 두 함수가 인접하고 겹치지 않는다. 하한 `0x140168000` 도 근거가 없다(그 자리는 `#if` 파서 사슬이다). 정정 권장(파일 소유 밖이라 미수행) |
| `#require` 줄의 MSL 유출 | 줄을 공백으로 덮는다(`0x14016bc63`) | 종전엔 전처리를 통과했지만 **번역기 조립부가 삼켜** MSL 엔 안 갔다 | **[2026-08-21 착지]** 이제 전처리가 소비한다(§8-G1). 방출 MSL 은 전후 동일 |

---

## 9. 배제한 가설

1. **"`conditions` 는 `COMBO==1 && X` 같은 문자열 식이다."** 아니다. 평가기
   `0x1401e63b0` 은 문자열 우변을 만나면 조건을 **건너뛴다**(`0x1401e65fe`). 자산도
   8/8 전건 `{콤보:정수}` 다. 문자열 식 `alignment.value<2&&check`(`0x140488c78`)는
   **프로퍼티 UI** 문법이지 콤보 게이트가 아니다(§4.5).
2. **"`type`/`options` 를 런타임이 읽어 콤보 값을 검증한다."** 아니다. `options`
   `imageblending` `audioprocessingoptions` 는 `wallpaper64.exe` 에 **문자열조차 없다**.
   `type` 은 있지만 비교 대상이 `"color"` 하나뿐(`0x140163ee3`)이고 그건 유니폼 주석용이다.
3. **"엔진이 선언된 콤보만 주입한다."** 아니다. 설치본 저작 콤보 66종 중 **37종이
   어디에도 선언되지 않았고** 그래도 셰이더가 그 이름을 `#if` 로 본다.
4. **"콤보 이름 대소문자는 선언 목록으로 맞춘다."** 아니다. `toupper` 무조건 적용이다(§2.2).
5. **"`[OFF_COMBO]`/`[COMBO_OFF]` 도 파스된다."** 아니다. 스캐너가 `// [` 다음
   6바이트를 `COMBO]` 와 `memcmp` 한다(§1.1).
6. **"셰이더 캐시는 메모리뿐이다."** 아니다. `.dxs` 디스크 캐시가 설치본에 실물로 5개 있다.
7. **"`#if` 식은 `==`/`&&`/`||` 수준의 축소 문법이다."** 아니다. 렉서가 C 정수식
   전체(시프트·비트·모듈로·16진)를 토큰화하고 파서가 전부 계산한다. 다만 **삼항 `?:` 는 없다**.
8. **"`#include` 는 여러 검색 경로를 본다."** 아니다. `shaders/` 접두 하나다.

---

## 10. 미해결

1. **콤보 병합 순서**(§2.6) — `[COMBO]` 기본값 / 머티리얼 `combos` / 씬 오버라이드 /
   텍스처 유래 콤보를 한 맵에 합치는 코드 자리를 못 짚었다. 관측 계약은 확정이나
   충돌 시 우선순위는 코드로 확인 못 했다.
2. **캐시 키 ①의 정수**(§6.2) — `[[dev+0x1518]]+0x30` 가상호출 반환값의 의미.
   백엔드/셰이더모델/디바이스 티어 중 무엇인지 미확정.
3. **`.dxs` 꼬리 61~222 B**(§6.1) — DXBC 두 블롭 뒤에 붙는 메타의 구조.
4. **`#define` 방출 순서**(§3.2) — 컨테이너 순회 순서가 이름순인지 삽입순인지.
   캐시 키 쪽은 `0x14016e270` 이 만든 목록을 쓰는데 그 함수가 정렬을 하는지 미확인.
5. **프로세스 내 컴파일 중복 회피**(§6.4) — WE 가 같은 SHA-1 을 두 번 만나면
   메모리에서 재사용하는지.
6. **씬 `objects[].effects[].passes[].combos` 오버라이드**가 `0x140154480` 을 타는지
   (=대문자화되는지). `0x1401515b0` 의 두 호출 자리는 "씬 인라인 패스"와 "머티리얼 JSON"
   으로 갈리는데, 이펙트 패스 오버라이드가 그중 어느 쪽으로 들어오는지 못 짚었다.
   (Waple 은 `GLSLTranslator.translate` 진입에서 접으므로 **어느 경로로 들어오든 대문자화된다**
   — 실물이 한쪽만 접는다면 우리가 더 공격적이다. §8-G3.)
7. **[2026-08-21] `#require LightingV1` 의 주입 미구현**(§8-G1). 생성기의 입력
   (`LIGHTS_*` 매크로)과 출력(`g_L*` 유니폼)을 Waple 렌더러가 아직 다루지 않는다.
   구현 전까지 `LIGHTING != 0` 구성은 `PerformLighting_V1` 미정의로 MSL 컴파일 실패 →
   폴백이다(조용한 오답은 아니다).
8. **[2026-08-21] `#if` 소수 리터럴**(§3.7) — 실물은 `.` 뒤 소수부를 읽고 **버린다**
   (`0x140167021`–`0x140167046`) → `#if 1.5` 는 1. Waple 은 `.` 를 모르는 문자로 남겨
   거부한다. 어느 자산도 안 쓰므로 도달 0 이지만 규약 차이다.
9. **[2026-08-21] 잔여 토큰 관용**(§3.7) — 실물 파서는 식을 다 못 먹어도 그냥 값을
   돌려준다(`#if 2 x` → 2). Waple 은 거부한다("오역보다 폴터" — 의도적 이탈).
10. **[2026-08-21] `resolvePassCombos.canonical()` 잉여**(§8-G3) — 대문자화가 번역기
   진입으로 옮겨져 이 함수는 더 이상 하는 일이 없다. 제거는 파일 소유 밖이라 별건.

---

## 부록 A — 재현 절차

전부 리포 밖 원본(`/root/.claude/uploads/…/440072bd-wallpaper64.exe`,
`/home/user/Waple-wallpaper-source/wallpaper_engine/`)만 읽는다.

```bash
WE=/home/user/Waple-wallpaper-source/wallpaper_engine

# ① 동봉 사본이 설치본과 같은지
diff -rq /home/user/Waple/Sources/WapleRender/Resources/WEAssets/shaders "$WE/assets/shaders"

# ② [COMBO] 전수 · 키 도수 · 이름 도수
python3 - "$WE" <<'PY'
import os,sys,json,collections
root=sys.argv[1]; c=collections.Counter(); names=collections.Counter(); per=collections.Counter()
for base in ('assets','projects'):
  for dp,dn,fn in os.walk(os.path.join(root,base)):
    for f in fn:
      if not f.endswith(('.frag','.vert','.geom','.h')): continue
      p=os.path.join(dp,f)
      for l in open(p,encoding='utf-8',errors='replace').read().splitlines():
        l=l.rstrip('\r')
        if not l.startswith('// [COMBO]'): continue
        j=json.loads(l[10:].strip()); per[p]+=1; names[j['combo']]+=1
        for k in j: c[k]+=1
print(sum(per.values()), dict(c), len(names))
PY

# ③ #if/#elif 식의 구문 도수(등장/미등장 표) — 동봉 assets/ 기준
python3 - "$WE" <<'EOF2'
import os,re,sys
root=sys.argv[1]; ex=[]
for dp,dn,fn in os.walk(os.path.join(root,'assets')):
  for f in fn:
    if not f.endswith(('.frag','.vert','.geom','.h')): continue
    for l in open(os.path.join(dp,f),encoding='utf-8',errors='replace').read().splitlines():
      m=re.match(r'#\s*(if|elif)\b(.*)',l.strip())
      if m: ex.append(re.split(r'//|/\*',m.group(2))[0].strip())
chk=[('%',r'%'),('&',r'(?<!&)&(?!&)'),('|',r'(?<!\|)\|(?!\|)'),('^',r'\^'),('~',r'~'),
     ('<<',r'<<'),('>>',r'>>'),('hex',r'\b0[xX][0-9a-fA-F]+'),('suffix',r'\b\d+[uUlLfF]\b'),
     ('?:',r'\?'),('defined',r'\bdefined\b'),('&&',r'&&'),('||',r'\|\|'),('==',r'=='),('!=',r'!=')]
print(len(ex), {n: sum(1 for e in ex if re.search(r,e)) for n,r in chk})
EOF2

# ④ conditions 도달 — fluidsimulation 이 트레일링 콤마라 **관대 파스가 필요**하다.
#    엄격 json.load 만 쓰면 0건이 나온다(그게 함정). → §4.2 표

# ⑤ 디스크 캐시 실물
ls "$WE/assets/scenes/videoplayer/shaders/blobsSM40/"
python3 -c "b=open('$WE/assets/scenes/videoplayer/shaders/blobsSM40/be980a718f19b831f952cc29cb39fd0d5871c168.dxs','rb').read();print(b[:16])"

# ⑥ 바이너리 — 세션 스크래치의 RE 도구(wpe.py / wxref.py / vdis2.py)로 본다.
#    $SP 는 그 도구가 있는 디렉터리(세션마다 다르다).
#    wxref.funcs_of(va) = 그 주소를 rel32 로 가리키는 명령들을 primary() 함수별로 묶어 준다.
python3 -c "import sys;sys.path.insert(0,'$SP');import wxref;print(wxref.funcs_of(0x1402bfb48))"  # toupper 호출부 2곳
python3 "$SP/vdis2.py" 0x14016c400 0x14016c7fe   # #define 방출기
python3 "$SP/vdis2.py" 0x140166a90 0x1401670ba   # 렉서 토큰표
python3 "$SP/vdis2.py" 0x140154480 0x140155668   # 머티리얼 패스 파서(대문자화 0x140154599)
```

게이트: `python3 scripts/spec/check_address_ranges.py` · `python3 scripts/spec/validate.py`
(둘 다 이 문서 작성 전후로 0 오류).

---

## 부록 B — 이 문서가 인용한 함수 범위

| 함수(가칭) | 범위 | 역할 |
|---|---|---|
| `Shader::compile` | `0x1400d5070`–`0x1400d7034` | 프리앰블·`blobsSM40/`·`.dxs` 경로·D3DCompile |
| `Shader::loadAndPreprocess` | `0x140162ac0`–`0x140163693` | 경로 조립·`#define` 블록·인클루드·`SHDV0069` mtime 게이트·전처리 3회 |
| `Shader::resolveIncludes` | `0x140162100`–`0x140162ab9` | `#include` 인식·`shaders/` 접두·include-once·재귀 |
| `Shader::preprocess` | `0x14016b0e0`–`0x14016c3f8` | 지시문 9종·`SHADERVERSION=69` 시딩 |
| `Shader::emitComboDefines` | `0x14016c400`–`0x14016c7fe` | `#define NAME <10진>\n` |
| `Shader::emitTextureDefines` | `0x14016c800`–`0x14016c984` | `#define NAME 1\n`(슬롯 combo·components) |
| `Shader::cacheKeySHA1` | `0x14016c990`–`0x14016cd95` | 퍼뮤테이션 캐시 키 |
| `Shader::scanDeclarations` (DECL) | `0x14016ce60`–`0x14016e0c8` | 유니폼 주석 · `// [COMBO]` · `// [PASS]` |
| `Expr::lex` | `0x140166a90`–`0x1401670ba` | `#if` 렉서(토큰 0~0x19) |
| `Expr::parseAtom` | `0x140167c00`–`0x140167e0c` | 리터럴·식별자·`defined`·단항·괄호 |
| `Expr::eval` | `0x140167e10`–`0x140169138` | 우선순위 사슬 |
| `Shader::generateLightingV1` | `0x140169140`–`0x14016b0d4` | `#require LightingV1` 코드 생성 |
| `Shader::loadPair` | `0x1401a5c40`–`0x1401a6c5d` | `TEXnFORMAT` 조립 |
| `Shader::buildDeclarations` | `0x1401a6c60`–`0x1401a72a8` | 인클루드 후 DECL ×2(스테이지 합집합) |
| `Material::parsePass` | `0x140154480`–`0x140155668` | `combos`(대문자화)·`constantshadervalues`·`usershadervalues`·`usertextures` |
| `Material::load` | `0x1401515b0`–`0x140151e6c` | 위 파서의 두 진입(씬 인라인 / JSON 파일) |
| `Shader::bindUserValue` | `0x1401636a0`–`0x140164013` | 유니폼 주석 → 사용자 값(`material`/`default`/`conversion`/`type`) |
| `Effect::parse` | `0x1401e7170`–`0x1401e814e`(참조만) | 이펙트 인스턴스 `combos`·`fbos`·`passes`·`conditions` |
| `Effect::evalConditions` | `0x1401e63b0`–`0x1401e6976` | `conditions` 평가(기존 정본) |
| `jsoncpp isIntegral` | `0x1400886e0`– | `[COMBO] default` 타입 게이트 |
| `jsoncpp asInt` | `0x140085ee0`– | 〃 |
| `toupper` | `0x1402bfb48`–`0x1402bfb72` | 콤보 키 대문자화 |

문자열 앵커: `"// ["`=`0x1404dfd00` · `"COMBO]"`=`0x1404dfcc0` · `"PASS]"`=`0x1404dfce0` ·
`"shaders/"`=`0x1404dfca0`(컴파일 경로) / `0x14048b9b0`(인클루드) · `"#define "`=`0x14048d0b8` ·
`" 1\n"`=`0x14048d0b4` · `"#define HLSL 1\n#define HLSL_SM40 1\n"`=`0x140486898` ·
`"#define GS_ENABLED 1\n"`=`0x14048b998` · `"SHADERVERSION"`=`0x14048d068` · `"69"`=`0x14048d078` ·
`"SHDV0069"`=`0x140486948` · `"blobsSM40/"`=`0x1404868c8` · `".dxs"`=`0x1404868d4` ·
`"require"`=`0x14048d0d0` · `"shadow"`=`0x14048d0d8` · `"formatcombo"`=`0x14048d0e0` ·
`"components"`=`0x14048d0f0` · `"combo"`=`0x140488bec` · `"material"`=`0x14048ba08` ·
`"conversion"`=`0x14048b9f8` · `"rad2deg"`=`0x14048b9f0` · `"startdelta"`=`0x14048ba18` ·
`"default"`=`0x140476ef8` · `"combos"`=`0x14048b4c4` · `"usershadervalues"`=`0x14048b610` ·
`"TEX"`=`0x14048ee70` · `"FORMAT"`=`0x14048ee98` · `"LightingV1"`=`0x14048be90` ·
지시문 정규식=`0x14048d048` · 유니폼 선언 정규식=`0x14048b9d0` ·
`g_TextureN` 정규식=`0x14048d100`.
