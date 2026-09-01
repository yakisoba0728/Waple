# 레인 16 — 두 저장소에 걸친 정본(spec) 무결성

- 대상: `/Users/yakisoba0728/Documents/GitHub/Waple` (HEAD `b883386e`, 작업트리 깨끗)
  · 짝 `/Users/yakisoba0728/Documents/GitHub/Waple-wallpaper-source` (HEAD `1fac2a0c`, **작업트리 더러움 — 14파일 미커밋**)
- 읽기 전용으로 수행. 실행한 것: `validate.py`, `check_canon_generator_values.py`,
  `check_cited_address_census.py`, `measure_particle_fields.py`(전제조건에서 중단), `python3` 단발 계산.

---

## 0. 지시받은 5개 항목의 판정 요약

| 항목 | 판정 |
| --- | --- |
| 1. M11 (근거 커버리지) | **고쳐짐** — 661/1,211(55%) 미검사 → **261/1,210(21.6%)**. 기전·수치 아래 §1 |
| 2. H7 (`particle-fields.json` 미재생성) | **고쳐짐** — 정본 `:2557` = 실소스 `:2557`. 생성기는 코퍼스 요구로 직접 호출 불가, 대체 판정 §2 |
| 3. M25 | 정본은 고쳐졌으나 **쌍둥이 문서가 안 따라왔다** → 🟡 F2 |
| 3. M22 | Waple 고쳐짐(30/13/1/11). **짝 저장소는 13(≠11)로 갈려 있다** → 🟡 F3 |
| 3. M19 | 고쳐졌으나 **짝 저장소 미커밋 작업트리에만 존재** → 🟡 F4 |
| 3. M12 | **고쳐짐** — 모집단 분리 서술 + `g_Bones` 48 로 정정됨 |
| 4. 모집단 혼동 | 구체 자리 2건 발견 → 🟡 F5, ⚪ F8 |
| 5. `validate.py` 재고 | 직전 감사와 **완전 일치**(오류 0 · 경고 0 · 헤지 27 · 488/24/12) |

