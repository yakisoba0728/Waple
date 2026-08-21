# 색 · HDR · 톤매핑 파이프라인 복원

**조사일 2026-08-21 · WE 2.8.42 `wallpaper64.exe`(imagebase `0x140000000`)**
**대상: 씬이 픽셀이 되어 스왑체인에 실릴 때까지의 색 공간 · 렌더타깃 포맷 · 톤 곡선 · 그레이딩**

- 바이너리: `/root/.claude/uploads/.../440072bd-wallpaper64.exe`
- 셰이더 평문: `assets/shaders/` **137 파일**(`.frag` 59 · `.vert` 59 · `.h` 14 · `.geom` 4 · `.json` 1).
  동봉 사본 `Sources/WapleRender/Resources/WEAssets/shaders/` 와 설치본이 **파일 목록·내용 전건 동일**
- 씬 코퍼스: 동봉 172 + 설치본 186 = **358** (`{scene,gifscene}.json`)

관련 문서(중복 대신 참조): `docs/re/scene-postprocessing.md`(블룸 파이프라인·씬 키 전표),
`docs/re/volumetric-light.md`(볼류메트릭), `docs/re/tex-format.md`(`.tex` 컨테이너),
`spec/engine/render-pass.json`(패스 순서), `spec/engine/render-state.json`(백버퍼).
이 문서는 그것들이 **비워 둔 색 공간 축**을 채우고, 그 과정에서 **네 곳을 반증**한다(§0).

---

## 0. 결론

| # | 항목 | 판정 |
| --- | --- | --- |
| 1 | 톤매핑 연산자 | **없다.** 137 셰이더에 ACES/Reinhard/Uncharted2/filmic/노출/휘도적응 식별자가 **0건**. 바이너리 문자열도 `tonemap`·`gamma`·`exposure` **0건**(§3·§4) |
| 2 | 자동노출 | **없다.** 히스토그램·평균휘도 리덕션 패스·적응 상수가 전무(§4) |
| 3 | 감마/sRGB 변환 지점 | 137 파일 중 **5 파일 6 지점**. 그중 **런타임(wallpaper64.exe)이 실제로 로드하는 것은 3 파일 4 지점**이고 **전부 `hdr:true` 경로 전용**이다(§2) |
| 4 | 하드웨어 sRGB | **어디에도 없다.** 포맷 enum→DXGI 사상 28 arm 중 `_SRGB` 값 0건, 스왑체인 `R8G8B8A8_UNORM`(28), RTV 오버라이드 없음(§1) |
| 5 | **`spec/engine/render-state.json` `backbuffer.swapchainFormat`** | **반증 · 값 확정.** 종전 *"`B8G8R8A8_UNORM`(87) 로 추정 · notMeasured"* → 실측 **`DXGI_FORMAT_R8G8B8A8_UNORM`(28)**. `DXGI_SWAP_CHAIN_DESC` 를 채우는 자리는 바이너리 전체에 **하나뿐**이다(`0x140008127`–`0x140008172`, §1.2) |
| 6 | **`scene-postprocessing.md` §4 "에디터 = 역방향(linear→sRGB)"** | **반증.** `combine_hdr_editor.frag:9` 의 함수 이름은 `srgb()` 지만 **본문은 `lin()` 과 바이트 단위로 같은 sRGB→linear 디코드**다. 이름만 보고 방향을 뒤집었다(§2.3) |
| 7 | **Waple 의 "WE 는 sRGB-뷰 스왑체인이라 상쇄되는 쌍"** | **전제 반증.** sRGB 뷰도, sRGB 스왑체인도 없다. `lin()` 을 상쇄할 하드웨어 인코드가 존재하지 않는다. 다만 *결론*(`lin()` 미이식)은 골든 실측이 따로 받치고 있어 **근거만 갈아 끼우면 된다**(§2.6·§9 W-20) |
| 8 | **`volumetric-light.md` §6.3 "sRGB/감마 변환 지점이 0개"** | **범위 안에서 참, 일반화하면 거짓.** 그 문장이 다룬 대상(Waple 볼류메트릭 오프스크린 → PNG)에서는 정확하다. WE 전체로 넓히면 `hdr:true` 경로에 디코드 **3지점** + 인코드 **1지점**이 있다(§2.4·§2.5) |
| 9 | 블룸 탭 규약(최근 Waple 수정) | **재검증 통과.** 다운샘플 `1<<i`(`0x14018374a`), 업샘플 `2<<(i-1)`(`0x140183856`), BICUBIC = 가장 깊은 두 단(`0x140183810`), `bloomhdrstrength` 기본 **2.0**(`0x1401870c2`) — 넷 다 Waple 현행과 일치(§5) |
| 10 | 컬러 그레이딩 | 있다. **32×32×32 RGBA8 3D LUT** + HSV 밝기/대비/채도/색상. **씬 키가 아니라 앱(월페이퍼) 설정** `wec_*`/`wcc_*` 다(§6) |
| 11 | 합성 순서 | 씬(+볼류메트릭) → 블룸 → **감마 디코드(HDR 한정)** → 그레이딩 → 페이드. **감마가 그레이딩보다 앞**이다(§7) |
| 12 | 도달 | `hdr:true` 는 358씬 중 **4씬**(비-프리뷰 24씬 중 **2씬**). 즉 감마 논쟁이 화면에 닿는 표본이 애초에 4/358 이다(§8) |

---

## 1. 렌더 타깃 포맷 체인

### 1.1 포맷 enum → DXGI 사상 — `sub_1400d2a20` 전표

렌더타깃 생성자 `sub_1400d2c60` 이 컬러/뎁스 두 인자를 각각 `sub_1400d2a20` 에 넣어
DXGI 값으로 바꿔 `[rt+0x90]`(컬러)·`[rt+0x94]`(뎁스)에 적는다
(`0x1400d2d71`·`0x1400d2d81` → `0x1400d2d78`·`0x1400d2d8d`).

`sub_1400d2a20` 은 `cmp ecx, 0x1b / ja default` + 점프테이블(`0x1400d2aa4`, 28엔트리) 하나다.

| enum | DXGI | 이름 | 쓰이는 곳 |
|---:|---:|---|---|
| 0·1·2·3·5·0x15 | 28 | `R8G8B8A8_UNORM` | **LDR 컬러 타깃 전부**(enum `1`) |
| 4 | 77 | `BC3_UNORM` | `.tex` DXT5 |
| 6 | 74 | `BC2_UNORM` | `.tex` DXT3 |
| 7 | 71 | `BC1_UNORM` | `.tex` DXT1 |
| 8 | 49 | `R8G8_UNORM` | `.tex` RG88 |
| 9 | 61 | `R8_UNORM` | `.tex` R8 |
| 0x0a | 34 | `R16G16_FLOAT` | — |
| 0x0b | 54 | `R16_FLOAT` | — |
| 0x0c | 98 | `BC7_UNORM` | — |
| 0x0d | 24 | `R10G10B10A2_UNORM` | — |
| **0x0e·0x0f** | **10** | **`R16G16B16A16_FLOAT`** | **HDR 컬러 타깃 전부**(enum `0xf`) |
| 0x10 | 41 | `R32_FLOAT` | — |
| 0x11·0x12 | 11 | `R16G16B16A16_UNORM` | — |
| 0x13·0x14 | 13 | `R16G16B16A16_SNORM` | — |
| 0x16 | 55 | `D16_UNORM` | 뎁스 |
| 0x17·0x19 | 39 | `R32_TYPELESS` | 뎁스(볼류메트릭) |
| 0x18 | 40 | `D32_FLOAT` | 뎁스(백버퍼·MSAA) |
| 0x1a | 0 | `UNKNOWN` + 전용 플래그 | `cmp edi,0x1a / sete [rt+0x58]`(`0x1400d2cf3`·`0x1400d2d0f`) — 의미 **[미해결]** |
| 0x1b | 0 | `UNKNOWN` = **없음** | 컬러 없는 뎁스 타깃 / 뎁스 없는 컬러 타깃 |
| ≥0x1c | 28 | `R8G8B8A8_UNORM` | 기본 arm(`0x1400d2a9e`) |

> **28 arm 중 `_SRGB` DXGI 값(29·72·75·78·91·93·99)은 0건이다.** 즉 **엔진은 sRGB 텍스처 뷰를
> 만들 수단 자체가 없다**. `Sources/WapleRender/SceneRendererResources.swift:1604-1605` 가 이미
> 같은 결론을 적어 두었다 — 이번 재측정은 그 문장을 확인만 했다.

### 1.2 스왑체인 — `spec/engine/render-state.json` 의 `notMeasured` 를 닫는다

`DXGI_SWAP_CHAIN_DESC` 를 채우고 `IDXGIFactory::CreateSwapChain`(vtbl `+0x50`)을 부르는 자리는
**바이너리 전체에 하나뿐**이다. (전수 판정법: "필드에 즉시값 `0x20`(=`DXGI_USAGE_RENDER_TARGET_OUTPUT`)을
쓰는 스토어 중, **같은 베이스에서 0x14 바이트 앞**에 또 다른 즉시값 스토어가 있는 것" — 레거시
`DXGI_SWAP_CHAIN_DESC` 의 `BufferDesc.Format`(+0x10) → `BufferUsage`(+0x24) 간격이 정확히 0x14 다.
`.pdata` 로 잡은 전 함수를 훑어 **1건**이 나왔다. `DESC1`(간격 0x10)로도 훑었고 진짜 후보는 0건이다.)

