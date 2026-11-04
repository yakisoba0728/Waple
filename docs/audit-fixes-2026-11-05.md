# 2026-11-05 전체 감사 후속 수정 기록

기준 커밋 `b2b4fbee92ead347fb8f7d9d212e83c6db859c60`의 전체 코드 감사에서 소스로 확정한 **51건**을 수정한 기록이다. 구현과 독립 소스 리뷰는 완료했다. 아래의 회귀 참조는 추가·보강한 검사의 위치이며, 전체 XCTest 실행 완료를 뜻하지 않는다.

원 감사의 `needs_validation` 세 항목(`CI-06`, `FORMATS-02`, `LIB-04`)은 이 51건에 포함하지 않는다. 알려진 미지원 기능이나 실물 WE와의 시각 일치를 전부 해결했다고 주장하지 않는다.

## 검증 상태

| 검증 | 현재 기록 |
| --- | --- |
| 51개 수정의 독립 소스·통합 리뷰 | 완료. 초기 리뷰의 반례를 반영한 후 재검토했으며, 최종 통합 리뷰에서 누락·중복·새 P1/P2 발견 0건 |
| Linux Core 공식 XCTest | 최종 Core 소스와 같은 불변 S3 스냅샷에서 2,176개 실행 · 스킵 31 · 실패 0 · 83.349초 |
| Python 도구·회귀 검사 | 157개 실행 · 스킵 1 · 실패 0 |
| 정본·기계 검증 게이트 | 26/26 통과. 정수 좁힘 355/355, shell 10개 구문 검사 통과, 동봉 WE 에셋 2,940파일 무결성 일치 |
| macOS SDK 26.5 native 전체 소스·앱·CLI 빌드 | 최종 불변 S4 스냅샷에서 debug·release 전체 앱+CLI 빌드 통과(release 82.95초). 현재 Sources/Tests/Resources와 동일 |
| macOS 테스트 타입체크 | 최종 S4 Sources/Tests와 동일한 입력으로 전체 7개 타깃의 XCTest 대역 모듈 타입체크 통과(rc0). 단언 실행 결과가 아님 |
| macOS 독립 native 회귀 실행 | 앱 상태 16건(행동 15 + 소스 배선 1), 3D/JSC 6건, 2D/Web 8건(스킵 0 · 단언 81, GPU 차이 픽셀·WebKit 포함), Library/Workshop·현지화 16건(스킵 0 · 단언 41) 통과. Core 14건·셰이더 16건도 동일한 최종 Core 소스에서 통과 |
| Compat·오디오 독립 native 회귀 | Compat의 기준선 보존·사용자 씬·실패 캡처 거부·URL 크기 캐시의 빈 파일→정상→빈 파일 사례, 실제 Ogg append 예산·잘못된 예산 사례 통과. MW-02는 실제 모듈·무음 PCM(음량 0) 드라이버 2/2 통과(스킵 0 · 단언 22 · 실패 0) |
| 정적 XCTest 메서드 수 | 정본 AGENTS 레시피로 기준 커밋 4,042 → 현재 4,127(+85 순증: 추가 이름 88 · 제거 이름 3). 기존 Keychain 3개는 update 우선 계약에 맞춰 개명·교체했다. 성공 update·없을 때 add·ACL 거부 검증을 보존했다. 실행 수와 구분하며 macOS CI 실측 전에는 실행 하한을 올리지 않음 |
| 전체 macOS XCTest 스위트 | 이 기록에서 실행 완료로 취급하지 않음. Xcode XCTest 실행 결과가 필요 |
| 실물 코퍼스 전체 픽셀 비교·데스크탑/다중 모니터·절전·실제 오디오 | 이번 수정의 소스 리뷰 및 합성 검사만으로 확정하지 않음 |

테스트 수와 CI 실행 하한의 정본은 [CI census](../.github/workflows/ci.yml)다. 최종 실행 전 추정 개수를 여기에 적거나, 독립 실행 드라이버 결과를 전체 XCTest 통과로 바꾸어 쓰지 않는다.

