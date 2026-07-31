# Waple 메인 UI 개편 — "실제 Wallpaper Engine처럼" (2026-07-11)

승인된 설계. 목표: 분산된 창/컨텍스트메뉴 UI를 실제 Wallpaper Engine(이하 WE)의
"한 창에서 전부" 구조로 통합한다. 데이터 계층은 건드리지 않는다 — UI 재배치가 전부다.

## 확정 요구사항

1. **범위**: 통합 메인창(그리드+검색/필터/정렬+우측 속성 패널+하단 바) + 디스플레이 탭 + 워크샵 탭.
   상태바 메뉴는 전역 설정 전용으로 유지(창 열기 항목은 "Waple 열기" 하나로 통합).
2. **스타일**: WE 다크 고정(`NSAppearance(named: .darkAqua)` 창 단위 강제) + macOS 네이티브 컨트롤.
   픽셀 클론 아님 — 레이아웃·밀도·항상 다크만 WE를 따른다.
3. **미리보기**: preview.gif 애니 재생(그리드 호버 + 우측 패널), 정적 이미지 폴백. 라이브 렌더 임베드 없음(WE도 안 함).

## 레이아웃

```
┌────────────────────────────────────────────────────┐
│ [설치됨] [워크샵] [디스플레이]   🔍검색  [타입▾][정렬▾] │ ← TopBar
├──────────────────────────────────────┬─────────────┤
│  월페이퍼 그리드 (LazyVGrid)           │ SelectionPanel│
│  호버=gif+제목 / 클릭=선택 / 더블클릭=적용│ 고정폭 ~300pt │
├──────────────────────────────────────┴─────────────┤
│ 현재: <배경명> │ ▶재생목록 ⏭ 간격▾ │ ⏸일시정지        │ ← BottomBar
└────────────────────────────────────────────────────┘
```

- **설치됨 탭**: 그리드(좌) + SelectionPanel(우). 속성 편집은 기존 시트를 폐지하고 패널에 인라인(WE 방식).
  타일: 타입 뱃지(scene/video/web), 미지원은 감광+뱃지 유지. 컨텍스트 메뉴는 보조로 존치.
- **SelectionPanel**: preview(gif), 제목·타입·폴더 경로, [적용] [모니터에 적용▾] [재생목록 추가/제거],
  웹 타입이면 [조작 창 열기], 아래로 PropertyEditor 인라인. 선택 없음 = 플레이스홀더.
- **디스플레이 탭**: `NSScreen.screens` 비례 배치 다이어그램(WE 모니터 선택 화면).
  모니터 클릭 → 할당 배경 표시 + "선택한 배경 적용"(설치됨 탭에서 선택된 항목) / "할당 해제".
- **워크샵 탭**: 기존 WorkshopView 로직 무변경 이식(별창 폐지).
- **BottomBar**: 현재 적용 배경명, 재생목록 재생/다음/간격, 전역 일시정지 토글 — 전부 기존 AppLogic/AppDelegate 기능의 재노출.

## 구현 원칙

- **데이터 계층 무변경**: LibraryStore / PlaylistStore / MonitorAssignmentStore / UserPropertyStore / AppLogic 그대로.
  LibraryViewModel에 UI 상태만 추가: `searchText`, `typeFilter`, `sortOrder`(이름/최근추가), 필터·정렬된 `filteredEntries`.
- **GIF**: `NSImageView(animates=true)` NSViewRepresentable 랩. 의존성 0. 그리드에선 호버 중에만 animates=true(성능).
  preview가 gif가 아니면 기존 PreviewImageCache 정적 경로.
- **파일 구성** (Sources/Waple/):
  - `MainWindowView.swift` — 탭 셸 + TopBar + BottomBar (신규)
  - `WallpaperGridView.swift` — LibraryView.swift 개조·개명(임포트/드롭 로직 유지)
  - `SelectionPanelView.swift` — 신규, PropertyEditorView 임베드
  - `DisplaysTabView.swift` — 신규
  - `WorkshopView.swift` — 탭 이식만
  - `AppDelegate.swift` — libraryWindow→mainWindow 승격(다크 강제, 최소 크기 ~1100×700), workshopWindow 제거,
    상태바 메뉴 항목 정리
- **테스트**: 뷰모델 로직만 유닛(WapleAppTests) — 필터/정렬 조합, 디스플레이 다이어그램 좌표 매핑(순수 함수로 분리),
  gif/정적 프리뷰 URL 선택 로직. 픽셀·레이아웃은 수동 스모크.

## 수용 기준

1. 메인창 하나에서: 검색→선택→속성 수정→적용→모니터 지정→재생목록 관리가 전부 가능.
2. 워크샵 다운로드 → 그리드 자동 반영(기존 동작 유지).
3. 디스플레이 탭 다이어그램이 실제 모니터 배치와 비례 일치, 할당/해제 즉시 반영.
4. 항상 다크. 시스템 라이트 모드에서도 다크 유지.
5. 기존 기능 퇴행 없음: 드롭 임포트, zip/동영상 임포트, 조작 창, 미지원 뱃지, 컨텍스트 메뉴.
6. `swift build` 에러 0, 기존+신규 테스트 green.

## 비범위 (이번 패스 아님)

- 상태바 전역 설정의 다이얼로그화(WE 설정창) — 후속.
- 워크샵 탭 내부 UX 개선(검색/페이지네이션) — 이식만.
- 라이브 렌더 미리보기, 타일 크기 슬라이더, 폴더/태그 분류.
