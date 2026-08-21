# 씬 라이팅(lpoint/lspot/ltube/ldirectional) 복원

WE 의 3D 씬 라이팅을 **셰이더 평문 + `wallpaper64.exe`(imagebase `0x140000000`)** 양쪽에서 복원한
기록이다. `docs/re/shader-uniforms.md` §1.2(140행 전수표)가 "미채움/부분 — 인식만" 으로만 적어 둔 `g_L{Point,Spot,Tube,Directional}_*`
11개와 `g_LFeature_*` 4개, 그리고 `SceneDocument.SceneLightConfig`(파스만 있고 소비 없음)의
**소비 규약**을 채운다.

- 셰이더 평문: `wallpaper_engine/assets/shaders/common_pbr_2.h`(V1 코어) · `common_pbr.h`(V0) ·
  `common_fragment.h`(레거시) · `generic4.frag`/`generic3.frag`/`generic2.frag`/`generic.frag` ·
  `generic4.vert`/`generic2.vert` · `shadowcaster.vert`/`.frag`
- 바이너리: 라이팅 스니펫 **생성기 `0x140169140`–`0x14016b0d4`** · HLSL 백엔드 `0x1400f5cb0`–`0x1400f8520` ·
  콤보 세터 `0x1401a5c40`–`0x1401a6c5d` · 유니폼 패커 `0x140190c80`–`0x1401964b8` ·
  라이트 프로퍼티 등록 `0x14025da80`–`0x14025e9da` · 라이트 생성자 `0x14018ff60`–`0x1401909b1` ·
  레거시 4슬롯 패커 `0x14025d1f0`–`0x14025d2fb` · `lightconfig` 파스 `0x140187732`–`0x140187D0A`
- 코퍼스: 동봉 172 + 설치본 186 = 358 씬(전수 재스캔) · 워크샵 162 씬은
  `spec/corpus/scene-schema.json` 실측치 인용

> **방법론 메모.** `docs/re/volumetric-light.md` 머리말과 같은 결론이다 — **픽셀을 정하는 상수는 전부
> `common_pbr_2.h` 385줄 안에 평문으로 있다.** 다만 이 항목은 반쪽만 그렇다: `PerformLighting_V1`
> 이라는 **함수 본문 자체가 `.frag` 파일에 없고**(`generic4.frag:75` 는 `#require LightingV1` 한 줄뿐)
> 엔진이 씬의 `lightconfig` 를 보고 **문자열로 조립**한다. 그 조립기가 `0x140169140` 이고, 아래 §2.2 는
> 그 함수가 붙이는 문자열 조각을 전부 원문 그대로 옮긴 것이다. 셰이더만 읽어서는 절대 못 얻는다.

---

## 1. 라이트 종류 전수

### 1.1 문자열 → enum 표는 **5 엔트리다**

정적 초기화 `0x14025e853`–`0x14025e9d0`, 저장소 `0x1404e9cf0`, stride `0x28`(SSO 문자열 0x20 + 값 8):

| scene.json `"light"` | 표 VA | enum 값 | 값 세트 VA |
| --- | --- | ---: | --- |
| `point` | `0x1404e9cf0` | **5** | `0x14025e931` |
| `lpoint` | `0x1404e9d18` | 0 | `0x14025e955` |
| `lspot` | `0x1404e9d40` | 1 | `0x14025e979` |
| `ltube` | `0x1404e9d68` | 2 | `0x14025e99d` |
| `ldirectional` | `0x1404e9d90` | 3 | `0x14025e9c9` |

**이게 전부다.** `spot`/`tube`/`directional` 같은 접두 `l` 없는 축약형은 `point` 를 빼면 **없다**.
표에 없는 문자열은 필드가 생성자 기본값 그대로 남는데 그 기본값이 `5`(`0x140190486`
`mov byte [rdi+0x2c0], 5`)라 **미지 타입 = 레거시 `point` 레인**이다.

⚠️ Waple `Scene3DLightKind(type:)` 는 `"spot"`/`"tube"`/`"directional"` 도 받는다 — WE 에는 없는
관용이다. 동봉 172 + 설치본 186 + 워크샵 162 전부에서 이 세 축약형 도달 **0건**이라 무해하지만,
"WE 가 받는다" 는 근거로 쓰면 안 된다.

### 1.2 종은 4 개가 아니라 **두 레인 4+1** 이다

`[light+0x2c0]` 값으로 패커가 갈린다(`0x1401910f2` `movzx eax, byte [r14+0x2c0]`):

| 값 | 분기 VA | 레인 | 유니폼 | 소비 셰이더 |
| ---: | --- | --- | --- | --- |
| 0 (`lpoint`) | `0x14019325f` | V1 | `g_LPoint_Color/Origin` | `generic4`/`chroma4`/`fur4`/`foliage4` |
| 1 (`lspot`) | `0x140192dbf` | V1 | `g_LSpot_Color/Origin/Direction/Exponent` | 〃 |
| 2 (`ltube`) | `0x140192a19` | V1 | `g_LTube_Color/OriginA/OriginB` | 〃 |
| 3 (`ldirectional`) | `0x14019111d` | V1 | `g_LDirectional_Color/Direction` | 〃 |
| 4 | — | **없음** | — | — |
| 5 (`point`/미지) | `0x14025d1f6` | 레거시 4슬롯 | `g_LightsColorRadius[4]` / `g_LightsPosition[4]` | `generic`/`generic2` |

`0x140191114` 의 `cmp eax,1 / jne 0x14019318c` 때문에 **값 4 와 5 는 V1 패커에서 통째로 버려진다.**

### 1.3 라이트 프로퍼티 전수 — 키 · 오프셋 · 기본값

등록 테이블 `0x14025da80`–`0x14025e826`(`[reg+0x34]`=오프셋, `[reg+0x30]`=타입 4=float 5=enum 6=bool),
기본값은 생성자 `0x140190441`–`0x1401904e4`.
`docs/re/volumetric-light.md` §2.5 의 표를 **완성**한다(굵은 행 = 그 표에 없던 것).

| scene.json 키 | 오프셋 | 타입 | 기본값 | 등록 VA | 기본값 VA |
| --- | --- | --- | --- | --- | --- |
| `light` | `+0x2c0` | enum | `5` | `0x14025e4c6` | `0x140190486` |
| `castshadow` | `+0x2c4` bit0 | bool | false | `0x14025e63d` | `0x14019048d` |
| `usecookie` | `+0x2c4` bit1 | bool | false | `0x14025e6f9` | 〃 |
| `castvolumetrics` | `+0x2c4` bit2 | bool | false | `0x14025e7bb` | 〃 |
| `color` | `+0x2cc` | vec3 | `0 0 0` | `0x14025db25` | `0x140190460` |
| **`controlpoint`** | **`+0x2d8`** | **vec3** | **`2 0 0`** | **`0x14025e412`** | **`0x140190474`** |
| `intensity` | `+0x2e4` | float | `0` | `0x14025dbef` | `0x14019047f` |
| `radius` | `+0x2e8` | float | `1.0` | `0x14025dcb6` | `0x140190494` |
| `exponent` | `+0x2ec` | float | `2.0` | `0x14025dd5f` | `0x14019049e` |
| `innercone` | `+0x2f0` | float | `20.0`(도) | `0x14025de14` | `0x1401904a8` |
| `outercone` | `+0x2f4` | float | `30.0`(도) | `0x14025dec9` | `0x1401904b2` |
| `density` | `+0x2f8` | float | `2.0` | `0x14025df85` | `0x1401904bc` |
| `volumetricsexponent` | `+0x2fc` | float | `1.0` | `0x14025e04c` | `0x1401904c6` |
| `cascadedistance0` | `+0x300` | float | `3.0` | `0x14025e10a` | `0x1401904d0` |
| `cascadedistance1` | `+0x304` | float | `10.0` | `0x14025e1d3` | `0x1401904da` |
| **`cascadedistance2`** | **`+0x308`** | **float** | **`100.0`** | **`0x14025e29c`** | **`0x1401904e4`** |
| **`lightsourcesize`** | **`+0x30c`** | **float** | **`0`** | **`0x14025e35e`** | **`0x1401904e4`**(qword 상위) |
| `visible` | `+0x120` | bool | true | `0x14025e587` | (공통 오브젝트 필드) |

`+0x2c4` 비트 배정은 패커에서 배타적으로 확정된다 — point 경로가 `test byte [r14+0x2c4], 1`
(`0x14019331d`)로 castshadow 를 읽고, spot 경로가 `and eax, (2 | (quality!=0))`(`0x140192e0a`/`0x140192e11`)
로 **bit1=cookie / bit0=shadow** 를 커서 인덱스로 쓴다. bit2 는 볼류메트릭(볼류메트릭 문서 §2.1).

**`originb` 는 존재하지 않는다.** tube 단점 B 는 `controlpoint`(`+0x2d8`)다 — `ltube` 패커
`0x140192aa6` 이 `lea rdx, [r14+0x2d8]` 로 그 필드를 월드 변환(`0x14019d450`)에 넘긴다.
(`Scene3DLighting.Scene3DResolvedLight.originB` 주석의 반증과 같은 결론.)