```
0x140008127  xorps  xmm0, xmm0
0x14000812a  mov    dword [rbp-0x50], r13d     ; BufferDesc.Width  = 0  (자동)
0x140008142  movups [rbp-0x4c], xmm0           ; Height/RefreshRate/Format 0으로
0x140008146  mov    dword [rbp-0x40], 0x1c     ; BufferDesc.Format = 28  = R8G8B8A8_UNORM
0x14000814d  movups [rbp-0x3c], xmm0           ; ScanlineOrdering/Scaling = 0
0x140008163  mov    dword [rbp-0x34], 1        ; SampleDesc.Count  = 1
0x140008151  mov    dword [rbp-0x2c], 0x20     ; BufferUsage = RENDER_TARGET_OUTPUT
0x140008134  mov    dword [rbp-0x28], 1        ; BufferCount = 1
0x140008158  mov    qword [rbp-0x20], rdi      ; OutputWindow = HWND
0x14000815c  mov    dword [rbp-0x18], 1        ; Windowed = TRUE
                                               ; SwapEffect = 0 (DISCARD)
0x140008172  call   qword [rax+0x50]           ; IDXGIFactory::CreateSwapChain
```
팩토리는 **`IDXGIFactory1`** 이다(IID `0x140474248`, `GetParent` 로 얻어 `0x1400080e3` 에서 인용).

**리사이즈도 포맷을 바꾸지 않는다** — `ResizeBuffers`(vtbl `+0x68`)는 두 호출부 모두
`NewFormat = 0`(`DXGI_FORMAT_UNKNOWN` = 유지)로 부른다(`0x14009983c`→`0x140099844`,
`0x14011115d`→`0x140111165`).

IID 전수 스캔(있음/없음):

| IID | 결과 |
| --- | --- |
| `IDXGIFactory1` | **있다** `0x140474248` |
| `IDXGIFactory2` | 있다 `0x140477f00` |
| `IDXGIOutput6` | **있다** `0x14048a798` — HDR **감지** 전용(§1.5) |
| `ID3D11Texture2D` | 있다 `0x140477ef0` |
| `IDXGISwapChain` / `1` / `2` / **`3`** / **`4`** | **전부 없다** |

→ `IDXGISwapChain3::SetColorSpace1` 을 부를 수 없다. **HDR10/scRGB 출력 경로는 존재하지 않는다.**
(`render-state.json` 의 `noSRGBViewNoHDROutput`(확정)과 정합. 이 문서가 더한 것은 `swapchainFormat` 의 **값**이다.)

### 1.3 씬 타깃 · "스냅샷" 규약

`spec/engine/render-pass.json` 의 `fullFrameBufferIsSnapshot`(확정)이 규약을 이미 적었다.
이번에 **vtable 슬롯의 D3D 호출까지** 짚었다.

| RT vtable(`0x140486768`) 슬롯 | 함수 | 실제 호출 |
| --- | --- | --- |
| `+0x08` | `0x1400d3310` | `[rt+0x60]` 있으면 `ID3D11DeviceContext::ResolveSubresource`(ctx vtbl `+0x1c8`), 없으면 `CopyResource`(`+0x178`) — **현재 화면을 이 RT 로 캡처** |
| `+0x10` | `0x1400d33b0` | `ResolveSubresource(dst = RT스택 top 또는 기본 RT, src = this, format = **목적지**의 `[rt+0x90]`)` |
| `+0x48` | `0x1400d3920` | 이 RT 를 현재 타깃으로 바인드 |
| `+0x20` | `0x1400d3430` | `GenerateMips` |

씬 자체는 `_rt_FullFrameBufferMultiSampled`(`[composite+0x3100]`)가 있으면 그것으로,
없으면 **현재 타깃(=백버퍼)** 으로 그린다(`0x140183563`–`0x140183582`). 드로우가 끝나면
스택을 pop 하고 MSAA RT 를 되-리졸브한다(`0x1401835bb`–`0x1401835fb`).

### 1.4 렌더타깃 표 — 생성 인자 전건

전부 `sub_1401aadb0(mgr, w, h, divisor, name, colorFmt, depthFmt, flags, flags2)` 다
(시그니처는 `volumetric-light.md` §2.2 가 확정했다). 컬러 포맷 선택은 한 자리에서 갈린다:

```
0x14017f310  r14d = [composite+0x128]
0x14017f317  edi  = 1            ; LDR → enum 1  = R8G8B8A8_UNORM
0x14017f323  ecx  = 0xf          ; HDR → enum 0xf = R16G16B16A16_FLOAT
0x14017f328  r14d >>= 13 ; r14b &= 1        ; bit13 = hdr
0x14017f33d  cmovne edi, ecx
```

| RT | 슬롯 | 스케일 | 컬러 enum | 뎁스 enum | 생성 VA | 조건 |
|---|---|---|---|---|---|---|
| `_rt_FullFrameBuffer` | `0x3098` | 1 | `hdr ? 0xf : 1` | `[flagsbit0 ? 0x1a : 0x16]`(`lea eax,[rax*4+0x16]` @`0x14017f591`) | `0x14017f5ac` | 항상 |
| `_rt_4FrameBuffer` | `0x30a0` | 4 | 〃 | `0x1b`(없음) | `0x14017f5f9` | **LDR 만** |
| `_rt_8FrameBuffer` | `0x30a8` | 8 | 〃 | `0x1b` | `0x14017f63d` | **LDR 만** |
| `_rt_Bloom` | `0x30b0` | 8 | 〃 | `0x1b` | `0x14017f681` | **LDR 만** |
| `_rt_{2<<i}FrameBuffer` | `0x30b8+8i` | `2<<i`, 최대 8단 | 〃(=`0xf`) | `0x1b` | `0x14017f4c3` | **HDR 만** |
| `_rt_Reflection` | `0x3090` | 1 | `1` | `[rcx*4+0x16]` | `0x140181c65` | 씬 flags bit0 |
| `_rt_MipMappedFrameBuffer` | `0x30f8` | 1 | `hdr ? 0xf : 1` | `0x1b` | `0x140181cf8` | 씬 flags bit11 |
| `_rt_FullFrameBufferMultiSampled` | `0x3100` | 1 | `hdr ? 0xf : 1` | `0x18`(D32_FLOAT) | `0x140181e2a` | `[composite+0x1b8] != 0` |
| 백버퍼 기본 RT | `[core+0x20]` | 1 | `0x1b`(외부 텍스처 래핑) | `0x18` | `0x14011122f` | 항상 |

`hdr ? 0xf : 1` 상수 `0xf` 는 `0x140181c92` 의 `mov r15d, 0xf`, HDR 판정은 `0x140181c04`
(`ebx = [composite+0x128] >> 13 & 1`)다.

> **[미해결 A]** HDR 씬에서 **MSAA 타깃이 없으면**(`[composite+0x1b8] == 0`) 씬은 8비트 백버퍼에
> 그려지고, fp16 `_rt_FullFrameBuffer` 는 그 8비트 화면을 `CopyResource`/`ResolveSubresource` 로
> 받게 된다 — D3D11 의 포맷 요건과 어긋난다. 되-리졸브(`+0x10`)도 목적지 포맷(백버퍼 28)을 쓴다.
> 세 갈래 중 무엇이 맞는지 정적으로 못 갈랐다: (a) `[composite+0x1b8]` 이 HDR 에서 항상 켜진다,
> (b) 백버퍼 기본 RT 의 `[rt+0x90]` 이 나중에 실제 텍스처 포맷으로 덮인다, (c) 프레임 전체를 감싸는
> 오프스크린 타깃이 따로 있다. `[composite+0x1b8]` 은 비트마스크(`0x10`·`0x20`·`0x40`·`0x80`·`0x100`
> 를 `or` 로 세우는 자리가 `0x14010e0e6`–`0x14010e7ec` 에 있다)인데 비트 의미를 특정하지 못했다.
> **이 문서의 다른 결론은 이 항목에 의존하지 않는다**(포맷 값·감마·톤커브·블룸은 전부 독립 측정).

### 1.5 HDR 디스플레이 감지 — `g_RenderVar0` 의 출처 (`scene-postprocessing.md` §8-2 를 닫는다)

종전 문서가 *"디바이스 vtable `+0x158` 질의, 함수 이름 미상"* 으로 남긴 자리다.

- 디바이스 vtable = **`0x140485b90`**(ctor `0x140098ea0` 이 `[this] = 0x140485b90`, `[this+0x70] = D3D 코어`).
- 슬롯 `+0x158` = `sub_14009b790` — **7바이트짜리 게터**다:

```
0x14009b790  mov r8, [rcx+0x70]
0x14009b794  mov eax, [r8+0x40] ; [rdx+0] = g_RenderVar0.x
0x14009b79a  mov eax, [r8+0x44] ; [rdx+4] = g_RenderVar0.y
```

두 float 를 채우는 자리는 `sub_14012ac60`(디스플레이 열거)다:

```
QueryInterface(output, IID_IDXGIOutput6 @0x14048a798)          ; 0x14012aec6
GetDesc1(vtbl+0xd8)                                            ; 0x14012af29
if (desc.Monitor != target)              → skip                ; 0x14012af37
if (desc.ColorSpace != 12) → skip        ; 12 = RGB_FULL_G2084_NONE_P2020(HDR10)   0x14012af44
maxLum  = max(desc.MaxLuminance, 80.0)   ; [rbp+0x18c], 80.0 @0x1404928e8          0x14012af5b
sdrRef  = max(80.0, min(200.0, maxLum))  ; 200.0 @0x140492904                      0x14012b5ba
[core+0x40] = sdrRef        / 80.0       ; g_RenderVar0.x                          0x14012b5d9
[core+0x44] = (maxLum-sdrRef)/ 80.0      ; g_RenderVar0.y                          0x14012b5df
```

즉 `g_RenderVar0 = (clamp(maxNits,80,200)/80, (maxNits − clamp(maxNits,80,200))/80)` 이고,
`combine_hdr.frag:31` 의 `hdrFactors = .y·smoothstep(1,5,luma) + .x` 와 정확히 정합한다.
**모니터가 HDR10 이 아니면 이 블록이 통째로 건너뛰어진다**(`0x14012af4b` → `0x14012b5e7`).

