# Waple — Scene SP3a: 효과 패스 프레임워크 + BC3 디코드 + waterwaves (설계 문서)

- 작성일: 2026-06-24
- 상태: 설계 확정(자율 진행)
- 선행: SP1/SP1.5/SP2 병합(main). `SceneRenderer`(Metal 컴포지터)·`TexImage`/`TexDecoder`·`SceneDocument` 존재.
- 범위: 객체별 **효과 패스 프레임워크** + **BC3/LZ4/DXT5 디코드**(마스크용) + **waterwaves 손-포팅** + g_Time 애니메이션.
  엔드투엔드 타깃: `2111201226`(WallpaperEngine 객체 + waterwaves + 마스크).

---

## 1. 개요 / 목표
WE 효과(포스트프로세스 패스)를 씬 객체에 적용한다. 객체의 베이스 이미지를 오프스크린 텍스처로 렌더한 뒤,
효과 프래그먼트 셰이더가 그 framebuffer(g_Texture0) + 마스크(g_Texture1) + 유니폼으로 처리해 합성한다.
SP3b(blur/tint/scroll/opacity/shake)와 그 이후 효과가 올라설 기반.

## 2. 정찰 결과 (Ground Truth)
- **효과 부착**: `object.effects = [{ file:"effects/<name>/effect.json", passes:[{ constantshadervalues:{...}, textures:[null|fb, "masks/<mask>"] }] }]`.
  `constantshadervalues` = 유니폼 값(speed/scale/strength/perspective/direction…), `textures[1]` = 마스크(BC3 .tex).
- **waterwaves.frag**(≈15줄, self-contained, #include 없음): `g_Texture0`(framebuffer) UV를 `sin(g_Time*g_Speed + dot(uv,dir)*g_Scale)`로 왜곡, 마스크로 강도 변조. `texSample2D`(=texture2D), `gl_FragColor`, 표준 벡터 수학 → **Metal 손-포팅 직관적**.
- waterwaves.vert: `v_TexCoord`(xy=framebuffer uv, zw=mask uv) + `v_Direction`(direction 파라미터로 회전한 단위벡터) 계산.
- **BC3 .tex 구조**(SP2 정찰): TEX 헤더(format=9) → TEXB0003/0004 → mip 헤더에 `decompressedSize`(=DXT5 raw=ceil(w/4)*ceil(h/4)*16) + `compressedSize` → **LZ4 raw 페이로드**. 디코드 = LZ4 해제 → DXT5(BC3) 블록 디코드 → RGBA.

## 3. 설계

### 3.1 BC3/LZ4/DXT5 디코드 (WapleCore + WapleRender)
- `TexImage` 확장: format==9일 때 TEXB 컨테이너 파싱 → `bc3: BC3Mip?{ width, height, decompressedSize, compressedSize, payloadRange }`.
- `TexDecoder.rgba`의 `.bc3` 경로: `payloadRange` 바이트를 **Apple Compression(`COMPRESSION_LZ4_RAW`, dst=decompressedSize)** 로 해제 → **DXT5 블록 디코드**(4×4 블록: 8B 알파(BC4) + 8B 컬러(BC1)) → RGBA8888.
- DXT5 블록 디코드는 순수 알고리즘 → TDD(알려진 블록 벡터).

### 3.2 효과 패스 프레임워크 (WapleRender)
- 객체별: 베이스 이미지를 **오프스크린 MTLTexture A**에 렌더 → 각 효과 패스마다 효과 프래그먼트 셰이더로
  A(g_Texture0)+마스크(g_Texture1)+유니폼을 샘플해 **텍스처 B**에 렌더(ping-pong) → 최종 결과를 화면에 합성.
- 효과 셰이더는 **손-포팅 MSL 레지스트리**: `effectName → (vert, frag MSL)`. SP3a는 `waterwaves`만. 미지원 효과는 스킵(베이스만).
- 유니폼: `g_Time`(전역 애니메이션 시계) + `constantshadervalues`(speed/scale/strength/perspective/direction).

### 3.3 애니메이션 (g_Time)
- 효과 있는 씬은 MTKView를 **연속 드로우**(`isPaused=false`, `preferredFramesPerSecond=30`)로 전환, g_Time 누적.
- ⚠️ **가림 스로틀링**: 창이 가려지면 드로우 일시정지(배터리). 데스크탑 보일 때만 애니메이션. 효과 없는 정적 씬은 기존 온디맨드 유지.

## 4. 컴포넌트
| 컴포넌트 | 위치 | 검증 |
|---|---|---|
| `TexImage.bc3: BC3Mip?`(TEXB mip 파싱) | WapleCore | **TDD** |
| `DXT5Decoder.decode(blocks,w,h)->RGBA` (순수) | WapleRender | **TDD** |
| `TexDecoder` `.bc3` 경로(LZ4 해제 + DXT5) | WapleRender | **TDD**(라운드트립) |
| `SceneLayer.effects: [SceneEffect]` 파싱(name/constants/maskName) | WapleCore | **TDD** |
| `EffectShaders`(waterwaves MSL vert+frag, 레지스트리) | WapleRender | 빌드 |
| `SceneRenderer` 오프스크린 패스 + 효과 적용 + g_Time 애니메이션 + 가림 일시정지 | WapleRender | 수동 |

## 5. 데이터 흐름
적용 → SceneRenderer: 각 객체 베이스를 오프스크린 A에 렌더 → 효과 있으면 effectName 레지스트리에서 MSL 로드 →
마스크(BC3 디코드)·constants·g_Time로 A→B 패스 → B를 레이어로 합성. g_Time는 디스플레이 루프로 증가(가림 시 정지).

## 6. 에러/강등
- 미지원 effectName/마스크 디코드 실패 → 효과 스킵(베이스 레이어만). 무크래시.
- BC3/LZ4 해제 실패(포맷 불일치) → 해당 텍스처 스킵.
- 효과 없는 씬 → 기존 정적/패럴랙스 경로(애니메이션 루프 미가동).

## 7. 리스크 / 게이트
- **LZ4 변형**: WE가 raw LZ4 블록인지 실측 검증(디코드 결과가 유효 DXT5/이미지인지). 프레임 포맷이면 `COMPRESSION_LZ4` 시도.
- **오프스크린 좌표/uv 방향**: 효과 패스의 framebuffer uv·마스크 uv·Y축은 실측 게이트(첫 결과가 뒤집힘/오프셋 가능).
- **waterwaves 느낌**(speed/scale 스케일): constantshadervalues 그대로 + g_Time 단위 매칭 실측.
- **가림 스로틀링**(애니메이션): 데스크탑 보일 때 동작·가려지면 정지 실측(G2식).
- **DXT5/LZ4 정확도**: 디코드 출력이 마스크로서 합당한지(그라데이션/형상) 실측.

## 8. 테스트
- **TDD**: `TexImage.bc3` mip 파싱(합성 TEXB), `DXT5Decoder`(알려진 블록→RGBA), `TexDecoder.bc3` 라운드트립
  (작은 DXT5를 LZ4 압축→.tex 합성→디코드), `SceneLayer.effects` 파싱(name/constants/maskName).
- **수동/자율 게이트**: `2111201226`가 waterwaves 물결 왜곡 + 마스크 적용으로 애니메이션 렌더; 가림 시 정지.

## 9. 범위 밖
- 다른 효과(blur/tint/scroll/opacity/shake = SP3b), 씬-와이드 효과/bloom, 다중 패스(>1)·다중 효과 체인 심화,
  파티클(SP4)·오디오(SP5), perspective 패럴랙스, 자동 GLSL→Metal 변환.
