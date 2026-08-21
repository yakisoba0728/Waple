# GLSL→MSL 번역기·전처리기 재대조

**측정일 2026-08-21 · WE 2.8.42 · `wallpaper64.exe`(imagebase `0x140000000`, 원본 5,360,112 B)**

이웃 문서와의 경계. `docs/re/shader-combos.md` 는 **콤보 시스템**(선언·주입·캐시·주석 스키마)을,
`docs/re/shader-uniforms.md` 는 **엔진이 주는 `g_*` 유니폼**을 다룬다. 이 문서는 그 둘이 다루지
않는 **번역기 자신** — 무엇이 검사되고 무엇이 안 되는가, 실물 전처리기와 어디가 갈리는가 — 이다.

코퍼스: 동봉 `Sources/WapleRender/Resources/WEAssets/` 와 설치본
`/home/user/Waple-wallpaper-source/wallpaper_engine/assets/` 를 `md5sum` 전건 대조했다 —
`.vert`/`.frag`/`.h`/`.geom` **502 파일이 바이트 동일**(vert 242 · frag 242 · h 14 · geom 4).
즉 "동봉은 설치본의 부분집합" 이 아니라 **같은 트리**다. 아래 "자산 도달 N건" 은 두 트리 공통이다.

---

## 0. 네 줄 요약

1. **실결함 1건 — `varying mat3` 이 `struct Vary` 에 그대로 나갔다.** MSL 은 `[[stage_in]]`
   구조체와 정점 반환 타입에 **행렬 멤버를 금지**한다. 동봉 도달은 `effects/cursorripple/preview/
   shaders/effects/cursorripple_apply_force` **1쌍**, `PERSPECTIVE == 1` 에서만. 열 벡터로 펼쳐 고쳤다.
2. **회귀 하네스 결함 1건 — CRLF 때문에 헤더가 한 번도 인라인되지 않았다.** 동봉 셰이더가 전건
   CRLF 인데 하네스가 `split(separator: "\n")` 을 썼다(공통 브리프 함정 11). 그래서 콤보 스윕의
   노브가 헤더 안에서만 등장하는 콤보를 통째로 놓쳤다.
3. **콤보 *값* 사각지대.** 종전 스윕은 구성이 셋(선언 기본값 · 전부 1 · 전부 0)뿐이라
   `#if NAME == N`(N≥2) 분기를 **원리적으로** 못 본다. 그런 (이름,값) 쌍이 **76종**,
   그런 분기를 가진 셰이더가 **239쌍 중 89쌍(37%)** 이다. 최대 덩어리는
   `common_blending.h` 의 `#if BLENDMODE == 1..32`(**56쌍**이 인라인).
4. **전처리 규약차 3건은 전부 잠복이다**(자산 도달 0건): `# if` 공백 · `#if` 식 안의 매크로
   확장 · 지시문 줄 중간의 `/* */`. 앞 둘은 고쳤고 셋째는 미해결로 남겼다.

---

## 1. 실물 전처리기 — 다시 뜬 사실

### 1.1 인식하는 지시문은 9종, 줄 인식은 정규식

원본 파일오프셋 `0x48be48` 에 문자열 `^\s*#\s*([a-z]+)\b\s*(.*)` 가 있고, 바로 뒤에
`SHADERVERSION` · `69` · `ifndef` · `ifdef` · `define` · `elif` · `if` · `endif` · `else` ·
` 1\n` · `#define ` · `undef` · `require` 가 이어진다. 디스패처는 `0x14016b0e0`–`0x14016c3f8`.

- `[a-z]+` 라 **소문자만** — `#IFDEF` 는 지시문이 아니다.
- `#\s*` 라 **`# if` 도 지시문이다.** Waple 은 `hasPrefix("#if ")` 라 이 형태를 못 읽고
  지시문 줄을 본문으로 흘렸다(짝 `#endif` 도 같이 흘러 조건부가 통째로 무시된다). **고쳤다.**
  자산 도달 **0건**(`^\s*#[ \t]+<kw>` 실측 0) — 워크샵 대비의 잠복 게이트다.
