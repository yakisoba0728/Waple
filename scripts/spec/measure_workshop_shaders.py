"""워크샵 저작 셰이더(.frag/.vert) 전수 조사 → spec/corpus/workshop-shaders.json.

무엇을 재는가
  1) 참조 g_* 유니폼 전수·도수
  2) #include 헤더 전수·도수 + 해석처(pkg / 베이스에셋 / 내장 / 미해석)
  3) GLSL 문법 기능 도수(구조체·배열·함수형 매크로·#if 복잡도 …)
  4) Waple 의 ShaderPreprocessor 가 **실제로** 거부하는 건수
  5) [COMBO] 선언 전수와 값 도메인
  6) 난이도 상위 사례

왜 포트인가
  이 머신엔 Swift 툴체인이 없어 Waple 을 실행할 수 없다. 그래서 거부 판정 경로만
  (ShaderPreprocessor.preprocessStrict + ExprEval.evalChecked) Python 으로 1:1 포팅하고,
  Swift 테스트(Tests/WapleCoreTests/TranslationEvalFixRegressionTests.swift,
  TranslatorSceneFixRegressionTests.swift, ShaderPreprocessorTests.swift)에 있는
  기대 입출력 케이스로 포트 자체를 검증한다(`--selftest`). 포트 대상은 "거부하는가"
  까지이며 매크로 확장/본문 방출은 포팅하지 않는다(거부는 그 전에 결정된다).

  근거 줄번호(포팅 시점 소스):
    ShaderPreprocessor.swift:17-67(preprocessStrict), :81-95(splice), :98-106(COMBO),
    :108-129(inlineIncludes), :136-333(evaluateConditionals), :338-361(hasIdenticalBranches),
    :469-477(builtin CAST), :483-609(ExprEval)
    GLSLTranslator.swift:1178-1216(isEngine), :7-20(GLSLType.from), :1061-1087(parseUniforms)

재현: python scripts/spec/measure_workshop_shaders.py [--selftest]
"""
import collections
import hashlib
import json
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WS = os.environ.get("WE_WORKSHOP", r"Z:\SteamLibrary\steamapps\workshop\content\431960")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BASE_ASSETS = os.path.join(REPO, "Sources", "WapleRender", "Resources", "WEAssets")

# ---------------------------------------------------------------- pkg (measure_corpus.py 와 동일 규약)


def parse_pkg(data):
    n = len(data)
    p = 0

    def i32():
        nonlocal p
        if p + 4 > n:
            raise ValueError("eof")
        v = struct.unpack_from("<i", data, p)[0]
        p += 4
        return v

    vlen = i32()
    if vlen < 0 or p + vlen > n:
        raise ValueError("bad vlen")
    magic = data[p:p + vlen].decode("ascii", "ignore")
    p += vlen
    count = i32()
    if count < 0 or count > 65536:
        raise ValueError("bad count")
    entries = []
    for _ in range(count):
        nlen = i32()
        if nlen < 0 or p + nlen > n:
            raise ValueError("bad nlen")
        name = data[p:p + nlen].decode("utf-8", "ignore")
        p += nlen
        entries.append((name, i32(), i32()))
    return magic, entries, p


# ---------------------------------------------------------------- ExprEval 포트 (ShaderPreprocessor.swift:483-609)

TWO_CHAR_OPS = {"==", "!=", "<=", ">=", "&&", "||"}
SINGLE_OPS = set("()!*/+-<>")


def tokenize(s):
    """ExprEval.tokenize — (tokens, unsupported)."""
    toks = []
    i = 0
    n = len(s)
    unsupported = False
    while i < n:
        c = s[i]
        if c.isspace():
            i += 1
            continue
        if i + 1 < n and s[i:i + 2] in TWO_CHAR_OPS:
            toks.append(s[i:i + 2])
            i += 2
            continue
        if i + 1 < n and (s[i:i + 2] == "<<" or s[i:i + 2] == ">>"):
            unsupported = True   # 시프트: `<`/`>` 이중 토큰 오평가 방지 명시 거부
            i += 2
            continue
        if c in SINGLE_OPS:
            toks.append(c)
            i += 1
            continue
        if c.isalpha() or c == "_":
            j = i
            while j < n and (s[j].isalnum() or s[j] == "_"):
                j += 1
            toks.append(s[i:j])
            i = j
            continue
        if c.isdigit():
            j = i
            while j < n and s[j].isdigit():
                j += 1
            if j < n and (s[j].isalpha() or s[j] == "_"):
                unsupported = True   # 0x10 / 1u / 1e5 — 10진 파서로는 오평가
            toks.append(s[i:j])
            i = j
            continue
        unsupported = True   # % & | ^ ~ ? : . , ; " 등
        i += 1
    return toks, unsupported


MAX_DEPTH = 256
INT_MIN = -(2 ** 63)
INT_MAX = 2 ** 63 - 1


def _wrap(v):
    v &= (2 ** 64 - 1)
    return v - 2 ** 64 if v > INT_MAX else v


def eval_checked(expr, defines, defined_names=None, suspect=frozenset()):
    """ExprEval.evalChecked — 미지원이면 None."""
    toks, unsupported = tokenize(expr)
    if unsupported:
        return None
    known = set(defines.keys()) if defined_names is None else defined_names
    state = {"pos": 0, "failed": False, "depth": 0}

    def peek():
        return toks[state["pos"]] if state["pos"] < len(toks) else None

    def nxt():
        t = peek()
        state["pos"] += 1
        return t

    def parse_primary():
        state["depth"] += 1
        try:
            if state["depth"] > MAX_DEPTH:
                return 0
            t = nxt()
            if t is None:
                return 0
            if t == "(":
                v = parse_or()
                if peek() == ")":
                    state["pos"] += 1
                return v
            if t == "!":
                return 0 if parse_primary() != 0 else 1
            if t == "-":
                return _wrap(0 - parse_primary())
            if t == "defined":
                if peek() == "(":
                    state["pos"] += 1
                    name = nxt() or ""
                    if peek() == ")":
                        state["pos"] += 1
                    return 1 if name in known else 0
                return 1 if (nxt() or "") in known else 0
            try:
                return int(t)          # Swift Int(t) — 10진만
            except ValueError:
                pass
            if t in suspect:
                state["failed"] = True
                return 0
            return defines.get(t, 0)
        finally:
            state["depth"] -= 1

    def parse_mul():
        v = parse_primary()
        while peek() in ("*", "/"):
            op = nxt()
            r = parse_primary()
            if op == "*":
                v = _wrap(v * r)
            elif r == 0 or (v == INT_MIN and r == -1):
                v = 0                                   # Swift 측 트랩 가드와 동일
            else:
                q = abs(v) // abs(r)                    # Swift Int 나눗셈 = 0 방향 절단
                v = q if (v < 0) == (r < 0) else -q
        return v

    def parse_add():
        v = parse_mul()
        while peek() in ("+", "-"):
            op = nxt()
            r = parse_mul()
            v = _wrap(v + r) if op == "+" else _wrap(v - r)
        return v

    def parse_cmp():
        v = parse_add()
        while peek() in ("==", "!=", "<", ">", "<=", ">="):
            op = nxt()
            r = parse_add()
            v = int({"==": v == r, "!=": v != r, "<": v < r,
                     ">": v > r, "<=": v <= r, ">=": v >= r}[op])
        return v

    def parse_and():
        v = parse_cmp()
        while peek() == "&&":
            state["pos"] += 1
            r = parse_cmp()
            v = 1 if (v != 0 and r != 0) else 0
        return v

    def parse_or():
        v = parse_and()
        while peek() == "||":
            state["pos"] += 1
            r = parse_and()
            v = 1 if (v != 0 or r != 0) else 0
        return v

    value = parse_or()
    if state["failed"] or state["pos"] != len(toks):
        return None
    return value


# ---------------------------------------------------------------- ShaderPreprocessor 포트

BUILTIN_CAST_MACROS = [
    ("CAST2", "vec2(x)"), ("CAST3", "vec3(x)"), ("CAST4", "vec4(x)"),
    ("CAST2X2", "mat2(x)"), ("CAST3X3", "we_cast3x3(x)"), ("CAST4X4", "mat4(x)"),
    ("CASTI", "int(x)"), ("CASTU", "uint(x)"), ("CASTF", "float(x)"), ("CAST4U", "uint4(x)"),
    ("DECLARE_SAMPLER2D_PARAMETER", "sampler2D x"),
    ("MAKE_SAMPLER2D_ARGUMENT", "x"),
    ("DECLARE_SAMPLER2D_COMPARE_PARAMETER", "sampler2D x"),
    ("MAKE_SAMPLER2D_COMPARE_ARGUMENT", "x"),
]


def normalize_newlines(s):
    return s.replace("\r\n", "\n").replace("\r", "\n")


def json_string(line, key):
    i = line.find('"%s"' % key)
    if i < 0:
        return None
    rest = line[i + len(key) + 2:]
    c = rest.find(":")
    if c < 0:
        return None
    after = rest[c + 1:]
    q1 = after.find('"')
    if q1 < 0:
        return None
    q2 = after.find('"', q1 + 1)
    if q2 < 0:
        return None
    return after[q1 + 1:q2]


def json_int(line, key):
    i = line.find('"%s"' % key)
    if i < 0:
        return None
    rest = line[i + len(key) + 2:]
    c = rest.find(":")
    if c < 0:
        return None
    num = ""
    for ch in rest[c + 1:]:
        if ch in ",}":
            break
        if ch.isdigit() or ch == "-":
            num += ch
        elif not ch.isspace() and num:
            break
    try:
        return int(num)
    except ValueError:
        return None


def parse_combo_defaults(source):
    out = {}
    for line in source.split("\n"):
        if "[COMBO]" not in line:
            continue
        combo = json_string(line, "combo")
        if combo is None:
            continue
        v = json_int(line, "default")
        out[combo] = 0 if v is None else v
    return out


