B1: 전수 정독했다. 담당 21파일을 첫 줄부터 마지막 줄까지 Read 로 순서대로 읽었고 건너뛴 구간은 없다.

파일별 실제 줄 수(`wc -l`): SceneDocument 4187 · Scene3DLighting 782 · ParticleControlPointFrame 651 · SystemAudioSpectrumProvider 554 · WallpaperBridgeJS 418 · PuppetModel 378 · SimplexNoise 331 · DisplaysView 275 · AudioResponse 255 · WallpaperProject 223 · DeepReport 195 · OnboardingView 158 · SceneRendererFinalizer 146 · ColorRole 128 · MediaPoller 100 · PlaylistStore 100 · SceneRenderSettings 75 · ZipImporter 75 · PlaylistStateTimeStore 62 · SystemPreference 40 · BinaryReading 32.

**합계 8,965줄이다 — 버킷 헤더의 "총 9165줄" 과 200줄 어긋난다.** 파일 목록 21개는 헤더와 일치하므로 차이는 줄 수 계산 쪽이지 누락이 아니다(내 쪽은 `wc -l` 실측). 21파일 전건을 다 읽었다는 사실은 그대로다.

읽기 방식: 300줄 단위 Read 로 연속 오프셋(1-300, 300-599, 599-898, …)을 이어 붙였고, 중간에 grep 은 (a) 읽은 내용의 인용 대조 (b) 호출부/정의부 찾기 두 용도로만 썼다. 지시대로 파일 수정·`swift build`/`swift test` 는 하지 않았다.

버킷 밖 파일도 대조를 위해 부분 열람했다(형제 비대칭·인용 검증 목적, 전수 아님): SceneRendererResources.swift, SceneRendererFrameEncoder.swift, SceneRenderer.swift, SceneRenderer3D.swift, GLSLTranslator.swift, Model3D.swift, VideoRenderer.swift, WebRenderer.swift, AppDelegate.swift, SnapshotPipeline.swift, ProjectJSONParser.swift, PlaybackPolicyRuntime.swift, WallpaperGridView.swift, WorkshopTabView.swift, TexImage.swift, AudioSpectrum.swift, WapleProfiler.swift, docs/re/scene-lighting.md, docs/re/media-playback.md, spec/corpus/scene-schema.json.

못 한 것: `wallpaper64.exe`/`webwallpaper64.exe` 가 이 머신에 없어 VA 인용(수백 자리)은 **한 건도 검증하지 못했다**. 워크샵 코퍼스 446개도 없으므로 워크샵 도수는 리포 동봉 정본(`spec/corpus/scene-schema.json`)으로만 대조했다.

B2: 담당 22파일(bucket-2.txt) **전부를 첫 줄부터 마지막 줄까지 읽었다. 못 읽은 파일·구간 없음.** 읽은 방식과 범위(겹침 있음, 빈틈 없음):

- Sources/WapleCore/ParticleSystem.swift(3,519줄) — 1-360 / 356-755 / 755-1154 / 1154-1553 / 1553-1953 / 1953-2352 / 2352-2751 / 2751-3150 / 3150-3520, 9회 분할
- Sources/WapleCore/ShaderPreprocessor.swift(988) — 1-340 / 340-679 / 679-988
- Sources/WapleCore/PropertyAnimation.swift(779) — 1-400 / 400-779
- Sources/WapleCore/PropertyConditionEvaluator.swift(642) — 1-330 / 330-643
- Sources/Waple/WallpaperGridView.swift(486) — 1-250 / 250-489
- Sources/Waple/SelectionPanelView.swift(401) — 1-210 / 210-404
- Sources/WapleCore/PlaylistRuntime.swift(357) — 1회 전문
- Sources/WapleCore/WallpaperProperties.swift(310) — 1회 전문
- Sources/Waple/Surfaces/Settings/SettingsView.swift(274) — 1회 전문
- Sources/WapleRender/OggVorbis/VorbisCodebook.swift(243) — 1회 전문
- Sources/WapleSnapshot/Snapshot.swift(209) — 1회 전문
- Sources/WapleCore/PlaylistStateTime.swift(176) — 1회 전문
- Sources/WapleCompatCore/SnapshotCompare.swift(153) — 1회 전문
- Sources/Waple/PlaybackObservers.swift(133) · Sources/WapleRender/UserPropertyStore.swift(118) · Sources/Waple/DesignSystem/TileAccessibility.swift(92) · Sources/Waple/Shell/StatusBanner.swift(78) · Sources/Waple/VideoImport.swift(75) · Sources/WapleRender/SceneLivePresentationFix.swift(54) · Sources/Waple/main.swift(47) · Sources/WapleCore/WapleLog.swift(21) · Sources/WapleRender/OffscreenCapture.swift(19) — 전부 1회 전문

