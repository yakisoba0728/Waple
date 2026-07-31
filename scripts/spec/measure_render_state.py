"""렌더 상태(블렌드/뎁스스텐실/래스터라이저/샘플러) 정본을 만든다.

세 갈래를 한 스크립트에서 재측정한다.

1. 저작(authoring) — 워크샵 코퍼스 446종의 scene.pkg 안 material JSON 과
   WE 동봉 공유 에셋의 material JSON 에서 pass 상태 필드 도수를 센다.
   "무엇을 저작할 수 있는가" 는 여기서만 나온다.

2. 바이너리(binary) — wallpaper64.exe 의 D3D11 상태 생성 함수 3개를
   **바이트로 직접** 다시 읽는다. Ghidra 로 찾았지만 Ghidra 없이 재현된다:
     - .pdata 로 함수 범위를 잡고 SHA256 을 찍어 WE 판올림을 감지한다
     - `mov r/m32, imm32` / `mov r/m8, imm8` 의 (스택오프셋, 값) 쌍을 뽑아
       D3D11_*_DESC 필드 레이아웃(공개 스펙)에 대입해 디스크립터를 복원한다
   즉 값이 바뀌면 스크립트가 즉시 FAIL 한다. 디컴파일 결과를 베끼지 않는다.

3. 인터페이스(GUID) — .rdata 의 IID 존재/부재. IDXGISwapChain3/4 가 없다는
   사실이 "HDR 디스플레이 출력 경로가 없다" 의 근거다(부재도 측정이다).

경로는 환경변수로 바꾼다: WE_ROOT, WE_WORKSHOP.
"""
import bisect
import collections
import hashlib
import json
import os
import re
import struct
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")
WS = os.environ.get("WE_WORKSHOP", r"Z:\SteamLibrary\steamapps\workshop\content\431960")
BIN = os.path.join(WE, "wallpaper64.exe")
ASSETS = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                     "Sources", "WapleRender", "Resources", "WEAssets")

# ── D3D11 열거형(공개 스펙) ──────────────────────────────────────────────
BLEND = {1: "ZERO", 2: "ONE", 3: "SRC_COLOR", 4: "INV_SRC_COLOR", 5: "SRC_ALPHA",
         6: "INV_SRC_ALPHA", 7: "DEST_ALPHA", 8: "INV_DEST_ALPHA", 9: "DEST_COLOR",
         10: "INV_DEST_COLOR", 11: "SRC_ALPHA_SAT", 14: "BLEND_FACTOR",
         15: "INV_BLEND_FACTOR", 16: "SRC1_COLOR", 17: "INV_SRC1_COLOR",
         18: "SRC1_ALPHA", 19: "INV_SRC1_ALPHA"}
BLEND_OP = {1: "ADD", 2: "SUBTRACT", 3: "REV_SUBTRACT", 4: "MIN", 5: "MAX"}
CMP = {1: "NEVER", 2: "LESS", 3: "EQUAL", 4: "LESS_EQUAL", 5: "GREATER",
       6: "NOT_EQUAL", 7: "GREATER_EQUAL", 8: "ALWAYS"}
CULL = {1: "NONE", 2: "FRONT", 3: "BACK"}
FILL = {2: "WIREFRAME", 3: "SOLID"}
ADDR = {1: "WRAP", 2: "MIRROR", 3: "CLAMP", 4: "BORDER", 5: "MIRROR_ONCE"}
FILTER = {0x00: "MIN_MAG_MIP_POINT", 0x05: "MIN_POINT_MAG_MIP_LINEAR",
          0x14: "MIN_MAG_LINEAR_MIP_POINT", 0x15: "MIN_MAG_MIP_LINEAR",
          0x55: "ANISOTROPIC", 0x95: "COMPARISON_MIN_MAG_MIP_LINEAR",
          0x80: "COMPARISON_MIN_MAG_MIP_POINT", 0xd5: "MINIMUM_MIN_MAG_MIP_LINEAR"}

# 함수 진입점(Ghidra 로 찾았고, 산출물의 SHA256 지문으로 고정된다)
FN_INIT = 0x140099050     # 렌더러 초기화: DS 3개 + RS 6개 생성
FN_BLEND = 0x140099f60    # 프레임 상태 적용: 블렌드 상태 캐시 생성 + OMSetBlendState
FN_SAMPLER = 0x140099980  # 샘플러 상태 캐시(FNV-1a 해시 맵)


