B1: 아래는 전 줄을 읽고 실제로 따져 본 뒤 문제를 못 찾은 자리다. 다음 라운드가 건너뛸 근거로 쓰라.

**SimplexNoise.swift(331줄 전부) — 인덱스 상한을 손으로 재계산했다.** `snoise2` 의 `perm[ii + Int(perm[jj])]` 최대 255+255=510, `perm[ii+1+perm[jj+1]]` 최대 256+255=511 < 512. `snoise3` 의 3중 중첩 `permMod12[ii+i2+perm[jj+j2+perm[kk+k2]]]` 도 i2/j2/k2∈{0,1} 이라 최대 511, `gi ≤ 11` 이 `grad3X/Y/Z[12]` 와 정확히 맞는다. `i & 0xff` 는 음수에서도 0..255. `fold`(±10⁶ 접기) → `fastFloor` 의 `Int(Float)` 트랩 불가(px+s 최대 ~2e6). `grad2` 의 `test al,0x3C` 이식(비트2..5, upstream 의 `h&7` 아님)과 합산 순서(`((n1+n0)+n2)*scale2`)가 주석과 일치. 상수 4개(f2/g2/g2x2/scale2)도 주석 값 그대로.

**BinaryReading.swift(32줄 전부).** 뺄셈 경계검사(`bytes.count - at >= 4`)가 오버플로 불가라는 주석의 논증을 확인했다(at>=0 을 먼저 보고 count>=0 이므로 `count-at` 은 최소 -Int.max, 표현 가능). `readCString` 의 `e < bytes.count` 종료 조건도 NUL 없는 꼬리에서 nil 로 떨어진다.

**AudioResponse.compute()(:141-203).** mode 별 인덱싱 상한을 실제로 따라갔다 — `count = (mode==2) ? right.count : left.count` 라 mode 1/3 은 `left[a]` 가 항상 안전하고 mode 2 는 `left` 를 아예 안 읽는다. `count==0` 이면 `hi = -1` 로 루프가 0회. `bin()` 이 NaN 을 0 으로, ±inf 를 [-1, count] 로 접어 `Int(Float)` 트랩을 막는다. `.peak`(러닝 max, mode3 ×0.5)와 `.average`(원시 float 분모, 0/비유한이면 0) 두 규약이 주석과 1:1. `audioAnnFloats` 의 숫자 리터럴 스캐너(지수 `e`/`E`, 부호 `+`)도 정상.

**ParticleControlPointFrame.swift(651줄 전부).** `clampIndex` 가 주석의 `cmovb`(부호 없는 **strictly-below**)와 일치함을 케이스로 확인(0..6 통과 · 7 이상 → 7 · 음수 → 32비트 절단 후 7). `frameUpdate` 의 우선순위(bit16 → bit0 → bit2 → childFeed → bit1/worldspace)와 슬롯0 예외(`test edx,edx`)가 주석 표와 일치. `childControlPointFeed` 의 "막힌 슬롯 영구 정체"(slot 을 안 올리고 particle 만 전진)가 주석이 기술한 실물 동작과 같다. `applyInstanceOverride` 의 두 센티널 독립 검사·`overrideBlockMask` 선행 게이트도 일치.

**PuppetModel.swift parseV0013(:166-377).** 신뢰 못 할 입력이 닿는 자리를 전부 짚었다 — vSize 관용 탐색이 후보를 iSize/maxIndex 로 교차검증하고, `iSize % 2`·`o + iSize <= count`·`maxIndex < vCount`·`msz == 64`·`boneCount < 100_000`·`tSize % 36`·`eventCount <= 4096` 가 다 있다. `animCount` 가 무경계 UInt32 지만 오프셋이 전진하지 않으면 `u32`/`cstr` 이 nil 을 내 break 하므로 무한루프 불가. `Bone` 뒤 제약 config cstring 소비(:277)도 주석의 실물 근거와 맞다.

**Scene3DLighting.swift(782줄 전부).** `resolveLights` 의 유한성 가드가 intensity/exponent/origin/angles/color/radius/position/forward 전부에 걸려 있고, kind!=directional 에만 radius>minimumRadius 를 요구하는 분기가 주석과 맞다. lightconfig 예산이 **가시성 판정 뒤** 소비되고 섀도우 예산이 별도인 것, `&&` 단락평가로 비-캐스터가 섀도우 슬롯을 안 먹는 것도 코드대로다. tube 의 axis 슬롯 재활용(cone 미사용)과 `packLights` 의 `slice*6` 인덱싱, CSM `validCascades`(엄격 상승) 게이트도 정합.

**SystemAudioSpectrumProvider.swift(554줄 전부).** `lock` 이 `running`/`accumulator` 만 지키고 콜백은 항상 메인 홉 뒤라는 `@unchecked Sendable` 근거가 코드와 일치. `SharedAudioCaptureCore` 의 generation 무효화 경로(add/remove/swapStreamIfCurrent/stopCaptureIfRunningLocked)에 락 밖 stopCapture 규율이 지켜져 있다. 주석의 "windowLength(2048) = 1365" 를 `AudioSpectrum.windowLength` 구현으로 재계산해 확인(0.33333334f × 2048 = 682.667 → 2048-682.667 = 1365.33 → 1365).

**SceneDocument.swift 의 나머지.** `SceneLightConfig.parse`/`uintField` 의 isUInt 게이트 + 마스크 절단, `blendModeVal` 의 0…32 범위 밖 → 0 낙하(Int32 트랩 방지), `claimObjectID` 의 first-wins 와 그것을 쓰는 네 빌더의 동기, `cameraParallaxRootsByOrder`/`worldParentTransform`/`hasInvisibleAncestor` 의 사이클 종료(visited · depth<32), `resolveUserBindings` 의 depth<32, `schemeColorVec3` 의 성분 부족 → 0 규약, `weBool`/`weBoolOpt` 의 CFBoolean 판별 — 전부 주석과 일치하고 결함 없음.

**나머지 파일들.** WallpaperProject `with(...)` 의 이중 옵셔널 규약과 `??` 함정 경고가 시그니처와 정확히 대응. PlaylistStore/PlaylistStateTimeStore 의 corrupt/loadFailed 이중 가드가 같은 모양으로 둘 다 있다(형제 대칭 확인). ZipImporter 의 심링크 미추종(`isSymbolicLink != true` 를 `isDirectory` 보다 먼저)과 배경 루트 발견 시 하위 중단. SceneRendererFinalizer 의 피라미드→단일레벨→hdrPost→rawCopy 4단 폴백. DeepReport 의 `pct` 0분모 방어와 ogg 시간예산 분모 보정. ColorRole/SystemPreference/OnboardingView/DisplaysView/WallpaperBridgeJS/MediaPoller/SceneRenderSettings — 로직 결함 없음(SceneRenderSettings 는 인용만 틀렸고 값·폴백 자체는 정확하다).

B2: 다음 라운드가 건너뛰어도 되는 자리를 구체적으로 적는다.

**ParticleSystem.swift** — (a) `parseInitializers`/`parseOperators`/`parse` 의 주입 기본값 상수는 전부 주석의 VA 와 값이 짝을 이루고 `injected/injectedInt/injectedVec3/injectedVec3OrScalar` 의 "부재에만 주입, 있는데 못 읽히면 0" 규약이 네 헬퍼(:3379-3398·:3489-3491)에서 일관된다. (b) `positionoffsetrandom` 의 octaves 32비트 절단(:2334-2336)은 판정·결과가 같은 값 위에서 돈다(r3 이 지적한 `mapSeqClampCP` 와 달리 여기는 고쳐져 있다). (c) `sheetFrameIndex`(:345-356)의 mirror 주기 `2N-2` 0분모는 `frameCount > 1` 가드가 막고, `Int(rounded)` 도 `rounded >= Float(Int.max)` 로 포화한다. (d) `saturatedCount`(:3446-3450)·`maxCount` 0/65536 클램프(:3115-3120)·자식 `maxInstances` 클램프(:3149-3152)는 전부 유한검사+포화로 트랩이 없다. (e) `bakeControlPointTargets`(:3333-3364)의 `authoredOffset` 비멱등 재베이크 방어는 실제로 닫혀 있다(:3232-3238이 첫 bake 전 값을 굽는다). (f) `RemapChannel` 의 `weIndex`/`hasOutputComponentSwitch`(6종)/`isNoOpOutput`(6종)은 선언부 주석의 목록과 원소 단위로 일치한다.

**ShaderPreprocessor.swift** — H1 탭 접기(:279-295)는 9종 화이트리스트 안에서만 접고 `sep` 에 탭이 있을 때만 재조립하므로 `# version` 류를 안 건드린다(검증: `#if\\t(X)`·`# ifdef\\tX`·`#  if X`·`#else`(인자 없음) 네 형태를 손으로 추적). `ExprEval` 의 우선순위 사슬(||→&&→|→^→&→==→rel→shift→add→mul→unary)은 주석 표의 실물 VA 순서와 단계 단위로 일치하고, 0 나눗셈·`Int.min / -1`·시프트량 [0,31] 밖·중첩 깊이 256 캡이 전부 막혀 있다. `weNumericLiteral` 의 16진 분기가 소수점 검사에 합류하는 것(:938, `#if 0x10.5` = 16)도 주석대로다. `hasIdenticalBranches`(:534-557)의 깊이 추적과 `#elif` 보수 반환도 정확하다.

