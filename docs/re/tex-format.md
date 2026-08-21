# `.tex` 컨테이너와 `.tex-json` — 동봉 전건 대조

**조사일 2026-08-21 · WE 2.8.42 `wallpaper64.exe` (md5 `438cb215f20a8f6c38f57fbc3d9da588`, imagebase `0x140000000`)**
**대상: 동봉 자산 `Sources/WapleRender/Resources/WEAssets/` — `.tex` 311개 · `.tex-json` 298개 전건**

## 0. 결론

| 항목 | 판정 |
| --- | --- |
| 동봉 `.tex` 311건 Waple 파스 | **311/311 성공.** 단 조사 시작 시점엔 28건(`materials/lut/*`)이 **컨테이너를 못 읽고** PNG 시그니처 스캔 폴백으로 흐르고 있었다 — 픽셀만 우연히 맞았다 |
| 원인 | `flags & 0x40`(slice3d)일 때 **헤더와 mip 레코드 양쪽에** i32 depth 가 추가되는 것을 파서가 몰랐다 |
| 조치 후 | 311/311 이 컨테이너를 실제로 읽는다. 참조 파서(엔진 레이아웃 그대로)와 **전 필드 일치**, 파스 끝이 **311/311 EOF 정확히 일치** |
| mip 페이로드 | 1,473 레벨 전건 LZ4 해제 성공, 해제 크기가 `(format, w, h, depth)` 예측치와 **전건 일치** |
| `.tex-json` | 런타임 의미가 있는 키는 **전부** 컴파일된 `.tex` 헤더로 들어온다(272쌍 전건 일치). Waple 이 못 읽는 자리는 **소스 폼(.tex 부재) 26건**뿐 |
| 알파 규약 | **straight(비프리멀티)** — fmt0 반투명 텍스처 108개 중 107개에 `RGB > A` 픽셀이 실재한다. Waple 규약과 일치 |
| 남은 디코더 갭 | BC3 알파 보간 라운딩 1건(±1). 색(565→8)은 이번에 맞췄다 |

---

## 1. 리더 전표 — 필드마다 VA

섹션 루프는 `0x14015e580` 이다. `TEXV0005` 를 `memcmp`(`0x14015e66e`) 로 확인한 뒤
NUL 종단 섹션 이름을 하나씩 읽어 앞 4글자로 분기하고, 뒤 4자리를 `atoi`(`0x14015e745`) 해
버전으로 넘긴다.

| 섹션 | 분기 | 리더 |
| --- | --- | --- |
| `TEXI` | `0x14015e75b` | `0x14015c760` |
| `TEXB` | `0x14015e792` | `0x14015c8d0` |
| `TEXS` | `0x14015e7e6` | `0x14015e1d0` |

`TEXV0004` 도 받는다(`0x14015e8c5`) — 그 경우 TEXI/TEXB 를 **버전 0** 으로 부른다
(`xor ecx, ecx` @`0x14015e8dc`·`0x14015e8f9`). 코퍼스엔 `TEXV0005` 뿐이라 Waple 은 0005 만 받는다.

### 1.1 `TEXI` 헤더 (`0x14015c760`)

| 오프셋 | 필드 | 읽는 VA | 조건 |
| --- | --- | --- | --- |
| 0 | `"TEXV0005"` + NUL | — | 항상 |
| 9 | `"TEXI000N"` + NUL | — | 항상 |
| 18 | i32 `format` | `0x14015c789` | 항상 |
| 22 | i32 `flags` | `0x14015c7b1` | 항상 — **대입이 아니라 `or`** |
| 26 | i32 `texWidth` | `0x14015c7da` | 항상 |
| 30 | i32 `texHeight` | `0x14015c803` | 항상 |
| 34 | i32 `imageWidth` | `0x14015c82c` | 항상 |
| 38 | i32 `imageHeight` | `0x14015c85a` | 항상 |
| 42 | i32 `texDepth` | 게이트 `0x14015c855` / 저장 `0x14015c885` | **`flags & 0x40`** |
| 42 또는 46 | u32 `previewColor` | 게이트 `0x14015c891` / 저장 `0x14015c8c1` | **TEXI 버전 ≥ 1** |

