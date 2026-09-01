# 레인 2 — WapleCore 바이너리 파서(mdl/tex/pkg) 감사

- 대상 트리: `/Users/yakisoba0728/Documents/GitHub/Waple` @ `b883386e` (읽기 전용, 빌드 미실행)
- 짝 저장소: `/Users/yakisoba0728/Documents/GitHub/Waple-wallpaper-source` (manifest 대조만)
- 담당 파일 10개 전건 통독 + `git show b883386e` 로 PR #8 델타 대조.
- 발견 **3건**(🟠 1 · 🟡 2) + ⚪ 1 + 의심 1.

---

### [🟠] H6(`PuppetModel` MDLA 이벤트 블록 미스킵)은 **반만 고쳐졌다** — 클립 `flags` 를 읽고 버려서 `flags & 1` 의 0xC0바이트 레코드를 여전히 못 건너뛴다

- 자리:
  - `Sources/WapleCore/PuppetModel.swift:326` — `o += 16  // fps, frameCount, flags, boneCount`
    (오프셋 `o+8` 의 `u32 flags` 를 **읽지 않고** 커서만 민다)
  - `Sources/WapleCore/PuppetModel.swift:352` — `guard let eventCount = u32(o), eventCount <= 4096 else { break }`
    (본 트랙 직후를 곧바로 이벤트 카운트로 본다)
  - 정본: `docs/re/skeleton-animation.md:887` — “`flags & 1` 이면 클립 꼬리에 **0xC0바이트 레코드**가
    하나 더 붙는다(`0x140264fc9` `test byte [rbp+0xc0], 1` → `0x140264fdb`)”,
    `docs/re/skeleton-animation.md:894-895` — “`flags & 1` 의 0xC0바이트 레코드 경로도 이 블록(이벤트)으로 합류한다”
  - 같은 표가 `Sources/WapleCore/Model3D.swift:44` 에도 그대로 있다.

- 근거/재현(계산식 — 코퍼스 불요):
  1. `docs/re/skeleton-animation.md:816-817` 이 확정하듯 섹션 디스패치는 `strncmp(magic,"MDLA0006",**4**)`
     (`0x14026397d`)라 **MDLA0001 과 MDLA0006 은 같은 코드 경로**다. 그러므로 버전 게이트 밖 블록은
     MDLA0001 에도 전부 적용된다. `PuppetModel.swift:71` 주석도 그 사실을 인정한다.
  2. `0xC0` 레코드는 **버전 게이트가 아니라 클립 `flags` 비트0** 이 켠다. PuppetModel 은 그 비트를
     한 번도 보지 않는다(:326).
  3. 바이트 산수 — 클립0 이 `flags = 1` 인 MDLV0013:
     `u64 id | "idle\0" | "loop\0" | f32 fps | u32 frameCount | u32 flags=1 | u32 boneCount=1 |`
     `u32 trackFlags | u32 trackBytes | 트랙 |` **`0xC0(192)바이트 레코드`** `| u32 eventCount | … | 클립1`
     PuppetModel 은 트랙 끝에서 192바이트 레코드의 **첫 u32** 를 `eventCount` 로 읽는다.
     그 레코드의 기본값에는 `-1`(`0x140264ff7`)과 `1.0f` 가 깔린다(§6.2) — 첫 워드가 `0xFFFFFFFF`
     이면 `4294967295 > 4096` 이라 `else { break }` 가 돌아 **이미 파스가 끝난 클립0 까지 폐기되고
     이후 클립 전부가 사라진다**(`anims.append` 는 그 guard 뒤에 있다 — `PuppetModel.swift:370`). 첫 워드가 우연히
     4096 이하이면 레코드 내부를 `f32 + cstring` 쌍으로 소비해 임의 desync → 클립1 이하 유실.
     **이것이 정확히 H6 이 고쳤다고 주장한 실패 형태다**(“두 번째 클립부터 전부 유실”).

- 왜 문제인가: PR #8 은 “버전 게이트 밖 블록은 이벤트 하나”라는 전제로 구조 파스를 넣었는데,
  정본 표에는 게이트 밖 항목이 **셋**이다(항상 스칼라 트랙 배열 / `flags&1` 0xC0 / 이벤트).
  둘째 항목을 놓쳐 다중 클립 퍼펫이 **첫 클립부터 통째로** 사라지는 경로가 남았다.

