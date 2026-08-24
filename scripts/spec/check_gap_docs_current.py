#!/usr/bin/env python3
"""갭 문서의 **표 행이 주장하는 미구현**이 아직도 사실인지 실측과 대조한다.

왜 있는가
---------
`docs/re/bundled-key-coverage.md` 와 `docs/re/unimplemented-json-keys.md` 는 "무엇이 아직
안 됐나" 의 지도다. 그런데 이 지도는 **한 방향으로만 썩는다** — 갭이 구현되면 표는 그대로
"없음/언급만/미구현" 이라고 적힌 채 남는다. 아무도 안 잡는다:

  · `validate.py` 는 `spec/**` 정본만 본다. `docs/**` 산문은 대상이 아니다.
  · `check_canon_generator_*.py` 는 정본↔생성기 대조라 문서와 무관하다.
  · 측정기(`scripts/re/bundled_key_coverage.py`)는 **총계**를 다시 재지만, 손으로
    큐레이션한 표(§5-A "진짜 구멍" 같은)를 갱신해 주지는 않는다.

실제로 이 게이트를 만들며 확인한 상태: `bundled-key-coverage.md` §5-A 가 "진짜 구멍 10개"
라고 못박은 `duration` · `delay` · `arcamount` · `controlpointstartindex` ·
`inputrangemin` · `inputrangemax` · `wraploop` · `nopadding` · `collisionbehavior` ·
`bouncefactor` 가 **열 개 전부 이미 구현돼 있었다.** 지도가 실제보다 비관적이면 다음 사람이
이미 닫힌 갭을 다시 파거나, 우선순위를 틀리게 잡는다.

무엇을 보는가
-------------
1. 실측: `scripts/re/bundled_key_coverage.py --json` 이 내는 **현재 구멍 목록**.
2. 문서: 대상 문서의 마크다운 표에서 **상태 칸이 정확히 `없음`/`언급만`/`미구현` 인 행**.
3. 그 행이 이름을 밝힌 키가 실측 구멍에 **없으면** → 표가 낡았다(실패).

키 추출은 백틱 토큰 중 **동봉 코퍼스에 실제로 키로 존재하는 것**만 취한다. 그래야 값 예시
칸의 `` `1` `` · `` `"slide"` `` 같은 토큰이 키로 오인되지 않는다. 코퍼스 잎 이름 인구조사는
측정기와 **독립**으로 여기서 다시 센다 — 같은 실수를 두 번 하지 않으려는 것이다.

무엇을 안 보는가 (정직하게)
---------------------------
· **절 단위 스냅샷 면제.** 머리말이 스스로 "이 표는 … 스냅샷이다" 라고 밝힌 절은 건너뛴다.
  리포 관례가 옛 측정을 지우지 않고 남기는 것이라(툼스톤), 그런 절까지 실패시키면 관례와
  싸운다. 대신 그 절은 **현재 판정을 가리키는 포인터**를 갖고 있어야 한다는 뜻이다.
· **산문 안의 `[미해결]`.** 표가 아닌 문장은 기계로 못 가른다. 이 게이트는 표만 본다.
· **설치본·워크샵 코퍼스.** 측정기가 동봉 자산만 보므로 여기도 동봉 한정이다.
· **역방향(툼스톤이 이른가)은 일부러 안 본다.** 처음엔 넣었다가 셀프테스트가 불건전함을
  잡아냈다. 측정기의 "구멍" 은 **"소스에 리터럴이 없다"** 한 가지 뜻인데, 문서의
  "해소 — 갭 아님" 은 **"엔진도 안 읽는 죽은 키/에디터 전용"** 이라는 다른 판정이다.
  실제로 `gizmos`(에디터 전용, 바이너리 문자열 0)는 문서가 옳게 "갭 아님" 이라 적었는데
  측정기 목록에는 여전히 들어 있다 — 역방향을 켜면 이런 행이 전부 거짓 경보가 된다.
  측정기가 "엔진이 읽는가" 축을 갖게 되면 그때 켜라. 순방향은 그 애매함이 없다:
  **소스가 읽는 키를 "안 읽는다" 고 적은 행은 어느 뜻으로도 틀렸다.**

고치는 법
---------
실패한 행에 툼스톤을 달아라 — `**해소(2026-MM-DD)**` 처럼. 지우지 마라(관례).
§4 처럼 측정기가 생성하는 표라면 측정기를 다시 돌려 표를 갈아 끼워라.
"""
import json
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
ASSETS = REPO / "Sources/WapleRender/Resources/WEAssets"
MEASURER = REPO / "scripts/re/bundled_key_coverage.py"

TARGETS = [
    "docs/re/bundled-key-coverage.md",
    "docs/re/unimplemented-json-keys.md",
]