> **[미해결 B]** HDR10 이 아닐 때 `[core+0x40]/[+0x44]` 의 **초기값**을 못 짚었다. `combine_hdr.frag:43`
> (`DISPLAYHDR` 미적용 분기)도 `* g_RenderVar0.x` 를 곱하므로 이 값이 0 이면 HDR 씬이 검게 나온다 —
> 실제로 그렇지 않으니 **1.0 일 것**이지만, 초기화 지점을 인용할 수 없어 추정으로 남긴다.

---

## 2. 감마 / sRGB — 셰이더 평문 전수

### 2.1 grep 정량 (137 파일)

`assets/shaders/` 전 파일(하위 `HLSL/` 7 · `base/` 2 · `editor/` 4 포함)에 대해:

| 패턴 | 히트 파일 수 | 비고 |
| --- | ---: | --- |
| `pow(` | 23 | 대부분 스페큘러/프레넬 지수. **전이함수는 아래 5건뿐** |
| `2.2` | **1** | `downsample_quarter_linear.frag:13` |
| `0.4545` · `0.45` | **0** | — |
| `srgb` (대소문자 무시) | 4 | 7행 — 그중 3행은 chilliant URL 주석 |
| `gamma` (대소문자 무시) | 3 | **전부 같은 URL 주석 한 줄**. 코드 식별자 0건 |
| `toLinear`·`linearTo`·`linearize` | **0** | — |
| `2.4` · `1.055` · `12.92` · `0.04045` · `0.055` | 4 | sRGB 전이함수 상수 (7행) |
| `0.0031308` | **0** | 정석 인코드의 무릎점 — **없다** |

**전이함수를 담은 파일은 5개, 적용 지점은 6개다.** 전부 나열한다.

### 2.2 전이함수 5파일 전문

**(1) `combine_hdr.frag` — 디코드 2지점 (`:32`, `:43`)**
```glsl
// Proper gamma conversion http://chilliant.blogspot.com/2012/08/srgb-approximations-for-hlsl.html
vec3 lin(vec3 v) {
    vec3 c = step(0.04045, v);
    return c * (pow((v + 0.055) / 1.055, CAST3(2.4))) + (1.0 - c) * (v / 12.92);
}
...
#if DISPLAYHDR == 1
    albedo = saturate(albedo);  albedo += bloom1;
    float hdrFactors = g_RenderVar0.y * smoothstep(1.0, 5.0, dot(vec3(0.299,0.587,0.114), albedo)) + g_RenderVar0.x;
    gl_FragColor = vec4(lin(max(CAST3(0.0), albedo)) * hdrFactors, 1.0);      // :32
#else
  #if LINEAR == 1
    gl_FragColor = vec4(saturate(albedo), 1.0);                               // :41  — 콤보 미로드(§2.4)
  #else
    gl_FragColor = vec4(saturate(lin(albedo)) * g_RenderVar0.x, 1.0);         // :43
  #endif
#endif
```

**(2) `passthroughsrgb.frag` — 디코드 1지점 (`:15`)** — `lin()` 본문이 (1)과 **문자 단위로 동일**
```glsl
albedo.rgb = lin(albedo.rgb);
```

**(3) `combine_hdr_editor.frag` — 디코드 1지점 (`:18`), 이름만 `srgb()`**
```glsl
vec3 srgb(vec3 v) {
    vec3 c = step(0.04045, v);
    return c * (pow((v + 0.055) / 1.055, 2.4)) + (1 - c) * (v / 12.92);   // ← lin() 과 같은 식
}
gl_FragColor = vec4(srgb(saturate(albedo)), 1.0);
```

**(4) `passthroughlinear.frag` — 유일한 인코드 (`:9`,`:14`)**
```glsl
vec3 _srgb(vec3 v) { return max(1.055 * pow(v, 0.416666667) - 0.055, 0.0); }   // 0.4166… = 1/2.4
albedo.rgb = _srgb(albedo.rgb / g_HDRParams.x);
```
정석 인코드의 **선형 발끝 구간(`v ≤ 0.0031308 → 12.92v`)이 없다** — 순수 거듭제곱 근사다.

**(5) `downsample_quarter_linear.frag:13` — 감마 2.2 인코드**
```glsl
gl_FragColor = vec4(pow(albedo, 1/2.2), 1.0);
```

### 2.3 `combine_hdr_editor.frag` 의 `srgb()` 는 **디코드다** — `scene-postprocessing.md` §4 정정

종전 §4 표의 마지막에서 두 번째 행:

> `에디터 | srgb(saturate(albedo)) — **역방향**(linear→sRGB) | combine_hdr_editor.frag:18`

**틀렸다.** `:11-12` 의 본문은 `step(0.04045, v)` · `pow((v+0.055)/1.055, 2.4)` · `v/12.92` —
`combine_hdr.frag:14-15` 의 `lin()` 과 같은 sRGB **EOTF(디코드)** 다. 방향을 결정하는 것은
`2.4`(디코드)냐 `1/2.4`(인코드)냐이고, 무릎점 `0.04045`(디코드) 대 `0.0031308`(인코드)다.
이 파일은 `2.4` 와 `0.04045` 를 쓴다. **함수 이름을 근거로 방향을 적은 것이 사고 원인**이다.

같은 함정을 파일 이름에서도 조심해야 한다 — 명명 규약은 **`passthrough<입력공간>`** 이다:
`passthroughsrgb` = sRGB 입력을 읽어 선형 출력, `passthroughlinear` = 선형 입력을 읽어 sRGB 출력.

### 2.4 어느 것이 실제로 로드되는가 — 머티리얼 문자열 전수

`.frag` 가 존재한다고 실행되는 것이 아니다. `wallpaper64.exe` 는 머티리얼을 **경로 문자열**로 연다.

| 머티리얼 | 셰이더 | 바이너리 문자열 | 로드 지점 |
| --- | --- | --- | --- |
| `combine_hdr_upsample.json` | `combine_hdr`(콤보 없음) | 있다 `0x14048e0e0` | `0x14017fb55` — HDR & 블룸 |
| `combine_dhdr_upsample.json` | `combine_hdr` + `DISPLAYHDR=1` | 있다 `0x14048e000` | `0x14017fb49` — HDR & bit14(HDR10 모니터) |
| `combine_srgb.json` | `passthroughsrgb` | 있다 `0x14048e070` | `0x14017fb88` — HDR & 블룸 off |
| `combine_video_hdr.json` | `combine_video_hdr` | 있다 `0x14048e098` | `0x14017fb94` — HDR & flags bit16 |
| `combine_ldr.json` | `combine`(감마 없음) | 있다 `0x14048e0c0` | `0x14017fb5c` — LDR & 블룸 |
| `downsample_quarter_linear.json` | `downsample_quarter_linear` | 있다 `0x14048e280` | `0x140113368` — §2.7 |
| `backbufferpassthrough.json` | `passthroughlinear` | 있다 `0x140485b40` | `0x14009bb6b` — `_rt_editor_backbuffer_resolve` 를 다루는 함수 |
| **`combine_hdr_upsample_linear.json`** (`LINEAR=1`) | `combine_hdr` | **없다** | — |
| **`combine_hdr_upsample_dbg.json`** (`COMBINEDBG=1`) | `combine_hdr` | **없다** | — |
| **`combine_hdr_editor.json`** | `combine_hdr_editor` | **없다** | — |

머티리얼 선택 코드(`0x14017fb45`–`0x14017fb9f`):
```
al   = (flags[0x128] bit13) && (flags[0x128] bit14)   ; 0x14017fb0d–0x14017fb24  (HDR && HDR10 디스플레이)
r13b = flags[0x128] bit13                             ; = hdr
슬롯 0x3150 = al ? combine_dhdr_upsample : (r13b ? combine_hdr_upsample : combine_ldr)
슬롯 0x3158 = (r13b) ? ((flags[0x128] bit16) ? combine_video_hdr : combine_srgb) : (로드 안 함)
```

**따라서 런타임이 실제로 감마 변환을 하는 곳은 3파일 4지점이고, 전부 `hdr:true` 뒤에 있다:**

| # | 지점 | 방향 | 게이트 |
|---:|---|---|---|
| 1 | `combine_hdr.frag:32` | sRGB→linear | `hdr && bloom && HDR10모니터` |
| 2 | `combine_hdr.frag:43` | sRGB→linear | `hdr && bloom` (HDR10 아님) |
| 3 | `passthroughsrgb.frag:15` | sRGB→linear | `hdr && !bloom` |
| 4 | `downsample_quarter_linear.frag:13` | linear→감마2.2 | `hdr && 플러그인 CPU 버퍼 경로`(§2.7) |

**LDR 경로에는 감마 변환이 한 지점도 없다.** `combine.frag:13-15` 는 순수 가산이고,
`bloom:false` 인 LDR 씬은 최종 패스 자체가 없다(씬이 이미 타깃에 그려져 있다).

### 2.5 `volumetric-light.md` §6.3 "sRGB/감마 변환 지점이 0개" 검증

그 표의 배제 근거는 **Waple 쪽 파이프라인**(`VolumetricLightPass.makeDescriptor` 의 `bgra8Unorm`,
`writeFramePNG` 의 원바이트, `OffscreenCapture.png` 의 `.deviceRGB`)에 대한 것이다.
그 범위에서는 **참**이다 — 재확인했다:

- `VolumetricLightPass.swift` 파이프라인 포맷에 `_srgb` 변종이 없다.
- 문제의 픽스처는 `hdr` 키가 없어 `hdrActive == false` → `finalizeScene` 이 무연산으로 빠진다.
- 즉 그 경로에 **디코드도 인코드도 없다**.

**일반화하면 거짓이다.** WE 전체에는 §2.4 의 4지점이 있고, 그중 1·2·3 은 최종 프레젠트 직전에
걸린다. §6.3 문장은 "이 픽스처 경로에" 라는 한정을 달아야 안전하다. 실제로 §6.3 이
검증하려던 4.5배 격차의 원인은 감마가 아니라 레이 재구성이었으므로 **결론에는 영향이 없다**.

