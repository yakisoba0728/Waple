#!/usr/bin/env python3
"""`TEXnFORMAT` 배선이 딛고 선 **실측 표 세 개**가 서로 어긋나지 않는지 매번 다시 잰다.

왜 있는가
---------
`common_fragment.h` 의 노멀 언팩은 텍스처 **포맷**으로 분기한다:

    #if TEX1FORMAT == FORMAT_RG88   normal.xy = normal.rg * 2 - 1
    #else                           normal.xy = normal.wy * 2 - 1

Waple 은 `TEX*FORMAT` 을 아무 데서도 정의하지 않아 전처리기가 0 을 주고 **항상 else** 를 탔다.
`effects/refraction` 의 노멀맵은 `.tex` 가 없고 소스 `refractnormal.png` 가 알파 없는 RGB 라
`normal.w` 가 1.0 상수 → `normal.x = 1`, `normal.z = 0`. 굴절 무늬의 x 가 통째로 죽는다.

고치는 배선이 **세 가지 실측**에 동시에 기대고 있다. 하나라도 조용히 어긋나면 그림이 조용히
틀린다 — 그래서 셋을 매 CI 마다 다시 재서 맞물리는지 본다:

  ① `shaders/common_fragment.h` 의 `FORMAT_*` enum      (셰이더가 비교하는 값의 정의역)
  ② 동봉 `*.tex-json`「format 문자열」↔ 짝 `*.tex` 헤더 format 필드   (실제 대응표)
  ③ `SceneRendererResources.swift` 의 `texJSONFormatCodes` 리터럴      (Waple 이 먹이는 값)

②는 **이름에서 유추하면 틀린다**. 실측이 알려준 두 가지:
  · `n` 접미(노멀맵 표기)는 코드를 바꾸지 않는다 — rgba8888n·dxt5n·rg88n 이 베이스와 같다.
  · `rgb888` 은 `FORMAT_RGB888(1)` 이 아니라 **0(RGBA8888)** 으로 컴파일된다.
이름 유추를 배반하는 집합을 아래에 **못박아** 둔다(D). 자산이 바뀌어 배반 집합이 달라지면
사람이 봐야 한다 — 조용히 정규화되면 이 표의 근거가 사라진다.

`.tex` 를 일부러 제외하는 규칙도 여기서 지킨다(E)
--------------------------------------------------
Waple 의 `TexDecoder._decodeMip` 은 GPU 네이티브 포맷을 올리지 않고 전부 CPU 에서 RGBA8 로 편다.
그때 채널 배치를 이미 WE 셰이더의 **변환 후** 모양으로 맞춘다 — r8 → (v,v,v,v), rg88 → (b0,b0,b0,b1).
그래서 컴파일된 `.tex` 에 `TEXnFORMAT` 을 심으면 셰이더가 변환을 **두 번** 걸어 알파가 죽는다.
지금의 "정의 없음 = 0" 이 그 경로에선 맞는 값이라, 배선은 **소스 폼(.tex 부재)에만** 값을 준다.
즉 이 예외의 정당성은 전적으로 디코더의 정규화 모양에 달려 있다 — 디코더가 네이티브 배치로
바뀌면 예외가 틀린 것이 되므로, 그 두 줄이 그대로인지 함께 본다.

슬롯 판정 기준도 지킨다(F)
--------------------------
처음 구현은 `samplerCombos`(`"combo"` 어노테이션)로 슬롯을 골랐고, **정작 고치려던
`refract.frag:8` 이 안 걸렸다** — 그 줄엔 `"formatcombo":true` 만 있고 `"combo"` 가 없다.
주석은 맞는 규칙을 적고 코드는 다른 규칙을 구현한, 조용히 아무것도 안 하는 수정이었다.

이 검사가 **안 보던 것들**(2026-08-21 에 메웠다)
---------------------------------------------
종전 이 파일은 `.tex-json`↔헤더 대응 중 **`format` 하나만** 봤고, 헤더는 **오프셋 18 의 u32
하나만** 읽었다. 그래서 다음이 전부 사정권 밖이었다 — 셋 다 여기서 잡는다.

  H  **헤더 프레이밍.** `format` 만 읽으면 그 뒤 필드가 다 틀려도 조용하다. 이제 NUL 구분자
     둘 · 컨테이너 버전 · `flags` · texW/H · imgW/H · **`flags & 0x40` 일 때만 있는
     `i32 texDepth`** · **TEXI 버전 > 0 일 때만 있는 `u32 previewColor`** 까지 세고,
     그 계산 위치에 `TEXB` 매직이 **정확히 착지**하는지 본다. 조건부 필드를 하나라도 잘못
     세면 착지가 깨지므로 착지 자체가 조건부 레이아웃의 검증이다(동봉 311/311).
     `flags & 0x4` ⟺ `TEXS` 섹션 존재도 여기서 본다(동봉 311/311 · 설치 projects 129/129).
  I  **`.tex-json` 키 집합.** `MIN_PAIRS`/`MIN_FORMATS` 는 **하한**이라 자산이 늘어 대응이
     깨지는 쪽만 잡고 **새 키가 생기는 것은 못 잡았다**. 이제 관측 키 경로(중첩 포함)가
     `KNOWN_TEXJSON_KEYS` 를 벗어나면 실패한다 — 새 키는 사람이 봐야 한다.
  J  **플래그 비트 게이트.** 문서에만 있고 아무 게이트도 없던 대응을 매번 다시 잰다:
     `nointerpolation`↔`0x1` · `clampuvs`↔`0x2` · `srgb`↔`0x10` ·
     `alphachannelpriority`↔`0x80000` · `spritesheetsequences`↔`0x4`.
     ⚠️ 마지막 것은 **쌍대응이 아니다** — 설치 `projects/dino_run` 3건은
     `spritesheetsequences` 없이 `imagesequence` 로 같은 비트와 TEXS 를 얻는다(실측).
     그래서 게이트의 왼쪽은 `spritesheetsequences OR imagesequence` 다.

`srgb`↔`0x10` 은 **동봉 트리에 표본이 0** 이라(동봉 272쌍 전건 `srgb` 부재) 동봉만으로는
판별력이 없다. `WE_ROOT` 를 주면 설치 `projects/` 를 붙여 10/10 · 76/76 으로 잰다 —
CI 에는 설치본이 없으므로 그때는 "표본 0" 을 **숨기지 않고 note 로 찍는다**.

실행
----
    python3 scripts/spec/check_tex_format_map.py            # 검사(매번 selftest 선행)
    python3 scripts/spec/check_tex_format_map.py --selftest # 음성 대조만
    WE_ROOT=/path/to/wallpaper_engine python3 scripts/spec/check_tex_format_map.py
                                                            # 설치 projects/ 까지 붙여서
"""
import collections
import json
import os
import re
import struct
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ASSETS = REPO / "Sources/WapleRender/Resources/WEAssets"
SWIFT = REPO / "Sources/WapleRender/SceneRendererResources.swift"
TEXDECODER = REPO / "Sources/WapleRender/TexDecoder.swift"