# 상태 칸이 **정확히** 이것일 때만 갭 주장으로 본다(굵게·공백은 벗겨 낸다).
# "포함" 이 아니라 "일치" 인 이유: 산문 칸에 "없음" 이 흔하게 들어간다
# (예: "바이너리 문자열 0 — 리더 없음").
GAP_STATUS = {"없음", "언급만", "미구현"}


def gap_status_cell(cell: str) -> bool:
    """상태 칸이 갭 주장인가. 툼스톤을 단 뒤에도 **행은 여전히 갭 표 행**이므로
    `~~언급만~~ → **해소(2026-08-22)**` 처럼 정정된 꼴도 인정한다 — 안 그러면 문서를
    성실히 고칠수록 훑는 행 수가 줄어 하한에 걸린다(실제로 처음 그렇게 짰다가 걸렸다)."""
    head = cell.split("→")[0]
    return head.replace("~~", "").strip().strip("*").strip() in GAP_STATUS

# 행이 이미 정정된 표시. 하나라도 있으면 갭 주장이 아니라 **툼스톤 행**으로 본다.
RESOLVED_MARKS = ("해소", "구현됨", "갭 아님", "[정정", "툼스톤", "구현 완료")

# 절 머리말이 스스로 옛 스냅샷임을 밝히면 그 절은 통째로 건너뛴다.
SNAPSHOT_MARKS = ("스냅샷이다", "스냅샷 기준", "스냅샷이고", "스냅샷입니다")

SECTION_RE = re.compile(r"^#{2,4}\s")
BACKTICK_RE = re.compile(r"`([^`]+)`")
# 키 꼴: 영문/밑줄로 시작하고 점·대괄호·말줄임표만 섞인다. `1` · `"slide"` · `0.7` 은 탈락.
KEYISH_RE = re.compile(r"^[…]?[A-Za-z_][A-Za-z0-9_]*(?:(?:\[\])?\.[…]?[A-Za-z0-9_]+)*(?:\[\])?$")

# 그물이 파싱 변화로 조용히 비는 것을 막는다. **툼스톤 포함 행 수**로 센다(아래 claims 주석).
# 2026-08-22 실측 43.
MIN_CLAIMS = 35


def corpus_leaves() -> set:
    """동봉 자산 JSON 전건의 **잎 키 이름** 집합. 측정기와 독립으로 다시 센다."""
    leaves = set()

    def walk(o):
        if isinstance(o, dict):
            for k, v in o.items():
                leaves.add(k)
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)

    for p in ASSETS.rglob("*.json"):
        if p.name.endswith(".tex-json"):
            continue
        try:
            walk(json.loads(p.read_text(encoding="utf-8", errors="replace")))
        except Exception:
            continue
    return leaves


def live_gap_leaves() -> set:
    out = subprocess.run([sys.executable, str(MEASURER), "--json"],
                         capture_output=True, text=True, cwd=str(REPO))
    if out.returncode != 0:
        print("[gap-docs] 측정기가 실패했다 — 대조할 실측이 없다:", file=sys.stderr)
        print(out.stderr[-2000:], file=sys.stderr)
        sys.exit(2)
    d = json.loads(out.stdout)
    # **이름 단위로 접는다.** `gaps_by_leaf` 는 같은 잎이 스키마마다 한 줄씩 나오므로
    # 엔트리 수(2026-08-22 실측 49)와 고유 이름 수(40)가 다르다 — `version` 은 scene ·
    # project · effect 셋, `description` 은 둘이다. 이 게이트가 묻는 것은 "이 이름이 아직
    # 구멍인가" 뿐이라 접는 쪽이 맞다.
    return {g["leaf"] for g in d["gaps_by_leaf"]}


def leaf_of(token: str) -> str:
    """`emitter[].duration` → `duration`, `…a.b.magic` → `magic`."""
    t = token.strip().strip("…")
    t = t.split(".")[-1]
    return t.replace("[]", "").strip()


def sections(text: str):
    """(머리말, [줄...]) 목록. 첫 절 앞의 서문도 하나로 준다."""
    cur_head, cur = "(서문)", []
    for line in text.splitlines():
        if SECTION_RE.match(line):
            yield cur_head, cur
            cur_head, cur = line.strip(), []
        else:
            cur.append(line)
    yield cur_head, cur


