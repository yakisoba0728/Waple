import SwiftUI
import AppKit
import WapleRender

/// 설정 창 — 트레이에 흩어져 있던 설정을 grouped Form 으로 통합(SP5′).
/// 시각은 전부 시스템: grouped Form·시맨틱 컬러·SF Symbols. 치수는 Metrics.settingsSize 만.
struct SettingsView: View {
    @ObservedObject var vm: SettingsViewModel

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
        .frame(width: Metrics.settingsSize.width, height: Metrics.settingsSize.height)
        .onAppear { vm.refresh() }
    }

    private var playbackSection: some View {
        Section {
            Picker("화면 맞춤", selection: Binding(get: { vm.fitMode }, set: { vm.setFit($0) })) {
                ForEach(FitMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("가려지면 일시정지",
                   selection: Binding(get: { vm.occlusionRaw }, set: { vm.setOcclusion($0) })) {
                ForEach(SettingsPresentation.occlusionOptions, id: \.raw) { Text($0.label).tag($0.raw) }
            }
            Picker("프레임 상한", selection: Binding(get: { vm.maxFPS }, set: { vm.setMaxFPS($0) })) {
                ForEach(SceneFPSCap.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        } header: {
            Text("배경 재생")
        } footer: {
            Text("프레임 상한은 장면(씬) 배경에만 적용됩니다 — 동영상·웹 배경은 자체 페이싱을 씁니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var playlistSection: some View {
        Section {
            Toggle("자동 전환",
                   isOn: Binding(get: { vm.playlistEnabled }, set: { vm.setPlaylistEnabled($0) }))
            Picker("전환 간격",
                   selection: Binding(get: { vm.playlistInterval }, set: { vm.setPlaylistInterval($0) })) {
                ForEach(SettingsPresentation.playlistIntervalMinutes, id: \.self) { Text("\($0)분").tag($0) }
            }
            .disabled(!vm.playlistEnabled)
            Toggle("셔플(무작위 순서)",
                   isOn: Binding(get: { vm.playlistShuffle }, set: { vm.setPlaylistShuffle($0) }))
        } header: {
            Text("재생목록")
        } footer: {
            Text("항목 추가는 라이브러리 타일 우클릭 → 재생목록.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var videoSection: some View {
        Section {
            Picker("음량", selection: Binding(get: { vm.videoVolume ?? 0 }, set: { vm.setVolume($0) })) {
                ForEach(SettingsPresentation.volumeSteps, id: \.value) { Text($0.label).tag($0.value) }
            }
            .disabled(vm.videoVolume == nil)
            Picker("배속", selection: Binding(get: { vm.videoRate ?? 1 }, set: { vm.setRate($0) })) {
                ForEach(SettingsPresentation.rateSteps, id: \.value) { Text($0.label).tag($0.value) }
            }
            .disabled(vm.videoRate == nil)
        } header: {
            Text("동영상")
        } footer: {
            Text(vm.videoVolume == nil
                 ? "동영상 배경이 적용 중일 때 조절할 수 있습니다."
                 : "변경 시 재생이 처음부터 다시 시작됩니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var systemSection: some View {
        Section {
            Toggle("로그인 시 시작",
                   isOn: Binding(get: { vm.loginEnabled }, set: { vm.setLogin($0) }))
            LabeledContent("화면보호기") {
                HStack(spacing: Metrics.gap) {
                    Text(saver.label).foregroundStyle(.secondary)
                    Button(vm.saverSelected ? "끄기" : "켜기") { vm.toggleSaver() }
                        .disabled(!saver.canToggle)
                }
            }
            if let message = vm.statusMessage {
                Text(message).font(.caption).foregroundStyle(.red)
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
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var assetsSection: some View {
        Section {
            LabeledContent("기본 에셋 폴더") {
                HStack(spacing: Metrics.gap) {
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
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var saver: (label: String, canToggle: Bool) {
        SettingsPresentation.saverStatus(bundled: vm.saverBundled, selected: vm.saverSelected)
    }
}
