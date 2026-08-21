# `.pkg` 컨테이너와 `project.json` 매니페스트 — 로더 전표 + 동봉 전수 대조

**조사일 2026-08-21 · WE 2.8.42 `wallpaper64.exe` (md5 `438cb215f20a8f6c38f57fbc3d9da588`, imagebase `0x140000000`)**
**대상: 설치본 `/home/user/Waple-wallpaper-source/wallpaper_engine/` + 동봉 자산 `Sources/WapleRender/Resources/WEAssets/` — 9,078 파일 1.20 GB 전수**

## 0. 결론

| 항목 | 판정 |
| --- | --- |
| 이 환경의 실물 `.pkg` | **0개.** 두 루트 9,078 파일 전건에서 **첫 4 KiB 에** `PKGV` **0건**. `find -iname '*.pkg'` 도 0건 (파일 **내부** 리터럴은 별개다 — `wallpaperui.exe` 에 2건, §2.2b·부록 A.8) |
| 워크샵 코퍼스 도수 | 실물 pkg 는 없어도 **전수 스캔 산출물이 트리에 있다** — `Waple-wallpaper-source/corpus_scan/*.tsv`. 446 폴더 · `scene.pkg` **161** · 엔트리 **19,777** · **8.89 GiB** · 경로 종수 **11,338** · 파스 오류 **0** (§1.1b) |
| 경로 위생 실측 | 11,338 엔트리 경로 중 역슬래시 **0** · `..` **0** · 절대경로 **0**. 반대로 대문자 보유 **3,061**(27.0%) — 정규화가 일하는 자리는 대소문자다 (§1.1c) |
| 그래서 무엇으로 확정했나 | **로더 디스어셈**(`0x140276700`)이 1차 근거. 합성 `.pkg` 왕복 + 실물 페이로드 LZ4 해제로 교차검증 |
| 컨테이너 압축 | **없다.** TOC·페이로드 모두 무압축. `LZ4_decompress_safe`(`0x14014c160`) 를 부르는 곳은 `wallpaper64.exe` 전체에 **호출 지점 4 · 함수 2**(`0x1400ce760`·`0x14015c8d0`)이고 **전부 `.tex` 경로**다 (2026-08-21 재측정 — 종전 표기 "2곳" 은 함수 수였다) |
| LZ4 실측 | 순수 파이썬 LZ4 블록 디코더로 **해제 성공**. `effectpreview.tex` mip0 47,371 → 262,144 B, 합성 pkg 슬라이스에서 뽑은 사본과 **바이트 동일** |
| 매직 검증 | 읽는 쪽 WE 는 `"PKGV"` 를 **비교하지 않는다** — `wallpaper64.exe` **전역에 그 4바이트가 0건**이다(쓰는 쪽 `wallpaperui.exe` 에는 2건 — §2.2b). `atoi(magic+4) > 24` 만 거부(`0x140276964`) |
| 엔트리 키 정규화 | 바이트별 C `tolower` **뿐**(`0x140276ac4`·`0x140274003`). 역슬래시→슬래시 변환 **없음** |
| **엔트리 표의 정체** | **[2026-08-21 신규]** 이름을 **제자리에서** 접어(`0x140276ac0`–`0x140276ad6`) 그대로 키로 쓰는 `unordered_map` **하나**다. 대소문자를 보존하는 색인이 **없다** — WE 는 `A.tex` 와 `a.tex` 를 **구별하지 못한다** |
| **중복 접힌 키의 승자** | **[2026-08-21 신규] 마지막 엔트리가 이긴다.** 삽입은 find-or-emplace(`0x140276ae4`→`0x140277890`)인데 호출부가 **조건 없이** offset/size 를 덮어쓴다(`0x140276aef`·`0x140276af5`). Waple 은 반대(first-wins)였다 — §7.8 에서 고쳤다 |
| 엔트리 루프의 종단 조건 | **고정 횟수뿐**(`0x1402769a0` `r12d=0` … `0x140276b3c cmp r12d,[rbp+0x77]` / `0x140276b40 jl`). 센티널도, **스트림 상태 검사도 없다** — 잘린 파일도 0(성공)으로 끝난다 |
| `scene.pkg` vs `scene.json` | 우선순위 다툼이 **없다.** `project.json` 의 `file` 이 단독 결정자고, `.pkg` 는 그 파일이 **디스크에 없을 때만** 시도하는 폴백이다(`0x14011e330`–`0x14011e3f9`) |
| `project.json` `type` | **읽히지 않는다.** `file`(또는 `dependency`) 확장자로 유도해 `type` 을 **덮어쓴다**(`0x14011e520` → `0x14011e300`) |
| `contentrating`/`tags`/`visibility`/`approved` | `wallpaper64.exe` 에 문자열조차 **없다** — 런타임이 안 읽는다(`wallpaperui.exe` 전용) |
| 씬 문서 이름 | `stem(file) + ".json"` 이다 — `filename()` 이 **아니다**(`0x14010e22a`·`0x14010e253`, §4.3.1). 2026-08-21 정정 |
| Waple 갭 | 마운트 선택자 1건(고), 타입 유도표 1건(중), 정규화·게이트 3건(저) — §7. **2026-08-21 에 5건 처리**, 미처리 §7.7 1건(저). **2026-08-21 2차: §7.8(중복 접힌 키 승자, 고) 신규 확정 + 처리** |

---

## 1. 실물 도달 실측

### 1.1 `.pkg` 파일 (과제 6항)

| 루트 | 파일 | 바이트 | `.pkg` 확장자 | `PKGV` 매직 보유 |
| --- | --- | --- | --- | --- |
| `wallpaper_engine/`(설치본 전체) | 6,138 | 1,122,265,206 | **0** | **0** |
| `WEAssets/`(동봉 사본) | 2,940 | 79,515,997 | **0** | **0** |
| 합계 | 9,078 | 1,201,781,203 | **0** | **0** |

확장자만 본 게 아니라 **모든 파일의 첫 4 KiB 에서 `PKGV` 를 찾았다** — 다른 확장자로 위장한
패키지도 없다. 시스템 전역 `find / -iname '*.pkg'` 는 Go 툴체인 테스트 픽스처 4건뿐이다.

**따라서 "동봉 `.pkg` 평균 엔트리 수"·"총 바이트" 는 이 환경에서 산출할 수 없다 — 표본이 0이다.**

### 1.1b 워크샵 코퍼스 — 실물 `.pkg` 는 없어도 **전수 스캔 산출물은 이 트리에 있다**

**[2026-08-21 추가]** 종전 이 절은 "워크샵 코퍼스는 이 환경에 없음 → `spec/` 에 굳은 값만 인용"
으로 끝났다. 그 서술은 **`spec/` 밖의 산출물을 놓친다**. `Waple-wallpaper-source/corpus_scan/`
에 같은 워크샵 루트(`Z:\SteamLibrary\steamapps\workshop\content\431960`)를 전수로 돈
`pkgv_census.py` 의 **출력 TSV 가 그대로 들어 있다** — `scenes-index.tsv`(폴더별 1행),
`entry-name-frequency.tsv`(엔트리 경로 도수), `chunk-type-census.md`(내용 스니핑 도수),
`parse-errors.tsv`(헤더뿐, 본문 0행). 즉 pkg 자체는 없어도 **도수는 전부 재집계 가능**하다.

| 값 | 수 | 산출 |
| --- | --- | --- |
| 워크샵 폴더 | **446** | `scenes-index.tsv` 행수 |
| `pkgv_census.py` 분류기 타입 | scene **162** · video 145 · web 138 · unknown 1 | 같은 파일 2열 |
| `scene.pkg` 보유 폴더 | **161** | 6열 합 (타입 scene 인데 pkg 없는 폴더가 1건 — `1612750231`, 파일 3개) |
| 파스 오류 | **0** | `parse-errors.tsv` 본문 0행 |
| 엔트리 총계 | **19,777** | 7열 합 |
| pkg 당 엔트리 | 최소 **4** · 중앙값 **103** · p90 **210** · 최대 **1,175** · 평균 **122.84** | 7열 분포 |
| pkg 총 바이트 | **9,547,122,275** (≈8.89 GiB) | 4열 합. 최대 단일 pkg **712,246,205 B**(≈679 MiB, `3429479356`) |
| 엔트리 경로 종수 | **11,338** | `entry-name-frequency.tsv` 행수 |

> **[2026-08-21 라벨 정정]** 위 2열을 종전에는 "`project.json` 유도 타입" 이라 적었다. 그 이름은
> **WE 의 유도(§5.3, `type` 을 무시하고 `file` 확장자로 정함)를 뜻하는 것처럼 읽힌다.** 실제로는
> `pkgv_census.py` 의 `classify_wallpaper` 이고, 그것은 `type` 이 있으면 **그것을 그대로 쓴다** —
> 곧 WE 규약이 아니라 Waple 과 같은 `type` 우선 규약이다. §7.2 ⑷ 의 도달을 이 열로 재면 안 된다.

**`spec/` 의 162 와 여기 161 은 모순이 아니다 — 분모가 다르다.** `scripts/spec/measure_corpus.py`
는 폴더마다 `scene.pkg` **와 `gifscene.pkg` 를 둘 다** 연다(`for fn in ("scene.pkg", "gifscene.pkg")`).
`pkgv_census.py` 는 `scene.pkg` 만 본다. 차이를 그대로 빼면 그 한 개의 `gifscene.pkg` 를 복원할 수 있다:

* pkg 수 162 − 161 = **1**
* 엔트리 19,781 − 19,777 = **4**
* 확장자 델타: `.json` 10,470 − 10,467 = **+3**, `.tex` 4,680 − 4,679 = **+1**, **나머지 10종 전부 0**

→ **워크샵 코퍼스의 유일한 `gifscene.pkg` 는 엔트리 4개(`.json` 3 + `.tex` 1)** 다. 이건 §4.3.1 의
`stem(file) + ".json"` 규칙과도 맞물린다(`gifscene.pkg` 안의 씬 문서 이름은 `gifscene.json`).

#### 엔트리 확장자 도수(161 pkg · 19,777 엔트리)

| 확장자 | 수 | 내용 스니핑 타입 | 수 |
| --- | ---: | --- | ---: |
| `.json` | 10,467 | `json` | 10,467 |
| `.tex` | 4,679 | `tex` | 4,679 |
| `.frag` | 1,689 | `glsl-frag` | 1,689 |
| `.vert` | 1,689 | `glsl-vert` | 1,689 |
| `.mdl` | 423 | `mesh`(MDLV) | 423 |
| `.mp3` | 338 | `mp3` | 336 |
| `.ttf`/`.otf`/`.ttc` | 225/144/3 | `font` | 372 |
| `.wav` | 70 | `wav` | 68 |
| `.ogg` | 44 | `ogg` | 48 |
| `.flac` | 6 | `flac` | 6 |

**확장자와 내용이 어긋나는 엔트리는 정확히 4개**다 — Ogg 컨테이너인데 `.mp3`(2건) 또는 `.wav`(2건)
이름을 달았다(338−336 = 2, 70−68 = 2, 44+4 = 48). Waple 의 오디오 경로는 확장자가 아니라 내용으로
갈라야 이 4건이 산다(범위 밖 — 미디어 클러스터에 넘김).

**`.dxs`·`.png`·`.mp4` 엔트리는 0건이다.** 곧 `.pkg` 안에서 만나는 파일 종류는 위 12 확장자가 전부다.

#### 씬 문서는 예외 없이 루트의 `scene.json` 이다

`entry-name-frequency.tsv` 에서 **디렉터리 성분이 없는 경로는 딱 하나**고, 그 하나가
`scene.json` 이며 도수가 **161** — 즉 **161개 pkg 전건**에 있다. 다른 이름의 루트 문서도,
하위 디렉터리에 놓인 씬 문서도 0건이다.

이 사실이 §4.3.1 의 [미해결](`file:"techno.pkg"` 이면 WE 는 `stem + ".json"` = `techno.json` 을
여는데 Waple 은 `project.fileName` 을 그대로 넘긴다)의 **도달을 0으로 만든다**: 워크샵 pkg 는
전건 `scene.pkg` + 내부 `scene.json` 이라 stem 규칙과 하드코딩이 같은 답을 낸다. 그 갭은
`gifscene.pkg`(코퍼스 1건, 내부에 `.json` 3개 중 하나가 `gifscene.json` 일 것)와, 아직 관측되지
않은 임의 이름 pkg 에서만 갈린다.

참고로 최빈 비-루트 엔트리는 전부 `waterwaves` 효과 세트다 —
`shaders/effects/waterwaves.frag`·`.vert`, `effects/waterwaves/effect.json`,
`materials/effects/waterwaves.json` 이 각각 **83/161**(51.6%). 워크샵 씬의 절반이 이 효과를
쓴다는 뜻이라, 효과 파리티 우선순위의 근거로 쓸 수 있다.

### 1.1c 엔트리 경로 위생 — 전수 11,338 종

경로 탈출 방어(`WallpaperPathSecurity`)가 무엇을 막고 있고 **실제로 얼마나 밟히는지**의 실측이다.

| 성질 | 종수 | 비율 |
| --- | ---: | --- |
| 역슬래시 `\` 포함 | **0** | — |
| `..` 성분 포함 | **0** | — |
| 절대경로(`/…` 또는 `X:`) | **0** | — |
| 선행 `./` · `//` · 양끝 공백 | **0** | — |
| 대문자 ASCII 포함 | **3,061** | 27.0% |
| 비-ASCII 포함(한자·키릴) | **2,422** | 21.4% |
| ASCII 폴딩 ≠ 유니코드 폴딩 | **114** | 1.0% (갈리는 문자 136개 **전부 키릴**) |
| 최대 경로 깊이 | 6 성분 | — |
| 최대 이름 길이 | 266 B | — |

최상위 디렉터리: `materials` 7,137 · `models` 2,320 · `shaders` 664 · `sounds` 455 · `effects` 281 ·
`particles` 278 · `fonts` 172 · `scripts` 30 · 루트 직속 1.

**읽히는 결론 셋**

1. **경로 탈출 방어는 코퍼스 도달 0이다.** 역슬래시·`..`·절대경로가 전건 0이므로
   `WallpaperPathSecurity.normalizedRelativePath` 의 거부 분기는 워크샵 실물에서 한 번도 안 걸린다.
   방어를 뺄 이유는 되지 않는다(신뢰 경계는 코퍼스가 아니라 위협모델이 정한다) — 다만 **"엄격해서
   실물이 깨진다" 는 반론도 실측으로 반증된다**는 뜻이다.
2. **대소문자 정규화는 반대로 도달이 크다** — 27.0%(3,061종)가 대문자를 갖는다. 이 3,061 이 곧
   실패 건수는 아니다(조회 쪽 철자가 같으면 접힌 키도 같은 답을 낸다 — **[2026-08-21 정정]**
   종전 이 괄호는 "정확 일치가 먼저 이긴다" 였는데, `.pkg` 백엔드에는 이제 접힌 색인 하나뿐이라
   그 표현이 틀렸다. §7.8). **정규화 색인이 일할 수 있는
   후보의 상한**이 이만큼이라는 뜻이고, `scene.json` 이 참조 문자열을 어떻게 적었느냐가 실제
   도달을 정한다 — 그건 이 산출물로는 못 잰다(엔트리 이름만 있고 참조 문자열이 없다).