TEX_MAGIC = b"TEXV0005"
FORMAT_OFFSET = 18          # TexImage.parse: format = u32 LE @18

# 실측 하한 — 여기서 내려가면 표의 근거가 사라진 것이다(현재 272쌍 / 8종).
MIN_PAIRS = 250
MIN_FORMATS = 8
# 이름 유추를 배반하는 포맷(위 ② 참조). 늘어도 줄어도 사람이 봐야 한다.
NAME_INFERENCE_DEFIANT = {"rgb888"}
# 소스 폼(.tex 부재)이면서 코드가 0 이 아닌 자산 = 이 배선이 실제로 그림을 바꾸는 전부.
EXPECTED_REACH = {"effects/refraction/materials/effects/refractnormal.tex-json"}

# ── H: 헤더 프레이밍 ────────────────────────────────────────────────────────
# 동봉 트리 실측(2026-08-21): .tex 311개 · 전건 TEXB 착지 · headerLen {46: 283, 50: 28} ·
# TEXB0001 42 / 0002 29 / 0003 113 / 0004 127 · depth 32 ×28.
MIN_TEX_HEADERS = 280            # 현재 311
MIN_DEPTH_WITNESS = 20           # 현재 28 — `flags & 0x40` 조건부 필드의 **유일한** 증인이다
TEXB_KNOWN = {"TEXB0001", "TEXB0002", "TEXB0003", "TEXB0004"}

# ── I: `.tex-json` 키 집합 ─────────────────────────────────────────────────
# 동봉 14 + 설치 projects 4(srgb / spritesheet / frameduration / imagesequence).
# 여기서 벗어난 키가 나오면 컴파일러 입력이 바뀐 것이므로 사람이 봐야 한다.
EXPECTED_EMBEDDED_KEYS = {
    "format", "clampuvs", "nonpoweroftwo", "nomip", "alphachannelpriority",
    "spritesheetsequences", "spritesheetsequences.[].duration",
    "spritesheetsequences.[].frames", "spritesheetsequences.[].height",
    "spritesheetsequences.[].width", "nointerpolation", "bleedtransparentcolors",
    "halfmip", "forcerawcompression",
}
KNOWN_TEXJSON_KEYS = EXPECTED_EMBEDDED_KEYS | {
    "srgb", "spritesheet", "frameduration", "imagesequence",
}

# ── J: `.tex-json` 키 ↔ flags 비트 ─────────────────────────────────────────
# (라벨, 비트, 왼쪽을 참으로 만드는 키들). 왼쪽이 참 ⟺ 비트가 섬.
FLAG_GATES = (
    ("nointerpolation", 0x1, ("nointerpolation",)),
    ("clampuvs", 0x2, ("clampuvs",)),
    ("spritesheetsequences|imagesequence", 0x4, ("spritesheetsequences", "imagesequence")),
    ("srgb", 0x10, ("srgb",)),
    ("alphachannelpriority", 0x80000, ("alphachannelpriority",)),
)
# 동봉 트리에서 실제로 **참인 쪽** 표본이 이만큼은 있어야 게이트에 판별력이 있다.
# 현재 동봉 실측: nointerpolation 1 · clampuvs 182 · sprite 52 · alphachannelpriority 82 ·
# srgb **0**(그래서 하한이 없다 — 위 모듈 주석 참조).
MIN_GATE_POSITIVES = {"nointerpolation": 1, "clampuvs": 150,
                      "spritesheetsequences|imagesequence": 40,
                      "alphachannelpriority": 60}

_DEFINE = re.compile(r"^#define\s+FORMAT_([A-Z0-9_]+)\s+(\d+)\s*$", re.M)
_SWIFT_TABLE = re.compile(
    r"texJSONFormatCodes\s*:\s*\[String\s*:\s*Int\]\s*=\s*\[(.*?)\]", re.S)
