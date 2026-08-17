import SwiftUI
import AppKit
import WapleRender

/// 설정 창 — 트레이에 흩어져 있던 설정을 grouped Form 으로 통합(SP5′).
/// 시각은 전부 시스템: grouped Form·시맨틱 컬러·SF Symbols. 치수는 Metrics.settingsSize 만.
struct SettingsView: View {
    /// 창을 어디까지 줄일 수 있는가. `Metrics` 는 Phase 0 이후 동결이라 여기 산다.
    /// 오늘은 창이 리사이즈 불가라 이 값이 드러나지 않는다 — 스타일마스크에 `.resizable` 이
    /// 붙는 날(그 코드는 AppDelegate 소유다) 바닥으로 쓰인다.
    private static let minHeight: CGFloat = 420

    @ObservedObject var vm: SettingsViewModel

    /// ## 왜 높이를 프레임에 박지 않나 — 마지막 섹션이 접혀 있었다
    ///
    /// 섹션이 6개로 늘면서 콘텐츠가 약 953pt 가 됐는데 창 안쪽은 820pt 다. 그래서 마지막
    /// `에셋·도구` 가 첫 화면에서 반쯤 잘린 채로 보인다(청사진 §9.2).
    ///
    /// **먼저 청사진의 전제 하나를 정정한다 — 그 섹션은 도달 불가가 아니었다.** 스크롤바를
    /// 항상 보이게 켜고 찍어 보면 종전 빌드에도 스크롤 트랙이 있고, 썸이 트랙의 약 86% 를
    /// 차지한다(= 820/953). grouped `Form` 이 스스로 스크롤한다는 뜻이다. 그러니 문제는
    /// "꺼낼 수 없다" 가 아니라 "창을 키워서 한눈에 볼 수 없다" 다.
    ///
    /// **그리고 창 크기는 이 뷰가 정하지 못한다.** `AppDelegate` 가 창을 만들 때
    /// `setContentSize` 로 560×820 을 못 박는다. 이상 높이를 1000 으로 바꿔 띄워 봐도
    /// 창은 그대로 560×848(=820+타이틀바) 이었다.
    ///
    /// 그렇다면 여기서 할 수 있는 일은 하나다 — **창 쪽이 고쳐질 때 뷰가 발목을 잡지 않게
    /// 하는 것.** 종전의 고정 높이가 정확히 그 발목이었다. 창에 `.resizable` 을 주고 콘텐츠
    /// 높이를 1000 으로 올려 양쪽을 비교해 봤다(임시 패치, 되돌림):
    ///
    /// - 고정 높이를 그대로 둔 뷰 → 창이 **560×848 로 되돌아간다.** 뷰의 경직된 요구가
    ///   창이 요청한 크기를 이긴다. 즉 창만 고쳐서는 아무 것도 달라지지 않는다.
    /// - 고정 높이를 걷어낸 뷰 → 창이 **560×1028** 로 열리고 6개 섹션이 전부 보인다.
    ///
    /// 그래서 높이는 최소·이상·최대로만 말한다. 이상값을 비워 두면 이번엔 반대로 콘텐츠
    /// 전체 높이가 위로 전파돼 작은 화면에서 창이 화면 밖까지 자란다 — 디스플레이 시트가
    /// 가로로 겪은 것과 같은 기전이라 이상값을 명시해 둔다.
    ///
    /// `Form` 을 `ScrollView` 로 한 겹 더 감싸는 안은 **버렸다.** 감싼 빌드와 안 감싼 빌드의
    /// 스크롤바 썸 기하가 픽셀 단위로 같았고(이미 스크롤되니 당연하다), 창이 콘텐츠보다
    /// 커졌을 때 폼 배경이 따라 늘지 않아 아래가 빈 판으로 남는 단점만 남는다.
    ///
    /// 남은 절반(스타일마스크에 `.resizable`, 그리고 못 박는 `setContentSize`)은
    /// `AppDelegate` 소유라 여기서 손대지 않는다.
    var body: some View {
        Form {
            playbackSection
            playlistSection
            videoSection
            systemSection
            desktopSyncSection
            assetsSection
        }
        .formStyle(.grouped)
        .frame(width: Metrics.settingsSize.width)
        .frame(minHeight: Self.minHeight,
               idealHeight: Metrics.settingsSize.height,
               maxHeight: .infinity)
        .onAppear { vm.refresh() }
    }

