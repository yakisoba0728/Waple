# 레인 15 — RE 저장소: 분석 도구·리포트 (2026-08-31 r2)

대상: `/Users/yakisoba0728/Documents/GitHub/Waple-wallpaper-source`
HEAD `1fac2a0c` (2026-08-28). **커밋된 것은 없다** — 직전 감사 이후 새 커밋 0건.
작업 트리에 미커밋 수정 **14파일**(직전 감사가 본 13 + 그 뒤 바뀐 것).
가장 최근 편집: `corpus_scan/mdl-format.md` (08-31 10:04) · `WE-ENGINE-ANALYSIS-2026-07-27.md` (08-31 10:17).
나머지 12파일은 전부 08-30 13:43~13:54.

## 기지 항목 상태 (요청받은 3건)

| 기지 | 상태 | 근거 |
|---|---|---|
| **M26** `pdataCoverage 52.4%` | ✅ 고쳐짐 (RE 저장소 밖) | `Waple/spec/engine/decompilation-provenance.json:134` = `6824 / 14792 = **46.1%**`. RE 저장소에는 `pdataCoverage` 문자열이 없다. RE 쪽 대응 정정(`analysis/pe-structure.md:117-148`)도 14,792 entries / 6,824 primary / 7,748 corpus 세 도수를 분리해 적었고 **내가 무손상 바이너리로 재측정해 셋 다 정확히 일치**(아래 "문제없던 것" 참조). |
| **M7** 디컴파일 실패 3건 산문 미기록 | ✅ 고쳐짐 | `WE-ENGINE-ANALYSIS-2026-07-27.md:41, 773-790` 이 "7,748 manifest entries: 7,745 C bodies + 3 header-only failures" 와 실패 3건 표를 새로 넣었다. 실측 일치: manifest `decompiled:false` 3건(1401c5490/14023fbc0/140300680) = 디스크에서 5줄 이하 파일 정확히 그 3개. |
| **M19** `mdl-format.md` v≥23 UNRESOLVED | ✅ 고쳐짐 — **단, 형제 리포트를 안 쓸었다** → 아래 F4 |

---

## 발견

### 🟡 F1 — `pe-structure.md` 의 delay-load 절: 개수가 종결자를 센 4(실제 3)이고, 후보 4개 중 3개가 오답이며, 교차참조 파일도 틀렸다
- **자리**: `analysis/pe-structure.md:165` (§6 표) · `analysis/pe-structure.md:229-230` (§11 전체)
- **근거/재현**:
  ```
  # 저장소 루트에서. DELAY_IMPORT dir = RVA 0x4D87B0 / size 0x80
  python3 -c "
  import struct
  d=open('binaries/wallpaper64.exe','rb').read(); e=struct.unpack_from('<I',d,0x3c)[0]
  S=[struct.unpack_from('<IIII',d,e+24+struct.unpack_from('<H',d,e+20)[0]+i*40+8) for i in range(struct.unpack_from('<H',d,e+6)[0])]
  r2o=lambda v:next(ro+(v-va) for vs,va,rs,ro in S if ro and va<=v<va+max(vs,rs))
  off=r2o(0x4D87B0); i=0
  while any(struct.unpack_from('<8I',d,off+i*32)):
      n=r2o(struct.unpack_from('<8I',d,off+i*32)[1]); print(i,d[n:d.index(b'\\0',n)].decode()); i+=1
  print('TERMINATOR at',i,'-> real delay DLLs =',i)"
  # -> 0 MF.dll / 1 MFPlat.DLL / 2 pdh.dll / TERMINATOR at 3 -> real delay DLLs = 3
  ```
  실측 결과: **`MF.dll` · `MFPlat.DLL` · `pdh.dll`, 그리고 전부 0인 종결자**. → 실제 delay-load DLL 은 **3개**, `0x80/0x20 = 4` 는 종결자를 센 수다.
  - 같은 표의 IMPORT 행은 `0x118`(=14 디스크립터)에서 종결자를 빼고 **"13 DLL descriptors"** 라고 옳게 적는다 — 같은 문서·같은 표 안의 비대칭.
  - §11 의 후보 목록 `d3dcompiler_47.dll` / `dxcompiler.dll` / `pdh.dll` / `mmdevapi.dll` 중 맞은 것은 `pdh.dll` 하나. `dxcompiler`·`mmdevapi` 는 **바이너리에 문자열조차 없다**(`d.find()` → −1).
  - §11 은 "The string `d3dcompiler_47.dll` is present in `.rdata` (see `analysis/strings/d3d-dxgi.txt`)" 라고 하는데 **그 파일에 없다**: `grep -rn d3dcompiler analysis/strings/` → `file-extensions.txt:27,119` · `misc-notable.txt:55,136` · `error-messages.txt:129` 뿐. 게다가 `d3dcompiler_47.dll` 은 delay-import 가 아니라 런타임 `LoadLibrary` 대상이다(같은 문자열이 `DirectX compiler cannot be found, d3dcompiler_47.dll is missing.` 에러 메시지와 짝을 이룬다).