## 수정 원장

각 ID는 원 감사와 동일하다. 테스트 링크의 함수명으로 검색하면 줄번호 드리프트 없이 회귀 사례를 찾을 수 있다.

### 작업공간·캡처 도구 보호

| ID | 수정 내용 | 대표 회귀 참조 |
| --- | --- | --- |
| `CI-01` | 포인터 프로브가 지정 출력 루트를 삭제하지 않고 고유 하위 디렉터리에 기록한다. | [`test_pointer_preserves_existing_output_root`](../scripts/dev/tests/test_audit_tool_safety.py) |
| `CI-02` | 타입체크 작업공간의 소유 마커·빈 폴더·심링크를 확인한 뒤에만 사본을 갱신한다. | [`test_typecheck_refuses_unowned_existing_source_directory`](../scripts/dev/tests/test_audit_tool_safety.py) |
| `CS-01` | A/B 소스 패치·빌드·정리를 임시 worktree에 한정해 원래 작업 트리의 편집을 보존한다. | [`test_ab_cleanup_preserves_edits_made_during_build_on_success_and_failure`](../scripts/dev/tests/test_audit_tool_safety.py) |
| `CI-03` | 캡처 실패·빈 해시를 성공으로 취급하지 않는다. 시각 스윕도 요청한 씬·시각의 PNG가 모두 있어야 기록한다. | [`test_pointer_rejects_failed_or_empty_captures`](../scripts/dev/tests/test_audit_tool_safety.py) |

### 오디오

| ID | 수정 내용 | 대표 회귀 참조 |
| --- | --- | --- |
| `MW-01` | 채널 수를 포함한 전체 PCM 표본 예산을 예약과 실제 append 양쪽에 적용한다. 짧은 다채널 입력은 유지한다. | [`testPCMFrameLimitsShareOneBudgetAcrossChannels`](../Tests/WapleRenderTests/OggVorbisDecoderTests.swift) |
| `MW-02` | 정지 중 도착한 곡 종료는 다음 곡을 예약만 하고 재개 시 한 번 진행한다. stop은 예약을 버린다. | [`testPausedCompletionDefersTheNextTrackUntilResume`](../Tests/WapleRenderTests/SceneAudioPlayerTests.swift) |

### 앱 상태·재생목록·화면별 정책

| ID | 수정 내용 | 대표 회귀 참조 |
| --- | --- | --- |
| `APP-01` | 라이브러리에서 유일화한 ID를 마운트 해석까지 전달해 다른 배경의 속성 저장소를 읽지 않는다. | [`testLibraryIdentitySurvivesMountResolutionAndKeepsProjectMetadata`](../Tests/WapleAppTests/AuditAppStateRegressionTests.swift) |
| `APP-02` | 화면별 정책 pause를 재생목록 시계에 전달한다. mute만으로는 시계를 멈추지 않는다. | [`testPolicyPausedScreenFreezesWhileOtherScreenAdvances`](../Tests/WapleCoreTests/AuditPlaylistPauseRegressionTests.swift) |
| `APP-03` | 새 렌더러를 마운트하기 전 음소거하고 마운트 직후 pause를 적용해 정책이 잠시 풀리는 창을 막는다. | [`testPolicyMountMutesBeforeStartingAndPausesBeforeRestoringUserMute`](../Tests/WapleAppTests/AuditAppStateRegressionTests.swift) |
| `APP-04` | 선택·화면·요청 세대를 확인해 최신 스틸 캡처만 시스템 배경과 최종 캐시를 갱신한다. | [`testStillCaptureCompletionOnlyAcceptsLatestRequest`](../Tests/WapleAppTests/AuditAppStateRegressionTests.swift) |
| `APP-05` | Finder 데스크탑 호스트 면제는 화면 면적이 아니라 해당 화면의 위치와 크기 일치로 판정한다. | [`testLargeFinderBrowserOnMainScreenDoesNotMatchSmallOtherScreen`](../Tests/WapleAppTests/AuditAppStateRegressionTests.swift) |
| `APP-06` | 재생목록이 교체하는 화면 외의 렌더러는 재사용한다. 실패 롤백도 기존 렌더러를 해제하지 않는다. | [`testPlaylistSwapKeepsUnchangedRendererAndOnlyRetiresChangedRenderer`](../Tests/WapleAppTests/AuditAppStateRegressionTests.swift) |
| `APPV-01` | 스틸 요청마다 중간 프레임과 산출 경로를 분리한다. 오래된 요청은 자기 경로만 정리한다. | [`testStillRequestsUseIndependentIntermediateAndFinalPaths`](../Tests/WapleAppTests/AuditAppStateRegressionTests.swift) |