_SWIFT_ENTRY = re.compile(r'"([a-z0-9_]+)"\s*:\s*(\d+)')


def format_enum(root):
    """① 셰이더가 비교하는 `FORMAT_*` 정의역 → {이름: 값}."""
    h = root / "shaders/common_fragment.h"
    if not h.is_file():
        return None
    return {n: int(v) for n, v in _DEFINE.findall(h.read_text(encoding="utf-8", errors="replace"))}


def measure_pairs(root):
    """② `*.tex-json` 의 format 문자열 → 짝 `*.tex` 헤더 코드. {fmt: Counter(code)}, 무짝 수, 이상."""
    pairs, unpaired, broken = collections.defaultdict(collections.Counter), collections.Counter(), []
    for j in sorted(root.rglob("*.tex-json")):
        rel = j.relative_to(root).as_posix()
        try:
            doc = json.loads(j.read_text(encoding="utf-8", errors="replace"))
        except (json.JSONDecodeError, OSError) as e:
            broken.append((rel, "tex-json 파스 실패: %s" % e))
            continue
        fmt = doc.get("format") if isinstance(doc, dict) else None
        if not isinstance(fmt, str) or not fmt:
            continue
        fmt = fmt.lower()
        tex = Path(str(j)[: -len(".tex-json")] + ".tex")
        if not tex.is_file():
            unpaired[fmt] += 1
            continue
        raw = tex.read_bytes()
        if len(raw) < FORMAT_OFFSET + 4 or not raw.startswith(TEX_MAGIC):
            broken.append((tex.relative_to(root).as_posix(), "매직이 %r" % raw[:8]))
            continue
        pairs[fmt][struct.unpack_from("<I", raw, FORMAT_OFFSET)[0]] += 1
    return pairs, unpaired, broken


def parse_texi(raw):
    """TEXI 헤더를 **조건부 필드까지** 읽는다. (필드dict, None) 또는 (None, 사유).

    종전 검사는 `FORMAT_OFFSET` 의 u32 하나만 읽었다. 그 한 필드는 뒤 필드가 전부 어긋나도
    맞을 수 있다 — 조건부 필드(`texDepth`/`previewColor`)를 잘못 세는 오류를 하나도 못 잡는다.
    여기서는 끝까지 세고 그 자리에 `TEXB` 매직이 오는지 본다. **착지가 곧 검증이다.**

        "TEXV0005" | u8 0 | "TEXI000N" | u8 0
        | i32 format | i32 flags | i32 texW | i32 texH | i32 imgW | i32 imgH
        | [flags & 0x40: i32 texDepth] | [TEXI 버전 > 0: u32 previewColor]
        | "TEXB000N" | u8 0 | …
    """
    if not raw.startswith(TEX_MAGIC):
        return None, "매직이 %r" % raw[:8]
    if len(raw) <= 17 or raw[8] != 0 or raw[17] != 0:
        return None, "헤더 NUL 구분자가 없다(%r)" % raw[:18]
    if raw[9:13] != b"TEXI":
        return None, "TEXI 매직이 아니다(%r)" % raw[9:17]
    try:
        ver = int(raw[13:17])
        fmt, flags, texw, texh, imgw, imgh = struct.unpack_from("<6i", raw, FORMAT_OFFSET)
        p = FORMAT_OFFSET + 24
        depth = None
        if flags & 0x40:
            depth = struct.unpack_from("<i", raw, p)[0]
            p += 4
        preview = None
        if ver > 0:
            preview = struct.unpack_from("<I", raw, p)[0]
            p += 4
    except (ValueError, struct.error) as e:
        return None, "헤더 파스 실패: %s" % e
    if raw[p:p + 4] != b"TEXB" or len(raw) <= p + 8 or raw[p + 8] != 0:
        return None, "조건부 필드까지 세면 TEXB 가 오프셋 %d 여야 하는데 %r 이다" % (p, raw[p:p + 9])
    return dict(texiVersion=ver, format=fmt, flags=flags, texW=texw, texH=texh,
                imgW=imgw, imgH=imgh, depth=depth, previewColor=preview, headerLen=p,
                texb=raw[p:p + 8].decode("ascii", "replace"),
                hasTexs=raw.find(b"TEXS", p) >= 0), None


def measure_headers(roots):
    """H: 트리의 `.tex` 전건을 조건부 필드까지 파스한다. (요약, 문제후보 목록)."""
    got = dict(total=0, landed=0, headerLens=collections.Counter(),
               texb=collections.Counter(), texiVersion=collections.Counter(),
               depth=collections.Counter(), flagBits=collections.Counter(),
               spriteVsTexs=collections.Counter())
    broken = []
    for root in roots:
        root = Path(root)
        for t in sorted(root.rglob("*.tex")):
            got["total"] += 1
            h, why = parse_texi(t.read_bytes())
            if h is None:
                broken.append((_rel(t, root), why))
                continue
            got["landed"] += 1
            got["headerLens"][h["headerLen"]] += 1
            got["texb"][h["texb"]] += 1
            got["texiVersion"][h["texiVersion"]] += 1
            if h["depth"] is not None:
                got["depth"][h["depth"]] += 1
            for i in range(32):
                if h["flags"] & (1 << i):
                    got["flagBits"][i] += 1
            got["spriteVsTexs"][(bool(h["flags"] & 0x4), h["hasTexs"])] += 1
    return got, broken