def first_quoted(s):
    a = s.find('"')
    if a < 0:
        return None
    b = s.find('"', a + 1)
    if b < 0:
        return None
    return s[a + 1:b]


def inline_includes(source, include, depth, seen_stats=None):
    if depth > 16:
        return source
    lines = []
    for line in source.split("\n"):
        t = line.strip()
        if t.startswith("#include"):
            name = first_quoted(t)
            if name is not None:
                header = include(name)
                if header is not None:
                    lines.append(inline_includes(normalize_newlines(header), include, depth + 1, seen_stats))
                elif seen_stats is not None:
                    seen_stats["dropped"].append(name)
            continue
        lines.append(line)
    return "\n".join(lines)


def splice_define_continuations(source):
    if "\\\n" not in source:
        return source
    out = []
    lines = source.split("\n")
    i = 0
    while i < len(lines):
        s = lines[i]
        i += 1
        if s.strip().startswith("#define"):
            while s.endswith("\\") and i < len(lines):
                s = s[:-1] + " " + lines[i]
                i += 1
        out.append(s)
    return "\n".join(out)


def identifier_referenced(name, source):
    return re.search(r"\b%s\b" % re.escape(name), source) is not None


def identifier_defined(name, source):
    return re.search(r"#define\s+%s\b" % re.escape(name), source) is not None


def has_identical_branches(lines, start):
    depth = 0
    else_idx = None
    i = start
    while i < len(lines):
        lt = lines[i].strip()
        if lt.startswith("#endif"):
            if depth == 0:
                a = lines[start:(else_idx if else_idx is not None else i)]
                b = lines[else_idx + 1:i] if else_idx is not None else []
                return a == b
            depth -= 1
        elif lt.startswith("#if"):
            depth += 1
        elif depth == 0 and lt.startswith("#elif"):
            return False
        elif depth == 0 and lt.startswith("#else") and else_idx is None:
            else_idx = i
        i += 1
    return False


def paren_decimal_int(value):
    v = value.strip()
    if not v.startswith("("):
        return None
    while v.startswith("(") and v.endswith(")"):
        v = v[1:-1].strip()
    try:
        return int(v)
    except ValueError:
        return None


def token_after(kw, line):
    rest = line[len(kw):].strip().split(" ")
    return rest[0] if rest else ""


def classify_refusal(expr, defines, defined_names, suspect):
    """거부 사유 분류(진단용 — 판정은 eval_checked 가 한다)."""
    toks, unsupported = tokenize(expr)
    if unsupported:
        if "<<" in expr or ">>" in expr:
            return "shift"
        if re.search(r"\b0[xX][0-9a-fA-F]+", expr):
            return "hexLiteral"
        if re.search(r"\b\d+[a-zA-Z_]", expr):
            return "suffixedOrExpLiteral"
        if "?" in expr or ":" in expr:
            return "ternary"
        if "%" in expr:
            return "modulo"
        if re.search(r"[&|^~]", expr) and not re.search(r"&&|\|\|", expr.replace("&&", "").replace("||", "")):
            return "bitwise"
        if "." in expr:
            return "memberAccess"      # uniform 멤버 비교(g_Texture0Resolution.x < …)
        if re.search(r"[&|^~]", expr):
            return "bitwise"
        return "unknownChar"
    if any(t in suspect for t in toks):
        return "suspectDefine"
    return "residualTokens"


                    # 관용 스위치(어블레이션용) — 전부 켜짐이 Waple 현행 동작
ALL_TOLERANCES = ("directiveComment", "ifParen", "trailingSemicolon", "identicalBranches", "parentActive")


def preprocess_strict(source, combos, include, stats=None, tolerances=ALL_TOLERANCES):
    """ShaderPreprocessor.preprocessStrict 의 **거부 판정** 포트.

    반환: (ok: bool, reason: str|None, defines_snapshot, emittedLines)
    본문 매크로 확장/방출은 포팅하지 않는다(거부는 그 전에 결정된다).
    """
    source = normalize_newlines(source)
    defines = dict(combos)
    defines["HLSL"] = 1
    defines["HLSL_SM40"] = 1
    defines["SHADERVERSION"] = 69
    for name, dv in parse_combo_defaults(source).items():
        defines.setdefault(name, dv)
    included = inline_includes(source, include, 0, stats)
    for name, body in BUILTIN_CAST_MACROS:
        if not identifier_defined(name, included) and identifier_referenced(name, included):
            included = "#define %s(x) %s\n" % (name, body) + included
    for name, dv in parse_combo_defaults(included).items():
        defines.setdefault(name, dv)
    return evaluate_conditionals(splice_define_continuations(included), defines, tolerances)


def evaluate_conditionals(source, defines, tolerances=ALL_TOLERANCES):
    d = dict(defines)
    text_defines = {}
    func_macros = {}
    flag_defines = set()
    suspect = set()
    stack = []          # [active, taken, parentActive]
    emitted = []

    def emitting():
        return all(f[0] for f in stack)

    def defined_names():
        return set(d.keys()) | set(text_defines.keys()) | set(func_macros.keys())

    src_lines = source.split("\n")
    li = 0
    while li < len(src_lines):
        line = src_lines[li]
        li += 1
        t = line.strip()
        if t.startswith("#") and "directiveComment" in tolerances:
            c = t.find("//")
            if c >= 0:
                t = t[:c].strip()
            c = t.find("/*")
            if c >= 0:
                t = t[:c].strip()
        if "ifParen" in tolerances:
            if t.startswith("#if("):
                t = "#if " + t[3:]
            elif t.startswith("#elif("):
                t = "#elif " + t[5:]
        if (t.startswith("#if ") or t.startswith("#elif ")) and "trailingSemicolon" in tolerances:
            while t.endswith(";"):
                t = t[:-1].strip()

        if t.startswith("#if ") or t.startswith("#ifdef ") or t.startswith("#ifndef "):
            parent_active = emitting()
            cond = False
            if t.startswith("#ifdef "):
                cond = token_after("#ifdef", t) in defined_names()
            elif t.startswith("#ifndef "):
                cond = token_after("#ifndef", t) not in defined_names()
            else:
                expr = t[3:]
                v = eval_checked(expr, d, defined_names(), suspect)
                if v is not None:
                    cond = v != 0
                elif parent_active or "parentActive" not in tolerances:
                    if "identicalBranches" in tolerances and has_identical_branches(src_lines, li):
                        cond = False
                    else:
                        return False, classify_refusal(expr, d, defined_names(), suspect), d, emitted
            stack.append([parent_active and cond, cond, parent_active])
        elif t.startswith("#elif "):
            if not stack:
                continue
            f = stack.pop()
            cond = False
            if not f[1]:
                expr = t[5:]
                v = eval_checked(expr, d, defined_names(), suspect)
                if v is not None:
                    cond = v != 0
                elif f[2] or "parentActive" not in tolerances:
                    return False, classify_refusal(expr, d, defined_names(), suspect), d, emitted
            f[0] = f[2] and cond
            f[1] = f[1] or cond
            stack.append(f)
        elif t == "#else" or t.startswith("#else ") or t.startswith("#else//"):
            if not stack:
                continue
            f = stack.pop()
            f[0] = f[2] and not f[1]
            f[1] = True
            stack.append(f)
        elif t == "#endif" or t.startswith("#endif ") or t.startswith("#endif//"):
            if stack:
                stack.pop()
        elif t.startswith("#undef "):
            if emitting():
                name = token_after("#undef", t)
                d.pop(name, None)
                text_defines.pop(name, None)
                func_macros.pop(name, None)
                flag_defines.discard(name)
                suspect.discard(name)
        elif t.startswith("#define ") and emitting():
            decl = t[8:]
            m = re.search(r"[ (\t]", decl)
            name_end = m.start() if m else len(decl)
            name = decl[:name_end]
            if not name:
                pass
            elif name_end < len(decl) and decl[name_end] == "(":
                after = decl[name_end + 1:]
                close = after.find(")")
                if close >= 0:
                    body_raw = after[close + 1:]
                    c = body_raw.find("//")
                    if c >= 0:
                        body_raw = body_raw[:c]
                    c = body_raw.find("/*")
                    if c >= 0:
                        body_raw = body_raw[:c]
                    params = [p.strip() for p in after[:close].split(",") if p.strip()]
                    if body_raw.strip():
                        func_macros[name] = (params, body_raw.strip())
            else:
                raw = decl[name_end:]
                c = raw.find("//")
                if c >= 0:
                    raw = raw[:c]
                c = raw.find("/*")
                if c >= 0:
                    raw = raw[:c]
                value = raw.strip()
                if not value:
                    d[name] = 1
                    flag_defines.add(name)
                else:
                    try:
                        d[name] = int(value)
                    except ValueError:
                        pv = paren_decimal_int(value)
                        if pv is not None:
                            d[name] = pv
                        elif value[0].isdigit():
                            suspect.add(name)
                    text_defines[name] = value
        elif emitting():
            emitted.append(line)
    return True, None, d, emitted


# ---------------------------------------------------------------- isEngine 포트 (GLSLTranslator.swift:1178-1216)


def is_engine(name):
    return (name in ("g_Time", "g_ModelViewProjectionMatrix", "g_PointerPosition",
                     "g_TexelSize", "g_TexelSizeHalf", "g_ParallaxPosition",
                     "g_Frametime", "g_PointerPositionLast", "g_PointerState",
                     "g_Screen", "g_LightAmbientColor")
            or name.startswith("g_AudioSpectrum")
            or (name.startswith("g_Texture") and name.endswith("Resolution"))
            or (name.startswith("g_Texture") and name.endswith("Texel"))
            or (name.startswith("g_") and "Matrix" in name)
            or name.startswith("g_LPoint_") or name.startswith("g_LSpot_")
            or name.startswith("g_LTube_") or name.startswith("g_LDirectional_")
            or name.startswith("g_LFeature_Shadow"))


