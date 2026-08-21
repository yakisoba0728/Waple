# `.tex` 컨테이너와 `.tex-json` — 동봉 전건 대조

**조사일 2026-08-21 · WE 2.8.42 `wallpaper64.exe` (md5 `438cb215f20a8f6c38f57fbc3d9da588`, imagebase `0x140000000`)**
**대상: 동봉 자산 `Sources/WapleRender/Resources/WEAssets/` — `.tex` 311개 · `.tex-json` 298개 전건**

> **범위 라벨 규약.** 이 문서의 도수는 넷 중 하나의 범위다. 섞어 읽으면 결론이 뒤집힌다.
>
> | 라벨 | 범위 | `.tex` |
> | --- | --- | --- |
> | **동봉** | `Sources/WapleRender/Resources/WEAssets/` | 311 |
> | **설치 assets** | `wallpaper_engine/assets/` | 311 — **동봉과 상대경로·SHA1 전건 동일**(2026-08-21 재확인, 차이 0건) |
> | **설치 projects** | `wallpaper_engine/projects/defaultprojects/` | 129 — 2026-08-21 에 코퍼스로 들어왔다(§2.4) |
> | **워크샵 코퍼스** | scene.pkg 162개 + 설치 assets + **설치 projects** | **5,120** (`spec/formats/tex-deep.json`) |
>
> 즉 "동봉 311" 과 "설치 assets 311" 은 **같은 파일 집합**이고, 워크샵 코퍼스는 그 311 을 포함한다.
>
> **[2026-08-21 갱신] 설치 projects 129 가 코퍼스에 들어왔다.** 종전엔 `measure_tex_deep.iter_tex` 가
> `WE/assets` 만 훑어 이 129건이 **어느 코퍼스에도 없었고**, 그래서 `.tex` 플래그 비트 `0x10` 이
> 정본의 어느 도수에도 안 나타났다("코퍼스 4,991개 전수 비트 도수" 라는 근거가 실재하는 비트 하나를
> 못 보고 있었다). 지금은 `iter_tex` 가 `assets/`·`projects/` 를 함께 훑는다 —
> `corpusTexFiles` **4,991 → 5,120**, `flags.bits.observedBitCounts` 에 `"4": 10`(= 비트 4 = `0x10`)이
> 새로 생겼다. 형제 측정 `measure_texjson()` 은 처음부터 `projects/` 를 훑고 있었으므로
> (`texJsonFiles` 388 = 동봉 298 + projects 90) `.tex` 쪽과 `.tex-json` 쪽의 범위가 서로 달랐던
> 비대칭도 이때 없어졌다.

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

**2026-08-21 2차 대조에서 더 나온 것** (범위 라벨은 아래 표 참조)