def _rel(p, root):
    try:
        return p.relative_to(root).as_posix()
    except ValueError:
        return str(p)


def key_paths(doc, pre=""):
    """`.tex-json` 이 실제로 쓰는 키 경로(중첩 포함). 리스트는 `[].` 로 접는다."""
    if isinstance(doc, dict):
        for k, v in doc.items():
            yield pre + k
            yield from key_paths(v, pre + k + ".")
    elif isinstance(doc, list):
        for v in doc:
            yield from key_paths(v, pre + "[].")


def measure_sidecars(roots):
    """I·J: `.tex-json` 키 경로 도수와 키↔flags 비트 대응. (키도수, 게이트, 짝수, 문제후보)."""
    keys = collections.Counter()
    gates = {label: collections.Counter() for label, _, _ in FLAG_GATES}
    pairs = 0
    broken = []
    for root in roots:
        root = Path(root)
        for j in sorted(root.rglob("*.tex-json")):
            try:
                doc = json.loads(j.read_text(encoding="utf-8-sig", errors="replace"))
            except (json.JSONDecodeError, OSError) as e:
                broken.append((_rel(j, root), "tex-json 파스 실패: %s" % e))
                continue
            if not isinstance(doc, dict):
                broken.append((_rel(j, root), "tex-json 최상위가 객체가 아니다"))
                continue
            for k in key_paths(doc):
                keys[k] += 1
            t = Path(str(j)[: -len(".tex-json")] + ".tex")
            if not t.is_file():
                continue
            h, why = parse_texi(t.read_bytes())
            if h is None:
                continue                    # 헤더 자체의 문제는 H 가 이미 보고한다
            pairs += 1
            for label, bit, names in FLAG_GATES:
                want = any(bool(doc.get(n)) for n in names)
                gates[label][(want, bool(h["flags"] & bit))] += 1
    return keys, gates, pairs, broken


def swift_table(path):
    """③ Swift 리터럴 → {fmt: code}. 못 찾으면 None."""
    if not path.is_file():
        return None
    m = _SWIFT_TABLE.search(path.read_text(encoding="utf-8", errors="replace"))
    if not m:
        return None
    return {k: int(v) for k, v in _SWIFT_ENTRY.findall(m.group(1))}


def name_inferred(fmt, enum):
    """이름 기반 유추: `rg88n` → FORMAT_RG88. 못 찾으면 None."""
    for cand in (fmt, fmt[:-1] if fmt.endswith("n") else fmt):
        v = enum.get(cand.upper())
        if v is not None:
            return v
    return None


def format_combo_samplers(root):
    """F: `"formatcombo"` 만 있고 `"combo"` 는 없는 샘플러 선언 목록 [(rel, slot)]."""
    only = []
    for p in sorted(root.rglob("*")):
        if p.suffix not in (".frag", ".vert", ".h") or not p.is_file():
            continue
        for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
            i = line.find("//")
            if i < 0:
                continue
            code, comment = line[:i], line[i:]
            if "sampler2D" not in code or "formatcombo" not in comment:
                continue
            m = re.search(r"g_Texture(\d+)", code)
            if m and '"combo"' not in comment:
                only.append((p.relative_to(root).as_posix(), int(m.group(1))))
    return only


def reach(root, table):
    """G: 소스 폼(.tex 부재)이면서 코드 != 0 인 `.tex-json` — 배선이 실제로 그림을 바꾸는 전부."""
    out = set()
    for j in sorted(root.rglob("*.tex-json")):
        if Path(str(j)[: -len(".tex-json")] + ".tex").is_file():
            continue
        try:
            doc = json.loads(j.read_text(encoding="utf-8", errors="replace"))
        except (json.JSONDecodeError, OSError):
            continue
        fmt = doc.get("format") if isinstance(doc, dict) else None
        if isinstance(fmt, str) and table.get(fmt.lower(), 0) != 0:
            out.add(j.relative_to(root).as_posix())
    return out