### 라이브러리·Workshop

| ID | 수정 내용 | 대표 회귀 참조 |
| --- | --- | --- |
| `LIB-01` | 적용 중인 항목을 제거하면 요청을 취소·무효화하고 늦은 성공이 제거한 ID를 다시 선택하지 못하게 한다. | [`testRemovingPendingCandidateCancelsApplyAndRejectsLateSuccess`](../Tests/WapleAppTests/LibraryApplyBranchTests.swift) |
| `LIB-02` | Keychain 키 교체는 update 우선으로 처리한다. 교체 실패 시 기존 키를 지우지 않는다. | [`testFailedKeyReplacementPreservesExistingKey`](../Tests/WapleAppTests/WorkshopAPITests.swift) |
| `LIB-03` | 심링크 동영상의 실제 정규 파일 바이트를 관리 폴더에 복사해 외부 링크에 의존하지 않는다. | [`testPrepareCopiesSymlinkTargetBytesIntoManagedFolder`](../Tests/WapleAppTests/VideoImportFixRegressionTests.swift) |
| `GAP-WORKSHOP-01` | API 키 삭제·새 검색은 응답 세대를 갱신한다. 옛 페이지 응답이 새 검색의 로딩 상태를 지우지 않는다. | [`testClearingKeyDiscardsPendingSearchAndLoadsReplacementKey`](../Tests/WapleAppTests/WorkshopPagingTests.swift) |

### 파티클·포맷·코어 검사

| ID | 수정 내용 | 대표 회귀 참조 |
| --- | --- | --- |
| `PART-01` | 자체 입자뿐 아니라 살아 있거나 향후 방출할 자손까지 확인해 자식 트리를 유지·회수한다. | [`testOneShotChildRetainsLivingDeathBurstGrandchildren`](../Tests/WapleCoreTests/AuditCoreRegressionTests.swift) |
| `PART-02` | 현재 worldBasis를 기존 자식과 손자 시뮬레이터에도 step 전에 전달한다. | [`testBasisChangesReachExistingAlwaysDescendants`](../Tests/WapleCoreTests/AuditCoreRegressionTests.swift) |
| `PART-03` | 초기 step(0)의 burst는 유지하되 이후 step(0) 조회는 remap·자식 상태를 재누적하지 않는다. | [`testZeroStepDoesNotReapplyPhysicalRemapsOrChangeSubsequentSteps`](../Tests/WapleCoreTests/AuditCoreRegressionTests.swift) |
| `PART-04` | 원샷 자식의 각 이미터가 첫 방출 기회를 얻을 때까지 기다린다. 앞 이미터는 다시 방출하지 않는다. | [`testOneShotChildrenWaitForEveryEmitterAndDoNotRestartCompletedEmitters`](../Tests/WapleCoreTests/AuditCoreRegressionTests.swift) |
| `FORMATS-01` | 애니메이션 재동기화의 이름·모드 C 문자열 읽기를 각각 정해진 길이로 제한한다. | [`testBoundedCStringReadsExactByteLimitAndRejectsLongTails`](../Tests/WapleCoreTests/AuditCoreRegressionTests.swift) |
| `GAP-CORE-01` | 웹 참조 파일은 남은 예산+1바이트까지만 읽고 초과 입력을 디코드 전에 거부한다. | [`testWebFeatureReadBudgetBoundsActualBytesRead`](../Tests/WapleCoreTests/AuditCoreRegressionTests.swift) |
| `render2d-03` | 애니메이션 값과 이벤트 마커가 대소문자·미지 모드의 loop/single/mirror 해석을 공유한다. | [`testAnimationMarkerModesMatchValueModeNormalization`](../Tests/WapleCoreTests/AuditCoreRegressionTests.swift) |
| `TESTCORE-01` | 코퍼스 부재만 skip한다. 존재하는 모델의 파스 실패·빈 본·부족한 클립은 테스트 실패다. | [`testRenneeMultiLayerBlendDiffersFromSingleClip`](../Tests/WapleCoreTests/PuppetBlendRealSceneTests.swift) |

