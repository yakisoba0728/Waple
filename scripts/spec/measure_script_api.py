"""SceneScript(scenescript64.dll) 가 JS 에 노출하는 바인딩 API 를 실측해 정본을 만든다.

세 개의 독립 원본을 교차한다:

  (1) 선언 표면 — WE 편집기가 Monaco 자동완성에 먹이는 공식 타입 선언
      ui/dist/monaco/autocomplete/lib.sceneScript.d.ts ("OFFICIAL SCENESCRIPT TYPE
      DECLARATION - VERSION 2.8"). 사람이 읽는 문서가 아니라 배포물이라 정본 자격이 있다.
  (2) JS 측 구현 — assets/scripts/jsclasses/baseclasses.js (평문). Vec2/Vec3/Vec4/
      Mat3/Mat4, MediaPlaybackEvent 상수, _Internal 주입 프로토콜, createScriptProperties
      가 전부 여기 있다. 네이티브가 아니라 이 파일이 정본이다.
  (3) 네이티브 바인딩 — scenescript64.dll .rdata 의 바인딩 문자열 군집.
      V8 은 오픈소스라 WE 자체 바인딩만 골라낸다: 군집이 .rdata 한 구간에 연속으로
      박혀 있어(0x1819a2f00~0x1819a3c00) 이름과 이웃을 함께 읽을 수 있다.

(1) 과 (3) 이 어긋나는 지점이 이 문서의 핵심이다 — d.ts 에 없는 네이티브 바인딩
(cursorHitTest / animationEvent / isObjectValid / clearTimeout / thisObject / button)과,
d.ts 에만 있고 어느 바이너리에도 문자열이 없는 선언(renderContext / thisProperty /
IModel / IAssetHandle).

pefile 등 외부 패키지는 쓰지 않는다(AGENTS.md: 외부 의존 0). struct 로 충분하다.
"""
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")

DLL = os.path.join(WE, "bin", "scenescript64.dll")
EXE = os.path.join(WE, "wallpaper64.exe")
DTS = os.path.join(WE, "ui", "dist", "monaco", "autocomplete", "lib.sceneScript.d.ts")
BASECLASSES = os.path.join(WE, "assets", "scripts", "jsclasses", "baseclasses.js")
JSMODULES = os.path.join(WE, "assets", "scripts", "jsmodules")

# 리포에 동봉된 사본(동일성 검증용) — 다르면 리포 사본이 정본이 아니다.
REPO_ASSETS = os.path.join("Sources", "WapleRender", "Resources", "WEAssets", "scripts")

# scenescript64.dll .rdata 의 WE 바인딩 문자열 군집. 경계는 여유를 두고 잡고
# 군집 밖 잡음(로캘/iostream 메시지)은 아래 분류에서 걸러낸다.
#
# 군집 안에 있다는 것이 이 문서의 강한 주장이다. 24MB 짜리 V8 블롭 어딘가에
# 같은 바이트열이 있다는 것은 거의 아무 뜻도 없다 — 'console' 은 V8 자체에도
# 3번 나오고 그중 WE 바인딩은 0x1819a35f0 하나뿐이다. 그래서 주소 조회는
# 언제나 군집 우선이고, 군집 밖이면 None 을 돌려준다.
BIND_LO, BIND_HI = 0x1819A2B50, 0x1819A3C60

# wallpaper64.exe 쪽 레이어 바인딩 구간. DLL 군집과 달리 씬 JSON 키·머티리얼
# 키·_rt_* 타깃과 뒤섞여 있어 "구간 안"이 곧 "JS 바인딩"은 아니다. 그래서
# 카멜케이스 메서드만 확정으로 올리고 전소문자 이름은 ambiguous 로 내린다.
EXE_BIND_REGIONS = [
    (0x140490200, 0x140491500, "layer/effect/bone/particle"),
    (0x14048DE60, 0x14048DEA0, "animation(frame/rate/duration)"),
]

# ─────────────────────────────────────────────────────────────── PE


def read_pe(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:2] != b"MZ":
        raise ValueError(f"{path}: MZ 아님")
    pe_off = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe_off:pe_off + 4] != b"PE\0\0":
        raise ValueError(f"{path}: PE 시그니처 없음")
    coff = pe_off + 4
    nsec = struct.unpack_from("<H", data, coff + 2)[0]
    opt_size = struct.unpack_from("<H", data, coff + 16)[0]
    opt = coff + 20
    pe32plus = struct.unpack_from("<H", data, opt)[0] == 0x20B
    image_base = (struct.unpack_from("<Q", data, opt + 24)[0] if pe32plus
                  else struct.unpack_from("<I", data, opt + 28)[0])
    dd = opt + (112 if pe32plus else 96)
    export_rva, export_size = struct.unpack_from("<II", data, dd)

    sec_off = opt + opt_size
    sections = []
    for i in range(nsec):
        b = sec_off + i * 40
        name = data[b:b + 8].rstrip(b"\0").decode("ascii", "ignore")
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, b + 8)
        sections.append({"name": name, "vsize": vsize, "vaddr": vaddr,
                         "rawsize": rawsize, "rawptr": rawptr})

    def rva_to_off(rva):
        for s in sections:
            if s["vaddr"] <= rva < s["vaddr"] + max(s["vsize"], s["rawsize"]):
                return s["rawptr"] + (rva - s["vaddr"])
        return None

    return {"data": data, "imageBase": image_base, "sections": sections,
            "rva_to_off": rva_to_off, "exportRVA": export_rva, "exportSize": export_size,
            "fileBytes": len(data)}


def read_exports(pe):
    """이름 있는 export 를 (name, rva) 로. ordinal-only 는 무시(WE 는 안 쓴다)."""
    if not pe["exportRVA"]:
        return []
    off = pe["rva_to_off"](pe["exportRVA"])
    data = pe["data"]
    n_names = struct.unpack_from("<I", data, off + 24)[0]
    addr_rva, names_rva, ords_rva = struct.unpack_from("<III", data, off + 28)
    a_off = pe["rva_to_off"](addr_rva)
    n_off = pe["rva_to_off"](names_rva)
    o_off = pe["rva_to_off"](ords_rva)
    out = []
    for i in range(n_names):
        name_rva = struct.unpack_from("<I", data, n_off + i * 4)[0]
        s = pe["rva_to_off"](name_rva)
        end = data.index(b"\0", s)
        name = data[s:end].decode("ascii")
        ordinal = struct.unpack_from("<H", data, o_off + i * 2)[0]
        fn_rva = struct.unpack_from("<I", data, a_off + ordinal * 4)[0]
        out.append((name, ordinal + 1, fn_rva))
    return sorted(out, key=lambda t: t[1])


PRINTABLE = re.compile(rb"[\x20-\x7e]{2,300}")


def strings_in_va_range(pe, lo, hi):
    """[lo, hi) VA 구간의 인쇄가능 문자열을 (va, text) 로. 군집 전수 열거용."""
    base = pe["imageBase"]
    out = []
    for s in pe["sections"]:
        va0 = base + s["vaddr"]
        va1 = va0 + max(s["vsize"], s["rawsize"])
        if not (va0 <= lo < va1):
            continue
        off = s["rawptr"] + (lo - va0)
        blob = pe["data"][off:off + (hi - lo)]
        for m in PRINTABLE.finditer(blob):
            out.append((lo + m.start(), m.group().decode("ascii")))
        break
    return out


def string_va_index(pe):
    """전 섹션의 NUL 종단 ASCII 문자열 → 최초 VA. 존재 확인/주소 조회용."""
    base = pe["imageBase"]
    idx = {}
    for s in pe["sections"]:
        blob = pe["data"][s["rawptr"]:s["rawptr"] + s["rawsize"]]
        va0 = base + s["vaddr"]
        for m in re.finditer(rb"[\x20-\x7e]{3,300}", blob):
            t = m.group().decode("ascii")
            if t not in idx:
                idx[t] = (va0 + m.start(), s["name"])
    return idx


def has_utf16(path, name):
    with open(path, "rb") as fh:
        return fh.read().find(name.encode("utf-16-le")) >= 0


def string_at(pe, va):
    """VA 의 NUL 종단 ASCII 문자열. 아니면 None."""
    base = pe["imageBase"]
    for s in pe["sections"]:
        va0 = base + s["vaddr"]
        if not (va0 <= va < va0 + max(s["vsize"], s["rawsize"])):
            continue
        off = s["rawptr"] + (va - va0)
        end = pe["data"].find(b"\0", off)
        if end < 0 or end - off > 64 or end == off:
            return None
        try:
            t = pe["data"][off:end].decode("ascii")
        except UnicodeDecodeError:
            return None
        return t if all(32 <= ord(c) < 127 for c in t) else None
    return None


# lea r64, [rip+disp32] : REX.W(0x48~0x4f) 8D modrm(mod=00, rm=101) disp32
LEA_RIP = re.compile(rb"[\x48-\x4f]\x8d[\x05\x0d\x15\x1d\x25\x2d\x35\x3d]")


def lea_targets(pe):
    """.text 의 RIP 상대 lea 를 전부 훑어 target VA -> [참조 사이트 VA]."""
    base = pe["imageBase"]
    text = next(s for s in pe["sections"] if s["name"] == ".text")
    blob = pe["data"][text["rawptr"]:text["rawptr"] + text["rawsize"]]
    tva = base + text["vaddr"]
    out = {}
    for m in LEA_RIP.finditer(blob):
        i = m.start()
        if i + 7 > len(blob):
            continue
        disp = struct.unpack_from("<i", blob, i + 3)[0]
        site = tva + i
        out.setdefault(site + 7 + disp, []).append(site)
    return out


