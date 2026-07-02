# 텍스트 레이어 + 텍스트 프로퍼티 스크립트(JS) — 설계

날짜: 2026-07-02. 브랜치 `feat/text-layers`. 실측: 뮤직비주얼라이저/정보형 씬의 잔여 핵심
(2881558311/3288383262/3352517853 등 — Clock/Date/Song Title 텍스트 오브젝트).

## 실물 스키마

scene.json 오브젝트에 `text` 키: 값은 평문 문자열 **또는** `{"script": "...JS..."}`.
필드: font("systemfont_arial" | "fonts/....otf|ttf" — pkg/base-assets), pointsize(씬 픽셀 단위),
color/alpha, horizontalalign/verticalalign, origin, size(=스케일 배수, 예 "2 2"), padding, maxwidth 등.
스크립트 계약: `createScriptProperties()` 빌더(.addCheckbox/.addText/.addSlider/.addCombo → .finish()
= name→기본값 객체) + `export function update(value) → String`. engine/shared 등 엔진 API 참조 가능.

## 구현

1. **파스(WapleCore)**: `SceneTextLayer` — order/origin/scale/color/alpha/pointsize/font/halign/valign +
   text(평문) + script(JS 소스, 있으면). SceneDocument.texts 로 수집(visible 필터/바인딩 언랩 공유).
2. **TextScriptEngine(WapleRender, JavaScriptCore)**: ES export 구문 제거 → JSContext 에
   createScriptProperties 빌더 + engine/shared/thisScene Proxy(no-op catch-all) 심 주입 → 평가 →
   `update(현재텍스트)` 호출 결과 반환. 예외/미정의 → nil(텍스트 비움 + 로그) — 미디어류 스크립트는
   데이터가 없어 자연히 빈 문자열(graceful).
3. **TextRasterizer(WapleRender, CoreText)**: 흰색 글리프 + 알파(straight)로 래스터 → 텍스처.
   색/알파는 기존 레이어 tint 경로가 적용(규약 일관). 폰트: "fonts/..." → pkg→base-assets 바이트 →
   CTFontManagerCreateFontDescriptorFromData(전역 등록 불필요); "systemfont_X" → NSFont(name:) → 시스템 폴백.
4. **렌더러**: GPUText { texture, vbuf, tint, order, engine?, lastText }. drawPlan 을 3-종(layer/particle/text)
   으로 확장, 씬 순서 인터리브 유지. 지오메트리: 비트맵 px = 씬 px, ×scale, origin 앵커(halign/valign).
   라이브: 초당 1회 update() 재평가 → 변경 시 재래스터(시계 갱신). captureFrames: 캡처 시점 1회 평가.

## 검증

단위: 파스(평문/script 추출), 스크립트 엔진(실물 시계 스크립트 패턴 → HH:MM 일치, 오류 → nil,
프로퍼티 빌더), 래스터(치수>0, 알파 픽셀 존재). 렌더 PNG: "HELLO" 텍스트가 검정 bg 에 밝은 픽셀.
실측 GT: 시계 씬 PNG 에 현재 시각 문자열 육안 확인. 스위트/릴리스 그린.
