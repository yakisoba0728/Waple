# 씬 합성/후처리 체인 복원

wallpaper64.exe (imagebase `0x140000000`) + 동봉 셰이더/머티리얼 평문 + 씬 코퍼스 358개를
교차대조해, **씬이 화면에 도달하기까지의 합성·후처리 전 구간**을 복원한 기록이다.

- 바이너리: `/root/.claude/uploads/.../440072bd-wallpaper64.exe`
- 셰이더/머티리얼 평문: `wallpaper_engine/assets/{shaders,materials}/`
- 코퍼스: `Sources/WapleRender/Resources/WEAssets/**/{scene,gifscene}.json`(171+1) +
  `wallpaper_engine/**/{scene,gifscene}.json`(184+2) = **358 파일**

관련 정본(중복 서술 대신 참조): `spec/engine/render-pass.json`(패스 순서·머티리얼 슬롯),
`spec/engine/uniform-feed.json`(유니폼 피드), `spec/engine/hdr-bloom.json`(피라미드 구조),
`spec/engine/render-state.json`(블렌드/백버퍼). 이 문서는 그것들이 다루지 않는
**씬 키 전수 · 파서/기본값 VA · 카메라 투영 · 탭 반경** 을 채우고, 겹치는 곳은 재측정해 확인/정정한다.

---

## 1. 코퍼스 후처리 키 히스토그램 (358 씬)

### 1.1 `general.*` 전수 — 39키 (상위 30)

| # | 키 | 씬 수 | 비율 | 타입 | 압도적 저작값 |
|---|---|---:|---:|---|---|
| 1 | `bloom` | 358 | 100.0% | bool | `false` 348 / `true` 10 |
| 2 | `clearcolor` | 358 | 100.0% | vec3 | 정확히 `0.7 0.7 0.7` 273 · `0.70196` 18 |
| 3 | `ambientcolor` | 353 | 98.6% | vec3 | `0.3 0.3 0.3` 348 |
| 4 | `orthogonalprojection` | 353 | 98.6% | object | `{w:256,h:256}` 332 · `{auto:true}` 4 · `null` 3 |
| 5 | `skylightcolor` | 353 | 98.6% | vec3 | `0.3 0.3 0.3` 352 |
| 6 | `bloomstrength` | 341 | 95.3% | float | `2.0` 338 |
| 7 | `bloomthreshold` | 341 | 95.3% | float | `0.65` 338 |
| 8 | `cameraparallax` | 341 | 95.3% | bool | `false` 339 |
| 9 | `cameraparallaxamount` | 341 | 95.3% | float | `0.5` 341 |
| 10 | `cameraparallaxdelay` | 341 | 95.3% | float | `0.1` 341 |
| 11 | `cameraparallaxmouseinfluence` | 341 | 95.3% | float | `0` 337 |
| 12 | `camerapreview` | 341 | 95.3% | bool | `true` 341 — **런타임 미소비**(§2.4) |
| 13 | `camerashake` | 341 | 95.3% | bool | `false` 341 |
| 14 | `camerashakeamplitude` | 341 | 95.3% | float | `0.5` 341 |
| 15 | `camerashakeroughness` | 341 | 95.3% | float | `1.0` 341 |
| 16 | `camerashakespeed` | 341 | 95.3% | float | `3.0` 341 |
| 17 | `clearenabled` | 277 | 77.4% | bool | `true` 188 / `null` 89 |
| 18 | `camerafade` | 195 | 54.5% | bool | `true` 192 |
| 19 | `fov` | 192 | 53.6% | float | `50.0` 190 |
| 20 | `farz` | 188 | 52.5% | float | `10000.0` 188 |
| 21 | `nearz` | 188 | 52.5% | float | `0.01` 180 / `0.1` 8 |
| 22 | `zoom` | 181 | 50.6% | float | `1.0` 181 |
| 23 | `bloomhdrstrength` | 179 | 50.0% | float | `2.0` 175 |
| 24 | `bloomhdrfeather` | 177 | 49.4% | float | `0.1` 176 |
| 25 | `bloomhdrscatter` | 177 | 49.4% | float | `1.619` 175 |
| 26 | `bloomhdrthreshold` | 177 | 49.4% | float | `1.0` 176 |
| 27 | `hdr` | 177 | 49.4% | bool | `false` 173 / `true` 4 |
| 28 | `bloomhdriterations` | 173 | 48.3% | int | `8` 173 (전건) |
| 29 | `bloomtint` | 154 | 43.0% | vec3 | `1 1 1` 154 (전건) |
| 30 | `perspectiveoverridefov` | 154 | 43.0% | float | `95.0` 142 / `90.76` 12 |

31~39위(후처리 밖이지만 `general` 소속): `gravitydirection`·`gravitystrength`·`winddirection`·
`windenabled`·`windstrength` 각 138, `norecompile` 12, `spritesheetrefreshsync` 5,
`lightconfig` 4, `transparentsorting` 4.

`camera` 블록: `eye`/`center`/`up` 각 356, `paths` 4.

### 1.2 요청 목록 중 **코퍼스에 존재하지 않는** 키

전 358 씬을 재귀 전수(모든 깊이, 모든 키 이름) 스캔한 결과:

`tonemap` · `colorgrade` · `lut` · `fxaa` · `vignette` · `dof` · `motionblur`(키로서) ·
`ambientocclusion` · `exposure` · `gamma` — **0건**.

씬 레벨 후처리의 저작 표면은 `general.*` 하나뿐이고, 나머지 후처리는 전부
오브젝트별 `effects[]`(별도 축)로 들어간다. 코퍼스가 참조하는 이펙트 상위:
`scroll` 38, `tint` 17, `lightshafts` 8, `blend` 8, `foliagesway` 8, `blurradial` 6,
`motionblur` 4(이펙트 파일), `vhs` 4, `blurprecise` 4, `colorkey` 4, `filmgrain` 3, `godrays` 3.

### 1.3 바이너리에는 있으나 코퍼스가 **한 번도 저작하지 않는** general 키

`fogdistance` · `fogheight` · `fogdistancecolor` · `fogheightcolor` · `fogdistancestart` ·
`fogdistanceend` · `fogdistancestartdensity` · `fogdistanceenddensity` · `fogheightstart` ·
`fogheightend` · `fogheightstartdensity` · `fogheightenddensity` · `customsortorder` — **13키 0건**.

→ fog 기본값 이탈은 코퍼스 A/B 로 절대 안 잡힌다. 워크샵 씬에서만 드러난다.

### 1.4 실효 분기 규모

| 분기 | 씬 수 |
|---|---:|
| `bloom:true` | 10 / 358 (2.8%) |
| `hdr:true` | 4 / 358 |
| `hdr && bloom`(→ HDR 피라미드) | **4** |
| `bloom && !hdr`(→ LDR 3패스) | 6 |
| `orthogonalprojection` 이 딕셔너리(=2D 정사영) | 350 |
| 그중 `auto:true` | 4 |
| 딕셔너리 아님(=3D 원근) | 8 |

`hdr && bloom` 4씬: `presets/lightning/previewthunderbolt`(동봉/설치본 각 1),
`projects/defaultprojects/shimmering_particles`, `projects/defaultprojects/razer_bedroom`.

---

## 2. 파서 — `general` 리플렉션 테이블

### 2.1 등록 함수

`general` 의 47개 키는 **한 함수**가 프로퍼티 디스크립터 배열로 등록한다.

- 등록 함수: `0x140199780`–`0x14019b4d6`
- 키 등록 헬퍼: `0x14000f880` (인자 `rcx=&desc.name`, `rdx=문자열 VA`, `r8d=길이`)
- 디스크립터 레이아웃: `+0x30`=타입 · `+0x34`=씬 구조체 오프셋 · `+0x38/0x40/0x48/0x50`=set/parse/put/get 썽크 · `+0x58`=변경 콜백
- 타입 enum: `0`=int · `2`=vec3 · `4`=float · `6`=bool

**[2026-08-21 보강] 등록 헬퍼는 하나가 아니라 둘이다.** 앞 42키는 `0x14000f880` 을 쓰지만
마지막 5키(`gravitydirection` `0x14019b2f3` · `gravitystrength` `0x14019b35c` ·
`windenabled` `0x14019b3b7` · `winddirection` `0x14019b436` · `windstrength` `0x14019b498`)는
`0x14000ddd0` 을 쓴다(길이 인자 없음). 헬퍼만 보고 테이블을 뽑으면 그 5키를 통째로 놓친다 —
47키를 재판독할 때 실제로 42키만 나왔고, 그래서 이 줄이 있다.

**[2026-08-21 보강] 변경 콜백(`+0x58`) 배치.** 47키 중 콜백이 붙는 것은 22키뿐이고 셋으로 갈린다:

| 콜백 VA | 붙는 키 | 하는 일 |
|---|---|---|
| `0x1401863e0` | `bloomstrength` `bloomthreshold` `bloomhdrstrength` `bloomhdrthreshold` `bloomhdrfeather` `bloomhdrscatter` `bloomhdriterations` `bloomtint` (8키) | 블룸 파이프라인 dirty 비트(bit31) 셋 |
| `0x1401863f0` | `ambientcolor` `skylightcolor` (2키) | 렌더상태 `+0x1298`/`+0x12a4` 로 푸시(§6.2) |
| `0x140186440` | `fogdistance` `fogheight` + fog 색/거리/밀도 10키 (12키) | fog 파라미터 패킹(§6.2) |