- **왜 문제인가**: §11 이 "strongly implying it is one of the 4 delay-loads" 라는 단정 톤으로 존재하지 않는 delay-import 를 지목한다. 실제 delay-load 3종은 Media Foundation 2 + PDH(성능 카운터)로 **비디오 파이프라인**의 신호이지 셰이더 컴파일러의 신호가 아니다 — 후속 분석의 방향을 반대로 돌린다.
- **기지 목록 대조**: 해당 없음 (직전 감사가 이 파일의 08-30 변경을 "결함 0" 으로 통과시켰다)

### 🟡 F2 — `pe-structure.md` §10 의 TLS 주소 3개가 바이너리·형제 JSON 둘 다와 어긋난다 (폐기된 옛 파서의 잔재)
- **자리**: `analysis/pe-structure.md:224-226`
- **근거/재현**: TLS 디렉터리(RVA 0x497F80 → 파일 0x496D80)의 `IMAGE_TLS_DIRECTORY64` 를 직접 읽으면

  | 필드 | `pe-structure.md` | 바이너리 실측 | `pe-structure.json` |
  |---|---|---|---|
  | Raw data start..end | `0x14048A000..0x14048A030` (48 B) | **`0x14049DD70..0x14049E0A8`** (824 B) | 0x14049DD70 / 0x14049E0A8 ✅ |
  | AddressOfIndex | `0x140493848` | **`0x1404E3A88`** | 0x1404E3A88 ✅ |
  | AddressOfCallbacks | `0x140492980` | **`0x140426DA0`** | 0x140426DA0 ✅ |
  | 콜백 2개 | 0x14028AEB0 / 0x14028AF90 ✅ | 동일 | 동일 |

  즉 **`.md` 만 틀렸고 `.json` 은 옳다.** 문서 상단(`:10`)은 "an earlier parser had two offset bugs (e_lfanew=0x100 …) … The values below were re-derived from a fresh parser and cross-checked by hand" 라고 주장하는데, §10 은 그 재도출에서 빠진 절이다(옛 파서가 e_lfanew 를 0xC0 밀어 읽으면 TLS 디렉터리 자체를 딴 데서 읽는다).
- **왜 문제인가**: 같은 절이 TLS 콜백 배열을 "a **high-priority Ghidra target**" 이라고 지목한다. 적힌 `AddressOfCallbacks 0x140492980` 을 그대로 열면 엉뚱한 데이터를 본다(진짜는 `0x140426DA0`, `.rdata`). 그리고 "48 bytes of thread-local init data" 는 실제 824바이트의 6% 다.
- **기지 목록 대조**: 해당 없음

### 🟡 F3 — `analysis/parse_pe.py` 의 TLS 언팩이 존재하지 않는 7번째 필드를 읽는다 — 정본 JSON 의 `characteristics` 가 구조체 **밖** 4바이트다
- **자리**: `analysis/parse_pe.py:237-243`
  ```python
  # PE32+ TLS: raw_start(8) raw_end(8) index_addr(8) callbacks(8) zs(4) sz(4) char(4)
  (raw_start, raw_end, index_addr, callbacks) = struct.unpack_from("<QQQQ", data, tls_off)
  (zero_fill, sz_of_sz, char_tls) = struct.unpack_from("<III", data, tls_off+32)
  ```