- `version`/`extension`/`pragma`/`error`/`line` 은 **여기 없다.** 실물은 못 알아보고 본문에
  그대로 남긴다(`0x14016c1f8` → `0x14016bbb0`). 그래서 공백 접기도 **아는 9종에만** 건다.

### 1.2 `#if` 식 렉서(`0x140166a90`–`0x1401670ba`) — `primary()` 확인

| 사실 | 근거 |
|---|---|
| 주석을 **건너뛰고 계속 렉싱**한다(`//` 는 줄 끝까지, `/* */` 는 닫는 자리까지) | `0x140166aff` `cmp al,'/'` → `0x140166b10`(`//`) / `0x140166b28`–`0x140166b74`(`/* */`) |
| 매크로 확장을 **렉서가** 한다 — 본문 포인터를 스택에 밀고 그 자리에서 재렉싱, 끝나면 팝 | push `0x140166cc1`–`0x140166db7`(`inc dword [rbx+0x40]`) / pop `0x140166ada`–`0x140166af7`(`dec`) |
| 확장 깊이 캡 **0x63 = 99**, 넘으면 그냥 식별자 토큰(2) | `0x140166cb7` `cmp dword [rbx+0x40], 0x63; jge` |
| `defined` 는 **확장하지 않는다** | 렉서 `0x140166bff` 플래그 `[rbx+0x44]` 검사 + `0x140166c09`–`0x140166c33` 자체 이름 검사 |
| 수치 리터럴: `0x`/`0X` 16진 · 10진 · **소수부는 읽고 버림** · `u`/`f`/`l` 접미 다중 | 16진 `0x140166f9c`(`add al,0xa8; test al,0xdf`)·누적 `0x140166fe7`(`shl esi,4`) / 10진 `0x140167007`–`0x140167019` / 소수 `0x140167021`–`0x140167046` / 접미 `0x140167058`·`0x140167068`·`0x140167078` |
| 토큰 코드 | `(`3 `)`4 `+`0xe `-`0xf `*`0x10 `/`0x11 `%`0x12 `&&`0xc `\|\|`0xd `&`0x13 `\|`0x14 `^`0x15 `~`0x16 `!`5 `!=`7 `==`6 `<<`0x17 `<=`9 `<`8 `>>`0x18 `>=`0xb `>`0xa · 수1 · 이름2 · 미지 0x19 · EOF 0 |

### 1.3 `defined` 는 **있다** — 문자열이 아니라 즉치 비교라 안 보인다

바이너리 전체에 ASCII `"defined"` 도 UTF-16 `"defined"` 도 **0건**이다. 그래서 "WE 는 `defined`
를 모른다" 로 오독하기 쉽다(이 조사에서 실제로 한 번 그렇게 결론낼 뻔했다 — 문자열 부재를
근거로 삼으면 안 된다는 브리프 함정 10 의 변형이다). 실제로는 **즉치 비교**다:

```
0x140167c90  cmp qword [rbx+0x18], 7        ; 토큰 길이 7
0x140167c9f  mov ecx, [rdx]
0x140167ca1  sub ecx, 0x69666564            ; "defi"
0x140167ca9  movzx ecx, word [rdx+4]
0x140167cad  mov eax, 0x656e                ; "ne"
0x140167cb6  movzx ecx, byte [rdx+6]
0x140167cba  sub ecx, 0x64                  ; 'd'
```

동작: `[rbx+0x44] = 1`(확장 금지 플래그, `0x140167cc8`) → 다음 토큰이 `(`(3)면 소비
(`0x140167cd1`) → 식별자(2)면 매크로맵 조회 `0x1401669a0`(`0x140167cff`) → 플래그 해제
(`0x140167d0a`) → 열었으면 `)`(4) 소비(`0x140167d24`). 즉 **괄호는 선택**이고 피연산자는
확장되지 않는다. Waple 의 구현이 이미 같은 모양이다(회귀 방지 테스트를 새로 붙였다).

### 1.4 파서 사슬은 C 와 같다

