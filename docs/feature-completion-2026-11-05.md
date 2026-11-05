# 현재 Waple 미완성 기능 완성 원장 — 2026-11-05

기준: `d9917e50ae49fb93b787a4a762812b7dffbc9c9a`. 사용자가 확인한 범위는 **현재 Waple의 미완성 기능 완성**이다. Windows 실행형 배경 호환, 씬 제작 편집기, Steam 게시·업로드 등 새 제품 기능은 포함하지 않는다.

이 표는 **224개 검토 항목**이다. 실제 구현 공백 외에 계약 재측정, 실기 수락, 의도적인 제품·플랫폼 경계도 포함한다. 따라서 이 숫자를 미구현 버그 수나 완료 수로 인용하지 않는다. 오래된 문서의 이미 해결된 주장과 WE 자체의 no-op은 별도로 걸러냈다.

기준선은 로컬 Xcode 27.2/Swift 6.4.2의 실제 XCTest 4,127개 실행·63개 스킵·실패 0이다. 현재 실행 하한과 그린 CI 실측 근거의 정본은 [ci.yml](../.github/workflows/ci.yml)의 census다.

**진행 규칙:** P1 실행 경로와 선행 ABI를 먼저 연결하고 독립 항목을 병렬로 진행한다. 기존 공개 파서·런타임·렌더러·스토어·CLI의 관찰 가능한 동작에 회귀 검사를 건다. 아래 ‘시작 판정’은 착수 시점 사실이다. 수정 완료는 실제 소비 경로와 실행 근거가 함께 있을 때 기록한다. 외부 계정·권한·실물 자산·하드웨어가 필요한 수락은 구현 완료와 구분한다.


> **사용량 제한에 따른 범위 변경:** 사용자는 이후 “현재 작성분 검증·커밋·CI만 마무리”를 선택했다. 추가 기능 구현·조사는 중단했다. 이 원장의 모든 항목을 완료했다고 주장하지 않으며, 미완료 항목과 외부 검증 조건은 그대로 보존한다.

## 검증 상태

사용량 제한으로 추가 구현을 중단하고 현재 작성분의 커밋·푸시·CI만 마무리하는 범위로 축소했다. 이후 사용자 지시에 따라 로컬 회귀 실행도 중단했으며, 남은 실패는 CI 결과로 수정했다.