- **근거/재현**: `IMAGE_TLS_DIRECTORY64` 는 필드 **6개, 40바이트**(= 디렉터리 size `0x28`, 이 파일이 §10 에 직접 적어둔 값)다. `sz_of_sz` 라는 필드는 없다. 파일 `0x496D80+32` 에서 u32 3개를 읽으면 `(0, 5242880, 1)` — 즉
  - `zero_fill` ← SizeOfZeroFill = 0 ✅
  - `sz_of_sz` ← **Characteristics = 0x500000** (버려짐)
  - `char_tls` ← **구조체 끝을 4바이트 넘어선 값 = 1** → 커밋된 `analysis/pe-structure.json` 의 `"characteristics": 1`
  형제 스크립트 `analysis/pe_parse.py:175` 는 `struct.unpack_from("<QQQQII", …)` 로 **처음부터 옳다** — 새 파서가 회귀한 것이다.
  재현성 확인: `python3 analysis/parse_pe.py binaries/wallpaper64.exe <tmp>` 산출물이 커밋된 `pe-structure.json` 과 **완전 동일**(diff 0). 즉 이 오독은 지금 정본에 그대로 들어 있다.
- **왜 문제인가**: (1) 정본 JSON 이 TLS `characteristics` 를 틀린 값으로 기록한다. (2) 40바이트 경계 밖을 읽으므로 TLS 디렉터리가 섹션 raw 데이터 끝에 놓인 PE 에서는 `struct.error` 로 죽는다 — 이 리포가 `inject_rich_header.py` 에서 방금 고친 것과 같은 "판정 대신 트레이스백" 형태.
- **기지 목록 대조**: 해당 없음

### 🟡 F4 — M19 수정이 형제 리포트를 쓸지 않았다: `mdl-tex-decoders` 에 폐기된 "본 바인딩" 명명이 3자리, 그중 하나는 여전히 **[미해결]** 목록에 있다
- **자리**: `analysis/reports/mdl-tex-decoders-2026-08-27.md:144` · `:322` · `:557`
- **근거/재현**:
  ```
  grep -rn "본 바인딩\|morph" corpus_scan/mdl-format.md analysis/reports/mdl-tex-decoders-2026-08-27.md
  ```
  `corpus_scan/mdl-format.md` 는 2026-08-31 편집으로 `:72`, `:89`, `:95-108`, `:299-302` 를 전부 **"morph/mask record — ✅ RESOLVED"** 로 바꾸고 "not a skinning/bone-binding block" 이라고 명시했다. 그런데 같은 저장소의 형제 리포트는
  - `:144` `| v23 본 바인딩 레코드 | version >= 23 | 디컴파일 :345 |`
  - `:322` `- MDLV0023: … = v23 본 바인딩 카운트 0 + 빈 태그.`
  - `:548-558` `## 4. 검증하지 못한 것 (전부 [미해결])` 의 **3번 항목**: "**v23 본 바인딩 레코드의 뒷부분** … 실물에서 `n`(카운트)이 전부 0 이라 레코드 본문은 한 번도 실행되지 않았다. 사실상 미검증이다."
  로 그대로 남았다. `:565` 에서 같은 목록의 5번 항목은 "[2026-08-30 해결 — 미해결 목록에서 내린다]" 로 처리했으므로, 이 파일에 정정 블록을 다는 관례는 이미 성립해 있다.
- **왜 문제인가**: 이 저장소가 반복해서 잡아내는 바로 그 패턴(형제 미스윕)이다. 다음 라운드가 §4 목록을 읽고 이미 해소된 항목을 다시 조사한다. 명명도 반증된 쪽(skinning/bone)이라 Waple 의 `Model3D.MorphTarget` 과 어긋난다.
- **기지 목록 대조**: **M19 의 반만 고침** (브리핑이 최고가치로 지목한 부류)