def texture_index(name):
    if not name.startswith("g_Texture"):
        return None
    rest = name[len("g_Texture"):]
    digits = ""
    for ch in rest:
        if ch.isdigit():
            digits += ch
        else:
            break
    return int(digits) if digits else None


# GLSLType.from (GLSLTranslator.swift:7-20) — 이 집합 밖 타입의 uniform/varying/attribute 선언은 파서가 통째로 건너뛴다.
GLSL_TYPES = {"float", "vec2", "vec3", "vec4", "mat2", "mat3", "mat4", "mat4x3", "sampler2D",
              "float2", "float3", "float4", "float2x2", "float3x3", "float4x4", "float4x3",
              "uvec2", "ivec2", "uvec3", "ivec3", "uvec4", "ivec4", "sampler2DBackBuffer"}


# ---------------------------------------------------------------- 소스 계측 헬퍼

RE_LINE_COMMENT = re.compile(r"//[^\n]*")
RE_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)


def strip_comments(src):
    return RE_LINE_COMMENT.sub("", RE_BLOCK_COMMENT.sub(" ", src))


G_IDENT = re.compile(r"\bg_[A-Za-z0-9_]+")


def max_conditional_depth(src):
    depth = 0
    peak = 0
    for line in src.split("\n"):
        t = line.strip()
        if t.startswith("#if"):
            depth += 1
            peak = max(peak, depth)
        elif t.startswith("#endif"):
            depth = max(0, depth - 1)
    return peak


def directive_exprs(src):
    """#if/#elif 식 원문(주석·후행 ; 절단 후) 목록 — Waple 이 보는 형태."""
    out = []
    for line in src.split("\n"):
        t = line.strip()
        if not t.startswith("#"):
            continue
        c = t.find("//")
        if c >= 0:
            t = t[:c].strip()
        c = t.find("/*")
        if c >= 0:
            t = t[:c].strip()
        if t.startswith("#if("):
            t = "#if " + t[3:]
        elif t.startswith("#elif("):
            t = "#elif " + t[5:]
        if t.startswith("#if ") or t.startswith("#elif "):
            while t.endswith(";"):
                t = t[:-1].strip()
            out.append(t[3:].strip() if t.startswith("#if ") else t[5:].strip())
    return out


NAIVE_BAD = re.compile(r"%|(?<![&])&(?![&])|(?<![|])\|(?![|])|\^|~|\?|:|<<|>>|\b0[xX][0-9a-fA-F]+|\b\d+[a-zA-Z_]")


def naive_unsupported(src):
    """관용 로직을 무시한 '거칠게 센' 미지원 #if 보유 여부(포트의 관용 로직이 실제로 일하는지 대조용)."""
    return any(NAIVE_BAD.search(e) for e in directive_exprs(src))


FEATURE_PATTERNS = [
    ("structDecl", re.compile(r"\bstruct\s+[A-Za-z_]\w*\s*\{")),
    ("arrayDecl", re.compile(r"\b(?:float|int|uint|bool|vec[234]|ivec[234]|uvec[234]|mat[234]|float[234])\s+\w+\s*\[")),
    ("funcLikeMacro", re.compile(r"^\s*#define\s+\w+\(", re.M)),
    ("objectLikeMacro", re.compile(r"^\s*#define\s+\w+(?:\s|$)", re.M)),
    ("macroLineContinuation", re.compile(r"^\s*#define[^\n]*\\\s*$", re.M)),
    ("forLoop", re.compile(r"\bfor\s*\(")),
    ("whileLoop", re.compile(r"\bwhile\s*\(")),
    ("doWhile", re.compile(r"\bdo\s*\{")),
    ("switchStmt", re.compile(r"\bswitch\s*\(")),
    ("ternaryInBody", re.compile(r"\?[^\n]*:")),
    ("bitwiseInBody", re.compile(r"(?:<<|>>|(?<![&])&(?![&=])|(?<![|])\|(?![|=])|\^|~)")),
    ("moduloInBody", re.compile(r"%")),
    ("discard", re.compile(r"\bdiscard\b")),
    ("glFragColor", re.compile(r"\bgl_FragColor\b")),
    ("glFragData", re.compile(r"\bgl_FragData\b")),
    ("glFragCoord", re.compile(r"\bgl_FragCoord\b")),
    ("glPointSize", re.compile(r"\bgl_PointSize\b")),
    ("glVertexID", re.compile(r"\bgl_(?:VertexID|InstanceID)\b")),
    ("glslTexture2DBuiltin", re.compile(r"\btexture(?:2D|Lod|2DLod|Cube)?\s*\(")),
    ("weTexSample2D", re.compile(r"\btexSample2D\w*\s*\(")),
    ("weTexLoad2D", re.compile(r"\btexLoad2D\s*\(")),
    ("mulIntrinsic", re.compile(r"\bmul\s*\(")),
    ("castMacro", re.compile(r"\bCAST(?:2|3|4|I|U|F|2X2|3X3|4X4|4U)\s*\(")),
    ("hlslIntrinsic", re.compile(r"\b(?:frac|saturate|lerp|rsqrt|ddx|ddy|fmod|atan2)\s*\(")),
    ("versionDirective", re.compile(r"^\s*#version\b", re.M)),
    ("extensionDirective", re.compile(r"^\s*#extension\b", re.M)),
    ("pragmaDirective", re.compile(r"^\s*#pragma\b", re.M)),
    ("lineDirective", re.compile(r"^\s*#line\b", re.M)),
    ("layoutQualifier", re.compile(r"\blayout\s*\(")),
    ("precisionQualifier", re.compile(r"^\s*precision\s", re.M)),
    ("inoutParam", re.compile(r"\b(?:inout|out)\s+(?:float|vec[234]|int|uint|bool|mat[234])\b")),
    ("outVarDecl", re.compile(r"^\s*out\s+(?:float|vec[234]|int|uint)\s", re.M)),
    ("uniformArrayDecl", re.compile(r"^\s*uniform\s+\w+\s+\w+\s*\[", re.M)),
    ("undefDirective", re.compile(r"^\s*#undef\b", re.M)),
    ("includeInsideConditional", re.compile(r"^\s*#if[^\n]*\n(?:[^\n]*\n)*?\s*#include", re.M)),
]

DECL_RE = re.compile(r"^\s*(uniform|varying|attribute)\s+([A-Za-z_]\w*)\s+", re.M)


def collect_decl_types(src):
    """선언 키워드별 타입 도수 — GLSL_TYPES 밖이면 Waple 파서가 통째로 스킵한다."""
    out = collections.Counter()
    for kw, ty in DECL_RE.findall(src):
        out[(kw, ty)] += 1
    return out


COMBO_LINE = re.compile(r"\[COMBO\][^\n]*")


def collect_combos(src):
    """[COMBO] 어노테이션 → (name, default, 선언된 도메인 힌트)."""
    out = []
    for line in COMBO_LINE.findall(src):
        name = json_string(line, "combo")
        if name is None:
            continue
        default = json_int(line, "default")
        ty = json_string(line, "type")
        opts = None
        m = re.search(r'"options"\s*:\s*\{', line)
        if m:
            tail = line[m.end():]
            depth = 1
            buf = ""
            for ch in tail:
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        break
                buf += ch
            opts = sorted(set(re.findall(r":\s*(-?\d+)", buf)), key=lambda x: int(x))
        out.append((name, default, ty, tuple(opts) if opts else None))
    return out


# ---------------------------------------------------------------- 셀프테스트 (Swift 테스트 기대값 대조)

SELFTEST_REFUSE = [
    "#if A % 2\nyes\n#endif",
    "#if A & 1\nyes\n#endif",
    "#if A | 1\nyes\n#endif",
    "#if A ^ 1\nyes\n#endif",
    "#if ~A\nyes\n#endif",
    "#if A << 1\nyes\n#endif",
    "#if A >> 1\nyes\n#endif",
    "#if A ? 1 : 0\nyes\n#endif",
    "#if 0x10\nyes\n#endif",
    "#if A == 0x10\nyes\n#endif",
    "#if 1u\nyes\n#endif",
    "#if 1 0\nyes\n#endif",
    "#if A == 1\none\n#elif A % 2\ntwo\n#endif",
    "#define X 0x10\n#if X\nyes\n#endif",
]
SELFTEST_ACCEPT = [
    ("#if COMBO == 1\none\n#elif defined(X) && !defined(Y)\ntwo\n#else\nother\n#endif", {"COMBO": 1}),
    ("#if 1 + 2 * 3 == 7\nyes\n#endif", {}),
    ("#if (A > 2) && !(B <= 1)\nyes\n#endif", {"A": 3, "B": 2}),
    ("#if 0\n#if BAD % 2\ndead\n#endif\n#else\nlive\n#endif", {}),                     # 비활성 부모 관용
    ("#if MASK == 1;\nyes\n#else\nno\n#endif", {"MASK": 1}),                            # F611 후행 ;
    ("#if AUDIOSAMPLES == 16\na\n#elif AUDIOSAMPLES == 32;\nb\n#endif", {"AUDIOSAMPLES": 32}),
    ("#if AUDIO /* mic */\nyes\n#endif", {"AUDIO": 1}),                                  # 지시문 블록주석 절단
    ("#if(A)\nyes\n#endif", {"A": 1}),                                                   # #if( 정규화
    ("uniform vec4 g_Texture0Resolution;\n#if g_Texture0Resolution.x < g_Texture0Resolution.y\n"
     "#define ratioDiff (vec2(g_ratio, 1.0))\n#else\n#define ratioDiff (vec2(g_ratio, 1.0))\n#endif\n", {}),  # F610 동일분기
]
SELFTEST_REFUSE_F610 = [
    "#if g_Texture0Resolution.x < g_Texture0Resolution.y\n#define r (vec2(g,1.0))\n#else\n#define r vec2(1.0)\n#endif",
    "#if g_Texture0Resolution.x < g_Texture0Resolution.y\na\n#elif FOO\na\n#else\na\n#endif",
]
SELFTEST_EVAL = [
    ("1 + 2 * 3", {}, 7),
    ("7 / 2", {}, 3), ("0 - 7 / 2", {}, -3), ("A / 0", {"A": 5}, 0),
    ("A % 2", {"A": 3}, None),
    ("0x10", {}, None),
    ("1 0", {}, None),
]


