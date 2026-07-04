# Waple — Scene SP5: 오디오-반응 (pulse + 범용 audioResponse) 설계 문서

- 작성일: 2026-06-25
- 상태: 설계 확정(자율 — "이어서 SP5 진행해")
- 선행: SP4 파티클 + 공유 에셋 폴백 main 병합.
- 범위: WE 표준 **오디오 응답 축약식** + 스톡 **pulse** 효과 포팅 + 효과 파이프라인에 per-frame 오디오 주입. **+ 전체 BLENDMODE enum(0–32) 확정 → tint blend mode 수정**.

---

## 상태(2026-07-04) — 본체 구현 + "보류"였던 트랜스파일러도 완료

SP5 본체(AudioResponse 리듀서·16빈 스펙트럼·pulse·applyBlending·tint 수정)는 구현·병합됨. 갱신 요점:

- **§5 "GLSL→MSL 트랜스파일러(다개월 규모)로 보류" [완료]**: 범위 밖으로 미룬 트랜스파일러가 이후 실제로 **구현되었다** — `2026-06-25-…glsl-to-msl-design.md`(Stage 1) + `2026-07-02-…glsl-stage2-design.md`(Stage 2). 임의 워크샵 GLSL 효과는 이제 전처리기·콤보·include·헬퍼 캡처를 거쳐 MSL 로 번역되고, 실패 시에만 손-포팅/스킵 폴백한다(`Sources/WapleCore/{ShaderPreprocessor,GLSLTranslator}.swift`). "프로젝트 성격을 바꾸는 다개월 분기 → 사용자 결정 보류" 판단은 무효.
- 나머지(오디오 식·blend enum·라이브 TCC 권한)는 유효.

---

## 1. 정찰 결과(실데이터: effects/pulse stock 셰이더)
- 오디오-반응은 scene.json 효과 패스의 `combos.AUDIOPROCESSING`(0=off,1=L,2=R,3=L+R평균) + constants(audioamount/audiobounds/audioexponent, frequencymin/max)로 선언. 18개 씬에서 사용.
- 스펙트럼 유니폼: `g_AudioSpectrum16Left[16]`, `g_AudioSpectrum16Right[16]` (채널당 16빈).
- **WE 표준 축약식**(pulse.vert `CreateAudioResponse`, 모든 오디오 효과 공통):
  ```
  sum = Σ_{a=int(min)..int(max)} (L[a] [+ R[a]])     // 포함 루프
  resp = sum / ((max-min+1) * channels)
  resp = smoothstep(bounds.x, bounds.y, resp)
  resp = saturate(pow(resp, exponent)) * multiply
  ```
  기본값: bounds "0.5 1.0"(셰이더 주석) — 단 scene.json 은 보통 audiobounds "0 1" 전달 → 씬 상수 우선, 없으면 0.5/1.0.
- pulse.frag: `pulse`(audio면 audioResponse, 아니면 time `smoothstep(thresh, sin(time*speed+phase)*.5+.5)*amount`). PULSECOLOR → `ApplyBlending(BLENDMODE, albedo*tintLow, albedo*tintHigh, pulse)`. PULSEALPHA → `albedo.a *= pulse`. MASK 옵션.
- **BLENDMODE enum(common_blending.h, 확정)**: 0=Normal,1=Darken,2=Multiply,3=ColorBurn,4=Subtract,5=Min,6=Lighten,7=Screen,8=ColorDodge,**9=Add**,10=Max,11=Overlay,12=SoftLight,13=HardLight,…30=Tint,31=A+B·o,32=mix(A,A+A·B,o). pulse PULSECOLOR 기본 BLENDMODE=9(Add).

## 2. 설계

### 2.1 순수 audioResponse 리듀서 (WapleCore)
- `enum AudioResponse { static func compute(left:[Float], right:[Float], mode:Int, freqMin:Float, freqMax:Float, bounds:SIMD2<Float>, power:Float, multiply:Float) -> Float }`.
- WE 식 1:1 구현(int 절단, 포함 루프, 채널수 나눗셈, smoothstep→pow→saturate→×multiply). **TDD**(손계산 값: zero→0; all-ones bounds(0,1)→1; mode1/2/3).