**PR #8 이 이 레인에서 새로 심은 것** (브리핑의 최우선 가치축): 정본 JSON 12개 · `scripts/spec/`
21개 · `docs/re/` 10개가 바뀌었다. 리터럴 드리프트는 `check_canon_generator_values`(생성기 40 ·
리터럴 1,246건 · 불일치 0)가 전면 덮으므로, 그 그물 밖인 **동적 값 786건과 산문**을 표적으로 봤다.
거기서 나온 것이 **F1**(동적 census 가 PR #8 자신의 편집으로 낡음)과
**F9**(새 전제조건 불변식의 구멍)이고, 나머지 게이트·자체검사 22개는 전부 초록이다(아래 §확인 7·8).

---

## 1. 기지 M11 — 기전 특정과 현재 커버리지 (고쳐짐)

**왜 349건이 빠졌는가(기전).** PR #8 이전 `validate.py` 에는 존재 검사 그물이 **하나뿐**이었다:

```
$ git show b883386e^:scripts/spec/validate.py | grep -n "검사 대상이"
45:# 리포 밖 참조(설치본 `Z:\...`, 코퍼스, wallpaper64.exe)는 머신마다 다르므로 검사 대상이
```

`repo_ref_path()`(현 `scripts/spec/validate.py:89`)는 `REPO_PREFIXES =
("spec/","Sources/","Tests/","scripts/","docs/",".github/","Package.swift")` 로 시작하지 **않는**
ref 를 전부 `None` 으로 버리고, `validate_doc` 의 검사 분기는 `rel is not None` 일 때만 돌았다.
짝 저장소 표기(`wallpaper64.exe`, `bin/…`, `assets/…`, `ui/…`, `shaders/…`)는 그 접두사에 하나도
안 걸리므로 **머신에 파일이 실재하든 말든 무조건 검사 생략**이었다. "휴대성(CI 에 설치본이 없다)"
이 이유였는데, 그 이유는 파일이 있는 머신에서도 검사를 끄는 이유가 되지 못한다.

**PR #8 이 무엇을 했나.** `we_ref_path()` (`scripts/spec/validate.py:104-146`) + 존재 검사 분기
(`:266-271`) + census 출력(`:493-497`)을 새로 넣었다. `WE_ROOT` 기본값은
`<repo>/../Waple-wallpaper-source/wallpaper_engine` 이고, `os.path.isdir(WE_ROOT)` 일 때만 검사한다
(CI 휴대성 유지).

**현재 커버리지(직접 계산).**

```
$ python3 scripts/spec/validate.py | tail -3
상태 분포: 확정 488 / 보고 24 / 추정 12
근거 경로: 리포 550건 존재 검사 · WE/짝 저장소 399건 존재 검사 · 비정형/외부 261건 (합계 1210)
오류 0 건 · 문서간 경고 0건 · 헤지 27건(묘비 면제 1건 별도)
```

| | 직전 감사 | 지금 |
| --- | ---: | ---: |
| 리포 상대경로 존재 검사 | 550 | 550 |
| 짝 저장소 존재 검사 | 0 | **399** |
| 검사 밖 | **661 (54.6%)** | **261 (21.6%)** |
| 합계 | 1,211 | 1,210 |

- 합계 1,211→1,210 은 PR #8 이 `spec/` 에서 evidence 1건을 줄인 결과다(§F1 이 그 부작용이다).
- 잔여 261건은 **구조적으로 검사 불가한 부류가 맞다**: 첫 토큰 히스토그램이 `워크샵`(119) ·
  `WE`(20) · `macOS`(9) · `코퍼스`(8) · `4991개` · `0x1401e53a0` 등 **산문·주소**다.
  261건 전부를 짝 저장소 루트에 조인해 봤을 때 실재하는 것은 **0건**이다(스크립트로 확인).
  즉 M11 의 "349건은 실재하는데 검사 안 된다" 는 잔여가 없다.
- `spec/README.md:20` 의 "`spec/` 의 evidence 중 `analysis/`·`corpus_scan/` 을 가리키는 것은 0건"
  도 재확인했다 — 실제 0건이다(정본 45문서 1,210 evidence 전수 grep).

재현:
```
python3 - <<'EOF'
import os,sys,json,glob,collections
sys.path.insert(0,"/Users/yakisoba0728/Documents/GitHub/Waple/scripts/spec"); import validate as V
rows=collections.Counter()
for p in glob.glob(os.path.join(V.REPO_ROOT,"spec","**","*.json"),recursive=True):
    rel=os.path.relpath(p,V.REPO_ROOT)
    if not V.is_canon_path(rel): continue
    for e in json.load(open(p,encoding="utf-8")).get("entries",[]):
        for ev in (e.get("evidence") or []):
            r=ev.get("ref")
            if isinstance(r,str):
                rows["repo" if V.repo_ref_path(r) else ("we" if V.we_ref_path(r) else "uns")]+=1
print(rows)
EOF
```

---

## 2. 기지 H7 — `particle-fields.json` 재생성 (고쳐짐)

- **생성기 직접 호출은 코퍼스를 요구한다**(지시대로 시도했고 결과를 적는다):

```
$ python3 scripts/spec/measure_particle_fields.py
[measure_particle_fields] 필수 입력(prerequisite)이 없다. 정본을 쓰지 않고 중단한다.
  - 워크샵 코퍼스: 'Z:\SteamLibrary\steamapps\workshop\content\431960' (WE_WORKSHOP 설정 필요)
EXIT=1
```
  (이 `specfmt.require_inputs` 가드 자체가 PR #8 이 넣은 것이다 —
  `scripts/spec/measure_particle_fields.py:517`. 종전엔 코퍼스 0 으로도 정본을 덮어썼다.)

- **따라서 전면 diff 는 불가**. 대신 코퍼스 없이 재계산 가능한 세 값(`consumeSite` ·
  `staleComment` · `evidence.file.ref`)을 PR #8 이 전용 게이트로 분리해 두었다
  (`scripts/spec/check_canon_generator_values.py:126-141`, `:209-235`) — 리터럴 대조에서
  "값 동적" 으로 빠지던 부류다. 그것을 돌렸다:

```
$ python3 scripts/spec/check_canon_generator_values.py
selftest: OK
[canon-generator-values] 생성기 40개 · 리터럴 대조 1246건 · 불일치 0건 …
EXIT=0
```

- 실소스와 직접 대조로도 확인:
```
$ grep -n "sys.def.flags & 1" Sources/WapleRender/SceneRenderer3D.swift
2557:        let worldspace = (sys.def.flags & 1) != 0
```
  정본 `spec/engine/particle-fields.json:199,219` 이 둘 다 `:2557`. 종전 `:2183`(무관한 `///` 줄)
  드리프트는 해소됐고, 이제 줄번호는 조건식에서 매 실행 되짚는다(`_flags_consume_lineno()`).
  `ParticleSimulator.swift` 가 PR #8 에서 +586 움직였는데도 여기가 맞는 것은 유의미하다.
- `staleComment` 도 하드코딩 리터럴 → 소스 실측(`flags_comment_staleness()`)으로 바뀌었다.
- CI 배선 확인: `.github/workflows/spec.yml:210` 이 이 게이트를 돌린다. 게이트가 아니면 무의미하다.

---

# 발견

### 🟡 F1 — PR #8 이 `spec/` evidence 를 바꿔 놓고 `binaries-fingerprint.json` 을 재생성하지 않았다 — 인용 도수가 246/341 → 실제 245/340 으로 갈렸다
- **자리**: `spec/binaries-fingerprint.json` `binary.fingerprints.why`(status **확정**) —
  `citations.wallpaper64.exe` · `reason`("341회 인용") · `citationsUnit`("종별 합(341)", "246 → 251")
- **근거/재현**:
```
python3 - <<'EOF'
import sys,os,json
sys.path.insert(0,'/Users/yakisoba0728/Documents/GitHub/Waple/scripts/spec')
os.chdir('/Users/yakisoba0728/Documents/GitHub/Waple')
import measure_we_binaries_fingerprint as M
c=M.count_citations([os.path.basename(t) for t in M.TARGETS])
print("재계산:", c['wallpaper64.exe'], sum(c.values()))
d=json.load(open('spec/binaries-fingerprint.json',encoding='utf-8'))
v=[e for e in d['entries'] if e['id']=='binary.fingerprints.why'][0]['value']
print("정본  :", v['citations']['wallpaper64.exe'], sum(v['citations'].values()))
EOF
# 재계산: 245 340
# 정본  : 246 341
```
  **PR #8 이 원인이라는 것을 커밋 전후로 직접 재계산해 확정했다** — 같은 레시피를
  `b883386e^` / `b883386e` 의 `spec/` 트리에 각각 걸면:

```
b883386e^  wallpaper64.exe=246  sum=341  evidence refs=1211
b883386e   wallpaper64.exe=245  sum=340  evidence refs=1210
```

  (`git ls-tree -r --name-only <rev> spec/` → `is_canon_path` 필터 → 각 evidence 의
  `ref`+`note` 에 파일명이 낱말 경계로 나타나는지. 낡은 값 246/341/1,211 이 커밋 전 트리에서
  정확히 재현되므로 레시피 동치성도 함께 확인된다.) 순 −1 을 만든 삭제는
  `spec/engine/mul-convention.json` 의 `"wallpaper_dev/…/A4-headers-blending-fog.md §1.4 —
  wallpaper64.exe strings 의 매크로 프롤로그에 `mul` 정의 0건…"` evidence 다.
- **왜 문제인가**: 이 항목의 존재 이유가 "정본이 WE 바이너리를 몇 번 인용하는지" 다.
  값이 `len()` 합이라 **동적**이라서 `check_canon_generator_values.py` 의 리터럴 대조에서
  "값 동적(f-string·변수 등) 786" 버킷으로 빠지고, 축소 가드는 양수→0 만 잡으므로
  246→245 를 못 잡는다. `check_cited_address_census.py` 가 같은 부류(주소 census)를 위해
  PR #8 에서 새로 만들어졌는데 **바이너리 인용 census 에는 형제 게이트가 없다.**
- **덤(같은 자리)**: `scripts/spec/measure_we_binaries_fingerprint.py:159`
  → `spec/binaries-fingerprint.json:114` 의 `population` 이 **"…evidence 객체 — 1,203개 중…"**
  으로 하드코딩돼 있다. 실제는 **1,210개**다(위 §1 census). 바로 두 줄 위 note 가
  *"citations 는 이 스크립트가 spec/ 정본을 훑어 매 실행 다시 센다 — 종전의 하드코딩 리터럴이
  아니다"* 라고 적는데, 그 분모가 하드코딩 리터럴이고 이미 낡았다.
- **기지 목록 대조**: 해당 없음(신규). M11 이 만든 census 축과 인접하나 별개 값이다.

---

### 🟡 F2 — M25 를 정본에서만 고치고 쌍둥이 문서를 안 고쳤다 — `shader-uniforms.md:820` 이 아직 폐기된 VA `0x1404875f3` 를 `g_Bones` 좌표로 제시하며, **같은 문서 :186 과 자기모순**이다
- **자리**: `docs/re/shader-uniforms.md:820`
  (대조: 같은 문서 `:186` · 정본 `spec/engine/uniforms.json:93`)
- **근거/재현**:
```
$ sed -n '820p' docs/re/shader-uniforms.md
| 이름 문자열 블록 | `0x14048d138..0x14048dd94` | 140개 대부분이 여기. 예외 3개는 `0x1404875f3`(`g_Bones`) 등 다른 블록 |
$ sed -n '186p' docs/re/shader-uniforms.md
| 113 | `g_Bones` | `0x14048daf8` | …
$ git show b883386e -- spec/engine/uniforms.json | grep -A1 '"g_Bones"'
-     "va": "0x1404875f3",
+     "va": "0x14048daf8",
```
  PR #8 diffstat 에 `docs/re/shader-uniforms.md` 는 **없다**(정본 16행 + `g_Texture`
  `coordinateKind` 1행 = M25 의 17행만 손댔다).
  `0x1404875f3` 이 선언 조각 안 오프셋이라는 것은 짝 저장소 바이트로 재확인된다 —
  `analysis/strings/strings-ascii.txt:19090` 이 파일오프셋 `0x004863e4 = "const float4x3 g_Bones["`,
  `:19643` 이 `0x0048c8f8 = "g_Bones"`(맨 이름). RVA−파일오프셋 = `0x1200` 이므로
  맨 이름 VA = `0x48c8f8+0x1200+0x140000000` = **`0x14048daf8`**(정본 신값과 일치),
  구값 `0x1404875f3` = `0x4863e4+0x1200+0x140000000+0xF` = `"const float4x3 "` 15바이트 뒤,
  즉 **선언 조각 내부 토큰**이다.