### 2.6 그래서 `lin()` 은 무엇과 짝인가 — **짝이 없다**

Waple 은 네 자리에서 같은 문장을 적고 있다:
`HDRBloomPass.swift:39,301-302` · `HDRPostPass.swift:9` · `SceneRendererFinalizer.swift:17-18`
— *"WE 는 sRGB-뷰 스왑체인이라 하드웨어 재인코드와 상쇄되는 쌍"*.

**전제가 틀렸다.** §1.1(포맷 사상에 `_SRGB` 0건) + §1.2(스왑체인 `R8G8B8A8_UNORM`) +
`render-state.json` `noSRGBViewNoHDROutput`(RTV `pDesc=NULL`) 셋이 같은 방향을 가리킨다:
**상쇄해 줄 하드웨어 인코드는 존재하지 않는다.**

그런데 Waple 이 인용한 골든 실측은 반대 방향을 가리킨다:
*"EOTF 이식 p50 0.047 vs WE 골든 0.18, 클램프 p50 ≈0.19 — 골든 정합"*.
즉 **관측된 WE 화면은 디코드가 안 걸린 모습**이다. 정적 측정과 골든이 갈린다.

가장 그럴듯한 화해는 §2.4 다: **`lin()` 은 `hdr:true` 에서만 실행된다.** 골든 씬이 LDR 이었다면
`combine.frag`(디코드 없음)를 탄 것이고, 두 관측이 모두 옳다. 이 문서는 골든 픽스처의 `hdr` 여부를
확인할 수 없어 **[미해결 C]** 로 남긴다.

**어느 쪽이든 코드 변경은 필요 없다** — Waple 의 현행 동작(디코드 미이식)은 LDR 358−4 씬에서
정확하다. 바꿔야 하는 것은 **주석의 근거**다(§9 W-20).

### 2.7 `downsample_quarter_linear` — 유일한 인코드가 걸리는 자리

```
0x14011334e  eax = [composite+0x128]
0x14011335c  eax >>= 0xd ; test al,1
0x140113361  je  → downsample_quarter.json          ; LDR: 변환 없음
0x140113363  cmp qword [composite+0x70], 0
0x140113368  rdx = "materials/util/downsample_quarter_linear.json"
0x14011336f  je  → 그대로 사용                       ; 소스 오버라이드가 없을 때만
0x140113371  rdx = "materials/util/downsample_quarter.json"
```
소스는 `_rt_FullFrameBuffer`(`[composite+0x70]` 오버라이드가 없으면), 목적지는
`_rt_pluginCpuBuffer1/2`(`[composite+0x31d8]`/`0x31e0`) 로 가는 CPU 리드백 경로다
(`0x140113304`–`0x140113442`). **화면 경로가 아니다.**

의미는 분명하다: **LDR 프레임버퍼는 그대로 넘기고 HDR 프레임버퍼만 `pow(1/2.2)` 로 눌러 넘긴다.**
두 경우의 CPU 측 바이트가 같은 눈금이 되려면 **HDR 프레임버퍼 내용이 선형**이어야 한다.
이것은 §2.4 의 1·2·3(HDR 프레임버퍼를 sRGB 로 보고 디코드한다)과 **정면으로 충돌한다.**

두 사실 중 어느 쪽이 WE 의 의도인지 정적으로 못 갈랐다 — **[미해결 D]**. 관측 가능한 것만 적으면:
같은 `_rt_FullFrameBuffer` 를 한 소비자는 sRGB 로 보고 디코드하고 다른 소비자는 선형으로 보고
인코드한다. 둘 중 하나는 WE 자신의 버그일 수 있다.

### 2.8 바이너리 쪽 정량

| 검색어 | ASCII | UTF-16LE |
| --- | ---: | ---: |
| `gamma` / `Gamma` / `GAMMA` | **0** | 0 |
| `tonemap` / `Tonemap` / `ToneMap` | **0** | 0 |
| `exposure` / `Exposure` | **0** | 0 |
| `SRGB` | 0 | 0 |
| `sRGB` | 1 | 0 — **PNG 청크 FourCC** (`cmp ecx, 0x42475273` @`0x1400b8817`, 인접 문자열 `"#png: bad chunk"` @`0x140479a38`) |
| `srgb` | 1 | 0 — `materials/util/combine_srgb.json` 경로의 일부 |
| `linear` | 1 | 0 — `materials/util/downsample_quarter_linear.json` 의 일부 |

즉 **감마·톤맵·노출을 이름으로 가진 코드 경로가 바이너리에 없다.**

---

## 3. 톤매핑 연산자 — 없다

137 셰이더 전수:

| 검색어 | 히트 |
| --- | ---: |
| `ACES` · `Reinhard` · `Uncharted` · `filmic` · `Hable` (대소문자 각각) | **0** |
| `tonemap` · `ToneMap` · `toneMap` | **0** |
| `whitepoint` | **0** |
| `aces` | 1 — `HLSL/dx11playlisttransition.vert:87` 주석 `"Move pieaces up and down"` (오타 `pieaces`) |

최종 픽셀 연산 전건(§2.4 의 게이트와 짝):

| 경로 | 씬 수(358) | 최종 식 |
| --- | ---: | --- |
| LDR · 블룸 on | 10 − (hdr 4 중 겹침 4) = **6** | `scene + bloom` (UNORM 타깃이 클램프) |
| LDR · 블룸 off | **348** | 최종 패스 없음 |
| HDR · 블룸 on · SDR 모니터 | **4** | `saturate(lin(scene + 4탭bloom)) * g_RenderVar0.x` |
| HDR · 블룸 on · HDR10 모니터 | 〃 | `lin(max(0, saturate(scene)+bloom)) * (g_RenderVar0.y·smoothstep(1,5,luma) + g_RenderVar0.x)` |
| HDR · 블룸 off | **0** | `lin(scene)` |
| 비디오 HDR(flags bit16) | 0 | `saturate(rgb / (2·g_HDRParams.y)) · (2·g_HDRParams.y)` — 순수 클리핑 |

**어깨(shoulder)도 발끝(toe)도 없다.** `saturate` 는 곡선이 아니라 클램프다.
`combine_hdr.frag:31` 의 `smoothstep(1,5,luma)` 는 톤 곡선이 아니라 **HDR10 부스트 램프**다
(휘도 1~5 구간에서 헤드룸 배수를 0→1 로 켠다). SDR 경로에는 실리지 않는다.

---

## 4. 노출 · 자동노출 — 없다

- 히스토그램/평균휘도 리덕션 패스가 없다: `materials/util/` 에 그런 머티리얼이 없고,
  셰이더에 `luminance`·`histogram`·`adapt` 식별자가 0건.
- 적응 속도 상수(`exp(-dt/tau)` 류)를 후보 자리에서 찾지 못했다.
- 밝기 축은 **정적 값 두 개**뿐이다:
  1. `g_RenderVar0.x` — 디스플레이 질의 결과(§1.5). 프레임마다 변하지 않는다.
  2. `wec_brs`(앱 설정 밝기, §6) — HSV `value` 배수. 씬 내용에 반응하지 않는다.

Waple 의 `HDRPostPass.exposure`(기본 1.0)는 **WE 에 대응물이 없는 Waple 확장 노브**다.
기본값이 항등이라 무해하지만 정본으로 오인하면 안 된다(§9 W-27).

---

## 5. 블룸 — 최근 Waple 수정 재검증

`scene-postprocessing.md` §3 이 이미 파이프라인 전체를 적었다. 여기서는 **최근 커밋이 고친 네 가지를
독립으로 다시 재어** 맞는지 본다. **넷 다 맞다.**

### 5.1 탭 반경 — 디스어셈 재판독

기저(`0x14018362b`–`0x1401836ba`):
```
xmm1 = [composite+0x84] (W)   xmm0 = [composite+0x88] (H)
xmm6 = 1.0  (0x140492704)     xmm7 = -1.0 (0x1404929b8)
xmm8 = xmm6 / W   xmm6 = xmm6 / H   xmm9 = xmm7 / W   xmm7 = xmm7 / H
[composite+0xb8..0xc4] = (1/W, 1/H, -1/W, -1/H) = g_RenderVar0
```

| 패스 | 배율 코드 | 배율 | 소스 | 소스 텍셀 기준 반경 |
|---|---|---|---|---|
| 추출 i=0 | 없음(기저 그대로) `0x1401836a0` | 1 | `_rt_FullFrameBuffer`(W×H) | **±1.0** |
| 다운샘플 i | `mov eax,1 ; shl eax,cl`(cl=i) `0x14018374a`–`0x14018375c` | `1<<i` | level[i−1] (W/2^i) | **±1.0** |
| 업샘플 i→i−1 | `mov eax,2 ; shl eax,cl`(cl=i−1) `0x140183856`–`0x14018386b` | `2<<(i−1)` | level[i] (W/2^(i+1)) | **±0.5** |

소스/목적지 슬롯도 다시 짚었다(피라미드 배열은 `[composite+0x30b8]` 부터라 `level[k]` = `0x30b8 + 8k`):

| 패스 | 목적지 바인드(`RT vtbl+0x48`) | 소스 SRV(`[mat+0xd0]`) |
|---|---|---|
| 다운샘플 i | `0x140183723` → `[composite + i*8 + 0x30b8]` = **level[i]** | `0x14018378f` → `[composite + i*8 + 0x30b0]` = **level[i−1]** |
| 업샘플 i→i−1 | `0x14018382a` → `[composite + i*8 + 0x30b0]` = **level[i−1]** | `0x14018389e` → `[composite + i*8 + 0x30b8]` = **level[i]** |


**Waple 대조**: `HDRBloomPyramidPass.downsampleTapScale(level) = 1 << level`(`:166`),
`upsampleTapScale(sourceLevel) = 2 << (sourceLevel-1)`(`:171`),
`tapOffsetUV(scale, baseWidth, baseHeight) = scale / 풀프레임버퍼크기`(`:159-161`) — **전건 일치**.