    private var playbackSection: some View {
        Section {
            Picker("화면 맞춤", selection: Binding(get: { vm.fitMode }, set: { vm.setFit($0) })) {
                ForEach(FitMode.allCases, id: \.self) { Self.fitLabel($0).tag($0) }
            }
            Picker("가려지면 일시정지",
                   selection: Binding(get: { vm.occlusionRaw }, set: { vm.setOcclusion($0) })) {
                ForEach(SettingsPresentation.occlusionOptions, id: \.raw) { Text($0.label).tag($0.raw) }
            }
            Picker("프레임 상한", selection: Binding(get: { vm.maxFPS }, set: { vm.setMaxFPS($0) })) {
                ForEach(SceneFPSCap.allCases, id: \.self) { Self.fpsLabel($0).tag($0) }
            }
        } header: {
            Text("배경 재생")
        } footer: {
            Text("프레임 상한은 장면(씬) 배경에만 적용됩니다 — 동영상·웹 배경은 자체 페이싱을 씁니다.")
                .font(Typography.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 열거형 표시 라벨
    //
    // `FitMode.label` / `SceneFPSCap.label` 은 `String` 을 돌려주므로 `Text($0.label)` 이
    // 비현지화 오버로드로 해석된다 — 영어 시스템에서도 한국어로 남고, 그 리터럴은 스캔
    // 패턴에도 안 걸린다(청사진 §5.0·§5.3). 정석은 열거형 쪽을 `NSLocalizedString` 으로
    // 감싸는 것이지만 그 둘은 `WapleRender` 에 있고, 커버리지 오라클의 스캔 루트는
    // `Sources/Waple` 하나다. 거기서 감싸면 키가 스캔되지 않아 번역을 넣는 순간
    // `testNoOrphanTranslations` 가 고아로 신고한다 — 런타임을 고치면서 오라클을 깨는 셈이다.
    // 그래서 표시 라벨만 이 화면이 `Text` 리터럴로 들고, 열거형은 저장 값의 출처로 남긴다.
    //
    // 같은 병이 `SettingsPresentation`(가려지면 일시정지·화면보호기·ffmpeg 상태)에도 있지만
    // 그 파일(`AppLogic.swift`)은 Phase 2 동안 동결이라 손대지 않는다.

    private static func fitLabel(_ mode: FitMode) -> Text {
        switch mode {
        case .fit: return Text("맞춤 (전체 표시)")
        case .fill: return Text("채움 (꽉 채움)")
        case .stretch: return Text("늘이기")
        }
    }

    private static func fpsLabel(_ cap: SceneFPSCap) -> Text {
        switch cap {
        case .fps30: return Text("30 fps (절전)")
        case .fps60: return Text("60 fps (부드러움)")
        }
    }

    private var playlistSection: some View {
        Section {
            Toggle("자동 전환",
                   isOn: Binding(get: { vm.playlistEnabled }, set: { vm.setPlaylistEnabled($0) }))
            // F490: NowPlayingBar 팝오버(Stepper 1...240)와 같은 저장소를 쓰는데 Picker 가
            // [5,15,30,60]만 제공해 그 외 값이면 선택 표시가 비어 보였다 — Stepper 로 정합.
            Stepper(String(format: NSLocalizedString("전환 간격: %lld분", comment: "설정 전환 간격"), vm.playlistInterval),
                    value: Binding(get: { vm.playlistInterval }, set: { vm.setPlaylistInterval($0) }),
                    in: 1...240)
            .font(Typography.metricBody)   // 자리수가 바뀌어도 라벨 폭이 튀지 않게
            .disabled(!vm.playlistEnabled)
            Toggle("셔플(무작위 순서)",
                   isOn: Binding(get: { vm.playlistShuffle }, set: { vm.setPlaylistShuffle($0) }))
        } header: {
            Text("재생목록")
        } footer: {
            Text("항목 추가는 라이브러리 타일 우클릭 → 재생목록.")
                .font(Typography.caption).foregroundStyle(.secondary)
        }
    }

    /// w5d-settings-ia: 음량/배속 조절은 재생 컨텍스트를 이미 아는 하단 Now Playing 바(스피커
    /// 아이콘)로 이관됐다 — 여기는 그 위치를 알려주는 안내로 축소(전역 설정 창에 묻혀 미디어
    /// 플레이어 기대를 배신하던 문제 해소).
    private var videoSection: some View {
        Section {
            Label("동영상이 적용 중일 때 메인 창 하단의 스피커 아이콘에서 조절합니다.", systemImage: "speaker.wave.2")
                .font(Typography.caption).foregroundStyle(.secondary)
        } header: {
            Text("동영상")
        }
    }

    private var systemSection: some View {
        Section {
            Toggle("로그인 시 시작",
                   isOn: Binding(get: { vm.loginEnabled }, set: { vm.setLogin($0) }))
            LabeledContent("화면보호기") {
                HStack(spacing: Space.controlGap) {
                    Text(saver.label).foregroundStyle(.secondary)
                    // 삼항으로 String 을 고르면 두 리터럴 다 스캔에 안 걸린다(§5.3) — Text 를 고른다.
                    Button { vm.toggleSaver() } label: {
                        vm.saverSelected ? Text("끄기") : Text("켜기")
                    }
                    .disabled(!saver.canToggle)
                }
            }
            if let message = vm.statusMessage {
                // 이 문자열은 **생산 지점(SettingsViewModel)에서 이미 현지화됐다** — Text(String)
                // 오버로드는 번역하지 않으므로 여기서 감싸 봐야 늦다(청사진 §5.0 의 권장 (a)).
                Text(message).font(Typography.caption).foregroundStyle(ColorRole.destructive)
            }
        } header: {
            Text("시스템 연동")
        }
    }

    /// 정적 배경 동기화(자동·지속)와 정지 배경 설정(수동·1회)을 동작 중심 라벨로 묶은 하위 섹션
    /// (w5d-settings-ia) — 거의 동일한 명칭의 두 기능이 "시스템 연동"에 나란히 있어 자동 vs 수동
    /// 차이와 "둘 다 실제 바탕화면을 덮어쓴다"는 관계가 전달되지 않던 문제.
    private var desktopSyncSection: some View {
        Section {
            Toggle("배경을 바탕화면에도 자동 반영",
                   isOn: Binding(get: { vm.stillSync }, set: { vm.setStillSync($0) }))
                .help("적용 성공 시 정지 이미지를 실제 바탕화면에도 반영합니다. 끄면 원본을 복원합니다.")
            Button("지금 바탕화면으로 한 번 굽기") { vm.makeStillNow() }
                .help("현재 배경에서 정지 이미지를 만들어 모든 화면의 바탕화면으로 지정합니다(1회) — 위 자동 반영과 무관하게 즉시 동작합니다.")
        } header: {
            Text("바탕화면 반영")
        } footer: {
            Text("위는 배경이 바뀔 때마다 자동으로, 아래는 지금 한 번만 실제 macOS 바탕화면에 반영합니다.")
                .font(Typography.caption).foregroundStyle(.secondary)
        }
    }

    private var assetsSection: some View {
        Section {
            LabeledContent("기본 에셋 폴더") {
                HStack(spacing: Space.controlGap) {
                    // 경로는 런타임 데이터라 번역 대상이 아니다. 미지정 폴백 문구는
                    // SettingsViewModel 이 NSLocalizedString 으로 만들어 넘긴다.
                    Text(vm.baseAssetsPath)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("변경…") { vm.chooseBaseAssets() }
                }
            }
            LabeledContent("ffmpeg") {
                Text(vm.ffmpegStatus)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        } header: {
            Text("에셋·도구")
        } footer: {
            Text("일부 씬은 Wallpaper Engine 공유 에셋(assets) 폴더의 텍스처를 참조합니다.")
                .font(Typography.caption).foregroundStyle(.secondary)
        }
    }

    private var saver: (label: String, canToggle: Bool) {
        SettingsPresentation.saverStatus(bundled: vm.saverBundled, selected: vm.saverSelected)
    }
}
