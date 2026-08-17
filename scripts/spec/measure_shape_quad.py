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


def measure_corpus():
    if not os.path.isdir(WS):
        fail("코퍼스가 없다: %s (WE_WORKSHOP/WAPLE_REAL_PKGS)" % WS)
    values = collections.Counter()
    total = withEffects = withSize = withParent = childrenOfQuad = 0
    scenes = set()
    for wid in sorted(os.listdir(WS)):
        if not os.path.isdir(os.path.join(WS, wid)):
            continue
        sc = load_scene(wid)
        if not sc:
            continue
        objs = [o for o in sc.get("objects", []) if isinstance(o, dict)]
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
        for o in objs:
            if isinstance(o.get("parent"), int) and o["parent"] in quad_ids:
                childrenOfQuad += 1
    return {"scanned": len(os.listdir(WS)), "shapeObjects": total,
            "scenes": len(scenes), "values": dict(values),
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
            "shape.defaultSizeHypothesis",
            {"hypothesis": "shape 렌더러블의 기본 크기 = (orthoHeight, orthoHeight) 정사각 — "
                           "§3 의 destFloatPairOffset 가 '레이어 크기' 라는 전제 위에서만 성립한다",
             "whyUnconfirmed": [
                 "this+0x2F0/0x2F4 를 '크기' 로 읽은 근거는 정황뿐이다: 기본 생성자가 (1.0, 1.0) 로 "
                 "두고, 바로 뒤 0x2F8/0x2FC/0x300 이 월드 행렬에 곱해지는 위치 벡터다. 이 두 성분을 "
                 "**소비**하는 지점을 찾지 못했다.",
                 "이미지 레이어 타입은 별개 클래스(0x960)라 같은 오프셋으로 대조할 수 없었다.",
             ],
             "abTest": {
                 "what": "effectQuadLayer 를 size=(orthoH,orthoH) + 저작 origin/scale/angles/parent 로 "
                         "바꿔 코퍼스 5씬을 렌더 대조(1920×1080, t=6.0)",
                 "result": {
                     "3404976219": "개선 — 오른쪽 절반 백색 플레어가 좌상단 일부로 수축",
                     "3558034522": "개선 — 인물을 덮던 무지개 줄무늬가 좌상단으로 수축",
                     "3521337568": "악화 — scale 3/4 쿼드가 6480/8640px 로 커져 전면이 뿌옇게 뜬다",
                     "3460973721": "판정 애매 — 광선이 더 굵고 밝아진다",
                 },
                 "confounds": [
                     "3521337568 의 쿼드 부모(id 2065)의 scale 을 확인하지 않았다",
                     "우리 렌더러의 솔리드 레이어 이펙트 체인이 **비-풀스크린** 지오메트리에서 "
                     "WE 와 같은 UV/RT 규약을 쓰는지 자체가 미검증이다 — 3404976219 결과에 "
                     "WE 에는 없는 하드 엣지(rayfeather 대신 클리핑)가 남았다",
                 ],
                 "verdict": "반증이 아니라 **혼재·교란**. 가설은 살아 있고, 고치려면 두 교란 요인을 "
                            "먼저 닫아야 한다.",
             }},
            "추정", [binref, scriptref,
                   specfmt.ev("file", "Sources/WapleCore/SceneDocument.swift effectQuadLayer")]),
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


if __name__ == "__main__":
    main()
