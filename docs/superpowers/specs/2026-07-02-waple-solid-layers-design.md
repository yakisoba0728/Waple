# 솔리드 레이어 + 공유 모델 폴백 + 바인딩 값 언랩 — 설계

날짜: 2026-07-02. 브랜치 `feat/solid-layers`. 근거: 실측 31씬에서 util 모델 레이어 60개 드롭
(solidlayer 18, fullscreenlayer 9, projectlayer 2, solid_instance 6, composelayer 25).

## 실측 구조 (assets 팩 + pkg 대조)

- `models/util/solidlayer.json` = `{material: materials/util/solidlayer.json, solidlayer: true}`;
  그 머티리얼은 shader "flat", **textures 없음** → 오브젝트 color/alpha 로 솔리드 필.
- `models/solid_instance_model_*.json` (pkg 내부) → material `materials/util/solidlayer_instance.json`
  (**base-assets 전용**), genericimage2 + textures ["util/white"] → JSON 폴백만 있으면 기존 텍스처 폴백으로 완결.
- `models/util/fullscreenlayer.json`/`composelayer.json` → textures ["_rt_FullFrameBuffer"] = 하위 컴포지트
  프레임버퍼 참조 → **컴포지션 의미론 = 다음 SP** (이번엔 명시적 로그와 함께 스킵 유지).
- 씬 오브젝트의 origin/alpha 등이 **바인딩 객체** `{"animation": {...}, "value": X}` 로 옴 —
  현재 파서는 `as? String`/`as? Double` 실패 → 기본값 → 배치/투명도 오류. 정적 `value` 언랩 필요
  (프로퍼티 애니메이션 재생 자체는 별도 후속 기능).

## 변경

1. **SceneDocument.parse(package:assets:)** — `assets: (String) -> Data?` 리졸버 주입(기본 nil).
   모델/머티리얼 JSON 로드가 pkg → assets 순으로 폴백. WapleCore 순수성 유지(파일 IO 는 호출자 소관).
   SceneRenderer 가 BaseAssetsSettings 디렉터리 파일 읽기 클로저를 전달.
2. **무텍스처 머티리얼 → 솔리드 마커**: 유효 텍스처 이름이 없으면 `textureEntryName = ""` 로 레이어 생성.
   렌더러 buildLayers 는 "" → 흰색 1x1 텍스처(기존 tint 경로가 color×brightness, alpha 적용 = 솔리드 필).
3. **`_rt_` 텍스처 레이어는 파스 단계에서 명시 스킵** + "composition layer unsupported" 로그(다음 SP 게이트).
4. **바인딩 값 언랩**: float/vec2/vec3 게터가 `{"value": ...}` 객체도 수용(visible 은 기존 처리).

## 검증

단위(TDD): 언랩/폴백/솔리드마커/_rt_ 스킵. 렌더: 솔리드(검정 α0.5 over 흰 bg → luma≈0.5) PNG.
실측: GT run — solidlayer/solid_instance 드롭 소멸(2947302287, 3147346398 등 PNG 육안), 스위트/릴리스 그린.
