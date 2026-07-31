# Waple — Scene SP3c: 다중 텍스처 효과 + waterripple + tint 블렌드 모드 (설계 문서)

- 작성일: 2026-06-25
- 상태: 설계 확정(자율 진행 — "끝까지 해" 지침, 승인 대기 없이 진행)
- 선행: SP3b(scroll/opacity/tint + 일반 유니폼) main 병합.
- 범위: **다중 텍스처 슬롯** 효과 지원 + **waterripple**(노멀맵 물결) + **tint 블렌드 모드**(흔한 것). shake는 다음(common.h+combo+flow로 가장 bespoke).

---

## 상태(2026-07-04) — shake 구현됨

SP3c 본체(다중 텍스처 슬롯·waterripple·tint 블렌드 모드)는 구현·병합됨. 갱신 요점:

- **shake [완료]**: SP3b·SP3c 가 "범위 밖 / 다음"으로 미룬 shake 효과는 이후 손-포팅되었다 — `Sources/WapleRender/EffectShaders.swift`(`case "shake":` 파라미터 매핑 + shake frag MSL). 따라서 §6·§8 의 "shake 는 별도/범위 밖" 서술과 SP3b §8 의 동일 항목은 폐기.
- 나머지(specular 생략·전체 블렌드모드~30종 미구현)는 유효.

---

## 1. 개요 / 목표
효과 프레임워크가 framebuffer + 마스크 1장만 바인딩 → **임의 개수 텍스처 슬롯**으로 일반화(노멀/flow 맵 등). 이를 활용해 waterripple(노멀맵 기반 물결+specular)을 추가하고, tint에 흔한 블렌드 모드를 더한다.

## 2. 정찰 결과
- waterripple 텍스처: object effect `textures: [null, "effects/waterripplenormal", "util/white"(mask)]` → g_Texture0=framebuffer, g_Texture1=노멀맵, g_Texture2=마스크. 노멀맵은 pkg 엔트리 `materials/effects/waterripplenormal.tex`(이름 `effects/X`→`materials/effects/X.tex`). `util/white`→흰색 폴백.
- waterripple.frag: 노멀맵을 시간 스크롤로 샘플 → framebuffer UV를 노멀로 왜곡(strength) + specular(combo, 기본 OFF). 유니폼: strength, specular*. 오브젝트 constants: ratio, ripple_scale, ripple_strength.
- tint: BLENDMODE combo(common_blending.h, 기본 30). SP3b는 normal만 구현됨.

## 3. 설계

### 3.1 다중 텍스처 슬롯 (프레임워크)
- `SceneEffect`에 `textureNames: [String?]` 추가(scene.json object effect `textures[]`; slot0=null=framebuffer). 기존 `maskTextureName` 제거(textureNames로 대체; 마지막 또는 명시 슬롯이 마스크).
- `EffectGPU`에 `auxTextures: [MTLTexture]`(slot1..N 디코드 결과; 실패 슬롯은 흰색 1×1).
- `applyEffect`: g_Texture0=오프스크린 framebuffer, 이후 `auxTextures[i]`를 texture(i+1)에 바인딩.
- 효과 frag는 자기가 쓰는 texture0..N 선언.

### 3.2 waterripple (frag 손-포팅)
- 공유 vert. frag: 노멀맵(g_Texture1) 시간 스크롤 샘플 → 노멀 xy로 framebuffer UV 변위(× strength × mask(g_Texture2).r). specular는 SP3c에선 생략(기본 OFF). params 순서: [time, strength, scale, scrollSpeed].
- 노멀맵/마스크는 다중 텍스처 슬롯으로 바인딩.

### 3.3 tint 블렌드 모드
- `EffectShaders` tint frag에 블렌드 함수 추가: normal/multiply/add/screen/overlay. params에 `blendMode`(float enum) 추가 → frag가 분기.
- 매핑: WE BLENDMODE enum(예 0=normal,…)에서 흔한 것만; 미지원 모드→normal. 정확 enum은 게이트서 확인.

## 4. 컴포넌트
| 컴포넌트 | 위치 | 검증 |
|---|---|---|
| `SceneEffect.textureNames:[String?]` + parseEffects(textures[] 전체) | WapleCore | **TDD** |
| `EffectShaders`: waterripple frag + tint 블렌드 모드 + params(waterripple/tint) | WapleRender | **TDD**(params) + 빌드 |
| `SceneRenderer`: 다중 텍스처 바인딩(auxTextures), effectMask→일반 텍스처 해석 | WapleRender | 빌드 |
| (순수) `BlendMode` 헬퍼/math(테스트용) | WapleRender | **TDD** |

## 5. 데이터 흐름
효과 적용 → effectName source + params + textureNames 해석(각 슬롯 디코드) → applyEffect가 framebuffer+aux 텍스처 바인딩 + `[time]+params` → frag 처리.

## 6. 에러/강등
- 텍스처 슬롯 디코드 실패 → 흰색 1×1. 미지원 effect/블렌드모드 → 스킵/normal. 무크래시.

## 7. 테스트
- **TDD**: `parseEffects` textureNames(slot0 null + 이름들), `EffectShaders.params(waterripple/tint+blendMode)`, blend-mode 분기값(셰이더는 빌드; 블렌드 수학은 순수 헬퍼로 테스트).
- **수동/자율 게이트(best-effort)**: waterripple 씬(1412044563)에서 노멀맵 물결, tint 블렌드 모드 씬(2902406982/3395777145). 스모크(무크래시). 시각 정밀 검증은 데스크탑 가시 시.

## 8. 범위 밖
- **shake** — [완료 2026-07-04: EffectShaders 에 손-포팅됨]: (common.h+noise/direction combo+flow map — 별도), waterripple specular, 전체 블렌드모드(~30종), 파티클(SP4)·오디오반응(SP5)·퍼펫/3D(SP6).
