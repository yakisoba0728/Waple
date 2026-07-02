# 유저 속성 편집 — 설계

날짜: 2026-07-02. 브랜치 `feat/user-properties`. WE 파리티: 배경별 속성 패널(색/슬라이더/체크/콤보/
텍스트)을 편집하면 저장되고 배경에 반영된다(웹: applyUserProperties 재주입 의미론, 씬: user 바인딩 필드).

## 구성

1. **모델 확장(WapleCore, TDD)**: WallpaperProperty += text(라벨), min/max/step(슬라이더),
   options[(label,value)](콤보). `applying(overrides:)` 로 효과값 병합(순수).
2. **저장(WapleRender)**: `UserPropertyStore` — 배경 id 별 [key: PropertyValue] UserDefaults(JSON) 영속.
3. **적용 — 웹**: WebRenderer 가 효과값으로 weUserPropertiesJSON 생성(기존 주입 경로 재사용).
4. **적용 — 씬**: 실물 바인딩 `{"user": "이름", "value": 기본}` — SceneDocument.parse(userProps:) 로
   visible/수치/색 바인딩과 effect constantshadervalues 의 user 키를 오버라이드. SceneRenderer 가
   mount 시 스토어에서 로드해 전달.
5. **UI(Waple)**: 라이브러리 선택 배경의 "속성…" 시트 — 타입별 컨트롤(bool→Toggle, slider→Slider,
   color→ColorPicker, combo→Picker, textinput→TextField, text→라벨, file→v1 스킵) + 초기화.
   변경 즉시 저장, 현재 적용 중이면 재적용(fit-mode 패턴). condition(속성 간 표시 조건식)은 v1 무시(표시만).

## 검증

단위: 확장 파스(라벨/범위/옵션), 병합, 스토어 영속, 씬 user 바인딩 오버라이드(visible off→레이어 드롭,
alpha 오버라이드), 웹 JSON 에 오버라이드 반영. 실물: 3115349801 속성 오버라이드 주입 확인(기존 GT 확장),
씬 GT 회귀. 스위트/릴리스 그린, ff-merge.