### 5.2 BICUBIC 선택

```
0x140183810  eax = [composite+0x3108]      ; N = 실효 레벨 수
0x140183816  ecx = 0x31a8                  ; hdr_upsample_cubic 슬롯
0x14018381b  eax -= 2
0x140183820  cmp ebp, eax                  ; ebp = 업샘플의 소스 레벨 (N-1 → 1)
0x140183822  cmovl rcx, r15                ; r15 = 0x31a0 = hdr_upsample
```
→ **소스 레벨 ≥ N−2 인 가장 깊은 두 단만 큐빅.**
Waple `upsampleUsesBicubic(sourceLevel, levelCount) = sourceLevel >= levelCount - 2`(`:183-185`) — 일치.

큐빅 커널 자체(`hdr_downsample.frag:8-51`)도 Waple `weCubicWeights`/`weBicubic`(`:390-416`)과
줄 단위로 대응한다. `texSize = 0.5 / g_RenderVar0.xy`(`:22`) 항등식이 **업샘플에서만** 성립한다는
`scene-postprocessing.md` §3.5 의 경고도 그대로 유효하다(BICUBIC 콤보는 `hdr_upsample_cubic`
하나에만 걸려 있다 — `hdr_upsample_cubic.json` 의 `"combos": {"UPSAMPLE":1,"BICUBIC":1}`).

### 5.3 강도 정규화와 기본값

씬 생성자 `0x140186c90`–`0x1401872ba` 의 해당 스토어를 바이트로 다시 읽었다:

| 오프셋 | 키 | 즉시값 | float | VA |
|---|---|---|---:|---|
| `0x3bc` | `bloomstrength` | `0x40000000` | **2.0** | `0x1401870ac` |
| `0x3c0` | `bloomthreshold` | `0x3f266666` | **0.6499999761581421** | `0x1401870b7` |
| `0x3c4` | **`bloomhdrstrength`** | `0x40000000` | **2.0** | `0x1401870c2` |
| `0x3c8` | `bloomhdrthreshold` | `0x3f800000` | **1.0** | `0x1401870cd` |
| `0x3cc` | `bloomhdrfeather` | `0x3dcccccd` | **0.10000000149011612** | `0x1401870d8` |
| `0x3d0` | `bloomhdrscatter` | `0x3fcf3b64` | **1.61899995803833** | `0x1401870e3` |
| `0x3d4` | `bloomhdriterations` | `8` | 8 | `0x1401870ee` |

**`bloomhdrstrength` 기본값 2.0 확정** — Waple 이 최근 `0 → 2` 로 고친 것이 맞다
(`SceneDocument.swift:1172`, 파스 `:3314`). `bloomhdrthreshold` 1.0 도 맞다(`:1173`, `:3315`).

정규화식 `g_BloomStrength = bloomhdrstrength / (powf(bloomhdrscatter, max(N,2)−2) + 1)`
(`0x14017f847`–`0x14017f88f`, `powf = 0x14041e350`, `+1.0` 상수 `0x140492704`)도
Waple `normalizedStrength`(`:137-140`)와 일치.

`g_BloomBlendParams` 패킹 `(T, T−K, 2K, 0.25/(K+1e-5))`, `K = T·feather`
(`0x14017f8bc`–`0x14017f906`, `0.25`=`0x14049268c`, `1e-5`=`0x1404925ec`)도
Waple `blendParams`(`:191-195`)와 일치(Waple 만 `max(K,0)` 방어 추가 — WE 는 음수 feather 를 막지 않는다).

### 5.4 셰이더 평문 대조

`hdr_downsample.frag` 한 파일이 콤보로 3역할을 한다:
```glsl
albedo = 4탭(v_TexCoord ± g_RenderVar0.xy / .zy / .xw / .zw)
#if UPSAMPLE  albedo *= 0.25 * g_BloomScatter;   #else  albedo *= 0.25;  #endif
#if BLOOM                                        // 소프트니 임계
  albedo = max(0, albedo);  brightness = max(albedo.r, albedo.g, albedo.b);
  soft = clamp(brightness - P.y, 0, P.z);  soft = soft*soft*P.w;
  contribution = max(soft, brightness - P.x) / max(brightness, 1e-5);
  albedo *= contribution * g_BloomStrength * g_BloomTint;
#endif
```
`hdr_upsample.json` / `hdr_upsample_cubic.json` 의 `"blending": "additive"` 가 누적을 만든다.
**가우시안 패스는 어디에도 없다** — 전 단계가 4탭 박스다.

### 5.5 재검증 총평

| 항목 | WE 실측 | Waple 현행 | 판정 |
| --- | --- | --- | --- |
| 다운샘플 배율 `1<<i` | `0x14018374a` | `:166` | **일치** |
| 업샘플 배율 `2<<(i-1)` | `0x140183856` | `:171` | **일치** |
| 탭 기저 = 풀 프레임버퍼 `1/W` | `0x14018367c`–`0x1401836ba` | `:159` | **일치** |
| BICUBIC = 깊은 두 단 | `0x140183810`–`0x140183822` | `:183` | **일치** |
| 큐빅 커널 | `hdr_downsample.frag:8-51` | `:376-416` | **일치** |
| `bloomhdrstrength` 기본 2.0 | `0x1401870c2` | `SceneDocument:1172,3314` | **일치** |
| `bloomhdrthreshold` 기본 1.0 | `0x1401870cd` | `:1173,3315` | **일치** |
| 강도 정규화 | `0x14017f88f` | `:137` | **일치** |
| soft-knee 패킹 | `0x14017f8bc` | `:191` | **일치** |
| 레벨 0 = 1/2 | `0x14017f376` | `Finalizer:56-57` | **일치** |

**반증할 것이 없었다.** 최근 수정은 전건 옳다.

---

## 6. 컬러 그레이딩 — `ccsimple`

### 6.1 무엇이 켜는가 — **씬 키가 아니다**

`ccsimple` 머티리얼(`[composite+0x3188]`)을 세우는 함수는 `0x140181f30`–`0x140182f84` 이고,
읽는 키는 전부 **앱(월페이퍼) 설정** JSON 이다(`{"value": …}` 래핑, 헬퍼 `sub_140086de0`):

| 키 | 저장 | 변환 | 파스 VA |
| --- | --- | --- | --- |
| `wec_e` | `[obj+0x3110]` (bool) | — | `0x140182336` |
| `wec_con` (대비) | `[obj+0x3114]` | `value / 50.0` (`50.0`=`0x1404928cc`) | `0x140182396` |
| `wec_brs` (밝기) | `[obj+0x3118]` | `value / 50.0` | `0x140182409` |
| `wec_sa` (채도) | `[obj+0x311c]` | `value / 50.0` | `0x140182474` |
| `wec_hue` | `[obj+0x3120]` | `value / 100.0 − 0.5` (`100.0`=`0x1404928f8`, `0.5`=`0x1404926c0`) | `0x1401824df` |
| `wcc_v` (LUT 이름) | `[obj+0x3128]` (string) | — | `0x140182560` |
| `wcc_amt` (LUT 강도) | `[obj+0x3148]` | `value / 100.0` | `0x1401825d7` |

> 설치본 `ui/dist/scripts/scripts.js` 는 `wec_sat`(끝에 `t`)라는 이름을 지우는 목록에만 갖고 있는데,
> 바이너리가 읽는 키는 **`wec_sa`(6자)** 다(`0x140488754`, 길이 인자 `r8 = 0x14048875a`).
> 어느 쪽이 실사용인지는 확인 못 했다 — 화면 영향은 채도 슬라이더 하나다. **[미해결 E]**

### 6.2 콤보 게이트 — 패스가 아예 없어질 수 있다

```
0x140182638  al = (wec_e != 0) && (con != 1.0 || brs != 1.0 || sa != 1.0 || hue != 0.0)   → COL 필요
0x140182698  cl = ([obj+0x3138] != 0 /*LUT 이름 비어있지 않음*/) && (wcc_amt > 0.0)        → LUT 필요
0x1401826ef  if (!al && !cl)  [composite+0x3188] = 0     ; ccsimple 패스 자체를 만들지 않는다
0x140182969  else  콤보 = { "COL": 1, "LUT": cl }        ; 문자열 "COL"=0x14048e2e4 · "LUT"=0x14048e2e0
```
**`"HDR"` 콤보 문자열은 바이너리에 없다** — `ccsimple.frag:30-33` 의 `#if HDR` 오버브라이트 보정
(`lutColor = lut(albedo) * (1 + dot(max(0, albedo−1), 1))`)은 **wallpaper64.exe 에서 컴파일되지 않는다.**

### 6.3 유니폼 패킹 (`0x140182d85`–`0x140182ea3`)

```
params.x = powf([0x3118] /*brs*/, 2.0)     ; 2.0 = 0x1404927a8
params.y = powf([0x3114] /*con*/, 0.5)     ; 0.5 = 0x1404926c0
params.z = powf([0x311c] /*sa */, 0.5)
params.w =      [0x3120] /*hue*/           ; 가공 없음
setMaterialParam(ccsimple, "params", &params, count=4)      ; 0x140182df9
```
셰이더가 쓰는 순서(`ccsimple.frag:19-27`):
```glsl
albedo.rgb = mix(0.5, albedo.rgb, g_Params.y);   // 대비 — 0.5 중심
vec3 hsv = rgb2hsv(albedo.xyz);
hsv.z *= g_Params.x;    // 밝기(value)
hsv.y *= g_Params.z;    // 채도
hsv.x += g_Params.w;    // 색상 시프트
albedo.rgb = hsv2rgb(hsv);
```
**대비가 HSV 변환 밖(RGB 공간)에서 먼저 걸리고, 나머지 셋이 HSV 안에서 걸린다.** 순서가 결과를 바꾼다.

기본 슬라이더 50/50/50/50 → `con=brs=sa=1.0`, `hue=0.0` → `params=(1,1,1,0)` = 항등.

### 6.4 LUT