**PropertyConditionEvaluator.swift** — `Tokenizer.readOperator` 가 미지 문자에서 `failed=true`+nil 을 내고 `tokens()` 가 그걸 nil 로 승격하는 경로, `parser.isAtEnd` 잔여 토큰 거부, `splitTopLevelTernary` 의 따옴표·괄호·중첩 삼항 깊이 추적, `isAssignmentExpression` 의 `== != >= <=` 제외, `replaceStringMethods` 의 `includes("")`=true 특례(:336) 전부 정확. `value(forReference:)`·`Parser.value(for:)` 의 `.value` 접미 제거 규약도 두 자리가 같다.

**PropertyAnimation.swift** — `firedMarkers` 의 Double 위상 누적(2^24 무한루프 방어)과 `iter < 4` 2차 방어선, `keyframes` 의 안정 정렬(동률 시 원래 인덱스), `handleEnabled` 의 true-부류 폴라리티(:557-561)와 `b()` 의 false-부류(:546)가 주석 표(:511-518)와 자리 단위로 일치. `wrapLooped` 의 세 단계(꼬리 버리기 → count<2 조기반환 → 덮기/붙이기)도 주석 1·2·3 과 그대로 대응한다(거짓인 것은 :357-361 Note 하나뿐).

**PlaylistRuntime.swift** — 화면별 상태 분리·FNV-1a 시드(`String.hashValue` 회피)·`restoreElapsed` 의 미부착 화면 자리 생성·`tick` 이 후보를 안 뽑는 계약(마운트 실패 시 셔플백 소모 방지) 전부 문서와 일치. 시각 기반 모드가 `nextCandidate` 를 불러도 백/커서를 안 건드리는 것도 확인.

**Snapshot.swift / SnapshotCompare.swift** — `diffRGBA`·`meanLuma` 의 `count/4*4` 정규화로 OOB 없음, `goldenVerdict` 의 세 지표(identical/relDiff/structureLoss)가 `SnapshotCompare` 단일 호출부로 모여 있어 수식 중복이 실제로 해소돼 있다. `runCompare` 의 90% 하한은 정수 산술로만 계산한다.

**PlaylistStateTime.swift** — `Reader.count()` 가 길이 필드를 남은 바이트로 상한하고 `string()` 이 그 위에 한 번 더 검사해 잘린 파일에서 트랩이 없다. `encode(elapsedByName:)` 이 키를 정렬해 같은 상태→같은 바이트를 보장한다.

**UserPropertyStore.swift** — `resolvingPresetResources` 의 절대경로 폐기(F357)가 root 유무와 무관하게 먼저 걸리고, `.none` 이 `rawDictionary`·`overrides` 양쪽에서 일관되게 드롭된다. 우선순위 사슬(defaults < preset < user)이 :31-35 에서 merge 순서로 정확히 표현돼 있다.

**PlaybackObservers / TileAccessibility / StatusBanner / VideoImport / SceneLivePresentationFix / main.swift / WapleLog / OffscreenCapture** — 여덟 파일 다 새 결함 0건. 특히 `StatusBannerModel.autoDismissAfterDelay` 의 취소 삼킴 수정(`try?`→do/catch)과 `TileAccessibilityModifier.activate()` 의 `.ignored` 반환은 주석이 설명한 함정을 실제로 막는다. `VideoImport.prepare` 는 복사·기록 실패 두 경로 모두 만든 폴더를 정리한다(F583 완결).

**재보고 안 한 기지 발견(자리 확인만)**: r3 M1(:419) · M5(:3474-3477) · M23(SettingsView:150) · M26(WallpaperGridView:183) · M55(ShaderPreprocessor:515) · M67(SelectionPanelView:95) · O5(:680) · O7(WallpaperProperties:285) · O17(SnapshotCompare:142) · O27(WallpaperGridView:285) · O28(StatusBanner:74) · lane03 F5(ParticleSystem:2327) · lane04 F2(ShaderPreprocessor:638·:647) · lane09(SelectionPanelView:308 생 transition) · full-audit-08-26(WallpaperGridView:399 Data-only 드롭 · SceneLivePresentationFix:47 env 1회 캐시 · VideoImport:41) — 전부 HEAD 에서 그대로 살아 있음을 확인했다.

**죽은 가지 하나(발견으로 안 올림)**: WallpaperGridView 의 우클릭 `적용 + 조작 창 열기`(:329-331)는 `supported` 게이트 밖인데 접근성 액션(:456-460)은 `supportedActions` 안이라 형태가 갈린다. `WallpaperType.isSupportedInMVP`(WallpaperType.swift:36)가 `.web` 을 항상 지원으로 두므로 `isWeb && !supported` 는 도달 불가다.

B3: 다음 라운드가 **이 자리들을 건너뛸 근거**로 구체적으로 남긴다. 전부 이번에 직접 따라간 것이다.

**SceneRenderer.swift (3,072줄 전수)**
- `teardown()`(:2982-3071) ↔ `mount()`(:1764-2339) 리셋 대칭: teardown 이 안 지우는 상태(`drawPlan`·`assetProbeCache`·`sceneQuality`·`clearEnabled`·`hdrBloomPyramid*`·`sceneZoom`·`camera*Anim`)는 전부 mount 가 무조건 덮거나(`applyCameraObjects`·:1885·:1910-1912·:1998·:2008) `assetBaseRoots` didSet(:1557)이 연쇄로 비운다. mount 중도 throw 시에도 `pipeline=nil`/`mtkView=nil` 이라 draw 가 :2504 가드에서 돌아선다. **누락 없음.**
- nearest 파이프라인 5종 빌드(:2088-2102): `pdesc` 의 `att.destination*BlendFactor` 를 선형 본체와 같은 순서(oneMinusSourceAlpha → one)로 되돌렸다 확인. 게이트 `noInterp && effects.isEmpty` 는 `GPULayer.noInterp` 선언 주석(:106)의 계약과 일치.
- `deliverGlobalMouse`/`clickLatch`(:998-1021), `dispatchPointerEvent` 의 `only:` 인덱스 공간(:518-533), `presentInteractionGeometry`(:693-709), `updateHover`(:719-741): 인덱스는 전부 `pointerTargets` 배열 위치로 자기정합적이고 teardown 이 `clickLatch.cancel()` 로 함께 비운다.
- `tickAnimationEvents`(:915-938) `guard f > prev`, `frameDelta`(:1358-1361) 0..50ms 클램프, `advanceCaptureCameraParallax`(:1335-1352) 의 targetTime<=0 특례 — 전부 주석대로.
- 주석의 파일:줄 자기인용은 **여전히 다수 어긋난다**(예 :50→`:2002`, :1405→`:723`, :1673→`:443`, :2559→`:1448`, :2792→`:1279`, :2993→`:1172`/`:836`). 그러나 이는 기지 **M10 재발/잔존**(`lane05-render-core.md:133-166` 이 신규 6 + 잔존 16 으로 이미 열거)의 같은 부류라 **개별 재보고하지 않았다.** 다만 lane05 목록에 없는 자리가 최소 6곳 더 있다는 사실만 기록한다 — 그 목록의 "잔존 16건" 은 하한이다.

**TexImage.swift (995줄 전수) — 신뢰 경계 파서, 경계검사 전건 통과**
- 헤더 6필드 경계(:562-569, maxDim 16384), 조건부 depth/previewColor 오프셋 42/46/50(:577-586), `b[13..<17]` TEXI 버전 판정이 `b.count>42` 가드 안에서 안전.
- `parseMip`: `imageCount<=1024`, `variantCount<=1024`, mip `w,h<=16384`, `comp>0 && q+4+comp<=b.count`, `dec<=512MB` — 전부 있음. `mipCount` 상한은 없지만 `readMip` 이 즉시 nil 을 내 루프가 곧바로 끊긴다(DoS 아님).
- `parseFrames`: `count<=4096`, `p+count*32<=b.count`(오버플로 불가), v1 i32 지오메트리 분기, 회전 프레임 퇴화 드롭.
- `findLastSignature`(:947-958)의 시작 인덱스 `count-sig-2` 는 **의도된 여유**다 — 그 −2 가 없으면 호출부 `b[ti+7]`(:884)이 범위 밖이 된다. `Model3D.findMagic`(Model3D.swift:1386-1400)과 "동형" 이라는 인용도 구조상 참(전진/후진만 다름, 둘 다 `m.count==1` 에서 안전).
- `spriteFrameIndex`/`sheetFramePair`/`sheetFrameQuadUV`: `safeInt` 경유, 음수 시간 랩, `min(n-1,cur+1)` 클램프 전부 주석대로.

**PlaylistTransition.swift (872줄 전수)** — `weAtoi` 포화(:229-241)는 `magnitude>ceiling` 조기 continue 로 Int64 오버플로 불가. `ShuffleBag.next`(:759-778)의 "playintro? n>2 : n>1 ⟺ 백 크기>1" 동치 손검증 통과. `PlaylistSortedCursor.next` 음수 커서 정규화, `PlaylistDayOfWeek.index` 의 `+6` 원점 보정(월=0 로케일에서 월→0/일→6) 손검증 통과. `TransitionTimeline.progress` 의 NaN→1.0 순서가 인용 디스어셈블(`comiss 1.0,p / jbe`)과 일치.