---

## 2. 셰이더에서 얻은 것 — 픽셀 수식 전부

### 2.1 `PerformLighting_V1` 은 파일이 아니라 **생성물**이다

```glsl
// generic4.frag:75
#require LightingV1
// generic4.frag:122
light = PerformLighting_V1(v_WorldPos, albedo.rgb, normal, normalizedViewVector, CAST3(1.0), f0, roughness, metallic);
```

`#require` 이름 비교는 `0x1401691f5`(`"LightingV1"` @`0x14048be90`), 그 앞의 `LIGHTING` 콤보 조회는
`0x1401691b8`(`"LIGHTING"` @`0x140486930`). 생성기는 **`LIGHTING == 0` 이면 아무것도 안 찍고
곧바로 반환한다**(`0x14016922a` `je 0x14016b0b2`).

**⛔️ 함수 범위 정정.** `Scene3DLighting.swift:272`(수정 전)의 `0x1401691c0–0x14016b154` 는 오기였다.
`primary(0x1401691c0)` 실측 = **`0x140169140`–`0x14016b0d4`**(`ret` @`0x14016b0cc`). 바로 뒤
`0x14016b0e0`–`0x14016c3f8` 은 스니펫이 아니라 **전처리기 디렉티브 파서**
(정규식 `^\s*#\s*([a-z]+)\b\s*(.*)` @`0x14048d048`, `ifdef`/`ifndef`/`else`/`endif`/`require`/`undef`)다.
HLSL 판 라이트 배열은 또 다른 함수 `0x1400f5cb0`–`0x1400f8520`(§3.4)에 있다.

### 2.2 생성기가 찍는 GLSL 전문 (문자열 원문)

먼저 콤보 9개를 `atoi`(`0x1402c82c0`)로 읽는다 — 레지스터 배정 실측:

| 콤보 | 문자열 VA | 읽기 VA | 보관 |
| --- | --- | --- | --- |
| `LIGHTS_POINT` | `0x140487630` | `0x140169281` | `r14d` |
| `LIGHTS_SPOT` | `0x140487678` | `0x1401692e1` | `[rbp-0x18]` |
| `LIGHTS_TUBE` | `0x140487770` | `0x140169343` | `[rbp+0x58]` |
| `LIGHTS_DIRECTIONAL` | `0x1404877e8` | `0x140169398` | `[rbp+0x50]` |
| `LIGHTS_SPOT_SHADOW_COOKIE` | `0x1404877c8` | `0x1401693ed` | `r15d` |
| `LIGHTS_SPOT_SHADOW` | `0x140487878` | `0x140169442` | `r13d` |
| `LIGHTS_SPOT_COOKIE` | `0x140487890` | `0x140169499` | `r12d` |
| `LIGHTS_DIRECTIONAL_SHADOW` | `0x140487828` | `0x1401694f0` | `[rbp+0x68]` |
| `LIGHTS_POINT_SHADOW` | `0x140487948` | `0x140169547` | `edi` |

그 다음 유니폼 선언을 찍고(§3.1), 본문을 **완전히 언롤**한다. 루프가 없다 — 블록마다
`const uint i = <상수>u;` 를 박는다(`"\tconst uint i = "` @`0x14048c298`, `"u;\n"` @`0x14048c068`).

머리(`0x14048c070`, 175바이트):

```glsl
vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector, vec3 specularTint, vec3 ambient, float roughness, float metallic)
{
	vec3 light = CAST3(0.0);
```

꼬리(`0x14048ce30`): `\treturn light;\n}`.

블록 9종 — 방출 순서 그대로:

| # | 조건(루프 상한) | 인덱스 범위 | 방출 VA | 본문 |
| ---: | --- | --- | --- | --- |
| 1 | `LIGHTS_POINT_SHADOW` | `[0, PS)` | `0x140169bd0` | point + 큐브 섀도우 |
| 2 | `LIGHTS_POINT` | `[PS, P)` | `0x140169d50` | point, `shadowFactor = 1.0` |
| 3 | `LIGHTS_SPOT_SHADOW_COOKIE` | `[0, SSC)` | `0x140169e90` | spot + 섀도우 + 쿠키 |
| 4 | `LIGHTS_SPOT_COOKIE` | `[SSC, SSC+SC)` | `0x14016a010` | spot + 쿠키, `1.0` |
| 5 | `LIGHTS_SPOT_SHADOW` | `[SSC+SC, SSC+SC+SS)` | `0x14016a170` | spot + 섀도우 + **콘** |
| 6 | `LIGHTS_SPOT` | `[SSC+SC+SS, S)` | `0x14016a300` | spot + 콘, `1.0` |
| 7 | `LIGHTS_TUBE` | `[0, T)` | `0x14016a460` | tube, `1.0` |
| 8 | `LIGHTS_DIRECTIONAL_SHADOW` | `[0, DS)` | `0x14016a5a0` | directional + **3-캐스케이드** |
| 9 | `LIGHTS_DIRECTIONAL` | `[DS, D)` | `0x14016ae60` | directional, `1.0` |

**핵심: 섀도우/쿠키 카운트는 가산이 아니라 부분집합이다.** point 루프는 `ebx=0` 에서 시작해
`cmp ebx, edi`(=`LIGHTS_POINT_SHADOW`, `0x140169d23`)로 섀도우 블록을 찍고, 이어서
`cmp ebx, r14d`(=`LIGHTS_POINT`, `0x140169d42`/`0x14016a...`)까지 무섀도우 블록을 찍는다. spot 도 같은
방식으로 SSC → SC → SS → 나머지 순으로 **하나의 `LIGHTS_SPOT` 배열을 4구간으로 자른다**
(`ebx` 누적: `0x140169fe8` / `0x14016a14f` / `0x14016a2d9`).

블록 본문 원문(문자열 VA — 전부 그대로 인용):

```glsl
// #1 point + shadow
	vec3 lightDelta = g_LPoint_Origin[i].xyz - worldPos;                              // 0x14048c260
	vec4 projectedCoords = CalculateProjectedCoordsPoint(worldPos, g_LPoint_Origin[i].xyz, g_LFeature_ShadowPointProjection[i], g_LFeature_ShadowPointProjectionTransform[i]);   // 0x14048c1b0
	float shadowFactor = PerformPointShadowMapping(projectedCoords);                  // 0x14048c160
	light += ComputePBRLightShadow(normal, lightDelta, viewVector, color, g_LPoint_Color[i].rgb, g_LPoint_Color[i].w, g_LPoint_Origin[i].w, specularTint, ambient, roughness, metallic, shadowFactor);   // 0x14048c410

// #2 point (무섀도우) — 마지막 인자만 리터럴 1.0                                       // 0x14048c350

// #3 spot + shadow + cookie
	vec3 lightDelta = g_LSpot_Origin[i].xyz - worldPos;                               // 0x14048c310
	vec3 projectedCoords = CalculateProjectedCoords(worldPos, g_LFeature_ShadowProjection[i]);        // 0x14048c2b0
	float shadowFactor = PerformShadowMapping(projectedCoords, g_LFeature_ShadowProjectionTransform[i]);  // 0x14048c6e0
	vec3 colorCookie = texSample2D(COOKIE_SAMPLER, projectedCoords.xy).rgb;           // 0x14048c690
	light += ComputePBRLightShadow(normal, lightDelta, viewVector, color, g_LSpot_Color[i].rgb * colorCookie, g_LSpot_Color[i].w, g_LSpot_Exponent[i].x, specularTint, ambient, roughness, metallic, shadowFactor);   // 0x14048c5b0

// #4 spot + cookie (무섀도우)                                                        // 0x14048c4e0

// #5 spot + shadow + cone
	float spotCookie = -dot(normalize(lightDelta), g_LSpot_Direction[i].xyz);         // 0x14048c960
	spotCookie = smoothstep(g_LSpot_Direction[i].w, g_LSpot_Origin[i].w, spotCookie); // 0x14048c900
	light += ComputePBRLightShadow(..., g_LSpot_Color[i].rgb * spotCookie, ..., shadowFactor);   // 0x14048c820

// #6 spot + cone (무섀도우)                                                          // 0x14048c750

// #7 tube — 섀도우 판이 **없다**
	vec3 lightDelta = PointSegmentDelta(worldPos, g_LTube_OriginA[i].xyz, g_LTube_OriginB[i].xyz);   // 0x14048caa0
	light += ComputePBRLightShadow(normal, lightDelta, viewVector, color, g_LTube_Color[i].rgb, g_LTube_Color[i].w, g_LTube_OriginA[i].w, specularTint, ambient, roughness, metallic, 1.0);   // 0x14048c9e0

// #8 directional + 3 캐스케이드
	const uint p1 = <n>u;  const uint p2 = <n+1>u;  const uint p3 = <n+2>u;           // 0x14048c9c8 / 0x14048c9b0 / 0x14048cc58
	vec4 projectedCoords1 = CalculateProjectedCoordsCascades(worldPos, g_LFeature_ShadowProjection[p1]);   // 0x14048cbf0
	vec4 projectedCoords2 = ... [p2] ...                                              // 0x14048cb80
	vec4 projectedCoords3 = ... [p3] ...                                              // 0x14048cb10
	projectedCoords1.xyz = mix(projectedCoords1.xyz, projectedCoords2.xyz, projectedCoords1.w);   // 0x14048cdd0
	projectedCoords1.xyz = mix(projectedCoords1.xyz, projectedCoords3.xyz, projectedCoords2.w);   // 0x14048cd70
	vec4 uvTransforms = mix(g_LFeature_ShadowProjectionTransform[p1], g_LFeature_ShadowProjectionTransform[p2], projectedCoords1.w);   // 0x14048cce0
	uvTransforms = mix(uvTransforms, g_LFeature_ShadowProjectionTransform[p3], projectedCoords2.w);   // 0x14048cc70
	float shadowFactor = max(projectedCoords3.w, PerformShadowMapping(projectedCoords1.xyz, uvTransforms));   // 0x14048cfd0
	light += ComputePBRLightShadowInfinite(normal, g_LDirectional_Direction[i].xyz, viewVector, color, g_LDirectional_Color[i].rgb, specularTint, ambient, roughness, metallic, shadowFactor);   // 0x14048cf10

// #9 directional (무섀도우)                                                          // 0x14048ce50
```