**`bloom` 과 `hdr` 에는 콜백이 없다**(`0x1401998b1` 이 `[rbx+0x58]` 에 `rdi=0` 을 기록 —
`xor edi,edi` @`0x14019989d`). 즉 강도/임계를 런타임에 바꾸면 파이프라인이 다시 서지만
`bloom` 플래그 자체를 토글하는 것은 dirty 를 안 세운다(게이트는 매 프레임 읽으므로 문제는 없다).

### 2.2 후처리/카메라 키 전표 (오프셋 = 씬 객체 기준)

| 키 | 타입 | 오프셋 | 기본값 | 등록 VA | 기본값 기록 VA |
|---|---|---|---|---|---|
| `bloom` | bool bit1 | `0xe0` | **true** | `0x140199825` | `0x140186d1f` (`qword=0x26`) |
| `hdr` | bool bit10 | `0xe0` | false | `0x1401998fd` | 〃 |
| `camerafade` | bool bit2 | `0xe0` | **true** | `0x14019ac9c` | 〃 |
| `clearenabled` | bool bit5 | `0xe0` | **true** | `0x14019a03d` | 〃 |
| `camerashake` | bool bit7 | `0xe0` | false | `0x14019ae94` | 〃 |
| `cameraparallax` | bool bit8 | `0xe0` | false | `0x14019b0c8` | 〃 |
| `transparentsorting` | bool bit12 | `0xe0` | false | `0x14019ad44` | 〃 |
| `customsortorder` | bool bit13 | `0xe0` | false | `0x14019adec` | 〃 |
| `fogdistance` | bool bit14 | `0xe0` | false | `0x14019a2fc` | 〃 |
| `fogheight` | bool bit15 | `0xe0` | false | `0x14019a3b8` | 〃 |
| `windenabled` | bool **bit16** | `0xe0` | false | `0x14019b361` | 〃 |
| `bloomstrength` | float | `0x3bc` | **2.0** | `0x1401999dc` | `0x1401870ac` |
| `bloomthreshold` | float | `0x3c0` | **0.65** | `0x140199ab4` | `0x1401870b7` |
| `bloomhdrstrength` | float | `0x3c4` | **2.0** | `0x140199b76` | `0x1401870c2` |
| `bloomhdrthreshold` | float | `0x3c8` | **1.0** | `0x140199c42` | `0x1401870cd` |
| `bloomhdrfeather` | float | `0x3cc` | **0.1** | `0x140199d08` | `0x1401870d8` |
| `bloomhdrscatter` | float | `0x3d0` | **1.61899995803833** | `0x140199dce` | `0x1401870e3` |
| `bloomhdriterations` | int | `0x3d4` | **8** | `0x140199ea6` | `0x1401870ee` |
| `bloomtint` | vec3 | `0x3d8` | (1,1,1) | `0x140199f70` | `0x140186ff0`·`0x140186ffb`·`0x140187006` |
| `clearcolor` | vec3 | `0x35c` | (0,0,0) | `0x14019a117` | `0x140186f61`·`0x140186f68` |
| `ambientcolor` | vec3 | `0x368` | (0,0,0) | `0x14019a1b5` | `0x140186f6f`·`0x140186f76` |
| `skylightcolor` | vec3 | `0x374` | (0,0,0) | `0x14019a25e` | `0x140186f76`·`0x140186f7d` |
| `fov` | float | `0x140` | **50.0** | `0x14019aa08` | `0x140186d5c` |
| `perspectiveoverridefov` | float | `0x144` | **95.0** | `0x14019aa8c` | `0x140186d67` |
| (실효 fov, 파생) | float | `0x148` | 50.0 | — | `0x140186d72` |
| `nearz` | float | `0x14c` | **0.1** | `0x14019ab10` | `0x140186d7d` |
| `farz` | float | `0x150` | **10000.0** | `0x14019ab94` | `0x140186d88` |
| `zoom` | float | `0x154` | 1.0 | `0x14019ac18` | `0x140186d93` |
| `camerashakespeed` | float | `0x328` | 3.0 | `0x14019af3c` | `0x140186f84` |
| `camerashakeamplitude` | float | `0x32c` | 0.5 | `0x14019afc0` | `0x140186f8f` |
| `camerashakeroughness` | float | `0x330` | 1.0 | `0x14019b044` | `0x140186f9a` |
| `cameraparallaxamount` | float | `0x334` | **0.5** | `0x14019b170` | `0x140186fa5` |
| `cameraparallaxdelay` | float | `0x338` | **0.1** | `0x14019b1f4` | `0x140186fb0` |
| `cameraparallaxmouseinfluence` | float | `0x33c` | **0.5** | `0x14019b278` | `0x140186fbb` |
| `fogdistancecolor` | vec3 | `0x380` | (0,0,0) | `0x14019a460` | `0x140186fd4`(`rax=0` @`0x140186f3b`) |
| `fogheightcolor` | vec3 | `0x38c` | (0,0,0) | `0x14019a506` | `0x140186fe2` |
| `fogdistancestart` | float | `0x398` | **1.0** | `0x14019a59c` | `0x140187063` |
| `fogdistanceend` | float | `0x39c` | **5.0** | `0x14019a634` | `0x14018706e` |
| `fogdistancestartdensity` | float | `0x3a0` | 0.0 | `0x14019a6bc` | `0x14018706e`(상위 dword) |
| `fogdistanceenddensity` | float | `0x3a4` | **1.0** | `0x14019a744` | `0x140187079` |
| `fogheightstart` | float | `0x3a8` | **1.0** | `0x14019a7dc` | `0x140187084` |
| `fogheightend` | float | `0x3ac` | **-3.0** | `0x14019a870` | `0x14018708f` |
| `fogheightstartdensity` | float | `0x3b0` | 0.0 | `0x14019a8f8` | `0x14018709a` |
| `fogheightenddensity` | float | `0x3b4` | **1.0** | `0x14019a980` | `0x1401870a1` |
| `gravitydirection` | vec3 | `0x3e4` | (0,-1,0) | `0x14019b2e8` | `0x140187006`·`0x140187011`·`0x14018701c` |
| `gravitystrength` | float | `0x3f0` | 1.0 | `0x14019b351` | `0x1401870f9` |
| `winddirection` | vec3 | `0x3f4` | (0.707, 0.707, 0.0) | `0x14019b42b` | `0x140187023`(x) · `0x14018702e`(qword → y=0.707, z=0) |
| `windstrength` | float | `0x400` | 1.0 | `0x14019b48d` | `0x140187104` |

씬 생성자(전 기본값 기록): `0x140186c90`–`0x1401872ba`.

**bool 비트맵**(`scene+0xe0`, 생성자 초기값 `0x26` = bit1|bit2|bit5):

| bit | 의미 | getter 썽크 VA |
|---:|---|---|
| 1 | `bloom` | `0x14019b6e0` |
| 2 | `camerafade` | `0x14019c1a0` |
| 3 | **정사영 활성**(explicit w/h) | `0x140187602` 에서 소비 |
| 4 | **정사영 auto** | `0x140189d8f` 에서 소비 |
| 5 | `clearenabled` | `0x14019bb20` |
| 7 | `camerashake` | `0x14019c830` |
| 8 | `cameraparallax` | `0x14019ca60` |
| 10 | `hdr` | `0x14019b900` |
| 12 | `transparentsorting` | `0x14019c3d0` |
| 13 | `customsortorder` | `0x14019c600` |
| 14 | `fogdistance` | `0x14019bd50` |
| 15 | `fogheight` | `0x14019bf80` |
| 16 | `windenabled` **[2026-08-21 보강]** | `0x14019cc90` |
| 31 | 블룸 파이프라인 dirty(변경 콜백 `0x1401863e0` 이 셋) | — |

주의: **엔진 기본값 `bloom=true`** 다(비트1). 에디터가 전 씬에 `"bloom": false` 를 명시하기 때문에
코퍼스에서는 드러나지 않지만, `bloom` 키가 없는 씬은 WE 에서 블룸이 **켜진다**.

> **[2026-08-21 재확인]** 위 47키 전표를 등록 함수와 생성자에서 **독립으로 다시 뽑아** 대조했다
> (디스어셈 → 디스크립터 `+0x30/+0x34` 추출 → 생성자 스토어를 바이트 단위로 재구성 → 오프셋별 f32/i32 복원).
> 키 47개 · 타입 · 오프셋 · 기본값이 **전건 일치**했다. 위 표에서 이번에 고친 것은 `windenabled` 의
> 비트 번호(공란 → bit16)와 §2.1 의 두 항목(등록 헬퍼 2종 · 변경 콜백 배치)뿐이다.
> qword 스토어가 두 필드를 한 번에 까는 자리(`0x140186fbb` → `0x33c`=0.5 & `0x340`=0,
> `0x14018706e` → `0x39c`=5.0 & `0x3a0`=0, `0x1401870a1` → `0x3b4`=1.0 & `0x3b8`=0,
> `0x140187006` → `0x3e0`=1.0 & `0x3e4`=0, `0x14018702e` → `0x3f8`=0.707 & `0x3fc`=0)도 그대로 확인했다.

### 2.3 `orthogonalprojection` 파스 — `0x1401874ec`–`0x140187618`

