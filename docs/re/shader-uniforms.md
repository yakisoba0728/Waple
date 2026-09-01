# 셰이더 엔진 유니폼(`g_*`) 전수 census

WE 셰이더가 쓰는 `g_` 접두 심볼 **340개**를 평문에서 전수로 뽑고, 그중 **어느 것이 엔진이
채우는 유니폼이고 어느 것이 자산 저작 관례일 뿐인지**를 wallpaper64.exe 로 판정한 기록이다.
마지막에 Waple 이 무엇을 채우고 무엇을 안 채우는지를 대조한다.

- 바이너리: `/root/.claude/uploads/.../440072bd-wallpaper64.exe` (imagebase `0x140000000`),
  형제 43개(`wallpaper_engine/bin/**`, `wallpaper32.exe`, `wallpaperui.exe`, `launcher.exe`) 포함
- 셰이더 평문: `wallpaper_engine/**`(592 파일) + `Sources/WapleRender/Resources/WEAssets/**`(502 파일)
  = **1,094 파일**(`.frag .vert .geom .h .hlsl` 등). 두 트리는 겹치지만 **설치본에만 있는
  `projects/defaultprojects/**` 커스텀 셰이더**가 이 과제의 핵심 표본이라 합집합으로 센다.
- 씬 코퍼스: `scene.json`/`gifscene.json` + `project.json → file` = **362 씬**(non-preview 28)

관련 정본(중복 서술 대신 참조): `spec/engine/uniforms.json`(이름→VA 스캔),
`spec/engine/uniform-feed.json`(cbuffer 4종·레지스트리 140·`g_BloomBlendParams` 식·
`g_RenderVar0` 피라미드·`g_TextureNResolution` 4성분), `docs/re/playlist-transition.md`
(HLSL `g_bufDynamic` 경로), `docs/re/audio-capture.md`(`g_AudioSpectrum*` 산출),
`docs/re/volumetric-light.md`(`g_RenderVar1..4` 의미), `docs/re/skeleton-animation.md`(`g_Bones`).

이 문서가 새로 채우는 것: **레지스트리 140개의 이름·ID·VA 를 초기화 함수에서 직접 복원**(§1),
**셰이더 평문 340 이름의 3분류 전수표**(§2·§6), **엔진에 없는 238개의 확정**(§2.3),
**Waple 채움/미채움 전수 대조와 우선순위**(§7).

---

## 1. 엔진 유니폼 레지스트리 — 140개 전수

### 1.1 어떻게 얻었는가

정적 이니셜라이저 `sub_140002860`(범위 `0x140002860..0x140004321`, `.pdata` 단편 1개,
`primary()` 로 확인)이 스택에 **140개짜리 배열**을 만든다. 꼬리에서:

```
0x1400042f1  lea r9, [rip + 0x12fb8]   ; 0x1400172b0  (비교자)
0x1400042f8  mov edx, 0x28             ; stride 40바이트
0x1400042fd  mov r8d, 0x8c             ; 원소 140개
0x140004303  lea rcx, [rbp + 0x10]     ; 배열 시작 = rbp+0x10
0x140004307  call 0x140005c10          ; 정렬
```

원소 = `{ std::string name (32B); int32 id (+0x20); pad 4 }`. 엔트리 k 는 `rbp + 0x10 + 0x28*k`.
이름은 세 가지 형태로 들어간다 — 이 셋을 다 잡아야 140/140 이 복원된다:

| 형태 | 개수 | 모양 |
|---|---:|---|
| **SSO 인라인** | 14 | 이름 ≤15바이트라 `mov rax,[rip+X]` → `mov [rbp+off],rax` 로 **바이트가 직접 복사**된다. `lea` 가 없어서 xref 로는 안 잡힌다. `g_Alpha` `g_Color` `g_Color4` `g_Time` `g_Frametime` `g_Daytime` `g_TexelSize` `g_TexelSizeHalf` `g_Screen` `g_ModelMatrix` `g_EyePosition` `g_ViewForward` `g_ViewRight` `g_ViewUp` |
| **ctor 호출** | 121 | `lea rdx,[rip+이름]` + `lea rcx,[rbp+off]` + `call sub_14016f7a0` 또는 `call sub_140017480` |
| **전용 헬퍼** | 5 | `call sub_14016f800 / f850 / f8a0 / f8f0 / f940` — 이름 문자열이 **헬퍼 안에** 있다 |

전용 헬퍼 5개(각각 `g_TextureReductionScale`, `g_LightsColorPremultiplied`,
`g_LDirectional_Direction`, `g_LFeature_ShadowProjectionTransform`,
`g_LFeature_ShadowPointProjectionTransform`)는 초기화 함수만 훑으면 **통째로 빠진다**.

복원 결과: **이름 140개 전부 고유**, **ID 집합 = 정확히 0..139**. 배열 순서와 ID 는 두 곳에서
어긋난다 — 배열[6]=`g_TexelSize`(ID 7), 배열[7]=`g_TexelSizeHalf`(ID 6);
배열[12]=`g_ModelViewProjectionMatrix`(ID 13), 배열[13]=`g_ModelViewProjectionMatrixInverse`(ID 12).
(`spec/engine/uniform-feed.json` 의 `idsByArrayIndex` 가 0..79 만 담고 있던 것을 80..139 까지 채웠다 —
80..83 의 ID 는 `mov dword ptr [rbp+0x1610], 0x50` 처럼 **양수 rbp 변위**의 임시 슬롯에 쓰여
`[rbp-N]`/`[rsp+N]` 만 보던 스캔이 놓치고 있었다.)

### 1.2 전수표 (140행, 절단 없음)

열 설명:
- **타입**: 동봉/설치본 셰이더의 `uniform` 선언에서 확정. `—` = 셰이더에 선언 0건(§1.3).
- **선언파일**: 그 이름을 쓰는 셰이더 파일 수(설치본+동봉 합집합, 1,094 파일 기준).
- **저작레인**: 그중 **built-in `assets/shaders/**` 밖**(= 이펙트/프로젝트 커스텀 셰이더) 파일 수.
  Waple 의 GLSL→MSL 번역 레인이 실제로 보는 건 이 쪽이라 우선순위의 근거가 된다.
- **씬 / np**: 도달 씬 수 / 그중 non-preview 씬 수(§6).
- **Waple**: §7 판정.