헤더 길이는 그래서 42 / 46 / 50 셋 중 하나다. 실물은 전부 `TEXI0001` 이라 최소 46 이다.

`flags` 를 `or` 로 합치는 것(`0x14015c7b1`)은 **엔진이 미리 세운 비트를 파일이 못 지운다**는 뜻이다.
실제로 로더는 파일을 다 읽은 뒤 mip 체인 길이가 2 미만이면 `flags |= 8` 을 스스로 세운다
(`0x14015e90a`–`0x14015e933`, `or dword ptr [rsi + 4], 8`). 동봉 311건 중 파일에 bit3 이 켜진 것은 0건이다 —
**리더는 이 비트를 무시해야 한다.**

### 1.2 `TEXB` 컨테이너 (`0x14015c8d0`)

```
(v≥1) i32 imageCount            ; 0x14015c93c   — v0 이면 1 고정(0x14015c941)
(v≥3) i32 imageFormat           ; 0x14015c978   — -1 이면 raw, 아니면 FreeImage enum(2=JPEG 13=PNG 25=GIF 35=MP4)
(v≥4) i32 variantCount          ; 0x14015c9a0   — 0 이면 조건 변형 없음(0x14015c9d4 test/je)
변형 × variantCount:
    i32 ×3 + NUL 종단 조건 JSON ; 0x14015ca2d / 0x14015ca57 / 0x14015ca7c, 문자열 0x14015ca93
image × imageCount:
    i32 mipCount                ; 0x14015d2bb
    mip × mipCount:
        i32 width               ; 0x14015d32b
        i32 height              ; 0x14015d356
        (flags&0x40) i32 depth  ; 게이트 0x14015d374 / 읽기 0x14015d399 / 기본 1 은 0x14015d2f4
        (v≥2) i32 isLZ4         ; 0x14015d454  — **bit0 만 본다**(0x14015d484 `and al, 1`)
        (v≥2) i32 decompressed  ; 0x14015d47f
        i32 compressed          ; 0x14015d4d3
        payload[compressed]     ; 포인터 0x14015d4f9, 전진 0x14015d4ff
```

경계 검사(`0x14015d3a2`–`0x14015d3e8`): `w ≤ 0x2000`, `h ≤ 0x2000`, `depth ≤ 0x80`,
`w·h·depth·4 ≤ 0xffffffff` 를 어기면 에러 경로(`0x1400986c0`).

`variantCount` 는 **Waple 이 `isVideoMp4` 불리언으로 오해하고 있던 필드**다. 모델은 틀렸지만
휴리스틱 결과가 코퍼스 전건 같아서(spec `format.tex.texb.variantCount`, 불일치 0건) 이번엔 손대지 않았다.

**절반 해상도 로드 경로**(spec `format.tex.texs.halfScalePath` 가 "재현 조건 미상" 으로 남겨 둔
자리)의 조건을 이번에 특정했다. TEXB 리더가 받는 **옵션 워드**(스택 인자, 로더가 `[rbp+0x7f]` 에서
실어 준다 — `0x14015e7a7`·`0x14015e7b8`)의 **bit1** 이 켜져 있고 지금이 **mip 0** 이며
**mipCount > 1** 이면 그 레벨을 통째로 건너뛴다:

```
0x14015d2d4  mov eax, [rbp+0x290] ; opt          0x14015d3fd  cmp [rbp-0x1c], 0   ; opt & 2
0x14015d2da  and eax, 2                          0x14015d403  test esi, esi       ; mip 인덱스 == 0
0x14015d2e0  mov [rbp-0x1c], eax                 0x14015d407  cmp r13d, 1         ; mipCount > 1
                                                 0x14015d40d  mov r10b, 1         ; → 스킵 표시
0x14015d513  test r10b, r10b → 0x14015e118(다음 레벨) + r15d = 1 (0x14015d521)
0x14015e1ad  mov eax, r15d                        ; 그 표시가 곧 반환값
```

(`esi` 가 mip 인덱스라는 근거: 루프 계속 지점 `0x14015e118` 이 `[rbp-0x54]` 에서 다시 읽어
`inc` 하고 `mipCount` 와 비교한다 — `0x14015e11f`–`0x14015e127`.)