- **형제 `Model3D` 와의 대조(브리핑 항목 1의 답): 같은 모양이 아니고, 그게 의도다 — 그러나 그
  차이 때문에 PuppetModel 만 깨진다.**
  `Model3D.parseAnimations`(`Model3D.swift:930-1024`)는 꼬리 길이를 계산하지 않고 **리싱크**한다
  (`Model3D.swift:991` `while d <= 256`). `flags&1` 이 켜져도 MDLA0006 의 꼬리는 최소
  `35 + 192 = 227`, 다음 클립의 `u64 id` 8바이트를 더해 `235 ≤ 256` 이라 **리싱크가 그대로
  넘어간다**. 즉 `Model3D` 는 이 블록에 무감하고, 구조 파스로 전환한 `PuppetModel` 만 취약해졌다.
  PR #8 은 한쪽을 더 정밀하게 만들면서 그에 상응하는 관용을 넣지 않았다 —
  **비대칭이 해소된 게 아니라 방향이 바뀌었다.**
  (패치안: 트랙 끝에서 이벤트 카운트를 읽기 전에 `flags & 1 != 0` 이면 `o += 0xC0`. 또는
  `eventCount` 가 상한을 넘으면 `break` 대신 이 클립의 이벤트만 포기하고 `Model3D` 식 리싱크로
  다음 클립 헤더를 찾는다.)

- 도달: **미측정**. 설치본 `.mdl` 28개에는 MDLS/MDLA/MDAT/MDMP/MDLE 매직이 0건이고
  (`docs/re/skeleton-animation.md:807-809`) 워크샵 코퍼스가 이 컨테이너에 없다. 파스 순서가
  엔진과 갈린다는 것은 코드 + §6.2 로 **확정**이고, 그것을 켜는 실물 파일의 존재만 미확인이다.
  회귀 핀도 이 구멍을 못 잡는다 — `Tests/WapleCoreTests/PuppetMDLAFramingTests.swift:22` 의
  `var flags: UInt32 = 0` 이 유일한 대입이고 그 값을 바꾸는 테스트가 **0건**이라
  (`grep -n "flags:" Tests/WapleCoreTests/PuppetMDLAFramingTests.swift` → 22행 하나),
  빌더(:84 `u32(c.flags, &d)`)도 0xC0 레코드를 절대 쓰지 않는다.
  **수정과 그 핀이 같은 불완전 모델을 공유한다.**