| ID | 이름 | 문자열 VA | 타입 | 선언파일 | 저작레인 | 씬 | np | Waple | 대체값 | 네이티브 등가 |
|---:|---|---|---|---:|---:|---:|---:|---|---|---|
| 0 | `g_Alpha` | `0x14048d180` | `float` | 15 | 1 | 13 | 1 | 부분 | 중립 상수 1 폴백 | 컴포지터 `layerTint.a`(출력 후곱) |
| 1 | `g_Color` | `0x14048d178` | `vec3` | 6 | 0 | 12 | 0 | 부분 | 중립 상수 1 폴백 | 컴포지터 `layerTint.rgb` |
| 2 | `g_Color4` | `0x14048d1b0` | `vec4` | 10 | 0 | 106 | 4 | 부분 | 중립 상수 1 폴백 | 컴포지터 `layerTint` |
| 3 | `g_Time` | `0x14048d1a4` | `float` | 190 | 180 | 63 | 19 | 채움 | `eng.timeAndPad.x` | — |
| 4 | `g_Frametime` | `0x14048d198` | `float` | 20 | 20 | 2 | 0 | 채움 | `eng.timeAndPad.w` | — |
| 5 | `g_Daytime` | `0x14048d188` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 6 | `g_TexelSizeHalf` | `0x14048d1e0` | `vec2` | 8 | 2 | 3 | 3 | 채움 | `0.5/eng.targetRes.xy` | — |
| 7 | `g_TexelSize` | `0x14048d1f0` | `vec2` | 19 | 5 | 2 | 2 | 채움 | `1/eng.targetRes.xy` | — |
| 8 | `g_Screen` | `0x14048d1d0` | `vec3` | 18 | 2 | 108 | 4 | 채움 | `float3(texRes[0].xy, w/h)` | — |
| 9 | `g_ModelMatrix` | `0x14048d1c0` | `mat3·mat4` | 45 | 11 | 115 | 11 | 부분 | `float4x4(1)` 항등 | SceneRenderer3D `MeshUniform` |
| 10 | `g_ModelMatrixInverse` | `0x14048d260` | `mat4` | 6 | 0 | 6 | 4 | 부분 | `float4x4(1)` 항등 | — |
| 11 | `g_ViewProjectionMatrix` | `0x14048d248` | `mat4` | 48 | 12 | 115 | 11 | 부분 | `float4x4(1)` 항등 | SceneRenderer3D `MeshUniform` |
| 12 | `g_ModelViewProjectionMatrixInverse` | `0x14048d200` | `mat4` | 2 | 2 | 2 | 0 | 부분 | `float4x4(1)` 항등 | — |
| 13 | `g_ModelViewProjectionMatrix` | `0x14048d228` | `mat4` | 365 | 303 | 145 | 21 | 채움 | `eng.mvp` | — |
| 14 | `g_NormalModelMatrix` | `0x14048d2c8` | `mat3` | 10 | 0 | 108 | 4 | 부분 | `float4x4(1)` 항등 | SceneRenderer3D `MeshUniform` |
| 15 | `g_AltModelMatrix` | `0x14048d2b0` | `mat4` | 8 | 0 | 106 | 4 | 부분 | `float4x4(1)` 항등 | — |
| 16 | `g_AltNormalModelMatrix` | `0x14048d298` | `mat3` | 6 | 0 | 106 | 4 | 부분 | `float4x4(1)` 항등 | — |
| 17 | `g_AltViewProjectionMatrix` | `0x14048d278` | `mat4` | 10 | 0 | 106 | 4 | 부분 | `float4x4(1)` 항등 | — |
| 18 | `g_ViewportViewProjectionMatrices` | `0x14048d350` | `mat4[6]` | 6 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 19 | `g_EffectModelMatrix` | `0x14048d338` | `mat4` | 6 | 4 | 0 | 0 | 부분 | `float4x4(1)` 항등 | — |
| 20 | `g_EffectModelViewProjectionMatrix` | `0x14048d310` | `mat4` | 6 | 4 | 2 | 0 | 채움 | `eng.mvp` | — |
| 21 | `g_EffectModelViewProjectionMatrixInverse` | `0x14048d2e0` | `mat4` | 6 | 6 | 0 | 0 | 부분 | `float4x4(1)` 항등 | — |
| 22 | `g_EffectTextureProjectionMatrix` | `0x14048d3c8` | `mat4` | 4 | 4 | 0 | 0 | 부분 | `float4x4(1)` 항등 | — |
| 23 | `g_EffectTextureProjectionMatrixInverse` | `0x14048d3a0` | `mat4` | 14 | 14 | 2 | 0 | 부분 | `float4x4(1)` 항등 | — |
| 24 | `g_LayerModelMatrix` | `0x14048d388` | `—` | 0 | 0 | 0 | 0 | 부분 | `float4x4(1)` 항등 | — |
| 25 | `g_EyePosition` | `0x14048d378` | `vec3` | 44 | 12 | 116 | 12 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | SceneRenderer3D 카메라 |
| 26 | `g_ViewForward` | `0x14048d420` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 27 | `g_ViewRight` | `0x14048d410` | `vec3` | 9 | 1 | 6 | 4 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 28 | `g_ViewUp` | `0x14048d400` | `vec3` | 9 | 1 | 6 | 4 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 29 | `g_OrientationForward` | `0x14048d3e8` | `vec3` | 6 | 0 | 6 | 4 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 30 | `g_OrientationRight` | `0x14048d460` | `vec3` | 2 | 0 | 6 | 4 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 31 | `g_OrientationUp` | `0x14048d450` | `vec3` | 2 | 0 | 6 | 4 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 32 | `g_Texture0` | `0x14048d440` | `sampler2D·sampler2DComparison` | 505 | 405 | 138 | 22 | 채움 | 텍스처 슬롯 0 직결 | — |
| 33 | `g_Texture1` | `0x14048d430` | `sampler2D·sampler2DBackBuffer·sampler3D` | 290 | 234 | 134 | 22 | 채움 | 텍스처 슬롯 1 직결 | — |
| 34 | `g_Texture2` | `0x14048d4a8` | `sampler2D` | 178 | 154 | 124 | 12 | 채움 | 텍스처 슬롯 2 직결 | — |
| 35 | `g_Texture3` | `0x14048d498` | `sampler2D` | 66 | 42 | 121 | 11 | 채움 | 텍스처 슬롯 3 직결 | — |
| 36 | `g_Texture4` | `0x14048d488` | `sampler2D·sampler2DComparison` | 35 | 15 | 113 | 9 | 채움 | 텍스처 슬롯 4 직결 | — |
| 37 | `g_Texture5` | `0x14048d478` | `sampler2D` | 27 | 7 | 11 | 5 | 채움 | 텍스처 슬롯 5 직결 | — |
| 38 | `g_Texture6` | `0x14048d4e8` | `sampler2D·sampler2DComparison` | 15 | 5 | 5 | 1 | 채움 | 텍스처 슬롯 6 직결 | — |
| 39 | `g_Texture7` | `0x14048d4d8` | `sampler2D` | 14 | 4 | 4 | 0 | 채움 | 텍스처 슬롯 7 직결 | — |
| 40 | `g_Texture8` | `0x14048d4c8` | `sampler2D` | 6 | 0 | 2 | 0 | 채움 | 텍스처 슬롯 8 직결 | — |
| 41 | `g_Texture9` | `0x14048d4b8` | `—` | 0 | 0 | 0 | 0 | 채움 | 텍스처 슬롯 9 직결 | — |
| 42 | `g_Texture0Rotation` | `0x14048d540` | `vec4` | 12 | 0 | 116 | 12 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 43 | `g_Texture1Rotation` | `0x14048d528` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 44 | `g_Texture2Rotation` | `0x14048d510` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 45 | `g_Texture3Rotation` | `0x14048d4f8` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 46 | `g_Texture4Rotation` | `0x14048d5a0` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 47 | `g_Texture5Rotation` | `0x14048d588` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 48 | `g_Texture6Rotation` | `0x14048d570` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 49 | `g_Texture7Rotation` | `0x14048d558` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 50 | `g_Texture8Rotation` | `0x14048d600` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 51 | `g_Texture9Rotation` | `0x14048d5e8` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 52 | `g_Texture0Translation` | `0x14048d5d0` | `vec2` | 12 | 0 | 116 | 12 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 53 | `g_Texture1Translation` | `0x14048d5b8` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 54 | `g_Texture2Translation` | `0x14048d660` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 55 | `g_Texture3Translation` | `0x14048d648` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 56 | `g_Texture4Translation` | `0x14048d630` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 57 | `g_Texture5Translation` | `0x14048d618` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 58 | `g_Texture6Translation` | `0x14048d6c0` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 59 | `g_Texture7Translation` | `0x14048d6a8` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 60 | `g_Texture8Translation` | `0x14048d690` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 61 | `g_Texture9Translation` | `0x14048d678` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 62 | `g_Texture0Resolution` | `0x14048d720` | `vec4` | 230 | 218 | 32 | 6 | 채움 | `eng.texRes[0]` (N≥8 미치환) | — |
| 63 | `g_Texture1Resolution` | `0x14048d708` | `vec4` | 154 | 146 | 38 | 2 | 채움 | `eng.texRes[1]` (N≥8 미치환) | — |
| 64 | `g_Texture2Resolution` | `0x14048d6f0` | `vec4` | 70 | 64 | 107 | 5 | 채움 | `eng.texRes[2]` (N≥8 미치환) | — |
| 65 | `g_Texture3Resolution` | `0x14048d6d8` | `vec4` | 22 | 20 | 10 | 0 | 채움 | `eng.texRes[3]` (N≥8 미치환) | — |
| 66 | `g_Texture4Resolution` | `0x14048d780` | `vec4` | 6 | 6 | 2 | 0 | 채움 | `eng.texRes[4]` (N≥8 미치환) | — |
| 67 | `g_Texture5Resolution` | `0x14048d768` | `vec4` | 16 | 6 | 6 | 0 | 채움 | `eng.texRes[5]` (N≥8 미치환) | — |
| 68 | `g_Texture6Resolution` | `0x14048d750` | `vec4` | 6 | 6 | 2 | 0 | 채움 | `eng.texRes[6]` (N≥8 미치환) | — |
| 69 | `g_Texture7Resolution` | `0x14048d738` | `vec4` | 6 | 6 | 2 | 0 | 채움 | `eng.texRes[7]` (N≥8 미치환) | — |
| 70 | `g_Texture8Resolution` | `0x14048d7d0` | `vec4` | 2 | 0 | 0 | 0 | 미채움 | N≥8 미치환 | — |
| 71 | `g_Texture9Resolution` | `0x14048d7b8` | `—` | 0 | 0 | 0 | 0 | 미채움 | N≥8 미치환 | — |
| 72 | `g_Texture0Texel` | `0x14048d7a8` | `vec4` | 2 | 0 | 0 | 0 | 채움 | `(1/texRes[0].xy, texRes[0].xy)` | — |
| 73 | `g_Texture1Texel` | `0x14048d798` | `vec4` | 4 | 0 | 0 | 0 | 채움 | `(1/texRes[1].xy, texRes[1].xy)` | — |
| 74 | `g_Texture2Texel` | `0x14048d818` | `—` | 0 | 0 | 0 | 0 | 채움 | `(1/texRes[2].xy, texRes[2].xy)` | — |
| 75 | `g_Texture3Texel` | `0x14048d808` | `—` | 0 | 0 | 0 | 0 | 채움 | `(1/texRes[3].xy, texRes[3].xy)` | — |
| 76 | `g_Texture4Texel` | `0x14048d7f8` | `vec4` | 4 | 0 | 6 | 4 | 채움 | `(1/texRes[4].xy, texRes[4].xy)` | — |
| 77 | `g_Texture5Texel` | `0x14048d7e8` | `vec4` | 6 | 0 | 0 | 0 | 채움 | `(1/texRes[5].xy, texRes[5].xy)` | — |
| 78 | `g_Texture6Texel` | `0x14048d858` | `vec4` | 12 | 2 | 4 | 0 | 채움 | `(1/texRes[6].xy, texRes[6].xy)` | — |
| 79 | `g_Texture7Texel` | `0x14048d848` | `—` | 0 | 0 | 0 | 0 | 채움 | `(1/texRes[7].xy, texRes[7].xy)` | — |
| 80 | `g_Texture8Texel` | `0x14048d838` | `—` | 0 | 0 | 0 | 0 | 미채움 | N≥8 미치환 | — |
| 81 | `g_Texture9Texel` | `0x14048d828` | `—` | 0 | 0 | 0 | 0 | 미채움 | N≥8 미치환 | — |
| 82 | `g_Texture0MipMapInfo` | `0x14048d8b0` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 83 | `g_Texture1MipMapInfo` | `0x14048d898` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 84 | `g_Texture2MipMapInfo` | `0x14048d880` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 85 | `g_Texture3MipMapInfo` | `0x14048d868` | `float` | 16 | 0 | 108 | 4 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | SceneRenderer3D 반사 mip |
| 86 | `g_Texture4MipMapInfo` | `0x14048d910` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 87 | `g_Texture5MipMapInfo` | `0x14048d8f8` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 88 | `g_Texture6MipMapInfo` | `0x14048d8e0` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 89 | `g_Texture7MipMapInfo` | `0x14048d8c8` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 90 | `g_Texture8MipMapInfo` | `0x14048d970` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 91 | `g_Texture9MipMapInfo` | `0x14048d958` | `—` | 0 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 92 | `g_TextureReductionScale` | `0x14048d940` | `float` | 4 | 4 | 0 | 0 | 부분 | 중립 상수 1 폴백 | — |
| 93 | `g_LightsColorRadius` | `0x14048d928` | `vec4[4]` | 5 | 1 | 2 | 2 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | Scene3DLighting `lights[]` |
| 94 | `g_LightsColorPremultiplied` | `0x14048d9d0` | `vec4[3]` | 4 | 2 | 104 | 4 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | Scene3DLighting `lights[]` |
| 95 | `g_LightsPosition` | `0x14048d9b8` | `vec3[4]` | 11 | 5 | 106 | 6 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | Scene3DLighting `lights[]` |
| 96 | `g_LightAmbientColor` | `0x14048d9a0` | `vec3` | 25 | 5 | 113 | 9 | 채움 | `float3(1,1,1)` 상수 | — |
| 97 | `g_LightSkylightColor` | `0x14048d988` | `vec3` | 15 | 1 | 7 | 5 | 채움 | `float3(1,1,1)` 상수 | — |
| 98 | `g_AudioSpectrum16Left` | `0x14048da38` | `float[16]` | 11 | 11 | 3 | 3 | 채움 | `audioL` | — |
| 99 | `g_AudioSpectrum16Right` | `0x14048da20` | `float[16]` | 9 | 9 | 2 | 2 | 채움 | `audioR` | — |
| 100 | `g_AudioSpectrum32Left` | `0x14048da08` | `float[32]` | 2 | 2 | 0 | 0 | 채움 | `audioL32` | — |
| 101 | `g_AudioSpectrum32Right` | `0x14048d9f0` | `float[32]` | 2 | 2 | 0 | 0 | 채움 | `audioR32` | — |
| 102 | `g_AudioSpectrum64Left` | `0x14048da98` | `float[64]` | 2 | 2 | 0 | 0 | 채움 | `audioL64` | — |
| 103 | `g_AudioSpectrum64Right` | `0x14048da80` | `float[64]` | 2 | 2 | 0 | 0 | 채움 | `audioR64` | — |
| 104 | `g_PointerPositionLast` | `0x14048da68` | `vec2` | 8 | 8 | 2 | 0 | 채움 | `eng.pointerLastAndPad.xy` | — |
| 105 | `g_PointerPosition` | `0x14048da50` | `vec2` | 12 | 12 | 4 | 0 | 채움 | `eng.timeAndPad.yz` | — |
| 106 | `g_PointerState` | `0x14048dae8` | `vec4` | 8 | 8 | 2 | 0 | 채움 | `float4(0,0,클릭힘,0)` | — |
| 107 | `g_ParallaxPosition` | `0x14048dad0` | `vec2` | 4 | 4 | 2 | 0 | 채움 | `eng.timeAndPad.yz`(별칭) | — |
| 108 | `g_RenderVar0` | `0x14048dac0` | `vec4` | 16 | 0 | 6 | 4 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | HDRBloomPyramidPass / VolumetricLightPass |
| 109 | `g_RenderVar1` | `0x14048dab0` | `vec4` | 11 | 1 | 6 | 4 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | VolumetricLightPass |
| 110 | `g_RenderVar2` | `0x14048db20` | `vec4` | 4 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | VolumetricLightPass |
| 111 | `g_RenderVar3` | `0x14048db10` | `vec4` | 4 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | VolumetricLightPass |
| 112 | `g_RenderVar4` | `0x14048db00` | `vec4` | 2 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | VolumetricLightPass |
| 113 | `g_Bones` | `0x14048daf8` | `mat4x3[BONECOUNT]` | 18 | 0 | 108 | 4 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | Mesh3DShaders `bones[]` |
| 114 | `g_BonesAlpha` | `0x14048db60` | `float[BONECOUNT]` | 8 | 0 | 106 | 4 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | 부분(본 알파 미배선) |
| 115 | `g_BlendMap` | `0x14048db50` | `vec4[BLENDROWCOUNT]` | 2 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 116 | `g_MorphOffsets` | `0x14048db40` | `uint[12]` | 24 | 0 | 4 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | PuppetPose(번역 레인 밖) |
| 117 | `g_MorphWeights` | `0x14048db30` | `float[12]` | 24 | 0 | 4 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | PuppetPose(번역 레인 밖) |
| 118 | `g_MorphBoneTransform` | `0x14048dba8` | `mat4x3[11]` | 4 | 0 | 2 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 119 | `g_MorphBoneRules` | `0x14048db90` | `vec3[11]` | 4 | 0 | 2 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |
| 120 | `g_LPoint_Color` | `0x14048db80` | `vec4[LIGHTS_POINT]` | 4 | 0 | 0 | 0 | 부분 | `float4(0)` — 인식만 | Scene3DLighting |
| 121 | `g_LPoint_Origin` | `0x14048db70` | `vec4[LIGHTS_POINT]` | 4 | 0 | 0 | 0 | 부분 | `float4(0)` — 인식만 | Scene3DLighting |
| 122 | `g_LSpot_Color` | `0x14048dc00` | `vec4[LIGHTS_SPOT]` | 4 | 0 | 0 | 0 | 부분 | `float4(0)` — 인식만 | Scene3DLighting |
| 123 | `g_LSpot_Origin` | `0x14048dbf0` | `vec4[LIGHTS_SPOT]` | 4 | 0 | 0 | 0 | 부분 | `float4(0)` — 인식만 | Scene3DLighting |
| 124 | `g_LSpot_Direction` | `0x14048dbd8` | `vec4[LIGHTS_SPOT]` | 4 | 0 | 0 | 0 | 부분 | `float4(0)` — 인식만 | Scene3DLighting |
| 125 | `g_LSpot_Exponent` | `0x14048dbc0` | `—` | 0 | 0 | 0 | 0 | 부분 | `float4(0)` — 인식만 | Scene3DLighting |
| 126 | `g_LTube_Color` | `0x14048dc48` | `vec4[LIGHTS_TUBE]` | 4 | 0 | 0 | 0 | 부분 | `float4(0)` — 인식만 | Scene3DLighting |
| 127 | `g_LTube_OriginA` | `0x14048dc38` | `vec4[LIGHTS_TUBE]` | 4 | 0 | 0 | 0 | 부분 | `float4(0)` — 인식만 | Scene3DLighting |
| 128 | `g_LTube_OriginB` | `0x14048dc28` | `vec4[LIGHTS_TUBE]` | 4 | 0 | 0 | 0 | 부분 | `float4(0)` — 인식만 | Scene3DLighting |
| 129 | `g_LDirectional_Color` | `0x14048dc10` | `vec4[LIGHTS_DIRECTIONAL]` | 4 | 0 | 0 | 0 | 부분 | `float4(0)` — 인식만 | Scene3DLighting |
| 130 | `g_LDirectional_Direction` | `0x14048dcc8` | `vec4[LIGHTS_DIRECTIONAL]` | 4 | 0 | 0 | 0 | 부분 | `float4(0)` — 인식만 | Scene3DLighting |
| 131 | `g_LFeature_ShadowProjection` | `0x14048dca8` | `—` | 0 | 0 | 0 | 0 | 채움 | `float4x4(1)` | — |
| 132 | `g_LFeature_ShadowProjectionTransform` | `0x14048dc80` | `—` | 0 | 0 | 0 | 0 | 부분 | `float4(0)` — 인식만 | — |
| 133 | `g_LFeature_ShadowPointProjection` | `0x14048dc58` | `—` | 0 | 0 | 0 | 0 | 부분 | `float4(0)` — 인식만 | — |
| 134 | `g_LFeature_ShadowPointProjectionTransform` | `0x14048dd30` | `—` | 0 | 0 | 0 | 0 | 부분 | `float4(0)` — 인식만 | — |
| 135 | `g_FogDistanceColor` | `0x14048dd18` | `vec3` | 2 | 0 | 8 | 4 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | Scene3DLighting `FogU3D` |
| 136 | `g_FogDistanceParams` | `0x14048dd00` | `vec4` | 2 | 0 | 8 | 4 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | Scene3DLighting `FogU3D` |
| 137 | `g_FogHeightColor` | `0x14048dce8` | `vec3` | 2 | 0 | 8 | 4 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | 부분(높이 fog 미구현) |
| 138 | `g_FogHeightParams` | `0x14048dd70` | `vec4` | 2 | 0 | 8 | 4 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | 부분(높이 fog 미구현) |
| 139 | `g_HDRParams` | `0x14048dd60` | `vec2` | 4 | 0 | 0 | 0 | 미채움 | 머티리얼 파라미터 강등 → 기본 0 | — |

### 1.3 레지스트리에 있으나 **동봉 셰이더가 한 번도 안 쓰는** 42개

`g_Daytime` · `g_ViewForward` · `g_LayerModelMatrix` · `g_LSpot_Exponent` ·
`g_LFeature_ShadowProjection` · `g_LFeature_ShadowProjectionTransform` ·
`g_LFeature_ShadowPointProjection` · `g_LFeature_ShadowPointProjectionTransform` ·
`g_Texture9` · `g_Texture9Resolution` ·
`g_Texture{1..9}Rotation`(9) · `g_Texture{1..9}Translation`(9) ·
`g_Texture{2,3,7,8,9}Texel`(5) · `g_Texture{0,1,2,4,5,6,7,8,9}MipMapInfo`(9)

→ 이 42개는 **동봉 코퍼스 A/B 로는 절대 회귀가 안 잡힌다.** 워크샵 씬이나 에디터에서 저작한
셰이더에서만 드러난다. `g_Texture3MipMapInfo` 만 예외적으로 built-in 반사 경로가 쓴다.

---

## 2. 셰이더 평문 `g_*` 전수 census — 340 이름

### 2.1 분류 기준

WE 셰이더는 유니폼 선언 뒤에 JSON 어노테이션을 단다. 이게 1차 분류기다:

```glsl
uniform sampler2D g_Texture0; // {"hidden":true}
uniform vec2 g_Scale; // {"material":"repeat","label":"ui_editor_properties_repeat","default":"1 1","linked":true,"range":[0.01, 10.0]}
                            ^^^^^^^^^^ 저작 키 — constantshadervalues[repeat] 로 들어온다
uniform float g_Time;       // 어노테이션 없음 = 엔진이 채운다
```

`"material":"<키>"` 가 있으면 **머티리얼 JSON `constantshadervalues[<키>]`** 로 값이 온다.
어노테이션이 없으면 엔진 피드다. 다만 이 규칙만으로는 판정이 흔들리는 경계가 있어서
(§2.2 의 `g_BloomBlendParams` 같은 사례) **바이너리 문자열 존재 여부**를 2차 판정에 쓴다.

이 규약이 엔진 쪽에도 그대로 있다는 근거 — `wallpaper64.exe` `.rdata` 에 셰이더 원문을
훑는 정규식이 들어 있다:

| VA | 문자열 | 쓰임 |
|---|---|---|
| `0x14048d048` | `^\s*#\s*([a-z]+)\b\s*(.*)` | 전처리기 지시자 |
| `0x14048d100` | `^uniform[\s]+(sampler[\w]*)[\s]+g_Texture([\d]+)` | **샘플러 슬롯 번호 추출** |
| `0x14048d0e0` / `0x14048d0f0` | `formatcombo` / `components` | 어노테이션 키 |

즉 텍스처 슬롯만은 **이름 패턴 `g_TextureN` 으로 직접 파싱**한다(레지스트리 조회가 아니다).
`wallpaper64.exe` 문자열 스캔이 `g_Texture` 를 하나 더 내놓는 것도 이 정규식 때문이다(§3.2).

### 2.2 3분류 결과

| 부류 | 개수 | 판정 근거 | 값이 오는 곳 |
|---|---:|---|---|
| **A. 엔진 레지스트리** | 98 | 340 ∩ 레지스트리 140 | 엔진이 ID 로 직접 피드 |
| **B. 엔진 다른 경로** | 4 | exe 문자열에는 있으나 레지스트리엔 없음 | DX11 재생목록 전환 전용(§3.2) |
| **C. 자산 저작** | 238 | **exe 어디에도 문자열 없음** | 머티리얼 JSON `constantshadervalues[material 키]` |