3. **ASCII 폴딩과 유니코드 폴딩이 갈리는 이름이 114종 있다**(전부 키릴 대문자). 그런데 폴딩 충돌군은
   ASCII 14군 · 유니코드 14군으로 같고 **유니코드에서만 생기는 충돌은 0군**이다. 그래서
   `ScenePackage.asciiLowercased` 로의 전환은 무회귀다 — "갈리는 이름이 없어서" 가 아니라
   **갈리는 114종이 아무와도 충돌하지 않아서**다(종전 주석은 전자로 적혀 있었다. 표본이
   `spec/corpus/workshop-shaders.json` 부분집합이었던 탓이다).

#### `maxEntries = 65_536` 방어선의 여유

관측 최대 엔트리 수는 **1,175**(pkg 하나). 방어선은 그 **55.8배** 위다 — 실물을 거부할 여지가 없다.
같은 근거로 `ScenePackage.parse` 의 `count <= maxEntries` 는 §7 의 "엄격 이탈" 목록에 들어가지 않는다.

### 1.1d `spec/` 에 굳어 있는 값(재현 불가, 인용만)

| 값 | 수 | 출처 |
| --- | --- | --- |
| 파싱한 pkg | 162 (= `scene.pkg` 161 + `gifscene.pkg` 1, §1.1b) | `spec/corpus/inventory.json` `corpus.pkgParsed` |
| 파스 오류 | 0 | 같은 파일 `corpus.pkgParseErrors` |
| 엔트리(알려진 확장자만) | 19,781 | `corpus.entryExtensions` 합 → **pkg 당 122.1** (파생치, 확장자 없는 엔트리 미포함) |
| 매직 분포 | `PKGV0002·0007·0008·0011·0012·0016`~`0024` 14종, 최빈 `0023`×50, 최대 `0024`×13 | `spec/formats/pkg.json` `format.pkg.magicDistribution` |

관측 최대 버전 `0024` 가 §2.2 의 엔진 상한(`atoi(magic+4) <= 24`)과 **정확히 같다** — 즉 이 상한은
"미래 여유" 가 아니라 **현재 최신 버전에 딱 붙어 있는** 값이다.

### 1.2 `project.json` 361건 전수 (과제 4·5항의 실측 기반)

| 최상위 키 | 도수 | 엔진이 읽나 |
| --- | --- | --- |
| `file` | 361 | **읽는다**(§5) |
| `title` | 359 | 읽는다 — 없으면 폴더명으로 채움 |
| `general` | 341 | 읽는다(`general.properties`) |
| `type` | 288 | **안 읽는다** — 유도해서 덮어씀 |
| `version` | 175 | 이 만큼도 안 읽는다(§5.5) |
| `official` | 19 | 문자열 부재 |
| `preview` | 19 | 읽는다(절대경로화) |
| `authorsteamid` | 12 | 문자열 부재 |
| `visibility` | 10 | `wallpaper64.exe` 문자열 부재 |
| `timestamp` | 4 | 문자열 부재 |
| `description` | 3 | 기록 전용(§5.5) |
| `templateoptions` | 3 | 문자열 부재 |
| `approved` | 2 | 문자열 부재 |
| `contentrating` | 2 | `wallpaper64.exe` 문자열 부재 |
| `tags` | 2 | `wallpaper64.exe` 문자열 부재 |

`type` 원문: `scene` 286 · **키 없음 73** · `web` 2 (설치본은 전건 소문자다 — 대소문자 혼용은 워크샵 쪽 문제).
`file` 확장자: `.json` 358 · `.html` 2 · `.exe` 1. `file` 값: `scene.json` 353, 그 외 `ricepod.json`
`fantasticcar.json` `techno.json` `audiophile.json` `gifscene.json` `index.html` `sheep.exe` 각 1.

**설치본 361건 중 `file` 이 `.pkg` 인 것은 0건이고, `file` 이 디스크에 없어 `.pkg` 폴백이 도는
경우도 0건이며, `file` 과 같은 stem 의 `.pkg` 가 병존하는 경우도 0건이다.**
즉 §6 의 우선순위 규칙은 이 코퍼스로는 **분기 자체가 안 도는** 규칙이고, 코드로만 확정된다.

---

## 2. 컨테이너 레이아웃

### 2.1 바이트 오프셋 표

문자열은 전부 **i32 길이 접두 + 널 종단 없음**이다. 정수는 전부 **리틀엔디언 i32**(`std::istream::read`
로 메모리에 그대로 얹는다 — `0x14004aa50`, 엔디언 변환 없음). **정렬·패딩 없음.**

| 오프셋 | 필드 | 크기 | 읽는 VA | 비고 |
| --- | --- | --- | --- | --- |
| 0 | `magicLen` | i32 | `0x140060746` | `> 8` 이면 매직을 **빈 문자열로 만들고 바이트를 안 먹는다**(`0x140060752`) |
| 4 | `magic` | `magicLen` B | `0x1400607fd` | 실물은 `"PKGV%04d"` 8B. **엔진은 접두를 비교하지 않는다** |
| 4+`magicLen` | `entryCount` | i32 | `0x14027698d` | 부호 있음. `<= 0` 이면 엔트리 표를 건너뛰고 **성공 반환** |
| — | 엔트리 레코드 × `entryCount` | | | 아래 |
| = TOC 끝 | `dataBase` | — | `0x140276b4d`(tellg) | 여기부터 페이로드 |

엔트리 레코드(연속, 패딩 없음):

| 상대 오프셋 | 필드 | 크기 | 읽는 VA | 비고 |
| --- | --- | --- | --- | --- |
| +0 | `nameLen` | i32 | `0x1402769b0` | `> 0x800` 이면 이름을 **빈 문자열로 만들고 바이트를 안 먹는다**(`0x1402769bb`) |
| +4 | `name` | `nameLen` B | `0x140276a4d` | UTF-8. 적재 즉시 **바이트별 `tolower`**(`0x140276ac0`–`0x140276ad6`) |
| +4+`nameLen` | `offset` | i32 | `0x140276a70` | **`dataBase` 상대**. 적재 후 전 엔트리에 `dataBase` 가산(`0x140276b63`) |
| +8+`nameLen` | `size` | i32 | `0x140276a82` | 바이트 수 |

페이로드는 `dataBase + offset` 부터 `size` 바이트. **엔트리별 헤더도, 압축도, 정렬도 없다.**

> **[2026-08-21 독립 재확인]** 위 표의 VA 를 **다시 떠서** 전부 맞는 것을 확인했다(남의 주석을
> 베끼지 않았다는 기록). 확인한 것:
> `0x14027692f mov r8d, 8`(매직 maxLen=8) → `0x140276941 call 0x140060720` ·
> `0x140276946 cmp qword [rbp+0xf], 4 / jbe`(길이>4 일 때만 버전) ·
> `0x14027695f call atoi` · `0x140276964 cmp eax, 0x18 / jle`(≤24 통과) ·
> `0x14027698d call ReadRaw(4)`(entryCount) → `0x140276996 jle`(≤0 이면 표 건너뜀) ·
> `0x1402769b0 call ReadRaw(4)`(nameLen) → `0x1402769bb cmp eax, 0x800 / jbe` ·
> `0x140276a4d`(이름) · `0x140276a70`(offset) · `0x140276a82`(size) ·
> `0x140276ac0 movsx ecx, byte [r14] / 0x140276ac4 call 0x1402bfb1c`(바이트별 tolower) ·
> `0x140276b46 call tellg` → `0x140276b63 add dword [rax+0x30], edx`(전 엔트리에 dataBase 가산).
>
> 두 가지를 더 확정했다.
> ① **길이 접두 문자열 리더(`0x140060720`)의 초과 처리.** `0x140060752 cmp eax, ebx / jbe` 는
>    **무부호** 비교다. `len > maxLen` 이면 `0x140060756`–`0x14006076c` 가 문자열을 **빈 문자열로
>    초기화하고 그대로 반환**한다 — 스트림에서 **한 바이트도 먹지 않는다**. 무부호라서 음수 길이
>    (`0xFFFFFFFF`)도 같은 가지로 간다.
> ② **`tolower`(`0x1402bfb1c`)의 빠른 경로가 정말 ASCII 뿐이다.**
>    `0x1402bfb34 lea eax,[rcx-0x41] ; cmp eax,0x19 ; ja ; add ecx,0x20` — `'A'..'Z'` 만 +0x20 이고
>    그 밖은 원본 그대로다(로케일이 설정돼 있으면 `0x1402bf8b4` 로 새지만, 기본 "C" 로케일에서
>    `0x1404e45dc == 0` 이라 빠른 경로다). `ScenePackage.asciiLowercased` 가 이것과 같다.
>
> VFS 조회 쪽(`0x140273f50`)도 다시 떴다: 키 정규화는 `0x140274000`–`0x140274015` 의
> **바이트별 tolower 루프뿐**(역슬래시 치환 없음)이고, 해시 히트 뒤
> `0x14027412a cmp dword [rbx+0x34], 0 / jle 0x140274161` 이 **크기 ≤ 0 을 "못 찾음" 과 같은
> 자리로** 보낸다(엔트리 구조체 +0x30 = offset, +0x34 = size — 위 `add [rax+0x30], edx` 와 정합).

### 2.1b 엔트리 표는 **접힌 키 하나짜리 맵**이고, 중복 키는 **뒤가 이긴다**

**[2026-08-21 신규 — 이 조사에서 새로 확정]** 종전 §2.1·§4.2 는 "이름을 tolower 한다" 까지만
적고 **그 접힌 이름이 유일한 키라는 것**과 **중복 시 누가 이기는지**를 적지 않았다. 둘 다
관측 가능한 사실이고, 둘 다 Waple 이 갈려 있었다(§7.8).

로더를 `.pdata` 함수 시작(`0x140276700`)에서 선형으로 다시 떠서 확인한 것:

```
0x140276ac0  movsx ecx, byte ptr [r14]      ; 소스 바이트
0x140276ac4  call 0x1402bfb1c               ; CRT tolower ('A'..'Z' 만 +0x20)
0x140276ac9  inc  r14
0x140276acc  mov  byte ptr [r15], al        ; **같은 버퍼에 되쓴다** (r15 초기값 = r14 초기값)
0x140276acf  lea  r15, [r15 + 1]
0x140276ad3  cmp  r14, rbx ; jne 0x140276ac0
0x140276ad8  lea  r8,  [rbp - 0x61]         ; ← 접힌 문자열이 그대로 키다
0x140276adc  lea  rdx, [rbp - 0x41]         ; out pair<iterator,bool>
0x140276ae0  lea  rcx, [r13 + 0x38]         ; 맵
0x140276ae4  call 0x140277890               ; find-or-emplace
0x140276ae9  mov  rcx, qword ptr [rax]      ; 노드
0x140276aec  mov  eax, dword ptr [rbp + 0x7f]
0x140276aef  mov  dword ptr [rcx + 0x30], eax   ; offset  ← **무조건 덮어쓴다**
0x140276af2  mov  eax, dword ptr [rbp - 0x69]
0x140276af5  mov  dword ptr [rcx + 0x34], eax   ; size    ← **무조건 덮어쓴다**
```

삽입 함수 `0x140277890` 이 하는 일도 직접 떴다. FNV-1a 64
(`0x1402778b4 movabs rdi, 0xcbf29ce484222325` · `0x1402778c3 movabs r9, 0x100000001b3`,
바이트 루프 `0x1402778d0`)로 해시를 만들고 `0x1402778f2 call 0x1400110a0` 으로 버킷을 뒤진 뒤

* **찾았으면** `0x140277901 mov [r15], rax` / `0x140277907 mov byte [r15+8], 0`
  (= `pair<iterator,bool>.second = false`) 로 **기존 노드를 그대로 돌려준다**,
* **없으면** `0x140277930 mov ecx, 0x38` → `0x14027793a call operator new` 로 노드를 만든다.

즉 **매핑된 값을 갱신하는 것은 삽입 함수가 아니라 호출부**이고, 호출부에는 분기가 없다.
⇒ **같은 접힌 키가 두 번 오면 뒤에 온 엔트리의 offset/size 가 남는다.**

조회 쪽(`0x140273f50`)도 같은 그림이다 — 요청을 같은 방식으로 접고
(`0x140274000`–`0x140274015`) FNV-1a 로 버킷을 잡아(`0x14027402b`·`0x140274040`·`0x140274068`)
길이 비교 + `memcmp`(`0x1402740b8`)로 확정한 뒤 끝난다. **대소문자를 보존한 2차 조회가 없다.**