- 기지 목록 대조: **H6 의 미해결 잔여분**(“PR #8 이 고쳤다는데 반만 고쳤다”). 새 발견 아님을 명시.

---

### [🟡] PR #8 이 새로 쓴 주석 2곳 + 기존 1곳이 “게이트 밖 블록은 이벤트뿐”이라고 적어 정본과 자기 표를 동시에 반박한다

- 자리:
  - `Sources/WapleCore/PuppetModel.swift:71` — “MDLA 이벤트 블록은 버전 게이트 밖이라
    MDLA0001/0003…0006 모두 같은 형식이다.” (PR #8 신설)
  - `Sources/WapleCore/PuppetModel.swift:307-308` — “MDLA0001 은 버전 1 이라 v≥2..v≥6 게이트
    블록은 전부 꺼져 있다. **단** 이벤트 블록은 버전 게이트 밖이라 … 항상 소비한다.” (PR #8 신설)
  - `Sources/WapleCore/Model3D.swift:50` — “v≥2..v≥6 게이트 블록이 전부 꺼져 있어
    **꼬리가 이벤트 블록뿐이다**.” (PR #8 이전부터 존재)

- 근거/재현:
  `grep -n "항상  스칼라 f32 트랙 배열\|flags&1 이면 0xC0바이트\|항상  \*\*u32 이벤트수\*\*" Sources/WapleCore/Model3D.swift`
  → **35 / 44 / 45**. 즉 같은 파일이 게이트 밖 항목을 **세 줄** 나열해 놓고 다섯 줄 뒤 :50 에서
  “이벤트뿐”이라고 적는다. 정본 `docs/re/skeleton-animation.md:869`(항상, 스칼라 f32 배열) ·
  `:887`(`flags & 1` 0xC0) · `:892`(항상, 이벤트) 도 같은 셋을 센다.
  `PuppetModel.swift:307-308` 의 “단”은 나머지 둘을 배제하는 배타 표현이라 정본과 정면으로 어긋난다.

- 왜 문제인가: 이 세 문장이 위 🟠 발견의 **원인 문서**다. 다음 사람이 이 주석을 믿고 구조 파스를
  손대면 같은 구멍을 다시 판다. 브리핑의 최고 수익 부류(“문서·주석·정본이 코드와 어긋난 것”)에 해당.

- 기지 목록 대조: 해당 없음(M10 은 줄 번호 드리프트이지 내용 모순이 아니다).

---

### [🟡] M10 미해결/재발 — `TexImage.swift` 의 교차파일 줄 인용 2건이 현 트리와 안 맞고, 그중 하나는 PR #8 이 밀어냈다

- 자리 ①: `Sources/WapleCore/TexImage.swift:64` — “`SceneRendererFrameEncoder.spriteSubrect(:1834)`”
  - 재현: `grep -n "func spriteSubrect" Sources/WapleRender/SceneRendererFrameEncoder.swift` → **2407**.
    `git show b883386e^:Sources/WapleRender/SceneRendererFrameEncoder.swift | grep -n "func spriteSubrect"` → **1922**.
    곧 인용 `:1834` 는 PR #8 **이전에도 틀렸고**(1922), PR #8 의 `+785` 줄이 2407 로 더 밀었는데
    그 커밋이 인용을 갱신하지 않았다. 오차 **+573**.
- 자리 ②: `Sources/WapleCore/TexImage.swift:214` — “`ScenePackage.parse(:38)` 의 `let base = data.startIndex`”
  - 재현: `grep -n "let base = data.startIndex" Sources/WapleCore/ScenePackage.swift` → **117**.
    현 :38 은 `0x140276acc mov [r15], al` 어셈블리 주석이다. 오차 **+79**.
- (대조군: 같은 부류의 `Sources/WapleCore/ScenePackage.swift:407` → `WebRenderer.swift:657` 은
  **맞다**(`let keys: [URLResourceKey] = [.isRegularFileKey, …]`). 전수 드리프트는 아니다.)

- 왜 문제인가: 실동작 무영향이지만 두 인용 모두 “왜 이렇게 짰는가”의 유일한 포인터라,
  틀린 줄로 가면 근거를 못 찾고 규약(payloadRange 절대 인덱스 · spriteSubrect 클램프)을 되돌릴 위험.
- 기지 목록 대조: **M10 의 재발/미해결**.

---

### [⚪] PR #8 의 `[정정 2026-08-30]` 이 머리말 지침을 오인용했고, 같은 인용의 형제 3건은 그대로 남았다

- 자리: `Sources/WapleCore/Model3D.swift:222-223` — “~~`디컴파일 :1227-1457`~~ 은 폐기 코퍼스
  줄 번호라 **버렸고(이 파일 머리말 지침대로 VA·조건식만 남긴다)**”
- 근거: 머리말 `Model3D.swift:117-122` 는 정반대를 적는다 — “**지우지 않는 이유는** 그 옆의
  어셈블리 VA 가 내구성 있는 앵커라서다 … **새로** 인용을 다는 사람은 줄 번호 대신 조건식을 적어라.”
  즉 지침은 *신규* 인용에만 적용되고 기존 인용은 남기라는 쪽이다. 실제로 같은 트레일러를 가리키는
  `디컴파일 :1214-1457` 인용은 **:238 · :789 · :1051** 세 곳에 그대로 살아 있다
  (`grep -n "1214-1457" Sources/WapleCore/Model3D.swift`).
- 왜 문제인가: 규약 위반은 아니지만(머리말이 존치를 허용한다) “지침대로 버렸다”는 서술이 거짓이라
  다음 사람이 나머지 3건을 “빠뜨린 것”으로 오인해 일괄 삭제할 수 있다. 순수 문서 결함.
- 기지 목록 대조: 해당 없음.

---

## 의심(확인 못 함 — 발견으로 올리지 않는다)

- **“항상” 스칼라 f32 트랙 배열도 PuppetModel 이 건너뛰지 않는다.**
  정본 `docs/re/skeleton-animation.md:869` 은 그 배열을 버전 게이트 **밖**에 두고 개수를
  스켈레톤 필드 `[r15+0x28]`(= MDLS 꼬리 T3 레코드 수)에서 가져온다고 적는다.
  PuppetModel 은 MDLS0001 에 꼬리 파스가 아예 없고(`PuppetModel.swift:259-281` 이 본 레코드만 읽고
  곧장 :307 의 MDLA 매직 검사로 간다), 파일 머리말 `PuppetModel.swift:10` 이
  “`u32 다음섹션오프셋(=MDLA 위치, 실측 일치 검증)`”이라 적으므로 **2D MDLS0001 에 T3 꼬리가 없다
  → 개수 0 → 0바이트**로 보는 것이 합리적 추론이다. 그러나 정본 스스로
  `docs/re/skeleton-animation.md:914` 에서 “**(2D 퍼펫에서 0 이라는 것 자체는 여전히 미검증.)**”
  이라고 못 박는다. 그래서 확정하지 않고 의심으로 남긴다 — 0 이 아니면 위 🟠 와 같은 desync 다.

---

## 확인했지만 문제없던 것 (다음 라운드 시간 절약)

1. **PR #8 의 `FUN_` 이름 정정 4건 전건 정확.** 짝 저장소 `analysis/decompiled/manifest.json`
   (`total` = 7,748) 대조: `FUN_14009c500` ✓ · `FUN_14009c5c0` ✓ · `FUN_1400d7f90` ✓ ·
   `FUN_140261680` ✓ 가 **있고**, 툼스톤 처리된 `FUN_14009c5d0` / `FUN_14009c690` /
   `FUN_1400d8060` / `FUN_140261950` / `FUN_14009c630` 는 **없다**. 담당 파일에 남은 미존재 이름은
   전부 `~~취소선~~` 안에만 있다(재확인 불요).
2. **PR #8 의 `uv0` 게이팅 수정(`Model3D.swift:1345-1360`, 핵심은 :1348 `let uvOff = layout.map { $0.uv } ?? …` 와 :1360 비스킨 분기)은 산수가 맞다.** 주석의 실측 3종을
   테이블로 재계산: `0x03` stride 24 → `stride-8 = 16` = normal.yz ✓ · `0x07` stride 40 →
   `32` = tangent.zw ✓ · `0x01` stride 12 → `4` = position.yz ✓ · 스킨 `0x01800003` stride
   `12+12+16+16 = 56` ✓. `layout.map { $0.uv }`(`Int??`) 가 “테이블 없음”과 “테이블이 uv 없음”을
   실제로 가른다. `skinFieldsFit` 에서 `l.uv != nil` 를 뺀 것도 안전 — 그 분기의
   `layout?.boneIndices ?? stride-40` 는 `l.boneIndices != nil && l.weights != nil` 로 이미 보호된다.
3. **`Model3DFormat` 버전표가 정본과 정확히 일치.** `spec/formats/mdl-deep.json`
   `format.mdl.versionGates.관측버전` = {0004:8, 0014:15, 0016:8, 0017:3, 0019:18, 0021:17, 0023:382},
   합 **451** = `format.mdl.parseCoverage.파일수`. `Model3DFormat.swift:49-58` 표의
   설치본/코퍼스 분해도 전건 합치(설치본 8+15+1+4 = **28** = 짝 저장소 `find . -name '*.mdl' | wc -l` 실측 28).
   `Model3D.swift:5-8` 의 174(=100+5+69)와 6/2/7 은 **개별 워크샵 항목**의 부분집합이라 모순 아님.
4. **README 의 `Flags & 0x40`(volume) 서술은 현재 코드와 맞다.** 헤더 `texDepth`
   (`TexImage.swift:577-581`)와 mip 레코드 `depth`
   (`TexImage.swift:702-706`, 상한 128 = 엔진 `0x14015d3b4`)를 둘 다 읽고, `grep -rn "type3D" Sources/` 는 **0건**(있는 것은
   `.type2D`/`.type2DArray` 뿐) — “파싱은 되지만 3D 로 샘플링되지 않는다”가 그대로 참.
5. **신뢰 경계 전수 스윕 — 새 구멍 없음.**
   ① 길이·오프셋 산술: `BinaryReading.swift:12-14/19-21` 이 덧셈 대신 `count - at >= 4` 뺄셈형이라
   `Int` 오버플로 트랩 불가. 다른 자리(`q + 4 + vSize`, `blobBase + offset + size`)는 피연산자가
   전부 u32 상한(≈4.3e9)이라 64비트에서 안전.
   ② 인덱스 상한: `Model3D.swift:781`(`maxIndex >= vCount → nil`), `PuppetModel.swift:235`(동일),
   GPU 업로드 전 본 인덱스 클램프 `SceneRenderer3D.swift:345-347` · `Model3DPose.swift:108-109` ·
   `PuppetPose.swift:635`(앞의 `!matrices.isEmpty` guard 로 `count-1 >= 0` 보장) — 음수 인덱스 불가.
   ③ 헤더값 직결 할당: `meshCount < 100_000` · `materialCount ≤ 256` · `boneCount ≤ 128` ·
   `mc ≤ 4096`(모프) · `n1/n2/c2 ≤ 1,048,576` · `imageCount/variantCount ≤ 1024` ·
   `dec ≤ 512MB` · dims ≤ 16384 · TEXS `count ≤ 4096` — 전부 `reserveCapacity` **앞**에 있다.
   ④ 루프 종료: `parseMip` 의 `mipCount` 와 `parseSkeletonTail` T4b 의 4중 중첩(1024×4096×4096)은
   상한이 커 보이지만 회당 최소 18~21바이트를 **반드시 소비**하고 경계 초과 시 `nil` 로 빠지므로
   반복 수는 파일 크기로 상계된다. `Model3D.swift:991` 리싱크도 `d <= 256` 유한이고
   바깥 `while let h = tryHeader(o)` 는 매 회 `o` 가 최소 `이름+모드+16+8·bc` 만큼 전진한다(무진행 불가).
6. **DXT5Decoder 3종 무결.** `abits` 비트폭(BC3 6바이트=48bit, idx≤15 → `3*15+3 = 48`),
   BC2 니블(8바이트=64bit, `4*15+4 = 64`), `alpha[i+1]` 쓰기 범위(2…7), 팔레트 인덱스(0…3),
   `out` 인덱스(`(y*width+x)*4`, `x>=width||y>=height` 스킵) 전부 정확. 반올림 규약
   (`+3)/7`, `+2)/5`, 색은 floor)은 spec `format.tex.bcDecodeRounding` 과 일치.
7. **`MDMP0001` / `MDLE0002` 는 Waple 이 **본문을 파스하지 않는다** —
   `grep -rn "MDMP0001\|MDLE0002" Sources/` 가 `Model3D.swift:1246-1247`
   (착지 검증용 매직 접두 판정) 두 줄뿐이다. 즉 그 두 섹션은 공격 표면이 아니다.
8. **거짓 양성으로 걸러 낸 것(재조사 불요):** `eventCount <= 4096` 캡은
   `PuppetMDLAFramingTests.testNativeMDLAEventCountAboveSafetyLimitDropsClipBeforeAllocation`
   이 의도로 못 박아 둔 방어선 · `PuppetModel` 의 본 100k 상한은 `PuppetModel.swift:245-259` 가
   “의도적 발산”이라고 근거와 함께 기록 · `ScenePackage` 의 `e.offset >= 0` 류 사문(死文) guard 는
   `i32` 를 무부호로 읽는 의도적 이탈(`ScenePackage.swift:210-229`)의 결과이고
   `ScenePackageWEParityTests` 가 잠그고 있다 · `Model3D` 에 남은 `디컴파일 :NNN` 인용은
   머리말 `:117-121` 이 명시적으로 존치를 결정한 것(위 ⚪ 참조).
