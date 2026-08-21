#!/usr/bin/env python3
"""동봉 WE 자산 JSON 전건의 **키 경로**를 뽑아 Waple 소스가 그 키를 읽는지 기계적으로 대조한다.

목적은 하나다 — **"우리가 통째로 못 읽고 버리는 키"의 완전한 목록**을 근거와 함께 얻는 것.
사람의 기억이나 감이 아니라, 자산에 실제로 있는 키 ∖ 소스에 실제로 있는 문자열 로 계산한다.

    python3 scripts/re/bundled_key_coverage.py             # 사람이 읽는 요약
    python3 scripts/re/bundled_key_coverage.py --json      # 기계 판독(JSON)
    python3 scripts/re/bundled_key_coverage.py --by-leaf   # 구멍 표를 키 이름 단위로
    python3 scripts/re/bundled_key_coverage.py --schema scene --top 50
    python3 scripts/re/bundled_key_coverage.py --status none mention
    python3 scripts/re/bundled_key_coverage.py --assets /path/to/wallpaper_engine/assets

표준 라이브러리만 쓴다(`scripts/re/xref.py` 와 같은 방침 — 설치 의존을 만들지 않는다).


## 1. 스키마 판정 — 파일명 우선, 그 다음 경로

동봉 자산은 `presets/magic/previewtrinity/materials/presets/magic_trinity.json` 처럼
**최상위 디렉터리가 스키마를 말해 주지 않는다**(저건 프리셋 폴더 안의 *머티리얼*이다).
그래서 판정은 아래 순서로 한다. 위에서 먼저 맞는 것이 이긴다.

    1. basename == scene.json      → scene      씬 그래프
    2. basename == project.json    → project    프로젝트 매니페스트
    3. basename == effect.json     → effect     이펙트 매니페스트(전건 effects/** 하위임을 확인)
    4. basename == template.json   → template   에디터 신규-씬 템플릿
    5. basename == preset.json     → preset     프리셋 매니페스트(변형 목록)
    6. basename == config.json     → config     zcompat 셰이더 대체 규칙
    7. 경로에 /materials/ 세그먼트 → material   머티리얼(passes[])
    8. 경로에 /models/ 세그먼트    → model      모델 래퍼(.json 형)
    9. 경로에 /particles/ 세그먼트 → particle   파티클 시스템
   10. zcompat/web/*.json          → zcompat-web  웹 월페이퍼 패치 규칙
   11. shaders/declarations.json   → shaderdecl   에디터 셰이더 선언 카탈로그
   12. 최상위가 scenes/            → scene      (`scenes/gifs/gifscene.json` — 파일명이 관례를
                                                벗어나지만 내용은 씬 그래프다. WE 의
                                                `templates/gif` 프로젝트가 `file` 로 가리킨다)
   13. 그 외                       → misc       (현재 동봉 자산에서 0건)

`*.tex` 는 JSON 이 아니므로 애초에 대상이 아니고, **`*.tex-json` 도 제외한다** — 저건 텍스처
빌드 사이드카(임포터 입력)라 런타임 씬 파서가 읽는 스키마가 아니다. 이 스크립트는 확장자가
정확히 `.json` 인 파일만 본다.


## 2. 키 경로 표기

    general.clampuvs        오브젝트 키
    passes[].compose        배열 원소 안의 키
    objects[].effects[]     배열 그 자체

**열린 사전은 접는다.** `constantshadervalues` / `combos` / `usershadervalues` /
`general.properties`(프로젝트 사용자 속성) / `gizmos[].vars` / `condition`·`conditions[]`
아래의 키 이름은 셰이더 유니폼명·콤보명·저작자 지정명이라 스키마가 아니다. 접지 않으면 `constantshadervalues` 하나로 키 경로가 135개
불어나 히스토그램이 무의미해진다. 접은 자리는 `<*>` 로 표기한다.

집계 단위는 **등장 파일 수**다(한 파일에 같은 경로가 100번 나와도 1). 그래야 "이 키를 쓰는
자산이 몇 개냐" 라는 질문에 답이 된다.


## 3. 소스 대조 — 3분류, 그리고 그 한계

키 **이름**(경로의 마지막 마디)을 `"` 로 감싼 리터럴(`"clampuvs"`)로 `grep -rF` 한다.
WE 자산 파서는 전건 `obj["key"]` 첨자 방식이고 Codable/CodingKeys 를 쓰지 않으므로
(`ProjectJSONParser`·`SceneDocument`·`ParticleSystem` 전부 그렇다) 이 리터럴 검색이 타당한
대리 지표다.

    없음   (none)     소스·테스트·문서 어디에도 그 리터럴이 없다
    언급만 (mention)  주석/문서/테스트에만 있다 — 파서 코드에는 없다
    파스됨 (parsed)   Sources/ 의 **비주석 코드**에 있다

대조 코퍼스는 `Sources/`·`Tests/`(코드) 와 `docs/`·`spec/`·`scripts/`·루트 md(문서)다.
**두 가지를 반드시 뺀다** — (1) `Sources/WapleRender/Resources/WEAssets/` 자신(동봉 자산이
`Sources/` 안에 있어서, 안 빼면 모든 키가 자기 자신에 매칭돼 전건 "파스됨" 이 되는 무의미한
항등식이 된다), (2) 이 스크립트와 그 리포트(`SELF_EXCLUDE`) — 구멍을 적은 문서가 그 구멍을
메우면 안 된다.

주석 판정은 파일 단위로 한다. 각 소스 파일에서 문자열 리터럴 상태를 추적하며 `//` 줄 주석과
`/* */` 블록 주석을 걷어낸 "코드만" 텍스트를 만들고, 그 안에 리터럴이 있으면 파스됨이다.
(`"http://…"` 처럼 문자열 안의 `//` 를 주석으로 오인하지 않으려면 이 상태 추적이 필요하다.)

**문자열 보간으로 만드는 키도 잡는다.** `SceneDocument` 는 번호 붙은 키를 루프로 읽는다:

    if let v = vec3(io["controlpoint\(i)"]) { ov.controlPoints[i] = v }

이러면 `"controlpoint1"` 리터럴이 소스에 **한 번도 안 나온다** — 순진한 리터럴 검색은
동봉 34개 씬이 쓰는 이 키를 `없음` 으로 오판한다. 그래서 코드에서 `"접두사\(…)"` 꼴 리터럴의
접두사를 모아 두고, 키 이름이 그 접두사 + **숫자**로 끝나면 파스됨(보간)으로 친다.
숫자로 한정하는 것이 중요하다 — `controlpoint` 접두사는 `controlpoint1` 을 잡지만
`controlpointangle1` 은 **안 잡는다**. 실제로 후자는 아직 미구현이고(같은 파일 선언부 주석),
그 구멍이 접두사 일치에 먹히면 안 된다.

### 반드시 알고 볼 것 — 두 가지 편향

**(a) 주입 ≠ 소비.** 리터럴이 코드에 있다고 그 키를 *읽는* 것은 아니다. 기본값 주입기가
`"gravity"` 를 **쓰는**(write) 자리일 수도 있다. 그래서 `파스됨` 은 "읽는다"가 아니라
**"이 문자열이 파서 코드에 등장한다"** 로만 읽어야 한다.

**(b) 이름 충돌.** 대조는 키 **이름**으로 하는데 보고는 키 **경로**로 한다. `min` 은
`initializer[].min` 에서 읽지만 `emitter[].min` 은 안 읽을 수 있는데, 둘 다 `파스됨` 으로
찍힌다. 즉 이 도구가 내는 `없음`/`언급만` 목록은 **실제 구멍의 하한**이다 — 여기 오른 것은
확실한 구멍이고, `파스됨` 중에도 구멍이 섞여 있다. 이름이 2개 이상의 스키마에 걸친 경로에는
`leaf_ambiguous` 플래그를 달아 그 하한의 폭을 드러낸다.

편향 방향이 안전한 쪽(과소 보고)이라 목록의 신뢰도는 높다. 목록에 있는 것부터 메우면 된다.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import re
import subprocess
import sys

# ── 경로 기본값 ────────────────────────────────────────────────────────────────
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
ASSETS = os.path.join(REPO, "Sources", "WapleRender", "Resources", "WEAssets")

# 소스 대조 대상. WEAssets 자신은 반드시 뺀다 — 동봉 자산이 Sources/ **안에** 있어서
# 빼지 않으면 모든 키가 자기 자신에 매칭돼 전건 "파스됨" 이 된다(무의미한 항등식).
CODE_ROOTS = ["Sources", "Tests"]
DOC_ROOTS = ["docs", "spec", "scripts", "AGENTS.md", "BACKLOG.md", "README.md", "AUDIT.md"]
CODE_EXT = (".swift", ".m", ".h", ".metal")
EXCLUDE_DIR_PARTS = (os.path.join("Resources", "WEAssets"),)

# **이 도구 자신의 산출물은 코퍼스에서 뺀다.** 안 빼면 자기 참조로 결과가 무너진다:
# 이 스크립트의 docstring 과 리포트가 구멍 키를 `"nopadding"` 처럼 따옴표째 인용하므로,
# 리포트를 쓰는 순간 그 키들이 `없음` → `언급만` 으로 옮겨간다(실측: 51 → 42).
# **구멍을 적은 문서가 그 구멍을 메워서는 안 된다.**
SELF_EXCLUDE = (
    os.path.join("scripts", "re", "bundled_key_coverage.py"),
    os.path.join("docs", "re", "bundled-key-coverage.md"),
)

# ── 스키마 판정 ────────────────────────────────────────────────────────────────
BY_BASENAME = {
    "scene.json": "scene",
    "project.json": "project",
    "effect.json": "effect",
    "template.json": "template",
    "preset.json": "preset",
    "config.json": "config",
}
BY_SEGMENT = [("materials", "material"), ("models", "model"), ("particles", "particle")]

SCHEMA_DESC = {
    "scene": "씬 그래프 — 카메라·general·objects 트리",
    "project": "프로젝트 매니페스트 — file/type/title/general.properties",
    "effect": "이펙트 매니페스트 — passes/dependencies/gizmos",
    "template": "에디터 신규-씬 템플릿",
    "preset": "프리셋 매니페스트 — variants[].objects",
    "config": "zcompat 셰이더 대체 규칙",
    "material": "머티리얼 — passes[] 셰이더·블렌딩·텍스처",
    "model": "모델 래퍼 — material + 레이어 플래그",
    "particle": "파티클 시스템 — emitter/initializer/operator/renderer",
    "zcompat-web": "웹 월페이퍼 소스 패치 규칙",
    "shaderdecl": "에디터 셰이더 선언 카탈로그",
    "misc": "위 어디에도 안 붙는 잔여",
}

# 열린 사전 — 아래 경로 **아래의** 키 이름은 스키마가 아니라 저작자/셰이더가 정하는 이름이다.
# `conditions`/`condition` 의 자식 키는 **셰이더 콤보 이름**(PERSPECTIVE·LIGHTING·POINTEMITTER…)
# 이지 스키마가 아니다. `EffectManifest.parseConditions` 도 이름을 모르고 일반 처리한다.
OPEN_DICT_SUFFIXES = (
    "constantshadervalues",
    "usershadervalues",
    "combos",
    "general.properties",
    "gizmos[].vars",
    "condition",
    "conditions",
    "conditions[]",
)
WILDCARD = "<*>"


def classify(rel: str) -> str:
    """자산 상대 경로 → 스키마 이름. 위 docstring 의 판정 순서를 그대로 구현한다."""
    rel = rel.replace(os.sep, "/")
    segs = rel.split("/")
    base = segs[-1]
    if base in BY_BASENAME:
        return BY_BASENAME[base]
    parents = segs[:-1]
    for seg, name in BY_SEGMENT:
        if seg in parents:
            return name
    if len(segs) >= 2 and segs[0] == "zcompat" and segs[1] == "web":
        return "zcompat-web"
    if rel == "shaders/declarations.json":
        return "shaderdecl"
    if segs[0] == "scenes":
        return "scene"
    return "misc"


# ── 관대 JSON 파스 ─────────────────────────────────────────────────────────────
# WE 는 jsoncpp 의 allowComments/allowTrailingCommas 를 둘 다 켠다. 동봉 자산이 실제로 그
# 관용에 의존한다(Sources/WapleCore/AssetJSON.swift 의 근거 주석 참조). 엄격 파스를 먼저 하고
# 실패했을 때만 전처리한다 — Waple 런타임과 같은 순서라 두 쪽이 어긋나지 않는다.
def _relax(text: str) -> str:
    out = []
    i, n = 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1; continue
        if c == '"':
            in_str = True; out.append(c); i += 1; continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == ",":
            j = i + 1
            while j < n and text[j] in " \t\r\n":
                j += 1
            if j < n and text[j] in "]}":
                i += 1; continue
        out.append(c); i += 1
    return "".join(out)


def load_json(path: str):
    raw = open(path, encoding="utf-8-sig", errors="replace").read()
    try:
        return json.loads(raw), None
    except Exception:
        pass
    try:
        return json.loads(_relax(raw)), "relaxed"
    except Exception as exc:
        return None, "fail: %s" % str(exc)[:80]


# ── 키 경로 추출 ───────────────────────────────────────────────────────────────
def _is_open(prefix: str) -> bool:
    """이 경로 **아래**의 키 이름이 스키마가 아니라 저작자/셰이더가 정하는 이름인가."""
    return any(prefix == suf or prefix.endswith("." + suf) for suf in OPEN_DICT_SUFFIXES)


def key_paths(node, samples: dict, prefix: str = "") -> set:
    """한 문서에서 나온 **서로 다른** 키 경로 집합. 값 예시도 함께 모은다."""
    found = set()

    def walk(n, pre):
        if isinstance(n, dict):
            if _is_open(pre):
                q = pre + "." + WILDCARD
                found.add(q)
                for v in n.values():
                    _sample(samples, q, v)
                    walk(v, q)
                return
            for k, v in n.items():
                q = (pre + "." + k) if pre else k
                found.add(q)
                _sample(samples, q, v)
                walk(v, q)
        elif isinstance(n, list):
            for v in n:
                walk(v, pre + "[]")

    walk(node, prefix)
    return found


def _typename(v) -> str:
    if v is None: return "null"
    if isinstance(v, bool): return "bool"
    if isinstance(v, int): return "int"
    if isinstance(v, float): return "float"
    if isinstance(v, str): return "string"
    if isinstance(v, list): return "array"
    if isinstance(v, dict): return "object"
    return type(v).__name__


def _sample(samples: dict, path: str, v):
    slot = samples.setdefault(path, {"types": collections.Counter(), "values": []})
    slot["types"][_typename(v)] += 1
    if len(slot["values"]) < 6 and not isinstance(v, (dict, list)):
        s = json.dumps(v, ensure_ascii=False)
        if s not in slot["values"]:
            slot["values"].append(s)
    elif len(slot["values"]) < 6 and isinstance(v, (dict, list)):
        s = json.dumps(v, ensure_ascii=False)
        s = s if len(s) <= 70 else s[:67] + "..."
        if s not in slot["values"]:
            slot["values"].append(s)


# ── 소스 코퍼스 ────────────────────────────────────────────────────────────────
def _excluded(path: str) -> bool:
    return any(part in path for part in EXCLUDE_DIR_PARTS)


def _is_self(path: str) -> bool:
    return any(path.endswith(suf) for suf in SELF_EXCLUDE)


def collect_files(repo: str) -> tuple[list, list]:
    code, docs = [], []
    for root in CODE_ROOTS:
        base = os.path.join(repo, root)
        for dp, dn, fn in os.walk(base):
            if _excluded(dp):
                dn[:] = []
                continue
            for f in fn:
                q = os.path.join(dp, f)
                if f.endswith(CODE_EXT) and not _is_self(q):
                    code.append(q)
    for root in DOC_ROOTS:
        base = os.path.join(repo, root)
        if os.path.isfile(base):
            if not _is_self(base):
                docs.append(base)
            continue
        for dp, dn, fn in os.walk(base):
            if _excluded(dp):
                dn[:] = []
                continue
            for f in fn:
                q = os.path.join(dp, f)
                if f.endswith((".md", ".json", ".py", ".sh", ".txt", ".swift")) and not _is_self(q):
                    docs.append(q)
    return sorted(code), sorted(docs)


_BLOCK = re.compile(r"/\*.*?\*/", re.S)
# `"controlpoint\(i)"` 처럼 보간으로 조립하는 키의 **접두사**를 뽑는다. 접두사가 짧으면
# (`"\(x)"` 같은 순수 보간, `"g_\(n)"`) 아무 키나 걸리므로 4자 이상만 쓴다.
_INTERP = re.compile(r'"([A-Za-z_][A-Za-z0-9_]{3,})\\\(')


def strip_comments(text: str) -> str:
    """Swift/ObjC 소스에서 주석만 지운다. 문자열 리터럴 안의 `//` 는 건드리지 않는다."""
    out = []
    i, n = 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            if c == "\\" and i + 1 < n:
                out.append(text[i:i + 2]); i += 2; continue
            out.append(c)
            if c == '"':
                in_str = False
            i += 1; continue
        if c == '"':
            in_str = True; out.append(c); i += 1; continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            depth, i = 1, i + 2
            while i < n and depth:
                if text.startswith("/*", i): depth += 1; i += 2
                elif text.startswith("*/", i): depth -= 1; i += 2
                else: i += 1
            continue
        out.append(c); i += 1
    return "".join(out)


def grep_hits(repo: str, names: list, code: list, docs: list) -> dict:
    """`grep -rF` 한 방으로 후보 파일을 좁히고, 그 파일만 정밀 판정한다.

    키 하나마다 grep 을 돌리면 500회 프로세스 기동이라 느리다. `-f` 로 패턴을 한꺼번에
    넘겨 **한 번만** 훑고, 걸린 파일에서만 주석/코드 분리를 한다 — 결과는 동일하고 빠르다.
    """
    pats = "\n".join('"%s"' % nm for nm in names) + "\n"
    pf = os.path.join(repo, ".bundled_key_coverage.patterns.tmp")
    with open(pf, "w", encoding="utf-8") as fh:
        fh.write(pats)
    hit_files = set()
    try:
        for group in (code, docs):
            for chunk in (group[i:i + 400] for i in range(0, len(group), 400)):
                if not chunk:
                    continue
                r = subprocess.run(["grep", "-lF", "-f", pf] + chunk,
                                   capture_output=True, text=True)
                hit_files.update(x for x in r.stdout.splitlines() if x)
    finally:
        os.unlink(pf)

    # 보간 접두사는 grep 후보에 안 걸리므로 코퍼스를 따로 훑는다(코드 425개, 1초 미만).
    interp = {}   # 접두사 -> 그 접두사를 만드는 소스 파일
    src_dir = os.path.join(repo, "Sources") + os.sep
    for path in code:
        if not path.startswith(src_dir):
            continue
        try:
            bare = strip_comments(open(path, encoding="utf-8", errors="replace").read())
        except OSError:
            continue
        for m in _INTERP.finditer(bare):
            interp.setdefault(m.group(1), os.path.relpath(path, repo))

    codeset, docset = set(code), set(docs)
    res = {nm: {"src_code": [], "src_comment": [], "test_code": [], "doc": [],
                "interp": []} for nm in names}
    for nm in names:
        for pre, where in interp.items():
            # 접두사 + 숫자만 인정한다. `controlpoint`+`1` → OK, `controlpoint`+`angle1` → 불인정.
            if nm != pre and nm.startswith(pre) and nm[len(pre):].isdigit():
                res[nm]["interp"].append("%s ← \"%s\\(…)\"" % (where, pre))
    lookup = {'"%s"' % nm: nm for nm in names}
    tests_dir = os.path.join(repo, "Tests") + os.sep
    for path in sorted(hit_files):
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        is_code = path in codeset
        bare = strip_comments(text) if is_code else text
        rel = os.path.relpath(path, repo)
        is_test = path.startswith(tests_dir)
        for lit, nm in lookup.items():
            if lit not in text:
                continue
            if is_code and lit in bare:
                bucket = "test_code" if is_test else "src_code"
            elif is_code:
                bucket = "src_comment"
            else:
                bucket = "doc"
            if len(res[nm][bucket]) < 8:
                res[nm][bucket].append(rel)
            else:
                res[nm][bucket].append(None)  # 개수만 센다
    return res


def status_of(hit: dict) -> str:
    if hit["src_code"] or hit.get("interp"):
        return "parsed"
    if hit["src_comment"] or hit["test_code"] or hit["doc"]:
        return "mention"
    return "none"


STATUS_KO = {"parsed": "파스됨", "mention": "언급만", "none": "없음"}


# ── 본체 ───────────────────────────────────────────────────────────────────────
def build(assets: str, repo: str) -> dict:
    per_schema = collections.defaultdict(collections.Counter)   # schema -> path -> 파일 수
    leaf_files = collections.defaultdict(lambda: collections.defaultdict(set))  # schema -> leaf -> {파일}
    leaf_paths = collections.defaultdict(lambda: collections.defaultdict(set))
    schema_files = collections.Counter()
    samples: dict = {}
    rep_asset: dict = {}         # (schema, path) -> 대표 자산 경로
    parse_notes = []
    total = 0
    for dp, dn, fn in os.walk(assets):
        for f in sorted(fn):
            if not f.endswith(".json"):
                continue                       # *.tex / *.tex-json 은 여기서 걸러진다
            path = os.path.join(dp, f)
            rel = os.path.relpath(path, assets).replace(os.sep, "/")
            schema = classify(rel)
            doc, note = load_json(path)
            total += 1
            schema_files[schema] += 1
            if note and note.startswith("fail"):
                parse_notes.append({"file": rel, "note": note}); continue
            if note:
                parse_notes.append({"file": rel, "note": note})
            for p in key_paths(doc, samples):
                per_schema[schema][p] += 1
                rep_asset.setdefault((schema, p), rel)
                lf = p.split(".")[-1].replace("[]", "")
                if lf and lf != WILDCARD:
                    leaf_files[schema][lf].add(rel)
                    leaf_paths[schema][lf].add(p)

    names = sorted({p.split(".")[-1].replace("[]", "") for c in per_schema.values() for p in c
                    if p.split(".")[-1].replace("[]", "") not in ("", WILDCARD)})
    code, docs = collect_files(repo)
    hits = grep_hits(repo, names, code, docs)

    leaf_schemas = collections.defaultdict(set)
    for schema, c in per_schema.items():
        for p in c:
            leaf_schemas[p.split(".")[-1].replace("[]", "")].add(schema)

    out = {
        "assets_root": os.path.relpath(assets, repo),
        "asset_files": total,
        "corpus": {"code_files": len(code), "doc_files": len(docs)},
        "parse_notes": parse_notes,
        "schemas": {},
        "leaf_names": len(names),
    }
    for schema in sorted(per_schema, key=lambda s: -schema_files[s]):
        rows = []
        for p, n in per_schema[schema].most_common():
            leaf = p.split(".")[-1].replace("[]", "")
            hit = hits.get(leaf, {"src_code": [], "src_comment": [], "test_code": [],
                                  "doc": [], "interp": []})
            st = status_of(hit) if leaf and leaf != WILDCARD else "parsed"
            samp = samples.get(p, {"types": collections.Counter(), "values": []})
            rows.append({
                "path": p, "leaf": leaf, "files": n, "status": st,
                "types": dict(samp["types"]), "values": samp["values"][:2],
                "asset": rep_asset.get((schema, p)),
                "leaf_ambiguous": len(leaf_schemas.get(leaf, ())) > 1,
                "evidence": {k: [x for x in v if x][:3] for k, v in hit.items()},
                "tests_only": bool(hit["test_code"]) and not hit["src_code"],
                "via": ("literal" if hit["src_code"]
                        else "interpolation" if hit.get("interp") else None),
            })
        lrows = []
        for lf, files in sorted(leaf_files[schema].items(), key=lambda kv: -len(kv[1])):
            hit = hits.get(lf, {"src_code": [], "src_comment": [], "test_code": [],
                                "doc": [], "interp": []})
            paths = sorted(leaf_paths[schema][lf])
            samp = samples.get(paths[0], {"types": collections.Counter(), "values": []})
            ty = collections.Counter()
            vals = []
            for q in paths:
                sp = samples.get(q)
                if not sp:
                    continue
                ty.update(sp["types"])
                for v in sp["values"]:
                    if v not in vals and len(vals) < 4:
                        vals.append(v)
            lrows.append({
                "leaf": lf, "files": len(files), "status": status_of(hit),
                "paths": paths[:6], "path_count": len(paths),
                "types": dict(ty), "values": vals[:2],
                "asset": sorted(files)[0],
                "leaf_ambiguous": len(leaf_schemas.get(lf, ())) > 1,
                "via": ("literal" if hit["src_code"]
                        else "interpolation" if hit.get("interp") else None),
                "evidence": {k: [x for x in v if x][:3] for k, v in hit.items()},
            })
        out["schemas"][schema] = {
            "desc": SCHEMA_DESC.get(schema, ""), "files": schema_files[schema],
            "key_paths": len(rows), "rows": rows, "leaves": lrows,
            "by_status": dict(collections.Counter(r["status"] for r in rows)),
            "by_status_leaf": dict(collections.Counter(r["status"] for r in lrows)),
        }
    return out


def gaps(data: dict, by_leaf: bool = False) -> list:
    """`없음` + `언급만` 을 **동봉 도달 수 내림차순**으로.

    기본은 (스키마, 키 경로) 단위. `by_leaf` 면 (스키마, 키 이름) 단위로 접는다 — 같은 이름이
    `…c0[].lockangle`/`…c1[].lockangle`/`…c2[].lockangle` 처럼 인덱스만 다른 경로로 흩어져
    표를 채우는 것을 막는다. 이때 도달 수는 **서로 다른 파일 수**라 중복 계산되지 않는다.
    """
    key = "leaves" if by_leaf else "rows"
    rows = []
    for schema, blk in data["schemas"].items():
        for r in blk.get(key, []):
            if r["status"] in ("none", "mention"):
                rows.append(dict(r, schema=schema))
    rows.sort(key=lambda r: (-r["files"], r["schema"], r.get("path") or r["leaf"]))
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description="동봉 WE 자산 JSON 키 경로 ↔ Waple 소스 대조")
    ap.add_argument("--assets", default=ASSETS, help="자산 루트(기본: 동봉 WEAssets)")
    ap.add_argument("--repo", default=REPO, help="대조할 저장소 루트")
    ap.add_argument("--json", action="store_true", help="기계 판독 출력")
    ap.add_argument("--top", type=int, default=30, help="구멍 표에 낼 행 수")
    ap.add_argument("--schema", help="이 스키마만 본다")
    ap.add_argument("--by-leaf", action="store_true",
                    help="구멍 표를 키 경로 대신 **키 이름** 단위로 접는다(도달 수 = 파일 수)")
    ap.add_argument("--status", nargs="*", choices=["none", "mention", "parsed"],
                    help="이 상태만 본다")
    args = ap.parse_args()

    data = build(args.assets, args.repo)
    if args.schema:
        data["schemas"] = {k: v for k, v in data["schemas"].items() if k == args.schema}
    if args.status:
        keep = set(args.status)
        for blk in data["schemas"].values():
            blk["rows"] = [r for r in blk["rows"] if r["status"] in keep]
            blk["leaves"] = [r for r in blk["leaves"] if r["status"] in keep]

    if args.json:
        json.dump({"summary": data, "gaps": gaps(data),
                   "gaps_by_leaf": gaps(data, by_leaf=True)},
                  sys.stdout, ensure_ascii=False, indent=1)
        print()
        return 0

    print("자산 루트 : %s" % data["assets_root"])
    print("자산 파일 : %d개 (.json 만 — .tex/.tex-json 제외)" % data["asset_files"])
    print("대조 코퍼스: 코드 %d개 · 문서 %d개 (WEAssets 자신은 제외)"
          % (data["corpus"]["code_files"], data["corpus"]["doc_files"]))
    print("키 이름   : %d개" % data["leaf_names"])
    relaxed = [n for n in data["parse_notes"] if n["note"] == "relaxed"]
    failed = [n for n in data["parse_notes"] if n["note"].startswith("fail")]
    print("파스      : 관대 전처리 %d건 · 실패 %d건" % (len(relaxed), len(failed)))
    for n in failed[:5]:
        print("   실패 %s — %s" % (n["file"], n["note"]))

    print("\n=== 스키마별 ===")
    print("%-12s %6s %8s %8s %8s %8s   %s" % ("스키마", "파일", "키경로", "파스됨", "언급만", "없음", "설명"))
    tot = collections.Counter()
    for schema, blk in data["schemas"].items():
        s = blk["by_status"]
        for k, v in s.items():
            tot[k] += v
        print("%-12s %6d %8d %8d %8d %8d   %s"
              % (schema, blk["files"], blk["key_paths"], s.get("parsed", 0),
                 s.get("mention", 0), s.get("none", 0), blk["desc"]))
    print("%-12s %6d %8d %8d %8d %8d"
          % ("합계", data["asset_files"], sum(b["key_paths"] for b in data["schemas"].values()),
             tot["parsed"], tot["mention"], tot["none"]))

    g = gaps(data, by_leaf=args.by_leaf)
    unit = "키 이름" if args.by_leaf else "키 경로"
    print("\n=== 구멍(없음 + 언급만) 상위 %d — 동봉 도달 수 내림차순 · %s 단위 ==="
          % (args.top, unit))
    print("%5s %-11s %-62s %-6s %-10s %s" % ("파일", "스키마", unit, "상태", "타입", "값 예시"))
    for r in g[:args.top]:
        ty = ",".join(sorted(r["types"]))[:10]
        vals = " | ".join(r["values"])[:38]
        amb = "~" if r["leaf_ambiguous"] else " "
        cell = r["leaf"] if args.by_leaf else r["path"]
        cell = cell if len(cell) <= 62 else "…" + cell[-61:]
        print("%5d %-11s %-62s %-6s %-10s %s%s" % (r["files"], r["schema"], cell,
                                                   STATUS_KO[r["status"]], ty, amb, vals))
    print("\n구멍 총계: %d개 %s (없음 %d · 언급만 %d)"
          % (len(g), unit, sum(1 for r in g if r["status"] == "none"),
             sum(1 for r in g if r["status"] == "mention")))
    print("`~` 는 키 이름이 두 스키마 이상에 걸침 — 이 목록은 실제 구멍의 **하한**이다"
          "(docstring §3 편향 (b) 참조).")
    print("안정된 값은 **총계(없음+언급만)** 다. 그 안의 없음/언급만 경계는 문서 코퍼스에"
          " 달려 있어, 누가 리포트에 그 키를 적기만 해도 없음 → 언급만 으로 옮겨간다.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
