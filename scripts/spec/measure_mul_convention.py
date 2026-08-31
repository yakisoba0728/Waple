"""WE 셰이더 방언의 `mul(a,b)` 인자 규약 판별 → spec/engine/mul-convention.json.

WE 셰이더는 GLSL 문법으로 저작되지만 HLSL 네이티브 이름 `mul` 을 쓴다. HLSL 은
`m[행][열]`, GLSL/MSL 은 `m[열][행]` 이라 **같은 소스 대입문이 만드는
행렬은 서로 전치**이고, 그래서 HLSL `mul(v,M)`(행벡터) 과 등가인 GLSL/MSL 식은 `M*v` 다.

이 스크립트는 그 규약을 **판별식으로 측정한다** — 문헌 인용이 아니라 계산이다:
`common_perspective.h` 의 `squareToQuad` 는 정의상 단위정사각형 코너를 (p0,p1,p2,p3) 로 보내야
한다. 두 곱셈 순서로 각각 코너를 통과시켜, 어느 쪽이 그 계약을 만족하는지 본다.

점열은 `lightshafts.vert` 의 어노테이션 기본값을 원문에서 파싱해 쓴다(하드코딩 아님).
두 파일 모두 리포 동봉본이라 WE 설치 없이 재현된다.

코퍼스가 있으면(`WAPLE_REAL_PKGS`, 기본 ~/Downloads/wallpaper_dev/backgrounds) 도달도 함께 잰다:
  · DIRECTDRAW lightshafts 패스/씬 census
  · 두 규약 각각에서 프래그먼트 `mask` 가 화면 전역 0(= fx≡0, 소등) 이 되는 패스 수
  · 엔진 공급 행렬이 **아닌** 피연산자로 `mul` 을 부르는 셰이더를 가진 씬 수(변경 폭)
코퍼스가 없으면 그 항목만 빠진다 — 셰이더 사실(규약 판별)은 코퍼스와 무관하게 재현된다.

재현: python3 scripts/spec/measure_mul_convention.py   (git status 가 비어야 정상)
"""
import hashlib
import json
import math
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WEASSETS = os.path.join(REPO, "Sources", "WapleRender", "Resources", "WEAssets")
PERSPECTIVE_H = os.path.join(WEASSETS, "shaders", "common_perspective.h")
LIGHTSHAFTS_VERT = os.path.join(WEASSETS, "effects", "lightshafts", "shaders", "effects", "lightshafts.vert")
LIGHTSHAFTS_FRAG = os.path.join(WEASSETS, "effects", "lightshafts", "shaders", "effects", "lightshafts.frag")
TRANSLATOR = os.path.join(REPO, "Sources", "WapleCore", "GLSLTranslator.swift")
OUT = os.path.join(REPO, "spec", "engine", "mul-convention.json")

CORPUS = os.environ.get("WAPLE_REAL_PKGS", os.path.expanduser("~/Downloads/wallpaper_dev/backgrounds"))

# 엔진이 유니폼으로 올리는 행렬 — 업로드 측에서 전치할 수 있으므로 규약 판별의 증거가 되지 못한다.
ENGINE_MATRIX = re.compile(r"^\s*g_[A-Za-z0-9_]*(Matrix|MatrixInverse)[A-Za-z0-9_]*\s*$")


# ─── 셰이더 사실 ──────────────────────────────────────────────────────────────

