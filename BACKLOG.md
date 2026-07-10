# Waple 백로그

> 2026-07-10 확정: 코퍼스(실물 460종) 기준 기능 완성 — scene 170/170 마운트, 시각 회귀 게이트
> 그린, 전 스위트 통과. 이 시점부터 **유지보수 모드**. 아래는 "해야 할 일"이 아니라
> **트리거가 오면 할 일**이다. 트리거 전에는 하지 않는다. 상세 근거는 [AUDIT.md](AUDIT.md)(감사
> 리포트, 2026-07-06)와 각 파일 위치 참조.

## 시각 충실도 — 트리거: 해당 씬을 실제 배경으로 쓸 때

| 항목 | 영향 | 메모 |
| --- | --- | --- |
| 3D 메시 라이팅 | 코퍼스 5씬 | 2D 포워드 라이팅(`f_lit`)은 완료. 3D 메시는 unlit(Mesh3DShaders). 실물 규약 유니폼 팩(SceneLight3D.packUniforms)은 이미 있음 |
| HDR/톤맵 | 라이트 씬 일부 | intensity>1(실측 최대 9.84) LDR 클램프 백화. 2D 라이팅 커밋에 한계 기록 |
| 원근 태양계 라이팅·노멀맵 1건·스팟 콘 | 각 1씬 내외 | 2D 라이팅 SP 잔여 목록 |
| 파리티 상위 각개 진단 | 2902406982(0.37) 등 | 방법: rank.py 랭킹 → drawPlan prefix 이분 → SKIP 노브 |

## 잠재 결함 — 트리거: 실제 파일/사용에서 물릴 때

- **PuppetModel 2D cstring Latin-1 3곳** → CJK 머티리얼 경로 mojibake·흑화면 ([PuppetModel.swift](Sources/WapleCore/PuppetModel.swift):110,162,190). `String(decoding:as: UTF8.self)` 통합으로 해소. 코퍼스 현재 0건
- **combo Picker 값-타입 불일치** → 편집기 무선택 표시 ([WallpaperProperties.swift:67](Sources/WapleCore/WallpaperProperties.swift:67) — 옵션만 `type:""` 파싱)
- **textinput 포커스 이탈 시 커밋 유실** ([PropertyEditorView.swift:102](Sources/Waple/PropertyEditorView.swift:102) — `.onSubmit`만)
- **빌보드 per-frame `makeBuffer`** ([SceneRenderer3D.swift:620](Sources/WapleRender/SceneRenderer3D.swift:620)) → 빌보드 다수 씬에서 스터터 관찰되면 `DynamicVertexBuffer`(3슬롯 링, 같은 파일에 기존 패턴) 재사용
- **FFmpeg `converted/` 캐시 무한 증가** ([FFmpegConverter.swift](Sources/WapleRender/FFmpegConverter.swift)) → 디스크가 차면 `VideoTextureExtractor.evictOldest` 재사용
- **볼륨/배속 변경 = 렌더러 전체 재장착**(재생 리셋) ([AppDelegate.swift:196](Sources/Waple/AppDelegate.swift:196)) → mkv/webm 실사용에서 거슬리면 `queue.volume`/`defaultRate` 라이브 반영으로
- **LibraryStore.remove 부재** — 삭제 기능 추가 시 playlist/monitor orphan id 정리 동반
- 기타 low 항목은 [AUDIT.md](AUDIT.md) §1–3 참조 (inferStride 재검증, 리싱크 오인, LE 리더/cstring 중복 등)

## 제품화 — 트리거: 배포 결심

1. **`notify()` NSLog-only → NSAlert/UNUserNotification** ([AppDelegate.swift:546](Sources/Waple/AppDelegate.swift:546)) — 앱 전역 유일 피드백 경로라 이 한 함수가 UX 최대 지렛대
2. 최초 실행 온보딩 + base-assets/ffmpeg 미설정 안내 (현재 조용한 저하)
3. CI 구축 — 현재 저장소에 CI 자체가 없음. `.saver`(WapleSaverView.m) clang 컴파일 스텝 포함(현재 `swift test` 커버리지 밖)
4. LICENSE 결정 (README "미정")
5. 코드사인/공증, GUI 스모크, 워크샵 E2E
6. 접근성(그리드 타일 VoiceOver/키보드), 현지화(하드코딩 한국어 40+) — [AUDIT.md](AUDIT.md) §4–5

## 하네스 — 트리거: 게이트 오탐/소요가 거슬릴 때

- 스냅샷 드리프트 2씬(3000562427, 3448290956) 부하 내성 — 순정에서도 요동하는 크로스-프로세스 비결정, 현재는 판독 시 제외 규약
- GT 인-테스트(debug, ~35분 추정)를 release `WapleCompat --capture/--compare` 게이트(6분)로 이관하고 debug GT 슬림화 검토
- 초대형 멀티페이지 스프라이트 스트리밍(6씬 정지 폴백 해제), scriptproperties 주입(중국 2패키지), TEXS 회전 실물 검증(코퍼스 0건)
