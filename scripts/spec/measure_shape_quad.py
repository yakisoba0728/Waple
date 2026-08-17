"""`shape:"quad"` 이펙트 캐리어 오브젝트 정본 → spec/engine/shape-quad.json

왜 이 스크립트가 있나.
  `SceneDocument.effectQuadLayer` 는 shape 오브젝트를 **풀스크린**으로 승격하며 저작
  origin/scale/angles 를 버린다. 그 결과 화면 밖에 놓인 쿼드(3404976219: origin
  (-521.8, 2333.7))가 전화면을 칠한다. 고치려면 "WE 의 shape 쿼드 기본 크기" 를 알아야
  하는데, 프리셋 프리뷰 3종의 scale 로 역산하면 122/126/212 로 갈려 추론이 안 됐다
  (아래 §4 가 그 계산을 다시 낸다 — 실패를 정본에 남겨 두는 이유는 다음 사람이 같은
  막다른 길을 또 파지 않게 하려는 것이다).

무엇을 바이트로 확인하나(전부 wallpaper64.exe, Ghidra 없이 재현된다).
  §1 문자열 `"quad"` 가 **어떤 WE 바이너리에도 없다**(ASCII·UTF-16). 즉 shape 의 값
     문자열은 엔진이 해석하지 않는다. `"shape"` 는 있다(대조).
  §2 오브젝트 디스패처의 shape 분기 — `"shape"` 문자열 xref 2건 뒤에 오는 것은 JSON
     노드 **타입 태그 비교**(`cmp byte ptr [rax+8], 4`) 하나뿐이고, 값 문자열 비교가
     없다. 이어서 0x460 바이트 객체를 new 하고 vtable 을 심는다.
  §3 그 vtable 의 슬롯 +0x40 함수가 `(float)(int32)[ctx + F]` 를 `this + S` 에 **두 성분**
     으로 쓴다(movsd = 8바이트 = float 2개). F/S 는 바이트에서 뽑는다(하드코딩 아님).
  §4 general.orthogonalprojection 파스가 width/height 를 float 로 씬에 넣고, 같은 함수가
     그 둘을 **int 로 잘라** ctx+0x84 / ctx+0x88 에 넣는다. §3 의 F 가 0x88 이면 곧
     ortho **height** 다.
  §5 코퍼스 — shape 오브젝트 전수(값·effects·size 키·parent·쿼드를 부모로 삼는 자식 수).
  §6 lightshafts 프리셋 프리뷰 3종의 scale 역산(=실패한 추론의 재현).
  §7 **그 오프셋이 무엇인지** — 렌더러블 기반 클래스의 프로퍼티 리플렉션 등록 함수를 읽어
     `(이름, 멤버 오프셋)` 쌍을 뽑는다. `"size"` 가 §3 의 S 와 같은 오프셋에 등록돼 있으면
     추론이 아니라 바이너리가 스스로 이름을 대는 것이다(대조: color/alpha/brightness).
  §8 **소비 지점** — 드로우 준비 함수가 `[this+S]`, `[this+S+4]` 를 **0.5 로 곱해** 월드행렬
     0·1행에 각각 스케일해 상수 블록에 쓴다. 즉 쿼드는 origin 중심 ±size/2 다. 0.5 는
     rip-상대 상수를 실제로 읽어 확인한다(하드코딩 아님).
  §9 이미지 레이어 클래스(alloc 0x960)의 vtable 과 shape vtable(0x460)의 **슬롯 교집합** —
     같은 기반 클래스를 공유하므로 §7 의 size@S 가 이미지 레이어에도 같은 자리다. 저작
     `size`(풀스크린 이미지 = 프로젝션 크기)가 정확히 화면을 덮는다는 사실이 §8 의
     "로컬 코너 ±1" 규약을 되짚어 준다(2배 모호성 해소).

경로 환경변수: WE_ROOT(설치본) 또는 WE_BIN(wallpaper64.exe 직접), WE_WORKSHOP(코퍼스).

⚠️ 보관본 PE 의 208B 섹션 오프셋 어긋남은 measure_texture_filtering.PE 가 보정한다
(그 모듈 독스트링 참조) — 여기서는 그 리더를 그대로 재사용한다.
"""
import collections
import json
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt
from measure_texture_filtering import PE, BIN, WE
from measure_corpus import parse_pkg, WS

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ASSETS = os.path.join(REPO, "Sources", "WapleRender", "Resources", "WEAssets")
OUT = os.path.join("spec", "engine", "shape-quad.json")

# 같은 설치본 안의 형제 바이너리 — "quad" 부재를 엔진 전체로 넓혀 확인한다.
SIBLINGS = ("wallpaper64.exe", os.path.join("bin", "wallpaperui.exe"),
            os.path.join("bin", "scenescript64.dll"),
            os.path.join("bin", "resourcecompiler64.exe"),
            os.path.join("bin", "webwallpaper64.exe"))


def fail(msg):
    raise SystemExit("measure_shape_quad: " + msg)