### 셰이더 번역·전처리

| ID | 수정 내용 | 대표 회귀 참조 |
| --- | --- | --- |
| `SH-01` | fragment 전용 helper 의존성을 전이적으로 추적해 공용 wrapper도 올바른 하위 helper를 호출하게 한다. | [`testFragmentWrapperChainUsesFragmentCallee`](../Tests/WapleCoreTests/AuditShaderRegressionTests.swift) |
| `SH-02` | 강등 const의 전이 의존성을 원래 순서로 주입하고 파라미터·지역 변수의 이름 가림을 보존한다. | [`testTransitiveRuntimeConstDoesNotCollideWithHelperParameter`](../Tests/WapleCoreTests/AuditShaderRegressionTests.swift) |
| `SH-03` | 매크로 재정의 시 이전 숫자·텍스트·함수·flag 상태와 치환 범위를 함께 교체한다. | [`testRedefinitionReplacesFunctionAndSuspectState`](../Tests/WapleCoreTests/AuditShaderRegressionTests.swift) |
| `SH-04` | ambient 색 helper 캡처를 실제 엔진 표현식과 같은 float3로 선언한다. | [`testAmbientHelperCaptureKeepsVec3Type`](../Tests/WapleCoreTests/AuditShaderRegressionTests.swift) |
| `SH-05` | #if 매크로를 토큰으로 전개해 우선순위를 보존한다. 재귀 전체의 방문·출력 예산으로 과도한 전개를 거부한다. | [`testMalformedMacroBranchesConsumeTheSharedExpansionBudget`](../Tests/WapleCoreTests/AuditShaderRegressionTests.swift) |

### 2D 렌더·웹·미디어 전달

| ID | 수정 내용 | 대표 회귀 참조 |
| --- | --- | --- |
| `render2d-01` | 동적 텍스처 선택을 해상도 유니폼과 실제 바인딩에 함께 사용한다. | [`testDynamicEffectUniformsUseSnapshotAndBothArtworkSizes`](../Tests/WapleRenderTests/Audit2DWebRegressionTests.swift) |
| `render2d-02` | 텍스트 블렌드는 화면 전체 스냅샷 한 장을 순차 재사용해 오브젝트별 보유를 막는다. | [`testManyBlendTextsReuseSnapshotAndPreserveDifferencePixels`](../Tests/WapleRenderTests/Audit2DWebRegressionTests.swift) |
| `MW-03` | 미디어 폴러 stop/restart 전의 응답을 버리고 현재 세대 요청을 바로 진행한다. | [`testStoppedMediaPollDropsPendingFetch`](../Tests/WapleRenderTests/Audit2DWebRegressionTests.swift) |
| `MW-04` | 웹 문서 교체 전 디렉터리 순회 결과를 새 문서로 전달하지 않는다. 이전 작업도 용량 상한에 포함한다. | [`testDirectoryWalkCompletionDoesNotCrossRemount`](../Tests/WapleRenderTests/Audit2DWebRegressionTests.swift) |
| `MW-05` | 영상 폴백 URL을 HTML 속성에 넣기 전 엔티티·query·fragment 구분자를 올바르게 인코드한다. | [`testVideoFallbackDOMPreservesEntityFileNames`](../Tests/WapleRenderTests/Audit2DWebRegressionTests.swift) |
| `MW-06` | DOM key는 문자를, code는 물리 키를 각각 전달해 표준 키 바인딩을 유지한다. | [`testProxyDOMKeysHaveIndependentPhysicalCodes`](../Tests/WapleRenderTests/Audit2DWebRegressionTests.swift) |
| `TR-01` | 사용자 속성·영상 설정 테스트마다 UUID 저장 ID와 임시 경로를 사용해 병렬 삭제 경합을 없앤다. | [UserPropertyStoreTests](../Tests/WapleRenderTests/UserPropertyStoreTests.swift) · [VideoSettingsTests](../Tests/WapleRenderTests/VideoSettingsTests.swift) |