```
o = general["orthogonalprojection"]
if (typeof(o) != object) → 아무것도 안 함(원근)
auto = o["auto"];  w = o["width"];  h = o["height"]
if (auto == true)             → flags |= 0x18            (0x140187565: bit3|bit4)
else if (w,h 가 정수형)        → scene[0x354]=(float)w, scene[0x358]=(float)h   (0x14018759e / 0x1401875c0)
                                 flags |= 8  if (w != 0 && h != 0)              (0x1401875df)
                                 flags &= ~8 else                                (0x1401875d5)
                                 renderState[0x84]=(int)w, [0x88]=(int)h        (0x1401875eb / 0x1401875fb)
```
`auto:true` 의 실제 크기 결정: `0x14018b2c0`–`0x14018b38f`. 씬 오브젝트를 순회해 **첫 번째
type==1 오브젝트의 `size`**(`obj+0x2f0/0x2f4`, `spec/engine/shape-quad.json` 의 `sizeIsProperty0x2F0`)를
정사영 크기(`scene+0x354/0x358`)와 렌더타깃 크기로 그대로 쓰고, 그 오브젝트를 `size*0.5` 로 센터링한다
(`0x14018b30c`–`0x14018b373`, 0.5 상수 `0x1404926c0`). **화면 크기가 아니라 레이어 크기에 맞춘다.**

### 2.4 `camera` 블록 파스 — `0x14018821c`–`0x140188543`

| 키 | 저장 | 파스 VA | 기본값 |
|---|---|---|---|
| `camera.eye` | `0x118/0x11c/0x120` | `0x14018821c` (저장 `0x1401882fe`) | (2,2,2) — `0x140186ded`·`0x140186df8`·`0x140186e03` |
| `camera.center` | `0x124/0x128/0x12c` | `0x140188323` (저장 `0x1401883f9`) | (0,0,0) — `0x140186e03`·`0x140186e0e` |
| `camera.up` | `0x130/0x134/0x138` | `0x14018841e` (저장 `0x1401884f3`) | (0,1,0) — `0x140186e15`·`0x140186e1c` |
| `camera.paths` | 배열 | `0x140188518` | — |

값은 `"x y z"` 공백구분 문자열을 `strtod`(`0x1402d06ac`) 로 3회 파싱한다.

**`camerapreview`(341씬 저작)는 wallpaper64.exe 에 문자열 자체가 없다** — 런타임 플레이어는 완전히 무시한다.
에디터 전용 키다. 같은 스캔에서 `lightconfig`(`0x14048e4e0`, 로더 `0x1401876a2`),
`norecompile`(`0x140187626`), `spritesheetrefreshsync`(`0x140187656`)는 파스된다.

---

## 3. 블룸 파이프라인

### 3.1 분기 게이트

```
블룸 체인 실행:  scene.flags bit1(bloom)  &&  씬 오브젝트 리스트 비어있지 않음
                 0x140180a51 (shr eax,1 / test al,1) · 0x140180a68 (list 비교) · 호출 0x140180ac5
LDR vs HDR:      renderer.flags[obj+0x128] bit13(0x2000)
                 0x140183618 (체인) · 0x14017f7cb (파라미터 피드) · 0x14017fb79 (머티리얼 로드)
```

### 3.2 렌더타깃 (할당 `0x14017f1b0`–`0x14017fa6f`)

**HDR 피라미드**(bit13 set) — 이름을 `"_rt_"`(`0x14048dfe8`) + `2<<i` + `"FrameBuffer"`(`0x14048dff0`)
로 동적 생성(`0x14017f3ae`–`0x14017f3d3`), 최대 8단(`0x14017f541` `cmp ebx,8`),
매 단계 `sar eax,1`(`0x14017f376`)로 반감, 0 이하가 되면 중단.
슬롯 `obj+0x30b8 + i*8`, 실제 생성된 단 수 `obj+0x310c`, 포맷 enum `0x1b`.
**레벨 0 = 1/2 해상도**(`_rt_2FrameBuffer`).

**LDR**(bit13 clear):

| RT | 슬롯 | 스케일 | 포맷 | 생성 VA |
|---|---|---|---|---|
| `_rt_FullFrameBuffer` | `0x3098` | 1 | `0x16`(LDR)/`0x1a`(HDR) — `lea eax,[rax*4+0x16]` @`0x14017f591` | `0x14017f59c` |
| `_rt_4FrameBuffer` | `0x30a0` | 4 | `0x1b` | `0x14017f5c6` |
| `_rt_8FrameBuffer` | `0x30a8` | 8 | `0x1b` | `0x14017f62a` |
| `_rt_Bloom` | `0x30b0` | 8 | `0x1b` | `0x14017f66e` |

### 3.3 머티리얼 슬롯 (로드 `0x14017fb30`–`0x14017fc44`)

| 슬롯 | 머티리얼 | 조건 |
|---|---|---|
| `0x3150` | `combine_ldr` / `combine_hdr_upsample` / `combine_dhdr_upsample` | HDR bit13 / +bit14 (`0x14017fb49`·`0x14017fb5c`) |
| `0x3158` | `combine_srgb` / `combine_video_hdr` | HDR, bit16 이면 후자 (`0x14017fb88`·`0x14017fb94`) |
| `0x3190` | `hdr_downsample_bloom` (BLOOM=1) | HDR (`0x14017fbba`) |
| `0x3198` | `hdr_downsample` | HDR (`0x14017fba4`) |
| `0x31a0` | `hdr_upsample` (UPSAMPLE=1, additive) | HDR (`0x14017fbd0`) |
| `0x31a8` | `hdr_upsample_cubic` (UPSAMPLE=1,BICUBIC=1) | HDR (`0x14017fbe6`) |
| `0x3160` | `downsample_quarter_bloom` | LDR (`0x14017fc05`) |
| `0x3170` | `downsample_eighth_blur_v` | LDR (`0x14017fc11`) |
| `0x3178` | `blur_h_bloom` | LDR (`0x14017fc27`) |

### 3.4 LDR 3패스 (드로우 `0x140183949`–`0x140183a21`)

```
_rt_FullFrameBuffer --downsample_quarter_bloom--> _rt_4FrameBuffer (1/4)
_rt_4FrameBuffer    --downsample_eighth_blur_v--> _rt_8FrameBuffer (1/8)   [X축 13탭]
_rt_8FrameBuffer    --blur_h_bloom------------->  _rt_Bloom        (1/8)   [Y축 13탭]
_rt_FullFrameBuffer + _rt_Bloom --combine_ldr--> 현재 타깃
```

**축 이름이 뒤집혀 있다**: `downsample_eighth_blur_v` 가 X, `blur_h_bloom` 이 Y다
(`downsample_eighth_blur_v.vert:12` `localTexel = g_TexelSize.x*8.0`,
`blur_h_bloom.vert:12` `localTexel = g_TexelSize.y*8.0`).

추출 수식 (`downsample_quarter_bloom.frag:11-25`):
```
albedo = 0.25 * Σ 4탭(a_TexCoord ± g_TexelSize)      // ±1 풀해상도 텍셀
scale  = max(albedo.x, albedo.y, albedo.z)
albedo *= saturate(scale - g_BloomThreshold)          // 하드 임계(소프트니 아님)
gray   = dot(vec3(0.2989, 0.5870, 0.1140), albedo)
albedo = -gray*sat + albedo*(1+sat),  sat = 1.0       // = 2*albedo - gray (채도 2배)
out    = max(0, albedo * g_BloomStrength * g_BloomTint)
```
13탭 가우시안 가중(`blur_h_bloom.frag:7-19`): `0.006299 0.017298 0.039533 0.075189 0.119007
0.156756 0.171834 0.156756 0.119007 0.075189 0.039533 0.017298 0.006299`.

파라미터 피드(`0x14017f994`–`0x14017fa3f`): `bloomstrength`←`scene[0x3bc]` 생값(`0x14017f9b0`),
`bloomthreshold`←`scene[0x3c0]` 생값(`0x14017f9f7`), `bloomtint`←`scene[0x3d8..0x3e0]`(`0x14017fa28`).
**LDR 경로에는 정규화가 없다.**

### 3.5 HDR 듀얼필터 피라미드 (드로우 `0x140183610`–`0x140183948`)

```
i=0 : _rt_FullFrameBuffer --hdr_downsample_bloom--> level[0] (1/2)   (0x1401836e2)
i≥1 : level[i-1]          --hdr_downsample------->  level[i]         (0x1401837b0)
up  : level[i]            --hdr_upsample(_cubic)-->  level[i-1], additive  (0x1401838b1)
fin : _rt_FullFrameBuffer + level[0] --combine_hdr--> 타깃            (0x140180b45)
```
- 레벨 수 `N` = `min(bloomhdriterations, 생성된 단 수)`, 하한 1 (`0x14017f815`–`0x14017f84c`, `obj+0x3108`)
  - **생성된 단 수**(`obj+0x310c`)는 **`min(W,H)`** 를 계속 반으로 나눠 0 이 되기 전까지의 횟수다
    (`cmovg r14d,r12d` `0x14017f363` 로 min → `sar eax,1` `0x14017f376` → `jle` `0x14017f37d`
    → `inc [rsi+0x310c]` `0x14017f383`), 루프 상한은 `cmp ebx,8` `0x14017f541`.
    즉 `min(8, floor(log2(min(W,H))))` 다 — **max 가 아니라 min** 이다(§7 W-25).
    진입 전에 두 변이 `max(·,2)` 로 클램프된다(`cmovg r15d,edx` `0x14017f1ec` ·
    `cmovg r12d,r8d` `0x14017f200`) — 그래서 1×N 소스도 최소 1단은 나온다.
    **[2026-08-21] Waple 이 같은 산식이 됐다** — `WapleCore/HDRBloomMath.swift:66-75`