읽는 법 넷:

1. **`ambient` 라는 인자 이름은 거짓말이다.** 호출부(`generic4.frag:122`)가 그 자리에 `f0` 를 넘긴다 —
   `ComputePBRLightShadow` 의 `baseReflectance`(프레넬 `F0`)다. 앰비언트는 §2.6 에서 따로 더해진다.
2. **`radius` 는 `Color.w`, `exponent` 는 `Origin.w`** 다(spot 만 exponent 가 `g_LSpot_Exponent[i].x`).
   패커도 그렇게 쓴다(§3.3).
3. **쿠키는 콘을 대체한다.** #3/#4 에는 `smoothstep` 콘 항이 아예 없다 — 쿠키 텍스처가 콘 모양을
   대신하고, `innercone`/`outercone` 은 `g_LSpot_Origin[i].w`/`g_LSpot_Direction[i].w` 에 실려 있어도
   **읽히지 않는다**.
4. **`castshadow:true` 인 tube 는 WE 에서도 그림자를 안 만든다** — 섀도우 판 문자열 자체가 없다.

### 2.3 코어 — `ComputePBRLightShadow` (`common_pbr_2.h:256-314`)

```glsl
vec3 ComputePBRLightShadow(vec3 N, vec3 L, vec3 V, vec3 albedo, vec3 lightColor,
	float radius, float exponent, vec3 specularTint, vec3 baseReflectance, float roughness, float metallic, float shadowFactor)
{
	float distance = length(L);
	L = L / distance;
	vec3 H = normalize(V + L);

	float falloff = saturate(1.0 - distance / radius);
	// Ensure x > 0 && y >= 0 to avoid undefined behavior
	float flt_min = 6.103515625e-5;
	vec3 radiance = lightColor * mix(0.0, pow(falloff + flt_min, exponent), step(0.0, falloff - flt_min));

	float NDF = shadowFactor * Distribution_GGX(N, H, roughness);
	float G   = GeoSmith(N, V, L, roughness);
	vec3  F   = FresnelSchlick(max(dot(H, V), 0.0), baseReflectance);
	vec3 numerator = NDF * G * F;

	vec3 diffuse = (1.0 - metallic) * (CAST3(1.0) - F);
	float dNL = dot(N, L);
	float NL = max(dNL * shadowFactor, 0.0);
	float denominator = 4.0 * max(dot(N, V), 0.0) * NL;
	vec3 specular = numerator / max(denominator, 0.001);

	return (diffuse * albedo / M_PI + specular * specularTint) * radiance * NL;
}
```

$$L_o=\Bigl(\frac{(1-m)(1-F)\,c_{alb}}{\pi}+\frac{s\cdot D\,G\,F}{\max(4(N\!\cdot\!V)(N\!\cdot\!L)_s,\,10^{-3})}\odot t_{spec}\Bigr)\cdot c_{light}\bigl(\mathrm{sat}(1-\tfrac{d}{r})+\epsilon\bigr)^{e}\cdot (N\!\cdot\!L)_s$$

여기서 $s=\texttt{shadowFactor}$, $(N\!\cdot\!L)_s=\max(s\,(N\!\cdot\!L),0)$, $\epsilon=6.103515625\times10^{-5}$
(= FP16 최소 정규수. HLSL 분기는 `1.17549435e-38` = FP32 최소 정규수, `:266`).

- **프레넬**: Schlick, `pow(max(1-cosθ, 0.001), 5)`(`:6`) — `max(...,0.001)` 클램프가 원문이다.
- **분포/기하**: GGX + Schlick-GGX, $k=(r+1)^2/8$(`:30`) — **직접광 규약**.
- **에너지 보존**: `diffuse = (1-metallic)*(1-F)`, diffuse 만 `/π`. 스페큘러는 `/π` 가 없고
  `specularTint` 로 스케일된다.
- **섀도우는 `NL` 과 `NDF` 양쪽에 곱해진다**(`:272`, `:301`) — 통상적인 "가시성×조명" 이 아니라
  스페큘러 로브에 두 번 들어간다(WE 고유).
- **`DOUBLESIDEDLIGHTING`** 콤보면 `dNL = abs(dNL)`(`:281`) — `generic3.frag:7` 에서 `COMBO_DISABLED`.
- **`SHADINGGRADIENT`**(툰): `NL` 이 스칼라가 아니라 `texSample2D(GRADIENT_SAMPLER, vec2(max(min(s,dNL)*0.5+0.5,0), 0)).rgb`
  로 바뀐다(`:285-290`) — 하프램버트 좌표를 그라디언트 램프로 룩업.
- **`RIMLIGHTING`**: `rimTerm = s·pow(1-max(N·V,0), g_RimExponent)·g_RimAmount·NL·step(0.001, Σc)`,
  `NL = max(NL, rimTerm)`, `metallic -= saturate(rimTerm)`(`:303-308`).

### 2.4 무한광 — `ComputePBRLightShadowInfinite` (`:317-363`)

directional 전용. 위 식에서 **`radius`/`exponent`/거리 정규화가 통째로 빠지고** `radiance = lightColor`
그대로다(`:362`). `L` 은 정규화하지 않고 `g_LDirectional_Direction[i].xyz` 를 그대로 받는다 —
즉 그 유니폼이 **정규화된 "표면→광원" 벡터**여야 한다.

### 2.5 tube — `PointSegmentDelta` (`common_pbr_2.h:9-16` = `common_pbr.h:9-16`)

```glsl
vec3 PointSegmentDelta(vec3 pos, vec3 segmentA, vec3 segmentB)
{
	vec3 delta = segmentB - segmentA;
	float v = dot(delta, delta);
	if (v == 0.0)
		return segmentA - pos;
	return segmentA + saturate(dot(pos - segmentA, segmentB - segmentA) / v) * (segmentB - segmentA) - pos;
}
```

세그먼트 최근접점까지의 델타. `v == 0`(A==B) 이면 point 와 수치 동치. 이후는 point 와 완전히 같은
`ComputePBRLightShadow` 라 **tube = "가장 가까운 점이 움직이는 point"** 다.

### 2.6 앰비언트와 합성

앰비언트는 **정점 셰이더**에서 반구 보간으로 계산된다 — `generic4.vert:168`
(`generic.vert:77` · `generic2.vert:73` · `generic3.vert:171` 과 **문자 단위로 동일**):

```glsl
v_LightAmbientColor = mix(g_LightSkylightColor, g_LightAmbientColor, dot(normal, vec3(0, 1, 0)) * 0.5 + 0.5);
```

프래그먼트 합성(`generic4.frag:119-132`):

```glsl
vec3 light = CAST3(0.0);
#if LIGHTING
light = PerformLighting_V1(v_WorldPos, albedo.rgb, normal, normalizedViewVector, CAST3(1.0), f0, roughness, metallic);
vec3 ambient = v_LightAmbientColor * albedo.rgb;
#else
vec3 ambient = albedo.rgb;
#endif
#if EMISSIVE_MAP
light = max(light, g_EmissiveColor * albedo.rgb * (componentMaps.a * g_EmissiveBrightness));
#endif
albedo.rgb = CombineLighting(light, ambient);
```

`CombineLighting`(`common_pbr_2.h:365-374`)은 **HDR 콤보에서만** 오버브라이트를 남긴다:

```glsl
#if HDR
	float lightLen = length(light);
	float overbright = (saturate(lightLen - 2.0) * 0.5) / max(0.01, lightLen);
	return saturate(ambient + light) + (light * overbright);
#else
	return ambient + light;
#endif
```

`specularTint` 자리에 `CAST3(1.0)` 이 들어가는 것도 여기서 확정된다 — **`generic4` 는 머티리얼
`speculartint` 를 라이팅에 안 쓴다**(그 상수는 다른 레인/다른 셰이더 소관).

