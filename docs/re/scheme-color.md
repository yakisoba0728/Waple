# `schemecolor` — 파스·소비·그리고 배선하지 않기로 한 근거

대상: project `general.properties.schemecolor` (그리고 이름만 같은 material
`passes[].usershadervalues.schemecolor`).
바이너리: `wallpaper64.exe` (imagebase `0x140000000`), 보조로 `wallpaper32.exe`·`ui/dist/scripts/scripts.js`.

문장마다 **[확정]** / **[추정]** / **[미해결]** 을 구분한다.

---

## 0. 한 문단 결론

**[확정]** `general.properties.schemecolor.value` 는 `"r g b"` 문자열이고, WE 는 이 키를
**이름으로 특수 취급**해 `wallpaper+0x31B0/0x31B4/0x31B8` 전용 float3 슬롯에 넣는다. 그 슬롯의
소비처는 이미지 전체에서 **정확히 한 곳**이고, 거기서 `(r, g, b, 1.0)` 으로 그래픽 디바이스의
**클리어 색 설정 가상 함수**에 넘어간다. 곧 schemecolor 는 **배경/여백을 칠하는 색**이다.

**[확정]** 그런데 그 소비는 `wallpaper+0x124`(= 사용자 속성 `alignment`)가 **0 도 2 도 아닐 때만**
일어난다. `alignment` 는 project.json 키가 **아니고**(설치본 191 project.json 중 0건) WE 브라우저가
이미지/비디오 배경화면에 **주입하는 런타임 사용자 속성**이며, 생성자 기본값도 UI 기본값도 **0** 이다.
0/2 일 때는 schemecolor 대신 씬의 `general.clearcolor`(`scene+0x35C`)를 쓴다.

**그래서 Waple 에서 schemecolor 를 셰이더·렌더러에 배선하면 관측 차이가 0 이 아니라 "음수" 다** —
도달 가능한 경로가 없는데 씬의 `clearcolor` 를 덮을 위험만 생긴다. **배선하지 않는다.**

**[확정]** material 쪽 `usershadervalues.schemecolor` 는 **완전히 다른 것**이고 특수 처리가
**아니다**. `usershadervalues` 는 `{사용자 속성 키: 셰이더 material 토큰}` 제네릭 매핑이며,
`schemecolor` 는 그 키 자리에 가장 흔히 오는 이름일 뿐이다(§6). Waple 은 이미 제네릭 경로로
올바르게 처리한다.

---

## 1. 코퍼스 실측 (범위 라벨 포함)

직접 재측정했다. 브리프의 "162건" 은 맞다.

### 1.1 동봉 `Sources/WapleRender/Resources/WEAssets/`

| 항목 | 수 |
|---|---|
| `project.json` 총수 | **170** |
| 그중 `general.properties.schemecolor` 선언 | **161** |
| 그 161건 중 경로에 `preview` 가 들어가는 것 | **160** |
| `preview` 아닌 것 | **1** — `scenes/modeleditor/project.json` |
| material `passes[].usershadervalues.schemecolor` | **1** — `materials/util/fade.json`, 값 `"tint"` |
| 합계 | **162** ✅ |

**[확정] 161건의 `value` 는 전건 `"0 0 0"` 이다. 비영값 0건.**
전부 아래 한 형태다:

```json
"schemecolor" : { "order": 0, "text": "ui_browse_properties_scheme_color",
                  "type": "color", "value": "0 0 0" }
```

곧 **동봉 코퍼스만 놓고 보면 schemecolor 를 구현해도 그림이 바뀔 자산이 0건이다** — 값이 전건
생성자 기본값 `(0,0,0)` 과 동치이기 때문이다.

### 1.2 설치본 `/home/user/Waple-wallpaper-source/wallpaper_engine/`

| 항목 | 수 |
|---|---|
| `project.json` 총수 | **191** |
| `general.properties.schemecolor` 선언 | **180** |
| 그중 `"0 0 0"` | **164** |
| **비영값** | **16** (전건 `projects/defaultprojects/`) |
| material `usershadervalues.schemecolor` | **29** (`tint` 20 · `ambientcolor` 5 · `color1` 4) |

