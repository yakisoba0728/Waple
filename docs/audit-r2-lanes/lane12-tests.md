# 레인 12 — 테스트 오라클 품질 (PR #8 `b883386e` 신규 테스트 중심)

작업 트리 `b883386e`, 읽기 전용. `swift build/test` 미실행(브리핑 규약).

## 0. 측정 도구와 그 정확도

전수 스캔용 Swift 파서를 스크래치패드에 만들었다
(`/private/tmp/.../scratchpad/lane12/parse.py` + `count2.py`).
멀티라인 문자열(`"""`)·raw 문자열(`#"…"#`)·주석·시그니처 안 클로저(`{ _ in nil }`)를
전부 걷어낸 뒤 중괄호 매칭으로 `func test*` 본문을 잘라낸다.

**교정 근거**: 이 파서가 세는 테스트 수가 정본 레시피(AGENTS.md:95)와 **정확히 4,016 으로 일치**한다.
(순진한 정규식 파서는 3,944~3,999 로 어긋났고, 그 오차가 곧 "본문을 잘못 잘라 단언을 못 본" 자리다.
아래 단언 0건 판정이 신뢰할 수 있는 이유가 이것이다.)

재현:
```
python3 <scratchpad>/lane12/count2.py     # → total: 4016
grep -rE '^[[:space:]]*(@[A-Za-z]+(\([^)]*\))?[[:space:]]+|(private|fileprivate|internal|public|open|final|static|class|nonisolated|override|mutating)[[:space:]]+)*func test' Tests/ --include='*.swift' | wc -l   # → 4016
```

헬퍼 체인은 **타깃(모듈) 단위**로 전이 폐포를 잡았다 — `assertClose`/`assertCompiles`/
`assertConvention` 처럼 XCTAssert 를 감싼 비-test 함수를 호출하면 단언으로 센다.
모듈별 직접 헬퍼는 81개뿐이고 전부 `assert*`/`expect*` 계열이라 과대매칭 위험이 낮다
(짧은 이름 `pixel`/`text`/`value`/`body` 는 확인했고, 헬퍼만으로 단언하는 테스트 35건은 전부
`assertConvention`·`assertVec`·`assertCornersMatch`·`assertCompiles`·`assertFinite`·
`assertRangesInside`·`assertMatrix`·`assertClose` 8종으로 수동 확인했다).

---

## 발견

### 🟠 F1 — PR #8 신규 테스트 `testPerspectiveFovIsClampedAtRenderConsumption` 은 빈 배열 3개를 서로 비교한다(FOV 클램프를 전혀 잠그지 못한다)

