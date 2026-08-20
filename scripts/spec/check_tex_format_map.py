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

실행
----
    python3 scripts/spec/check_tex_format_map.py            # 검사(매번 selftest 선행)
    python3 scripts/spec/check_tex_format_map.py --selftest # 음성 대조만
"""
import collections
import json
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


def check(root, swift_path=SWIFT, texdecoder=TEXDECODER, strict_extras=True):
    """문제 목록을 돌려준다(빈 목록 = 통과). 두 번째 값은 사람이 읽을 요약."""
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
    return problems, notes


def _tree(td, fmt_json, tex_code, enum_extra=""):
    """음성 대조용 최소 트리."""
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
        (m / ("t%d.tex-json" % i)).write_text(json.dumps({"format": fmt}), encoding="utf-8")
        if code is not None:
            (m / ("t%d.tex" % i)).write_bytes(
                TEX_MAGIC + b"\0" * (FORMAT_OFFSET - 8) + struct.pack("<I", code) + b"\0" * 32)
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
    print("selftest: OK")


def main():
    if "--selftest" in sys.argv:
        selftest()
        return 0
    selftest()
    if not ASSETS.is_dir():
        print("[tex-format-map] 동봉 자산이 없다: %s" % ASSETS)
        return 1
    problems, notes = check(ASSETS)
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