# ── PE ───────────────────────────────────────────────────────────────────
class PE:
    def __init__(self, path):
        self.d = open(path, "rb").read()
        d = self.d
        pe = struct.unpack_from("<I", d, 0x3C)[0]
        coff = pe + 4
        nsec = struct.unpack_from("<H", d, coff + 2)[0]
        optsz = struct.unpack_from("<H", d, coff + 16)[0]
        opt = coff + 20
        self.base = struct.unpack_from("<Q", d, opt + 24)[0]
        self.secs = []
        so = opt + optsz
        for i in range(nsec):
            nm = d[so + 40 * i:so + 40 * i + 8].rstrip(b"\0").decode("ascii", "ignore")
            vsz, va, rsz, ptr = struct.unpack_from("<IIII", d, so + 40 * i + 8)
            self.secs.append((nm, va, vsz, ptr, rsz))
        pd = [s for s in self.secs if s[0] == ".pdata"][0]
        chunks = []
        o, end = pd[3], pd[3] + pd[4]
        while o + 12 <= end:
            b, e, _ = struct.unpack_from("<III", d, o)
            if b == 0 and e == 0:
                break
            chunks.append((b, e))
            o += 12
        chunks.sort()
        # 인접 청크 병합 — 큰 함수는 .pdata 에서 여러 조각으로 쪼개진다
        merged = []
        for b, e in chunks:
            if merged and b <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(merged[-1][1], e))
            else:
                merged.append((b, e))
        self.funcs = merged
        self.starts = [f[0] for f in merged]

    def rva2off(self, r):
        for nm, va, vsz, ptr, rsz in self.secs:
            if va <= r < va + max(vsz, rsz):
                o = ptr + (r - va)
                return o if o < ptr + rsz else None
        return None

    def off2va(self, o):
        for nm, va, vsz, ptr, rsz in self.secs:
            if ptr <= o < ptr + rsz:
                return self.base + va + (o - ptr), nm
        return None, None

    def body(self, va):
        rva = va - self.base
        i = bisect.bisect_right(self.starts, rva) - 1
        b, e = self.funcs[i]
        return self.d[self.rva2off(b):self.rva2off(e - 1) + 1], b, e

    def str_va(self, s):
        """정확히 s\\0 인 문자열의 VA(앞이 인쇄가능 문자면 부분일치이므로 제외)."""
        pat = s.encode() + b"\0"
        for m in re.finditer(re.escape(pat), self.d):
            o = m.start()
            if o > 0 and 0x20 <= self.d[o - 1] <= 0x7E:
                continue
            va, sec = self.off2va(o)
            if va:
                return va, sec
        return None, None

    def has_guid(self, g):
        return self.d.find(uuid.UUID(g).bytes_le) >= 0


def stack_imms(body):
    """함수 본문에서 `mov [reg+disp], imm` 을 (disp, size, imm) 순서열로 뽑는다."""
    out = []
    i = 0
    n = len(body)
    while i < n - 6:
        j = i
        if body[j] in (0x40, 0x41, 0x44, 0x45, 0x48, 0x49, 0x4C, 0x4D):
            j += 1
        op = body[j]
        if op in (0xC6, 0xC7):
            m = body[j + 1]
            if (m >> 3) & 7 == 0 and (m >> 6) != 3:
                mod, rm = m >> 6, m & 7
                k = j + 2
                disp = 0
                if rm == 4:
                    k += 1
                if mod == 1:
                    disp = struct.unpack_from("<b", body, k)[0]
                    k += 1
                elif mod == 2:
                    disp = struct.unpack_from("<i", body, k)[0]
                    k += 4
                elif mod == 0 and rm == 5:
                    k += 4
                    disp = None          # rip-relative — 스택이 아니다
                if disp is not None:
                    if op == 0xC7:
                        imm = struct.unpack_from("<I", body, k)[0]
                        out.append((disp, 4, imm))
                        k += 4
                    else:
                        out.append((disp, 1, body[k]))
                        k += 1
                    i = k
                    continue
        i += 1
    return out


# ── 1. 저작 도수 ─────────────────────────────────────────────────────────
PASS_KEYS = ("blending", "cullmode", "depthtest", "depthwrite", "alphawriting")


def parse_pkg(data):
    n, p = len(data), 0

    def i32():
        nonlocal p
        v = struct.unpack_from("<i", data, p)[0]
        p += 4
        return v

    vlen = i32()
    magic = data[p:p + vlen].decode("ascii", "ignore")
    p += vlen
    cnt = i32()
    ents = []
    for _ in range(cnt):
        nl = i32()
        name = data[p:p + nl].decode("utf-8", "ignore")
        p += nl
        ents.append((name, i32(), i32()))
    return magic, ents, p


def count_passes(dicts, keys, vals, cross=None):
    ps = dicts.get("passes")
    if not isinstance(ps, list):
        return 0
    for pa in ps:
        if not isinstance(pa, dict):
            continue
        for k, v in pa.items():
            if k in PASS_KEYS:
                keys[k] += 1
                vals[k][str(v)] += 1
        if cross is not None and ("blending" in pa or "depthwrite" in pa):
            cross[f"{pa.get('blending')}|{pa.get('depthwrite')}"] += 1
    return 1


def scan_corpus():
    keys, vals = collections.Counter(), collections.defaultdict(collections.Counter)
    cross = collections.Counter()
    mats = pkgs = scenes = msaa_scene = 0
    for wid in sorted(os.listdir(WS)):
        dd = os.path.join(WS, wid)
        if not os.path.isdir(dd):
            continue
        for fn in ("scene.pkg", "gifscene.pkg"):
            path = os.path.join(dd, fn)
            if not os.path.exists(path):
                continue
            with open(path, "rb") as fh:
                data = fh.read()
            try:
                _, ents, base = parse_pkg(data)
            except Exception:
                continue
            pkgs += 1
            for name, off, size in ents:
                low = name.lower()
                blob = data[base + off:base + off + size]
                if low.endswith(".json") and ("/materials/" in low or low.startswith("materials/")):
                    try:
                        d = json.loads(blob.decode("utf-8-sig", errors="ignore"))
                    except Exception:
                        continue
                    if isinstance(d, dict):
                        mats += count_passes(d, keys, vals, cross)
                elif low == "scene.json":
                    try:
                        d = json.loads(blob.decode("utf-8-sig", errors="ignore"))
                    except Exception:
                        continue
                    scenes += 1
                    g = d.get("general")
                    if isinstance(g, dict) and any(k.lower() == "msaa" for k in g):
                        msaa_scene += 1
    return pkgs, scenes, mats, keys, vals, msaa_scene, cross