def check(root, swift_path=SWIFT, texdecoder=TEXDECODER, strict_extras=True, extra_roots=()):
    """문제 목록을 돌려준다(빈 목록 = 통과). 두 번째 값은 사람이 읽을 요약.

    `extra_roots` 는 H/I/J(헤더 프레이밍 · 키 집합 · 플래그 게이트)에만 더해진다.
    ②③(format 대응)과 D/E/F/G 는 **동봉 트리 전용**이다 — 그 셋은 동봉 자산에 배선된
    Swift 표를 대조하는 것이라, 설치본을 섞으면 대조 대상이 아닌 값이 들어온다.
    """
    problems, notes = [], []

    enum = format_enum(root)
    if not enum:
        return ["① `shaders/common_fragment.h` 의 FORMAT_* enum 을 못 찾았다"], notes
    if len(enum) < 10:
        problems.append("① FORMAT_* 가 %d종뿐 — enum 이 잘렸다" % len(enum))
    codomain = set(enum.values())

    pairs, unpaired, broken = measure_pairs(root)
    for rel, why in broken:
        problems.append("② %s — %s" % (rel, why))
    total = sum(sum(c.values()) for c in pairs.values())
    notes.append("② 짝 %d쌍 · 포맷 %d종 · 무짝 %d건" % (total, len(pairs), sum(unpaired.values())))
    if total < MIN_PAIRS:
        problems.append("② 짝이 %d쌍뿐 — 하한 %d" % (total, MIN_PAIRS))
    if len(pairs) < MIN_FORMATS:
        problems.append("② 포맷이 %d종뿐 — 하한 %d" % (len(pairs), MIN_FORMATS))

    measured = {}
    for fmt, counter in sorted(pairs.items()):
        if len(counter) > 1:
            problems.append("② `%s` 가 코드 %s 로 갈린다 — 대응이 함수가 아니다"
                            % (fmt, dict(counter)))
            continue
        code = next(iter(counter))
        measured[fmt] = code
        if code not in codomain:
            problems.append("②→① `%s`→%d 인데 그 값이 FORMAT_* 에 없다" % (fmt, code))

    table = swift_table(swift_path)
    if table is None:
        problems.append("③ `texJSONFormatCodes` 리터럴을 못 찾았다: %s" % swift_path)
        table = {}
    for fmt, code in sorted(measured.items()):
        if fmt not in table:
            problems.append("③ 실측 `%s`→%d 가 Swift 표에 없다" % (fmt, code))
        elif table[fmt] != code:
            problems.append("③ `%s`: 실측 %d ≠ Swift %d" % (fmt, code, table[fmt]))
    if strict_extras:
        for fmt in sorted(set(table) - set(measured)):
            problems.append("③ Swift 표의 `%s`→%d 는 **실측 근거가 없다**"
                            % (fmt, table[fmt]))

    # D: 이름 유추를 배반하는 집합이 그대로인가.
    defiant = {f for f, c in measured.items()
               if (v := name_inferred(f, enum)) is not None and v != c}
    notes.append("D 이름유추 배반 %s" % (sorted(defiant) or "없음"))
    if defiant != NAME_INFERENCE_DEFIANT:
        problems.append("D 배반 집합이 %s → %s 로 바뀌었다 — 표의 근거를 다시 봐야 한다"
                        % (sorted(NAME_INFERENCE_DEFIANT), sorted(defiant)))

    # E: `.tex` 제외 규칙의 근거 = 디코더의 정규화 모양.
    if texdecoder is not None:
        src = texdecoder.read_text(encoding="utf-8", errors="replace") if texdecoder.is_file() else ""
        for want, why in (
            ("d[i * 4] = v; d[i * 4 + 1] = v; d[i * 4 + 2] = v; d[i * 4 + 3] = v",
             "r8 → (v,v,v,v)"),
            ("d[i * 4] = r; d[i * 4 + 1] = r; d[i * 4 + 2] = r; d[i * 4 + 3] = g",
             "rg88 → (b0,b0,b0,b1)"),
        ):
            if want not in src:
                problems.append("E 디코더의 %s 정규화가 사라졌다 — `.tex` 제외 규칙의 근거가"
                                " 없어졌으니 배선을 다시 봐야 한다" % why)

    # F: 슬롯 판정이 `formatcombo` 기준인가.
    only = format_combo_samplers(root)
    notes.append("F formatcombo 단독 샘플러 %d건" % len(only))
    if not only:
        problems.append("F `formatcombo` 단독 샘플러가 0건 — 그렇다면 formatComboSlots 가 왜"
                        " 필요한지 근거가 사라진다")
    if swift_path.is_file():
        s = swift_path.read_text(encoding="utf-8", errors="replace")
        if "TEX\\(slot)FORMAT" in s and "formatComboSlots" not in s:
            problems.append("F `TEXnFORMAT` 을 심는데 `formatComboSlots` 를 안 쓴다 —"
                            " `samplerCombos` 로는 refract.frag:8 이 안 걸린다")

    # G: 실제 도달 집합.
    got = reach(root, measured)
    notes.append("G 도달(소스 폼 & 코드≠0) %s" % (sorted(got) or "없음"))
    if strict_extras and got != EXPECTED_REACH:
        problems.append("G 도달 집합이 %s → %s 로 바뀌었다 — 그림이 바뀌는 자산이 달라졌다"
                        % (sorted(EXPECTED_REACH), sorted(got)))

    roots = (root,) + tuple(extra_roots)

    # H: 헤더 프레이밍 — 조건부 필드까지 세고 TEXB 착지를 본다.
    hdr, hdr_broken = measure_headers(roots)
    for rel, why in hdr_broken:
        problems.append("H %s — %s" % (rel, why))
    notes.append("H .tex %d개 중 TEXB 착지 %d · headerLen %s · TEXB %s · depth %s · flags비트 %s"
                 % (hdr["total"], hdr["landed"], dict(sorted(hdr["headerLens"].items())),
                    dict(sorted(hdr["texb"].items())), dict(sorted(hdr["depth"].items())),
                    dict(sorted(hdr["flagBits"].items()))))
    if strict_extras and hdr["total"] < MIN_TEX_HEADERS:
        problems.append("H .tex 가 %d개뿐 — 하한 %d" % (hdr["total"], MIN_TEX_HEADERS))
    if strict_extras and hdr["headerLens"].get(FORMAT_OFFSET + 24 + 8, 0) < MIN_DEPTH_WITNESS:
        problems.append("H headerLen %d(= flags&0x40 조건부 texDepth 가 있는 모양) 표본이 %d개뿐"
                        " — 하한 %d. 이 표본이 없으면 조건부 필드가 아무 데서도 안 밟힌다"
                        % (FORMAT_OFFSET + 24 + 8,
                           hdr["headerLens"].get(FORMAT_OFFSET + 24 + 8, 0), MIN_DEPTH_WITNESS))
    unknown_texb = sorted(set(hdr["texb"]) - TEXB_KNOWN)
    if unknown_texb:
        problems.append("H 모르는 TEXB 버전 %s — 컨테이너 레이아웃 분기를 다시 봐야 한다"
                        % unknown_texb)
    for (sprite, texs), n in sorted(hdr["spriteVsTexs"].items()):
        if sprite != texs:
            problems.append("H `flags & 0x4`=%s 인데 TEXS 섹션 존재=%s 인 파일이 %d개 —"
                            " 스프라이트 비트와 TEXS 섹션의 대응이 깨졌다" % (sprite, texs, n))

    # I: `.tex-json` 키 집합. 하한(MIN_PAIRS)은 **새 키가 생기는 것**을 못 잡는다.
    keys, gates, gpairs, side_broken = measure_sidecars(roots)
    for rel, why in side_broken:
        problems.append("I %s — %s" % (rel, why))
    unknown_keys = sorted(set(keys) - KNOWN_TEXJSON_KEYS)
    notes.append("I `.tex-json` 키 %d종 · 게이트 짝 %d쌍 · 미등록 키 %s"
                 % (len(keys), gpairs, unknown_keys or "없음"))
    if unknown_keys:
        problems.append("I 등록되지 않은 `.tex-json` 키 %s — 컴파일러 입력이 바뀌었다."
                        " 헤더에 무슨 영향을 주는지 재보고 KNOWN_TEXJSON_KEYS 를 갱신하라"
                        % unknown_keys)
    if strict_extras:
        missing = sorted(EXPECTED_EMBEDDED_KEYS - set(key_paths_of(root)))
        if missing:
            problems.append("I 동봉 트리에서 키 %s 가 사라졌다 — 근거가 줄었다" % missing)

    # J: 키 ↔ flags 비트. 문서에만 있던 대응을 매번 다시 잰다.
    for label, bit, _names in FLAG_GATES:
        c = gates[label]
        pos, neg = c.get((True, True), 0), c.get((False, False), 0)
        miss = {"키만 참": c.get((True, False), 0), "비트만 참": c.get((False, True), 0)}
        notes.append("J `%s` ↔ 0x%x — 둘다참 %d · 둘다거짓 %d · 어긋남 %s"
                     % (label, bit, pos, neg, miss))
        if sum(miss.values()):
            problems.append("J `%s` ↔ 0x%x 대응이 %s 로 깨졌다 — 문서(docs/re/tex-format.md §3)의"
                            " 근거가 사라진다" % (label, bit, miss))
        need = MIN_GATE_POSITIVES.get(label, 0)
        if strict_extras and pos < need:
            problems.append("J `%s` 가 참인 표본이 %d개뿐 — 하한 %d. 표본이 없으면 이 게이트에"
                            " 판별력이 없다" % (label, pos, need))
    if not gates["srgb"].get((True, True), 0):
        notes.append("J `srgb`↔0x10 은 참 표본 0 — 동봉 트리에는 `srgb` 를 쓰는 사이드카가 없다."
                     " 판별력을 얻으려면 `WE_ROOT` 로 설치 `projects/` 를 붙여라(실측 10/10)")
    return problems, notes