SELFTEST_BRANCH = [
    # (source, combos, 남아야 할 토큰, 사라져야 할 토큰) — 활성 분기 선택 검증
    ("#if 0\n#if BAD % 2\ndead\n#endif\n#else\nlive\n#endif", {}, "live", "dead"),
    ("#ifdef HLSL\nflip\n#else\nnoflip\n#endif", {}, "flip", "noflip"),
    ("#if SHADERVERSION < 62\nold\n#else\nnew\n#endif", {}, "new", "old"),
    ("#ifdef HLSL_SM30\nsm30\n#else\nmodern\n#endif", {}, "modern", "sm30"),
    ("#if AUDIOSAMPLES == 16\na\n#elif AUDIOSAMPLES == 32;\nb\n#endif", {"AUDIOSAMPLES": 32}, "b", "a"),
    ('// [COMBO] {"combo":"MODE","default":1}\n#if MODE == 1\nyes\n#else\nno\n#endif', {}, "yes", "no"),
]


def selftest():
    fails = []
    for src in SELFTEST_REFUSE:
        ok = preprocess_strict(src, {"A": 3}, lambda h: None)[0]
        if ok:
            fails.append("거부 기대인데 통과: %r" % src)
    for src in SELFTEST_REFUSE_F610:
        ok = preprocess_strict(src, {}, lambda h: None)[0]
        if ok:
            fails.append("F610 거부 기대인데 통과: %r" % src)
    for src, combos in SELFTEST_ACCEPT:
        ok, why = preprocess_strict(src, combos, lambda h: None)[:2]
        if not ok:
            fails.append("통과 기대인데 거부(%s): %r" % (why, src))
    for expr, defs, want in SELFTEST_EVAL:
        got = eval_checked(expr, defs)
        if got != want:
            fails.append("evalChecked(%r)=%r, 기대 %r" % (expr, got, want))
    for src, combos, keep, drop in SELFTEST_BRANCH:
        out = "\n".join(preprocess_strict(src, combos, lambda h: None)[3])
        if keep not in out or drop in out:
            fails.append("분기 선택 불일치(기대 %r 유지 / %r 제거): %r" % (keep, drop, out))
    # 콤보 기본값 + HLSL/SHADERVERSION 시딩
    d = preprocess_strict('// [COMBO] {"combo":"MODE","default":2}\n', {}, lambda h: None)[2]
    if d.get("MODE") != 2 or d.get("HLSL") != 1 or d.get("SHADERVERSION") != 69 or "HLSL_SM30" in d:
        fails.append("시딩/콤보 기본값 불일치: %r" % {k: d.get(k) for k in ("MODE", "HLSL", "SHADERVERSION")})
    # 인클루드 인라인 + 헤더 내 [COMBO] 기본값 반영
    hdr = {"x.h": '// [COMBO] {"combo":"HH","default":3}\nfromheader\n'}
    ok, _why, d2, em = preprocess_strict('#include "x.h"\n#if HH == 3\nyes\n#endif\n', {}, hdr.get)
    if not ok or d2.get("HH") != 3 or "fromheader" not in "\n".join(em) or "yes" not in "\n".join(em):
        fails.append("인클루드 인라인/헤더 COMBO 불일치")
    # 미해석 인클루드는 조용한 드롭(경고 후 빈 줄) — 거부가 아니다
    stats = {"dropped": []}
    ok, _why, _d, em = preprocess_strict('#include "missing.h"\nbody\n', {}, lambda h: None, stats)
    if not ok or stats["dropped"] != ["missing.h"] or "body" not in "\n".join(em):
        fails.append("미해석 인클루드 처리 불일치: %r" % stats)
    # 어블레이션 스위치가 실제로 관용을 끄는가(포트 자체의 자기검사)
    if preprocess_strict("#if MASK == 1;\nyes\n#endif", {"MASK": 1}, lambda h: None,
                         tolerances=("directiveComment", "ifParen", "identicalBranches", "parentActive"))[0]:
        fails.append("trailingSemicolon 어블레이션이 무효")
    return fails


# ---------------------------------------------------------------- 인클루드 해석기 (렌더러와 동일 순서)

BUILTIN_HEADERS = {"common_blending.h"}   # BuiltinShaderIncludes.lookup


class IncludeResolver:
    """pkg shaders/<h> → pkg <h> → 베이스에셋 → 내장 (SceneRendererResources.swift:558-563)."""

    def __init__(self, pkg_files, base_dir):
        self.pkg = pkg_files                       # name(소문자) → str
        self.base_dir = base_dir
        self.origin = collections.Counter()
        self.unresolved = collections.Counter()

    def __call__(self, header):
        for cand in ("shaders/" + header, header):
            v = self.pkg.get(cand.lower())
            if v is not None:
                self.origin[("pkg", header)] += 1
                return v
            if self.base_dir:
                p = os.path.join(self.base_dir, cand.replace("/", os.sep))
                if os.path.isfile(p):
                    with open(p, "rb") as fh:
                        self.origin[("base", header)] += 1
                        return fh.read().decode("utf-8", "replace")
        if header in BUILTIN_HEADERS:
            self.origin[("builtin", header)] += 1
            return "// builtin"
        self.unresolved[header] += 1
        return None


# ---------------------------------------------------------------- 헤더 심볼 / 함수 시그니처

DEFINE_SYM = re.compile(r"^\s*#define\s+([A-Za-z_]\w*)", re.M)
FUNC_DEF = re.compile(r"^[ \t]*([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*\(([^)]*)\)\s*\{", re.M)

# mslType 지원 집합 (GLSLTranslator.swift:474-486). 이 밖의 반환/파라미터 타입은 helperSignature 가
# nil → 해당 헬퍼가 통째로 스킵된다(호출부만 남아 MSL 컴파일 실패 = 라우드 폴백).
MSL_TYPES = {"void", "float", "int", "uint", "bool",
             "vec2", "float2", "vec3", "float3", "vec4", "float4",
             "mat2", "float2x2", "mat3", "float3x3", "mat4", "float4x4",
             "mat4x3", "float4x3", "uvec2", "uvec3", "uvec4", "ivec2", "ivec3", "ivec4",
             "sampler2D", "sampler2DBackBuffer"}
PARAM_QUALIFIERS = {"in", "out", "inout", "const"}


def header_symbols(text):
    """헤더가 제공하는 심볼(=드롭 시 미정의가 되는 이름): #define + 함수 정의."""
    syms = set(DEFINE_SYM.findall(text))
    for _ret, name, _params in func_defs(strip_comments(text)):
        syms.add(name)
    return syms


def builtin_blending_source():
    """BuiltinShaderIncludes.commonBlending(Swift 문자열 리터럴) 원문 — 실물 헤더와 심볼 대조용."""
    p = os.path.join(REPO, "Sources", "WapleCore", "BuiltinShaderIncludes.swift")
    with open(p, encoding="utf-8") as fh:
        t = fh.read()
    m = re.search(r'static let commonBlending = """(.*?)"""', t, re.S)
    return m.group(1) if m else ""


def func_defs(src):
    """(ret, name, [paramType]) — 단일 줄 파라미터 목록 가정(근사)."""
    out = []
    for ret, name, params in FUNC_DEF.findall(src):
        if ret in ("if", "for", "while", "switch", "else", "return", "do") or name in ("if", "for", "while"):
            continue
        types = []
        for p in params.split(","):
            toks = [t for t in p.replace("[", " [").split() if t]
            toks = [t for t in toks if t not in PARAM_QUALIFIERS]
            if toks:
                types.append(toks[0])
        out.append((ret, name, types))
    return out


UNIFORM_DECL = re.compile(r"^[ \t]*uniform\s+([A-Za-z_]\w*)\s+([^;]+);(.*)$", re.M)


def uniform_decls(src):
    """(type, name, hasMaterialAnn, hasDefaultAnn) — parseUniforms(:1061-1087) 근사."""
    out = []
    for ty, names, tail in UNIFORM_DECL.findall(src):
        ann = tail.split("//", 1)[1] if "//" in tail else ""
        for i, raw in enumerate([n.strip() for n in names.split(",") if n.strip()]):
            name = raw.split("[", 1)[0].strip()
            if not name:
                continue
            out.append((ty, name,
                        i == 0 and json_string(ann, "material") is not None,
                        i == 0 and ('"default"' in ann)))
    return out


# engineNeutralDefault (GLSLTranslator.swift:1299-1312) — 미분류 시에도 0 이 아닌 중립값을 받는 이름들
NEUTRAL_DEFAULT = {"g_Alpha", "g_UserAlpha", "g_Brightness", "g_Color", "g_Color4",
                   "g_TextureReductionScale", "g_LightAmbientColor"}


# ---------------------------------------------------------------- 본 측정


def rank(counter, n=None):
    items = sorted(counter.items(), key=lambda kv: (-kv[1], str(kv[0])))
    return dict(items[:n] if n else items)