**PlaybackPolicy.swift (692줄 전수)** — `PlaybackEvaluator.evaluate`(:443-555) 축 순서 ①~⑨ 를 인용 VA 순서와 한 줄씩 대조: fullscreen 대입↔OR 동치(그 시점 마스크 0), unpauseAero/forcePauseAll 이 battery **앞**, sleepLatched 가 pause/mute 갱신을 통째로 막고 .max 를 내는 것까지 전부 일치. `allowedActions`(:156-163)의 `k(e,t,a)` 세 인자 재현(첫 인자가 sleep/battery/audio 에서 리터럴 false)도 일치. `VRAMHysteresis.update` NaN 경로(진입 실패 → 래치 유지)도 주석대로.

**AudioSpectrumProcessor.swift (315줄 전수)** — `reduce`(:301-314) 의 3분면 인덱싱을 j 구간별로 손검증(0..31→L, 32..63→R, 64..95→Mono; 16밴드도 동형). average32/16 이 average64 를 MAX 로 접는 순서(:171-175 주석의 반례 L=[1,0],R=[0,1])와 코드 일치. `ScriptResolution.validate`(:223-229) 마스크 `0xffffffcf` + `!=0x30` 두 게이트가 16/32/64 만 통과시킴을 비트로 확인. 소비처 `SceneRenderer.swift:2297-2336` 의 dt 클램프 [1/240, 0.1] 과 밴드 길이(16/32/64) 계약 양방향 일치.

**FluidSimulationPrecision.swift (244줄 전수)** — `binary16Bits` 준정규 분기의 `shift ∈ [14,24]`(주석 "1...24" 는 느슨하나 `shift-1>=0` 보장), `biased==0` 이 `exponent<-10` 으로 먼저 걸러짐, 자리올림 `0x400` → 최소 정규수 비트 처리, `unorm8Store` 의 NaN→`exactly:` nil→0 — 전부 확인.

**OggPageReader.swift (88줄 전수, 신뢰 경계)** — 세그먼트 테이블 경계(`segTableStart+nsegs<=count`), 바디 경계(`bodyStart+bodySize<=count`), lace 누적이 bodySize 를 못 넘음, `pos` 가 매 회 최소 +27 전진(무한루프 불가), continued 플래그 ↔ `current` 비어있음 대응, 시퀀스 gap 검사가 대상 스트림에만 걸림 — 전부 확인. 버전 바이트 검사만 비대상 스트림에도 걸리는데 이는 의도(주석 :50-53).

**WallpaperSchemeHandler.swift (384줄 전수)** — `parseRangeHeader`(:145-171) 6분기 손검증: suffix `bytes=-N` 의 `fileSize-n` 무오버플로, `end>=fileSize ? fileSize : end+1` 의 F570 오버플로 회피, `bytes=-`/멀티레인지/3토큰 전부 `.full` 폴백. 경로는 `WallpaperPathSecurity.containedFileURL` 단일 관문(:88-93)을 거치고 2026-08-28 의 `.isRegularFileKey` 게이트가 FIFO 블록을 막는다. zcompat 상대경로 키 정합 확인 — `url.path` 의 선행 `/` 는 `WebCompatPatch.normalizedRelativePath`(:153-160)의 `split(separator:"/")` 가 흡수하므로 패치가 죽지 않는다.

**PlaybackPolicyComposition.swift (229줄 전수)** — :124-125 의 "이 오버로드의 프로덕션 호출부는 0건" 주장을 grep 으로 검증: 프로덕션은 `AppDelegate.swift:1174` 의 `projects:conditions:global:` 하나뿐이고 `rendererCount:` 오버로드는 테스트 전용 — **주장 참**. 모니터 인덱스는 `monitorIndexByKey[...] ?? -1` 로 넘어가고 `PlaybackVerdict.isPaused` 가 음수를 false 로 떨어뜨린다.

**EffectShaders / ParticleShaders** — `waterripple` animationspeed 제곱 누락(r3 S2/R-2)과 `waterwaves` 유령 키 `perspective`/미독 `exponent`(r3 R-3), `nearestSource` 전역 치환이 주석 명시 집합보다 넓은 것(`full-audit-2026-08-26.md:252` ①)은 **전부 기지**라 재보고하지 않았다. `scroll` 포트는 WE `scroll.vert:18-20`/`scroll.frag:10` 과 정확히 일치(`frac((uv + t·signSq(speed))·repeat)`) — 이 자리는 clean.

**LibraryViewModel.swift** — `remove(_:)` 가 UserPropertyStore/VideoSettings 를 안 지우는 orphan 누수는 **r3 M65 로 기지**(그리고 `lane10-library-saver.md:214` 의 "orphan 누수 없음" 판정이 그 두 저장소를 안 세었다는 점까지 M65 가 이미 지적). 재보고하지 않음. `setProperty→reapplyIfCurrent→onApply`(:523-543) 배선은 `SceneRenderer.swift:1632` 의 주장과 일치. `filteredCache` 무효화가 `objectWillChange`(willSet 시점) 구독 하나인 것도 SwiftUI 갱신이 동기 재진입을 안 만드는 한 정합.

**나머지(RendererFactory·Model3DFormat·MonitorAssignmentStore·LibraryEntry·TileChrome·SectionHeader·PropertyDecoration·SmokeLaunch·SettingsViewModel·AudioSpectrum)** — 전수 정독했고 경계·비대칭·죽은 가드 어느 부류도 발견 없음. `RendererFactory` 가 `@MainActor`(:4)라는 사실은 `SceneRenderer` 의 `@unchecked Sendable` 문단(:26)이 근거로 삼는 전제이며 **실재 확인**. `Model3DFormat` 의 게이트 표(v≥17 AABB / v≥15 per-mesh flag / v≥21 트레일러 / v≥13 섹션 / bone≤128 / skinCount 0=0개)는 인용 VA 순서와 자기정합적이고 `materialCount` 의 >256 거부가 방어선.

B4: **근거를 실제로 따라가서 전건 맞았음을 확인한 자리(다음 라운드는 건너뛰어도 된다):**

1. **`WapleCore/ScenePBRLighting.swift`(1,011줄) — WE 셰이더 원문 인용 전수 대조, 드리프트 0.** 짝 저장소에서 직접 확인: `common_pbr_2.h` :4-7 FresnelSchlick · :9-16 PointSegmentDelta · :18-25 Distribution_GGX · :27-32 Schlick_GGX · :34-37 GeoSmith · :256 ComputePBRLightShadow · :263-270 falloff(HLSL 1.17549435e-38 / GLSL 6.103515625e-5) · :268-269 · :277 · :281 abs · :284-290 GRADIENT_SAMPLER half-Lambert · :292-297·:303-308 RIMLIGHTING · :298-313 specular · :301 NL · :313 return · :340-345 · :365-374 CombineLighting; `common_pbr.h` :9-16 · :29-30 · :40 · :64,75(step 0.01) · :84 역제곱 · :88-96; `common_fragment.h` :51-54 · :56-59 · :64,71 · :65,80(제곱) · :68-81 · :74(1승); `genericimage4.frag` :136-137 f0 mix · :139 g_SpecularTint; `generic2.frag`:6-9 기본 0/0(→404); `generic3.frag` :64 · :90 · :145 · :160 · :87-121; `base/model_vertex_v1.h`:207-210 = generic{,2,3,4}.vert 77/73/171/168 네 곳 동일식; `volumetricsfront.frag` :63-74 · :64 · :71 · :78-97(64/32/24/12 · 8/5/3/2) · :105-111 · :113 · :115-122 · :119 · :121 · :128-187 · :130 · :132 · :139 · :140 · :187 · :190; `volumetricsfront.vert`:11/:13(0.99 는 non-POINTLIGHT 만); `common_blur.h`:25-30 blur3 0.25/0.5/0.25. **유일한 드리프트는 기지 r3 M9(generic3.frag:132/152)** 뿐이다. 도수도 재현: `castvolumetrics` 동봉 0건(직접 grep), `spec/corpus/scene-schema.json` n=4/scenes=3/전건 True, 동봉 172씬(`scene.json` 171 + `gifscene.json` 1 — HDRBloomPass:61 의 세는 명령대로).

2. **`WapleCore/ScenePackage.swift`(559줄) — 코퍼스 도수 인용 전수 재현, 어긋남 0.** `corpus_scan/entry-name-frequency.tsv` 로 python3 재계산: distinct 11,338 · 출현 19,777 · scene.json 161 · ASCII 폴딩 충돌군 **14군** · Σmin(도수) **16** · 최대군 합계 6 · 인용 예시 3개(`models/Background.json`↔`background.json`, `materials/Layer 4.tex`↔`layer 4.tex`, `models/Sky/Sky.mdl`↔`sky/sky.mdl`) 전건 실재 · 대문자 보유 3,061(27.0%) · 비-ASCII 2,422(21.4%) · ASCII폴딩≠유니코드폴딩 **114**(전부 키릴, `materials/Спойлер Ч.tex` 포함) · 유니코드 충돌군도 14 · 유니코드 전용 충돌 **0** · 역슬래시/`..`/절대경로/선행`./`·`//`·양끝공백 **전건 0** · 최대 이름 **266 B** · 디렉터리 성분 없는 경로는 `scene.json` 하나(도수 161). `scenes-index.tsv`: has_scene_pkg 161 · 엔트리합 19,777 · 최대 pkg 712,246,205 B. `spec/formats/pkg.json` magicDistribution 14종/합 162. ("최대 깊이 6" 은 슬래시 기준 6·성분 7 — 기지 r3 O9 와 같은 축이라 재보고하지 않았다.)