반환값이 1 이면 로더가 TEXS 프레임 지오메트리 6개를 전부 0.5 배 한다
(`0x14015e937` 비교 → `0x14015e94e` `movdqa xmm3, [0x140492dd0]` = `(0.5,0.5,0.5,0.5)`, 루프 `0x14015e960`).
mip0 을 버렸으니 정규화 분모가 절반이 되어 UV 가 2배로 튀는 것을 되돌리는 보정이다.
즉 **파일 속성이 아니라 엔진 품질 옵션**(텍스처 해상도 낮춤)이다. Waple 엔 대응 경로가 없으니 무관하다.

### 1.3 `TEXS` 스프라이트시트 (`0x14015e1d0`)

```
i32 frameCount                          ; 0x14015e21c
(v≥3) i32 gifWidth                      ; 0x14015e23e   — v<3 이면 헤더 imageWidth (0x14015e26c)
(v≥3) i32 gifHeight                     ; 0x14015e273   — v<3 이면 헤더 imageHeight (0x14015e26f)
frame × frameCount (32B):
    i32 imageId                         ; 0x14015e2d5
    f32 frametime                       ; 0x14015e2f6
    지오메트리 6개 x, y, width, widthY, heightX, height
        v1  : i32 → float 캐스팅         ; 0x14015e322 이하 (cvtdq2ps 0x14015e331 …)
        v≥2 : f32 그대로                  ; 0x14015e402 이하
```

지오메트리는 저장 직후 **그 `imageId` 페이지의 mip0 alloc 크기로 나눠 0..1 로 정규화**된다
(`0x14015e4d6`–`0x14015e4eb`: x·width·heightX 는 폭으로, y·widthY·height 는 높이로).
분모가 `imgW/imgH` 가 **아니라 decode dims** 라는 뜻이다 — Waple 이 픽셀 좌표를 그대로 들고
소비처(`keepFullAtlas`)에서 decode dims 텍스처를 쓰는 것과 결과가 같다.

총 재생길이는 `[rdi]` 에 누적된다(`0x14015e514` `addss` → `0x14015e518` 저장).

---

## 2. 동봉 311건 파스 결과

### 2.1 분포 (조치 후)

| format | 파일 | payload |
| --- | --- | --- |
| 0 (rgba8888) | 191 | `lz4RGBA` 156 · `embeddedImage` 35 |
| 9 (r8) | 60 | `r8` 60 |
| 8 (rg88) | 51 | `rg88` 51 |
| 4 (dxt5/BC3) | 9 | `bc3` 9 |

fmt 6(BC2)·7(BC1)·12(BC7) 는 동봉 자산에 **0건**이다(워크샵 코퍼스엔 fmt6 38 · fmt7 73 이 있다).
BC7 은 어느 쪽에도 실물이 없어 디코더 필요성이 없다.

컨테이너 버전: `TEXB0004` 127 · `TEXB0003` 113 · `TEXB0001` 42 · `TEXB0002` 29.
`TEXS0003` 44 · `TEXS0002` 8 · 없음 259.
`imageCount` 는 311건 모두 1(다중 페이지 아틀라스는 동봉 자산엔 없다).
`variantCount` 는 311건 모두 0(조건 변형 텍스처는 워크샵 젤다 8종뿐).

> `TEXB0001` 이 42건 있는데 **imageCount 필드를 갖는다.** 리더는 `cmp ecx, 1 / jl`(`0x14015c910`) 이라
> 버전 1 은 필드를 읽는다 — spec `format.tex.container.versionDistribution` 의 산문
> ("TEXB0001: imageCount 없음") 은 버전 0 얘기다. 참조 파서로 42건 전부 EOF 정확 일치를 확인했다.

### 2.2 조치 전 실패 — `materials/lut/*.tex` 28건

전부 `flags = 0x42`(clampuvs | slice3d), `texW/H = 32×32`, `imgW/H = 1024×32`, `depth = 32` 인
32³ 색보정 LUT 다. mip 레코드에 depth 가 하나 더 들어가는 것을 몰라
`parseMip` 이 전건 실패했고, 그 다음 512B PNG 시그니처 스캔이 페이로드를 우연히 정확히
집어서(`comp` 가 EOF 까지라 범위가 같았다) **픽셀은 맞고 컨테이너 정보는 전부 사라진** 상태였다:
`imageCount = 0`, `mip = nil`, `mipChain = []`, `depth` 개념 자체 없음.