> **따름 정리**: WE 는 한 `.pkg` 안에서 `materials/Background.json` 과
> `materials/background.json` 을 **같은 파일로 본다**. 둘 다 있으면 뒤엣것 하나만 열린다.
>
> **반대로 구분자는 접지 않는다.** 위 두 루프 어디에도 `\`↔`/` 치환이 없다 —
> `Models\A.JSON` 의 키는 `models\a.json` 이고 `models/a.json` 과 **다른 칸**이다.
> Waple 의 역슬래시 관용은 그래서 WE 키 색인이 아니라 **2차 폴백**에만 있어야 한다(§7.8 주의).

**도달** — 워크샵 전수(`corpus_scan/entry-name-frequency.tsv`, `scene.pkg` 161개 · 경로 11,338 종 ·
출현 19,777건)에서 ASCII 폴딩 충돌군은 **14군**이다:

| 접힌 키 | 원문(도수) |
| --- | --- |
| `models/background.json` | `models/background.json`(4) · `models/Background.json`(2) |
| `materials/background.json` | `materials/background.json`(4) · `materials/Background.json`(2) |
| `materials/background.tex` | `materials/background.tex`(3) · `materials/Background.tex`(1) |
| `models/bg.json` · `materials/bg.json` · `materials/bg.tex` | 각 소문자(2) · `BG`(1) |
| `materials/mask.tex` · `{materials,models}/moon.json` · `materials/moon.tex` | 각 (1) · (1) |
| `{materials,models}/layer 4.*` (3군) | `layer 4`(1) · `Layer 4`(1) |
| `models/sky/sky.mdl` | `models/sky/sky.mdl`(1) · `models/Sky/Sky.mdl`(1) |

**이 산출물로는 "한 pkg 안에 둘 다 있는가" 를 못 잰다** — 경로별 도수만 있고 pkg 별 보유가
없다. 비둘기집으로 **강제되는** 동시 보유는 0건이고(최대 군 합계 6 ≪ 161), 상한은
Σmin(도수) = **16 pkg / 161**(9.9%)이다. 곧 도달은 **0 이 아니라 미측정이고 구간이 [0, 16]** 이다.
근거는 코퍼스가 아니라 위 디스어셈이다.

### 2.2 버전 게이트

```
0x140276941  call 0x140060720          ; ReadLengthPrefixedString(stream, &magic, maxLen=8)
0x140276946  cmp  qword [rbp+0xf], 4   ; magic.size() > 4 일 때만 버전을 본다
0x14027694b  jbe  0x140276980          ;   4 이하면 **버전 검사를 통째로 건너뛴다**
0x14027695f  call 0x1402c82c0          ; atoi(magic.c_str() + 4)
0x140276964  cmp  eax, 0x18
0x140276967  jle  0x140276980          ; version <= 24 만 통과 (부호 있는 비교)
0x14027696c  lea  rcx, [rip+0x21b975]  ; 0x1404922e8 "Cannot open %s, version %i not supported.\n"
```

**`"PKGV"` 접두 비교가 없다.** **`wallpaper64.exe`** 전역에서 ASCII `PKGV` 는 **0건**이다
(§2.2b 가 곧바로 정정하듯 이 문장은 **읽는 바이너리 한정**이다 — 쓰는 쪽 `wallpaperui.exe` 에는
2건 있다. 부록 A.8 이 152개 바이너리 전수 도수를 준다.) 대비: `TEXV0005` 와
`MDLV0023` 은 각각 `0x14048b910`·`0x140492318` 에 리터럴로 있고 `memcmp` 로 비교된다.
즉 WE 가 보는 건 **"5~8바이트 문자열이고, 4번째 글자부터가 24 이하 정수로 읽힌다"** 뿐이다.
`atoi` 규약상 숫자가 아니면 0 이므로 `"XXXX????"` 도 통과한다.

#### 2.2b 쓰는 쪽은 `wallpaperui.exe` 다 — 거기엔 `"PKGV0024"` 가 리터럴로 있다

**[2026-08-21 추가]** 위 문단(과 `ScenePackage.swift` 주석)은 "`PKGV` 는 **바이너리에** 0건" 이라고만
적어 두었다. 그 서술은 `wallpaper64.exe` 에 한정할 때만 참이다. 실측:

| 바이너리 | `PKGV`(ASCII) | `PKGV`(UTF-16LE) |
| --- | ---: | ---: |
| `wallpaper64.exe` (5,360,112 B, 업로드본과 md5 동일) | **0** | **0** |
| `wallpaperui.exe` (12,742,640 B) | **2** | 0 |

두 건의 정체가 결정적이다.

* 파일 오프셋 `0xad0898` — `"unpackProject\0steamtrackhours\0-o\0-i\0**PKGV0024**\0packProject\0…"`.
  곧 **패커/언패커 CLI 배선 바로 옆에 현행 버전 문자열이 하드코딩**돼 있다.
* 파일 오프셋 `0xab2876` — `"getWallpaperResolutions\0**checkWallpaperPKGVersions**\0toggleMiniMode\0…"`.
  이건 UI 브리지 메서드 이름이고, `ui/dist/scripts/scripts.js` 가 실제로 부른다:
  `callDeferred("browseWallpaperObject", "checkWallpaperPKGVersions", device.mpkgsupport||0, isExporting, files)`
  → `{status, versions}` 를 받아 배경마다 검사한다.

**이 둘이 "4자리 = 버전" 을 독립적으로 확정한다.** ① 쓰는 쪽이 **단일 상수**를 찍는다면 파일마다
달라지는 난수 serial 일 수 없다. ② UI 가 그 값을 **기기 지원 수준(`mpkgsupport`)과 대조**한다 —
serial 에는 대조할 대상이 없다. ③ 그 상수 `0024` 가 코퍼스 최대값(§1.1d)과도, 리더 상한
`atoi(magic+4) <= 24`(위 `0x140276964`)와도 **정확히 같다**.

그래서 리더에 접두 비교가 없는 이유도 설명된다 — **읽는 바이너리와 쓰는 바이너리가 다르고, 읽는
쪽은 자기 포맷만 열면 되니 매직을 신뢰 입력으로 안 본다**. 대비되는 `TEXV0005`/`MDLV0023` 은
`wallpaper64.exe` 안에 각각 1건씩 리터럴로 있고 `memcmp` 로 비교된다(실측: 그 두 문자열의
`wallpaper64.exe` 내 출현 수는 각각 1).

### 2.3 상한과 방어 (엔진이 실제로 두는 것)

| 대상 | 상한 | VA | 위반 시 |
| --- | --- | --- | --- |
| `magicLen` | ≤ 8 | `0x140060752` | 빈 문자열 반환, **스트림 미전진** → 이후 파스 전체가 밀린다 |
| 버전 | ≤ 24 | `0x140276964` | 에러 로그 + 반환 2 |
| `nameLen` | ≤ 0x800 (2048) | `0x1402769bb` | 빈 이름, **스트림 미전진** → 이후 파스 전체가 밀린다 |
| `entryCount` | **상한 없음** | — | 음수·0 은 빈 패키지로 성공 처리 |
| `offset`/`size` | **검증 없음** | — | 그대로 `seekg`/길이 상한에 실림 |

**[2026-08-21 추가] 엔트리 루프의 종단 조건은 고정 횟수뿐이다.** `.mdl` 처럼 "빈 cstring 이면
끝" 같은 센티널이 있는지 확인했는데 **없다**. 루프는 `0x1402769a0 mov r12d, r15d`(= 0)로 시작해
`0x140276b33 inc r12d` · `0x140276b3c cmp r12d, dword [rbp+0x77]` · `0x140276b40 jl 0x1402769a3`
로만 돈다. 그리고 루프 안에서 부르는 것은 `0x14004aa50`(read) · `0x1402bfb1c`(tolower) ·
`0x140277890`(map insert) · 문자열 할당/해제뿐 — **스트림 상태(failbit/eofbit)를 보는 자리가
없다.** 파일이 중간에서 잘리면 읽기가 실패한 채로 직전 반복의 스택 값이 그대로 엔트리로 쌓이고,
그래도 반환은 `0x140276b6e mov esi, r15d`(= 0, 성공)다.

Waple 은 경계를 넘는 순간 `malformed` 로 끊는다(잠금:
`ScenePackageWEParityTests.testTruncatedEntryTableIsRejectedUnlikeWE`).

두 "미전진" 경로는 방어라기보다 **버그에 가깝다**(스트림을 되돌리지도, 실패로 끊지도 않는다).
Waple 은 두 경우 모두 `malformed` 로 끊으므로 **더 안전한 쪽**이고, 이 차이는 정상 파일에서
관측되지 않는다.

### 2.4 반환 코드

| 값 | 뜻 | VA |
| --- | --- | --- |
| 0 | 성공 | `0x140276b6e` |
| 1 | 파일을 못 열었다 (`"VFS missing file: %s\n"` `0x1404922d0`) | `0x140276925` |
| 2 | 버전 미지원 | `0x14027672d` 초기값, `0x14027697b` 로 탈출 |

호출측(`0x14010e18f`–`0x14010e1cf`)은 1 → UI 에러 코드 **5**, 2 → 코드 **4** 로 옮긴다.

**[2026-08-21 독립 재확인]** 반환 경로를 다시 떴다. 성공은 `0x140276b6e mov esi, r15d` 인데
`r15d` 는 진입부 `0x140276780 xor r15d, r15d` 이후 이 경로에서 **다시 쓰이지 않는다**(루프 안
`0x140276b36 mov r15d, 0` 도 같은 값이다) — 곧 0이다. 버전 거부는 `0x14027672d mov esi, 2` 로
미리 심어 둔 값을 `0x14027697b jmp 0x140276b71` 이 그대로 들고 나간다(성공 대입을 건너뛴다).
파일 열기 실패만 `0x140276925 mov eax, 1` 로 직접 쓴다.
호출측도 다시 떴다 — `0x14010e18f sub eax, 1` / `je 0x14010e1b7`(→ `mov r8d, 5`) ·
`cmp eax, 1` / `jne 0x14010e225`(→ 나머지) · 그 사이가 `mov r8d, 4` 다.

---

## 3. 압축 — 실측

### 3.1 코드 근거

`LZ4_decompress_safe` 는 `0x14014c160` 이다(`docs/re/tex-format.md` §7 에서 확정).
`wallpaper64.exe` 전체를 `.pdata` 조각 단위로 훑어 `call 0x14014c160` 을 세면
**호출 지점 4 · 소속 함수 2**다.

| 호출 지점 | 소속 함수 | 무엇 |
| --- | --- | --- |
| `0x14015dcf8` · `0x14015df73` | `0x14015c8d0` | `TEXB` mip 페이로드 리더 |
| `0x1400ce7bc` · `0x1400ce9c4` | `0x1400ce760` | 텍스처 업로드 워커(같은 mip 바이트) |

> **[2026-08-21 정정]** 종전 이 표는 함수마다 **한 지점씩만** 적어 "호출자는 2곳" 으로 읽혔다.
> 함수는 2개가 맞지만 **호출 지점은 4개**다(각 함수가 두 번 부른다). 결론은 바뀌지 않는다 —
> 네 지점 모두 `.tex` 경로다. 도수를 적을 때는 **무엇을 세는지**(지점인지 함수인지)를 밝혀야
> 한다(방법론 함정 4).

**패키지 경로(`0x140276700`·`0x140273f50`)에는 없다.** zlib/Wuffs 호출도 없다. 컨테이너는
**통짜도 아니고 엔트리별도 아니라, 아예 압축이 아니다.**

### 3.2 실행한 검증

`lz4` 파이썬 모듈이 없어 **순수 파이썬 LZ4 블록 디코더**를 짜서 돌렸다(프레임 헤더 없음 —
`.tex` 는 블록 포맷이고 해제 크기를 컨테이너가 별도 필드로 준다).

```
[통제군] 디스크 .tex mip0 LZ4 해제: 47371 -> 262144 bytes  OK
합성 pkg: 48126 bytes, 엔트리 3
파스: PKGV0023 version= 23 count= 3 dataBase= 137
  scene.json                                    off=137   size=282    bytes-identical=True
  effects/blendgradient/preview/materials/effectpreview.tex
                                                off=419   size=47458  bytes-identical=True
  shaders/empty.frag                            off=47877 size=249    bytes-identical=True
round-trip 전건 일치: True
[검증] pkg 슬라이스에서 뽑은 .tex mip0 LZ4 해제: 47371 -> 262144 bytes, 디스크본과 동일=True
```

곧 **pkg 슬라이스를 그대로 `.tex` 리더에 먹여 LZ4 해제가 성공했다** — 컨테이너가 페이로드를
건드리지 않는다는 뜻이다. 버전 게이트도 같은 스크립트로 실측했다.

```
  magic PKGV0024       -> OK version=24
  magic PKGV0025       -> REJECT (version 25 not supported (>24))
  magic PKGV0100       -> REJECT (version 100 not supported (>24))
  magic PKGV0001       -> OK version=1
  magic XXXX0023       -> OK version=23        ← 접두를 안 본다는 증거
  magic PKGV           -> OK (버전 검사 자체를 건너뜀)
  magic PKGV000000023  -> 길이 13 > 8 → 매직 소실 + 스트림 미전진 → EOF