- **업샘플 큐빅 선택**: `ebp >= N-2` 이면 `hdr_upsample_cubic`, 아니면 `hdr_upsample`
  (`0x140183810`–`0x140183822`) — 즉 **가장 깊은 두 단만 bicubic**
- 가우시안 패스 없음. 전 단계가 4탭 박스다.

#### 탭 반경 — `g_RenderVar0` (오브젝트 `+0xb8..+0xc4`)

기본값 `(1/W, 1/H, -1/W, -1/H)`, `W=obj+0x84`, `H=obj+0x88` = **풀 프레임버퍼 크기**
(`0x14018367c`·`0x140183690`·`0x140183694`·`0x140183699` → 저장 `0x1401836a0`–`0x1401836ba`).

| 패스 | 스케일 | 코드 VA | 결과 오프셋 | **소스 텍셀 기준** | **목적지 텍셀 기준** |
|---|---|---|---|---|---|
| 추출(i=0) | ×1 (기본값 그대로) | `0x1401836a0` | `1/W` | **±1.0** | ±0.5 |
| 다운샘플 i | `1 << i` | `0x14018374a`–`0x14018375c` | `2^i/W` | **±1.0** | ±0.5 |
| 업샘플 i→i-1 | `2 << (i-1)` | `0x140183856`–`0x14018386b` | `2^i/W` | ±0.5 | ±1.0 |
| 합성 | `g_TexelSize`(별개 유니폼) | — | `1/W` | ±0.5(블룸텍스처) | ±1.0 |

`hdr_downsample.frag` BICUBIC 분기의 `texSize = 0.5 / g_RenderVar0.xy`(:22)가 소스 크기를 복원한다는
항등식은 **업샘플에서만** 성립한다(BICUBIC 은 `hdr_upsample_cubic` 에서만 컴파일된다).
다운샘플에 그 관계를 일반화하면 탭 반경이 **정확히 절반**이 된다 — §7 W-1.

기하학적 의미: 선형 샘플러에서 ±1 소스 텍셀 4탭은 소스 **4×4 박스**를 균등 평균하고,
±0.5 소스 텍셀 4탭은 소스 **2×2 박스**만 평균한다.

#### soft-knee 임계 곡선 (`hdr_downsample.frag:83-92`)

```
brightness   = max(albedo.r, albedo.g, albedo.b)
soft         = clamp(brightness - P.y, 0, P.z);  soft = soft*soft*P.w
contribution = max(soft, brightness - P.x) / max(brightness, 1e-5)
albedo      *= contribution * g_BloomStrength * g_BloomTint
```
엔진이 채우는 `P = g_BloomBlendParams`(머티리얼 키 `"blend"`, 4성분) — `0x14017f8bc`–`0x14017f906`:

| 성분 | 식 | VA | 상수 VA |
|---|---|---|---|
| `K`(knee) | `bloomhdrthreshold * bloomhdrfeather` | `0x14017f8cd` | — |
| `P.x` | `bloomhdrthreshold` | `0x14017f8c7` | — |
| `P.y` | `threshold - K` | `0x14017f8d5`·`0x14017f8d9` | — |
| `P.z` | `2*K` | `0x14017f8e2`·`0x14017f8ee` | — |
| `P.w` | `0.25 / (K + 1e-5)` | `0x14017f8f4`·`0x14017f8fc`·`0x14017f900` | `0.25`=`0x14049268c`, `1e-5`=`0x1404925ec` |

기본값(T=1.0, F=0.1)이면 `K=0.1`, `P=(1.0, 0.9, 0.2, 2.4998)`.

#### 강도 정규화 (`0x14017f7f7`–`0x14017f89b`)

```
N     = min(bloomhdriterations, 생성단수)        ; obj+0x3108 에 저장 (0x14017f82d / 0x14017f841)
k     = max(N,2) - 2                              ; 0x140f847 cmp/0x14017f851 add -2
denom = powf(bloomhdrscatter, k) + 1.0            ; powf=0x14041e350, +1.0 상수 0x140492704
g_BloomStrength = bloomhdrstrength / denom        ; divss 0x14017f88f
setMaterialParam(hdr_downsample_bloom, "bloomstrength", {strength, scatter}, count=2)   ; 0x14017f89b
setMaterialParam(hdr_upsample,        "scatter", bloomhdrscatter, 1)                     ; 0x14017f967
setMaterialParam(hdr_upsample_cubic,  "scatter", bloomhdrscatter, 1)                     ; 0x14017f988
```
`scatter` 는 **가공 없이** 그대로 실린다(`movss xmm6,[rbx+0x3d0]` @`0x14017f807`; 중간의
`movaps xmm0,xmm6` @`0x14017f854` 는 powf 입력이라 xmm6 를 바꾸지 않는다).
업샘플이 레벨마다 `×0.25×scatter` 로 곱해 누적하는 발산을, 추출 강도의 나눗셈이 상쇄하는 **한 쌍**이다.

기본값(scatter 1.619)의 실효 강도:

| N | k | denom | 실효 g_BloomStrength (저작 2.0 기준) |
|---:|---:|---:|---:|
| 1 | 0 | 2.000 | 1.0000 |
| 2 | 0 | 2.000 | 1.0000 |
| 3 | 1 | 2.619 | 0.7637 |
| 8 | 6 | **19.0086** | **0.10522** |

### 3.6 합성

```glsl
// combine_hdr.frag:20-25, 43   (combine_hdr_upsample.json = 콤보 없음)
bloom1 = 0.25 * Σ 4탭(v_TexCoord ± g_TexelSize)          // ±1 풀해상도 텍셀
albedo += bloom1
gl_FragColor = vec4(saturate(lin(albedo)) * g_RenderVar0.x, 1.0)
```
```glsl
// combine.frag:10-15  (combine_ldr.json)  — LDR 은 단일 탭, lin() 없음
gl_FragColor = vec4(texSample(tex0) + texSample(tex1), 1.0)
```
합성 패스용 `g_RenderVar0` 의 출처(정본 `uniform-feed.json` 이 미해결로 남긴 항목)를 이번에 특정했다:
**HDR 일 때만** 합성 직전에 디바이스 vtable 슬롯 `+0x158` 을 `&obj[0xb8]` 를 out-파라미터로 호출한다
(`0x140180b15`–`0x140180b26`, 게이트 `0x140180b10` `test r13b,r13b`). 즉 피라미드가 남긴 텍셀 잔값이
아니라 **디스플레이 질의 결과**가 실린다 — `combine_hdr.frag:31` 의 `DISPLAYHDR` 분기가
`g_RenderVar0.y * smoothstep(1,5,luma) + g_RenderVar0.x` 로 쓰는 (SDR 화이트, HDR 부스트) 쌍과 정합한다.
같은 자리에서 `level[0]` SRV 를 combine 머티리얼의 `g_Texture1` 슬롯(`mat+0xd8`)에 직접 꽂는다
(`0x140180b2c`–`0x140180b3e`). *(등급: 유력 — vtable 슬롯의 이름은 확인하지 못했다.)*

---

## 4. 톤매핑 — **없다**

`assets/shaders/` 전량에 Reinhard / ACES / Uncharted2 / filmic 형태의 곡선이 없다.
최종 합성이 적용하는 전부는:

| 경로 | 최종 픽셀 연산 | 출처 |
|---|---|---|
| LDR + bloom | `scene + bloom` (클램프는 UNORM 타깃이 함) | `combine.frag:13-15` |
| LDR, bloom off | 패스 자체가 없다(씬이 이미 타깃에 있다) | `render-pass.json` 7.1 |
| HDR + bloom | `saturate(lin(scene + bloom4tap)) * g_RenderVar0.x` | `combine_hdr.frag:37,43` |
| HDR, bloom off | `lin(scene)` | `passthroughsrgb.frag:15-17` |
| HDR + DISPLAYHDR | `lin(saturate(scene)+bloom) * (g_RenderVar0.y*smoothstep(1,5,luma) + g_RenderVar0.x)` | `combine_hdr.frag:27-32` |
| 에디터 | `srgb(saturate(albedo))` — **역방향**(linear→sRGB) | `combine_hdr_editor.frag:18` |
| 비디오 HDR | `saturate(rgb / (2*g_HDRParams.y)) * (2*g_HDRParams.y)` | `combine_video_hdr.frag:10-13` |

`lin()`(`combine_hdr.frag:12-16`)은 정석 sRGB→선형 변환:
`c = step(0.04045, v)`, `c*pow((v+0.055)/1.055, 2.4) + (1-c)*(v/12.92)`.
즉 **HDR 경로에만 감마 변환이 하나 붙고 그 외에는 곡선이 전혀 없다.**
`ccsimple`(밝기/대비/채도/색상 + 3D LUT)은 블룸 **뒤**에 오는 별개 패스이며
씬 키가 아니라 프로젝트 색보정 설정이다(정본 `render-pass.json`: `ccsimpleAfterBloom`).

---

## 5. 카메라 / 투영

### 5.1 실효 fov 선택 — `0x140189278`–`0x1401892c4`