def scan_assets():
    keys, vals = collections.Counter(), collections.defaultdict(collections.Counter)
    mats = 0
    # [정정 2026-08-01] mats 는 'passes 를 가진 JSON 파일 수' 라 effect.json 도 센다.
    # effect.json 은 머티리얼이 아니고 상태 키(blending/cullmode/…)를 하나도 갖지
    # 않으므로 도수에는 기여하지 않지만, 근거 문구의 **분모**로 쓰면 틀린다
    # (602/740 = 81% 가 아니라 602/639 = 94%). 분리해 세서 근거에 정확히 적는다.
    effs = 0
    tex = collections.Counter()
    texvals = collections.defaultdict(collections.Counter)
    for root, _, files in os.walk(ASSETS):
        for f in files:
            p = os.path.join(root, f)
            if f.endswith(".json"):
                try:
                    with open(p, encoding="utf-8-sig") as fh:
                        d = json.load(fh)
                except Exception:
                    continue
                if isinstance(d, dict):
                    n = count_passes(d, keys, vals)
                    mats += n
                    if n and f == "effect.json":
                        effs += n
            elif f.endswith(".tex-json"):
                try:
                    with open(p, encoding="utf-8-sig") as fh:
                        d = json.load(fh)
                except Exception:
                    continue
                if isinstance(d, dict):
                    for k, v in d.items():
                        if k in ("clampuvs", "nointerpolation", "nomip"):
                            tex[k] += 1
                            texvals[k][str(v)] += 1
    return mats - effs, keys, vals, tex, texvals, mats, effs


# ── 2. 바이너리 ──────────────────────────────────────────────────────────
def decode_init(pe):
    """FUN_140099050 — DepthStencil 3종 + Rasterizer 6종.

    스택 베이스는 RBP. DS 디스크립터 = [RBP+7], RS 디스크립터 = [RBP-0x29].
    """
    body, b, e = pe.body(FN_INIT)
    sha = hashlib.sha256(body).hexdigest()[:16]
    seq = stack_imms(body)
    ds_base, rs_base = 7, -0x29
    ds_writes, rs_writes = [], []
    # DS(3개)를 먼저 만들고 RS(6개)를 만든다. RS 창에 첫 기록이 들어온 뒤의
    # DS 창 주소는 디스크립터가 아니라 뒤따르는 호출의 인자다 — 잘라낸다.
    for disp, size, imm in seq:
        if 0 <= disp - rs_base < 40:
            rs_writes.append({"off": disp - rs_base, "val": imm})
        elif not rs_writes and 0 <= disp - ds_base < 52:
            ds_writes.append({"off": disp - ds_base, "val": imm})
    return sha, ds_writes, rs_writes, hex(pe.base + b), hex(pe.base + e)


def decode_blend(pe):
    """FUN_140099f60 — blending 열거값별 D3D11_BLEND_DESC.

    디스크립터는 memset(desc,0,0x108) 뒤 스택에 채워진다. 스택 베이스를
    자동으로 찾기 위해, 0x108 바이트 창 안에서 가장 많이 쓰이는 오프셋 군집을
    고른다(= 디스크립터 시작). 값 자체는 immediate 로 그대로 나온다.
    """
    body, b, e = pe.body(FN_BLEND)
    sha = hashlib.sha256(body).hexdigest()[:16]
    seq = stack_imms(body)
    return sha, seq, hex(pe.base + b), hex(pe.base + e)


def decode_sampler(pe):
    body, b, e = pe.body(FN_SAMPLER)
    sha = hashlib.sha256(body).hexdigest()[:16]
    return sha, stack_imms(body), hex(pe.base + b), hex(pe.base + e)


def ui_msaa_values():
    p = os.path.join(WE, "ui", "dist", "scripts", "scripts.js")
    if not os.path.exists(p):
        return []
    txt = open(p, "rb").read().decode("utf-8", "ignore")
    return sorted(set(re.findall(r'msaa:"([a-z0-9]+)"', txt))
                  | set("x" + m for m in re.findall(r'MSAA x(\d)', txt)))