`be5f1730`의 [macOS debug CI](https://github.com/yakisoba0728/Waple/actions/runs/42082324736/job/127439044334)는 **4,288개 실행·63개 스킵·실패 0**이며 병렬 격리와 스크린세이버 검사도 통과했다. 누락된 파티클 용량, MDLA 픽스처, 텍스트 padding·outline, CPU 스키닝 선택과 행렬 초기화 검증을 정정했다. 동시성 경고 상한은 실측에 따라 25→24로 낮췄다.

실행 하한은 이 성공 실측으로 4,127→4,288로 갱신한다. 최종 debug·release 결과는 [현재 브랜치 CI](https://github.com/yakisoba0728/Waple/actions?query=branch%3Acodex%2Fcomplete-feature-gaps-20261105), 현재 하한과 증분 근거는 [ci.yml](../.github/workflows/ci.yml)의 census가 정본이다. release는 잡의 성공 표시 대신 실제 Test 결과를 확인한다. CI에는 실물 코퍼스가 없으므로 실물 자산·외부 권한·다중 화면 수동 수락을 완료했다고 주장하지 않는다.

## 이번 마감에 포함되는 작성분

- 앱: 재생정책 stop의 자원 해제·복원, macOS 메모리 압력 대응, 화면별·이름 있는 재생목록 및 전환 설정, 사용자 선택 단축키, Workshop 취소·재시도, 시스템 알림과 접근성 변경 관측.
- 렌더·스크립트: 전환 오버레이, 이미지 레이어 합성 타깃, 볼륨·페이지 텍스처, 텍스트 스타일·분할·HDR 색상, 셰이더 배열·행렬·조명 ABI, 3D 텍스트·애니메이션·환경 값 소비, JS 런타임 명령 및 Web Audio 음소거.
- 포맷·미디어·검증: MDLA 직렬화 프레이밍, 모델 포즈·파티클 계약, Vorbis floor0, 오디오 캡처 복구·미디어 상태, 비디오 음량 램프, 스냅샷 프로세스 격리와 스크린세이버 생명주기·현지화.

이 목록은 코드 변경 영역이며 각 영역의 전체 호환성을 보증하는 완료 목록이 아니다. MSDF 생성·샘플링, procedural geometry의 네이티브 실행부, 공간 오디오, 정확한 clone 재생 위상·span 자르기, 생산자 기준 텍스트 anchor 및 일부 포맷·렌더 경로 등은 미완료 또는 추가 수락이 필요하다. 실제 Steam·권한·다중 화면·실물 코퍼스 수락은 자동 합성 테스트와 구분한다. 아래 표의 시작 판정을 현재 완료 상태로 읽지 않는다.

## 앱·정책·재생목록

| ID | 우선순위 | 항목 | 시작 판정 | 코드·계약 근거 |
| --- | --- | --- | --- | --- |
| APPG-01 | P1 | Policy stop does not release renderer resources or restore them after the stop clears | partial | [RenderPauseComposition.stopIsReducedToPause](../Sources/Waple/PlaybackPolicyComposition.swift) · [AppDelegate.applyPlaybackPolicy](../Sources/Waple/AppDelegate.swift) |
| APPG-02 | P1 | VRAM pressure setting and hysteresis have no native sampler, runtime latch or user control | model_only | [PlaybackConditionsBuilder.make](../Sources/Waple/PlaybackObservers.swift) · [GlobalPlaybackSettings.setPauseVRAM](../Sources/Waple/PlaybackPolicyRuntime.swift) |
| APPG-03 | P2 | External stop/pause/mute requests and force/unpause flags never enter app policy conditions | model_only | [PlaybackConditionsBuilder.make](../Sources/Waple/PlaybackObservers.swift) · [PlaybackConditions](../Sources/WaplePolicy/PlaybackPolicy.swift) |
| APPG-04 | P2 | Daytime and weekday playlists exist only in the pure scheduler | model_only | [PlaylistSettingsBridge.settings](../Sources/Waple/PlaylistDriver.swift) · [PlaylistStore.Model](../Sources/WapleLibrary/PlaylistStore.swift) |
| APPG-05 | P2 | Logon playlist mode has no storage, UI or proven login-trigger mapping | externally_gated | [PlaylistSettingsBridge.settings](../Sources/Waple/PlaylistDriver.swift) · [PlaylistScreenScheduler.nextCandidate](../Sources/WapleCore/PlaylistRuntime.swift) |
| APPG-06 | P2 | Video end cannot advance a wallpaper playlist | missing | [PlaylistSettingsBridge.settings](../Sources/Waple/PlaylistDriver.swift) · [PlaylistRuntime.shouldAdvanceOnVideoEnd](../Sources/WapleCore/PlaylistRuntime.swift) |
| APPG-07 | P2 | Begin-first and play-intro flags never become active | model_only | [PlaylistSettingsBridge.settings](../Sources/Waple/PlaylistDriver.swift) · [PlaylistSettingsBridge.settings](../Sources/Waple/PlaylistDriver.swift) |
| APPG-08 | P2 | Update-on-pause option is fixed off even though scheduling supports it | model_only | [PlaylistSettingsBridge.settings](../Sources/Waple/PlaylistDriver.swift) · [PlaylistSettings.accumulatesElapsed](../Sources/WapleCore/PlaylistTransition.swift) |
| APPG-09 | P2 | Wallpaper changes have no visual transition renderer or outgoing-frame overlay | model_only | [PlaylistSettingsBridge.settings](../Sources/Waple/PlaylistDriver.swift) · [RendererSwap.apply](../Sources/Waple/AppLogic.swift) |
| APPG-10 | P2 | Transition selection, duration, pool and manual browse-transition settings are absent | missing | [PlaylistStore.Model](../Sources/WapleLibrary/PlaylistStore.swift) · [PlaylistSettingsBridge.settings](../Sources/Waple/PlaylistDriver.swift) |
| APPG-11 | P2 | Monitor-specific playlist contents and secondary current selection are not persisted | partial | [PlaylistDriver.sync](../Sources/Waple/PlaylistDriver.swift) · [AppDelegate.finishStagedPlaylistOverride](../Sources/Waple/AppDelegate.swift) |
| APPG-12 | P2 | Users cannot create, name, switch or manage multiple saved playlists | missing | [PlaylistStore.Model](../Sources/WapleLibrary/PlaylistStore.swift) · [§3.3](../docs/re/playlist-transition.md) |
| APPG-14 | P2 | Wallpaper-specific policy overrides are read from authored projects but cannot be edited by users | partial | [PlaybackPolicyResolver.effective](../Sources/Waple/PlaybackPolicyRuntime.swift) · [SettingsViewModel.setPlaybackAction](../Sources/Waple/Surfaces/Settings/SettingsViewModel.swift) |
| APPG-15 | P2 | Session lock/unlock is not an independent pause reason | missing | [AppDelegate.applicationDidFinishLaunching](../Sources/Waple/AppDelegate.swift) · [PauseGate.Reason](../Sources/Waple/AppLogic.swift) |
| APPG-16 | P2 | Modern macOS lock-screen still synchronization has only a legacy best-effort file path | externally_gated | [AppDelegate.writeLockscreenStill](../Sources/Waple/AppDelegate.swift) · [AppDelegate.writeLockscreenStill](../Sources/Waple/AppDelegate.swift) |
| APPG-17 | P2 | Closed-window notices lack system notification delivery | partial | [AppDelegate.notify](../Sources/Waple/AppDelegate.swift) · [Productization](../BACKLOG.md) |
| APPG-18 | P2 | Other-app audio detection stops working while any wallpaper is producing audio | partial | [SystemAudioObserver.isOtherAppPlaying](../Sources/Waple/PlaybackObservers.swift) · [AppDelegate.playbackDecisions](../Sources/Waple/AppDelegate.swift) |
| APPG-20 | P2 | Per-playlist-item preset references are modelled but not stored or applied | externally_gated | [PlaylistItem](../Sources/WapleCore/PlaylistTransition.swift) · [PlaylistDriver.sync](../Sources/Waple/PlaylistDriver.swift) |
| APPG-13 | P3 | Playlist intervals are limited to whole minutes instead of supported fractional delays | partial | [PlaylistStore.intervalMinutes](../Sources/WapleLibrary/PlaylistStore.swift) · [PlaylistSettingsBridge.settings](../Sources/Waple/PlaylistDriver.swift) |
| APPG-19 | P3 | Stretch/clone monitor layouts exist in policy model but not desktop rendering or settings | model_only | [PlaybackConditionsBuilder.make](../Sources/Waple/PlaybackObservers.swift) · [DesktopWindowController.rebuild](../Sources/WapleRender/DesktopWindowController.swift) |
| APPG-21 | P3 | Web wallpaper still fallback uses preview metadata rather than a rendered page capture | partial | [StillWallpaper.source](../Sources/Waple/StillWallpaper.swift) · [AppDelegate.stillImage](../Sources/Waple/AppDelegate.swift) |

## 오디오·미디어

| ID | 우선순위 | 항목 | 시작 판정 | 코드·계약 근거 |
| --- | --- | --- | --- | --- |
| AUDG-01 | P2 | Spatial sound fields are preserved but source/listener transforms and attenuation are not rendered | partial_requires_semantic_measurement | [SceneSound.spatialization/attenuation/minDistance](../Sources/WapleCore/SceneDocument.swift) · [SceneDocument.parse sound branch](../Sources/WapleCore/SceneDocument.swift) |
| AUDG-02 | P2 | Capture starvation never resets the last spectrum to silence | missing_ready | [SystemAudioSpectrumProvider.analyzeWindow](../Sources/WapleRender/SystemAudioSpectrumProvider.swift) · [audioProvider.onFrame](../Sources/WapleRender/SceneRenderer.swift) |
| AUDG-03 | P2 | Shared capture has no asynchronous failure recovery or output-session restart path | missing_ready_for_failure_recovery_device_switch_needs_runtime_check | [SharedAudioCaptureCore.startCapture](../Sources/WapleRender/SystemAudioSpectrumProvider.swift) · [SharedAudioCaptureCore.add](../Sources/WapleRender/SystemAudioSpectrumProvider.swift) |
| AUDG-04 | P2 | Audio input gain and silence-threshold settings have no user controls | missing_ready | [AudioInputSettings](../Sources/WapleRender/SystemAudioSpectrumProvider.swift) · [AudioInputSettings.volumeSetting/thresholdSetting](../Sources/WapleRender/SystemAudioSpectrumProvider.swift) |
| AUDG-05 | P2 | Media enabled/status is conflated with playback and web receives the wrong status payload | partial_ready | [startMediaPollingIfNeeded onPlayback](../Sources/WapleRender/SceneRenderer.swift) · [startMediaPolling onPlayback](../Sources/WapleRender/WebRenderer.swift) |
| AUDG-06 | P2 | NowPlaying metadata loses defined properties before scene/web delivery | partial_ready_with_provider_capabilities | [NowPlayingInfo](../Sources/WapleRender/NowPlayingProvider.swift) · [onProperties](../Sources/WapleRender/SceneRenderer.swift) |
| AUDG-07 | P2 | Paused timeline changes are discarded | partial_ready | [MediaPoller.deliver](../Sources/WapleRender/MediaPoller.swift) · [timeline paused expectation](../Tests/WapleRenderTests/MediaPollerTests.swift) |
| AUDG-08 | P2 | Provider arbitrates by app existence rather than active playback | partial_ready | [runningPlayer](../Sources/WapleRender/NowPlayingProvider.swift) · [fetchArtwork](../Sources/WapleRender/NowPlayingProvider.swift) |
| AUDG-14 | P2 | Video pause/mute lacks the confirmed asymmetric volume ramp | missing_ready | [attachPlayer](../Sources/WapleRender/VideoRenderer.swift) · [pause](../Sources/WapleRender/VideoRenderer.swift) |
| AUDG-09 | P3 | Artwork updates are keyed only by display strings | partial_ready | [poll track key/artwork fetch](../Sources/WapleRender/MediaPoller.swift) · [lastTrackKey assignment](../Sources/WapleRender/MediaPoller.swift) |
| AUDG-10 | P3 | Vorbis floor0 remains unsupported | explicit_format_limit_requires_fixture | [VorbisStream.parseSetup floors](../Sources/WapleRender/OggVorbis/VorbisDecoder.swift) |
| AUDG-11 | P3 | FFT length and consumer timing intentionally approximate WE | deliberate_approximation_not_immediate_bug | [fftSize](../Sources/WapleRender/SystemAudioSpectrumProvider.swift) · [audioProvider.onFrame timing](../Sources/WapleRender/SceneRenderer.swift) |
| AUDG-12 | P3 | WE audio-processing user toggle and declaration conjunction are deliberately deferred | deliberate_deferral_blocked_by_recorded_prerequisites | [parseSupportsAudioProcessing disposition](../Sources/WapleCore/ProjectJSONParser.swift) |
| AUDG-13 | P3 | Audio capture source selection is limited to system output | explicit_platform_scope_limit | [SharedAudioCaptureCore.startCapture configuration](../Sources/WapleRender/SystemAudioSpectrumProvider.swift) |

## 호환성 도구·화면보호기·검증

| ID | 우선순위 | 항목 | 시작 판정 | 코드·계약 근거 |
| --- | --- | --- | --- | --- |
| VALG-09 | P1 | 동봉 WEAssets 공개 재배포 승인 | external_gated_release_policy | [Require distribution approval](../.github/workflows/release.yml) · [distribution approval](../docs/RELEASING.md) |
| VALG-01 | P2 | WapleSaver 안내문 영어 현지화와 saver 번들 리소스 연결 | implementation_gap | [loadContentForPath:](../Sources/WapleSaver/WapleSaverView.m) · [saver bundle assembly](../scripts/package-app.sh) |
| VALG-02 | P2 | 혼합 packed/unpacked 코퍼스에서 capture 대상 누락 | implementation_gap_with_baseline_validation | [sceneFolders(root:)](../Sources/WapleCompatCore/SnapshotPipeline.swift) · [sceneFolders(root:)](../Sources/WapleCompatCore/SnapshotPipeline.swift) |
| VALG-03 | P2 | GT와 스냅샷 캡처 조건 차이로 중간 규모 시각 회귀 판별 공백 | validation_gap | [testMountAndCaptureAllRealScenes](../Tests/WapleRenderTests/RealPackagesGroundTruthTests.swift) · [captureFrame(project:into:)](../Sources/WapleCompatCore/SnapshotPipeline.swift) |
| VALG-05 | P2 | 실물 비디오-백드 캡처 테스트의 결정성 단언 플레이크 | needs_runtime_validation | [testVideoBackedScenesCaptureContent](../Tests/WapleRenderTests/VideoBackedSceneCaptureTests.swift) · [testVideoBackedScenesCaptureContent](../Tests/WapleRenderTests/VideoBackedSceneCaptureTests.swift) |
| VALG-06 | P2 | 실물 코퍼스 GT는 합성 CI 성공만으로 검증되지 않음 | external_gated_validation | [testMountAndCaptureAllRealScenes](../Tests/WapleRenderTests/RealPackagesGroundTruthTests.swift) · [Skip / execution census](../.github/workflows/ci.yml) |
| VALG-08 | P2 | Developer ID 서명·공증은 배선 완료, 실제 자격과 성공 산출물 확인 필요 | external_gated_release | [Detect signing configuration](../.github/workflows/release.yml) · [Notarize DMG](../.github/workflows/release.yml) |
| VALG-04 | P3 | compare 시 현재 빌드의 결정성 재측정 부재(F144) | deferred_triggered_validation_gap | [runCompare](../Sources/WapleCompatCore/SnapshotCompare.swift) · [goldenVerdict call](../Sources/WapleCompatCore/SnapshotCompare.swift) |
| VALG-07 | P3 | Waple↔WE 원본 화면 파리티는 제한된 외부 실측 범위 | external_gated_measurement_boundary | [module contract](../scripts/we-parity/compare_we_reference.py) · [module contract](../scripts/we-parity/compare_we_reference.py) |
| VALG-10 | P3 | WapleSaver 실제 macOS host 재생 검증 범위 | external_gated_validation | [Compile screensaver bundle](../.github/workflows/ci.yml) · [module contract](../scripts/dev/tests/test_waple_saver_lifecycle.py) |
| VALG-11 | P3 | Intel macOS 실행 지원은 검증되지 않은 경계 | external_gated_platform_validation | [requirements table](../README.md) |
| VALG-12 | P3 | Saver는 scene/web가 아닌 native video 전용 | documented_product_boundary | [isPlayableVideoPath:](../Sources/WapleSaver/WapleSaverView.m) · [updateVideoPath](../Sources/Waple/ScreenSaverController.swift) |
| VALG-13 | P3 | application과 top-level image 재생은 현재 지원 범위 밖 | documented_unsupported_scope | [WallpaperType](../Sources/WapleCore/WallpaperType.swift) · [checkProjectType](../Sources/WapleCore/WallpaperCompatibilityAnalyzer.swift) |
| VALG-14 | P3 | 자동 업데이트 체커는 명시적으로 연기된 별도 제품 범위 | deliberately_deferred_scope | [future items](../docs/RELEASING.md) |

## 파티클·모델·포맷

| ID | 우선순위 | 항목 | 시작 판정 | 코드·계약 근거 |
| --- | --- | --- | --- | --- |
| COREG-01 | P2 | Propagate scene projection into all conditional particle defaults | ready_for_implementation | [ParticleSystemDef.parse/parseInitializers/parseOperators](../Sources/WapleCore/ParticleSystem.swift) · [SceneDocument.parseParticleDef](../Sources/WapleCore/SceneDocument.swift) |
| COREG-02 | P2 | Resolve and wire scene wind/gravity external-force controls | research_required | [SceneDocument.windEnabled/windStrength/windDirection/gravityStrength/gravityDirection](../Sources/WapleCore/SceneDocument.swift) |
| COREG-03 | P2 | Connect pointer-driven control points to production simulation | ready_with_render_binding | [ParticleControlPointMath.pointerControlPointTranslation](../Sources/WapleCore/ParticleControlPointFrame.swift) · [ParticleSystemDef.controlPointFlags](../Sources/WapleCore/ParticleSystem.swift) |
| COREG-04 | P2 | Apply CP world-authored/system-space conversion with full object matrices | ready_with_render_binding | [ParticleControlPointMath.frameUpdate](../Sources/WapleCore/ParticleControlPointFrame.swift) · [ParticleSimulator.runtimeControlPoints](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-05 | P2 | Complete mixed-space child CP attachment and wholesale-copy bit | ready_with_render_binding | [ParticleSimulator.applyAttachedParentControlPoints](../Sources/WapleCore/ParticleSimulator.swift) · [ParticleControlPointMath.FrameUpdate](../Sources/WapleCore/ParticleControlPointFrame.swift) |
| COREG-06 | P2 | Mark remap-output CPs before instance overrides and block normal CP updates | ready_for_implementation | [ParticleSystemDef.parse controlPointFlags](../Sources/WapleCore/ParticleSystem.swift) · [ParticleControlPointMath.remapOutputMarkedSlot](../Sources/WapleCore/ParticleControlPointFrame.swift) |
| COREG-07 | P2 | Implement inheritcontrolpointvelocity initializer | ready_for_implementation | [Initializer.inheritControlPointVelocity](../Sources/WapleCore/ParticleSystem.swift) · [ParticleSimulator.apply](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-08 | P2 | Carry parent event values and execute both event inheritance elements | research_required | [Initializer.inheritInitialValueFromEvent](../Sources/WapleCore/ParticleSystem.swift) · [ParticleSimulator.init operator cache](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-09 | P2 | Parse and execute complete remapinitialvalue pipeline at spawn | research_required | [Initializer.remapInitialValue](../Sources/WapleCore/ParticleSystem.swift) · [ParticleSimulator.apply](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-10 | P2 | Implement plane, sphere and quad collision shapes and responses | research_required | [CollisionOperator](../Sources/WapleCore/ParticleSystem.swift) · [ParticleSystemDef.parseOperators](../Sources/WapleCore/ParticleSystem.swift) |
| COREG-13 | P2 | Consume sphere emitter cone in direction sampling | research_required | [ParticleSystemDef.emitterCone](../Sources/WapleCore/ParticleSystem.swift) · [ParticleSimulator.spawn sphere](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-14 | P2 | Honor emitter flags and recover periodic gating/state semantics | research_required | [ParticleSystemDef.parse.parsePeriodic](../Sources/WapleCore/ParticleSystem.swift) · [ParticleSimulator.PeriodicState](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-15 | P2 | Match emitter burst lifetime and duration-zero retirement | research_required | [ParticleSimulator._step](../Sources/WapleCore/ParticleSimulator.swift) · [ParticleSimulator.stepEmitterWindows](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-16 | P2 | Implement layerimage alpha-weighted emission instead of box fallback | research_required | [ParticleSystemDef.parse emitter](../Sources/WapleCore/ParticleSystem.swift) |
| COREG-18 | P2 | Consume all remaining supported operator blend windows | ready_for_implementation | [ParticleSimulator.init operator cache](../Sources/WapleCore/ParticleSimulator.swift) · [ParticleSystemDef.parseOperators](../Sources/WapleCore/ParticleSystem.swift) |
| COREG-19 | P2 | Execute particle operators in authored stream order | ready_for_implementation | [ParticleSimulator.init](../Sources/WapleCore/ParticleSimulator.swift) · [ParticleSimulator._integrateParticle](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-20 | P2 | Keep repeated fade and oscillation operator declarations | ready_for_implementation | [ParticleSimulator.init alphaFade](../Sources/WapleCore/ParticleSimulator.swift) · [ParticleSimulator.init oscillatePosition](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-21 | P2 | Implement numeric swept-distance attract deletion and original timing | ready_for_implementation | [ParticleOperator.controlPointAttract](../Sources/WapleCore/ParticleSystem.swift) · [ParticleSimulator.applyAttract](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-22 | P2 | Apply oscillateposition Y-only shared-random phase | ready_for_implementation | [ParticleSimulator.oscPositionOffset](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-24 | P2 | Apply turbulentvelocityrandom scale/offset and original distribution | research_required | [ParticleSimulator.apply turbulentVelocityRandom](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-25 | P2 | Support all real remap input channels | research_required | [RemapInput](../Sources/WapleCore/ParticleSystem.swift) · [ParticleSimulator.remapEval](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-26 | P2 | Preserve three-lane remap input and per-axis normalization | ready_for_implementation | [ParticleSimulator.remapReduce](../Sources/WapleCore/ParticleSimulator.swift) · [ParticleSimulator.remapNormalizeInput](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-27 | P2 | Implement five control-point remap output channels | research_required | [ParticleSimulator.remapChannelIsApplied](../Sources/WapleCore/ParticleSimulator.swift) · [RemapSpec.outputCP0/outputCP1](../Sources/WapleCore/ParticleSystem.swift) |
| COREG-28 | P2 | Use original missing-input remap default and clamp semantics | ready_for_implementation | [RemapSpec.input](../Sources/WapleCore/ParticleSystem.swift) · [ParticleSimulator.remapEval input](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-30 | P2 | Persist remap velocity arithmetic and speed scaling in actual velocity state | ready_for_implementation | [ParticleSimulator._integrateParticle](../Sources/WapleCore/ParticleSimulator.swift) · [ParticleSimulator._integrateParticle speed](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-31 | P2 | Bind distinct remap runtime/layer/system/time-of-day and layer-origin sources | research_required | [ParticleSimulator.remapEval](../Sources/WapleCore/ParticleSimulator.swift) · [ParticleSimulator.remapEval](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-32 | P2 | Recover remap waveform phase and noise input coordinates | research_required | [RemapTransform](../Sources/WapleCore/ParticleSystem.swift) · [ParticleSimulator.remapEval transform](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-33 | P2 | Resolve remaining system flags including perspective projection | research_required | [ParticleSystemDef.flags](../Sources/WapleCore/ParticleSystem.swift) · [ParticleSimulator.simulatesInWorldSpace](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-35 | P2 | Retain and bind remaining valid MDL vertex attributes | ready_with_render_binding | [Model3D.vertexLayoutTable](../Sources/WapleCore/Model3D.swift) · [Model3DPose.cpuSkinnedPacked](../Sources/WapleCore/Model3DPose.swift) |
| COREG-36 | P2 | Select model material skins instead of always skin0 | research_required | [Model3D.Mesh.materials](../Sources/WapleCore/Model3D.swift) · [SceneDocument.parseModel](../Sources/WapleCore/SceneDocument.swift) |
| COREG-37 | P2 | Replace heuristic MDLA resynchronization with bounded structural clip decoding | research_required | [Model3D.parseAnimations](../Sources/WapleCore/Model3D.swift) · [Model3D.parse](../Sources/WapleCore/Model3D.swift) |
| COREG-39 | P2 | Implement confirmed skeleton constraints and spring/IK runtime | research_required | [Model3D.skeletonTail](../Sources/WapleCore/Model3D.swift) · [Model3D.Bone.properties](../Sources/WapleCore/Model3D.swift) |
| COREG-40 | P2 | Implement mesh/puppet morph targets and bone-driven morph modifiers | research_required | [Model3D.MeshTrailer.morphs](../Sources/WapleCore/Model3D.swift) · [PuppetModel.fromModel3D](../Sources/WapleCore/PuppetModel.swift) |
| COREG-43 | P2 | Retain and evaluate animation-layer blend/rate/visible keyframe values | ready_with_render_binding | [SceneDocument.parseAllAnimationLayers](../Sources/WapleCore/SceneDocument.swift) · [AnimationLayer.eventTimelines](../Sources/WapleCore/SceneDocument.swift) |
| COREG-44 | P2 | Evaluate property value animations on3D model/group transforms | ready_with_render_binding | [SceneObject3D.eventTimelines](../Sources/WapleCore/SceneDocument.swift) · [SceneDocument.parseModel](../Sources/WapleCore/SceneDocument.swift) |
| COREG-45 | P2 | Blend all3D animation layers instead of selecting a single initial winner | ready_with_render_binding | [SceneObject3D.animationLayers](../Sources/WapleCore/SceneDocument.swift) · [Model3DPose.skinMatrices](../Sources/WapleCore/Model3DPose.swift) |
| COREG-46 | P2 | Use named bone attachments for3D models and transform-only parent nodes | ready_with_render_binding | [SceneObject3D.attachment](../Sources/WapleCore/SceneDocument.swift) · [SceneLayer/SceneObject3D/SceneNode3D.attachment](../Sources/WapleCore/SceneDocument.swift) |
| COREG-49 | P2 | Apply oscillateposition weighted deltas to physical state | ready_for_implementation | [ParticleSimulator.oscPositionOffset](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-11 | P3 | Implement collisionbounds against confirmed runtime scene bounds | research_required | [ParticleSystemDef.collisionOperators](../Sources/WapleCore/ParticleSystem.swift) |
| COREG-12 | P3 | Implement collisionmodel model references and triangle/BVH collision | research_required | [ParticleSystemDef.parseOperators](../Sources/WapleCore/ParticleSystem.swift) |
| COREG-17 | P3 | Recover box emitter initial-speed direction distribution | research_required | [ParticleSimulator.spawn box](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-23 | P3 | Apply colorlist hue/saturation/value noise | research_required | [Initializer.colorList](../Sources/WapleCore/ParticleSystem.swift) · [ParticleSimulator.apply colorList](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-29 | P3 | Preserve invalid remap operation/component/channel sentinels | ready_for_implementation | [RemapOperation](../Sources/WapleCore/ParticleSystem.swift) · [premapcomponent](../Sources/WapleCore/ParticleSystem.swift) |
| COREG-34 | P3 | Resolve around auxiliary stream opcodes3/10 producer behavior | research_required | [MapSequenceAroundSpec](../Sources/WapleCore/ParticleSystem.swift) |
| COREG-38 | P3 | Expose and evaluate extra MDLA scalar/secondary/modifier tracks | research_required | [Model3D MDLA format contract](../Sources/WapleCore/Model3D.swift) · [Model3DPose.skinMatrices](../Sources/WapleCore/Model3DPose.swift) |
| COREG-41 | P3 | Preserve multi-mesh container puppet materials and wide indices | ready_with_render_binding | [PuppetModel.fromModel3D](../Sources/WapleCore/PuppetModel.swift) |
| COREG-42 | P3 | Remove non-original skin-weight normalization across CPU/GPU paths | ready_with_render_binding | [PuppetPose.skinnedPositions](../Sources/WapleCore/PuppetPose.swift) · [Model3DPose.cpuSkinnedPacked](../Sources/WapleCore/Model3DPose.swift) |
| COREG-47 | P3 | Match single-token vec2 parser behavior for spacing/padding | ready_for_implementation | [SceneDocument.uniformVec2](../Sources/WapleCore/SceneDocument.swift) |
| COREG-48 | P3 | Stabilize long-running simulation clock without losing short-time parity | ready_for_implementation | [ParticleSimulator.time](../Sources/WapleCore/ParticleSimulator.swift) |
| COREG-50 | P3 | Recover and honor runtime operator state-mask gates | research_required | [ParticleSimulator._integrateParticle angularSpeed remap](../Sources/WapleCore/ParticleSimulator.swift) |

## 라이브러리·속성·Workshop

| ID | 우선순위 | 항목 | 시작 판정 | 코드·계약 근거 |
| --- | --- | --- | --- | --- |
| LIBG-01 | P2 | 속성 슬라이더 step·precision·fraction 메타를 편집 위젯에 연결 | model_only | [WallpaperProperty.step](../Sources/WapleCore/WallpaperProperties.swift) · [PropertyEditorView.control(for:)](../Sources/Waple/PropertyEditorView.swift) |
| LIBG-02 | P2 | 파일 속성의 파싱된 fileType 제한을 선택 패널에 연결 | model_only | [WallpaperProperties.parse](../Sources/WapleCore/WallpaperProperties.swift) · [PropertyEditorView.chooseResource(for:directory:)](../Sources/Waple/PropertyEditorView.swift) |
| LIBG-03 | P2 | group 속성의 전체 그룹 조건 표시와 접기 동작 | partial | [PropertyDecoration group contract](../Sources/WapleCore/PropertyDecoration.swift) · [PropertyGrouping.sections(in:visible:)](../Sources/Waple/PropertyGrouping.swift) |
| LIBG-04 | P2 | WE volume 속성에 수치 편집 위젯 연결 | partial | [PropertyControl.kind(forType:)](../Sources/Waple/AppLogic.swift) · [WallpaperProperties.parseValue](../Sources/WapleCore/WallpaperProperties.swift) |
| LIBG-05 | P2 | Workshop 설치됨 매핑을 영속화하고 재실행 후 적용 표시 | missing | [UI 네이티브 재구축 잔여](../BACKLOG.md) · [LibraryEntry](../Sources/WapleLibrary/LibraryEntry.swift) |
| LIBG-06 | P2 | 진행 중 Workshop 다운로드 취소와 늦은 콜백 차단 | missing | [SteamCmdDownloader.download](../Sources/Waple/SteamCmdDownloader.swift) · [WorkshopViewModel.DownloadUIState](../Sources/Waple/Surfaces/Workshop/WorkshopViewModel.swift) |
| LIBG-07 | P2 | 기존 ffmpeg 재생 경로에 raw webm/mkv/avi 임포트 연결 | partial | [Wallpaper type support](../README.md) · [VideoImport.extensions](../Sources/Waple/VideoImport.swift) |
| LIBG-08 | P2 | 라이브러리 제거 시 해당 엔트리 script-storage 정리 | partial | [LibraryViewModel.remove](../Sources/Waple/LibraryViewModel.swift) · [SceneRenderer script initialization](../Sources/WapleRender/SceneRenderer.swift) |
| LIBG-09 | P2 | top-level 정적 이미지 타입·렌더러와 raw 이미지 임포트 | missing | [Wallpaper type support](../README.md) · [WallpaperType](../Sources/WapleCore/WallpaperType.swift) |
| LIBG-10 | P3 | usershortcut 속성의 실제 값 계약과 네이티브 편집 소비 | externally_gated | [PropertyControl.kind(forType:)](../Sources/Waple/AppLogic.swift) · [documented WE property types](../Sources/WapleCore/WallpaperProperties.swift) |
| LIBG-11 | P3 | combolutfilters 속성 선택 UI 및 실제 LUT 값 연결 | externally_gated | [PropertyControl.kind(forType:)](../Sources/Waple/AppLogic.swift) · [engine-injected wcc_v](../docs/re/property-animation.md) |
| LIBG-12 | P3 | Application 배경은 모델·지원예정 UI만 있고 실행 백엔드 없음 | externally_gated | [WallpaperType.application](../Sources/WapleCore/WallpaperType.swift) · [RendererFactory.makeRenderer](../Sources/WapleRender/RendererFactory.swift) |

## 2D·텍스처·동영상

| ID | 우선순위 | 항목 | 시작 판정 | 코드·계약 근거 |
| --- | --- | --- | --- | --- |
| R2G-01 | P1 | 2D composition child RTT and runtime _rt_imageLayerComposite sampling (triangle masks/copybackground) | confirmed_partial | [if n.hasPrefix("_rt_imageLayerComposite_")](../Sources/WapleRender/SceneRendererResources.swift) · [backdrop = snap](../Sources/WapleRender/SceneRendererFrameEncoder.swift) |
| R2G-02 | P1 | Upload and bind encoded volume textures as Metal type3D | confirmed_missing | [volume(tex.depth > 1)](../Sources/WapleRender/TexDecoder.swift) · [func makeImageTexture(](../Sources/WapleRender/SceneRendererResources.swift) |
| R2G-06 | P1 | 27 playlist transition GPU effects and frame overlay | confirmed_missing | [**전환 효과 27종 + 오버레이 파이프라인**](../docs/re/playlist-transition.md) · [public enum PlaylistTransitionKind](../Sources/WapleCore/PlaylistTransition.swift) |
| R2G-09 | P1 | Oversized multi-page spritesheets freeze on first page | confirmed_partial | [return (texture, multipage ? [] : tex.frames)](../Sources/WapleRender/SceneRendererResources.swift) · [frames.isEmpty](../Tests/WapleRenderTests/SpriteSheetLayerRenderTests.swift) |
| R2G-03 | P2 | Color grading final pass (ccsimple COL/LUT) | confirmed_missing | [### W-25](../docs/re/tonemapping.md) · [func finalizeScene(](../Sources/WapleRender/SceneRendererFinalizer.swift) |
| R2G-04 | P2 | HDR single-level fallback strength still uses authored strength × iterations | confirmed_partial | [strength: doc.bloomHDRStrength * Float(max(1, doc.bloomHDRIterations))](../Sources/WapleRender/SceneRenderer.swift) · [if sceneWantsHDRBloom, let hdrBloomPass,](../Sources/WapleRender/SceneRendererFinalizer.swift) |
| R2G-10 | P2 | Rotated and nonuniform layer sheet frames plus ribbon atlas rotation | confirmed_partial | [ponytail: 회전 미지원](../Sources/WapleRender/SceneRendererFrameEncoder.swift) · [리본은 rotationQuarters 미반영](../Sources/WapleRender/SceneRendererFrameEncoder.swift) |
| R2G-11 | P2 | orthoAuto projection is parsed but not bound to drawable dimensions | confirmed_missing | [public var orthoAuto](../Sources/WapleCore/SceneDocument.swift) · [**`nopadding`/`orthoAuto` 소비처가 없다**](../docs/re/media-playback.md) |
| R2G-13 | P2 | Per-wallpaper video alignment center/free and position/zoom/flip | confirmed_partial_contract_partial | [switch SceneRenderSettings.fitMode](../Sources/WapleRender/VideoRenderer.swift) · [**`alignment` 5모드가 없다.**](../docs/re/media-playback.md) |
| R2G-14 | P2 | Video audio output global and per-monitor gate | confirmed_missing | [policyMuted \|\| volume <= 0](../Sources/WapleRender/VideoRenderer.swift) · [**`videoaudiooutput` 2단 게이트](../docs/re/media-playback.md) |
| R2G-15 | P2 | Embedded video HDR color resource and combine_video_hdr path | confirmed_missing | [kCVPixelFormatType_32BGRA](../Sources/WapleRender/SceneVideoLayer.swift) · [/// HDR video.](../Sources/WapleRender/SceneVideoLayer.swift) |
| R2G-16 | P2 | VideoRenderer end event hook for videosequence playlists | confirmed_missing | [let looper = AVPlayerLooper](../Sources/WapleRender/VideoRenderer.swift) · [`videosequence`(동영상 끝나면 전환)](../docs/re/playlist-transition.md) |
| R2G-17 | P2 | IVideoTexture backing control and per-layer texture animation clocks | cross_owner_missing | [getVideoTexture: function() { return __noopProxy(); }](../Sources/WapleRender/TextScriptEngine.swift) · [let fr = layer.frames[TexImage.spriteFrameIndex](../Sources/WapleRender/SceneRendererFrameEncoder.swift) |
| R2G-05 | P3 | Camera fade scene final overlay is parsed and unused | confirmed_missing_contract_partial | [public var cameraFade: Bool = true](../Sources/WapleCore/SceneDocument.swift) · [### W-26](../docs/re/tonemapping.md) |
| R2G-07 | P3 | TEXV0004 legacy container layout | confirmed_missing_real_sample_absent | [guard b.count > 42](../Sources/WapleCore/TexImage.swift) · [TEXV0004` 레거시 컨테이너](../docs/re/tex-format.md) |
| R2G-08 | P3 | SHDV0069 shader cache parser and user-shader-values table | confirmed_missing | [gradient uniforms, and `SHDV0069`](../README.md) · [**꼬리는 반사 테이블이 아니라](../docs/re/shader-combos.md) |
| R2G-12 | P3 | spritesheetrefreshsync start alignment is parsed only | confirmed_missing | [public var spritesheetRefreshSync](../Sources/WapleCore/SceneDocument.swift) · [**`spritesheetrefreshsync` 소비가 없다.**](../docs/re/media-playback.md) |

## 3D·라이팅

| ID | 우선순위 | 항목 | 시작 판정 | 코드·계약 근거 |
| --- | --- | --- | --- | --- |
| R3G-01 | P1 | 3D 텍스트 내용의 매프레임 재래스터·텍스처 교체 | not_implemented | [build3D/text billboard](../Sources/WapleRender/SceneRenderer3D.swift) · [evaluate3DScripts](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-02 | P1 | 3D 텍스트 alpha/color 프로퍼티 업데이트 | not_implemented | [build3D/text attachScripts](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-07 | P1 | 3D 이미지 이펙트 visible 스크립트와 effect owner 머티리얼 쓰기 | not_implemented | [build3D/effect loop](../Sources/WapleRender/SceneRenderer3D.swift) · [buildEffectChain](../Sources/WapleRender/SceneRendererResources.swift) |
| R3G-08 | P1 | 3D 컴포지션 copybackground=false·자식별 오프스크린 RT | partial | [Billboard3D](../Sources/WapleRender/SceneRenderer3D.swift) · [encode3D/framebuffer billboard](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-10 | P1 | 3D 객체·빌보드 transform/property 키프레임 값 구동 | not_implemented | [Node3D.evaluateScripts](../Sources/WapleRender/SceneRenderer3D.swift) · [Billboard3D.evaluateScripts](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-12 | P1 | 3D 모델 다층 animationlayers·가중치·동적 rate/visible | partial | [MeshRenderable](../Sources/WapleRender/SceneRenderer3D.swift) · [build3D/animation selection](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-13 | P1 | 3D 모델 bone attachment 부착 변환 | not_implemented | [SceneObject3D.attachment](../Sources/WapleCore/SceneDocument.swift) · [encode3D/model world](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-14 | P1 | 3D 모델 머티리얼 user/script/animation 및 material override 런타임 | partial | [loadMesh3DMaterial/fvec](../Sources/WapleRender/SceneRenderer3D.swift) · [CustomMeshShader](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-16 | P1 | PBR mask 개별 콤보·emissive A채널·reflection B채널·normal 결합 | partial | [mf_normal mask](../Sources/WapleRender/Mesh3DShaders.swift) · [mf_reflect](../Sources/WapleRender/Mesh3DShaders.swift) |
| R3G-18 | P1 | legacy generic/generic2와 deprecated generic3 조명 레인 파리티 | partial | [Scene3DMaterialValues/legacy](../Sources/WapleRender/Scene3DLighting.swift) · [Scene3DMaterialValues docs](../Sources/WapleRender/Scene3DLighting.swift) |
| R3G-21 | P1 | 3D light own propertyScripts·가시성·동적 조명 값 | not_implemented | [SceneLight3D.propertyScripts](../Sources/WapleCore/SceneDocument.swift) · [build3D](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-23 | P1 | ortho hybrid 모델의 custom/normal-mask/fog 경로 동등성 | partial | [runOrtho3DMeshes](../Sources/WapleRender/SceneRendererFrameEncoder.swift) · [runOrtho3DMeshes](../Sources/WapleRender/SceneRendererFrameEncoder.swift) |
| R3G-31 | P1 | 3D 파티클 script visibility·play/pause·order interleave·굴절 소비 | partial | [encode3DParticles](../Sources/WapleRender/SceneRenderer3D.swift) · [encode3D particle placement](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-03 | P2 | 3D 텍스트 effects·배경/아웃라인·blend/depth 저작 상태 | partial | [build3D/text billboard](../Sources/WapleRender/SceneRenderer3D.swift) · [parseText](../Sources/WapleCore/SceneDocument.swift) |
| R3G-04 | P2 | 3D 이미지 빌보드 동영상·스프라이트 프레임 런타임 | not_implemented | [build3D/image upload](../Sources/WapleRender/SceneRenderer3D.swift) · [encode3D/billboard effects](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-05 | P2 | 3D 이미지 퍼펫·본 부착 지오메트리 | not_implemented | [build3D/image Billboard3D](../Sources/WapleRender/SceneRenderer3D.swift) · [encodeBillboard](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-06 | P2 | 3D 빌보드 custom shader·normal/PBR/refraction/reflection·색상 블렌드 패리티 | partial | [Billboard3D](../Sources/WapleRender/SceneRenderer3D.swift) · [encodeBillboard](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-09 | P2 | 3D 모델 객체 effects[] 렌더 소비 | not_implemented | [SceneObject3D](../Sources/WapleCore/SceneDocument.swift) · [build3D/model material](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-11 | P2 | 3D 이미지/텍스트의 전체 XYZ 회전·scaleZ·부모 배향 | partial_spec_pending | [Billboard3D](../Sources/WapleRender/SceneRenderer3D.swift) · [encodeBillboard](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-15 | P2 | 실제 tangent/handedness 전달 및 스키닝 normal/PBR·반사·굴절 결합 | partial | [Model3D.Vertex](../Sources/WapleCore/Model3D.swift) · [encode3D/PBR normal branch](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-17 | P2 | 반사 입력 RT 생성 시점·씬 콘텐츠 완전성의 WE 파리티 | partial_spec_pending | [encode3D/reflection snapshot](../Sources/WapleRender/SceneRenderer3D.swift) · [mf_reflect/source caveat](../Sources/WapleRender/Mesh3DShaders.swift) |
| R3G-19 | P2 | spot light shadow map | not_implemented | [resolveLights/shadowCandidate](../Sources/WapleRender/Scene3DLighting.swift) · [mf_main spot](../Sources/WapleRender/Mesh3DShaders.swift) |
| R3G-20 | P2 | spot cookie 투영 및 spotcookie/spotshadowcookie 슬롯 | not_implemented_spec_pending | [SceneLight3D](../Sources/WapleCore/SceneDocument.swift) · [Scene3DLightUniform](../Sources/WapleRender/Scene3DLighting.swift) |
| R3G-22 | P2 | tube 단점 B의 진짜 controlpoint 키·기본값 | partial | [parseLight](../Sources/WapleCore/SceneDocument.swift) · [Scene3DResolvedLight.originB](../Sources/WapleRender/Scene3DLighting.swift) |
| R3G-24 | P2 | ortho hybrid 그림자·volumetric 조명 패스 | not_implemented_spec_pending | [runOrtho3DMeshes](../Sources/WapleRender/SceneRendererFrameEncoder.swift) · [encode3D/volumetrics](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-25 | P2 | 모델 두 번째 UV와 LIGHTMAP 렌더 | not_implemented | [Model3D.Vertex.uv1](../Sources/WapleCore/Model3D.swift) · [build3D/packed vertex](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-27 | P2 | fog 바인딩·재평가와 빌보드 FOG:0 opt-out | partial | [Scene3DFog.parse](../Sources/WapleRender/Scene3DLighting.swift) · [encodeBillboard fog](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-28 | P2 | volumetric 정확한 light kind·spot hull·품질 render graph | partial | [VolumetricLightParameters.isPointLight](../Sources/WapleRender/VolumetricLightPass.swift) · [VolumetricLightPass scope](../Sources/WapleRender/VolumetricLightPass.swift) |
| R3G-29 | P2 | MSAA alpha-to-coverage 및 material render-state 완전성 | partial | [loadMesh3DMaterial/blend](../Sources/WapleRender/SceneRenderer3D.swift) · [mesh3DPipeline](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-30 | P2 | 그림자 SHADINGGRADIENT 결합 및 CSM 피팅/바이어스 파리티 | partial_spec_pending | [directionalPBR shadow caveat](../Sources/WapleRender/Mesh3DShaders.swift) · [DirectionalShadowMath](../Sources/WapleRender/Scene3DLighting.swift) |
| R3G-32 | P2 | 3D spritetrail/rope 리본 연결 지오메트리 | not_implemented | [particle3DVertices](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-33 | P2 | 3D text glyph·spritesheet·RIM/SHADINGGRADIENT 최종 픽셀 오라클 | verification_gap | [F406](../BACKLOG.md) · [RIM/gradient tests](../Tests/WapleRenderTests/Scene3DRenderCorrectnessTests.swift) |
| R3G-34 | P2 | 8개 고정 light cap과 native lightconfig 가변 크기 | partial | [Scene3DLighting.maximumLights](../Sources/WapleRender/Scene3DLighting.swift) · [light loops](../Sources/WapleRender/Mesh3DShaders.swift) |
| R3G-35 | P2 | 모델·3D 빌보드 explicit dependencies render/evaluation order | not_implemented | [rebuild3DDrawOrders](../Sources/WapleRender/SceneRenderer3D.swift) · [parseModel](../Sources/WapleCore/SceneDocument.swift) |
| R3G-36 | P2 | 3D 이미지 castshadow 및 변형된 custom geometry의 caster 패리티 | not_implemented | [WE image property registration](../Sources/WapleCore/SceneDocument.swift) · [encodePointShadows](../Sources/WapleRender/SceneRenderer3D.swift) |
| R3G-26 | P3 | 모델 MORPHING runtime·트레일러 morph 소비 | not_implemented_spec_pending | [Model3D.MeshTrailer](../Sources/WapleCore/Model3D.swift) · [build3D/vertex packing](../Sources/WapleRender/SceneRenderer3D.swift) |

## SceneScript·웹

| ID | 우선순위 | 항목 | 시작 판정 | 코드·계약 근거 |
| --- | --- | --- | --- | --- |
| JSG-01 | P1 | WE 기본 Vec/Mat 클래스 전체 표면을 실제 런타임에 로드 | partial | [ctx.evaluateScript(TextScriptEngine.shims)](../Sources/WapleRender/TextScriptEngine.swift) · [baseclasses 미로드(= 현재)](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-02 | P1 | ES module 로딩·별칭·named/default import를 실제 모듈 내용에 연결 | partial | [private static func importBindings(clause: String)](../Sources/WapleRender/TextScriptEngine.swift) · [// 모듈 문자열 소비.](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-03 | P1 | createLayer/sortLayer/destroyLayer를 실제 렌더 레이어 생명주기에 연결 | partial | [private func installWarnBridge](../Sources/WapleRender/TextScriptEngine.swift) · [createLayer: function(configuration)](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-05 | P1 | 씬 카메라 JS 객체와 camera transforms를 실제 view/projection에 연결 | stub | [function __makeCamera()](../Sources/WapleRender/TextScriptEngine.swift) · [setCameraTransforms: function(v)](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-07 | P1 | resizeScreen/destroy/applyGeneralSettings 훅과 실제 screenResolution 배달 | partial | [`resizeScreen`/`destroy`/`applyGeneralSettings` 는 여기서 **수집만**](../Sources/WapleRender/TextScriptEngine.swift) · [public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize)](../Sources/WapleRender/SceneRenderer.swift) |
| JSG-08 | P1 | 씬 localStorage의 screen/global scope를 실제로 분리 | partial | [get: function(key, location)](../Sources/WapleRender/TextScriptEngine.swift) · [set: function(key, value, location)](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-10 | P1 | thisScene/getAnimation과 IObject.getAnimation의 실제 property timeline 제어 | stub | [__animations: {},](../Sources/WapleRender/TextScriptEngine.swift) · [getAnimation: function() { return tex.animation; }](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-23 | P1 | 웹directory fetchall 파일변경·삭제 자동통지 | partial | [private func deliverFetchAllDirectories()](../Sources/WapleRender/WebRenderer.swift) · [defineBridge('__wapleDirectoryFilesRemoved'](../Sources/WapleRender/WallpaperBridgeJS.swift) |
| JSG-25 | P1 | 웹정책음소거의WebAudio출력까지커버 | partial | [**못 덮는 것: Web Audio.**](../Sources/WapleRender/WebRenderer.swift) · [static func muteJS](../Sources/WapleRender/WebRenderer.swift) |
| JSG-04 | P2 | getInitialLayerConfig가 저작 초기값을 반환하도록 snapshot 보존 | stub | [getInitialLayerConfig: function()](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-06 | P2 | thisScene 렌더 속성·scene 소유 thisObject의 실제 상태 노출/쓰기 | missing | [function __makeScene(layer)](../Sources/WapleRender/TextScriptEngine.swift) · [public enum ScriptOwner](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-09 | P2 | SceneScript console.log/error를 제한된 진단 싱크에 연결 | stub | [var console = { log: function(){}, error: function(){} };](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-11 | P2 | ITextureAnimation 제어를 실제 sprite/GIF 프레임 공급에 연결 | stub | [function __makeTextureAnimation()](../Sources/WapleRender/TextScriptEngine.swift) · [getTextureAnimation: function() { return tex.animation; }](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-12 | P2 | getVideoTexture의 IVideoTexture 제어 핸들을 실제 SceneVideoLayer에 연결 | stub | [getVideoTexture: function() { return __noopProxy(); }](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-13 | P2 | get/create/playSingle/destroyAnimationLayer를 실제 skeletal mixer에 연결 | stub | [getAnimationLayer: function() { return animLayer; }](../Sources/WapleRender/TextScriptEngine.swift) · [function __makeAnimationLayer()](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-14 | P2 | bone/attachment query·pose쓰기·transformAttachmentToTexture 실제연결 | missing_or_stub | [transformAttachmentToTexture: function() { return __noopProxy(); }](../Sources/WapleRender/TextScriptEngine.swift) · [function __makeLayer()](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-16 | P2 | blend shape index/weight API를 morph target 렌더에 연결 | missing_requires_backend | [function __makeLayer()](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-17 | P2 | 파티클 스크립트 stop/emitParticles/instance 실제 제어 | partial | [emitParticles: function() { return this; }](../Sources/WapleRender/TextScriptEngine.swift) · [stop() 이 pause() 와 같은 이유](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-18 | P2 | 효과 lookup·material metadata·매프레임 object-write 반영 | partial | [getEffect: function() { return __noopProxy(); }](../Sources/WapleRender/TextScriptEngine.swift) · [per-frame `update` 안의 thisObject 쓰기는 아직 소비하지 않는다](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-19 | P2 | engine.registerAsset와procedural IModelData 생성·갱신·수명 | missing | [var __engineState](../Sources/WapleRender/TextScriptEngine.swift) · [function __makeScene(layer)](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-20 | P2 | 레이어 좌표변환 보조API·실제reparent/children를renderer와 동기화 | partial | [setParent: function(p) { this.parent = p \|\| null; return this; }](../Sources/WapleRender/TextScriptEngine.swift) · [getChildren: function() { return this.children.slice(); }](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-21 | P2 | 선언된시각필드의JS직접쓰기 read-back 채널 완성 | partial | [func readBackScriptLayerState(index: Int)](../Sources/WapleRender/SceneRendererFrameEncoder.swift) · [__updateSceneLayers(descriptors, start)](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-24 | P2 | 웹랜덤파일요청을WE소진형셔플백으로변경 | partial | [walk(directoryURL).randomElement()](../Sources/WapleRender/WebRenderer.swift) |
| JSG-26 | P2 | 웹입력프록시modifier/repeat/flagsChanged와pointer button메타데이터 | partial | [private func forwardKey](../Sources/WapleRender/WebInputProxyView.swift) · [var ko = { key: a, code: b \|\| a](../Sources/WapleRender/WallpaperBridgeJS.swift) |
| JSG-27 | P2 | wallpaperOnVideoEnded 웹fallback→native종료신호배달 | stub | [defineBridge('wallpaperOnVideoEnded', function () {});](../Sources/WapleRender/WallpaperBridgeJS.swift) |
| JSG-15 | P3 | bone physics impulse/reset API의 시뮬레이터 연결 | missing_requires_backend | [function __makeLayer()](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-22 | P3 | engine.openUserShortcut 등록프로퍼티의 제한된실행 | missing_requires_contract | [var __engineState](../Sources/WapleRender/TextScriptEngine.swift) |
| JSG-28 | 해당 없음 | 브라우저영속저장·원격네트워크제약은의도된정책으로유지 | intentional_policy_not_implementation_gap | [config.websiteDataStore = .nonPersistent()](../Sources/WapleRender/WebRenderer.swift) · ["connect-src \(local)"](../Sources/WapleRender/WallpaperSchemeHandler.swift) |
| JSG-29 | 해당 없음 | ServiceWorker shim은성공모양compatibility no-op임을유지/명시 | intentional_compatibility_stub | [var serviceWorkerShim = {](../Sources/WapleRender/WallpaperBridgeJS.swift) |
| JSG-30 | 해당 없음 | Windows LED plugin로드통지는현재platform외부제약 | platform_blocked_not_to_fake | [### 6.2 플러그인 로드 통지](../docs/re/web-wallpaper-bridge.md) |
| JSG-31 | 해당 없음 | WE screenshot 페이지왕복프로토콜은WebKit방식차이로미재현 | platform_difference_not_required_for_native_snapshot | [defineBridge('wallpaperRequestTakeScreenshotResponse', function () {});](../Sources/WapleRender/WallpaperBridgeJS.swift) · [### 6.1](../docs/re/web-wallpaper-bridge.md) |
| JSG-32 | 해당 없음 | localStorage.subscribe는WE선언표면밖의기존compatibility no-op | not_a_declared_we_requirement | [subscribe: function(key, cb) { return function() {}; }](../Sources/WapleRender/TextScriptEngine.swift) |

## 셰이더 번역·바인딩

| ID | 우선순위 | 항목 | 시작 판정 | 코드·계약 근거 |
| --- | --- | --- | --- | --- |
| SHG-01 | P1 | Preserve and bind typed fixed-size uniform arrays | partial | [Uniform / parseUniforms](../Sources/WapleCore/GLSLTranslator.swift) · [symbolMap](../Sources/WapleCore/GLSLTranslator.swift) |
| SHG-02 | P1 | Supply legacy custom-shader light arrays | missing | [legacy lighting](../Sources/WapleRender/Resources/WEAssets/shaders/generic.frag) · [isEngine](../Sources/WapleCore/GLSLTranslator.swift) |
| SHG-03 | P1 | Generate LightingV1 and bind the Forward+ custom-shader contract | missing | [evaluateConditionals #require](../Sources/WapleCore/ShaderPreprocessor.swift) · [isEngine Forward+](../Sources/WapleCore/GLSLTranslator.swift) |
| SHG-04 | P1 | Carry a_Tangent4 through custom static-mesh shaders | missing | [vertexAttributeWhitelist](../Sources/WapleCore/GLSLTranslator.swift) · [NORMALMAP vertex branch](../Sources/WapleRender/Resources/WEAssets/shaders/generic3.vert) |
| SHG-06 | P1 | Bind camera and model/effect transform uniforms in custom shaders | partial | [engineReplacement](../Sources/WapleCore/GLSLTranslator.swift) · [authoring reach](../docs/re/shader-uniforms.md) |
| SHG-07 | P1 | Feed authored ambient and skylight colors to translated shaders | partial | [engineReplacement](../Sources/WapleCore/GLSLTranslator.swift) · [prepare3D](../Sources/WapleRender/SceneRenderer3D.swift) |
| SHG-05 | P2 | Support custom particle attribute and engine-data layout | missing | [particle attributes](../Sources/WapleRender/Resources/WEAssets/shaders/genericparticle.vert) · [ComputeSpriteFrame](../Sources/WapleRender/Resources/WEAssets/shaders/common_particles.h) |
| SHG-08 | P2 | Upload and bind real 3D LUT textures for sampler3D | partial | [ccsimple LUT](../Sources/WapleRender/Resources/WEAssets/shaders/ccsimple.frag) · [TexImage.depth](../Sources/WapleCore/TexImage.swift) |
| SHG-09 | P2 | Extend translated texture metadata through actual engine slots 8 and 9 | partial | [emitMSL EngineU](../Sources/WapleCore/GLSLTranslator.swift) · [engineReplacement](../Sources/WapleCore/GLSLTranslator.swift) |
| SHG-10 | P2 | Preserve tokens after inline block comments in directives | missing | [evaluateConditionals](../Sources/WapleCore/ShaderPreprocessor.swift) |
| SHG-12 | P2 | Declare and bind textures used by vertex shaders | missing | [emitMSL vertSig](../Sources/WapleCore/GLSLTranslator.swift) · [morph vertex texture load](../Sources/WapleRender/Resources/WEAssets/shaders/base/model_vertex_v1.h) |
| SHG-14 | P2 | Carry custom skeletal and morph animation data through translated shaders | partial_external_owner | [generic4 skinning](../Sources/WapleRender/Resources/WEAssets/shaders/generic4.vert) · [generic4 morphing](../Sources/WapleRender/Resources/WEAssets/shaders/generic4.vert) |
| SHG-11 | P3 | Match 32-bit arithmetic in already-supported #if integer expressions | partial | [ExprEval contract](../Sources/WapleCore/ShaderPreprocessor.swift) · [parseAdd](../Sources/WapleCore/ShaderPreprocessor.swift) |
| SHG-13 | P3 | Handle SHDV0069-only shader permutations through an explicit compatibility path | unsupported_external | [SHDV cache §7](../docs/re/shader-combos.md) · [SHDV user binding tail](../docs/re/shader-combos.md) |
| SHG-15 | P3 | Make scalar CAST3X3 reproduce the confirmed WE HLSL cast | partial_intentional_divergence | [we_cast3x3(float)](../Sources/WapleCore/GLSLTranslator.swift) |
| SHG-16 | P3 | Pass expanded array/matrix varyings through helper captures | partial_declared_limit | [varying matrix/array limit](../docs/re/shader-translation.md) · [expandArrayVaryings](../Sources/WapleCore/GLSLTranslator.swift) |

## 텍스트·UI·접근성

| ID | 우선순위 | 항목 | 시작 판정 | 코드·계약 근거 |
| --- | --- | --- | --- | --- |
| TXTG-01 | P2 | 텍스트 spacing의 자간·추가 행간 소비 | parsed_not_rendered | [SceneTextLayer.spacing / parseText](../Sources/WapleCore/SceneDocument.swift) · [render](../Sources/WapleRender/TextRasterizer.swift) |
| TXTG-02 | P2 | outline·outlineColor·outlineThickness를 글리프 외곽선으로 렌더 | parsed_not_rendered | [SceneTextLayer.outline*](../Sources/WapleCore/SceneDocument.swift) · [parseText](../Sources/WapleCore/SceneDocument.swift) |
| TXTG-03 | P2 | 렌더 padding 및 opaqueBackground·backgroundColor·backgroundBrightness 구현 | partially_consumed_hitbox_only | [SceneTextLayer.opaqueBackground / padding / backgroundBrightness](../Sources/WapleCore/SceneDocument.swift) · [rasterize](../Sources/WapleRender/SceneRendererResources.swift) |
| TXTG-04 | P2 | 텍스트 anchor를 화면 사각형 기반 전체 모델 변환에 적용 | parsed_and_script_exposed_not_rendered | [SceneTextLayer.anchor](../Sources/WapleCore/SceneDocument.swift) · [sceneScriptLayers(from:)](../Sources/WapleRender/SceneRenderer.swift) |
| TXTG-07 | P2 | 컬러 글리프는 원색을 유지하고 단색 glyph에만 레이어 tint 적용 | bitmap_color_preserved_but_tint_shared | [render un-premultiply / color font note](../Sources/WapleRender/TextRasterizer.swift) · [f_main](../Sources/WapleRender/QuadShaders.swift) |
| TXTG-10 | P2 | 창이 닫혀 있을 때 중요한 실패를 macOS 알림으로 전달 | tray_fallback_present_native_notifications_missing | [notify](../Sources/Waple/AppDelegate.swift) · [제품화 1](../BACKLOG.md) |
| TXTG-05 | P3 | 텍스트 blur·drop shadow 7개 속성의 파스와 렌더 | missing_parse_and_render | [SceneTextLayer / parseText](../Sources/WapleCore/SceneDocument.swift) · [render](../Sources/WapleRender/TextRasterizer.swift) |
| TXTG-06 | P3 | 명시적 msdf 텍스트 거리장 생성·샘플링 경로 | missing_parser_and_backend | [SceneTextLayer / parseText](../Sources/WapleCore/SceneDocument.swift) · [render](../Sources/WapleRender/TextRasterizer.swift) |
| TXTG-08 | P3 | 유한 pointsize를 WE와 같은 1~256pt 범위로 clamp | known_explicit_deviation | [maxPointSize](../Sources/WapleRender/TextRasterizer.swift) · [render](../Sources/WapleRender/TextRasterizer.swift) |
| TXTG-09 | P3 | 무제한 초장문을 저작 글자 크기로 그리는 분할 래스터/드로우 | fallback_shrinks_instead_of_preserving_size | [render allocation guard](../Sources/WapleRender/TextRasterizer.swift) · [GPUText rasterize](../Sources/WapleRender/SceneRendererResources.swift) |
| TXTG-11 | P3 | 접근성 표시 설정 변경의 실행 중 즉시 반영 | settings_read_on_demand_without_change_observer | [SystemPreference type comment](../Sources/Waple/DesignSystem/SystemPreference.swift) · [isReduced](../Sources/Waple/DesignSystem/Motion.swift) |
| TXTG-12 | P3 | WE의 고정 폰트 fallback 순서와 플랫폼 대체의 충실도 정합 | platform_fallback_approximation | [systemFontAliases](../Sources/WapleRender/TextRasterizer.swift) · [makeFont/fallbackFont](../Sources/WapleRender/TextRasterizer.swift) |