### 2.7 옛 레인 둘 (비교용)

| 레인 | 감쇠 | 스페큘러 | 원문 |
| --- | --- | --- | --- |
| **V1** (`generic4`) | `pow(sat(1-d/r), e)` | GGX, 같은 식 안에서 `+ specular*tint` | `common_pbr_2.h:263-313` |
| **V0** (`generic3`, deprecated) | `lightColor/(d·d)`, 호출부가 `color*r*r` 를 실어 보냄 | GGX, `specularTint` 없음 | `common_pbr.h:69-70`, `generic3.frag:135/145/153/160` |
| **레거시** (`generic`/`generic2`) | `sat((r-d)/r)²` | Blinn 로브를 **따로 누적**해 마지막에 가산 | `common_fragment.h:61-81` |

```glsl
// common_fragment.h:68-81 — 레거시
vec3 ComputeLightSpecular(..., inout vec3 specularResult)
{
	float lightAttn = saturate((radius - lightDistance) / radius);
	vec3 lightDir = lightDelta / lightDistance;
	float specular = max(0.0, dot(normalize(viewDir + lightDir), normal));
	specularResult += pow(specular, specularPower) * specularStrength * lightAttn * color;
	float lightDot = dot(lightDir, normal);
	float halfLambertLight = lightDot * 0.5 + 0.5;
	lightDot = mix(lightDot, halfLambertLight, halfLambert);        // halfLambert = g_Light
	float rim = metallicTerm * 2.0;
	rim = pow((1.0 - saturate(dot(normal, viewDir))) * pow(halfLambertLight, 0.25), 6.0 - rim) * rim;
	return color * (saturate(lightDot) + rim) * lightAttn * lightAttn;   // ← /π 없음
}
// :51-58
specularPower    = (1.01 - roughness) * mix(400.0, 250.0, metallic);
specularStrength = (0.5 + metallic * 0.5) * (1.0 - roughness * 0.9);
```

`generic3.frag:100-105` 의 `spotCookie` 는 계산만 하고 **쓰이지 않는다**(WE 자신의 버그).
`SHADERVERSION < 62` 가지(`:87-123`)는 `radius²` 세기 배율조차 없다.

---

## 3. 엔진 유니폼 — 이름 · 원소 크기 · 최대 개수 · 팩 순서

### 3.1 GLSL 선언 — 생성기가 찍는 문자열 그대로

`uniform ` 접두 + 배열 길이 + `];\n`(`0x1404876a8`). 길이 0 이면 **선언 자체를 생략한다**.

| 유니폼 선언 문자열 | 문자열 VA | 배열 길이 | 방출 VA |
| --- | --- | --- | --- |
| `uniform vec4 g_LPoint_Color[` | `0x14048be70` | `LIGHTS_POINT` | `0x140169573` |
| `uniform vec4 g_LPoint_Origin[` | `0x14048be50` | 〃 | `0x1401695e3` |
| `uniform vec4 g_LSpot_Color[` | `0x14048bf00` | `LIGHTS_SPOT` | `0x140169671` |
| `uniform vec4 g_LSpot_Origin[` | `0x14048bee0` | 〃 | `0x1401696de` |
| `uniform vec4 g_LSpot_Direction[` | `0x14048bec0` | 〃 | `0x140169749` |
| `uniform vec4 g_LSpot_Exponent[` | `0x14048bea0` | 〃 | `0x140169792` |
| `uniform vec4 g_LTube_Color[` | `0x14048bf88` | `LIGHTS_TUBE` | `0x140169822` |
| `uniform vec4 g_LTube_OriginA[` | `0x14048bf68` | 〃 | `0x14016988e` |
| `uniform vec4 g_LTube_OriginB[` | `0x14048bf48` | 〃 | `0x1401698fa` |
| `uniform vec4 g_LDirectional_Color[` | `0x14048bf20` | `LIGHTS_DIRECTIONAL` | `0x140169987` |
| `uniform vec4 g_LDirectional_Direction[` | `0x14048c040` | 〃 | `0x1401699d0` |
| `uniform mat4 g_LFeature_ShadowProjection[` | `0x14048c010` | **S_proj** (아래) | `0x140169a42` |
| `uniform vec4 g_LFeature_ShadowProjectionTransform[` | `0x14048bfd8` | **S_proj** | `0x140169a8b` |
| `uniform vec4 g_LFeature_ShadowPointProjection[` | `0x14048bfa8` | `LIGHTS_POINT_SHADOW` | `0x140169af2` |
| `uniform vec4 g_LFeature_ShadowPointProjectionTransform[` | `0x14048c120` | 〃 | `0x140169b3b` |

$$S_{proj} = 3\cdot\texttt{DIRECTIONAL\_SHADOW} + \texttt{SPOT\_SHADOW\_COOKIE} + \texttt{SPOT\_COOKIE} + \texttt{SPOT\_SHADOW}$$