def key_paths_of(root):
    """한 트리의 `.tex-json` 키 경로 집합(I 의 '사라짐' 방향 전용)."""
    out = set()
    for j in sorted(Path(root).rglob("*.tex-json")):
        try:
            doc = json.loads(j.read_text(encoding="utf-8-sig", errors="replace"))
        except (json.JSONDecodeError, OSError):
            continue
        if isinstance(doc, dict):
            out.update(key_paths(doc))
    return out


def _tex(code, flags=0, depth=None, texb=b"TEXB0003", texi=b"TEXI0001", texs=False,
         preview=0xFF000000):
    """음성 대조용 `.tex` 바이트 — 조건부 필드까지 진짜 레이아웃대로 만든다.

    `depth=None` 이면서 `flags & 0x40` 이면 **일부러 어긋난** 파일이 된다(H 음성 대조).
    """
    b = bytearray(TEX_MAGIC + b"\0" + texi + b"\0")
    b += struct.pack("<6i", code, flags, 64, 64, 64, 64)
    if depth is not None:
        b += struct.pack("<i", depth)
    if int(texi[4:]) > 0 and preview is not None:
        b += struct.pack("<I", preview)      # preview=None 이면 **일부러 빼먹는다**(H 음성 대조)
    b += texb + b"\0"
    b += struct.pack("<i", 1) + b"\0" * 24        # imageCount + 더미 페이로드
    if texs:
        b += b"TEXS0003\0" + struct.pack("<i", 1) + b"\0" * 40
    return bytes(b)


