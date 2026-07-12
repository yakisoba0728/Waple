# Waple UI/UX — 실제 Wallpaper Engine 완전 복제 (2026-07-12)

승인된 설계. [2026-07-11-waple-ui-design.md](2026-07-11-waple-ui-design.md)("픽셀 클론 아님" — 레이아웃·다크만 차용)를
**대체**한다. 이번 목표는 실제 Wallpaper Engine(이하 WE)과 **시각·상호작용 모두 동일한 수준**의 재현이다.
데이터 계층(스토어·ViewModel 콜백 계약·렌더러)은 보존하고 뷰 계층을 갈아엎는다.

## 확정 요구사항

1. **그라운드 트루스**: 사용자가 제공하는 실제 WE 스크린샷(`docs/reference/we/`, PNG, 가능하면 100% 배율·한국어 UI).
   스크린샷 없이는 해당 표면에 착수하지 않는다 — 근사 착수 금지.
2. **범위**: 앱 전체 표면 — 메인창(설치됨 탭: 필터 사이드바·그리드 페이지네이션·우측 선택 패널),
   하단 디스플레이 바 + 디스플레이 선택 화면, 워크샵 + 디스커버 탭, 설정 창, 트레이 메뉴. 서브 프로젝트(SP) 5개로 분해해 순차 진행.
3. **창 크롬**: 통합 다크 타이틀바 — `titlebarAppearsTransparent` + `fullSizeContentView`, macOS 신호등 유지(WE 다크 배경 위에 얹힘),
   탭바가 최상단에서 시작. 그 외 내부 UI는 100% WE.
4. **기능 갭**: 백엔드까지 최대한 구현. 로컬/Steam Web API로 받칠 수 있는 것은 전부 실동작(§기능 매핑),
   **모바일 페어링·월페이퍼 에디터·실제 스팀 투표만 예외**(비활성 + 툴팁).
5. **그래픽 자산**: SF Symbols 우선 + WE 특유 모양만 유사 벡터 직접 제작. **WE 설치 폴더의 실제 자산 파일·로고 복사 금지**(저작권).
   WE 로고 위치에는 Waple 브랜딩. 스크린샷은 개발 내부 레퍼런스로만 사용, 배포물 미포함(리포가 public이면 포함 여부는 사용자 판단).
6. **완료 기준**: 표면별로 `WAPLE_SMOKE` 기동 → 화면 캡처 → WE 스크린샷과 좌우 배치 비교 이미지 제시 → **사용자 판정이 SP 완료 게이트**.
   기존 테스트 전체 그린 유지는 기본.
7. **폰트**: WE는 Windows Segoe UI — 배포 불가하므로 시스템 폰트(SF Pro)에 크기·웨이트를 스크린샷 실측으로 맞춘다(승인된 근사).

## 접근법 (A안 — 디자인 시스템 선행)

`WETheme`(토큰) + WE 컨트롤 킷을 먼저 만들고 그 위에 표면을 하나씩 올린다. 수치가 뷰마다 갈라져 드리프트하던
기존 문제를 구조로 차단한다. SwiftUI 유지(고정 px + 커스텀 스타일로 픽셀 제어 충분), 특수 지점만 NSViewRepresentable(기존 패턴).

기각: B(표면 우선 돌진 — 하드코딩 드리프트 재발 위험), C(AppKit 재작성 — 기존 SwiftUI 자산 폐기, 이득 없음).

## 아키텍처

```
Sources/Waple/
  DesignSystem/          ← SP1. 유일한 수치 출처
    WETheme.swift          색(배경 4단계·액센트·텍스트 3단계·보더)·폰트 스케일·간격·코너 토큰.
                           값은 스크린샷 스포이드/실측만 기록 — 추측값 금지.
    WEControls.swift       버튼·체크박스·콤보·검색창·슬라이더·별점·배지·페이지네이션.
                           SwiftUI 표준 프로토콜(ButtonStyle/ToggleStyle 등) 구현 → `.buttonStyle(.we)` 소비.
  Shell/                 ← SP1
    MainWindowView.swift   통합 다크 타이틀바 + WE 탭바 + 하단 바 골격.
    WEStatusBanner.swift   창 내 오류/성공 배너(notify() UI 승격).
  Surfaces/
    Installed/           ← SP2. 필터 사이드바 · 그리드+페이지네이션 · 타일 · 우측 선택 패널
    Displays/            ← SP3. 디스플레이 선택 화면 + 하단 바 디스플레이 영역
    Workshop/            ← SP4. 워크샵 + 디스커버
    Settings/            ← SP5. 설정 창
```