```

### 3.3 코퍼스 근거 (과거 측정, 재현 불가)

`spec/corpus/workshop-shaders.json` 은 워크샵 `scene.pkg` 162개에서 뽑은 `.frag`/`.vert`
**3,378건**을 `decodeFailures: 0` 으로 기록한다. GLSL 원문이 그대로 실려 있다 — TOC 슬라이스를
평문 텍스트로 읽어 성공했다는 뜻이고, **엔트리 무압축의 실물 증거**다.

---

## 4. 로더 전표 — 필드마다 VA

### 4.1 컨테이너 적재 `0x140276700`

`(this, std::string utf8Path)`. 진입 즉시 `0x140078a40(this+0x38)`(엔트리 맵 비우기)을 부르고,
경로를 `MultiByteToWideChar(CP_UTF8, …)`(`0x140426678`, 2패스)로 `std::wstring` 화해
`this+0x18` 에 넣은 뒤 `0x140277820(this+0x78, path, 0x20)` 으로 파일을 연다
(`mode |= 1` → `ios::in|ios::binary`, `0x140277833`).

이 함수 자체는 vtable 슬롯이 아니라 **직접 호출**된다(§4.3 2번). 객체는 §4.2 의 VFS 와
같은 클래스이고 ctor 는 `0x140273d70`, vtable 은 `0x140492238`(`0x140273d88` 에서 심는다).
레이아웃:

| 오프셋 | 멤버 | 근거 |
| --- | --- | --- |
| +0x18 | `std::wstring` `.pkg` 절대경로 | `0x140276872` 대입, `0x140274130` 재사용 |
| +0x38 | `std::unordered_map` `_Max_bucket_size` (float 1.0f) | `0x140273e06` |
| +0x40 | 같은 맵의 리스트 센티넬 | `0x140273de7`(`operator new(0x38)` = 노드 크기) |
| +0x48 | 맵 원소 수 | `0x140273dce` |
| +0x50 / +0x68 | 버킷 벡터 / 마스크 | `0x14027406c` / `0x140274068` |
| +0x78 | `std::ifstream` | `0x1402768f7` |
| +0x108 | 열림 여부 | `0x14027690d` |

엔트리 노드(맵 값): 키 `std::string` 이 `+0x10`(크기 `+0x20`, 용량 `+0x28`), **`offset` 이
`+0x30`, `size` 가 `+0x34`** (`0x140276aef`·`0x140276af5`).

TOC 를 다 읽은 뒤:

```
0x140276b46  lea rdx, [rbp-0x41] ; mov rcx, rdi ; call 0x14004a840   ; tellg()  (seekoff(0,cur,in))
0x140276b56  mov edx, [rax+8] ; add edx, [rax]                       ; 절대 위치
0x140276b63  add dword ptr [rax+0x30], edx                           ; 전 엔트리 offset += dataBase
```

### 4.2 엔트리 조회 + 열기 `0x140273f50` (VFS `openFile`, vtable `0x140492238`+0x08)

1. 요청 이름을 복사해 **바이트별 `tolower`**(`0x140274000`–`0x140274015`, `0x1402bfb1c` = CRT `tolower`
   — C 로케일에서 `'A'..'Z'` 만 `+0x20`, `0x80` 이상 바이트는 손대지 않음).
2. **FNV-1a 64비트** 해시: `h = 0xcbf29ce484222325`, 바이트마다 `h ^= b; h *= 0x100000001b3`
   (`0x14027402b`·`0x140274040`·`0x14027405b`).
3. `h & mask`(`0x140274068`)로 버킷을 잡고 길이 비교 + `memcmp`(`0x1402740b8`)로 확정.
4. **찾았고 `size > 0`** 이면(`0x140274124`·`0x14027412a`):
   ```
   0x14027413d  call 0x140277820        ; ifstream::open(this+0x18, ios::in|binary)
   0x140274142  movsxd rdx, [rbx+0x30]  ; entry.offset (이미 dataBase 가산됨)
   0x14027414c  call 0x14004a920        ; seekg(offset, beg)      ; dir 0=beg, 2=end
   0x140274151  mov eax, [rbx+0x34]
   0x140274154  mov [r12+0x110], eax    ; 스트림에 길이 상한을 심는다
   ```
   **해제도, 변환도 없다.**
5. **못 찾았거나 `size <= 0`** 이면 `0x140274161` 로 빠져 **마운트된 디렉터리 루트에서 실제 파일**을
   연다(`0x140274425` `filebuf::open`). 즉 VFS 는 *패키지 → 디스크* **합집합**이다.

> **`size == 0` 은 "없음"과 같다.** 0바이트 엔트리는 조회에서 탈락하고 디스크 폴백으로 넘어간다.
>
> **[2026-08-21 추가] 조회는 이 한 번뿐이다.** 위 1~4 는 "정규화 조회" 처럼 읽히지만 실제로는
> **유일한** 조회다 — 대소문자를 보존한 1차 조회가 앞에 없다(엔트리 이름 자체가 §2.1b 처럼
> 적재 때 접혀 저장된다). Waple 이 `entryByName`(정확) → `entryByNormalizedName`(접힘) 2단으로
> 찾던 것은 이 지점에서 WE 와 갈렸다. §7.8.

### 4.3 마운트 디스패처 `0x14010df40`

`project.json` 의 `file`(UTF-8 std::string, 3번째 인자)을 `MultiByteToWideChar` → `wstring` →
`std::filesystem::path` 로 만들어 `[rbp+0x98]` 에 두고(`0x14010df87`–`0x14010dfbc`),
그 **확장자**를 `[rbp+0xb8]` 에 뽑아(`0x140053f80`, `0x14010dfe1`) 그것만 보고 갈린다.

**[2026-08-21 정정]** `0x140118880` 은 "이 확장자로 **끝나는가**" 가 아니라
`std::filesystem::path` **동등 비교**다(루트명 비교 → 컴포넌트 순회, `0x1401188ed`·`0x140420ff0`).
왼쪽 피연산자가 이미 `extension()` 결과라 결과적으로 "확장자가 **정확히** 같은가" 다.
그 `extension()` 은 wstring→UTF-8 변환 후 **바이트별 ASCII `tolower`**
(`0x140054262`–`0x140054276`, CRT `tolower` `0x1402bfb1c`)를 돌려 되돌리므로 `SCENE.PKG` 도 잡힌다.
곧 `.pkg2` 나 `x.notpkg` 는 **안 잡힌다** — 접미사 검사가 아니다.

| 순서 | 조건 | 동작 | VA |
| --- | --- | --- | --- |
| 1 | 확장자 == `.gif` | 플래그 `0x20` 세우고 GIF 씬 경로로 이탈 | `0x14010e0ee`–`0x14010e12c` |
| 2 | 확장자 == `.pkg` | `0x140276700`(패키지 적재) | `0x14010e14d`–`0x14010e18a` |
| 3 | 그 외 | `0x1402764d0`(**부모 폴더**를 루트로 마운트) | `0x14010e1d1`–`0x14010e20c` |

**어느 분기도 다른 분기를 되짚지 않는다** — 2번에서 실패하면 에러 코드 5 로 끝난다.

### 4.3.1 씬 문서 이름은 `stem() + ".json"` 이다 — `filename()` 이 아니다

**[2026-08-21 정정]** 종전 서술("이후 공통으로 `filename()` 을 씬 문서 이름으로 쓴다")은 **틀렸다.**
합류한 뒤 도는 것은 이렇다:

> **[2026-08-21 재정정 — "세 분기가 합류한" 이 아니다]** 종전 이 문장은 "세 분기가 합류한 뒤" 로
> 시작했다. 직접 떠 보면 **합류하는 것은 두 분기(2·3번)뿐**이다. `.gif` 분기는
> `0x14010e124 or dword [r14+0x1b8], 0x20` 직후 `0x14010e12c jmp 0x14010ea74` 로 **아래 코드를
> 건너뛰고 나간다.** 2번은 `0x14010e18f`–`0x14010e1cf`(반환값 → UI 코드 5/4)를 거쳐,
> 3번은 `0x14010e211`–`0x14010e220`을 거쳐 **`0x14010e225` 에서 만난다.**
> (재현: `vdis2.dis(0x14010de40, 0x14010e290)` — `.pdata` 조각 시작 `0x14010df40` 에서 뜨면
> 어긋난다. 함정 1·15.)

```
0x14010e22a  lea rcx, [rbp+0x98] ; call 0x14003fc80   ; path::stem()   ← filename() 이 아니다
0x14010e23e  call 0x140018ce0                          ; wstring → UTF-8 std::string
0x14010e246  lea rdx, [rip+0x368ac7]                   ; 0x140476d14 ".json"
0x14010e24d  mov r8d, 5 ; call 0x1400532a0             ; std::string::append(".json", 5)
```

`0x14003fc80` 이 `stem()` 인 근거: 뒤에서부터 구분자(`/`·`\`)를 걷어내 파일명 구간을 잡고
(`0x14003fcb4`–`0x14003fced`), 그 안에서 마지막 `.`(`0x2e`)를 찾되 `"."`·`".."` 는 예외로 두는
(`0x14003fd0e`·`0x14003fd1d`) 표준 `stem` 절차다. 대비군 `0x14003fd90` 은 같은 골격에 확장자
탐색이 없고 마지막 컴포넌트를 통째로 잘라내는 `parent_path()` 이고, 3번 분기가 그것을 쓴다.

**결과**: `file:"techno.pkg"` 면 WE 는 그 패키지 안에서 **`techno.json`** 을 찾는다.
`file:"techno.json"` → `techno.json`(같음), `file:"gifscene.json"` → `gifscene.json`(같음).
곧 `file` 이 `.json` 인 동안에는 `filename()` 과 `stem()+".json"` 이 구별되지 않아 지금까지
드러나지 않았다 — 설치본+동봉 361건이 전건 `.json`(358) / `.html`(2) / `.exe`(1) 이다.

---

## 5. `project.json` 매니페스트

### 5.1 리더 `0x14011d7d0`

`(out ProjectRecord*, std::filesystem::path)`. `ProjectRecord`: `+0x01` 유효 플래그,
`+0x04` 타입 enum, `+0x08` 본 JSON, `+0x30` 프리셋 원본 JSON.
JSON 값의 타입 태그는 jsoncpp 규약 그대로다 — `[value+8]` 하위 바이트가
`0`=null `1`=int `2`=uint `3`=real **`4`=string** `5`=bool `6`=array **`7`=object**
(`0x14011d9f1` `cmp byte [rax+8], 4`, `0x14010a703` `cmp byte [rax+8], 7`).

| 키 | 기대 타입 | 읽는 VA | 동작 / 기본값 |
| --- | --- | --- | --- |
| `file` | string(4) | `0x14011d9e1`·`0x14011deb4` | 프로젝트 폴더 기준 **절대경로로 정규화해 다시 써 넣는다**. 없으면 프리셋 병합 경로로 |
| `preview` | string(4) | `0x14011df1d`·`0x14011dfe2` | 절대경로화해 다시 씀. 문자열이 아니면 **null 로 덮어씀**(`0x14011e027`) |
| `title` | string(4) | `0x14011e08a`·`0x14011e0f7` | 문자열이 아니면 **폴더명**으로 채워 씀 |
| `type` | — | — | **입력으로 안 쓴다.** 유도 결과를 캐논 문자열로 **덮어쓴다**(`0x14011e300`) |
| `general` | object(7) | `0x14010a6f7` | `general.properties`(object)가 wproperties 스키마 |
| `dependency` | string(4) | `0x14011e894` | 있으면 그 경로의 확장자로 타입을 유도하고 `.pkg` 폴백을 **막는다** |
| `preset` | — | `0x14011d8e4` | 프리셋 체인 해석 |
| `project` | string(4) | `0x14011d61c` | 경로 정규화 대상(`0x14011d3b0`) |
| `workshopid` | — | `0x14010ab00` | **읽지 않고 쓴다** — §5.4 |

### 5.2 타입 enum과 캐논 문자열 (`0x14011e2aa`–`0x14011e2f9`)

| 값 | 캐논 문자열 | VA |
| --- | --- | --- |
| 0 | `Unknown` | `0x14011e2e9` |
| 1 | `Scene` | `0x14011e2e0` |
| 2 | `Web` | `0x14011e2d7` |
| 3 | `Application` | `0x14011e2ce` |
| 4 | `Video` | `0x14011e2c5` |
| 5 | (매핑 없음 → `Unknown` 으로 출력) | `0x14011e864` |

`+0x01` 유효 플래그 = `type != 0`(`0x14011e325`–`0x14011e32d`).

### 5.3 확장자 → 타입 분류기 `0x14011e520`

입력 문자열을 `std::filesystem::path` 로 만들어 **확장자를 소문자로** 뽑은 뒤
(`0x140053f80` — wstring→UTF-8 → 바이트별 ASCII `tolower` `0x140054262`–`0x140054276` → UTF-8→wstring),
`.rdata` 의 확장자 테이블들과 순서대로 `memcmp` 한다. 테이블은 `[imagebase + i*8 + RVA]` 로 색인된다.

| 순서 | 테이블 RVA | 개수 | 확장자 | 결과 | 매치 VA |
| --- | --- | --- | --- | --- | --- |
| 1 | `0x483850` | 3 | `.json` `.pkg` `.gif` | **1 Scene** | `0x14011e7a5` |
| 2 | `0x4837d0` | 1 | `.html` | **2 Web** | `0x14011e79e` |
| 3 | `0x4837c0` | 1 | `.exe` | **3 Application** | `0x14011e7ac` |
| 4 | `0x483810` | 7 | `.mp4` `.wmv` `.avi` `.m4v` `.mov` `.webm` `.mkv` | **4 Video** | `0x14011e7b3` |
| 5 | — | — | 문자열이 `http://`·`https://` 로 시작(`0x140018980`) | **2 Web** | `0x14011e79e` |
| 6 | `0x4837e0` | 5 | `.png` `.bmp` `.jpeg` `.jpg` `.jfif` | **5** | `0x14011e864` |
| 7 | — | — | 그 외 | **0 Unknown** | `0x14011e800` |

분류기에 들어가는 문자열은 **`dependency` 가 문자열이면 그것, 아니면 `file` 의 절대경로**다
(`0x14011e14b`–`0x14011e159` vs `0x14011e1f7`–`0x14011e242`). `type` 값은 어느 쪽에도 안 들어간다.

> `.htm` 은 표에 **없다** — WE 는 `.html` 만 Web 으로 본다.

**[2026-08-21 독립 재확인]** 다섯 표를 **포인터 배열에서 직접 읽어** 다시 떴다(문자열을 하나씩
역참조). 결과가 위 표와 **정확히 같다**:
`0x483850` → `.json .pkg .gif` · `0x4837d0` → `.html` · `0x4837c0` → `.exe` ·
`0x483810` → `.mp4 .wmv .avi .m4v .mov .webm .mkv` · `0x4837e0` → `.png .bmp .jpeg .jpg .jfif`.
(재현: 부록 A.3 의 절대 포인터 스캔과 같은 방식 — rip-상대 xref 로는 안 잡힌다, 함정 10.)

### 5.4 `workshopid` 는 경로에서 나온다

`0x14010a9a0`–`0x14010ab27` 이 프로젝트 폴더 경로를 뒤에서부터 컴포넌트 단위로 훑으며
`strtoull(comp, NULL, 10)`(`0x1402c0e80`, `r8d = 0xa`)을 두 번 부른다.

```
0x14010aabc  call 0x1402c0e80          ; strtoull(<상위 컴포넌트>, 0, 10)
0x14010aac1  cmp  rax, 0x69758         ; == 431960  (Wallpaper Engine Steam AppID)
0x14010aac7  jne  0x14010ab36          ;   아니면 workshopid 를 아예 안 쓴다
0x14010aadf  call 0x1402c0e80          ; strtoull(<그 아래 컴포넌트>, 0, 10)
0x14010ab00  lea  rdx, [rip+0x369239]  ; 0x140473d40 "workshopid"
0x14010ab27  call 0x140085610          ; json["workshopid"] = <그 수>
```

즉 `…/steamapps/workshop/content/431960/<id>/` 구조일 때만 `<id>` 를 채우고,
그 밖의 폴더(로컬 프로젝트·설치본 기본 배경)에서는 `workshopid` 를 **건드리지 않는다**.
`project.json` 에 적힌 `workshopid` 는 입력으로 쓰이지 않는다.

### 5.5 읽히지 않는 키

`contentrating` · `tags` · `visibility` · `approved` · `ratingsex` 는 **`wallpaper64.exe` 안에
문자열 자체가 없다**(전건 grep 0). `wallpaperui.exe` 에만 있다 — 저작·업로드 UI 전용이다.
`official` · `authorsteamid` · `timestamp` · `templateoptions` 도 같다.

`0x140056220`–`0x14005675C` 의 기록 함수가 내보내는 `key`/`file`/`status`/`name`/`description`/
`version`/`options` 중 **`status`·`description` 은 전 바이너리 xref 가 이 기록 함수 1건뿐이다.**
즉 `wallpaper64.exe` 안에 **대응하는 읽기 함수가 없다.**
(같은 `key`/`options` 문자열을 쓰는 `0x1401a4db0` 은 wproperty 스키마 리더지 이 매니페스트가 아니다 —
그쪽은 `user`/`value`/`condition`/`script`/`animation` 을 같이 읽는다.)
이 매니페스트는 리스트 노드마다 가상 호출 `+0x30`(name)·`+0x38`(description)·`+0x40`(version)·
`+0x50`(options)로 채워지는 **런타임 산출물**이고, 호출자는 `0x14001eae0`·`0x140021e50` 다.
**`.pkg` 안에 이런 매니페스트가 들어 있다는 증거는 이 바이너리에서 찾지 못했다. `[미해결]`**

> **[해소 2026-08-21]** 바이너리 쪽 결론(읽기 함수 없음)은 그대로 두고, **"`.pkg` 안에 있는가"**
> 는 코퍼스로 닫는다. `corpus_scan/entry-name-frequency.tsv` 는 워크샵 `scene.pkg` **161개**의
> 엔트리 경로 **11,338 종 / 출현 19,777건 전수**다. 그 안에서:
>
> * **디렉터리 성분이 없는(= pkg 루트 직속) 경로는 딱 하나**이고 그것이 `scene.json`(도수 161)이다.
> * `manifest`·`key`·`status`·`options` 같은 이름의 엔트리는 **0건**이다(전수 문자열 대조).
> * 최상위 디렉터리는 `materials`·`models`·`shaders`·`sounds`·`effects`·`particles`·`fonts`·
>   `scripts` **여덟 개뿐**이다(§1.1c).
>
> 곧 **`.pkg` 안에는 그런 매니페스트가 없다** — 161 pkg 표본에서 0건이다. 남는 것은
> "wallpaperui.exe 쪽 저작 산출물인가" 인데 그건 이 문서의 범위(런타임 컨테이너) 밖이다.
> 판정: **부재를 161 pkg 범위에서 확정.** 전 워크샵(수만 건) 범위로는 여전히 미측정.

---

## 6. `scene.pkg` vs 평문 `scene.json` — 누가 이기나

**우선순위 다툼이 성립하지 않는다.** 결정자는 `project.json` 의 `file` 하나다.
`.pkg` 는 그 파일이 **없을 때만** 도는 폴백이고, 그 폴백에도 게이트가 셋 붙는다
(`0x14011e330`–`0x14011e3f9`):

```
cmp  dword [rdi+4], 1        ; ① type 유도 결과가 Scene 일 때만
jne  skip
call 0x14011e880             ; ② json 에 string 타입 `dependency` 가 있으면 → skip
test al, al ; jne skip
lea  rcx, [rbp-0x28]
call 0x140018f30             ; ③ is_regular_file(<file 절대경로>) 가 true 면 → skip
test al, al ; jne skip
...  replace_extension("pkg")            ; 0x14011e368 "pkg" (점 없음) + 0x140060d90
call 0x140018f30             ; ④ 바꾼 경로가 실제 파일이면
je   skip
...  json["file"] = <그 .pkg 절대경로>    ; 0x14011e3f2
```

| 디스크 상태 (`file` = `"scene.json"`) | WE 가 여는 것 |
| --- | --- |
| `scene.json` 만 | `scene.json` (폴더 마운트) |
| `scene.json` + `scene.pkg` 둘 다 | **`scene.json`** — ③에서 빠진다 |
| `scene.pkg` 만 | `scene.pkg` (④에서 재작성) |
| 둘 다 없음 | 실패 |

