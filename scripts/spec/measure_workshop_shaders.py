"""워크샵 저작 셰이더(.frag/.vert) 전수 조사 → spec/corpus/workshop-shaders.json.

무엇을 재는가
  1) 참조 g_* 유니폼 전수·도수
  2) #include 헤더 전수·도수 + 해석처(pkg / 베이스에셋 / 내장 / 미해석)
  3) GLSL 문법 기능 도수(구조체·배열·함수형 매크로·#if 복잡도 …)
  4) Waple 의 ShaderPreprocessor 가 **실제로** 거부하는 건수
  5) [COMBO] 선언 전수와 값 도메인
  6) 난이도 상위 사례

왜 포트인가
  최초 작성(2026-08-01) 머신에는 Swift 툴체인이 없어 거부 판정 경로
  (ShaderPreprocessor.preprocessStrict + ExprEval.evalChecked)를 Python 으로 옮겼다. 현재 머신에는
  Xcode/Swift가 있지만, 워크샵 PKG 전수 측정을 독립 실행할 수 있게 이 포트를 유지한다.

  `--selftest` 는 **Swift 를 실행하지 않는다**. Swift 소스의 연산자 집합과 XCTest의 단일행 리터럴
  기대값을 정적으로 수확해 Python 결과와 맞추고, 수확 불가 케이스는 이 파일의 고정 기대값과 맞춘다.
  따라서 이것은 소스 드리프트 감시자이지 Python↔Swift 직접 differential 검증이 아니다. 프로덕션
  동작은 아래 Swift 테스트를 별도로 실행해야 하며, 코퍼스 전체를 Swift에 직접 넣은 대조는 아직 없다.
  포트 대상은 "거부하는가"까지이며 매크로 확장/본문 방출은 포팅하지 않는다.

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

# **[G2/BK 2026-08-30 이식]** 종전 이 두 집합은 pre-G2 판본이었다 — `SINGLE_OPS` 가
# `% & | ^ ~` 를 빠뜨리고 시프트를 명시 거부했다. HEAD 의 Swift 는 그 전부를 **평가한다**
# (`ShaderPreprocessor.swift:914` 의 two 집합 · `:922` 의 `"()!*/%+-<>&|^~"`).
# 두 집합은 이제 `selftest_operator_sets()` 가 그 두 줄을 파싱해 대조한다 —
# Swift 쪽이 넓어지면 이 파일을 안 고치는 한 셀프테스트가 빨개진다.
TWO_CHAR_OPS = {"==", "!=", "<=", ">=", "&&", "||", "<<", ">>"}
SINGLE_OPS = set("()!*/%+-<>&|^~")
NUMERIC_SUFFIXES = "uUfFlL"        # 실물 접미 집합(ShaderPreprocessor.swift:891 `"uUfFlL"`)

INT32_MIN = -(2 ** 31)
INT32_MAX = 2 ** 31 - 1


def _w32(v):
    """실물이 32비트(`eax`/`esi`)로 도는 자리의 폭 맞춤 — Swift `w32`/`wide` 쌍과 같다."""
    v &= (2 ** 32 - 1)
    return v - 2 ** 32 if v > INT32_MAX else v


def _ascii_digit(c, radix):
    """실물은 `isdigit`/`isxdigit`(ASCII)로 판정한다 — 유니코드 숫자는 배제(Swift:869-872)."""
    if not c.isascii():
        return None
    try:
        v = int(c, 16)
    except ValueError:
        return None
    return v if v < radix else None


def we_numeric_literal(s, start):
    """ExprEval.weNumericLiteral 포트(ShaderPreprocessor.swift:865-897) — (값, 다음 인덱스) 또는 None.

    · `0x`/`0X` 접두 → 16진 누적, 그 밖엔 10진 누적. 둘 다 **32비트 랩**(`0xFFFFFFFF` = -1).
    · 정수부 뒤 `.` 은 **무조건 소비**하고 이어지는 숫자도 소비하되 값에는 안 넣는다
      (`#if 1.5` = 1 · `#if 1.` = 1 · 16진도 같은 합류점이라 `#if 0x10.5` = 16).
    · 이어서 `u`/`f`/`l`(대소문자 무관) 접미를 여러 개 소비한다.
    · `1e5` 는 여기서 수 `1` 로 끊기고 `e5` 가 식별자 토큰이 된다 → **잔여 토큰**으로 거부된다
      (종전의 명시 거부와 결말 동일).
    """
    n = len(s)
    i = start
    if i >= n or _ascii_digit(s[i], 10) is None:
        return None
    acc = 0
    if s[i] == "0" and i + 1 < n and s[i + 1] in "xX":
        i += 2
        while i < n:
            d = _ascii_digit(s[i], 16)
            if d is None:
                break
            acc = _w32(acc * 16 + d)
            i += 1
    else:
        while i < n:
            d = _ascii_digit(s[i], 10)
            if d is None:
                break
            acc = _w32(acc * 10 + d)
            i += 1
    if i < n and s[i] == ".":
        i += 1
        while i < n and _ascii_digit(s[i], 10) is not None:
            i += 1
    while i < n and s[i] in NUMERIC_SUFFIXES:
        i += 1
    return acc, i


def numeric_literal(s):
    """ExprEval.numericLiteral — 문자열 **전체**가 하나의 WE 수치 리터럴일 때 그 값."""
    v = s.strip()
    r = we_numeric_literal(v, 0)
    if r is None or r[1] != len(v):
        return None
    return r[0]


def tokenize(s):
    """ExprEval.tokenize 포트(ShaderPreprocessor.swift:903-940) — (tokens, unsupported, badChars).

    `badChars` 는 렉서가 모른 문자 목록(실물 토큰 코드 0x19) — `classify_refusal` 이 이걸로
    사유를 가른다. 종전에는 식 원문을 정규식으로 되짚어 분류했는데, 그 정규식이 렉서와
    따로 낡아 `%`/시프트/16진을 계속 거부 사유로 적고 있었다.
    """
    toks = []
    i = 0
    n = len(s)
    bad = []
    while i < n:
        c = s[i]
        if c.isspace():
            i += 1
            continue
        # 2글자 토큰을 1글자보다 먼저 — `<<` 가 `<`+`<` 로 쪼개지면 `A << 2` 가 `A < 0` 로 오평가된다.
        if i + 1 < n and s[i:i + 2] in TWO_CHAR_OPS:
            toks.append(s[i:i + 2])
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
            r = we_numeric_literal(s, i)
            if r is None:
                bad.append(c)
                i += 1
                continue
            toks.append(str(r[0]))
            i = r[1]
            continue
        # 렉서가 모르는 문자(`? : @ ; .` 등). 수 리터럴 안의 `.` 는 위에서 이미 소비됐으므로
        # 여기 오는 `.` 는 수 밖의 것뿐이다(= 멤버 접근).
        bad.append(c)
        i += 1
    return toks, bool(bad), bad


MAX_DEPTH = 256
# 재귀 하강 파서는 괄호 한 겹마다 Python 프레임을 여러 개 쓴다. CPython 기본 한도(보통
# 1000)를 그대로 두면 깊이 약 120에서 MAX_DEPTH 검사보다 먼저 RecursionError가 난다.
# Swift 포트 대상의 256 캡까지는 실제로 도달하게 충분한 여유를 두고, 구현 세부가 바뀌어
# 그래도 넘치면 아래 eval_checked 경계에서 우아하게 거부한다.
PYTHON_RECURSION_FLOOR = (MAX_DEPTH + 1) * 16
INT_MIN = -(2 ** 63)
INT_MAX = 2 ** 63 - 1


def _wrap(v):
    v &= (2 ** 64 - 1)
    return v - 2 ** 64 if v > INT_MAX else v


def eval_checked(expr, defines, defined_names=None, suspect=frozenset(), text_defines=None,
                 macro_depth=0):
    """ExprEval.evalChecked 포트(ShaderPreprocessor.swift:702-853) — 미지원이면 None.

    **[G2/BK 2026-08-30 이식]** 거부 규약은 유지하고 **아는 문법만 넓혔다**. HEAD 의 Swift 에서
    거부는 이제 셋뿐이다: ① 렉서가 모르는 문자(`? : @ ;` · 수 밖의 `.`) ② 수로 못 읽는 수치
    define(suspect) 참조 ③ 잔여 토큰. `% & | ^ ~ << >>` 와 16진·접미·소수 리터럴은 **평가된다**.

    우선순위 사슬은 실물(=C)과 같다 — `|` < `^` < `&` < `==`/`!=` < 비교 < 시프트 < `+`/`-` <
    `*`/`/`/`%` < 단항. 뭉치면 `1 | 2 ^ 3 & 1` · `2 == 1 < 1` · `1 << 2 + 1` 이 갈린다.
    산술 폭도 실물과 같이 갈라 둔다: 비트·시프트·`~` 만 32비트 절단, `+ - * /` 는 64비트 랩.
    """
    if sys.getrecursionlimit() < PYTHON_RECURSION_FLOOR:
        sys.setrecursionlimit(PYTHON_RECURSION_FLOOR)

    toks, unsupported, _bad = tokenize(expr)
    if unsupported:
        return None
    known = set(defines.keys()) if defined_names is None else defined_names
    td = text_defines or {}
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
            if t == "~":
                return _w32(~_w32(parse_primary()))     # 실물 `not eax`(0x140167e04) — 32비트
            if t == "-":
                return _wrap(0 - parse_primary())
            if t == "+":
                return parse_primary()                   # 실물 0x140167c29: 단항 `+` 는 통과
            if t == "defined":
                if peek() == "(":
                    state["pos"] += 1
                    name = nxt() or ""
                    if peek() == ")":
                        state["pos"] += 1
                    return 1 if name in known else 0
                return 1 if (nxt() or "") in known else 0
            try:
                return int(t)          # 토큰화 단계에서 10진 문자열로 정규화돼 있다
            except ValueError:
                pass
            if t in suspect:
                state["failed"] = True
                return 0
            if t in defines:
                return defines[t]
            # G5 — 실물은 `#if` 식 안에서도 매크로를 확장한다(렉서가 재렉싱, 깊이 캡 0x63=99).
            # 본문이 식으로 안 읽히면 0(거부가 아니다) — Swift 의 `?? 0` 과 같다.
            if t in td and macro_depth < 99:
                inner = dict(td)
                inner.pop(t, None)     # 자기 참조(`#define A A`) 무한재귀 차단
                v = eval_checked(td[t], defines, known, suspect, inner, macro_depth + 1)
                return 0 if v is None else v
            return 0
        finally:
            state["depth"] -= 1

    def parse_mul():
        v = parse_primary()
        while peek() in ("*", "/", "%"):
            op = nxt()
            r = parse_primary()
            if op == "*":
                v = _wrap(v * r)
            elif r == 0 or (v == INT_MIN and r == -1):
                v = 0                                   # 실물 0x140167bcc: 제수 0 이면 결과 0
            elif op == "/":
                q = abs(v) // abs(r)                    # Swift Int 나눗셈 = 0 방향 절단
                v = q if (v < 0) == (r < 0) else -q
            else:
                q = abs(v) % abs(r)                     # Swift `%` 는 피제수 부호를 따른다
                v = q if v >= 0 else -q
        return v

    def parse_add():
        v = parse_mul()
        while peek() in ("+", "-"):
            op = nxt()
            r = parse_mul()
            v = _wrap(v + r) if op == "+" else _wrap(v - r)
        return v

    def parse_shift():
        # 실물 0x140167a8e: `cmp ebp,0x1f; ja → 0`. **부호 없는** 비교라 음수 시프트량도 0.
        v = parse_add()
        while peek() in ("<<", ">>"):
            op = nxt()
            r = parse_add()
            if r < 0 or r > 31:
                v = 0
            elif op == "<<":
                v = _w32(_w32(v) << r)
            else:
                v = _w32(_w32(v) >> r)                  # `sar` = 산술 시프트(Python >> 도 산술)
        return v

    def parse_rel():
        v = parse_shift()
        while peek() in ("<", ">", "<=", ">="):
            op = nxt()
            r = parse_shift()
            v = int({"<": v < r, ">": v > r, "<=": v <= r, ">=": v >= r}[op])
        return v

    def parse_eq():
        # 실물은 `==`/`!=` 가 비교보다 **느슨**하다(0x140167680 이 0x140167850 을 부른다) —
        # 뭉치면 `2 == 1 < 1` 이 1(종전) vs 0(실물)로 갈린다.
        v = parse_rel()
        while peek() in ("==", "!="):
            op = nxt()
            r = parse_rel()
            v = int(v == r if op == "==" else v != r)
        return v

    def parse_bit_and():
        v = parse_eq()
        while peek() == "&":
            state["pos"] += 1
            r = parse_eq()
            v = _w32(_w32(v) & _w32(r))
        return v

    def parse_bit_xor():
        v = parse_bit_and()
        while peek() == "^":
            state["pos"] += 1
            r = parse_bit_and()
            v = _w32(_w32(v) ^ _w32(r))
        return v

    def parse_bit_or():
        v = parse_bit_xor()
        while peek() == "|":
            state["pos"] += 1
            r = parse_bit_xor()
            v = _w32(_w32(v) | _w32(r))
        return v

    def parse_and():
        v = parse_bit_or()
        while peek() == "&&":
            state["pos"] += 1
            r = parse_bit_or()
            v = 1 if (v != 0 and r != 0) else 0
        return v

    def parse_or():
        v = parse_and()
        while peek() == "||":
            state["pos"] += 1
            r = parse_and()
            v = 1 if (v != 0 or r != 0) else 0
        return v

    try:
        value = parse_or()
    except RecursionError:
        # 매크로 재평가 등 파서 밖 재귀까지 합쳐 안전 여유를 넘더라도 측정 런 전체를
        # traceback 으로 중단하지 않는다. evalChecked 의 미지원/잔여 토큰과 같은 거부다.
        return None
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
    """ShaderPreprocessor.parenthesizedDecimalInt 포트(:593-600).

    G2: 안쪽은 10진뿐 아니라 실물 문법(16진·`u`/`f`/`l` 접미·소수부)도 받는다 — `(0x10)`.
    """
    v = value.strip()
    if not v.startswith("("):
        return None
    while v.startswith("(") and v.endswith(")"):
        v = v[1:-1].strip()
    try:
        return int(v)
    except ValueError:
        return numeric_literal(v)


def token_after(kw, line):
    rest = line[len(kw):].strip().split(" ")
    return rest[0] if rest else ""


def classify_refusal(expr, defines, defined_names, suspect):
    """거부 사유 분류(진단용 — 판정은 eval_checked 가 한다).

    **[G2/BK 2026-08-30 이식]** 종전 이 함수는 식 원문을 정규식으로 되짚어 `shift`/`hexLiteral`/
    `suffixedOrExpLiteral`/`modulo`/`bitwise` 를 사유로 냈다. HEAD 의 Swift 에서 그 다섯은
    **거부가 아니라 평가**이므로 도달 불가한 라벨이었다(`ShaderPreprocessor.swift:700` 이 남은
    트리거를 셋으로 열거한다: 미지 문자 · suspect define · 잔여 토큰).
    이제 분류는 정규식이 아니라 **렉서가 실제로 모른 문자**(`tokenize` 의 세 번째 반환)로 한다 —
    렉서가 넓어지면 분류도 자동으로 따라간다(정규식은 따라오지 않아 이 드리프트가 났다).
    """
    toks, unsupported, bad = tokenize(expr)
    if unsupported:
        if "?" in bad or ":" in bad:
            return "ternary"           # 실물 렉서에도 삼항이 없다(토큰 코드 0x19)
        if "." in bad:
            return "memberAccess"      # 수 밖의 `.` — uniform 멤버 비교(g_Texture0Resolution.x < …)
        return "unknownChar"           # `;` `@` 등 그 밖의 미지 문자
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
                v = eval_checked(expr, d, defined_names(), suspect, text_defines)
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
                v = eval_checked(expr, d, defined_names(), suspect, text_defines)
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
                    # 등록 사슬은 Swift `ShaderPreprocessor.swift:430-450` 과 같은 순서다:
                    #   10진 정수 → 괄호 감싼 정수(F422) → WE 수치 리터럴(G2/BK) → suspect(F421)
                    try:
                        d[name] = int(value)
                    except ValueError:
                        pv = paren_decimal_int(value)
                        nl = numeric_literal(value) if pv is None else None
                        if pv is not None:
                            d[name] = pv
                        elif nl is not None:
                            # G2/BK: `#define X 0x10` · `1u` · `1.5` — 실물 렉서가 아는 문법이므로
                            # 값으로 등록한다. 종전에는 아래 suspect 로 몰려 이 이름을 쓰는 `#if`
                            # 가 통째로 거부됐다(= 이펙트 폴백).
                            d[name] = nl
                        elif value[0].isdigit():
                            # 남은 거부는 실물이 **수로도 안 읽는** 형태뿐이다(`1e5` = 수 1 +
                            # 식별자 `e5` → 잔여 토큰). `1.5` 는 [BK 2026-08-21] 이후 여기 안 온다.
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


# ---------------------------------------------------------------- 셀프테스트
#
# **[정정 2026-08-30] 종전 이 절은 기대값을 손으로 베껴 적어 두어, 잡아야 할 드리프트를
# 자기 자신과 함께 굳혔다.** 종전 `SELFTEST_REFUSE` 는 14건 전부를 거부로 단언했는데
# HEAD 의 Swift 는 그중 **2건만** 거부한다(삼항 · 잔여 토큰). 나머지 12건
# (`% & | ^ ~ << >>` · `0x10` · `A == 0x10` · `1u` · `#elif A % 2` 체인 · `#define X 0x10`)은
# G2(1e4660ad)/BK(ba2b6623, 둘 다 2026-08-21) 이후 **평가된다**. 이식본이 pre-G2 판본인데
# 기대값도 같은 시점에 굳었으므로 `--selftest` 는 "통과 (0 실패)" 를 찍고 0 으로 종료했다 —
# 프로덕션 로직이 통째로 바뀌어도 초록인 **죽은 게이트**였다.
#
# **그래서 기대값을 다시 굳히지 않는다.** 아래 `harvest_swift_expectations()` 가
# `Tests/WapleCoreTests/` 의 XCTest 단언에서 `ExprEval.evalChecked` ·
# `ShaderPreprocessor.preprocessStrict` 케이스를 **파싱해** 기대값을 만든다. Swift 쪽이
# 넓어지거나 좁아지면 그 테스트 줄이 먼저 바뀌므로 이 셀프테스트가 자동으로 따라간다.
# 문법 집합도 같은 이유로 `harvest_swift_operator_sets()` 가 `ShaderPreprocessor.swift` 의
# 두 줄(two 집합 · 1글자 연산자 문자열)을 파싱해 이 파일의 `TWO_CHAR_OPS`/`SINGLE_OPS` 와
# 대조한다 — Swift 가 연산자를 추가하면 여기서 빨개진다.
#
# **수확기가 못 덮는 것**(그래서 아래 손으로 적은 케이스가 남는다): 다중행 `"""` 리터럴로
# 쓰인 소스, 배열 변수를 순회하는 단언, `preprocess`(비-strict) 문자열 포함 검사, 그리고
# 애초에 Swift 테스트가 없는 이식본 고유 경로(관용 어블레이션 스위치 · 인클루드 통계 ·
# [COMBO] 시딩). 이것들은 `SELFTEST_*` 에 남기되 **HEAD 의 Swift 에 실제로 돌려서** 값을
# 정했다(방법: `.build/debug/WapleCore.o` 에 `@testable import WapleCore` 하는 스크래치
# 실행파일을 링크해 14+10 케이스를 직접 호출 — 리포의 `Tests/` 는 건드리지 않았다).

SWIFT_PREPROCESSOR = os.path.join(REPO, "Sources", "WapleCore", "ShaderPreprocessor.swift")
SWIFT_TEST_FILES = (
    "Tests/WapleCoreTests/ShaderPreprocessorRequireTests.swift",
    "Tests/WapleCoreTests/ShaderEngineUniformTypeTests.swift",
    "Tests/WapleCoreTests/TranslationEvalFixRegressionTests.swift",
    "Tests/WapleCoreTests/ShaderPreprocessorConformanceTests.swift",
    "Tests/WapleCoreTests/ShaderPreprocessorTests.swift",
    "Tests/WapleCoreTests/TranslatorSceneFixRegressionTests.swift",
)

SWIFT_STR_LIT = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
_SWIFT_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "\\": "\\", "'": "'"}


def swift_unescape(s):
    out = []
    i = 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            out.append(_SWIFT_ESCAPES.get(s[i + 1], s[i + 1]))
            i += 2
            continue
        out.append(s[i])
        i += 1
    return "".join(out)


def _swift_balanced(text, start):
    """text[start] == '(' 일 때 짝이 맞는 ')' 바로 다음 인덱스. 문자열 리터럴 안은 세지 않는다."""
    depth = 0
    i = start
    in_str = False
    while i < len(text):
        c = text[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            i += 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return None


def _swift_split_args(s):
    """최상위 콤마 분리 — 괄호·대괄호·문자열 리터럴 안의 콤마는 무시."""
    out = []
    buf = ""
    depth = 0
    in_str = False
    i = 0
    while i < len(s):
        c = s[i]
        if in_str:
            buf += c
            if c == "\\" and i + 1 < len(s):
                buf += s[i + 1]
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            buf += c
            i += 1
            continue
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        if c == "," and depth == 0:
            out.append(buf)
            buf = ""
            i += 1
            continue
        buf += c
        i += 1
    if buf.strip():
        out.append(buf)
    return out


# Swift 기대값 표현식 중 **정수 산술만** 받는다(파이썬과 결과가 같은 연산자에 한정).
# `1 | (2 ^ (3 & 1))` 처럼 테스트가 기대값을 식으로 적는 자리를 그대로 읽기 위한 것이다.
_SWIFT_NAMED_INTS = {"Int(Int32.min)": -(2 ** 31), "Int(Int32.max)": 2 ** 31 - 1,
                     "Int32.min": -(2 ** 31), "Int32.max": 2 ** 31 - 1}
_SWIFT_INT_EXPR = re.compile(r"^[\s\d()+\-*/|&^~]+$")


def swift_int_expr(text):
    """Swift 테스트가 적은 기대 정수. 정수 리터럴·괄호·`+ - * / | & ^ ~` 만. 그 밖은 None."""
    t = text.strip()
    if t in _SWIFT_NAMED_INTS:
        return _SWIFT_NAMED_INTS[t]
    if not t or not _SWIFT_INT_EXPR.match(t):
        return None
    if re.search(r"\d\s*/\s*\d", t):
        return None                       # 파이썬 `/` 는 실수 나눗셈 — 뜻이 갈리므로 받지 않는다
    try:
        return int(eval(t, {"__builtins__": {}}, {}))   # 위 정규식이 이름·호출·속성을 전부 배제한다
    except (SyntaxError, ValueError, ZeroDivisionError, TypeError):
        return None


def swift_int_dict(text):
    """`[:]` / `["A": 3, "B": 2]` → dict. 그 밖 형태(변수·계산식)는 None."""
    t = text.strip()
    if t == "[:]":
        return {}
    if not (t.startswith("[") and t.endswith("]")):
        return None
    body = t[1:-1].strip()
    if not body:
        return {}
    out = {}
    for part in _swift_split_args(body):
        m = re.match(r'^\s*"([A-Za-z_]\w*)"\s*:\s*(-?\d+)\s*$', part)
        if m is None:
            return None
        out[m.group(1)] = int(m.group(2))
    return out


def harvest_swift_expectations(repo=None):
    """`Tests/WapleCoreTests/` 의 XCTest 단언에서 기대값을 뽑는다.

    반환: (evals, pres, skipped)
      evals — (expr, defines, want|None, 출처)  ← `ExprEval.evalChecked`
      pres  — (source, combos, ok: bool, 출처)  ← `ShaderPreprocessor.preprocessStrict`
      skipped — (출처, 이유) — 문법상 못 읽은 단언. **개수를 셀프테스트가 감시한다**(아래).
    """
    repo = repo or REPO
    evals = []
    pres = []
    skipped = []
    for rel in SWIFT_TEST_FILES:
        path = os.path.join(repo, rel)
        if not os.path.isfile(path):
            skipped.append((rel, "테스트 파일이 없다"))
            continue
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        for m in re.finditer(r"XCTAssert(Equal|Nil|NotNil)\s*\(", text):
            kind = m.group(1)
            close = _swift_balanced(text, m.end() - 1)
            if close is None:
                continue
            args = _swift_split_args(text[m.end():close - 1])
            if not args:
                continue
            call = args[0].strip()
            where = "%s:%d" % (rel, text[:m.start()].count("\n") + 1)
            for prefix, sink in (("ExprEval.evalChecked(", "eval"),
                                 ("ShaderPreprocessor.preprocessStrict(", "pre")):
                if not call.startswith(prefix):
                    continue
                cclose = _swift_balanced(call, call.index("("))
                cargs = _swift_split_args(call[call.index("(") + 1:cclose - 1])
                if len(cargs) < 2:
                    skipped.append((where, "인자 형태를 못 읽었다"))
                    break
                lit = SWIFT_STR_LIT.match(cargs[0].strip())
                if lit is None:
                    skipped.append((where, "첫 인자가 단일행 문자열 리터럴이 아니다"))
                    break
                first = swift_unescape(lit.group(1))
                label = "defines:" if sink == "eval" else "combos:"
                dm = re.match(r"^\s*%s(.*)$" % label, cargs[1], re.S)
                if dm is None:
                    skipped.append((where, "`%s` 인자를 못 찾았다" % label))
                    break
                d = swift_int_dict(dm.group(1))
                if d is None or len(cargs) > 2:
                    skipped.append((where, "정수 리터럴 맵이 아니거나 추가 인자가 있다"))
                    break
                if sink == "eval":
                    if kind == "Nil":
                        evals.append((first, d, None, where))
                    elif kind == "Equal" and len(args) >= 2:
                        want = swift_int_expr(args[1])
                        if want is None:
                            skipped.append((where, "기대값이 정수식이 아니다: %r" % args[1].strip()))
                        else:
                            evals.append((first, d, want, where))
                    else:
                        skipped.append((where, "evalChecked 에 %s 는 안 읽는다" % kind))
                else:
                    if kind in ("Nil", "NotNil"):
                        pres.append((first, d, kind == "NotNil", where))
                    else:
                        skipped.append((where, "preprocessStrict 에 %s 는 안 읽는다" % kind))
                break
    return evals, pres, skipped


# 수확기가 최소 이만큼은 읽어야 한다 — 테스트 파일이 개명·이동되거나 파서가 깨지면
# 조용히 0건이 되어 게이트가 다시 죽는다. 실측(2026-08-30, HEAD 70a8a708): eval 48 · pre 4.
MIN_HARVESTED_EVALS = 40
MIN_HARVESTED_PRES = 4
# 못 읽은 단언 수의 상한. 실측 5건은 전부 다중행 `"""` 소스이고 아래 SELFTEST_* 가 덮는다.
# 이 수가 늘면 새로 못 읽는 단언이 생긴 것이므로 수확기를 넓히거나 상한을 근거와 함께 올려라.
MAX_HARVEST_SKIPPED = 5


def harvest_swift_operator_sets(path=None):
    """`ShaderPreprocessor.swift` 의 렉서 두 줄에서 연산자 집합을 뽑는다. 실패 시 (None, None)."""
    path = path or SWIFT_PREPROCESSOR
    if not os.path.isfile(path):
        return None, None
    with open(path, encoding="utf-8") as fh:
        src = fh.read()
    two = None
    m = re.search(r"let\s+two\s*:\s*Set<String>\s*=\s*\[([^\]]*)\]", src)
    if m:
        two = set(swift_unescape(x) for x in re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1)))
    single = None
    m = re.search(r'if\s+"((?:[^"\\]|\\.)*)"\.contains\(c\)\s*\{\s*toks\.append', src)
    if m:
        single = set(swift_unescape(m.group(1)))
    return two, single


# ---- 이식본 고유 경로(대응 Swift 테스트가 없거나 다중행 리터럴이라 수확 불가) ----
#
# 아래는 수확기가 읽지 못하는 경로의 **고정 기대값**이다. `--selftest` 자체는 Swift 를 실행하지
# 않으므로 이 목록만으로 현재 HEAD 와의 직접 동등성을 주장하지 않는다.

# G2/BK 이후에도 여전히 거부되는 것 — 렉서가 모르는 문자 · 잔여 토큰 · 수로 못 읽는 define.
# (실측: 이 6건 전부 `preprocessStrict(_, combos: ["A": 3])` 가 nil 을 낸다.)
SELFTEST_REFUSE = [
    "#if A ? 1 : 0\nyes\n#endif",                       # 삼항 — 실물 렉서에도 없다(토큰 0x19)
    "#if 1 0\nyes\n#endif",                             # 잔여 토큰
    "#if 1e5\nyes\n#endif",                             # 수 `1` + 식별자 `e5` → 잔여 토큰
    "#if A @ 1\nyes\n#endif",                           # 미지 문자
    "#if .5\nyes\n#endif",                              # 수 **밖**의 `.` 는 여전히 미지 문자
    "#if A == 1\none\n#elif A ? 2 : 3\ntwo\n#endif",    # 활성 체인의 #elif 도 같다
    "#define K 1e5\n#if K\nyes\n#endif",                # 수로 못 읽는 수치 define(suspect)
]
# G2/BK 로 **거부에서 평가로 넘어간** 것들 — 종전 SELFTEST_REFUSE 에 있던 12건이 여기 온다.
# (`want` 는 emitted 에 남아야 할 토큰. 자동 Swift 대조가 아닌 고정 기대값이다.)
SELFTEST_NOW_EVALUATED = [
    ("#if A % 2\nyes\n#endif", {"A": 3}, "yes"),
    ("#if A & 1\nyes\n#endif", {"A": 3}, "yes"),
    ("#if A | 1\nyes\n#endif", {"A": 3}, "yes"),
    ("#if A ^ 1\nyes\n#endif", {"A": 3}, "yes"),
    ("#if ~A\nyes\n#endif", {"A": 3}, "yes"),
    ("#if A << 1\nyes\n#endif", {"A": 3}, "yes"),
    ("#if A >> 1\nyes\n#endif", {"A": 3}, "yes"),
    ("#if 0x10\nyes\n#endif", {"A": 3}, "yes"),
    ("#if A == 0x10\nyes\n#endif", {"A": 3}, None),      # 3 != 16 — 통과하되 본문은 빈다
    ("#if 1u\nyes\n#endif", {"A": 3}, "yes"),
    ("#if A == 1\none\n#elif A % 2\ntwo\n#endif", {"A": 3}, "two"),
    ("#define X 0x10\n#if X\nyes\n#endif", {"A": 3}, "yes"),
    # BK: 소수 리터럴 define 도 값이다(정수부만) — `0.0174533` 은 0 이라 거짓 분기로 간다.
    ("#define DEG2RAD 0.0174533\n#if DEG2RAD > 0\nyes\n#else\nno\n#endif", {}, "no"),
    ("#define M_D_PI_2 1.5707963\n#if M_D_PI_2 > 0\nyes\n#else\nno\n#endif", {}, "yes"),
]
SELFTEST_ACCEPT = [
    ("#if COMBO == 1\none\n#elif defined(X) && !defined(Y)\ntwo\n#else\nother\n#endif", {"COMBO": 1}),
    ("#if 1 + 2 * 3 == 7\nyes\n#endif", {}),
    ("#if (A > 2) && !(B <= 1)\nyes\n#endif", {"A": 3, "B": 2}),
    ("#if 0\n#if BAD ? 1 : 0\ndead\n#endif\n#else\nlive\n#endif", {}),                 # 비활성 부모 관용
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
# G5 — 실물은 `#if` 식 안에서도 매크로를 확장한다(ShaderPreprocessor.swift:747-763).
# 대응 Swift 테스트가 다중행이라 수확 불가 → 직접 실측한 값이다.
SELFTEST_MACRO_IN_IF = [
    ("#define A B\n#define B 1\n#if A\nyes\n#else\nno\n#endif", {}, "yes"),
    ("#define A A\n#if A\nyes\n#else\nno\n#endif", {}, "no"),                    # 자기 참조 → 0
    ("#define A vec2(1.0)\n#if A\nyes\n#else\nno\n#endif", {}, "no"),            # 식으로 안 읽히면 0
]
# 이식본 고유(연산자 우선순위·32비트 폭) — 수확기가 읽는 Swift 단언과 겹치는 것은 여기 안 적는다.
SELFTEST_EVAL = [
    ("7 / 2", {}, 3), ("0 - 7 / 2", {}, -3), ("A / 0", {"A": 5}, 0),
    ("1.", {}, 1), ("0x10.5", {}, 16),
]


SELFTEST_BRANCH = [
    # (source, combos, 남아야 할 토큰, 사라져야 할 토큰) — 활성 분기 선택 검증
    ("#if 0\n#if BAD ? 1 : 0\ndead\n#endif\n#else\nlive\n#endif", {}, "live", "dead"),
    ("#ifdef HLSL\nflip\n#else\nnoflip\n#endif", {}, "flip", "noflip"),
    ("#if SHADERVERSION < 62\nold\n#else\nnew\n#endif", {}, "new", "old"),
    ("#ifdef HLSL_SM30\nsm30\n#else\nmodern\n#endif", {}, "modern", "sm30"),
    ("#if AUDIOSAMPLES == 16\na\n#elif AUDIOSAMPLES == 32;\nb\n#endif", {"AUDIOSAMPLES": 32}, "b", "a"),
    ('// [COMBO] {"combo":"MODE","default":1}\n#if MODE == 1\nyes\n#else\nno\n#endif', {}, "yes", "no"),
]


# ---------------------------------------------------------------- 정본 산문 (근거 문면)
#
# 두 문면을 여기 한 곳에 둔다 — 종전에는 `portFidelity` 와 evidence `note` 가 각자 자리에서
# **서로 다른 숫자**를 적고 있었다(전자 "거부 16", 후자 "거부 14" — 후자가 F610 2건을 빼먹었다).
# 같은 사실을 두 곳에 적으면 한 곳은 반드시 썩는다.

PORT_FIDELITY = (
    "이 수치는 ShaderPreprocessor/ExprEval 의 **거부 판정 경로를 Python 으로 이식한 판본**으로 "
    "측정한 것이고, 코퍼스에 대해 Swift 를 직접 돌려 얻은 것은 아니다. 이식본은 "
    "`--selftest` 가 검증한다: ① `ShaderPreprocessor.swift` 의 렉서 두 줄에서 연산자 집합을 "
    "파싱해 대조 ② `Tests/WapleCoreTests/` 의 XCTest 단언에서 기대값 52건을 수확해 대조"
    "(evalChecked 48 · preprocessStrict 4) ③ 수확 불가 경로 46건은 이 파일의 고정 기대값과 "
    "대조(거부 9 · G2·BK 평가 14 · G5 매크로 3 · 통과 9 · 평가값 5 · 분기선택 6). "
    "`--selftest` 는 Swift 바이너리를 실행하지 않으므로 이 셋은 직접 differential 증거가 아니다. "
    "미커버 경로에서 발산할 가능성은 남는다 — macOS 에서 GLSLTranslator.translate 를 코퍼스에 "
    "직접 돌려 재확인할 것. "
    "**[정정 2026-08-30]** 종전 이 문면은 두 가지를 거짓으로 주장했다. "
    "① ~~\"이 머신엔 Swift 툴체인이 없다\"~~ — 이 값이 기록된 2026-08-01 시점에는 맞았지만 "
    "지금은 아니다(`xcode-select -p` = Xcode 27.0 Beta 5, `swift --version` = 6.4). "
    "② ~~\"Swift 회귀테스트의 기대값(거부 16·통과 9·분기선택 6·인클루드 2 케이스)으로 포트를 "
    "검증했다\"~~ — `--selftest` 는 Swift 를 **한 번도 부르지 않았고**, 이식본을 자기 자신이 "
    "적어 둔 기대값과 대조했을 뿐이다. 그 기대값이 이식 시점(pre-G2)에 함께 굳어서 "
    "**Swift 가 반대를 단언하는 12건을 거부로 계속 단언**하고 있었다: "
    "`% & | ^ ~ << >>` · `0x10` · `A == 0x10` · `1u` · `#elif A % 2` 체인 · `#define X 0x10` — "
    "실측(HEAD 70a8a708, `preprocessStrict(_, combos: [\"A\": 3])`)으로 14건 중 **2건만** 거부다"
    "(삼항 · 잔여 토큰). Swift 쪽 반대 단언은 "
    "`Tests/WapleCoreTests/ShaderPreprocessorRequireTests.swift:179-192`. "
    "그래서 `--selftest` 는 프로덕션 로직이 통째로 바뀐 뒤에도 \"통과 (0 실패)\" 를 찍는 "
    "죽은 게이트였다. 이식본을 G2(1e4660ad)/BK(ba2b6623, 둘 다 2026-08-21)에 맞춰 넓혔고, "
    "연산자 집합과 수확 가능한 52건은 Swift 소스·테스트에서 유도하고, 수확 불가 46건은 이 파일의 "
    "고정 기대값으로 남겼다. 그러므로 직접 differential 이라는 주장은 하지 않는다."
)

SUSPECT_CRITERION_CORRECTION = (
    "**[정정 2026-08-30]** 바로 위 `suspectDefineCandidates` 와 `suspectDefineCandidatesTop` 은 "
    "**옛 판정 기준으로 센 값이다**(2026-08-01 측정). 종전 기준은 \"숫자로 시작하는데 10진 정수도 "
    "괄호 정수도 아니면 suspect\" 라 `0x10`·`1u`·`1.5`·`0.0174533` 을 전부 후보로 셌는데, "
    "G2/BK(1e4660ad·ba2b6623, 둘 다 2026-08-21) 이후 Swift 는 그 넷을 **값으로 등록**한다"
    "(`ShaderPreprocessor.swift` 의 `ExprEval.numericLiteral` 분기 — `#define X 0x10` · `1.5` 는 "
    "이제 suspect 가 아니다). 실측(HEAD 70a8a708, `preprocessStrict`): "
    "`#define DEG2RAD 0.0174533` + `#if DEG2RAD > 0` → `\"no\"`(값 0 으로 평가, nil 아님) · "
    "`#define M_D_PI_2 1.5707963` + `#if … > 0` → `\"yes\"`(값 1). 즉 위 표의 상위 항목 대부분이 "
    "HEAD 의 suspect 집합에 없다. 남는 후보는 실물이 **수로도 못 읽는** 값뿐이다(`1e5` 류 지수 표기). "
    "생성기(`measure_workshop_shaders.py`)의 판정은 이 정정과 함께 고쳤으니 다음 재생성이 참값을 "
    "적을 것이다 — **워크샵 코퍼스가 두 리포 어디에도 없어 지금 재측정할 수 없다**"
    "(`WE_WORKSHOP` 미설정, 기본 경로 `Z:\\SteamLibrary\\…\\431960` 부재). "
    "숫자를 지우지 않는 이유는 근거 보존이다 — 옛 값이 무엇이었는지가 이 드리프트의 증거다. "
    "**이 항목의 논지와 headline 은 바뀌지 않는다.** HEAD 의 suspect 집합은 옛 기준의 "
    "**진부분집합**이므로 넓은 기준에서 이미 빈 `suspectNamesReferencedInIf: {}` 는 좁은 기준에서도 "
    "비어 있고(단조성), 같은 이유로 `refusedFiles: 0` 과 `verdict` 는 재생성에서 0 이 아닌 값으로 "
    "바뀔 수 없다 — 즉 이 정정은 정확성 회복이 아니라 **근거 문면의 정정**이다."
)

HISTOGRAM_MECHANISM_CORRECTION = (
    "**[정정 2026-08-30]** 종전 이 히스토그램의 `%`·`&(비트)`·`|(비트)`·`^`·`~`·`<<`·`>>` 버킷은 "
    "**`unsupported` 플래그 안에서 식 원문 문자열 검사로** 셌다. G2 이후 그 연산자들은 지원되므로 "
    "플래그가 서지 않아 그 버킷은 구조적으로 **항상 0** 이 된다(도수가 아니라 죽은 코드였다). "
    "이제 토큰에서 직접 센다. **위 표의 값은 바뀌지 않는다** — 이 코퍼스의 `#if`/`#elif` 식에는 "
    "그 연산자들이 실제로 0건이라(그래서 종전에도 표에 없었다) 세는 법만 고쳐졌다. "
    "`?:`·`.멤버` 버킷도 정규식 대신 렉서가 실제로 모른 문자로 센다."
)

CAUSE_LABELS_CORRECTION = (
    "**[검증 2026-08-30]** 위 `causes` 의 세 라벨(`residualTokens`·`unknownChar`·`memberAccess`)은 "
    "G2/BK 뒤에도 **전부 살아 있는 거부 사유**다(`ShaderPreprocessor.swift` 가 남은 트리거를 "
    "미지 문자·suspect define·잔여 토큰 셋으로 열거한다). 각 어블레이션이 건드리는 트리거도 "
    "여전히 거부된다: `directiveComment` 를 끄면 `/* mic */` 가 `/`·`*`·식별자·`*`·`/` 토큰으로 "
    "남아 잔여 토큰 가드에 걸리고(그 다섯은 전부 1글자 연산자다), `trailingSemicolon` 을 끄면 "
    "`;` 가 미지 문자로 남고, `identicalBranches` 를 끄면 `g_Texture0Resolution.x` 의 수 밖 `.` 이 "
    "미지 문자로 남는다. 그래서 이 표는 재생성에서 같은 값이 나올 것으로 본다 — "
    "종전 생성기가 냈던 죽은 라벨(`shift`·`hexLiteral`·`modulo`·`bitwise`·`suffixedOrExpLiteral`)은 "
    "이 표에 애초에 등장하지 않는다. 정정이 필요한 것은 위 `evidence.note` 의 셀프테스트 주장뿐이다."
)

SCRIPT_EV_NOTE = (
    "ShaderPreprocessor.swift / GLSLTranslator.swift 의 거부 판정 경로 포트"
    "(preprocessStrict · evaluateConditionals · ExprEval · weNumericLiteral · isEngine). "
    "`--selftest` 는 Swift 소스에서 연산자 집합을 파싱하고 `Tests/WapleCoreTests/` 의 단언 "
    "52건을 수확해 대조한다(+ 수확 불가 경로 46건은 이 파일의 고정 기대값). "
    "**[정정 2026-08-30]** 종전 이 note 는 \"Swift 회귀테스트 기대값(거부 14·통과 9·분기선택 6 "
    "케이스) 대조 통과\" 라고 적었는데 세 군데가 틀렸다: (a) 셀프테스트는 Swift 를 부르지 않았다 "
    "(이식본 대 이식본 대조), (b) 그 \"거부 14\" 중 12건은 HEAD 에서 **평가된다**, "
    "(c) 같은 목록을 세는 `portFidelity` 는 F610 2건을 포함해 \"거부 16\" 이라 적어 두 문면이 "
    "서로 어긋났다. 줄 번호 인용도 드리프트해 심볼명으로 바꿨다."
)


def selftest():
    fails = []
    # M23: Python 재귀 한도가 MAX_DEPTH(256)보다 먼저 터지면 이 포트는 Swift 의
    # "캡 초과는 우아하게 0/거부" 규약에 도달하지 못하고 측정 런 전체를 중단한다.
    for depth, want in ((120, 1), (200, 1), (400, None)):
        expr = "(" * depth + "1" + ")" * depth
        try:
            got = eval_checked(expr, {})
        except RecursionError:
            fails.append("괄호 깊이 %d 에서 RecursionError — MAX_DEPTH 가 도달 불가" % depth)
            continue
        if got != want:
            fails.append("괄호 깊이 %d 결과 %r, 기대 %r" % (depth, got, want))
    # ---- ① Swift 소스에서 뜬 연산자 집합과 대조(문법이 넓어지면 여기서 걸린다)
    two, single = harvest_swift_operator_sets()
    if two is None or single is None:
        fails.append("ShaderPreprocessor.swift 에서 연산자 집합을 못 읽었다 — 렉서 형태가 바뀌었나?"
                     " (two=%r single=%r)" % (two, single))
    else:
        if two != TWO_CHAR_OPS:
            fails.append("2글자 연산자 집합 불일치: Swift %r vs 이식본 %r (차집합 %r)"
                         % (sorted(two), sorted(TWO_CHAR_OPS), sorted(two ^ TWO_CHAR_OPS)))
        if single != SINGLE_OPS:
            fails.append("1글자 연산자 집합 불일치: Swift %r vs 이식본 %r (차집합 %r)"
                         % (sorted(single), sorted(SINGLE_OPS), sorted(single ^ SINGLE_OPS)))
    # ---- ② Swift 테스트에서 수확한 기대값과 대조(Swift 가 동작을 바꾸면 여기서 걸린다)
    evals, pres, skipped = harvest_swift_expectations()
    if len(evals) < MIN_HARVESTED_EVALS:
        fails.append("Swift evalChecked 단언 수확 %d건 < 하한 %d — 수확기가 깨졌거나 테스트가 옮겨졌다"
                     % (len(evals), MIN_HARVESTED_EVALS))
    if len(pres) < MIN_HARVESTED_PRES:
        fails.append("Swift preprocessStrict 단언 수확 %d건 < 하한 %d" % (len(pres), MIN_HARVESTED_PRES))
    if len(skipped) > MAX_HARVEST_SKIPPED:
        fails.append("수확 못 한 단언 %d건 > 상한 %d: %r"
                     % (len(skipped), MAX_HARVEST_SKIPPED, skipped[:8]))
    for expr, defs, want, where in evals:
        got = eval_checked(expr, defs)
        if got != want:
            fails.append("[%s] evalChecked(%r, %r)=%r, Swift 기대 %r" % (where, expr, defs, got, want))
    for src, combos, want_ok, where in pres:
        ok = preprocess_strict(src, combos, lambda h: None)[0]
        if ok != want_ok:
            fails.append("[%s] preprocessStrict(%r) ok=%r, Swift 기대 %r" % (where, src, ok, want_ok))
    # ---- ③ 수확 불가 경로(이 파일에 고정한 기대값 — 자동 Swift 대조 아님)
    for src in SELFTEST_REFUSE:
        ok = preprocess_strict(src, {"A": 3}, lambda h: None)[0]
        if ok:
            fails.append("거부 기대인데 통과: %r" % src)
    for src in SELFTEST_REFUSE_F610:
        ok = preprocess_strict(src, {}, lambda h: None)[0]
        if ok:
            fails.append("F610 거부 기대인데 통과: %r" % src)
    for src, combos, keep in SELFTEST_NOW_EVALUATED:
        ok, why, _d, em = preprocess_strict(src, combos, lambda h: None)
        if not ok:
            fails.append("G2/BK 이후 평가 기대인데 거부(%s): %r" % (why, src))
        elif keep is not None and keep not in "\n".join(em):
            fails.append("G2/BK 평가 결과 불일치(기대 %r 유지): %r → %r" % (keep, src, em))
    for src, combos, keep in SELFTEST_MACRO_IN_IF:
        ok, why, _d, em = preprocess_strict(src, combos, lambda h: None)
        if not ok:
            fails.append("G5 매크로 확장 기대인데 거부(%s): %r" % (why, src))
        elif keep not in "\n".join(em):
            fails.append("G5 매크로 확장 결과 불일치(기대 %r): %r → %r" % (keep, src, em))
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
    # 거부 사유 분류가 살아 있는 라벨만 내는가 — 종전 분류기는 G2 로 사라진 사유
    # (`shift`/`hexLiteral`/`modulo`/`bitwise`/`suffixedOrExpLiteral`)를 계속 냈다.
    live_causes = {"ternary", "memberAccess", "unknownChar", "suspectDefine", "residualTokens"}
    for src in SELFTEST_REFUSE + SELFTEST_REFUSE_F610:
        why = preprocess_strict(src, {"A": 3}, lambda h: None)[1]
        if why is not None and why not in live_causes:
            fails.append("죽은 거부 사유 라벨 %r (살아 있는 것: %r): %r" % (why, sorted(live_causes), src))
    # 콤보 기본값 + HLSL/SHADERVERSION 시딩
    d = preprocess_strict('// [COMBO] {"combo":"MODE","default":2}\n', {}, lambda h: None)[2]
    if d.get("MODE") != 2 or d.get("HLSL") != 1 or d.get("SHADERVERSION") != 69 or "HLSL_SM30" in d:
        fails.append("시딩/콤보 기본값 불일치: %r" % {k: d.get(k) for k in ("MODE", "HLSL", "SHADERVERSION")})
    # 인클루드 인라인 + 헤더 내 [COMBO] 기본값 반영
    hdr = {"x.h": '// [COMBO] {"combo":"HH","default":3}\nfromheader\n'}
    ok, _why, d2, em = preprocess_strict('#include "x.h"\n#if HH == 3\nyes\n#endif\n', {}, hdr.get)
    if not ok or d2.get("HH") != 3 or "fromheader" not in "\n".join(em) or "yes" not in "\n".join(em):
        fails.append("인클루드 인라인/헤더 COMBO 불일치")
    # 미해석 인클루드는 조용한 드롭(줄 자체가 사라진다) — 거부가 아니다
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

    specfmt.require_inputs("measure_workshop_shaders",
                           ("dir", WS, "WE_WORKSHOP", "워크샵 코퍼스"))

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
            toks, unsupported, bad = tokenize(e)
            # **[정정 2026-08-30]** 종전 이 히스토그램은 `%`·비트·시프트 버킷을 `unsupported`
            # 플래그 안에서 식 원문 문자열 검사로 셌다 — G2 이후 그 연산자들은 지원되므로
            # `unsupported` 가 서지 않아 **전부 0 이 된다**. 이제 토큰에서 직접 센다
            # (`&&` 와 `&` 를 혼동하지 않는 것은 렉서가 2글자를 먼저 보기 때문이다).
            for t in toks:
                if t in ("==", "!=", "<=", ">=", "&&", "||", "<", ">", "+", "-", "*", "/",
                         "!", "(", ")", "%", "^", "~", "<<", ">>"):
                    if_ops[t] += 1
                elif t == "&":
                    if_ops["&(비트)"] += 1
                elif t == "|":
                    if_ops["|(비트)"] += 1
                elif t == "defined":
                    if_ops["defined"] += 1
            if unsupported:
                # 미지 문자 버킷도 정규식이 아니라 **렉서가 실제로 모른 문자**로 센다.
                if "?" in bad or ":" in bad:
                    if_ops["?:"] += 1
                if "." in bad:
                    if_ops[".멤버"] += 1
                unsupported_exprs[e] += 1
                unsupported_expr_where.setdefault(e, "%s/%s::%s" % (sh["wid"], sh["pkg"], sh["name"]))

        # F421 suspect 후보: 숫자로 시작하지만 **실물이 수로도 못 읽는** 값의 #define.
        # 이 이름이 #if 에서 참조되면 거부다 — 후보 수와 실제 참조를 따로 센다.
        #
        # **[정정 2026-08-30]** 종전 판정은 "10진 정수도 아니고 괄호 정수도 아니면 suspect" 라
        # `0x10`·`1u`·`1.5`·`0.0174533` 을 전부 후보로 셌다. G2/BK 이후 Swift 는 그 넷을 **값으로
        # 등록**하므로(`ShaderPreprocessor.swift:436` 의 `ExprEval.numericLiteral` 분기) 후보가
        # 아니다. 남는 것은 `1e5` 류 지수 표기뿐이다 — 실물도 수 `1` 에서 끊고 `e5` 를 식별자로
        # 내며, 우리는 그 잔여 토큰을 거부한다.
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
            if paren_decimal_int(val) is None and numeric_literal(val) is None:
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
    script_ev = specfmt.ev("script", "scripts/spec/measure_workshop_shaders.py", SCRIPT_EV_NOTE)
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
            "histogramMechanismCorrection": HISTOGRAM_MECHANISM_CORRECTION,
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
            "portFidelity": PORT_FIDELITY,
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
                "suspectCriterionCorrection": SUSPECT_CRITERION_CORRECTION,
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
            "causeLabelsCorrection": CAUSE_LABELS_CORRECTION,
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