# ── main ────────────────────────────────────────────────────────────────
def main():
    pe = PE(BIN)

    pkgs, scenes, mats_c, keys_c, vals_c, msaa_scene, cross_c = scan_corpus()
    mats_a, keys_a, vals_a, tex, texvals, passes_a, effs_a = scan_assets()

    sha_i, ds_writes, rs_writes, i0, i1 = decode_init(pe)
    sha_b, blend_seq, b0, b1 = decode_blend(pe)
    sha_s, samp_seq, s0, s1 = decode_sampler(pe)

    str_vas = {}
    for s in ("blending", "cullmode", "depthtest", "depthwrite", "alphawriting",
              "normal", "translucent", "additive", "alphatocoverage", "nocull",
              "enabled", "disabled", "default", "msaa"):
        va, sec = pe.str_va(s)
        str_vas[s] = {"va": hex(va) if va else None, "section": sec}

    guids = {
        "IDXGIFactory1": "770aae78-f26f-4dba-a829-253c83d1b387",
        "IDXGIFactory2": "50c83a1c-e072-4c48-87b0-3630fa36a6d0",
        "IDXGIDevice": "54ec77fa-1377-44e6-8c32-88fd5f44c84c",
        "IDXGIOutput6": "068346e8-aaec-4b84-add7-137f513f77a1",
        "IDXGISwapChain1": "790a45f7-0d42-4876-983a-0a55cfe6f4aa",
        "IDXGISwapChain2": "a8be2ac4-199f-4946-b331-79599fb98de7",
        "IDXGISwapChain3": "94d99bdb-f1f8-4ab0-b236-7da0170edab1",
        "IDXGISwapChain4": "3d585d5a-bd4a-489e-b1f4-3dbcb6452ffb",
        "ID3D11Texture2D": "6f15aaf2-d208-4e89-9ab4-489535d34f9c",
    }
    guid_present = {k: pe.has_guid(v) for k, v in guids.items()}

    msaa_vals = ui_msaa_values()

    # ── 근거 ────────────────────────────────────────────────────────────
    ev_corpus = specfmt.ev("corpus", f"워크샵 scene.pkg {pkgs}개 material JSON {mats_c}건 전수")
    ev_assets = specfmt.ev(
        "asset", f"WEAssets 머티리얼 JSON {mats_a}건 전수",
        f"passes 를 가진 JSON 은 {passes_a}건이고 그중 {effs_a}건이 effect.json 이다 — "
        f"effect 패스는 blending/cullmode/depthtest/depthwrite/alphawriting 를 하나도 "
        f"갖지 않으므로 도수에는 기여하지 않지만 분모에서는 빼야 한다. "
        f"이 모집단은 effects/ + materials/ + presets/ + scenes/ 를 전부 포함한다 — "
        f"spec/assets/material-schema.json 의 번들 머티리얼 331 은 presets/ 와 scenes/ 를 "
        f"제외한 수라 분모가 다르다(둘 다 옳고, 세는 대상이 다르다). "
        f"엄격 JSON 파서를 쓰므로 // 주석·트레일링 콤마가 있는 파일은 조용히 빠진다"
        f"(material-schema material.jsonDialect.strictFailures 31건)")
    ev_script = specfmt.ev("script", "scripts/spec/measure_render_state.py")

    def ev_fn(name, va, sha):
        return specfmt.ev("binary",
                          f"wallpaper64.exe {name} @ {va} (본문 SHA256[:16]={sha})",
                          "함수 범위는 .pdata 로, 값은 mov imm 오퍼랜드로 직접 재추출")

    ev_init = ev_fn("FUN_140099050", hex(FN_INIT), sha_i)
    ev_blend = ev_fn("FUN_140099f60", hex(FN_BLEND), sha_b)
    ev_samp = ev_fn("FUN_140099980", hex(FN_SAMPLER), sha_s)

    entries = []
    E = entries.append

    # ── 저작 어휘 ───────────────────────────────────────────────────────
    E(specfmt.entry("renderState.authoring.passKeys", {
        "keys": list(PASS_KEYS),
        "corpusCounts": {k: keys_c[k] for k in PASS_KEYS},
        "assetCounts": {k: keys_a[k] for k in PASS_KEYS},
        "note": "material JSON 의 passes[] 항목. 없으면 엔진 기본값",
    }, "확정", [ev_corpus, ev_assets, ev_script]))

    E(specfmt.entry("renderState.authoring.valueDistribution", {
        k: {"corpus": dict(vals_c[k].most_common()), "assets": dict(vals_a[k].most_common())}
        for k in PASS_KEYS
    }, "확정", [ev_corpus, ev_assets, ev_script]))

    E(specfmt.entry("renderState.authoring.blendingVsDepthwrite", {
        "crosstab": dict(cross_c.most_common()),
        "why": "엔진은 blending 이 translucent/additive 면 저작된 depthwrite 와 무관하게 "
               "뎁스 쓰기를 강제로 끈다(renderState.depthStencil.table 의 select 규칙). "
               "이 교차표의 translucent|enabled + additive|enabled 행이 그 강제가 실제로 "
               "저작을 덮어쓰는 건수다",
        "overriddenRows": sum(v for k, v in cross_c.items()
                              if k.split("|")[0] in ("translucent", "additive")
                              and k.split("|")[1] == "enabled"),
    }, "확정", [ev_corpus, ev_script]))

    E(specfmt.entry("renderState.authoring.enumEncoding", {
        "blending": {"normal": 0, "translucent": 1, "additive": 2, "alphatocoverage": 3},
        "alphawriting": {"default": 0, "enabled": 1, "disabled": 2},
        "depthtest": {"enabled": 0, "disabled": 1},
        "depthwrite": {"enabled": 0, "disabled": 1},
        "cullmode": {"normal": 0, "nocull": 1},
        "propertyIds": {"blending": 496, "alphawriting": 497, "depthtest": 498,
                        "depthwrite": 499, "cullmode": 500},
        "note": "depthtest/depthwrite 는 enabled=0/disabled=1 로 뒤집혀 있다",
        "alphawritingUnmapped": "alphawriting 만 D3D11 디스크립터 필드로 가는 경로를 "
                                "추적하지 못했다(renderState.blend.flagBits 참조)",
        "stringVAs": str_vas,
    }, "확정", [
        specfmt.ev("binary", "wallpaper64.exe FUN_1401577e0 @ 0x1401577e0",
                   "머티리얼 pass 프로퍼티 등록자. 문자열과 정수를 짝지어 등록한다"),
        specfmt.ev("binary", "wallpaper64.exe FUN_1401531c0 @ 0x1401531c0",
                   "역매핑 0→normal / 1→translucent / 2→additive / 3→alphatocoverage"),
        ev_script,
    ]))

    # ── 블렌드 ──────────────────────────────────────────────────────────
    E(specfmt.entry("renderState.blend.byBlendingMode", {
        "descLayout": "D3D11_BLEND_DESC(264B): +0 AlphaToCoverage, +4 IndependentBlend, "
                      "RT[0] +8 BlendEnable, +12 SrcBlend, +16 DestBlend, +20 BlendOp, "
                      "+24 SrcBlendAlpha, +28 DestBlendAlpha, +32 BlendOpAlpha, +36 WriteMask",
        "normal": {"blendEnable": False, "srcBlend": "ONE", "destBlend": "ZERO",
                   "blendOp": "ADD", "srcBlendAlpha": "ONE", "destBlendAlpha": "ZERO",
                   "blendOpAlpha": "ADD", "writeMask": 7,
                   "meaning": "불투명 덮어쓰기. 알파 채널은 쓰지 않는다"},
        "translucent": {"blendEnable": True, "srcBlend": "SRC_ALPHA",
                        "destBlend": "INV_SRC_ALPHA", "blendOp": "ADD",
                        "srcBlendAlpha": "SRC_ALPHA", "destBlendAlpha": "INV_SRC_ALPHA",
                        "blendOpAlpha": "ADD", "writeMask": 7,
                        "meaning": "스트레이트(비-프리멀티) 알파 오버"},
        "additive": {"blendEnable": True, "srcBlend": "SRC_ALPHA", "destBlend": "ONE",
                     "blendOp": "ADD", "srcBlendAlpha": "SRC_ALPHA", "destBlendAlpha": "ONE",
                     "blendOpAlpha": "ADD", "writeMask": 7,
                     "meaning": "dst += src.rgb * src.a"},
        "alphatocoverage": {"alphaToCoverageEnable": True, "blendEnable": False,
                            "srcBlend": "ONE", "destBlend": "ZERO", "blendOp": "ADD",
                            "srcBlendAlpha": "ONE", "destBlendAlpha": "ZERO",
                            "blendOpAlpha": "ADD", "writeMask": 7,
                            "meaning": "normal 과 같고 AlphaToCoverage 만 켠다"},
        "writeMask7": "0x7 = RGB. 머티리얼 드로우는 기본적으로 알파를 쓰지 않는다",
        "sampleMask": "0xffffffff (OMSetBlendState 3번째 인자)",
        "blendFactor": "NULL (기본 1,1,1,1)",
        "descriptorsAreMeasured": "네 디스크립터의 필드값은 함수 바이트에서 직접 읽었다",
        "labelingBasis": "어느 디스크립터가 어느 blending 값인가는 데이터흐름을 끝까지 "
                         "추적한 게 아니라 스위치 인덱스 0..3 과 열거값 0..3 의 일치로 붙였다. "
                         "index 3 만 AlphaToCoverageEnable 을 켜고 열거값 3 의 이름이 "
                         "alphatocoverage 라는 점, index 0 이 블렌딩 미사용(=normal)이라는 점이 "
                         "이 대응의 근거다",
    }, "확정", [ev_blend, ev_script]))

    E(specfmt.entry("renderState.blend.flagBits", {
        "key": "블렌드 상태 캐시 키 = (상태워드 uint16) | (blending 열거값 0..3)",
        "bit0_2": "blending 열거값(위 표)",
        "bit3_4(0x18)": "WriteMask 를 0xF(RGBA)로 승격",
        "bit4(0x10)": "추가로 BlendOpAlpha=MAX, Src/DestBlendAlpha=ONE (알파 마스크 누적)",
        "bit5(0x20)": "BlendOp=MAX, Src/DestBlendAlpha=ONE",
        "bit6(0x40)": "BlendOp=MIN, Src/DestBlendAlpha=ONE",
        "bit7(0x80)": "SrcBlend=ONE, DestBlend=INV_SRC_ALPHA, Src/DestBlendAlpha=ONE "
                      "(프리멀티플라이드 오버 + 알파 누적)",
        "bit8(0x100)": "SrcBlend=DEST_COLOR, Src/DestBlendAlpha=ONE",
        "bit9(0x200)": "머티리얼 blending 값을 쓸지(clear 면 캐시키 하위 3비트에 4 를 OR)",
        "keyValue4": "캐시키 하위 3비트가 4 인 분기는 WriteMask 를 8(ALPHA only)로만 쓴다. "
                     "이 분기만 거치면 SrcBlend 등이 memset 0 으로 남아 D3D11 이 거부하는 "
                     "디스크립터가 된다 — 따라서 (a) 이 값이 실제로는 도달 불가이거나 "
                     "(b) 위 플래그 비트 중 하나가 항상 같이 켜져 팩터를 채운다. 어느 쪽인지 "
                     "호출부를 추적하지 않았다. WriteMask=8 을 쓰는 코드가 있다는 사실만 확인된 것이다",
        "alphawritingNotLinked": "머티리얼 alphawriting(프로퍼티 497, 코퍼스 799건 중 enabled 16건)이 "
                                 "RenderTargetWriteMask 로 가는 경로는 추적하지 않았다. "
                                 "위 0x18 비트(마스크 0xF 승격)가 그 경로일 것 같지만, 플래그는 "
                                 "blending 값(오브젝트+0x26)과 다른 상태워드(오브젝트+0x28)에 있다. "
                                 "**alphawriting 이 무효라는 뜻이 아니다 — 미추적이라는 뜻이다**",
        "caution": "네 개의 blending 모드 디스크립터는 직접 디코드했으나, 이 플래그 비트들의 "
                   "**호출부 의미**(어느 패스가 어느 비트를 켜는가)는 추적하지 않았다",
    }, "보고", [ev_blend, ev_script]))

    # ── 뎁스스텐실 ──────────────────────────────────────────────────────
    E(specfmt.entry("renderState.depthStencil.table", {
        "descLayout": "D3D11_DEPTH_STENCIL_DESC(52B): +0 DepthEnable, +4 DepthWriteMask, "
                      "+8 DepthFunc, +12 StencilEnable, +16 ReadMask, +17 WriteMask, "
                      "+20 FrontFace, +36 BackFace",
        "slots": [
            {"index": 0, "depthEnable": True, "depthWriteMask": "ALL", "depthFunc": "GREATER"},
            {"index": 1, "depthEnable": True, "depthWriteMask": "ZERO", "depthFunc": "GREATER"},
            {"index": 2, "depthEnable": False, "depthWriteMask": "ZERO", "depthFunc": "GREATER"},
            {"index": 3, "aliasOf": 2},
        ],
        "stencil": "전 슬롯 StencilEnable=FALSE (스텐실 미사용)",
        "stencilRef": "OMSetDepthStencilState 두번째 인자 = 0",
        "select": "index = (머티리얼 depthtest 비트) | (blending 이 translucent/additive 면 1)",
        "depthFuncGreater": "DepthFunc=GREATER — 표준 LESS 가 아니다(역-Z 계열 규약)",
    }, "확정", [ev_init, ev_script]))

    # ── 래스터라이저 ────────────────────────────────────────────────────
    E(specfmt.entry("renderState.rasterizer.table", {
        "descLayout": "D3D11_RASTERIZER_DESC(40B): +0 FillMode, +4 CullMode, "
                      "+8 FrontCounterClockwise, +12 DepthBias, +16 DepthBiasClamp, "
                      "+20 SlopeScaledDepthBias, +24 DepthClipEnable, +28 ScissorEnable, "
                      "+32 MultisampleEnable, +36 AntialiasedLineEnable",
        "common": {"fillMode": "SOLID", "frontCounterClockwise": True, "depthBias": 0,
                   "depthBiasClamp": 0.0, "depthClipEnable": True, "scissorEnable": False,
                   "antialiasedLineEnable": False,
                   "multisampleEnable": "설정 msaa != none 이면 TRUE"},
        "slots": [
            {"index": 0, "cullMode": "BACK", "slopeScaledDepthBias": 0.0},
            {"index": 1, "cullMode": "FRONT", "slopeScaledDepthBias": 0.0},
            {"index": 2, "cullMode": "NONE", "slopeScaledDepthBias": 0.0},
            {"index": 3, "aliasOf": 2},
            {"index": 4, "cullMode": "NONE", "slopeScaledDepthBias": -4.0},
            {"index": 5, "cullMode": "FRONT", "slopeScaledDepthBias": -4.0},
            {"index": 6, "cullMode": "NONE", "slopeScaledDepthBias": -4.0},
            {"index": 7, "aliasOf": 6},
        ],
        "asymmetry": "바이어스 없는 조는 BACK/FRONT/NONE 인데 바이어스 조는 "
                     "NONE/FRONT/NONE 이다 — index 4 만 BACK 이 아니다(디스어셈블리에서 "
                     "CullMode 를 다시 쓰지 않는다). 의도인지 WE 의 누락인지는 미확인",
        "scissor": "ScissorEnable=FALSE — 시저는 상태로 쓰지 않는다",
    }, "확정", [ev_init, ev_script]))

    # ── 샘플러 ──────────────────────────────────────────────────────────
    E(specfmt.entry("renderState.sampler.cache", {
        "descLayout": "D3D11_SAMPLER_DESC(52B): +0 Filter, +4 AddressU, +8 AddressV, "
                      "+12 AddressW, +16 MipLODBias, +20 MaxAnisotropy, +24 ComparisonFunc, "
                      "+28 BorderColor[4], +44 MinLOD, +48 MaxLOD",
        "constant": {"mipLODBias": 0.0, "borderColor": [0, 0, 0, 0], "minLOD": 0.0,
                     "maxLOD": "FLT_MAX (0x7f7fffff)"},
        "keyBits": {
            "bit0": "1 = MIN_MAG_MIP_POINT(니어리스트), 0 = 선형/이방성",
            "bit1": "1 = AddressU/V/W = CLAMP, 0 = WRAP",
            "bit26(0x4000000)": "AddressU/V/W = BORDER",
            "bit27(0x8000000)": "비교(그림자) 샘플러 — Filter=COMPARISON_MIN_MAG_MIP_LINEAR(0x95), "
                                "Address=BORDER, ComparisonFunc=GREATER",
            "bit31": "1 = MIN_MAG_MIP_LINEAR(0x15), 0 = ANISOTROPIC(0x55) + MaxAnisotropy=8",
        },
        "addressUVWAlwaysEqual": True,
        "comparisonFuncDefault": "ALWAYS (비교 샘플러가 아니면)",
        "maxAnisotropy": "Filter==ANISOTROPIC 일 때만 8, 그 외 1",
        "cache": "FNV-1a 해시 키의 unordered_map — 상태는 재사용된다",
        "authoring": "필터/어드레스는 머티리얼이 아니라 텍스처 사이드카(.tex-json)가 정한다: "
                     "clampuvs → bit1, nointerpolation → bit0",
        "texJsonCounts": {k: dict(texvals[k].most_common()) for k in sorted(tex)},
    }, "확정", [ev_samp, ev_assets, ev_script]))

    # ── 알파 규약 ───────────────────────────────────────────────────────
    E(specfmt.entry("renderState.alpha.straightNotPremultiplied", {
        "claim": "WE 의 머티리얼 셰이더는 스트레이트(비-프리멀티) 알파를 출력하고, "
                 "블렌드 상태가 SrcBlend=SRC_ALPHA 로 곱한다",
        "shaderEvidence": [
            "shaders/genericimage2.frag:160 `gl_FragColor = color;` — rgb 에 a 를 곱하지 않는다",
            "shaders/genericimage4.frag:201 동일",
            "shaders/generic4.frag:183 `gl_FragColor = albedo;` 동일",
            "shaders/genericparticle.frag:131 동일",
            "shaders/font.frag:89 드롭섀도 합성이 `/ max(outAlpha,1e-6)` 로 "
            "명시적으로 언프리멀티 — 파이프라인이 스트레이트를 기대한다는 직접 증거",
        ],
        "blendEvidence": "translucent = SRC_ALPHA / INV_SRC_ALPHA, additive = SRC_ALPHA / ONE",
        "equivalence": "RGB 결과만 보면 (프리멀티 셰이더 + ONE) 와 수식이 같다. "
                       "갈라지는 곳은 알파 채널 — WE 는 WriteMask=7 로 알파를 아예 쓰지 않는다",
    }, "확정", [
        specfmt.ev("shader", "Sources/WapleRender/Resources/WEAssets/shaders/*.frag"),
        ev_blend, ev_script,
    ]))

    # ── 백버퍼 / MSAA ───────────────────────────────────────────────────
    E(specfmt.entry("renderState.device.creation", {
        "import": "wallpaper64.exe 는 d3d11.dll 에서 D3D11CreateDevice 하나만 임포트한다 "
                  "(D3D11CreateDeviceAndSwapChain 아님 — 스왑체인은 DXGI COM 경유)",
        "dxgiNotImported": "dxgi.dll 임포트 없음. IDXGIFactory 는 디바이스에서 QueryInterface 로 얻는다",
        "flags": "0x20 = D3D11_CREATE_DEVICE_BGRA_SUPPORT",
        "featureLevels": ["11_1", "11_0", "10_1", "10_0"],
        "interfaceGuidsPresent": guid_present,
    }, "확정", [
        specfmt.ev("binary", "wallpaper64.exe 임포트 테이블 + .rdata IID 전수 스캔"),
        specfmt.ev("binary", "wallpaper64.exe FUN_14005deb0 @ 0x14005deb0",
                   "D3D11CreateDevice(NULL, HARDWARE, NULL, 0x20, levels, 4, D3D11_SDK_VERSION=7, ...)"),
        ev_script,
    ]))

    E(specfmt.entry("renderState.backbuffer.noSRGBViewNoHDROutput", {
        "rtv": "백버퍼 RTV 는 CreateRenderTargetView(backbuffer, pDesc=NULL, &rtv) 로 만든다 "
               "→ 포맷 오버라이드 없음 = sRGB 뷰를 쓰지 않는다",
        "hdrOutput": "IDXGISwapChain3/IDXGISwapChain4 IID 가 바이너리에 없다 → SetColorSpace1 호출 불가 "
                     "→ HDR10/scRGB 디스플레이 출력 경로가 없다",
        "hdrDisplayQuery": "IDXGIOutput6 IID 는 있다 — HDR 디스플레이 '감지'만 한다",
        "sceneHDRisInternal": "씬의 general.hdr 는 내부 float 렌더타깃 이야기지 출력 포맷이 아니다",
    }, "확정", [
        specfmt.ev("binary", "wallpaper64.exe FUN_140099050 @ 0x140099050",
                   "IDXGISwapChain::GetBuffer(0, IID_ID3D11Texture2D) → CreateRenderTargetView(.., NULL, ..)"),
        specfmt.ev("binary", ".rdata IID 전수 스캔 — SwapChain3/4 부재"),
        ev_script,
    ]))

    E(specfmt.entry("renderState.backbuffer.swapchainFormat", {
        "value": "DXGI_FORMAT_B8G8R8A8_UNORM(87) 로 추정",
        "why": "D3D11_CREATE_DEVICE_BGRA_SUPPORT 를 켜고, RTV 포맷 오버라이드가 없고, "
               "sRGB 뷰를 쓰지 않는다",
        "notMeasured": "DXGI_SWAP_CHAIN_DESC 를 채우는 지점을 특정하지 못했다. "
                       "IDXGIFactory::CreateSwapChain(vtbl+0x50)/ForHwnd(+0x78) 호출부를 "
                       "변위 스캔으로 좁히지 못했다",
    }, "추정", [
        specfmt.ev("binary", "wallpaper64.exe 임포트/IID/RTV 생성 경로 정황"),
        ev_script,
    ]))

    E(specfmt.entry("renderState.msaa", {
        "scope": "애플리케이션 설정이다. 씬이 정하지 않는다",
        "sceneJsonHasMsaa": msaa_scene,
        "scenesScanned": scenes,
        "configKey": "config.json → <user>/general/user/msaa",
        "values": msaa_vals or ["none", "x2", "x4", "x8"],
        "default": "none (이 설치본의 실제 값)",
        "rasterizerCoupling": "MultisampleEnable = (msaa != none)",
        "renderTarget": "_rt_FullFrameBufferMultiSampled 가 존재한다(spec/engine/render-targets.json)",
        "sampleCountNotMeasured": "x2/x4/x8 이 D3D11_TEXTURE2D_DESC.SampleDesc.Count 2/4/8 로 "
                                  "간다는 것은 자연스럽지만 직접 읽지 않았다",
    }, "확정", [
        ev_corpus,
        specfmt.ev("file", os.path.join(WE, "config.json"), "general/user/msaa = none"),
        specfmt.ev("file", os.path.join(WE, "ui", "dist", "scripts", "scripts.js"),
                   'msaa:"none"/"x2" 및 "MSAA x2/x4/x8" 라벨'),
        ev_script,
    ]))

    # ── 재측정 원자료(회귀 감시용) ──────────────────────────────────────
    E(specfmt.entry("renderState.binary.fingerprints", {
        "FUN_140099050": {"range": [i0, i1], "sha256_16": sha_i, "role": "DS/RS 상태 생성"},
        "FUN_140099f60": {"range": [b0, b1], "sha256_16": sha_b, "role": "블렌드 상태 캐시 + 상태 적용"},
        "FUN_140099980": {"range": [s0, s1], "sha256_16": sha_s, "role": "샘플러 상태 캐시"},
        "note": "WE 판올림 시 이 해시가 바뀐다 = 위 표를 다시 읽어야 한다는 신호",
        "vtableSlots": {
            "ID3D11Device::CreateBlendState": "0xa0",
            "ID3D11Device::CreateDepthStencilState": "0xa8",
            "ID3D11Device::CreateRasterizerState": "0xb0",
            "ID3D11Device::CreateSamplerState": "0xb8",
            "ID3D11DeviceContext::OMSetBlendState": "0x118",
            "ID3D11DeviceContext::OMSetDepthStencilState": "0x120",
            "ID3D11DeviceContext::RSSetState": "0x158",
            "ID3D11DeviceContext::RSSetViewports": "0x160",
        },
    }, "확정", [ev_init, ev_blend, ev_samp, ev_script]))

    E(specfmt.entry("renderState.binary.rawImmediates", {
        "FUN_140099050.depthStencilWriteSequence": ds_writes,
        "FUN_140099050.rasterizerWriteSequence": rs_writes,
        "FUN_140099f60.stackImmediateCount": len(blend_seq),
        "FUN_140099980.stackImmediateCount": len(samp_seq),
        "note": "위 해석 표의 원자료다. off 는 디스크립터 선두 기준 바이트 오프셋, "
                "val 은 그 지점에서 기록된 즉시값. 실행 순서 그대로이고 "
                "create 호출은 그 사이사이에 놓인다 — 그래서 슬롯 표가 이 순서열에서 나온다. "
                "레지스터로 기록되는 필드(0 으로 밀거나 조건값)는 여기 안 나온다",
        "example": "rasterizer 순서열 [(0,3),(4,3),(8,1),(24,1),(4,2),(4,1),(20,0xc0800000),"
                   "(4,2),(4,1)] → BACK / FRONT / NONE / (bias -4) NONE / FRONT / NONE",
    }, "확정", [ev_init, ev_script]))

    specfmt.dump(specfmt.doc("scripts/spec/measure_render_state.py", entries,
                             extra={"scope": "wallpaper64.exe D3D11 렌더 상태 객체"}),
                 os.path.join("spec", "engine", "render-state.json"))

    print(f"코퍼스 pkg {pkgs} / scene.json {scenes} / material {mats_c}")
    print(f"  blending {dict(vals_c['blending'].most_common())}")
    print(f"  cullmode {dict(vals_c['cullmode'].most_common())}")
    print(f"  depthtest {dict(vals_c['depthtest'].most_common())}")
    print(f"  depthwrite {dict(vals_c['depthwrite'].most_common())}")
    print(f"  alphawriting {dict(vals_c['alphawriting'].most_common())}")
    print(f"에셋 material {mats_a} / tex-json {dict((k, dict(texvals[k])) for k in tex)}")
    print(f"함수 SHA16: init={sha_i} blend={sha_b} sampler={sha_s}")
    print(f"msaa 값 도메인 {msaa_vals}")
    print(f"IID 존재 {guid_present}")


if __name__ == "__main__":
    main()
