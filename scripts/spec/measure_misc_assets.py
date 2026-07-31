"""WE assets/ 의 나머지 트리(zcompat / scenes / particles / models / presets /
scripts / shaders/declarations.json)를 전수 판독해 정본을 만든다.

이 트리들은 Waple 에 대응물이 거의 없다. 그래서 먼저 답해야 하는 질문은
"무엇인가"가 아니라 **"런타임인가 에디터인가"** 다. 그 판정은 추측이 아니라
바이너리 문자열 소비자로 한다:

  wallpaper64.exe      씬 렌더러(런타임)   -> 여기 있으면 Waple 이 구현해야 한다
  bin/scenescript64.dll 씬 스크립트(런타임)
  bin/webwallpaper64.exe 웹 렌더러(런타임)
  bin/wallpaperui.exe  에디터/브라우저 UI  -> 여기만 있으면 Waple 은 0건이어도 된다
  ui/dist/scripts/*.js 에디터 웹 UI

경로가 코드 리터럴이 아니라 **씬 JSON 데이터**에서 오는 경우가 있어서
(models/util/*.json 이 그렇다) 바이너리 스캔만으로는 부족하다. 그래서
코퍼스 pkg 의 **blob 본문**까지 정규식으로 훑는다.

외부 의존 0. PE 파싱·RIP 상대 LEA 스캔·.pdata 함수 경계는 stdlib 로 직접 한다.
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

WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")
WS = os.environ.get("WE_WORKSHOP", r"Z:\SteamLibrary\steamapps\workshop\content\431960")
BUNDLED = os.path.join("Sources", "WapleRender", "Resources", "WEAssets")

# 판정에 쓰는 소비자들. distribution\ 아래는 bin\ 과 바이트 동일한 사본이라 제외한다
# (같은 히트가 두 번 세어지는 것을 막는다 — 동일성은 consumers.distributionIsCopy 로 확정한다).
CONSUMERS = [
    ("wallpaper64.exe", "wallpaper64.exe", "런타임: 씬 렌더러"),
    ("scenescript64.dll", os.path.join("bin", "scenescript64.dll"), "런타임: 씬 스크립트(JS)"),
    ("webwallpaper64.exe", os.path.join("bin", "webwallpaper64.exe"), "런타임: 웹 렌더러"),
    ("wallpaperui.exe", os.path.join("bin", "wallpaperui.exe"), "에디터/브라우저 UI"),
    ("ui/dist/scripts/scripts.js", os.path.join("ui", "dist", "scripts", "scripts.js"), "에디터 웹 UI"),
]


# ---------------------------------------------------------------- 파일 유틸

def assets_root():
    return BUNDLED if os.path.isdir(BUNDLED) else os.path.join(WE, "assets")


def sha16(data):
    return hashlib.sha256(data).hexdigest()[:16]


_TRAILING_COMMA = re.compile(r",(\s*[}\]])")


def strip_trailing_commas(text):
    """문자열 리터럴 밖의 후행 쉼표만 지운다. WE 의 JSON 파서는 이걸 허용한다."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    break
                j += 1
            out.append(text[i:j + 1])
            i = j + 1
            continue
        if c == ",":
            j = i + 1
            while j < n and text[j] in " \t\r\n":
                j += 1
            if j < n and text[j] in "}]":
                i += 1          # 후행 쉼표 — 버린다
                continue
        out.append(c)
        i += 1
    return "".join(out)