**B 4개**: `g_Texture0MipMapped`, `g_Texture1Noise`, `g_Texture2Clouds`
(`assets/shaders/HLSL/dx11playlisttransition.frag:18-20` 의 `Texture2D …:register(tN)`),
`g_bufDynamic`(cbuffer 이름). → `docs/re/playlist-transition.md` 소관.

**C 238개**가 이 문서의 핵심 결론이다. `g_Scale`·`g_Speed`·`g_Brightness`·`g_TintColor`·
`g_NoiseAmount` 같이 **`g_` 로 시작해 엔진 유니폼처럼 보이는 이름들이 전부 여기 있다.**
엔진 코드에는 그 이름이 없다 — 엔진은 셰이더 리플렉션으로 얻은 이름을 레지스트리와 대조해
못 찾으면 머티리얼 파라미터로 넘긴다(§3.1). 즉 **`g_` 접두는 엔진 유니폼의 표식이 아니라
WE 셰이더 저작 관례**다.

`g_BloomBlendParams`(`hdr_downsample.frag:56` `// {"material":"blend","default":"1 1 0 1"}`)는
C 부류지만 **엔진 내장 블룸 패스가 그 머티리얼 키 `blend` 를 코드로 채운다**
(`spec/engine/uniform-feed.json` `codeVA 0x14017f8bc`). 부류 C 라고 해서 "엔진이 안 채운다"가
아니라 **"이름으로 안 채운다 — 머티리얼 키로 채운다"** 라는 뜻이다. 같은 부류의
`g_BloomStrength`(`bloomstrength`)·`g_BloomTint`(`bloomtint`)·`g_BloomScatter`(`scatter`)도 동형.

### 2.3 부류 C 전수표 (238행, 절단 없음)

**타입** 은 `uniform` 선언에서, **머티리얼 키** 는 `"material"` 어노테이션에서 확정.
같은 이름이 파일마다 다른 키를 쓰면 **전부 ` / ` 로 나열**한다(§2.5 참조).
`(uniform 선언 없음)` 20건은 §2.4 참조.

| 이름 | 타입 | 머티리얼 키 | 출현 | 선언파일 | 씬 | np |
|---|---|---|---:|---:|---:|---:|
| `g_Scale` | `float·vec2` | `Blur scale / Distortion / Ripple scale / Scale / blurscale / distortion / rayscale / repeat / scale / ui_editor_properties_blur_scale / ui_editor_properties_scale` | 212 | 84 | 26 | 2 |
| `g_Speed` | `float` | `Speed / rayspeed / speed / speeduv / ui_editor_properties_speed` | 144 | 55 | 27 | 1 |
| `g_Point0` | `vec2` | `point0` | 104 | 52 | 14 | 0 |
| `g_Point1` | `vec2` | `point1` | 104 | 52 | 14 | 0 |
| `g_Point2` | `vec2` | `point2` | 96 | 48 | 12 | 0 |
| `g_Point3` | `vec2` | `point3` | 96 | 48 | 12 | 0 |
| `g_Direction` | `float` | `Angle / Direction / Scroll direction / angle / direction / scrolldirection / ui_editor_properties_direction` | 122 | 39 | 9 | 1 |
| `g_NoiseAmount` | `float` | `Noise amount / noiseamount / ui_editor_properties_noise_amount` | 122 | 34 | 15 | 1 |
| `g_NoiseScale` | `float` | `noisescale / scale / ui_editor_properties_noise_scale / ui_editor_properties_scale` | 101 | 34 | 16 | 2 |
| `g_TintColor` | `vec3` | `Color / color / ui_editor_properties_color` | 64 | 29 | 10 | 2 |
| `g_BlendAlpha` | `float` | `Alpha / alpha / ui_editor_properties_alpha` | 44 | 23 | 9 | 1 |
| `g_Amount` | `float` | `Accumulation rate / Strength / amount / rate / strength` | 58 | 22 | 6 | 0 |
| `g_Strength` | `float` | `Ripple strength / Strength / ripplestrength / strength` | 70 | 22 | 6 | 0 |
| `g_Brightness` | `float` | `Bright / Brightness / Brigtness / brightness` | 42 | 21 | 113 | 11 |
| `g_Metallic` | `float` | `Metal / metallic` | 67 | 21 | 110 | 6 |
| `g_Roughness` | `float` | `Rough / roughness` | 47 | 21 | 110 | 6 |
| `g_Feather` | `float·vec2` | `feather / rayfeather` | 100 | 20 | 12 | 0 |
| `g_NoiseSpeed` | `float` | `Noise speed / noisespeed / ui_editor_properties_noise_speed` | 47 | 20 | 5 | 1 |
| `g_Power` | `float` | `Power / power` | 45 | 20 | 11 | 7 |
| `g_Intensity` | `float` | `Ray intensity / colorwintensity / rayintensity / ui_editor_properties_ray_intensity` | 50 | 19 | 11 | 1 |
| `g_Phase` | `float` | `Phase / foliagephase / phase` | 42 | 18 | 2 | 0 |
| `g_Size` | `float` | `Size / size` | 70 | 18 | 4 | 0 |
| `g_Center` | `float·vec2` | `Center / center` | 50 | 17 | 3 | 1 |
| `g_NoiseAlpha` | `float` | `strength / ui_editor_properties_strength` | 44 | 17 | 5 | 1 |
| `g_EmissiveBrightness` | `float` | `emissivebrightness` | 48 | 16 | 108 | 4 |
| `g_EmissiveColor` | `vec3` | `emissivecolor` | 48 | 16 | 108 | 4 |
| `g_Multiply` | `float` | `Multiply / multiply / ui_editor_properties_multiply` | 48 | 16 | 10 | 0 |
| `g_Reflectivity` | `float` | `reflectivity` | 32 | 16 | 108 | 4 |
| `g_ScrollX` | `float` | `Scroll 1 X / Speed X / speedx` | 45 | 15 | 16 | 10 |
| `g_Color1` | `vec3` | `Color start / clouds / color1 / colorstart / ui_editor_properties_color_start` | 35 | 14 | 3 | 3 |
| `g_ScrollY` | `float` | `Scroll 1 Y / Speed Y / speedy` | 42 | 14 | 15 | 9 |
| `g_Tint` | `vec3` | `tint` | 34 | 14 | 6 | 6 |
| `g_TintAlpha` | `float` | `Alpha / alpha` | 28 | 14 | 3 | 1 |
| `g_Color2` | `vec3` | `Color end / color2 / colorend / ui_editor_properties_color_end` | 32 | 13 | 2 | 2 |
| `g_ArtifactsScale` | `float` | `artifacts` | 26 | 12 | 4 | 0 |
| `g_Exponent` | `float` | `colorwexponent / exponent` | 24 | 12 | 8 | 0 |
| `g_Ratio` | `float` | `ratio` | 32 | 12 | 2 | 0 |
| `g_SpinCenter` | `vec2` | `Center / center` | 44 | 12 | 4 | 0 |
| `g_FlowSpeed` | `float` | `Speed / speed / ui_editor_properties_speed` | 31 | 11 | 1 | 1 |
| `g_Bottom` | `float` | `Bottom / bottom / ui_editor_properties_bottom` | 36 | 10 | 0 | 0 |
| `g_ColorRaysEnd` | `vec3` | `colorend` | 20 | 10 | 8 | 0 |
| `g_ColorRaysStart` | `vec3` | `colorastart / colorstart` | 20 | 10 | 8 | 0 |
| `g_KeyAlpha` | `float` | `Write alpha / alpha` | 18 | 10 | 0 | 0 |
| `g_KeyColor` | `vec3` | `Color / color` | 18 | 10 | 0 | 0 |
| `g_KeyFuzz` | `float` | `Fuzziness / fuzziness` | 18 | 10 | 0 | 0 |
| `g_KeyTolerance` | `float` | `Tolerance / tolerance` | 18 | 10 | 0 | 0 |
| `g_Left` | `float` | `Left / left / ui_editor_properties_left` | 36 | 10 | 0 | 0 |
| `g_Length` | `float` | `Ray length / length / raylength / ui_editor_properties_ray_length` | 20 | 10 | 4 | 2 |
| `g_Radius` | `float` | `rayradius` | 30 | 10 | 8 | 0 |
| `g_Right` | `float` | `Right / right / ui_editor_properties_right` | 36 | 10 | 0 | 0 |
| `g_RimAmount` | `float` | `rimamount` | 20 | 10 | 2 | 0 |
| `g_RimExponent` | `float` | `rimexponent` | 20 | 10 | 2 | 0 |
| `g_Smoothness` | `float` | `raysmoothness` | 30 | 10 | 8 | 0 |
| `g_Top` | `float` | `Top / top / ui_editor_properties_top` | 36 | 10 | 0 | 0 |
| `g_Threshold` | `float` | `Ray threshold / raythreshold / ui_editor_properties_ray_threshold` | 18 | 9 | 3 | 1 |
| `g_UserAlpha` | `float` | `Alpha / alpha` | 15 | 9 | 111 | 11 |
| `g_AnimationSpeed` | `float` | `Animation speed / animationspeed` | 40 | 8 | 2 | 0 |
| `g_Chromatic` | `float` | `chromatic` | 34 | 8 | 4 | 0 |
| `g_CloudFeather` | `float` | `feather / ui_editor_properties_feather` | 18 | 8 | 0 | 0 |
| `g_CloudThreshold` | `float` | `threshold / ui_editor_properties_threshold` | 28 | 8 | 0 | 0 |
| `g_CloudsAlpha` | `float` | `alpha / ui_editor_properties_alpha` | 18 | 8 | 0 | 0 |
| `g_Offset` | `vec2` | `Offset / offset` | 16 | 8 | 4 | 0 |
| `g_ScrollSpeed` | `float` | `Scroll speed / scrollspeed` | 24 | 8 | 2 | 0 |
| `g_ShadingDirection` | `float` | `shadingdirection / ui_editor_properties_shading_direction` | 16 | 8 | 2 | 0 |
| `g_CloudScales` | `vec2·vec4` | `scale / ui_editor_properties_scale` | 21 | 7 | 1 | 1 |
| `g_CloudSpeeds` | `vec2·vec4` | `speed / ui_editor_properties_speed` | 21 | 7 | 1 | 1 |
| `g_ColorRays` | `vec3` | `color / ui_editor_properties_color` | 14 | 7 | 3 | 1 |
| `g_PulseAmount` | `float` | `Pulse amount / amount` | 14 | 7 | 0 | 0 |
| `g_PulseSpeed` | `float` | `Pulse speed / speed` | 14 | 7 | 0 | 0 |
| `g_PulseThresholds` | `vec2` | `Pulse bounds / bounds` | 21 | 7 | 0 | 0 |
| `g_AlphaMultiply` | `float` | `alpha` | 8 | 6 | 2 | 0 |
| `g_AspectRatio` | `(uniform 선언 없음)` | `—` | 62 | 6 | 0 | 0 |
| `g_Axis` | `float` | `angle` | 20 | 6 | 2 | 0 |
| `g_BlendAngle` | `float` | `blendangle` | 20 | 6 | 2 | 0 |
| `g_BlendOffset` | `vec2` | `blendoffset` | 12 | 6 | 2 | 0 |
| `g_BlendScale` | `float` | `blendscale` | 14 | 6 | 2 | 0 |
| `g_CloudLOD` | `float` | `smoothness / ui_editor_properties_smoothness` | 22 | 6 | 0 | 0 |
| `g_CornerWeights` | `vec4` | `Corner weights / cornerweights` | 30 | 6 | 2 | 0 |
| `g_DetectionMultiply` | `float` | `Detection multiply / detectmultiply` | 12 | 6 | 0 | 0 |
| `g_DetectionSize` | `float` | `Detection size / size` | 12 | 6 | 0 | 0 |
| `g_DetectionThreshold` | `float` | `Detection threshold / detectthreshold` | 12 | 6 | 0 | 0 |
| `g_DirectionWeights` | `vec2` | `Direction weights / directionweights` | 18 | 6 | 2 | 0 |
| `g_DistortionSpeed` | `float` | `distortionspeed` | 12 | 6 | 4 | 0 |
| `g_DistortionStrength` | `float` | `distortionstrength` | 12 | 6 | 4 | 0 |
| `g_DistortionWidth` | `float` | `distortionwidth` | 12 | 6 | 4 | 0 |
| `g_FlowAmp` | `float` | `Amount / Strength / strength` | 22 | 6 | 2 | 2 |
| `g_FlowPhaseScale` | `float` | `phasescale / ui_editor_properties_phase_scale` | 8 | 6 | 0 | 0 |
| `g_Hash` | `(uniform 선언 없음)` | `—` | 46 | 6 | 0 | 0 |
| `g_Hash2` | `(uniform 선언 없음)` | `—` | 20 | 6 | 0 | 0 |
| `g_Height` | `(uniform 선언 없음)` | `—` | 14 | 6 | 0 | 0 |
| `g_OutlineColor1` | `vec3` | `Outline color / outlinecolor` | 12 | 6 | 0 | 0 |
| `g_OutlineColor2` | `vec3` | `Outline background / outlinecolorbg` | 12 | 6 | 0 | 0 |
| `g_Progress` | `(uniform 선언 없음)` | `—` | 34 | 6 | 0 | 0 |
| `g_Random` | `(uniform 선언 없음)` | `—` | 6 | 6 | 0 | 0 |
| `g_SpecularTint` | `vec3` | `speculartint` | 12 | 6 | 2 | 0 |
| `g_ViewProjection` | `(uniform 선언 없음)` | `—` | 10 | 6 | 0 | 0 |
| `g_ViewProjectionInv` | `(uniform 선언 없음)` | `—` | 6 | 6 | 0 | 0 |
| `g_Width` | `(uniform 선언 없음)` | `—` | 8 | 6 | 0 | 0 |
| `g_AudioBounds` | `vec2` | `audiobounds` | 15 | 5 | 0 | 0 |
| `g_AudioFrequencyMax` | `float` | `frequencymax` | 40 | 5 | 0 | 0 |
| `g_AudioFrequencyMin` | `float` | `frequencymin` | 40 | 5 | 0 | 0 |
| `g_AudioMultiply` | `float` | `audioamount` | 10 | 5 | 0 | 0 |
| `g_AudioPower` | `float` | `audioexponent` | 10 | 5 | 0 | 0 |
| `g_Light` | `float` | `Light` | 25 | 5 | 2 | 2 |
| `g_NoisePower` | `float` | `exponent / ui_editor_properties_power` | 10 | 5 | 1 | 1 |
| `g_PulsePhase` | `float` | `phase` | 10 | 5 | 0 | 0 |
| `g_ShadingAmount` | `float` | `shading / shadingamount` | 10 | 5 | 3 | 1 |
| `g_TintColor1` | `vec3` | `Tint low / tintlow` | 10 | 5 | 0 | 0 |
| `g_TintColor2` | `vec3` | `Tint high / tinthigh` | 10 | 5 | 0 | 0 |
| `g_Additive` | `float` | `Additive` | 6 | 4 | 0 | 0 |
| `g_Amp` | `float` | `Strength / strength` | 12 | 4 | 2 | 0 |
| `g_BloomStrength` | `float` | `bloomstrength` | 8 | 4 | 0 | 0 |
| `g_BloomTint` | `vec3` | `bloomtint` | 8 | 4 | 0 | 0 |
| `g_Bounds` | `vec2` | `bounds` | 10 | 4 | 0 | 0 |
| `g_CenterPos` | `float` | `center` | 8 | 4 | 2 | 0 |
| `g_CloudScale` | `float` | `scale / ui_editor_properties_scale` | 24 | 4 | 0 | 0 |
| `g_CloudShading` | `float` | `shadingamount / ui_editor_properties_shading` | 8 | 4 | 0 | 0 |
| `g_CutOff` | `float` | `foliagecutoff` | 8 | 4 | 0 | 0 |
| `g_CutoutEnd` | `float` | `ui_editor_properties_cutout_end` | 8 | 4 | 6 | 4 |
| `g_CutoutOpacity` | `float` | `ui_editor_properties_cutout_opacity` | 8 | 4 | 6 | 4 |
| `g_CutoutStart` | `float` | `ui_editor_properties_cutout_start` | 8 | 4 | 6 | 4 |
| `g_Density` | `float` | `density` | 12 | 4 | 2 | 0 |
| `g_EdgeBrightness` | `float` | `edgebrightness` | 8 | 4 | 2 | 0 |
| `g_EdgeColor` | `vec3` | `edgecolor` | 8 | 4 | 2 | 0 |
| `g_EyeColor` | `vec3` | `color` | 8 | 4 | 2 | 0 |
| `g_FoliageScale` | `float` | `foliagescale` | 10 | 4 | 0 | 0 |
| `g_FoliageUVBounds` | `vec2` | `foliageuvbounds` | 10 | 4 | 0 | 0 |
| `g_Friction` | `vec2` | `friction` | 16 | 4 | 0 | 0 |
| `g_GlitterColor` | `vec3` | `color / glittercolor` | 8 | 4 | 2 | 0 |
| `g_GlitterOpacity` | `float` | `alpha` | 8 | 4 | 2 | 0 |
| `g_GlitterScale` | `float` | `scale` | 8 | 4 | 2 | 0 |
| `g_GradientScale` | `float` | `gradientscale` | 16 | 4 | 2 | 0 |
| `g_NitroAlpha` | `float` | `multiply / ui_editor_properties_multiply` | 8 | 4 | 0 | 0 |
| `g_NitroColor0` | `vec3` | `colorstart / ui_editor_properties_color_start` | 8 | 4 | 0 | 0 |
| `g_NitroColor1` | `vec3` | `colorend / ui_editor_properties_color_end` | 8 | 4 | 0 | 0 |
| `g_NitroRanges` | `vec2` | `bounds / ui_editor_properties_bounds` | 8 | 4 | 0 | 0 |
| `g_NitroScales` | `vec2` | `scale / ui_editor_properties_scale` | 12 | 4 | 0 | 0 |
| `g_NitroSpeeds` | `vec4` | `speed / ui_editor_properties_speed` | 12 | 4 | 0 | 0 |
| `g_Overbright` | `float` | `ui_editor_properties_overbright` | 8 | 4 | 6 | 4 |
| `g_PointerScale` | `float` | `size / ui_editor_particle_element_exponent` | 10 | 4 | 2 | 0 |
| `g_ReflectionOffset` | `float` | `Offset / offset` | 8 | 4 | 0 | 0 |
| `g_RippleDecay` | `float` | `rippledecay` | 8 | 4 | 2 | 0 |
| `g_RippleScale` | `float` | `ripplescale` | 8 | 4 | 2 | 0 |
| `g_RippleSpeed` | `float` | `ripplespeed` | 10 | 4 | 2 | 0 |
| `g_RippleStrength` | `float` | `ripplestrength` | 8 | 4 | 2 | 0 |
| `g_Rough` | `float` | `rough` | 8 | 4 | 2 | 0 |
| `g_ScreenPosition` | `(uniform 선언 없음)` | `—` | 10 | 4 | 0 | 0 |
| `g_Sensitivity` | `float` | `sens` | 16 | 4 | 2 | 0 |
| `g_ShadingHigh` | `vec3` | `shadingtinthigh` | 8 | 4 | 2 | 0 |
| `g_ShadingLow` | `vec3` | `shadingtintlow` | 8 | 4 | 2 | 0 |
| `g_SpeedBase` | `float` | `foliagespeedbase` | 8 | 4 | 0 | 0 |
| `g_SpeedLeaves` | `float` | `foliagespeedleaves` | 8 | 4 | 0 | 0 |
| `g_StrengthBase` | `float` | `strengthbase` | 8 | 4 | 0 | 0 |
| `g_StrengthLeaves` | `float` | `strengthleaves` | 8 | 4 | 0 | 0 |
| `g_TexCoord` | `(uniform 선언 없음)` | `—` | 8 | 4 | 0 | 0 |
| `g_Texture0SamplerState` | `(uniform 선언 없음)` | `—` | 68 | 4 | 0 | 0 |
| `g_TreeHeight` | `float` | `foliageheight` | 10 | 4 | 0 | 0 |
| `g_TreeRadius` | `float` | `foliageradius` | 22 | 4 | 0 | 0 |
| `g_NoiseSmoothness` | `float` | `noisesmoothness` | 9 | 3 | 1 | 1 |
| `g_SpecularPower` | `float` | `ripplespecularpower / specularpower` | 6 | 3 | 1 | 1 |
| `g_SpecularStrength` | `float` | `ripplespecularstrength / specularstrength` | 6 | 3 | 1 | 1 |
| `g_AmbientLowPass` | `(uniform 선언 없음)` | `—` | 4 | 2 | 2 | 0 |
| `g_AudioSpectrum16` | `(uniform 선언 없음)` | `—` | 2 | 2 | 2 | 2 |
| `g_BlendBrightness` | `float` | `brightness` | 4 | 2 | 0 | 0 |
| `g_BloomBlendParams` | `vec4` | `blend` | 10 | 2 | 0 | 0 |
| `g_BloomScatter` | `float` | `scatter` | 4 | 2 | 0 | 0 |
| `g_BloomThreshold` | `float` | `bloomthreshold` | 4 | 2 | 0 | 0 |
| `g_BrushColor` | `vec4` | `brushcolor` | 6 | 2 | 0 | 0 |
| `g_BrushPosition` | `vec4` | `brushposition` | 20 | 2 | 0 | 0 |
| `g_BrushSettings` | `vec4` | `brushsettings` | 8 | 2 | 0 | 0 |
| `g_Color3` | `vec3` | `color3` | 4 | 2 | 2 | 2 |
| `g_CompositeAlpha` | `float` | `compositealpha` | 10 | 2 | 0 | 0 |
| `g_CompositeColor` | `vec3` | `compositecolor` | 4 | 2 | 0 | 0 |
| `g_CompositeOffset` | `vec2` | `compositeoffset` | 4 | 2 | 0 | 0 |
| `g_Direction2` | `float` | `direction2` | 4 | 2 | 0 | 0 |
| `g_Distortion` | `float` | `distortion` | 4 | 2 | 0 | 0 |
| `g_EndAngle` | `float` | `rayzzendangle` | 6 | 2 | 0 | 0 |
| `g_Exponent2` | `float` | `exponent2` | 4 | 2 | 0 | 0 |
| `g_FurDetail` | `float` | `furdetail` | 4 | 2 | 0 | 0 |
| `g_FurDistance` | `float` | `furdistance` | 4 | 2 | 0 | 0 |
| `g_FurOcclusion` | `float` | `furocclusion` | 8 | 2 | 0 | 0 |
| `g_LightmapMapSampler` | `(uniform 선언 없음)` | `—` | 6 | 2 | 1 | 1 |
| `g_LutParams` | `float` | `lutparams` | 4 | 2 | 0 | 0 |
| `g_ModelViewMatrix` | `mat4` | `—` | 2 | 2 | 0 | 0 |
| `g_Multiply2` | `float` | `multiply2` | 4 | 2 | 0 | 0 |
| `g_Multiply3` | `float` | `multiply3` | 4 | 2 | 0 | 0 |
| `g_Multiply4` | `float` | `multiply4` | 4 | 2 | 0 | 0 |
| `g_Multiply5` | `float` | `multiply5` | 4 | 2 | 0 | 0 |
| `g_Multiply6` | `float` | `multiply6` | 4 | 2 | 0 | 0 |
| `g_NitroLOD` | `float` | `smoothness` | 6 | 2 | 0 | 0 |
| `g_NormalMapSampler` | `(uniform 선언 없음)` | `—` | 4 | 2 | 1 | 1 |
| `g_Offset2` | `float` | `offset2` | 4 | 2 | 0 | 0 |
| `g_Params` | `vec4` | `params` | 10 | 2 | 0 | 0 |
| `g_PhaseFeather` | `float` | `feather` | 6 | 2 | 0 | 0 |
| `g_PhaseOffset` | `float` | `phase` | 4 | 2 | 0 | 0 |
| `g_ReflectionAlpha` | `float` | `alpha` | 6 | 2 | 0 | 0 |
| `g_ReflectionSampler` | `(uniform 선언 없음)` | `—` | 4 | 2 | 1 | 1 |
| `g_ReflectivityDistance` | `float` | `reflectivitydistance` | 4 | 2 | 2 | 0 |
| `g_RefractAmount` | `float` | `ui_editor_properties_refract_amount` | 4 | 2 | 6 | 4 |
| `g_Scale2` | `float` | `scale2` | 4 | 2 | 0 | 0 |
| `g_Scroll2X` | `float` | `Scroll 2 X` | 6 | 2 | 7 | 7 |
| `g_Scroll2Y` | `float` | `Scroll 2 Y` | 6 | 2 | 7 | 7 |
| `g_SpecularColor` | `vec3` | `ripplespecularcolor` | 4 | 2 | 0 | 0 |
| `g_Speed2` | `float` | `speed2` | 4 | 2 | 0 | 0 |
| `g_StartAngle` | `float` | `rayzstartangle` | 6 | 2 | 0 | 0 |
| `g_SwayAmp` | `float` | `Amount` | 4 | 2 | 1 | 1 |
| `g_SwaySpeed` | `float` | `Speed` | 4 | 2 | 1 | 1 |
| `g_Texture0SamplerStateWrap` | `(uniform 선언 없음)` | `—` | 8 | 2 | 0 | 0 |
| `g_Tint2` | `vec3` | `tint2` | 5 | 2 | 2 | 2 |
| `g_TintBack` | `vec3` | `tintback` | 6 | 2 | 0 | 0 |
| `g_TintExponent` | `float` | `tintwexponent` | 4 | 2 | 0 | 0 |
| `g_TintFront` | `vec3` | `tintfront` | 6 | 2 | 0 | 0 |
| `g_TintPigmentation` | `float` | `tintpigmentation` | 4 | 2 | 0 | 0 |
| `g_Tracking` | `float` | `tracking` | 4 | 2 | 0 | 0 |
| `g_WaveSpeed` | `float` | `Speed` | 6 | 2 | 2 | 2 |
| `g_WaveStrength` | `float` | `Strength` | 4 | 2 | 2 | 2 |
| `g_AmbientColor` | `vec3` | `ambientcolor` | 2 | 1 | 1 | 1 |
| `g_CMode` | `float` | `colormode` | 3 | 1 | 1 | 1 |
| `g_ColorGridBackground` | `vec3` | `gridbackground` | 2 | 1 | 1 | 1 |
| `g_ColorGridFar` | `vec3` | `gridfar` | 3 | 1 | 1 | 1 |
| `g_ColorGridNear` | `vec3` | `gridnear` | 3 | 1 | 1 | 1 |
| `g_ColorHorizon` | `vec3` | `horizon` | 2 | 1 | 1 | 1 |
| `g_ColorSunBottom` | `vec3` | `colorsunbottom` | 3 | 1 | 1 | 1 |
| `g_ColorSunTop` | `vec3` | `colorsuntop` | 2 | 1 | 1 | 1 |
| `g_CurveFreq` | `float` | `Freq` | 2 | 1 | 1 | 1 |
| `g_CurveSpeed` | `float` | `Scroll speed` | 2 | 1 | 1 | 1 |
| `g_FlowSpeed0` | `float` | `Speed0` | 3 | 1 | 1 | 1 |
| `g_FlowSpeed1` | `float` | `Speed1` | 3 | 1 | 1 | 1 |
| `g_FlowSpeed2` | `float` | `Speed2` | 3 | 1 | 1 | 1 |
| `g_FlowSpeed3` | `float` | `Speed3` | 3 | 1 | 1 | 1 |
| `g_FlowSpeed4` | `(uniform 선언 없음)` | `—` | 3 | 1 | 1 | 1 |
| `g_FlowSpeed5` | `(uniform 선언 없음)` | `—` | 3 | 1 | 1 | 1 |
| `g_MountainScale` | `float` | `mountainscale` | 2 | 1 | 1 | 1 |
| `g_NoiseFX` | `float` | `noisefx` | 2 | 1 | 1 | 1 |
| `g_PaintColor` | `vec3` | `paintcolor` | 4 | 1 | 1 | 1 |
| `g_PaintColorStripes` | `vec3` | `paintcolorstripes` | 2 | 1 | 1 | 1 |
| `g_SpecularSineScale` | `float` | `specularsinescale` | 2 | 1 | 1 | 1 |
| `g_TintAccent` | `vec3` | `tintaccent` | 4 | 1 | 1 | 1 |