**버킷 밖에서 읽은 것은 전부 "인용 대조용 부분 발췌" 이고 전문이 아니다**: ParticleSimulator.swift(246·300-310·504·1733·1754·2045-2050 근방), GLSLTranslator.swift(170-176·265-275·1462-1502·2050-2066), SceneRendererResources.swift(808-818·1084-1180), SceneDocument.swift(1825-1830·2837-2842·3595-3600 근방), ParticleControlPointFrame.swift(24-90), VorbisBitReader.swift(1-80), VorbisDecoder.swift(140-170 + grep), WorkshopTabView.swift(grep), LibraryViewModel.swift(485-505), AppDelegate.swift(512-540), WallpaperType.swift(31-45), JSONNumerics.swift(93-130·276-306), 선행 감사 4종(AUDIT-FULL ×3 + docs/audit-r2-lanes/lane03·04·08·09·11 + sweep/full-audit/swarm)은 dedup 목적의 grep + 해당 절 발췌.

금지사항 준수: 파일 수정 0 · git 쓰기 0 · `swift build`/`swift test` 미실행. advisor 는 두 번 호출했으나 첫 회 rate-limited, 두 번째 unavailable 로 조언 없이 진행했다.

B3: 버킷 3 의 23파일 9,168줄을 **전부 첫 줄부터 마지막 줄까지 순서대로 읽었다. 건너뛴 파일·구간 없음.**

파일별 실독 범위(파일 총줄수 = 읽은 줄수):
- Sources/WapleRender/SceneRenderer.swift 3,072 (1-300 / 300-600 / 600-900 / 899-1199 / 1198-1498 / 1497-1797 / 1796-2096 / 2095-2395 / 2394-2694 / 2693-3072 — 10회 분할, 경계 1줄씩 겹쳐 읽음)
- Sources/WapleCore/TexImage.swift 995 (1-340 / 340-670 / 669-995)
- Sources/WapleCore/PlaylistTransition.swift 872 (1-300 / 300-600 / 599-872)
- Sources/WaplePolicy/PlaybackPolicy.swift 692 (1-300 / 300-692)
- Sources/Waple/LibraryViewModel.swift 544 (1-280 / 280-544)
- Sources/WapleRender/VolumetricLightPass.swift 414 (전체 1회)
- Sources/WapleRender/WallpaperSchemeHandler.swift 384 (전체 1회)
- Sources/WapleCore/AudioSpectrumProcessor.swift 315 (전체 1회)
- Sources/WapleRender/EffectShaders.swift 294 (전체 1회)
- Sources/WapleCore/FluidSimulationPrecision.swift 244 (전체 1회)
- Sources/Waple/PlaybackPolicyComposition.swift 229 (전체 1회)
- Sources/Waple/Surfaces/Settings/SettingsViewModel.swift 183 (전체 1회)
- Sources/WapleRender/ParticleShaders.swift 169 (전체 1회)
- Sources/WapleCore/Model3DFormat.swift 146 (전체 1회)
- Sources/Waple/DesignSystem/Components/TileChrome.swift 122 (전체 1회)
- Sources/Waple/Shell/SmokeLaunch.swift 108 (전체 1회)
- Sources/WapleLibrary/MonitorAssignmentStore.swift 95 (전체 1회)
- Sources/WapleRender/OggVorbis/OggPageReader.swift 88 (전체 1회)
- Sources/WapleRender/RendererFactory.swift 64 (전체 1회)
- Sources/WapleCore/PropertyDecoration.swift 63 (전체 1회)
- Sources/Waple/DesignSystem/Components/SectionHeader.swift 40 (전체 1회)
- Sources/WapleLibrary/LibraryEntry.swift 30 (전체 1회)
- Sources/WapleRender/AudioSpectrum.swift 5 (전체 1회)