`||`0x1401670c0 → `&&`0x140167390 → `|`0x140167520 → `^`/`&`0x1401675e0 → `==`/`!=`0x140167680
→ 비교0x140167850 → 시프트0x1401679d0 → `+`/`-`0x140167ad0 → `*`/`/`/`%`0x140167b80 →
단항·원자0x140167c00. 괄호 안은 `&&` 레벨부터 시작하고 `||` 루프를 인라인한다(`0x140167d48`–
`0x140167d9d`) — 값은 전체 `||` 파싱과 같다. `&&`/`||` 는 **단락 평가가 아니다**(`or eax,esi;
setne`), Waple 도 양쪽을 계산하므로 같다.

---

## 2. Waple 과 실물이 갈리는 지점 (전부 자산 도달 0건)

| # | 항목 | 실물 | Waple | 자산 도달 | 조치 |
|---|---|---|---|---|---|
| D1 | `# if COND`(`#`·키워드 사이 공백) | 지시문 | 종전: 본문으로 유출 | 0건 | **고침** |
| D2 | `#if` 식 안의 매크로 확장 | 렉서가 재귀 확장(캡 99) | 종전: 정수 맵만 → 0 | 0건 | **고침**(자기참조 차단, 본문이 식이 아니면 0) |
| D3 | 지시문 줄 중간의 `/* c */` | 건너뛰고 계속 | 그 자리에서 **절단** | 0건 | 미해결 — 고치려면 절단이 아니라 구간 삭제 |
| D4 | `#if 1.5` 소수 리터럴 | 소수부 버리고 `1` | **거부**(셰이더 폴백) | 0건 | 유지(선행 라운드의 의도적 결정) |
| D5 | 잔여 토큰(`#if 1 0`) | 그냥 버림 | **거부** | 0건 | 유지("오역보다 폴터") |
| D6 | 렉서가 모르는 문자(`?` `:` `.` `;` `@`) | 토큰 0x19 → 값 0 | **거부** | `;` 는 절단으로 관용 | 유지 |
| D7 | `#include` 중복 | include-once | 매번 인라인 | 0건 — 같은 헤더가 한 TU 에 두 번 들어오는 동봉 셰이더는 **없다**(재귀 인라인 전수 실측) | 미조치 |
| D8 | 32비트 산술 | 전 구간 `eax` | 비트·시프트·`~`·리터럴만 32비트, `+ - * /` 는 `Int` | 0건(2^31 넘는 리터럴 0회) | 유지 |

**정확도 주의.** D1–D8 은 전부 "동봉=설치본 502 파일에서 0건" 이다. 워크샵 pkg 는 이 컨테이너에
없으므로 그쪽 빈도는 **모른다**. "0건" 은 이 코퍼스 범위 라벨이지 "발생하지 않는다" 가 아니다.

---

## 3. 실결함 — `varying mat3` 이 `stage_in` 에 들어갔다

### 3.1 MSL 이 금지한다

Metal Shading Language Specification(2026-06-04 판) §5.2.4:

> The members of the structure can be: A scalar integer or floating-point value. A vector of
> integer or floating-point values. … **You cannot use the `stage_in` attribute to declare members
> of the structure that are packed vectors, matrices, structures, bitfields, references or
> pointers to a type, or arrays of scalars, vectors, or matrices.**

같은 스펙의 함수 제약 절:

> The return type of a vertex or fragment function cannot include an element that is a packed
> vector type, **matrix type**, a structure type, a reference, or a pointer to a type.

Waple 의 `struct Vary` 는 **정점 반환 타입이자 프래그먼트 `[[stage_in]]`** 이므로 두 금지에 다 걸린다.

### 3.2 실물 자산

동봉 502 파일에서 `varying mat<N>` 선언은 **2줄**, 한 쌍이다:

```
effects/cursorripple/preview/shaders/effects/cursorripple_apply_force.vert:28  varying mat3 v_XForm;
effects/cursorripple/preview/shaders/effects/cursorripple_apply_force.frag:13  varying mat3 v_XForm;
```