### 2.4 `uniform` 이 아닌 `g_` 토큰 20개

전수 grep 은 유니폼이 아닌 것도 쓸어온다. 전부 분류했다:

| 토큰 | 실체 | 위치 |
|---|---|---|
| `g_bufDynamic` | HLSL `cbuffer` 이름 | `assets/shaders/HLSL/dx11playlisttransition.vert:23` |
| `g_Progress` `g_Hash` `g_Hash2` `g_Random` `g_AspectRatio` `g_Width` `g_Height` `g_ViewProjection` `g_ViewProjectionInv` | 위 cbuffer **멤버**(`const float` / `const float4x4`) | 같은 파일 `:25-34` |
| `g_Texture0MipMapped` `g_Texture1Noise` `g_Texture2Clouds` | HLSL `Texture2D …:register(tN)` | `dx11playlisttransition.frag:18-20` |
| `g_Texture0SamplerState` `g_Texture0SamplerStateWrap` | HLSL `SamplerState …:register(sN)` | 같은 파일 `:22-23` |
| `g_NormalMapSampler` `g_LightmapMapSampler` `g_ReflectionSampler` | `#define` **별칭**(→ `g_Texture1/2/3`) | `assets/shaders/generic.frag:20,24,31,40` |
| `g_ScreenPosition` | `varying vec3` | `assets/shaders/brushinvert.vert:6` |
| `g_TexCoord` | `varying vec2` | `assets/shaders/brushpreview.vert:7` |
| `g_AudioSpectrum16` `g_AmbientLowPass` `g_FlowSpeed4` `g_FlowSpeed5` | **주석 처리된** 죽은 선언 | `audiophile/shaders/audiophileglow.vert:23`, `genericimage4.frag:50`, `deep_space/shaders/flowimage.vert:11-12` |

`g_ViewProjection`(HLSL) vs `g_ViewProjectionMatrix`(GLSL 레지스트리)는 **다른 이름**이다.
HLSL 재생목록 전환 경로는 레지스트리를 안 쓰고 자기 cbuffer 를 쓴다.

### 2.5 머티리얼 키는 **이름당 하나가 아니다** — 86개가 다중 키

`"material"` 어노테이션 키를 이름별로 모으면, `uniform` 으로 선언된 **316개 이름 중 86개가
키를 2개 이상** 갖는다. 같은 `g_` 이름이 파일마다 다른 저작 키에 묶인다는 뜻이다.

| 이름 | 키 수 | 키 목록 |
|---|---:|---|
| `g_Texture1` | 17 | `Blend texture` / `Color mask` / `Flow map` / `Mask` / `Noise` / `Prev` / `Previous framebuffer` / `Water normal` / `mask` / `morph` / `noise` / `previous` / `ui_editor_properties_albedo` / `ui_editor_properties_blend_texture` / `ui_editor_properties_flow_map` / `ui_editor_properties_noise` / `ui_editor_properties_opacity_mask` |
| `g_Texture2` | 12 | `Flow Phase` / `Flow phase` / `Mask` / `Opacity mask` / `Prev` / `albedo` / `mask` / `normalmap` / `previous` / `ui_editor_properties_albedo` / `ui_editor_properties_opacity_mask` / `ui_editor_properties_sprite` |
| `g_Scale` | 11 | `Blur scale` / `Distortion` / `Ripple scale` / `Scale` / `blurscale` / `distortion` / `rayscale` / `repeat` / `scale` / `ui_editor_properties_blur_scale` / `ui_editor_properties_scale` |
| `g_Direction` | 7 | `Angle` / `Direction` / `Scroll direction` / `angle` / `direction` / `scrolldirection` / `ui_editor_properties_direction` |
| `g_Texture0` | 5 | `Framebuffer` / `albedo` / `framebuffer` / `previous` / `ui_editor_properties_framebuffer` |
| `g_Color1` | 5 | `Color start` / `clouds` / `color1` / `colorstart` / `ui_editor_properties_color_start` |
| `g_Speed` | 5 | `Speed` / `rayspeed` / `speed` / `speeduv` / `ui_editor_properties_speed` |
| `g_Amount` | 5 | `Accumulation rate` / `Strength` / `amount` / `rate` / `strength` |