**보조로 읽은 버킷 밖 파일**(형제 대조·근거 추적 목적, 전수 아님 — 지정 구간만): SceneRenderer3D.swift:2060-2115·2502·2610, SceneRendererFrameEncoder.swift(심볼 위치 grep만), ScenePBRLighting.swift:645-760, WebCompatPatch.swift:70-100·145-175, Model3D.swift:1386-1401, AppDelegate.swift:1160-1195·1500-1560, LibraryStore.swift:95-150, UserPropertyStore.swift:1-80, VideoSettings.swift 전체, main.swift:1-20, WEAssets 원문 셰이더 4종(waterwaves.vert/frag · scroll.vert/frag · waterripple.vert/frag).

**못 잰 것(정직하게):** `swift build`/`swift test` 는 브리핑 금지라 안 돌렸다. 워크샵 코퍼스 446이 이 머신에 없어 도수 재검증이 불가능한 주석(예: `T-G15` 의 1,372/1,573/556/88 · TEXS0002 워크샵 분포 · volumetricsexponent 27건)은 **인용된 spec 파일명만 확인하고 값 자체는 재측정하지 않았다.** GPU 를 돌리지 않았으므로 MSL 셰이더 결과는 전부 문면 대조다.

B4: 23파일 9,171줄 **전 줄 정독**(bucket-4.txt 합계와 일치). `nl -ba <file> | sed -n 'A,Bp'` 로 실제 줄 번호를 붙여 300~400줄 창으로 겹치게 읽었고, 건너뛴 구간은 없다. 파일별 읽은 줄수: SceneRendererFrameEncoder 2946 · ScenePBRLighting 1011 · DeepScan 929 · VorbisDecoder 731 · ScenePackage 559 · LibraryStore 401 · SceneVideoLayer 398 · WorkshopAPI 314 · LDRBloomPass 291 · MainWindowView 254 · FFmpegConverter 220 · DesktopVisibilityMonitor 184 · ScreenSaverController 165 · RemapOperation 148 · LibraryFiltering 129 · SidebarView 103 · HDRPostPass 93 · AnimatedPreviewView 89 · StillWallpaper 68 · APIKeyGateView 54 · AudioSpectrum16 46 · SplitMix64 26 · ProjectJSONBuilder 12.

경계(정직하게):
· **버킷 밖 파일은 검증 보조로 부분만** 열람했다 — SceneRendererResources(:24-54, :325-360, :630-700, :736-860, :1215-1300), SceneRenderer(:885-893, :1480-1505, :2234), ParticleSystem(:335-360), SceneDocument(:983-1150, :378-400 상당의 AudioSpectrum:378-400), EffectShaders(:22-60, :160-280 키 목록), LDRBloomMath(:71-133), ZipImporter(전문 75줄), SteamCmdDownloader(:100-175), LibraryViewModel(:336-365), LibraryEntry(전문), VorbisCodebook(:1-120, :173-235), WapleSaverView.m(:88), check_lenient_json_reach.py(:56-73, :234-241). 이 파일들은 **전수 정독하지 않았다**.
· 짝 저장소 `Waple-wallpaper-source` 는 WE 셰이더 원문(common_pbr_2.h · common_pbr.h · common_fragment.h · genericimage4/generic2/generic3.frag · generic{,2,3,4}.vert · model_vertex_v1.h · volumetricsfront.{frag,vert} · common_blur.h · downsample_quarter_bloom.{frag,vert} · downsample_eighth_blur_v.{frag,vert} · blur_h_bloom.{frag,vert} · combine.frag · combine_hdr.frag)과 `corpus_scan/`(entry-name-frequency.tsv · scenes-index.tsv)만 인용 대조 목적으로 열었다.
· **VA(`0x1401…`) 인용은 전건 미검증**이다 — 디스어셈블 도구를 쓰지 않았다. 이 라운드가 확인한 것은 셰이더 평문 인용 · 코퍼스 도수 · 인트리 `파일:줄` 인용 · 코드 경로다.
· 지시대로 `swift build`/`swift test` 를 한 번도 돌리지 않았고 파일을 하나도 수정하지 않았다. 재현은 `nl`/`sed`/`grep`/`git show`/`git log -S`/`find`/`python3`(struct·해시만) 로만 했다.