둘 다 `#if PERSPECTIVE == 1` 안이고 `[COMBO]` 기본값은 `PERSPECTIVE: 0` 이다. 그래서
**선언 기본값 구성에서는 안 보이고 allOn 스윕에서만 나타난다.** 비-preview 판
(`effects/cursorripple/shaders/effects/cursorripple_apply_force.vert:27`)은 같은 줄이
`//varying mat3 v_XForm;` 로 **주석 처리돼 있다** — WE 저작자가 직접 껐다.

고치기 전 방출물(실측):

```
struct Vary {
  float4 gl_Position [[position]];
  ...
  float3x3 v_XForm;          ← Metal 이 거부한다
};
```

### 3.3 왜 종전 게이트가 못 잡았나

`GLSLBundledShaderRegressionTests` 의 미번역 토큰 목록은 **방출 MSL 전체**를 훑는 금칙어
목록이다. `float3x3` 은 `EngineU.mvp`·지역 변수로 **정당하게** 나오므로 전역 금칙어가 될 수
없고, GLSL 철자 `mat3` 도 아니라 "matN 타입" 패턴에 안 걸린다. **구조체 범위**로 봐야만 걸린다.
그래서 `allOn` 스윕이 이 구성을 실제로 번역했는데도 초록이었다.

### 3.4 고친 방법

배열 varying 과 **같은 규약**으로 열 벡터에 펼친다(`GLSLTranslator.expandArrayVaryings`):

- 선언 `varying mat3 v_XForm;` → `varying vec3 v_XForm_0..2;`
- vert: main 머리에 `float3x3 v_XForm;` 를 놓고, 말미에 `out.v_XForm_i = v_XForm[i];`
- frag: main 머리에 `float3x3 v_XForm = float3x3(in.v_XForm_0, in.v_XForm_1, in.v_XForm_2);`

성분 보존의 근거는 스펙 §2.3 "A matrix of type `floatnxm` consists of n `floatm` vectors" ·
`m[i]` 는 **열** · §2.3.2 "construct a matrix of type T with n columns and m rows from n vectors
of type T with m components" · "Metal constructs and consumes matrix components in column-major
order". GLSL 도 `m[i]` 가 열이라 왕복이 항등이다. `mat4x3` = 4열 × 3행 = MSL `float4x3` 로 같다.

**한계(배열과 동일)**: 로컬은 main 스코프라 **헬퍼 함수 안의 참조는 못 본다.** 그 경우 미정의
식별자가 남아 MSL 컴파일이 실패하고 폴백한다(조용한 오답이 아니라 폴터). 동봉에서 행렬 varying 을
헬퍼가 읽는 사례는 0건이다.

**[미해결] macOS 실컴파일 미검증.** 리눅스에 Metal 컴파일러가 없어 "고친 MSL 이 실제로 컴파일된다"
는 확인하지 못했다. 확인한 것은 (a) 스펙이 종전 형태를 금지한다는 것과 (b) 방출 텍스트가
의도한 모양이라는 것 둘뿐이다. macOS 레인의 `WapleRenderTests/GLSLTranslatorMSLTests`
(`makeLibrary`)가 최종 판정이다.

---

## 4. 회귀 하네스의 구멍

### 4.1 CRLF 때문에 헤더가 한 번도 인라인되지 않았다

`GLSLBundledShaderRegressionTests.inlineIncludes` 가 `src.split(separator: "\n")` 을 썼다.
Swift 의 `"\r\n"` 은 **단일 grapheme** 이라 `Character("\n")` 에 안 걸린다(브리프 함정 11).
동봉 셰이더는 `.vert`/`.frag`/`.h` 전건이 CRLF 이므로 **파일 전체가 한 "줄"** 이 되고
`hasPrefix("#include")` 가 거짓이 되어 헤더가 하나도 들어가지 않았다.

귀결: 스윕 노브(`knobs`)가 **헤더 안에서만 등장하는 콤보를 통째로 놓쳤다.** 새로 붙인 값
스윕의 요구 수가 정확히 이 결함을 잰다 — 고치기 전 **38**, 고친 뒤 **76**.

고친 방법: 자체 구현을 버리고 `ShaderPreprocessor.inlinedSource` 에 위임했다. 그 함수는 번역기
메모 키가 쓰는 바로 그 함수라 **전처리가 실제로 보게 될 텍스트와 정의상 같다.**