### 🟡 F5 — `analysis/rtti-references.json` 이 삭제된 손상 바이너리의 좌표를 그대로 들고 있다(형제 파일이 지적했으나 안 함) + 그 단 하나의 레코드 라벨이 틀린 클래스다
- **자리**: `analysis/rtti-references.json` (`DWriteFontFileLoader` 레코드, `file_off: 4823728`) · 미이행 지적은 `analysis/rtti-vtables.json:25-29` ("그 파일에도 같은 종류의 표시가 필요하다") · 라벨 출처는 `scripts/MapRttiReferences.py:94`
- **근거/재현**: `MapRttiReferences.py` 는 `.?A…` TypeDescriptor 의 RVA 를 4바이트 LE 로 파일 전체에서 훑어 `file_off` 를 적는다. 그 RVA(`0x4E37E0`)로 각 입력을 스캔하면
  | 입력 | RVA4 히트 file_off |
  |---|---|
  | `binaries/wallpaper64.exe` (무손상) | **4823520** (0x4999E0) |
  | `binaries/wallpaper64_rich.exe` (현행, growth 0x200) | **4824032** (0x499BE0) |
  | 커밋된 JSON | **4823728** = 무손상 + **0xD0** |
  0xD0 은 `f46cecd5`/`6597a69c` 가 폐기한 **2026-08-26 결함 주입본**의 growth 다. 즉 이 좌표는 **현재 저장소의 어떤 입력으로도 재현되지 않는다** — 손상 코퍼스 사태의 마지막 잔존 산출물.
- **덤**: 그 레코드의 클래스 라벨도 틀렸다. `MapRttiReferences.py:94` 의 `'DWriteFontFileLoader': 0x4e17f0` 에서 0x4e17f0 의 실제 문자열은 **`.?AUIDWriteFontFileStream@@`** 이고, 진짜 `.?AVDWriteFontFileLoader@@` 는 `0x4e1910` 이다. 산문 `WE-ENGINE-ANALYSIS-2026-07-27.md:905` 가 "only `DWriteFontFileLoader` has an entry" 로 그 오라벨을 그대로 재인용한다.
- **왜 문제인가**: 형제 `rtti-vtables.json` 은 08-30 에 무효/한계 표시를 받았고 그 주석이 명시적으로 "rtti-references.json 에도 같은 표시가 필요하다" 고 적었는데 이행되지 않았다. 표시 없는 좌표 하나가 정본으로 남아 있다.
- **기지 목록 대조**: 해당 없음(스스로 예고한 미이행)

### 🟡 F6 — 산문 "Decompilation coverage limit" 표의 오퍼레이터 VM 범위가 **874바이트 짧다**
- **자리**: `WE-ENGINE-ANALYSIS-2026-07-27.md:782`
  `| FUN_14023fbc0 | 542 | particle operator VM dispatcher (0x14023fbc0–0x14024bace; …) |`
- **근거/재현**: 짝 저장소 정본 `Waple/docs/re/particle-operator-vm.md:42-44` —
  "VM 함수 전체 범위는 `.pdata` 4조각을 `UNW_FLAG_CHAININFO` 로 묶어 **`0x14023fbc0–0x14024be38`**(조각: `0x14023fbc0–0x14023fccd`, `0x14023fccd–0x14024bace`, `0x14024bace–0x14024bae3`, `0x14024bae3–0x14024be38`)".
  즉 `0x14024bace` 는 **2·3조각 경계**일 뿐 함수 끝이 아니다. `0x14024be38 − 0x14024bace = 0x36A = 874` 바이트가 빠진다.
- **왜 문제인가**: 이 표의 존재 이유가 "이 범위에서는 `analysis/decompiled/all/` 이 근거가 아니니 원본 바이너리를 봐라" 다. 범위를 짧게 적으면 3·4조각(874 B — 종료 처리 포함)이 커버된 것으로 오인되고, 그 구간을 근거 없는 디컴파일로 인용하게 된다.
- **부수 관찰**: 같은 행의 manifest size(**542** 주소)와 적힌 span(**48,910** B)이 90배 차이인데 설명이 없다. 4조각 체인 구조를 적었더라면 그 자체로 해소됐을 자리다.
- **기지 목록 대조**: 해당 없음

### 🟡 F7 (의심) — "66 distinct files" 는 38+28 **합산**을 서로소 합집합처럼 제시한 것이다
- **자리**: `WE-ENGINE-ANALYSIS-2026-07-27.md:781-786`
- **근거/재현**: Waple 저장소 전체에서 두 범위(`0x1401c5490–0x1401d152c`, `0x14023fbc0–0x14024bace`)의 주소 인용을 세면 파일 집합이 **항상 겹친다**:
  | 스코프 | 범위1 인용/파일 | 범위2 인용/파일 | 합집합 | 겹침 |
  |---|---|---|---|---|
  | 전체 | 1375 / 51 | 1044 / 30 | **57** | 24 |
  | `Sources/` 만 | 437 / 8 | 406 / 4 | **8** | 4 |
  | `.swift` 만 | 610 / 24 | 524 / 16 | **26** | 14 |
  | `docs/history/` 제외 | 1375 / 51 | 1039 / 29 | **56** | 24 |
  인용 수의 합(`1,277 + 1,001 = 2,278`)은 타당하지만 파일 수는 합산 대상이 아니다.