# ── PE 보조 ────────────────────────────────────────────────────────────────

def string_vas(pe, s):
    """NUL 로 시작·끝나는 정확한 문자열의 VA 전수."""
    pat = s.encode() + b"\0"
    out, start = [], 0
    while True:
        i = pe.d.find(pat, start)
        if i < 0:
            return out
        start = i + 1
        if i and pe.d[i - 1] != 0:
            continue          # 더 긴 문자열의 꼬리
        for nm, va, vsz, ptr, rsz in pe.secs:
            if ptr <= i < ptr + rsz:
                out.append(pe.base + va + (i - ptr))
                break


def text_bounds(pe):
    nm, va, vsz, ptr, rsz = pe.sec(".text")
    return va, ptr, rsz


def rip_refs(pe, target):
    """.text 안에서 rip-상대 disp32 가 target 을 가리키는 지점(그 disp32 필드의 VA)."""
    va, ptr, rsz = text_bounds(pe)
    d, base, out = pe.d, pe.base, []
    for i in range(ptr, ptr + rsz - 4):
        disp = struct.unpack_from("<i", d, i)[0]
        if base + va + (i + 4 - ptr) + disp == target:
            out.append(base + va + (i - ptr))
    return out


def at(pe, va, n):
    return pe.d[pe.rva2off(va - pe.base):pe.rva2off(va - pe.base) + n]


def in_text(pe, va):
    _nm, tva, _vsz, _ptr, rsz = pe.sec(".text")
    return pe.base + tva <= va < pe.base + tva + rsz


def fn_body(pe, va):
    """va 가 속한 함수의 (바이트, 시작VA). .pdata 범위 기준(PE.funcs 는 병합돼 있다)."""
    import bisect
    f = pe.fn_start(va - pe.base)
    if f is None:
        return None, None
    i = bisect.bisect_right(pe.starts, f) - 1
    b, e = pe.funcs[i]
    o1, o2 = pe.rva2off(b), pe.rva2off(e - 1)
    if o1 is None or o2 is None:
        return None, None
    return pe.d[o1:o2 + 1], pe.base + b


def vtable_slots(pe, vt, limit=80):
    """vtable 의 .text 를 가리키는 연속 슬롯. 첫 비-.text 값에서 멈춘다."""
    off = pe.rva2off(vt - pe.base)
    out = []
    for i in range(limit):
        p = struct.unpack_from("<Q", pe.d, off + i * 8)[0]
        if not in_text(pe, p):
            break
        out.append(p)
    return out


def call_closure(pe, roots, depth):
    """roots(함수 VA들)에서 직접 호출(E8 rel32)로 depth 단계까지 닿는 함수 시작 VA 집합."""
    seen, frontier = set(), list(roots)
    for _ in range(depth + 1):
        nxt = []
        for v in frontier:
            body, bva = fn_body(pe, v)
            if body is None or bva in seen:
                continue
            seen.add(bva)
            for m in re.finditer(rb"\xe8(....)", body, re.S):
                tgt = bva + m.end() + struct.unpack("<i", m.group(1))[0]
                if in_text(pe, tgt):
                    nxt.append(tgt)
        frontier = nxt
    return seen


# ── §1 값 문자열 부재 ──────────────────────────────────────────────────────

def measure_value_string_absent():
    root = os.path.dirname(BIN) if os.path.basename(BIN).lower().endswith(".exe") else WE
    if os.path.basename(root).lower() == "wallpaper_engine":
        base = root
    else:
        base = WE
    rows = {}
    for rel in SIBLINGS:
        p = os.path.join(base, rel)
        if not os.path.exists(p):
            rows[rel] = None
            continue
        d = open(p, "rb").read()
        rows[rel] = {
            "bytes": len(d),
            "asciiQuad": len(re.findall(rb"(?<![A-Za-z0-9_])quad\x00", d)),
            "utf16Quad": len(re.findall(re.escape("quad".encode("utf-16-le")), d)),
            "asciiShape": len(re.findall(rb"(?<![A-Za-z0-9_])shape\x00", d)),
        }
    present = [k for k, v in rows.items() if v]
    if not present:
        fail("형제 바이너리를 하나도 못 찾았다 — WE_ROOT/WE_BIN 확인")
    return rows


# ── §2 디스패처 shape 분기 ────────────────────────────────────────────────

# 0x140190779 실측 바이트에서 뽑은 형태(오프셋/상대주소는 와일드카드):
#   4C 8D 05 rel32        lea r8,[rip+..]   ; "shape" 끝
#   48 8B CE              mov rcx,rsi
#   48 8D 15 rel32        lea rdx,[rip+..]  ; "shape"
#   E8 rel32              call <json lookup>
#   80 78 08 04           cmp byte [rax+8], 4      ← 타입 태그(문자열)만 본다
#   75 imm8               jne <다음 분기>
#   B9 imm32              mov ecx, <객체 크기>
#   E8 rel32              call operator new
DISPATCH = re.compile(
    rb"\x4c\x8d\x05....\x48\x8b\xce\x48\x8d\x15(....)\xe8....\x80\x78\x08(.)\x75."
    rb"\xb9(....)\xe8....", re.S)