def _tree(td, fmt_json, tex_code, enum_extra="", sidecars=None, tex_kw=None):
    """음성 대조용 최소 트리. `sidecars`/`tex_kw` 는 인덱스별 추가 키/헤더 인자."""
    root = Path(td)
    (root / "shaders").mkdir(parents=True)
    (root / "shaders/common_fragment.h").write_text(
        "#define FORMAT_RGBA8888 0\n#define FORMAT_DXT5 4\n#define FORMAT_RG88 8\n"
        "#define FORMAT_R8 9\n#define FORMAT_RGB888 1\n#define FORMAT_RGB565 2\n"
        "#define FORMAT_ETC1_RGB8 3\n#define FORMAT_ETC2_RGBA8 5\n#define FORMAT_DXT3 6\n"
        "#define FORMAT_DXT1 7\n" + enum_extra, encoding="utf-8")
    m = root / "materials"
    m.mkdir()
    for i, (fmt, code) in enumerate(zip(fmt_json, tex_code)):
        doc = {"format": fmt}
        doc.update((sidecars or {}).get(i, {}))
        (m / ("t%d.tex-json" % i)).write_text(json.dumps(doc), encoding="utf-8")
        if code is not None:
            (m / ("t%d.tex" % i)).write_bytes(_tex(code, **(tex_kw or {}).get(i, {})))
    (root / "shaders/x.frag").write_text(
        'uniform sampler2D g_Texture1; // {"formatcombo":true}\n', encoding="utf-8")
    return root


def _swift(td, table):
    Path(td).mkdir(parents=True, exist_ok=True)
    p = Path(td) / "S.swift"
    body = ", ".join('"%s": %d' % kv for kv in sorted(table.items()))
    p.write_text("    private static let texJSONFormatCodes: [String: Int] = [%s]\n"
                 '        combos["TEX\\(slot)FORMAT"] = GLSLTranslator.formatComboSlots(frag)\n'
                 % body, encoding="utf-8")
    return p


def selftest():
    ok = {"rgba8888": 0, "rg88": 8, "r8": 9, "dxt5": 4}
    with tempfile.TemporaryDirectory() as td:
        root = _tree(td, list(ok), list(ok.values()))
        sw = _swift(td, ok)
        # 기준 픽스처는 통과해야 한다(하한/배반/도달 검사는 꺼서 최소 트리로 본다).
        probs, _ = check(root, swift_path=sw, texdecoder=None, strict_extras=False)
        probs = [p for p in probs if not p.startswith(("② 짝", "② 포맷", "D "))]
        assert not probs, "정상 픽스처가 걸렸다: %r" % probs

        # ① 갈라지는 대응 — 같은 문자열이 두 코드로.
        root2 = _tree(td + "/a", ["rg88", "rg88"], [8, 9])
        probs, _ = check(root2, swift_path=_swift(td + "/a", {"rg88": 8}),
                         texdecoder=None, strict_extras=False)
        assert any("함수가 아니다" in p for p in probs), probs

        # ② 정의역 밖 코드.
        root3 = _tree(td + "/b", ["rg88"], [99])
        probs, _ = check(root3, swift_path=_swift(td + "/b", {"rg88": 99}),
                         texdecoder=None, strict_extras=False)
        assert any("FORMAT_* 에 없다" in p for p in probs), probs

        # ③ Swift 가 실측과 다른 값.
        root4 = _tree(td + "/c", ["rg88"], [8])
        probs, _ = check(root4, swift_path=_swift(td + "/c", {"rg88": 4}),
                         texdecoder=None, strict_extras=False)
        assert any("실측 8 ≠ Swift 4" in p for p in probs), probs

        # ③ Swift 에만 있는 근거 없는 항목.
        probs, _ = check(root4, swift_path=_swift(td + "/c2", {"rg88": 8, "bc7": 12}),
                         texdecoder=None, strict_extras=True)
        assert any("실측 근거가 없다" in p for p in probs), probs

        # ③ 실측에 있는데 Swift 에 없음.
        probs, _ = check(root4, swift_path=_swift(td + "/c3", {}),
                         texdecoder=None, strict_extras=False)
        assert any("Swift 표에 없다" in p for p in probs), probs

        # E 디코더 정규화가 사라지면 잡히는가.
        gone = Path(td) / "TexDecoderGone.swift"
        gone.write_text("// 네이티브 배치로 바꿨다\n", encoding="utf-8")
        probs, _ = check(root4, swift_path=_swift(td + "/c", {"rg88": 8}),
                         texdecoder=gone, strict_extras=False)
        assert sum("E 디코더" in p for p in probs) == 2, probs

        # F `formatcombo` 단독이 하나도 없으면 잡히는가.
        (root4 / "shaders/x.frag").write_text(
            'uniform sampler2D g_Texture1; // {"formatcombo":true,"combo":"N"}\n', encoding="utf-8")
        probs, _ = check(root4, swift_path=_swift(td + "/c", {"rg88": 8}),
                         texdecoder=None, strict_extras=False)
        assert any(p.startswith("F `formatcombo` 단독") for p in probs), probs

        # F `samplerCombos` 로 되돌리면 잡히는가.
        bad = Path(td) / "Bad.swift"
        bad.write_text('    private static let texJSONFormatCodes: [String: Int] = ["rg88": 8]\n'
                       '        combos["TEX\\(slot)FORMAT"] = GLSLTranslator.samplerCombos(frag)\n',
                       encoding="utf-8")
        probs, _ = check(root4, swift_path=bad, texdecoder=None, strict_extras=False)
        assert any("refract.frag:8 이 안 걸린다" in p for p in probs), probs

        # ── H/I/J 음성 대조 ────────────────────────────────────────────────
        # 게이트를 넓혔으니 넓힌 만큼 음성 대조를 붙인다. 양성 대조 없는 게이트는
        # "동작하는 척하는 도구" 다 — 이 리포가 실제로 여러 번 당한 실패 양식이다.
        def probe(tag, **kw):
            r = _tree(td + "/" + tag, ["rg88"], [8], **kw)
            p, _ = check(r, swift_path=_swift(td + "/" + tag, {"rg88": 8}),
                         texdecoder=None, strict_extras=False)
            return p

        # H1 조건부 `texDepth` 를 안 세면 TEXB 착지가 깨진다.
        assert any("TEXB 가 오프셋" in p for p in probe("h1", tex_kw={0: {"flags": 0x40}})), \
            "H1: flags&0x40 인데 depth 없는 파일을 못 잡았다"
        # H1b 반대로, depth 를 제대로 세면 통과해야 한다(오탐 방지).
        assert not [p for p in probe("h1b", tex_kw={0: {"flags": 0x40, "depth": 32}})
                    if p.startswith("H ")], "H1b: 정상 slice3d 헤더가 걸렸다"
        # H2 previewColor 를 빼먹으면(=TEXI 버전만 0 으로 위장) 착지가 깨진다.
        assert any("TEXB 가 오프셋" in p for p in probe(
            "h2", tex_kw={0: {"texi": b"TEXI0001", "preview": None}})), \
            "H2: previewColor 누락을 못 잡았다"
        # H3 모르는 TEXB 버전.
        assert any("모르는 TEXB 버전" in p for p in probe(
            "h3", tex_kw={0: {"texb": b"TEXB0009"}})), "H3: 미지 TEXB 버전을 못 잡았다"
        # H4 `flags & 0x4` 인데 TEXS 섹션이 없다.
        assert any("TEXS 섹션 존재" in p for p in probe(
            "h4", sidecars={0: {"spritesheetsequences": [{"frames": 2}]}},
            tex_kw={0: {"flags": 0x4}})), "H4: 0x4 ⟺ TEXS 위반을 못 잡았다"
        # I 등록되지 않은 `.tex-json` 키.
        assert any("등록되지 않은" in p for p in probe(
            "i1", sidecars={0: {"brandnewkey": True}})), "I: 새 키를 못 잡았다"
        # I 중첩 키도 본다.
        assert any("brandnewkey" in p for p in probe(
            "i2", sidecars={0: {"spritesheetsequences": [{"brandnewkey": 1}]}},
            tex_kw={0: {"flags": 0x4, "texs": True}})), "I: 중첩된 새 키를 못 잡았다"
        # J 키는 참인데 비트가 안 섰다.
        assert any("`clampuvs` ↔ 0x2" in p for p in probe(
            "j1", sidecars={0: {"clampuvs": True}})), "J: 키만 참인 경우를 못 잡았다"
        # J 비트는 섰는데 키가 없다.
        assert any("`nointerpolation` ↔ 0x1" in p for p in probe(
            "j2", tex_kw={0: {"flags": 0x1}})), "J: 비트만 참인 경우를 못 잡았다"
        # J srgb ↔ 0x10 도 같은 규칙으로 걸린다(동봉 트리엔 표본이 0인 게이트).
        assert any("`srgb` ↔ 0x10" in p for p in probe(
            "j3", sidecars={0: {"srgb": True}})), "J: srgb 게이트가 죽어 있다"
        # J `imagesequence` 도 0x4 를 세운다 — 왼쪽이 OR 가 아니면 여기서 오탐이 난다.
        assert not [p for p in probe("j4", sidecars={0: {"imagesequence": ["a.png", "b.png"]}},
                                     tex_kw={0: {"flags": 0x4, "texs": True}})
                    if p.startswith("J ")], "J: imagesequence 경로가 오탐을 낸다"
        # J 정상 쌍(키 참 + 비트 참)은 통과해야 한다.
        assert not [p for p in probe("j5", sidecars={0: {"clampuvs": True}},
                                     tex_kw={0: {"flags": 0x2}}) if p.startswith("J ")], \
            "J: 정상 대응이 걸렸다"
    print("selftest: OK")