- **자리**: `Tests/WapleRenderTests/ScenePerspectiveOverrideFovRenderTests.swift:216-231`
  (PR #8 이 새로 추가한 파일 `--diff-filter=A`, 459줄 중)
- **근거/재현**:
  ```
  git show b883386e --stat --diff-filter=A -- Tests/ | grep Perspective
  sed -n '216,231p' Tests/WapleRenderTests/ScenePerspectiveOverrideFovRenderTests.swift
  ```
  테스트 본문(요지):
  ```swift
  let l = layer(perspective: true, originZ: 25)          // projH = 200
  let over   = quadVertices(l, perspectiveFov: 1_000)
  let nan    = quadVertices(l, perspectiveFov: .nan)
  let capped = quadVertices(l, perspectiveFov: 179.89999389648438)
  XCTAssertTrue(capped.isEmpty, ...)
  XCTAssertEqual(over, capped)     // ← [] == []
  XCTAssertEqual(nan,  capped)     // ← [] == []
  ```
  소비 경로는 `Sources/WapleRender/SceneRendererFrameEncoder.swift:677-684`:
  ```swift
  let fov = CameraMotion.clampedFovDegrees(perspectiveFov)
  let d   = SceneCameraMath.layerPerspectiveDistance(orthoHeight: projH, fovDegrees: fov)
  let clip = SceneCameraMath.layerPerspectiveClip(distance: d)
  let depth = d - originZ
  guard depth >= clip.near, depth <= clip.far else { return [] }
  ```
  산수(계산으로 확인 가능, 실행 불필요):
  | 입력 | 클램프 **있음** | 클램프 **없음** |
  | --- | --- | --- |
  | fov=1000 | d=200/(2·tan 89.95°)=0.0873 → depth=−24.9 <5 → `[]` | fov/2=500°, tan 500°=tan 140°=−0.839 → d=−119.2 → depth=−144.2 → `[]` |
  | fov=NaN  | 179.9 로 클램프 → `[]` | d=NaN → `NaN>=5` false → `[]` |
  | fov=179.9| → `[]` | → `[]` |
  즉 **`CameraMotion.clampedFovDegrees(...)` 호출을 SceneRendererFrameEncoder 에서 통째로
  지워도 세 배열이 전부 `[]` 라 이 테스트는 초록**이다.
- **왜 문제인가**: 이 테스트의 독트링이 명시적으로 주장하는 것이
  "클램프는 파서가 아니라 렌더 소비에서 일어난다 … `CameraMotion.clampedFovDegrees` 를
  실제 정점 경로가 사용해야 한다"(:219-220)인데, 그 배선이 오라클로 잠기지 않는다.
  클램프 함수 **자체**는 `Tests/WapleCoreTests/CameraMotionTests.swift:143-148` 이 리터럴로 잠그고
  있으므로, PR #8 이 새로 얹은 것은 오직 "소비부 배선" 인데 그게 공집합 비교다.
  기계적 확인: 전 4,016개 중 "이미 empty/nil 로 단언된 값을 다시 `XCTAssertEqual` 의 피연산자로
  쓰는" 자리는 이 한 건과 `JSONNumericsTagGateTests.swift:154`(부분집합 관계라 의도적) 둘뿐이다.
- **고치는 법(제안)**: `originZ` 를 클램프 결과가 클립 안에 드는 값으로 잡으면
  세 결과가 서로 다른 **실제 정점 배열**이 되어 비교가 살아난다.
  예: `originZ = -200` → 클램프시 d=0.0873·depth=200.09(통과), 미클램프 fov=1000 시
  d=−119.2·depth=80.8(역시 통과하지만 정점이 다르다) → 클램프 제거가 즉시 빨개진다.
- **기지 목록 대조**: 해당 없음(PR #8 이 새로 심은 자리).

---

### 🟡 F2 — PR #8 이 Metal 게이트 정본 수치 `파일 77 / 사이트 324 / 거주 575` 를 갱신하지 않고 **새 줄로 다시 찍었다**. 실측은 82 / 364 / 627

- **자리**: `.github/workflows/ci.yml:295`(PR #8 이 `+` 로 **추가한** 줄) ·
  `.github/workflows/ci.yml:421-431`(세는 법 정의) · `:595`
- **근거/재현**: ci.yml:421-424 가 세는 법을 명시한다. 그대로 실행하면
  ```
  grep -rlE 'XCTSkip[^(]*\([^)]*no Metal' Tests/ --include='*.swift' | wc -l                  # 82  (정본 77)
  grep -rcE 'XCTSkip[^(]*\([^)]*no Metal' Tests/ --include='*.swift' | awk -F: '{s+=$2}END{print s}'   # 364 (정본 324)
  grep -rlE 'XCTSkip[^(]*\([^)]*no Metal' Tests/ --include='*.swift' | xargs grep -cE \
    '^[[:space:]]*(@[A-Za-z]+(\([^)]*\))?[[:space:]]+|(private|fileprivate|internal|public|open|final|static|class|nonisolated|override|mutating)[[:space:]]+)*func test' \
    | awk -F: '{s+=$2}END{print s}'                                                            # 627 (정본 575)
  ```
  **부모 커밋에서는 정확히 맞았다** — 정본이 애초에 틀린 게 아니라 PR #8 이 썩혔다:
  ```
  git grep -lE 'XCTSkip[^(]*\([^)]*no Metal' 70a8a708 -- 'Tests/*.swift' | wc -l   # 77
  # 사이트 324 · 거주 575 도 70a8a708 에서 그대로 재현된다
  ```
  차이의 출처(정확히 +5 파일)는 PR #8 의 신규 파일 5개다:
  ```
  comm -13 <(git grep -lE 'XCTSkip[^(]*\([^)]*no Metal' 70a8a708 -- 'Tests/*.swift' | sed 's/^70a8a708://' | sort) \
           <(grep -rlE 'XCTSkip[^(]*\([^)]*no Metal' Tests/ --include='*.swift' | sort)
  #  CameraParallaxRenderTests.swift · ParticleInstanceOverrideAnimationRenderTests.swift
  #  PerspectivePointerTargetTests.swift · Scene3DPointerTargetTests.swift
  #  ScenePerspectiveOverrideFovRenderTests.swift
  ```
- **왜 문제인가**: 게이트 동작(스킵 상한 100)은 여전히 옳지만, 그 상한을 정당화하는 **근거 숫자
  세 개가 전부 낡았다**. ci.yml 이 바로 그 자리에 "**세는 법을 함께 적는다. 값만 적으면 반드시
  썩는다**"(:419)라고 써 놨는데 같은 PR 이 그 규율을 깼다. 게다가 문제의 줄은 수정이 아니라
  **PR #8 이 새로 추가한 문장**이라 "썩은 값을 물려받았다" 로 변명되지 않는다.
  PR #8 은 같은 파일에서 실행 수 하한만 3875 → 4016 으로 래칫했고 Metal 인구 조사는 손대지 않았다.
- **기지 목록 대조**: H2(정본 인용 census 62 vs 66)와 **같은 부류지만 다른 자리**. C1 의 재발 아님.

---

### 🟡 F3 — "단언이 전무한 `func test*` 1건" 은 틀렸다. 추적되는 파일에 **2건 더** 있고, 둘 다 어디서도 실행되지 않으면서 4,016 하한에 집계된다

- **자리**:
  - `Tests/WapleRenderTests/SingleSceneProbeTests.swift:10` `testProbeSingleScene`
  - `Tests/WapleRenderTests/ThreeDV3CaptureTests.swift:11` `testCapture3DScenes`
  - 대조되는 정본 주장: `AUDIT-FULL-2026-08-31.md:147`
    "| 단언이 전무한 `func test*` | **1건** (`ZZTempSqrtVerify` …) / 3,886 |"
- **근거/재현**:
  ```
  python3 <scratchpad>/lane12/count2.py
  # total: 4016
  # zero-assert (XCTSkip NOT counted): 2
  #   WapleRenderTests/SingleSceneProbeTests.swift:10  testProbeSingleScene
  #   WapleRenderTests/ThreeDV3CaptureTests.swift:11  testCapture3DScenes
  grep -c XCTAssert Tests/WapleRenderTests/SingleSceneProbeTests.swift   # 0
  grep -c XCTAssert Tests/WapleRenderTests/ThreeDV3CaptureTests.swift    # 0
  ```
  두 파일 모두 캡처 결과를 `NSLog` 로만 흘리고 단언을 하나도 하지 않는다
  (`SingleSceneProbeTests.swift:52-58`: `NSLog("[Probe] \(id) luma=…")`).
  게다가 **영구 스킵**이다 — 게이트가 CI 어디에서도 세팅되지 않는 환경변수다:
  ```
  grep -nE 'WAPLE_PROBE_ID|WAPLE_3DV3|WAPLE_REAL_PKGS|WAPLE_BASE_ASSETS|WE_ROOT' .github/workflows/ci.yml   # 0건
  ```
  (`ci.yml` 이 세팅하는 WAPLE_* 는 `WAPLE_GOLDEN_BOOTSTRAP` 하나뿐이다.)
  H1 자체는 **해소 확인**: `ZZTempSqrtVerify.swift` 는 워킹트리에 없고 `git status --porcelain
  --untracked-files=all` 이 완전히 비어 있다(추적/미추적 모두 0).
- **왜 문제인가**: 감사 문서가 "오라클 품질 매우 양호 / 단언 0건은 1건뿐" 이라고 결론지은 근거표가
  틀렸다. 실제로는 H1 시점에 **3건**(미추적 1 + 추적 2)이었고, H1 을 지운 지금도 2건이 남아
  `XCTSkip` 으로 통과 집계된 채 4,016 하한을 떠받친다 — 하한 여유가 0 이라 이 2건을 정리하면
  census 게이트가 곧바로 빨개지는 구조이기도 하다.
- **기지 목록 대조**: H1 의 **재발이 아니라 미완결** — H1 이 지목한 파일은 사라졌지만
  "단언 0 개발 하네스가 테스트 타깃에 있다" 는 부류는 그대로 남았고, 감사가 그 모집단을 1건으로
  과소 집계했다.

---

## 스캔했지만 발견 0건인 항목(다음 라운드 시간 절약용)

1. **단언 0개 `func test*`** — 4,016 전수. F3 의 2건(둘 다 개발 하네스) 외에 **0건**.
   PR #8 신규 141개 중 단언 0 은 **0건**.
2. **항진 단언** — `XCTAssertTrue(true)` · `XCTAssertFalse(false)` · `XCTAssertEqual(x, x)` ·
   `XCTAssertNotNil(<리터럴>)` 전수 스캔 **0건**(PR #8 포함).
3. **`guard … else { return }` 조용한 탈출** — 14건 전부 **바로 앞줄에 같은 조건의 단언**이
   있는 "단언하고 나서 크래시 대신 빠져나가기" 패턴이다(예:
   `PuppetMDLAFramingTests.swift:122-123` `XCTAssertEqual(m.animations.count, 3)` 직후
   `guard m.animations.count == 3 else { return }`). 거짓 초록 아님.
4. **모집단 0이면 초록인 발견 루프** — 파일시스템/코퍼스 열거로 만든 컬렉션 안에만 단언이 있는
   테스트 **0건**. `UIConventionTests.assertConvention` 은 `XCTAssertGreaterThan(sources.count, 20)`
   로 모집단 자체를 먼저 단언하고, 허용목록이 스테일해도 실패하게 만들어 놨다
   (`Tests/WapleAppTests/UIConventionTests.swift:56-72`).
5. **자기 산수 단언(프로덕션 수식 재구현)** — 기계 스캔이 불가능한 부류라 두 단계로 봤다.
   (a) PR #8 신규·수정 테스트 전 파일에서 "기대값이 리터럴이 아니라 계산식/함수호출인
   `XCTAssertEqual`" 과 "`let expected/want/ref/... = <계산>`" 을 뽑아 후보를 6곳으로 좁히고,
   (b) 그 6곳만 정독했다. **거짓 초록으로 판정된 것은 0건**이고, 연쇄가 어디서 리터럴에
   닿는지까지 확인했다:
   - `ScenePerspectiveOverrideFovRenderTests:116,141` 은 `SceneCameraMath.layerPerspectiveScale/
     Distance` 를 중간값으로 쓰지만, 그 둘은 `SceneGeometryCameraMathTests.swift:240-268` 이
     **리터럴**(117.29039 · 126.31329 · 1.093205)로 따로 잠근다.
   - `ParticleMapSequenceOracleTests:595-601` 은 `SplitMix64` 를 7회 돌려 기대 lifetime 을
     만들지만 매핑은 테스트가 리터럴(`10 + r*10`)로 적고, `SplitMix64` 자체는
     `SplitMix64Tests` 가 골든값으로 잠근다. 잠그려는 대상이 **드로 횟수 7** 이라 성립한다.
   - `ParticleMapSequenceOracleTests:224` 의 `4 * want` 는 `want` 가 루프 표의 리터럴이다.
   오히려 PR #8 은 반대 방향의 수정을 했다 — `SceneWELightMathTests` 의 Schlick k 매핑을
   테스트 안 리터럴에서 **동봉 `common_pbr.h` 원문 파싱**으로 바꾸고, 살아 있는 MSL 두 레인
   (`Mesh3DShaders.swift`·`QuadShaders.swift`)까지 같은 파서로 대조한다
   (기지 `SnapshotTests`·`SceneRendererMeshCustomShaderTests` 물림에 대한 정면 대응이다).

   ⚪ **관찰(발견 아님)**: PR #8 이 새로 만든 프로덕션 함수 `SceneRenderer.projectedHitPolygon`
   (`Sources/WapleRender/SceneRendererFrameEncoder.swift:797`)과 `projectedBillboardHitQuad`
   (`Sources/WapleRender/SceneRenderer3D.swift:2118`) — 둘 다 부모 커밋에 없다
   (`git grep -c 'func projectedHitPolygon' 70a8a708 -- 'Sources/*.swift'` → 0) — 는
   등호 양변에 자기 자신이 오는 형태로만 비교된다
   (`PerspectivePointerTargetTests.swift:182`, `Scene3DPointerTargetTests.swift:355`).
   다만 같은 스위트의 `PerspectivePointerTargetTests.swift:54`
   `testPerspectiveImageHitFollowsProjectedTrapezoid` 가 **독립 계산**으로 교차검증한다 —
   테스트 로컬 `renderedContains`(:45-50)가 `quadVertices` NDC 삼각형에 대해 직접
   point-in-triangle 을 돌려, raw 사각형 안 · 렌더 사다리꼴 밖인 점을 찾아
   `pointerTargetCovers` 가 false 임을 단언한다. 그래서 연쇄가 닫힌다.
6. **랜덤 시드 미고정** — `Double.random`/`shuffled()` 는 `OggVorbisDecoderTests.swift:67-100`
   5곳뿐이고 전부 FFT 왕복 오차 허용치 비교(값 무관)다.
7. **전역 상태 복원** — 프로세스 전역 `setenv` 5곳은 전부 `defer { unsetenv }` 짝을 갖고,
   짝 없는 `unsetenv` 2곳(`Scene3DRenderCorrectnessTests.swift:119`,
   `SceneRendererMeshCustomShaderTests.swift:464`)은 "기본값 = 미설정" 을 만드는 의도적 베이스라인
   리셋이라 누수 방향이 아니다. `UserDefaults` 를 만지는 스위트는 전부 `suiteName` 격리이거나
   저장·복원 주석을 동반한다(`WorkshopDownloadTests.swift:28-32`,
   `SettingsViewModelTests.swift:261-266`). `SingleSceneProbeTests`/`ThreeDV3CaptureTests` 의
   `BaseAssetsSettings` 전역도 `oldBase` + `defer` 복원이 있다.
   유일한 비대칭은 `Tests/WapleCoreTests/SceneComboVisibleTests.swift:251-253` —
   `setenv("WAPLE_VIS_INHERIT","0",1)` 다음 줄이 `try SceneDocument.parse(...)` 이고 해제가
   `defer` 가 아니라 그 뒤의 평범한 `unsetenv` 라, 그 `parse` 가 던지면 같은 프로세스의 후속
   테스트로 env 가 샌다. PR #8 과 무관한 기존 자리이고 실패 경로에서만 발현하므로 ⚪ 관찰로 둔다.
   (macOS `swift test --parallel` 은 테스트 클래스마다 별도 프로세스라 클래스 간 경합은 아니다.)
8. **`try?` 로 실패를 삼킨 뒤 단언 없이 끝나는 테스트** — PR #8 이 얹은 `try?` 34곳
   (`git show b883386e -- Tests/ | grep -cE '^\+.*try\? '`)은 전부
   `try? FileManager.default.removeItem(...)` 임시 디렉터리 정리(28곳 — 그중 8곳이 `defer`),
   `try? setAttributes(.posixPermissions)`(1곳),
   `guard let re = try? NSRegularExpression(...) else { XCTFail/return nil }`(3곳),
   `(try? JSONSerialization.jsonObject(...)) != nil`(엄격 파스 가부를 **값으로 재는** 의도,
   `AssetJSONLenientTests.swift`), `try XCTUnwrap(try? ProjectJSONParser.parse(...))`(nil 이면 실패)
   이다. 실패를 삼키고 단언 없이 끝나는 자리 **0건**.

9. **PR #8 신규 테스트의 스킵 게이트** — 43개가 `XCTSkip` 을 쓰지만 전부 `no Metal`
   (이 맥·CI macOS 러너 모두 Metal 있음) 또는 `getuid()==0` 이라 실제로는 다 돈다.
   `ParticleEmitterControlPointTests.swift:158-165` 는 동봉 루트를 **못 찾으면 XCTFail**,
   오버라이드 트리에 파일이 없을 때만 스킵하도록 올바르게 갈라 놨다.

## 의심(확인 못 함 — 발견 아님)

- ~~`Scene3DRenderCorrectnessTests.swift:31` `throw XCTSkip("billboards 비어 있음")`~~ —
  **문제 없음으로 판정**. 바로 앞줄이 `XCTFail("billboards[\(index)] 없음 — 실제 …개 …")`
  (`:28-30`)이라 실패를 먼저 기록하고, 그 뒤의 `throw XCTSkip` 은 인덱싱 크래시를 피해
  그 테스트만 끊는 용도다. 실패 회피가 아니다.
- **실패 회피형 스킵 1곳(기존, PR #8 아님)**: `Tests/WapleCoreTests/ParticleRemapFlagsWiringTests.swift:121`
  `throw XCTSkip("remapvalue 가 Ex 경로로 안 갔다")` — 프로덕션이 `.remapValueEx` 로 안 가면
  **실패가 아니라 스킵**으로 끝난다. 같은 파일 `testBundledFlagsReachTable` 이
  `legacyTotal == 0` 을 따로 잠그므로 실제 사각지대는 좁지만, 게이트 방향은 환경 부재가 아니다.
  (돌려보지 않아 실제로 스킵되는지 확인 못 함 → 의심으로 둔다.)
- **F398 "고정시간 `RunLoop.run(until:)` 33사이트"**: 현재 트리의 `run(until:)` 는 55곳이고
  그중 앞 4줄에 `while/repeat/for` 가 없는(=폴 루프가 아닌) 곳이 16곳이다. 33 을 어떤 레시피로
  셌는지 BACKLOG:640 에 없어 대조 불가. PR #8 은 이 수를 바꾸지 않았다(부모에서도 55).
- **브리핑의 "3,886 → 4,016(+130)"**: 커밋 기준으로는 `70a8a708`=3,875 → `b883386e`=4,016,
  즉 **+141** 이다(ci.yml:680-683 도 "3875 → 4016 래칫" 이라고 적는다). 3,886 은 감사 당시의
  **더러운 워킹트리** 값으로 보인다. 순증 141 = 신규 함수 159 − 삭제 18.