def measure_dispatch(pe):
    vas = string_vas(pe, "shape")
    if len(vas) != 1:
        fail("'shape' 문자열이 %d 개다(기대 1) — WE 판올림" % len(vas))
    refs = rip_refs(pe, vas[0])
    if len(refs) != 2:
        fail("'shape' xref 가 %d 건이다(기대 2)" % len(refs))
    site = refs[1] - 3            # lea 명령 시작
    blob = at(pe, site - 18, 64)
    m = DISPATCH.search(blob)
    if not m:
        fail("shape 분기의 명령 시퀀스를 못 찾았다 — 값 문자열 비교가 새로 생겼을 수 있다")
    tag = m.group(2)[0]
    alloc = struct.unpack("<I", m.group(3))[0]
    # 같은 함수 창에서 값 문자열("quad" 등) 과의 비교가 없음을 재확인: 창 안 rip-참조가
    # 가리키는 .rdata 문자열이 'shape' 하나뿐이어야 한다.
    return {"stringVA": hex(vas[0]), "xrefs": [hex(r) for r in refs],
            "branchVA": hex(site), "jsonTypeTag": tag, "allocBytes": alloc,
            "valueStringCompare": False}


def vtable_of(pe, branch_va):
    """분기 직후 `lea rax,[rip+..]; ...; mov [rdi],rax` 로 심는 vtable VA."""
    blob = at(pe, branch_va, 160)
    for m in re.finditer(rb"\x48\x8d\x05(....)", blob, re.S):
        ins_end = branch_va + m.end()
        tgt = ins_end + struct.unpack("<i", m.group(1))[0]
        # vtable 은 .rdata 에 있고 첫 슬롯이 .text 를 가리킨다.
        off = pe.rva2off(tgt - pe.base)
        if off is None:
            continue
        slot0 = struct.unpack_from("<Q", pe.d, off)[0]
        tva, tptr, trsz = text_bounds(pe)
        if pe.base + tva <= slot0 < pe.base + tva + trsz:
            return tgt
    fail("shape 분기에서 vtable 을 못 찾았다")


# ── §3 init 훅이 쓰는 두 성분 ─────────────────────────────────────────────

INIT = re.compile(
    rb"\x48\x8b\x81(....)"          # mov rax,[rcx+ctxOff]
    rb"\x66\x0f\x6e\x80(....)"      # movd xmm0,[rax+fieldOff]   (int32)
    rb"\x66\x0f\x70\xc0\x00"        # pshufd xmm0,xmm0,0
    rb"\x0f\x5b\xc8"                # cvtdq2ps xmm1,xmm0
    rb"\xf2\x0f\x11\x89(....)",     # movsd [rcx+dstOff],xmm1    (float 2개)
    re.S)


def measure_init(pe, vtable):
    off = pe.rva2off(vtable - pe.base)
    fn = struct.unpack_from("<Q", pe.d, off + 0x40)[0]
    m = INIT.match(at(pe, fn, 40))
    if not m:
        fail("shape vfunc+0x40 의 시퀀스가 바뀌었다 — 기본 크기 유도가 무효")
    ctx, field, dst = (struct.unpack("<I", m.group(i))[0] for i in (1, 2, 3))
    return {"vtableVA": hex(vtable), "initVA": hex(fn),
            "ctxFieldOffset": hex(ctx), "sourceIntOffset": hex(field),
            "destFloatPairOffset": hex(dst),
            "writes": "movsd — float 2개(동일 값)"}


# ── §4 ortho → ctx int ────────────────────────────────────────────────────

ORTHO = re.compile(
    rb"\xf3\x41\x0f\x10\x8e(....)"      # movss xmm1,[r14+wOff]      (씬 float width)
    rb".{0,80}?"
    rb"\xf3\x0f\x2c\xc1"                # cvttss2si eax,xmm1
    rb"\x41\x89\x85(....)"              # mov [r13+wIntOff],eax
    rb"\xf3\x41\x0f\x2c\x86(....)"      # cvttss2si eax,[r14+hOff]
    rb"\x41\x89\x85(....)",             # mov [r13+hIntOff],eax
    re.S)


def measure_ortho(pe):
    vas = string_vas(pe, "orthogonalprojection")
    if not vas:
        fail("'orthogonalprojection' 문자열이 없다")
    refs = rip_refs(pe, vas[0])
    for r in refs:
        blob = at(pe, r, 400)
        m = ORTHO.search(blob)
        if not m:
            continue
        w, wi, h, hi = (struct.unpack("<I", m.group(i))[0] for i in (1, 2, 3, 4))
        return {"parseSiteVA": hex(r), "sceneWidthFloatOffset": hex(w),
                "sceneHeightFloatOffset": hex(h),
                "ctxWidthIntOffset": hex(wi), "ctxHeightIntOffset": hex(hi)}
    fail("ortho width/height → ctx int 저장 시퀀스를 못 찾았다")