def claims(text: str, corpus: set):
    """(절, 행문자열, 키집합) 목록 + **훑은 갭 표 행 총수**(툼스톤 포함).

    총수를 따로 세는 이유: 하한을 "정정 안 된 주장 수" 로 걸면 **툼스톤이 늘수록 하한에
    가까워진다** — 문서를 성실히 고칠수록 CI 가 깨지는 그물이 된다. 하한이 지키려는 것은
    "표 형식이 바뀌어 파서가 아무것도 못 찾는 상태" 이므로 **정정 여부와 무관한 행 수**로
    세야 한다.
    """
    found, rows = [], 0
    for head, body in sections(text):
        blob = "\n".join(body)
        if any(m in blob for m in SNAPSHOT_MARKS):
            continue
        for line in body:
            s = line.strip()
            if not s.startswith("|") or set(s) <= set("|- :"):
                continue
            cells = [c.strip() for c in s.strip("|").split("|")]
            if not any(gap_status_cell(c) for c in cells):
                continue
            # **첫 키 토큰만** 본다. 이 표들은 전부 키 칸이 앞에 오고, 뒤쪽 산문 칸에도
            # 백틱 토큰이 흔하다(`general`·`initializer` 처럼 코퍼스 키와 겹치는 것도 있다).
            # 행 전체를 긁으면 "그 중 하나라도 살아 있으면 통과" 가 되어 **그물이 느슨해진다** —
            # 실제로 그렇게 짰다가 `lightconfig` 행이 같은 행의 `general` 덕에 통과했다.
            keys = set()
            for tok in BACKTICK_RE.findall(s):
                if not KEYISH_RE.match(tok.strip()):
                    continue
                lf = leaf_of(tok)
                if lf in corpus:
                    keys.add(lf)
                    break
            if not keys:
                continue
            rows += 1
            if any(m in s for m in RESOLVED_MARKS):
                continue      # 이미 정정된 행 — 순방향 검사 대상이 아니다
            found.append((head, s, keys))
    return found, rows


def selftest() -> None:
    corpus = {"duration", "camerapreview", "version"}
    live = {"camerapreview", "version"}

    doc = "\n".join([
        "## 4. 구멍 표",
        "| 파일 | 키 | 상태 | 타입 |",
        "| ---: | --- | --- | --- |",
        "| 168 | `general.camerapreview` | 언급만 | bool |",        # 살아 있는 갭 → 통과
        "| 32 | `emitter[].duration` | 언급만 | int — `1`, `0` |",  # 이미 구현 → 잡아야 한다
        "| 1 | `version` | ~~언급만~~ → **해소(2026-01-01)** | int |",  # 정정된 꼴도 행으로 센다
        "## 9. 스냅샷 절",
        "> 이 표는 2026-01-01 스냅샷이다.",
        "| 1 | `emitter[].duration` | 언급만 | int |",              # 절 면제
    ])
    cl, rows = claims(doc, corpus)
    assert len(cl) == 2, f"주장 2건이어야 한다(툼스톤·스냅샷 면제) — 실제 {len(cl)}"
    assert rows == 3, f"훑은 행은 툼스톤을 **포함해** 3이어야 한다 — 실제 {rows}"
    stale = [c for c in cl if not (c[2] & live)]
    assert len(stale) == 1 and "duration" in stale[0][2], stale

    # 값 예시 칸의 토큰은 키로 오인되면 안 된다.
    only_values = "| 1 | `emitter[].duration` | 언급만 | float — `0.7`, `\"slide\"` |"
    ks = claims("## x\n" + only_values, corpus)[0][0][2]
    assert ks == {"duration"}, ks

    # 상태는 **일치**여야 한다 — 산문 안의 "없음" 은 주장이 아니다.
    prose = "| `version` | 바이너리에 리더 없음 | 검토중 |"
    assert claims("## x\n" + prose, corpus)[0] == [], "산문 '없음' 을 주장으로 세면 안 된다"

    # 코퍼스에 없는 토큰은 키가 아니다.
    assert claims("## x\n| 1 | `notakey` | 없음 | int |", corpus)[0] == []
    print("selftest: OK")


def main() -> int:
    selftest()
    corpus = corpus_leaves()
    live = live_gap_leaves()

    stale, scanned = [], 0
    for rel in TARGETS:
        p = REPO / rel
        if not p.exists():
            print(f"[gap-docs] 대상 문서가 없다: {rel}")
            return 1
        cl, rows = claims(p.read_text(encoding="utf-8"), corpus)
        scanned += rows
        for head, row, keys in cl:
            if not (keys & live):
                stale.append((rel, head, row, sorted(keys)))

    if scanned < MIN_CLAIMS:
        print(f"[gap-docs] 훑은 갭 표 행 {scanned}건 — 하한 {MIN_CLAIMS} 미만. "
              f"표 형식이 바뀌어 그물이 빈 것으로 본다.")
        return 1

    for rel, head, row, keys in stale:
        print(f"[gap-docs] **표가 낡았다** {rel} {head}")
        print(f"    {row}")
        print(f"    → {' · '.join(keys)} 는 이미 소스가 읽는다. 행에 툼스톤을 달아라"
              f"(지우지 말고 `**해소(날짜)**`).")
    if stale:
        print(f"[gap-docs] 갭 표 행 {scanned}건 · **낡은 행 {len(stale)}건**")
        return 1
    print(f"[gap-docs] 갭 표 행 {scanned}건(툼스톤 포함) · 코퍼스 잎 {len(corpus)} · "
          f"실측 구멍 {len(live)} · 불일치 0건")
    return 0


if __name__ == "__main__":
    sys.exit(main())