def main():
    if "--selftest" in sys.argv:
        selftest()
        return 0
    selftest()
    if not ASSETS.is_dir():
        print("[tex-format-map] 동봉 자산이 없다: %s" % ASSETS)
        return 1
    # 설치본이 붙어 있으면 `projects/` 도 H/I/J 에 넣는다. **없으면 조용히 건너뛴다** —
    # CI 에는 설치본이 없고, 없다는 이유로 붉게 만들면 게이트가 무의미해진다. 대신 붙었는지
    # 아닌지를 note 로 반드시 찍어서 "무엇을 안 봤는지" 를 숨기지 않는다.
    extra = []
    we_root = os.environ.get("WE_ROOT")
    if we_root and (Path(we_root) / "projects").is_dir():
        extra.append(Path(we_root) / "projects")
    problems, notes = check(ASSETS, extra_roots=extra)
    notes.insert(0, "범위: 동봉 %s%s" % (
        ASSETS.relative_to(REPO),
        " + 설치 " + str(extra[0]) if extra else
        " (설치 projects/ **미부착** — WE_ROOT 를 주면 srgb↔0x10 게이트가 살아난다)"))
    for n in notes:
        print("[tex-format-map] " + n)
    if problems:
        print("\n[tex-format-map] 어긋남 %d건" % len(problems))
        for p in problems:
            print("  · " + p)
        return 1
    print("[tex-format-map] ①②③ 정합 · D 배반집합 고정 · E 디코더 근거 유지 · F 슬롯기준 유지 · G 도달 고정")
    return 0


if __name__ == "__main__":
    sys.exit(main())