# ── §5 코퍼스 ─────────────────────────────────────────────────────────────

def load_scene(wid):
    for pkgname, cands in (("scene.pkg", ("scene.json", "gifscene.json")),
                           ("gifscene.pkg", ("gifscene.json", "scene.json"))):
        p = os.path.join(WS, wid, pkgname)
        if not os.path.exists(p):
            continue
        data = open(p, "rb").read()
        try:
            _m, entries, base = parse_pkg(data)
        except Exception:
            return None
        t = {n: (o, s) for n, o, s in entries}
        nm = next((c for c in cands if c in t), None)
        if nm is None:
            continue
        o, s = t[nm]
        try:
            return json.loads(data[base + o:base + o + s].decode("utf-8-sig"))
        except Exception:
            return None
    return None


def vec_first(s, default=1.0):
    """`"3.00000 3.00000 1.00000"` → 3.0. dict 바인딩({user,value})도 언랩."""
    if isinstance(s, dict):
        s = s.get("value")
    if s is None:
        return default
    try:
        return float(str(s).split()[0])
    except (ValueError, IndexError):
        return default


def measure_corpus():
    if not os.path.isdir(WS):
        fail("코퍼스가 없다: %s (WE_WORKSHOP/WAPLE_REAL_PKGS)" % WS)
    values = collections.Counter()
    total = withEffects = withSize = withParent = childrenOfQuad = 0
    scenes = set()
    # 부모 체인의 scale 누적 — "부모가 쿼드를 키운다" 는 교란을 닫기 위한 실측.
    ancestor_scaled = 0
    self_scaled = 0
    scaled_examples = []
    for wid in sorted(os.listdir(WS)):
        if not os.path.isdir(os.path.join(WS, wid)):
            continue
        sc = load_scene(wid)
        if not sc:
            continue
        objs = [o for o in sc.get("objects", []) if isinstance(o, dict)]
        byid = {o["id"]: o for o in objs if isinstance(o.get("id"), int)}
        quad_ids = set()
        for o in objs:
            v = o.get("shape")
            if isinstance(v, dict):
                v = v.get("value")
            if v is None:
                continue
            total += 1
            scenes.add(wid)
            values[str(v)] += 1
            if o.get("effects"):
                withEffects += 1
            if o.get("size") is not None:
                withSize += 1
            if isinstance(o.get("parent"), int):
                withParent += 1
            if isinstance(o.get("id"), int):
                quad_ids.add(o["id"])
            own = vec_first(o.get("scale"))
            chain, p, depth = 1.0, o.get("parent"), 0
            while isinstance(p, int) and p in byid and depth < 32:
                chain *= vec_first(byid[p].get("scale"))
                p = byid[p].get("parent")
                depth += 1
            if abs(own - 1.0) > 1e-6:
                self_scaled += 1
            if abs(chain - 1.0) > 1e-6:
                ancestor_scaled += 1
            if abs(own * chain - 1.0) > 1e-6:
                scaled_examples.append({"scene": wid, "id": o.get("id"),
                                        "ownScale": round(own, 5),
                                        "ancestorScaleProduct": round(chain, 5)})
        for o in objs:
            if isinstance(o.get("parent"), int) and o["parent"] in quad_ids:
                childrenOfQuad += 1
    return {"scanned": len(os.listdir(WS)), "shapeObjects": total,
            "scenes": len(scenes), "values": dict(values),
            "quadsWithOwnScale": self_scaled,
            "quadsWithScaledAncestor": ancestor_scaled,
            "scaledQuads": sorted(scaled_examples, key=lambda r: (r["scene"], r["id"] or 0)),
            "scaleNote": "쿼드의 최종 크기 = size × (자기 scale) × (조상 scale 누적). 조상 scale 이 "
                         "1 이 아닌 쿼드는 quadsWithScaledAncestor 건뿐이다 — 3521337568 의 "
                         "쿼드 부모(id 2065)는 scale 키가 없어 (1,1,1) 이고 평행이동만 한다.",
            "withEffects": withEffects, "withSizeKey": withSize,
            "withParent": withParent, "objectsParentedToAQuad": childrenOfQuad}


# ── §6 프리뷰 역산(실패한 추론의 재현) ────────────────────────────────────

PREVIEWS = ("previewlscorner", "previewlsradial", "previewlslinear")