`usershadervalues.schemecolor` 29건의 소재: `projects/defaultprojects/**` 27 · `projects/templates/flag/materials/flag.json` 1 · `assets/materials/util/fade.json` 1.
`projects/defaultprojects/` 만 보면 `project.json` 19개가 **전건** `schemecolor` 를 선언하고 그중 **16건이 비영값**이다 — 곧 실제 배경화면에서는 이 키가 사실상 필수 속성이다.

비영 16건 전부:

```
demon_core            1 0 0                          shimmering_particles  0.8 0.4 0.05
razer_bedroom         0.0156… 0.0313… 0.2            eagleflag             0.18 0.38 0.184
retro                 0.72 0.64 0.42                 dino_run              0.2823… 0.5019… 0.0941…
fantasticcar          0.5725… 0.7098… 0.8078…        sheep                 0.1960… 0.4470… 0.2509…
beach                 1 0.8 0.2078…                  neon_sunset           0.89 0 0.27
deep_space            0.608 0.36 0.412               techno                0.1 0.2 0.7
dna_fragment          0.3294… 0.4509… 0.5137…        audiophile            0.45 1 0.1
razer_vortex          0.075 0.125 0.180              arsenal               0.22 0.17 0.125
```

**[확정]** `text` 도 저자가 자유롭게 바꾼다 — `ui_browse_properties_scheme_color` 외에
`ui_browse_properties_accent_color`(demon_core), `ui_browse_properties_background_color`(retro·
fantasticcar), `"Background color"`(eagleflag), `"Bar color"`, `"Scheme color"` 가 실측된다.
곧 **라벨은 규약이 아니다**. 규약인 것은 키 이름뿐이다.

---

## 2. 값의 형식과 색공간

**[확정] 0–1 부동소수 3성분, 스페이스 구분, 감마 변환 없음.**

UI 의 컨버터가 전부다(`ui/dist/scripts/scripts.js`):

```js
this.convertHexToVec3 = function(e){ e=A(e); return e.r/255+" "+e.g/255+" "+e.b/255 };
this.convertVec3ToHex = function(e){ … M(Math.round(255*parseFloat(t[0])), …) };
```

에디터/브라우저의 색 선택기는 `spectrum-colorpicker … vec-color-converter` 로 이 두 함수를
`$parsers`/`$formatters` 에 건다. 곧 저장되는 문자열은 **8비트 sRGB 헥스를 그냥 255 로 나눈 값**
이다 — 선형화도, 0–255 유지도 아니다. 실측 최대 성분이 `1`(beach `1 0.8 …`, demon_core `1 0 0`)
인 것과 일치한다.

**[확정]** 엔진 측 파스에도 변환이 없다 — `strtod` 결과를 `cvtsd2ss` 로 float 로 좁히는 것이
전부다(§3). 그래서 **문자열 그대로가 셰이더/클리어 색에 들어가는 값**이다.

**[확정]** WE 는 이 값을 미리보기 이미지의 대표색에서 자동 산출하는 경로도 갖는다 —
`getDominantColorFromFile` → `project.schemecolor`(scripts.js). 곧 의미는 "이 배경화면의
**강조색/대표색**" 이다.

---

## 3. 파스 — 어디에 착지하는가

**[확정]** 파서는 **사용자 속성 적용기** `0x140181F30` 이다(진입 `0x140181F30`, 본체 조각
`0x140181F5F–0x140182652`). 브리프 §5.2 의 `0x140181AF0` 은 **바로 앞의 다른 함수**다 —
`.pdata` 조각이 인접해 `merged()` 가 `0x140181AF0–0x140182F84` 를 한 덩어리로 보여줄 뿐이고
`primary()` 로 가르면 갈린다(재확인함).

시그니처: `f(rcx = wallpaper, rdx = Json::Value& userProps)` (`0x140181F4D` `mov r13, rdx` ·
`0x140181F55` `mov r15, rcx`).