조치 후 28건은 `payload = .embeddedImage`(imageFormat 13 = PNG), `depth = 32`,
`mip.depth = 32`, `imageCount = 1` 로 읽힌다. `payloadRange` 는 조치 전후 **완전히 동일**해
디코드 픽셀은 무회귀다.

> ⚠️ **LUT 는 헤더와 실제 PNG 의 축이 다르다.** 헤더는 `imgW = texW × depth`(가로 언롤) 인데
> 저장된 PNG 는 **32×1024**(세로로 32 슬라이스 적층) 이다 — 28건 전수 동일. 3D LUT 샘플링을
> 구현할 때 헤더 치수를 믿으면 안 된다.

### 2.3 무결성 검증

`scripts/re` 밖의 임시 참조 파서(엔진 레이아웃 그대로)로 두 가지를 쟀다.

1. **파스 끝 == EOF**: 311/311 정확히 일치. depth 필드를 빼면 28건이 즉시 어긋난다.
2. **Waple vs 참조 전 필드 대조**: `format` `flags` `imgW/H` `depth` `previewColor` `imageCount`
   `frameCount` `TEXS 버전` `gifW/H` `mip0(w,h,depth,lz4,dec,범위)` `체인 전 레벨(dims·범위·orig)` —
   **불일치 0건**.
3. **페이로드 해제**: 1,473 mip 레벨 전건. LZ4 해제 실패 0, 해제 크기가
   `fmt0 → w·h·4·depth`, `fmt4 → ceil(w/4)·ceil(h/4)·16·depth`, `fmt8 → w·h·2`, `fmt9 → w·h` 예측치와
   전건 일치. 인코딩 레벨 76개(PNG 72 · JPEG 4)는 전건 시그니처 정상.

---

## 3. 플래그 비트 — 주입과 소비

`wallpaper64.exe` 는 텍스처 플래그를 내부 상태 워드로 옮기는 자리가 하나 있다
(`0x14030358e`–`0x1403035d5`). 거기서 **읽는 비트는 여섯 개뿐**이다.

| 비트 | 의미 | 엔진 소비 | Waple |
| --- | --- | --- | --- |
| `0x1` | NoInterpolation | `0x14030358e` → 상태 `|= 2` | **소비** — `resolveTextureNoInterpolation` → `texFilter[slot]` |
| `0x2` | ClampUVs | `0x1403035a1` → `|= 4` | **소비** — `resolveTextureClampUVs` → `texWrap[slot]` |
| `0x4` | IsGif(스프라이트시트) | `0x1403035ae` → `|= 8` | **소비** — TEXS 프레임 경로. 동봉에서 이 비트와 TEXS 존재가 52/52 일치 |
| `0x8` | 저장 mip 1장 | `0x1403035d5` → `|= 0x10` | **입력 아님**(로더가 세움). Waple 은 무시 — 정확 |
| `0x20` | IsVideoTexture | `0x1403035bb` → `|= 0x20` | **소비** — `.video` 페이로드 |
| `0x40` | Slice3D(volume) | `0x1403035c8` → `|= 0x40` | **이번에 파스 추가**(`depth`). 3D 샘플 소비처는 아직 없다 |
| `0x80000` | AlphaChannelPriority | **없음** | 노출만(`alphaChannelPriority`). 82건이 켜져 있지만 **WE 자신도 런타임에 읽지 않는다** |
| `0x100000`–`0x800000` | 미상(이펙트 마스크) | **없음** | 동봉 0건 |

즉 `0x80000` 과 상위 니블은 **주입은 되지만 소비는 어디서도 안 되는** 컴파일러 힌트다.
`test dword ptr [reg+4], 0x80000` 형태의 명령이 바이너리 전체에 존재하지 않는다(전수 스캔).

동봉 311건 flags 도수: `2`×121 · `0x80002`×66 · `4`×40 · `0`×36 · `0x42`×28 · `0x80004`×10 ·
`0x80000`×6 · `6`×2 · `1`×1 · `3`×1.

---

## 4. `.tex-json` 298건 키 히스토그램