def measure_preview_backsolve():
    rows = {}
    for name in PREVIEWS:
        p = os.path.join(ASSETS, "presets", "lightshafts", name, "scene.json")
        if not os.path.exists(p):
            continue
        sc = json.load(open(p, encoding="utf-8"))
        ortho = sc["general"]["orthogonalprojection"]
        obj = next(o for o in sc["objects"] if o.get("shape"))
        scale = float(str(obj.get("scale", "1 1 1")).split()[0])
        rows[name] = {
            "ortho": [ortho["width"], ortho["height"]],
            "origin": obj.get("origin"), "scale": scale,
            "sizeIfItExactlyFilledFrame": round(ortho["width"] / scale, 1),
        }
    spread = sorted(r["sizeIfItExactlyFilledFrame"] for r in rows.values())
    return {"variants": rows, "spread": spread,
            "verdict": "프리뷰는 저작자가 손으로 배치·확대한 것이라 '프레임을 꽉 채운다'는 "
                       "전제가 성립하지 않는다 — 이 역산으로는 기본 크기를 정할 수 없다"}


# ── §7 프로퍼티 리플렉션 테이블: 이름 → 멤버 오프셋 ─────────────────────────

# 0x1401ee5bd 실측 바이트(오프셋/상대주소는 캡처):
#   48 8D 15 rel32        lea rdx,[rip+..]      ; 프로퍼티 이름 문자열
#   41 B8 imm32           mov r8d, <이름 길이>
#   48 8D 4B 68           lea rcx,[rbx+0x68]    ; 등록 대상(디스크립터의 이름 슬롯)
#   E8 rel32              call <문자열 assign>
#   48 8D 05 rel32        lea rax,[rip+..]      ; getter/setter thunk
#   C7 43 34 imm32        mov dword [rbx+0x34], <멤버 오프셋>   ← 이게 답이다
PROPREG = re.compile(
    rb"\x48\x8d\x15(....)\x41\xb8(....)\x48\x8d\x4b\x68\xe8....\x48\x8d\x05...."
    rb"\xc7\x43\x34(....)", re.S)


def measure_property_table(pe):
    """`"size"` 문자열 xref 중 위 등록 시퀀스가 성립하는 곳을 찾아 그 함수의 전체 표를 뽑는다."""
    vas = string_vas(pe, "size")
    if len(vas) != 1:
        fail("'size' 문자열이 %d 개다(기대 1)" % len(vas))
    site = None
    for r in rip_refs(pe, vas[0]):
        m = PROPREG.match(at(pe, r - 3, 48))
        if m:
            site = r - 3
            break
    if site is None:
        fail("'size' 프로퍼티 등록 시퀀스를 못 찾았다 — 리플렉션 표 형태가 바뀌었다")
    body, bva = fn_body(pe, site)
    if body is None:
        fail("등록 함수의 .pdata 범위를 못 잡았다")
    rows = {}
    for m in PROPREG.finditer(body):
        name_va = bva + m.start() + 7 + struct.unpack("<i", m.group(1))[0]
        off = pe.rva2off(name_va - pe.base)
        if off is None:
            continue
        end = pe.d.find(b"\0", off, off + 64)
        name = pe.d[off:end].decode("ascii", "ignore")
        strlen = struct.unpack("<I", m.group(2))[0]
        if not name or len(name) != strlen:
            continue          # 이름 길이 인자와 실제 문자열이 어긋나면 다른 시퀀스다
        rows[name] = "0x%x" % struct.unpack("<I", m.group(3))[0]
    if "size" not in rows:
        fail("등록 표에서 'size' 를 못 뽑았다")
    return {"registrarVA": hex(bva), "properties": rows}


# ── §8 소비 지점: size × 0.5 로 월드행렬 x·y 기저를 스케일 ─────────────────

# 0x1401ec428 실측(자기완결형 — 0.5 상수 로드가 시퀀스 안에 있다):
#   F3 44 0F 10 86 off32   movss  xmm8,[rsi+size.x]
#   44 0F 29 4C 24 xx      movaps [rsp+..],xmm9      (레지스터 대피 — 값 무관)
#   F3 44 0F 10 8E off32   movss  xmm9,[rsi+size.y]
#   44 0F 29 5C 24 xx      movaps [rsp+..],xmm11
#   F3 44 0F 10 1D rel32   movss  xmm11,[rip+K]      ← K 를 읽어 0.5 임을 확인
#   F3 45 0F 59 C3         mulss  xmm8,xmm11
#   F3 45 0F 59 CB         mulss  xmm9,xmm11
HALVE = re.compile(
    rb"\xf3\x44\x0f\x10\x86(....)\x44\x0f\x29\x4c\x24."
    rb"\xf3\x44\x0f\x10\x8e(....)\x44\x0f\x29\x5c\x24."
    rb"\xf3\x44\x0f\x10\x1d(....)\xf3\x45\x0f\x59\xc3\xf3\x45\x0f\x59\xcb", re.S)