def sha16(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()[:16]


def annotation_defaults(src, names):
    """`uniform vec2 g_PointN; // {"material":"pointN","default":"x y"}` 의 기본값."""
    out = {}
    for n in names:
        m = re.search(r'uniform\s+vec2\s+' + re.escape(n) + r'\s*;\s*//\s*(\{.*?\})\s*$',
                      src, re.M)
        if not m:
            raise SystemExit(f"{n} 어노테이션을 찾지 못했다 — 셰이더 원문이 바뀌었다")
        j = json.loads(m.group(1))
        out[n] = tuple(float(x) for x in j["default"].split())
    return out


def square_to_quad(p0, p1, p2, p3):
    """common_perspective.h 그대로. 반환은 GLSL 관례의 m[열][행]."""
    dx0, dy0 = p0
    dx1, dy1 = p1
    dx2, dy2 = p3          # WE 는 여기서 p3/p2 를 맞바꾼다
    dx3, dy3 = p2
    diffx1, diffy1 = dx1 - dx3, dy1 - dy3
    diffx2, diffy2 = dx2 - dx3, dy2 - dy3
    det = diffx1 * diffy2 - diffx2 * diffy1
    sumx = dx0 - dx1 + dx3 - dx2
    sumy = dy0 - dy1 + dy3 - dy2
    if det == 0.0 or (sumx == 0.0 and sumy == 0.0):
        return ([[dx1 - dx0, dy1 - dy0, 0.0],
                 [dx3 - dx1, dy3 - dy1, 0.0],
                 [dx0, dy0, 1.0]], True)
    ovdet = 1.0 / det
    g = (sumx * diffy2 - diffx2 * sumy) * ovdet
    h = (diffx1 * sumy - sumx * diffy1) * ovdet
    return ([[dx1 - dx0 + g * dx1, dy1 - dy0 + g * dy1, g],
             [dx2 - dx0 + h * dx2, dy2 - dy0 + h * dy2, h],
             [dx0, dy0, 1.0]], False)


def inverse3(m):
    a00, a01, a02 = m[0]
    a10, a11, a12 = m[1]
    a20, a21, a22 = m[2]
    b01 = a22 * a11 - a12 * a21
    b11 = -a22 * a10 + a12 * a20
    b21 = a21 * a10 - a11 * a20
    det = a00 * b01 + a01 * b11 + a02 * b21
    if det == 0:
        return None
    cols = [[b01, -a22 * a01 + a02 * a21, a12 * a01 - a02 * a11],
            [b11, a22 * a00 - a02 * a20, -a12 * a00 + a02 * a10],
            [b21, -a21 * a00 + a01 * a20, a11 * a00 - a01 * a10]]
    return [[v / det for v in c] for c in cols]


def mul_matvec(m, v):
    """`(b*a)` = GLSL `M * v` — result[행] = Σ_열 m[열][행]·v[열]."""
    return [sum(m[c][r] * v[c] for c in range(3)) for r in range(3)]


def mul_vecmat(m, v):
    """`(a*b)` = GLSL `v * M` — result[열] = Σ_행 m[열][행]·v[행]."""
    return [sum(m[c][r] * v[r] for r in range(3)) for c in range(3)]


ORDERS = {"(b*a) = M·v": mul_matvec, "(a*b) = v·M": mul_vecmat}


def corner_identity(points):
    p0, p1, p2, p3 = points
    m, degenerate = square_to_quad(p0, p1, p2, p3)
    want = {(0, 0): p0, (1, 0): p1, (1, 1): p2, (0, 1): p3}
    res = {}
    for name, fn in ORDERS.items():
        worst = 0.0
        got = {}
        for (u, v), w in want.items():
            r = fn(m, [float(u), float(v), 1.0])
            xy = (r[0] / r[2], r[1] / r[2]) if r[2] else (float("inf"), float("inf"))
            got[f"({u},{v})"] = [round(xy[0], 6), round(xy[1], 6)]
            worst = max(worst, abs(xy[0] - w[0]), abs(xy[1] - w[1]))
        res[name] = {"corners": got, "maxAbsError": round(worst, 9),
                     "satisfiesSquareToQuad": worst < 1e-9}
    res["degenerateBranch"] = degenerate
    return res


# ─── 코퍼스 도달 ──────────────────────────────────────────────────────────────

def read_pkg(path):
    with open(path, "rb") as fh:
        b = fh.read()
    p = 0
    (vlen,) = struct.unpack_from("<i", b, p); p += 4
    magic = b[p:p + vlen].decode("ascii", "replace"); p += vlen
    if not magic.startswith("PKGV"):
        return None
    (count,) = struct.unpack_from("<i", b, p); p += 4
    entries = {}
    for _ in range(count):
        (nlen,) = struct.unpack_from("<i", b, p); p += 4
        name = b[p:p + nlen].decode("utf-8", "replace"); p += nlen
        (off,) = struct.unpack_from("<i", b, p); p += 4
        (sz,) = struct.unpack_from("<i", b, p); p += 4
        entries[name] = (off, sz)
    base = p
    return {"blob": b, "base": base, "entries": entries}


def pkg_get(pkg, name):
    key = name if name in pkg["entries"] else None
    if key is None:
        low = name.replace("\\", "/").lower()
        for k in pkg["entries"]:
            if k.replace("\\", "/").lower() == low:
                key = k
                break
    if key is None:
        return None
    off, sz = pkg["entries"][key]
    s = pkg["base"] + off
    return pkg["blob"][s:s + sz]


def mul_call_args(txt):
    out = []
    for m in re.finditer(r"\bmul\s*\(", txt):
        i, depth, start, args = m.end(), 1, m.end(), []
        while i < len(txt) and depth > 0:
            ch = txt[i]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    args.append(txt[start:i])
                    break
            elif ch == "," and depth == 1:
                args.append(txt[start:i]); start = i + 1
            i += 1
        if len(args) == 2:
            out.append((args[0].strip(), args[1].strip()))
    return out


def smoothstep(e0, e1, x):
    if e1 == e0:
        return 0.0 if x < e0 else 1.0
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def mask_is_identically_zero(consts, combos, order_fn, grid=65):
    """lightshafts.frag 의 `mask` 체인(노이즈 제외)을 격자에서 평가 → 전역 0 이면 fx≡0."""
    def f(k, d):
        v = consts.get(k, d)
        return float(v.split()[0]) if isinstance(v, str) else float(v)

    def v2(k, d):
        v = consts.get(k, d)
        if isinstance(v, str):
            parts = [float(x) for x in v.split()]
            return (parts[0], parts[1] if len(parts) > 1 else parts[0])
        return (float(v), float(v))

    pts = (v2("point0", "0.67728 0.01297"), v2("point1", "0.76007 0.14043"),
           v2("point2", "0.46654 1.09592"), v2("point3", "0.16363 0.44881"))
    feather = v2("rayfeather", "0.05 0.2")
    radius = f("rayradius", 0.2)
    start_a, end_a = f("rayzstartangle", 0.0), f("rayzzendangle", 1.0)
    raymode = int(combos.get("RAYMODE", 0) or 0)
    raycorner = int(combos.get("RAYCORNER", 0) or 0)

    m, _ = square_to_quad(*pts)
    x = inverse3(m)
    if x is None:
        return True, 0.0
    peak = 0.0
    for j in range(grid):
        for i in range(grid):
            u, v = i / (grid - 1), j / (grid - 1)
            r = order_fn(x, [u, v, 1.0])
            if r[2] == 0:
                continue
            cx, cy = r[0] / r[2], r[1] / r[2]
            mask = 1.0 if r[2] >= 0 else 0.0
            if raymode == 1:
                dx, dy = cx - 0.5, cy - 0.5
                cx = math.atan2(dy, dx) / 6.283185 + 0.5
                cy = smoothstep(radius, 1.0, math.hypot(dx, dy) * 2.0)
                cy = (cy - 0.0001) * 1.00021
                mask *= smoothstep(-0.00001 + start_a, start_a + feather[0], cx)
                mask *= smoothstep(end_a + 0.00001, end_a - feather[0], cx)
                mask *= smoothstep(0.50001, 0.5 - feather[1], abs(cy - 0.5))
            elif raymode == 2:
                dx, dy = cx, cy
                if raycorner == 1:
                    dx = 1.0 - dx
                elif raycorner == 2:
                    dy = 1.0 - dy
                elif raycorner == 3:
                    dx, dy = 1.0 - dx, 1.0 - dy
                cx = math.atan2(dy, dx) / 6.283185 * 4
                cy = smoothstep(radius, 1.0, max(dx, dy))
                mask *= smoothstep(0.50001, 0.5 - feather[0], abs(cx - 0.5))
                mask *= smoothstep(0.50001, 0.5 - feather[1], abs(cy - 0.5))
            else:
                mask *= smoothstep(0.50001, 0.5 - feather[0], abs(cx - 0.5))
                mask *= smoothstep(0.50001, 0.5 - feather[1], abs(cy - 0.5))
            peak = max(peak, mask * (1.0 - cy))
    return peak <= 1e-6, peak


def scan_corpus():
    if not os.path.isdir(CORPUS):
        return None
    dd_passes, dd_scenes = [], set()
    dark = {name: 0 for name in ORDERS}
    reach_scenes, reach_files = set(), 0
    pkg_count = 0
    for sid in sorted(os.listdir(CORPUS)):
        d = os.path.join(CORPUS, sid)
        pkg_path = os.path.join(d, "scene.pkg")
        if not os.path.isfile(pkg_path):
            continue
        pkg = read_pkg(pkg_path)
        if pkg is None:
            continue
        pkg_count += 1
        for name in pkg["entries"]:
            if not name.endswith((".vert", ".frag", ".h")):
                continue
            txt = (pkg_get(pkg, name) or b"").decode("utf-8", "replace")
            if any(not ENGINE_MATRIX.match(b) for _, b in mul_call_args(txt)):
                reach_scenes.add(sid)
                reach_files += 1
        raw = pkg_get(pkg, "scene.json")
        if raw is None:
            continue
        if raw[:3] == b"\xef\xbb\xbf":
            raw = raw[3:]
        try:
            scene = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            continue
        for o in scene.get("objects", []) or []:
            for e in o.get("effects", []) or []:
                for p in e.get("passes", []) or []:
                    combos = p.get("combos") or {}
                    if not int(combos.get("DIRECTDRAW", 0) or 0):
                        continue
                    dd_scenes.add(sid)
                    dd_passes.append(sid)
                    consts = p.get("constantshadervalues") or {}
                    for name, fn in ORDERS.items():
                        zero, _ = mask_is_identically_zero(consts, combos, fn)
                        if zero:
                            dark[name] += 1
    return {"packagesScanned": pkg_count,
            "directDrawPasses": len(dd_passes), "directDrawScenes": len(dd_scenes),
            "maskIdenticallyZeroPasses": dark,
            "nonEngineMatrixMulScenes": len(reach_scenes),
            "nonEngineMatrixMulShaderFiles": reach_files}


MUL_MATVEC_RE = re.compile(
    r'rewriteCall\(s,\s*"mul"\)[\s\S]{0,400}?\\\(args\[1\]\)\s*\*\s*\\\(args\[0\]\)')
MUL_VECMAT_RE = re.compile(
    r'rewriteCall\(s,\s*"mul"\)[\s\S]{0,400}?\\\(args\[0\]\)\s*\*\s*\\\(args\[1\]\)')


def detect_mul_order(translator: str) -> bool:
    """번역기가 `mul(a,b)` 를 `(b * a)` 로 내는지 판정한다. True = (b*a) = 행렬·벡터.

    **양성/음성 대조가 있는 이유.** 종전 판정은 기준점의 *한 줄 삼항식*을 리터럴로 매칭했다:

        'rewriteCall(s, "mul") { args in args.count == 2 ? "(\\(args[1]) * \\(args[0]))"'

    그 코드가 `guard … / return` 다중행으로 리팩터되면서(GLSLTranslator.swift:1517-1520)
    매칭이 죽었는데, **동작은 하나도 안 바뀌었다**. 그런데 판정은 `in` 이 False 면 조용히
    `(a * b)` 를 내고 스크립트는 exit 0 으로 완주했다 — 즉 다음 사람이 재생성하면 오류 하나
    없이 확정 값이 **정반대로 뒤집힌 채** 커밋된다. 실제로 2026-08-20 재생성에서 그 일이 났다.

    그래서 두 순서를 **각각** 찾고, 정확히 하나만 잡힐 때만 판정한다. 둘 다 못 잡거나 둘 다
    잡히면 그건 "코드가 바뀌었다" 가 아니라 "**이 판정식이 낡았다**" 는 신호이므로 하드 실패한다.
    조용히 틀린 값을 내는 것보다 재생성이 멈추는 편이 낫다.
    """
    matvec = bool(MUL_MATVEC_RE.search(translator))
    vecmat = bool(MUL_VECMAT_RE.search(translator))
    if matvec == vecmat:
        raise SystemExit(
            "[measure_mul_convention] mul 인자 순서를 판정할 수 없다"
            f" (matvec={matvec}, vecmat={vecmat}).\n"
            f"  {TRANSLATOR} 의 `rewriteCall(s, \"mul\")` 방출식이 바뀌었으면"
            " 이 스크립트의 MUL_MATVEC_RE / MUL_VECMAT_RE 를 함께 고쳐라.\n"
            "  (조용히 반대 값을 확정으로 커밋하지 않으려고 일부러 여기서 멈춘다.)")
    return matvec


def carry_forward(entry_id: str):
    """코퍼스가 없어 재측정 못 하는 항목을 **기존 산출물에서 그대로 이어받는다**.

    종전엔 코퍼스가 없으면 경고 한 줄 찍고 항목을 통째로 뺐다. 그러면 코퍼스 없는 환경에서
    한 번 재생성하는 것만으로 169패키지를 실측한 근거가 **소리 없이 사라진다**(2026-08-20
    재생성에서 mul.reach 30줄이 그렇게 날아갔다). 측정할 수 없다는 것은 근거가 틀렸다는
    뜻이 아니므로, 있으면 이어받고 없으면 그때만 뺀다.
    """
    if not os.path.isfile(OUT):
        return None
    try:
        doc = json.load(open(OUT, encoding="utf-8"))
    except (OSError, ValueError):
        return None
    for e in doc.get("entries", []):
        if e.get("id") == entry_id:
            return e
    return None


def main():
    for p in (PERSPECTIVE_H, LIGHTSHAFTS_VERT, LIGHTSHAFTS_FRAG, TRANSLATOR):
        if not os.path.isfile(p):
            raise SystemExit(f"필수 파일 없음: {p}")
    vert = open(LIGHTSHAFTS_VERT, encoding="utf-8").read()
    defaults = annotation_defaults(vert, ["g_Point0", "g_Point1", "g_Point2", "g_Point3"])
    identity = corner_identity([defaults[f"g_Point{i}"] for i in range(4)])
    translator = open(TRANSLATOR, encoding="utf-8").read()
    emits_matvec = detect_mul_order(translator)

    S = specfmt.ev("script", "scripts/spec/measure_mul_convention.py")
    entries = [
        specfmt.entry(
            "mul.shim",
            {"weDialect": "GLSL 문법의 동봉 셰이더가 HLSL 네이티브 이름 `mul` 을 호출한다",
             "hlslSemantics": "mul(v, M) = 행벡터 v·M, m[행][열]",
             "portedShim": "#define mul(a,b) ((b)*(a))  // GLSL/MSL 은 m[열][행] — 같은 대입문이 만드는 행렬이 전치라 순서를 뒤집어야 등가",
             "translatorEmits": "(b * a)" if emits_matvec else "(a * b)",
             "appliesToBothArgForms": "벡터-우선 mul(v,M) 과 행렬-우선 mul(M,v)(generic.vert 의 mul(tangentSpace, lightDir)) 모두에 동시에 옳다"},
            "확정",
            [specfmt.ev("shader", "Sources/WapleRender/Resources/WEAssets/shaders/common_perspective.h "
                                  f"(sha256_16 {sha16(PERSPECTIVE_H)}) — `#if HLSL` 분기가 같은 원문이 두 백엔드로 컴파일됨을 보인다"),
             specfmt.ev("file", "Sources/WapleCore/GLSLTranslator.swift translateBody ①"),
             S]),
        specfmt.entry(
            "mul.squareToQuadCornerIdentity",
            {"points": {k: list(v) for k, v in defaults.items()},
             "pointsSource": "lightshafts.vert 어노테이션 default (원문 파싱)",
             "byOrder": identity,
             "verdict": "(b*a) 만 squareToQuad 계약(단위정사각형 코너 → p0,p1,p2,p3)을 만족한다"},
            "확정",
            [specfmt.ev("shader", f"WEAssets/effects/lightshafts/shaders/effects/lightshafts.vert (sha256_16 {sha16(LIGHTSHAFTS_VERT)})"),
             specfmt.ev("shader", f"WEAssets/shaders/common_perspective.h (sha256_16 {sha16(PERSPECTIVE_H)})"),
             S]),
    ]

    corpus = scan_corpus()
    if corpus:
        entries.append(specfmt.entry(
            "mul.reach",
            corpus,
            "확정",
            [specfmt.ev("corpus", f"$WAPLE_REAL_PKGS — scene.pkg {corpus['packagesScanned']}개 전수"),
             specfmt.ev("shader", f"lightshafts.frag mask 체인 재현 (sha256_16 {sha16(LIGHTSHAFTS_FRAG)}), 65² 격자"),
             S]))
    else:
        prior = carry_forward("mul.reach")
        if prior is not None:
            entries.append(prior)
            print(f"  ⚠️ 코퍼스 없음({CORPUS}) — mul.reach 는 기존 산출물에서 이어받는다(근거 보존)",
                  file=sys.stderr)
        else:
            print(f"  ⚠️ 코퍼스 없음({CORPUS}) — mul.reach 항목이 아직 없어 뺀다", file=sys.stderr)

    specfmt.dump(specfmt.doc("scripts/spec/measure_mul_convention.py", entries), OUT)
    print(f"mul 규약 → {os.path.relpath(OUT, REPO)}")
    for name, r in identity.items():
        if name == "degenerateBranch":
            continue
        print(f"  {name:14s} maxAbsError={r['maxAbsError']:.6g} 계약충족={r['satisfiesSquareToQuad']}")
    if corpus:
        print(f"  DIRECTDRAW {corpus['directDrawPasses']}패스/{corpus['directDrawScenes']}씬, "
              f"mask≡0: {corpus['maskIdenticallyZeroPasses']}")
        print(f"  비-엔진행렬 mul 보유: {corpus['nonEngineMatrixMulScenes']}씬 / {corpus['nonEngineMatrixMulShaderFiles']}파일")
    return 0


if __name__ == "__main__":
    sys.exit(main())