def pdata_functions(pe):
    """.pdata(RUNTIME_FUNCTION)로 정확한 함수 경계. 휴리스틱 없음."""
    data = pe["data"]
    pe_off = struct.unpack_from("<I", data, 0x3C)[0]
    opt = pe_off + 4 + 20
    dd = opt + 112
    exc_rva, exc_size = struct.unpack_from("<II", data, dd + 3 * 8)
    off = pe["rva_to_off"](exc_rva)
    ranges = []
    for i in range(exc_size // 12):
        b, e, _ = struct.unpack_from("<III", data, off + i * 12)
        ranges.append((b, e))
    ranges.sort()
    return ranges


def make_fn_of(pe, ranges):
    import bisect
    starts = [r[0] for r in ranges]

    def fn_of(va):
        rva = va - pe["imageBase"]
        j = bisect.bisect_right(starts, rva) - 1
        if j >= 0 and ranges[j][0] <= rva < ranges[j][1]:
            return (pe["imageBase"] + ranges[j][0], pe["imageBase"] + ranges[j][1])
        return None
    return fn_of


def all_string_vas(pe, name):
    """NUL 로 앞뒤가 끊긴 name 의 모든 등장 VA. 소문자 흔한 이름은 여러 번 나온다."""
    base = pe["imageBase"]
    pat = b"\0" + name.encode("ascii") + b"\0"
    out = []
    for s in pe["sections"]:
        if s["name"] not in (".rdata", ".data"):
            continue
        blob = pe["data"][s["rawptr"]:s["rawptr"] + s["rawsize"]]
        va0 = base + s["vaddr"]
        i = blob.find(pat)
        while i >= 0:
            out.append(va0 + i + 1)
            i = blob.find(pat, i + 1)
    return out


def referencing_functions(leas, fn_of, vas):
    """주어진 문자열 VA 들을 lea 로 참조하는 .pdata 함수 집합."""
    fns = set()
    for va in vas:
        for site in leas.get(va, []):
            f = fn_of(site)
            if f:
                fns.add(f)
    return fns


def find_pointer_table(pe, wanted):
    """wanted(VA 집합)를 원소로 갖는 8바이트 포인터 배열을 .rdata/.data 에서 찾는다."""
    base = pe["imageBase"]
    hits = {}
    for s in pe["sections"]:
        if s["name"] not in (".rdata", ".data"):
            continue
        blob = pe["data"][s["rawptr"]:s["rawptr"] + s["rawsize"]]
        va0 = base + s["vaddr"]
        for off in range(0, len(blob) - 8, 8):
            q = struct.unpack_from("<Q", blob, off)[0]
            if q in wanted:
                hits[q] = va0 + off
    return hits


# ─────────────────────────────────────────────────────── lib.sceneScript.d.ts

BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
TOP_DECL = re.compile(r"^\s*(?:declare\s+)?(interface|class|module)\s+'?([A-Za-z_][\w]*)'?")
GLOBAL_DECL = re.compile(r"^\s*declare\s+let\s+(\w+)\s*:\s*([^;]+);")
MEMBER_FN = re.compile(r"^\s*(static\s+)?(?:readonly\s+)?(\w+)\??\s*\(([^)]*)\)\s*(?::\s*([^;{]+))?;")
# 세미콜론은 선택 — d.ts 에 빠뜨린 줄이 실제로 있다(CursorEvent.worldPosition, 1030행).
MEMBER_PROP = re.compile(r"^\s*(static\s+)?(readonly\s+)?(\w+)\??\s*:\s*([^;=]+?)\s*(?:=\s*(.+?))?\s*;?\s*$")
EXPORT_FN = re.compile(r"^\s*export\s+function\s+(\w+)\s*\(([^)]*)\)\s*:\s*([^;]+);")
EXPORT_LET = re.compile(r"^\s*export\s+let\s+(\w+)\s*:\s*([^;]+);")
COMMENTED_MEMBER = re.compile(r"^\s*//\s*(\w+)\??\s*[:(]")


def parse_dts(path):
    raw = open(path, encoding="utf-8").read()
    src = BLOCK_COMMENT.sub(lambda m: "\n" * m.group().count("\n"), raw)
    lines = src.split("\n")

    types, globals_, cur, depth = {}, {}, None, 0
    for line in lines:
        if cur is None:
            g = GLOBAL_DECL.match(line)
            if g:
                globals_[g.group(1)] = g.group(2).strip()
                continue
            t = TOP_DECL.match(line)
            if t and "{" in line:
                cur = {"kind": t.group(1), "name": t.group(2),
                       "extends": [], "members": [], "commentedOut": []}
                ex = re.search(r"\bextends\s+([^{]+)", line)
                if ex:
                    cur["extends"] = [x.strip() for x in ex.group(1).split(",") if x.strip()]
                depth = line.count("{") - line.count("}")
                if depth <= 0:
                    types[cur["name"]] = cur
                    cur = None
            continue

        depth += line.count("{") - line.count("}")
        if depth <= 0:
            types[cur["name"]] = cur
            cur, depth = None, 0
            continue

        c = COMMENTED_MEMBER.match(line)
        if c:
            cur["commentedOut"].append(c.group(1))
            continue
        if line.lstrip().startswith("//"):
            continue

        for rx, kind in ((EXPORT_FN, "fn"), (EXPORT_LET, "prop")):
            m = rx.match(line)
            if m:
                cur["members"].append({"name": m.group(1), "kind": kind})
                break
        else:
            m = MEMBER_FN.match(line)
            if m:
                cur["members"].append({
                    "name": m.group(2), "kind": "fn",
                    "static": bool(m.group(1)),
                    "args": m.group(3).strip(),
                    "returns": (m.group(4) or "void").strip()})
                continue
            m = MEMBER_PROP.match(line)
            if m:
                cur["members"].append({
                    "name": m.group(3), "kind": "prop",
                    "static": bool(m.group(1)),
                    "readonly": bool(m.group(2)),
                    "type": m.group(4).strip(),
                    **({"value": m.group(5).strip()} if m.group(5) else {})})
    return types, globals_


def member_names(t, statics=None):
    out = []
    for m in t["members"]:
        if statics is True and not m.get("static"):
            continue
        if statics is False and m.get("static"):
            continue
        out.append(m["name"])
    return out


# ─────────────────────────────────────────────────────────── baseclasses.js

# `class Vec2 {` 뿐 아니라 `this.IModelData = class IModelData {` 도 잡아야 한다.
JS_CLASS = re.compile(r"\bclass\s+(\w+)\s*\{")
JS_METHOD = re.compile(r"^\t(static\s+)?(\w+)\s*\(([^)]*)\)\s*\{")
JS_STATIC_FIELD = re.compile(r"^\t(?:static\s+)(\w+)\s*=\s*(.+?);?\s*$")
JS_THIS_ASSIGN = re.compile(r"^this\.(\w+)\s*=")


def parse_baseclasses(path):
    src = open(path, encoding="utf-8").read()
    lines = src.split("\n")
    classes, cur, depth = {}, None, 0
    for line in lines:
        if cur is None:
            m = JS_CLASS.search(line)
            if m and "{" in line:
                cur = {"name": m.group(1), "methods": [], "statics": []}
                depth = line.count("{") - line.count("}")
            continue
        # 중괄호를 더하기 **전에** 판정한다. 메서드 여는 줄은 그 자체로 depth 를 올리므로
        # 먼저 더하면 클래스 본문(depth 1)이 절대 관측되지 않는다.
        if depth == 1:
            m = JS_METHOD.match(line)
            if m:
                (cur["statics"] if m.group(1) else cur["methods"]).append(m.group(2))
            else:
                m = JS_STATIC_FIELD.match(line)
                if m:
                    cur["statics"].append(m.group(1))
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            classes[cur["name"]] = cur
            cur = None

    injected = [m.group(1) for line in lines for m in [JS_THIS_ASSIGN.match(line)] if m]
    internal = re.findall(r"^\t(\w+)\(", src[src.index("this._Internal"):], re.M)
    props = re.findall(r"^\t\t(\w+):\s*function", src[src.index("this.createScriptProperties"):], re.M)
    return classes, injected, internal, props


def parse_jsmodules(dirpath):
    out = {}
    for fn in sorted(os.listdir(dirpath)):
        if not fn.endswith(".js"):
            continue
        src = open(os.path.join(dirpath, fn), encoding="utf-8").read()
        names = re.findall(r"^export\s+(?:function|let|const|var)\s+(\w+)", src, re.M)
        out[fn] = names
    return out


# ────────────────────────────────────────────────────────────────── 분류

# 군집 안에서 API 이름이 아닌 것(에러 메시지·CRT/JSON 잡음). 접두로 걸러낸다.
NOISE_PREFIX = ("Invalid ", "Cannot ", "Vertex ", "Index ", "Model ", "Buffer ",
                "Incorrect ", "Material ", "Shapes ", "Inconsistent ", "Script ",
                "Resolution ", "unordered_map", "invalid hash", "ios_base",
                "iostream", "bad locale", "system error", "JS base class",
                "Error: ", "Log: ", "<member>", "models/", "materials/", "scripts/",
                "IModelData.", " cannot", "registerAudioBuffers can", "setTimeout cannot",
                "setInterval cannot", "timeout cannot", "Failed ")


def is_api_name(s):
    if any(s.startswith(p) for p in NOISE_PREFIX):
        return False
    return bool(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", s))


def main():
    specfmt.require_inputs(
        "measure_script_api",
        ("file", DLL, "WE_ROOT", "scenescript64.dll"),
        ("file", EXE, "WE_ROOT", "wallpaper64.exe"),
        ("file", DTS, "WE_ROOT", "sceneScript TypeScript 정의"),
        ("file", BASECLASSES, "WE_ROOT", "baseclasses.js"),
        ("dir", JSMODULES, "WE_ROOT", "JS modules"),
    )
    dll, exe = read_pe(DLL), read_pe(EXE)
    dll_idx, exe_idx = string_va_index(dll), string_va_index(exe)
    types, dts_globals = parse_dts(DTS)
    classes, injected, internal, propbuilder = parse_baseclasses(BASECLASSES)
    modules = parse_jsmodules(JSMODULES)

    cluster = [(va, s) for va, s in strings_in_va_range(dll, BIND_LO, BIND_HI)]
    cluster_names = {s: hex(va) for va, s in cluster if is_api_name(s)}
    cluster_va = {}
    for va, s in cluster:
        cluster_va.setdefault(va, s)

    # 등록 흐름: 바인딩 문자열을 참조하는 lea 를 주소순으로 세우면
    # 네이티브가 어떤 순서로 무엇을 등록하는지 그대로 읽힌다.
    leas = lea_targets(dll)
    fn_of = make_fn_of(dll, pdata_functions(dll))
    trace = []
    for tgt, sites in leas.items():
        if tgt not in cluster_va:
            continue
        for st in sites:
            trace.append((st, cluster_va[tgt]))
    trace.sort()

    def trace_in(lo, hi):
        return [{"site": hex(a), "name": n} for a, n in trace if lo <= a < hi]

    def dll_va(name):
        """WE 바인딩 군집 안의 주소만. 군집 밖 동일 바이트열은 V8/CRT 것이라 세지 않는다."""
        return cluster_names.get(name)

    def exe_va(name):
        """레이어 바인딩 구간 안의 주소만."""
        if name not in exe_idx:
            return None
        va = exe_idx[name][0]
        for lo, hi, _ in EXE_BIND_REGIONS:
            if lo <= va < hi:
                return hex(va)
        return None

    def exe_region(name):
        if name not in exe_idx:
            return None
        va = exe_idx[name][0]
        for lo, hi, tag in EXE_BIND_REGIONS:
            if lo <= va < hi:
                return tag
        return None

    ev_dll = specfmt.ev("binary", "bin/scenescript64.dll .rdata 문자열 군집 0x1819a2b50~0x1819a3c10",
                        "PE 섹션 매핑 후 인쇄가능 런 전수 — scripts/spec/measure_script_api.py")
    ev_exe = specfmt.ev("binary", "wallpaper64.exe .rdata 문자열 전수 스캔")
    ev_dts = specfmt.ev("file",
                        "ui/dist/monaco/autocomplete/lib.sceneScript.d.ts (2570행, 66,051B)",
                        "편집기 Monaco 자동완성용 공식 배포물 — 헤더 'OFFICIAL SCENESCRIPT "
                        "TYPE DECLARATION - VERSION 2.8'")
    ev_js = specfmt.ev("asset", "assets/scripts/jsclasses/baseclasses.js (1457행, 38,646B)")
    ev_mod = specfmt.ev("asset", "assets/scripts/jsmodules/{wemath,wevector,wecolor}.js")
    ev_swift = specfmt.ev("file", "Sources/WapleRender/TextScriptEngine.swift (2067행)")

    E = []

    # ── 1. DLL 자체
    exports = read_exports(dll)
    EXPORT_ROLE = {
        "Init": "엔진 전역 1회 초기화(V8 플랫폼/스냅샷). CreateSceneScriptEngine 앞에 온다",
        "Shutdown": "Init 의 짝 — 전역 해제",
        "CreateSceneScriptEngine": "씬 1개당 스크립트 엔진 인스턴스 생성. 유일한 실팩토리",
        "GetSceneScriptVersion": "바인딩 ABI 버전 질의",
        "CrashForExceptionInNonABICompliantCodeRange": "V8(Chromium) 표준 크래시 핸들러 — WE 것이 아니다",
        "NoHotPatch": "Chromium 빌드 관용 더미 — WE 것이 아니다",
    }
    E.append(specfmt.entry(
        "script.dll.fileBytes", dll["fileBytes"], "확정",
        [specfmt.ev("binary", "bin/scenescript64.dll", "24.3MB 라는 사전 보고와 다르다 — 실측값")]))
    E.append(specfmt.entry(
        "script.dll.exports",
        [{"ordinal": o, "name": n, "rva": hex(r), "va": hex(dll["imageBase"] + r),
          "role": EXPORT_ROLE.get(n, "미상"),
          "origin": "V8/Chromium" if n in ("CrashForExceptionInNonABICompliantCodeRange", "NoHotPatch") else "WE"}
         for n, o, r in exports],
        "확정", [specfmt.ev("binary", "bin/scenescript64.dll export 디렉터리")]))
    E.append(specfmt.entry(
        "script.dll.surface",
        {"exportCount": len(exports), "weExports": 4, "v8Exports": 2,
         "note": "표면이 4개뿐이라 API 는 export 가 아니라 .rdata 바인딩 문자열로만 드러난다. "
                 "이 문서의 네이티브 근거는 전부 그 군집이다."},
        "확정", [specfmt.ev("binary", "bin/scenescript64.dll export 디렉터리")]))

    # ── 2. 바인딩 소유권 분할
    scene_side = ["getLayer", "getLayerByID", "getLayerCount", "enumerateLayers", "createLayer",
                  "destroyLayer", "sortLayer", "getLayerIndex", "getInitialLayerConfig",
                  "getCameraTransforms", "setCameraTransforms", "createModelData", "destroyModelData",
                  "registerAsset", "registerAudioBuffers", "setTimeout", "setInterval", "clearTimeout",
                  "openUserShortcut", "isObjectValid", "timeOfDay", "frametime", "canvasSize",
                  "screenResolution", "userProperties", "cursorWorldPosition", "cursorScreenPosition",
                  "cursorLeftDown", "thisScene", "thisLayer", "thisObject", "localStorage", "engine"]
    layer_side = ["getTransformMatrix", "rotateObjectSpace", "lookAt", "lookAtYaw", "setParent",
                  "getParent", "getChildren", "getAttachmentIndex", "getAttachmentMatrix",
                  "getAttachmentOrigin", "getAttachmentAngles", "transformAttachmentToTexture",
                  "getEffect", "getEffectCount", "getMaterial", "getMaterialCount",
                  "setMaterialProperty", "executeMaterialFunction", "getTextureAnimation",
                  "getVideoTexture", "getAnimationLayer", "getAnimationLayerCount",
                  "createAnimationLayer", "playSingleAnimation", "destroyAnimationLayer",
                  "getBoneCount", "getBoneIndex", "getBoneParentIndex", "getBoneTransform",
                  "setBoneTransform", "getLocalBoneTransform", "setLocalBoneTransform",
                  "getLocalBoneAngles", "setLocalBoneAngles", "getLocalBoneOrigin",
                  "setLocalBoneOrigin", "applyBonePhysicsImpulse", "resetBonePhysicsSimulation",
                  "getBlendShapeIndex", "getBlendShapeWeight", "setBlendShapeWeight",
                  "emitParticles", "addEndedCallback", "parallaxDepth", "getCurrentTime",
                  "setCurrentTime", "join", "rootmotion"]
    E.append(specfmt.entry(
        "script.binding.ownershipSplit",
        {"scenescript64.dll": {
            "owns": "전역(thisScene/thisLayer/thisObject/engine/localStorage/console/input), "
                    "IScene·IEngine·ILocalStorage·IInput 전 멤버, 컴포넌트 훅 19종, "
                    "IModelData, 커서/미디어 이벤트 필드",
            "inBindingCluster": sum(1 for n in scene_side if n in cluster_names),
            "sampleTotal": len(scene_side),
            "absentInExe": [n for n in scene_side if n not in exe_idx]},
         "wallpaper64.exe": {
             "owns": "ILayer/IEffect/IMaterial/IAnimationLayer/ITextureAnimation/IVideoTexture/"
                     "IParticleSystem 의 메서드 이름 — 씬그래프를 쥔 쪽이 등록한다",
             "inBindingRegion": sum(1 for n in layer_side if exe_va(n)),
             "sampleTotal": len(layer_side),
             "absentInDll": [n for n in layer_side if n not in dll_idx]},
         "결론": "레이어 API 이름이 DLL 에 없다고 없는 API 가 아니다. 등록 주체가 EXE 다. "
                 "재구현은 두 바이너리를 합쳐야 전수가 된다."},
        "확정", [ev_dll, ev_exe]))

    # ── 2b. 등록 흐름 — 어느 함수가 무엇을 어떤 순서로 심는가
    def site_of(n):
        return next((a for a, x in trace if x == n), None)

    def site_hex(n, lo=0, hi=1 << 64):
        """이름을 참조하는 lea 사이트 주소. lo/hi 로 함수 범위를 좁힐 수 있다 —
        getAnimation 처럼 IScene 과 IObject 양쪽에 등록되는 이름은 좁히지 않으면 엉뚱한 쪽을 준다."""
        a = next((a for a, x in trace if x == n and lo <= a < hi), None)
        return hex(a) if a is not None else None

    installer = fn_of(site_of("thisObject"))
    scene_fn = fn_of(site_of("thisScene"))
    mod_fn = fn_of(site_of("scripts/jsmodules/"))
    ev_pdata = specfmt.ev(
        "binary",
        "scenescript64.dll .text 의 RIP 상대 lea 전수 + .pdata(RUNTIME_FUNCTION) 함수 경계",
        "휴리스틱 없음 — 함수 경계는 x64 예외 디렉터리가 정확히 알려준다")
    E.append(specfmt.entry(
        "script.binding.registration",
        {"globalInstaller": {
            "range": [hex(installer[0]), hex(installer[1])],
            "bytes": installer[1] - installer[0],
            "does": "커서/미디어 이벤트 필드 → AudioBuffers → scriptProperties 설정 키 → "
                    "IObject.getAnimation·CameraTransforms → thisObject·thisLayer → "
                    "console(log/error 먼저) → engine(멤버 23개 먼저) → input → localStorage → "
                    "scripts/jsclasses/baseclasses.js 로드 → _Vec2.._Mat4·_Internal 핸들 회수",
            "pattern": "객체는 **멤버를 먼저 등록하고 마지막에 객체 이름**을 심는다. "
                       "log(0x181648fcf)/error(0x181649065) 다음 console(0x181649119), "
                       "IEngine 멤버 23개 다음 engine(0x181649d5e), "
                       "cursor* 3개 다음 input(0x181649f11), "
                       "set/get/delete/clear/LOCATION_* 다음 localStorage(0x18164a2d8) — 전부 같은 모양",
            "trace": trace_in(*installer)},
         "sceneTemplate": {
             "range": [hex(scene_fn[0]), hex(scene_fn[1])],
             "bytes": scene_fn[1] - scene_fn[0],
             "does": "IScene 메서드 14개 등록 후 thisScene 전역, 이어서 IModelData "
                     "(applyData/replaceData/prototype)",
             "trace": trace_in(*scene_fn)},
         "moduleResolver": {
             "range": [hex(mod_fn[0]), hex(mod_fn[1])],
             "bytes": mod_fn[1] - mod_fn[0],
             "does": "'scripts/jsmodules/' + 모듈명 + '.js' 로 import 를 해석한다",
             "trace": trace_in(*mod_fn)},
         "sceneRenderProps": "IScene 의 bloom/clearcolor/ambientcolor/fov/nearz/farz/camerashake* 등 "
                             "렌더 프로퍼티는 이 함수에서 등록되지 않는다 — 이름 기반 일반 프로퍼티 "
                             "경로(wallpaper64.exe)로 흐르는 것으로 보인다. 미확증"},
        "확정", [ev_pdata]))

    # ── 3. 전역
    globals_tbl = {}
    for name, typ in dts_globals.items():
        globals_tbl[name] = {"dtsType": typ, "bindingVA": dll_va(name),
                             "inBindingCluster": name in cluster_names,
                             "anywhereInDll": name in dll_idx}
    for name, note in (
        ("thisObject", "d.ts 미선언. 군집에서 thisLayer(0x1819a35d8) 바로 앞. "
                       "전역인지 컴포넌트 문맥 멤버인지는 문자열 인접만으로는 못 가른다"),
        ("console", "군집 0x1819a35f0. 바로 앞 0x1819a35e4 'log' / 0x1819a35e8 'error' 가 "
                    "IConsole 의 두 메서드. 출력 접두 문자열도 군집 끝에 있다"
                    "('Log: ' 0x1819a3af0, 'Error: ' 0x1819a3ae8)"),
        ("input", "군집 0x1819a37e0 — ILocalStorage set/get/delete/clear 바로 앞"),
        ("shared", "**군집에 없다.** baseclasses.js 마지막 줄 `this.shared = {};` 가 실체다 — "
                   "네이티브가 만드는 객체가 아니라 베이스클래스가 심어 두는 빈 객체이고, "
                   "그래서 씬 안 모든 스크립트가 같은 참조를 본다"),
    ):
        if name in globals_tbl:
            globals_tbl[name]["note"] = note
        else:
            globals_tbl[name] = {"dtsType": None, "bindingVA": dll_va(name),
                                 "inBindingCluster": name in cluster_names,
                                 "anywhereInDll": name in dll_idx, "note": note}
    E.append(specfmt.entry(
        "script.globals",
        {"count": len(globals_tbl), "table": globals_tbl,
         "vaMeaning": "bindingVA 는 scenescript64.dll .rdata 의 WE 바인딩 군집 안 주소다. "
                      "군집 밖에 같은 바이트열이 있어도 세지 않는다(V8/CRT 문자열)"},
        "확정", [ev_dts, ev_dll, ev_js]))

    # ── 4. 컴포넌트 훅 전수
    HOOK_ORDER = ["init", "update", "resizeScreen", "destroy", "applyUserProperties",
                  "applyGeneralSettings", "animationEvent", "cursorHitTest", "cursorEnter",
                  "cursorLeave", "cursorMove", "cursorClick", "cursorDown", "cursorUp",
                  "mediaStatusChanged", "mediaPlaybackChanged", "mediaPropertiesChanged",
                  "mediaThumbnailChanged", "mediaTimelineChanged"]
    icomp = member_names(types["IComponent"])
    hook_str_va = {h: int(cluster_names[h], 16) for h in HOOK_ORDER if h in cluster_names}
    ptr_slots = find_pointer_table(dll, set(hook_str_va.values()))
    slot_of = {}
    if ptr_slots:
        tbl_lo = min(ptr_slots.values())
        for h, sva in hook_str_va.items():
            slot_of[h] = (ptr_slots[sva] - tbl_lo) // 8
    hooks = {}
    for h in HOOK_ORDER:
        m = next((x for x in types["IComponent"]["members"] if x["name"] == h), None)
        hooks[h] = {"slot": slot_of.get(h), "nameVA": dll_va(h),
                    "slotVA": hex(ptr_slots[hook_str_va[h]]) if h in hook_str_va else None,
                    "inDts": h in icomp, "arg": (m or {}).get("args") or None}
    tbl_lo = min(ptr_slots.values()) if ptr_slots else None
    E.append(specfmt.entry(
        "script.hooks",
        {"count": len(HOOK_ORDER),
         "dispatchTable": {
             "va": hex(tbl_lo) if tbl_lo else None,
             "entries": len(ptr_slots), "stride": 8,
             "type": "const char*[19]",
             "bounds": "앞은 0x0(0x1819a3ed8), 뒤는 코드 포인터(0x1819a3f78~) — 19개에서 딱 끊긴다",
             "meaning": "이건 문자열 인접이 아니라 실제 훅 디스패치 테이블이다. "
                        "슬롯 번호가 곧 훅 ID 이고 19개가 전부다"},
         "table": hooks,
         "dtsMissing": [h for h in HOOK_ORDER if h not in icomp],
         "export규약": "스크립트가 `export function <hook>(...)` 로 내보내면 네이티브가 "
                       "이 테이블의 이름으로 모듈 export 를 찾아 부른다"},
        "확정", [ev_dll, ev_dts,
                specfmt.ev("binary", "scenescript64.dll .rdata 0x1819a3ee0 의 const char*[19] 포인터 배열",
                           "훅 문자열 VA 를 qword 로 검색해 발견 — 슬롯 순서까지 실측")]))

    # ── 5. d.ts 에 없는 네이티브 바인딩
    guard_va = next((hex(va) for va, s in cluster
                     if s == "timeout cannot be cleared from global scope."), None)
    E.append(specfmt.entry(
        "script.undocumented",
        {"cursorHitTest": {
            "kind": "컴포넌트 훅",
            "nameVA": dll_va("cursorHitTest"),
            "evidence": f"훅 디스패치 테이블 슬롯 {slot_of.get('cursorHitTest')} "
                        f"(0x1819a3ee0 기준 {slot_of.get('cursorHitTest')}번째). "
                        "cursorEnter 바로 앞 — 커서 이벤트 전달 전에 히트 판정을 스크립트에 "
                        "물어보는 훅으로 읽힌다(이름 근거, 시그니처 미확증)",
            "dts": "IComponent 에 없음"},
         "animationEvent": {
             "kind": "컴포넌트 훅",
             "nameVA": dll_va("animationEvent"),
             "evidence": f"훅 디스패치 테이블 슬롯 {slot_of.get('animationEvent')}. "
                         "d.ts 는 AnimationEvent{name, frame} 클래스만 선언하고 "
                         "그걸 받는 훅은 선언하지 않는다",
             "dts": "IComponent 에 없음 / AnimationEvent 클래스는 있음"},
         "isObjectValid": {
             "kind": "IEngine 메서드",
             "nameVA": dll_va("isObjectValid"),
             "evidence": f"전역 설치 함수의 IEngine 멤버 등록 런 안({site_hex('isObjectValid')}) — "
                         f"isScreensaver({site_hex('isScreensaver')})와 "
                         f"openUserShortcut({site_hex('openUserShortcut')}) 사이. "
                         "문서화된 멤버들과 같은 스트라이드로 심긴다",
             "dts": "IEngine 에 없음"},
         "clearTimeout": {
             "kind": "IEngine 메서드",
             "nameVA": dll_va("clearTimeout"),
             "evidence": f"IEngine 멤버 등록 런 안({site_hex('clearTimeout')}) — "
                         f"setInterval({site_hex('setInterval')}) 바로 다음. "
                         f"전용 스코프 가드 문자열도 있다: {guard_va} "
                         "'timeout cannot be cleared from global scope.' "
                         "죽은 심볼이 아니라 살아있는 경로다",
             "dts": "주석 처리 — 'Not implemented. Use returned function to clear.'"},
         "thisObject": {
             "kind": "전역",
             "nameVA": dll_va("thisObject"),
             "evidence": f"전역 설치 함수 안({site_hex('thisObject')})에서 "
                         f"thisLayer({site_hex('thisLayer')}) 직전에 같은 스트라이드로 심긴다. "
                         "같은 함수가 console/engine/input/localStorage 전역도 심는다 — "
                         "컴포넌트 문맥 멤버가 아니라 전역이다",
             "likelyType": "d.ts 의 IThisPropertyObjectBase extends IObject "
                           "('The object this property is bound to'). 이 인터페이스는 선언돼 있는데 "
                           "그걸 담는 전역 declare 가 d.ts 에 없다. 등록 직전에 IObject 의 유일 멤버 "
                           f"getAnimation({site_hex('getAnimation', *installer)})이 심기는 것도 이 해석과 맞는다. "
                           "타입 자체는 미확증",
             "dts": "선언 없음"},
         "button": {
             "kind": "CursorEvent 필드",
             "nameVA": dll_va("button"),
             "evidence": f"CursorEvent 필드 등록 런 선두({site_hex('button')}) — "
                         f"worldPosition({site_hex('worldPosition')})/localPosition/hitBox 와 "
                         "63바이트 등간격",
             "dts": "주석 처리(NOT USED)"}},
        "확정", [ev_dll, ev_dts, ev_pdata]))

    # ── 6. d.ts 선언 중 네이티브 문자열이 없는 것
    unbacked = {}
    for n in ("renderContext", "thisProperty", "IModel", "IAssetHandle"):
        unbacked[n] = {
            "ascii_dll": n in dll_idx, "ascii_exe": n in exe_idx,
            "utf16_dll": has_utf16(DLL, n), "utf16_exe": has_utf16(EXE, n)}
    unbacked["renderContext"]["dts"] = "declare let renderContext: IRenderContext — IRenderContext 는 빈 인터페이스"
    unbacked["thisProperty"]["dts"] = "IThisPropertyObjectBase 인터페이스만 있고 전역 declare 는 없다"
    unbacked["IModel"]["dts"] = "ILayer extends … IModel … 로 참조되나 정의가 없다(d.ts 자체 미정의 참조)"
    unbacked["IAssetHandle"]["dts"] = "registerAsset 반환형/createLayer 인자로 참조되나 정의가 없다"
    E.append(specfmt.entry(
        "script.dts.unbacked", unbacked, "보고",
        [ev_dts, specfmt.ev("binary", "scenescript64.dll · wallpaper64.exe ASCII+UTF-16LE 전수 검색"),
         specfmt.ev("doc", "부재 증거라 약하다. 런타임 조립 이름이면 문자열로 안 잡힌다. "
                           "실행 검증(스크립트에서 typeof renderContext) 전까지 보고 유지",
                     "[2026-08-28] kind 를 열거 밖의 'note' 에서 'doc' 으로 고쳤다 — "
                     "이 ref 는 참조가 아니라 방법의 한계를 적은 산문이다")]))

    # ── 7. IScene / IEngine / ILocalStorage / IInput / IConsole
    for iface, gname in (("IScene", "thisScene"), ("IEngine", "engine"),
                         ("ILocalStorage", "localStorage"), ("IInput", "input"),
                         ("IConsole", "console")):
        t = types[iface]
        tbl = {}
        for m in t["members"]:
            rec = {"kind": m["kind"], "dllVA": dll_va(m["name"])}
            if m["kind"] == "fn":
                rec["args"] = m["args"]
                rec["returns"] = m["returns"]
            else:
                rec["type"] = m.get("type")
                if m.get("value"):
                    rec["value"] = m["value"]
            if m.get("static"):
                rec["static"] = True
            if m.get("readonly"):
                rec["readonly"] = True
            tbl[m["name"]] = rec
        extra = [n for n in cluster_names
                 if n not in tbl and n in ("clearTimeout", "isObjectValid")] if iface == "IEngine" else []
        E.append(specfmt.entry(
            f"script.api.{iface}",
            {"global": gname, "memberCount": len(tbl), "members": tbl,
             **({"dts미선언_추가": {n: cluster_names[n] for n in extra}} if extra else {}),
             **({"commentedOutInDts": t["commentedOut"]} if t["commentedOut"] else {})},
            "확정", [ev_dts, ev_dll]))

    # ── 8. ILayer 와 그 믹스인
    #
    # EXE 쪽은 DLL 군집처럼 깨끗하지 않다. alpha/color/text/visible 같은 전소문자 멤버는
    # scene.json 키로도 쓰여 문자열 존재만으로는 JS 바인딩을 확증할 수 없었다(종전 69건 ambiguous).
    # 그래서 DLL 에 쓴 것과 같은 도구를 EXE 에 그대로 적용한다: 문자열을 참조하는 lea 를 찾고
    # .pdata 로 그 lea 가 어느 함수 안인지 본다. 앵커(누구도 JSON 키로 오해하지 않는 카멜케이스
    # 메서드)를 참조하는 함수 집합을 "레이어 바인딩 함수"로 정의하고, 전소문자 멤버가 그 함수
    # 안에서 참조되면 JS 바인딩으로 확정한다.
    layer_mixins = ["IObject", "IImageLayer", "ISoundLayer", "IEffectLayer", "ITextLayer",
                    "IParticleSystem", "IParticleSystemInstance", "IModelLayer", "ICamera",
                    "IEffect", "IMaterial", "IAnimation", "IAnimationLayer",
                    "ITextureAnimation", "IVideoTexture", "IModelData"]
    exe_leas = lea_targets(exe)
    exe_fn_of = make_fn_of(exe, pdata_functions(exe))
    fam_names = {m["name"] for i in ["ILayer"] + layer_mixins for m in types[i]["members"]}
    fn_names = {}
    for n in fam_names:
        for sva in all_string_vas(exe, n):
            for site in exe_leas.get(sva, []):
                f = exe_fn_of(site)
                if f:
                    fn_names.setdefault(f, set()).add(n)
    # 등록자 판정: 이 계열 이름을 5개 이상 참조하고, 1000바이트당 1개 이상 밀도.
    # 밀도 조건이 씬 JSON 파서(0x1401c5b2f, 27KB 에 5개 = 0.00019/B)를 걸러낸다 —
    # 등록자는 이름을 촘촘히 늘어놓지만 파서는 넓은 코드에 흩어 쓴다.
    binding_fns = {f for f, ns in fn_names.items()
                   if len(ns) >= 5 and len(ns) * 1000 >= (f[1] - f[0])}

    def best_iface(ns):
        """커버리지 우선, 동점이면 그 함수의 이름을 더 많이 설명하는 쪽.
        IAnimation ⊂ IAnimationLayer 처럼 포함관계가 있어 동점이 실제로 난다."""
        best, key = None, (0.0, 0)
        for i in ["ILayer"] + layer_mixins:
            mem = {m["name"] for m in types[i]["members"]}
            if not mem:
                continue
            hit = len(ns & mem)
            k = (hit / len(mem), hit)
            if k > key:
                best, key = i, k
        return best, round(key[0], 2)

    registrars = {}
    for f in sorted(binding_fns):
        iface, score = best_iface(fn_names[f])
        registrars[hex(f[0])] = {"bytes": f[1] - f[0], "names": len(fn_names[f]),
                                 "bestMatch": iface, "coverage": score,
                                 "registers": sorted(fn_names[f])}

    def exe_binding_sites(name):
        """레이어 등록자 함수 안에서 이 이름을 참조하는 (문자열VA, 사이트VA, 함수시작) 목록."""
        out = []
        for sva in all_string_vas(exe, name):
            for site in exe_leas.get(sva, []):
                f = exe_fn_of(site)
                if f in binding_fns:
                    out.append((sva, site, f[0]))
        return out

    js_statics = set(classes.get("IModelData", {}).get("statics", []))
    layer_tbl = {}
    resolved, still_ambiguous = [], []
    for iface in ["ILayer"] + layer_mixins:
        t = types[iface]
        tbl = {}
        for m in t["members"]:
            name = m["name"]
            methodish = m["kind"] == "fn" or re.search(r"[a-z][A-Z]", name)
            rec = {"kind": m["kind"]}
            if m["kind"] == "fn":
                rec["args"] = m["args"]
                rec["returns"] = m["returns"]
            else:
                rec["type"] = m.get("type")
                if m.get("value"):
                    rec["value"] = m["value"]
            sites = exe_binding_sites(name)
            if iface == "IModelData" and name in js_statics:
                rec["nameVA"] = None
                rec["boundIn"] = "baseclasses.js (JS static)"
            elif sites:
                rec["nameVA"] = hex(sites[0][0])
                rec["boundIn"] = "wallpaper64.exe"
                rec["registrarFn"] = sorted({hex(f) for _, _, f in sites})
                if not methodish:
                    resolved.append(f"{iface}.{name}")
            elif dll_va(name):
                rec["nameVA"] = dll_va(name)
                rec["boundIn"] = "scenescript64.dll"
            else:
                rec["nameVA"] = None
                rec["boundIn"] = None
                rec["evidence"] = "레이어 바인딩 함수에서 참조되지 않는다 — d.ts 선언이 유일 근거"
                if not methodish:
                    still_ambiguous.append(f"{iface}.{name}")
            tbl[name] = rec
        layer_tbl[iface] = {"extends": t["extends"], "members": tbl,
                            **({"commentedOutInDts": t["commentedOut"]} if t["commentedOut"] else {})}
    E.append(specfmt.entry(
        "script.api.ILayer",
        {"global": "thisLayer",
         "composition": types["ILayer"]["extends"],
         "note": "d.ts 의 ILayer extends 목록에 IModel 이 있으나 IModel 정의는 d.ts 에 없다(미정의 참조). "
                 "IModelLayer 가 실제 모델 레이어 인터페이스다.",
         "method": "wallpaper64.exe .text 의 RIP 상대 lea 전수 + .pdata 함수 경계. "
                   "이 계열 이름을 5개 이상, 1000바이트당 1개 이상 밀도로 참조하는 함수를 "
                   f"'등록자'로 잡았다({len(binding_fns)}개). 그 안에서 참조되는 이름만 바인딩으로 "
                   "인정한다 — 문자열이 EXE 어딘가에 있다는 사실은 근거로 세지 않는다. "
                   "밀도 조건이 씬 JSON 파서를 걸러낸다(27KB 함수에 5개 = 0.19/1000B)",
         "registrars": registrars,
         "registrarNote": "등록자 함수가 d.ts 인터페이스와 거의 일대일로 대응한다 — "
                          "bestMatch/coverage 가 그 대응이다. 인터페이스 분해가 문서상 편의가 아니라 "
                          "구현 구조 그대로라는 뜻",
         "resolvedLowercase": {"count": len(resolved), "names": resolved,
                               "note": "전소문자라 종전에 확증 불가로 남겼던 멤버 중 "
                                       "레이어 바인딩 함수 안에서 참조가 잡힌 것들"},
         "stillAmbiguous": {"count": len(still_ambiguous), "names": still_ambiguous},
         "interfaces": layer_tbl},
        "확정", [ev_dts, specfmt.ev(
            "binary", "wallpaper64.exe .text RIP 상대 lea 전수 + .pdata(RUNTIME_FUNCTION) 함수 경계")]))

    # ── 8b. 전수성 — 등록된 것과 선언된 것을 맞춰 본다
    #
    # "d.ts 를 옮겨 적었다"와 "네이티브 등록과 선언이 일치한다"는 다른 주장이다.
    # 등록 흐름에서 각 객체의 멤버 런을 잘라 선언과 집합 차를 낸다. 차가 0 이면 전수다.
    inst_seq = [x["name"] for x in trace_in(*installer)]

    def slice_between(seq, a, b):
        try:
            i, j = seq.index(a), seq.index(b)
        except ValueError:
            return []
        return seq[i + 1:j]

    scene_seq = [x["name"] for x in trace_in(*scene_fn)]
    runs = {
        "IConsole": (set(slice_between(inst_seq, "thisLayer", "console")), "console"),
        "IEngine": (set(slice_between(inst_seq, "console", "engine")), "engine"),
        "IInput": (set(slice_between(inst_seq, "engine", "input")), "input"),
        # global/screen 은 LOCATION_* 상수의 값 문자열이지 멤버가 아니다.
        "ILocalStorage": (set(slice_between(inst_seq, "input", "localStorage"))
                          - {"global", "screen"}, "localStorage"),
        "IScene": (set(scene_seq[:scene_seq.index("thisScene")]), "thisScene"),
    }
    closure = {}
    for iface, (reg, obj) in runs.items():
        decl = {m["name"] for m in types[iface]["members"]}
        closure[iface] = {
            "registered": len(reg), "declared": len(decl),
            "extra(등록됐는데 d.ts 에 없음)": sorted(reg - decl),
            "missing(선언됐는데 이 런에 없음)": sorted(decl - reg),
            "terminator": obj}
    for iface, fva in [(v["bestMatch"], k) for k, v in registrars.items()]:
        if iface in closure:
            continue
        reg = set(registrars[fva]["registers"])
        decl = {m["name"] for m in types[iface]["members"]}
        closure[iface] = {
            "registered": len(reg & decl), "declared": len(decl),
            "extra(등록됐는데 d.ts 에 없음)": sorted(reg - decl),
            "missing(선언됐는데 이 런에 없음)": sorted(decl - reg),
            "registrarFn": fva}
    closure["IComponent(훅)"] = {
        "registered": len(HOOK_ORDER), "declared": len(icomp),
        "extra(등록됐는데 d.ts 에 없음)": [h for h in HOOK_ORDER if h not in icomp],
        "missing(선언됐는데 이 런에 없음)": [h for h in icomp if h not in HOOK_ORDER],
        "terminator": "const char*[19] @0x1819a3ee0"}
    E.append(specfmt.entry(
        "script.binding.closure", {
            "meaning": "각 인터페이스에 대해 네이티브가 실제 등록하는 이름 집합과 d.ts 선언 집합의 차. "
                       "missing 이 비면 선언이 등록을 다 덮고, extra 가 비면 선언이 과하지 않다 — "
                       "둘 다 비면 그 인터페이스의 전수는 증명된 것이다",
            "table": closure,
            "mixinDrift": "ILayer 계열의 extra/missing 은 '없는 멤버'가 아니라 d.ts 와 네이티브가 "
                          "멤버를 서로 다른 믹스인에 넣은 것이다: solid 는 ILayer 등록자가 심는데 "
                          "d.ts 는 IEffectLayer 에 선언하고, alpha/color 는 IEffectLayer 등록자가 "
                          "심는데 d.ts 는 IImageLayer/ITextLayer 에 선언하며, visible 은 "
                          "ILayer/IModelLayer/IParticleSystem/IEffect 등록자가 각각 심는다. "
                          "ILayer 가 이 믹스인들의 합집합이라 스크립트가 보는 표면은 동일하다 — "
                          "재구현 시 믹스인 경계를 d.ts 대로 나눌 이유가 없다는 뜻",
            "IScene.renderProps": "IScene 의 missing 은 bloom/clearcolor/ambientcolor/fov/nearz/farz/"
                                  "camerashake*/cameraparallax* 등 렌더 프로퍼티다. 씬 템플릿 함수에서 "
                                  "등록되지 않는다 — 이름 기반 일반 프로퍼티 경로로 흐르는 것으로 보이나 "
                                  "그 경로는 미확인",
        }, "확정", [ev_pdata, ev_dts]))

    # ── 8c. 군집 잔여 — 일곱 번째 미문서 이름이 없다는 것까지 보인다
    explained = set()
    for t in types.values():
        explained |= {m["name"] for m in t["members"]}
        explained |= set(t["commentedOut"])
    explained |= set(HOOK_ORDER) | set(dts_globals)
    explained |= {"thisObject", "isObjectValid", "clearTimeout", "button",
                  "animationEvent", "cursorHitTest"}
    explained |= {"_config", "combo", "int", "float", "global", "screen"}
    explained |= {"_Vec2", "_Vec3", "_Vec4", "_Mat3", "_Mat4", "_Internal", "__modelDataToken",
                  "__workshopId", "convertUserProperties", "updateScriptProperties",
                  "stringifyConfig"}
    explained |= {"shapes", "vertexBuffer", "indexBuffer", "vertexFormat", "material",
                  "isVertexBufferDynamic", "isIndexBufferDynamic", "boundingBoxMins",
                  "boundingBoxMaxs", "position", "normal", "tangentSigned", "instance",
                  "sprite", "particle", "image", "font", "path", "sound", "effects", "file",
                  "passes", "textures", "model", "text", "light", "camera", "models", "particles",
                  "materials", "sounds", "json", "js", "workshop", "top", "left", "right"}
    explained |= {"commentStyle", "indentation", "emitUTF8", "precision", "collectComments", "None"}
    # scriptProperties 설정 키 / IModelData 값 문자열 / JS 리플렉션
    explained |= {"scriptProperties", "label", "mode", "order", "min", "max", "options",
                  "value", "uv", "prototype", "IModelData"}
    residue = sorted(n for n in cluster_names if n not in explained)

    # 군집 문자열을 가리키는 8바이트 포인터 배열 전수 — 훅 테이블 말고 또 있는가
    all_cluster_vas = {int(v, 16) for v in cluster_names.values()}
    slots = find_pointer_table(dll, all_cluster_vas)
    by_slot = sorted((s, v) for v, s in slots.items())
    tables, run = [], []
    for s, v in by_slot:
        if run and s == run[-1][0] + 8:
            run.append((s, v))
        else:
            if len(run) >= 3:
                tables.append(run)
            run = [(s, v)]
    if len(run) >= 3:
        tables.append(run)
    E.append(specfmt.entry(
        "script.binding.clusterResidue",
        {"clusterNames": len(cluster_names),
         "unexplained": residue,
         "note": "군집 170개 중 d.ts 멤버·훅·scriptProperties 설정 키·IModelData 셰이프 키·"
                 "위에서 밝힌 미문서 6종·에셋 경로/JSON 잡음으로 설명되지 않는 나머지. "
                 "비어 있으면 일곱 번째 미문서 이름은 없다",
         "context": {
             "nameVA": dll_va("context"),
             "site": site_hex("context", *installer),
             "position": "전역 설치 함수에서 localStorage 등록 직후, "
                         "scripts/jsclasses/baseclasses.js 로드 직전",
             "status": "추정 — baseclasses.js 는 `this._Vec2 = …` / `this.shared = {}` 처럼 "
                       "this 에 심는다. 그 this 로 쓰이는 객체의 이름일 가능성이 있으나 확인 못 했다. "
                       "d.ts 의 renderContext 와는 무관해 보인다(그 문자열은 어느 바이너리에도 없다)"},
         "pointerTables": [{"va": hex(r[0][0]), "count": len(r),
                            "names": [cluster_va.get(v) for _, v in r]} for r in tables],
         "pointerTableNote": "군집 문자열을 원소로 갖는 8바이트 포인터 배열 전수(길이 3 이상). "
                             "훅 디스패치 테이블 하나만 나오면 훅이 19개로 닫힌다는 뜻"},
        "확정", [ev_dll, ev_dts]))

    # ── 9. d.ts 에 없는 EXE 측 파티클 인스턴스 프로퍼티
    extra_particle = [n for n in ("controlpointangle0", "controlpointangle1", "controlpointangle2",
                                  "controlpointangle3", "controlpointangle4", "controlpointangle5",
                                  "controlpointangle6", "controlpointangle7", "emitterimage",
                                  "instanceoverride") if n in exe_idx]
    E.append(specfmt.entry(
        "script.api.IParticleSystemInstance.extra",
        {"names": {n: exe_va(n) for n in extra_particle},
         "dts": "IParticleSystemInstance 는 controlpoint0..7 만 선언한다",
         "caveat": "전소문자라 파티클 JSON 키일 수도 있다 — JS 바인딩 확증은 XREF 필요"},
        "보고", [ev_exe]))

    # ── 10. baseclasses.js — JS 측 정본
    same = True
    for rel in ("jsclasses/baseclasses.js", "jsmodules/wemath.js",
                "jsmodules/wevector.js", "jsmodules/wecolor.js"):
        a = os.path.join(WE, "assets", "scripts", *rel.split("/"))
        b = os.path.join(REPO_ASSETS, *rel.split("/"))
        if not (os.path.exists(b) and open(a, "rb").read() == open(b, "rb").read()):
            same = False
    E.append(specfmt.entry(
        "script.baseclasses",
        {"loadPath": "scripts/jsclasses/baseclasses.js",
         "loadPathVA": dll_va("scripts/jsclasses/baseclasses.js"),
         "moduleResolution": {"prefix": dll_va("scripts/jsmodules/") and "scripts/jsmodules/",
                              "suffix": ".js",
                              "note": "import * as X from 'X' → scripts/jsmodules/X.js. "
                                      "WEMath/WEVector/WEColor 이름 자체는 바이너리에 없다 — "
                                      "스크립트의 import 문에서 온다"},
         "errorString": "JS base class error: %s",
         "nativeHandles": {n: dll_va(n) for n in ("_Vec2", "_Vec3", "_Vec4", "_Mat3", "_Mat4",
                                                  "_Internal", "__modelDataToken", "__workshopId")},
         "handleMeaning": "baseclasses.js 가 `this._Vec3 = Vec3.prototype` 로 프로토타입을 내주면 "
                          "네이티브가 그 핸들로 Vec3 인스턴스를 직접 만들어 스크립트에 넘긴다. "
                          "즉 Vec2/Vec3/Vec4/Mat3/Mat4 는 네이티브 클래스가 아니라 이 JS 파일이 정본이다",
         "classes": {k: {"methodCount": len(v["methods"]), "methods": v["methods"],
                         "statics": v["statics"]} for k, v in classes.items()},
         "injectedGlobals": injected,
         "repoCopyIdentical": same,
         "repoCopyPath": REPO_ASSETS.replace("\\", "/")},
        "확정", [ev_js, ev_dll]))

    # ── 11. _Internal 주입 프로토콜
    E.append(specfmt.entry(
        "script.protocol._Internal",
        {"members": internal,
         "va": {n: dll_va(n) for n in ("_Internal", "convertUserProperties",
                                       "updateScriptProperties", "stringifyConfig")},
         "direction": "네이티브 → JS. 세 함수 모두 baseclasses.js 에 있고 네이티브가 이름으로 호출한다",
         "updateScriptProperties(script, varsJSON)":
             "JSON 문자열을 파싱해 script.scriptProperties 의 **기존 키만** 덮어쓴다. "
             "기존 값이 Vec3 이면 새 값을 new Vec3(문자열) 로 승격한다 — "
             "색 프로퍼티가 'r g b' 문자열로 와도 스크립트는 Vec3 메서드를 쓸 수 있다",
         "convertUserProperties(pJSON)":
             "{key:{type,value}} 를 {key: 원시값} 으로 평탄화한다. type=='color' 는 new Vec3(value), "
             "type=='usershortcut' 은 {isbound, commandtype, file} 객체, 나머지는 value 그대로. "
             "→ engine.userProperties 는 래퍼가 아니라 원시값 맵이다",
         "stringifyConfig(obj)":
             "JSON.stringify(obj, stringifyAdapter). stringifyAdapter 는 값에 toConfigString 이 "
             "있으면 그것을 쓴다 — Vec2/Vec3/Vec4/Mat3/Mat4/IModelData 가 전부 toConfigString 을 "
             "가지므로 설정 왕복 시 'x y z' 공백구분 문자열로 직렬화된다"},
        "확정", [ev_js, ev_dll]))

    # ── 12. scriptproperties 주입 규약
    E.append(specfmt.entry(
        "script.protocol.scriptProperties",
        {"factory": "createScriptProperties()",
         "factoryMethods": propbuilder,
         "factoryInBinary": "createScriptProperties" in dll_idx,
         "factoryNote": "네이티브에 이 이름이 없다. 스크립트가 부르는 JS 팩토리라 네이티브는 "
                        "결과 객체만 읽는다 — 부재가 곧 방향(JS→네이티브)의 증거",
         "produces": "addX({name, value, label, ...}) 마다 vars[name]=value 와 "
                     "vars[name+'_config']={order, label, ...} 를 함께 만든다. finish() 가 vars 반환",
         "configKeys": {n: dll_va(n) for n in ("scriptProperties", "_config", "order",
                                               "label", "mode", "options", "combo")},
         "modes": {"addSlider": "options.integer===true 이면 mode:'int', 아니면 mode 없음(float). min/max 동반",
                   "addCombo": "mode:'combo', options 배열 그대로. 초기값은 options[0].value",
                   "addCheckbox": "mode 없음(bool)", "addText": "mode 없음", "addColor": "mode 없음"},
         "runtimeUpdate": "사용자가 편집기에서 값을 바꾸면 네이티브가 "
                          "_Internal.updateScriptProperties(script, JSON) 을 호출한다. "
                          "스크립트는 script.scriptProperties.<name> 을 그냥 읽으면 된다",
         "exportName": "스크립트는 `export let scriptProperties = createScriptProperties()...finish();`"},
        "확정", [ev_js, ev_dll]))

    # ── 13. update(value) 규약
    ic = types["IComponent"]["members"]
    init_m = next(m for m in ic if m["name"] == "init")
    upd_m = next(m for m in ic if m["name"] == "update")
    E.append(specfmt.entry(
        "script.contract.update",
        {"binding": "SceneScript 는 프로퍼티 바인딩이다 — 스크립트 1개가 레이어의 프로퍼티 1개에 붙는다",
         "init.args": init_m["args"], "init.returns": init_m["returns"],
         "update.args": upd_m["args"], "update.returns": upd_m["returns"],
         "rule1_returnValue": "update 는 바인딩된 프로퍼티와 **정확히 같은 타입**을 반환해야 한다. "
                              "Color 에 붙었으면 Vec3 를 받아 Vec3 를 반환한다",
         "rule2_assignmentException": "여러 프로퍼티를 한 번에 바꿔야 하면 직접 대입"
                                      "(thisLayer.scale = new Vec3(...))이 허용되고 권장된다 — "
                                      "무거운 오디오 처리를 프로퍼티마다 복제하지 않기 위해",
         "rule3_preferHooks": "update 는 선택이고 매 프레임 돈다. init/resizeScreen/"
                              "applyUserProperties/cursorClick 로 옮길 수 있으면 옮기라는 것이 공식 지침",
         "rule4_useStrict": "모든 프로퍼티 스크립트는 'use strict' 를 쓰라고 명시",
         "generalPurposeSlot": "레이어 하나에 붙일 범용 스크립트는 관례상 Visibility 프로퍼티에 바인딩",
         "typeAsymmetry": "init/update 의 인자 유니온에는 Mat4|Mat3 가 있는데 반환 유니온에는 없다. "
                          "d.ts 오타인지 실제로 행렬 프로퍼티는 대입 전용인지는 미확정",
         "scopeGuards": [s for _, s in cluster if "global scope" in s]},
        "확정", [ev_dts, ev_dll]))

    # ── 14. 이벤트 클래스
    event_types = ["CursorEvent", "AnimationEvent", "MediaPlaybackEvent", "MediaStatusEvent",
                   "MediaPropertiesEvent", "MediaThumbnailEvent", "MediaTimelineEvent",
                   "CameraTransforms", "AudioBuffers"]
    ev_tbl = {}
    for n in event_types:
        t = types[n]
        ev_tbl[n] = {
            "fields": {m["name"]: {"type": m.get("type"), "va": dll_va(m["name"]),
                                   **({"value": m["value"]} if m.get("value") else {}),
                                   **({"static": True} if m.get("static") else {})}
                       for m in t["members"]},
            **({"commentedOutInDts": t["commentedOut"]} if t["commentedOut"] else {})}
    ev_tbl["MediaPlaybackEvent"]["jsDefinedIn"] = (
        "baseclasses.js — PLAYBACK_STOPPED=0 / PLAYBACK_PLAYING=1 / PLAYBACK_PAUSED=2 "
        "가 JS static 필드로 실재한다(네이티브 문자열 없음)")
    ev_tbl["AnimationEvent"]["hook"] = "animationEvent(event) — d.ts IComponent 미선언, DLL 훅 런에 존재"
    E.append(specfmt.entry("script.api.events", ev_tbl, "확정", [ev_dts, ev_dll, ev_js]))

    # ── 15. 벡터/행렬 클래스
    vecs = {}
    undocumented_js = {}
    for n in ("Vec2", "Vec3", "Vec4", "Mat3", "Mat4"):
        dts_m = set(member_names(types[n]))
        js_m = set(classes[n]["methods"]) | set(classes[n]["statics"])
        only_js = sorted(js_m - dts_m - {"constructor"})
        vecs[n] = {"jsMethods": classes[n]["methods"], "jsStatics": classes[n]["statics"],
                   "jsMethodCount": len(classes[n]["methods"]),
                   "onlyInJS": only_js,
                   "onlyInDts": sorted(dts_m - js_m - {"constructor", "x", "y", "z", "w", "m"})}
        if only_js:
            undocumented_js[n] = only_js
    E.append(specfmt.entry(
        "script.api.vectors",
        {"definedIn": "assets/scripts/jsclasses/baseclasses.js — 순수 JS. 네이티브 바인딩이 아니다",
         "dtsVsJs": "d.ts 선언과 JS 구현이 Vec2/Vec3/Vec4/Mat4 에서 정확히 일치한다"
                    "(onlyInDts 전부 빈 배열) — 선언이 실물을 따라간다는 뜻이라 d.ts 를 근거로 쓸 수 있다",
         "undocumentedInJS": undocumented_js,
         "undocumentedNote": "toConfigString 은 다섯 클래스 모두에 있으나 d.ts 에 없다(설정 직렬화용). "
                             "Mat3.right()/up()/forward() 는 구현돼 있는데 d.ts 가 Mat4 쪽에만 선언한다",
         "epsilon": 1e-05,
         "angleUnit": "도(degree). deg2rad/rad2deg 상수가 파일 상단에 있고 "
                      "angle()/rotate()/fromRotation()/fromEuler() 가 전부 도를 쓴다",
         "matrixLayout": "컬럼메이저. Mat4.m[12..14] = 평행이동, Mat3.m[6..7] = 평행이동",
         "toConfigString": "모든 클래스가 toString 과 동일한 공백구분 문자열을 낸다 — 설정 왕복 형식",
         "classes": vecs},
        "확정", [ev_js, ev_dts]))

    # ── 16. jsmodules
    E.append(specfmt.entry(
        "script.api.modules",
        {"resolution": "import ... from 'NAME' → scripts/jsmodules/NAME.js (ES module, export)",
         "modules": {"WEMath": {"file": "wemath.js", "exports": modules["wemath.js"]},
                     "WEVector": {"file": "wevector.js", "exports": modules["wevector.js"]},
                     "WEColor": {"file": "wecolor.js", "exports": modules["wecolor.js"]}},
         "WEMath.smoothStep": "실구현은 Hermite: x=clamp((v-min)/(max-min),0,1); return x*x*(3-2*x). "
                              "d.ts 문구('[0,1] 재매핑')만으로는 선형/Hermite 를 못 가르는데 소스가 가른다",
         "WEMath.mix": "a+(b-a)*v — 클램프 없음",
         "WEVector.angleVector2": "도 → (cos, sin) Vec2",
         "WEColor": "rgb2hsv/hsv2rgb 는 정규화 [0,1] 도메인, normalizeColor/expandColor 가 255 환산"},
        "확정", [ev_mod, ev_dts]))

    # ── 17. IModelData
    E.append(specfmt.entry(
        "script.api.IModelData",
        {"createdBy": "thisScene.createModelData(config) / thisScene.destroyModelData(handle)",
         "vertexFormatConstants": classes["IModelData"]["statics"] if "IModelData" in classes else [],
         "constantsFrom": "baseclasses.js `this.IModelData = class IModelData {…}` — "
                          "POSITION/NORMAL/UV/TANGENT_SIGNED/COLOR 문자열 상수와 toConfigString",
         "shapeConfigKeys": [s for _, s in cluster
                             if s in ("shapes", "vertexBuffer", "indexBuffer", "vertexFormat",
                                      "material", "isVertexBufferDynamic", "isIndexBufferDynamic",
                                      "boundingBoxMins", "boundingBoxMaxs")],
         "vertexFormatOrder": "position, normal, tangentSigned, uv, color 순서 고정. "
                              "재배열 불가(구성만 켜고 끌 수 있다)",
         "handleToken": "__modelDataToken — toConfigString 이 이 토큰을 반환한다",
         "updateRestrictions": [s for _, s in cluster
                                if s.startswith(("Cannot ", "Vertex ", "Index ", "Model ",
                                                 "Material cannot", "IModelData."))],
         "applyData_vs_replaceData": "applyData 는 매 프레임 update 에서 호출 가능(버퍼 길이·포맷 동일 전제). "
                                     "replaceData 는 update 안에서 호출 금지 — 예외를 던진다",
         "coordinateScale": "2D 배경 기본 문맥은 1 유닛 = 1 픽셀. 0~1 정규화 좌표를 쓰지 말라고 명시",
         "winding": "삼각형 CCW"},
        "확정", [ev_dts, ev_js, ev_dll]))

    # ── 18. localStorage 위치 상수
    E.append(specfmt.entry(
        "script.api.ILocalStorage.locations",
        {"LOCATION_GLOBAL": {"value": "global", "va": dll_va("global"),
                             "meaning": "모든 배경 인스턴스가 공유"},
         "LOCATION_SCREEN": {"value": "screen", "va": dll_va("screen"),
                             "meaning": "화면(배경 인스턴스)별. 기본값"},
         "constVA": {"LOCATION_GLOBAL": dll_va("LOCATION_GLOBAL"),
                     "LOCATION_SCREEN": dll_va("LOCATION_SCREEN")},
         "methods": ["set", "get", "delete", "clear"],
         "methodVA": {n: dll_va(n) for n in ("set", "get", "delete", "clear")},
         "layout": "set/get/delete/clear/global/screen/LOCATION_GLOBAL/LOCATION_SCREEN 이 "
                   "0x1819a37e8~0x1819a3830 에 연속 — localStorage 전역(0x1819a3830) 바로 앞",
         "workshopKey": {"__workshopId": dll_va("__workshopId"), "workshop": dll_va("workshop"),
                         "추정": "저장 네임스페이스를 워크샵 ID 로 가르는 것으로 보이나 미확증"}},
        "확정", [ev_dll, ev_dts]))

    # ── 19. Waple 커버리지 갭
    swift = open(os.path.join("Sources", "WapleRender", "TextScriptEngine.swift"),
                 encoding="utf-8").read()
    waple_hooks = re.search(r"eventHookNames\s*=\s*\[(.*?)\]", swift, re.S)
    waple_hook_list = re.findall(r'"(\w+)"', waple_hooks.group(1)) if waple_hooks else []
    # [2026-08-20 정정] 종전엔 소스 전문에서 `baseclasses|jsclasses|jsmodules` 라는 **단어**를
    # 찾았다. 그 파일에 baseclasses.js 를 언급하는 주석이 생기자마자 이 값이 true 로 뒤집혔는데,
    # 정작 같은 주석이 "baseclasses 미로드(= 현재)" 라고 적고 있었다 — 정본이 스스로와 모순됐다.
    # 로드는 **문자열 리터럴로 파일을 지목하는 코드**로만 성립한다. 주석을 걷어내고 본다.
    code = re.sub(r"/\*.*?\*/", "", swift, flags=re.S)
    code = re.sub(r"//[^\n]*", "", code)
    loads_baseclasses = bool(re.search(r'"[^"\n]*(?:baseclasses|jsclasses|jsmodules)[^"\n]*"', code))

    def waple_has(name):
        return bool(re.search(r"\b" + re.escape(name) + r"\b", swift))

    missing_vec = {}
    for n in ("Vec2", "Vec3", "Vec4", "Mat3", "Mat4"):
        if n not in classes:
            continue
        we_methods = [m for m in classes[n]["methods"] if m != "constructor"]
        have = [m for m in we_methods if re.search(
            re.escape(n) + r"\.prototype\." + re.escape(m) + r"\s*=", swift)]
        missing_vec[n] = {"weMethodCount": len(we_methods),
                          "wapleMethodCount": len(have),
                          "missing": [m for m in we_methods if m not in have]}
    scene_missing = [n for n in ("createModelData", "destroyModelData", "getLayerByID",
                                 "sortLayer", "getInitialLayerConfig")
                     if not waple_has(n)]
    engine_missing = [n for n in ("registerAsset", "openUserShortcut", "screenResolution",
                                 "isObjectValid") if not waple_has(n)]
    layer_missing = [n for n in layer_side if not waple_has(n)]
    E.append(specfmt.entry(
        "waple.coverage",
        {"engine": "JavaScriptCore + 손으로 쓴 shim prelude(TextScriptEngine.swift 내 문자열 리터럴)",
         "method": "TextScriptEngine.swift 전문에 대한 식별자 grep 이다. missing = 소스 어디에도 그 "
                   "이름이 없다(강한 주장). 반대로 '있다'는 약한 주장이다 — 올바른 객체에 붙어 "
                   "있는지도, 의미가 맞는지도 보지 않는다. 예: lookAt 은 카메라 심에만 있고 "
                   "ILayer 에는 없는데 grep 은 '있음'으로 센다. 단 벡터 메서드는 "
                   "`Vec2.prototype.name =` 형태로 정밀하게 보고, loadsBaseclassesJS 는 "
                   "주석을 걷어낸 뒤 문자열 리터럴만 본다",
         "loadsBaseclassesJS": loads_baseclasses,
         # 하드코딩하면 loadsBaseclassesJS 와 어긋날 수 있다 — 같은 사실을 두 번 적지 않는다.
         "shippedButUnused": (
             "Sources/WapleRender/Resources/WEAssets/scripts/ 아래 baseclasses.js·wemath.js·"
             "wevector.js·wecolor.js 4개가 WE 설치본과 바이트 동일하게 동봉돼 있다. "
             + ("일부를 로드한다(위 loadsBaseclassesJS 참조)."
                if loads_baseclasses else "그러나 Swift 어디에서도 로드하지 않는다.")),
         "hooks": {"waple": waple_hook_list,
                   "weTotal": len(HOOK_ORDER),
                   "missing": [h for h in HOOK_ORDER
                               if h not in waple_hook_list and h not in ("init", "update",
                                                                        "applyUserProperties")],
                   "note": "init/update/applyUserProperties 는 eventHookNames 밖에서 따로 처리한다",
                   # [2026-08-21] `missing` 은 **이름 존재**만 센다. 이름이 있어도 부를 자리가 없으면
                   # 커버리지가 아니다 — 그 구분을 `IScene.presentButStub`/`IEngine.proxyFallback` 과
                   # 같은 규약으로 남긴다. 이 셋은 `eventHookNames` 에 들어와 `missing` 에서 빠졌지만
                   # **발화하는 코드가 없다**(TextScriptEngine.swift:577 이 그렇게 적어 두었고,
                   # `callHook("resizeScreen")` 류가 Sources 전체에 0건인 것으로 재확인했다).
                   "presentButNeverFired": {
                       "names": ["resizeScreen", "destroy", "applyGeneralSettings"],
                       "why": "훅 수집(eventHookNames)에는 들어와 있지만 발화원이 렌더러 소유라 "
                              "아직 배선되지 않았다 — 창 리사이즈·마운트 해제·앱 설정 변경 중 "
                              "어느 것도 callHook 하지 않는다. 이름이 있으니 `missing` 에서는 "
                              "빠지지만 **동작은 없다.**",
                       "evidence": "Sources/WapleRender/TextScriptEngine.swift:577-582"}},
         "vectors": missing_vec,
         "Mat3": "Waple 에 전무. WE 는 Mat3 를 IEffectLayer.transformAttachmentToTexture 반환형과 "
                 "Mat4.normalMatrix() 반환형으로 쓴다",
         "Mat4": "심은 {m:[16]} 평면 객체 + 부모체인 합성뿐. WE Mat4 의 "
                 f"{len(classes['Mat4']['methods']) + len(classes['Mat4']['statics'])}개 메서드/스태틱 중 "
                 "인스턴스 메서드는 하나도 없다 — .inverse()/.multiply()/.transformPoint() 호출은 TypeError",
         "IScene.missing": scene_missing,
         "IScene.presentButStub": "getLayerByID/sortLayer/getInitialLayerConfig 는 이름만 있고 "
                                  "각각 uid 비교·no-op·고정 항등 설정을 돌려준다. destroyLayer 는 "
                                  "배열에서 지우지 않고 툼스톤 처리한다(렌더러 인덱스 규약 때문)",
         "IEngine.missing": engine_missing,
         "IEngine.proxyFallback": "engine 은 Proxy 라 미지 멤버가 noop 객체로 흡수된다. "
                                  "registerAsset/openUserShortcut/screenResolution 호출이 예외로 "
                                  "죽지는 않지만 값은 전부 무의미하다",
         "ILayer.missing": layer_missing,
         # [2026-08-21] 위 `missing` 과 같은 이유의 구분(hooks.presentButNeverFired 참조).
         "ILayer.presentButStub": "transformAttachmentToTexture 는 이름만 있고 "
                                  "`__noopProxy()` 를 돌려준다(TextScriptEngine.swift:2190 · :2259). "
                                  "그래서 `missing` 에서는 빠지지만 반환값으로 Mat3 산술을 하면 "
                                  "전부 무의미하다 — 위 `Mat3` 항목과 함께 읽어라.",
         "ILayer.extraNonWE": "Waple shim 은 WE 에 없는 이름을 다수 만든다"
                              "(getName/setName/getOrigin/setOrigin/setAngles/setScale/setVisible/"
                              "setAlpha/setText/getTexture/addChild/playAnimation/…). "
                              "실물 스크립트는 이것들을 부르지 않으므로 무해하지만 정본은 아니다",
         "WEMath": "smoothStep/mix/deg2rad/rad2deg 4개 — 실제 wemath.js 와 표면 일치. 갭 없음",
         "WEVector": "angleVector2/vectorAngle2 2개 — wevector.js 와 일치. 갭 없음",
         # [정정 2026-09-01] 종전 문구는 "rgb2hsv/hsv2rgb 2개. wecolor.js 는
         # normalizeColor/expandColor 도 export 한다" 였다 — 마치 뒤 둘이 심에 없는 갭인 것처럼
         # 읽힌다. 그 갭은 2026-08-20 에 이미 닫혔다: `TextScriptEngine.swift` 의 `__WEColor`
         # 가 넷을 다 내고(주석이 "심에 둘이 빠져 있어서 … TypeError 로 훅이 통째로 죽었다" 며
         # 그때 메운 것을 기록한다), 이 파일이 내는 정본 자신도 같은 entry 의
         # `modules.wecolor.js.exports` 에 넷을 전부 커버로 등재한다. 생성기 하드코딩만
         # 옛 상태로 남아 정본과 어긋나 있었다.
         # (주의: 커밋된 `spec/engine/script-api.json` 은 이 생성기를 **다시 돌려야** 갱신된다.
         #  재실행은 WE 바이너리/코퍼스를 요구하므로 그 파일에는 옛 문구가 남아 있을 수 있다.)
         "WEColor": "rgb2hsv/hsv2rgb/normalizeColor/expandColor 4개 — wecolor.js 의 export "
                    "전부를 심이 낸다(2026-08-20 에 뒤 둘을 메웠다). 갭 없음",
         "input.cursorScreenPosition": "Waple 은 Vec3 로 만든다. d.ts 는 Vec2 — .z 접근 시 동작이 갈린다",
         "engine.userProperties": "Waple 은 원시값 맵으로 주입한다 — "
                                  "_Internal.convertUserProperties 결과와 일치(정합)"},
        "확정", [ev_swift, ev_js, ev_dts, ev_exe]))

    doc = specfmt.doc("scripts/spec/measure_script_api.py", E, extra={
        "area": "scenescript64.dll 바인딩 API",
        "sources": {
            "dts": "ui/dist/monaco/autocomplete/lib.sceneScript.d.ts",
            "baseclasses": "assets/scripts/jsclasses/baseclasses.js",
            "jsmodules": "assets/scripts/jsmodules/*.js",
            "dll": "bin/scenescript64.dll",
            "exe": "wallpaper64.exe"},
        "note": "V8 은 오픈소스라 다루지 않는다. WE 자체 바인딩만 담는다. "
                "네이티브 근거는 .rdata 문자열 군집이라 '이름이 등록됐다'까지 증명하고 "
                "인자 개수/타입은 증명하지 않는다 — 그건 d.ts 근거다.",
    })
    out = os.path.join("spec", "engine", "script-api.json")
    specfmt.dump(doc, out)
    print(f"{out} — {len(E)} 항목")
    print(f"  DLL export {len(exports)}개 / 바인딩 군집 문자열 {len(cluster_names)}개")
    print(f"  d.ts 타입 {len(types)}개 · 전역 {len(dts_globals)}개")
    print(f"  baseclasses.js 클래스 {len(classes)}개")


if __name__ == "__main__":
    main()