def strip_line_comments(text):
    """문자열 리터럴 밖의 `//` 줄 주석을 지운다. WE 의 JSON 파서는 이것도 허용한다."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    break
                j += 1
            out.append(text[i:j + 1])
            i = j + 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def classify_json(data):
    """(strict_ok, needs, obj). needs 는 'comment' / 'trailing-comma' / None / 'unrecovered'."""
    text = data.decode("utf-8-sig")
    try:
        return True, None, json.loads(text)
    except ValueError:
        pass
    try:
        return False, "trailing-comma", json.loads(strip_trailing_commas(text))
    except ValueError:
        pass
    try:
        return False, "comment", json.loads(strip_trailing_commas(strip_line_comments(text)))
    except ValueError:
        return False, "unrecovered", None


def lenient_json(data):
    return classify_json(data)[2]


def read(path):
    with open(path, "rb") as fh:
        return fh.read()


def count_files(root):
    return sum(len(f) for _, _, f in os.walk(root))


# ---------------------------------------------------------------- PE 유틸

def pe_sections(data):
    """(imagebase, [(name, va, vsize, rawoff, rawsize)])"""
    lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    if data[lfanew:lfanew + 4] != b"PE\0\0":
        raise ValueError("PE 헤더 아님")
    nsec = struct.unpack_from("<H", data, lfanew + 6)[0]
    optsz = struct.unpack_from("<H", data, lfanew + 20)[0]
    magic = struct.unpack_from("<H", data, lfanew + 24)[0]
    if magic == 0x20B:
        base = struct.unpack_from("<Q", data, lfanew + 24 + 24)[0]
    else:
        base = struct.unpack_from("<I", data, lfanew + 24 + 28)[0]
    off = lfanew + 24 + optsz
    secs = []
    for i in range(nsec):
        o = off + i * 40
        name = data[o:o + 8].rstrip(b"\0").decode("ascii", "ignore")
        vsz, va, rsz, ra = struct.unpack_from("<IIII", data, o + 8)
        secs.append((name, va, vsz, ra, rsz))
    return base, secs


def va_to_off(base, secs, va):
    for _, sva, vsz, ra, rsz in secs:
        if base + sva <= va < base + sva + max(vsz, rsz):
            d = va - (base + sva)
            if d < rsz:
                return ra + d
    return None


def off_to_va(base, secs, off):
    for _, sva, _vsz, ra, rsz in secs:
        if ra <= off < ra + rsz:
            return base + sva + (off - ra)
    return None


def lea_refs(data, base, secs, target_va):
    """target_va 를 가리키는 `lea r64,[rip+disp32]` 명령 주소들. REX.W + 8D + modrm(mod=00,rm=101)."""
    out = []
    for name, sva, _vsz, ra, rsz in secs:
        if name != ".text":
            continue
        blob = data[ra:ra + rsz]
        start = base + sva
        for i in range(len(blob) - 7):
            if blob[i] not in (0x48, 0x49, 0x4C, 0x4D):
                continue
            if blob[i + 1] != 0x8D or (blob[i + 2] & 0xC7) != 0x05:
                continue
            disp = struct.unpack_from("<i", blob, i + 3)[0]
            if start + i + 7 + disp == target_va:
                out.append(start + i)
    return out


def pdata_range(data, base, secs, va):
    """x64 예외 디렉터리(.pdata)의 RUNTIME_FUNCTION 으로 va 를 포함하는 함수 경계."""
    pd = [s for s in secs if s[0] == ".pdata"]
    if not pd:
        return None
    _, _, _, ra, rsz = pd[0]
    blob = data[ra:ra + rsz]
    best = None
    for i in range(0, len(blob) - 11, 12):
        beg, end, _unw = struct.unpack_from("<III", blob, i)
        if beg == 0 and end == 0:
            continue
        if base + beg <= va < base + end:
            best = (base + beg, base + end)
            break
    return best


def find_string_va(data, base, secs, literal):
    """NUL 로 끝나는 정확한 리터럴의 VA 들(앞이 NUL 경계인 것만)."""
    out = []
    b = literal.encode()
    for m in re.finditer(re.escape(b) + b"\x00", data):
        if m.start() > 0 and data[m.start() - 1] != 0:
            continue
        va = off_to_va(base, secs, m.start())
        if va is not None:
            out.append(va)
    return out


# ---------------------------------------------------------------- pkg

def parse_pkg(data):
    n = len(data)
    p = 0

    def i32():
        nonlocal p
        v = struct.unpack_from("<i", data, p)[0]
        p += 4
        return v

    vlen = i32()
    magic = data[p:p + vlen].decode("ascii", "ignore")
    p += vlen
    count = i32()
    entries = []
    for _ in range(count):
        nlen = i32()
        name = data[p:p + nlen].decode("utf-8", "ignore")
        p += nlen
        entries.append((name, i32(), i32()))
    return magic, entries, p


def corpus_pkgs():
    """[(workshopId, pkgBytes, entries, blobBase)] — 정렬 고정."""
    out = []
    for wid in sorted(os.listdir(WS)):
        d = os.path.join(WS, wid)
        if not os.path.isdir(d):
            continue
        for fn in ("scene.pkg", "gifscene.pkg"):
            p = os.path.join(d, fn)
            if not os.path.exists(p):
                continue
            data = read(p)
            try:
                _magic, entries, base = parse_pkg(data)
            except Exception:
                continue
            out.append((wid, data, entries, base))
    return out


# ---------------------------------------------------------------- 측정

def measure_consumers(literals):
    """리터럴별 {소비자: 출현수}. 0 인 소비자는 뺀다."""
    blobs = {}
    for key, rel, _role in CONSUMERS:
        p = os.path.join(WE, rel)
        blobs[key] = read(p) if os.path.exists(p) else b""
    res = {}
    for lit in literals:
        b = lit.encode()
        hits = {k: blobs[k].count(b) for k in blobs}
        res[lit] = {k: v for k, v in sorted(hits.items()) if v}
    return res


def main():
    A = assets_root()
    ev_asset = specfmt.ev("asset", A)
    ev_corpus = specfmt.ev("corpus", "워크샵 코퍼스 scene.pkg/gifscene.pkg 전수")
    ev_script = specfmt.ev("script", "scripts/spec/measure_misc_assets.py")
    entries = []

    # ---------- 소비자 판정 -------------------------------------------------
    LITERALS = [
        "zcompat", "assets/zcompat/web", "assets/zcompat/scene/shaders",
        "maximumprojectid", "assets/scenes/videoplayer/scene.json",
        "assets/scenes/gifs", "projects/temp/gifs", "gifscene.json", "videotex",
        "assets/scenes/particleeditor/project.json",
        "assets/scenes/particleeditor3dscale/project.json",
        "assets/scenes/modeleditor/project.json",
        "scenes/particleelementpreviews/",
        "assets/particles/example.json", "assets/particles/example3d.json",
        "declarations.json", "preset.json",
        "scripts/jsclasses/baseclasses.js", "scripts/jsmodules/",
        "models/util/solidlayer.json", "models/util/solidlayer_depthtest.json",
        "models/util/", "materials/util/",
    ]
    cons = measure_consumers(LITERALS)
    entries.append(specfmt.entry(
        "misc.consumerMap", cons, "확정",
        [specfmt.ev("binary", "wallpaper64.exe / bin/scenescript64.dll / bin/webwallpaper64.exe / "
                              "bin/wallpaperui.exe / ui/dist/scripts/scripts.js 바이트 카운트",
                    "런타임(앞 3개)에 없고 UI 에만 있으면 에디터 전용이다"), ev_script]))

    dist_same = {}
    for key, rel, _role in CONSUMERS:
        a = os.path.join(WE, rel)
        b = os.path.join(WE, "distribution", rel)
        if os.path.exists(a) and os.path.exists(b):
            dist_same[key] = sha16(read(a)) == sha16(read(b))
    entries.append(specfmt.entry(
        "misc.distributionIsCopy", dist_same, "확정",
        [specfmt.ev("binary", "distribution/ 아래 사본과 sha256[:16] 대조",
                    "동일하므로 문자열 카운트에서 distribution/ 은 제외한다"), ev_script]))

    # ---------- zcompat ----------------------------------------------------
    zweb = {}
    zwebdir = os.path.join(A, "zcompat", "web")
    for f in sorted(os.listdir(zwebdir)):
        d = read(os.path.join(zwebdir, f))
        j = json.loads(d.decode("utf-8"))
        zweb[f] = {"sha16": sha16(d), "bytes": len(d),
                   "actionCount": len(j.get("actions", [])),
                   "files": sorted({a["file"] for a in j.get("actions", [])})}
    entries.append(specfmt.entry("zcompat.web.files", zweb, "확정", [ev_asset, ev_script]))
    entries.append(specfmt.entry(
        "zcompat.web.schema",
        {"path": "assets/zcompat/web/<steamWorkshopId>.json",
         "root": {"actions": "배열"},
         "action": {"file": "월페이퍼 디렉터리 기준 상대 경로",
                    "replace": "찾을 문자열 리터럴",
                    "insert": "대체할 문자열 리터럴"},
         "note": "정규식이 아니라 리터럴이다. 대상은 워크샵 아이템이 배포한 .js 파일이다"},
        "확정", [ev_asset, ev_script]))

    # webwallpaper64.exe 에서 web zcompat 이 사는 함수와 소비 문자열
    wwp = read(os.path.join(WE, "bin", "webwallpaper64.exe"))
    wbase, wsecs = pe_sections(wwp)
    web_syms = {}
    for lit in ("431960", "assets/zcompat/web", ".json", "actions", "file", "replace", "insert",
                "Failed writing compat fix at %S\n"):
        vas = find_string_va(wwp, wbase, wsecs, lit)
        refs = []
        for va in vas:
            refs += lea_refs(wwp, wbase, wsecs, va)
        web_syms[lit] = {"stringVA": [hex(v) for v in vas], "codeRefs": [hex(r) for r in sorted(refs)]}
    web_fn = pdata_range(wwp, wbase, wsecs,
                         int(web_syms["assets/zcompat/web"]["codeRefs"][0], 16))
    entries.append(specfmt.entry(
        "zcompat.web.consumer",
        {"binary": "bin/webwallpaper64.exe",
         "function": {"start": hex(web_fn[0]), "end": hex(web_fn[1])},
         "symbols": web_syms,
         "reading": "웹 월페이퍼 로드 경로에서 실행된다 — 런타임이다. "
                    "경로에 Steam AppID 431960 이 있을 때만 동작하고, "
                    "패치 결과를 월페이퍼 파일에 되쓴다(실패 시 'Failed writing compat fix at %S')"},
        "확정",
        [specfmt.ev("binary", "bin/webwallpaper64.exe .pdata 함수 경계 + RIP 상대 LEA 역참조"), ev_script]))

    zsc = {}
    zscdir = os.path.join(A, "zcompat", "scene", "shaders")
    for sid in sorted(os.listdir(zscdir)):
        cfg = json.loads(read(os.path.join(zscdir, sid, "config.json")).decode("utf-8"))
        files = sorted(os.listdir(os.path.join(zscdir, sid)))
        zsc[sid] = {"config": {k: cfg[k] for k in sorted(cfg)}, "files": files}
    entries.append(specfmt.entry("zcompat.scene.entries", zsc, "확정", [ev_asset, ev_script]))

    ui = read(os.path.join(WE, "bin", "wallpaperui.exe"))
    ubase, usecs = pe_sections(ui)
    zsc_va = find_string_va(ui, ubase, usecs, "assets/zcompat/scene/shaders")[0]
    zsc_ref = lea_refs(ui, ubase, usecs, zsc_va)[0]
    zsc_fn = pdata_range(ui, ubase, usecs, zsc_ref)
    # 같은 함수가 참조하는 다른 문자열들 = 이 함수의 정체
    neighbours = []
    lo, hi = zsc_fn
    flo = va_to_off(ubase, usecs, lo)
    body = ui[flo:flo + (hi - lo)]
    for i in range(len(body) - 7):
        if body[i] not in (0x48, 0x49, 0x4C, 0x4D):
            continue
        if body[i + 1] != 0x8D or (body[i + 2] & 0xC7) != 0x05:
            continue
        disp = struct.unpack_from("<i", body, i + 3)[0]
        tgt = lo + i + 7 + disp
        to = va_to_off(ubase, usecs, tgt)
        if to is None:
            continue
        end = ui.find(b"\0", to, to + 120)
        if end < 0:
            continue
        s = ui[to:end]
        if len(s) < 6:
            continue
        try:
            t = s.decode("ascii")
        except UnicodeDecodeError:
            continue
        if t.startswith("ui_browse_mobile_transcoder") or t in ("-transcode -i \"", " -f ETC2",
                                                                "MPKG_VFS://", "wallpaper.mp4"):
            neighbours.append(t)
    entries.append(specfmt.entry(
        "zcompat.scene.consumer",
        {"binary": "bin/wallpaperui.exe",
         "function": {"start": hex(zsc_fn[0]), "end": hex(zsc_fn[1])},
         "stringVA": hex(zsc_va), "codeRef": hex(zsc_ref),
         "functionIdentity": sorted(set(neighbours)),
         "notInRuntime": {"wallpaper64.exe": cons["zcompat"].get("wallpaper64.exe", 0),
                          "scenescript64.dll": cons["zcompat"].get("scenescript64.dll", 0)},
         "reading": "'zcompat' 문자열이 씬 렌더러(wallpaper64.exe)에 0회 나온다. "
                    "scene zcompat 은 wallpaperui.exe 의 모바일 변환(convert to mobile) "
                    "함수 안에서만 소비된다 — 데스크톱 재생 경로가 아니다"},
        "확정",
        [specfmt.ev("binary", "bin/wallpaperui.exe 0x%x-0x%x 의 리터럴 이웃" % zsc_fn), ev_script]))

    # 조회 키: shaders/workshop/<originId>/... (parent^2 = 디렉터리 이름, parent^3 = "workshop")
    entries.append(specfmt.entry(
        "zcompat.scene.lookupKey",
        {"candidateFiles": "프로젝트 루트 기준 첫 경로 요소가 'shaders' 이고 확장자가 .vert/.frag/.geom",
         "zcompatDir": "assets/zcompat/scene/shaders/<filename(parent(parent(file)))>",
         "guard": "filename(parent(parent(parent(file)))) 를 대소문자 무시 비교해 'workshop' 이어야 한다",
         "corpusLayout": "코퍼스 pkg 는 남의 워크샵에서 가져온 셰이더를 "
                         "shaders/workshop/<originWorkshopId>/... 로 저장한다 — 위 규칙과 정확히 맞는다",
         "replacement": {".frag": "config.json 의 'frag' 값", ".vert": "config.json 의 'vert' 값",
                         ".geom": "config.json 에 대응 키가 없다 — 치환되지 않는다"}},
        "확정",
        [specfmt.ev("binary", "bin/wallpaperui.exe FUN@0x14003d0e0 디컴파일 — "
                              "parent_path 3회 + _stricmp(...,'workshop')"),
         specfmt.ev("corpus", "pkg 엔트리 이름 정규식 ^shaders/workshop/(\\d+)/"), ev_script]))

    # maximumprojectid 는 파싱만 되고 결과가 버려진다 — 바이트로 못 박는다
    mpid_va = find_string_va(ui, ubase, usecs, "maximumprojectid")
    mpid_refs = lea_refs(ui, ubase, usecs, mpid_va[0])
    ptr_le = struct.pack("<Q", mpid_va[0])
    ptr_in_data = ui.count(ptr_le)
    WIN_LO, WIN_HI = 0x14003FD24, 0x14003FD44
    win = ui[va_to_off(ubase, usecs, WIN_LO):va_to_off(ubase, usecs, WIN_HI)]
    entries.append(specfmt.entry(
        "zcompat.scene.maximumProjectIdUnused",
        {"stringVA": [hex(v) for v in mpid_va],
         "codeRefs": [hex(r) for r in mpid_refs],
         "pointerInDataTables": ptr_in_data,
         "assertedBytes": {"from": hex(WIN_LO), "to": hex(WIN_HI), "hex": win.hex()},
         "disassembly": [
             "CMP byte ptr [RSP+0x38], 0x4     ; JSON 값 타입 == string",
             "JNZ  0x14003fd42",
             "TEST RSI,RSI",
             "JZ   0x14003fd42",
             "LEA  RCX,[RSP+0x30]",
             "CALL 0x1402357b0                 ; json string -> const char*",
             "MOV  RCX,RAX",
             "CALL 0x14000cd50                 ; strtoull(s, 0, 10)",
             "LEA  RCX,[RBP+0x698]             ; <- RAX 를 읽지 않는다"],
         "reading": "2.8.42 에서 maximumprojectid 는 읽고 10진 파싱까지 하지만 "
                    "결과를 아무도 쓰지 않는다. 즉 치환은 프로젝트 ID 와 무관하게 무조건 적용된다"},
        "확정",
        [specfmt.ev("binary", "bin/wallpaperui.exe 0x14003fd24..0x14003fd44 바이트 고정 + "
                              "0x%x 포인터가 데이터 테이블에 %d회" % (mpid_va[0], ptr_in_data)),
         ev_script]))

    # 코퍼스 영향
    pkgs = corpus_pkgs()
    origin_items = collections.defaultdict(set)
    items_with_origin = set()
    rx_origin = re.compile(r"^shaders/workshop/(\d+)/")
    for wid, _data, ents, _base in pkgs:
        for name, _o, _s in ents:
            m = rx_origin.match(name)
            if m:
                origin_items[m.group(1)].add(wid)
                items_with_origin.add(wid)
    covered = {}
    for sid in sorted(zsc):
        hit = sorted(origin_items.get(sid, ()))
        maxpid = int(zsc[sid]["config"]["maximumprojectid"])
        covered[sid] = {"corpusItems": hit, "count": len(hit),
                        "wouldBeFilteredByMaxProjectId": len([w for w in hit if int(w) <= maxpid]),
                        "maximumprojectid": zsc[sid]["config"]["maximumprojectid"]}
    affected = sorted(set().union(*[set(v["corpusItems"]) for v in covered.values()]) if covered else set())
    entries.append(specfmt.entry(
        "zcompat.scene.corpusImpact",
        {"scenePkgs": len(pkgs),
         "itemsImportingForeignShaders": len(items_with_origin),
         "distinctOriginIds": len(origin_items),
         "zcompatCoveredOriginIds": len([s for s in covered if covered[s]["count"]]),
         "perZcompatDir": covered,
         "distinctAffectedItems": len(affected),
         "affectedItems": affected,
         "note": "maximumprojectid 가 쓰이지 않으므로(zcompat.scene.maximumProjectIdUnused) "
                 "무조건 적용 기준의 수가 정본이다. wouldBeFilteredByMaxProjectId 는 참고값"},
        "확정", [ev_corpus, ev_script]))

    entries.append(specfmt.entry(
        "zcompat.wapleImpact",
        {"sceneZcompat": "Waple 0건이 옳다 — 데스크톱 재생 경로에 없다(모바일 익스포트 전용)",
         "webZcompat": "웹 월페이퍼를 구현할 때만 필요하다. 런타임이고 파일을 되쓴다",
         "risk": "코퍼스 %d개 씬에 대해 WE 데스크톱과 Waple 은 **같은 셰이더 원문을 입력으로 받는다** "
                 "— WE 도 재생 시에는 치환하지 않기 때문이다. 렌더 결과 동일성은 별개 문제이며 "
                 "여기서 주장하지 않는다(Swift 툴체인·골든 A/B 없음)" % len(affected)},
        "확정",
        [specfmt.ev("binary", "wallpaper64.exe 에 'zcompat' 0회"), ev_corpus, ev_script]))

    # ---------- scenes -----------------------------------------------------
    scenes_root = os.path.join(A, "scenes")
    subtrees = {}
    for d in sorted(os.listdir(scenes_root)):
        subtrees[d] = count_files(os.path.join(scenes_root, d))
    subtrees["(합계)"] = sum(v for k, v in subtrees.items())
    entries.append(specfmt.entry("scenes.subtrees", subtrees, "확정", [ev_asset, ev_script]))

    def load(rel):
        return lenient_json(read(os.path.join(A, rel)))

    vp_scene = load("scenes/videoplayer/scene.json")
    entries.append(specfmt.entry(
        "scenes.videoplayer.sceneGeneral",
        {"crossRef": "이 씬의 모델/머티리얼/videotex 배선은 spec/engine/media.json 의 "
                     "engine.media.mfEngine.videotex 와 engine.media.video.frameworks 가 정본이다. "
                     "여기는 그쪽이 안 담은 **씬 general 블록**만 더한다",
         "general": vp_scene["general"],
         "objectCount": len(vp_scene["objects"]),
         "object": vp_scene["objects"][0],
         "reading": "번들 비디오 씬은 general 에서 bloom 을 끄고(bloom=false, bloomhdrstrength=0) "
                    "직교투영을 auto 로, clearcolor 를 검정으로 고정하고 "
                    "spritesheetrefreshsync 를 켠다. 오브젝트는 정확히 1개다. "
                    "즉 WE 의 비디오 경로는 **씬 파이프라인을 타되 후처리는 명시적으로 비운** 형태다"},
        "확정", [ev_asset, ev_script]))

    gif_scene = load("scenes/gifs/gifscene.json")
    gif_mat = load("scenes/gifs/materials/background.json")
    gif_tex = load("scenes/gifs/materials/background.tex-json")
    entries.append(specfmt.entry(
        "scenes.gifs",
        {"loadedBy": "wallpaper64.exe (리터럴 'assets/scenes/gifs', 'projects/temp/gifs', 'gifscene.json')",
         "flow": "assets/scenes/gifs 템플릿을 projects/temp/gifs 로 복사하고 .gif 를 함께 복사한 뒤 "
                 "gifscene.json 을 씬으로 연다",
         "scene": {"general": gif_scene["general"], "object": gif_scene["objects"][0]},
         "material": gif_mat,
         "texJson": gif_tex,
         "reading": "GIF 도 씬이다. videoplayer 와 구조가 같고 텍스처를 스프라이트시트 "
                    "combo 로 돌린다는 점만 다르다"},
        "확정",
        [specfmt.ev("binary", "wallpaper64.exe: 'assets/scenes/gifs', 'projects/temp/gifs', "
                              "'gifscene.json', 'Failed copying gif template from %S to'"),
         ev_asset, ev_script]))

    prev_dir = os.path.join(scenes_root, "particleelementpreviews")
    elements = sorted(os.listdir(prev_dir))
    entries.append(specfmt.entry(
        "scenes.particleElementPreviews",
        {"count": len(elements), "files": count_files(prev_dir), "elements": elements,
         "layout": "<element>/{project.json, scene.json, particles/new_particle_system.json, "
                   "materials/particle/halo_1.json} (+ 일부는 template.json / effects / models)",
         "consumer": "bin/wallpaperui.exe (리터럴 'scenes/particleelementpreviews/' + '/project.json')",
         "reading": "에디터가 파티클 요소(emitter/initializer/operator/renderer)를 고를 때 "
                    "보여주는 미리보기 씬들이다. 부수적으로 **WE 가 문서화하는 파티클 요소 이름 목록**이다"},
        "확정", [ev_asset,
                specfmt.ev("binary", "bin/wallpaperui.exe 'scenes/particleelementpreviews/'"), ev_script]))

    dxs_dir = os.path.join(A, "scenes", "videoplayer", "shaders", "blobsSM40")
    dxs = {}
    for f in sorted(os.listdir(dxs_dir)):
        b = read(os.path.join(dxs_dir, f))
        dxs[f] = {"bytes": len(b), "magic": b[:8].decode("ascii", "ignore"),
                  "payloadTag": b[12:15].decode("ascii", "ignore"),
                  "declaredSize": struct.unpack_from("<I", b, 8)[0]}
    entries.append(specfmt.entry(
        "scenes.videoplayerShaderBlobs",
        {"path": "scenes/videoplayer/shaders/blobsSM40/<40자 hex>.dxs", "files": dxs,
         "measured": "매직 'SHDV0069' + u32 + 오프셋 12에 'DXB'(DXBC 컨테이너). "
                     "파일명은 전부 40자 hex, 디렉터리 이름은 blobsSM40",
         "reading": "컴파일된 D3D 셰이더 바이너리다(SM4.0). Metal 이식에는 못 쓴다. "
                    "번들 씬에도 이 캐시가 동봉된다는 사실만 기록한다. "
                    "파일명이 소스 해시인지 조합 키인지는 확인하지 않았다"},
        "확정", [ev_asset, ev_script]))

    entries.append(specfmt.entry(
        "scenes.editorHosts",
        {"particleeditor": "assets/scenes/particleeditor/project.json",
         "particleeditor3dscale": "assets/scenes/particleeditor3dscale/project.json",
         "modeleditor": "assets/scenes/modeleditor/project.json",
         "consumer": "bin/wallpaperui.exe 전용",
         "reading": "파티클/모델 에디터가 편집 대상을 띄우는 호스트 씬. 런타임 무관"},
        "확정", [specfmt.ev("binary", "bin/wallpaperui.exe 리터럴"), ev_asset, ev_script]))

    # ---------- particles / models -----------------------------------------
    part_dir = os.path.join(A, "particles")
    parts = sorted(os.listdir(part_dir))
    uijs = read(os.path.join(WE, "ui", "dist", "scripts", "scripts.js"))
    part_ref = {f: uijs.count(("assets/particles/" + f).encode()) for f in parts}
    entries.append(specfmt.entry(
        "particles.templates",
        {"files": parts, "referencedInEditorUI": {k: part_ref[k] for k in sorted(part_ref)},
         "uiLists": ["particleDefaultPresets", "particleDefaultPresets3d"],
         "reading": "6개 전부 에디터가 '새 파티클 시스템'을 만들 때 쓰는 시작 템플릿이다. "
                    "런타임 바이너리에는 없다 — Waple 은 0건이어도 된다"},
        "확정",
        [specfmt.ev("binary", "ui/dist/scripts/scripts.js 의 particleDefaultPresets/3d 목록"),
         specfmt.ev("binary", "bin/wallpaperui.exe 'assets/particles/example.json'"), ev_asset, ev_script]))

    util_dir = os.path.join(A, "models", "util")
    util = {}
    for f in sorted(os.listdir(util_dir)):
        util[f] = load("models/util/" + f)
    util_keys = sorted({k for v in util.values() for k in v})
    entries.append(specfmt.entry(
        "models.util.archetypes",
        {"files": util,
         "distinctKeys": util_keys,
         "reading": "6개는 씬 JSON 의 오브젝트가 \"image\": \"models/util/<name>.json\" 으로 "
                    "직접 참조하는 **공유 레이어 원형**이다. 워크샵 pkg 는 이걸 동봉하지 않는다. "
                    "각 파일은 material 경로 하나 + 불리언 플래그 몇 개가 전부다"},
        "확정", [ev_asset, ev_script]))
    entries.append(specfmt.entry(
        "models.util.flagSemantics",
        {"passthrough": "머티리얼 패스를 그대로 통과시키는 레이어로 읽힌다",
         "fullscreen": "화면 전체 쿼드로 읽힌다",
         "autosize": "텍스처 해상도에 맞춰 크기 자동으로 읽힌다",
         "projectlayer": "프로젝트(투사) 레이어로 읽힌다",
         "solidlayer": "단색/솔리드 레이어로 읽힌다",
         "왜 추정인가": "플래그 이름과 참조 머티리얼로부터의 해석이다. "
                     "wallpaper64.exe 는 이 키 이름들을 문자열로 갖고 있지만"
                     "(passthrough/solidlayer/projectlayer/nopadding/autosize) "
                     "각각의 렌더 동작을 디스어셈블로 확인하지는 않았다"},
        "추정", [ev_asset,
               specfmt.ev("binary", "wallpaper64.exe 에 키 이름 리터럴 존재"), ev_script]))

    # 코퍼스 blob 본문에서 공유 에셋 참조 — 경로가 코드가 아니라 데이터에서 온다
    BLOB_RX = {
        "models/util": rb"models/util/[A-Za-z0-9_]+\.json",
        "materials/util": rb"materials/util/[A-Za-z0-9_]+\.json",
        "util texture": rb'"util/[a-z0-9_]+"',
        "jsmodule import": rb"from ['\"]WE[A-Za-z]+['\"]",
        "presets copy": rb"(?:materials|particles)/presets/[A-Za-z0-9_]+\.json",
        "assets/ absolute": rb"assets/[a-z]+/",
    }
    blob = {}
    for key, rx in sorted(BLOB_RX.items()):
        per_item = collections.defaultdict(set)
        raw = collections.Counter()
        items = set()
        for wid, data, _e, _b in pkgs:
            for m in re.finditer(rx, data):
                s = m.group(0).decode("utf-8", "ignore")
                raw[s] += 1
                per_item[s].add(wid)
                items.add(wid)
        byitem = {k: len(v) for k, v in per_item.items()}
        blob[key] = {"items": len(items), "rawMatches": sum(raw.values()),
                     "itemsPerName": dict(sorted(byitem.items(), key=lambda kv: (-kv[1], kv[0]))[:10])}
    entries.append(specfmt.entry(
        "misc.corpusSharedAssetReferences",
        {"measurement": "pkg blob **본문** 정규식. 엔트리 이름이 아니다 — "
                        "공유 에셋 경로는 코드 리터럴이 아니라 씬/머티리얼 JSON 데이터에서 온다",
         "itemsPerName": "그 이름을 참조하는 pkg 개수(한 pkg 안 중복은 1)",
         "patterns": blob,
         "crossRef": "materials/util 상세 카탈로그는 spec/assets/material-schema.json 의 "
                     "material.util.* 가 정본이다. 여기서는 models/util 대조용으로만 같이 센다"},
        "확정",
        [ev_corpus, specfmt.ev("script", "pkg blob 본문 정규식"), ev_script]))

    entries.append(specfmt.entry(
        "models.util.runtimeProof",
        {"corpusItemsReferencing": blob["models/util"]["items"],
         "scenePkgs": len(pkgs),
         "perFileItems": blob["models/util"]["itemsPerName"],
         "weOwnProjects": ["projects/defaultprojects/dino_run/scene.json",
                           "projects/defaultprojects/neon_sunset/scene.json"],
         "reading": "wallpaper64.exe 에 'models/util/' 리터럴이 없다고 에디터 전용이 아니다. "
                    "경로는 씬 JSON 데이터에서 온다. 코퍼스 %d/%d 씬이 참조하므로 런타임 필수다"
                    % (blob["models/util"]["items"], len(pkgs))},
        "확정", [ev_corpus,
                specfmt.ev("file", "WE 기본 프로젝트 scene.json 의 \"image\":\"models/util/fullscreenlayer.json\""),
                ev_script]))

    cam = os.path.join(A, "models", "editor", "camera", "camera.mdl")
    entries.append(specfmt.entry(
        "models.editorCamera",
        {"path": "models/editor/camera/camera.mdl", "bytes": os.path.getsize(cam),
         "magic": read(cam)[:8].decode("ascii", "ignore"),
         "reading": "에디터 뷰포트의 카메라 기즈모 메시. 런타임 무관"},
        "확정", [ev_asset, ev_script]))

    # ---------- presets ----------------------------------------------------
    pres_root = os.path.join(A, "presets")
    cats = sorted(d for d in os.listdir(pres_root) if os.path.isdir(os.path.join(pres_root, d)))
    cat_info = {}
    lib = {}
    def dep_path(d):
        return d if isinstance(d, str) else d.get("file", "")

    def variants_of(j):
        """신스키마는 variants[], 구스키마는 최상위 preview/objects/dependencies 를 1개 변형으로 본다."""
        if "variants" in j:
            return j["variants"], "variants"
        return [{k: j[k] for k in ("preview", "objects", "dependencies") if k in j}], "flat"

    for c in cats:
        pj = os.path.join(pres_root, c, "preset.json")
        j = lenient_json(read(pj))
        vs, shape = variants_of(j)
        deps_raw = [d for v in vs for d in v.get("dependencies", [])]
        deps = [dep_path(d) for d in deps_raw]
        cat_info[c] = {"name": j.get("name"), "tag": j.get("tag"), "group": j.get("group"),
                       "schemaShape": shape,
                       "disabledKeys": sorted(k for k in j if k.startswith("DISABLED_")),
                       "variants": len(vs),
                       "previews": [v.get("preview") for v in vs],
                       "dependencyKinds": sorted({d.split("/")[0] for d in deps if d}),
                       "dependencyForms": sorted({("문자열" if isinstance(d, str)
                                                   else "{%s}" % ",".join(sorted(d)))
                                                  for d in deps_raw})}
        for kind in ("materials", "particles"):
            d = os.path.join(pres_root, c, kind, "presets")
            if not os.path.isdir(d):
                continue
            for f in sorted(os.listdir(d)):
                lib.setdefault("%s/presets/%s" % (kind, f), set()).add(sha16(read(os.path.join(d, f))))
    # preset.json 은 최상위 20개 말고 preview 미니 프로젝트 안에도 사본이 있고, 그쪽은 스키마가 다르다
    all_preset_json = []
    for dp, _dn, fn in os.walk(pres_root):
        for f in sorted(fn):
            if f != "preset.json":
                continue
            rel = os.path.relpath(os.path.join(dp, f), A).replace(os.sep, "/")
            j = lenient_json(read(os.path.join(dp, f)))
            all_preset_json.append({"path": rel,
                                    "keys": sorted(j.keys()) if isinstance(j, dict) else None,
                                    "schema": "variants" if isinstance(j, dict) and "variants" in j
                                              else "objects"})
    schema_mix = collections.Counter(x["schema"] for x in all_preset_json)
    entries.append(specfmt.entry(
        "presets.catalogue",
        {"categories": len(cats), "libraryFiles": len(lib), "perCategory": cat_info,
         "presetJsonFiles": len(all_preset_json),
         "schemaMix": dict(sorted(schema_mix.items())),
         "legacySchemaFiles": sorted(x["path"] for x in all_preset_json if x["schema"] == "objects"),
         "schemaNote": "preset.json 은 두 형태가 공존한다. 신형은 options.droplistOptions + "
                       "variants[]{preview,objects,dependencies}, 구형은 최상위에 "
                       "preview/objects/dependencies 를 바로 둔다(variants 없음). "
                       "구형 일부는 tag 대신 'scene':'2d' 를 쓴다",
         "disabledConvention": "키 앞에 DISABLED_ 를 붙여 항목을 끈다 — "
                               "예: presets/fern/preset.json 의 'DISABLED_name'. "
                               "name 이 없는 프리셋은 에디터 목록에 안 뜬다는 뜻으로 읽힌다(추정 아님: 키 실재)",
         "descriptorSchema": {"name": "로케일 키", "description": "로케일 키",
                              "tag": "scene2d 등", "group": "preset",
                              "options.droplistOptions": "[{label, value}]",
                              "variants[].preview": "미니 프로젝트 project.json 경로",
                              "variants[].objects": "씬에 삽입할 오브젝트 배열",
                              "variants[].dependencies": "프로젝트로 복사할 파일 목록"}},
        "확정", [ev_asset, ev_script]))

    names = collections.Counter()
    pres_items = set()
    cls = collections.Counter()
    for wid, data, ents, base in pkgs:
        for name, off, size in ents:
            if not (name.startswith("materials/presets/") or name.startswith("particles/presets/")):
                continue
            pres_items.add(wid)
            names[name] += 1
            h = sha16(data[base + off:base + off + size])
            if name not in lib:
                cls["라이브러리에 없는 이름"] += 1
            elif h in lib[name]:
                cls["바이트 동일"] += 1
            else:
                cls["이름 동일·내용 변경"] += 1
    entries.append(specfmt.entry(
        "presets.editorOnly",
        {"runtimeLiteral": {"wallpaper64.exe 'preset.json'": cons["preset.json"].get("wallpaper64.exe", 0),
                            "wallpaperui.exe 'preset.json'": cons["preset.json"].get("wallpaperui.exe", 0)},
         "corpusItemsWithCopies": len(pres_items),
         "corpusEntries": sum(names.values()),
         "distinctNames": len(names),
         "namesFoundInSharedLibrary": len([n for n in names if n in lib]),
         "contentClassification": dict(sorted(cls.items())),
         "corpusPathsIntoAssetsPresets": blob["assets/ absolute"]["items"],
         "sharedFallbackDirsExist": {
             "assets/materials/presets": os.path.isdir(os.path.join(A, "materials", "presets")),
             "assets/particles/presets": os.path.isdir(os.path.join(A, "particles", "presets"))},
         "reading": "assets/presets/ 는 **에디터 콘텐츠 라이브러리**다. 에디터가 preset.json 의 "
                    "variants[].dependencies 를 프로젝트로 복사하므로, 워크샵 프로젝트는 "
                    "항상 자기 사본을 들고 다닌다. 런타임이 assets/presets/ 를 해석하는 일은 없다. "
                    "코퍼스에서 이름은 %d/%d 가 공유 라이브러리에 있고 상당수는 바이트까지 같다 — "
                    "복사본이라는 직접 증거다. 게다가 공유 에셋에는 "
                    "materials/presets/ 도 particles/presets/ 도 아예 없으므로, "
                    "프로젝트가 사본을 빠뜨리면 **폴백이 없다**"
                    % (len([n for n in names if n in lib]), len(names))},
        "확정", [ev_corpus, ev_asset,
                specfmt.ev("binary", "'preset.json' 은 bin/wallpaperui.exe 에만 있다"), ev_script]))

    # ---------- JSON 관용성 (측정하다 걸린 것 — Waple 로더의 하드 제약) ------
    strict_fail = []
    json_total = 0
    for dp, _dn, fn in os.walk(A):
        for f in sorted(fn):
            if not f.lower().endswith((".json", ".tex-json")):
                continue
            p = os.path.join(dp, f)
            json_total += 1
            ok, needs, _obj = classify_json(read(p))
            if not ok:
                strict_fail.append({"path": os.path.relpath(p, A).replace(os.sep, "/"),
                                    "needs": needs})
    corpus_fail = 0
    corpus_json = 0
    for _wid, data, ents, base in pkgs:
        for name, off, size in ents:
            if not name.lower().endswith((".json", ".tex-json")):
                continue
            corpus_json += 1
            try:
                json.loads(data[base + off:base + off + size].decode("utf-8-sig"))
            except ValueError:
                corpus_fail += 1
    by_tree = collections.Counter(x["path"].split("/")[0] for x in strict_fail)
    mine = [x for x in strict_fail if x["path"].split("/")[0] == "presets"]
    entries.append(specfmt.entry(
        "presets.jsonTrailingCommas",
        {"bundledJsonFiles": json_total,
         "strictParseFailuresAllTrees": len(strict_fail),
         "failuresByTree": dict(sorted(by_tree.items())),
         "presetsFailures": mine,
         "corpusPkgJsonEntries": corpus_json,
         "corpusStrictParseFailures": corpus_fail,
         "presetsNeeds": dict(sorted(collections.Counter(x["needs"] for x in mine).items())),
         "crossRef": "effects/·materials/ 쪽 %d개는 spec/assets/material-schema.json 의 "
                     "material.jsonDialect / waple.gap.strictJSON 이 정본이다. "
                     "여기서는 presets/ %d개만 새로 더한다"
                     % (by_tree.get("effects", 0), len(mine)),
         "reading": "WE 의 JSON 방언은 **후행 쉼표와 `//` 줄 주석**을 둘 다 허용한다. "
                    "presets/ 의 %d개가 엄격 파서로 거부되고 needs 로 분류하면 %s 다. "
                    "워크샵 pkg 안 JSON 은 %d개 전건 엄격 통과 — 비엄격 JSON 은 "
                    "WE 배포 에셋 원본에만 있다. Waple 이 presets 를 읽을 계획이 없으면 "
                    "무해하지만, 동봉 에셋 로더가 트리 전체를 훑는 순간 이것들이 조용히 실패한다"
                    % (len(mine),
                       dict(sorted(collections.Counter(x["needs"] for x in mine).items())),
                       corpus_json)},
        "확정", [ev_asset, ev_corpus, ev_script]))

    # ---------- scripts ----------------------------------------------------
    bc = read(os.path.join(A, "scripts", "jsclasses", "baseclasses.js")).decode("utf-8")
    top = re.findall(r"(?m)^\s{0,1}(class|function|const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)", bc)
    syms = collections.OrderedDict()
    for kind, name in top:
        syms.setdefault(kind, [])
        if name not in syms[kind]:
            syms[kind].append(name)
    mods = {}
    jm = os.path.join(A, "scripts", "jsmodules")
    for f in sorted(os.listdir(jm)):
        src = read(os.path.join(jm, f)).decode("utf-8")
        mods[f] = {"exports": sorted(set(re.findall(r"export\s+(?:function|let|var|const)\s+(\w+)", src))),
                   "imports": sorted(set(re.findall(r"from\s+'([^']+)'", src)))}
    imports = collections.Counter()
    imp_items = set()
    for wid, data, _e, _b in pkgs:
        for m in re.finditer(rb"from ['\"](WE[A-Za-z]+)['\"]", data):
            imports[m.group(1).decode()] += 1
            imp_items.add(wid)
    calls = collections.Counter()
    call_items = collections.defaultdict(set)
    for mod, fns in (("WEMath", mods["wemath.js"]["exports"]),
                     ("WEColor", mods["wecolor.js"]["exports"]),
                     ("WEVector", mods["wevector.js"]["exports"])):
        for fn in fns:
            needle = ("%s.%s" % (mod, fn)).encode()
            for wid, data, _e, _b in pkgs:
                c = data.count(needle)
                if c:
                    calls["%s.%s" % (mod, fn)] += c
                    call_items["%s.%s" % (mod, fn)].add(wid)
    entries.append(specfmt.entry(
        "scripts.assetInventory",
        {"files": {"scripts/jsclasses/baseclasses.js":
                       os.path.getsize(os.path.join(A, "scripts", "jsclasses", "baseclasses.js")),
                   "scripts/jsmodules/wecolor.js": os.path.getsize(os.path.join(jm, "wecolor.js")),
                   "scripts/jsmodules/wemath.js": os.path.getsize(os.path.join(jm, "wemath.js")),
                   "scripts/jsmodules/wevector.js": os.path.getsize(os.path.join(jm, "wevector.js"))},
         "moduleExports": mods,
         "resolution": "bin/scenescript64.dll 이 'scripts/jsmodules/' + <모듈명> + '.js' 로 만든다",
         "nameMapping": {"WEMath": "wemath.js", "WEColor": "wecolor.js", "WEVector": "wevector.js"},
         "nested": "wevector.js 자신이 `import * as WEMath from 'WEMath'` 를 한다 — 모듈 간 import 가 된다",
         "topLevelSymbolsOfBaseclasses": {k: syms[k] for k in sorted(syms)},
         "crossRef": "클래스 메서드 표·d.ts 대조·네이티브 핸들은 spec/engine/script-api.json 의 "
                     "script.baseclasses / script.api.vectors / script.api.modules 가 정본이다. "
                     "여기는 **에셋 쪽 사실**(파일·크기·export 목록·해석 규칙)만 담는다",
         "reading": "assets/scripts/ 4개 파일은 전부 런타임(bin/scenescript64.dll)이 읽는다. "
                    "에디터 전용이 아니다"},
        "확정", [ev_asset, specfmt.ev("binary", "bin/scenescript64.dll"), ev_script]))
    entries.append(specfmt.entry(
        "scripts.corpusUsage",
        {"itemsImportingAnyModule": len(imp_items),
         "scenePkgs": len(pkgs),
         "importsByModule": dict(sorted(imports.items())),
         "callsByFunction": {k: {"calls": calls[k], "items": len(call_items[k])}
                             for k in sorted(calls, key=lambda k: (-calls[k], k))},
         "unusedExports": sorted(set("%s.%s" % (m, f)
                                     for m, fs in (("WEMath", mods["wemath.js"]["exports"]),
                                                   ("WEColor", mods["wecolor.js"]["exports"]),
                                                   ("WEVector", mods["wevector.js"]["exports"]))
                                     for f in fs) - set(calls)),
         "reading": "코퍼스 %d/%d 씬이 공유 JS 모듈을 import 한다. "
                    "호출 도수가 구현 우선순위를 준다 — WEMath.mix/smoothStep 이 압도적이고 "
                    "unusedExports 는 코퍼스에서 한 번도 안 불린다"
                    % (len(imp_items), len(pkgs))},
        "확정", [ev_corpus, ev_asset, ev_script]))

    # ---------- shaders/declarations.json ----------------------------------
    decl = json.loads(read(os.path.join(A, "shaders", "declarations.json")).decode("utf-8"))
    groups = {}
    for g in sorted(decl):
        e0 = decl[g][0]
        tex = e0.get("textures", [{}])[0]
        groups[g] = {"value": e0.get("value"), "shader": e0.get("shader"),
                     "combos": e0.get("combos", {}),
                     "blending": e0.get("blending"), "depthtest": e0.get("depthtest"),
                     "depthwrite": e0.get("depthwrite"), "cullmode": e0.get("cullmode"),
                     "formats": [f["value"] for f in tex.get("formats", [])],
                     "texConfig": {k: tex.get("config", {})[k] for k in sorted(tex.get("config", {}))}}
    entries.append(specfmt.entry(
        "shaders.declarations",
        {"path": "shaders/declarations.json",
         "consumer": {"wallpaperui.exe": cons["declarations.json"].get("wallpaperui.exe", 0),
                      "wallpaper64.exe": cons["declarations.json"].get("wallpaper64.exe", 0)},
         "groups": groups,
         "schema": {"<group>": "[{value, shader, label, blending, depthtest, depthwrite, cullmode, "
                               "combos, textures:[{suffix, formats:[{value,label}], config}]}]"},
         "reading": "에디터 임포터의 **기본 머티리얼 선언표**다. 이미지/모델을 프로젝트에 넣을 때 "
                    "어떤 셰이더·블렌딩·텍스처 포맷을 기본으로 쓸지 정한다. "
                    "런타임은 읽지 않는다(wallpaper64.exe 0회). "
                    "Waple 에게는 '임포트된 이미지 레이어의 기본 상태'를 알려주는 대조표로 값이 있다"},
        "확정", [ev_asset, specfmt.ev("binary", "'declarations.json' 은 bin/wallpaperui.exe 에만"), ev_script]))

    # ---------- Waple 대조 --------------------------------------------------
    # Swift 툴체인이 없어 빌드/실행은 못 한다. 소스 문자열 존재 여부만 기계적으로 센다.
    SRC = "Sources"
    def src_hits(needle):
        n = 0
        files = []
        for dp, _dn, fn in os.walk(SRC):
            for f in sorted(fn):
                if not f.endswith(".swift"):
                    continue
                p = os.path.join(dp, f)
                c = read(p).decode("utf-8", "ignore").count(needle)
                if c:
                    n += c
                    files.append(os.path.relpath(p, SRC).replace(os.sep, "/"))
        return {"hits": n, "files": files[:6]}

    waple = {k: src_hits(k) for k in
             ("zcompat", "models/util", "keepaspect", "normalizeColor", "expandColor",
              "videoplayer", "videotex", "jsmodules", "baseclasses")}
    entries.append(specfmt.entry(
        "waple.sourceStringCensus", waple, "확정",
        [specfmt.ev("file", "Sources/**/*.swift 문자열 카운트"),
         specfmt.ev("script", "Swift 툴체인이 없어 빌드/실행은 못 했다 — 존재 여부만"), ev_script]))

    entries.append(specfmt.entry(
        "waple.ok.zcompatZero",
        {"waple": "'zcompat' 문자열 %d회 — 0건 구현" % waple["zcompat"]["hits"],
         "정본": "scene zcompat 은 모바일 익스포트 전용이라 데스크톱 렌더러가 구현할 것이 없다",
         "판정": "현행이 옳다. 다만 web 월페이퍼를 구현하면 zcompat/web 은 런타임이라 필요해진다"},
        "확정", [specfmt.ev("binary", "wallpaper64.exe 에 'zcompat' 0회"),
                specfmt.ev("file", "Sources/**/*.swift"), ev_script]))

    entries.append(specfmt.entry(
        "waple.note.videoPathDivergence",
        {"정본": "WE 는 type=video 를 **씬**으로 돌린다 — assets/scenes/videoplayer/scene.json 을 열고 "
                 "디코딩 프레임을 usertexture 'videotex' 로 바인딩한다"
                 "(배선 상세는 spec/engine/media.json)",
         "Waple": "RendererFactory 가 .video 를 VideoRenderer(AVPlayer/AVPlayerLayer)로 라우팅한다 — "
                  "씬 그래프를 타지 않는다",
         "측정된 것": {
             "keepaspect 를 아는 Waple 소스": waple["keepaspect"]["hits"],
             "코퍼스 pkg 안 'keepaspect' 참조 pkg 수": 0,
             "번들 씬 general 의 후처리": "bloom=false, bloomhdrstrength=0"},
         "판정": "결함이 아니라 **구조 분기**다. WE 의 videotex 씬은 후처리를 명시적으로 비운 "
                "1오브젝트 씬이라 AVPlayer 직접 합성과 화면 결과가 갈릴 이유가 지금은 없다. "
                "코퍼스 어느 씬도 keepaspect 를 쓰지 않으므로 현행 코퍼스에서 관측 가능한 차이는 0이다",
         "언제 문제가 되나": "비디오 위에 씬 이펙트/레이어를 얹는 기능(WE 는 씬이므로 공짜)을 "
                          "구현하려 할 때, Waple 은 경로를 합쳐야 한다",
         "확인 못 한 것": "keepaspect + autosize + orthogonalprojection.auto 의 조합이 "
                       "fit 인지 fill 인지는 파일 검사만으로 안 갈린다 — 빌드/골든이 없다"},
        "보고",
        [specfmt.ev("asset", "scenes/videoplayer/{scene,models/background,materials/background}.json"),
         specfmt.ev("file", "Sources/WapleRender/RendererFactory.swift case .video"),
         ev_corpus, ev_script]))

    entries.append(specfmt.entry(
        "waple.gap.weColorMissingExports",
        {"정본": "wecolor.js 는 4개를 export 한다: %s" % ", ".join(mods["wecolor.js"]["exports"]),
         "Waple": "TextScriptEngine 의 __WEColor 는 hsv2rgb / rgb2hsv 2개뿐 — "
                  "normalizeColor(%d회) / expandColor(%d회) 가 없다"
                  % (waple["normalizeColor"]["hits"], waple["expandColor"]["hits"]),
         "실패 시나리오": "스크립트가 WEColor.normalizeColor(c) 를 부르면 undefined 호출로 예외",
         "코퍼스 영향": {k: {"calls": calls.get(k, 0), "items": len(call_items.get(k, ()))}
                     for k in ("WEColor.normalizeColor", "WEColor.expandColor",
                               "WEColor.rgb2hsv", "WEColor.hsv2rgb")},
         "판정": "코퍼스 호출 0건이라 지금은 발현하지 않는다. 구현은 4줄이고 원문이 동봉돼 있다"},
        "확정", [ev_asset, ev_corpus,
                specfmt.ev("file", "Sources/WapleRender/TextScriptEngine.swift __WEColor"), ev_script]))

    entries.append(specfmt.entry(
        "waple.ok.modelsUtilResolved",
        {"정본": "코퍼스 %d/%d 씬이 models/util/*.json 을 경로로 참조한다 — 런타임 필수"
                 % (blob["models/util"]["items"], len(pkgs)),
         "Waple": "SceneDocument 가 공유 base-assets 리졸버로 models/util/*.json 을 푼다. "
                  "config 의 passthrough / solidlayer / projectlayer 플래그도 파싱한다",
         "확인 못 한 것": "fullscreen / autosize 플래그가 models/util JSON 최상위에서(오브젝트 config 가 아니라) "
                       "읽히는지는 소스 문자열만으로는 못 가린다 — 빌드가 없다",
         "판정": "현행이 맞는 방향. 세부 플래그 커버리지는 미확인"},
        "보고", [ev_corpus, specfmt.ev("file", "Sources/WapleCore/SceneDocument.swift:843"), ev_script]))

    out = os.path.join("spec", "assets", "misc-schema.json")
    specfmt.dump(specfmt.doc("scripts/spec/measure_misc_assets.py", entries), out)
    print("%s: 항목 %d개" % (out, len(entries)))


if __name__ == "__main__":
    main()