B5: 전수 달성 — 담당 22파일 9,170줄을 **한 줄도 건너뛰지 않고 첫 줄부터 마지막 줄까지 순서대로** 읽었다(`cat -n | sed -n 'A,Bp'` 300~360줄 청크). 파일별 확인:
TextScriptEngine 1-2875 · WallpaperCompatibilityAnalyzer 1-1177 · Mesh3DShaders 1-909 · AppLogic 1-685 · AudioSpectrum 1-501 · FluidSimulation 1-458 · NowPlayingBar 1-366 · SceneAudioPlayer 1-318 · QuadShaders 1-282 · WapleCompat/main 1-265 · NowPlayingProvider 1-212 · WebInputProxyView 1-200 · AssetJSON 1-159 · Model3DPose 1-144 · BuiltinShaderIncludes 1-128 · WallpaperPathSecurity 1-103 · WapleProfiler 1-97 · Motion 1-82 · Badges 1-71 · Typography 1-56 · VideoSettings 1-43 · DesktopWindow 1-39. 못 읽은 파일·구간 **0**. 진행 원장은 scratchpad/coverage.txt 에 청크마다 적었다.

**검증 범위의 한계(정직하게 — 읽기 범위의 구멍은 아니다).** 주석 근거는 이 머신에서 따라갈 수 있는 것만 실제로 따라갔다: 짝 저장소 GLSL 원문(common_pbr.h · common_pbr_2.h · common_blending.h · common_fragment.h · model_vertex_v1.h · generic*.vert/frag · fluidsimulation 8종 + effect.json/materials) · `lib.sceneScript.d.ts` · 동봉/설치본 코퍼스 계수 · 인트리 `파일:줄` 교차인용 · `git log -S` 출생 특정 · python3 산술 재계산. **바이너리 VA 인용(`0x140…` wallpaper64.exe / scenescript64.dll)은 디스어셈블로 재확인하지 않았다** — 이 라운드에서 그 축은 미검증으로 남는다. 브리핑 금지대로 `swift build`/`swift test` 는 돌리지 않았고 파일도 한 줄도 고치지 않았다.

버킷 밖 대조로 읽은 자리(형제 확인용, 전수 대상 아님): WebRenderer:65-76 · SceneRenderer:215-235/1145/1925 · SceneRendererFrameEncoder:1395-1462 · SystemAudioSpectrumProvider:30-90/150-200 · PlaybackObservers:48-131 · AppDelegate:30-36/752-758/919-1123 · ZipImporter:69 · SteamCmdDownloader:203 · FFmpegConverter:206 · SceneVideoLayer:58 · ProfilePipeline/SnapshotPipeline/SnapshotCompare 인용 지점 · AudioSpectrumWEParityTests:105-130.

B6: **버킷 6 의 22파일 9,170줄을 전부 첫 줄부터 마지막 줄까지 읽었다. 건너뛴 파일·구간 없다.**

읽은 구간(연속·중복 허용, 누락 0):
- ParticleSimulator.swift(2754): 1-330 / 330-669 / 669-1008 / 1008-1347 / 1347-1686 / 1686-2025 / 2025-2364 / 2364-2754
- Model3D.swift(1401): 1-350 / 350-699 / 699-1048 / 1048-1401
- WebRenderer.swift(845): 1-300 / 300-599 / 599-845
- PuppetPose.swift(642): 1-330 / 330-642
- CameraMotion.swift(529): 1-280 / 280-529
- VideoRenderer.swift(435): 1-240 / 240-435
- HDRBloomPass.swift(358): 1-200 / 200-358
- 나머지 15파일(PropertyEditorView 332 · TextRasterizer 279 · BlendMSL 260 · FluidSimulationGrid 215 · PlaybackPolicyRuntime 197 · HDRBloomMath 160 · VideoTextureExtractor 141 · VorbisImdct 130 · DiscoverViewModel 104 · DiscoverView 96 · Surface 86 · WorkshopUtilityBar 69 · PropertyGrouping 52 · VideoFallbackHTML 47 · DesktopWindowController 38): 각 1회 전문 읽기