### 3D·공유 스크립트

| ID | 수정 내용 | 대표 회귀 참조 |
| --- | --- | --- |
| `D3D-01` | 모델·그룹의 thisLayer/thisObject를 자기 descriptor에 연결한다. 카메라가 만든 레이어와 배열 identity도 보존한다. | [`testNodeBuilderBindsModelsAndGroupsToOwnLiveDescriptors`](../Tests/WapleRenderTests/Audit3DScriptRegressionTests.swift) |
| `D3D-02` | PBR와 볼류메트릭 라이트가 부모 변환·가시성·방향 계산을 공유한다. | [`testVolumetricLightUsesSameParentTransformAndVisibilityAsPBR`](../Tests/WapleRenderTests/Audit3DScriptRegressionTests.swift) |
| `D3D-03` | 타이머는 등록한 스크립트의 사용자 오버라이드를 캡처하고 콜백 뒤 이전 전역 상태를 복원한다. | [`testTimerUsesOriginatingScriptOverridesWhenSiblingPumps`](../Tests/WapleRenderTests/Audit3DScriptRegressionTests.swift) |
| `D3D-04` | 같은 씬 시각의 형제 setRuntime 호출은 0ms 타이머 세대를 중복 진행하지 않는다. | [`testZeroDelayTimerAdvancesOnceForEachDistinctSceneTime`](../Tests/WapleRenderTests/Audit3DScriptRegressionTests.swift) |
| `D3D-05` | 3D 그룹의 저작 order를 보존해 공유 스크립트의 실행 순서를 유지한다. | [`testGroupOrderSurvivesProductionNodeBuilder`](../Tests/WapleRenderTests/Audit3DScriptRegressionTests.swift) |

### 캡처·호환성 CLI

| ID | 수정 내용 | 대표 회귀 참조 |
| --- | --- | --- |
| `CS-02` | 기존 캡처 라벨은 작업 시작 전에 거부한다. 모든 호출부도 실행별 출력 루트와 실패 전파를 사용하며 기존 기준선을 덮지 않는다. | [`testCaptureRefusesExistingBaselineBeforeStartingHelper`](../Tests/WapleCompatCoreTests/AuditCompatRegressionTests.swift) |
| `CS-03` | 프로파일·인벤토리·가시성 도구도 project.json이 선언한 씬 파일을 읽는다. | [`testInventoryParsesDeclaredSceneInsteadOfConventionalName`](../Tests/WapleCompatCoreTests/AuditCompatRegressionTests.swift) |
| `CS-05` | 유효한 크기·출력 경로와 실제 정규 파일 프레임 하나를 확인해야 프로파일 결과를 기록한다. | [`testProfileCaptureRejectsMissingFrame`](../Tests/WapleCompatCoreTests/AuditCompatRegressionTests.swift) |

### 검증·역공학 도구