```
0x140182e19  경로 = "lut/" + [obj+0x3128]                 ; "lut/" = 0x14048e334
0x140182e53  tex  = loadTexture(경로, srgbFlag=1)         ; sub_14014cf90, r8b=1
0x140182e64  [ccsimple매트+0xd8] = tex                     ; g_Texture1 슬롯
0x140182e8e  setMaterialParam(ccsimple, "lutparams", [obj+0x3148], count=1)
```

동봉 `materials/lut/*.tex` **28건 전건 실측**(TEXI 헤더 직접 파스):

| 필드 | 값(28/28 동일) |
| --- | --- |
| `format` | `0` = RGBA8888 |
| `flags` | `0x42` = `0x2`(ClampUVs) + `0x40`(Slice3D) |
| `texWidth × texHeight` | 32 × 32 |
| `texDepth` | **32** |
| `imageWidth × imageHeight` | 1024 × 32 (32슬라이스 가로 스트립) |

→ **32×32×32 RGBA8 3D LUT, 선형 보간(NoInterpolation 비트 꺼짐), 경계 클램프.**

적용 식(`ccsimple.frag:29-39`, `LUT` 콤보만):
```glsl
vec3 albedoFiltered = texSample3D(g_Texture1, albedo.rgb);
albedo.rgb = mix(albedo.rgb, albedoFiltered, g_LutParams);
```
**샘플 좌표 보정이 없다.** 흔한 `c·(N−1)/N + 0.5/N` 인셋을 쓰지 않고 `albedo.rgb` 를 그대로 넣고
**CLAMP 샘플러에 양 끝을 맡긴다**. 그래서 실효 매핑은 `texel = clamp(c·32 − 0.5, 0, 31)` 이고,
`c ∈ [0, 1/64]` 과 `c ∈ [63/64, 1]` 구간이 각각 첫/끝 슬라이스에 눌린다. 이식할 때 인셋을 넣으면 어긋난다.

적용 순서: **COL(대비·HSV) → LUT** 이며, 둘 다 `ccsimple` **한 패스** 안에서 이 순서로 일어난다.

---

## 7. 최종 합성 순서 — 확정

`spec/engine/render-pass.json` 의 `order`/`ccsimpleAfterBloom`/`fullFrameBufferIsSnapshot`(전부 확정)에
이번에 **감마·그레이딩·페이드의 상대 위치**를 붙인다. `Composite::frame`(`0x14017fa70`–`0x1401816cc`)
한 함수 안에서 전부 결정된다.

```
 1. 반사                drawScene(obj, 1) → _rt_Reflection                     (씬 flags bit0)
 2. 씬                  drawScene(obj, 0) → MSAA RT 있으면 그것, 없으면 현재 타깃  0x140183550
      └ 볼류메트릭 5패스는 이 안에서 씬 컬러에 additive 로 합쳐진다(volumetric-light.md §2.4)
 3. MSAA resolve        RT vtbl+0x10 → ResolveSubresource                       0x1401835fb
 4. 화면 캡처            RT vtbl+0x08 → _rt_FullFrameBuffer                      0x140180a82
 5. 밉맵 프레임버퍼       캡처 + GenerateMips → _rt_MipMappedFrameBuffer          0x140180a8f (씬 flags bit11)
 6. 블룸 체인            drawBloomChain                                          0x140180ac5
      LDR: FFB →quarter_bloom→ 1/4 →eighth_blur_v(X 13탭)→ 1/8 →blur_h_bloom(Y 13탭)→ _rt_Bloom
      HDR: FFB →hdr_downsample_bloom→ L0 →hdr_downsample→ L1..Ln-1 →hdr_upsample(_cubic) additive→ L0
 7. 합성 + **감마 디코드**  슬롯 0x3150                                            0x140180b45–0x140180b62
      LDR : combine.frag        = scene + bloom            (감마 없음)
      HDR : combine_hdr.frag    = saturate(lin(scene+bloom)) * g_RenderVar0.x
 7.1 블룸 off & HDR      슬롯 0x3158 = passthroughsrgb = lin(scene)              0x140180ba9–0x140180bc6
      (블룸 off & LDR 은 패스 자체가 없다)
 8. **컬러 그레이딩**      슬롯 0x3188 = ccsimple (COL → LUT)                      0x140180bd2–0x140180c06
      직전 0x140180bdc 에서 화면을 _rt_FullFrameBuffer 로 다시 캡처
 9. **페이드**            슬롯 0x3180 = materials/util/fade.json (translucent)     0x140180c96–0x140180cc0
      게이트 0x140180c1a: test byte [scene+0xe0], 4 = camerafade(bit2)
```

**요약: 볼류메트릭 → 블룸 → 감마 → 그레이딩 → 페이드.**
감마(디코드)가 **그레이딩보다 앞**이라는 것이 이 절의 핵심이다 — HDR 씬에서 LUT 은 **디코드된 값**을 본다.
그리고 **그레이딩 뒤에 되-인코드가 없다.**

### 7.1 `fade` = `camerafade` 소비 지점 — `scene-postprocessing.md` §8-4 를 닫는다

종전 §8-4 는 *"`camerafade`(bit2, 195씬 저작)의 소비 지점을 못 찾았다"* 로 남아 있었다. 찾았다.

- 머티리얼 로드: `0x140181bce` `lea rdx, "materials/util/fade.json"` → `[composite+0x3180]`(`0x140181bda`)
- 게이트: `0x140180c1a` `test byte [scene+0xe0], 4` (bit2 = `camerafade`)
- 값 계산(`0x140180c23`–`0x140180c8c`): 씬의 오브젝트 배열 `[scene+0x310..0x318]` 에서
  인덱스 `[scene+0xe4]` 의 `+0x18` 필드와 `[scene+0xec]` 로 구간을 만들고, `0.5`(`0x1404926c0`)를
  기준으로 앞/뒤 절반을 나눠 `alpha = 1 − 2·t` 꼴로 램프를 만든다.
- 드로우: `alpha > 0` 이고 `[composite+0x3180] != 0` 일 때만. 알파는 `[composite+0x130]` 에 실린다(`0x140180ca2`).
- 셰이더(`fade.frag:9`): `gl_FragColor = vec4(color * 0.7, g_Alpha)` — 틴트에 **0.7 이 곱해진다**.
  머티리얼 `usershadervalues: { "schemecolor": "tint" }`, `tint` 기본 `(0.315, 0.135, 0.1125)`.

즉 `camerafade` 는 **후처리 체인의 마지막 전면 패스**이고, 씬 페이드-인/아웃(플레이리스트 전환이 아니라
씬 자체 타임라인)에 쓰인다. 코퍼스가 전건 기본값(true)이라 A/B 로는 안 드러난다는 §8-4 의 진단도 맞다.

---

## 8. 동봉 + 설치본 358 씬 도달 실측

파스: 엄격 JSON → 실패 시 `//` 주석·트레일링 콤마 제거 재시도. **358/358 성공, 실패 0.**
"프리뷰"는 경로에 `preview` 가 들어간 씬(이펙트/프리셋/파티클 엘리먼트 미리보기) = **334**,
나머지 **24** 가 실제 벽지/에디터 씬이다.

### 8.1 키별 저작·생략

`저작 수(기본값과 같음 / 다름) · 생략 수` 형식.