(상위 8개만 실었다 — **86개 중 78개를 잘랐다.** 전 목록은 §2.3 표의 "머티리얼 키" 열에
` / ` 로 나열돼 있고 절단 없다.)

두 가지 함정이 여기서 나온다:

1. **키에 공백·대문자·로컬라이즈 토큰이 그대로 들어간다.** `"material":"Scroll 1 Y"`,
   `"material":"ui_editor_properties_speed"` 는 실제 저작 값이고, 씬 JSON 의
   `constantshadervalues` 키가 이 문자열 그대로다(`projects/defaultprojects/beach/materials/beach.json`
   의 `"Scroll 1 Y": 0`). **소문자 정규화로 키를 만들면 매칭이 깨진다.**
2. **WE 자산에 오타 키가 있다.** `assets/shaders/generic2.frag:8`
   `uniform float g_Brightness; // {"material":"Brigtness","default":1,"range":[0,10]}` —
   `Brigtness`(t 누락). 같은 유니폼이 `genericimage2.frag:9` 에서는 `Brightness` 다.
   **이름으로 키를 추론하는 코드는 이 파일에서 반드시 틀린다.**

### 2.6 같은 이름 · 다른 타입 — 10건

WE 는 같은 `g_` 이름을 파일마다 다른 타입으로 선언한다. **타입을 이름으로 추론하면 틀린다.**

| 이름 | 선언 분포 | 예시 |
|---|---|---|
| `g_Texture0` | `sampler2D`×497 · `sampler2DComparison`×2 | 후자는 섀도우 아틀라스 |
| `g_Texture1` | `sampler2D`×288 · `sampler3D`×2 · `sampler2DBackBuffer`×2 | |
| `g_Texture4` | `sampler2D`×31 · `sampler2DComparison`×4 | |
| `g_Texture6` | `sampler2DComparison`×12 · `sampler2D`×3 | **다수파가 Comparison** |
| `g_Scale` | `vec2`×64 · `float`×20 | `scroll.frag` 은 vec2(`repeat`), `twirl` 계열은 float |
| `g_Feather` | `vec2`×10 · `float`×10 | `lightshafts` vec2(`rayfeather`) vs `twirl` float(`feather`) |
| `g_Center` | `vec2`×13 · `float`×4 | |
| `g_ModelMatrix` | `mat4`×39 · `mat3`×2 | mat3 는 `audiophile/shaders/grid.vert:2`, `fantasticcar/shaders/grid.vert:2` |
| `g_CloudSpeeds` | `vec2`×5 · `vec4`×2 | 같은 이펙트의 vert 와 frag 이 서로 다르다(`clouds`) |
| `g_CloudScales` | `vec4`×5 · `vec2`×2 | 위와 짝 |

`g_NormalModelMatrix` / `g_AltNormalModelMatrix` 는 전건 `mat3` 다(§7.4 위험).

---

## 3. 바이너리 교차 확인

### 3.1 값이 셰이더에 닿는 경로

```
정적 초기화                            파이프라인 빌드                      드로우
sub_140002860 ──정렬(sub_140005c10)──▶ 전역 해시맵 0x1404e8100
   140×40B                                  ▲
                                            │ sub_14016f740(name) -> id, 없으면 -1
                                            │   호출부 **단 1곳**: 0x1400dac4c
                                       sub_1400dab40 (셰이더 리플렉션 바인딩,
                                       0x1400dab40..0x1400dc075)
                                            │
                                            └▶ 바인딩 레코드 +0x60 = 유니폼 ID
                                                 (0x1400db21e  mov dword ptr [r15+0x60], eax)
```

즉 엔진은 **컴파일된 셰이더의 리플렉션 이름**을 레지스트리와 대조한다. 매칭되면 그 유니폼은
ID 로 피드되고, 매칭 안 되면 머티리얼 파라미터 경로로 떨어진다. 이것이 §2.2 부류 C 가
성립하는 기계적 이유다.

상수 버퍼는 4개뿐이고 이름 테이블은 `0x140484b60` 에 있다(5번째 슬롯은 `.obj` — 다른 테이블):

| 슬롯 | 포인터 VA | 문자열 VA | 이름 |
|---:|---|---|---|
| 0 | `0x140484b60` | `0x14048d138` | `g_bufStatic` |
| 1 | `0x140484b68` | `0x14048d168` | `g_bufDynamic` |
| 2 | `0x140484b70` | `0x14048d158` | `g_bufAnimation` |
| 3 | `0x140484b78` | `0x14048d148` | `g_bufLights` |

이름이 갱신 주기를 말해 준다 — Static(1회) / Dynamic(프레임·드로우) / Animation(본·모프) /
Lights(라이트). **다만 140개 유니폼이 각각 어느 cbuffer 로 가는지는 GLSL 원문에 안 적혀 있고
(WE 의 HLSL 크로스컴파일러가 정한다) 이 문서에서 확정하지 못했다 — `[미해결]`.**
**[해소 2026-08-21]** 아래 §3.1b 가 140/140 을 확정했다. 크로스컴파일러는 별도 도구가 아니라
`wallpaper64.exe` 안의 **텍스트 조립기**이고, 배정은 **유니폼 ID 로 색인하는 디스패치 표**가 정한다.

### 3.1b [해소 2026-08-21] 유니폼 → cbuffer 배정 — 140/140 확정

**어떻게 찾았는가.** `"cbuffer "`(`0x140487618`)·`":register(b"`(`0x1404875d0`)를 xref 하니
호출자가 하나뿐이다 — `sub_1400f5cb0`(범위 `0x1400f5cb0`..`0x1400f8520`, `primary()` 확인).
이 함수가 **GLSL 유니폼 선언을 HLSL 텍스트로 조립**한다(GLSL→HLSL 크로스컴파일의 실체).

**① 유니폼 하나를 처리하는 디스패처**(`0x1400f6d68`–`0x1400f709f`). 이름으로 레지스트리 맵
(`0x1404e8100`, 센티널 `[0x1404e8108]`)을 조회해 못 찾으면 머티리얼 경로로 빠지고, 찾으면
노드 `+0x30` 의 **ID** 로 갈린다(`unordered_map<string,int>` 노드: next 8 + prev 8 + string 32 → int):

```
0x1400f6d8b  movsxd rcx, dword ptr [rdx + 0x30]   ; 유니폼 ID
0x1400f6d8f  cmp ecx, 0x20
0x1400f6d92  jl  0x1400f703f                      ; ID < 32
0x1400f6d98  cmp ecx, 0x29
0x1400f6d9b  jg  0x1400f7047                      ; ID > 41
0x1400f6da1  lea edx, [rcx - 0x20]                ; ID 32..41 → 텍스처 슬롯 = ID - 0x20
0x1400f6da8  call 0x140053e40                     ; to_string(slot)
```

즉 **ID 32..41 이 `g_Texture0`..`g_Texture9` 라는 것이 여기서 독립적으로 증명된다** — §1.2 표의
ID 는 이름 `lea` 옆의 상수가 아니라 이 범위 검사로 확인한 것이다(방법론 함정 16 의 그 자리).
그 열 개는 cbuffer 가 아니라 `Texture2D`/`Texture3D` + `SamplerState`/`SamplerComparisonState` 로
`:register(t<slot>)`/`:register(s<slot>)` 에 나간다(`0x1400f6dbd`·`0x1400f6df9`·`0x1400f6e79`).

**② cbuffer 슬롯을 고르는 점프 표**(`0x1400f7065`–`0x1400f709f`):

```
0x1400f7065  cmp ecx, 0x8b
0x1400f706b  ja  0x1400f709d                              ; ID > 139 → 슬롯 0
0x1400f706d  lea rdx, [rip - 0xf7074]                     ; 0x140000000 (이미지 베이스)
0x1400f7074  movzx eax, byte ptr [rdx + rcx + 0xf8494]    ; **바이트 색인 표**(베이스+0xf8494), ID 로 색인
0x1400f707c  mov ecx, dword ptr [rdx + rax*4 + 0xf8480]   ; **점프 표**(베이스+0xf8480)
0x1400f7083  add rcx, rdx
0x1400f7086  jmp rcx
```

점프 표 5엔트리 → 암(arm) → 슬롯 번호(`ebx`):

| 색인 | 암 VA | `ebx` | cbuffer |
|---:|---|---:|---|
| 0 | `0x1400f7088` | 1 | `g_bufDynamic` |
| 1 | `0x1400f709d` | 0 | `g_bufStatic` |
| 2 | `0x1400f708f` | 2 | `g_bufAnimation` |
| 3 | `0x1400f7096` | 3 | `g_bufLights` |
| 4 | `0x1400f709d` | 0 | (텍스처 ID 전용 채움 — ①이 먼저 잡아 **도달 불가**) |

**③ 방출부**(레지스터 번호가 상수로 박혀 있다):

| cbuffer | `cbuffer ` | 이름 | 레지스터 상수 | 내용 |
|---|---|---|---|---|
| `g_bufStatic` | `0x1400f72c2` | `0x1400f72d3` (표 엔트리 0) | `0x1400f7309` `xor edx,edx` → **b0** | 누산기 `[rbp+0x00]` |
| `g_bufDynamic` | `0x1400f73aa` | `0x1400f73bb` (표 엔트리 1) | `0x1400f73f1` `mov edx,1` → **b1** | 누산기 `[rbp+0x20]` |
| `g_bufAnimation` | `0x1400f7e60` | `0x1400f7eb1` | `0x1400f7f0d` `mov byte,0x32` → **b2** | **고정 텍스트** `const float4x3 g_Bones[BONECOUNT];` (`0x1400f7f81`→`0x1404875e0`) |
| `g_bufLights` | `0x1400f74db` | `0x1400f74f2` | `0x1400f751d` `mov byte,0x33` → **b3** | **고정 텍스트** LightingV1 라이트 배열 전부 |

표 둘 다 **`.text` 안 데이터**다 — MSVC 가 함수 뒤에 붙인 것이라 `sub_1400f5cb0` 의 `.pdata`
범위 안에 있지만 명령이 아니다. 그래서 여기서는 절대 VA 대신 **이미지 베이스 상대 오프셋**으로
적는다(명령이 인코딩한 그대로 — 명령 경계 검사기가 명령으로 오독하지 않게).

**④ 자기검증 셋.** 바이트 색인 표(베이스+0xf8494, 140바이트)를 그대로 읽으면 세 군데가 의미와 정확히 맞는다:

- 색인 `4` 인 자리 = **정확히 ID 32..41 열 개** — ①의 텍스처 범위와 일치.
- 색인 `3` 인 자리 = **정확히 ID 120..134 열다섯** — `g_LPoint_Color`..`g_LFeature_ShadowPointProjectionTransform`,
  즉 `#require LightingV1` 생성기가 만드는 집합과 같다.
- 색인 `2` 인 자리 = **ID 113 하나** — `g_Bones`. ③의 `g_bufAnimation` 고정 텍스트와 일치.

**⑤ 결과 — 140/140.**

| cbuffer | 수 | 유니폼 |
|---|---:|---|
| **`g_bufStatic`(b0)** | 5 | `g_TexelSizeHalf`(6) · `g_TexelSize`(7) · `g_Screen`(8) · `g_TextureReductionScale`(92) · `g_HDRParams`(139) |
| **`g_bufAnimation`(b2)** | 1 | `g_Bones`(113) |
| **`g_bufLights`(b3)** | 15 | `g_LPoint_Color`(120) · `g_LPoint_Origin`(121) · `g_LSpot_Color`(122) · `g_LSpot_Origin`(123) · `g_LSpot_Direction`(124) · `g_LSpot_Exponent`(125) · `g_LTube_Color`(126) · `g_LTube_OriginA`(127) · `g_LTube_OriginB`(128) · `g_LDirectional_Color`(129) · `g_LDirectional_Direction`(130) · `g_LFeature_ShadowProjection`(131) · `g_LFeature_ShadowProjectionTransform`(132) · `g_LFeature_ShadowPointProjection`(133) · `g_LFeature_ShadowPointProjectionTransform`(134) |
| **텍스처(cbuffer 아님)** | 10 | `g_Texture0`..`g_Texture9`(32..41) → `t`/`s` 레지스터 |
| **`g_bufDynamic`(b1)** | **109** | 나머지 전부 |

**⑥ 이게 왜 중요한가 — `g_TexelSize` 규약이 여기서 갈린다.**

`g_bufStatic` 에 든 다섯 개는 전부 **"리사이즈/로드에 한 번" 성격**이다(화면 크기, 그 역수,
그 절반, 텍스처 축소 배율, HDR 디스플레이 파라미터). 반대로 **바인드마다 바뀌는**
`g_TextureNResolution`(62..71)·`g_TextureNTexel`(72..81) 은 전부 `g_bufDynamic` 이다. 즉
"패스/바인드마다 바뀌는 것" 과 "해상도 변화 때만 바뀌는 것" 이 **버퍼로 갈라져 있다.**

→ 따라서 `g_TexelSize`/`g_TexelSizeHalf`/`g_Screen` 은 **패스 타깃이 아니라 풀해상도
프레임버퍼 기준이고 이펙트 체인 전 구간에 걸쳐 상수**다. §4 가 "풀해상도 프레임버퍼 역수 ·
리사이즈" 라고 적어 둔 것을 **버퍼 배정이 뒷받침한다**(종전엔 정본에서도 "보고" 상태였다).
Waple 은 `1/eng.targetRes.xy`(= 이펙트 **출력 dst**)와 `texRes[0]` 근사를 쓰므로 **갈린다** —
§7.4 참조. 다만 `eng.targetRes`/`eng.texRes` 를 채우는 자리는 이 문서 소관 밖이라 미수정이다.

**⑦ 리드백은 크기만 본다.** `sub_1400dc080`(범위 `0x1400dc080`..`0x1400dc0a3` 조각, `primary()`)이
컴파일된 셰이더의 리플렉션(`GetConstantBufferByIndex` → `GetDesc`)을 훑어 이름을 위 4종과
**대소문자 무시로**(`_stricmp` `0x1402c10d0`, `0x1400dc0e7`) 대조하고, `D3D11_SHADER_BUFFER_DESC`
의 `Size`(구조체 `+0x10` = `[rsp+0x30]`)를 **u16 으로 잘라** `[r14 + slot*2]` 에 적는다
(`0x1400dc102`–`0x1400dc109`). 이름이 안 맞으면 인덱스가 `-1` 이라 배열 앞 2바이트에 버려진다.
**즉 엔진이 cbuffer 에서 되읽는 것은 바이트 크기뿐이다** — 유니폼별 오프셋은 리플렉션이 아니라
조립 순서가 정한다.

### 3.2 문자열 전수 스캔 (ASCII + UTF-16LE)

`g_[A-Za-z0-9_]{1,48}` 를 두 인코딩으로, **44개 바이너리**(wallpaper64/32, launcher, `bin/*.{exe,dll}` 41개) 전부에 돌렸다.

| 바이너리 | ASCII 고유 | UTF-16LE 고유 |
|---|---:|---:|
| `wallpaper64.exe` | **150** | 1 |
| `wallpaper32.exe` | 159 | 1 |
| `wallpaperui.exe` | 145 | 2 |
| `resourcecompiler64.exe` | 0 | 1 |
| `scenescript64.dll` | 4 | 1 |
| `dxcompiler.dll` | 6 | 1 |
| 나머지 38개 | 0~1 | 0~2 |