### 4.2 콤보 *값* 사각지대

종전 구성은 셋뿐이다 — 선언 기본값 · 모든 노브 1 · 모든 노브 0. 그래서 `#if NAME == N`(N≥2)
분기는 기본값이 마침 N 이 아닌 한 **원리적으로 도달 불가**다. 동봉 239쌍 실측:

| 항목 | 수 |
|---|---|
| 세 구성 어느 것으로도 참이 될 수 없는 (이름, 값) 쌍 | **76종** |
| 그런 분기를 하나라도 가진 셰이더 쌍 | **89쌍 / 239쌍 (37%)** |
| 최대 덩어리 `BLENDMODE == 2..32` 를 인라인하는 쌍 | **56쌍** |

`common_blending.h:172-271` 의 `ApplyBlending` 이 그 32갈래를 갖고 있고, 그 안에는
`#define BlendLighten BlendLightenf`(object-like 별칭 → function-like) ·
`BlendHardMixf` → `BlendVividLightf` → `BlendColorBurnf` 3중 체인 ·
`BlendOpacity(base, blend, F, O) mix(base, F(base, blend), O)`(**매크로 인자를 호출 이름으로**)
같은 어려운 입력이 들어 있다. 종전 게이트는 이 코드를 **한 줄도 번역해 본 적이 없었다.**

고친 방법: (이름, 값) 요구 하나당 **대표 셰이더 하나**를 골라 그 셰이더의 선언 기본값에서
**그 노브 하나만** 그 값으로 바꾼다. 76 요구 → 76 번역(대표 20쌍, 약 14초). 전량이면 1,452
번역이다. 노브를 하나만 흔드는 이유는 "전부 25" 같은 실물이 만들 수 없는 조합을 피하기 위해서다.

**결과: nil 0건 · 새 미번역 토큰 0종.** 즉 지금 시점에는 **무결점 확인**이지 결함 발견이 아니다.
값은 앞으로에 있다 — 블렌드/커널/품질 분기를 건드리면 여기서 걸린다.

### 4.3 여전히 못 보는 것 (남은 구멍)

- **MSL 이 실제로 컴파일되는지.** 리눅스에 Metal 이 없다. 여기 초록은 필요조건이다.
- **오역.** 토큰 린트는 "방언 토큰이 남았나" 만 본다. 의미가 틀린 번역은 통과한다
  (§3 의 결함이 정확히 그 부류였고, 구조체 멤버 타입 린트를 새로 붙여 그 한 갈래를 막았다).
- **`.geom` 4건**과 **`shaders/HLSL/` 3쌍**은 범위 밖(각각 Metal 에 지오메트리 스테이지가 없고,
  후자는 GLSL 이 아니라 D3D11 HLSL 원본이다).
- **노브 조합.** 값 스윕은 노브를 하나씩만 흔든다. `A==2 && B==3` 같은 교차 조건은 안 본다
  (동봉에 그런 형태는 없다).
- **워크샵 pkg.** 이 컨테이너에 없다.

---

## 5. 자산 전수 통계 (동봉 = 설치본)