3. **`WapleRender/LDRBloomPass.swift` + `HDRPostPass.swift` — WE 원문과 비트 수준 일치.** `downsample_quarter_bloom.frag`(4탭·×0.25·`saturate(scale-threshold)`·`2a−gray`·`max(0, a·strength·tint)`)와 `.vert:11-14`(`a_TexCoord ± g_TexelSize` 대각 4탭), 애노테이션 기본값 2/0.65/"1 1 1"(:6-8) 전건 일치. 13탭 가중치 7값(0.171834/0.156756/0.119007/0.075189/0.039533/0.017298/0.006299)이 `downsample_eighth_blur_v.frag:7-19`·`blur_h_bloom.frag:7-19` 와 **완전 동일**. 두 `.vert:12` `localTexel = g_TexelSize.{x,y} * 8.0` → `LDRBloomMath.horizontalStepUV`=2/quarterW, `verticalStepUV`=1/eighthH 로 양축 8 풀텍셀 등방. **함정 회피 확인**: `common_blur.h` 의 `blur13`(7탭 bilinear, 역산 σ≈2.02)은 **다른 커널**이고 `LDRBloomMath.swift:131` 이 이미 그렇게 경고한다. HDRPostPass: 동봉 `WEAssets/shaders` **137파일**(정확) · 톤커브 식별자 10종 전수 grep 히트 **1건**이고 그것이 `HLSL/dx11playlisttransition.vert:87` 의 `Move pieaces up and down`(오타 안의 "aces") · `combine.frag:13-15` · `combine_hdr.frag:43` 정확. HDRBloomPass:66-68 의 "LDRBloomPass·HDRPostPass 도 186 으로 함께 고쳤다" 주장은 **실제로 반영돼 있다**(양쪽 :33 / :21-23). 폐기 이중계수 358 은 HDRBloomPass 의 정정 기록 외에 소스에 생존 0건(기지 r1 M2 닫힘).

4. **`WapleRender/OggVorbis/VorbisDecoder.swift`(731줄) — 비신뢰 입력 경계 전수 확인, 발견 0.** floor1: xList 중복 거부(:237)가 `predictPoint` 의 `adx≠0` 과 neighbors low/high≥0 을 동시에 보증(xList[0]=0, xList[1]=2^rangebits 가 양끝) · finalY 채움 총량이 정확히 values−2 라 OOB 없음 · `drawLine` 의 `y & 255` 는 음수에서도 안전 · `renderFloor1` 말단 clamp(:553). residue: `cls[]=q % nClass < nClass`, `partsToRead<=0` 조기 반환 두 자리(:603·:639), `decodeVectorContig/Scatter` 의 `buf.count` 가드, `vqFlat[base+d] ≤ entries*dim−1`. **무한루프/0나눗셈 후보(classwords==0, dim==0)는 `VorbisCodebook.parse:52` 의 `dimensions > 0` 강제로 기각.** 상한 주석 수치 재계산: maxDecodedFrames 28.8M = 115 MB/ch ✓, maxReservedFrames 2^21 = 8.4 MB/ch = 43.7 s@48 kHz ✓. `pcm16WAV` 는 NaN/∞ 입력에서 Swift `min/max` 규약상 1.0 으로 떨어져 무트랩.

5. **`WapleCore/SplitMix64.swift` — Vigna 레퍼런스와 비트 동일.** 상수 0x9E3779B97F4A7C15 / 0xBF58476D1CE4E5B9(shift 30) / 0x94D049BB133111EB(shift 27) / 최종 shift 31 이 전부 일치하고, python3 재현으로 seed 0 → `e220a8397b1dcdaf, 6e789e6aa1b965f4, 06c45d188009454f, f88bb8a8724c81ec, 1b39896a51a8749b`(공인 테스트 벡터)를 확인했다. `nextFloat` 의 `>>40` 은 상위 24비트로 주석과 일치.

6. **`WapleCore/AudioSpectrum16.swift`** — `groupMax` 의 인덱스 산술이 `AudioSpectrum.bin`(:386-387)과 **글자 그대로 동일**하고 축약만 mean→max 다(주석 :31 이 맞다). r3 M11(44.1/48 kHz 밴드 경계)은 이 파일에 밴드 산술이 없어 해당 없음. n<binCount·NaN·−∞ 경계 전부 무트랩.

7. **`Waple/WorkshopAPI.swift`** — `isValidPublishedFileID`(:86)는 유일 소비처 `SteamCmdDownloader.swift:129`(steamcmd 진입)에서 실제로 걸리고, 그 게이트 뒤에 argv(`+` 명령 주입)와 `resultPathCandidates` 경로 조각 **두 소비처가 모두** 있다 — F840 주장 유효. `%d`(OSStatus=Int32) vs `%lld`(Int) 폭 일치. `.ephemeral` + `urlCache=nil` 이라 API 키가 URLCache 디스크에 남지 않음. `preview_url` https 강제. `lenient*` 3종이 CFBoolean 제외.

8. **`Waple/ScreenSaverController.swift`** — `ScreenSaverLogic.videoExtensions {mp4,mov,m4v}` 가 `Sources/WapleSaver/WapleSaverView.m:88` 의 `@[@"mp4",@"mov",@"m4v"]` 와 일치(주석이 요구한 대칭 성립).

9. **`WapleLibrary/LibraryStore.swift`** — 재임포트 시 `entry.rating` 이관(:139)이 `LibraryEntry` 9필드 중 **유일한 비복원 필드**를 정확히 덮는다(tags/contentRating 은 project.json 에서 되살아난다) — 형제 비대칭 없음.

10. **`WapleRender/SceneRendererFrameEncoder.swift`** — `engineUniform` 오프셋 표(count 84, 인덱스 0..83)가 주석 레이아웃과 정합 · `appendRibbon` 의 `u = i/(n−1)` 은 :236 `pts.count >= 2` 가드가 0분모를 막는다 · `quadVertices` Sutherland–Hodgman 클립 · `spriteSubrect` 엄격 클램프 · `particleSheetPair` 의 `safeInt` 가드 · unique FBO 예산 회계가 **버릴 때 먼저 차감**한다 · swap 이 포맷/크기/`fit` 봉투까지 대조.

**기각한 후보(같은 자리를 다시 파지 말 것):**
· `SceneRendererFrameEncoder.swift:2902` 의 무가드 `fboTex[source]` — `SceneRendererResources.swift:742` 가 `fboIndex` 를 `liveFbos.enumerated()` 로 만들고 :857 이 `fboSpecs` 를 같은 `liveFbos` 로 만들므로 `source < fboTex.count` 가 항상 참. `runtimeTexRes`(:84)의 가드와의 비대칭은 무해.
· `ScenePBRLighting.swift:205` 의 `Int(kindCone[i].x + 0.5)` 트랩 — 생산 경로는 `SceneDocument.forwardLightKind` 뿐이고 값이 {0,1,2,4} 라 도달 없음.
· `SceneWELightMath.finiteFalloff`(가드 없음) vs `SceneLight3D.finiteLightFalloff`(radius>0 가드) 비대칭 — :172-174 가 의도로 명시 문서화.
· `ScenePackage.parse` 의 `count >= 0`/`offset >= 0`/`size >= 0` — `i32` 가 무부호라 항상 참인 죽은 가드지만, 실제 게이트는 문서화된 대로 상한 검사(`blobBase + offset + size <= total`)가 담당.
· `FFmpegConverter.swift:177` 의 tmp 프로브 타임아웃 — 기지 r3 O13 과 같은 기전이라 접었다.
· `DeepScan.swift:780`(`scanWeb :741,744`)·`:805`(`SceneVideoLayer:109,209`) 좌표 드리프트 — r3 §4.1 이 `:805` 를 이미 **refuted**(사후 드리프트 = 기지 M10)로 판정.

B5: 다음 라운드가 **건너뛸 근거**로 구체적으로 적는다. 아래는 전부 직접 원문·수치를 열어 대조해 문제없음을 확인한 자리다.