- **UTF-16 은 전부 무관**하다. 44개 중 32개가 똑같이 `g_point_value` 하나만 내놓는데 이건 CRT
  로캘 코드다. 유니폼 이름은 **UTF-16 으로 저장되지 않는다** — WE 는 셰이더 이름을 전부
  `char` 로 다룬다.
- `wallpaper64.exe` ASCII 150 = 레지스트리 140 + `g_Texture`(어노테이션 정규식 접두사)
  + cbuffer 4 + HLSL 텍스처 3 + **잡음 2**(`g_7`@`0x14049b43c`, `g_8`@`0x14049b674` — 둘 다
  `"33_7"`/`"7]_8"` 류 숫자 문자열 테이블에 우연히 생긴 부분열이다).
- 레지스트리 140개는 **전부** `wallpaper64.exe` 문자열에 있다(누락 0).
- `wallpaper32.exe` 의 +14개(`g_Al`·`g_Alf`·`g_Co`·`g_Da`·`g_Eff`·`g_Ey`·`g_Fr`·`g_Mo`·
  `g_Mof`·`g_Sc`·`g_Te`·`g_Tef`·`g_Ti`·`g_Vi`)는 **문자열이 아니라 `.text` 안의 imm32** 다.
  32비트 빌드는 SSO 이름을 `.rdata` 에서 읽지 않고 **4바이트씩 즉치로 박는다** —
  `C7 84 24 88 01 00 00 | 67 5F 41 6C` = `mov dword ptr [esp+0x188], 'g_Al'`(오프셋 `0x1422`).
  `g_Alf`·`g_Tef`·`g_Mof` 의 끝 `f` 는 뒤따르는 `66`(operand-size prefix)을 정규식이
  같이 먹은 것이다. **새 유니폼이 0개**이고, 이 함정은 64비트에도 그대로 있다 —
  §1.1 의 "SSO 인라인 14개" 가 `lea` 없이 들어오는 것과 같은 현상이다.
- `wallpaperui.exe` 145 = 레지스트리 140 + `g_Texture` + cbuffer 4. **에디터 UI 가 같은
  테이블을 공유**한다. `resourcecompiler64.exe` 가 0인 것도 정합한다 — 컴파일러는 이름을
  소스에서 읽지 테이블에서 읽지 않는다.
- 부류 C 238개는 **44개 바이너리 어디에도 없다**. 이 절이 §2.2 의 판정을 지지하는 유일한 증거다.

---

## 4. 값의 출처와 갱신 주기

이 문서가 **직접 확정한 것**만 적는다. 기존 정본이 이미 확정한 항목은 참조로 넘긴다.

| 유니폼 | 출처 | 주기 | 근거 |
|---|---|---|---|
| `g_Time` (ID 3) | 씬 클록(초) | 프레임 | 소비처 190파일. 피드 VA `[미해결]` — **[부분 해소 2026-08-21]** 선언 방출은 §3.1b 가 열었고(`g_bufDynamic` b1), 그 버퍼에 **값을 올리는** Map/Unmap 자리는 여전히 못 짚었다 |
| `g_Frametime` (ID 4) | 직전 프레임 Δt | 프레임 | 소비처 20파일 |
| `g_Daytime` (ID 5) | 하루 중 시각 | 프레임(추정) | **동봉 셰이더 소비 0건** — 재생목록 `daytime` 모드와 같은 소스로 보이나 확정 못 함 |
| `g_PointerPosition` / `…Last` / `g_PointerState` (105/104/106) | 커서 | 프레임 | `cursorripple`·`fluidsimulation`·**`xray`** 가 소비(각 12·8·8파일). **[2026-08-21] `g_PointerState` 는 `.z` 만 읽힌다** — 설치본·동봉 4파일 전건이 `.z` 뿐이고 `.x/.y/.w` 소비 0건(`cursorripple_apply_force.frag:83` ×5.0 · `fluidsimulation_vorticity.frag:198` 게인 1 + 프리뷰 사본). 그 `.z` 는 **누른 첫 프레임에만 1.0**(엣지) — `docs/re/pointer-interaction.md` §4 |
| `g_ParallaxPosition` (107) | 시차 컨트롤러 | 프레임 | `depthparallax` 4파일 |
| `g_AudioSpectrum{16,32,64}{Left,Right}` (98..103) | 오디오 캡처 | 프레임 | `docs/re/audio-capture.md` |
| `g_TexelSize` / `…Half` (7/6) | 풀해상도 프레임버퍼 역수 | 리사이즈 | `spec/engine/uniform-feed.json` — **피드부 미독**이라 그쪽도 "보고" 상태 |
| `g_TextureNResolution` (62..71) | 바인드된 텍스처 (paddedW, paddedH, imageW, imageH) | 바인드 시 | `spec/engine/uniform-feed.json` |
| `g_TextureNTexel` (72..81) | (1/w, 1/h, w, h) | 바인드 시 | `model_vertex_v1.h` 가 `.z` 를 정수 치수로 씀 |
| `g_TextureNMipMapInfo` (82..91) | 밉 개수 | 바인드 시 | `generic4.frag:159` `roughness * g_Texture3MipMapInfo` |
| `g_TextureNRotation` / `…Translation` (42..61) | 레이어 UV 2×2 + 오프셋 | 드로우 | `passthrough.vert:22` `v_TexCoord.xy = g_Texture0Translation + a_TexCoord.x*g_Texture0Rotation.xy + a_TexCoord.y*g_Texture0Rotation.zw` |
| `g_ModelMatrix` / `g_ViewProjectionMatrix` / `g_ModelViewProjectionMatrix`(+Inverse) (9..13) | 행렬 스택 | 드로우 | |
| `g_Alt*Matrix` (15..17) | 보조(반사·2번째 뷰) 행렬 스택 | 드로우 | |
| `g_Effect*Matrix` (19..23) | 이펙트 쿼드 로컬 행렬 | 드로우 | |
| `g_ViewportViewProjectionMatrices[6]` (18) | 큐브맵/멀티뷰 6면 | 패스 | 소비 6파일(전부 built-in) |
| `g_EyePosition` `g_ViewForward/Right/Up` (25..28) | 카메라 | 프레임 | |
| `g_Orientation{Forward,Right,Up}` (29..31) | 스프라이트 빌보드 축 | 드로우 | `docs/re/sprite-occlusion.md` |
| `g_Lights*` (93..97) / `g_L{Point,Spot,Tube,Directional}_*` (120..130) / `g_LFeature_*` (131..134) | 씬 라이트 | 프레임 | `Sources/WapleCore/SceneDocument.swift:658-674` 가 팩 규약 기록 |
| `g_Bones` `g_BonesAlpha` (113/114) | 스켈레톤 포즈 | 프레임 | `docs/re/skeleton-animation.md`. cbuffer `g_bufAnimation` 후보 |
| `g_Morph*` (116..119) | 모프 타깃 | 프레임 | `model_vertex_v1.h` |
| `g_Fog{Distance,Height}{Color,Params}` (135..138) | 씬 `general.fog*` | 씬 로드 | `spec/engine/uniform-feed.json` `sceneDefaults` 변위 `0x380`/`0x38c`/`0x398`..`0x3b4` |
| `g_LightAmbientColor` / `g_LightSkylightColor` (96/97) | 씬 `general.ambientcolor` `0x368` / `skylightcolor` `0x374` | 씬 로드 | 같은 정본. 기본 검정 `(0,0,0)` |
| `g_HDRParams` (139) | HDR 디스플레이 파라미터 | 리사이즈/디스플레이 변경 | 소비 4파일, 산출식 `[미해결]`. **[성분 의미 해소 2026-08-21]** `.x` = **SDR 화이트 스케일**(선형값을 이걸로 나눈 뒤 sRGB 인코드 — `shaders/passthroughlinear.frag:14` `albedo.rgb = _srgb(albedo.rgb / g_HDRParams.x)`), `.y` = **피크 HDR 의 절반**(`combine_video_hdr.frag:10` `float maxHDR = g_HDRParams.y * 2.0;` 뒤 `/maxHDR → saturate → *maxHDR` 로 클램프). 주기는 §3.1b 가 확정 — `g_bufStatic`(b0) |
| `g_RenderVar0..4` (108..112) | **고정 의미 없음** — 드로우를 소유한 서브시스템이 채우는 범용 vec4 5칸 | 드로우 | `spec/engine/uniform-feed.json` `g_RenderVar` |
| `g_Alpha` `g_Color` `g_Color4` (0..2) | 레이어 알파/틴트 | 드로우 | |
| `g_Screen` (8) | (w, h, w/h) | 리사이즈 | 소비 18파일 |
| `g_TextureReductionScale` (92) | 텍스처 축소 배율 | 텍스처 로드 | `blend.vert` TRANSFORMUV 가 UV 를 이 값으로 나눔 — **0 이면 ÷0** |
| `g_BlendMap[BLENDROWCOUNT]` (115) | 퍼펫 블렌드 행렬 | 프레임 | 소비 2파일 |
| `g_LayerModelMatrix` (24) | — | — | **동봉 소비 0건**, 용도 `[미해결]` — **[미해소]** 소비처가 0 이라 역산할 자산이 없고, §3.1b 는 배정(`g_bufDynamic` b1 = 드로우 주기)만 알려 준다. 이름·주기·이웃 ID(23 `g_EffectTextureProjectionMatrixInverse` / 25 `g_EyePosition`)로 보아 **레이어 쿼드의 모델 행렬**로 보이나 근거 부족 |

---

## 5. 엔진 상수 / 기본값 (VA)

| 값 | VA | 무엇 |
|---|---|---|
| `0x8c` = 140 | `0x1400042fd` | 레지스트리 원소 수 (`mov r8d, 0x8c`) |
| `0x28` = 40 | `0x1400042f8` | 원소 stride (`mov edx, 0x28`) |
| 배열 시작 `rbp+0x10` | `0x140004303` | |
| 정렬 비교자 | `0x1400172b0` (→ `jmp 0x140017240`) | |
| 정렬 루틴 | `0x140005c10` | |
| 전역 맵 설치 | `0x14016f990` | 맵 객체 `0x1404e8100`, 버킷 초기 크기 `0x10`/`7`/`8`(`0x14016f9d0`, `0x14016f9f6`, `0x14016fa01`), 로드팩터 `1.0f` = `0x3f800000`(`0x14016fa0c`) |
| 이름→ID 조회 | `0x14016f740` | 유일 호출부 `0x1400dac4c` |
| 리플렉션 바인딩 | `0x1400dab40..0x1400dc075` | ID 저장 `0x1400db21e` (`mov [r15+0x60], eax`) |
| cbuffer 이름 테이블 | `0x140484b60` (4×8B) | §3.1 |
| 문자열 ctor A | `0x14016f7a0` | `(dest, str, &id)` — id 를 `[rdi+0x20]` 에 복사 |
| 문자열 ctor B | `0x140017480` | `(dest, str, len)` — id 는 호출부가 따로 씀 |
| 전용 헬퍼 5 | `0x14016f800` `0x14016f850` `0x14016f8a0` `0x14016f8f0` `0x14016f940` | 각 함수 안에 이름 문자열 + 길이 상수(`0x17`/`0x1a`/`0x18`/`0x24`/`0x29`) |
| 이름 문자열 블록 | `0x14048d138..0x14048dd94` | 140개 대부분이 여기. 예외 **4개** — 텍스처 이름 셋 `0x140477be8`(`g_Texture0MipMapped`) · `0x140477c00`(`g_Texture1Noise`) · `0x140477c10`(`g_Texture2Clouds`) 과 `0x14048d120`(`g_Texture`, 블록 바로 앞 24바이트). **[정정 2026-09-01] 종전 이 칸은 `g_Bones` 를 `0x1404875f3` 로 예외에 넣고 있었다** — 정본 `spec/engine/uniforms.json` 은 `g_Bones` 를 `0x14048daf8` 로 이미 고쳤고 그 주소는 이 블록 **안**이라 더 이상 예외가 아니다. `0x1404875f3` 는 아래 「HDR 소비 문자열」 행의 `0x1404875e0`(`")\n{\nconst float4x3 g_Bones["`) 계열 — 이름 문자열이 아니라 HLSL 조립기가 뱉는 **선언 텍스트**다. 두 주소가 같은 식별자를 담고 있어 섞였다 |
| **GLSL→HLSL 조립기** | `0x1400f5cb0..0x1400f8520` | §3.1b. 유니폼 선언을 `cbuffer`/`Texture2D`/`SamplerState` 텍스트로 조립 |
| ID 라우팅 진입 | `0x1400f6d8b` (`movsxd rcx, dword ptr [rdx + 0x30]`) | 맵 노드에서 유니폼 ID 를 꺼낸다 |
| 텍스처 범위 검사 | `0x1400f6d8f` / `0x1400f6d98` / `0x1400f6da1` | ID 32..41 → 슬롯 = ID − 0x20 |
| cbuffer 점프 표 | `0x1400f7074`(바이트 색인, 베이스+0xf8494) · `0x1400f707c`(점프, 베이스+0xf8480) | 암 `0x1400f7088`=1 · `0x1400f709d`=0 · `0x1400f708f`=2 · `0x1400f7096`=3 |
| cbuffer 레지스터 상수 | `0x1400f7309`(b0) · `0x1400f73f1`(b1) · `0x1400f7f0d`(b2, `'2'`) · `0x1400f751d`(b3, `'3'`) | |
| cbuffer 크기 리드백 | `0x1400dc080` | 리플렉션 이름을 `_stricmp`(`0x1400dc0e7`)로 4종과 대조 → `Size` 하위 16비트를 `[r14+슬롯*2]`(`0x1400dc109`) |
| HDR 소비 문자열 | `0x140487618`(`"cbuffer "`) · `0x1404875d0`(`":register(b"`) · `0x1404875e0`(`")\n{\nconst float4x3 g_Bones["`) | §3.1b ③ |

`g_BloomBlendParams` soft-knee 상수(ε `1e-5`, 분자 `0.25`, `codeVA 0x14017f8bc`)와
HDR 블룸 기본값(`bloomstrength 2.0` / `bloomthreshold 0.65` / `bloomhdrscatter 1.619` /
`bloomhdriterations 8`, ctor `0x140186c90`, 파서 `0x140199780`)은
`spec/engine/uniform-feed.json` 이 이미 확정했다 — 재측정해서 일치 확인만 했다.

---

## 6. 동봉 도달 실측

### 6.1 코퍼스 규모

| 축 | 수 |
|---|---:|
| 셰이더 파일(설치본 592 + 동봉 502) | **1,094** |
| 그중 `g_*` 를 하나라도 쓰는 파일 | 1,037 (설치본 562 / 동봉 475) |
| 고유 `g_*` 이름 | **340** |
| 씬 파일(`scene.json`/`gifscene.json`/`project.json→file`) | **362** |
| 그중 non-preview | **28** |

non-preview 28 = `projects/defaultprojects/**` 12(arsenal, beach, deep_space, demon_core,
dino_run, dna_fragment, eagleflag, neon_sunset, razer_bedroom, razer_vortex, retro,
shimmering_particles) + `.mdl` 기반 4(audiophile, fantasticcar, ricepod, techno) +
`projects/templates/**` 2 + `assets/scenes/**` 5(gifs, modeleditor, particleeditor,
particleeditor3dscale, videoplayer) ×(설치본/동봉 중복 5).

**측정 한계**: `.mdl`(바이너리 모델) 을 쓰는 4개 프로젝트는 재질 참조가 바이너리 안에 있어
JSON 그래프로 못 따라간다. 그 4개는 **프로젝트의 `materials/**/*.json` 전부를 도달로 근사**했다.
과대 추정일 수 있다.

### 6.2 출현 상위 20