**[확정] `r13` 은 project.json 의 `general.properties` 가 아니라 "유효 사용자 속성 딕셔너리" 다.**
근거: 같은 `r13` 에서 연달아 읽는 키가 `alignment` · `alignmentposition` · `alignmentx` ·
`alignmenty` · `alignmentz` · `alignmentfliph` · `schemecolor` · `wec_e` 인데, `alignment*`/`wec_*`
는 **project.json 에 존재하지 않고**(설치본 191/191 부재) WE 브라우저가 주입하는 런타임 속성이다
(§5). Waple 의 `userProps` 가 같은 성격이므로 `SceneDocument` 가 `userProps["schemecolor"]` 를
읽는 현행이 **원본과 동형이다**(project.json 을 직접 읽는 쪽이 오히려 덜 충실하다).

절차:

```
0x1401821F9  lea rdx, "schemecolor"          ; .rdata 0x140474560
0x140182200  call 0x140086DE0                ; Json::Value::operator[](key)
0x14018220B  cmp byte [rax+8], 7             ; objectValue 아니면 → 0x14018232C (슬롯 미변경)
0x140182226  call 0x140086DE0                ; ["value"]
0x14018222B  cmp byte [rax+8], 4             ; stringValue 아니면 → 0x14018232C (슬롯 미변경)
0x14018224B  mov rbx, [rax]                  ; char* 획득
0x140182283  cmp byte [rbx], 0               ; 빈 문자열이면 → 0x140182311 (셋 다 0 저장)
0x14018228F  call 0x1402D06AC  (strtod)      ; r  → xmm8
0x1401822C0  cmp byte [rbx], 0x20            ; 구분자 전진 스캔: **스페이스(0x20)만**
0x1401822D0  call 0x1402D06AC  (strtod)      ; g  → xmm7
0x140182308  call 0x1402D06AC  (strtod)      ; b  → xmm0
0x140182311  movss [r15+0x31B0], xmm8
0x14018231A  movss [r15+0x31B4], xmm7
0x140182323  movss [r15+0x31B8], xmm0
```

**[확정]** 부재/타입 불일치는 세 store 를 **건너뛴다** — 슬롯은 생성자값을 유지한다. 빈 문자열은
반대로 **명시적으로 0 을 쓴다**. 두 경로 모두 결과는 `(0,0,0)` 이라 관측상 같다.

**[확정]** 생성자 기본값은 0 이다:
`0x140110BD1`(`mov qword [rdi+0x31B0], 0` · `0x140110BDF` `mov [rdi+0x31B8], r12d`) 와
`0x14012B9C8`(`mov qword [rsi+0x31B0], r15` · `0x14012B9CF` `mov [rsi+0x31B8], r15d`), 둘 다 r12/r15 = 0.

**[확정] 성분이 모자라면 남은 성분은 0 이고 드롭이 아니다** — `strtod` 가 비숫자 토큰에서 0 을
주고 자리는 유지된다. 실측(동봉+설치본)은 전건 3성분이라 이 규약 차이가 드러나는 자산은 0건이다.

### 3.1 이미지 전수 스캔 — `+0x31B0/B4/B8` 을 만지는 자리는 다섯 곳뿐

`.text` 전체를 disp32 바이트 스캔했다(`lea` 선형 스캔이 아니라 — 함정 10/12).

| VA | 무엇 | 함수(primary) |
|---|---|---|
| `0x140110BD1` | 생성자 A, 0 초기화 | `0x140110630` |
| `0x14012B9C8` | 생성자 B, 0 초기화 | `0x14012B890` |
| `0x140182311`–`0x140182323` | **쓰기**(위 파서) | `0x140181F30` |
| `0x14017FC58`–`0x14017FC6E` | **읽기(주소 취득)** | `0x14017FA70` |
| `0x14018033A`–`0x14018034D` | **읽기(역참조)** | `0x14017FA70` |

나머지 disp32 매치(`0x1401C7F28` · `0x1403F25A8` = `jmp rel32`, `0x1400D2A65` · `0x1403006C4` =
`mov eax, 0x31`)는 전부 오탐이다.

