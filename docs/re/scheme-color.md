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
`0x140110BD1`(`mov qword [rdi+0x31B0], 0` · `0x140110BDC` `mov [rdi+0x31B8], r12d`) 와
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

나머지 disp32 매치(`0x1401C7F28` · `0x1403F25A8` = `jmp rel32`, `0x1400D2A65` · `0x1403006C4` =  [VA-스캐너위치]
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

> **[2026-08-21 · 클러스터 CJ — 상태 갱신]** 위 목록은 그대로 둔다(툼스톤). 지금 상태만 덧붙인다.
>
> | # | 상태 |
> | ---: | --- |
> | 1 | **여전히 미해결.** `[wallpaper+0x1528]` 의 RTTI 를 뜨지 않았다 |
> | 2 | **여전히 미해결.** 능력 비트마스크의 씬 경로를 대응시키지 않았다 |
> | 3 | **여전히 미해결.** `usershadervalues` 런타임 갱신 여부 |
> | 4 | **여전히 미해결이지만 도달 0으로 재확인.** 동봉 161 · 설치본 180건 전건 스페이스 구분이다 |
> | 5(§9.4) | **절반 해소.** "wallpaper64.exe 어디서 만드나" 는 **없다**로 확정했다(§9.4 의 추가 상자). 남은 것은 `bin/winrtutil64.exe` 안의 산식이다 |
> | 6(§10, 신규) | GIF 자동 생성 경로의 **호출자 사슬** |

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

> **[2026-08-21 · 클러스터 CJ — 명령 단위 재확인]** 위 4단계는 맞다. 아래는 그것을 **상수 적재
> 자리까지** 좁힌 것이고, 과제가 물은 "양자화 방식 · 가중치 · 채도 하한" 셋을 확정한다.
> 정본은 `spec/engine/dominant-color.json` `dominantColor.algorithm`, 생성기는
> `scripts/spec/measure_dominant_color.py`(바이트를 전수 대조하므로 낡으면 exit(1) 한다).

#### 9.2a 상수와 그 적재 자리 (`bin/resourceutil64.dll`, imagebase `0x180000000`)

| 상수 | 상수 VA | 적재 명령 | 쓰는 곳 |
| --- | --- | --- | --- |
| `255.0f` | `0x18011a3dc` | `0x180009efb` `movss xmm15` | 채널 정규화 제수 |
| `6.0f` | `0x18011a3d4` | `0x180009f14` `movss xmm13` | hue 섹터 제수 |
| `1.0f` | `0x18011a39c` | `0x180009f1d` `movss xmm12` | hue<0 보정 |
| `360.0f` | `0x18011a3e0` | `0x180009f26` `movss xmm9` | 빈 수 |
| `100.0f` | `0x18011a3d8` | `0x180009f48` `movss xmm10` | **가중치 배율** |
| `1e-5f` | `0x18011a398` | `0x180009f5a` `movss xmm11` | **무채색 임계** |
| `2.0`(f64) | `0x18011a3b0` | `0x180009f07` `movsd xmm14` | hue 섹터 +2 |
| `4.0`(f64) | `0x18011a3b8` | `0x180009f37` `movsd xmm7` | hue 섹터 +4 |
| `6.0`(f64) | `0x18011a3c0` | `0x18000a508` `movsd xmm1` | HSV→RGB `fmod` 제수 |

버퍼 넷은 진입에서 0 으로 밀린다 — `0x180009e97` `mov r8d, 0xb40`(= 360 × int64, weight·count
두 개)과 `0x180009edc` `mov r8d, 0x5a0`(= 360 × float, satSum·valSum 두 개).

#### 9.2b 양자화 축 — hue 360빈, **채도·명도는 양자화하지 않는다**

```
0x180009f85  mov ecx, [rsi + rax]     ; 픽셀 dword — byte0 = R
0x180009fd4  comiss xmm11, xmm6       ; 1e-5 > delta ?   → 무채색
0x180009fda  comiss xmm4, xmm8        ; fmax <= 0 ?      → 무채색
0x180009fe6  divss  xmm2, xmm4        ; S = delta / fmax  (HSV 채도)
0x18000a035  cvttss2si ecx, xmm1      ; bin = trunc(H · 360)
0x18000a039  cmp ecx, 0x167           ; 359 상한
0x18000a051  cmovs ecx, eax           ; 0 하한
```

`V` 는 `xmm4` = `fmax` 다. 무채색 갈래(`0x18000a048` `xor ecx,ecx` · `0x18000a04a`
`xorps xmm2,xmm2`)는 **빈 번호와 S 만 0 으로 만들고 `V` 는 건드리지 않는다** — 곧 흰색·회색
픽셀도 빈 0 의 `valSum` 을 올린다. (기존 문면 "빈 0 에 `sat = 0` 으로 들어간다" 와 같은 말이고,
V 가 그대로라는 점을 명시한다.)

#### 9.2c 가중치와 "채도 하한" — **별도의 하한 상수는 없다**

```
0x18000a05a  mulss xmm0, xmm4          ; S · V
0x18000a078  mulss xmm0, xmm10         ; × 100.0
0x18000a08c  cvttss2si eax, xmm0       ; **절단**
0x18000a093  add [rbp + rdx*8 + 0xa60], rcx   ; weight[bin] += (int64)eax
0x18000a070  inc qword [rbp + rdx*8 + 0x15a0] ; count[bin] += 1
```

곧 하한 노릇을 하는 것은 **`cvttss2si` 의 절단**이다: `S·V < 0.01` 인 픽셀은 가중치 기여가
정확히 0 이다. 다만 그 픽셀도 `count`/`satSum`/`valSum` 에는 들어가므로, **뽑힌 빈의 평균색은
여전히 끌어내린다.** "채도 하한이 있다/없다" 는 이 두 문장을 함께 읽어야 맞다.

#### 9.2d 선택과 역변환

```
0x18000a0fb  cmp r9, rax               ; weight[bin] > best ?
0x18000a105  mov edx, r9d              ; ← best 를 **int32 로 좁힌다**
0x18000a116  divss xmm0, xmm9          ; H = bin / 360
0x18000a14c  divss xmm6, xmm1          ; S = satSum[bin] / count[bin]
0x18000a150  divss xmm7, xmm1          ; V = valSum[bin] / count[bin]
0x18000a515  mulss xmm6, xmm7          ; C = S · V
0x18000a544  subss xmm7, xmm6          ; m = V − C
0x18000a6a2  or edx, 0xff000000        ; 출력 = 0xFF000000 | B<<16 | G<<8 | R
```

역변환은 표준 HSV→RGB 다 — `C = S·V`, `X = C·(1 − |fmod(H·6, 2) − 1|)`(`0x18000a51d` /
`0x18000a533` 의 `fmod` 두 번), `m = V − C`, 각 채널 `×255` 후 `[0,255]` 클램프.

**결함 하나 [확정].** 최대 빈 비교(`0x18000a0fb`)는 새 최대를 `mov edx, r9d`(`0x18000a105`)로
**32비트만** 보관하고 다음 비교에서 `movsxd rax, edx` 로 되편다. 픽셀수 × 100 이 2³¹ 을 넘으면
(전 픽셀이 `S·V=1` 일 때 약 2,148만 픽셀 = 대략 5.7K×3.8K 이상) 비교가 뒤집힐 수 있다.
실행 관측은 못 했으므로 **결함의 존재만 확정이고 발현 여부는 미관측**이다.

**알파는 읽지 않는다 [확정].** 본체 `0x180009e30`–`0x18000a6af` 어디에도 픽셀 dword 의 byte3
을 쓰는 명령이 없다(`shr ecx, 0x10` 까지가 전부 — `0x180009f92`).

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

> **[2026-08-21 · 클러스터 CJ — 어디에 **없는지**를 확정했다]** 위 문장의 "쓰기 자리" 를
> `wallpaper64.exe` 안에서 **전수로 찾았고, 없다는 것을 확정했다.**
>
> **그물.** `.pdata` 의 모든 함수를 선형 디스어셈해서, 다섯 변위
> (`+0x150`·`+0x154`·`+0x158`·`+0x15c`·`+0x160`)로 가는 **스택이 아닌** dword
> 스토어(`mov`/`movss`)를 전수로 셌다 — **95건 / 48함수**. 다섯 중 **넷 이상**을 쓰는 함수는
> 다섯 개뿐이고 전부 무관하다:
>
> | 함수 | 왜 무관한가 |
> | --- | --- |
> | `0x140058c15` · `0x1401dd630` · `0x1401de962` · `0x1401df620` | 전건 `movss` — **float** 다섯 개다. uint32 색이 아니다 |
> | `0x1400d834f` | `[rdi + r9 + 0x150]` 처럼 **런타임 베이스**를 더한 4×4 행렬 복사(같은 함수가 `+0x108`…`+0x17c` 를 `0x10` 간격으로 채운다) |
>
> 미디어 구조체 자신을 만지는 자리는 **셋뿐이다**:
> (a) 생성자 `0x1400c1390` 의 0 초기화 — `0x1400c1402`(qword, `+0x150`/`+0x154`) ·
> `0x1400c1409`(qword, `+0x158`/`+0x15c`) · `0x1400c1413`(dword, `+0x160`),
> 그리고 `0x1400c1428` `mov byte [rdx+0x174], 1` 로 `enabled` 만 1 이다.
> (b) 복사 생성자 `0x1400c23f0`–`0x1400c249b`(`0x1400c2422`–`0x1400c2454`).
> (c) 이벤트 빌더 `0x14011be40`–`0x14011c90c` 의 **읽기**(위 표).
>
> **교차 근거.** `wallpaper64.exe` 에는 WinRT 미디어 세션 문자열이 **0건**이다 —
> `Windows.Media.Control` · `GlobalSystemMediaTransportControlsSessionManager` 를 ASCII·UTF-16
> 양쪽으로 세도 0/0 이다. 그 문자열은 `bin/winrtutil64.exe` 에만 있고(각각 ascii 1·utf16 1 /
> utf16 1), 그 실행 파일은 `api-ms-win-core-winrt-l1-1-0.dll` 을 임포트하며 OpenCV 4.4.0 과
> FreeImage 를 링크한다. 곧 미디어 세션 호스트는 **별도 프로세스**이고 다섯 색은 IPC 로
> 건너온다 — 공통 브리프 함정 #13("바이너리 하나 ≠ WE") 그대로다.
>
> **[미해결] 로 남는 것**은 이제 "wallpaper64 어디서 만드나" 가 아니라
> "`winrtutil64.exe` 의 어느 함수가 만드나" 다. 그 안에서 `cv::kmeans` 는 링크만 되고
> **호출되지 않는다**(`OPENCV_KMEANS_PARALLEL_GRANULARITY` 전역 `0x1403ab6b0` 을 읽는 자리가
> 정적 초기화자 `0x1400017d0` 하나뿐이고, 그 초기화자를 부르는 자리도 0건이다). 즉 팔레트
> 추출에 OpenCV kmeans 를 쓰지는 않는다 — 그 이상은 안 떴다.
>
> **Waple 에 대한 함의는 바뀌지 않는다.** `ArtworkColors` 는 여전히 독자 알고리즘이고,
> `GetDominantColor` 로는 다섯 색을 채울 수 없다(색이 하나다).

---

## 10. `schemecolor` 를 **엔진이 직접** 짓는 자리 (2026-08-21, 클러스터 CJ)

§2 는 "WE 는 이 값을 미리보기 이미지의 대표색에서 자동 산출하는 경로도 갖는다" 를
**에디터 JS**(`getDominantColorFromFile`)로만 인용했다. 같은 일을 하는 **네이티브 경로**가
`wallpaper64.exe` 안에 있다. 정본은 `spec/engine/dominant-color.json`
`dominantColor.schemecolorGeneration`.

함수는 `0x140110060`–`0x1401105a5`(`.pdata` 조각 5개 병합)이고, 절차는:

```
0x140110209  lea rdx, ".gif"                       ; 0x140487000  — 확장자 게이트
0x140110223  call 0x140118880                      ; endsWith 판정 → al
0x140110237  je  0x1401104ab                       ; .gif 가 아니면 통째로 건너뛴다
0x14011023f  lea rcx, L"resourceutil64.dll"        ; 0x140478170 (UTF-16)
0x14011024c  call [0x140426638]                    ; LoadLibraryExW(…, 0, 0x1000)
0x14011027b  lea rdx, "GetDominantColorFromImage"  ; 0x140489198
0x140110285  call [0x140426660]                    ; GetProcAddress
0x1401102a4  call rax                              ; eax = 0xFF000000|B<<16|G<<8|R
0x1401102c1  lea r8,  "%.5f %.5f %.5f"             ; 0x1404890d8
0x140110322  call 0x1400162a0                      ; snprintf(buf, 0xc4, fmt, R, G, B)
0x1401103cb  lea rdx, "schemecolor"                ; 0x140474560
0x1401103ea  lea rdx, "value"                      ; 0x140474508
```

**[확정] 채널 순서는 R, G, B 다.** `eax` 를 쪼개는 세 명령이
`0x1401102cd` `shr ecx, 0x10`(B) · `0x1401102da` `shr eax, 8`(G) · `0x1401102f8` `movzx eax, bl`(R)
이고, 가변인자 자리가 `r9`=R · `[rsp+0x20]`=G · `[rsp+0x28]`=B 다. 각 채널은 `/255.0f`
(`0x1401102b9` `movss xmm2, 255.0`) 후 double 로 넓혀 실린다.

**[확정] 이것이 §2 의 "0–1 부동소수 3성분" 을 네이티브 쪽에서도 뒷받침한다** — 감마 변환도
0–255 유지도 없고, 그냥 `채널/255` 를 소수 5자리로 찍는다.

**[확정] 게이트는 `.gif` 다.** 곧 이 경로는 **애니메이션 GIF 배경화면**이 `schemecolor` 를
안 갖고 있을 때 엔진이 첫 프레임에서 뽑아 채우는 자리다. 씬(`scene.json`) 배경화면은 이
경로를 타지 않는다 — 씬의 `schemecolor` 는 저작 시점에 에디터가 넣는다(§2 의 JS 경로).

**[미해결]** 이 함수의 호출자 사슬(어느 시점에 GIF 배경화면이 이 경로를 타는지)은 따라가지
않았다. `wallpaper+0x3d8` 뮤텍스와 `+0x424` 상태값으로 보호되는 것까지만 봤다.

**Waple 도달 0.** Waple 은 `schemecolor` 를 배선하지 않기로 했고(§7), GIF 배경화면의
자동 생성 경로도 없다. 이 절은 **왜 안 배선해도 되는지**를 한 겹 더 뒷받침한다 — 원본에서도
이 값을 만드는 쪽은 렌더러가 아니라 저작·임포트 단계다.

---

> **[2026-08-21 · VA 인용 정정 1건]** `scripts/re/va_citations.py` 로 잡았다. §4 의
> 종전 `0x140110BDF` 는 `mov [rdi+0x31B8], r12d` 의 **변위 필드 위치**(명령 +3)였다 —  [VA-정정]
> 명령 주소는 `0x140110BDC` 다. 문서가 적은 명령 자체는 맞았고 주소만 밀려 있었다.  [VA-정정]
> 같은 절의 "나머지 disp32 매치" 줄은 **일부러** disp32 위치를 적은 것이라 그대로 두고
> `[VA-스캐너위치]` 마커만 달았다.