- **왜 문제인가**: M25 의 피해 시나리오가 "다음 사람이 `0x140487665` 를 떠 보고 이름이 왜 `[` 로
  끝나는지 다시 조사한다" 였다. 정본만 고치고 산문을 남기면 그 조사는 그대로 발생하고,
  이번엔 **정본과 문서가 서로 다른 답을 준다**(둘 다 `확정` 취급 자리다).
  (그 행의 "예외 3개" 라는 **수** 자체는 건드리지 않는다 — 그 행은 140개짜리 **레지스트리**를
  세고 내 계수는 정본의 144개 **문자열 census** 라 모집단이 다르다. 확정적으로 틀린 것은
  **예시로 든 좌표**다: `g_Bones` 는 PR #8 이후 이름 블록 **안**(`0x14048daf8`)이므로
  그 행이 드는 "블록 밖 예외" 의 사례가 될 수 없다.)
- **기지 목록 대조**: **M25 의 반쪽 수정**(브리핑이 최고가치로 지정한 부류).

---

### 🟡 F3 — M22 의 정정이 짝 저장소에 반영되지 않았고, 짝 저장소 수치는 **어느 산식으로도 안 나오는 13**이다(정본은 11)
- **자리**: `Waple-wallpaper-source/corpus_scan/scene-json-schema.md:195-196`
  vs `Waple/spec/corpus/scene-schema.json:5259` (+ 생성기 `scripts/spec/measure_scene_schema.py:237-254`)