**[확정] 스크립트 바인딩 없음. 셰이더 유니폼 업로드 없음.** 소비는 §4 한 곳뿐이다.

---

## 4. 소비 — 끝까지 따라간 결과

**[확정] 유일한 소비는 배경 클리어 색이다.**

### 4.1 주소 선택 (`0x14017FA70` 안, `0x14017FC4C`–`0x14017FC9A`)

```
0x14017FC4C  test dword [rsi+0x124], 0xFFFFFFFD   ; = (alignment & ~2)
0x14017FC56  je   0x14017FC7B                     ; 0 이면 clearcolor 경로
0x14017FC58  lea rcx, [rsi+0x31B0] → [rbp-0x50]   ; R  (schemecolor)
0x14017FC63  lea rcx, [rsi+0x31B8] → [rbp-0x70]   ; B
0x14017FC6E  lea rcx, [rsi+0x31B4] → [rbp-0x48]   ; G
0x14017FC79  jmp 0x14017FC9E
0x14017FC7B  mov rax, [rsi]                       ; [wallpaper+0] = scene
0x14017FC7E  lea rcx, [rax+0x35C] → [rbp-0x50]    ; R  (clearcolor)
0x14017FC89  lea rcx, [rax+0x364] → [rbp-0x70]    ; B
0x14017FC90  add rax, 0x360        → [rbp-0x48]   ; G
```

**[확정] `scene+0x35C` 는 `general.clearcolor` 다.** 리플렉션 디스크립터에서 직접 확인했다
(함정 16 대비: 이름 store 와 오프셋 store 가 **같은 `rbx`** 위에 있고, 다음 항목 `ambientcolor`
전에 `mov rbx, [rbp-0x38]` 로 rbx 가 갈리므로 한 칸 밀림이 아니다):

```
0x14019A117  lea rdx, "clearcolor"                ; .rdata 0x14048E7D0
0x14019A128  call 0x14000F880                     ; 이름 → [rbx+0x68]
0x14019A130  mov dword [rbx+0x34], 0x35C          ; ← 멤버 오프셋
0x14019A142  mov dword [rbx+0x30], 2              ; ← 타입 태그
0x14019A1B5  lea rdx, "ambientcolor"              ; (다음 항목, rbx 재적재 후)
```

곧 **두 후보는 "씬의 클리어 색" 과 "배경화면의 강조색" 이고, 둘 중 하나가 배경으로 칠해진다.**

### 4.2 실제 호출 (`0x14018031F`–`0x140180351`)

```
0x14018031F  mov rdx, [rbp-0x70]          ; &B
0x140180323  mov rcx, [rsi+0x1528]        ; 그래픽 디바이스/컨텍스트 객체
0x14018032A  movss xmm14, 1.0
0x140180333  movss [rsp+0x20], xmm14      ; arg4 = alpha = 1.0
0x14018033A  movss xmm3, [rdx]            ; arg3 = b
0x14018033E  mov rdx, [rbp-0x48]
0x140180345  movss xmm2, [rdx]            ; arg2 = g
0x140180349  mov rdx, [rbp-0x50]
0x14018034D  movss xmm1, [rdx]            ; arg1 = r
0x140180351  call [rax+0x118]             ; this = [rsi+0x1528]
```

**[확정] 가상 슬롯 `+0x118` 은 "클리어 색 설정(r,g,b,a)" 이다.** 교차검증: 같은 슬롯이
`0x140181D2B`–`0x140181D4C` 에서 **불투명 검정으로 상수 호출**되고, 바로 다음 줄에서
같은 객체의 `+0x120` 이 호출된다(= 실제 Clear로 보임, **[추정]**):

```
0x140181D2B  mov rcx, [r14+0x1528]
0x140181D32  xorps xmm3, xmm3            ; b = 0
0x140181D3D  xorps xmm2, xmm2            ; g = 0
0x140181D40  xorps xmm1, xmm1            ; r = 0
0x140181D43  movss [rsp+0x20], 1.0       ; a = 1
0x140181D4C  call [rax+0x118]            ; SetClearColor(0,0,0,1)
0x140181D61  call [rax+0x120]            ; (dl=1, r8d=0)
```