```
eax = 0x144                      ; perspectiveoverridefov
edx = 0x140                      ; fov
test r9b, 8                      ; r9d = scene.flags[0xe0], bit3 = 정사영 활성
cmove eax, edx                   ; bit3 == 0(=3D 원근) 이면 fov, bit3 == 1(=2D 정사영) 이면 override
scene[0x148] = scene[eax]
```
**2D(정사영) 씬은 `perspectiveoverridefov`(기본 95°), 3D 씬은 `fov`(기본 50°)가 실효 fov 다.**
2D 에서의 실효 fov 는 `perspective:true` 레이어와 카메라 패럴랙스가 쓰는 원근 각이다.

### 5.2 클램프 — `0x140189b1a`–`0x140189b4c`

```
fov = min(fov, 179.9)    ; 상수 0x140492900
fov = max(0.1,  fov)     ; 상수 0x140492654  (comiss 0x140189b3a / movaps 0x140189b3f)
scene[0x148] = fov       ; 0x140189b4c
```

### 5.3 투영 행렬 — `0x140183a70`–`0x140184016`

분기: `test byte [scene+0xe0], 8` @ `0x140183aa2`.

**정사영(bit3 = 1)** — `0x140183ab8`–`0x140183eda`
- 프러스텀 폭/높이 = `scene[0x354]`/`scene[0x358]`(정사영 width/height)에서 뷰포트 피팅 여백을 뺀 값
  (`0x140183e1b`·`0x140183e71`), 피팅 모드는 `obj[0x124]`(4분기, `0x140183b47`–`0x140183b65`)
- **near = -2000.0, far = +2000.0 하드코딩** (`0x140183df9`/`0x140183e01`, `0x140183e38`/`0x140183e40`;
  상수 `0x14049294c`=2000.0, `0x140492a1c`=-2000.0). `nearz`/`farz` 를 **읽지 않는다**.
  카메라 상태에도 2000.0 이 직접 기록된다(`0x140189df0`, imm `0x44fa0000`).

  > **[2026-08-21 보강 — "하드코딩" 의 정확한 모양]** 코드는 상수를 무조건 싣는 게 아니라
  > `eax = scene[0xe0] & 8` 을 다시 뽑아(`0x140183dee`) `test eax,eax` 로 한 번 더 갈린다
  > (`0x140183df7` / `0x140183e36`). set 이면 ±2000, clear 면 `scene[0x14c]`/`scene[0x150]`
  > (`0x140183e0b` / `0x140183e4a`)를 읽는다. 그런데 이 블록 자체가 진입 분기
  > `test byte [rdi+0xe0], 8` @`0x140183aa2` 의 **비-je 쪽**(= bit3 set)이라 그 재검사는 항상 참이다 —
  > 즉 `nearz`/`farz` 를 읽는 두 팔은 정사영 경로에서 **도달 불가능**하다.
  > 결론(±2000 고정, `nearz`/`farz` 무시)은 그대로지만, 디스어셈에 `[rdi+0x14c]` 로드가 보인다고
  > "ortho 도 nearz 를 읽는다" 로 뒤집으면 안 된다.
  > 안쪽 ±2000 두 쌍(`0x140183df9` / `0x140183e38`)을 가르는 것은 `esi = [rcx+0x128] & 0x800`
  > (`0x140183a92`·`0x140183a9c`, 렌더러 플래그 bit11)이고 **양쪽 다 ±2000** 이다 — 레지스터 배치만 다르다.
- 카메라 fovRad = `scene[0x148] * π/180` (`0x140183dc9`·`0x140183dd1`, 상수 `0x140492628`)

**원근(bit3 = 0)** — `0x140183edf`–`0x140183f78`
- aspect = `renderTarget.w / renderTarget.h` (`0x140183ee9`)
- near = `scene[0x14c]`(nearz), far = `scene[0x150]`(farz) (`0x140183f20`·`0x140183f28`)
- fovY = `scene[0x148] * π/180` (`0x140183f30`·`0x140183f38`) → **fov 단위는 도(degree)**
- 행렬 빌더 = 디바이스 vtable `+0x10` (`0x140183f50`)

**결론: `nearz`/`farz` 는 3D 원근 씬(코퍼스 8개)에서만 살아 있다.** 2D 씬 188개가 저작한
`nearz 0.01` / `farz 10000` 은 전부 무시된다.

---

## 6. 그 외 후처리 축

### 6.1 clear

```
ecx = scene.flags[0xe0]; shr ecx,5; test cl,1      ; 0x140183588–0x140183591
if set → device_vtbl[0x120](ctx, 1, 1)             ; 0x1401835a7  (게이트=clearenabled 는 확정,
                                                   ;  vtable 슬롯이 clear 라는 것은 유력)
```
클리어 색은 `scene+0x35c/0x360/0x364`(clearcolor)를 프레임 함수가 스테이징한다(`0x14017fc7e`–`0x14017fc9a`);
`obj[0x124]` 가 특정 모드일 땐 `obj+0x31b0/0x31b4/0x31b8` 의 오버라이드를 쓴다(`0x14017fc58`–`0x14017fc75`).
`clearenabled:false` = 이전 프레임 잔상 누적(의도된 동작).

### 6.2 fog — 파라미터 패킹 확정 (`0x140186440`–`0x14018655a`)

씬 값 → 렌더 상태(`scene[0xd8]`) 복사:

| 렌더상태 오프셋 | 값 | VA |
|---|---|---|
| `+0x12b0` | `fogdistancecolor`(vec3) | `0x14018644a`–`0x140186460` |
| `+0x12bc` | `fogheightcolor`(vec3) | `0x14018646d`–`0x140186483` |
| `+0x12c8` | `fogdistancestart` | `0x140186490` |
| `+0x12cc` | `fogdistanceend − fogdistancestart` | `0x14018649c`–`0x1401864b3` |
| `+0x12d0` | `fogdistancestartdensity` | `0x1401864c2` |
| `+0x12d4` | `fogdistanceenddensity − fogdistancestartdensity` | `0x1401864cf`–`0x1401864e8` |
| `+0x12d8` | `fogheightstart` | `0x1401864f7` |
| `+0x12dc` | `fogheightend − fogheightstart` | `0x140186504`–`0x14018651d` |
| `+0x12e0` | `fogheightstartdensity` | `0x14018652c` |
| `+0x12e4` | `fogheightenddensity − fogheightstartdensity` | `0x140186539`–`0x140186552` |

→ `g_FogDistanceParams = (start, end−start, startDensity, endDensity−startDensity)`.
`common_fog.h:16,33` 의 `(d − P.x)/P.y` · `mix(color, fogColor, P.z + P.w*f*f)` 와 정합한다.
**엔진은 `end == start` 를 방어하지 않는다**(0 나눗셈 → ±inf → saturate).

같은 방식으로 `ambientcolor` → 렌더상태 `+0x1298`, `skylightcolor` → `+0x12a4`
(`0x1401863f0`–`0x14018643a`). 둘 다 기본 (0,0,0) — **흰색이 아니다**.

### 6.3 볼류메트릭 (WE 5패스)

씬 키가 아니라 3D 라이트 속성(`volumetricsexponent` 등, 코퍼스 2씬)이 켠다.

```
volumetrics_back      (volumetricsback,  cull normal, blend normal)   → _rt_volumetricsBack
volumetrics_front     (volumetricsfront, cull normal, blend additive) → _rt_volumetricsLightBuffer
  또는 volumetrics_fullscreen (FULLSCREEN=1, nocull)
volumetrics_blur_h    (blur_k3, VERTICAL=0) → _rt_volumetricsLightBufferB
volumetrics_blur_v    (blur_k3, VERTICAL=1) → 되돌림
volumetrics_combine   (passthrough, additive) → 화면
```
핵심 상수(`volumetricsfront.frag`):
- 레이마치 샘플 수 — SHADOW/COOKIE 있으면 QUALITY 4/3/2/그외 = `64/32/24/12`(:78-86),
  없으면 `8/5/3/2`(:88-96)
- `radiusFalloff = pow(saturate(1 − |lightDelta|/radius), VAR_EXPONENT)` (:132)
- spot: `smoothstep(outer, inner, dot(normalize(lightDelta), forward))` (:140)
- 점광원 스케일 보정 `× 0.5` (:119)
- 디더링 `worldStart += worldStep * hash12(screenUV)` — SHADOW 일 때만 (:125)
- 최종 `gl_FragColor.rgb = VAR_DENSITY * maxLightScale * shadowFactor * VAR_COLOR * 0.1` (:190)
- `blur_k3` = `blur3` = `[0.25, 0.5, 0.25]`, 스트라이드 = `1/g_Texture0Resolution.xy`
  (`common_blur.h:25-30`, `blur_k3.vert:27`)

---

## 7. Waple 대조 — 어긋난 숫자

`spec/engine/uniform-feed.json` 의 `wapleGaps` 중 `hdrBloomStrengthNormalization` 은 **이미 해소됐다**
(`HDRBloomPyramidPass.swift:255-256` 호출 → `WapleCore/HDRBloomMath.swift:95-98`) — 그 정본 항목이 낡았었다. **[2026-08-21] `해소` 키를 추가해 정정했다**(옛 키는 묘비 규약으로 남겼다).
아래는 재측정으로 남은 것만이다.