버킷 밖 **부분** 읽기(형제 대조 목적 — 전수 아님, 그 파일들은 다른 버킷 소관):
FluidSimulation.swift:120-199(divergence/jacobiPressure 정본) · VorbisDecoder.swift:700-725 + blocksize grep(FFTPlan precondition 안전성) · Model3DFormat.swift:142-146(materialCount 상한) · WallpaperSchemeHandler.swift:7-8(scheme/host 리터럴 대조) · WebRendererOcclusionTests.swift:1-70 · AppDelegate.swift:775-795·1170-1225 · BACKLOG.md:365-430(D9) · docs/audit-r2-lanes/lane05-render-core.md:210-245.

빌드/테스트 금지 조건을 지켰다 — `swift build`/`swift test` 0회. 실행한 것은 grep·sed·python3(WEAssets json 파스, 순수 읽기)뿐이고 파일 수정·git 조작 0건.

**실행하지 못한 검증**: F1 은 코드 트레이스이고 런타임 재현을 못 돌렸다(빌드 금지). `AVPlayer.pause()` 직후 `rate == 0` 이라는 전제와, 루프 이음매에서 `rate` 가 0 을 스친다는 2차 경로는 이 파일의 자기 주석(:387-388)에 의존한 것이지 계측한 것이 아니다.

B7: 담당 22파일 **9,168줄 전부**를 첫 줄부터 마지막 줄까지 순서대로 읽었다. 건너뛴 파일·구간 없음. 읽기 방식은 `cat -n <file> | sed -n 'X,Yp'` 로 연속 구간 전수(200~250줄 단위), 각 구간의 끝 줄과 다음 구간의 시작 줄을 겹쳐 잡아 경계 누락을 막았다.

구간별 실적(파일 = 읽은 줄 범위 = 파일 총줄수):
SceneRenderer3D.swift 1-2691 / AppDelegate.swift 1-1921 / EffectManifest.swift 1-750 / GLSLTypeAdapter.swift 1-621 / SnapshotPipeline.swift 1-476 / TexDecoder.swift 1-398 / JSONNumerics.swift 1-336 / WorkshopViewModel.swift 1-305 / PlaylistDriver.swift 1-266 / SceneGeometry.swift 1-234 / WebCompatPatch.swift 1-210 / LDRBloomMath.swift 1-176 / Scene3DMath.swift 1-150 / PreviewThumbnail.swift 1-138 / BaseAssetsSettings.swift 1-118 / Metrics.swift 1-89 / ParallaxController.swift 1-80 / Space.swift 1-72 / WallpaperRenderer.swift 1-61 / FavoritesStore.swift 1-41 / LoginItemController.swift 1-23 / WallpaperWindowLevel.swift 1-12.
합 = 2691+1921+750+621+476+398+336+305+266+234+210+176+150+138+118+89+80+72+61+41+23+12 = **9,168** (bucket-7.txt 의 선언값과 일치).