**[미해결]** `+0x118`/`+0x120` 의 실제 심볼명. RTTI 로 클래스명을 확정하지 않았다.
다만 인자 형태(4 float, 알파 1.0 고정)와 호출 위치(프레임 시작, 씬 그리기 직전)로
**클리어 색 설정** 이라는 판정은 흔들리지 않는다.

---

## 5. `alignment` 게이트 — 왜 도달하지 않는가

### 5.1 게이트 조건

`test dword [wallpaper+0x124], 0xFFFFFFFD` + `je` ⇒ **`(alignment & ~2) == 0`**, 곧
`alignment ∈ {0, 2}` 이면 **clearcolor**, 그 밖(`1, 3, 4`)이면 **schemecolor**.

### 5.2 `+0x124` 는 사용자 속성 `alignment` 다

```
0x140181F6A  lea rdx, "alignment"
0x140181F79  cmp byte [rax+8], 7      ; objectValue 게이트
0x140181F98  call 0x1400886E0         ; Json::Value::isInt()  (태그 1/2/3 정수성 검사 — 본체 확인)
0x140181FBA  call 0x140085EE0         ; Json::Value::asInt()  (태그 0/1/2/3/5 처리 — 본체 확인)
0x140181FBF  mov [r15+0x124], eax
```

**[확정] 생성자 기본값은 0 이다** — `wallpaper+0x10` 서브객체 생성자 `0x14017C6D0` 의
`0x14017C7CA  mov qword [rcx+0x110], 0x3F800000` 가 서브객체 `+0x114`(= `wallpaper+0x124`)를
같은 qword store 의 상위 4바이트로 **0 으로 깐다**.
**[확정]** UI 기본값도 0 이다 — `getSharedDefaultProperties = function(e){ var t = {alignment:0,
alignmentposition:50, rate:100, volume:50, cameraparallax:!0}; return e && (t.schemecolor=""), t }`.

### 5.3 열거값 (직접 떠서 확인 — 남의 표를 베끼지 않았다)

콤보 옵션 생성기 `0x140104B60`–`0x140108C17` 에서, 각 옵션마다 `"label"` 문자열과 `"value"`
정수를 **같은 블록에서** 같은 객체 `[rbp-0x30]` 에 넣는다:

| 값 | 라벨 | 정수 store VA |
|---|---|---|
| **0** | `ui_browse_properties_alignment_cover` | `0x140105A3C`(`xor ebx,ebx`) → `0x140105A60` |
| **1** | `ui_browse_properties_alignment_fill` | `0x140105B1C` |
| **2** | `ui_browse_properties_alignment_stretch` | `0x140105C93` |
| **3** | `ui_browse_properties_alignment_center` | `0x140105BD5` (`mov edx, 3` → `0x140084EF0`) |
| **4** | `ui_browse_properties_alignment_free` | `0x140105D4C` (`mov edx, 4` → `0x140084EF0`) |

**[확정] 게이트 `{0, 2}` = cover + stretch = 화면을 반드시 꽉 채우는 두 모드다.**
나머지 `fill(1)`/`center(3)`/`free(4)` 는 여백(레터박스/필러박스)이 생길 수 있는 모드다.
곧 **schemecolor 는 "여백이 생기는 정렬 모드에서 그 여백을 칠하는 색"** 이다.
`wallpaper32.exe` 의 UI 조건식이 이 해석과 정확히 맞물린다:
`alignment.value<2 && checkPositionVisibility()`(0·1 은 위치 슬라이더),
`alignment.value==3||alignment.value==4`(3·4 는 가로 오프셋), `alignment.value==4`(4 만 세로 오프셋).

### 5.4 `alignment` 는 project.json 키가 아니다