| 키 | 기본값 | 비-프리뷰 24 | 프리뷰 334 | 합계 저작 |
| --- | --- | --- | --- | ---: |
| `hdr` | false | 5 (3/**2**) · 생략 19 | 172 (170/**2**) · 생략 162 | 177 |
| `bloom` | **true** | 24 (8/**16**) · 생략 0 | 334 (2/**332**) · 생략 0 | 358 |
| `bloomstrength` | 2.0 | 7 (4/**3**) · 생략 17 | 334 (334/0) · 생략 0 | 341 |
| `bloomthreshold` | 0.65 | 7 (4/**3**) · 생략 17 | 334 (334/0) · 생략 0 | 341 |
| `bloomhdrstrength` | 2.0 | 7 (3/**4**) · 생략 17 | 172 (172/0) · 생략 162 | 179 |
| `bloomhdrthreshold` | 1.0 | 5 (4/**1**) · 생략 19 | 172 (172/0) · 생략 162 | 177 |
| `bloomhdrfeather` | 0.1 | 5 (4/**1**) · 생략 19 | 172 (172/0) · 생략 162 | 177 |
| `bloomhdrscatter` | 1.619 | 5 (3/**2**) · 생략 19 | 172 (172/0) · 생략 162 | 177 |
| `bloomhdriterations` | 8 | 3 (3/0) · 생략 21 | 170 (170/0) · 생략 164 | 173 |
| `bloomtint` | (1,1,1) | 0 · 생략 24 | 154 (154/**0**) · 생략 180 | 154 |

읽는 법 몇 가지:

- **`bloomtint` 는 저작 154건이 전부 정확히 `"1.00000 1.00000 1.00000"`** = 기본값이다.
  코퍼스에 틴트를 실제로 쓰는 씬이 **0건**이다.
- `bloomhdriterations` 는 저작 173건 전부 `8` — 기본값 외 값이 **0건**이다.
- `bloom` 은 358/358 이 명시 저작하고 그중 348이 `false` 다. **엔진 기본은 `true`** 라
  코퍼스만 보면 절대 드러나지 않는다(`scene-postprocessing.md` §2.2 W-4 와 같은 이야기).

### 8.2 `hdr:true` 씬 전건 (4/358)

| 범위 | 경로 | bloom | 특기 |
| --- | --- | --- | --- |
| 동봉 | `presets/lightning/previewthunderbolt/scene.json` | true | 프리뷰 |
| 설치본 | `assets/presets/lightning/previewthunderbolt/scene.json` | true | 위와 동일 파일 |
| 설치본 | `projects/defaultprojects/razer_bedroom/scene.json` | true | **비-프리뷰** |
| 설치본 | `projects/defaultprojects/shimmering_particles/scene.json` | true | **비-프리뷰** |

**동봉 172 씬 중 `hdr:true` 는 previewthunderbolt 1건뿐이고, 비-프리뷰 `hdr:true` 는 0건이다.**
따라서 §2 의 감마 논쟁·§1.5 의 `g_RenderVar0`·`combine_hdr` 경로는 **동봉 코퍼스만으로는
화면이 전혀 안 바뀐다.**

### 8.3 비-프리뷰 24씬 전표

`-` = 생략. `DYN` = `{"script":…}` 또는 `{"user":…}` 동적 바인딩.

| 씬 | hdr | bloom | bStr | bThr | hStr | hThr | hFeath | hScat | hIter |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `assets/scenes/gifs` | - | F | - | - | - | - | - | - | - |
| `assets/scenes/modeleditor` | F | T | 2 | 0.65 | 2 | 1 | 0.1 | 1.619 | 8 |
| `assets/scenes/particleeditor` | - | F | - | - | - | - | - | - | - |
| `assets/scenes/particleeditor3dscale` | - | F | - | - | - | - | - | - | - |
| `assets/scenes/videoplayer` | - | F | - | - | **0** | - | - | - | - |
| `defaultprojects/arsenal` | - | T | - | - | - | - | - | - | - |
| `defaultprojects/beach` | - | F | - | - | - | - | - | - | - |
| `defaultprojects/deep_space` | - | F | - | - | - | - | - | - | - |
| `defaultprojects/demon_core` | - | T | - | - | - | - | - | - | - |
| `defaultprojects/dino_run` | F | F | 2 | 0.65 | 2 | 1 | 0.1 | 1.619 | 8 |
| `defaultprojects/dna_fragment` | - | T | - | - | - | - | - | - | - |
| `defaultprojects/eagleflag` | - | F | - | - | - | - | - | - | - |
| `defaultprojects/neon_sunset` | - | T | **0.5** | **0.36** | - | - | - | - | - |
| `defaultprojects/razer_bedroom` | **T** | T | **1** | **1** | **2.5** | 1 | 0.1 | **1.62** | - |
| `defaultprojects/razer_vortex` | - | F | 2 | 0.65 | - | - | - | - | - |
| `defaultprojects/retro` | - | F | - | - | - | - | - | - | - |
| `defaultprojects/shimmering_particles` | **T** | T | **DYN** | **0.36** | **DYN** | **0.7** | **0** | **1.13** | - |
| `templates/flag` | - | F | - | - | - | - | - | - | - |
| `templates/gif` | - | F | - | - | - | - | - | - | - |
| `scenes/gifs`(동봉) | - | F | - | - | - | - | - | - | - |
| `scenes/modeleditor`(동봉) | F | T | 2 | 0.65 | 2 | 1 | 0.1 | 1.619 | 8 |
| `scenes/particleeditor`(동봉) | - | F | - | - | - | - | - | - | - |
| `scenes/particleeditor3dscale`(동봉) | - | F | - | - | - | - | - | - | - |
| `scenes/videoplayer`(동봉) | - | F | - | - | **0** | - | - | - | - |

읽을 만한 것:

- **`videoplayer` 는 `bloomhdrstrength: 0` 을 명시한다**(동봉·설치본 양쪽). `hdr` 를 생략하므로
  현 상태로는 도달하지 않지만, **기본값을 0 으로 두던 종전 Waple 이 우연히 맞던 유일한 씬**이다.
- `shimmering_particles` 는 `bloomstrength`·`bloomhdrstrength` 를 **동적 바인딩**으로 저작한다
  (`{"script": "…thisObject.bloomstrength = changedUserProperties.glow * 0.5…"}`,
  `{"user":"glow","value":2.0}`). 정적 기본값만 반영하는 파서는 이 씬에서 값이 다르다.
- `bloomhdrscatter` 비기본 저작은 코퍼스 전체에서 **2건**뿐이고 둘 다 비-프리뷰다:
  `1.62`(razer_bedroom) · `1.13`(shimmering_particles). 프리뷰 172건은 전부 기본값이다
  (저작 문자열은 `1.619` 171건 · `1.61899995803833` 4건 두 표기로 갈리지만 float 로는 같은 값이다).
- `bloomhdrthreshold` 비기본은 **1건**(`0.7`, shimmering_particles), `bloomhdrfeather` 비기본도
  **1건**(`0`, 같은 씬).

---

## 9. Waple 갭 — `Sources/WapleRender/` 대조

`scene-postprocessing.md` §7 의 W-1~W-24 와 번호를 잇는다(W-25 부터가 신규).

| # | 항목 | WE | Waple | 등급 | 착지 지점 |
|---|---|---|---|---|---|
| **W-1** | HDR 피라미드 다운샘플 탭 반경 | `1<<i` = ±1 소스 텍셀 | `downsampleTapScale(:166)` = `1<<i` | **해소 확인** | 조치 없음 |
| **W-2** | 업샘플 BICUBIC | 깊은 두 단 | `upsampleUsesBicubic(:183)` | **해소 확인** | 조치 없음 |
| **W-3** | `bloomhdrstrength` 기본 | 2.0 | `SceneDocument:1172,3314` = 2 | **해소 확인** | 조치 없음 |
| **W-20** | HDR 최종 `lin()` | `combine_hdr.frag:43` · `passthroughsrgb.frag:15` | 미이식 | **근거 정정 필요** | 아래 |
| **W-21** | `g_RenderVar0` 출처 | `clamp(maxNits,80,200)/80` 등 (§1.5) | 없음(암묵 1.0) | **확정 · 저위험** | 아래 |
| **W-25** | 컬러 그레이딩(`ccsimple`) | COL+LUT 패스 | **패스 없음** | **확정 · 범위 밖** | 아래 |
| **W-26** | `camerafade` 패스 | `fade.json`, `color*0.7` | **패스 없음** | **확정 · 저우선** | 아래 |
| **W-27** | `HDRPostPass.exposure` | **대응물 없음** | Waple 확장 노브(기본 1.0) | **문서화만** | 주석 한 줄 |
| **W-28** | HDR 씬 `_rt_FullFrameBuffer` 포맷 | `R16G16B16A16_FLOAT` | `rgba16Float` (`accPixelFormat`) | **일치** | 조치 없음 |
| **W-29** | LDR 씬 컬러 포맷 | `R8G8B8A8_UNORM`(비-sRGB) | `bgra8Unorm`(비-sRGB) | **채널 순서만 다름** | 조치 없음 |
| **W-30** | 스왑체인/프레젠트 포맷 | `R8G8B8A8_UNORM`, 비-sRGB | `view.colorPixelFormat = .bgra8Unorm`(`SceneRenderer:1563`) | **일치(비-sRGB)** | 조치 없음 |

### W-20 — 고칠 것은 코드가 아니라 근거다

네 자리의 주석이 *"WE 는 sRGB-뷰 스왑체인"* 을 근거로 든다:

- `Sources/WapleRender/HDRBloomPass.swift:39`
- `Sources/WapleRender/HDRBloomPass.swift:301-302`
- `Sources/WapleRender/HDRPostPass.swift:9`
- `Sources/WapleRender/SceneRendererFinalizer.swift:17-18`

**측정으로 반증된다**(§1.1·§1.2). 대신 아래 두 근거로 갈아 끼우면 같은 결론이 선다:

1. **`lin()` 은 `hdr:true` 뒤에만 있다**(§2.4). 358씬 중 354씬은 `combine.frag`(감마 없음) 또는
   패스 없음이므로, Waple 의 LDR 경로는 **디코드가 없는 것이 정확하다**.
2. HDR 경로의 골든 실측(주석이 이미 인용한 p50 0.047 vs 0.18)이 디코드 미적용 쪽을 지지한다.
   그 골든 씬이 `hdr:true` 였는지 확인되면 §2.6 의 [미해결 C] 가 닫히고, `hdr:true` 4씬에 대해서만
   결론이 확정된다.

**권고**: 네 자리의 "sRGB-뷰 스왑체인" 문구를 지우고
*"WE 의 `lin()` 은 `hdr:true` 경로에만 있고(§2.4), 스왑체인은 비-sRGB `R8G8B8A8_UNORM` 이다
(`docs/re/tonemapping.md` §1.2). 미이식 근거는 골든 실측이다"* 로 바꾼다. **코드는 그대로 둔다.**
같은 이유로 `spec/engine/render-state.json` `backbuffer.swapchainFormat` 을
`추정 → 확정 · R8G8B8A8_UNORM(28) · va 0x140008146` 으로 올려야 한다.

### W-21 — `g_RenderVar0.x` (저위험)

SDR 모니터에서는 §1.5 의 블록이 실행되지 않으므로 값이 1.0 일 가능성이 높다([미해결 B]).
**Waple 이 macOS 에서 HDR10 디스플레이를 다루지 않는 한 조치 불필요**하다.
다룬다면 착지 지점은 `HDRBloomPyramidPass.hdrBloomCombine`(`:490` 부근)의 마지막 곱과
`HDRPostPass.hdrpost_f` 이고, 값은 `clamp(maxNits,80,200)/80` 이다.

### W-25 — 컬러 그레이딩

Waple 에는 `ccsimple` 대응 패스가 없다. **다만 씬 키가 아니라 앱 설정이므로 "WE 재현" 갭이라기보다
"Waple 이 아직 노출하지 않은 사용자 기능"** 이다. 부품은 이미 있다:

- `WapleCore/GLSLTranslator.swift:15,1637-1638,1802` — `texSample3D` → `texture3d<float>`,
  샘플러는 `smp`(clamp) 고정. **§6.4 의 CLAMP 규약과 일치**한다.
- `WapleCore/TexImage.swift:133` — `texDepth` 파스(3D LUT 28건 인지).
- `WapleRender/TexDecoder.swift:23-26` — **volume 텍스처를 2D 한 장으로 내놓는다**(32×1024).
  3D 로 샘플하려면 여기서 `MTLTextureType.type3D` 로 올려야 한다.

착지 순서: ① `TexDecoder` 에 3D 업로드 경로 → ② `ccsimple` 대응 패스를 `SceneRendererFinalizer`
의 블룸 **뒤**·페이드 **앞**에 삽입 → ③ 설정 표면(`wec_*`/`wcc_*` 대응)은 Waple 자체 규약으로.
수식은 §6.3(대비 RGB 선행, HSV 3항)과 §6.4(인셋 없음)를 그대로 따른다.

### W-26 — `camerafade`

`fade.json` 대응 패스가 없다. 코퍼스가 전건 기본값이라 화면 영향이 관측되지 않지만,
씬 타임라인 페이드가 있는 워크샵 씬에서 첫 프레임 팝이 난다. 착지 지점은
`SceneRendererFinalizer.finalizeScene` 끝(그레이딩 뒤). 식은 `vec4(tint*0.7, alpha)` translucent.

### 일치 확인만 한 것

| 항목 | 근거 쌍 |
| --- | --- |
| 포맷 사상에 `_SRGB` 0건 | `sub_1400d2a20` 28 arm ↔ `SceneRendererResources.swift:1604-1605` |
| HDR 씬 = `rgba16Float`, 그 외 `bgra8Unorm` | `0x14017f317`–`0x14017f33d` ↔ `SceneRenderer.swift:721-724` |
| 톤커브 부재 | 셰이더 137 전수 ↔ `HDRPostPass.swift:67-70` (`saturate` 만) |
| 블룸 5항목 | §5.5 표 |
| 3D LUT 경계 클램프 | `flags 0x2`(28/28) ↔ `GLSLTranslator.swift:1802` |

---

## 10. 미해결

| # | 항목 | 남은 것 | 닫는 법 |
|---|---|---|---|
| **A** | HDR 씬에서 MSAA 타깃이 없을 때의 캡처 포맷 | `[composite+0x1b8]` 비트 의미 | `0x14010df40` 의 `or [X+0x1b8], …` 5자리를 설정 UI 키와 짝지어 본다 |
| **B** | SDR 모니터에서 `g_RenderVar0` 초기값 | `[core+0x40]/[+0x44]` 초기화 지점 | `sub_140098ea0` 호출 직전(`0x1401109e7` `mov ecx,0x158` 할당)의 0-초기화 여부 확인 |
| **C** | Waple 골든 픽스처의 `hdr` 여부 | 3299228616 씬 JSON | `Tests/` 픽스처의 `general.hdr` 를 읽으면 즉시 판정 |
| **D** | `_rt_FullFrameBuffer` 는 sRGB 인가 선형인가 | §2.4(디코드)와 §2.7(인코드)이 충돌 | RenderDoc 으로 HDR 씬 1프레임의 `_rt_FullFrameBuffer` 픽셀과 백버퍼 픽셀을 같이 뜬다 |
| **E** | `wec_sa` vs `wec_sat` | UI 가 쓰는 실제 키 | `wallpaperui.exe` 문자열 스캔 |
| **F** | `0x1a` 뎁스 포맷 enum | `[rt+0x58]` 플래그의 소비처 | `0x1400d2d0f` 가 세우는 바이트를 읽는 자리를 역추적 |
| **G** | `combine_hdr.frag` `LINEAR` 콤보 | 로드되지 않는 이유 | 에디터 실행 파일(`wallpaperui.exe`)에 문자열이 있는지 |

**이 문서가 확정으로 적지 않은 것을 다시 못 박는다**: §2.6 의 "WE 화면에 실제로 감마 디코드가
보이는가" 는 **확정하지 못했다**. 확정한 것은 (1) 셰이더 평문에 그 식이 있다, (2) 그 머티리얼이
로드된다, (3) 상쇄해 줄 하드웨어 sRGB 인코드는 없다 — 셋뿐이다.

---

## 부록 A — 재현 절차

### A.1 셰이더 평문 전수 (바이너리 불필요)

```bash
cd /home/user/Waple/Sources/WapleRender/Resources/WEAssets/shaders
find . -type f | wc -l                                   # 137
grep -rniE "tolinear|linearto|lineari[sz]e|delinear" .    # 0건
grep -rnE "2\.4|1\.055|12\.92|0\.04045|0\.0031308" .      # 4파일 7행 (§2.2)
grep -rn  "2\.2" .                                        # downsample_quarter_linear.frag:13 만
for t in ACES Reinhard Uncharted filmic Hable tonemap exposure luminance histogram; do
  echo "$t : $(grep -ril "$t" . | wc -l)"; done           # aces 1건(오타) 외 전부 0
```

### A.2 포맷 enum → DXGI 표

```python
import sys, struct; sys.path.insert(0,'<scratchpad>')
from wpe import pe, DATA
tbl = 0x1400d2aa4; o = pe.va2off(tbl)
for i in range(0x1c):
    tgt = 0x140000000 + struct.unpack_from('<I', DATA, o + i*4)[0]
    b = DATA[pe.va2off(tgt): pe.va2off(tgt)+6]
    print(hex(i), struct.unpack_from('<I', b, 1)[0] if b[0]==0xb8 else 0)
```

### A.3 스왑체인 DESC 전수 (1건임을 보이는 판정)

`.pdata` 로 잡은 전 함수를 캡스톤으로 훑어, `mov dword [base±off], 0x20` 스토어마다
**같은 base 의 `off − 0x14`** 에 다른 즉시값 스토어가 있는지 본다. 유일한 히트가
`0x140008146`(값 28) / `0x140008151`(0x20) 이다. `DESC1` 후보(`off − 0x10`)는 오탐 1건뿐이다.

### A.4 씬 코퍼스 도달 (바이너리 불필요)

```python
import json, glob, os, re, collections
ROOTS = ['/home/user/Waple/Sources/WapleRender/Resources/WEAssets',
         '/home/user/Waple-wallpaper-source/wallpaper_engine']
files = [p for r in ROOTS for pat in ('**/scene.json','**/gifscene.json')
           for p in glob.glob(os.path.join(r, pat), recursive=True)]      # 358