| ID | 수정 내용 | 대표 회귀 참조 |
| --- | --- | --- |
| `CI-04` | release 로그를 확인하지 못하면 성공이 아닌 미확정 rc2를 반환한다. 정상 조회 뒤에만 검사 완료로 캐시한다. | [`test_missing_release_tally_is_unverified_in_all_modes`](../scripts/dev/tests/test_ci_status.py) |
| `CI-05` | 물리 XCTest 번들 수 대신 CI 실행 하한·실제 타깃 실행·실패 요약·프로세스 종료코드로 완주를 확인한다. | [`test_aggregate_and_separate_target_bundles_both_pass`](../scripts/dev/tests/test_audit_validation_tools.py) |
| `CS-04` | 발견한 OBJ/MDL 쌍 수뿐 아니라 실제 성공 비교 수도 하한을 충족해야 통과한다. | [`test_all_unsupported_pairs_are_not_a_success`](../scripts/spec/tests/test_rosetta.py) |
| `TAT-01` | 숫자 전환과 none/random/-2 특수 옵션 모두 로케일 키 존재를 검사한다. | [`test_missing_numeric_or_special_locale_key_fails`](../scripts/dev/tests/test_audit_validation_tools.py) |
| `TAT-02` | 섹션 마지막의 완전한 LEA/MOV/MOVZX 명령과 8바이트 포인터까지 검사한다. | [`test_last_aligned_pointer_in_minimum_and_full_sections`](../scripts/dev/tests/test_audit_validation_tools.py) |
| `TAT-03` | 명시 --binary를 기본 이미지·선택적 의존 검사 전에 해석한다. 명시 파일 부재는 실패한다. | [`test_explicit_binary_is_loaded_without_default_image`](../scripts/dev/tests/test_audit_validation_tools.py) |

## 캡처 호출부의 사용 변경

`CS-02`는 CLI만 고치면 기존 호출부가 지난 산출물을 재사용할 수 있어, 호출 스크립트와 안내문까지 함께 변경했다.

- `--capture <out>/<label>`은 기존 라벨을 덮지 않고 rc2로 거부한다. 실패한 새 산출물도 진단용으로 남으며 다음 시도에는 새 경로를 쓴다.
- `verify-plan-b12.sh`와 `verify-embedded-mips.sh`는 지정 출력 base의 `capture.XXXXXX/` 아래에 기존 SHA 라벨을 만든다.
- `rebaseline-golden.sh`, `probe-nondeterminism.sh`, `probe-session-nondeterminism.sh`, `probe-scene-repeat.sh`는 지정 base의 `run.XXXXXX/` 아래에서 원래 A/B/R1/단건 라벨 관계를 유지한다.
- 모든 캡처 호출은 실패 코드를 즉시 전파한다. 실패 뒤 과거 매니페스트를 읽어 비교·설치를 진행하지 않는다.
- 재베이스라인 설치 대상 `spec/golden/snapshot/baseline-<sha>`가 이미 있으면 rc1로 중단한다. 기존 기준선은 자동 삭제·교체하지 않는다. 새 캡처는 고유 run 디렉터리에 보존된다.
- 포인터 프로브와 시각 스윕도 각각 고유 `pointer.*`·`tsweep-*` 하위 디렉터리를 사용한다. 지정 base 자체를 삭제하지 않는다.

산출물 위치는 각 스크립트가 표준 출력으로 알려 준다. 세부 사용법과 예시는 [스냅샷 회귀 문서](snapshot-regression.md#로컬-캡처-스크립트의-출력-경로)에 둔다.

호출부 회귀는 [TestLocalCaptureRuns / TestCaptureProbeScripts](../scripts/dev/tests/test_audit_validation_tools.py)가 fake CLI와 임시 저장소로 실제 shell 경로를 실행한다. 동일 SHA 재실행, 기존 sentinel·기준선 보존, 비정상 캡처 종료코드 전파와 후속 분석 미실행을 확인하며, 이 검사를 실제 Metal·Swift 캡처 실행으로 세지는 않는다.