**[확정]** 설치본 191개 `project.json` 중 `general.alignment` 또는
`general.properties.alignment` 를 가진 것 **0건**. 동봉 170개 중에도 0건.
`alignment*` / `wec_*` / `rate` 는 **WE 브라우저가 런타임에 주입**하는 사용자 속성이고,
내보내기 때 다시 지운다(scripts.js: `delete e.alignment, delete e.alignmentx, …, delete e.wec_e,
delete e.rate`).

**[확정]** 주입 자체가 **배경화면 종류별 능력 비트마스크**에 걸린다 —
`0x140104B96` `and eax, 6` → `[rbp+0x1378]`, `0x140105792` `cmp dword [rbp+0x1378], 0` 이 0 이면
`alignment` 속성을 **아예 만들지 않는다**. (비트 2 는 추가로 `center`/`free` 옵션을 켠다:
`0x1401057C8` `shr r14d, 2` + `0x140105B7B`/`0x140105CF2` `test r14b, r14b`.)
문자열 이웃(`videowallpaper.cpp`, `volume`, `playback_rate`, `.webm`)으로 보아 **이미지/비디오
배경화면 전용 속성** 이다 — **[추정]**(씬용 호출자의 비트마스크를 개별 확정하지는 않았다).

---

## 6. material `usershadervalues.schemecolor` 는 특수 처리가 아니다

**[확정] `usershadervalues` 는 `{사용자 속성 키 → 셰이더 `material` 애노테이션 이름}` 제네릭 맵이다.**
셰이더 원문으로 교차검증했다:

```
demon_core/materials/backgroundsphere/background_diamond.json
    "usershadervalues": { "schemecolor": "tint", "bgcolor": "tint2" }
demon_core/shaders/backgroundsphere.frag
    uniform lowp vec3 g_Tint;  // {"material":"tint","default":"1 1 1"}
    uniform lowp vec3 g_Tint2; // {"material":"tint2","default":"0 0 0"}
demon_core/project.json general.properties
    bgcolor      = {… "value": "1 0.6470588235294118 0"}
    schemecolor  = {… "value": "1 0 0"}
```

`assets/materials/util/fade.json` 도 같은 구조다 — `{"schemecolor":"tint"}` 이고
`assets/shaders/fade.frag` 에 `uniform lowp vec3 color; // {"material":"tint", …}` 가 있다.

**[확정] 키 자리에는 아무 사용자 속성 이름이나 온다.** 설치본 전수 census:

```
키   : schemecolor 29 · accentcolor 4 · bgcolor 3 · color2 2 · flagcolor1 2 · flagcolor2 2 ·
       rimscolor · carbodycolor · carstripescolor · clouds · horizon · noisefx ·
       colorsunbottom · colorsuntop · gridnear · gridfar · gridbackground ·
       mountainscale · shading   (각 1)
값   : tint 23 · ambientcolor 5 · color1 4 · color2 4 · tint2 3 · color3 2 · paintcolor 2 ·
       paintcolorstripes · clouds · horizon · noisefx · colorsunbottom · colorsuntop ·
       gridnear · gridfar · gridbackground · mountainscale · shading · tintaccent  (각 1)
```

`schemecolor` 가 키로 제일 흔한 이유는 **모든 프로젝트에 반드시 존재하는 유일한 속성이라서**다
(WE 에디터가 없으면 `{value:"0 0 0"}` 을 주입한다 — scripts.js `openProject`). 이름 특수화가 아니다.

**Waple 은 이미 이 규약을 제네릭하게 구현한다** — `SceneDocument.swift` C⑦a
(`for (userKey, v) in usv { … p.constants[token] = … }`). **추가 작업 없음.**

**[미해결]** 사용자 속성 값이 **런타임에 바뀌었을 때** WE 가 이 바인딩을 매 프레임 다시 푸는지
(정적 해석이 아닌지)는 확인하지 않았다. Waple 은 파스 시점 정적 해석이다.

---

## 7. Waple 에서의 판단 — 배선하지 않는다

### 7.1 왜

1. **[확정]** 소비처는 클리어 색 하나뿐인데, 그 경로는 `alignment ∈ {1,3,4}` 를 요구한다.
2. **[확정]** `alignment` 는 project.json 에 존재하지 않는 WE 브라우저 주입 속성이고
   기본값이 0(cover)이다. Waple 에는 이 속성도, 그 주입 경로도, 여백이 생기는 정렬 합성 경로도 없다.