`.tex-json` 은 **빌드 사이드카**다(`resourcecompiler64 -tex` 입력). 런타임 파서가 읽는 스키마가
아니라서 `scripts/re/bundled_key_coverage.py` 는 이 확장자를 아예 제외한다 — `--schema texjson`
같은 스키마는 없다. 아래는 이번 조사에서 따로 센 것이다.

| 키 | 파일 | 짝 `.tex` 있음 | 소스 폼만 | 값 |
| --- | --- | --- | --- | --- |
| `format` | 298 | 272 | 26 | rgba8888 155 · r8 60 · rg88 50 · rgba8888n 19 · rgb888 4 · dxt5n 4 … |
| `clampuvs` | 266 | 243 | 23 | true 205 · false 61 |
| `nonpoweroftwo` | 231 | 208 | 23 | true 231 |
| `nomip` | 122 | 96 | 26 | true 119 · false 3 |
| `alphachannelpriority` | 82 | 82 | 0 | true 82 |
| `spritesheetsequences[]` | 52 | 52 | 0 | — |
| `spritesheetsequences[].frames` | 52 | 52 | 0 | 64 ×15 · 30 ×12 · 4 ×6 · 16 ×5 · 8 ×3 · 32 ×3 … |
| `spritesheetsequences[].duration` | 52 | 52 | 0 | **1 ×52**(전건) |
| `spritesheetsequences[].width` | 52 | 52 | 0 | 128 ×24 · 85.334 ×12 · 64 ×7 … |
| `spritesheetsequences[].height` | 52 | 52 | 0 | 128 ×26 · 102.4 ×9 · 64 ×8 … |
| `nointerpolation` | 12 | 11 | 1 | false 10 · true 2 |
| `bleedtransparentcolors` | 4 | 4 | 0 | true 4 |
| `halfmip` | 2 | 2 | 0 | true 2 |
| `forcerawcompression` | 2 | 2 | 0 | true 2 |

### 4.1 컴파일본이 있으면 모든 키가 헤더로 들어온다 — 272쌍 전건 검증

| `.tex-json` 키 | `.tex` 로의 사상 | 일치 |
| --- | --- | --- |
| `nointerpolation` | `flags & 0x1` | **11/11** |
| `clampuvs` | `flags & 0x2` | **243/243** |
| `alphachannelpriority` | `flags & 0x80000` | **82/82** |
| `spritesheetsequences` | `flags & 0x4` + TEXS 섹션 | **52/52** (프레임 수도 52/52 일치) |
| `nomip: true` | mipCount == 1 | **93/93** |
| `format` | 헤더 `format` | `check_tex_format_map.py` 가 매 CI 재측정 |

`nonpoweroftwo`(231건) 는 세 바이너리 어디에도 토큰이 없다 — 에디터 템플릿 잔재이고 컴파일 무영향.
`bleedtransparentcolors` · `forcerawcompression` · `halfmip` 은 인코딩 방식만 바꾸고 헤더에 흔적이 없다.

### 4.2 Waple 이 못 읽는 키 — 도달 수 순

컴파일본이 있는 272건에서는 **못 읽는 키가 없다**(위 표대로 전부 헤더로 들어오고, 헤더 필드는
이제 전부 파스된다). 남는 건 **소스 폼 26건** — `.tex` 가 없어 `TexImage.parse` 가 nil 이고
`resolveTextureClampUVs`/`resolveTextureNoInterpolation` 이 기본값으로 떨어지는 자리다.

| 키 | 미소비 파일 | 그중 런타임 도달 | Waple 현재값 | 실제 영향 |
| --- | --- | --- | --- | --- |
| `clampuvs: true` | 23 | **1** | `false`(= repeat) | 22건은 에디터 프리뷰 썸네일(`presets/*/preview*/materials/effectpreview`) — 월페이퍼 런타임이 안 그린다. 도달하는 1건은 `scenes/gifs/materials/background` |
| `nomip: true` | 26 | 26 | 무시 | 소스 폼은 `.png` 1장을 그대로 올려 애초에 저장 mip 이 없다 — 결과 동일 |
| `nonpoweroftwo: true` | 23 | 1 | 무시 | 데드 키(바이너리 토큰 없음) |
| `nointerpolation: true` | **1** | **1** | `false`(= linear) | `scenes/gifs/materials/background` — gif 템플릿 배경이 nearest 대신 linear 로 샘플된다 |
| `format` | 0 | — | **읽는다** | `SceneRendererResources.texJSONFormatCodes`(소스 폼 전용) |