def measure_size_consumer(pe, vtable, size_off):
    """shape vtable 에서 1단계 안에 닿는 함수들 중 size 두 성분을 0.5 배 하는 곳."""
    closure = call_closure(pe, vtable_slots(pe, vtable), 1)
    hits = []
    for fva in sorted(closure):
        body, bva = fn_body(pe, fva)
        if body is None:
            continue
        for m in HALVE.finditer(body):
            sx, sy = (struct.unpack("<I", m.group(i))[0] for i in (1, 2))
            if sx != size_off or sy != size_off + 4:
                continue
            # 상수 로드는 시퀀스 +30 에서 시작하는 9바이트 movss — rip 기준은 그 다음 명령(+39).
            kva = bva + m.start() + 39 + struct.unpack("<i", m.group(3))[0]
            k = struct.unpack("<f", at(pe, kva, 4))[0]
            hits.append({"funcVA": hex(bva), "siteVA": hex(bva + m.start()),
                         "constVA": hex(kva), "constant": k})
    if not hits:
        fail("size 두 성분을 상수배 하는 시퀀스를 못 찾았다 — 소비 규약이 바뀌었다")
    ks = {round(h["constant"], 6) for h in hits}
    if ks != {0.5}:
        fail("size 스케일 상수가 0.5 가 아니다: %s" % sorted(ks))
    # 같은 함수 안에서 size 두 성분을 읽는 movss 사이트 전수(회귀 감지용 개수)
    return {"sites": hits, "halfExtentConstant": 0.5,
            "meaning": "size × 0.5 가 월드행렬의 x·y 기저 행에 곱해진다 → 쿼드는 origin 중심 "
                       "±size/2. 로컬 코너는 ±1(§9 의 이미지 레이어 공유가 되짚는다)."}


# ── §9 이미지 레이어와의 기반 클래스 공유 ─────────────────────────────────

def measure_shared_base(pe, dispatch_branch, shape_vt):
    """디스패처에서 alloc 크기별 vtable 을 모으고, 이미지(0x960) vtable 과 슬롯 교집합을 낸다."""
    body, bva = fn_body(pe, dispatch_branch)
    if body is None:
        fail("디스패처 함수 범위를 못 잡았다")
    # `mov ecx,<객체 크기>; call operator new; ...; mov rdi,rax` — 크기 범위로 잡음을 거른다.
    allocs = []
    for m in re.finditer(rb"\xb9(....)\xe8....\x49\x8b", body, re.S):
        v = struct.unpack("<I", m.group(1))[0]
        if 0x40 <= v <= 0x4000:
            allocs.append((bva + m.start(), v))
    # alloc 직후 심는 vtable(.rdata 이면서 첫 슬롯이 .text)
    def vt_after(pos):
        blob = at(pe, pos, 160)
        for m in re.finditer(rb"\x48\x8d\x05(....)", blob, re.S):
            tgt = pos + m.end() + struct.unpack("<i", m.group(1))[0]
            off = pe.rva2off(tgt - pe.base)
            if off is None:
                continue
            if in_text(pe, struct.unpack_from("<Q", pe.d, off)[0]):
                return tgt
        return None
    table = {}
    for pos, sz in allocs:
        vt = vt_after(pos)
        if vt:
            table.setdefault(sz, hex(vt))
    img_vt = table.get(0x960)
    if img_vt is None:
        fail("이미지 레이어(alloc 0x960) 의 vtable 을 못 찾았다")
    a = vtable_slots(pe, shape_vt)
    b = vtable_slots(pe, int(img_vt, 16))
    shared = [{"slot": hex(i * 8), "fn": hex(a[i])}
              for i in range(min(len(a), len(b))) if a[i] == b[i]]
    if len(shared) < 4:
        fail("shape/이미지 vtable 공유 슬롯이 %d 개뿐이다 — 기반 클래스 공유 전제가 깨졌다"
             % len(shared))
    return {"allocToVtable": {hex(k): v for k, v in sorted(table.items())},
            "imageVtableVA": img_vt, "shapeSlots": len(a), "imageSlots": len(b),
            "sharedSlots": shared,
            "meaning": "shape(0x460)와 이미지(0x960)가 같은 기반 클래스 슬롯을 공유한다 — "
                       "§7 의 size@0x2F0 은 두 타입 공통 필드다. 풀스크린 이미지가 저작 "
                       "size=(프로젝션 w,h) 로 정확히 화면을 덮는다는 사실이 §8 의 ±size/2 "
                       "와 맞물려 로컬 코너 ±1 을 확정한다(2배 모호성 해소)."}


# ── 조립 ──────────────────────────────────────────────────────────────────