3. **[확정]** 동봉 코퍼스 161건은 값이 전건 `"0 0 0"` 이라, 설령 배선해도 **동봉 자산에서
   달라지는 픽셀이 0개다**.
4. **[확정]** 잘못 배선하면 **손해**다 — schemecolor 를 무조건 클리어 색으로 쓰면 씬의
   `general.clearcolor` 를 덮는다(원본은 alignment 0/2 에서 clearcolor 를 쓴다).

### 7.2 그래서 무엇을 했는가

- **프로덕션 로직 변경 없음.** `WallpaperProperties.swift` / `ProjectJSONParser.swift` 는
  `schemecolor` 를 **제네릭 사용자 속성으로 그대로 통과**시키고, 그게 원본과 일치한다.
- 대신 그 판단을 **테스트로 잠갔다**(`Tests/WapleCoreTests/WallpaperPropertiesTests.swift`
  `testSchemeColorStaysAPlainUserProperty…` 4건). 잠그는 것:
  - `type:"color"` + `value:"r g b"` 가 `.string` 으로 **원문 보존**(0–255 스케일링·감마 변환 금지),
  - 설치본 실측 비영값이 그대로 왕복,
  - `weUserPropertiesJSON` 이 `schemecolor` 를 **빼먹지 않음**(빼면 `usershadervalues.schemecolor`
    → `tint` 바인딩과 씬 스크립트가 동시에 깨진다),
  - `schemecolor` 없는 프로젝트의 파스가 한 값도 안 바뀜(무회귀).

### 7.3 만약 언젠가 배선한다면 (미래 참고용)

`alignment` 를 Waple 에 도입해 이미지/비디오 배경화면의 정렬 합성을 구현하는 날에만 의미가 있다.
그때의 규약은:

```
clearColorRGB = (alignment == 0 || alignment == 2) ? scene.clearColor : project.schemeColor
alpha = 1.0
```

`alignment` 는 `{cover:0, fill:1, stretch:2, center:3, free:4}`, 기본 0.

---

## 8. [미해결] 목록

1. `[wallpaper+0x1528]` 객체의 클래스명과 가상 슬롯 `+0x118`/`+0x120` 의 심볼명(RTTI 미확인).
   인자 형태로 "클리어 색 설정" 은 확정, 이름만 미확정.
2. 능력 비트마스크(`0x140104B60` 의 `edx`)에서 **씬 배경화면**이 정확히 어떤 값을 받는지.
   호출자 6곳 중 둘은 `edx = 0x24` 상수(`0x14012911E` · `0x14012986A`), 둘은
   `or edx, 0xD0` 로 동적 계산(`0x1400EB45` 근방 · `0x1401104D4` 근방)이다. 각 호출자가 어떤
   배경화면 종류인지 대응시키지 않았다. `0xD0 & 6 == 0` 이라 동적 계산분이 비트 1/2 를 켜지
   않으면 씬에는 `alignment` 가 안 붙는다 — **[추정]** 이지만 확정은 못 했다.
3. `usershadervalues` 바인딩의 런타임 갱신 여부(§6).
4. 구분자에 탭/개행이 섞인 `schemecolor` 값의 동작 차이. WE 는 `cmp byte [rbx],0x20` 하나만 보므로
   탭을 성분 내부로 삼킨다. 실측 도달 0건이라 맞추지 않았고, Waple 도 맞추지 않았다.

---

## 9. `GetDominantColor` — 편집기가 `schemecolor` 를 **만드는** 자리

> **[2026-08-21, 클러스터 AE]** §1–§8 은 `schemecolor` 를 **읽는** 쪽을 다룬다. 여기서는
> 그 값이 애초에 어디서 나오는지, 그리고 그것이 우리 `ArtworkColors` 와 어떻게 다른지를 적는다.
> 이 절은 `Sources/WapleRender/ArtworkColors.swift` 머리말이 참조하는 자리다.