> **[2026-08-21] 파스 기본값 7건 반영, 1건 고의 보류.** `SceneDocument.swift` 의 `general` 파스
> 기본값을 §2.2 전표에 맞췄다 — **반영: W-3 · W-5 · W-7(값만) · W-10 · W-11 · W-12 · W-13**,
> **보류: W-4**(`bloom` — 사유는 해당 행).
> 동봉 172씬 중 **실제로 화면이 달라지는 것은 W-5 의 1씬**(`scenes/particleeditor3dscale`)뿐이고
> 나머지는 전부 0건이다(해당 씬들이 키를 명시 저작하거나, 생략해도 그 값을 쓰는 분기가 꺼져 있다).
> 나머지 여섯의 실효 무대는 키를 생략하는 워크샵 씬이다. 회귀 고정:
> `Tests/WapleCoreTests/SceneGeneralDefaultsWEParityTests.swift`(기본값 전수 + 동봉 코퍼스 생략 인구조사).
>
> **fog 기본값(W-14)과 정사영 z 클립(W-6)은 이번 반영에서 빠졌다** — 둘 다 코드가 `Sources/WapleRender/`
> (`Scene3DLighting.swift` · `SceneRendererFrameEncoder.swift`)에 있어 이번 레인의 담당 파일이 아니다.

| # | 항목 | WE (VA/셰이더:행) | Waple (파일:행) | 등급 | 고치면 화면이 |
|---|---|---|---|---|---|
| **W-1** | HDR 피라미드 **추출·다운샘플 탭 반경** | `g_RenderVar0 = 2^i/W` = **±1 소스 텍셀**(`0x1401836a0`, `0x14018374a`–`0x14018375c`) → 4×4 박스 | ~~`0.5 / src.get_width()` = ±0.5 소스 텍셀~~ → **해소(`b19db5b`)**. 되짚기를 없애고 호스트가 `tapOffsetUV(scale:baseWidth:baseHeight)` 로 계산한 `t` 를 유니폼으로 싣는다 (`WapleCore/HDRBloomMath.swift:117-129` · `HDRBloomPyramidPass.swift:344-350`) | **확정 · 해소** | 글로우 반경이 단계마다 2배로 넓어지고 이동 하이라이트의 계단/쉬머가 사라진다 |
| **W-2** | HDR 업샘플 **BICUBIC** | 가장 깊은 두 단(`ebp >= N−2`)은 `hdr_upsample_cubic` (`0x140183810`–`0x140183822`) | ~~전 단계 bilinear 4탭~~ → **해소(`b19db5b`)**. `upsampleUsesBicubic(sourceLevel:levelCount:)` 이 단마다 파이프라인을 고르고 `weBicubic` 이 `hdr_downsample.frag:8-51` 축자 이식이다 (`WapleCore/HDRBloomMath.swift:141-143` · `HDRBloomPyramidPass.swift:447-459`) | **확정 · 해소** | 저해상도 단의 업스케일 블록 아티팩트가 사라져 넓은 헤일로가 매끈해진다 |
| **W-3** | `bloomhdrstrength` 기본값 | **2.0** (`0x1401870c2`) | ~~`?? 0`~~ → **`?? 2` 반영(2026-08-21)**. 패스 기본은 아직 0 (`HDRBloomPass.swift:15`, `HDRBloomPyramidPass.swift:40` — 렌더 레인 잔여) | **확정 · 파스 해소** | 키를 생략한 HDR 씬에서 블룸이 나타난다(현재는 완전히 안 보임). **동봉 172씬 영향 0건** — 84씬이 키를 생략하지만 `hdr && bloom` 인 씬은 previewthunderbolt 1건뿐이고 그 씬은 2.0 을 명시 저작한다 |
| **W-4** | `bloom` 기본값 | **true**(flags bit1, `0x140186d1f` `qword=0x26`) | `?? false` — **[2026-08-21] 확인했으나 의도적 미반영** | **확정 · 고의 이탈** | `bloom` 키 없는 씬에 블룸이 켜진다. **동봉 172씬 영향 0건**(전건 명시 저작)이라 실사용 이득이 없는데, `sceneWantsLDRBloom = doc.bloom && !doc.hdr` 를 타고 **키를 생략한 합성 렌더 픽스처 60여 개**의 합성 결과가 한꺼번에 바뀐다(`Tests/WapleRenderTests` 66파일 중 `bloom` 을 저작하는 것은 3파일뿐). 필요한 변경은 `SceneDocument.bloom` 선언 1줄 + 파스 `?? false` 1줄이고, **렌더 픽스처를 같이 갱신할 수 있는 레인에서 한 커밋으로** 뒤집어야 한다 |
| **W-5** | `nearz` 기본값 | **0.1** (`0x140186d7d`) | ~~`?? 0.01`~~ → **`?? 0.1` 반영(2026-08-21)** | **확정 · 해소** | 3D 원근 씬의 깊이 정밀도가 10배 올라 z-fighting 이 준다(대신 카메라 0.1 이내가 잘린다 — WE 와 동일 동작). 2D 는 무영향(§5.3). **동봉 172씬 영향 1건** — 3D 씬 2개 중 `particleeditor3dscale` 만 키를 생략한다(`modeleditor` 는 0.1 명시) |
| **W-6** | 정사영 씬의 z 클립 범위 | **하드코딩 ±2000**(`0x140183df9`/`0x140183e01`, 카메라 상태에도 `0x140189df0` imm `0x44fa0000`) — `nearz/farz` 무시 | `let F: Float = 10000` 대칭 클립 (`SceneRendererFrameEncoder.swift:923`, 주석은 *"WE ortho 기본 farz"* 라고 적었으나 WE 는 ortho 에서 `farz` 를 읽지 않는다 — **수정 시 상수와 함께 그 주석도 지워야 한다**; 도달 불가능한 `nearz`/`farz` 팔의 정체는 §5.3 의 2026-08-21 보강 참조) | **확정** — 렌더 레인 잔여 | ortho 3D 하이브리드의 깊이 버퍼 정밀도가 5배 올라 동일 z 메시의 z-fighting 이 줄고, \|z\|>2000 오브젝트의 클립 여부가 WE 와 같아진다 |
| **W-7** | 2D 실효 fov | 정사영이면 `perspectiveoverridefov`(기본 95°) (`0x140189278`–`0x1401892c4`) | 파스는 **`Float? = nil` → `Float = 95` 로 반영(2026-08-21)**. 렌더는 여전히 **리터럴 95 하드코딩** (`SceneRendererFrameEncoder.swift:596,1281`) — 렌더 레인 잔여 | **확정 · 파스 절반 해소** | 기본값 씬은 우연히 맞지만 `90.76` 을 저작한 씬(**동봉 6씬** · 전 코퍼스 12씬)의 `perspective:true` 레이어 원근 왜곡이 WE 와 일치한다. 렌더가 `doc.perspectiveOverrideFov` 를 읽기만 하면 끝난다(기본값이 이제 95 라 무저작 씬은 비트동일) |
| **W-8** | fov 클램프 | `[0.1, 179.9]` (`0x140189b1a`, `0x140189b3a`) | 클램프 없음 | **확정** — **[2026-08-21 정정] 고칠 자리가 파스가 아니다.** WE 의 클램프는 `Scene::updateCamera` 가 **매 프레임** 실효 fov(`scene+0x148`)에 거는 것이고(§5.1–5.2 와 같은 함수), 저작값 파스 지점이 아니다. 종전 표가 지목한 파스 지점(`SceneDocument.swift` 의 `let fov = float(general["fov"]) ?? 50`)에 클램프를 넣으면 **정적 값만** 막히고 스크립트/애니메이션이 프레임마다 미는 fov 는 그대로 통과한다 — 즉 반쪽 수정이다. 소비처(렌더러 카메라 갱신)에서 걸어야 한다 | 스크립트가 fov 를 0/음수/180+ 로 몰 때 화면이 뒤집히거나 검게 되지 않는다 |
| **W-9** | `orthogonalprojection.auto` | 첫 type==1 오브젝트의 `size` 로 투영/RT 크기 결정 (`0x14018b30c`–`0x14018b373`) | `width ?? 1920`, `height ?? 1080` (`SceneDocument.swift:1099-1100`) | **유력** | `auto:true` 4씬(파티클 프리뷰류)의 캔버스 비율/스케일이 맞는다 |
| **W-10** | `cameraparallaxamount` 기본값 | **0.5** (`0x140186fa5`) | ~~`?? 1`~~ → **`?? 0.5` 반영(2026-08-21)** | **확정 · 해소** | 키 생략 씬의 패럴랙스 이동량이 절반으로 — 종전은 2배로 흔들렸다. **동봉 172씬 영향 0건**(생략 4씬은 `cameraparallax` 도 생략 = 비활성) |
| **W-11** | `cameraparallaxmouseinfluence` 기본값 | **0.5** (`0x140186fbb`, qword 스토어의 하위 dword) | ~~`?? 1`~~ → **`?? 0.5` 반영(2026-08-21)** | **확정 · 해소** | 마우스 추종이 절반으로 줄어 WE 와 같아진다. **동봉 172씬 영향 0건**(위와 같은 4씬) |
| **W-12** | `cameraparallaxdelay` 기본값 | **0.1** (`0x140186fb0`) | ~~`?? 0`(즉시)~~ → **`?? 0.1` 반영(2026-08-21)** | **확정 · 해소** | 패럴랙스가 즉시 스냅하지 않고 WE 처럼 살짝 따라온다. **동봉 172씬 영향 0건**(위와 같은 4씬) |
| **W-13** | `skylightcolor` 폴백 | `ambientcolor` 와 **독립**, 기본 (0,0,0) (`0x140186f76`; 등록도 별개 — `0x14019a26f`→`0x374` vs `0x14019a1c6`→`0x368`) | ~~`?? ambientColor`~~ → **`?? (0,0,0)` 반영(2026-08-21)** | **확정 · 해소** | `ambientcolor` 만 저작한 씬에서 하늘광이 검정이 되어 이중 가산이 사라진다. **동봉 172씬 영향 0건** — 생략 2씬(gifscene · videoplayer)은 `ambientcolor` 도 생략해 종전 폴백 결과도 (0,0,0) 이었다 |
| **W-14** | fog `start/end` 기본값 | dist `1.0/5.0`, height `1.0/−3.0` (`0x140187063`·`0x14018706e`·`0x140187084`·`0x14018708f`) | `start ?? 0`, `end ?? 1` (`Scene3DLighting.swift:611-612`) | **확정** | fog 를 켜고 거리 키를 생략한 씬의 램프가 WE 와 같아진다(코퍼스 0건 → 워크샵 전용) |
| **W-15** | fog 밀도 기본값 | `startDensity 0`, `endDensity 1.0` (`0x1401864c2`·`0x140187079`) | `0` / `1` (`Scene3DLighting.swift:613-614`) | **확정** | **일치** — 조치 불필요 |
| **W-16** | fog `end==start` 방어 | 없음(0 나눗셈 허용) | `span` 을 ±1e-4 로 클램프 (`Scene3DLighting.swift:616`) | **확정**(의도적 이탈) | 없음. 안전 이탈로 유지 권장 — 문서화만 필요 |
| **W-17** | 볼류메트릭 모델 | 깊이 기반 5패스 레이마치(백페이스 깊이 → 12~64샘플 → blur3 h/v → additive), `×0.1` 스케일 (`volumetricsfront.frag:78-96,190`) | 화면공간 원뿔 근사 1패스: `exp(-density*dist*0.001)` + `pow(intensity, exponent)`, 선형 콘 램프 (`VolumetricLightPass.swift:162,169,177`) | **확정**(구조 차이) | 샤프트가 지오메트리에 가려지고 그림자 결이 생긴다. 현재는 오브젝트를 통과해 비친다 |
| **W-18** | 볼류메트릭 콘 감쇠 | `smoothstep(outer, inner, cos)` (`volumetricsfront.frag:140`) | `clamp((cos−outer)/(inner−outer), 0, 1)` 선형 (`VolumetricLightPass.swift:162`) | **확정** | 스포트 가장자리가 부드러워진다 |
| **W-19** | 볼류메트릭 반경 감쇠 | `pow(saturate(1 − dist/radius), exponent)` (`volumetricsfront.frag:132`) | `exp(−density*dist*0.001)` (`VolumetricLightPass.swift:169`) | **확정** | 라이트 `radius` 밖에서 정확히 0 이 되어 무한 꼬리가 사라진다 |
| **W-20** | HDR 최종 `lin()` | `saturate(lin(albedo)) * g_RenderVar0.x` (`combine_hdr.frag:43`), bloom off 는 `lin()`만 (`passthroughsrgb.frag:15`) | `saturate(base+bloom)` — `lin()` 미이식 (`HDRBloomPyramidPass.swift:473`, `HDRPostPass.swift:70`) | **미확정** | §8 참조 |
| **W-21** | `g_RenderVar0.x` 출처 | 합성 직전 디바이스 vtable `+0x158` 질의 (`0x140180b15`–`0x140180b26`) | 없음(암묵 1.0) | **유력** | 값이 1.0 이 아니면 HDR 씬 전체 밝기 배수가 바뀐다 |
| **W-22** | `camerapreview` | 문자열 자체가 바이너리에 없음 = 미소비 | 미파스 | **확정** | **일치**(둘 다 무시) — 조치 불필요 |
| **W-23** | `transparentsorting`(bit12) · `customsortorder`(bit13) | 등록됨(`0x14019ad55`·`0x14019adfd`), 기본 false | **미파스**(`SceneDocument` 에 키가 없다) | **확정** — 2026-08-21 47키 전건 대조에서 나온 잔여 | 지금은 무영향(WE 쪽 소비 지점도 §8-4 로 미특정). 동봉 저작은 `transparentsorting:true` 2씬(둘 다 3D)뿐이라 소비처를 찾기 전엔 파스만 넣어도 화면이 안 바뀐다 |
| **W-24** | `fov`/`nearz`/`farz` 파스 시점 | `general` 의 독립 키 — `camera` 블록 유무와 무관하게 씬 필드(`0x140`/`0x14c`/`0x150`)에 항상 실린다 | `parseCamera` 안에서만 읽는다 — `orthogonalprojection` 이 딕셔너리면(=2D) `camera3D == nil` 이라 세 값이 **문서에 남지 않는다** | **확정**(구조 차이) | 지금은 무영향(2D 는 세 값을 안 쓴다 — §5.3). `zoom`·`perspectiveoverridefov` 처럼 2D 에서도 살아 있어야 할 키가 늘면 그때 `applyGeneralSettings` 로 옮겨야 한다 |
| **W-25** | HDR 피라미드 **레벨 수 산식** | 생성 단수 = `min(8, floor(log2(min(W,H))))` (`0x14017f363`·`0x14017f376`·`0x14017f37d`·`0x14017f383`·`0x14017f541`; 진입 전 두 변이 `max(·,2)` 로 클램프 `0x14017f1ec`·`0x14017f200`), 실효 `N = max(1, min(bloomhdriterations, 생성단수))` (`0x14017f7f7`–`0x14017f84c` → `obj+0x3108`) | ~~`w > 1 || h > 1` 로 도는 **max 기준**~~ → **해소(2026-08-21)**. `levelCount` 을 min 기준으로 다시 썼고 본체를 `WapleCore/HDRBloomMath.swift:66-75` 로 옮겼다(`HDRBloomPyramidPass.swift:176-179` 는 위임) | **확정 · 해소** | **풀스크린 화면 차이는 0**(짧은 변 ≥ 256 이면 양쪽 다 상한 8). 갈리는 것은 짧은 변 < 256 **이고 두 변의 2-거듭제곱 구간이 다른** 소스뿐이다 — 정사각 2의 거듭제곱(4×4·64×64)은 min=max 라 안 갈린다. **도달 실측: 이 리포의 골든 썸네일이 256×144**(`SnapshotPipeline.thumbW/thumbH`)라 `N` 이 8 → 7 로 바뀐다 — 정규화 분모가 19.01 → 12.12 라 HDR 블룸 씬 썸네일이 약 1.57배 밝아지고 **골든 재기준선이 필요하다**. 64×32 렌더 테스트는 6 → 5(`HDRBloomTests.swift` 의 두 기대치를 같이 고쳤다). 코퍼스 `bloomhdriterations` 는 157건 중 8 이 149건이라 요청 쪽이 먼저 캡을 만들지 않는다 |