| 항목 | 수 |
|---|---|
| `.vert` / `.frag` / `.h` / `.geom` | 242 / 242 / 14 / 4 |
| 번역 대상 쌍(HLSL 3쌍 제외) | **239** |
| `#endif` / `#if` / `#else` / `#include` / `#define` / `#ifdef` / `#elif` / `#require` / `#ifndef` / `#undef` | 1657 / 1583 / 307 / 228 / 203 / 68 / 51 / 8 / 6 / 1 |
| 서로 다른 `#if`/`#elif` 식 | 322 |
| 그중 `%`·비트·시프트·16진·삼항·`defined` 를 쓰는 것 | **0** |
| 지시문 줄에 `/*` 가 오는 경우 | **0** |
| `# <kw>`(공백) 형태 | **0** |
| `#if` 가 비-정수 object-like 매크로를 참조 | **0** |
| 인라인 후 `#if` 중첩이 안 맞는 TU | **0** |
| 줄머리 `// [COMBO]` 완전일치가 아닌 `[COMBO]` | **0** |
| 같은 헤더가 한 TU 에 두 번 인라인 | **0** |
| 함수형 `#define` | 39 |
| `#define` 줄 이음(`\` + 개행) | 0 |

선언 타입 분포(전수): `uniform float` 782 · `uniform sampler2D` 514 · `varying vec2` 408 ·
`varying vec4` 404 · `uniform vec4` 326 · `uniform vec2` 253 · `attribute vec3` 249 ·
`attribute vec2` 230 · `uniform mat4` 224 · `varying vec3` 204 · `uniform vec3` 164 ·
`attribute vec4` 47 · `varying float` 16 · `uniform mat4x3` 11 · `attribute uvec4` 10 ·
`uniform sampler2DComparison` 9 · `uniform mat3` 8 · **`uniform uint` 7** · `varying uint` 3 ·
**`varying mat3` 2** · `uniform sampler3D` 1 · `uniform sampler2DBackBuffer` 1 · 정밀도 한정자 11.

`GLSLType.from` 이 nil 을 내는 것은 **`uint` 하나뿐**이다(`uniform uint g_MorphOffsets[12]` —
`shaders/base/model_vertex_v1.h:25` 경유로 7파일). 그 선언은 파스에서 탈락하고 본문 참조가
미정의로 남아 컴파일이 실패한다 — 기존 `knownGaps` 가 이미 그 집합을 못 박고 있다.
`varying uint gl_ViewportIndex` 3건은 스테이지 빌트인으로 따로 처리된다.

전처리 출력의 **최상위 청크**를 분류해 본 결과, `uniform`/`varying`/`attribute`/`const`/
`struct`/`precision`/`in` 과 함수 정의·프로토타입 **밖의 것은 0종**이다(239쌍 × 2스테이지,
선언 기본값). 즉 "번역기가 조립하지 않아 조용히 사라지는 최상위 줄" 은 이 코퍼스에 없다.

---

## 부록 A. 재현

```bash
SC=<scratchpad>
flock -w 3600 "$SC/swift.lock" env WAPLE_LINUX_TEST_DIR="$SC/linux-tests-shared" \
  scripts/dev/linux-core-tests.sh --filter "GLSL|ShaderPreprocessor"
python3 scripts/spec/check_swift_escapes.py
python3 scripts/spec/check_swift_enum_patterns.py
```

두 트리가 같다는 확인:

```bash
cd Sources/WapleRender/Resources/WEAssets && find . \( -name '*.vert' -o -name '*.frag' \
  -o -name '*.h' -o -name '*.geom' \) -exec md5sum {} \; | sort -k2 > /tmp/b.txt
cd /home/user/Waple-wallpaper-source/wallpaper_engine/assets && find . \( -name '*.vert' \
  -o -name '*.frag' -o -name '*.h' -o -name '*.geom' \) -exec md5sum {} \; | sort -k2 > /tmp/i.txt
diff /tmp/i.txt /tmp/b.txt && echo IDENTICAL
```

## 부록 B. 인용한 함수 범위 (전부 `primary()`/`merged()` 확인)

| 범위 | 무엇 |
|---|---|
| `0x140166a90`–`0x1401670ba` | `#if` 식 렉서(주석 스킵 · 매크로 확장/스택 · 수치 리터럴 · 연산자 토큰화) |
| `0x1401670c0`–`0x140167c00`… | `#if` 식 파서 사슬 10단(§1.4) |
| `0x140167c00`–`0x140167e0c` | 단항·원자(`!` `~` `-` `+` · 수 · 이름 · `(` · **`defined`**) |
| `0x1401669a0` | 매크로맵 "정의됐나" 조회(`defined` 가 부른다) |
| `0x14016b0e0`–`0x14016c3f8` | 지시문 디스패처 9종 |
| `0x140169140`–`0x14016b0d4` | `#require LightingV1` 코드 생성기(4중 게이트) |
| `0x48be48`(파일오프셋) | 줄 인식 정규식 + 지시문 키워드 풀 |
| `0x14015458c`–`0x1401545aa` | 머티리얼 패스 콤보 키 `toupper` |
