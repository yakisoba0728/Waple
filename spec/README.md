# spec/ — WE 2.8.42 정본

이 디렉터리는 Wallpaper Engine 2.8.42 실설치본에서 확보한 **정본(canon)** 이다.
구현이 무엇을 향해 쓰이는지의 기준이고, 여기서 테스트가 생성된다.

## 왜 코드 주석이 아니라 여기인가

이전에 역공학 산출물(`analysis/`)이 통째로 사라졌고 근거가 코드 주석에만 남았다.
지금 코드가 인용하는 `analysis/decompiled/all/FUN_140261950.c`,
`corpus_scan/mdl-format.md` 는 리포에 존재하지 않는다. 같은 사고를 구조적으로 막는다.

## 규약

1. **모든 항목에 근거(`evidence`)가 필수다.** 없으면 검증기가 거부한다.
2. **상태는 셋뿐이다.**
   - `확정` — 직접 측정했고 `generatedBy` 스크립트로 재현된다. **이 항목만 테스트를 생성한다.**
   - `보고` — 정찰이 보고했으나 재현하지 않았다.
   - `추정` — 근거 불충분. 구현이 이 값에 의존하면 코드 주석에 명시할 것.
3. **원문이 아니라 파생 사실을 담는다.** 값·표·필드 정의. WE 셰이더 원문 전사나
   전체 디컴파일 덤프는 넣지 않는다 — **저작권 때문이 아니라**(에셋은
   `Sources/WapleRender/Resources/WEAssets/` 에 원문 그대로 동봉된다) 원문 사본으로는
   테스트를 생성할 수 없고 diff 도 의미가 없기 때문이다.
4. **`weVersion` 은 항상 `2.8.42`.** WE 가 올라가면 재측정하고 이 값을 바꾼다.
5. **부정 결론은 표본 설계를 먼저 검사한다.** "X 는 되지 않는다" 를 `확정` 으로 쓰기 전에,
   **표본이 X 를 보여줄 수 있는 조건을 갖췄는지** 확인해야 한다.
   긍정 결론은 한 사례로 서지만 부정 결론은 그렇지 않다.

> 규칙 5 는 실제 사고에서 나왔다. `-transcode 는 디코더가 아니다` 를 `.tex` 5표본으로
> `확정` 기록하고 텍스처 골든 오라클을 폐기했는데, 그 5표본이 **전부 패스스루 포맷**
> (R8/RG88/raw)이라 애초에 디코드를 보여줄 수 없었다. BC 포맷으로 재검증하니 디코드가 됐고,
> 4,680개 텍스처의 오라클을 잃을 뻔했다. 정정 경위는 charter §5-3 에 남겼다.

## 검증

```bash
python scripts/spec/validate.py                  # 전체 검사
python scripts/spec/tests/test_validate.py -v    # 검증기 자체 테스트
python scripts/spec/tests/test_rosetta.py -v     # 로제타석 검증기 테스트
```

## 재측정 (WE 설치본 필요 — Windows)

```bash
python scripts/spec/measure_binaries.py        # spec/binaries.json
python scripts/spec/measure_corpus.py          # spec/corpus/, spec/formats/
python scripts/spec/measure_engine_symbols.py  # spec/engine/
python scripts/spec/measure_assets.py          # spec/assets/ (+ 에셋 동봉)
python scripts/spec/verify_rosetta.py          # .obj ↔ .mdl 대조
```

경로는 환경변수로 바꾼다: `WE_ROOT`, `WE_WORKSHOP`.

**재측정 후 `git status` 가 비어야 정상이다.** 파일이 바뀌면 측정에 비결정성이
있거나 WE 가 업데이트된 것이다.

## 문서

프로그램 차터: [../docs/superpowers/specs/2026-07-31-we-engine-port-charter.md](../docs/superpowers/specs/2026-07-31-we-engine-port-charter.md)
