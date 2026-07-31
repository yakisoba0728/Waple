# Waple — Scene SP3b: scroll / opacity / tint 효과 추가 (설계 문서)

- 작성일: 2026-06-25
- 상태: 설계 확정(자율 진행)
- 선행: SP3a(효과 패스 프레임워크 + waterwaves + BC3/LZ4 디코드) main 병합.
- 범위: 효과 유니폼 일반화 + **scroll·opacity·tint** 추가. WE 충실(강도 설정 없음). waterripple/shake·블렌드모드 다양화·추가 텍스처 슬롯은 SP3c.

---

## 1. 개요 / 목표
SP3a 효과 프레임워크에 흔한 스톡 효과 3종(scroll/opacity/tint)을 손-포팅해 Medium 씬 커버리지를 넓힌다.
효과별 유니폼이 제각각이므로 **유니폼 전달을 일반화**한다(공유 풀스크린 vert + 효과별 frag가 `time + params` 해석).

## 2. 정찰 결과 (효과 셰이더)
- **scroll.frag**(12줄): `frac((uv + scroll) * g_Scale)`. scroll = time×speed(원본은 vert 계산 → 포팅 시 frag에서 time으로 계산). 유니폼: scale(repeat) + scroll speed.
- **opacity.frag**(19줄): `albedo.a *= mask.r * g_UserAlpha`. 유니폼: alpha. 마스크 g_Texture1.
- **tint.frag**(29줄): `g_TintColor`·`g_BlendAlpha`·마스크, BLENDMODE combo(common_blending.h). **SP3b는 기본 블렌드(normal/알파)만**; 다양한 모드는 SP3c.
- 마스크 검증: waterwaves 마스크 동작은 정확(BC3 마스크는 0–255 풀레인지 디코드 확인). `2111201226`은 마스크가 어둡게 칠해진 씬-특화일 뿐 → 풀-마스크 씬으로 검증.

## 3. 설계

### 3.1 효과 유니폼 일반화 (EffectShaders)
- 효과별 frag 시그니처 통일: `ef_main(EOut in, texture2d fb [[texture(0)]], texture2d mask [[texture(1)]], constant float* P [[buffer(0)]])`.
  `P[0] = g_Time`(초), `P[1..]` = 효과별 파라미터(문서화된 순서).
- `EffectShaders.source(for: name) -> String?`: 공유 vert(`ev_main`, 풀스크린) + 해당 effect frag(MSL). 미지원 nil.
- `EffectShaders.params(for: name, constants: [String:Float]) -> [Float]`: constantshadervalues(+기본값)를 효과별 슬롯 순서로 매핑(time 제외; 프레임워크가 P[0]에 time 주입).
- 기존 waterwaves도 이 일반 스킴으로 이관(typed `EffectUniforms` struct 제거 → 공통 float 버퍼).

### 3.2 효과별 frag (손-포팅, 기본 동작)
- **scroll**: `uv' = fract((uv + P_time * float2(speedX,speedY)) * float2(scaleX,scaleY)); return fb.sample(uv')`. params: [scaleX, scaleY, speedX, speedY] (기본 scale 1,1).
- **opacity**: `c = fb.sample(uv); c.a *= mask.r * alpha; return c`. params: [alpha=1].
- **tint**: `c = fb.sample(uv); float m = mask.r; c.rgb = mix(c.rgb, tintRGB, blendAlpha * m); return c`. params: [r,g,b,blendAlpha] (기본 1,0,0,1) — 기본(normal) 블렌드만.

### 3.3 SceneRenderer 연동
- 효과 패스에서 효과별 파이프라인 + `[time] + EffectShaders.params(name, constants)` 를 float 버퍼로 `setFragmentBytes(index:0)`. g_Texture0=오프스크린 framebuffer, g_Texture1=마스크(없으면 흰색 1×1).
- `EffectUniforms`/`effectUniforms()`(waterwaves 전용) 제거, 일반 경로로 대체.

## 4. 컴포넌트
| 컴포넌트 | 위치 | 검증 |
|---|---|---|
| `EffectShaders.source(for:)`(vert+frag, 일반 유니폼) — waterwaves/scroll/opacity/tint | WapleRender | 빌드 |
| `EffectShaders.params(for:constants:) -> [Float]`(효과별 슬롯 매핑+기본값) | WapleRender | **TDD** |
| `SceneRenderer` 효과 유니폼 일반화(float 버퍼) | WapleRender | 수동 |

## 5. 데이터 흐름
효과 적용 → effectName으로 `source` 컴파일 + `params(constants)` → `[time]+params` 버퍼 → frag가 fb/mask/params로 처리 → 다음 패스/합성.

## 6. 에러/강등
- 미지원 effectName → nil → 효과 스킵(베이스만). 마스크 디코드 실패 → 흰색 폴백. 무크래시.

## 7. 테스트
- **TDD**: `EffectShaders.params(for:constants:)` — scroll/opacity/tint/waterwaves 각각 슬롯 순서·기본값(없는 키→기본).
- **수동/자율 게이트**:
  - scroll: 타일/스크롤 씬에서 시간에 따라 흐르는지.
  - opacity: 알파·마스크 적용으로 부분 투명.
  - tint: 색 틴트 + 마스크 적용.
  - waterwaves: **풀-마스크 씬(예 2842323353)** 에서 물결이 뚜렷한지(마스크 정확성 검증).

## 8. 범위 밖
- waterripple/shake(추가 텍스처 슬롯: 노멀/flow, 마스크 g_Texture2), tint 블렌드모드 다양화, common_blending.h/combo, 사용자 효과-강도 설정 → SP3c+. [완료 2026-07-04: waterripple(SP3c)·shake(EffectShaders) 모두 구현됨]
- 파티클(SP4)·오디오(SP5)·퍼펫(SP6).