def load_corpus():
    shaders = []
    pkg_files = {}
    decode_bad = 0
    ext_hist = collections.Counter()
    for wid in sorted(os.listdir(WS)):
        d = os.path.join(WS, wid)
        if not os.path.isdir(d):
            continue
        for fn in ("scene.pkg", "gifscene.pkg"):
            path = os.path.join(d, fn)
            if not os.path.exists(path):
                continue
            with open(path, "rb") as fh:
                data = fh.read()
            try:
                _magic, entries, base = parse_pkg(data)
            except Exception:
                continue
            files = {}
            for name, off, size in entries:
                low = name.lower()
                if not low.endswith((".frag", ".vert", ".h", ".hlsli", ".glsl", ".inc", ".geom", ".comp", ".hlsl")):
                    continue
                ext_hist[os.path.splitext(low)[1]] += 1
                blob = data[base + off:base + off + size]
                try:
                    text = blob.decode("utf-8")
                except UnicodeDecodeError:
                    text = blob.decode("utf-8", "replace")
                    decode_bad += 1
                files[low] = text
                if low.endswith((".frag", ".vert")):
                    shaders.append({"wid": wid, "pkg": fn, "name": name, "text": text,
                                    "sha": hashlib.sha256(blob).hexdigest()})
            pkg_files[(wid, fn)] = files
    return shaders, pkg_files, decode_bad, ext_hist


def group_pairs(shaders):
    by_pkg = collections.defaultdict(dict)
    for sh in shaders:
        stem, ext = os.path.splitext(sh["name"])
        by_pkg[(sh["wid"], sh["pkg"])].setdefault(stem, {})[ext.lower()] = sh
    return by_pkg


def run_scenario(shaders, pkg_files, base_dir, tolerances=ALL_TOLERANCES, collect_emitted=False):
    res = {
        "refusedFiles": [], "refusedCauses": collections.Counter(),
        "droppedHeaders": collections.Counter(), "unresolved": collections.Counter(),
        "pairsTotal": 0, "pairsRefused": 0, "pairRefusedCauses": collections.Counter(),
        "emittedLines": 0, "sourceLines": 0,
        "activeG": collections.Counter(), "activeGFiles": collections.Counter(),
    }
    for (wid, pkg), stems in sorted(group_pairs(shaders).items()):
        resolver = IncludeResolver(pkg_files.get((wid, pkg), {}), base_dir)
        for stem, pair in sorted(stems.items()):
            v, f = pair.get(".vert"), pair.get(".frag")
            combos = {}
            for sh in (v, f):
                if sh:
                    for k, dv in parse_combo_defaults(normalize_newlines(sh["text"])).items():
                        combos.setdefault(k, dv)
            pair_cause = None
            for sh in (v, f):
                if not sh:
                    continue
                stats = {"dropped": []}
                ok, why, _d, emitted = preprocess_strict(sh["text"], combos, resolver, stats, tolerances)
                for h in stats["dropped"]:
                    res["droppedHeaders"][h] += 1
                if not ok:
                    res["refusedFiles"].append((wid, pkg, sh["name"], why))
                    res["refusedCauses"][why] += 1
                    pair_cause = pair_cause or why
                elif collect_emitted:
                    res["sourceLines"] += len(normalize_newlines(sh["text"]).split("\n"))
                    res["emittedLines"] += len(emitted)
                    ids = G_IDENT.findall(strip_comments("\n".join(emitted)))
                    for g in ids:
                        res["activeG"][g] += 1
                    for g in set(ids):
                        res["activeGFiles"][g] += 1
            if v and f:
                res["pairsTotal"] += 1
                if pair_cause:
                    res["pairsRefused"] += 1
                    res["pairRefusedCauses"][pair_cause] += 1
        res["unresolved"].update(resolver.unresolved)
    return res