### 2.2 16빈 스펙트럼 소스 (WapleRender)
- `struct AudioSpectrum16 { var left:[Float]; var right:[Float] }`(각 16). 합성 주입 가능(테스트/캡처).
- 라이브: 기존 `SystemAudioSpectrumProvider`(128빈 모노) → 16빈 그룹핑(`downsample16`), L=R 근사(v1). **라이브 캡처만 Screen Recording(TCC) 권한 필요** — 그 클릭만 사용자 개입.
- FFT 그룹핑 정밀도는 라이브 전용이므로 깊이 파지 않음(합성으로 전 경로 검증).

### 2.3 효과 콤보/오디오 파싱 (WapleCore)
- `SceneEffect` 에 `combos: [String:Int]` 추가(passes[0].combos). `audioMode` 는 `combos["AUDIOPROCESSING"] ?? 0`.
- 오디오 파라미터(audioamount/audiobounds/audioexponent/frequencymin/max)는 기존 `constants` 에 이미 캡처됨.

### 2.3 pulse 효과 + 공유 ApplyBlending (WapleRender)
- `EffectShaders` 에 `pulse` frag 추가. 공유 MSL `applyBlending(int mode, float3 A, float3 B, float o)`(흔한 모드 0–13 + 30; 그 외 Normal). 런타임 분기(단일 셰이더).
- `EffectShaders.params(for:constants:combos:)` — combos 인자 추가(기본 `[:]`, 기존 호출 무변). pulse params: [speed,phase,amount,power,threshLo,threshHi, blendmode, pulseColor, pulseAlpha, audioMode, tintLo(3), tintHi(3)].
- pulse frag uniform: buffer(0)=`[time]+params`, buffer(1)=`audioResponse`(per-frame). audioMode>0 면 audioResponse 사용, 아니면 time 식.
- **tint 효과 수정**: 기존 0–4 패스스루 → 실제 BLENDMODE enum 사용(공유 applyBlending). 오래 보류된 항목 해소.

### 2.4 SceneRenderer 와이어링
- `EffectGPU` 에 `audio: AudioParams?`(mode,freqMin/Max,bounds,power,multiply) 저장(빌드 시 audioMode>0 일 때). build 시 hasAudio=true.
- `currentSpectrum: AudioSpectrum16`(기본 0). draw 의 `applyEffect`: audio!=nil 이면 `AudioResponse.compute(spectrum,...params)` → buffer(1) 바인드, 아니면 0.
- 라이브: hasAudio 면 SystemAudioSpectrumProvider 시작 → currentSpectrum 갱신. 캡처/테스트: `setSpectrum(_:)` 합성 주입.

## 3. 컴포넌트 / 검증
| 컴포넌트 | 위치 | 검증 |
|---|---|---|
| `AudioResponse.compute` | WapleCore | **TDD**(손계산) |
| `SceneEffect.combos`/audioMode 파싱 | WapleCore | **TDD** |
| `AudioSpectrum16` + downsample16 | WapleRender | **TDD**(그룹핑) |
| `EffectShaders.pulse` + applyBlending + tint 수정 | WapleRender | **MSL 컴파일** + params TDD |
| `SceneRenderer` 오디오 주입 + 합성 주입 | WapleRender | **PNG 시각**(audio=0 vs 高, PULSEALPHA) |

## 4. 에러/강등
- 권한 거부/무오디오 → 0 스펙트럼(배경 계속 렌더). audioMode 미지원 효과 → 무시. 무크래시.

## 5. 범위 밖 (FYI — 전략적 천장)
- **임의 워크샵 GLSL 셰이더** — [완료 2026-07-04: 트랜스파일러 구현됨, glsl-to-msl(Stage 1)+glsl-stage2(Stage 2)]: (audio_responsive_oscilloscope 27KB 등)는 pkg에 GLSL 소스로 존재하나, 렌더하려면 **GLSL→MSL 트랜스파일러**(SPIRV-Cross + WE 전처리기/콤보/include 재구현, 다개월 규모)가 필요. 이는 프로젝트 성격을 바꾸는 분기 → 사용자 결정 사항으로 보류. 스톡 효과(effects/*)는 손-포팅으로 커버 가능(러닝웨이 충분).
- 스크립트 기반 속성(constantshadervalues/*/script JS), 스테레오 분리, 전체 32 blend mode(흔한 것만), 다른 스톡 오디오 효과(이후).