- **분류**: 내 정규식으로 38/28 을 **정확히 재현하지 못했다**(오늘 병합된 PR #8 로 Waple 이 크게 바뀌었고, 인용 표기 형태를 다 맞추지 못했다) → **의심**. 다만 어떤 스코프에서도 겹침이 0 이 아니므로 "distinct" 라는 단어는 성립하지 않는다.
- **기지 목록 대조**: 해당 없음

### 🟡 F8 — 08-30 에 열거한 "재생성 불가 생성기" 목록에서 `analysis/` 쪽 3개가 빠졌다
- **자리**: `analysis/extract_strings.py:10-11` · `analysis/categorize_strings.py:7` · `analysis/pe_parse.py:9-11,271`
- **근거/재현**: `analysis/rtti-vtables.json:18-23` 이 하드코딩 절대경로 때문에 못 돌리는 생성기로 `scripts/TraceRttiVtables.py:161` · `TraceRttiVtables2.py:127` · `MapRttiReferences.py:41-44,154` **셋만** 열거하고 "그 세 파일은 이 레인의 소유가 아니어서 여기서 고치지 않았다" 고 적었다. 그러나 `analysis/` 안에도 같은 것이 셋 더 있다(`grep -rn 'C:\\Users\|Z:\\' analysis/*.py`), 전부 argv 폴백이 없다 — `analysis/parse_pe.py:14-18` 만 2026-08-28 에 폴백을 받았다.
- **연쇄**: `categorize_strings.py:8` 은 `OUTDIR/_all.json` 을 읽는데 그 파일은 **커밋돼 있지 않고 `.gitignore` 에도 없다**. 경로를 고쳐도 `extract_strings.py` 를 먼저 돌려야 재생성된다.
- **영향 범위**: `analysis/strings/*.txt` 8개 전부가 이 두 스크립트의 산출물이고, 산문 §5·§9 와 `pe-structure.md:230` 이 이를 인용한다.
- **완화(실측)**: 산출물 자체는 유효하다 — `analysis/strings/d3d-dxgi.txt` 의 14개 항목 전부가 무손상 `binaries/wallpaper64.exe` 의 그 파일 오프셋에서 바이트가 정확히 일치했다(14/14, 불일치 0).
- **기지 목록 대조**: 해당 없음 (M4 는 Waple 쪽 재측정 스크립트 얘기라 다른 건)

### ⚪ F9 — `pe_parse.py` 와 `parse_pe.py` 가 같은 `pe-structure.json` 을 **서로 다른 스키마**로 쓰는데 어느 쪽이 정본 생성기인지 표시가 없다
- **자리**: `analysis/pe_parse.py:271` vs `analysis/parse_pe.py:353-354` · 산문 트리 `WE-ENGINE-ANALYSIS-2026-07-27.md:728` ("parse_pe.py / pe_parse.py ← PE parser") 이 둘을 한 줄로 묶어 구별하지 않는다
- **근거**: 키가 다르다 — `debug_entries` vs `debug`, `analysis` vs `security_summary`, `tls.raw_data_start_rva` vs `tls.raw_data_start_va`, `dll_characteristics` 가 문자열 vs 정수. 커밋본은 `parse_pe.py` 쪽. `pe_parse.py` 를 (경로만 고쳐) 돌리면 정본이 조용히 다른 스키마로 갈아엎힌다.
- **아이러니**: TLS 언팩만은 **옛 `pe_parse.py` 가 옳고 새 `parse_pe.py` 가 틀렸다**(F3).

---

## 확인했지만 문제없던 것 (다음 라운드 시간 절약용)

1. **08-30 정정 블록의 바이트 인용 14건이 전부 정확하다.** 무손상 `wallpaper_engine/wallpaper64.exe` 에서 직접 대조: TEXS 디스패치 6자리(`0x14015e755/78c/7e0/7e6/7f9/811`, `lea` 목표 = `0x14048B8E0`, `jnz` 목표 = `0x14015e86b`, `call` 목표 = `0x14015e1d0`·`0x1402c9e60`)와 인덱스 폭 8자리(`0x1401d784c/7853/7870/7878`, `0x14009a98d/997/99c/9a1`) 모두 바이트 단위 일치. GLSL 시임도 파일 `0x486b10` 에서 `#define vec2 float2` 로 시작해 정정이 옳다.
2. **`.pdata` 재측정 3도수 일치.** `0x2b560/12 = 14792`(나머지 0), `.text` 안 14792, primary **6824** / chained(`UNW_FLAG_CHAININFO`) **7968**. `pe-structure.md:139-148` 의 값과 완전 일치. linker version 도 `0e 33` = **14.51** 로 `.json` 과 일치(`.md` 의 옛 `14.0` 은 이미 정정됨).
3. **`evidence-index.tsv` 관련 측정 전건 재현.** 엔진 클래스 11종 grep → **0**; `rtti_classes` 비어있지 않은 행 **5584**, 자기참조 **4735**; `format_magics` 14 / `api_calls` 44 / `key_strings` 33; `xref-index.tsv` `rtti_classes` 4 · `imported_apis` 66 · `filename_strings` 46. 데이터 행 7,748. 산문 §9 item 4 의 숫자와 전부 일치.
4. **`inject_rich_header.py` 의 새 `.reloc` 축이 실제로 작동한다.** 저장소 PE 8개(`binaries/` 6 + `distribution/` 2) 전부 `--verify-only` EXIT=0 · 블록이 디렉터리 크기를 정확히 타일링. `wallpaper32.exe` 의 모든 `PointerToRawData` 에 +0x200 을 더한 사본을 만들면 문서가 적어둔 그대로 `[ok] .text RawPtr 0x600 first bytes: 07 00 00 00 c7 05 fc 96` + `[!] .reloc block chain is inconsistent (block 0 SizeOfBlock 0x3ac23ab3 …)` · EXIT=1 이 재현된다. `inject()` 의 새 섹션 본문 대조도 shift 회귀를 반드시 잡는 구조다.
5. **D3D11 훅 슬롯 정정이 옳고 잔여 오류가 없다.** `quick/v17/late_attach` 의 CreateBuffer=3 · CreateTexture2D=5 · VS=12 · PS=15, `D3D11CreateDevice` 인자 10개(`ppDevice=args[7]`)로 모두 통일. 손대지 않은 `scan/validate/minimal/identify_device_vtable` 은 처음부터 옳았고, `v17.js:166-167` 의 컨텍스트 슬롯(DrawIndexed=12, Draw=13)도 정확하다. 인용한 `analysis/d3d_scan.log:9,297-299` 줄 내용도 일치.
6. **`DumpSceneScriptTargets.py` 정정 주석의 교차확인 전건 일치**: `ghidra_logs/decompile_scenescript64.log:45-47` 의 `.java` 실행 + EXIT=0, `manifest.txt` 형식이 `.java:64-65` 의 것, NO_FUNCTION 6 / 해소 3. `.py` 의 `int(str(addr))` 버그 진단도 정확(6번째 주소에서 반드시 죽는다).
7. **결정성·재현성**: `BuildEvidenceIndex.java:51` · `DecompileAll.java:87` 이 `TreeSet` 이라 TSV 순서가 결정적. `parse_pe.py` 재실행 산출물이 커밋본과 diff 0. `analysis/strings/d3d-dxgi.txt` 오프셋 14/14 일치. `corpus_scan` 도수(11,338 paths / 446 scenes / parse-errors 헤더만)와 `ghidra_logs/analyze_scenescript64.log` 32,180줄, `du` 크기(492M/50M/46M/44M/3.8M/84K/620K/55M/1.1G/.git 967M/총 2.6G) 전부 문서와 일치. (문서가 적은 `analysis/reports` 76K→84K, `scripts` 224K→244K 는 그 측정 이후 같은 트리에서 파일이 더 커진 결과라 결함으로 보지 않았다.)
8. **산문의 `[미해결]` 은 1건뿐**(`:522`, `0x14015e580` ↔ `Texture::ReadTextureData` 이름 결합)이고, Waple 이 확정한 것과 충돌하지 않는다. M19 부류의 잔존은 산문이 아니라 F4 의 형제 리포트 쪽이다.