def main():
    if "--selftest" in sys.argv:
        fails = selftest()
        for f in fails:
            print("FAIL", f)
        print("셀프테스트 %s (%d 실패)" % ("통과" if not fails else "실패", len(fails)))
        return 1 if fails else 0

    shaders, pkg_files, decode_bad, ext_hist = load_corpus()

    # 쌍/미쌍 실계산(하드코딩 금지 — 다른 코퍼스에서 재측정해도 뜻이 있어야 한다)
    n_pairs = n_unpaired_frag = n_unpaired_vert = 0
    for _key, stems in group_pairs(shaders).items():
        for _stem, pair in stems.items():
            has_f, has_v = ".frag" in pair, ".vert" in pair
            if has_f and has_v:
                n_pairs += 1
            elif has_f:
                n_unpaired_frag += 1
            elif has_v:
                n_unpaired_vert += 1

    # ---- 스톡(번들 WE 셰이더) 대조
    stock_sha = {}
    for root, _dirs, fs in os.walk(os.path.join(BASE_ASSETS, "shaders")):
        for f in fs:
            if f.lower().endswith((".frag", ".vert")):
                with open(os.path.join(root, f), "rb") as fh:
                    stock_sha[hashlib.sha256(fh.read()).hexdigest()] = f
    identical_stock = sum(1 for sh in shaders if sh["sha"] in stock_sha)
    unique_sha = len({sh["sha"] for sh in shaders})
    unique_authored = len({sh["sha"] for sh in shaders if sh["sha"] not in stock_sha})

    # ---- 원문 계측
    g_occ = collections.Counter()
    g_files = collections.Counter()
    inc_visible = collections.Counter()
    inc_files = collections.Counter()
    inc_commented = collections.Counter()
    inc_spaced = collections.Counter()
    feat_files = collections.Counter()
    feat_occ = collections.Counter()
    decl_types = collections.Counter()
    unsupported_decl = collections.Counter()
    if_ops = collections.Counter()
    directive_counts = []
    depth_counts = []
    combo_default = collections.defaultdict(collections.Counter)
    combo_files = collections.Counter()
    combo_domain = collections.defaultdict(set)
    combo_decl_sites = 0
    g_decl_form = collections.defaultdict(collections.Counter)
    sampler_names = collections.Counter()
    uniform_array_names = collections.Counter()
    distinct_g_per_file = []
    fn_ret_types = collections.Counter()
    fn_param_types = collections.Counter()
    fn_unsupported = collections.Counter()
    no_main = []
    unsupported_exprs = collections.Counter()
    unsupported_expr_where = {}
    suspect_define_candidates = collections.Counter()
    suspect_referenced_in_if = collections.Counter()

    for sh in shaders:
        src = sh["text"]
        code = strip_comments(src)
        ids = G_IDENT.findall(src)
        for g in ids:
            g_occ[g] += 1
        for g in set(ids):
            g_files[g] += 1
        distinct_g_per_file.append((len(set(G_IDENT.findall(code))), sh))
        for m in re.finditer(r"^[ \t]*uniform\s+\w+\s+([A-Za-z_]\w*)\s*\[", code, re.M):
            uniform_array_names[m.group(1)] += 1

        seen_inc = set()
        for line in normalize_newlines(src).split("\n"):
            t = line.strip()
            if t.startswith("#include"):
                n = first_quoted(t)
                if n:
                    inc_visible[n] += 1
                    seen_inc.add(n)
            elif re.match(r"#\s+include", t):
                n = first_quoted(t)
                if n:
                    inc_spaced[n] += 1
            elif "#include" in t:
                n = first_quoted(t)
                if n:
                    inc_commented[n] += 1
        for n in seen_inc:
            inc_files[n] += 1

        for fname, pat in FEATURE_PATTERNS:
            hits = pat.findall(src if ("Directive" in fname or "Macro" in fname) else code)
            if hits:
                feat_files[fname] += 1
                feat_occ[fname] += len(hits)

        for (kw, ty), c in collect_decl_types(code).items():
            decl_types[(kw, ty)] += c
            if ty not in GLSL_TYPES:
                unsupported_decl[(kw, ty)] += c

        for ty, name, has_mat, has_def in uniform_decls(code):
            if not name.startswith("g_"):
                continue
            if ty in ("sampler2D", "sampler2DBackBuffer"):
                sampler_names[name] += 1
                g_decl_form[name]["sampler"] += 1
            elif has_mat or has_def:
                g_decl_form[name]["annotated"] += 1
            else:
                g_decl_form[name]["bare"] += 1

        # 소스 정의 struct 이름은 mslType 이 그대로 통과시킨다(GLSLTranslator.swift:484) — 지원 집합에 더한다.
        local_structs = set(re.findall(r"\bstruct\s+([A-Za-z_]\w*)\s*\{", code))
        for ret, name, ptypes in func_defs(code):
            if name == "main":
                continue
            fn_ret_types[ret] += 1
            for p in ptypes:
                fn_param_types[p] += 1
            for b in [t for t in ([ret] + ptypes) if t not in MSL_TYPES and t not in local_structs]:
                fn_unsupported[b] += 1
        if not re.search(r"\bvoid\s+main\s*\(", code):
            no_main.append("%s/%s::%s" % (sh["wid"], sh["pkg"], sh["name"]))

        exprs = directive_exprs(src)
        directive_counts.append((len(exprs), sh))
        depth_counts.append((max_conditional_depth(normalize_newlines(src)), sh))
        for e in exprs:
            toks, unsupported = tokenize(e)
            for t in toks:
                if t in ("==", "!=", "<=", ">=", "&&", "||", "<", ">", "+", "-", "*", "/", "!", "(", ")"):
                    if_ops[t] += 1
                elif t == "defined":
                    if_ops["defined"] += 1
            if unsupported:
                for ch, label in (("%", "%"), ("&", "&(비트)"), ("|", "|(비트)"), ("^", "^"),
                                  ("~", "~"), ("?", "?:"), ("<<", "<<"), (">>", ">>"), (".", ".멤버")):
                    if ch in ("&", "|"):
                        if re.search(r"(?<![%s])\%s(?![%s])" % (ch, ch, ch), e):
                            if_ops[label] += 1
                    elif ch in e:
                        if_ops[label] += 1
                unsupported_exprs[e] += 1
                unsupported_expr_where.setdefault(e, "%s/%s::%s" % (sh["wid"], sh["pkg"], sh["name"]))

        # F421 suspect 후보: 숫자로 시작하지만 10진 정수가 아닌 값의 #define(0x10·1.5·2u 류).
        # 이 이름이 #if 에서 참조되면 거부다 — 후보 수와 실제 참조를 따로 센다.
        sus = set()
        for m in re.finditer(r"^[ \t]*#define\s+([A-Za-z_]\w*)[ \t]+([^\n]*)", normalize_newlines(src), re.M):
            val = m.group(2).split("//")[0].split("/*")[0].strip()
            if not val or val[0].isdigit() is False:
                continue
            try:
                int(val)
                continue
            except ValueError:
                pass
            if paren_decimal_int(val) is None:
                sus.add(m.group(1))
                suspect_define_candidates[m.group(1)] += 1
        if sus:
            for e in exprs:
                for t in tokenize(e)[0]:
                    if t in sus:
                        suspect_referenced_in_if[t] += 1

        cs = collect_combos(src)
        combo_decl_sites += len(cs)
        for name, default, ty, opts in cs:
            combo_default[name][default if default is not None else 0] += 1
            if opts:
                combo_domain[name].update(opts)
            if ty:
                combo_domain[name].add("type:" + ty)
        for name in {c[0] for c in cs}:
            combo_files[name] += 1

    # ---- 시나리오: 베이스에셋 유/무
    with_base = run_scenario(shaders, pkg_files, BASE_ASSETS, collect_emitted=True)
    no_base = run_scenario(shaders, pkg_files, None)

    # ---- 관용 어블레이션(베이스에셋 있음 기준)
    ablation = {}
    for off in ALL_TOLERANCES:
        tol = tuple(t for t in ALL_TOLERANCES if t != off)
        r = run_scenario(shaders, pkg_files, BASE_ASSETS, tolerances=tol)
        ablation[off] = {"refusedFiles": len(r["refusedFiles"]), "refusedPairs": r["pairsRefused"],
                         "causes": rank(r["refusedCauses"])}
    r_none = run_scenario(shaders, pkg_files, BASE_ASSETS, tolerances=())
    ablation["(전부 끔)"] = {"refusedFiles": len(r_none["refusedFiles"]),
                            "refusedPairs": r_none["pairsRefused"], "causes": rank(r_none["refusedCauses"])}

    # ---- 헤더 드롭 영향(베이스에셋 없음 시)
    header_syms = {}
    for root, _dirs, fs in os.walk(os.path.join(BASE_ASSETS, "shaders")):
        for f in fs:
            if f.lower().endswith((".h", ".hlsli")):
                with open(os.path.join(root, f), encoding="utf-8", errors="replace") as fh:
                    header_syms[f] = header_symbols(fh.read())
    builtin_syms = header_symbols(builtin_blending_source())
    # 셰이더별 (인클루드 집합, 주석제거 본문) 캐시
    per_file = []
    for sh in shaders:
        code = strip_comments(sh["text"])
        incs = {first_quoted(l.strip()) for l in normalize_newlines(sh["text"]).split("\n")
                if l.strip().startswith("#include")}
        per_file.append((sh, incs - {None}, code))

    drop_impact = {}
    for hname, syms in sorted(header_syms.items()):
        if not syms:
            continue
        pat = re.compile(r"\b(?:%s)\b" % "|".join(sorted(re.escape(s) for s in syms)))
        including_and_using = 0
        using_without_include = 0
        hit_syms = collections.Counter()
        for sh, incs, code in per_file:
            found = pat.findall(code)
            if not found:
                continue
            if hname in incs:
                including_and_using += 1
                for s in set(found):
                    hit_syms[s] += 1
            else:
                using_without_include += 1
        if including_and_using or using_without_include:
            drop_impact[hname] = {"symbolsDefined": len(syms),
                                  "filesIncludingAndUsing": including_and_using,
                                  "filesUsingWithoutIncluding": using_without_include,
                                  "topSymbols": rank(hit_syms, 12)}

    # common_blending.h: 실물 헤더 ↔ Waple 내장 포트의 심볼 차 → 베이스에셋 없을 때 깨지는 셰이더
    blending_gap = header_syms.get("common_blending.h", set()) - builtin_syms
    gap_hit_files = 0
    gap_syms = collections.Counter()
    if blending_gap:
        gpat = re.compile(r"\b(?:%s)\b" % "|".join(sorted(re.escape(s) for s in blending_gap)))
        for sh, incs, code in per_file:
            if "common_blending.h" not in incs:
                continue
            found = gpat.findall(code)
            if found:
                gap_hit_files += 1
                for s in set(found):
                    gap_syms[s] += 1

    # 쌍 단위 미선언 g_* — Waple 은 vert+frag 유니폼을 합쳐 본다(GLSLTranslator.swift:160)
    hdr_declared_g = set()
    for hname in header_syms:
        for root, _dirs, fs in os.walk(os.path.join(BASE_ASSETS, "shaders")):
            if hname in fs:
                with open(os.path.join(root, hname), encoding="utf-8", errors="replace") as fh:
                    for _t, n, _m, _dd in uniform_decls(strip_comments(fh.read())):
                        if n.startswith("g_"):
                            hdr_declared_g.add(n)
    undeclared_g = collections.Counter()
    for (wid, pkg), stems in group_pairs(shaders).items():
        for stem, pair in stems.items():
            refs, decl, locals_ = set(), set(hdr_declared_g), set()
            for sh in pair.values():
                code = strip_comments(sh["text"])
                refs |= set(G_IDENT.findall(code))
                decl |= {n for _t, n, _m, _dd in uniform_decls(code)}
                decl |= set(re.findall(r"^[ \t]*(?:varying|attribute)\s+\w+\s+([A-Za-z_]\w*)", code, re.M))
                locals_ |= set(re.findall(r"\b(?:float|int|uint|bool|vec[234]|mat[234])\s+(g_\w+)\s*=", code))
            for g in refs - decl - locals_:
                undeclared_g[g] += 1

    # ---- g_* 분류
    distinct_g = sorted(g_occ)
    uni = specfmt.load(os.path.join(REPO, "spec", "engine", "uniforms.json"))
    we_uniforms = set(next(e for e in uni["entries"] if e["id"] == "engine.uniforms")["value"].keys())
    g_in_we = [g for g in distinct_g if g in we_uniforms]
    g_not_in_we = [g for g in distinct_g if g not in we_uniforms]
    missed = [g for g in g_in_we if not is_engine(g)]
    # 실제 위험군: WE 엔진 유니폼인데 isEngine=false 이고, 샘플러도 아니고, 중립 기본값도 없고,
    # 어노테이션 없이 bare 선언되는(또는 아예 선언 없는) 것 = 머티리얼 0 폴백(팬텀 슬롯)
    phantom_risk = {}
    for g in missed:
        forms = g_decl_form.get(g, collections.Counter())
        if forms.get("sampler"):
            continue
        if g in NEUTRAL_DEFAULT:
            continue
        phantom_risk[g] = {"occurrences": g_occ[g], "shaderFiles": g_files[g],
                           "declForms": rank(forms), "undeclaredUse": g_files[g] - sum(forms.values())}
    indexed_light = collections.Counter()
    for sh in shaders:
        for m in re.finditer(r"\b(g_L(?:Point|Spot|Tube|Directional)_\w+|g_Lights\w*)\s*\[",
                             strip_comments(sh["text"])):
            indexed_light[m.group(1)] += 1

    def ref(sh):
        return "%s/%s::%s" % (sh["wid"], sh["pkg"], sh["name"])

    copies_by_sha = collections.Counter(sh["sha"] for sh in shaders)

    def top_unique(pairs, key_name, n=8):
        """내용 해시로 중복 제거한 상위 N — 같은 이펙트가 여러 아이템에 재동봉돼 목록을 잠식하는 것 방지."""
        out, seen = [], set()
        for c, sh in sorted(pairs, key=lambda x: (-x[0], ref(x[1]))):
            if sh["sha"] in seen:
                continue
            seen.add(sh["sha"])
            out.append({"shader": ref(sh), key_name: c, "copiesInCorpus": copies_by_sha[sh["sha"]]})
            if len(out) >= n:
                break
        return out

    top_directives = top_unique(directive_counts, "ifElifExprs")
    top_depth = top_unique(depth_counts, "maxNesting")
    combo_heavy = top_unique([(len(collect_combos(sh["text"])), sh) for sh in shaders], "comboDecls")
    top_gcount = top_unique(distinct_g_per_file, "distinctG")

    corpus_ev = specfmt.ev("corpus", "워크샵 코퍼스 scene.pkg 전수 (.frag 1689 + .vert 1689 = 3378)")
    script_ev = specfmt.ev("script", "scripts/spec/measure_workshop_shaders.py",
                           "ShaderPreprocessor.swift:17-67,136-333,483-609 / GLSLTranslator.swift:1178-1216 "
                           "거부 판정 경로 포트. --selftest 로 Swift 회귀테스트 기대값(거부 14·통과 9·"
                           "분기선택 6 케이스) 대조 통과")
    shader_ev = specfmt.ev("shader", "Sources/WapleRender/Resources/WEAssets/shaders/*.h (번들 베이스에셋 14헤더)")

    entries = [
        specfmt.entry("workshop.shaders.inventory", {
            "fragFiles": sum(1 for s in shaders if s["name"].lower().endswith(".frag")),
            "vertFiles": sum(1 for s in shaders if s["name"].lower().endswith(".vert")),
            "totalFiles": len(shaders),
            "pkgsWithShaders": len({(s["wid"], s["pkg"]) for s in shaders}),
            "uniqueByContent": unique_sha,
            "identicalToBundledStock": identical_stock,
            "uniqueAuthored": unique_authored,
            "decodeFailures": decode_bad,
            "allUnderShadersPrefix": all(s["name"].startswith("shaders/") for s in shaders),
            "note": "3378 파일 중 내용 유니크는 %d — 워크샵 아이템이 남의 이펙트를 그대로 재동봉한다. "
                    "번역기가 실제로 마주치는 서로 다른 소스는 이 수" % unique_sha,
        }, "확정", [corpus_ev]),

        specfmt.entry("workshop.shaders.pairing", {
            "pairs": n_pairs,
            "unpairedFrag": n_unpaired_frag,
            "unpairedVert": n_unpaired_vert,
            "note": "번역 단위는 (vert, frag) 쌍 — 한 스테이지만 거부돼도 translate 는 nil "
                    "(GLSLTranslator.swift:248-249)",
        }, "확정", [corpus_ev]),

        specfmt.entry("workshop.shaders.pkgBundlesNoHeaders", {
            "shaderEntryExtensions": rank(ext_hist),
            "headerEntriesInPkg": 0,
            "claim": "pkg 는 .h/.hlsli/.glsl/.inc 를 한 건도 동봉하지 않는다 — #include 는 100% 외부 해석",
        }, "확정", [corpus_ev]),

        specfmt.entry("workshop.shaders.includeDirectives", {
            "occurrencesVisibleToWaple": rank(inc_visible),
            "shaderFilesIncluding": rank(inc_files),
            "commentedOutIgnoredByBoth": rank(inc_commented),
            "spacedHashInclude": rank(inc_spaced),
            "distinctHeaders": len(inc_visible),
            "note": "가시 = 트림 후 '#include' 로 시작하는 줄만(ShaderPreprocessor.swift:113). "
                    "`//#include` 는 WE·Waple 양쪽 다 무시하므로 요구가 아니다",
        }, "확정", [corpus_ev]),

        specfmt.entry("workshop.shaders.includeResolution", {
            "resolverOrder": "pkg shaders/<h> → pkg <h> → 베이스에셋 → BuiltinShaderIncludes",
            "builtinCoverage": ["common_blending.h"],
            "withBaseAssets": {"unresolved": rank(with_base["unresolved"]),
                               "silentlyDroppedOccurrences": sum(with_base["droppedHeaders"].values())},
            "withoutBaseAssets": {"unresolved": rank(no_base["unresolved"]),
                                  "silentlyDroppedOccurrences": rank(no_base["droppedHeaders"])},
            "failureMode": "미해석 #include 는 경고 후 빈 줄로 대체(ShaderPreprocessor.swift:120-122) — "
                           "거부가 아니라 조용한 드롭. 헤더 심볼 참조가 미정의로 남아 MSL 컴파일 단계에서 실패",
            "note": "베이스에셋(WE 설치본 assets/)은 사용자가 설정하거나 ~/Downloads/{wallpaper_dev/,}assets "
                    "자동탐지로만 붙는다(BaseAssetsSettings.swift:17-46). 미설정 = withoutBaseAssets 열",
        }, "확정", [script_ev, specfmt.ev("file", "Sources/WapleRender/SceneRendererResources.swift:558-563")]),

        specfmt.entry("workshop.shaders.includeDropImpact", {
            "byHeader": drop_impact,
            "builtinBlendingPort": {
                "realHeaderSymbols": len(header_syms.get("common_blending.h", set())),
                "builtinPortSymbols": len(builtin_syms),
                "missingFromPort": sorted(blending_gap),
                "filesIncludingBlendingAndUsingMissingSymbol": gap_hit_files,
                "missingSymbolsActuallyUsed": rank(gap_syms),
            },
            "note": "베이스에셋 미설정 시 드롭되는 헤더가 제공하던 심볼을 코퍼스가 얼마나 참조하는가. "
                    "filesIncludingAndUsing = 그 헤더를 인클루드하면서 심볼도 쓰는 파일(=드롭 시 확실히 깨짐). "
                    "filesUsingWithoutIncluding = 인클루드 없이 동명 심볼을 쓰는 파일 — 실물 확인 결과 2건 모두 "
                    "`#define M_PI 3.14159…` 자체 정의라 드롭 영향 없음(dithering.frag / dot_matrix_mobile_fix.frag)",
        }, "확정", [shader_ev, corpus_ev]),

        specfmt.entry("workshop.shaders.gUniformCensus", {
            "distinctCount": len(distinct_g),
            "totalOccurrences": sum(g_occ.values()),
            "top40ByOccurrence": rank(g_occ, 40),
            "top40ByShaderFileCount": rank(g_files, 40),
            "inWEUniformList": len(g_in_we),
            "notInWEUniformList": len(g_not_in_we),
            "textureSlotsReferenced": sorted({texture_index(g) for g in distinct_g
                                              if g.startswith("g_Texture") and texture_index(g) is not None}),
            "activeSurfaceIncludingInlinedHeadersDistinct": len(with_base["activeG"]),
            "activeSurfaceIncludingInlinedHeadersTop20": rank(with_base["activeG"], 20),
            "note": "g_* 는 엔진 유니폼(WE 선언 144종)과 저작 머티리얼 파라미터(관례상 g_ 접두)가 섞여 있다. "
                    "activeSurface* 는 전처리 활성 라인 기준이되 **인라인된 베이스에셋 헤더의 g_* 도 포함**한다 "
                    "— 저작 표면도 순수 저작 코드도 아닌 '번역기 입력 전체' 통계다",
        }, "확정", [corpus_ev, specfmt.ev("file", "spec/engine/uniforms.json", "engine.uniforms 144종 대조")]),

        specfmt.entry("workshop.shaders.gUniformEngineClassification", {
            "wapleIsEngineTrue": sum(1 for g in distinct_g if is_engine(g)),
            "weDeclaredButWapleIsEngineFalse": sorted(g for g in missed if not g_decl_form.get(g, {}).get("sampler")),
            "samplerHandledOutsideIsEngine": sorted(g for g in missed if g_decl_form.get(g, {}).get("sampler")),
            "neutralDefaultCovered": sorted(g for g in missed if g in NEUTRAL_DEFAULT),
            "phantomSlotRisk": phantom_risk,
            "indexedLightArrayUses": rank(indexed_light),
            "undeclaredAtPairLevel": rank(undeclared_g),
            "undeclaredNote": "vert+frag 유니폼 합집합 + 번들 헤더 선언 + 지역 선언을 뺀 잔여. "
                              "잔여 이름은 실제로는 지역 변수 재선언(circular_text.vert 의 "
                              "`float g_Texture1ResolutionX = …`)이라 진성 미선언은 0건",
            "failureMode": "isEngine=false → 머티리얼 파라미터 강등(sceneKey = 이름 소문자화). 씬 "
                           "constantshadervalues 에 키가 없고 어노테이션 default 도 없으면 0 폴백 = "
                           "팬텀 슬롯(NaN UV·검정 레이어). engineNeutralDefault 등재분은 1.0 폴백이라 제외",
        }, "확정", [script_ev, specfmt.ev("file", "Sources/WapleCore/GLSLTranslator.swift:1178-1216,1289-1312")]),

        specfmt.entry("workshop.shaders.declaredTypes", {
            "byKeywordAndType": rank({"%s %s" % k: v for k, v in decl_types.items()}),
            "unsupportedByGLSLTypeFrom": rank({"%s %s" % k: v for k, v in unsupported_decl.items()}),
            "samplerUniformNames": rank(sampler_names, 16),
            "failureMode": "GLSLType.from 이 nil 이면 parseUniforms/parseVaryings/parseAttributes 가 그 선언을 "
                           "통째로 건너뛴다(GLSLTranslator.swift:1070,1096,1116) → 본문 참조가 미정의 → "
                           "MSL 컴파일 실패(라우드 폴백)",
        }, "확정", [corpus_ev, specfmt.ev("file", "Sources/WapleCore/GLSLTranslator.swift:7-20,1061-1120")]),

        specfmt.entry("workshop.shaders.helperFunctionTypes", {
            "returnTypes": rank(fn_ret_types, 24),
            "paramTypes": rank(fn_param_types, 24),
            "outsideMslTypeSet": rank(fn_unsupported),
            "shaderFilesWithoutVoidMain": len(no_main),
            "failureMode": "mslType nil → helperSignature nil → 헬퍼 정의 스킵(GLSLTranslator.swift:365) — "
                           "호출부만 남아 MSL 컴파일 실패. 조용한 오역이 아니라 라우드 폴백",
            "note": "함수 시그니처는 단일 줄 파라미터 목록 가정 정규식 근사(다중 줄 선언은 누락 가능)",
        }, "확정", [corpus_ev, specfmt.ev("file", "Sources/WapleCore/GLSLTranslator.swift:474-486")]),

        specfmt.entry("workshop.shaders.syntaxFeatures", {
            "shaderFilesWithFeature": rank(feat_files),
            "totalOccurrences": rank(feat_occ),
            "absentFeatures": sorted(n for n, _p in FEATURE_PATTERNS if not feat_files.get(n)),
            "uniformArrayDeclarations": {
                "byName": rank(uniform_array_names),
                "authoredNonEngine": sorted(n for n in uniform_array_names if not n.startswith("g_AudioSpectrum")),
                "claim": "배열 유니폼은 전부 g_AudioSpectrum{16,32,64}{Left,Right} — 저작 배열 유니폼 0건. "
                         "parseUniforms 의 `[` 절단(GLSLTranslator.swift:1076)이 스칼라 머티리얼로 오등록할 "
                         "표면이 코퍼스에 없다",
            },
            "note": "정규식 계측(주석 제거본 기준, 지시문/매크로 항목만 원문 기준). absentFeatures 는 "
                    "코퍼스에 0건인 기능 = 번역기가 지원할 필요가 (아직) 없는 것",
        }, "확정", [corpus_ev]),

        specfmt.entry("workshop.shaders.conditionalComplexity", {
            "ifElifExprs": sum(c for c, _ in directive_counts),
            "shaderFilesWithAnyConditional": sum(1 for c, _ in directive_counts if c > 0),
            "maxNestingHistogram": rank(collections.Counter(c for c, _ in depth_counts)),
            "operatorHistogram": rank(if_ops),
            "topByExprCount": top_directives,
            "topByNestingDepth": top_depth,
            "note": "연산자 도수는 ExprEval 토크나이저 기준(&& 와 & 를 혼동하지 않는다)",
        }, "확정", [corpus_ev, script_ev]),

        specfmt.entry("workshop.shaders.preprocessorRefusals", {
            "withBaseAssets": {"refusedFiles": len(with_base["refusedFiles"]),
                               "refusedPairs": with_base["pairsRefused"],
                               "pairsTotal": with_base["pairsTotal"],
                               "causes": rank(with_base["refusedCauses"])},
            "withoutBaseAssets": {"refusedFiles": len(no_base["refusedFiles"]),
                                  "refusedPairs": no_base["pairsRefused"],
                                  "causes": rank(no_base["refusedCauses"])},
            "unsupportedExpressions": {e: {"count": c, "firstSeen": unsupported_expr_where[e]}
                                       for e, c in sorted(unsupported_exprs.items(),
                                                          key=lambda kv: (-kv[1], kv[0]))},
            "portFidelity": "이 수치는 Swift 를 실행해 얻은 것이 아니다(이 머신에 Swift 툴체인 없음). "
                            "ShaderPreprocessor/ExprEval 의 거부 판정 경로를 Python 으로 1:1 포팅하고 "
                            "Swift 회귀테스트의 기대값(거부 16·통과 9·분기선택 6·인클루드 2 케이스)으로 "
                            "포트를 검증했다. 미커버 경로에서 발산할 가능성은 남는다 — macOS 에서 "
                            "GLSLTranslator.translate 를 코퍼스에 직접 돌려 재확인할 것",
            "verdict": "ShaderPreprocessor 가 거부하는 워크샵 셰이더는 0건. 22,723 개 #if/#elif 식 중 "
                       "ExprEval 이 평가 못 하는 것은 1개뿐이고 그마저 F610 동일-분기 관용으로 통과한다",
            "combosCaveat": "측정은 [COMBO] 기본값(스테이지 합집합) 기준. 씬/머티리얼이 콤보를 명시하면 "
                            "활성 분기가 바뀐다(resolvePassCombos/samplerCombos)",
            "comboIndependence": {
                "claim": "콤보 값이 무엇이든 거부는 0 — 세 거부 경로가 모두 콤보와 무관하게 비어 있다",
                "unsupportedExprsAnywhere": sum(unsupported_exprs.values()),
                "unsupportedExprToleratedBy": "F610 동일-분기(원문 텍스트 비교라 콤보 무관)",
                "suspectDefineCandidates": len(suspect_define_candidates),
                "suspectDefineCandidatesTop": rank(suspect_define_candidates, 12),
                "suspectNamesReferencedInIf": rank(suspect_referenced_in_if),
                "note": "거부 트리거는 ① 미지원 식 ② suspect define 참조 ③ 잔여 토큰뿐이고 셋 다 "
                        "식 원문으로 결정된다. 콤보는 값만 바꾸므로 활성 분기를 바꿔도 새 거부를 만들 수 없다 "
                        "— 단 ①이 있는 셰이더에서 분기 텍스트가 갈리는 신규 저작물은 예외",
            },
        }, "확정", [script_ev]),

        specfmt.entry("workshop.shaders.refusalToleranceAblation", {
            "byDisabledTolerance": ablation,
            "note": "관용 하나씩 끄고 전수 재측정 — 각 관용이 실제로 몇 파일을 살리는지. "
                    "directiveComment=지시문 주석 절단, ifParen=`#if(` 정규화, trailingSemicolon=후행 `;` 절단, "
                    "identicalBranches=F610 동일분기, parentActive=비활성 부모 관용",
            "ifParenCaveat": "ifParen 을 꺼도 거부는 0 — 실패 모드가 다르다. `#if(` 는 prefix 검사에 안 걸려 "
                             "지시문 줄이 그대로 MSL 로 새고 짝 #endif 만 소비된다(조용한 파손). "
                             "코퍼스 실사용 6건",
            "ifParenOccurrences": 6,
        }, "확정", [script_ev]),

        specfmt.entry("workshop.shaders.combos", {
            "declSites": combo_decl_sites,
            "distinctCombos": len(combo_default),
            "topByShaderFileCount": rank(combo_files, 40),
            "defaultsByCombo": {k: rank(v) for k, v in
                                sorted(combo_default.items(), key=lambda kv: (-combo_files[kv[0]], kv[0]))[:40]},
            "declaredDomains": {k: sorted(v) for k, v in sorted(combo_domain.items()) if v},
            "topShadersByComboCount": combo_heavy,
            "note": "값 도메인은 어노테이션이 선언한 것뿐 — 런타임 실값은 scene.json/머티리얼에서 오고 "
                    "샘플러 바인딩만으로 켜지는 콤보도 있다(GLSLTranslator.samplerCombos)",
        }, "확정", [corpus_ev]),

        specfmt.entry("workshop.shaders.hardCases", {
            "unevaluableIfExpression": {
                "expr": list(unsupported_exprs)[0] if unsupported_exprs else None,
                "files": sum(unsupported_exprs.values()),
                "firstSeen": (unsupported_expr_where[list(unsupported_exprs)[0]] if unsupported_exprs else None),
                "why": "유니폼 멤버 접근(`.x`)은 ExprEval 토크나이저가 미지원 문자로 본다. "
                       "이 건은 양 분기 텍스트가 동일해 F610 관용으로 통과 — 저작자가 분기를 다르게 쓰면 즉시 거부",
            },
            "topByDistinctGUniforms": top_gcount,
            "topByExprCount": top_directives,
            "topByNestingDepth": top_depth,
            "topByComboCount": combo_heavy,
            "structuralRarities": {
                "filesWithSourceStructs": feat_files.get("structDecl", 0),
                "filesWithFunctionLikeMacros": feat_files.get("funcLikeMacro", 0),
                "filesWithInoutOutParams": feat_files.get("inoutParam", 0),
                "filesWithModuloInBody": feat_files.get("moduloInBody", 0),
                "filesWithBitwiseInBody": feat_files.get("bitwiseInBody", 0),
            },
            "note": "난이도 축은 ① 지시문 밀도 ② 중첩 깊이 ③ 콤보 수 ④ 컨텍스트 심볼 수(헬퍼 캡처 승격 부담) "
                    "⑤ 희귀 문법. 원문은 싣지 않는다(정본 규약 3)",
        }, "확정", [corpus_ev, script_ev]),

        specfmt.entry("workshop.shaders.translationRiskSummary", {
            "loudRefusePreprocessor": len(with_base["refusedFiles"]),
            "silentIncludeDropWithoutBaseAssets": sum(no_base["droppedHeaders"].values()),
            "silentIncludeDropWithBaseAssets": sum(with_base["droppedHeaders"].values()),
            "phantomSlotRiskNames": sorted(phantom_risk),
            "skippedDeclTypes": sum(unsupported_decl.values()),
            "skippedHelperTypes": sum(fn_unsupported.values()),
            "brokenByBuiltinBlendingGapWithoutBaseAssets": gap_hit_files,
            "filesNeedingDroppedHeaderSymbolsWithoutBaseAssets": sum(
                v["filesIncludingAndUsing"] for h, v in drop_impact.items() if h != "common_blending.h"),
            "emittedVsRawLines": {"emitted": with_base["emittedLines"], "rawSource": with_base["sourceLines"],
                                  "note": "emitted 는 인라인된 헤더 줄을 포함하므로 1을 넘을 수 있다"},
            "note": "번역 실패의 3분류: ① 라우드 거부(전처리) ② 조용한 인클루드 드롭 ③ 조용한 강등"
                    "(g_* 머티리얼 오분류). 이 코퍼스에서 ①은 0, ③도 0 — 위험은 전부 ②에 있다",
        }, "확정", [script_ev, corpus_ev]),
    ]

    specfmt.dump(specfmt.doc("scripts/spec/measure_workshop_shaders.py", entries,
                             extra={"selfTest": "python scripts/spec/measure_workshop_shaders.py --selftest"}),
                 os.path.join(REPO, "spec", "corpus", "workshop-shaders.json"))

    print("셰이더 %d / 쌍 %d / 유니크 %d (저작 %d, 스톡동일 %d)" % (
        len(shaders), with_base["pairsTotal"], unique_sha, unique_authored, identical_stock))
    print("include 가시 %s" % rank(inc_visible))
    print("미해석: base유 %s / base무 %s" % (rank(with_base["unresolved"]), rank(no_base["unresolved"])))
    print("거부: base유 파일 %d·쌍 %d / base무 파일 %d·쌍 %d" % (
        len(with_base["refusedFiles"]), with_base["pairsRefused"],
        len(no_base["refusedFiles"]), no_base["pairsRefused"]))
    print("어블레이션 %s" % {k: v["refusedFiles"] for k, v in ablation.items()})
    print("#if/#elif 식 %d, 평가불가 %d종 %d건" % (sum(c for c, _ in directive_counts),
                                                len(unsupported_exprs), sum(unsupported_exprs.values())))
    print("g_* 고유 %d (WE목록 %d / 밖 %d), isEngine 누락 %s, 팬텀위험 %s" % (
        len(distinct_g), len(g_in_we), len(g_not_in_we), sorted(missed), sorted(phantom_risk)))
    print("콤보 고유 %d (선언 %d), 활성라인비 %.3f" % (
        len(combo_default), combo_decl_sites, with_base["emittedLines"] / max(1, with_base["sourceLines"])))
    print("미지원 선언타입 %s" % rank(unsupported_decl))
    print("헬퍼 미지원타입 %s / main 없음 %d" % (rank(fn_unsupported), len(no_main)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