| # | 이름 | 출현 | 선언파일 | 부류 |
|---:|---|---:|---:|---|
| 1 | `g_Texture0` | 2079 | 505 | A |
| 2 | `g_Texture1` | 772 | 290 | A |
| 3 | `g_ModelViewProjectionMatrix` | 746 | 365 | A |
| 4 | `g_Texture1Resolution` | 684 | 154 | A |
| 5 | `g_Texture0Resolution` | 620 | 230 | A |
| 6 | `g_Time` | 545 | 190 | A |
| 7 | `g_Texture2` | 393 | 178 | A |
| 8 | `g_Texture2Resolution` | 326 | 70 | A |
| 9 | `g_Scale` | 212 | 84 | **C** |
| 10 | `g_Bones` | 210 | 18 | A |
| 11 | `g_ModelMatrix` | 157 | 45 | A |
| 12 | `g_Speed` | 144 | 55 | **C** |
| 13 | `g_Texture3` | 139 | 66 | A |
| 14 | `g_NoiseAmount` | 122 | 34 | **C** |
| 15 | `g_Direction` | 122 | 39 | **C** |
| 16 | `g_Point0` | 104 | 52 | **C** |
| 17 | `g_Point1` | 104 | 52 | **C** |
| 18 | `g_NoiseScale` | 101 | 34 | **C** |
| 19 | `g_Feather` | 100 | 20 | **C** |
| 20 | `g_Point2` | 96 | 48 | **C** |

상위 20 중 **12개가 부류 C** — 즉 "많이 쓰이는 `g_` 이름" 과 "엔진 유니폼" 은 상관이 약하다.
전체 순위표는 §1.2(A 140행)와 §2.3(C 238행)에 절단 없이 실려 있다.

---

## 7. Waple 대조

### 7.1 Waple 의 세 레인

| 레인 | 무엇 | 유니폼 처리 |
|---|---|---|
| **L1 GLSL→MSL 번역** | 이펙트 셰이더 + 프로젝트 커스텀 셰이더 | `Sources/WapleCore/GLSLTranslator.swift`. `isEngine(name)`(`:1320-1361`)이 참이면 `engineReplacement(name)`(`:1362-1441`)이 MSL 식으로 **텍스트 치환**. 거짓이면 머티리얼 파라미터로 등록(`:200-212`) |
| **L2 네이티브 하드포트** | WE built-in 셰이더(`generic*` / `genericimage*` / bloom / volumetric / particle / quad) | MSL 로 재구현. 유니폼 **이름 없이 등가 필드**로 채운다. `SceneDocument.swift:667-670` 이 명시: *"라이트를 참조하는 원본 머티리얼 셰이더(generic*/genericimage2)는 로드·번역되지 않는다"* |
| **L3 머티리얼 파라미터** | 부류 C 238개 | `key = annotationMaterial ?? lowercased(name-g_)`, 기본값 = `"default"` 어노테이션. **설계상 정합** |

L1 의 엔진 유니폼 버퍼는 하나다:

```
struct EngineU { float4x4 mvp; float4 timeAndPad; float4 pointerLastAndPad;
                 float4 texRes[8]; float4 texWrap[2]; float4 texFilter[2];
                 float4 layerTint; float4 targetRes; };
```
(`GLSLTranslator.swift:1942`, 채우는 곳 `SceneRendererFrameEncoder.swift:43-67`)

### 7.2 판정 집계 — 레지스트리 140 기준

| 판정 | 수 | 뜻 |
|---|---:|---|
| **채움** | 46 | L1 이 실값으로 치환 |
| **부분** | 31 | L1 이 인식은 하나 **상수/항등/영벡터**를 넣는다 |
| **미채움** | 63 | L1 이 머티리얼 파라미터로 강등 → **기본 0** |

행별 판정은 §1.2 표의 마지막 세 열에 전부 있다(절단 없음).

**"미채움 63" 을 그대로 읽으면 안 된다.** 63개 중 **56개는 저작레인 도달이 0** — 즉 built-in
셰이더만 그 이름을 쓰고, built-in 은 L2 가 하드포트하므로 L1 에 절대 안 닿는다.
실제로 문제가 되는 건 **저작레인 도달 > 0 인 7개**다.

### 7.3 우선순위 — 저작레인(L1) 에 실제로 닿는 결손

**미채움 7개**(§7.2 의 63개 중 저작레인 도달 > 0 인 전부) + 참고로 "부분" 1개.

| 순위 | 유니폼 | 판정 | 타입 | 저작레인 파일 | np 씬 | Waple 값 | 증상 | L2 등가 |
|---:|---|---|---|---:|---:|---|---|---|
| 1 | `g_EyePosition` | 미채움 | `vec3` | **12** | 12 | `(0,0,0)` | 뷰 벡터가 원점 기준 → 스페큘러/프레넬/시차 전부 어긋남. `audiophile/grid`, `demon_core/core`, `dna_fragment/dna`, `fantasticcar/car`+`grid`, `ricepod/ricepod` 등 | 있음(3D 레인 카메라) |
| 2 | `g_LightsPosition` | 미채움 | `vec3[4]` | 5 | 6 | `0` | `fluidsimulation` **이펙트 본체**(preview 아님) + `demon_core/core.vert` — 조명 위치 소실 | 있음(`Scene3DLighting`) |
| 3 | `g_LightsColorPremultiplied` | 미채움 | `vec4[3]` | 2 | 4 | `0` | `fluidsimulation_combine.frag` 조명색 0 = 검정 | 있음 |
| 4 | `g_ViewRight` / `g_ViewUp` | 미채움 | `vec3` | 각 1 | 4 | `0` | `ricepod/sprite.vert` 빌보드 축 0 → **스프라이트 붕괴** | 없음 |
| 5 | `g_LightsColorRadius` | 미채움 | `vec4[4]` | 1 | 2 | `0` | `demon_core/core.frag` 감쇠 반경 0 | 있음 |
| 6 | `g_RenderVar1` | 미채움 | `vec4` | 1 | 4 | `0` | `shimmering_particles/particle.vert` — 파티클 스프라이트시트 파라미터(`common_particles.h` 규약) 소실 | 부분(볼류메트릭 전용) |
| — | `g_TextureReductionScale` | 부분 | `float` | 4 | 0 | **중립 1** | `blend.vert`/`skew.vert` TRANSFORMUV. 중립 폴백이 있어 ÷0 은 피함 | — |

또 하나의 축 — **"부분" 이지만 저작레인 도달이 큰 것**:

| 유니폼 | 저작레인 | np | Waple 대체 | 위험 |
|---|---:|---:|---|---|
| `g_ViewProjectionMatrix` | 12 | 11 | `float4x4(1)` | 3D 커스텀 셰이더가 자기 투영을 하면 화면 밖으로 나감 |
| `g_ModelMatrix` | 11 | 11 | `float4x4(1)` | 월드 변환 소실 |
| `g_EffectTextureProjectionMatrixInverse` | 14 | 0 | `float4x4(1)` | `depthparallax` — 회전 추출이 항등 |
| `g_EffectModelViewProjectionMatrixInverse` | 6 | 0 | `float4x4(1)` | |
| `g_EffectModelMatrix` / `g_EffectTextureProjectionMatrix` | 각 4 | 0 | `float4x4(1)` | |
| `g_ModelViewProjectionMatrixInverse` | 2 | 0 | `float4x4(1)` | |

### 7.4 이름 불일치 · 값 규약 불일치

| 유니폼 | WE | Waple | 결과 |
|---|---|---|---|
| `g_TextureNResolution` | `(paddedW, paddedH, imageW, imageH)` — `.zw` 는 **패딩 제거 전 실제 이미지 치수**(`spec/engine/uniform-feed.json`) | `texRes[n] = (w, h, w, h)` (`SceneRendererFrameEncoder.swift:57-61`, `SceneRenderer3D.swift:1132-1146`) | **패딩된 TEX 에서 `.z/.x` 비율이 항상 1** → `common_particles.h:71` `unpaddedWidth = g_Texture0Resolution.z / .x` 가 무력화. 패딩 TEX 를 쓰는 파티클/퍼펫에서 UV 어긋남 |
| `g_TextureNTexel` | `(1/w, 1/h, w, h)` | 같음 (`float4(1/texRes.xy, texRes.xy)`) | 일치 |
| `g_ParallaxPosition` | 시차 컨트롤러 출력(별도 유니폼) | `g_PointerPosition` 과 **같은 필드 별칭** | 시차 감쇠/지연(`cameraparallaxdelay`, `cameraparallaxamount`)이 반영 안 됨 |
| `g_Screen` | `vec3` — 소비처 18파일 | `float3(texRes[0].xy, texRes[0].x/texRes[0].y)` = **tex0 근사** | 이펙트 패스에서 tex0=프레임버퍼면 맞고, 아니면 어긋남. 코드 주석이 미확정임을 명시 |
| `g_TexelSize` | 풀해상도 프레임버퍼 역수(전 패스 불변) | `1/eng.targetRes.xy` = **이펙트 출력(dst)** 역수 | 종전엔 두 규약 다 "확정 아님"이었다. **[2026-08-21] WE 쪽이 확정됐다** — §3.1b ⑥: `g_TexelSize`/`…Half`/`g_Screen` 은 `g_bufStatic`(b0)이고 바인드마다 바뀌는 `g_TextureNResolution`/`…Texel` 은 `g_bufDynamic`(b1)이라 **버퍼가 주기를 가른다**. 즉 실물은 패스 타깃이 아니라 풀해상도 기준이다. Waple 은 갈린다 — 고치려면 `eng.targetRes` 를 채우는 `SceneRendererFrameEncoder`(이 문서 소관 밖)를 함께 바꿔야 하고 **화면이 바뀐다**(bokeh 계열 블러 폭). 넘김 |
| `g_Alpha` / `g_Color` / `g_Color4` | 엔진이 매 프레임 레이어 알파·틴트 주입 | 유니폼은 **중립 1**, 실제 틴트는 출력 후 `eng.layerTint` 곱(`GLSLTranslator.swift:2021-2022`) | 결과는 등가지만 **셰이더가 `g_Alpha` 를 산술에 쓰면**(단순 곱이 아니면) 어긋남 |
| `g_NormalModelMatrix` `g_AltNormalModelMatrix` | 전건 **`mat3`** | ~~`isEngine` 이 `contains("Matrix")` 로 잡아 **`float4x4(1.0)`** 반환~~ → **[해소 2026-08-21]** 선언 타입을 보고 `float3x3(1.0)` 반환 | 종전엔 `mul(vec3, mat3)` 자리에 `float4x4` 가 들어가 **MSL 컴파일 실패 → 폴백**이었다. `GLSLTranslator.engineDeclaredTypes` 가 선언 타입 표를 만들어 치환·헬퍼 캡처 양쪽에 먹인다. 도달: 설치본 502 셰이더 중 **선언 7파일 / 본문 소비 9쌍**(`generic4` · `genericimage2/3/4` 직접 4 + `base/model_vertex_v1.h` 인클루드 5: `chroma4` · `foliage4` · `fur4` · `shadowcasterfoliage4` · `shadowcasterfur4`). `mat3 g_ModelMatrix` 를 쓰는 **`audiophile/shaders/grid.vert:2`·`fantasticcar/shaders/grid.vert:2` 는 저작 셰이더라 L1 에 닿는다**(선언만 하고 본문 미사용이라 종전에도 컴파일은 안 깨졌다) |
| `g_Daytime` | 레지스트리 ID 5 | 없음 | 동봉 소비 0건이라 현시점 무해 |

### 7.5 부류 C(238) 대조

L3 경로는 `annotationMaterial` 을 그대로 키로 쓰고 `"default"` 어노테이션을 기본값으로 쓴다 —
**238개 전부 설계상 정합**이다. 개별 이펙트의 수식 이식 여부는 별개 축이고
`Sources/WapleRender/EffectShaders.swift` 가 손포팅한 이펙트에 한해 실측 대조돼 있다
(`g_Speed` 기본값 1 vs 구코드 5 같은 정정 이력이 그 파일 주석에 남아 있다).

주의할 함정 하나: `defaultKey()` 폴백(`lowercased(name - "g_")`)은 **어노테이션이 없을 때만**
쓰인다. §2.5 처럼 **86개 이름이 다중 키**를 갖고 `Brigtness` 같은 오타 키까지 있으므로 **이름으로 키를 추론하는 코드를 새로 쓰면 안 된다.**

---

### 7.6 [신설 2026-08-21] 유니폼 밖의 같은 클래스 — `attribute` 화이트리스트

이 문서는 유니폼 census 지만, **같은 "이름을 알아보는가" 축**에 하나가 더 있고 그쪽 도달이
§7.3 의 1·2위와 겹치므로 여기 적어 둔다.

`GLSLTranslator` 가 방출하는 정점 입력 구조체는 **두 attribute 로 고정**이다:

```
struct VIn { float3 a_Position [[attribute(0)]]; float2 a_TexCoord [[attribute(1)]]; };
```

`parseAttributes` 는 선언된 이름을 전부 `vin.<이름>` 으로 매핑하므로, 그 밖의 attribute 를
선언한 셰이더는 **`VIn` 에 없는 멤버를 참조**해 MSL 컴파일이 확정 실패한다(→ 폴백).

**도달(설치본 `assets/` + `projects/` 의 `.vert`/`.h` 전수).**

| attribute | 선언 파일 | 그중 저작레인(`projects/` · `effects/`) |
|---|---:|---:|
| `a_Position` | 282 | 226 |
| `a_TexCoord` | 272 | 225 |
| **`a_Normal`** | 17 | **8** |
| `a_Color` | 9 | 1 |
| `a_BlendIndices` / `a_BlendWeights` | 10 / 9 | 0 |
| `a_Tangent4` | 8 | 1 |
| `a_TexCoordVec4` 계열 · `a_PositionVec4` 등 | 각 1~7 | 0~1 |

저작레인 8건은 전부 **non-preview 기본 프로젝트**다 —
`audiophile/{audiophile,grid}.vert` · `demon_core/core.vert` · `dna_fragment/dna.vert` ·
`fantasticcar/{car,grid}.vert`(+`a_Tangent4`) · `ricepod/ricepod.vert` · `techno/technohex.vert` ·
`shimmering_particles/particle.vert`(`a_Color` + `a_TexCoordC2`/`a_TexCoordVec4`/`a_TexCoordVec4C1`).

즉 **§7.3 1위 `g_EyePosition`(저작레인 12파일)과 2위가 걸린 바로 그 프로젝트들**이 attribute
쪽에서도 걸린다. 유니폼을 고쳐도 이쪽이 남으면 그 셰이더들은 여전히 컴파일에 실패한다.

이건 이미 알려진 항목이다 — `Sources/WapleRender/SceneRenderer3D.swift` 의
`builtinMeshShaderWhitelist` 주석이 *"generic/generic2/generic3/generic4.vert 는 전부 a_Normal 을
무조건 참조하는데 VIn 은 a_Position/a_TexCoord 만 지원 … GLSLTranslator 의 attribute
화이트리스트 확장(a_Normal 추가)이 별도로 필요"* 라고 적고 있다. 여기서 새로 더하는 것은
**저작레인 도달을 수로 잰 것**과, 이 문서의 §7.3 우선순위와 같은 프로젝트를 가리킨다는 사실이다.

**고치려면 두 파일이 함께 가야 한다**(이 라운드 미수행): (a) `GLSLTranslator` 가 참조된
attribute 만 `VIn` 에 조건부로 싣고 그 사실을 `TranslatedShader` 로 알린다, (b)
`SceneRenderer3D.buildCustomMeshShader` 의 정점 디스크립터가 그때만 `attribute(2)` 를 더한다
(메시 정점은 이미 `pos3+normal3+uv2` 8f 라 **법선은 버퍼에 이미 있다** — 오프셋 12).
무조건 싣기는 금지다 — 2D 레이어/이펙트 쿼드는 법선이 없어 파이프라인 생성이 통째로 깨진다.