### 9.1 함수 동정

편집기(`ui/dist/scripts/scripts.js`)가 `getDominantColorFromFile` 로 부르고 그 결과를
`project.schemecolor` 에 넣는다. 네이티브 쪽 진입점은 `bin/resourceutil64.dll`
(imagebase `0x180000000`)의 `GetDominantColor` / `GetDominantColorFromImage` 두 export 이고,
**둘 다 `0x18000a6d0` 하나로 폴딩**된다. 본체는 `sub_180009e30` 이다.

`wallpaper64.exe` 가 아니라 `resourceutil64.dll` 이라는 점이 중요하다 — 공통 브리프 함정 #13
("바이너리 하나 ≠ WE") 그대로다. `wallpaper64.exe` 만 훑으면 이 함수는 존재하지 않는 것처럼 보인다.

### 9.2 산식 (실측)

1. RGBA8 전 픽셀을 HSV 로 바꾼다 (`0x180009f85`–`0x18000a035`). 픽셀 dword 는 byte0 = R.
2. **hue 를 1° 단위 360빈**으로 나눈다 (`cvttss2si` 후 359 상한, 음수는 0).
   `delta < 1e-5` 이거나 `max <= 0` 인 **무채색 픽셀은 빈 0 에 `sat = 0` 으로** 들어간다.
3. 빈마다 넷을 누적한다:
   - `weight += (int)(sat * val * 100)` (`0x18000a093`)
   - `count += 1`
   - `satSum += sat`
   - `valSum += val`
4. `weight` 최대 빈 하나를 고르고 `H = bin/360` · `S = satSum/count` · `V = valSum/count` 로
   **HSV→RGB 역변환**해 `0xFF000000 | B<<16 | G<<8 | R` 로 싼다
   (`0x18000a508`–`0x18000a6a2`).

핵심은 **`sat·val` 가중 빈도**다. 칙칙하거나 어두운 픽셀은 스스로 눌리므로, 면적이 넓어도
배경 회색이 대표색이 되지 않는다.

### 9.3 Waple `ArtworkColors` 와의 차이 — 전부 확정

| 축 | WE `GetDominantColor` | Waple `ArtworkColors` |
| --- | --- | --- |
| 양자화 | hue **360빈**(채도·명도는 빈 안에서 평균) | RGB 4bit×3 = **4096빈** |
| 가중치 | `sat·val` 가중 빈도 | **순수 빈도**(가장 넓은 면적이 이긴다) |
| 알파 | **안 본다** | `a < 128` 픽셀을 버린다 |
| 산출 개수 | **한 색** | 다섯(primary/secondary/tertiary/text/highContrast) |
| 표본 | 전 픽셀 | 64×64 이하로 리샘플 후 |

곧 **두 결과는 일반적으로 일치하지 않는다.** 이것은 버그가 아니라 서로 다른 문제를 푸는
두 함수다 — WE 의 이 함수는 *편집기가 프로젝트에 한 번 굽는* 값이고, 우리 쪽은 *재생 중
앨범아트에서 매번 뽑는* 값이다.

### 9.4 [미해결] — 다섯 색을 만드는 자리는 못 찾았다

썸네일 이벤트가 싣는 다섯 색은 `wallpaper64.exe` `0x14011be40`–`0x14011c90c` 에서
**이미 계산된 uint32** 로 읽힌다:

| 필드 | 오프셋 | 읽는 자리 |
| --- | --- | --- |
| primaryColor | `[obj+0x150]` | `0x14011c50d` |
| secondaryColor | `+0x154` | `0x14011c576` |
| tertiaryColor | `+0x158` | `0x14011c5c9` |
| textColor | `+0x15c` | `0x14011c61c` |
| highContrastColor | `+0x160` | `0x14011c66f` |

**그 다섯을 쓰는 자리는 특정하지 못했다.** `GetDominantColor` 를 그대로 이식해도 색이
하나뿐이라 이 다섯을 채울 수 없다. 이 갭을 닫으려면 쓰기 자리를 먼저 찾아야 한다.