# general 에서 hdr/bloom*/bloomtint 를 꺼내 기본값과 대조 (§8.1 표)
```

### A.5 LUT 치수

```python
import struct, glob
for p in glob.glob('.../materials/lut/*.tex'):
    d = open(p,'rb').read()                       # TEXV0005 / TEXI0001
    fmt, flags, tw, th, iw, ih = struct.unpack_from('<6i', d, 18)
    depth = struct.unpack_from('<i', d, 42)[0] if flags & 0x40 else 1
    # 28/28 → fmt 0, flags 0x42, 32x32, depth 32, image 1024x32
```

---

## 부록 B — 이 문서가 인용한 함수 범위

| 함수(추정 이름) | 범위 | 역할 |
| --- | --- | --- |
| `Dxgi::createSwapChain` | `0x140007e40`–`0x14000826a` | 유일한 `DXGI_SWAP_CHAIN_DESC` 채움 + `CreateSwapChain` |
| `Device::Device` | `0x140098ea0`–`0x140098f00` | 디바이스 래퍼 ctor(vtable `0x140485b90`, `[this+0x70]` = D3D 코어) |
| `Device::getHDRFactors` | `0x14009b790`–`0x14009b7a2` | vtable `+0x158` — `g_RenderVar0.xy` 게터 |
| `Device::createRenderTarget` | `0x14009ada0`–`0x14009ae40` | vtable `+0x70` — `sub_1400d2c60` 으로 포워드 |
| `Format::toDXGI` | `0x1400d2a20`–`0x1400d2aa4` | 포맷 enum → DXGI (테이블 `0x1400d2aa4`) |
| `RenderTarget::RenderTarget` | `0x1400d2c60`–`0x1400d2e00` | 컬러/뎁스 포맷 사상 + 리소스 생성 |
| `RenderTarget::capture` | `0x1400d3310`–`0x1400d33b0` | vtable `+0x08` — Resolve/CopyResource |
| `RenderTarget::resolveToCurrent` | `0x1400d33b0`–`0x1400d3410` | vtable `+0x10` |
| `Renderer::initDevice` | `0x140110630`–`0x140113bc0` | 디바이스/스왑체인/플러그인 CPU 버퍼 초기화 |
| `Display::queryHDR` | `0x14012ac60`–`0x14012b81c` | `IDXGIOutput6::GetDesc1` → `g_RenderVar0` 계산 |
| `Composite::allocateTargets` | `0x14017f1b0`–`0x14017fa6f` | RT 할당 + 컬러 포맷 선택 + 블룸 파라미터 피드 |
| `Composite::frame` | `0x14017fa70`–`0x1401816cc` | 머티리얼 로드 + 합성 순서(§7) |
| `Composite::initTargets2` | `0x140181af0`–`0x140181c40` | `fade` 로드 · Reflection/MipMapped/MSAA RT |
| `Composite::setupColorCorrection` | `0x140181f30`–`0x140182f84` | `wec_*`/`wcc_*` 파스 · `ccsimple` 콤보/유니폼/LUT |
| `Composite::drawScene` | `0x140183550`–`0x140183609` | clear + 씬 + MSAA resolve |
| `Composite::drawBloomChain` | `0x140183610`–`0x140183a61` | LDR 3패스 / HDR 피라미드 |
| `Scene::Scene` | `0x140186c90`–`0x1401872ba` | 전 기본값 기록 |
| `Scene::registerProperties` | `0x140199780`–`0x14019b4d6` | `general` 47키 등록(`hdr` = `0x1401998fd`, flags bit10) |

부동소수 상수: `1.0`=`0x140492704` · `-1.0`=`0x1404929b8` · `0.5`=`0x1404926c0` ·
`0.25`=`0x14049268c` · `2.0`=`0x1404927a8` · `1e-5`=`0x1404925ec` ·
`50.0`=`0x1404928cc` · `80.0`=`0x1404928e8` · `100.0`=`0x1404928f8` · `200.0`=`0x140492904`.
