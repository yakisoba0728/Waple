# Source-Backed LDR Bloom Design

**Date:** 2026-07-14
**Status:** Approved

## Goal

`general.bloom == true && general.hdr == false`인 2D·3D Scene의 최종 framebuffer에 WE의 고정 2단
LDR bloom을 적용한다. HDR/ACES 및 다른 post effect는 변경하지 않는다.

## Parameters

- `bloomstrength`: 기본 `2`, 상한 clamp 없음
- `bloomthreshold`: 기본 `0.65`, parser clamp 없음
- `bloomtint`: 기본 `(1,1,1)`

현재 parser의 strength/threshold 기본 `0`을 교정하고 `bloomTint`를 추가한다. `{value:...}`, 숫자,
문자열 입력을 기존 parser 규약으로 보존한다. `bloomHDR*` 필드와 기본값은 바꾸지 않는다.

## Confirmed Pass Chain

1. full-resolution source를 대각 네 sample 평균으로 quarter에 downsample한다.
2. `scale=max(rgb)` 후 `rgb *= saturate(scale-threshold)`로 bright-pass한다.
3. `gray=dot((0.2989,0.5870,0.1140),rgb)`, `rgb=2*rgb-gray`로 saturation을 적용한다.
4. `max(0, rgb*strength*tint)`를 quarter에 쓴다.
5. quarter→eighth에서 X축 discrete 13-tap blur를 적용한다.
6. eighth→bloom에서 Y축 같은 13-tap blur를 적용한다.
7. source에 linearly filtered bloom 한 sample을 더해 destination에 쓰고 alpha는 `1`로 둔다.

13-tap weight는 바깥에서 중심 순서로
`0.006299, 0.017298, 0.039533, 0.075189, 0.119007, 0.156756, 0.171834`이며
중심 외 항목을 대칭 적용한다. CPU `g_TexelSize` packing과 intermediate RT format은 미확정이므로,
Waple 구현은 실제 quarter/eighth texture의 texel size와 `.bgra8Unorm`을 사용한다고 명시한다.

## Architecture

새 `LDRBloomPass`는 immutable Metal pipelines/MSL만 소유하며 다음 원자적 진입점을 제공한다.

```swift
func encode(commandBuffer: MTLCommandBuffer,
            source: MTLTexture,
            quarter: MTLTexture,
            eighth: MTLTexture,
            bloom: MTLTexture,
            destination: MTLTexture,
            parameters: LDRBloomParameters) -> Bool
```

`SceneRenderer`가 `max(1,w/4)`, `max(1,h/4)`, `max(1,w/8)`, `max(1,h/8)` intermediate를 기존 frame
pool에서 준비한다. 모든 texture가 준비된 뒤에만 encode한다. live와 headless capture가 같은 finalizer를
호출하며 bloom capture는 source와 readback destination을 분리한다. 비-HDR 3D도 camera pass 뒤 같은
scene-global finalizer를 사용한다.

pipeline 생성, texture 할당, encoder 생성 중 하나라도 실패하면 source를 raw blit해 현재 출력으로
되돌린다. 부분 bloom이나 검은 frame을 제출하지 않는다. teardown은 pass를 해제한다.

## Tests

- parser 기본값, tint, 숫자/문자열/`{value}`와 HDR 필드 무변경
- Metal pipeline compile 및 홀수·8px 미만 texture 크기
- threshold 아래 source가 그대로이고 `strength=0`이 raw source와 동일함
- 고립 bright pixel이 주변 pixel로 퍼짐
- red tint가 green/blue bloom을 억제함
- `bloom:false`, `hdr:true`는 기존 경로를 유지함
- 2D와 비-HDR 3D headless capture가 같은 finalizer를 거침
- pass/resource 실패 시 byte-equivalent raw fallback

전체 suite와 render corpus는 실행하지 않고 parser, pass, 작은 synthetic renderer test만 실행한다.

## Exclusions

HDR bloom/soft-knee/pyramid, ACES 변경, `ccsimple`, LUT, general property script의 동적
`bloomstrength` 변경은 포함하지 않는다.