즉 실제 구멍은 **`scenes/gifs/materials/background.tex-json` 한 건**
(`{"nonpoweroftwo":true, "nointerpolation":true, "clampuvs":true, "nomip":true, "format":"rgba8888"}`)
이고, 고칠 자리는 `SceneRendererResources.resolveTextureClampUVs` /
`resolveTextureNoInterpolation` 의 소스 폼 폴백이다(이번 작업 담당 파일 밖이라 손대지 않았다).

---

## 5. 프레임/시트 메타데이터 — 주입 ≠ 소비

`.tex-json` 의 `spritesheetsequences[0].duration` 은 **52건 전부 1(초)** 이고,
`frames` 는 3~128 이다. 컴파일본에서 그 속도가 어떻게 나타나는지가 갈린다.

| TEXS 버전 | 동봉 | 프레임별 `frametime` |
| --- | --- | --- |
| `TEXS0003` | 44 | `duration / frames` 가 정확히 들어 있다 |
| `TEXS0002` | 8 | **전 프레임 0** — 필드는 있으나 항상 0이다 |

`TEXS0002` 8건은 `debris1` · `fire1` · `fire2` · `fire3` · `lightning1` · `lightning2` ·
`snow` · `smoke3` 로, 전부 자주 쓰이는 파티클 시트다.

Waple 의 두 소비 경로가 이 0 을 다르게 다루고 있었다.

* **파티클 경로** — `SceneRendererFrameEncoder.particleSheetFrameIndex` / `SceneRenderer3D` 가
  `max(0.016, ft)` 로 폴백한다. 정상 동작.
* **이미지 레이어 경로** — `TexImage.spriteFrameIndex` 가 `max(1e-4, f.time)` 로 클램프했다.
  총 재생길이가 `n × 0.1ms` 가 되어 **초당 수백 바퀴**를 돌았다. 같은 자산이 레이어냐 파티클이냐에
  따라 속도가 달라지는 상태였다.

조치: 저장 frametime 총합이 0 이면 프레임당 `TexImage.fallbackFrameTime`(0.016s) 으로 균일
재생한다. 값이 하나라도 있으면 **종전 식 그대로**라 `TEXS0003` 44건은 비트동일이다.

> WE 가 이 자리에 쓰는 값은 확정하지 못했다. TEXS 리더가 총 재생길이를 누적만 하고
> (`0x14015e514`), 그 값을 읽는 소비처를 바이너리에서 특정하지 못했다. 0.016 은 **Waple 내부
> 일관성**(파티클 경로와 동일)이 근거이고 RE 확정이 아니다.

`gifWidth`/`gifHeight` 도 이번에 노출했다(`TEXS0003` 은 파일값, 이하는 헤더 `imgW/imgH` 기본값).
소비처는 아직 없다 — Waple 은 프레임 렉트에서 크기를 얻는다.

---

## 6. 디코더 대조

### 6.1 알파 규약 — straight 확정

동봉 fmt0 텍스처 156개 중 반투명 픽셀이 있는 108개를 훑어 `RGB > A` 인 픽셀을 셌다.
**107개 파일에 존재한다**(최다 `waterplants1` 735,923 픽셀). 프리멀티였다면 원리적으로 불가능하다.
`bleedtransparentcolors`(투명 픽셀의 RGB 를 주변 색으로 채우는 컴파일러 옵션)가 존재하는 것도
같은 결론을 가리킨다.

따라서 Waple 규약 — raw/BC 는 저장 그대로 straight, PNG/JPEG 만 CG 의 premultiplied 를 역변환,
프리멀티는 최종 컴포지트 1회 — 이 맞다.

### 6.2 디코딩 경로