정직한 한계 3가지:
1. 바이너리 근거(`wallpaper64.exe` VA · 디스어셈블 인용)는 **한 건도 검증하지 않았다.** 이 버킷의 주석 상당량(LDRBloomMath · SceneGeometry · JSONNumerics · WebCompatPatch · EffectManifest)이 VA 로 논증하는데, 나는 코퍼스·소스·git 으로 검증 가능한 축만 밟았다. VA 축은 미검증으로 남는다.
2. `swift build`/`swift test` 금지 규약을 지켰으므로 **실행 재현은 0건**이다. 재현은 전부 코퍼스 실측(python3/grep) · git pickaxe · 코드 독해다. 발견 8건 중 실행이 필요한 것은 없다.
3. 워크샵 코퍼스(446)가 이 머신에 없으므로 그 모집단을 가리키는 도수는 반증할 수 없다. 그런 항목 하나를 보류했다 — SceneRenderer3D.swift:2663 \"코퍼스에서 x|y ≠ 0 을 저작한 씬이 33개다\": 동봉+설치본 union 에서는 rotationrandom/angularvelocityrandom 의 x|y≠0 def 를 마운트하는 씬이 unique 3건(rain splashes · leaves5 · shimmering_particles)뿐이라 33 은 워크샵 기준일 수밖에 없고 모집단 표기가 없다. 반증 불가라 발견으로 올리지 않았다.

B8: 20/20 파일 · 9,169줄 전건을 첫 줄부터 마지막 줄까지 순서대로 읽었다. 못 읽은 파일·구간 없음.

읽은 범위(모두 `cat -n <file> | sed -n 'A,Bp'` 로 연속, 경계 1줄 중첩):
- WapleRender/SceneRendererResources.swift(2683): 1-340, 340-560, 560-780, 780-1000, 1000-1220, 1220-1440, 1440-1660, 1660-1880, 1880-2100, 2100-2320, 2320-2540, 2540-2683
- WapleCore/GLSLTranslator.swift(2656): 1-200, 200-420, 420-640, 640-860, 860-1080, 1080-1300, 1300-1520, 1520-1740, 1740-1960, 1960-2180, 2180-2400, 2400-2656
- WapleRender/WebHardPauseJS.swift(632): 1-220, 220-440, 440-632
- WapleRender/HDRBloomPyramidPass.swift(476): 1-240, 240-476
- WapleCompatCore/ProfilePipeline.swift(399): 1-220, 220-399
- WapleCore/PointerHit.swift(342): 1-180, 180-342
- WapleCore/ProjectJSONParser.swift(307): 1-160, 160-307
- Waple/Surfaces/Workshop/RemoteTile.swift(266): 1-266
- Waple/SteamCmdDownloader.swift(240): 1-240
- WapleSaver/WapleSaverView.m(204): 1-204
- WapleRender/DXT5Decoder.swift(182): 1-182
- WapleRender/ArtworkColors.swift(149): 1-149
- Waple/Surfaces/Installed/FilterPopover.swift(137): 1-137
- Waple/Shell/LibrarySection.swift(116): 1-116
- Waple/Surfaces/Workshop/WorkshopTabView.swift(89): 1-89
- WapleLibrary/FolderStore.swift(83): 1-83
- WapleRender/OggVorbis/VorbisTables.swift(70) · VorbisBitReader.swift(56) · WapleCore/WallpaperType.swift(45) · Waple/BaseAssetsWarningGate.swift(37): 각각 전문 1회 출력

정직성 메모 두 가지.
① 재시도 1회 있었다 — SceneRendererResources 를 340-700 으로 읽으려다 출력 크기 상한(~30KB)에 걸려 잘렸고, 그래서 340-560 부터 다시 220줄 단위로 읽었다. 340-560 이후 560 에서 이어 붙였으므로 **구멍 없음**(위 목록이 그 연속성을 보인다).
② 대조를 위해 버킷 밖 파일도 필요한 부분만 읽었다(전수 아님, 참고용): SceneRendererFrameEncoder.swift(:367-392 pooledOffscreen, :2451-2530 호출부, :2541-2600·2734-2830 applyEffect/라우팅), SceneRenderer.swift(:945-960, :1288-1300, :2370-2380, :2529), SceneRenderer3D.swift(:1205-1235), TexDecoder.swift(:87-180), LibraryFiltering.swift(:1-80), LibraryViewModel.swift(:200-230), WorkshopViewModel.swift(:130-230), SelectionPanelView.swift(:375-395), SidebarView.swift(선택 태그부), VorbisDecoder.swift(테이블 인덱싱 2자리), 동봉 WEAssets 셰이더 5개(hdr_downsample.frag · combine_hdr.frag · cursorripple_apply_force.frag ×2 · fluidsimulation_vorticity.frag ×2).