원칙:
1. **수치는 WETheme에만** — 표면 뷰에 리터럴 색/간격 금지.
2. **뷰는 교체, 배선은 보존** — `LibraryViewModel`/`WorkshopViewModel`/스토어의 콜백 계약(onApply·onTogglePause 등) 그대로 소비.
   기존 뷰 파일(WallpaperGridView·SelectionPanelView·DisplaysTabView·WorkshopView·PropertyEditorView·현 MainWindowView)은
   각 SP에서 대체 완료 시 삭제. 플래그·병행 유지 없음.
3. **탭바 정확 구성(탭 이름·우측 상단 요소)·하단 바 배치·페이지당 타일 수 등 세부는 전부 스크린샷 확정 사항** —
   이 문서는 구조와 계약만 고정한다.

## 표면별 설계

### SP1 — 디자인 시스템 + 셸
- `WETheme` 토큰 + 컨트롤 킷(위 참조).
- 셸: 탭바(설치됨·디스커버·워크샵·모바일 — 스크린샷 확정) + 하단 바 골격 + `WEStatusBanner`.
- 창: `fullSizeContentView`/투명 타이틀바/신호등 유지, 기본·최소 크기는 WE 실측.
- 미커밋 `WAPLE_SMOKE` 훅(main.swift·AppDelegate) 정식 커밋 — 이후 전 SP의 검증 도구.

### SP2 — 설치됨 탭
- 좌: 접이식 필터 사이드바(타입 체크박스 다중선택·즐겨찾기·태그·나이등급).
- 중: 그리드 + 페이지네이션(WE 실측 페이지당 개수). 타일: 호버 gif·제목·타입 배지·즐겨찾기 별·평점(메타 있을 때만).
- 우: 선택 패널 — 프리뷰·제목·평점·속성 편집(기존 `PropertyControl.kind` 매핑 재사용, 겉만 WE 컨트롤)·액션 버튼.
- **신규: 라이브러리 제거**(`LibraryStore.remove(id:)`) — WE 우측 패널 제거 동작 대응. playlist/monitor orphan id 정리 동반
  (BACKLOG "LibraryStore.remove 부재" 항목 해소).

### SP3 — 디스플레이
- 하단 바 디스플레이 영역 + WE식 디스플레이 선택 화면.
- 기존 `MonitorAssignmentStore`·`DisplayDiagramLayout` 재사용, 겉만 교체.

### SP4 — 워크샵 + 디스커버
- 디스커버: 기존 `WorkshopClient` 정렬 쿼리(트렌드 3·최신 1·구독순 9·투표 0)를 행별로 조합해 WE 디스커버 레이아웃 재현.
- 워크샵: 검색+정렬+페이지네이션(`page` 파라미터 기존재)·다운로드 UI(기존 `DownloadUIState` 재사용).
- 모바일 탭: 표시하되 비활성 + 툴팁(페어링 프로토콜 재현 불가).

### SP5 — 설정 + 트레이
- WE 설정 창 구조(일반/성능/플레이리스트 등 — 스크린샷 확정)에 Waple 설정 매핑:
  fit 모드·가림 정지·base assets 경로·ffmpeg 안내·로그인 시작·정적 배경 동기화·화면보호기·동영상 음량/배속 기본.
- 메뉴바(트레이) 메뉴는 WE처럼 축소(현재 메뉴에 흩어진 설정이 전부 설정 창으로).

## 신규 백엔드