**FluidSimulation.swift(전 458줄) — 이 버킷에서 가장 깨끗하다.** 인용된 GLSL 이 동봉 `effects/fluidsimulation/shaders/effects/` 8쌍과 **글자 단위로 일치**한다: curl.frag(L/R=.y·T/B=.x 스위즐, `R-L-T+B`, `0.5*`) · vorticity.frag(force 성분 뒤바뀜·`/(len+0.0001)`·`force.y*=-1`·`velocity+=force*dt`·`clamp ±1000` **뒤에** 에미터/커서가 더해져 재클램프 없음 = :119-121 주장 확인) · divergence.frag(경계 if 4개가 유일한 명시 경계조건) · clear.vert/frag(`pow(u_Pressure, 60*g_Frametime)` — 생 frametime) · pressure.frag(`(L+R+B+T-div)*0.25`, 중심값 C 를 읽고 안 씀) · gradientsubtract.frag(`0.5` 없음) · advection.frag(`dt=min(1/20,g_Frametime)` · `decay=1+decayFactor*m_Dissipation*dt` · `lowPass=step(len,u_Lifetime)*0.5` 가 **분모에 가산** · boundaryMask 는 DYE 전용 · 중력만 생 frametime · `constantSpeed.y*=aspect`) · normal.frag(전진차분·클램프가 `×refAlpha` **앞**) · vorticity.vert(`v_PointDelta.y=60/max(1e-4,u_CursorInfluence)` · `v_PointerUV.w` 이중 부호 상쇄 · `step(0,moveAmt)*0.5`). 에미터 비대칭(속도=`step`+aspect 주석처리, 염료=`smoothstep`+aspect 적용)도 원문 그대로다. `effect.json` 실측: 패스 18개, pressure 9회 복제(:60~:180), 인덱스 0-17 이 주석의 패스 번호와 일치, `m_Dissipation` 속도 0.2 / 염료 0.4(materials/effects/*.json).

**Mesh3DShaders.swift 의 WE 인용 전건 정확**(:599 열거 하나만 무효): common_pbr.h:6(FresnelSchlick 0.001)·:9-16(PointSegmentDelta)·:23(GGX 분모)·:36(GeoSmith 0.001), common_pbr_2.h:263-266(HLSL pow lane)·277/296(유한광 diffuse→감산 순서)·355/361(무한광 감산→diffuse 순서 = `rimAdjustsDiffuse` 비대칭의 근거)·294/305/342/353(step 0.001 게이트 4자리)·284-311·317-363·372, model_vertex_v1.h:207-210 + generic.vert:77/generic2.vert:73/generic3.vert:171/generic4.vert:168(ApplyAmbientLighting 인자 순서), generic4.frag:123/132/159/166, common_fragment.h DecompressNormal vs WithMask 의 바이어스 축 교차(`x=a*2-1,y=g*2-0.965` ↔ `x=a*2-0.965,y=g*2-1`)까지 원문과 일치. 도수 \"설치본 186 씬 전수에서 hdr:true 3건\"도 실측 일치(scene.json+gifscene.json 186개 / hdr:true 3 = shimmering_particles · razer_bedroom · previewthunderbolt; 동봉 172개 중 1).

**BuiltinShaderIncludes.swift** — `ApplyBlending` 33모드를 설치본 `common_blending.h` 와 식 단위로 전건 대조했다(0 Normal ~ 32). Glow=Reflect(B,A) · HardLight=Overlay(B,A) · Hue/Saturation/Color/Luminosity 의 base/blend 배치 · Tint=max(A.xyz)*B · 5/10 은 opacity 미적용 return · 31/32 는 자체 return — 전부 원문대로. rgb2hsl/hue2rgb/hsl2rgb 도 RGBToHSL/HueToRGB/HSLToRGB 와 일치. `saturate` 무조건 적용과 `sqrt(max(b,0))` 는 이미 기지 이탈(r3 M60 계열).

**AudioSpectrum.swift 상수·산식**(위 :295 한 자리 제외) — float32 재계산 전건 일치: gain `127×0.001×2×640=162.56`, `50×0.02f` 가 정확히 1.0(따라서 0/25/50/100/200 → 0/81.28/162.56/325.12/650.24), engineFFTLength 1920/2089/3840/4179/8359, windowLength 절삭이 차에 걸림(2089→1392 vs `n-n/3`=1393, 2048→1365 vs 1366), topFrequency 14677.03125, 32 kHz 상한 10650, B=627/683/314, 1:1 구간표 622→30·689→28·314→37·940→26 과 `B∈623…688 → 29`, 틸트 감쇠비 sqrt(1)/sqrt(0.002)=22.36.

**AppLogic.swift 교차파일 인용 전건 정확**: PlaybackObservers.swift :115/:119/:122(unfocused/maximized/fullscreen 마스크) · :68(defaultOutputDeviceIsRunning) · :61(isOtherAppPlaying) · :48(isOnBattery) · :128-131(vramPressure·external* 미배선 사유), WaplePolicy/PlaybackPolicy.swift:546(`if sleepLatched`), docs/handoff-2026-08-26b.md:116, docs/swarm-audit-2026-08-26.md:296. `PresetResolver` 의 `merging { _, presetValue in presetValue }` 도 주석의 \"프리셋이 이긴다\" 규약과 일치.

**TextScriptEngine.swift** — `lib.sceneScript.d.ts` 인용 ~30자리를 실물 d.ts 로 전수 대조해 **:2371 하나만** 선언이 아닌 `}` 에 착지(선언은 :2365; r3 M62 의 86건 스윕이 이미 센 12건 부류라 발견으로 올리지 않음), 나머지(1200-1209·1257-1261·1295·1555·1565·1577-1655·1586·1596·1601·1606·1611·1616·1621·1626·1632·1637·1642·1647·1652·1785·1790·1916·2039·2138·2175·2180·2185·2314-2329·2377·2451-2456·2487·2492·52-55·2123)는 전건 정확. `maxKeyBytes=1024` 도 `WebRenderer.maxBridgeStringBytes=1024` 와 실제 동수. **:226-230 의 \"라이브 채널이 덮어쓰는 것은 visible/alpha/origin/scale/angles 뿐\" 은 참이다** — `SceneRendererFrameEncoder.pushLiveSceneLayers`(:1450-1462)가 마운트 스냅샷 `sceneScriptBaseDescriptors` 에서 시작해 그 다섯만 덮고, `ScriptLayerReadBack`(:1395-1401)/`readBackScriptLayerState`(:1410-1443)도 정확히 그 다섯 필드만 읽는다(나머지 키는 마운트값 그대로 재기록 = 값 무변화).

**NowPlayingProvider.swift** 형제 SIGKILL 에스컬레이션 인용 3자리 정확(ZipImporter:69 · SteamCmdDownloader:203 · FFmpegConverter:206). `parse` 의 `f[0]`/`f[5]` 인덱싱은 비어있지 않은 입력·`count>=6` 가드로 상한 안전.

**AssetJSON.swift** 근거 실측 일치: 설치본 `projects/defaultprojects/fantasticcar/materials/car/glass.json:6` 이 정확히 `//\"cullmode\": \"nocull\",`, 동봉 `effects/**/effect.json` **122/122 전건 CRLF**(`isNewline` 수정의 근거 그대로).

**WallpaperCompatibilityAnalyzer.swift** — `currentPropertyTypes`(14) / `weBrowserPropertyTypes`(13) 의 양방향 차집합이 주석의 \"WE 에만 3종(volume·combolutfilters·divider) / Waple 에만 4종(checkbox·text·texture·label)\" 과 정확히 일치. 주석의 `파일:줄` 드리프트는 r3 M54(131자리 중 77 무효)가 이미 규모로 다룬 자리라 개별 보고하지 않았다.

**작은 파일 4종은 결함 0**: Typography.swift(56줄) · Motion.swift(82줄, `fade` 가 계산 var 인 것이 AppLogic:610 의 인용과 일치) · DesktopWindow.swift(39줄) · WapleProfiler.swift(97줄, FNV-1a 상수 0xcbf29ce484222325/0x100000001b3 정확).

**중복 확인 후 의도적으로 뺀 기지 발견**(다음 라운드도 다시 파지 말 것): QuadShaders `nearestSource` 치환 범위(주석 4 vs 실제 6) = `docs/full-audit-2026-08-26.md:177-178` + `docs/audit-r2-lanes/r3-recover-render3d.md:167`(R-4) · WapleCompat `printUsage` \"전 옵션(11개+--help)\" = `lane11-compat.md:149-157` · `NowPlayingProvider.swift:198` 의 `SceneVideoLayer.swift:58` 인용 = r3 §4.1 이 이미 refuted 로 판정 · SceneAudioPlayer 의 \"157\" 전파 = r3 M17 §4.2 · Model3DPose:129 U+FFFD = r3 O8 · NowPlayingBar:57/:288 = r3 H2/M21 · SceneAudioPlayer:9/:17 = r3 M17/H1 · AudioSpectrum:40 = r3 M11 · TextScriptEngine:338 ScriptLocalStorage 3분기 로드 = r3 H5 · TextScriptEngine:334 살균 = r3 C1 의 형제 대조군.

B6: **이번 라운드에서 근거를 실제로 따라가 재현했고 전건 일치한 것 — 다음 라운드는 여기를 건너뛰어도 된다.**

**1) ParticleSimulator 의 코퍼스 도수 주석 전건 재현(모집단 = 동봉 `Sources/WapleRender/Resources/WEAssets`, python 으로 전 json 파스, 파티클 시스템 289개).** 하나도 안 틀렸다:
- `:1382-1383` controlpointattract *"all 34"* + *"deletethreshold 전건 생략"* → 실측 34건 / deletethreshold 0건 ✅
- `:1499` vortex_v2 *"5건 전부 bit2 없음"* → 5건, flags = 3·2·2·(부재)·2 → bit2(=4) 0건 ✅
- `:863` maintaindistancetocontrolpoint *"3건 전부 variablestrength 5"* → 3건 전부 5 ✅
- `:1663` hsvcolorrandom *"5건 중 huesteps 적은 것 2건"* → 5건, huesteps = 6·12·(부재)×3 ✅
- `:1901` boids *"동봉 5건"* → 5건 ✅
- `:1748` positionoffsetrandom *"5건 전부 scale 0/부재"* → 5건, scale = 부재·0·0·0·0 ✅
- `:1723-1726` mapsequence* *"19선언(17파일)"* → around 7 + between 12 = 19선언 / 17파일 ✅
- `:241` 이미터 창 *"32건 중 30건"* → `duration` 키 보유 32건(0×30 + 1×2), delay-만 2건 = 총 34 ✅(모집단이 \"duration 키 보유\" 라는 읽기에서 정확)
- `:2156-2160` remapvalue inputrange *"키 출현 5건"* → 키 5개 / 파일 4개(150-200 · 300 · 50×2) ✅

**2) G-C2-03(오퍼레이터 블렌드 창)의 구현 범위 = 도달 범위.** WEAssets 에서 `blendin*`/`blendout*` 보유 오퍼레이터를 전수로 세면 turbulence 4 · capvelocity 3 · oscillatealpha 5 · oscillateposition 2 · remapvalue 2 · controlpointattract 1 = 17건이고, `BACKLOG.md:420-422`(D9)의 도달표와 **전건 일치**한다. ParticleSimulator 가 실제로 창을 곱하는 5종이 정확히 도달 있는 5종이다.
- 그래서 **`oscillatesize` 에 블렌드 창이 없는 것은 결함이 아니다** — 동봉 8인스턴스의 키가 {id,name,scalemin/max,frequencymin/max} 뿐이고 blend 키 **0건**이다. 다음 라운드가 이 비대칭을 재발견해도 도달 0 이다.
- `angularmovement`/`maintaindistance*`/`reducemovement`/`vortex_v2` 도 같은 이유(D9 대상 13종 중 도달 0).

**3) boids 서브샘플링 — 겉보기 반례가 진짜 반례가 아니다(재발견 방지).** `:1901` 이 *"동봉 boids 자산 5건이 전부 K==1"* 이라 적는데, 5건 중 `scenes/particleelementpreviews/boids/…/new_particle_system.json` 은 **maxcount 250** 이라 얼핏 반례로 보인다. 그러나 K 의 밑값은 maxcount 가 아니라 **최고수위**(`boidsPeak`)이고, 그 씬은 emitter `rate 10` · `lifetimerandom 5/5` · burst 키 부재라 정상상태 생존이 ≈50 < 100 → `n = 50/100 + 1 = 1`. 주장은 성립한다. 나머지 4건은 maxcount 16(dripping_water ×2 + 프리뷰 사본 2 = `:1864` 의 \"실사용 2종\").

**4) Model3D `vertexLayoutTable` 검산 6종 전건 손계산 일치**(`:482-484`, `:641`): 0x0f→48 · 0x0f|skinMask→80 · 0x09→20(+skin 52) · 0x0b→32 · 0x27→56 · Kirby 0x00800021→44(pos@0/boneIdx@12/TEXCOORD0 float4@28) · sl_puppet 0x0181000e→84. `vertexLayoutKnownBits` = 26엔트리 OR = **0x03FF_FFFF**(= 주석의 \"정확히 하위 26비트\") ✅. `:197`·`:738` 의 u16 969 / u32 17 = 986 도 자기정합 ✅.

**5) HDRBloomPass 의 [정정 2026-08-30] 모집단 산술 전건 일치**: 358 = 172 + 186 · 348 = 178+170 · 6 = 5+1 · 4 = 3+1 · 186−3 = 183 = 178+5. 그리고 주석이 적어 준 계수 명령을 실제로 돌렸다 — `find Sources/WapleRender/Resources/WEAssets -name 'scene.json' -o -name 'gifscene.json' | wc -l` → **172** ✅.

**6) 순수 산술 3종 수학 검증 통과(문제 없음).**
- `VorbisImdct`: DCT-IV 를 2L 점 IFFT 로 푸는 유도(g[k]=X[k]e^{iπk/2L}, S=2L·IFFT, z=Re{e^{i(πm/2L+π/4L)}S}) 와 TDAC 언폴드 3구간(`z[i+N/4]` / `−z[3N/4−1−i]` / `−z[i−3N/4]`)을 DCT-IV 반대칭 `z[2L−1−m] = −z[m]` · 주기 `z[m+2L] = −z[m]` 로 재유도해 전건 일치. `FFTPlan(n)` 크기도 호출부(VorbisDecoder.swift:714) 와 맞고, blocksize 는 `1 << (bsByte & 0x0F)` 라 power-of-two precondition 이 트랩될 수 없다.
- `FluidSimulationGrid`: `warmStartResidualPercent` 의 `(l+r+t+b−4p) − div` 가 `FluidSimulation.jacobiPressure = (l+r+b+t−div)/4` 의 부동점과 정합(수렴에서 0). 경계 반사 인자(-1/2/2/-1)도 `divergence(…)` 의 `<0`/`>1` 술어와 좌우/상하가 맞다.
- `PuppetPose.rotationQuaternion`: 주석의 slot3..6 식(a=key+0x14, b=+0x10, g=+0x0c)을 코드 변수(a=X/2,b=Y/2,g=Z/2)로 치환하면 4성분이 전건 일치(Rz·Ry·Rx).

**7) `BlendMSL`**: 숫자 case 32개(1‥32) + `default: r = B` 확인, 모드 표(:103-119)와 구현 전건 일치. r3 M60 이 정정한 좌표(`:171` we_colordodge · `:176` we_hardmix)가 현재 정확하다. `we_hue2rgb`/`we_hsl2rgb` 도 common_blending 표준형.

**8) 경계·상한 점검 — 신뢰경계 입력이 닿는 자리에서 새 구멍 없음.**
- `Model3D`: `materialCount ≤ 256`(Model3DFormat:143) · `meshCount < 100_000` · `boneCount ≤ maxBoneCount(128)` · morph `mc ≤ 4096`/`n1,n2 ≤ 1M` · `readU32Array` 가 `o + n*4 <= count` 사전검사 · `skinFieldsFit` 이 stride ≥ 52 를 보장해 `stride−40` 음수 불가 · `findMagic` 의 `for j in 1..<m.count where … { break }` 은 첫 불일치에서 정확히 빠진다.
- `ParticleSimulator`: 배열 첨자 전건이 병렬 크기(`acc`/`periodicStates`/`movementGravity`/`windowStates`) 또는 `indices.contains` 로 묶여 있고, `0..<max(0, …)` 로 음수 Range 트랩을 막는다. `PlaybackMasks.allMonitors` 의 `n == 32 ? .max : (1<<n)−1` 도 오버플로 회피가 정확.
- `TextRasterizer`: `maxRows` 절단 뒤 `midParagraph[count-1]` 은 `mr ≥ 1` 이라 항상 유효. 8192/바이트 상한 재시도는 `scale < 1` 또는 0.95 로 항상 축소해 종료.
- `WebRenderer`: 절대경로 리소스는 `userSelectedResourceOverrides` 정확 일치일 때만 허용(:681-688), 인-플라이트 상한 2 + 열거 20,000 + 브리지 문자열 1024B 가 세 축 모두 걸려 있다.

**9) 기지 O25 부류(파일명 없는 `:N` 자기참조)의 좌표만 제공 — 신규 발견 아님.** r3 O25 가 82파일 416자리 중 414 미검증이라 적었는데, 이 버킷에서 실제로 어긋난 것을 다섯 자리 확인했다: `WebRenderer.swift:386`(`:341-343`·`:351` → 실제 467-470·477), `HDRBloomPass.swift:206`(`:53` → 실제 82), `ParticleSimulator.swift:1615`(`:739`·`:755` → 실제 1229·1259) · `:1621`(`:1445` → 실제 emitterSpeed 기본값 자리 아님) · `:1917`(`:923` → 실제 1594). O25 의 규모 주장을 뒷받침하는 표본으로만 쓰고 별건으로 올리지 않는다. 마찬가지로 lane03 이 이미 잡은 `:911`·`:915`·`:1856-1857`·`:532` 와 r3 O10(`:1856` doc 주석이 `applyBoids` 헤더에 붙음)은 **현재도 그대로 남아 있다**(수정 안 됨).

**10) 선행 감사 좌표의 현행 유효성 확인(재조사 불필요).** lane03 의 `ParticleSimulator` 인용은 대부분 아직 맞는다 — `:2482-2491` fadeFactor ✅ · `:2484`/`:2488` ✅ · `:1783` ✅ · `:1797`/`:1816` ✅ · `:1303` ✅ · `:1219`/`:1251` ✅ · `:1024-1028` ✅ · `:943-947`(핫루프 O(N) 할당) ✅ · `:1991-1995` ✅. lane06 의 `HDRBloomMath.swift:131`·`:102-105` 도 현재 정확. r3 C1(`VideoTextureExtractor.swift:24` cacheKey 미살균) · r3 H1/lane07 L7-1(WebRenderer.videoFallback 음량) · r3 M14(배속) · r3 M2/M4(Model3D 전칭·모집단) · 2026-08-26 의 `PuppetPose:247`(single 음수 프레임) · `CameraMotion` effectivePathDuration(O2) · valueNoise3 데드코드 · `PlaybackPolicyRuntime:68` setPauseVRAM 호출부 0 — **전부 미수정 상태 그대로**임을 확인했다.

**11) 검토했다가 도달 0 으로 접은 후보 4건(재쟁점화 방지).**
- `hsvColorRandom` 의 `hueSteps >= 2` 게이트가 주석의 엔진 규칙(divisor = steps−1, 순환 span 이면 +1)과 steps==1 에서 갈린다 → 동봉 huesteps 값이 {6, 12} 뿐이라 도달 0. 인접 기지: full-audit-2026-08-26:173(\"divisor<=0 방어가 steps>=2 뒤 도달 불가\").
- `oscillatesize` 블렌드 창 부재 → 위 (2) 대로 도달 0(D9).
- `PropertyLabel.pretty` 가 HTML 만인 text 에서 빈 라벨을 낸다 → 인트리 project.json 170파일 · text 속성 161개 중 태그 제거 후 공백이 되는 것 **0건**.
- `VideoFallbackHTML.swift:44` 가 `waple-asset://wallpaper/` 를 리터럴로 박는다(형제 WebRenderer 는 `WallpaperSchemeHandler.scheme/.host` 사용) → 실제 값이 `"waple-asset"`/`"wallpaper"`(WallpaperSchemeHandler.swift:7-8)와 일치해 현재 무해.

B7: 이 버킷에서 **실제로 재현해 보고 맞았던** 것들이다. 다음 라운드는 아래 자리를 건너뛰어도 된다.

**코퍼스 도수 — 전건 정확 재현**
- `SceneRenderer3D.swift:2554` \"동봉 camera3D 12씬의 파티클 마운트 4건\" — 정확. 재현: bundled+install 의 `objects[]` 보유 JSON 을 훑어 `SceneDocument.parseCamera` guard(top-level `camera.{eye,center,up}` 존재 + `general.orthogonalprojection` 이 dict 아님)를 적용 → **정확히 12씬**(arsenal · dna_fragment · neon_sunset · ricepod · demon_core · fantasticcar · techno · audiophile + modeleditor/particleeditor3dscale 각 ×2), 그 12씬의 particle 마운트 **정확히 4**(demon_core · ricepod · neon_sunset · dna_fragment). 파서 관용도를 두 가지로 바꿔도 12/4 는 불변. `docs/re/particle-world-basis.md` §4·§6-5 와 일치.
- `SceneRenderer3D.swift:2667` \"3D 모델+파티클 동시 보유 씬 5개\" — 실측 6건 중 collisionmodel 이 동봉/설치본 중복이라 unique 5. 일치.
- `JSONNumerics.swift:249-254` 폭 실측 — **전건 재현.** 파일 수 3,655(동봉 WEAssets 1,698 + 설치본 assets 1,698 + 설치본 projects 259) ✅ · Int32 범위 밖 정수 **0** ✅ · |실수| ≥ 2^31 **0** ✅ · 음수 정수 **131** ✅ · 그 131 중 키가 `order` 인 것 **정확히 2** ✅. (숫자 리터럴 총수만 내 계수 33,429 vs 주석 33,753 — 파서 차이 범위, 결함 아님.)
- `EffectManifest.swift` 다수 — :28-29 동봉 128 / 설치본 135 ✅ · :55 합 263 ✅ · :177-178 `compose:true` 도달 정확히 2건(effects/refraction + 그 preview 사본) ✅ · :192 fbo 선언 55/55 가 format 보유 ✅ 그중 rgba8888 28 → 비-rgba8 27 ✅ · :357 동봉 55 + 설치본 57 = 112 ✅ · :375 `fit` 28건 · `fit`+`scale` 0건 · `width|height`+`scale` 0건 ✅ · :371-372 fit 값은 256(fluidsimulation 6장)·512(cursorripple 2장) 두 가지뿐 ✅ · :377-380 그 두 이펙트를 쓰는 씬 자리 정확히 4건 ✅ · :480-484 최상위 effect.json 46개 · 디렉터리명과 다른 replacementkey **7종 목록 전건 일치**(_empty→empty, blurprecise→blur_precise, blurradial→blur_radial, chromaticaberration→chromatic_aberration, depthparallax→iris, refraction→refract, watercaustics→caustics) ✅ · :504 엄격 파스 실패 27건의 분류(1 non-preview 트레일링 콤마 + 26 preview 줄주석) ✅ · :513 동봉 effect.json 전건 CRLF ✅ · :561 한 파일 최대 fbo 수 9(한 자릿수) ✅.
- `TexImage.swift:969` 의 440건 포맷 센서스(내 버킷 밖이지만 대조에 썼다) — 설치본 전체 .tex 440 = {0:257, 4:72, 9:60, 8:51} **바이트 일치**.
- `LDRBloomMath.swift` 전 인용 검증 — :74-75 설치본 bloomtint 저작 77건 전건 `"1.00000 1.00000 1.00000"` ✅ · :129-134 13탭 가중 7값이 `blur_h_bloom.frag` · `downsample_eighth_blur_v.frag` 두 파일의 **:7-19 에 정확히 그 순서로** 존재 ✅ · :65 `downsample_quarter_bloom.frag:6-8` = 세 유니폼 애노테이션 ✅ · :104 `…vert:11-14` = `a_TexCoord ± g_TexelSize` ✅ · :144-153 인용 GLSL 이 frag:15-25 와 문면 일치 ✅.
- `SceneGeometry.swift:220-221` \"코퍼스의 유일한 `perspective:true` 저작 사례 = presets/clock/preview3dclock/scene.json, origin.z = 0\" — 두 코퍼스 통틀어 정확히 1건, origin `"128.000 139.759 0.000"` ✅.
- `SnapshotPipeline.swift:84` 동봉 170/170(project.json 170) ✅ · :100-104 \"동봉 170건 중 167건은 세 단계 아래\" ✅(깊이 3 = 167, 깊이 2 = 3).
- `WebCompatPatch.swift:56`(전건 `/` 구분자) · `:167-168`(5건 중 4건 texImage2D 형태 — 파일 4/5 · 액션 16/17) ✅.

**형제 비대칭 사냥 — 누락 없음 확인(전부 대조했고 전부 정합)**
- 포인터 핀 규약(`SnapshotPipeline.swift:427-430` 이 \"SceneRenderer 를 직접 만드는 캡처 하네스는 생성 직후 `r.capturePointerUV` 를 대입해야 한다\" 고 못박음): `grep -rn 'SceneRenderer()' Sources/ Tests/` 로 전수 → 프로덕션 3자리(SnapshotPipeline:153 · ProfilePipeline:297 · AppDelegate:1507) **+ 테스트 하네스 3자리**(RealPackagesGroundTruthTests:74 · CaptureAudioDeterminismTests:88 · AudioProcessingDeclarationTests:60)가 **전건 대입**한다. 빠진 형제 없음.
- `SceneRenderer3D.swift:645` `_ = makeScriptEngine(...)` 는 **죽은 코드가 아니다** — `SceneRenderer.swift:279-293` 이 engine 을 `eventEngines`/`pointerEngineOwners`/`hoverEngineOwners` 에 append 하는 사이드이펙트가 있어 커서 훅이 실제로 배달된다. 주석의 \"소유 객체로 배달\" 계약 주장은 참.
- `AppDelegate.swift:230`(notice) · `:1905`(empty) 의 `isEnabled = false` 는 기지 M19(트레이 \"다음 배경\" 비활성 no-op)의 형제가 **아니다** — 둘 다 `action: nil` 이라 NSMenu 자동활성화가 어차피 비활성으로 둔다. M19 는 action 이 있는 `nextMenuItem` 한정.
- `TexDecoder.swift:362-384 draw()` 는 이미 `pixels.withUnsafeMutableBytes { CGContext(data: base…) }` 형이다(F840 형제 수정 반영 완료). `&px` UB 형 아님.
- `FavoritesStore.swift:12-40` 은 3분기 로드 규약(readStoreFile → loadFailed / corrupt → backupCorruptStoreFile → 실패 시 저장 스킵)을 **완전히 지킨다** — 기지 H5(7번째 저장소 `ScriptLocalStorage` 만 미준수)의 반례 아님.

**코드 결함 0으로 닫은 자리**
- `WorkshopViewModel.swift` 전 305줄 — `searchEpoch` 세대 검사가 search/loadMore 양쪽에서 정합(defer 의 `epoch == searchEpoch` 게이트 포함), 취소를 실패와 분리, `page` 를 반영 시점에만 증가시켜 pagination gap 원천 차단. 결함 없음.
- `PlaylistDriver.swift` 전 266줄 — `:207`/`:214` 의 `pendingAdvance?.token == token` 재확인이 동기 콜백에서의 이중 커밋을 막는다. `remainingAttempts` 감소가 동기·비동기 두 경로에서 일치(한 바퀴 한도 보존). 결함 없음.
- `AppDelegate.swift` completion 이중호출 없음 — `applyResolved` 는 동기 `.applied`/`.failed` 경로에서 completion 을 부르지 않고, 호출부(`applyCurrentSelection:617-623` · `continueAdvance`)가 정확히 한 번만 부른다.
- `WebCompatPatch.applied()` 무한루프 없음 — needle 빈 경우 조기 반환, insert 가 비어도 매 회 needle.count 바이트가 줄어 종료. `firstIndex` 경계(haystack < needle → nil) 정상.
- `PreviewThumbnail.swift:118-136` 의 \"취소된 task 의 늦은 완료\" 논증은 `@State` 공유 저장 규약상 정확(옛 struct 의 `url` 은 옛 값, `loadedURL` 은 현재 값 → 스스로 물러난다).
- `Scene3DMath.swift` · `GLSLTypeAdapter.swift` · `Metrics.swift` · `Space.swift` · `WallpaperRenderer.swift` · `LoginItemController.swift` · `WallpaperWindowLevel.swift` — 신규 결함 0(GLSLTypeAdapter:568 은 기지 M8, Scene3DMath:42 는 기지 O23, Metrics:19/:71 은 기지 M25/M22).

B8: 읽었고 실제로 검산해 문제를 못 찾은 자리들(다음 라운드가 근거를 갖고 건너뛸 수 있게 구체적으로).

**HDRBloomPyramidPass.swift 전문 — WE 원문 인용 5자리 전건 대조 일치.** `Sources/WapleRender/Resources/WEAssets/shaders/hdr_downsample.frag` 을 직접 열어 `:8-17 cubic()`, `:19-51 textureBicubic()`, `:61 uniform float g_BloomScatter; // {"material":"scatter","default":1}`, `:66-69` BICUBIC 4탭, `:71-74` 비-BICUBIC 4탭이 전부 주석대로임을 확인. 이식 정합도 식 단위로 대조했다 — `weCubicWeights`↔`cubic`, `weBicubic` 의 `texSize=0.5/t`·`c=tc.xxyy+(-0.5,1.5).xyxy`·`offset=c+(xc.y,xc.w,yc.y,yc.w)/s`·`offset*=invTexSize.xxyy`·샘플 4점 좌표(xz/yz/xw/yw)·`mix(mix(s3,s2,sx),mix(s1,s0,sx),sy)` 전부 원문과 동일. `hdrBloomExtract` 도 `combine_hdr`/`hdr_downsample` BLOOM 블록(:83-91)의 `soft=clamp(brightness-P.y,0,P.z); soft*=soft*P.w; contribution=max(soft,brightness-P.x); contribution/=max(brightness,0.00001)` 와 1:1(1e-5 == 0.00001). `hdrBloomCombine` 은 `combine_hdr.frag:21-25,40-41` 의 LINEAR==1 갈래(plain saturate)와 4탭 코너 집합까지 일치. `encode`(:205-233)의 격리 가드(포맷/치수/중복 텍스처 O(n²) 검사)도 경계 정상.

**DXT5Decoder.swift 3종 — 산술 재유도 완료(lane02:175 \"무결\" 재확인).** `color565` 비트복제 `(r<<3)|(r>>2)`/`(g<<2)|(g>>4)` 확인, 주석의 예시를 직접 계산해 검증(r=13 → 복제 107 vs 13*255/31=106 ✔, r=5 → 41/41 동일 ✔). BC3 알파 `((7-i)*a0+i*a1+3)/7` · 6단 `((5-i)*a0+i*a1+2)/5` + alpha[6]=0/alpha[7]=255 규격 일치, `abits` 6바이트=48bit vs 최대 시프트 45+3 ✔. BC1 3색 모드 `(c0+c1)/2` + 인덱스3 투명, BC2 니블×17, 세 함수 모두 `w,h∈(0,16384]` 가드 + `blocks.count >= bx*by*blockBytes` 가드로 오버플로·OOB 없음.

**VorbisTables.swift — 수치 검산.** python 으로 파스: 정확히 256 엔트리, 첫 1.0649863e-07 / 끝 1.0, 이웃 비 min/max = 1.0649856/1.0649857(순수 기하수열), `10^((i-255)·7/256)` 모델에 대한 최대 상대오차 5.25e-08 → stb_vorbis 정본 값과 일치. 소비처 `VorbisDecoder.swift:553`(`min(255,max(0,ly))`)·`:572`/`:577`(`y & 255`)은 음수 y 에서도 0..255 로 접히므로 인덱스 안전.

**VorbisBitReader.swift** — LSB-first 규약·EOP 부분읽기·`readSigned` 부호확장 모두 정합. `read(_:)` 의 `take == 32` 마스크 분기만 도달 불가다(`take = min(8-bitPos, n-got) ≤ 8`) — 무해한 방어 잔재라 발견으로 올리지 않았다.

**선행 감사 항목 두 건이 이미 고쳐져 있다(기지 목록 갱신용).**
· `swarm-audit-2026-08-26.md:198`/`:205` 와 `full-audit-2026-08-26.md:123` 의 \"`--profile` 메타 파스가 여전히 `.pkg` 만 연다(`ProfilePipeline.swift:254`)\" 는 **해소됐다** — 현행 `:267 guard let mpkg = mountPackage(folder)` 이고 `:254-266` 이 그 수정을 기록한다. `mountPackage`(:43-54)가 `ScenePackage.resolveMountSource` 를 타므로 언팩 코퍼스에서 동작한다.
· `swarm-audit-2026-08-26.md:200` 의 \"layoutContent 가 매 틱마다 messageLayer 를 0×0 으로 삼킨다(`WapleSaverView.m:134`)\" 도 **해소됐다** — 현행 `:182-186 layoutContent` 가 `NSMakeRect(32, midY-40, width-64, 80)` 로 실치수를 준다.

**FilterPopover.swift** — `:73-75` 주석(\"'전체'는 available 전체 선택 — LibraryFiltering 이 무필터로 간주\")이 `LibraryFiltering.swift:68`(`!criteria.tags.isSuperset(of: allTags)`)와 정확히 맞물린다. `ContentRatingLabel.pretty` 3종 + 폭/높이 상수도 정상.

**ProjectJSONParser.swift** — `:44-64` 의 확장자 분류표(1번 `0x140483850`, 4번 `0x140483810`, 6번 `0x1404837e0`)는 AUDIT-FULL-2026-08-31:3339-3355 가 이미 포인터 테이블을 직접 읽어 검증한 자리다(재검 불필요). `parseSupportsAudioProcessing`(태그 5 booleanValue 엄격성 = `EffectManifest.isJSONBool`), `parsePlaybackProperties`(빈 문자열 ≡ 부재), `parseNumber` 의 CFBoolean 선배제, `parseStringOrNumber` 의 공백-only 거르기 모두 주석대로다.

**SteamCmdDownloader.swift** — `progressValue` 의 `drop { !isNumber && != "." }` 는 "progress:" 접두를 정확히 벗긴다. `run(...)` 의 SIGTERM→유예→SIGKILL 에스컬레이션(:202-211)·`\r`/`\n` 양쪽 줄끝 처리(:222)·EOF 잔여 버퍼 재파스(:231)까지 정상. lane08:146 의 argv 경화 비대칭(`username` 무검증)은 기지라 재보고하지 않았다.

**WebHardPauseJS.swift 632줄** — 가상 타이머 재무장/pause 잔여시간 보존, AudioContext 세대 카운터(`controllerGeneration`)와 `resumeAfterPause` 3경로(직접 resume · pause 중 생성 · pauseAudioContexts), WAAPI/미디어 캡처 리스너, iframe state 브로드캐스트(`isDirectChild` 검증) 모두 `setPaused` 의 역순 해제와 대칭. full-audit-2026-08-26:244 의 \"실결함 미발견\" 판정을 이번 전수 정독에서도 뒤집지 못했다.

**ArtworkColors.swift · WallpaperType.swift · BaseAssetsWarningGate.swift · FolderStore.swift** — 4096버킷 히스토그램 키 산식(12비트 상한), `nextDistinct` 누적 거리 0.2, F840 형태(`withUnsafeMutableBytes` 안에서 CGContext 생성·드로잉 완결) 정상. `WallpaperType.from`↔`storageString` 왕복 무손실. `FolderStore` 는 `createFolder`/`move` 트림 대칭(F585)·`loadFailed`/`corrupt` 이중 게이트 정상이고, `removeFolder` 가 트림하지 않는 비대칭은 호출부(`LibraryViewModel.deleteFolder` ← 기존 폴더명, `SelectionPanelView:385` 가 이미 트림)에서 닫혀 있다. lane10:86-90 의 스키마 마이그레이션 방어 부재는 기지.

**억지로 채우지 않고 버린 후보 3건(다음 라운드가 다시 쫓지 않도록 근거를 남긴다).**
· `SceneRendererResources.swift:2212 childSeed = seed &+ li &+ 1` 은 형제/손자 간 시드 충돌을 만들지만(root i 의 child 1 == root i+1 의 child 0), 자식 `GPUParticleSystem.sim` 은 더미로 한 번도 스텝되지 않는다(`SceneRenderer.swift:2828`·`SceneRenderer3D.swift:2398` 이 `childOf == nil` 로 필터). 실시뮬 자식 시드는 `ParticleSimulator.swift:504` 의 혼합식이라 무영향 → **기각**.
· `RemoteTile.swift:252` 의 \"다시 시도\" 버튼이 `.disabled(!steamcmdAvailable)` 를 안 거는 비대칭(:229 는 건다)은, `WorkshopViewModel.steamcmdAvailable` 이 `let`(:40)이고 `download(_:)` 가 `:208` 에서 조기 반환해 `downloads[item.id]` 를 아예 안 만들기 때문에 `steamcmdAvailable == false` + `.failed` 조합이 도달 불가 → **기각**. `sweep:475` 의 `Int(percent)` 무가드(현행 `:177`)도 기각 상태 유지.
· `SceneRendererResources.swift:2389 validMipLevels` 가 `lv.blocks.count` 를 검증하지 않는 점은, 생산자 `TexDecoder.nativeBC`(:142·:161)가 레벨마다 `blocks.count >= ceil(w/4)*ceil(h/4)*blockBytes` 를 이미 확인하고 `makeBCTexture` 의 호출부가 그 하나뿐(`grep -rn makeBCTexture Sources Tests` → :2438 단독)이라 **기각**.