> **W-1 이 어떻게 닫혔나(`b19db5b`).** 공용 헬퍼가 추출·다운샘플·업샘플 **세 곳을 겸하는 한**
> 반경을 분리할 수 없다 — 헬퍼의 `0.5` 를 `1.0` 으로 바꾸면 업샘플이 반대로 어긋난다. 그래서
> 상수를 고치는 대신 **되짚기 자체를 없앴다**: `weBox4(src, uv, t)` 가 `t` 를 유니폼으로 받고
> 호스트가 `downsampleTapScale(level:)` / `upsampleTapScale(sourceLevel:)` 로 계산한다.
>
> **[2026-08-21] 그 오진의 발원지는 정본이었다.** `spec/engine/hdr-bloom.json` 의
> `structure.renderVar0Meaning` 이 BICUBIC 전용 항등식 `texSize = 0.5 / g_RenderVar0.xy` 를
> "즉 4탭이 ±0.5 텍셀 코너에 놓인다" 로 **전 패스에 일반화**해 적어 두었고, 2026-08-02 교체가
> 그 문장을 그대로 따랐다. 그 줄과 `filterShapeDeviations.preSwap.W1` 을 정정했고
> `structure.tapRadiusBySlot` 에 슬롯별 반경을 실측으로 박아 두었다.

### 일치 확인(재측정으로 확인만 한 것)