**[2026-08-21 독립 재확인]** 위 게이트 넷을 `0x14011d7d0`(함수 시작)에서 **선형으로** 다시 떠서
전부 맞는 것을 확인했다: `0x14011e330 cmp ecx, 1` / `0x14011e333 jne` ① ·
`0x14011e33c call 0x14011e880` / `0x14011e341 test al, al` ② ·
`0x14011e34d call 0x140018f30`(is_regular_file) / `0x14011e352 test al, al` ③ ·
`0x14011e368 lea rdx, "pkg"`(점 없음) + `0x14011e383 call 0x140060d90`(replace_extension) ·
`0x14011e3ae call 0x140018f30` / `0x14011e3b5 je` ④ · `0x14011e3f2 lea rdx, "file"` 로 되쓰기.
같은 함수 바로 앞 `0x14011e300 lea rdx, "type"` → `0x140085610` 이 유도 결과를 **덮어쓰는** 자리다.

| 디스크 상태 (`file` = `"scene.pkg"`) | WE 가 여는 것 |
| --- | --- |
| `scene.pkg` 있음 | `scene.pkg` — `.json` 을 **찾아보지도 않는다** |
| `scene.pkg` 없음, `scene.json` 있음 | ③에서 통과하지만 ④가 `replace_extension("pkg")` → 같은 `scene.pkg` → 없음 → 실패 |

`file` 이름은 `scene.*` 일 필요가 없다. 설치본 실측(§1.2)이 `ricepod.json` `techno.json`
`audiophile.json` `fantasticcar.json` `gifscene.json` 5건을 보여 준다 — 폴백도 그 stem 을 따라간다
(`techno.json` 이 없으면 `techno.pkg` 를 본다).

`gifscene.pkg` 라는 이름은 **엔진 안 어디에도 없다.** `gifscene.json` 리터럴만
`0x140489300` 에 있고, GIF 분기는 §4.3 처럼 `.gif` **확장자**로 잡는다.

---

## 7. Waple 갭

### 7.1 [고] 마운트 대상을 `file` 이 아니라 파일 존재로 고른다

`Sources/WapleRender/SceneRendererResources.swift` 의 `func pkgURL(in folder: URL) -> URL?` 은
`scene.pkg`/`gifscene.pkg` **두 이름만** 하드코딩해 찾고, `Sources/WapleRender/SceneRenderer.swift`
가 그게 있으면 무조건 패키지로 마운트한다.
(**[2026-08-21 정정]** 이 절의 `…swift:166`·`:1207`·`:654` 같은 **다른 파일의 줄 번호** 인용은
전부 이미 어긋나 있었다 — 예: 종전 `SceneRenderer.swift:1207` 이 가리키던 코드는 지금
`let mountSource = ScenePackage.resolveMountSource(` 이고 줄이 300줄 넘게 밀렸다. 함정 22.
아래에서는 줄 번호 대신 **코드 문구**로 가리킨다.) WE 규칙(§6)과 세 군데에서 갈린다.

| 상황 | WE | Waple | 결과 |
| --- | --- | --- | --- |
| `file:"scene.json"` + 잔존 `scene.pkg` | `scene.json` | **`scene.pkg`** | 다른 씬을 그린다 |
| `file:"techno.json"` 부재, `techno.pkg` 존재 | `techno.pkg` | `pkgURL` 이 nil → 폴더 마운트 → `techno.json` 없음 → `.noScene` | **적용 실패** |
| `file:"scene.pkg"` 부재, `scene.json` 존재 | 실패 | `scene.json` 으로 성공 | Waple 이 더 관대(무해) |

**착지 지점** — `SceneRenderer.swift` 의 마운트 결정 자리. `pkgURL(in:)` 호출을 `project.fileName` 기반 결정으로
바꾼다: ① `fileName` 을 폴더 기준으로 풀어 존재하면 그 확장자로 분기(`.pkg` → 패키지, 그 외 → 폴더),
② 없으면 stem 을 `.pkg` 로 바꿔 재시도, ③ 그것도 없으면 현재의 `scene.pkg`/`gifscene.pkg` 탐색을
**하위 호환 폴백**으로 남긴다. `pkgURL(in:)` 은 ③ 전용으로 축소.
`Sources/WapleCore/WallpaperCompatibilityAnalyzer.swift` 의 같은 하드코딩도 같이 따라간다.