| 항목 | 구현 |
| --- | --- |
| 즐겨찾기 | `FavoritesStore`(favorites.json) — PlaylistStore 패턴(Codable + 손상 백업 규약 `backupCorruptStoreFile` 공유) |
| 태그·나이등급 필터 | `LibraryEntry`에 `tags: [String]?`·`contentRating: String?` 추가(optional → 기존 library.json 디코드 호환). import 시 채움, 기존 엔트리는 로드 시 project.json 재파싱으로 지연 백필 후 save |
| 필터 모델 | `LibraryFiltering.apply` 확장 — 타입 다중선택·태그·즐겨찾기·등급. 순수 함수 유지 |
| 페이지네이션 | 순수 함수(page/perPage) + `WEPagination` 컨트롤 |
| 평점 | `QueryFiles`에 `return_vote_data` 추가 → `WorkshopItem.voteScore` 파싱. 워크샵 다운로드 시 엔트리에 저장(optional), 있을 때만 별 표시 |
| 라이브러리 제거 | `LibraryStore.remove(id:)` + playlist/monitor orphan 정리 |
| 디스커버 | `WorkshopClient` 재사용(신규 네트워크 코드 없음), 행 조합 ViewModel |

## 기능 매핑 (WE 요소 → Waple)

| WE 요소 | 처리 |
| --- | --- |
| 설치됨/워크샵 탭, 검색·필터·정렬, 속성 편집, 재생목록, 모니터별 적용 | 기존 백엔드 실동작 |
| 디스커버 탭 | Steam Web API 쿼리 조합으로 실동작 (API 키 필요 — 미설정 시 기존 워크샵 탭과 동일한 키 안내 화면) |
| 즐겨찾기·별점 표시·태그/등급 필터·페이지네이션·항목 제거 | 신규 구현(위 표) |
| 구독/구독취소 | steamcmd 다운로드 / 라이브러리 제거로 매핑 |
| 모바일 탭 | 비활성 + 툴팁 (페어링 프로토콜 불가) |
| 월페이퍼 에디터 버튼 | 비활성 + 툴팁 (별도 앱 규모) |
| 실제 스팀 투표(별점 매기기) | 표시만 — 투표 액션은 비활성 (Steam 로그인 세션 불가) |

## 에러 처리

- `WEStatusBanner`: 적용 실패·임포트 실패·다운로드 실패를 창 내 배너로 표시(`LibraryViewModel.onError` 등 기존 콜백 소비).
- `AppDelegate.notify()`: 메인창이 열려 있으면 배너로, 아니면 기존 NSLog — NSLog는 항상 병행(AUDIT high "notify NSLog-only"의 표적 해소).
- 렌더러 쪽 에러 경로 불변.

## 검증

1. **기존 테스트 전체 그린 유지** (뷰 교체가 배선 계약을 깨지 않았음의 증명). 렌더러 무변경이므로 스냅샷 회귀는 최종 1회만.
2. **신규 순수 로직 단위 테스트** — 필터 확장·페이지네이션·FavoritesStore·vote 파싱·remove orphan 정리 (리포 규약: 순수 함수 추출, 실사용 경로 검증).
3. **표면별 좌우비교** — `WAPLE_SMOKE` 기동 → `screencapture` → WE 스크린샷과 좌우 배치 → 사용자 판정 = SP 완료 게이트.

## 레퍼런스 수급 (사용자 제공, `docs/reference/we/`)

| 시점 | 필요한 스크린샷 |
| --- | --- |
| SP1 (착수 전) | 메인창 전체(설치됨 탭 기본), 타이틀바·탭바 클로즈업, 하단 바 클로즈업 |
| SP2 | 필터 사이드바 열림, 타일 호버, 우측 패널(속성 많은 배경 선택), 정렬 드롭다운 열림, 페이지네이션 |
| SP3 | 디스플레이 선택 화면, 하단 바 디스플레이 영역 |
| SP4 | 워크샵 탭, 디스커버 탭 |
| SP5 | 설정 창 탭 전부, 트레이 메뉴 |

## 진행 규약

- SP 순서: 1 → 2 → 3 → 4 → 5. 각 SP는 "스크린샷 수령 → 치수·색 추출(WETheme 기록) → 구현 → 좌우비교 → 사용자 판정" 사이클.
- 커밋: 기존 스타일(`기능(ui): …`) 유지, SP 단위.
- 구현은 서브에이전트 구동(writing-plans → subagent-driven-development).