| 항목 | 근거 |
|---|---|
| `g_BloomBlendParams` 소프트니 식·상수 | `0x14017f8bc`–`0x14017f906` ↔ `WapleCore/HDRBloomMath.swift:149-152` |
| HDR 강도 정규화 `s/(scatter^(max(N,2)−2)+1)` | `0x14017f851`–`0x14017f88f` ↔ `WapleCore/HDRBloomMath.swift:95-98` |
| 업샘플 가중 `0.25(4탭 평균) × 생 scatter` + 탭 ±0.5 소스텍셀 | `0x140183856`, `hdr_downsample.frag:61,78` ↔ `HDRBloomPyramidPass.swift:431-439` |
| 합성 4탭 ±1 풀텍셀 | `combine_hdr.frag:21-25` ↔ `HDRBloomPyramidPass.swift:463-474` |
| 피라미드 레벨 0 = 1/2 | `0x14017f376`, divisor `2<<i` ↔ `SceneRendererFinalizer.swift:50-51` |
| LDR 추출 4탭 ±1 풀텍셀 + 하드 임계 + 채도 2배 | `downsample_quarter_bloom.frag:11-25` ↔ `LDRBloomPass.swift:214-224` |
| LDR 13탭 가중·스트라이드(2 quarter텍셀 → 1 eighth텍셀) | `blur_h_bloom.frag:7-19`, `*.vert:12` ↔ `LDRBloomPass.swift:134,149,228-244` |
| LDR 블러 축 순서(X 먼저, Y 나중) | `downsample_eighth_blur_v.vert:12` / `blur_h_bloom.vert:12` ↔ `LDRBloomPass.swift:134,149` |
| `bloomstrength 2.0` / `bloomthreshold 0.65` / `bloomtint (1,1,1)` | `0x1401870ac`·`0x1401870b7`·`0x140186ff0` ↔ `LDRBloomPass.swift:10-13` |
| `bloomhdrthreshold 1.0` / `feather 0.1` / `scatter 1.619` / `iterations 8` | `0x1401870cd`·`0x1401870d8`·`0x1401870e3`·`0x1401870ee` ↔ `SceneDocument.swift:2918-2921` |
| `fov 50` / `farz 10000` 기본값 | `0x140186d5c` / `0x140186d88` ↔ `SceneDocument.swift:1527,1538` |
| `clearenabled` 기본 true | `0x140186d1f`(bit5) ↔ `SceneDocument.swift:2928` |
| `ambientcolor` 기본 (0,0,0) | `0x140186f6f` ↔ `SceneDocument.swift:1102` |
| fog 파라미터 패킹 `(s, e−s, sd, ed−sd)` | `0x140186489`–`0x140186552` ↔ `Scene3DLighting.swift:575-576,618` |
| 톤커브 부재(ACES/Reinhard 없음) | `assets/shaders/` 전수 ↔ `HDRPostPass.swift:67-70` |

> **[2026-08-21] HDR 블룸 산술이 이제 리눅스에서 실행된다.** 종전에는 전부
> `HDRBloomPyramidPass`(WapleRender)의 `static` 이라 `import Metal` 때문에 **리눅스에서 한 줄도
> 돌지 않았고**(`scripts/dev/linux-render-typecheck.sh` 는 타입만 본다), 유일한 그물이 macOS 전용
> `Tests/WapleRenderTests/HDRBloomTests.swift` 였다. 탭 반경(W-1)·레벨 수(W-25) 두 이탈이 정확히
> 그 공백에서 나왔다. 본체를 `Sources/WapleCore/HDRBloomMath.swift` 로 옮기고
> `Tests/WapleCoreTests/HDRBloomMathTests.swift` **17건**이 덮는다 — WE 루프를 독립 재구현한
> 오라클과 전수 대조(폭 612종 × 높이 27종 × 요청 13종)하고 돌연변이 7건을 심어 7건을 잡았다.
> `HDRBloomPyramidPass` 의 `static` 은 **위임만** 남아 호출부(`SceneRendererFinalizer`)와
> macOS 테스트는 그대로다.

---

## 8. 미해결

1. **W-20 — HDR 최종 `lin()` 이 상쇄 쌍인가.**
   `HDRPostPass.swift:9-10` 은 *"WE 는 sRGB-뷰 스왑체인이라 하드웨어 인코드와 상쇄되는 쌍"* 을 근거로
   `lin()` 을 뺐다. 그런데 `spec/engine/render-state.json`
   `backbuffer.noSRGBViewNoHDROutput`(확정)은 **RTV 가 sRGB 뷰가 아니다**라고 적고,
   같은 파일 `backbuffer.swapchainFormat` 은 `B8G8R8A8_UNORM` **추정 · notMeasured** 다.
   RTV 는 포맷 오버라이드를 안 할 뿐 스왑체인 포맷을 상속하므로, 스왑체인이 `_SRGB` 로 만들어졌다면
   Waple 의 전제가 맞고 아니면 WE 의 HDR 경로가 실제로 어두워진다. 두 정본 항목만으로는 안 갈린다.
   **닫는 법**: `IDXGIFactory::CreateSwapChain(vtbl+0x50)` / `CreateSwapChainForHwnd(vtbl+0x78)` 호출부에서
   `DXGI_SWAP_CHAIN_DESC.BufferDesc.Format` 즉시값을 읽으면 된다.
2. **W-21 — 디바이스 vtable `+0x158`** 의 정체. out-파라미터가 float4 이고 HDR 에서만 호출되며
   `combine_hdr.frag:31` 의 (`.x` = 기준 배수, `.y` = HDR 부스트) 해석과 맞지만, 함수 이름을 못 짚었다.
3. `bloomstrength` 를 머티리얼에 **count=2**(`{정규화강도, scatter}`)로 넘긴다
   (`0x14017f870` `mov r9d,2`; 두 성분 스토어 `0x14017f893` `[rbp+0x120]`=정규화강도 ·
   `0x14017f876` `[rbp+0x124]`=생 scatter).
   **[2026-08-21 좁힘]** *"미공개 콤보용인가"* 는 배제됐다 — 동봉 셰이더 전수에서
   `g_BloomStrength` 를 선언하는 곳은 `hdr_downsample.frag:55` 와
   `downsample_quarter_bloom.frag:6` 둘뿐이고 **둘 다 `float`** 다. 콤보로 타입이 바뀌는
   선언도 없다. 따라서 출하 셰이더 집합 안에 두 번째 성분의 소비처는 **없다**.
   남은 질문은 하나로 좁혀진다: **`setMaterialParam`(`0x14017e920`–`0x14017eadc`)의
   `count` 인자가 값의 바이트 폭인가(= 두 번째 성분이 vec4 슬롯에 같이 실리기만 하고
   셰이더가 `.x` 만 읽는 것인가), 아니면 별도 의미가 있는가.**
   `0x14017e920` 이 이름 해시 조회(`0x140421e00`)와 맵 삽입으로 시작하므로,
   그 함수 안에서 `r9d`(=count) 가 `memcpy` 폭으로 흐르는지만 따라가면 닫힌다.
   (어느 쪽이든 실효 화면 영향은 없다.)
4. `camerafade`(bit2, 195씬 저작) / `camerashake`(bit7) / `transparentsorting`(bit12) /
   `customsortorder`(bit13) 의 소비 지점을 못 찾았다. 코퍼스가 전건 기본값(shake/sorting=false,
   fade=true)이라 A/B 로도 안 드러난다.
5. `zoom`(`scene+0x154`, 181씬 전건 1.0) 소비 지점 미특정.
6. Waple `hdrActive = sceneIsHDR && accPixelFormat == .rgba16Float`
   (`SceneRenderer.swift:716,721-724`) 이므로 `quality` 가 low/medium 이면 `hdr:true` 씬에서
   HDR 블룸도 LDR 블룸도 돌지 않는다(`sceneWantsLDRBloom = doc.bloom && !doc.hdr`,
   `SceneRenderer.swift:1289`). `quality` 는 Waple 확장 키이고 코퍼스 358/358 이 미저작이라
   현재는 잠복이다.

---

## 부록 — 이 문서가 인용한 함수 범위

| 함수 | 범위 | 역할 |
|---|---|---|
| `Scene::registerProperties` | `0x140199780`–`0x14019b4d6` | `general` 47키 리플렉션 등록 |
| `Scene::Scene` | `0x140186c90`–`0x1401872ba` | 전 기본값 기록 |
| `Scene::loadJson` | `0x1401872ba`–`0x140188816` | `objects`/`camera`/`general`/`orthogonalprojection` 파스 |
| `Scene::updateCamera` | `0x1401891a0`–`0x140189e08` | 실효 fov 선택·클램프·패럴랙스·정사영 auto |
| `Composite::buildProjection` | `0x140183a70`–`0x140184016` | 정사영/원근 행렬 |
| `Composite::allocateTargets` | `0x14017f1b0`–`0x14017fa6f` | RT 할당 + 블룸 파라미터 피드 |
| `Composite::frame` | `0x14017fa70`–`0x1401816cc` | 머티리얼 로드 + 프레임 합성 순서 |
| `Composite::drawBloomChain` | `0x140183610`–`0x140183a61` | LDR 3패스 / HDR 피라미드 드로우 |
| `Composite::drawScene` | `0x140183550`–`0x140183609` | clear + 씬 렌더 + MSAA resolve |
| `Scene::pushFogToRenderState` | `0x140186440`–`0x14018655a` | fog 파라미터 패킹 |
| `Scene::pushAmbientToRenderState` | `0x1401863f0`–`0x14018643a` | ambient/skylight |
| `Scene::autoSizeOrtho` | `0x14018b2c0`–`0x14018b38f` | `orthogonalprojection.auto` |

부동소수 상수: `1.0`=`0x140492704` · `0.5`=`0x1404926c0` · `0.25`=`0x14049268c` ·
`1e-5`=`0x1404925ec` · `-1.0`=`0x1404929b8` · `4.0`=`0x14049284c` · `-0.99`=`0x1404929b0` ·
`0.1`=`0x140492654` · `179.9`=`0x140492900` · `2000.0`=`0x14049294c` · `-2000.0`=`0x140492a1c` ·
`π/180`=`0x140492628` · `180/π`=`0x1404928d0` · `432000.0`=`0x14049296c`.
