# wallpaper64.exe 정적 분석 도구

WE 바이너리에서 **문자열·기본값·심볼**을 뽑는 도구다. 이 저장소는 Ghidra 를 쓰지 않는다 —
설치 의존을 만들지 않고, WE 설치본만 있으면 어디서든 도는 편이 재현성에 낫다.

> **바이너리 자체는 이 저장소에 없다.** 각자 자기 Steam 설치본을 가리켜야 한다.
> ```bash
> export WE_ROOT="/path/to/steamapps/common/wallpaper_engine"
> ```
> 기본값은 `Z:\SteamLibrary\steamapps\common\wallpaper_engine` 이다.

## 도구

| 스크립트 | 의존 | 용도 |
| --- | --- | --- |
| `xref.py` | 표준 라이브러리만 | 문자열 VA + `lea [rip+d]` 참조 + 포인터 테이블 |
| `disasm.py` | `capstone` | 주어진 VA 에서 선형 디스어셈 + rip-상대 피연산자 주석 |
| `playlist_transition.py` | 표준 라이브러리만 | 전환 효과 표(FADEEFFECT) 를 셰이더·UI·로케일 세 출처에서 교차 검증 |
| `va_citations.py` | `capstone` | 주석·문서가 인용한 VA 가 **명령 경계**인지 전수 대조. 어긋나면 어느 명령의 몇 바이트 안인지, xref 스캔이 준 disp32 위치인지까지 말해 준다 |

```bash
python scripts/re/xref.py flags perspective sphererandom
python scripts/re/disasm.py 0x1401c55e4 200
python scripts/re/va_citations.py                    # Sources·Tests·docs·spec 전수
python scripts/re/va_citations.py docs/re/tonemapping.md
python scripts/re/va_citations.py --binary "$WE_ROOT/bin/webwallpaper64.exe" docs/re/web-wallpaper-bridge.md
python scripts/re/playlist_transition.py
```

## 알아 둘 것 — 두 번 밟은 함정

**1. 선형 디스어셈으로 xref 를 찾지 마라.** `.text` 를 처음부터 훑으면 데이터/패딩에서
동기가 어긋나 그 뒤가 전부 쓰레기가 된다. 그 방식으로 참조 **0건**이 나왔었다.
`xref.py` 는 `lea` 를 **바이트 패턴**으로 찾아 동기 문제를 피하고, 오탐은
정확한 VA 일치로 거른다. `disasm.py` 는 xref 가 준 VA(=명령 경계 확실)에서만 시작할 것.

**2. `disasm.py` 를 `dis.py` 로 만들지 마라.** 파이썬 표준 라이브러리 `dis` 를 가려
capstone 임포트가 순환 임포트로 깨진다.

## WE 바이너리의 유용한 성질

- **기본값이 키 문자열 옆에 저장된다.** `.rdata` 의 파티클 키 클러스터를 덤프하면
  `"1 1 0"` 바로 뒤에 `"directions"` 가 오는 식이다. 기본값 측정의 1차 출처다.
- **float 상수는 그대로 박혀 있다.** 예: `bloomhdrscatter` 기본값 1.619 는
  바이너리에 float 로 **정확히 1회** 등장한다(`spec/engine/hdr-bloom.json`).

## 바이너리보다 먼저 볼 것

RE 는 마지막 수단이다. WE 는 아래를 **평문으로 배포**하고, 그게 디스어셈보다 나은 근거다.

| 위치 | 담긴 것 |
| --- | --- |
| `assets/shaders/*.frag,.vert,.h` | 픽셀 수식 전문(블룸 피라미드, 파티클 정점, PBR) |
| `assets/materials/util/*.json` | 패스 콤보·블렌딩 규약 |
| `ui/dist/monaco/autocomplete/lib.sceneScript.d.ts` | **WE 배포 API 정의**(속성 의미 설명 포함) |
| `locale/ui_en-us.json` | 에디터 UI 라벨 3,332개 |
| `assets/presets/**/*.json` | WE 팀이 만든 참조 저작물(A/B 대조군) |

실제로 파티클 `flags` bit4 의 의미는 디스어셈이 아니라 셰이더 + API 정의 + 프리셋 A/B 로
갈렸다(`spec/engine/particle-fields.json`).