산출 실측 `0x140169a1e`–`0x140169a2a`: `ecx=DS; edx=SC+2·DS; edx+=DS; edx+=SS; edx+=SSC`.
**쿠키만 켠 spot 도 프로젝션 슬롯을 먹는다** — 쿠키 UV 를 만들려면 같은 투영이 필요하기 때문이다
(블록 #4 가 `CalculateProjectedCoords` 를 호출한다).

`generic3.frag:63-80` 은 같은 배열들을 `#if LIGHTS_POINT` 로 감싼 **평문 선언**을 갖는다
(V0 레인은 `#require` 를 안 쓴다). 배열 길이만 콤보로 들어온다.

### 3.2 상수 버퍼 크기 — 실측 공식

패커 `0x140190cf3`–`0x140190d60`:

$$N_{vec4} = 5S_{proj} + 2P + 4S + 3T + 2D + 2P_{sh},\qquad \text{바이트} = 16\,N_{vec4}$$

(`edi = 5·S_proj + 2·(pointshadow + 2·spot + directional + point) + 3·tube`, `esi = edi << 4`.)

종별 vec4 수가 §3.1 선언과 정확히 맞는다 — point 2, spot 4, tube 3, directional 2,
point 섀도우 2, S_proj 슬롯 5(mat4 4 + vec4 1).

**최대 개수**: `lightconfig` 저장 폭이 상한이다 — point/spot/tube/directional 은 니블(**≤15**),
섀도우·쿠키 계열은 2비트(**≤3**). 그 이상은 클램프가 아니라 **절단**이라 `{"point":16}` → 0
(`SceneDocument.SceneLightConfig` 주석 참조). 별도의 하드 캡은 **없다**.

### 3.3 배열 안 순서와 필드 배정

패커가 종류마다 커서를 여러 개 두고 서브그룹을 앞쪽에 몰아넣는다:

| 종 | 커서 | 순서 |
| --- | --- | --- |
| point | `[rbp+0x5b8]`(섀도우) / `[rbp+0x5b0]`(무섀도우) | `[0, PS)` 섀도우, `[PS, P)` 무섀도우 |
| spot | `[rbp+0x5f0 + idx*8]`, `idx = flags & (2 \| (quality≠0))` | `[0,SSC)` 3=쿠키+섀도우 · `[SSC,+SC)` 2=쿠키 · `[+SS)` 1=섀도우 · 나머지 0=콘 |
| tube | `[rbp+0x4c8]` | 입력 순 |
| directional | `[rbp+0x128]`(섀도우) / `[rbp+0x120]` | `[0, DS)` 섀도우, 나머지 |

배열은 **구조체 배열이 아니라 병렬 배열**이다 — `g_LSpot_Color[S]` 전체 다음에 `g_LSpot_Origin[S]`,
그 다음 `Direction`, `Exponent` 순(`0x140192e46` `ebx=[rbp-0x6c]`=4·S dword, `0x140192e90`
`ecx=[rbp-0x78]`, `0x140192ec4` `eax=[rbp-0x60]`, `lea ecx,[rax+rax*2]; shl ecx,2` = 3·4·S dword).

필드 배정 실측:

| 유니폼 성분 | 값 | VA |
| --- | --- | --- |
| `g_LPoint_Color[i].rgb` | `color × intensity` | `0x140193283`–`0x1401932c8` |
| `g_LPoint_Color[i].w` | `radius`(`+0x2e8`) | `0x1401932d1` |
| `g_LPoint_Origin[i].xyz` | 월드 원점(`0x14019d3e0`) | `0x1401932f2` |
| `g_LPoint_Origin[i].w` | `exponent`(`+0x2ec`) | `0x140193301` |
| `g_LSpot_Color[i]` | `(color×intensity, radius)` | `0x140192e2e`–`0x140192e3e` |
| `g_LSpot_Origin[i].w` | **`cos(innercone × π/180)`** | `0x140192e64`–`0x140192e86` |
| `g_LSpot_Direction[i].w` | **`cos(outercone × π/180)`** | `0x140192eaa`–`0x140192ebf` |
| `g_LSpot_Exponent[i].x` | `exponent` | `0x140192eca`–`0x140192edd` |
| `g_LTube_OriginA[i]` | `(월드 원점, exponent)` | `0x140192a97`–`0x140192ab4` |
| `g_LTube_OriginB[i].xyz` | `controlpoint`(`+0x2d8`) 월드화 | `0x140192aa6`, `0x14019d450` |
| `g_LTube_OriginB[i].w` | `1.0` | `0x140192a80`(상수 적재) |
| `g_LDirectional_Color[i].w` | **`1.0` 리터럴** | `0x14019119f` |

deg→rad 상수 `0.01745329238474369` 적재는 `0x1401910bf`(원본 `0x140492628`). **`* 0.5` 는 없다** —
`innercone`/`outercone` 은 광축 기준 **반각(도)** 이고 셰이더가 `smoothstep(cos(outer), cos(inner), cosθ)`
로 쓴다. (`Scene3DLighting.spotConeCosines` 주석과 동일 결론.)

### 3.4 HLSL 백엔드 — 같은 배열, 다른 타입

`0x1400f5cb0`–`0x1400f8520` 이 `cbuffer g_bufLights`(`0x14048d148`) 안에 `const float4 ...` 로 찍는다.
**두 개는 타입이 다르다**:

| GLSL | HLSL | 문자열 VA |
| --- | --- | --- |
| `uniform vec4 g_LTube_OriginB[` | `const float3 g_LTube_OriginB[` | `0x140487750` |
| `uniform vec4 g_LDirectional_Direction[` | `const float3 g_LDirectional_Direction[` | `0x1404877a0` |

나머지는 `float4` 로 1:1. `docs/re/shader-uniforms.md` §3.1 이 "cbuffer 배정 미확정" 이라고 적은
`g_bufLights`(`0x140484b78`/`0x14048d148`)의 **내용물이 정확히 이 15개**임을 이 함수가 확정한다.

### 3.5 레거시 4슬롯 레인

`[light+0x2c0] == 5` 이고 `[light+0x2c8] ≤ 3` 일 때만 실린다(`0x14025d1f6`/`0x14025d20d`).

```glsl
// generic2.frag:4 / generic.frag:4
uniform vec4 g_LightsColorRadius[4];
// generic2.vert:7
uniform vec3 g_LightsPosition[4];
// generic2.frag:60-67 — 4개가 **언롤되어 하드코딩**돼 있다
vec3 light = ComputeLightSpecular(normal, v_Light0DirectionL3X.xyz, g_LightsColorRadius[0].rgb, g_LightsColorRadius[0].w, ...);
```

| 항목 | 씬 상수 오프셋 | 값 | VA |
| --- | --- | --- | --- |
| `g_LightsColorRadius[i]` | `[scene+0xc8] + 0x1258 + i*16` | `(color×intensity, radius)` | `0x14025d26b`–`0x14025d27d` |
| `g_LightsPosition[i]` | `[scene+0xc8] + 0x1228 + i*12` | 월드 원점 | `0x14025d2dc`–`0x14025d2ec` |
| 비활성 슬롯 파킹 | 〃 | 색 `0`, 반경 `1.0`, 위치 `(0, 100, 0)` | `0x14025d288`–`0x14025d2a6`, `0x14025cff2`–`0x14025d01e` |

---

## 4. `lightconfig` — 9키 ↔ 9콤보 ↔ 소비

### 4.1 비트필드 → 콤보 (1:1, 변환 없음)

파스(비트 배정·마스크·절단)는 `Sources/WapleCore/SceneDocument.swift` 의 `SceneLightConfig` 주석이
이미 확정했다. 여기서는 **그 다음**만 적는다 — 콤보 세터 `0x1401a5c40`–`0x1401a6c5d` 가
`[engine+0x121C]` 를 잘라 9개 콤보를 **무조건**(값 0 이어도) 세운다:

| 콤보 | 추출 | VA | ⇔ `lightconfig` 키 |
| --- | --- | --- | --- |
| `LIGHTS_POINT` | `w & 0xF` | `0x1401a5e44`/`0x1401a5e50` | `point` |
| `LIGHTS_SPOT` | `(w>>4) & 0xF` | `0x1401a5ed8`/`0x1401a5eea` | `spot` |
| `LIGHTS_TUBE` | `(w>>8) & 0xF` | `0x1401a5f66`/`0x1401a5f78` | `tube` |
| `LIGHTS_DIRECTIONAL` | `(w>>12) & 0xF` | `0x1401a5ffc`/`0x1401a6002` | `directional` |
| `LIGHTS_SPOT_SHADOW` | `(w>>16) & 3` | `0x1401a6115`/`0x1401a6127` | `spotshadow` |
| `LIGHTS_SPOT_COOKIE` | `(w>>18) & 3` | `0x1401a61a3`/`0x1401a61ac` | `spotcookie` |
| `LIGHTS_SPOT_SHADOW_COOKIE` | `(w>>20) & 3` | `0x1401a6091`/`0x1401a609b` | `spotshadowcookie` |
| `LIGHTS_DIRECTIONAL_SHADOW` | `(w>>22) & 3` | `0x1401a621a`/`0x1401a622d` | `directionalshadow` |
| `LIGHTS_POINT_SHADOW` | `(w>>24) & 3` | `0x1401a6220`/`0x1401a6235` | `pointshadow` |

**따라서 "9키 ↔ 9콤보 1:1" 은 확정이고, 콤보 값 = 저작값(절단 후)이다.**

### 4.2 파생 콤보 셋

| 콤보 | 조건 | VA |
| --- | --- | --- |
| `LIGHTS_SHADOW_MAPPING` = 1 | `pointshadow + directionalshadow + spotshadow + spotshadowcookie ≠ 0` | `0x1401a62ad`–`0x1401a62fc` |
| `LIGHTS_COOKIE` = 1 | `spotcookie + spotshadowcookie ≠ 0` | `0x1401a638c`–`0x1401a63e4` |
| `LIGHTS_SHADOW_MAPPING_QUALITY` | `byte [engine+0x1AC]` 그대로 | `0x1401a6340`/`0x1401a636a` |

`generic4.frag:21-31` 이 이 둘로 텍스처 슬롯을 붙인다:

```glsl
#if LIGHTS_SHADOW_MAPPING
#define SHADOW_ATLAS_SAMPLER g_Texture6
#define SHADOW_ATLAS_TEXEL   g_Texture6Texel
uniform sampler2DComparison g_Texture6; // {"hidden":true,"default":"_rt_shadowAtlas"}
uniform vec4 g_Texture6Texel;
#endif
#if LIGHTS_COOKIE
#define COOKIE_SAMPLER g_Texture7
uniform sampler2D g_Texture7; // {"hidden":true,"default":"_alias_lightCookie"}
#endif
```

**`[engine+0x1AC]` 의 정체 확정.** `docs/re/volumetric-light.md` §2.1 이 이미 이 바이트를
"셰도우맵 품질 → `LIGHTS_SHADOW_MAPPING_QUALITY` 콤보"(`0x1401983af`)로 지목했다. 여기서
합류하는 새 사실은 **`SceneDocument.SceneLightConfig` 주석이 `[미해결]` 로 남긴
`cmp byte [engine+0x1AC], 0`(`0x140187C39` — 0 이면 `pointshadow`/`spotshadow`/`directionalshadow` 를
버리고 `spotshadowcookie` 를 `spotcookie` 자리에 접는 그 바이트)가 바로 그것**이라는 점이다.
같은 바이트를 콤보 세터(`0x1401a6340`)와 유니폼 패커(`0x140190cd9` → `[rbp+0xd88]`, 섀도우 커서
선택)가 함께 읽는다. **0 = 섀도우 전면 오프**, 그리고 그 자리에서 `lightconfig` 의 섀도우 니블도
파스 단계에서 접힌다 — 즉 그 접힘은 씬 데이터가 아니라 **앱 품질 설정** 소관이다.

### 4.3 소비 규약 — 확정

유니폼 패커 `0x140190c80`–`0x1401964b8` 이 종류별 **잔여 카운터**로 쓴다:

```asm
0x140190ca1  mov  r9d, [rcx+0x121c]      ; lightconfig 워드
0x140190ca8  test r9d, r9d
0x140190cab  je   0x1401964ae            ; ← 0 이면 V1 라이트 유니폼을 아예 안 싣는다
...
0x1401910d6  call 0x140185010            ; IsVisible — 가시성이 먼저
0x1401910f2  movzx eax, byte [r14+0x2c0] ; 그 다음 종 분기
0x14019325f  mov  edx, [rsp+0x60]        ; point 잔여
0x140193263  test edx, edx
0x140193265  je   0x14019318c            ; ← 소진되면 라이트를 통째로 버린다
0x1401932ac  dec  edx
```

| 예산 | 슬롯 | 확인/감소 VA |
| --- | --- | --- |
| point | `[rsp+0x60]` | `0x14019325f` / `0x1401932ac` |
| spot | `[rbp-0x64]` | `0x140192dbf` / `0x140192dd3` |
| tube | `[rbp-0x68]` | `0x140192a19` / `0x140192a49` |
| directional | `[rbp-0x28]` | `0x14019111d` / `0x140191137` |
| pointshadow | `[rsp+0x6c]` | `0x14019332b` / `0x140193337` |
| directionalshadow | `[rbp+0x24]` | `0x14019353a` / `0x140193550` |

**확정 사항 5개**

1. `lightconfig` 는 힌트가 아니라 **정확한 슬롯 예산**이다. 초과 라이트는 유니폼에 안 실리고
   셰이더에도 자리가 없다.
2. 종별 카운트는 **총량**이고 섀도우/쿠키 카운트는 그 총량을 **분할**한다(가산 아님).
   `{"point":1,"pointshadow":1}` = 라이트 1개, 그게 섀도우 캐스터.
3. **미저작(`lightconfig` 부재 또는 전건 0) = V1 라이트 0개.** 라이트 오브젝트가 있어도 `LIGHTING`
   스니펫에 블록이 하나도 안 찍히고(§2.2 루프 상한 전부 0) 패커가 첫 줄에서 반환한다.
   레거시 `"point"`(타입 5)만 `g_LightsColorRadius[4]` 경로로 계속 그려진다.
4. 섀도우 예산이 소진된 캐스터는 **셰이딩은 남고 그림자만 잃는다**(`0x140193331` `je` 는 프로젝션
   기록만 건너뛴다).
5. 소비는 **가시성 판정 뒤**다(`IsVisible` `0x1401910d6` → 종 분기 `0x1401910f2` → `test/je`).
   비가시 라이트는 슬롯을 먹지 않는다.

**관찰된 WE 자체 결함 둘**(우리는 재현하지 않는다):

- directional 캐스케이드 슬롯 진행이 **+3 이 아니라 +1** 이다(`0x14016a9b4` `lea r14d,[r13+1]` →
  `0x14016ae36` `mov r13d, r14d`). 섀도우 directional 이 2개 이상이면 두 번째의 `p1/p2/p3` 가
  첫 번째의 `p2/p3` 와 겹친다. `directionalshadow` 는 2비트라 최대 3 — 도달 0건이라 무해.
- point 캐스터가 `pointshadow` 예산을 넘겨도 커서 선택(`eax = castshadow & (quality≠0)`,
  `0x1401932ae`)은 여전히 섀도우 커서를 고른다. 결과적으로 섀도우 구간 뒤 첫 무섀도우 슬롯에
  얹혀 **우연히** 맞는다.

---

## 5. 그림자

### 5.1 아틀라스 — 고정 해상도가 **아니다**

`_rt_shadowAtlas`(`0x14048b920`)는 사각형 패킹으로 매 프레임 크기가 정해진다.

| 사실 | 값 | VA |
| --- | --- | --- |
| 섀도우맵 타일 한 변 | **1024** | `0x1401964c2` `mov qword [rcx+0x48], 0x400` |
| 패킹 빈 한계 | **8192** | `0x14019371b` `mov ecx, 0x2000` |
| 아틀라스 크기 | 패킹 결과 extent, 최소 2 | `0x14019386f`–`0x14019387f` (`cmova` 로 max(2, ·)) |
| RT 생성 | `0x1401aadb0(mgr, w, h, divisor=1, "_rt_shadowAtlas", color=0x1b, depth=0x19, flags=0x8000008, flags2=0x41)` | `0x140193893`–`0x1401938d1` |
| RT 서술자 오버라이드 | `[desc+0x18]=0x10`, `[desc+0x1c]=0x8000008` (기본 `0`/`9`) | `0x1400ec5df`–`0x1400ec5fa` |

인자 이름은 `docs/re/volumetric-light.md` §2.2 가 형제 호출부(`_rt_FullFrameBuffer`=1 ·
`_rt_4FrameBuffer`=4 …, `0x14017f585`–`0x14017f681`)로 확정한 시그니처를 그대로 쓴다. 거기서
`0x1b` = **"포맷 없음"** 이므로 **섀도우 아틀라스는 컬러 없는 뎁스 전용 타깃**이고,
뎁스 포맷 `0x19` 는 `_rt_volumetricsBack` 과 같은 값이다. `divisor = 1` 이라 위의 패킹 extent 가
곧 픽셀 크기다.
| UV 트랜스폼 | `(rect.xy, rect.wh) / (gridW, gridH)` | `0x140196269`–`0x1401962b0` |

`g_LFeature_ShadowProjectionTransform[i]` = `(offsetU, offsetV, scaleU, scaleV)` — `PerformShadowMapping`
이 `projectedCoords.xy = projectedCoords.xy * transform.zw + transform.xy`(`common_pbr_2.h:46-47`)로 쓴다.

point 라이트는 자기 타일 **한 장 안에** 6면을 넣는다 — `viewportScale = vec2(0.5, 0.3333)`
(`common_pbr_2.h:153`), 즉 **2열 × 3행**. 면 순서는 dominant-axis 분기(`:167-235`)로
`+X, −X, +Y, −Y, +Z, −Z` 이고 셀 오프셋은 `(0,0) (1,0) (0,1) (1,1) (0,2) (1,2)`.
Waple `PointShadowMath.faceIndex`/`atlasCell` 과 **완전히 같다**.

### 5.2 캐스터 렌더 — 6 뷰포트 인스턴싱

```glsl
// shadowcaster.vert:9-11, 104-105
uniform mat4 g_ViewportViewProjectionMatrices[6];
in uint gl_InstanceID;
varying uint gl_ViewportIndex;
...
gl_Position = mul(mul(vec4(localPos, 1.0), g_ModelMatrix), g_ViewportViewProjectionMatrices[gl_InstanceID]);
gl_ViewportIndex = gl_InstanceID;
```

한 드로우로 최대 6 뷰포트에 동시 래스터한다. 배치 플러시가 `esi == 6` 에서 일어난다
(`0x140196248` `cmp esi,6` → `0x140196262` `call 0x140196530`). 프래그먼트는
`ALPHATOCOVERAGE` 가 아니면 **본문이 비어 있다** — 깊이만 남긴다(`shadowcaster.frag:7-15`).

### 5.3 바이어스 상수 둘

| 상수 | 값 | 상수 VA | 적용 VA | 대상 |
| --- | ---: | --- | --- | --- |
| 캐스터 | `-0.0005` | `0x140492604` | `0x14019632a` | `[engine + 0xb30 + i·64 + 0x38]` = `g_ViewportViewProjectionMatrices[i]` 의 row3.z |
| VP 조립 | `-0.00333` | `0x1404929a8` | `0x140193b4c` | 섀도우맵 서술자 VP(`[desc+8]`)의 row3.z 사본 |

둘 다 투영행렬 `m[3][2]` 에 더해지는 **포스트-프로젝션 상수 깊이 오프셋**이다. 셰이더 쪽에는
바이어스가 **없다** — `texSample2DCompare` 가 그대로 비교한다. Waple 의 `FrameU.meta.w`
("receiver depth bias") 는 WE 에 대응물이 없는 우리 쪽 장치다.

### 5.4 품질 등급이 바꾸는 것

`LIGHTS_SHADOW_MAPPING_QUALITY`(= `[engine+0x1AC]`):

| 값 | PCF | point 뷰포트 보정 | 원문 |
| ---: | --- | --- | --- |
| 0 | (섀도우 전면 오프) | — | `0x140187C39`, `0x1401a62bb` |
| 1 | **1탭** | `±0.47` | `common_pbr_2.h:74-75`, `:155-156` |
| 2 | 9탭 | `±0.47` | `:77-91`, `:155-156` |
| 3 | 9탭 | `±0.48` | `:157-158` |
| 그 외(≥4) | 9탭 | `±0.49` | `:159-161` |

9탭 오프셋은 `roundOffset = texel × 0.81616`, `axial = texel × 1.02323`, 합/9(`:77-90`).
`SHADOW_ATLAS_ANTIALIAS` 는 `#define ... 0`(`:40`)이라 **항상 꺼져 있다**.

Waple(`Mesh3DShaders.swift:412`/`:446`–`:457`)은 9탭 + `0.49` = **"그 외(≥4)" 등급**에 정합한다.

### 5.5 캐스케이드

directional 섀도우는 **항상 3 캐스케이드**다(§2.2 블록 #8, `S_proj` 공식의 `3·DS`). 선택은 브랜치가
아니라 `mix` 체인이고, 경계 밖 판정은 `CalculateProjectedCoordsCascades` 가 `proj.w` 에
`step(1.0, dot(1, step(0.99, abs(proj.xyz))))` 로 넣는다(`common_pbr_2.h:131-147`).
마지막 `max(projectedCoords3.w, ...)` 는 **세 번째 캐스케이드마저 벗어나면 그림자를 1(=밝음)로 강제**한다.

씬 키 `cascadedistance0/1/2`(`+0x300`/`+0x304`/`+0x308`, 기본 3/10/100)가 그 경계다.

---

## 6. 동봉 도달 실측 (2026-08-21)

### 6.1 동봉 172 + 설치본 186 = 358 씬 전수

라이트를 **쓰는 씬은 4개**(동봉 2 + 설치본 전용 2), 라이트 총 **6개**.

| 씬 | 구분 | 라이트 | `lightconfig` | `version` |
| --- | --- | --- | --- | --- |
| `scenes/modeleditor` | 동봉 · non-preview | `lpoint` ×2 | `{"point": 2}` | 3 |
| `scenes/particleelementpreviews/collisionmodel` | 동봉 · **preview** | `lpoint` ×1 (`castshadow:true`) | `{"point":1,"pointshadow":1}` | 0 |
| `projects/defaultprojects/arsenal` | 설치본 전용 · non-preview | `point` ×2 | **없음** | 키 없음 |
| `projects/defaultprojects/demon_core` | 설치본 전용 · non-preview | `point` ×1 | **없음** | 키 없음 |

종류별: `lpoint` 3 · `point` 3 · **`lspot` 0 · `ltube` 0 · `ldirectional` 0**.

라이트 오브젝트 6개가 쓰는 키 전수(중복 파일 제거 후):

| 키 | 라이트 6개 중 | 값 |
| --- | ---: | --- |
| `light` `origin` `angles` `color` `intensity` `radius` `id` `name` | 6 | — |
| `scale` | 5 | 전부 등방 1(arsenal/demon_core 포함) |
| `parallaxDepth` | 3 | 전부 `"0.00000 0.00000"` |
| `visible` | 2 | true |
| `locktransforms` | 2 | false |
| `castshadow` `exponent` `density` `volumetricsexponent` | **1** | collisionmodel |
| `cascadedistance0/1/2` | **1** | collisionmodel: `0.0` / `100.0` / `200.0` |
| `usecookie` `innercone` `outercone` `lightsourcesize` `controlpoint` `originb` `castvolumetrics` | **0** | — |

라이트 값 실측:

| 씬 | color | intensity | radius | exponent | castshadow |
| --- | --- | ---: | ---: | ---: | --- |
| modeleditor #1 | `0.63137 1 0.95294` | 6.0 | 150 | (기본 2.0) | — |
| modeleditor #2 | `0.5 0.2 1.0` | 5.0 | 50 | (기본 2.0) | — |
| collisionmodel | `1 1 1` | 6.44 | 811.69 | 2.0 | **true** |
| arsenal #1 | `1 1 1` | 1.87 | 16.32 | (기본) | — |
| arsenal #2 | `0.89 0.69 0.086` | 0.18 | 22.85 | (기본) | — |
| demon_core | `1 1 1` | 0.67 | 17.13 | (기본) | — |

`collisionmodel` 의 `cascadedistance0 = 0.0` 은 **`lpoint` 에 붙어 있다** — 프로퍼티 등록이
종 무관이라 에디터가 종 상관없이 써 넣는다(§1.3). 소비는 directional 섀도우 스니펫뿐이므로
WE 에서도 읽히지 않고, Waple `DirectionalShadowMath.validCascades`(전 성분 > 0 · 엄격 상승)도
`d.x = 0` 에서 탈락시킨다 — **양쪽 다 무해**, 도달 0.

`lightconfig` 를 가진 씬은 **동봉 2건이 전부**이고, 둘 다 **저작 카운트 == 실제 라이트 수**다.

### 6.2 워크샵 코퍼스 162 씬 (`spec/corpus/scene-schema.json` 인용)

| 항목 | 값 |
| --- | --- |
| `general.lightconfig` | **11 씬**(전부 dict) |
| 라이트 오브젝트 | 27개 / 11 씬 |
| 종류 | `lpoint` 17 · `ldirectional` 5 · `lspot` 5 · **`ltube` 0** |
| `castshadow` | true 9 / false 18 |
| `innercone`/`outercone` | 5개 / 2씬 (`10.63`–`20` / `14.28`–`30`) |
| `cascadedistance0/1/2` | 15개 / 9씬 |
| `usecookie` | **키 자체가 없음(0건)** |
| `castvolumetrics` | 4개 / 3씬 |

라이트를 쓰는 워크샵 씬 11개가 **전부** `lightconfig` 를 갖는다(라이트 있는 씬 수 = lightconfig 씬 수 = 11).
**`spotcookie`/`spotshadowcookie` 는 전 코퍼스에서 도달 0** 이므로 `LIGHTS_COOKIE` 경로(블록 #3/#4)는
현재 어떤 실물도 타지 않는다.

### 6.3 화면이 바뀌는 동봉 씬 — **0**

`lightconfig` 예산을 켜도 동봉 도달 2씬은 값이 그대로다:

| 씬 | 실제 라이트 | 예산 | 예산 적용 후 | 화면 |
| --- | --- | --- | --- | --- |
| modeleditor | `lpoint` 2, 캐스터 0 | point 2 / pointshadow 0 | 2 유지, 섀도우 0 | **불변** |
| collisionmodel | `lpoint` 1, 캐스터 1 | point 1 / pointshadow 1 | 1 유지, 섀도우 1 | **불변** |

설치본 `arsenal`/`demon_core` 는 `lightconfig` 미저작 → 폴백 경로라 **불변**.
즉 **이번 배선으로 픽셀이 달라지는 동봉 씬은 0개다.** 워크샵 11씬은 원본 `scene.json` 이
이 머신에 없어(`spec/corpus/*.json` 은 측정치만 보관) 대조 불가 — §9 `[미해결]`.

---

## 7. Waple 배선 — 이번에 바뀐 것

### 7.1 `Scene3DLighting.LightSlotBudget` (신규)

`resolveLights(_:nodes:config:)` 가 `SceneLightConfig?` 를 받아 §4.3 규약대로 소비한다.

| 규약 | 구현 |
| --- | --- |
| 종별 총량 상한 | `budget.take(kind)` — 소진 시 `continue` |
| 섀도우 별도 예산 | `budget.takeShadow(kind)` — 실패 시 `castsShadow = false`(셰이딩은 유지) |
| 가시성 우선 | 부모 가시성/유한성 가드 **뒤**에 소비 |
| 미저작(nil) | 모든 `take` 성공 = 종전 first-8 폴백(**비트동일**) |

**의도적 차이 3개**

1. 미저작 씬을 WE 처럼 "V1 라이트 0개" 로 만들지 **않는다**. `arsenal`(ambientcolor 완전 검정) 이
   새까매지고, 우리 메시 셰이더는 레거시 Blinn 레인을 이식하지 않았다 —
   `Scene3DLightKind` 주석의 기존 정책과 같은 이유다.
2. 소비 시점을 유한성/반경 가드 뒤로 미룬다(WE 는 그 가드가 없어 순서가 무의미).
3. 셰이더 배열이 8 고정이라 **줄이는 방향만** 반영한다. `lightconfig` 합이 8 을 넘는 씬은 여전히
   앞 8개만 산다 — §9 `[미해결]`.

### 7.2 주석 정정

- `Scene3DLighting.swift` 의 생성기 범위 `0x1401691c0–0x14016b154` → **`0x140169140–0x14016b0d4`**
  (`primary()` 실측). 인접 `0x14016b0e0–0x14016c3f8` 이 전처리기 파서라는 것과 HLSL 판이
  `0x1400f5cb0–0x1400f8520` 이라는 것도 같이 적었다.
- `QuadShaders.swift:193` 의 "슬롯 8" 주석에 WE 실물 규약(니블 상한 15 / 2비트 3 / 배열 길이 = 저작값)과
  2D 레인 미배선 사실을 명시.

### 7.3 착지 못 한 마지막 한 줄 (**타 레인 소유 파일**)

`config:` 인자는 기본값 `nil` 이라 **현재 호출부는 아무것도 안 넘긴다**. 실제로 켜려면:

| 파일(내 소유 아님) | 줄 | 필요한 변경 |
| --- | --- | --- |
| `Sources/WapleRender/SceneRenderer.swift` | `:1087` 근처 | `var scene3DLightConfig: SceneLightConfig? = nil` 저장 프로퍼티 + `:2288` 리셋 |
| `Sources/WapleRender/SceneRenderer3D.swift` | `:241` | `scene3DLightConfig = doc.lightConfig` |
| 〃 | `:1539` | `resolveLights(scene3DLights, nodes: nmap, config: scene3DLightConfig)` |
| `Sources/WapleRender/SceneRendererFrameEncoder.swift` | `:942` | 같은 인자 추가 |

동봉 도달 기준 화면 변화는 0(§6.3)이라 **무회귀 3줄**이다.

2D 레인(`SceneDocument.ForwardUniforms`, WapleCore)은 별도다 — 그쪽도 8슬롯 고정이고
`lightconfig` 를 안 본다.

---

## 8. 배제한 가설

| 가설 | 반증 |
| --- | --- |
| "`lightconfig` 는 편집기 힌트고 렌더는 라이트 오브젝트를 다 그린다" | 패커가 종별 잔여 카운터로 초과분을 드롭한다(`0x140193263` 외 5곳). 게다가 `test r9d,r9d; je`(`0x140190ca8`)로 미저작이면 **전부** 드롭. |
| "`pointshadow` 는 `point` 에 더해지는 추가 슬롯" | 생성기 point 루프가 같은 `ebx` 로 `[0,PS)` 다음 `[PS,P)` 를 찍는다(`0x140169d23`/`0x140169d42`). `{"point":1,"pointshadow":1}` 이 라이트 2개가 아니라 1개인 이유. |
| "`spotcookie` 는 `spot` 과 별개 배열" | 배열은 `g_LSpot_*[LIGHTS_SPOT]` 하나뿐이고 4구간으로 나뉜다(§3.3 커서 4개). |
| "쿠키 spot 도 innercone/outercone 콘을 쓴다" | 블록 #3/#4 에 `smoothstep` 문자열이 없다. 쿠키가 콘을 **대체**한다. |
| "tube 는 castshadow 를 존중한다" | tube 블록 문자열이 `0x14048c9e0` 하나뿐이고 마지막 인자가 리터럴 `1.0`. point/spot 은 두 판이 있다. |
| "생성기는 `0x1401691c0–0x14016b154`" | `primary()` 실측 `0x140169140–0x14016b0d4`. `0x14016b0e0` 부터는 전처리기 디렉티브 파서(`0x14048d048` 정규식). |
| "`0x14016b0e0–0x14016c3f8` 이 HLSL 판 스니펫" | 그 함수의 문자열은 `ifdef`/`endif`/`require`/`undef` 뿐. HLSL 라이트 배열은 `0x1400f5cb0–0x1400f8520`(`0x1400f7618` 이 `const float4 g_LPoint_Color[` 를 찍는다). |
| "섀도우 아틀라스는 고정 해상도" | 사각형 패커(`0x140193760`–`0x14019381e`)가 매번 extent 를 계산한다. 고정된 건 타일 한 변 1024(`0x1401964c2`)와 빈 한계 8192(`0x14019371b`). |
| "`_rt_shadowAtlas` 문자열은 exe 에서 참조되지 않는다" | rip-상대 `lea` 를 바이트 스캔하면 2곳(`0x1400ec5df`, `0x140193893`). 일반 xref 스캔이 놓친 건 선형 디스어셈 desync 탓 — 방법론 함정 #8. |
| "`[engine+0x1AC]` 는 미확정" | `LIGHTS_SHADOW_MAPPING_QUALITY` 콤보 값 그대로다(`0x1401a6338`–`0x1401a636a`). |
| "WE 도 `"spot"`/`"tube"` 축약형을 받는다" | 문자열 표는 5엔트리(`0x14025e853`–`0x14025e9c9`)뿐. 축약형은 미지 → 기본값 5(레거시 레인). |

---

## 9. 남은 미확정 `[미해결]`

1. **`lightconfig` 합 > 8 인 씬.** 우리 셰이더 배열이 8 고정이라 초과분을 못 싣는다. 올리려면
   `Mesh3DShaders`(`LightU* lights [[buffer(3)]]`, `count` clamp 8)와 `QuadShaders`(`for i<8`),
   `SceneRenderer3D`(`maximumLights*6` 섀도우 VP 배열)를 같이 올려야 한다 — 셋 다 타 레인 소유.
   워크샵 코퍼스 최대치가 얼마인지도 원본 부재로 미확인(§6.2 는 씬별 합계를 안 준다).
2. **`lightconfig` 미저작 씬을 WE 처럼 "라이트 0" 로 만들지 여부.** 우리는 의도적으로 안 한다(§7.1).
   레거시 Blinn 레인(`ComputeLightSpecular`)을 별도 kind 로 이식하면 그때 재검토.
3. **쿠키 경로 전체.** `LIGHTS_COOKIE`/`_alias_lightCookie` 텍스처의 출처(어떤 씬 키가 쿠키 텍스처를
   지정하는지)를 못 찾았다 — 라이트 프로퍼티 등록 테이블에 텍스처 키가 없다. 도달 0건이라 미추적.
4. **`lightsourcesize`(`+0x30c`, 기본 0).** 등록은 되는데 패커/생성기 어느 쪽에서도 소비를 못 찾았다.
   워크샵 3건(2씬) 도달.
5. **RT 플래그 상수.** 포맷 슬롯(`color=0x1b` 없음 / `depth=0x19`)은 `volumetric-light.md` §2.2 의
   형제 호출부 대조로 풀렸지만, `flags=0x8000008` · `flags2=0x41` · 이름별 오버라이드
   `[desc+0x18]=0x10` 은 필드 이름을 못 붙였다. 셰이더 쪽 `FORMAT_*` enum(0..12,
   `common_fragment.h:2-17`)과는 값 범위가 안 맞아 **다른 enum**이다.
6. **`-0.00333` 바이어스의 정확한 소비처.** 섀도우맵 서술자 VP 사본의 row3.z 에 더해지는 것까지는
   확정했으나(`0x140193b4c`), 그 사본이 최종적으로 `g_LFeature_ShadowProjection` 이 되는지
   중간 행렬곱의 피연산자로만 쓰이는지는 미확정.
7. **directional 캐스케이드 슬롯 +1 진행이 버그인지 의도인지.** 도달 0건이라 실측 불가.
8. **워크샵 11 씬의 화면 변화.** 원본 `scene.json` 이 없어 예산 적용 전후 대조 불가.

---

## 부록 A. 재현 절차

```bash
cd /tmp/claude-0/-home-user/<session>/scratchpad

# 1) 생성기 함수 범위 — 남의 주석 말고 primary() 로
python3 -c "
import sys; sys.path.insert(0,'.')
from wpe import primary
print([hex(x) for x in primary(0x1401691c0)[:2]])   # ['0x140169140', '0x14016b0d4']
print([hex(x) for x in primary(0x14016b154)[:2]])   # ['0x14016b0e0', '0x14016c3f8']  ← 다른 함수
"

# 2) 생성기가 붙이는 문자열 전문
python3 - <<'PY'
import sys, re, struct
sys.path.insert(0,'.')
from wpe import pe, DATA
import capstone
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64); md.detail=False
o = pe.va2off(0x140169140); code = DATA[o:o+(0x14016b0d4-0x140169140)]
for ins in md.disasm(code, 0x140169140):
    if ins.mnemonic != 'lea': continue
    m = re.search(r"\[rip \+ (0x[0-9a-f]+)\]|\[rip - (0x[0-9a-f]+)\]", ins.op_str)
    if not m: continue
    d = int(m.group(1),16) if m.group(1) else -int(m.group(2),16)
    t = ins.address + ins.size + d
    off = pe.va2off(t)
    if off is None: continue
    z = DATA[off:off+4096].split(b"\x00")[0]
    if not z or not all(0x09 <= c < 0x7f for c in z): continue
    print("=== @%#x -> %#x" % (ins.address, t)); print(z.decode())
PY

# 3) SSO(≤15바이트) 문자열의 xref — 선형 디스어셈이 놓치는 rip-lea 를 바이트로 훑는다
python3 - <<'PY'
import sys, struct
sys.path.insert(0,'.')
from wpe import pe, DATA, primary
tgt = 0x14048b920                      # "_rt_shadowAtlas" (15자)
sec = [s for s in pe.sections if s['name'] == '.text'][0]
for off in range(sec['rawptr'], sec['rawptr']+sec['rawsize']-8):
    if DATA[off] != 0x48 or DATA[off+1] != 0x8d: continue
    if (DATA[off+2] & 0xC7) != 0x05: continue
    va = pe.off2va(off)
    if va + 7 + struct.unpack_from('<i', DATA, off+3)[0] == tgt:
        p = primary(va); print(hex(va), hex(p[0]) if p else None)
PY
```

```bash
# 4) 동봉/설치본 라이트 전수 (§6.1 표를 그대로 재생성)
python3 - <<'PY'
import json, glob, collections
roots = {'bundled': 'Sources/WapleRender/Resources/WEAssets',
         'install': '/home/user/Waple-wallpaper-source/wallpaper_engine'}
for tag, root in roots.items():
    for p in glob.glob(root + '/**/scene.json', recursive=True):
        d = json.load(open(p, encoding='utf-8-sig'))
        kinds = collections.Counter()
        for o in d.get('objects') or []:
            if isinstance(o, dict) and 'light' in o:
                t = o['light']
                kinds[str(t.get('value') if isinstance(t, dict) else t).lower()] += 1
        lc = (d.get('general') or {}).get('lightconfig')
        if kinds or lc: print(tag, p, dict(kinds), lc)
PY
```

```bash
# 5) 셰이더 평문 대조
cd /home/user/Waple-wallpaper-source/wallpaper_engine/assets/shaders
sed -n '256,314p' common_pbr_2.h        # ComputePBRLightShadow
sed -n '44,115p'  common_pbr_2.h        # PerformShadowMapping / PerformPointShadowMapping
sed -n '149,253p' common_pbr_2.h        # CalculateProjectedCoordsPoint (2×3 셀)
sed -n '61,81p'   common_fragment.h     # 레거시 ComputeLightSpecular
grep -n 'LightAmbientColor' generic4.vert generic2.vert generic.vert generic3.vert
grep -rn 'LIGHTS_POINT' generic3.frag   # V0 레인의 평문 배열 선언
```