- **근거/재현**:
```
$ sed -n '191,196p' ../Waple-wallpaper-source/corpus_scan/scene-json-schema.md
   `{5: 63, 1: 33, 4: 32, 3: 31, absent: 3}` while `hdr`/`zoom` appear in **159** scenes
   and `wind`/`gravity` in **109**. By pigeonhole that forces at least **30** pre-v3
   scenes carrying HDR/zoom and at least **13** pre-v4 scenes carrying wind/gravity
```
  정본 값으로 재계산(`spec/corpus/scene-schema.json` 의 `scene.corpus.population.version`
  = {5:63,1:33,4:32,3:31,None:3} · `scene.general.keys` 의 n: hdr 159 · windenabled 109):
  - 옛 `versionGatedGeneral` 은 version 부재 시 **무게이트**였으므로 부재 3씬은 v≥임계와 함께 뺀다.
  - v3: 무게이트 = (63+32+31)+3 = 129 → 159−129 = **30** ✔ (짝 저장소도 30)
  - v4: 무게이트 = (63+32)+3 = 98 → 109−98 = **11** ✘ (짝 저장소는 13)
  - 부재 3을 빼지 않은 **옛 틀린 산식**으로도 109−95 = **14** 다. 즉 13 은 11 도 14 도 아니다.
  - **기전 추정**: 정정된 네 값은 30/**13**/1/**11**(hdr·zoom 30 · bloomtint 13 ·
    perspectiveoverridefov 1 · wind 11)이다. 짝 저장소의 "30 … 13" 은 **bloomtint 의 13 이
    wind 자리로 옮겨 붙은 꼴**이다 — 두 값이 인접해 적히는 목록이라 전사(transposition)로 설명된다.
    (확정은 아니다. 확정된 것은 13 이 어느 산식으로도 안 나온다는 것뿐이다.)
  Waple 쪽은 PR #8 이 `version_gate_counterexample_minima()` 로 하한을 **계산**하게 바꿔
  30/13/1/11 로 정정했다(`git show b883386e -- scripts/spec/measure_scene_schema.py`).
- **왜 문제인가**: 이 두 자리는 **의도적으로 서로를 인용하는 쌍**이다 —
  `spec/corpus/scene-schema.json:5259` 가 짝 저장소 커밋 `0bb963ed` 와 그 파일의 `:189` 을
  근거로 명시하고, `Sources/WapleCore/SceneDocument.swift:4052` ·
  `Tests/WapleCoreTests/SceneVersionFeatureGateTests.swift:13` 도 같은 줄을 인용한다.
  한쪽만 재계산되면 같은 주장에 두 수가 남고, 다음 사람이 어느 쪽을 재현해도 상대를 재현 못 한다.
  (짝 저장소 파일은 커밋 `0bb963ed` 상태 그대로다 — 미커밋 수정 목록에 없다.)
- **기지 목록 대조**: **M22 의 반쪽 수정**(Waple 쪽만 고쳐짐).

---

### 🟡 F4 — M19 와 `pkgv_census.py` 파괴 결함의 수정이 짝 저장소 **미커밋 작업트리에만** 있다
- **자리**: `Waple-wallpaper-source` 작업트리 —
  `corpus_scan/mdl-format.md`(+21/−6) · `corpus_scan/pkgv_census.py` 외 12파일
- **근거/재현**:
```
$ cd ../Waple-wallpaper-source && git status --porcelain
 M WE-ENGINE-ANALYSIS-2026-07-27.md
 M analysis/d3d_late.log
 M analysis/pe-structure.md
 M analysis/reports/mdl-tex-decoders-2026-08-27.md
 M analysis/reports/subsystems-identified.md
 M analysis/rtti-vtables.json
 M corpus_scan/mdl-format.md
 M corpus_scan/pkgv_census.py
 M scripts/DecompileAll.java  … (총 14)
$ git log -1 --format='%h %ad' -- corpus_scan/mdl-format.md
0bb963ed 2026-08-28 11:52:35 +0000     ← 커밋된 판은 아직 "bone-binding · [UNRESOLVED]"
```
  작업트리 판은 M19 를 정확히 닫는다: `:72` `u32 n -> n × morph/mask record` ·
  `:89` `| v23 morph/mask records |` · `:95` `### v23 morph/mask record — ✅ RESOLVED …` ·
  `:299` `7. ~~The v23 record body.~~ ✅ RESOLVED from Waple's wider workshop corpus`.
  모집단 구분도 정확히 적었다(설치본 28파일 count 0 vs 워크샵 12파일이 본체를 밟음).
  `pkgv_census.py` 쪽도 `WE_WORKSHOP` 환경변수 + "입력 0 이면 아무것도 안 쓰고 종료코드 2" 가드를
  넣은 실질 수정이다(종전엔 빈 입력으로 447행 산출물을 20B 로 파괴하며 종료코드 0).
- **왜 문제인가**: `git clone` 하는 사람 · CI · 다음 감사자는 전부 커밋된 판을 본다 —
  거기엔 M19 가 그대로 열려 있고 `pkgv_census.py` 는 여전히 근거 파괴 경로를 갖는다.
  Waple 쪽 정본은 이미 이 수정이 **있다고 전제**하고 짝 저장소를 인용한다.
  "한쪽 리포의 진전이 다른 쪽에 반영되지 않는다"(M19 의 원래 진단)가 이번엔 **커밋 경계**에서 재발했다.
- **기지 목록 대조**: M19 의 후속 — 내용은 고쳐졌으나 **내구성이 없다**. 재보고가 아니라 상태 갱신.
- **주의**: 이 레인은 읽기 전용이라 커밋하지 않았다. 오케스트레이터 판단 사항.

---

### 🟡 F5 — `.tex` 전수 도수가 세 저장소·문서에 **세 값**으로 살아 있고, 그중 하나는 생성기가 "정본과 갈려 있다" 고 자백한 채 방치돼 있다
- **자리**:
  - `spec/formats/tex-embedded-mips.json:38,66,81,96,270,357` — `"4991개 .tex 전수(워크샵 scene.pkg + 설치 assets)"` (6곳, 전부 `확정` 항목의 evidence ref)
  - `spec/formats/tex-deep.json:5` — `"corpusTexFiles": 5120`, 그리고 `:35,50,52,124,187,314,1043` 이 **"코퍼스 5120"** 으로만 적는다(모집단 미명시)
  - `Waple-wallpaper-source/corpus_scan/tex-format.md:2-4` · `chunk-type-census.md:16` — `4,679` (워크샵 pkg 한정)
- **근거/재현**:
```
$ grep -n "4991" spec/formats/tex-embedded-mips.json | head -3
$ python3 -c "import json;print(json.load(open('spec/formats/tex-deep.json'))['measuredAt'])"
{'corpusTexFiles': 5120, 'texJsonFiles': 388}
$ sed -n '152,172p' scripts/spec/measure_embedded_mips.py
  # ⚠️ **`spec/formats/tex-embedded-mips.json` 은 아직 옛 문장("… + 설치 assets", 전수
  # 4,991)을 6곳에 담고 있다 — 지금 정본과 이 생성기는 갈려 있다.**
$ grep -n '"{r\[.total.\]}개' scripts/spec/measure_embedded_mips.py
169: f"{r['total']}개 .tex 전수(워크샵 scene.pkg + 설치 assets/projects)"
$ grep -n "5120\|재생성\|projects" spec/formats/tex-embedded-mips.json   # → 0건
```
- **왜 문제인가**: 세 값은 **서로 다른 모집단**이라 전부 참일 수 있다
  (4,679 = 워크샵 pkg / 4,991 = 워크샵+설치 `assets` / 5,120 = +설치 `projects` 129).
  문제는 **어느 것도 정본 안에서 자기 모집단을 완결적으로 밝히지 않는다**는 것이다:
  `tex-deep.json` 은 `"코퍼스 5120"` 이라고만 적어 어느 코퍼스인지 없고
  (`projects/` 포함은 `:51`·`:124` 두 항목의 산문에서 부수적으로만 드러난다), `tex-embedded-mips.json` 은 **틀린 라벨**
  ("설치 assets", 실제는 assets+projects)과 **틀린 수**(4,991, 실제 5,120)를 6곳에 들고 있다.
  두 문서를 나란히 읽는 사람은 같은 `.tex` 사실에 대해 두 분모를 받는다.
- **정황(브리핑 규약 4 대로 근거를 읽었다)**: 방치는 **의도적이고 이유가 적혀 있다** —
  이 컨테이너에 워크샵 코퍼스가 없어 재측정이 불가하고, 못 잰 수를 손으로 적는 것이 이 리포가
  반복해 당한 실패라서 그대로 뒀다(`measure_embedded_mips.py:157-171`, 재생성 시 들어올
  델타까지 미리 계산해 뒀다). **그 정당화는 "손으로 새 수를 적지 마라" 까지만 덮는다** —
  정본 쪽에 "이 문서의 전수는 4,991 이고 현행 생성기 모집단(5,120)과 갈려 있다" 는
  **한 줄 묘비를 남기는 것**은 측정이 아니라 사실 기록이며, 그건 안 돼 있다.
  현재 이 갈림을 아는 유일한 방법은 생성기 소스를 읽는 것이다.
- **기지 목록 대조**: 직전 감사의 "세 개의 모집단" 경고의 **구체 자리**. M-번호 없음(신규 자리).

---

### ⚪ F6 — `validate.py` 가 새로 찍는 "WE/짝 저장소 399건 존재 검사" 는 그 60%가 파일 1개(또는 루트)를 볼 뿐이다
- **자리**: `scripts/spec/validate.py:493-497`(census 출력) · `:104-146`(`we_ref_path`)
- **근거/재현**: 399건의 해석 결과 분포 —
  `wallpaper64.exe` **237** · `bin/scenescript64.dll` 30 · `ui/dist/monaco/…d.ts` 20 ·
  `bin/wallpaperui.exe` 14 · … · **`.`(=WE_ROOT 자체) 2**
  (`.` 2건은 `spec/engine/blend-modes.json` `blend.corpusReach` 의 `WE_ROOT/**/*.json` 과
  `spec/engine/dominant-color.json` `dominantColor.schemecolorCorpus` 의 `WE_ROOT/**/project.json` —
  글로브 앞 비글로브 접두가 비어 루트로 접힌다.)
  237건의 원문은 `"wallpaper64.exe 안 'util/<name>' 리터럴 문자열 존재 여부"` 처럼
  **첫 토큰만 파일명인 산문**이고, 검사되는 것은 그 exe 의 존재뿐이다(주소·문자열은 아니다).
- **왜 문제인가**: 실패는 아니다 — `we_ref_path` 독스트링이 "글로브는 비글로브 최장 접두만 본다"
  를 명시적 규약으로 적어 뒀고 보수적 판단이 옳다. 다만 **"399건 존재 검사"** 라는 출력 문면은
  다음 감사자가 커버리지를 과대평가하게 만든다(=M11 이 고친 결함의 재발 위험을 숨긴다).
  주소 인용 쪽은 `check_cited_address_census.py`(PR #8 신규, `spec.yml:177`)가 별도로 덮는다 —
  실행해 봤고 통과한다(`인용 고유 주소 95개 · 대조 24건`).
- **기지 목록 대조**: 해당 없음(관찰).

---

### ⚪ F7 — `check_canon_generator_values.py` 의 새 particle 분기는 **cwd 의존**이고, 실패 메시지의 `정본:`/`생성:` 라벨이 뒤바뀐다
- **자리**: `scripts/spec/check_canon_generator_values.py:209-235`
- **근거/재현**:
```
$ cd /tmp && python3 /Users/…/Waple/scripts/spec/check_canon_generator_values.py
[canon-generator-values] particle-fields 동적 소스 근거가 정본과 갈린다.
  source
      정본: None
      생성: `(sys.def.flags & 1)` 조건식