### 7.7 [신설 2026-08-21] 배선 기록 — `a_Normal` 화이트리스트가 들어갔다

§7.6 은 "고치려면 두 파일이 함께 가야 한다(이 라운드 미수행)" 로 끝났다. 이 절은 그 둘이
**들어간 뒤**의 기록이다. §7.6 본문은 그대로 둔다(툼스톤) — 도달 표는 계속 유효하고,
여기서는 "무엇을 넣었고 무엇을 **일부러 안 넣었나**" 만 적는다.

#### (a) `GLSLTranslator` — 참조된 attribute 만 `VIn` 에 싣는다

`GLSLTranslator.vertexAttributeWhitelist` 가 (이름, 타입, 슬롯) 셋을 정본으로 들고,
`TranslatedShader.vertexAttributes` 가 **실제로 실린 목록**을 밖으로 알린다.

```
[("a_Position", .vec3, 0), ("a_TexCoord", .vec2, 1), ("a_Normal", .vec3, 2)]
```

* 슬롯 **0·1 은 무조건** 싣는다. 이 리포의 정점 디스크립터 셋이 전부 그 둘을 선언하고,
  어느 쪽도 참조하지 않는 셰이더에서 `VIn` 이 비면 `[[stage_in]]` 자체가 불법이 된다.
  두 개만 실린 경우의 방출 문자열은 **종전과 글자 그대로 같다**(무회귀 —
  `GLSLTranslatorTests.testVInIsUnchangedForShadersThatDoNotReferenceExtraAttributes`).
* 슬롯 **2 이상은 조건부**다. 판정은 **번역이 끝난 vertex 본문**에서 `vin.<이름>` 을
  **낱말 단위로** 찾는다(`referencesVertexAttribute`). `vertexBuiltins`(`gl_VertexID` 등)와
  같은 규율이다.
  - **선언을 기준으로 실으면 안 된다.** `#if LIGHTING` 안에서만 쓰이는 `a_Normal` 을
    콤보가 꺼진 구성에서도 실으면, 법선 없는 2D 쿼드 파이프라인이 통째로 깨진다.
    (`testDeclaredButUnreferencedNormalIsNotLoaded` 가 대조군까지 함께 잰다.)
  - **낱말 단위여야 한다.** `a_TexCoord` 는 실물 `a_TexCoordVec4`(6) ·
    `a_TexCoordVec4C1`(4) · `a_TexCoordC2`(1) 의 **접두**라, 단순 `contains` 는
    화이트리스트가 넓어지는 날 조용히 틀린다.

#### (b) `SceneRenderer3D.buildCustomMeshShader` — 그때만 `attribute(2)`

```swift
if t.vertexAttributes.contains("a_Normal") {
    vd.attributes[2].format = .float3; vd.attributes[2].offset = 12; vd.attributes[2].bufferIndex = 4
}
```

**새 버퍼가 필요 없다** — 메시 정점이 이미 `pos3+normal3+uv2`(8f, stride 32)라 법선이
오프셋 12 에 있다. 스키닝 메시도 CPU 프리스킨 뒤 같은 8f 라 같은 디스크립터를 탄다.

**(a)와 (b)는 함께 가야 한다.** (a)만 하면 MSL **컴파일 실패**가 **파이프라인 생성 실패**로
바뀔 뿐이다(둘 다 폴백이지만 진단이 나빠진다). (b)만 하면 아무 일도 안 일어난다.
조건의 단일 출처가 `t.vertexAttributes` 이고, 두 자리가 같은 조건을 본다는 사실을
`GLSLTranslatorTests.testMeshVertexDescriptorWiresNormalUnderTheSameCondition` 이
소스 문면으로 잠근다(리눅스에서 `WapleRender` 를 실행할 수 없어 이것이 유일한 그물이다).

#### 일부러 안 넣은 것 — `a_Color`·`a_Tangent4`·스키닝

§7.6 의 표에서 `a_Color` 9파일(저작레인 1) · `a_Tangent4` 8(1) ·
`a_BlendIndices`/`a_BlendWeights` 10/9(0)은 **그대로 둔다.** 이유는 하나다:
**그 데이터가 정점 버퍼에 없다.** `VIn` 에만 실으면 실패 지점이 컴파일에서 파이프라인
생성으로 옮겨갈 뿐 결말(스톡 폴백)이 같고, 원인 진단만 나빠진다. 버퍼 레이아웃 확장
(`Model3D` 의 정점 패킹 + `prepare3DCustomSkinBuffers` + 디스크립터 stride)이 **선행돼야
하는 별건**이다. `testNonWhitelistedAttributesStayUnloaded` 가 이 결정을 못박는다.

#### 도달 — 무엇이 실제로 달라지나

§7.6 이 센 저작레인 8건(`audiophile/{audiophile,grid}.vert` · `demon_core/core.vert` ·
`dna_fragment/dna.vert` · `fantasticcar/{car,grid}.vert` · `ricepod/ricepod.vert` ·
`techno/technohex.vert`)은 **pkg 안 셰이더**라 env 게이트와 무관하게 이 경로를 탄다.
반면 `SceneRenderer3D.builtinMeshShaderWhitelist` 의 `generic{,2,3,4}` 는 베이스 팩 소스라
`WAPLE_BUILTIN_MESH_SHADERS` 게이트 뒤에 있고, 그 게이트는 **이 변경과 독립**이다 —
게이트가 꺼져 있으면 그 넷은 애초에 이 함수에 들어오지 않는다.
(그래서 `builtinMeshShaderWhitelist` 주석의 "MSL 컴파일 단계에서 실패" 는 `a_Normal` 한
이름에 대해서만 더 이상 사실이 아니다. 그 주석에도 툼스톤을 달았다.)

**2D 경로에서 실패 지점이 옮겨간다(회귀 아님).** 동봉 `.vert` 중 `a_Normal` 을 참조하는 것은
10개인데(`generic{,2,3,4}` · `chroma4` · `foliage4` · `fur4` · `genericimage{3,4}` ·
`HLSL/dx11playlisttransition`), 그중 **`genericimage3`/`genericimage4` 는 2D 이미지 레이어
셰이더**다(`:196`/`:220` `v_WorldNormal = mul(a_Normal, M_NML)`). 그 둘이 씬 패키지 안에 복사돼
있으면 `buildCustomLayerShader` 경로로 들어오는데, 2D 쿼드 정점 버퍼에는 법선이 없다
(`translatedLayerPipeline` 은 `a_Position@0` + `a_TexCoord@12`, stride 20).
→ 종전에는 **MSL 컴파일**이 실패했고 지금은 **파이프라인 생성**이 실패한다. **둘 다 nil 을
돌려주고 `QuadShaders` 로 폴백한다** — 화면은 같다(로그 문구만 "MSL compile error" 에서
"pipeline compile failed" 로 바뀐다). 베이스 팩의 `genericimage*` 는 애초에 그 경로에 못
들어온다(`packageData` 로 pkg 전용, 3394601417 주야 토글 회귀 실증 이후의 정책).

**[미해결] 실제 시각 개선의 A/B 는 안 했다.** 이 컨테이너에는 Metal 도 워크샵 코퍼스도 없다.
확정된 것은 "번역 산출물이 이제 `VIn` 에 `a_Normal` 을 싣고 디스크립터가 같은 조건으로
슬롯 2를 꽂는다" 까지이고, **그 셰이더들이 실제로 컴파일에 성공하는지**는 macOS 판정이다
(다른 결손 — `g_EyePosition` 등 §7.3 의 유니폼 축 — 이 남아 있으면 여전히 실패한다).

## 8. 확정하지 못한 것

1. **`[미해결]` 유니폼별 cbuffer 배정.** `g_bufStatic/Dynamic/Animation/Lights` 4개가 있고
   이름이 주기를 암시하지만, 140개가 각각 어디로 가는지는 GLSL 원문에 없고 바이너리에서도
   못 찾았다. WE 의 HLSL 크로스컴파일러가 정한다.
   → **[해소 2026-08-21]** §3.1b. 크로스컴파일러는 별도 도구가 아니라 `sub_1400f5cb0` 의
   **텍스트 조립기**이고, 배정은 유니폼 **ID 로 색인하는 바이트 표 + 점프 표**가 정한다.
   140/140 확정: Static 5 · Dynamic 109 · Animation 1 · Lights 15 · 텍스처 10(cbuffer 아님).
   **레지스트리에 없는 이름(부류 C 사용자 값)은 `g_bufStatic`(b0)** 이다
   (`0x1400f6d85 je 0x1400f714e` → `xor ebx,ebx`) — `.dxs` 꼬리의 오프셋 표가 그걸 뒷받침한다
   (`docs/re/shader-combos.md` §6.1).
2. **`[미해결]` 유니폼별 피드 사이트 VA.** 리플렉션 바인딩(`0x1400dab40`)이 ID 를 레코드
   `+0x60` 에 넣는 데까지는 따라갔지만, 드로우 시 그 ID 로 값을 꺼내는 소비부는 못 열었다.
   `g_TexelSize`·`g_TextureNResolution` 의 값 규약이 기존 정본에서도 "보고" 로 남아 있는 이유가
   이것이다.
   → **[부분 해소 2026-08-21]** 값 업로드(Map/Unmap) 자리는 **여전히 미해결**이다. 하지만
   §3.1b ⑥ 이 그 미해결이 막고 있던 질문 하나를 **버퍼 배정으로 우회해 답했다** —
   `g_TexelSize`/`g_TexelSizeHalf`/`g_Screen` 은 `g_bufStatic`(b0), `g_TextureNResolution`/
   `…Texel` 은 `g_bufDynamic`(b1)로 **갈라져 있다**. "바인드마다 바뀌는 것" 과 "해상도 변화 때만
   바뀌는 것" 이 서로 다른 버퍼에 있으므로, `g_TexelSize` 는 **패스 타깃이 아니라 풀해상도
   프레임버퍼 기준이고 체인 전 구간 상수**다. 값 자체가 아니라 **주기**가 확정된 것이다.
3. **`[미해결]` 바인딩 레코드 `+0x64`.** ID 바로 뒤에 리플렉션 구조체(`rbp+0x134`)에서 온
   dword 가 하나 더 들어간다. cbuffer 내 오프셋으로 보이지만 확인 못 했다.
   → **[미해소 2026-08-21, 후보 하나 소거]** 명령 쌍을 다시 떴다:
   `0x1400db21e mov dword ptr [r15 + 0x60], eax`(ID) 바로 뒤가
   `0x1400db222 mov eax, dword ptr [rbp + 0x134]` · `0x1400db228 mov dword ptr [r15 + 0x64], eax`.
   **"cbuffer 슬롯 번호" 후보는 소거된다** — 슬롯은 리플렉션 리드백이 아니라 §3.1b 의 HLSL 텍스트
   조립 때 이미 정해지고, 리드백(`0x1400dc080`)이 되읽는 것은 **버퍼 크기(u16)뿐**이기 때문이다.
   남은 후보는 cbuffer 내 바이트 오프셋 / 성분 수 / 배열 길이인데 `rbp+0x110..0x134` 로 복사된
   원본 구조체를 특정하지 못해 못 갈랐다.
4. **`[미해결]` `g_Daytime`(ID 5) · `g_LayerModelMatrix`(ID 24) 의 용도.** 둘 다 동봉 셰이더
   소비 0건이라 소비처에서 역산할 수 없다.
   → **[미해소 2026-08-21]** 그대로다. 새로 아는 것은 배정뿐 — 둘 다 `g_bufDynamic`(b1),
   즉 **프레임·드로우 주기**다(§3.1b ⑤). 그것만으로는 의미가 안 나온다. 닫으려면 워크샵
   코퍼스(이 컨테이너에 없다)나 에디터 바이너리(`wallpaperui.exe`)의 UI 라벨이 필요하다.
5. **`[미해결]` `g_HDRParams`(ID 139) 2성분의 의미.** 소비 4파일뿐이고 산출식을 못 찾았다.
   → **[성분 의미 해소 2026-08-21 · 산출식은 미해소]** 소비처가 그대로 적고 있었다(함정 6 —
   x86 전에 자산부터). `.x` = **SDR 화이트 스케일**(`shaders/passthroughlinear.frag:14`
   `albedo.rgb = _srgb(albedo.rgb / g_HDRParams.x);` — 선형값을 이걸로 나눈 뒤 sRGB 인코드하므로
   `.x` 가 sRGB 1.0 에 대응하는 장면-선형 값이다). `.y` = **피크 HDR 의 절반**
   (`shaders/combine_video_hdr.frag:10` `float maxHDR = g_HDRParams.y * 2.0;` 이고 그 뒤가
   `/maxHDR → saturate → *maxHDR` 클램프다). 둘 다 디스플레이 능력에서 오는 값이라
   §3.1b 의 `g_bufStatic`(b0) 배정과 정합한다. **엔진이 디스플레이 정보에서 이 둘을 계산하는
   식은 여전히 못 찾았다.**
6. **`[미해결]` `.mdl` 프로젝트 4개의 정확한 셰이더 도달.** §6.1 의 근사(프로젝트 materials 전부)
   를 썼다. `.mdl` 파서를 붙이면 좁혀진다.
   → **[미해소 2026-08-21]** 손대지 않았다. 이유: 도달 수치를 좁히면 §1.2(140행)·§2.3(238행)
   두 표의 "씬 / np" 열이 통째로 다시 계산돼야 하는데, 그 재계산은 이 문서의 생성기
   (`scratchpad/UNIC/reach.py`)와 함께 가야 하고 그 스크립트는 세션 스크래치에만 있다
   (컨테이너 휘발). **부분만 고치면 표 안에서 서로 모순되는 수치가 남는다**(방법론 함정 20).
   과대 추정 방향이라는 것만 재확인해 둔다.
7. **부류 C 238개 중 "엔진이 머티리얼 키로 채우는 것"의 전수.** `g_BloomBlendParams` 계열 4개는
   확인했지만, 내장 패스가 코드로 채우는 머티리얼 키가 그 4개뿐이라는 것은 증명하지 못했다.
   그건 이름 축이 아니라 **머티리얼 키 축**의 census 라 별건이다.

---

## 부록 A. 재현 절차

전부 `scratchpad/UNIC/` 의 스크립트로 재현된다. `wpe.py`(PE/`.pdata`) + `vdis2.py`(capstone)
의존.

**A.1 레지스트리 140 복원**
```
python3 UNIC/reg.py     # ctor 형 55개 (call sub_14016f7a0)
python3 UNIC/reg3.py    # 전체 140 (SSO 인라인 + ctor 2종 + 전용 헬퍼 5)
python3 UNIC/regva.py   # 이름 → .rdata 문자열 VA
```
자기검증: `resolved 140/140`, `unique 140`, `idset==0..139: True` 가 나와야 한다.
하나라도 어긋나면 WE 빌드가 바뀐 것이니 조용히 진행하지 말 것.

**A.2 셰이더 평문 census**
```
python3 UNIC/census2.py > UNIC/c2.txt   # 340 이름, 316 선언, 어노테이션 키 분포
```
선언 정규식은 **정밀도 한정자(`lowp`/`mediump`/`highp`)를 반드시 허용**해야 한다 —
빠뜨리면 `fantasticcar/car.frag` 의 `uniform lowp vec3 g_PaintColor;` 류 5건을
"uniform 아님" 으로 오분류한다(실제로 처음에 그랬다).

**A.3 바이너리 문자열 교차**
```
python3 UNIC/strscan.py       # wallpaper64.exe
# strscan_all: wallpaper_engine/{,bin/}*.{exe,dll} 46개, ASCII + UTF-16LE(짝수·홀수 오프셋 양쪽)
```

**A.4 씬 도달**
```
python3 UNIC/reach.py         # scene→model→material→shader→#include 폐포
```

**A.5 표 생성**
```
python3 UNIC/gen2.py          # t_reg.md(140행) · t_auth.md(238행)
```

**게이트**: `python3 scripts/spec/check_address_ranges.py` · `python3 scripts/spec/validate.py`