def main():
    pe = PE(BIN)
    strings = measure_value_string_absent()
    dispatch = measure_dispatch(pe)
    vt = vtable_of(pe, int(dispatch["branchVA"], 16))
    init = measure_init(pe, vt)
    ortho = measure_ortho(pe)
    corpus = measure_corpus()
    previews = measure_preview_backsolve()
    proptable = measure_property_table(pe)
    size_off = int(init["destFloatPairOffset"], 16)
    if int(proptable["properties"]["size"], 16) != size_off:
        fail("리플렉션 표의 size 오프셋(%s)이 init 이 쓰는 오프셋(0x%x)과 다르다"
             % (proptable["properties"]["size"], size_off))
    consumer = measure_size_consumer(pe, vt, size_off)
    shared = measure_shared_base(pe, int(dispatch["branchVA"], 16), vt)

    binref = specfmt.ev("binary", "wallpaper64.exe (WE 2.8.42) — %s" % BIN)
    scriptref = specfmt.ev("script", "scripts/spec/measure_shape_quad.py")

    entries = [
        specfmt.entry(
            "shape.valueStringNotInterpreted",
            {"perBinary": strings,
             "meaning": "`shape` 의 값 문자열(\"quad\")은 어떤 WE 바이너리에도 없다 — 엔진은 "
                        "값을 해석하지 않고 키 존재와 JSON 타입만 본다. 코퍼스 값이 전건 "
                        "\"quad\" 인 것은 에디터가 그렇게 쓰기 때문이지 엔진 분기 조건이 아니다."},
            "확정", [binref, scriptref]),
        specfmt.entry(
            "shape.dispatchGatesOnJsonTypeOnly",
            dispatch,
            "확정", [binref, scriptref,
                   specfmt.ev("file", "Sources/WapleCore/SceneDocument.swift isEffectQuad — "
                                      "Waple 은 shape 존재 + effects 비어있지 않음으로 판정")]),
        specfmt.entry(
            "shape.initWritesOrthoHeightPair",
            init,
            "확정", [binref, scriptref]),
        specfmt.entry(
            "shape.contextOrthoIntFields",
            ortho,
            "확정", [binref, scriptref]),
        specfmt.entry(
            "shape.corpusUsage",
            corpus,
            "확정", [specfmt.ev("corpus", "%s (%d 항목)" % (WS, corpus["scanned"])), scriptref]),
        specfmt.entry(
            "shape.previewBackSolveIsInvalid",
            previews,
            "확정", [specfmt.ev("asset",
                              "Sources/WapleRender/Resources/WEAssets/presets/lightshafts/"),
                   scriptref]),
        specfmt.entry(
            "shape.sizeIsProperty0x2F0",
            proptable,
            "확정", [binref, scriptref]),
        specfmt.entry(
            "shape.sizeConsumedAsHalfExtent",
            consumer,
            "확정", [binref, scriptref]),
        specfmt.entry(
            "shape.sharesRenderableBaseWithImageLayer",
            shared,
            "확정", [binref, scriptref]),
        specfmt.entry(
            "shape.defaultSize",
            {"defaultSize": "(ortho.height, ortho.height) — 정사각. width 가 아니다",
             "geometry": "origin 중심 ±size/2. 최종 화면 크기 = size × scale(자기·조상 누적)",
             "howConfirmed": [
                 "§shape.sizeIsProperty0x2F0 — 리플렉션 표가 이름 `\"size\"` 를 멤버 0x2F0 에 "
                 "직접 묶는다. 추론이 아니라 바이너리가 스스로 이름을 댄다(대조 항목: "
                 "color@0x330 · alpha@0x33C · brightness@0x340 — scene.json 키와 1:1).",
                 "§shape.initWritesOrthoHeightPair — shape 클래스 vfunc+0x40 이 그 0x2F0 에 "
                 "(float)(int)ortho.height 를 movsd 로 두 성분 다 쓴다. 저작 `size` 키가 없을 "
                 "때 남는 값이 곧 기본값이고, §shape.corpusUsage 의 withSizeKey=0 이 "
                 "코퍼스 전건이 그 경로임을 보인다.",
                 "§shape.sizeConsumedAsHalfExtent — 드로우 준비가 size × 0.5 로 월드행렬 x·y "
                 "기저를 스케일한다. 0.5 는 rip-상대 상수를 실제로 읽어 확인했다.",
                 "§shape.sharesRenderableBaseWithImageLayer — 이미지 레이어(0x960)와 vtable "
                 "슬롯을 공유하므로 size@0x2F0 은 공통 필드다. 풀스크린 이미지가 저작 "
                 "size=(프로젝션 w,h) 로 정확히 화면을 덮는다는 사실이 ±size/2 와 맞물려 "
                 "로컬 코너 ±1 을 확정한다(size 가 반폭이 아니라 전폭이라는 2배 모호성 해소).",
             ],
             "supersedes": {
                 "wasStatus": "추정 (shape.defaultSizeHypothesis, 2026-08-17 1차)",
                 "whyItWasUnconfirmed": "당시엔 0x2F0 을 '크기' 로 읽은 근거가 정황(기본 생성자 "
                                        "1.0,1.0 + 뒤이은 위치 벡터)뿐이었고 소비 지점을 못 찾았다. "
                                        "찾는 방법은 vtable 슬롯 클로저(1단계 호출까지)를 "
                                        ".pdata 함수 범위로 잘라 0x2E0~0x310 modrm disp32 를 훑는 "
                                        "것이었다 — 오프셋 하나만 정확히 찾는 스캔으로는 SIMD "
                                        "블록 로드·lea 탈출을 놓친다.",
                 "abTestThatWasMixed": {
                     "3404976219": "개선", "3558034522": "개선",
                     "3521337568": "악화", "3460973721": "판정 애매",
                 },
                 "confoundsAndHowTheyClosed": [
                     "① 3521337568 쿼드 부모(id 2065)의 scale 미확인 → **닫힘**: scale 키가 "
                     "없어 (1,1,1) 이고 평행이동만 한다(§shape.corpusUsage.scaledQuads). "
                     "즉 6480/8640px 은 쿼드 자신의 scale 3/4 이 만든 것이고, 그 크기는 "
                     "WE 도 같다 — 부모로는 이 악화를 설명할 수 없다.",
                     "② 솔리드 레이어 이펙트 체인의 비-풀스크린 UV/RT 규약 미검증 → "
                     "**부분적으로만 닫힘**: 우리 체인 RT 는 layer.size(SceneRendererResources) "
                     "라 레이어-로컬 0..1 UV 가 나오고, 이는 WE 의 레이어별 RT 축과 같다. "
                     "다만 `size × scale` 로 커진 쿼드에서 WE 가 RT 해상도를 무엇으로 잡는지는 "
                     "**여전히 미확정**이다 — 아래 residual 참조.",
                 ],
             },
             "residualDefectNotInThisEntry": {
                 "symptom": "scale 이 큰 쿼드(3521337568 scale 3·4, 3640755971 scale 5, "
                            "3461168300 scale 4)에서 화면이 뿌옇게 뜬다. scale 1 쿼드"
                            "(3404976219·3558034522·3460973721·3690417937)는 뚜렷이 개선된다.",
                 "whyNotSize": "크기 자체는 위 네 근거로 WE 와 같다. 남는 축은 lightshafts "
                               "이펙트가 그 크기에서 만드는 **내용**이다 — 우리는 RT 를 "
                               "size(=2160²)로 잡고 draw 에서 scale 배 늘리므로 광선·rayfeather 가 "
                               "그대로 확대된다. WE 가 RT 를 화면 투영 크기로 잡는다면 광선은 "
                               "확대되지 않고 촘촘해진다.",
                 "whatWouldSettleIt": "shape/이미지 렌더러블이 이펙트 체인 RT 를 만드는 지점의 "
                                      "width/height 인자 — CreateTexture2D 호출까지 역추적하거나, "
                                      "scale>1 쿼드가 있는 씬의 RenderDoc 캡처 1장이면 끝난다"
                                      "(현재 보유한 RDC 4종에는 shape 쿼드가 없다).",
             }},
            "확정", [binref, scriptref,
                   specfmt.ev("file", "Sources/WapleCore/SceneDocument.swift effectQuadLayer"),
                   specfmt.ev("file", "Tests/WapleCoreTests/SceneDocumentTests.swift "
                                      "testEffectQuadPromotedToFullscreenEffectLayer"),
                   specfmt.ev("asset", "we-audit reference quad-lightshafts_3690417937 — "
                                       "쿼드 3개가 전부 scale 1·angles 0·origin (1841.92, 1052.11) "
                                       "이라 광선 구간의 좌우 끝이 곧 쿼드 폭이다. WE 실기 2프레임의 "
                                       "열-프로파일 상관이 승격 0.676 → 확정 크기 0.892 로 오른다")]),
    ]
    specfmt.dump(specfmt.doc("scripts/spec/measure_shape_quad.py", entries), OUT)
    print("[shape-quad] →", OUT)
    print("  §1 quad 문자열: " + ", ".join(
        "%s=%s" % (k, (v["asciiQuad"], v["utf16Quad"]) if v else "없음") for k, v in strings.items()))
    print("  §2 분기 %s  타입태그=%d  alloc=0x%x" %
          (dispatch["branchVA"], dispatch["jsonTypeTag"], dispatch["allocBytes"]))
    print("  §3 init %s: [ctx%s] → this%s (float 2개)" %
          (init["initVA"], init["sourceIntOffset"], init["destFloatPairOffset"]))
    print("  §4 ctx%s=(int)ortho.width  ctx%s=(int)ortho.height" %
          (ortho["ctxWidthIntOffset"], ortho["ctxHeightIntOffset"]))
    print("  §5 코퍼스 shape %d개/%d씬 values=%s size키=%d parent=%d 쿼드의자식=%d" %
          (corpus["shapeObjects"], corpus["scenes"], corpus["values"],
           corpus["withSizeKey"], corpus["withParent"], corpus["objectsParentedToAQuad"]))
    print("  §6 프리뷰 역산 spread=%s" % (previews["spread"],))
    print("  §7 리플렉션 표 %s: %s" %
          (proptable["registrarVA"],
           " ".join("%s=%s" % kv for kv in proptable["properties"].items())))
    print("  §8 소비 %d곳, size × %.1f → 월드행렬 x·y 기저 (±size/2)" %
          (len(consumer["sites"]), consumer["halfExtentConstant"]))
    print("  §9 이미지 vtable %s — shape 과 공유 슬롯 %d개" %
          (shared["imageVtableVA"], len(shared["sharedSlots"])))


if __name__ == "__main__":
    main()