$ echo rc=$?
rc=1                      ← 리포 루트에서는 rc=0
```
  `particle-fields.json` 은 `ROOT / …` 절대경로로 읽는데, `exec_module` 로 부르는
  `measure_particle_fields._flags_consume_lineno()` / `flags_comment_staleness()` 는
  `RSRC`·`PSRC` 를 **상대경로**로 연다(`measure_particle_fields.py:35-36,45`). 리포 루트가
  아닌 cwd 에서는 `line is None` 이 되어 없는 드리프트를 신고한다. 그리고 그 튜플
  `("source", None, "…조건식")` 은 `(key, current, expected)` 로 출력되는데 `None` 은
  **생성기 쪽** 결과이지 정본 값이 아니다 — 라벨이 반대다.
- **왜 문제인가**: CI 는 리포 루트에서 돌므로(`spec.yml:210`) 게이트는 지금 정상이다.
  다만 사람이 손으로 돌릴 때 재현 안 되는 실패를 보고, 그 메시지가 "정본이 None 이다" 로
  읽혀 엉뚱한 자리를 고치게 만든다. H7 재발 방지 장치 자체의 진단 품질 문제다.
- **기지 목록 대조**: 해당 없음(관찰). H7 수정이 새로 심은 자리다.

---

### ⚪ F8 — 모집단 명시용 `population` 필드가 도입 뒤 **1,210건 중 6건(0.5%)** 만 쓰인다
- **자리**: `scripts/spec/validate.py:230-236`(선택 필드, 미강제) · 실사용 6곳
- **근거/재현**: 위 §1 스크립트에 `ev.get("population")` 집계를 붙이면 6.
  실제 값은 `설치본 scene.pkg 161개(gifscene.pkg 제외 — 그래서 inventory.json 의 162 와 다르다)` ·
  `워크샵 요약 162씬의 general 키 전수` 등 **정확히 이 레인이 찾는 종류의 라벨**이다.
- **왜 문제인가**: 실패는 아니다(`83da9851` 이 소급 강제하지 않기로 한 판단은 옳다).
  다만 F5 같은 자리가 이 필드 하나로 해소되는데 채택이 사실상 멈춰 있다.
  참고로 그 6건 중 하나가 F1 의 낡은 "1,203개" 다 — 즉 채택된 소수마저 드리프트했다.
- **기지 목록 대조**: 해당 없음(관찰).

---

### 🟡 F9 — PR #8 의 새 불변식 "필수 입력이 없으면 정본을 못 건드린다" 가 리포 전역에 성립하지 않는다 — `measure_effect_fbo_audio.py` 는 입력 0 으로 **실제 정본 파일을 다시 쓰고 종료코드 0** 을 낸다
- **자리**: `scripts/spec/measure_effect_fbo_audio.py:43`(`OUT = os.path.join(REPO, …)`) ·
  `:513-524`(`main()` 의 carry-forward 경로) ·
  `scripts/spec/tests/test_measure_prerequisites.py:1-4`(불변식 문면) · `:36-53`(CASES 18개) ·
  `:78-81`(쓰기 검출 단언)
- **근거/재현** (빈 샌드박스 cwd + 전부 부재하는 입력 경로, 새 테스트와 같은 조건):
```
SB=$(mktemp -d); cd "$SB"
export WE_ROOT=$SB/missing/we-root WE_WORKSHOP=$SB/missing/workshop        WE_BINARY=$SB/missing/wallpaper64.exe WE_BIN=$SB/missing/wallpaper64.exe
python3 /…/Waple/scripts/spec/measure_effect_fbo_audio.py; echo rc=$?
#   ⚠️ wallpaper64.exe 없음 — 기존 산출물을 그대로 이어받는다(근거 보존)
#   이펙트 FBO · 오디오 → spec/engine/effect-fbo-audio.json (이어받음)
#   rc=0
```
  실측 결과: **리포의** `spec/engine/effect-fbo-audio.json` mtime 이 `Aug 31 12:05` →
  `Aug 31 20:42:11` 로 바뀐다(내용은 바이트 동일 — `git status` 는 계속 깨끗하다).
  같은 조건에서 나머지 16개 무가드 생성기는 전부 `rc=1` · 무쓰기다(내가 17개 전수 시행).
- **왜 문제인가**: 세 겹이다.
  1. **종료코드가 형제와 반대다.** `specfmt.require_inputs` 를 단 18개는 "정본을 쓰지 않고
     중단한다" + `rc=1` 이다. 이 하나만 `rc=0` 이라, 재생성 루프(`for s in measure_*.py`)나
     CI 가 rc 로 판정하면 **측정하지 않은 것을 측정 성공으로 집계**한다.
  2. **새 테스트가 이 부류를 구조적으로 못 본다.** `test_measure_prerequisites.py:78-81` 의
     쓰기 검출은 `self.assertFalse((sandbox / "spec").exists())` — **cwd 상대**로만 본다.
     `OUT` 을 절대경로(`REPO/spec/...`)로 잡는 생성기는 샌드박스 밖(진짜 리포)에 쓰므로
     이 단언에 절대 안 걸린다. 그런 생성기가 **8개**다: `measure_blend_modes` ·
     `measure_dominant_color` · `measure_effect_fbo_audio` · `measure_material_brightness` ·
     `measure_mul_convention` · `measure_particle_corpus` · `measure_shaders` ·
     `measure_tonemapping`(전부 CASES 18 밖이라 지금은 실해가 없지만, 다음에 하나가
     CASES 에 들어가면 테스트가 **거짓 초록**을 낸다).
  3. **문면이 전칭이다.** 그 테스트 모듈 독스트링이 *"A prerequisite regression therefore
     cannot touch the repository's `spec/**/*.json` files"* 라고 무조건으로 적는다.
     실제로는 "CASES 에 든 18개가, 상대 OUT 을 쓰는 한" 이다.
- **정황(규약 4)**: carry-forward 자체는 **의도된 설계**이고 이유도 옳다 — 입력이 없을 때
  빈 정본을 써서 근거를 파괴하는 것(짝 저장소 `pkgv_census.py` 가 당한 바로 그 실패)보다
  기존 산출물 보존이 낫다. 문제는 **보존과 종료코드 0 을 같이 쓴 것**과, 그 예외가
  새 census/테스트 어디에도 기록되지 않은 것이다. 한 줄이면 닫힌다(rc 를 2 로 하거나,
  CASES 에 "쓰지만 내용 보존" 부류를 별도 단언으로 등록).
- **기지 목록 대조**: **M4 의 잔여**(무코퍼스 트레이스백 18건은 PR #8 이 닫았다).
  M4 가 "트레이스백" 만 봤기 때문에 "쓰면서 성공한다" 는 이 한 건이 census 밖에 남았다.
- **주의(자기 신고)**: 이 재현이 리포 파일의 **mtime 한 개**를 바꿨다
  (`spec/engine/effect-fbo-audio.json`, 내용 불변·`git status` 깨끗). 그 밖에
  `spec/assets/particle-corpus.json` · `spec/engine/mul-convention.json` 의 mtime 이
  세션 중 `20:23:55` 로 바뀐 것을 관측했으나 **내 명령으로는 재현되지 않는다**
  (spec.yml 게이트 18개 · spec 테스트 4개 · 모듈 임포트 전부 무쓰기임을 mtime 스냅샷으로
  확인했다). 동시 실행 중인 다른 레인일 가능성이 높다 — 내용은 양쪽 다 불변이다.

---

## 확인했지만 문제없던 것 (다음 라운드 시간 절약)

1. **`validate.py` 실행 결과가 직전 감사와 완전히 일치**한다 — 오류 0 · 문서간 경고 0 ·
   헤지 27(묘비 면제 1) · 확정 488/보고 24/추정 12. 새로 늘어난 것은 근거 경로 census 한 줄뿐.
2. **양쪽 저장소가 공유하는 유일한 이중 정본 파일 `spec/engine/playback-policy.json` 은 바이트 동일**
   (md5 `7213ac5c7c871416c954f80091dd75b5`, 양쪽 14,920B). 이 축의 갈림은 없다.
3. **M12 는 실제로 고쳐졌다** — `Sources/WapleCore/GLSLTranslator.swift:2239-2247` 이 이제
   동봉 WEAssets 502셰이더(`g_Bones` **48**)와 형제 `wallpaper_engine/projects/` 90셰이더를
   **분리해** 열거하고, 중복 제거 합계를 따로 적으며, `assets/` 가 WEAssets 사본이라 합산하지
   않는다고 명시한다. 두 모집단 혼합·40/48 모두 해소.
4. **Waple → 짝 저장소 줄번호 인용 12건 전수 재확인, 전부 유효**:
   `scene-json-schema.md:24 / :38-42 / :80-82 / :123 / :141 / :189` ·
   `project-json-schema.md:47`(141건 ✔) · `mdl-format.md:38` · `tex-format.md:52`.
   `mdl-format.md` 가 작업트리에서 +15줄 늘었지만 인용된 자리는 그 위쪽이라 밀리지 않았다.
5. **`corpus_scan/` 산출물 도수와 Waple 문서의 인용이 일치**한다 —
   446 폴더(`scenes-index.tsv` 447행−헤더) · 11,338 경로종(`entry-name-frequency.tsv` 11,339−헤더) ·
   19,777 엔트리 · `scene.pkg` 161 · 파스 오류 0(`parse-errors.tsv` 는 헤더뿐).
   `docs/re/package-format.md:11,312,695,1104` 의 인용이 전부 재현된다.
6. **`spec/README.md:20` 의 "정본 evidence 중 `analysis/`·`corpus_scan/` 인용 0건" 은 여전히 참**이다
   (45문서 1,210 evidence 전수). 짝 저장소를 가리키는 evidence 12건은 전부
   `absence-audit.json` 의 산문형 `"WE 2.8.42 설치본 바이너리 42종 (/home/user/…)"` 이다.
7. **`spec.yml` 의 파이썬 게이트 18개 + spec 자체검사 4개가 HEAD 에서 전부 통과**한다
   (`check_int_narrowing` … `check_stray_artifacts`, `check_scene_mount_parity --selftest`,
   `test_validate` 56 · `test_rosetta` 22 · `test_mdla_framing` 13 · `test_measure_prerequisites` 3).
   그리고 **어느 것도 정본 파일을 쓰지 않는다**(mtime 스냅샷 전후 대조).
8. **M16 축(`measure_workshop_shaders.py`, PR #8 에서 +825)은 실제로 닫혔다.**
   `--selftest` 통과(0 실패)이고, 정본이 적는 "단언 52건(evalChecked 48 · preprocessStrict 4)" 을
   `harvest_swift_expectations()` 직접 호출로 재현했다 — **48/4/미수확 5**로 정확히 일치.
   히스토그램의 죽은 버킷(`%`·비트연산이 `unsupported` 플래그로 세어져 구조적 0 이던 것)도
   `histogramMechanismCorrection` 으로 명시 정정됐고, 값이 안 바뀌는 이유까지 적어 뒀다.
9. **`check_cited_address_census.py`(PR #8 신규)는 배선되어 있고 통과**한다
   (`.github/workflows/spec.yml:177`, 인용 고유 주소 95개 · 대조 24건).
   H2 가 지적한 "동적 도수는 재생성으로만 잡힌다" 를 이 축에서는 실제로 닫았다 —
   같은 처방이 F1 의 바이너리 인용 census 에는 아직 없다.