WE 는 zlib(inflate 전용)·LZ4·Wuffs 를 정적 링크하지만 `.tex` 페이로드에 쓰는 건 **LZ4 뿐**이다
(`isLZ4` bit0 → `LZ4_decompress_safe` @`0x14014c160`). 인코딩 mip(PNG/JPEG/GIF)은 그 다음 단계이고
`imageFormat` 이 FreeImage enum 으로 지정한다. Waple 은 `COMPRESSION_LZ4_RAW` + ImageIO 로 같은 구조다.
BC 블록 디코드는 Waple 의 자체 구현(`DXT5Decoder`) 또는 Metal 네이티브 업로드(`TexDecoder.nativeBC`)다.

### 6.3 565 → 8bit 색 확장 — **고쳤다**

WE 의 CPU 디코더(`resourcecompiler64 -transcode`)와 D3D/Metal 하드웨어는 둘 다 **비트 복제**
(`(r<<3)|(r>>2)`, `(g<<2)|(g>>4)`) 를 쓴다. Waple 은 `c*255/31` 을 썼고 채널값에 따라 ±1 이 어긋났다.

동봉 fmt4 9건 mip0 전수, 두 규칙의 RGB 바이트 차이:

| 텍스처 | 다른 RGB 바이트 | 총 바이트 |
| --- | --- | --- |
| `splash_1_normal` | 1,010,677 | 4,194,304 |
| `shower_stream_0_normal` | 32,850 | 262,144 |
| `fern1` | 24,916 | 1,048,576 |
| `rain_drops_0` | 7,535 | 262,144 |
| `flatnormal` | 256 | 1,024 (= **전 픽셀**) |

전부 ±1 이지만 노멀맵에서 나쁘다(`flatnormal` 은 (128,128,255) 여야 하는데 한 채널이 1 낮았다).
종전 규칙은 Waple 의 CPU 경로를 **자기 GPU 경로와도** 어긋나게 하고 있었다.

### 6.4 BC3 알파 보간 라운딩 — **남은 갭**

WE(와 D3D 규격)는 `((7-i)·a0 + i·a1 + 3) / 7`, 6단은 `+2)/5` 로 **반올림**한다.
`DXT5Decoder` 는 floor 라 알파가 최대 1 낮다. 동봉 실측 불일치 바이트:
`splash_1_normal` 48,400 · `splash_1` 11,608 · `fern1` 3,169 · `splash_9` 3,069 · `splash_10` 1,794.

고치려면 `Tests/WapleRenderTests/DXT5DecoderTests.testDecodesEightValueAlphaRamp` 의 기댓값
`[218,182,145,109,72,36]` 을 `[219,182,146,109,73,36]` 으로 함께 바꿔야 한다.
그 파일은 이번 작업의 담당 범위 밖이라 코드에 주석으로만 못박고 손대지 않았다.

### 6.5 R8 / RG88 / RGBA8888

`check_tex_format_map.py` 의 예외 E 가 딛고 선 두 줄(`r8 → (v,v,v,v)`, `rg88 → (b0,b0,b0,b1)`)은
그대로다. 셰이더 `ConvertTexture0Format` 의 **변환 후** 모양에 맞춘 정규화라, 여기를 네이티브
배치로 바꾸면 그 게이트의 근거가 무너진다.

---

## 7. 이번에 안 고친 것 (근거 포함)

| 항목 | 왜 |
| --- | --- |
| raw RGBA 폴백의 헤더 오프셋 42 | 실물 헤더 끝은 46/50 이지만 **이 분기는 실물에서 도달 불가**다(동봉 311/311, 코퍼스 4,680/4,680 이 TEXB 컨테이너를 갖는다). 기존 픽스처가 42 를 못박고 있고 그 테스트 파일은 담당 밖이다 |
| BC3 알파 라운딩 | §6.4 — 담당 밖 테스트 기댓값 동반 수정 필요 |
| `variantCount` 를 `isVideoMp4` 로 보는 모델 | 모델은 틀렸지만 출력이 코퍼스 전건 동일(spec 확정). 고치면 조건 변형 파스 경로 전체를 다시 재야 한다 |
| 3D LUT 슬라이스 샘플링 | `depth` 는 이제 파스한다. 실제 3D 샘플 소비처가 없어 죽은 코드를 만들지 않았다 |
| `previewColor` 소비 | 렌더 소비처를 못 찾았다(에디터/UI 힌트). 헤더 길이 계산 목적으로만 읽는다 |