| 항목 | 판정 |
| --- | --- |
| 설치 `projects/defaultprojects` 129건 | **여태 어느 코퍼스에도 안 들어 있던 범위.** 참조 파스 129/129 성공, Waple 도 전부 다루는 조합(§2.4). **2026-08-21 에 `iter_tex` 가 훑도록 고쳐 정본 코퍼스에 넣었다**(4,991 → 5,120) |
| flags 비트 `0x10` | **새 비트.** 설치 projects 10건에만. `.tex-json` 의 `srgb: true` 와 358쌍 기준 10/10·348/348 대응(이름은 추정, 소비 여부는 정황 — §3.1) |
| **§3 의 "플래그 디스패치" 근거** | **무효였다.** `0x14030358e`–`0x1403035d5` 는 텍스트 셰이핑/스크립트 표(`0x140438050` → 문자열 `0x140436aa0`)를 걷는 코드이고 텍스처와 무관하다. 비트 패턴이 겹친 우연이었다 — §3 정정 박스 |
| TEXB0004 `variantCount` | **개수 기반이 정답.** Waple 의 패턴 휴리스틱을 개수 기반으로 고쳤다(§1.2) |
| `TEXV0004` 레거시 컨테이너 | 엔진은 받고 Waple 은 거부한다. 실물 표본 0/5,120(설치 projects 129 포함) 이라 **구현하지 않고 근거만 남겼다**(§7) |
| 신뢰 경계(악성 헤더) | 거짓 차원·거짓 depth·거짓 comp/dec·거짓 mipCount/imageCount/frameCount + 전 길이 잘림·헤더 바이트 반전 스윕에서 **트랩 0건**. `Tests/WapleCoreTests/TexHostileInputTests.swift` 가 고정 |
| TEXS0002 8건의 "원래 속도" | 짝 `.tex-json` 에 `duration/frames` 로 남아 있다(3/8 만 Waple 폴백과 일치). 다만 런타임 근거가 없고 도달 자산이 파티클뿐이라 **관측 차이 없음**(§5) |
| TEXS0002 8건의 "원래 속도" **[2026-08-21 해소]** | 위 행은 사이드카를 기준으로 잰 것이라 방향이 뒤집혀 읽힌다. WE 는 `frametime == 0` 인 시트를 **렌더 프레임당 한 칸** 진행시킨다(`comiss` `0x14015f1c9` / `subss` `0x14015f1d8` / `minss` `0x14015f208`) — 즉 60Hz 기준 ≈0.0167s 이고 Waple 폴백 0.016 은 **8/8 전건에서 오차 4% 안**이다(프레임 수와 무관). 사이드카 `1/frames` 는 오히려 최대 15배 느리다(§5 툼스톤 · [`sprite-occlusion.md` §11.1](sprite-occlusion.md#111-fallbackframetime--헤지를-걷어내고-종전-패치안을-철회한다)) |

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

`variantCount` 는 **Waple 이 `isVideoMp4` 불리언으로 오해하고 있던 필드**다.

> **[2026-08-21 조치] 개수 기반으로 고쳤다.** 리더가 이 필드를 `[rbp-0x78]` 에 넣고(`0x14015c9b8`)
> 블록 루프의 상한으로 쓰는 것을 다시 떠서 확인했다 — `0x14015d1b3 inc esi` → `0x14015d1c9
> cmp esi, [rbp-0x78]` → `jb 0x14015ca00`. 0 이면 `0x14015c9d4 test esi,esi / je 0x14015d1df` 로
> image 루프 직행. 블록 본문은 `i32 ×3 + NUL 종단 문자열`이고 **엔진은 세 정수의 값을 검사하지 않는다**
> (`0x14015ca2d`·`0x14015ca57`·`0x14015ca7c` 는 읽어서 저장만 한다).
>
> 종전 Waple 은 개수를 버리고 `첫 정수 == 1 && idx ∈ 1…64 && 셋째 == 0` **패턴**으로 블록을 찾았다.
> 코퍼스 전건에서 결과가 같았던 건(`modelMismatchOnCorpus: 0`) 관측된 zelda 8종이 우연히 그 값이라서다.
> 패턴이 어긋나는 파일이 오면 그 자리를 mip 테이블로 읽어 **컨테이너를 통째로 잃는다**(= 텍스처가
> 통째로 안 나온다). 부수적으로 종전 스캔은 image 루프 **안**에 있어 다중 image v4 에서는 image 마다
> 다시 돌았다 — 엔진은 image 루프 **앞에서 한 번**만 읽는다.
>
> 회귀 위험: 코퍼스 분포가 `0×2865 · None×2118 · 1×7 · 3×1` 이고 세 값 모두 개수 해석으로 정상
> 파스되므로 출력은 종전과 동일하다. 새로 붙인 상한 1024(엔진엔 없다)는 블록마다 최대 64KB 를
> 훑는 것에 대한 Waple 자체 방어선이다 — `TexHostileInputTests` 가 양쪽 경계를 못박는다.

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
`variantCount` 는 **필드를 갖는 127건(TEXB0004)이 전부 0** 이고 나머지 184건(TEXB0001~0003)은 필드 자체가 없다
— 조건 변형 텍스처는 워크샵 젤다 8종뿐이다. (종전 판은 "311건 모두 0" 이라고 적었는데, 필드가 없는 것과
0인 것을 합쳐 세면 v3→v4 게이트가 검증됐다는 착각이 된다.)
`headerLen` 은 46 ×283 · 50 ×28(= slice3d 28건) — 42 는 **0건**이다(previewColor 가 항상 붙는다).
mip 레코드의 `isLZ4` 는 1 ×253 · 0 ×58, `mipCount` 는 1 ×131 · 2~10 ×180.

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

> ⚠️ **LUT 는 헤더와 실제 PNG 의 축이 다르다.** 재실측(2026-08-21, 28건 전수 IHDR 직독, 예외 0건):
>
> | 자리 | 값 |
> | --- | --- |
> | 헤더 `texW×texH` / `depth` | `32×32` / `32` (슬라이스 한 장 + 장수) |
> | 헤더 `imgW×imgH` | `1024×32` — 슬라이스를 **가로로** 편 규약(`imgW = texW × depth`) |
> | mip 레코드 `w×h` / `depth` / `isLZ4` | `32×32` / `32` / `0`(PNG 비압축 저장) |
> | 저장된 PNG IHDR | **`32×1024`**, 8bit truecolor(colortype 2, 알파 없음) — 세로 적층 |
>
> 즉 "축이 바뀐" 것이 아니라 **두 레이아웃이 공존한다.** 3D LUT 샘플링을 붙일 때 잘라야 하는 축은
> **세로**이고 슬라이스 k 는 PNG 의 `y ∈ [k·texH, (k+1)·texH)` 다 — 헤더 치수로 가로를 자르면 전부 틀린다.
> (raw `imageFormat = -1` volume 텍스처는 어느 코퍼스에도 표본이 **0건**이라 비인코딩 volume 의 슬라이스
> 순서는 **미확인**이다. 위 규약은 PNG 인코딩 28건 한정 확정.)

### 2.3 무결성 검증

`scripts/re` 밖의 임시 참조 파서(엔진 레이아웃 그대로)로 두 가지를 쟀다.

1. **파스 끝 == EOF**: 311/311 정확히 일치. depth 필드를 빼면 28건이 즉시 어긋난다.
2. **Waple vs 참조 전 필드 대조**: `format` `flags` `imgW/H` `depth` `previewColor` `imageCount`
   `frameCount` `TEXS 버전` `gifW/H` `mip0(w,h,depth,lz4,dec,범위)` `체인 전 레벨(dims·범위·orig)` —
   **불일치 0건**.
3. **페이로드 해제**: 1,473 mip 레벨 전건. LZ4 해제 실패 0, 해제 크기가
   `fmt0 → w·h·4·depth`, `fmt4 → ceil(w/4)·ceil(h/4)·16·depth`, `fmt8 → w·h·2`, `fmt9 → w·h` 예측치와
   전건 일치. 인코딩 레벨 76개(PNG 72 · JPEG 4)는 전건 시그니처 정상.

### 2.4 여태 안 훑던 범위 — 설치 `projects/defaultprojects` 129건

**[2026-08-21 해소]** 종전 `measure_tex_deep.iter_tex` 는 워크샵 pkg 와 `WE/assets` 만 훑었다.
설치본에는 그 밖에 `wallpaper_engine/projects/defaultprojects/**` 에 **`.tex` 가 129개** 더 있다
(WE 가 기본 제공하는 완성 씬들이다 — `razer_bedroom` `ricepod` `demon_core` `shimmering_particles` 등).
여기를 처음 전수로 뜬 것이 아래 표이고, 지금은 `iter_tex` 가 이 범위를 코퍼스에 포함한다.

| 항목 | 설치 projects 129건 |
| --- | --- |
| 매직 / TEXI | `TEXV0005` 129 · `TEXI0001` 129 · `headerLen` 46 ×129 (slice3d 0건) |
| 컨테이너 | `TEXB0003` ×129 (0001/0002/0004 **0건**) |
| format | 0 ×66 · 4 ×63 (8·9·6·7 **0건**) |
| imageFormat | −1 ×127 · 13(PNG) ×2 |
| imageCount | 1 ×129 |
| flags 비트 | `0x2` ×55 · **`0x10` ×10** · `0x4` ×9 · `0x1` ×33 |
| TEXS | `TEXS0003` ×9 · 없음 120 |
| mipCount | 1 ×47 · 2~11 ×82 (**11 레벨**이 4건 — 동봉 최대 10보다 깊다) |
| `imgW ≠ texW` | 37 · `imgH ≠ texH` 36 (npot 크롭) |
| 파스 | 참조 파서 129/129 성공 · 파스 끝 == EOF **129/129** |

새로 나온 사실은 둘이다.

1. **flags 비트 `0x10` 이 실재한다**(§3). 동봉·워크샵 코퍼스에는 0건이라 지금까지 표에 없던 비트다.
2. **mip 레벨이 11 까지 간다.** Waple 의 체인 수집엔 상한이 없어 문제 없지만, "최대 10" 을 전제로 한
   서술이 있다면 틀렸다.

Waple 파스 관점에서 이 129건은 전부 이미 다루는 조합이다(fmt 0/4, TEXB0003, imageFormat −1/13) —
`0x10` 은 파스에 영향이 없다. 즉 **이 범위에서 새로 깨지는 것은 없다.**

**정본 반영(2026-08-21).** `iter_tex` 가 `assets/` 뒤에 `projects/` 를 이어 훑는다. 순서는
`assets` **뒤**여야 한다 — `measure_corpus` 의 표본 선택(`picks`)과 `Counter` 삽입순(도수가 같을 때의
정렬 순서)이 순회 순서에 의존하므로 종전 코퍼스의 상대 순서를 흔들면 안 된다. 실측 반영 결과:

| 정본 값 | 종전 | 지금 |
| --- | --- | --- |
| `measuredAt.corpusTexFiles` | 4,991 | **5,120** |
| `flags.bits.observedBitCounts` | bit0 53 · bit1 4,382 · bit2 216 | bit0 86 · bit1 4,437 · bit2 225 · **bit4 10**(신설) |
| `container.versionDistribution.texb` | TEXB0003 2,047 | 2,176 |
| `container.versionDistribution.mip0ChainLength` | 최대 11 ×1 | 최대 11 ×**5** |
| `texs.versionDistribution` | TEXS0003 207 | 216 |
| `format.enum.corpusDistribution` | 0 ×1,435 · 4 ×1,796 | 0 ×1,501 · 4 ×1,859 |

`.tex-json` 쪽(`texJsonFiles` 388)은 원래부터 `projects/` 를 포함하고 있었으므로 바뀌지 않았다.

---

## 3. 플래그 비트 — 주입과 소비

> ### ⚠️ 정정 — 종전 판의 "플래그 디스패치 `0x14030358e`–`0x1403035d5`" 는 **텍스처와 무관하다**
>
> 종전 판은 이 문단을 "`wallpaper64.exe` 는 텍스처 플래그를 내부 상태 워드로 옮기는 자리가 하나
> 있다(`0x14030358e`–`0x1403035d5`), 거기서 읽는 비트는 여섯 개뿐" 으로 열고, 아래 표의 "엔진 소비"
> 칸을 그 VA 들로 채웠다. **틀렸다.** 2026-08-21 에 직접 다시 떠서 확인한 것:
>
> · 그 코드가 걷는 표는 `0x140438050` 이고 8바이트 레코드 `{i32 a, i32 b}` 에 종단값 `a == 0x159b` 다.
> · `a` 는 문자열 블롭 `0x140436aa0` 의 **오프셋**이다(`movsxd rcx, ecx; add rcx, 0x140436aa0`).
> · 그 문자열들을 실제로 읽어 보면 Adlam(U+1E9xx)·아랍·벵골·캐나다 음절문자 목록이다 —
>   **텍스트 셰이핑/스크립트 표**다. 감싸는 함수는 `0x140302bf0`(텍스트 경로).
> · 즉 `test byte ptr [rbx+4], 1/2/4/0x20/0x40/8` 여섯 줄은 **스크립트 속성 비트**를 상태 워드의
>   `2/4/8/0x20/0x40/0x10` 으로 재인코딩하는 코드이고, TexFlags 와 비트값이 겹친 것은 우연이다.
>
> **텍스처 플래그의 진짜 소비처는 아직 특정하지 못했다(미해결).** 잘못 붙은 근거를 지우고, 남는
> 사실만 아래에 다시 적는다. 의미(어떤 `.tex-json` 키가 어떤 비트를 켜는가)는 디스어셈블이 아니라
> **차분 컴파일**로 확정된 것이라(`spec/formats/tex-deep.json` `format.tex.flags.bits`) 이 정정과
> 무관하게 그대로 유효하다.

flags 워드가 사는 자리는 확정이다 — tex 디스크립터 **+4**(리더 `0x14015c7b1` `or dword ptr [r8+4], eax`,
로더 `0x14015e933` `or dword ptr [rsi+4], 8`). 그 오프셋에서 비트를 테스트하는 자리는 tex 리더 안에
**둘뿐**이다: `0x40`(`0x14015c856` 헤더 depth 게이트 · `0x14015d374` mip depth 게이트)과
`0x20`(`0x14015d20f`).

| 비트 | 의미 | 의미의 근거 | 엔진 런타임 소비 | Waple |
| --- | --- | --- | --- | --- |
| `0x1` | NoInterpolation | 차분 컴파일 · 사이드카 11/11 | **미특정** | **소비** — `resolveTextureNoInterpolation` → `texFilter[slot]` |
| `0x2` | ClampUVs | 차분 컴파일 · 사이드카 243/243 | **미특정** | **소비** — `resolveTextureClampUVs` → `texWrap[slot]` |
| `0x4` | IsGif(스프라이트시트) | `spritesheetsequences` **또는** `imagesequence` 61/61 + TEXS 존재 **440/440**(§4.1) | 파일 구조로 자명(TEXS 섹션) | **소비** — TEXS 프레임 경로 |
| `0x8` | 저장 mip 1장 | 로더가 세운다(`0x14015e933`) | — | **입력 아님.** Waple 은 무시 — 정확 |
| `0x10` | sRGB(**추정**) | 사이드카 10/10 · 348/348, 표본 1개 프로젝트 | **미특정** | 무시(§3.1) |
| `0x20` | IsVideoTexture | 코퍼스 38건 전부 mp4 페이로드 | `0x14015d20f`(TEXB 리더) | **소비** — `.video` 페이로드 |
| `0x40` | Slice3D(volume) | `slice3d: true` 로 재현 | `0x14015c856` · `0x14015d374`(조건부 필드 게이트) | **파스**(`depth`). 3D 샘플 소비처는 아직 없다 |
| `0x80000` | AlphaChannelPriority | 차분 컴파일 · 사이드카 82/82 | **미특정** | 노출만(`alphaChannelPriority`) |
| `0x100000`–`0x800000` | 미상(이펙트 마스크) | 코퍼스 30건 전부 `*_mask_*.tex` | **미특정** | 무시. 동봉 0건 |

`.text` 전수 바이트 스캔(2026-08-21): `test byte ptr [reg+4], 0x10` **0건**,
`test dword ptr [reg+4], 0x80000` **0건**(`0x80000` 을 보는 명령 2건은 `[rdi+0x20]`·`[rdi+0x4c]` 로
다른 구조체다). **다만 이 스캔은 `mov eax,[reg+4]` 로 먼저 적재한 뒤 `test al, imm` 하는 형태를
못 잡으므로 "소비 안 함" 의 증명이 아니다** — 종전 판이 "바이너리 전체에 존재하지 않는다" 로
단정한 것도 같은 한계를 안 적은 것이다. 지금 말할 수 있는 것은 "그 두 비트를 그 오프셋에서 직접
테스트하는 명령은 없다" 까지다.

**Waple 에 미치는 영향은 없다.** 0x1/0x2/0x4/0x20/0x40 은 이미 소비하고, 0x8 은 무시가 정답이며,
0x10·0x80000·상위 니블은 렌더 동작을 바꾸지 않으니 무시가 안전한 기본값이다. 바뀐 것은
**근거의 등급**(확정 → 미특정)뿐이다.

동봉 311건 flags 도수: `2`×121 · `0x80002`×66 · `4`×40 · `0`×36 · `0x42`×28 · `0x80004`×10 ·
`0x80000`×6 · `6`×2 · `1`×1 · `3`×1.
설치 projects 129건 flags 도수: `0`×72 · `3`×23 · `2`×14 · **`0x12`×10** · `7`×8 · `1`×1 · `5`×1.

### 3.1 `0x10` = `srgb` — 근거와 그 한계

`.tex-json` 이 있는 **358쌍**(동봉 272 + 설치 projects 86)에서 키↔비트 대응을 전수로 쟀다.
정확히 네 쌍이 **양방향 완전 일치**했다(켜진 쪽 전부 일치 + 꺼진 쪽 전부 일치):

| `.tex-json` 키 | flags 비트 | 켜짐 | 꺼짐 |
| --- | --- | --- | --- |
| `nointerpolation: true` | `0x1` | 34/34 | 324/324 |
| `clampuvs: true` | `0x2` | 237/237 | 121/121 |
| `alphachannelpriority: true` | `0x80000` | 82/82 | 276/276 |
| **`srgb: true`** | **`0x10`** | **10/10** | **348/348** |

> **한계를 분명히 한다.** `srgb: true` 를 쓰는 `.tex-json` 은 전 코퍼스에서 10개뿐이고
> **전부 같은 프로젝트**(`projects/defaultprojects/razer_bedroom/materials/`)다. 같은 시점에 같은
> 도구로 컴파일된 한 묶음이라, 이름 대응은 **교란 가능**하다(그 10건에만 있는 다른 성질이 원인일 수도).
> 다만 **지금 `resourcecompiler64.exe` 의 `.tex-json` 키 표에는 `srgb` 가 없다** — 표는 파일 오프셋
> `0x584da8`(`format`)부터 `0x584f70`(`variantcondition`)까지 NUL 로 이어진 34개이고 전체는:
> `format` `nointerpolation` `clampuvs` `croptoaspectratio` `nomip` `halfmip` `bilateralfilterkernel`
> `bilateralfilterstrength` `wildcard` `frameduration` `imagesequence` `file` `duration`
> `spritesheetsequences` `bleedtransparentcolors` `forcerawcompression` `ignoresizefornativecompression`
> `cropandresize` `cropresizewidth` `cropresizeheight` `alphachannelpriority` `normalmapflipx`
> `normalmapflipy` `slice3d` `variants` `options` `blend` `variantcondition` `alphablend`
> `component` `width` `height` `frames` `force`.
> 즉 **현행 컴파일러는 이 비트를 만들지 못한다** — 옛 버전의 잔재로 보는 것이 자연스럽다.
> `srgb` 문자열이 `wallpaper64.exe` 에 있긴 하지만 그건 `materials/util/combine_srgb.json` 경로
> 문자열이고, `sRGB` 는 PNG `sRGB` 청크 비교(`cmp ecx, 'sRGB'` @파일오프셋 `0xb7c19`)다 — 둘 다 키가 아니다.
>
> **판정: 이름은 추정**(강한 상관이지만 표본이 한 프로젝트라 교란 가능).
> 정본에서도 이 주장은 `flags.bits`(확정) 안에 섞지 않고 **별도 항목
> `format.tex.flags.srgbBit`(status `추정`)** 으로 뗐다 — 등급이 다른 주장을 확정 항목에 섞으면
> 항목 전체의 등급이 흐려진다. `flags.bits` 에는 도수(비트4 ×10)와 대응 사실만 남겼다.
> **"런타임 비소비" 도 확정이 아니라 정황**이다 — `test byte ptr [reg+4], 0x10` 이 `.text` 에 0건이고
> 현행 컴파일러 키 표에도 없다는 두 정황뿐이고, 위 정정대로 "여섯 비트 디스패치" 근거는 무효다.
> 어느 쪽이든 **Waple 이 무시하는 현재 동작은 안전하다**: 이 비트를 읽으면 그때부터는 WE 와 다르게
> 그리는 쪽이 되고, 지금은 렌더 결과가 이 비트와 무관하다.

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

> **⚠️ `spritesheetsequences ↔ 0x4` 는 쌍대응이 아니다**(2026-08-21, 설치 projects 를 붙이고 나서
> 드러났다). 설치 `projects/defaultprojects/dino_run/materials/` 의 **3건**(`coin_0` `vita_jump_0`
> `vita_walk_01`)은 `spritesheetsequences` 없이 `imagesequence` + `frameduration` 만 갖고도
> `flags = 0x7`(0x4 포함)과 **TEXS 섹션**을 얻는다. 즉 왼쪽 항은 `spritesheetsequences` 단독이 아니라
> **`spritesheetsequences OR imagesequence`** 다. 둘 다 `resourcecompiler64.exe` 의 34개 키 표에 있다(§3.1).
> 358쌍(동봉 272 + projects 86) 기준으로 이 OR 형태는 **61/61 · 297/297** 로 양방향 일치한다.
> `flags & 0x4` ⟺ TEXS 섹션 존재 쪽은 더 강해서 `.tex` **440건(동봉 311 + projects 129) 전건** 일치한다.

### 4.1a 이 대응을 이제 CI 가 매번 다시 잰다

종전 `check_tex_format_map.py` 는 `.tex-json`↔헤더 대응 중 **`format` 하나만** 봤고 헤더는
**오프셋 18 의 u32 하나만** 읽었다. 위 표의 나머지 대응은 **문서에만 있고 아무 게이트도 없었다.**
2026-08-21 에 셋을 붙였다.

| 게이트 | 무엇을 잠그나 | 현재 실측(동봉만 / +설치 projects) |
| --- | --- | --- |
| **H 헤더 프레이밍** | NUL 구분자 둘 · 컨테이너 버전 · `flags` · texW/H · imgW/H · **`flags & 0x40` 조건부 `i32 texDepth`** · **TEXI 버전>0 조건부 `u32 previewColor`** 를 다 센 자리에 `TEXB` 매직이 **정확히 착지**하는지. 조건부 필드를 하나라도 틀리면 착지가 깨진다. `flags & 0x4` ⟺ TEXS 도 함께 본다 | 311/311 · headerLen {46: 283, 50: 28} / 440/440 · {46: 412, 50: 28} |
| **I `.tex-json` 키 집합** | `MIN_PAIRS`/`MIN_FORMATS` 는 **하한**이라 **새 키가 생기는 것을 못 잡았다.** 관측 키 경로(중첩 포함)가 `KNOWN_TEXJSON_KEYS` 를 벗어나면 실패 | 14종 / 18종, 미등록 0 |
| **J 키↔flags 비트** | `nointerpolation`↔`0x1` · `clampuvs`↔`0x2` · `srgb`↔`0x10` · `alphachannelpriority`↔`0x80000` · (`spritesheetsequences` **OR** `imagesequence`)↔`0x4` 를 양방향으로 | 아래 |

동봉만: nointerpolation 1/271 · clampuvs 182/90 · sprite 52/220 · alphachannelpriority 82/190 ·
**srgb 0/272**(동봉에는 `srgb` 사이드카가 하나도 없다 — 판별력 0).
`WE_ROOT` 를 주면 설치 `projects/` 가 붙어 §3.1 의 358쌍 수치를 그대로 재현한다:
nointerpolation 34/324 · clampuvs 237/121 · sprite 61/297 · srgb **10/348** · alphachannelpriority 82/276.

> CI 에는 설치본이 없으므로 `srgb` 게이트는 **표본 0 으로 돈다**. 그 사실을 숨기지 않고 note 로 찍는다 —
> 0/0 은 아무것도 증명하지 않는데 초록으로만 보이면 "동작하는 척하는 도구" 가 된다.
> ②③(format↔Swift 표)과 D/E/F/G 는 **동봉 전용**으로 남겨 뒀다. 설치 `projects/` 에는 Swift 표에 없는
> `dxt5n+`(5쌍, 코드 4)가 있어 그대로 섞으면 `Sources/**` 를 고치지 않고는 못 넘는 실패가 난다(§7 넘길 것).

`nonpoweroftwo`(231건) 는 **`wallpaperui.exe`(에디터)에만 토큰이 있다** — 재확인 2026-08-21, 설치본
바이너리 27개를 ASCII·UTF-16LE 양쪽으로 훑은 결과 `wallpaperui.exe` 2건뿐이고
`wallpaper64.exe`·`resourcecompiler64.exe`·`scenescript64.dll`·`resourceutil64.dll` 에는 없다.
(종전 판은 "세 바이너리 어디에도 토큰이 없다" 였는데, 에디터를 안 본 결과다. 결론 — 컴파일·런타임
무영향 — 은 그대로지만 "죽은 키" 가 아니라 **에디터 전용 키**다.)
`bleedtransparentcolors` · `forcerawcompression` · `halfmip` 은 인코딩 방식만 바꾸고 헤더에 흔적이 없다.

`spritesheetsequences` 의 런타임 미도달도 같은 스윕으로 재확인했다: **`resourcecompiler32/64.exe`
두 개에만** 있고 `wallpaper64.exe`·`scenescript64.dll`·`resourceutil64.dll`·`wallpaperui.exe` 에는 없다.
즉 순수 컴파일 입력이고, 그 값은 TEXS 섹션으로 구워져 들어온다(아래 §5) — `.tex-json` 을 런타임에
읽을 이유가 없다. Waple 도 `.tex-json` 은 **소스 폼(`.tex` 부재) `format` 해석에만** 쓴다
(`SceneRendererResources.texJSONFormatCodes`, `check_tex_format_map.py` 가 매 CI 재측정).

### 4.2 Waple 이 못 읽는 키 — 도달 수 순

컴파일본이 있는 272건에서는 **못 읽는 키가 없다**(위 표대로 전부 헤더로 들어오고, 헤더 필드는
이제 전부 파스된다). 남는 건 **소스 폼 26건** — `.tex` 가 없어 `TexImage.parse` 가 nil 이고
`resolveTextureClampUVs`/`resolveTextureNoInterpolation` 이 기본값으로 떨어지는 자리다.

| 키 | 미소비 파일 | 그중 런타임 도달 | Waple 현재값 | 실제 영향 |
| --- | --- | --- | --- | --- |
| `clampuvs: true` | 23 | **1** | `false`(= repeat) | 22건은 에디터 프리뷰 썸네일(`presets/*/preview*/materials/effectpreview`) — 월페이퍼 런타임이 안 그린다. 도달하는 1건은 `scenes/gifs/materials/background` |
| `nomip: true` | 26 | 26 | 무시 | 소스 폼은 `.png` 1장을 그대로 올려 애초에 저장 mip 이 없다 — 결과 동일 |
| `nonpoweroftwo: true` | 23 | 1 | 무시 | 에디터 전용 키(`wallpaperui.exe` 에만 토큰) — 컴파일·런타임 무영향 |
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

> **[2026-08-21 해소 — 위 인용문은 전제가 틀렸다. 툼스톤으로 남긴다.]** 못 찾은 게 아니라
> **WE 가 아무 값도 안 쓴다.** 시트 진행기(`0x14015f0d0`–`0x14015f326`)는 `frametime` 을 누적
> 시간과 직접 비교할 뿐이고 0 일 때의 특례가 없다 — `comiss`(`0x14015f1c9`)가 통과하고
> `subss`(`0x14015f1d8`)가 0 을 빼고 `minss`(`0x14015f208`)가 누적을 0 으로 되돌려
> **렌더 프레임당 정확히 한 프레임** 전진한다(디스플레이 종속). 게다가 진행은 씬 프레임
> 카운터로 프레임당 1회만 열린다(`0x14015f162` ↔ `0x14015f275`) — 곧 **시트는 주사율보다
> 빠를 수 없다**. 그래서 0.016(= 1/62.5)은 60Hz 실동작 1/60 의 4% 근사이고, "RE 확정이 아니다"
> 가 아니라 **"이 자리에 확정할 값이 없다"** 가 맞다. 전문:
> [`sprite-occlusion.md` §11.1](sprite-occlusion.md#111-fallbackframetime--헤지를-걷어내고-종전-패치안을-철회한다).

**[2026-08-21 추가 실측] 그 8건의 "원래 속도" 는 짝 `.tex-json` 에 남아 있다.** 8건 전부
`spritesheetsequences[0] = {duration: 1, frames: N}` 을 갖고 있어 프레임당 시간이 `1/N` 로 나온다.
Waple 의 균일 폴백 0.016 과 대조하면:

| 자산 | `frames` | 사이드카가 뜻하는 프레임당 | Waple 폴백 0.016 대비 |
| --- | --- | --- | --- |
| `fire1` · `smoke3` · `lightning1` | 64 | 0.015625 | ≈ 일치(2.4% 빠름) |
| `fire2` · `lightning2` | 32 | 0.03125 | **2× 빠름** |
| `fire3` | 128 | 0.0078125 | **2× 느림** |
| `debris1` | 8 | 0.125 | **7.8× 빠름** |
| `snow` | 4 | 0.25 | **15.6× 빠름** |

즉 3/8 은 우연히 맞고 5/8 은 어긋난다. 그렇다고 사이드카를 런타임에 읽는 것이 **정답이라는 뜻은 아니다** —
`.tex-json` 은 컴파일 입력이고 그 문자열이 런타임 바이너리에 없다(§4). WE 자신은 그 값을 못 본다.

이 어긋남이 실제로 보이려면 그 8건이 **이미지 레이어 스프라이트시트**로 쓰여야 하는데, 전부
파티클 텍스처다. 파티클 경로는 TEXS frametime 을 안 쓰고 def 의 `animationmode` 를 쓴다 —
동봉 `.json` 전수에 `frametime` 키가 **0건**이고 `animationmode` 는 `null` ×106 · `randomframe` ×32 ·
`sequence` ×4 로 존재한다(Waple 은 `ParticleSystem.animationMode` 로 이미 소비한다).
**결론: 폴백 0.016 은 지금 도달하는 자산에서 관측 가능한 차이를 만들지 않는다.** 다만
"WE 가 이 값을 어떻게 정하는가" 는 여전히 미해결이고, 사이드카 수치는 그 답의 **후보**다.

**[2026-08-21 해소] 사이드카는 답의 후보가 아니다 — 오히려 WE 보다 15배 느린 오답이다.**
이 절이 이미 적었듯 `.tex-json` 은 컴파일 입력이다(런타임 문자열 실측: `.tex-json` 은
`wallpaper64.exe` 에 1개뿐이고 `resourcecompiler64.exe`·`-tex -i "` 클러스터 안이다 —
컴파일러 재호출 인자다. `spritesheetsequences` 는 ASCII·UTF-16LE 둘 다 **0개**).
그리고 WE 의 실제 재생속도는 위 [해소] 대로 **1/주사율**이므로, 60Hz 기준으로 사이드카
`1/frames` 는 `snow` 15배 느림 · `debris1` 7.5배 느림 · `fire2`·`lightning2` 1.9배 느림이고
`fire3` 만 2배 빠르다. 위 표의 "Waple 폴백 0.016 대비" 열은 **사이드카를 기준으로 잰 것**이라
방향이 뒤집혀 읽힌다 — 기준은 WE 실동작(≈0.0167)이어야 하고, 그 기준에서는 0.016 이 8/8 에서
맞는다. 표는 사이드카가 무엇을 뜻하는지의 기록으로 남긴다.

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
| raw RGBA 폴백의 헤더 오프셋 42 | 실물 헤더 끝은 46/50 이지만 **이 분기는 실물에서 도달 불가**다(동봉 311/311 · 설치 projects 129/129 · 코퍼스 5,120/5,120 이 TEXB 컨테이너를 갖는다. 종전 이 줄과 `spec/formats/tex-deep.json` 의 `transcode.args.goldenOracle` 에 적힌 **4,680** 은 유래를 확인하지 못했다 — 코퍼스 총계 4,991 과도 다르고 재현식도 없다. [미해결]로 남긴다). 기존 픽스처가 42 를 못박고 있고 그 테스트 파일은 담당 밖이다 |
| BC3 알파 라운딩 | §6.4 — 담당 밖 테스트 기댓값 동반 수정 필요 |
| ~~`variantCount` 를 `isVideoMp4` 로 보는 모델~~ | **2026-08-21 고쳤다** — §1.2 의 조치 노트 참조 |
| 3D LUT 슬라이스 샘플링 | `depth` 는 이제 파스한다. 실제 3D 샘플 소비처가 없어 죽은 코드를 만들지 않았다 |
| `previewColor` 소비 | 렌더 소비처를 못 찾았다(에디터/UI 힌트). 헤더 길이 계산 목적으로만 읽는다 |
| `TEXV0004` 레거시 컨테이너 | 엔진은 받는다(`0x14015e8c5`, TEXI/TEXB 를 **버전 0** 으로 호출 — previewColor 없음·`imageCount` 필드 없이 1 고정 `0x14015c941`·imageFormat/variantCount 없음). Waple 은 `TEXV0005` 만 받는다. **코퍼스 5,120 전건이 0005**(동봉 311 · 설치 projects 129 를 포함한 수치다 — 종전 이 줄은 4,991 을 '워크샵' 으로 라벨했는데 4,991 은 워크샵 pkg + 설치 assets 의 합계였다) 라 실물 표본이 0건이고, 표본 없이 두 번째 레이아웃을 쓰면 검증 불가능한 코드가 된다. 0004 실물이 나오면 추가할 것 |
| 플래그 `0x10`(sRGB) 소비 | 엔진도 안 읽는다(§3.1). 읽는 쪽을 만들면 **WE 보다 다르게** 그리게 된다 |
| `TexImage.spriteFrameIndex` 폴백 0.016 | §5 — 사이드카 수치가 후보지만 런타임 근거가 없고, 도달 자산에서 관측 가능한 차이가 없다 |
| `texJSONFormatCodes` 에 `dxt5n+` 없음 | 설치 `projects/` 에 `"format": "dxt5n+"` 사이드카가 **5쌍** 있고 컴파일된 코드는 전부 **4**(= `dxt5`)다. 정본도 "`+` 접미는 `dxt5n` 과 동일하게 처리된다" 로 적고 있다. 고칠 자리는 `Sources/WapleRender/SceneRendererResources.swift:1005-1009` 의 리터럴에 `"dxt5n+": 4` 를 더하는 것 — `Sources/**` 는 담당 밖이라 손대지 않았고, 그래서 `check_tex_format_map.py` 의 ②③ 는 **동봉 전용**으로 남겼다(§4.1a). 소스 폼(`.tex` 부재)인 `dxt5n+` 은 0건이라 **현재 그림에는 영향 없다** |
| ~~`RAW_DUMP_ALLOWED` 가 줄 번호로 고정~~ | **해소(커밋 `94045ac`).** 종전엔 `check_spec_shrink_guard.py` 가 `("measure_tex_deep.py", 493)` 로 줄 번호를 못박아 493행 위에 한 줄만 더해도 붉어졌다(이번 패치가 실제로 그렇게 만들어, 한 번은 줄 수 보존형으로 다시 짜고 코드 주석을 이 문서로 밀어냈다). 지금은 `RAW_DUMP_ALLOWED_LINES` 가 **그 줄의 전문 일치**로 보고, `[4b]` 가 면제 줄이 그 파일에 정확히 1회 있는지 매번 검사한다. 밀려났던 설명은 `iter_tex` 옆 코드 주석으로 되돌렸다 — 순회 순서를 뒤집지 말라는 경고가 필요한 자리는 문서가 아니라 그 줄 위다 |
| `spec/formats/tex-embedded-mips.json` 이 옛 범위 라벨을 담고 있다 | `measure_embedded_mips.py` 는 코퍼스를 스스로 열거하지 않고 **`measure_tex_deep.iter_tex()` 를 그대로 쓴다.** 이번 변경으로 그 생성기의 범위 라벨 `"워크샵 scene.pkg + 설치 assets"` 가 틀린 문장이 돼 `assets/projects` 로 고쳤다(생성기 문자열만). 정본은 아직 옛 문장(전수 4,991)을 6곳에 담고 있어 **지금 생성기와 갈려 있다** — 이 컨테이너엔 워크샵 코퍼스가 없어 새 값을 측정할 수 없고, 측정 못 한 수치를 손으로 적지 않는다는 원칙을 지켰다. 코퍼스 있는 환경에서 한 번 재생성하면 닫힌다. 그때 들어올 델타는 설치 `projects/` 129건을 그 스크립트로 실측해 생성기 주석에 미리 적어 뒀다 (total 4,991→5,120 · encodedTotal +2 · levelOK/halvingOK +6 · rawPkgs +81 … **전부 증가, 축소 없음**) |