> **[2026-08-21 처리됨]** 결정 본체는 `ScenePackage.resolveMountSource(folderURL:fileName:hasDependency:)`
> 로 옮겼다 — `WapleRender` 는 Metal 전용이라 리눅스에서 빌드가 안 되고, 그러면 이 결정을 재는
> 테스트가 macOS CI 왕복 없이는 못 돌기 때문이다. `SceneRenderer.swift` 의
> `let mountSource = ScenePackage.resolveMountSource(` 가 그것을 부르고,
> `SceneRendererResources.pkgURL(in:)` 은 `ScenePackage.legacyPackageURL(in:)` 델리게이트로 축소했다
> (`SceneRendererPathFallbackTests.testScenePackageDiscoveryIsCaseInsensitive` 가 이 메서드를 직접
> 부르므로 자리를 지울 수 없다 — 그 테스트는 이 과제의 소유가 아니다).
> 게이트 ②(string `dependency`)까지 `hasDependency:` 로 옮겼다.
>
> **무회귀 실측** — 설치본 + 동봉 `project.json` **361건 전수**로 바꾸기 전/후 결정을 대조했다:
> **차이 0건**(전건 `.directory`). 근거는 두 가지가 겹친다. ① 361건 전건이 선언한 `file` 이
> 디스크에 실재한다(부재 0건) → 새 경로는 ①에서 곧장 폴더로 간다. ② 두 루트 9,078 파일에
> `.pkg` 확장자가 **0개**다 → 종전 선택자도 전건 nil 을 냈다.
> 재현: 아래 부록 A.5.
>
> 종전 대비 답이 **달라질 수 있는** 조합은 셋뿐이고, 방향은 전부 WE 쪽이다.
> ⑴ 선언 파일이 실재 + 잔존 `.pkg` → 종전 pkg, 지금 폴더(§6 표 2행).
> ⑵ 선언 파일 부재 + 같은 stem `.pkg` 존재 → 종전 폴더(적용 실패), 지금 pkg.
> ⑶ 선언 파일이 `scene.pkg`/`gifscene.pkg` 가 **아닌** `.pkg` → 종전 nil, 지금 pkg.
> 이 세 조합의 코퍼스 도달은 모두 0이다(`.pkg` 자체가 0개).
>
> `WallpaperCompatibilityAnalyzer.swift` 는 **따라가지 않았다** — 이 과제의 소유 파일이 아니다.
> 스캐너는 여전히 두 이름을 하드코딩한다. `check_scene_mount_parity.py` 가 재는 "①마운트 형태 ·
> ②씬 문서 이름" 두 불변식은 그대로 유지되지만(게이트 통과), 스캐너와 렌더러의 **마운트 대상
> 선택**은 이제 갈려 있다. 갈린 방향은 ⑵⑶에서 스캐너가 더 비관적(= 렌더 가능한 것을 "불가"로
> 볼 수 있음)이고, ⑴에서는 스캐너가 더 낙관적이다. **`[미해결]`**
>
> **[해소 2026-08-21 — 트리 실측으로 이미 닫혀 있었다]** 위 문단("스캐너는 여전히 두 이름을
> 하드코딩한다")은 **지금 트리에서 참이 아니다.** 실측:
>
> * `Sources/WapleCore/WallpaperCompatibilityAnalyzer.swift` 가
>   `ScenePackage.resolveMountSource(folderURL: folderURL,` 를 부른다.
> * `Sources/WapleCompatCore/DeepScan.swift` 도
>   `switch ScenePackage.resolveMountSource(folderURL: folder,` 로 같은 함수를 쓴다.
> * 그리고 `scripts/spec/check_scene_mount_parity.py` 가 **그 사실을 게이트로 못 박아** 뒀다 —
>   `for text, label in ((analyzer, "Analyzer"), (deepscan, "DeepScan")):` 아래에서
>   `"ScenePackage.resolveMountSource(" not in text` 면 실패시킨다.
>
> 곧 렌더러·스캐너·DeepScan 셋이 **같은 선택자 하나**를 쓰고, 되돌리면 게이트가 잡는다.
> (도달 참고: 워크샵 446 폴더 중 `scene.pkg` 보유가 **161**(36.1%)이라 이 계약이 다루는 표본은
> 작지 않다. 다만 ⑴⑵⑶ 세 조합의 도달 자체는 `project.json` 의 `file` 값이 이 산출물에
> 없으므로 **미측정**이다 — 종전 서술의 "도달 0건" 은 설치본·동봉 361건 한정이다.)

### 7.2 [중] 확장자 → 타입 유도표가 WE 표와 다르다

`Sources/WapleCore/ProjectJSONParser.swift` 의 확장자 `switch` 폴백표는 `json`/`html`,`htm`/`exe`/
`VideoFormats.nativeExtensions`(= `mp4`,`m4v`,`mov` — `WallpaperType.swift` 의
`public static let nativeExtensions: Set<String> = ["mp4", "m4v", "mov"]`)뿐이다.

| WE(§5.3) | Waple | 차이 |
| --- | --- | --- |
| `.pkg` → Scene | 없음 | `type` 누락 + `file:"scene.pkg"` 인 항목이 `.preset` 으로 남는다 |
| `.gif` → Scene | 없음 | 같은 문제 |
| `.wmv .avi .webm .mkv` → Video | 없음 | 분류 자체가 안 된다(재생 불가와는 별개 축) |
| `.png .bmp .jpeg .jpg .jfif` → 5 | 없음 | WE 도 5를 `Unknown` 으로 출력하므로 영향 작음 |
| `http(s)://` → Web | 없음 | 원격 URL 배경 미분류 |
| `.html` 만 Web | `.htm` 도 Web | Waple 이 더 관대(무해) |
| **`type` 을 먼저 읽음** | `type` 우선 | **WE 는 `type` 을 아예 안 읽는다**(§5.1) |

마지막 줄이 본질이다. WE 는 `"type":"video"` + `"file":"scene.json"` 을 **Scene** 으로 본다.
Waple 은 video 로 본다.

**착지 지점** — `ProjectJSONParser.swift` 의 그 `switch`. 확장자표에 `pkg`/`gif` → `.scene` 을 추가하는 게
최소 수선이다. `type` 무시까지 맞추는 건 회귀 위험이 크므로(워크샵 코퍼스가 `type` 에 의존해
분류돼 있다) **별도 판단**으로 남긴다. 분류 축과 재생 가능 축을 섞지 않도록, 타입 유도용
확장자 집합은 `VideoFormats.nativeExtensions` 와 **분리**해서 새로 두는 편이 낫다.

> **[2026-08-21 처리됨]** `case "json", "pkg", "gif": type = .scene` 로 1번 표를 채웠다.
> 기존 가드(`type` 선언 있음 / `preset` 있음 / `dependency` 있음)는 그대로다 — 프리셋 오분류
> 방지가 목적이고 WE 와의 거리는 그 셋 중 `type` 하나뿐이다.
> **무회귀**: 설치본+동봉 361건의 `file` 확장자는 `.json` 358 · `.html` 2 · `.exe` 1 이 전부라
> 새 분기의 도달이 **0건**이다.
>
> 안 맞춘 것은 그대로 `[미해결]`: ⑴ 4번 표 7종 vs `VideoFormats.nativeExtensions` 3종
> (`VideoFormats` 가 이 과제 소유가 아니고, 넓히면 분류 축과 재생 축이 섞인다 — AVFoundation 이
> 못 여는 `wmv`/`mkv` 를 `.video` 로 보내 실패 지점만 뒤로 민다), ⑵ 6번 이미지 표(WE 자신도
> 값 5 를 `Unknown` 으로 출력하므로 실질 차이 없음), ⑶ `http(s)://` → Web
> (`WallpaperPathSecurity` 가 URL 스킴을 거부해 `fileName` 이 nil 이 된다), ⑷ **`type` 우선**.
>
> **[2026-08-21 도달 — 닫지 못했다. 왜 못 닫는지 적는다]** ⑷의 도달을 재려면 워크샵
> `project.json` 의 `type` **원문**과 `file` 확장자를 **쌍으로** 봐야 한다. 이 컨테이너에 있는
> 산출물은 그 쌍을 담지 않는다:
> `corpus_scan/scenes-index.tsv` 의 `wallpaper_type` 열은 원문이 아니라 **`pkgv_census.py` 의
> 자체 분류기**(`classify_wallpaper`) 결과이고, 그 분류기는 `t = project.get("type"…)` 이 비어
> 있을 때만 확장자를 본다 — 곧 **`type` 우선**이라 Waple 쪽과 같은 규약이지 WE 규약이 아니다.
> (재확인한 분포: scene **162** · video **145** · web **138** · unknown **1**, 합 446.
> 그중 `has_scene_pkg=1` 은 **161**이고 전부 `scene` 으로 분류됐다.)
> 따라서 ⑷의 도달은 **0 이 아니라 미측정**이고, 재려면 워크샵 `project.json` 원본이 필요하다.
> 종전 서술이 이 열을 "`project.json` 유도 타입" 이라 부른 것도 오해를 부른다 — §1.1b 에 주석을
> 달아 두었다.

### 7.3 [저] 조회 키 정규화가 WE 보다 넓다

`Sources/WapleCore/ScenePackage.swift` 의 `normalizedLookupKey` = 역슬래시→슬래시 + Swift
`.lowercased()`. WE 는 **바이트별 C `tolower`** 뿐이다(§4.2).
(**[2026-08-21 정정]** 종전 이 문단은 `ScenePackage.swift:111`·`:35`·`:112` 처럼 **다른 파일의
줄 번호**를 인용했다 — 한 줄만 밀려도 엉뚱한 곳을 가리킨다. 함수·코드 문구로 바꿨다.)

- 역슬래시 변환: WE 에 없다. Waple 은 정확 일치 뒤의 **폴백** 색인이라 추가 히트만 만든다(무해).
- 유니코드 소문자화: Swift 는 전체 케이스 폴딩이라 키릴·그리스 등도 접는다. WE 는 `A-Z` 만.
  Waple 쪽에서만 **서로 다른 두 엔트리가 같은 정규화 키로 충돌**할 수 있다(먼저 온 것이 이김 —
  `ScenePackage` 의 `if normalizedIndex[key] == nil { normalizedIndex[key] = entry }`).
  코퍼스에서 실제 충돌은 확인하지 못했다. `[미해결]`

> **[해소 2026-08-21]** 이 `[미해결]` 은 **두 조각**이었고 둘 다 답이 나왔다.
>
> ① **"유니코드 폴딩 때문에만 생기는 충돌이 실물에 있는가" → 없다(161 pkg 범위에서 확정).**
>    전수 11,338 경로에서 ASCII 폴딩 ≠ 유니코드 폴딩인 이름은 **114 종**(전부 키릴)이지만,
>    충돌군 수가 **ASCII 14군 = 유니코드 14군**으로 같다 — 곧 **유니코드에서만 생기는 충돌군은
>    0군**이다. `asciiLowercased` 로의 전환은 이 범위에서 무회귀다(§1.1c 결론 3).
>
> ② **"그래서 충돌하면 누가 이겨야 하는가" → 종전 답(먼저 온 것)이 틀렸다.**
>    이건 종전에 아예 묻지 않은 물음이다. §2.1b 에서 확정했듯 WE 는 **뒤에 온 것**이 이기고,
>    애초에 정확 일치 색인이 없다. 그 갭을 §7.8 로 새로 세우고 **고쳤다.**

**착지 지점** — 고칠 필요는 낮다. 고친다면 `normalizedLookupKey` 의 `.lowercased()` 를
ASCII 한정 소문자화로 좁히면 WE 와 동치가 된다.

> **[2026-08-21 처리됨]** `ScenePackage.asciiLowercased(_:)` 로 좁혔다(UTF-8 바이트 중 `0x41..0x5A`
> 만 `+0x20`). 역슬래시→슬래시 치환은 **그대로 뒀다** — 정확 일치 색인이 먼저 이긴 뒤의 폴백이라
> 히트만 늘리고 뺏지 않는다.
>
> **[2026-08-21 근거 교체]** 위 줄의 근거("정확 일치가 먼저 이긴 뒤의 폴백")는 §7.8 이후
> `.blob` 에서 그대로는 성립하지 않는다 — 정확 일치 색인이 `.blob` 경로에서 빠졌기 때문이다.
> 대신 **역슬래시 관용을 별도 색인으로 떼어** 같은 성질을 되살렸다: 1차 조회는 **WE 의 키**
> (ASCII 소문자화만)이고, 역슬래시까지 접는 색인은 그 **2차 폴백**이다. 그래서 이 치환은
> 여전히 **히트를 더하기만 하고 뺏지 않는다**. 실측 보강: 이 치환이 뺏을 수 있는 유일한 경우는
> 한 pkg 안에 `a\b.tex` 와 `a/b.tex` 가 **같이** 있는 것인데, 워크샵 전수 11,338 경로에
> 역슬래시가 **0건**이다(§1.1c).
>
> **무회귀 실측**(재현: 부록 A.6): 두 루트 9,078 파일의 경로 컴포넌트 **3,374 종에 비-ASCII 0건**,
> ASCII 폴딩 ≠ 유니코드 폴딩인 이름 **0건**. 워크샵 코퍼스에서 굳혀 둔 pkg 엔트리 경로
> (`spec/corpus/workshop-shaders.json`, path 형태 39종)도 갈리는 것 0건 —
> 대문자 ASCII 를 가진 21종은 두 폴딩이 같은 답을 낸다.
> 즉 "유니코드 충돌 실사례" 는 여전히 **미관측**이고(§8), 이 정정의 근거는 코퍼스가 아니라
> 로더 코드다. 반대로 말하면 이 정정이 지금 무언가를 고치는 것도 아니다 — **드리프트를 막는다.**
>
> **[2026-08-21 후속]** 위 "미관측" 은 **표본이 작았기 때문**이다(경로 컴포넌트 3,374 종 +
> 셰이더만 뽑은 39 종). 워크샵 **전수 11,338 경로**로 다시 재면 미관측이 아니라 **0군으로 확정**
> 된다(위 해소 블록 ①). 두 서술을 함께 남기는 이유는 표본이 어디서 어디로 커졌는지가
> 다음 사람에게 필요한 정보라서다.

### 7.4 [저] 매직·버전 게이트 방향이 반대다

`ScenePackage.parse` 의 `guard magic.range(of: "^PKGV[0-9]{4}$", options: .regularExpression) != nil`
이 접두를 **강제**하고 버전 상한은 **두지 않는다**.
WE 는 정반대다 — 접두를 안 보고 상한 24 를 건다(§2.2).

- Waple 이 더 엄격: `magicLen != 8` 이거나 접두가 다른 파일을 거부. WE 는 받는다.
- Waple 이 더 관대: `PKGV0025` 이상을 파싱 시도. WE 는 거부한다.

그 `guard` 위의 주석은 "값 범위 게이트를 두지 않는" 근거로 RePKG 를 든다.
그 결론(프레이밍이 버전 불변)은 **엔진 코드로도 맞다** — `0x140276980` 이후 버전 분기가 없다.
다만 주석이 함의하는 "WE 도 낙관적으로 받는다" 는 **틀렸다.**

**착지 지점** — 그 `guard` 와 주석. 주석에 "WE 는 `atoi(magic+4) > 24` 를 거부한다
(`0x140276964`)"를 적고, 게이트 정책이 **의도적 이탈**임을 명시. 코드 변경은 불필요.

> **[2026-08-21 처리됨]** 주석을 정정했다(코드 무변경). 틀렸던 것은 "프레이밍이 버전 불변" 이라는
> **결론**이 아니라 그 아래 함의("그러니 WE 도 낙관적으로 받는다") 였다는 점을 명시했다.
> 두 이탈은 `ScenePackageWEParityTests.testMagicPrefixIsEnforcedUnlikeWE` ·
> `testNoVersionCeilingUnlikeWE` 가 **양방향으로** 못 박는다 — 접두 게이트를 빼면 전자가,
> 상한 24 를 넣으면 후자가 깨진다(실측: 각각 테스트 케이스 2건씩 실패).

### 7.5 [저] `size == 0` 엔트리 처리

WE 는 `size <= 0` 엔트리를 **없는 것으로 보고 디스크 폴백**으로 넘긴다(`0x14027412a`).
Waple `ScenePackage.data(for:)` 의 `.blob` 분기는 **빈 `Data`** 를
돌려주고, `SceneRendererResources.swift` 의
`private func probeAssetData(_ name: String, package: ScenePackage) -> SharedAssetProbeResult` 가
그걸 성공으로 보고 공유 에셋 폴백을 **건너뛴다**. 0바이트 엔트리를 가진 pkg 는 관측하지 못했다.

**착지 지점** — `data(for:)` 의 `.blob` 분기가 `e.size == 0` 이면 `nil` 을 반환.

> **[2026-08-21 처리됨]** `.blob` 분기에만 `guard e.size > 0 else { return nil }` 를 넣었다.
> **`.directory` 분기에는 넣지 않았다** — WE 의 폴더 마운트(`0x1402764d0`)는 엔트리 표를 만들지
> 않고 파일을 바로 열므로, 디스크의 진짜 0바이트 파일은 WE 에서도 "0바이트로 열림" 이다.
> `fromDirectory` 는 엔트리 `size` 를 `fileSize` 로 채우므로, 구분하지 않았다면 0바이트 파일이
> 있는 언팩 프로젝트에서 **새 회귀**가 났을 자리다.
> 도달: 0바이트 엔트리를 가진 pkg 는 여전히 미관측(표본 0). 무회귀.
>
> **[2026-08-21 도달 보강 — 파생 실측]** "미관측" 을 "**161 pkg 범위에서 0건**" 으로 좁힐 수 있다.
> `corpus_scan/pkgv_census.py` 는 엔트리마다 `detect_type(name, blob)` 을 부르는데, 그 함수는
> json/TEX/PNG/Ogg/RIFF/fLaC 검사를 모두 통과한 뒤 **`head[0]`** 로 mp3 sync 를 본다 — 빈 blob 이면
> 거기서 `IndexError` 로 죽는다. 센서스가 예외 없이 끝났고 `parse-errors.tsv` 본문이 0행이므로
> **19,777 엔트리에 `size == 0` 이 없다.** (파생 추론이므로 "확정" 이 아니라 강한 간접 증거다 —
> §8.2 과 같은 성격이다.)

### 7.7 [저, 신규 2026-08-21] `file:"*.pkg"` 일 때 씬 문서 이름이 갈린다

§4.3.1 에서 새로 확정한 것이다. WE 는 마운트 뒤 `stem(file) + ".json"` 을 씬 문서 이름으로 쓴다
(`0x14010e22a` `path::stem` → `0x14010e253` `std::string::append(".json", 5)`).
Waple 은 `SceneRenderer.swift` 가 `SceneDocument.parse(sceneFileName:)` 에 `project.fileName`
**원문**을 넘기고, `SceneDocument.swift` 의
`let sceneCandidates: [String] = [sceneFileName, "scene.json", "gifscene.json"].compactMap { $0 }`
순으로 찾는다.

| `file` | WE 가 여는 문서 | Waple 후보 순서 | 결과 |
| --- | --- | --- | --- |
| `scene.json` | `scene.json` | `scene.json` … | 같음 |
| `techno.json` | `techno.json` | `techno.json` … | 같음 |
| `scene.pkg` | `scene.json` | `scene.pkg`(miss) → **`scene.json`** | 같음(폴백이 우연히 맞음) |
| `techno.pkg` | **`techno.json`** | `techno.pkg`(miss) → `scene.json`(miss) → `gifscene.json`(miss) | **`.noScene`** |

마지막 행 하나만 갈린다. **고치지 않았다.** 이유 둘:

1. **도달 0건.** 설치본+동봉 361건 중 `file` 이 `.pkg` 인 것은 0건이다. §7.1 이 새로 열어 준
   재작성 경로(`file:"techno.json"` 부재 → `techno.pkg`)도 이 문제를 만들지 않는다 —
   `project.fileName` 은 원문 `techno.json` 그대로라 후보 1번이 맞는다.
2. **`check_scene_mount_parity.py` 가 `sceneFileName: project.fileName` 리터럴을 불변식으로
   핀**해 두었다(그 게이트도 `SceneDocument.swift` 도 이 과제의 소유가 아니다). 고치려면
   게이트의 불변식 정의부터 다시 써야 한다.

고친다면 착지는 `SceneRenderer` 의 `sceneFileName:` 인자 — `fileName` 의 확장자가 `pkg` 일 때만
`stem + ".json"` 으로 바꾸면 위 표의 다른 세 행은 그대로다. **`[미해결]`**

> **[2026-08-21 — 닫지 못했다. 도달만 다시 쟀다.]** 못 닫은 이유는 **표본 부재가 아니라 소유
> 경계**다. 착지가 `Sources/WapleRender/SceneRenderer.swift` 의 `sceneFileName:` 인자이고,
> 그 리터럴을 `scripts/spec/check_scene_mount_parity.py` 가
> `'sceneFileName: project.fileName\n'` 로 **불변식으로 핀**한다. 둘 다 이 과제의 소유가 아니다.
>
> 도달은 다시 재서 **0 을 재확인**했다(측정 못 한 게 아니라 실제로 0이다):
> 워크샵 `scene.pkg` **161개** 전건이 루트에 `scene.json` 을 갖고(§1.1b), 컨테이너 이름도 전건
> `scene.pkg` 다. 곧 `stem+".json"` 과 하드코딩 `scene.json` 이 **161/161 에서 같은 답**을 낸다.
> 갈리는 것은 코퍼스에 1건 있는 `gifscene.pkg`(그 경우도 Waple 후보 3번 `gifscene.json` 이 맞는다)
> 와, **아직 관측되지 않은 임의 stem 의 `.pkg`** 뿐이다.
> 넘기는 패치안은 §9 에 적었다.

### 7.8 [고, 신규 2026-08-21 — **처리됨**] 중복 접힌 키의 승자가 WE 와 반대였다

§2.1b 에서 새로 확정한 사실의 착지다. 종전 `ScenePackage` 는

* 조회를 **정확 일치 색인 → 접힌 색인** 2단으로 했고(WE 에는 정확 일치 색인이 **없다**),
* 두 색인 모두 **먼저 온 엔트리를 유지**했다(WE 는 **뒤에 온 것**이 이긴다).

`Tests/WapleCoreTests/ScenePackageFixRegressionTests.swift` 가 그 규약을 "의도된 디듑" 이라며
못 박고 있었는데, **엔진 근거가 붙어 있지 않았다.** 그래서 갈리는 자리가 값으로 이랬다
(엔트리 `Models/A.JSON`(FIRST) → `models/a.json`(SECOND) 순으로 담긴 pkg. **대소문자만 다르다** —
역슬래시를 섞으면 축이 둘이 된다, 아래 주의):

| 질의 | WE | 종전 Waple | 지금 Waple |
| --- | --- | --- | --- |
| `models/a.json` | SECOND | SECOND (정확 일치) | SECOND |
| `Models/A.JSON` | SECOND | **FIRST** (정확 일치) | SECOND |
| `MODELS/A.JSON` | SECOND | **FIRST** (접힌 색인 · 선행 유지) | SECOND |

곧 **한 pkg 안에서 질의 철자에 따라 서로 다른 바이트**가 나왔다. WE 는 그 셋을 구별하지 못한다.
에러가 아니라 **조용한 오답**이라 골든·스캐너 어느 쪽도 잡지 못한다.

> **주의 — 역슬래시는 WE 의 키에 섞으면 안 된다.** 이 고침의 **첫 판은 틀렸다.** 접힌 색인
> 하나만 두고 그 키를 `normalizedLookupKey`(역슬래시→슬래시 + 소문자)로 잡았는데, WE 의 조회
> 정규화에는 **구분자 치환이 없다**(`0x140274000`–`0x140274015` 는 `tolower` 뿐이다). 그러면
> WE 가 **서로 다른 키**로 보는 `Models\A.JSON`(키 `models\a.json`)과 `models/a.json`(키
> `models/a.json`)이 Waple 에서 한 칸으로 합쳐져 **뒤엣것이 앞엣것을 지운다** — 종전 코드가
> 정확히 주던 답을 **뺏는 새 이탈**이었다. 그래서 색인을 둘로 나눴다(아래).
> 이 축은 `ScenePackageFixRegressionTests.testBackslashEntryStaysSeparateLikeWE` 가 따로 잰다.
> (도달: 워크샵 전수 11,338 경로에 역슬래시 **0건**이라 실물에서는 어느 쪽이든 같은 답이다.)

**처리** — `ScenePackage`:
* 색인 승자를 **덮어쓰기(last-wins)** 로 바꿨다 = WE 의 `0x140276aef`/`0x140276af5`.
* 색인을 **둘로 나눴다**: `entryByFoldedName`(**WE 의 키와 동일** — ASCII 소문자화만) 과
  `entryByNormalizedName`(그 위에 역슬래시까지 접은 **Waple 전용 관용 폴백**).
* `.blob`(진짜 `.pkg`) 조회는 **1차 = WE 키, 2차 = 관용 키** 순이다. 1차는 `0x140273f50` 과
  바이트 단위로 같은 답을 내고, 2차는 WE 가 못 찾는 자리에서만 답을 **더한다**(뺏지 않는다).
* `.directory`(언팩 폴더)는 **정확 일치를 먼저** 본다 — WE 의 폴더 마운트(`0x1402764d0`)는
  엔트리 표를 만들지 않고 요청 경로로 파일을 바로 열므로, 그쪽에서 WE 와 같은 답은 정확 일치다.
  (§7.5 의 0바이트 처리를 백엔드별로 가른 것과 같은 이유다.)

**도달** — §2.1b 와 같다: ASCII 폴딩 충돌군 **14군**, pkg 별 동시 보유는 이 산출물로 판별 불가,
비둘기집 하한 **0**, 상한 **16 pkg / 161**. 곧 **미측정 구간 [0, 16]** 이고 0 이 아니다.

**무회귀 실측** — 이 변경이 무언가를 **뺏는** 유일한 경우는 한 컨테이너/폴더 안에 접힌 키가
겹치는 두 엔트리가 있는 것이다. 설치본 + 동봉 두 루트를 **디렉터리마다 형제 파일끼리** 대조하면
그런 짝이 **0건**이다(9,078 파일 · 충돌 0). 곧 `.directory` 백엔드로 도는 모든 기존 테스트
(설치본 `.mdl`/`.tex` 코퍼스 테스트 포함)는 이 변경의 영향을 받지 않는다.

```python
import os, collections
def alow(t): return "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in t)
for r in ("…/wallpaper_engine", "…/Sources/WapleRender/Resources/WEAssets"):
    for dp, _, fns in os.walk(r):
        g = collections.defaultdict(list)
        for f in fns: g[alow(f)].append(f)
        for k, v in g.items():
            if len(v) > 1: print("COLLISION", dp, v)
# -> 출력 없음 (형제 그룹 9,078 · 충돌 0)
```

**잠금** — `ScenePackageFixRegressionTests`(5건: 정확 중복 · 접힌 충돌 4철자 · **역슬래시 축 분리** ·
코퍼스 실측 이름쌍 2건 · 폴더 백엔드 예외) + `ScenePackageWEParityTests` 의 프레이밍 5건(§2.1·§2.3).
돌연변이 검증 결과는 커밋 메시지에 적었다.

### 7.6 이미 맞는 것 (다시 손대지 말 것)

- 헤더 파스 순서·필드 크기·`blobBase` 규약: `ScenePackage.parse`(`let blobBase = p`)가 §2.1 과 **완전 일치**.
  **[2026-08-21] 단, "이미 맞는 것" 은 프레이밍까지다** — 그 뒤의 **엔트리 색인**은 맞지 않았다(§7.8).
- 씬 문서 이름을 `project.json` `file` 로 정하는 것: `SceneDocument.swift` 의 `sceneCandidates`. 맞다.
- 무압축 가정: 맞다.
- 언팩 폴더 마운트(`fromDirectory`): WE 의 §4.3 3번 분기와 같은 개념. 맞다.
  (다만 WE 는 `parent_path(file)` 을, Waple 은 프로젝트 폴더를 마운트한다 — `file` 에 하위
  디렉터리 성분이 있으면 Waple 쪽이 **상위집합**이라 씬 문서 이름도 그대로 풀린다. 361건
  전건이 디렉터리 성분 없는 파일명이라 도달 0건. 의도적 이탈.)

---

## 8. 확정하지 못한 것

### 8.0 2026-08-21 조사 시작 시점의 `[미해결]` 9건 전표

이 문서에 `[미해결]` 리터럴이 **9곳**(중복 참조 포함) 있었다. 도달 큰 순서로 처리했다.
도달은 **워크샵 코퍼스 전수 산출물**(`corpus_scan/`: 446 폴더 · `scene.pkg` 161 · 엔트리 19,777 ·
경로 11,338 종)로 다시 쟀다. 이 컨테이너에 실물 `.pkg` 는 여전히 **0개**다.

| # | 절 | 항목 | 도달(재측정) | 결과 |
| --- | --- | --- | --- | --- |
| 1 | §7.1 · §8 | 스캐너(`WallpaperCompatibilityAnalyzer`)의 마운트 선택이 렌더러와 갈림 | pkg 보유 폴더 **161/446**(36.1%). 갈리는 세 조합 자체는 `file` 값이 산출물에 없어 **미측정** | **해소** — 스캐너·DeepScan 이 이미 `resolveMountSource` 를 쓰고 `check_scene_mount_parity.py` 가 핀한다 |
| 2 | §7.3 | 유니코드 정규화 키 충돌 실사례 | ASCII 폴딩 충돌군 **14군** / 유니코드 **전용** 충돌군 **0군**(11,338 경로 전수) | **해소** — 그리고 **승자 규약이 반대**임을 새로 확정해 §7.8 로 고쳤다 |
| 3 | §5.5 | `key/file/status/…` 매니페스트가 `.pkg` 안에 있는가 | 엔트리 경로 11,338 종에 그런 이름 **0건**, 루트 직속은 `scene.json` 하나 | **해소**(161 pkg 범위 부재 확정) |
| 4 | §8 | 실물 `.pkg` 바이트 덤프 | 표본 **0개**(변동 없음) | **부분 해소** — §8.2: 독립 파서가 실물 161 pkg / 19,777 엔트리를 **파스 오류 0** 으로 돌았고, 그 파서가 거부하는 조건들이 곧 실물 바이트에 대한 단언이 된다 |
| 5 | §8 | `PKGV0002` 등 구버전 프레이밍 차이 | 버전 14종(`0002`~`0024`) 실물이 **같은 파서로 전건 통과** | **부분 해소**(§8.2) |
| 6 | §4.3.1 · §7.7 · §8 (3곳) | `file:"*.pkg"` 일 때 씬 문서 이름 (`stem+".json"` vs `project.fileName`) | **0/161** — 워크샵 pkg 전건이 `scene.pkg` + 루트 `scene.json` | **미해결 유지** — 착지(`SceneRenderer.swift`)와 게이트(`check_scene_mount_parity.py`)가 **소유 밖**이다. 패치안 §9.3 |
| 7 | §7.2 | 확장자→타입 유도표 ⑴ 비디오 7종 vs 3종 · ⑵ 이미지표 · ⑶ `http(s)://` · ⑷ **`type` 우선** | **미측정** — `scenes-index.tsv` 의 타입 열은 WE 유도가 아니라 `pkgv_census.py` 자체 분류기(그것도 `type` 우선)라 이 산출물로는 못 잰다 | **미해결 유지** — 소유 밖(`ProjectJSONParser.swift`). 못 닫은 이유는 **판별 자료 부재** |

새로 **연** 것도 하나 있다 — §2.1b/§7.8 의 **중복 접힌 키 승자**. 이건 종전에 `[미해결]` 로도
안 적혀 있던 자리다(질문 자체가 없었다). 확정하고 고쳤다.

### 8.1 항목별 상태 (누적)

| 항목 | 상태 |
| --- | --- |
| 실물 `.pkg` 바이트 덤프 | **`[미해결]` — 이 환경에 표본이 0개다.** §2 는 코드 + 합성 왕복으로만 확정 · **[부분 해소 2026-08-21]** 아래 §8.2 |
| 동봉 `.pkg` 총 바이트 / 평균 엔트리 수 | **산출 불가**(표본 0). 워크샵 코퍼스 파생치 122.1 은 §1.1 참조 |
| `PKGV0002` 등 구버전의 프레이밍 차이 | 코드에 버전 분기가 **없으므로** 차이가 없다고 본다. 실물로 확인 못 함 · **[부분 해소 2026-08-21]** 실물 161 pkg(버전 14종, `0002`~`0024`)가 **같은 프레이밍으로 전건 파스 성공**했다는 산출물이 있다 — §8.2 |
| `key/file/status/name/description/version/options` 매니페스트의 읽기 함수 | **없다**(xref 1건). `.pkg` 와의 관계도 미확인 · **[해소 2026-08-21]** `.pkg` 안에는 없다 — 워크샵 161 pkg · 엔트리 경로 11,338 종 전수에 그런 이름 **0건**, 루트 직속 엔트리는 `scene.json` 하나뿐(§5.5 각주) |
| 유니코드 정규화 키 충돌 실사례 | 코퍼스 부재로 미확인. 2026-08-21 재측정에서도 **0건**(경로 컴포넌트 3,374종 전건 ASCII) — 그래서 §7.3 정정은 "고침"이 아니라 **드리프트 차단**이다 · **[해소 2026-08-21]** 워크샵 전수 11,338 경로로 다시 재서 **유니코드 전용 충돌군 0군**(ASCII 14군 = 유니코드 14군) 확정. 대신 **승자 규약이 반대**였음이 드러나 §7.8 로 고쳤다 |
| `file:"*.pkg"` 일 때의 씬 문서 이름 | **`[미해결]`** — WE 는 `stem+".json"`, Waple 은 `project.fileName`. §7.7. 도달 0건이고 `check_scene_mount_parity.py` 가 현행 리터럴을 핀한다 · **2026-08-21 재확인: 도달 0/161 · 못 닫은 이유는 소유 경계**(§7.7 각주, 패치안 §9) |
| 스캐너(`WallpaperCompatibilityAnalyzer`)의 마운트 선택 | **`[미해결]`** — §7.1 을 렌더러에만 적용했다(소유 파일 밖). 두 쪽의 "이슈 없음 = 렌더 가능" 계약이 `.pkg` 보유 프로젝트에서 갈릴 수 있다. 이 환경 도달 0건(`.pkg` 0개) · **[해소 2026-08-21]** 스캐너·DeepScan 이 이미 `resolveMountSource` 를 쓰고 `check_scene_mount_parity.py` 가 그것을 핀한다(§7.1 각주) |
| `resourceutil64.dll` 등 형제 바이너리의 pkg IO | **없다** — `PKGV`·`.pkg`·`scene.pkg` 전건 0 히트(`resourceutil64.dll` `resourcecompiler64.exe` `wallpaperservice64.exe` `webwallpaper64.exe`). `scenescript64.dll` 에 `.pkg` 1건이 있으나 패키지 IO 로 이어지는 코드는 확인하지 못했다 |

### 8.2 [부분 해소 2026-08-21] 실물 바이트 증거는 있다 — 다만 **2차 산출물**이다

종전 §8 은 "실물 `.pkg` 표본 0개 ⇒ §2 는 코드 + 합성 왕복으로만 확정" 으로 끝났다. 그 서술은
`Waple-wallpaper-source/corpus_scan/` 을 놓친다. 거기에는 **실물 워크샵 코퍼스를 실제로 돈**
독립 파서(`pkgv_parse.py`)와 그 전수 출력이 들어 있다. pkg 바이트 자체는 여전히 없지만,
**그 파서가 무엇을 거부하는지**를 읽으면 통과 사실이 곧 실물 바이트에 대한 단언이 된다.

`pkgv_parse.parse_pkg` 가 **오류로 되돌리는** 조건(코드 그대로):

| 거부 조건 | 통과가 뜻하는 것 |
| --- | --- |
| `magic_len != 8` | 161 pkg 전건이 **`magicLen == 8`** |
| `magic_field[:4] != b"PKGV"` | 161 pkg 전건이 **`PKGV` 접두를 실제로 갖는다** |
| `name_len == 0 or name_len > 4096` | 19,777 엔트리 전건이 **이름 길이 1~4096** |
| `name_off + name_len + 8 > len(data)` | TOC 가 **잘리지 않았다** |
| `last_end > len(data)` | 마지막 blob 이 **파일을 넘지 않는다** |

그리고 `parse-errors.tsv` 본문이 **0행**이다. 곧 위 다섯이 **161 pkg 전건에서 참**이다.

더 강한 것은 내용 대조다. `pkgv_census.py` 는 각 엔트리의 바이트를
`abs_off = data_start + data_off`(= `data_start` 는 TOC 끝의 파일 오프셋)로 잘라 매직으로
타입을 판정하고, 그 결과가 `chunk-type-census.md` 에 있다:

* `.json` **10,467** → 전건 `json`(내용이 `{`/`[` 로 시작), `json-probable`(확장자 폴백) **0건**
* `.tex` **4,679** → 전건 `tex`(`TEXV0005…`), `tex-unknown` **0건**
* `.mdl` 423 → `MDLV0016…`, 폰트 372 → `\x00\x01\x00\x00`/`OTTO`/`ttcf`, `OggS`·`fLaC`·`RIFF/WAVE`·ID3 도 매직으로 확인

**19,777 개의 (offset, size) 쌍이 전부 유효한 파일 시작에 착지했다.** 오프셋 기준이
"데이터 섹션 선두" 가 아니었다면 이 숫자가 나올 수 없다. 확장자와 내용이 어긋난 것은 **4건**
(Ogg 를 `.mp3`/`.wav` 로 이름 붙인 것)뿐이고 그것도 컨테이너가 아니라 저작 쪽 문제다.

**파생 사실 하나 더**: `detect_type` 은 빈 blob 을 받으면 `head[0]` 에서 `IndexError` 로 죽는다
(json/TEX/PNG/Ogg/RIFF/fLaC 검사를 전부 통과한 뒤 mp3 검사에서 첨자 접근을 한다). 센서스가
예외 없이 끝났다는 것은 **19,777 엔트리에 `size == 0` 이 0건**이라는 뜻이다 — §7.5 가
"관측하지 못했다" 로 남겨 둔 도달이 여기서 **161 pkg 범위의 0건**으로 바뀐다. (파생 추론이므로
"확정" 이 아니라 **강한 간접 증거**로 적는다.)

**남는 미해결**: ① 바이트 덤프 자체는 여전히 없다 — 위는 전부 **남이 만든 2차 산출물**이고
그 파서가 틀렸다면 같이 틀린다(다만 그 파서의 프레이밍 서술은 §2.1 디스어셈과 **필드 단위로
일치**한다: 길이 접두 8, entry_count, `nameLen|name|off|size`, `data_start = 12 + Σ(4+nameLen+8)`,
연속 배치·패딩 없음). ② 이 컨테이너에서 **재실행할 수 없다**(워크샵 루트 부재).

---

## 9. 넘길 것 (소유 밖 · 패치안)

이 조사에서 나왔지만 이 과제의 소유 파일이 아니라 손대지 않은 것들이다. 전부 **정확한 착지와
값**을 적는다.

### 9.1 `scripts/spec/measure_absence_claims.py` 의 `PKGV` 부재 주장이 **반증됐다**

그 파일의 `CLAIMS` 에 `"PKGV": {"absentIn": "all", "claim": "… 토큰 자체가 없다"}` 가 있다.
`absentIn: "all"` 은 그 스크립트 스스로 "설치본 42종 전부" 라고 정의한 범위다.
**`wallpaperui.exe` 에 ASCII `PKGV` 가 2건 있다**(부록 A.8, §2.2b). 곧 `WE_ROOT` 를 주고 돌리면
이 주장은 실패해야 한다. CI 에서 안 돌아서(바이너리 미커밋) 조용히 살아 있는 **잘못된 부재
주장**이다. 게다가 그 `claim` 문자열은 `ScenePackage.swift:50-64` 라는 **다른 파일의 줄 번호**를
인용하는데, 지금 그 줄에는 해당 주석이 없다(함정 22).

**패치안** — 범위를 좁히고 줄 번호 인용을 코드 문구로 바꾼다:

```python
"PKGV": {
    "absentIn": ["wallpaper64.exe"],
    "claim": "ScenePackage.swift 의 매직 주석 — '읽는 쪽 wallpaper64.exe 에는 PKGV 리터럴이 "
             "없다'. 쓰는 쪽 wallpaperui.exe 에는 2건 있다(packProject CLI 옆의 PKGV0024 와 "
             "UI 브리지 checkWallpaperPKGVersions) — 그래서 absentIn 은 all 이 아니라 런타임 한정",
},
```

### 9.2 `spec/formats/pkg.json` 에 §2.1b 의 세 사실이 없다

정본 `format.pkg.layout` 의 `value` 는 `header`/`entry`/`blobBase`/`compression` 네 키뿐이다.
**엔트리 표가 접힌 키 하나짜리 맵이라는 것**도, **중복 키가 last-wins 라는 것**도, **엔트리 루프의
종단 조건**도 적혀 있지 않다. 구현만 고치면 정본이 낡아 다음 사람이 되돌린다(함정 19·23).

생성기는 `scripts/spec/measure_corpus.py` 다(코퍼스가 필요해 이 컨테이너에서 재생성 불가).
**정본과 생성기 리터럴을 반드시 함께** 고치고 `specfmt.dump` 를 통해 써야 한다.
기존 네 키는 그대로 두고 **추가만** 한다(툼스톤 규약):

```python
"entryIndex": "이름을 제자리에서 ASCII tolower 하여(0x140276ac0-0x140276ad6) 그것만을 키로 쓰는 "
              "unordered_map(FNV-1a 64: 0x1402778b4/0x1402778c3) 하나. 대소문자 보존 색인 없음",
"duplicateKeyWinner": "last — 삽입은 find-or-emplace(0x140276ae4 -> 0x140277890)이고 호출부가 "
                      "조건 없이 offset/size 를 덮어쓴다(0x140276aef/0x140276af5)",
"entryLoopTermination": "고정 횟수(0x140276b3c/0x140276b40). 센티널 없음, 스트림 상태 검사 없음 "
                        "— 잘린 파일도 0(성공)으로 끝난다",
```

### 9.3 §7.7 씬 문서 이름 — 착지와 게이트가 소유 밖이다

**패치안**(`Sources/WapleRender/SceneRenderer.swift` 의 `sceneFileName:` 인자):

```swift
// WE 는 마운트 뒤 stem(file) + ".json" 을 씬 문서 이름으로 쓴다
// (0x14010e231 path::stem -> 0x14010e253 std::string::append(".json", 5)).
let declared = URL(fileURLWithPath: project.fileName ?? "")
let sceneDocName = ScenePackage.asciiLowercased(declared.pathExtension) == "pkg"
    ? declared.deletingPathExtension().lastPathComponent + ".json"
    : project.fileName
```

그리고 `scripts/spec/check_scene_mount_parity.py` 가 `sceneFileName: project.fileName` 리터럴을
불변식으로 핀하므로 그 정의부터 다시 써야 한다. **도달 0/161 이라 우선순위는 낮다** — 게이트
재작성 비용이 이득보다 크다는 판단이고, 그래서 §7.7 을 `[미해결]` 로 남겼다.

### 9.4 `scripts/re/va_citations.py` — 오탐 2건을 봤고, **이 세션 중에 고쳐졌다**(넘길 것 없음)

기록으로만 남긴다. 이 조사 초반에 그 도구로 내 파일을 돌리자 `0x140276af5` 와 `0x14010e14d` 를
"경계 이탈" 로 찍었다. **둘 다 오탐이었다.** raw 바이트로 확인했다 — `0x140276ad8` 부터
`4c 8d 45 9f | 48 8d 55 bf | 49 8d 4d 38 | e8 a7 0d 00 00 | 48 8b 08 | 8b 45 7f | 89 41 30 |
8b 45 97 | 89 41 34` 이고 `0x140276af5` 는 `89 41 34`(`mov [rcx+0x34], eax`)의 **시작**이다.
독립 capstone 런(조각 시작 `0x140276866` 부터 219 명령)에서도 경계로 나온다.

조사 후반에 다시 돌리니 **두 건 다 사라졌다** — 같은 세션에서 다른 작업이 `image_base` 를
"섹션 표의 `va - raw` 최솟값" 어림에서 PE 옵셔널 헤더의 실제 `ImageBase` 로 고쳤고, 그 어림이
조각 경계를 통째로 밀고 있었다(그 파일의 `image_base` docstring 에 그대로 적혀 있다).
지금 상태로 이 조사의 owned 파일 4개를 돌리면 **고유 VA 248 · 경계 이탈 0** 이다.

남는 한계 하나는 그대로다: `pdata_functions` 가 "조각은 그대로 둔다" 이고 `containing` 이
"앞 함수를 씌우지 않는다" 라, **조각 시작이 함수 시작이 아닌 경우**(예: 이 문서 §4.3 의
`0x14010df40` — 진짜 시작은 앞 조각의 `0x14010de40`)에는 여전히 조각 시작에서 선형으로 뜬다.
지금은 그래도 결과가 맞지만(그 조각도 명령 경계에서 시작한다) **원리상 보장은 없다** —
그 파일의 "한계" 절에 `조각 시작 ≠ 함수 시작` 을 한 줄 적어 두면 다음 사람이 안 헤맨다.

### 9.5 `Sources/WapleCore/SceneDocument.swift` — 중복 엔트리 순회

`SceneDocument` 는 `package.entries` 를 순회하며 `package.data(for: entry.name)` 을 부르는 자리가
있다. §7.8 이후 접힌 키가 겹치는 두 엔트리는 **같은 바이트**를 돌려준다(WE 와 같다). 지금 그
자리에 중복 처리 로직이 없으므로 동작은 그대로지만, 같은 바이트를 두 번 파싱하는 낭비가 생긴다.
고칠 필요는 낮고, **고친다면** 순회 전에 접힌 키로 dedup 해야 한다(먼저가 아니라 **나중** 유지).

---

## 부록 A. 재현 절차

### A.1 실물 도달 실측 (§1)

```bash
python3 - <<'EOF'
import os
roots=["/home/user/Waple-wallpaper-source/wallpaper_engine",
       "/home/user/Waple/Sources/WapleRender/Resources/WEAssets"]
n=t=h=0
for r in roots:
    for dp,_,fn in os.walk(r):
        for f in fn:
            p=os.path.join(dp,f); n+=1; t+=os.path.getsize(p)
            if b'PKGV' in open(p,'rb').read(4096): h+=1
print(n,t,h)   # -> 9078 1201781203 0
EOF
```

`project.json` 361건 센서스는 같은 순회에서 `json.load` 후 최상위 키를 세면 재현된다(§1.2 표).

### A.2 컨테이너 왕복 + LZ4 해제 (§3.2)

스크래치의 `pkgref.py` 가 ① 엔진 순서 그대로의 리더(`read_pkg`), ② 순수 파이썬 LZ4 블록
디코더(`lz4_block_decompress`), ③ 합성 빌더(`build_pkg`)를 담는다. 핵심만 옮기면:

```python
def read_pkg(b):
    p = 0
    mlen, p = i32(b, p)
    magic = "" if mlen > 8 else b[p:p+mlen].decode(); p += 0 if mlen > 8 else mlen
    if len(magic) > 4 and atoi(magic[4:]) > 24: raise PkgError            # 0x140276964
    count, p = i32(b, p)
    out = []
    for _ in range(count):
        nlen, p = i32(b, p)
        name = "" if nlen > 0x800 else b[p:p+nlen].decode('utf-8')        # 0x1402769bb
        p += 0 if nlen > 0x800 else nlen
        off, p = i32(b, p); size, p = i32(b, p)
        out.append((ascii_lower(name), off, size))                        # 0x140276ac4
    base = p                                                              # 0x140276b4d
    return [(k, base + o, s) for (k, o, s) in out]                        # 0x140276b63
```

`ascii_lower` 는 `'A'..'Z'` 만 접는다 — Swift `.lowercased()` 를 쓰면 §7.3 의 차이가 섞인다.

### A.3 로더 디스어셈

```python
import sys; sys.path.insert(0, '<scratchpad>')
import vdis2
vdis2.dis(0x140276700, 0x140276bd2)   # 컨테이너 적재
vdis2.dis(0x140273f50, 0x14027458a)   # VFS openFile (조회 + seek)
vdis2.dis(0x14011d7d0, 0x14011e51c)   # project.json 리더
vdis2.dis(0x14011e520, 0x14011e872)   # 확장자 → 타입 분류기
vdis2.dis(0x14010de40, 0x14010efa2)   # 마운트 디스패처(§4.3 — merged() 로 합친 2조각)
vdis2.dis(0x140053f80, 0x14005420f)   # path::extension() + ASCII tolower (§4.3)
vdis2.dis(0x14003fc80, 0x14003fd86)   # path::stem()        (§4.3.1)
vdis2.dis(0x14003fd90, 0x14003fe73)   # path::parent_path() (§4.3 3번 분기)
```

`0x14010df40` 은 `.pdata` 가 2조각으로 쪼개 두었고 `primary()` 가 `0x14010de40` 을 준다 —
`dis()` 를 `0x14010df40` 에서 시작하면 명령이 어긋난다. 또 이 함수는 vtable 슬롯
(`0x1404897c0`)으로만 불려 직접 call xref 가 **0건**이다.

`.rdata` 확장자 테이블은 포인터 배열이라 rip-상대 xref 로 안 잡힌다 — 절대 64비트 포인터를
직접 찾아야 한다:

```python
import struct
from wpe import pe, DATA
pat = struct.pack('<Q', 0x140478088)          # ".pkg" 문자열 VA
i = DATA.find(pat); print(hex(pe.off2va(i)))  # -> 0x140483858 (테이블 슬롯)
```

### A.4 LZ4 호출자 census (§3.1)

`.pdata` 조각마다 따로 디스어셈해야 한다 — `.text` 전체 선형 스윕은 데이터-인-코드에서
동기를 잃고 xref 를 통째로 놓친다(실제로 `.pkg` 문자열 xref 가 0건으로 나왔다).

```python
for (b, e, u) in FUNCS:
    for ins in md.disasm(DATA[pe.va2off(b):pe.va2off(b)+(e-b)], b):
        if ins.mnemonic == 'call' and ins.op_str == '0x14014c160':
            print(hex(ins.address), hex(primary(ins.address)[0]))
# -> 0x1400ce7bc 0x1400ce760 / 0x14015dcf8 0x14015c8d0   (둘 다 .tex)
```

### A.5 마운트 결정 전/후 361건 대조 (§7.1 무회귀 근거)

`before` = 종전 선택자(`scene.pkg`/`gifscene.pkg` 존재만 본다), `after` = 새 결정
(`ScenePackage.resolveMountSource` 를 파이썬으로 1:1 포팅. `WallpaperPathSecurity.
normalizedRelativePath` 의 퍼센트 디코딩·`..` 거부·URL 스킴 거부까지 옮긴다).

```python
def after(folder, j):
    rel = norm_rel(j.get("file"))
    if rel:
        url = os.path.join(folder, rel)
        if os.path.isfile(url):                                  # 게이트 ③ 0x14011e34d
            ext = os.path.splitext(url)[1].lower().lstrip(".")
            return ("pkg", url) if ext == "pkg" else ("dir", folder)
        cand = os.path.splitext(url)[0] + ".pkg"                 # 0x14011e368 replace_extension
        if os.path.isfile(cand): return ("pkg", cand)            # 게이트 ④ 0x14011e3ae
    p = legacy_pkg(folder)                                       # 하위호환 폴백(WE 에 없음)
    return ("pkg", p) if p else ("dir", folder)
```

```
total projects: 361
decision differs: 0
before decisions: Counter({'dir': 361})
after  decisions: Counter({'dir': 361})
file missing on disk: 0
```

**차이가 나는 항목은 0건이다.** 스크립트 전문은 스크래치의 `mountsim.py`.

### A.6 ASCII 폴딩 ≠ 유니코드 폴딩 도달 (§7.3 무회귀 근거)

```python
def ascii_lower(s):
    return ''.join(chr(ord(c)+32) if 'A' <= c <= 'Z' else c for c in s)
names = set()
for r in roots:
    for dp, dn, fn in os.walk(r): names.update(fn); names.update(dn)
print(len(names),
      sum(any(ord(c) > 127 for c in f) for f in names),
      sum(ascii_lower(f) != f.lower() for f in names))
# -> 3374 0 0     (경로 컴포넌트 3,374종 · 비-ASCII 0 · 폴딩 갈림 0)
```

`spec/corpus/workshop-shaders.json` 의 pkg 엔트리 경로(39종, 그중 대문자 ASCII 보유 21종)도
갈리는 것 0건이다.

### A.7 접힌 키 충돌군 도수 (§2.1b·§7.8 근거) — 2026-08-21 신설

```python
import collections
rows = []
with open("Waple-wallpaper-source/corpus_scan/entry-name-frequency.tsv", encoding="utf-8") as f:
    next(f)
    for line in f:
        c, p = line.rstrip("\n").split("\t", 1)
        rows.append((int(c), p))

def alow(t):                       # WE 의 tolower 와 같은 폴딩 (0x1402bfb34)
    return "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in t)

g = collections.defaultdict(list)
for c, p in rows: g[alow(p)].append((c, p))
groups = [(k, v) for k, v in g.items() if len(v) > 1]
print(len(rows), sum(c for c, _ in rows))          # -> 11338 19777
print("ascii-fold collision groups:", len(groups)) # -> 14
print("pigeonhole-forced same-pkg:", sum(max(0, sum(c for c, _ in v) - 161) for _, v in groups))
print("upper bound of pkgs:", sum(min(c for c, _ in v) for _, v in groups))   # -> 0 / 16
gu = collections.defaultdict(list)
for c, p in rows: gu[p.lower()].append((c, p))
print("unicode-fold groups:", len([1 for v in gu.values() if len(v) > 1]))    # -> 14 (= ascii)
```

`161` 은 `scene.pkg` 보유 폴더 수(`scenes-index.tsv` 6열 합)다. **비둘기집 하한 0 · 상한 16** —
이 산출물로는 pkg 별 동시 보유를 판별할 수 없다는 뜻이고, 그래서 도달은 **미측정**이다.

### A.8 `PKGV` 전 바이너리 도수 (§2.2b·§9.1 근거) — 2026-08-21 신설

```python
import os
root = "/home/user/Waple-wallpaper-source/wallpaper_engine"
for dp, _, fns in os.walk(root):
    for fn in fns:
        if not fn.lower().endswith((".exe", ".dll")): continue
        d = open(os.path.join(dp, fn), "rb").read()
        a, u = d.count(b"PKGV"), d.count("PKGV".encode("utf-16-le"))
        if a or u: print(os.path.relpath(os.path.join(dp, fn), root), a, u)
# -> bin/wallpaperui.exe 2 0
#    distribution/bin/wallpaperui.exe 2 0        (152 개 검사, 그 밖 전부 0)
```

파일 오프셋 `0xab2876`(`…getWallpaperResolutions \0 checkWallpaperPKGVersions \0 toggleMiniMode…`)와
`0xad0898`(`… -i \0 PKGV0024 \0 packProject …`)로 §2.2b 의 두 건이 그대로 재현된다.

### A.9 로더·조회·삽입 디스어셈 (§2.1b) — 2026-08-21 신설

```python
import sys; sys.path.insert(0, "<scratchpad>")
import vdis2
vdis2.dis(0x140276700, 0x140276bd2)   # 컨테이너 적재 — **함수 시작에서 선형으로**
vdis2.dis(0x140277890, 0x140277a3c)   # unordered_map find-or-emplace (FNV-1a 64)
vdis2.dis(0x140273f50, 0x140274190)   # VFS 조회 — 접기 + 단일 맵 프로브
vdis2.dis(0x140060720, 0x140060828)   # 길이 접두 문자열 리더 (maxLen 초과 시 미전진)
vdis2.dis(0x1402bfb1c, 0x1402bfb46)   # CRT tolower 빠른 경로 ('A'..'Z' 만)
vdis2.dis(0x14010de40, 0x14010e290)   # 마운트 디스패처 + stem+".json"
vdis2.dis(0x14003fc80, 0x14003fd88)   # path::stem — 뒤에서 마지막 '.' 를 찾는 루프가 0x14003fd6c
```

`0x140276700` 은 `.pdata` 가 `[0x140276700, 0x140276866)` + `[0x140276866, 0x140276bd2)` 두 조각
으로 쪼개 두었지만 **둘 다 명령 경계에서 시작**해 어느 쪽에서 떠도 같은 결과가 나온다(확인함).
반면 `0x14010df40` 조각은 함수 시작이 아니다 — `0x14010de40` 에서 떠야 한다(§9.4).
