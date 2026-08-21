"""wallpaper64.exe 씬 렌더 루프의 패스 순서를 측정한다.

측정 대상은 셋이고 근거의 종류가 다르다.

(a) 패스별 **입력 RT** — 리포 동봉 공유 에셋 materials/util/*.json 의 "textures"
    배열이 그대로 g_Texture0..N 바인딩이다. 순수 파일 파싱이라 어디서든 재현된다.
(b) 머티리얼/RT 가 저장되는 **객체 필드 오프셋** — PE 를 직접 열어
    (1) "materials/util/*.json" / "_rt_*" 문자열 VA 를 찾고
    (2) .text 의 RIP 상대 참조(lea reg,[rip+disp32])를 역산해 참조 지점을 찾고
    (3) .pdata(예외 디렉터리)로 참조 지점이 속한 함수를 확정한다.
    Ghidra 없이 재현된다.
(c) 패스 **순서** — 프레임 함수 본문에서 각 머티리얼 필드 오프셋이 disp32 로
    등장하는 주소 순서. 같은 직선 블록 안이면 주소 순서 = 실행 순서다.
    (분기 재배치 가능성 때문에 이 스크립트는 "주소 순서"만 사실로 기록하고,
     실행 순서 해석은 디컴파일 대조로 검증한 항목에만 붙인다.)

D3D11 API 식별은 Windows SDK 의 d3d11.h 에서 ID3D11DeviceContextVtbl 멤버
순서를 파싱해 슬롯 번호를 구한다(암기값을 쓰지 않는다). SDK 가 없으면
해당 항목만 건너뛴다.
"""
import bisect
import json
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")
BIN = os.path.join(WE, "wallpaper64.exe")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ASSETS = os.path.join(REPO, "Sources", "WapleRender", "Resources", "WEAssets")
SDK_GLOB = r"C:\Program Files (x86)\Windows Kits\10\Include"

# 씬 프레임 함수(디컴파일로 확인한 진입점). 아래 measure 는 이 값을 가정하지 않고
# 참조 지점에서 역산하지만, 결과 대조용으로 남긴다.
FRAME_FN = 0x14017FA70

# 프레임 객체(파라미터 1)의 필드 바이트 오프셋 → 의미.
# 오프셋 자체는 디컴파일에서 읽었고, 이 스크립트는 "그 오프셋이 정말
# .text 안에서 disp32 로 등장하는가"와 "등장 주소 순서"를 재측정한다.
FIELDS = {
 0x3090: "rt._rt_Reflection",
 0x3098: "rt._rt_FullFrameBuffer",
 0x30A0: "rt._rt_4FrameBuffer",
 0x30A8: "rt._rt_8FrameBuffer",
 0x30B0: "rt._rt_Bloom",
 0x30B8: "rt.hdrBloomPyramid[0]",
 0x30F8: "rt._rt_MipMappedFrameBuffer",
 0x3100: "rt._rt_FullFrameBufferMultiSampled",
 0x3150: "mat.combine",
 0x3158: "mat.combine_srgb|combine_video_hdr",
 0x3160: "mat.downsample_quarter_bloom",
 0x3170: "mat.downsample_eighth_blur_v",
 0x3178: "mat.blur_h_bloom",
 0x3180: "mat.fade",
 0x3188: "mat.ccsimple",
 0x3190: "mat.hdr_downsample_bloom",
 0x3198: "mat.hdr_downsample",
 0x31A0: "mat.hdr_upsample",
 0x31A8: "mat.hdr_upsample_cubic",
}

# 렌더타깃 클래스 vtable(0x140486768) 슬롯 → 디컴파일로 확인한 구현 VA.
# 스크립트는 vtable 바이트를 다시 읽어 이 표와 대조한다.
RT_VTABLE = 0x140486768
RT_VTABLE_EXPECT = {
 0x00: 0x1400D3220, 0x08: 0x1400D3310, 0x10: 0x1400D33B0, 0x18: 0x1400D3410,
 0x20: 0x1400D3430, 0x28: 0x1400D3460, 0x30: 0x1400D3490, 0x38: 0x1400D34A0,
 0x40: 0x1400D3500, 0x48: 0x1400D3920, 0x50: 0x1400D39A0,
}


# ---------------------------------------------------------------- PE 기본

def pe_sections(data):
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    coff = pe + 4
    nsec = struct.unpack_from("<H", data, coff + 2)[0]
    optsz = struct.unpack_from("<H", data, coff + 16)[0]
    opt = coff + 20
    p32p = struct.unpack_from("<H", data, opt)[0] == 0x20B
    base = (struct.unpack_from("<Q", data, opt + 24)[0] if p32p
            else struct.unpack_from("<I", data, opt + 28)[0])
    secs = []
    for i in range(nsec):
        b = opt + optsz + i * 40
        nm = data[b:b + 8].rstrip(b"\0").decode("ascii", "ignore")
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, b + 8)
        secs.append({"name": nm, "raw": rawptr, "rawEnd": rawptr + rawsize,
                     "va": base + vaddr, "vsize": vsize})
    return base, secs


def sec_named(secs, name):
    for s in secs:
        if s["name"] == name:
            return s
    raise KeyError(name)


def file_off(secs, va):
    for s in secs:
        if s["va"] <= va < s["va"] + s["vsize"]:
            return s["raw"] + (va - s["va"])
    return None


def qword(data, secs, va):
    o = file_off(secs, va)
    return struct.unpack_from("<Q", data, o)[0] if o is not None else None


# ------------------------------------------------- .pdata (함수 경계 + 체인)

def runtime_functions(data, secs, base):
    pd = sec_named(secs, ".pdata")
    ents = []
    for i in range((pd["rawEnd"] - pd["raw"]) // 12):
        ba, ea, ui = struct.unpack_from("<III", data, pd["raw"] + i * 12)
        if ba == 0 and ea == 0:
            continue
        ents.append((base + ba, base + ea, base + ui))
    ents.sort()
    return ents


def chain_root(data, secs, ents, starts, va, depth=0):
    """체인 언와인드(UNW_FLAG_CHAININFO)를 따라 진짜 함수 시작을 찾는다."""
    i = bisect.bisect_right(starts, va) - 1
    if i < 0 or not (ents[i][0] <= va < ents[i][1]):
        return None
    s, e, u = ents[i]
    uo = file_off(secs, u)
    if uo is None:
        return s
    flags = data[uo] >> 3
    cnt = data[uo + 2]
    if (flags & 4) and depth < 16:
        codes_end = uo + 4 + ((cnt + 1) // 2) * 4
        cba, _cea, _cui = struct.unpack_from("<III", data, codes_end)
        return chain_root(data, secs, ents, starts, base_of(secs) + cba, depth + 1)
    return s


_BASE = [None]


def base_of(secs):
    return _BASE[0]


# ------------------------------------------------------ 문자열 / RIP 참조

STR_RX = re.compile(rb"(?:materials/[A-Za-z0-9_/]+\.json|(?:_rt_|_alias_)[A-Za-z0-9_]{2,40})")


def scan_strings(data, secs):
    out = {}
    for m in STR_RX.finditer(data):
        s = m.group().decode("ascii")
        if s in out:
            continue
        for sec in secs:
            if sec["raw"] <= m.start() < sec["rawEnd"]:
                out[s] = sec["va"] + (m.start() - sec["raw"])
                break
    return out


def rip_refs(data, secs, targets):
    """.text 전체에서 disp32 를 RIP 기준으로 역산해 targets 를 가리키는 지점을 찾는다."""
    tx = sec_named(secs, ".text")
    raw, rawend, tva = tx["raw"], tx["rawEnd"], tx["va"]
    tset = set(targets)
    hits = {}
    for i in range(raw, rawend - 4):
        disp = struct.unpack_from("<i", data, i)[0]
        if disp == 0:
            continue
        t = tva + (i + 4 - raw) + disp
        if t in tset:
            hits.setdefault(t, []).append(tva + (i - raw))
    return hits


def disp32_sites(data, secs, values, lo=None, hi=None):
    """.text 안에서 disp32 필드 오프셋이 나타나는 주소를 값별로 모은다."""
    tx = sec_named(secs, ".text")
    raw0, rawend, tva = tx["raw"], tx["rawEnd"], tx["va"]
    start = raw0 if lo is None else max(raw0, raw0 + (lo - tva))
    end = rawend if hi is None else min(rawend, raw0 + (hi - tva))
    vset = set(values)
    out = {}
    for i in range(start, end - 4):
        v = struct.unpack_from("<I", data, i)[0]
        if v in vset:
            out.setdefault(v, []).append(tva + (i - raw0))
    return out


# ------------------------------------------------------------ d3d11.h

def d3d11_slots():
    if not os.path.isdir(SDK_GLOB):
        return None, None
    vers = sorted(os.listdir(SDK_GLOB))
    for v in reversed(vers):
        h = os.path.join(SDK_GLOB, v, "um", "d3d11.h")
        if os.path.isfile(h):
            src = open(h, encoding="utf-8", errors="replace").read()
            m = re.search(r"typedef struct ID3D11DeviceContextVtbl\s*\{(.*?)\}\s*"
                          r"ID3D11DeviceContextVtbl;", src, re.S)
            if not m:
                continue
            meth = re.findall(r"STDMETHODCALLTYPE\s*\*\s*(\w+)\s*\)\s*\(", m.group(1))
            return {n: i for i, n in enumerate(meth)}, h
    return None, None


def indirect_sites(data, secs, offsets):
    """FF /2 (call) 와 FF /4 (jmp, 테일콜) 의 disp32 를 훑는다.

    바이트 패턴 스캔이라 오탐이 섞인다 — 호출부 확정은 디컴파일 대조로 한다.
    """
    tx = sec_named(secs, ".text")
    raw, rawend, tva = tx["raw"], tx["rawEnd"], tx["va"]
    want = set(offsets)
    out = {}
    i = raw
    while i < rawend - 6:
        if data[i] == 0xFF:
            m = data[i + 1]
            if (m >> 6) == 2 and ((m >> 3) & 7) in (2, 4):
                extra = 1 if (m & 7) == 4 else 0
                disp = struct.unpack_from("<i", data, i + 2 + extra)[0]
                if disp in want:
                    kind = "call" if ((m >> 3) & 7) == 2 else "jmp"
                    out.setdefault(disp, []).append((tva + (i - raw), kind))
        i += 1
    return out


# ------------------------------------------------------------ 에셋 그래프

def material_inputs():
    root = os.path.join(ASSETS, "materials", "util")
    out = {}
    if not os.path.isdir(root):
        return out
    for fn in sorted(os.listdir(root)):
        if not fn.endswith(".json"):
            continue
        try:
            d = json.load(open(os.path.join(root, fn), encoding="utf-8"))
        except Exception:
            continue
        passes = d.get("passes") or []
        if not passes:
            continue
        p = passes[0]
        out["materials/util/" + fn] = {
            "shader": p.get("shader"),
            "textures": p.get("textures", []),
            "blending": p.get("blending"),
            "combos": p.get("combos"),
        }
    return out


# ------------------------------------------------------------------ main

def main():
    # **[2026-08-20] 자기 입력 가드.** `engine.renderPass.d3d11Slots`(확정)가 Windows SDK 의
    # `d3d11.h` 에 매달려 있어, SDK 없는 환경에서 재생성하면 그 항목이 빈 dict 가 된다.
    # 종전엔 유일한 방어선이 `specfmt.dump` 의 축소 가드였다 — 그 가드에도 구멍이 있었으니
    # 방어선이 하나뿐이면 안 된다. 여기서 먼저 멈춘다.
    if not os.path.isfile(BIN):
        raise SystemExit(f"[measure_render_pass] 바이너리가 없다: {BIN}")
    slots_probe, _ = d3d11_slots()
    if not slots_probe:
        raise SystemExit(
            f"[measure_render_pass] Windows SDK 의 d3d11.h 를 못 찾았다: {SDK_GLOB}\n"
            f"  d3d11Slots 는 그 헤더에서 vtable 순서를 파싱해 얻는 **확정** 항목이라,\n"
            f"  SDK 없이 재생성하면 그 근거가 빈 dict 로 지워진다. SDK 가 있는 곳에서 돌려라.")
    data = open(BIN, "rb").read()
    base, secs = pe_sections(data)
    _BASE[0] = base
    ents = runtime_functions(data, secs, base)
    starts = [e[0] for e in ents]

    strings = scan_strings(data, secs)
    want = {v: k for k, v in strings.items()
            if v is not None and (k.startswith("materials/util/") or k.startswith("_rt_"))}
    refs = rip_refs(data, secs, want.keys())

    # 문자열 → 참조 지점 → (체인 언와인드 해석 후) 소속 함수
    sym_fn = {}
    for va, sites in refs.items():
        name = want[va]
        sym_fn[name] = {
            "stringVA": hex(va),
            "refs": [{"at": hex(a), "fn": (lambda r: hex(r) if r else None)(
                chain_root(data, secs, ents, starts, a))} for a in sites],
        }

    # 프레임 함수 = 후처리 머티리얼 문자열들이 모이는 함수
    post = ["materials/util/combine_ldr.json", "materials/util/blur_h_bloom.json",
            "materials/util/hdr_downsample.json", "materials/util/downsample_quarter_bloom.json"]
    loader_fns = sorted({r["fn"] for n in post if n in sym_fn for r in sym_fn[n]["refs"] if r["fn"]})

    # 프레임 함수 전체 범위 = 체인 루트가 프레임 함수인 .pdata 항목 모두
    frame_ranges = []
    for s, e, _u in ents:
        r = chain_root(data, secs, ents, starts, s)
        if r == FRAME_FN:
            frame_ranges.append((s, e))
    frame_ranges.sort()

    # 필드 오프셋 출현 순서(프레임 함수 범위 안에서만)
    order = []
    for s, e in frame_ranges:
        sites = disp32_sites(data, secs, FIELDS.keys(), lo=s, hi=e)
        for off, addrs in sites.items():
            for a in addrs:
                order.append((a, off))
    order.sort()
    order_list = [{"at": hex(a), "field": hex(o), "slot": FIELDS[o]} for a, o in order]

    # ccsimple(0x3188) vs 블룸 합성(combine 0x3150 / combine_srgb 0x3158) vs fade(0x3180).
    # 로더 블록(함수 앞머리)에도 필드가 나오므로 "최초"가 아니라
    # "합성 머티리얼의 마지막 지점 < ccsimple 최초 지점 < fade 최초 지점" 으로 본다.
    by_field = {}
    for a, o in order:
        by_field.setdefault(o, []).append(a)
    combine_last = max(by_field.get(0x3150, []) + by_field.get(0x3158, []) or [0])
    cc = min(by_field.get(0x3188, []) or [0]) or None
    fade = min(by_field.get(0x3180, []) or [0]) or None

    # RT 클래스 vtable 재확인
    vt = {}
    for k in range(0, 0x58, 8):
        vt[hex(k)] = hex(qword(data, secs, RT_VTABLE + k))
    vt_ok = all(vt[hex(k)] == hex(v) for k, v in RT_VTABLE_EXPECT.items())

    slots, hdr_path = d3d11_slots()
    d3d = {}
    if slots:
        for n in ("Draw", "DrawIndexed", "OMSetRenderTargets", "PSSetShaderResources",
                  "ClearRenderTargetView", "GenerateMips", "ResolveSubresource",
                  "CopyResource", "RSSetViewports"):
            d3d[n] = {"slot": slots[n], "vtableOffset": hex(slots[n] * 8)}
        sites = indirect_sites(data, secs, [slots[n] * 8 for n in
                                            ("GenerateMips", "ResolveSubresource", "CopyResource")])
        for n in ("GenerateMips", "ResolveSubresource", "CopyResource"):
            got = sites.get(slots[n] * 8, [])
            d3d[n]["sites"] = [{"at": hex(a), "insn": k} for a, k in got]

    mats = material_inputs()

    # 에셋에 있는 util 머티리얼 중 wallpaper64.exe 문자열 풀에 이름이 있는 것 / 없는 것.
    # 없는 것 = 런타임이 이름으로 로드하지 않는다(에디터/컴파일러 전용이거나 미사용).
    in_binary, not_in_binary = [], []
    for path in sorted(mats):
        (in_binary if path in strings else not_in_binary).append(path)

    ev_asset = specfmt.ev("asset", "Sources/WapleRender/Resources/WEAssets/materials/util/*.json")
    ev_bin = specfmt.ev("binary", "wallpaper64.exe — 문자열 VA + .text RIP 상대 참조 + .pdata 체인 언와인드")
    ev_script = specfmt.ev("script", "scripts/spec/measure_render_pass.py")
    ev_dec = specfmt.ev("binary", "wallpaper64.exe Ghidra 디컴파일 (FUN_14017fa70 / FUN_140183610 / "
                                  "FUN_140183550 / FUN_140181f30 / RT vtable 0x140486768)")

    entries = [
        specfmt.entry("engine.renderPass.sceneFrameFunction",
                      {"va": hex(FRAME_FN),
                       "chunkCount": len(frame_ranges),
                       "ranges": [[hex(a), hex(b)] for a, b in frame_ranges],
                       "postprocessMaterialLoaderFns": loader_fns},
                      "확정", [ev_bin, ev_script]),

        specfmt.entry("engine.renderPass.materialInputs", mats, "확정", [ev_asset, ev_script]),

        specfmt.entry("engine.renderPass.symbolRefs", sym_fn, "확정", [ev_bin, ev_script]),

        specfmt.entry("engine.renderPass.frameObjectFields",
                      {hex(k): v for k, v in sorted(FIELDS.items())},
                      "확정", [ev_dec, ev_bin]),

        specfmt.entry("engine.renderPass.fieldUseOrder", order_list, "확정", [ev_bin, ev_script]),

        specfmt.entry("engine.renderPass.ccsimpleAfterBloom",
                      {"result": bool(cc and fade and combine_last < cc < fade),
                       "answer": "ccsimple(색보정)은 블룸 **후**다. 그리고 fade 는 ccsimple 후다.",
                       "combineLastUseAt": hex(combine_last) if combine_last else None,
                       "ccsimpleFirstUseAt": hex(cc) if cc else None,
                       "fadeFirstUseAt": hex(fade) if fade else None,
                       "method": "프레임 함수 두 청크 전체에서 필드 오프셋 disp32 출현 주소를 모아 비교. "
                                 "블룸 합성 머티리얼(0x3150 combine / 0x3158 combine_srgb)의 마지막 "
                                 "지점이 ccsimple(0x3188) 최초 지점보다 앞서고, ccsimple 이 fade(0x3180) "
                                 "보다 앞선다. 두 분기(블룸 on/off)가 모두 ccsimple 앞에서 합류한다.",
                       "why": "[VA-스캐너위치] ccsimple 바인드 직전(0x140180bdf)에 _rt_FullFrameBuffer(0x3098) 객체의 "
                              "vtable+8 = '현재 프레임버퍼를 이 RT 로 캡처'가 호출된다. ccsimple.json 의 "
                              "입력이 _rt_FullFrameBuffer 이므로, ccsimple 이 읽는 것은 블룸 합성이 "
                              "끝난 화면이다. 순서가 반대라면 이 캡처가 불필요하다."},
                      "확정", [ev_bin, ev_script, ev_dec]),

        specfmt.entry("engine.renderPass.order",
                      [
                       {"n": 1, "pass": "reflection", "cond": "scene flags bit0 (_rt_Reflection 생성 조건과 동일)",
                        "out": "_rt_Reflection", "note": "FUN_140183550(obj,1). MSAA 경로를 타지 않는다(param2!=0)."},
                       {"n": 2, "pass": "scene", "cond": "항상",
                        "out": "_rt_FullFrameBufferMultiSampled 가 있으면 그것, 없으면 현재 타깃(백버퍼)",
                        "note": "FUN_140183550(obj,0) → FUN_14018aac0. 레이어/이펙트/파티클/3D 가 여기 안에서 그려진다."},
                       {"n": 3, "pass": "msaa-resolve", "cond": "_rt_FullFrameBufferMultiSampled != 0",
                        "in": "_rt_FullFrameBufferMultiSampled", "out": "직전 타깃(_rt_FullFrameBuffer 또는 백버퍼)",
                        "note": "FUN_140183550 끝. RT vtable+0x10 → ID3D11DeviceContext::ResolveSubresource. "
                                "즉 resolve 는 씬 렌더 직후, 어떤 후처리보다 앞이다."},
                       {"n": 4, "pass": "framebuffer-capture", "cond": "블룸 분기(B)에서 항상",
                        "out": "_rt_FullFrameBuffer",
                        "note": "RT vtable+8. MSAA면 resolve, 아니면 CopyResource."},
                       {"n": 5, "pass": "mipmapped-framebuffer", "cond": "_rt_MipMappedFrameBuffer != 0 && (settings>>7 & 1)",
                        "out": "_rt_MipMappedFrameBuffer",
                        "note": "vtable+8(캡처) → vtable+0x20(GenerateMips). 씬 렌더 직후·블룸 앞. "
                                "굴절/반사 셰이더(generic*.frag g_Texture3)가 다음 프레임에 이걸 읽는다."},
                       {"n": 6, "pass": "bloom-chain", "cond": "(settings & 0x40) && (scene flags>>1 & 1) && 씬 리스트 비어있지 않음",
                        "in": "_rt_FullFrameBuffer", "out": "_rt_Bloom(LDR) / 피라미드 레벨0(HDR)",
                        "note": "FUN_140183610. 아래 bloomChain.* 참조."},
                       {"n": 7, "pass": "combine", "cond": "블룸 분기 B",
                        "in": ["_rt_FullFrameBuffer", "_rt_Bloom 또는 피라미드 레벨0"],
                        "out": "현재 타깃(백버퍼)",
                        "note": "머티리얼 = combine_ldr / combine_hdr_upsample / combine_dhdr_upsample. "
                                "HDR 일 때 g_Texture1(오프셋 0xd8)에 피라미드 레벨0 SRV 를 코드에서 직접 꽂는다."},
                       {"n": 7.1, "pass": "combine_srgb", "cond": "블룸 분기 A(블룸 off) && HDR",
                        "in": "_rt_FullFrameBuffer", "out": "현재 타깃",
                        "note": "머티리얼 combine_srgb(셰이더 passthroughsrgb) 또는 bit16 이면 combine_video_hdr. "
                                "LDR + 블룸 off 면 이 패스도 없다(씬이 이미 타깃에 있음)."},
                       {"n": 8, "pass": "ccsimple", "cond": "ccsimple 머티리얼이 로드돼 있으면(색보정 사용 시)",
                        "in": "_rt_FullFrameBuffer(직전에 재캡처)", "out": "현재 타깃",
                        "note": "COL 콤보 = brightness/contrast/saturation/hue(g_Params), LUT 콤보 = 3D LUT. "
                                "**블룸 후**."},
                       {"n": 9, "pass": "fade", "cond": "플레이리스트 전환 알파 > 0 && fade 머티리얼 로드됨",
                        "out": "현재 타깃",
                        "note": "materials/util/fade.json, translucent. 마지막 전면 패스."},
                      ],
                      "확정", [ev_dec, ev_bin, ev_script]),

        specfmt.entry("engine.renderPass.bloomChain.ldr",
                      [{"material": "materials/util/downsample_quarter_bloom.json",
                        "in": "_rt_FullFrameBuffer", "out": "_rt_4FrameBuffer(1/4)"},
                       {"material": "materials/util/downsample_eighth_blur_v.json",
                        "in": "_rt_4FrameBuffer", "out": "_rt_8FrameBuffer(1/8)"},
                       {"material": "materials/util/blur_h_bloom.json",
                        "in": "_rt_8FrameBuffer", "out": "_rt_Bloom(1/8)"},
                       {"material": "materials/util/combine_ldr.json",
                        "in": ["_rt_FullFrameBuffer", "_rt_Bloom"], "out": "현재 타깃"}],
                      "확정", [ev_asset, ev_dec]),

        specfmt.entry("engine.renderPass.bloomChain.hdrPyramid",
                      {"levelCountField": "0x3108 (int)",
                       "levelRTField": "0x30b8 + i*8 (i = 0..N-1)",
                       "down": [
                           {"i": 0, "material": "materials/util/hdr_downsample_bloom.json (BLOOM=1)",
                            "in": "_rt_FullFrameBuffer", "out": "level[0]"},
                           {"i": "1..N-1", "material": "materials/util/hdr_downsample.json",
                            "in": "level[i-1]", "out": "level[i]"}],
                       "up": [
                           {"i": "N-1..1 (역순)",
                            "material": "i >= N-2 이면 hdr_upsample_cubic.json(UPSAMPLE=1,BICUBIC=1), "
                                        "아니면 hdr_upsample.json(UPSAMPLE=1)",
                            "in": "level[i]", "out": "level[i-1]", "blend": "additive"}],
                       # [정정 2026-08-01] 이 필드를 g_TexelSize 라 부른 것은 오기다.
                       # 0xb8..0xc4 는 float 4개이고 값이 (+t,-t) 부호쌍이라 vec2 인
                       # g_TexelSize 일 수 없다. 실소비처는 hdr_downsample.frag 의
                       # g_RenderVar0(.xy/.zy/.xw/.zw 4탭). 정본은
                       # spec/engine/uniform-feed.json engine.uniformFeed.g_RenderVar0.hdrBloomPyramid.
                       "texelScale": "다운샘플 i 는 2^i, 업샘플 i 는 2^i 배로 g_RenderVar0"
                                     "(오브젝트 0xb8..0xc4, float4 = (+t.x,+t.y,-t.x,-t.y)) 를 스케일",
                       "combine": "combine_hdr(g_Texture0=_rt_FullFrameBuffer, g_Texture1=level[0] 을 "
                                  "코드가 머티리얼 0xd8 슬롯에 직접 대입)"},
                      "확정", [ev_dec, ev_asset]),

        specfmt.entry("engine.renderPass.conditions",
                      {"objectFlagsField": "0x128 (uint) — 씬 렌더러 설정 비트",
                       "bit0": "리플렉션(_rt_Reflection 생성/렌더)",
                       "bit6 (0x40)": "블룸 활성(설정). 씬 플래그 bit1 및 씬 리스트 비어있지 않음과 AND",
                       "bit7 (0x80)": "_rt_MipMappedFrameBuffer 캡처+GenerateMips 수행 여부",
                       "bit11 (0x800)": "_rt_MipMappedFrameBuffer 생성 여부(씬 플래그 쪽)",
                       "bit13 (0x2000)": "HDR 파이프라인 — 이 비트로 LDR 3패스 블룸 / HDR 피라미드가 갈린다",
                       "bit14": "bit13 과 함께면 combine_dhdr_upsample(DISPLAYHDR=1)",
                       "bit16": "combine_srgb 대신 combine_video_hdr",
                       "note": "비트 위치는 디스어셈에서 확정. 각 비트의 저작(UI) 이름 대응은 미확인."},
                      "보고", [ev_dec]),

        specfmt.entry("engine.renderPass.notResolved",
                      {"_rt_FullAlphaMask / _rt_FullAlphaMaskIntermediate":
                           "씬 전역 패스가 아니다. 참조가 0x140208670 / 0x140208d4f / 0x140209563 "
                           "(이미지 레이어·클리핑마스크 계열)에 있고, 1/2 해상도(divisor 2, format 0x1b)로 "
                           "레이어 단위 생성된다. 씬 후처리 순서와는 무관 — 별도 조사 필요.",
                       "_rt_volumetrics*":
                           "라이트 단위. 0x140196ce0(생성) / 0x140196f65 / 0x140198124 에서 "
                           "volumetrics_back → blur_h → blur_v → combine(additive) 로 쓰인다. "
                           "씬 렌더(FUN_14018aac0) 내부라 프레임 함수 레벨 순서에는 나타나지 않는다. 미재현.",
                       "포맷 코드": "RT 생성 인자의 0x16/0x18/0x1b/0x1a 는 WE 내부 포맷 enum 이며 "
                                    "DXGI_FORMAT 과의 대응은 확인하지 못했다.",
                       "combine 분기 3번째 조건": "*(scene+0x158) != *(scene+0x160) 벡터가 무엇인지 미확인.",
                       # [해소 2026-08-01] obj+0x3108 조합식은 미확인이 아니다.
                       # spec/engine/uniform-feed.json engine.uniformFeed.hdrBloom.materialParams
                       # 가 VA 0x14017f7f7..0x14017f89b 실측으로 확정했다:
                       # N = clamp(min(bloomhdriterations, availableLevels), 1, ...) → +0x3108.
                       # 이 unknown 은 남겨 두면 해소된 항목을 두 번 조사하게 만든다.
                       "웹/비디오 벽지": "이 문서는 씬(scene) 벽지 경로만 다룬다. "
                                         "webwallpaper64.exe / 비디오 경로는 미조사."},
                      "추정", [ev_dec]),

        specfmt.entry("engine.renderPass.rtClassVtable",
                      {"base": hex(RT_VTABLE), "slots": vt, "matchesDecompiled": vt_ok,
                       "semantics": {
                           "0x0": "소멸자",
                           "0x8": "현재 프레임버퍼를 이 RT 로 캡처 (ResolveSubresource(this←top) 또는 CopyResource)",
                           "0x10": "이 RT 를 현재 프레임버퍼로 resolve (ResolveSubresource(top←this)) — MSAA resolve",
                           "0x18": "CopyResource(this←인자)",
                           "0x20": "ID3D11DeviceContext::GenerateMips(this.srv) — 밉 생성",
                           "0x48": "바인드: OMSetRenderTargets(1, this.rtv, dsv) + 뷰포트 설정",
                           "0x50": "언바인드: 이전 타깃 재바인드"}},
                      "확정", [ev_bin, ev_script, ev_dec]),

        specfmt.entry("engine.renderPass.d3d11Slots", d3d, "확정",
                      [specfmt.ev("file", hdr_path or "Windows SDK d3d11.h 없음"), ev_script]),

        specfmt.entry("engine.renderPass.materialsInBinary",
                      {"inBinary": in_binary, "notInBinary": not_in_binary,
                       "meaning": "바이너리 문자열 풀에 경로 리터럴이 있으면 코드가 그 이름으로 직접 로드한다. "
                                  "ccsimple/fade/combine_*/hdr_*/downsample_*/volumetrics_* 가 여기 든다. "
                                  "debugrt*·gizmo*·wireframe·error·combine_hdr_editor·combine_hdr_upsample_dbg "
                                  "는 없다.",
                       "caveat": "**없다고 에디터 전용은 아니다.** solidlayer/composelayer/passthrough 처럼 "
                                 "런타임 머티리얼인데도 없는 것이 있다(씬 JSON 이나 문자열 조립으로 로드되는 듯). "
                                 "이 항목은 '있다'만 근거로 쓴다.",
                       "ccsimpleIsLive": "ccsimple 이 에디터 전용이 아니라는 결정적 근거는 이 목록이 아니라 "
                                         "라이브 프레임 함수 FUN_14017fa70 안의 사용 지점(0x140180bd5/bec/c02)이다. [VA-스캐너위치]"},
                      "확정", [ev_asset, ev_bin, ev_script]),

        specfmt.entry("engine.renderPass.fullFrameBufferIsSnapshot",
                      {"fact": "_rt_FullFrameBuffer 는 렌더 타깃으로 **바인드되지 않는다**. "
                               "프레임 함수에서 이 필드(0x3098)가 쓰이는 세 곳(0x140180a82 / 0x140180b9f / "
                               "0x140180bdf)은 전부 vtable+0x08 = '현재 프레임버퍼를 이 RT 로 캡처'다. [VA-스캐너위치]",
                       "consequence": "WE 의 후처리는 '스냅샷 → 현재 타깃으로 되그리기'의 반복이다. "
                                      "각 전면 패스 직전에 현재 화면을 _rt_FullFrameBuffer 로 복사하고, "
                                      "머티리얼이 그것을 g_Texture0 으로 읽어 같은 타깃(백버퍼)에 그린다.",
                       "bindSites": "0x30f8(_rt_MipMappedFrameBuffer)도 같다 — 캡처(+8) 후 GenerateMips(+0x20)."},
                      "확정", [ev_bin, ev_script, ev_dec]),

        specfmt.entry("engine.renderPass.hdrPyramidAllocation",
                      {"where": "FUN_14017f1b0, 최대 8회 루프",
                       "levelField": "obj[0x617 + i] (바이트 0x30b8 + i*8)",
                       "divisor": "레벨 i 의 divisor = 2 << i = 2^(i+1) → **레벨 0 은 1/2 해상도**",
                       "names": "동적 생성. \"_rt_\"(0x14048dfe8) + str(divisor) + \"FrameBuffer\"(0x14048dff0) "
                                "→ _rt_2FrameBuffer, _rt_4FrameBuffer, _rt_8FrameBuffer, _rt_16FrameBuffer …",
                       "stop": "min(w,h) 를 매 단계 반으로 나눠 1 미만이 되면 그 레벨부터 해제. "
                               "가용 레벨 수는 obj+0x310c 에 저장",
                       "loopCount": "FUN_140183610 은 obj+0x3108 을 레벨 수로 쓴다. 조합식은 "
                                    "N = clamp(min(bloomhdriterations, availableLevels(0x310c)), 1, ...) "
                                    "— spec/engine/uniform-feed.json "
                                    "engine.uniformFeed.hdrBloom.materialParams 가 VA 0x14017f7f7 "
                                    "실측으로 확정했다(정본은 그쪽)",
                       "format": "0x1b (WE 내부 enum)",
                       "warning": "LDR 경로와 다르다. LDR 은 풀 → 1/4 → 1/8 로 바로 내려가지만, "
                                  "HDR 피라미드는 1/2 부터 시작한다."},
                      "확정", [ev_dec, ev_bin, ev_script]),

        specfmt.entry("engine.renderPass.toBackbuffer",
                      {"livePath": "별도 백버퍼 패스가 없다. RT 스택이 비면 현재 타깃이 스왑체인 백버퍼이고, "
                                   "combine / ccsimple / fade 가 모두 거기에 직접 그린다. 그 뒤 Present.",
                       "editorPath": "FUN_14009b7fd 이 materials/util/backbufferpassthrough.json"
                                     "(0x140485b40, 셰이더 passthroughlinear)을 로드해 그린다. 입력 SRV 는 "
                                     "_rt_editor_backbuffer_resolve(0x140485b70)로 만들어진다. "
                                     "[VA-스캐너위치] 샘플 수 >= 2 면 ResolveSubresource(0x14009b945) 후 CopyResource, "
                                     "아니면 CopyResource 만. 이름이 말하듯 에디터/미리보기 경로다.",
                       "note": "따라서 '씬 → … → 백버퍼'의 마지막 링크는 별도 패스가 아니라 "
                               "'후처리가 처음부터 백버퍼에 그린다'이다."},
                      "확정", [ev_dec, ev_bin, ev_asset]),

        specfmt.entry("engine.renderPass.msaaResolve",
                      {"where": "FUN_140183550(sceneObj, 0) 끝 — 씬 렌더 직후, 모든 후처리 앞",
                       "how": "RT vtable+0x10 (=0x1400d33b0) → ID3D11DeviceContext::ResolveSubresource "
                              "(vtable off 0x1c8, 호출 지점 0x1400d33fd) [VA-스캐너위치] "
                              "dst = RT 스택 상단, 비어 있으면 스왑체인 백버퍼. src = this. "
                              "라이브 씬 프레임에서는 이 시점에 스택이 비어 있으므로 **백버퍼**다 — "
                              "_rt_FullFrameBuffer 로 가지 않는다(그건 별도의 vtable+0x08 캡처).",
                       "sequence": ["_rt_FullFrameBufferMultiSampled 가 있으면 vtable+0x48 로 바인드",
                                    "FUN_14018aac0 로 씬 draw",
                                    "vtable+0x50 로 언바인드(또는 이전 타깃 재바인드)",
                                    "vtable+0x10 로 resolve"],
                       "notForReflection": "FUN_140183550 의 2번째 인자가 0 일 때만. 리플렉션 패스(인자 1)는 "
                                           "MSAA 타깃을 쓰지 않는다.",
                       "creation": "FUN_140181af0 에서 sampleCount(오브젝트 [0x37]) != 0 일 때만 생성. "
                                   "이름 _rt_FullFrameBufferMultiSampled, format 0x18, misc 0x20."},
                      "확정", [ev_dec, ev_bin, ev_script]),

        specfmt.entry("engine.renderPass.mipGeneration",
                      {"target": "_rt_MipMappedFrameBuffer (오브젝트 필드 0x30f8)",
                       "where": "씬 렌더 + MSAA resolve 직후, 블룸 체인/합성 **앞**. 두 분기 모두에서 수행된다.",
                       "how": ["RT vtable+0x08 — 현재 프레임버퍼를 _rt_MipMappedFrameBuffer 로 캡처",
                               "RT vtable+0x20 (=0x1400d3430) — ID3D11DeviceContext::GenerateMips "
                               "(vtable off 0x1b0, 호출 지점 0x1400d344e, tail-jmp 인코딩)"],
                       "cond": "_rt_MipMappedFrameBuffer != 0 && (settings>>7 & 1)",
                       "sitesInFrameFn": {"branchB(블룸 on)": ["0x140180a8f", "0x140180aa6"],
                                          "branchA(블룸 off)": ["0x140180b76", "0x140180b8d"]},
                       "creation": "FUN_140181af0, 씬 플래그 bit11 일 때. mipLevels = 1 또는 "
                                   "(품질 비트 set 시) 0xf, format 0x1b, misc 0x10. "
                                   "생성 직후 한 번 바인드해서 흰색(1,1,1,1)으로 클리어한다.",
                       "consumer": "generic3/generic4/chroma4/foliage4/fur4.frag 의 굴절·반사 경로가 "
                                   "_rt_MipMappedFrameBuffer 를 샘플러로 받는다(에셋 셰이더 소스에서 확인).",
                       "note": "즉 이 텍스처는 '블룸/색보정 전 씬 컬러'다 — 후처리 결과가 아니다."},
                      "확정", [ev_dec, ev_bin, ev_script]),

        specfmt.entry("engine.renderPass.ccsimple",
                      {"material": "materials/util/ccsimple.json",
                       "input": "_rt_FullFrameBuffer (패스 직전에 vtable+8 로 재캡처 — 블룸 합성 결과)",
                       "combos": {"COL": "밝기/대비/채도/색상(g_Params = vec4)",
                                  "LUT": "3D LUT(g_Texture1 = sampler3D)",
                                  "HDR": "LUT 경로에서 1.0 초과분 overbright 보정"},
                       "materialParams": {"params": {"va": "0x14048e33c", "count": 4,
                                                     "shader": "uniform vec4 g_Params"},
                                          "lutparams": {"va": "0x14048e328", "count": 1,
                                                        "shader": "uniform float g_LutParams"},
                                          "lutPathPrefix": {"va": "0x14048e334", "value": "lut/"}},
                       "comboStrings": {"LUT": "0x14048e2e0", "COL": "0x14048e2e4"},
                       "loadedAt": "FUN_140181f30 — 콤보 목록을 만들고 FUN_140150110 으로 로드해 "
                                   "오브젝트 필드 0x3188 에 저장. 색보정도 LUT 도 없으면 0 을 넣는다.",
                       "runtimeGuard": "프레임 함수에서 if (obj[0x3188] != 0) — 즉 항상 도는 패스가 아니다.",
                       "shaderMath": "ccsimple.frag: mix(0.5, albedo, g_Params.y) 로 대비 → rgb2hsv → "
                                     "v*=g_Params.x, s*=g_Params.z, h+=g_Params.w → hsv2rgb. "
                                     "알파는 보존(gl_FragColor = albedo)."},
                      "확정", [ev_bin, ev_asset,
                               specfmt.ev("shader", "WEAssets/shaders/ccsimple.frag"), ev_dec]),

        specfmt.entry("engine.renderPass.d3d11CallSiteNote",
                      {"method": "FF /2 (call) 와 FF /4 (jmp, 테일콜) 의 disp32 바이트 스캔. "
                                 "디스어셈블러가 아니라 바이트 패턴이라 오탐이 있다.",
                       "GenerateMips 0x140328618": "오탐 — 해당 함수는 텍스트 파서다. "
                                                   "진짜 호출은 0x1400d344e 하나뿐이다.",
                       "ResolveSubresource 0x14009b945": "[VA-스캐너위치] 백버퍼/프레젠트 경로(0x14009b7fd, "
                                                          "materials/util/backbufferpassthrough.json 참조 함수). "
                                                          "씬 후처리 순서와 별개.",
                       "warning": "GenerateMips 는 call 이 아니라 **테일 jmp** 로 인코딩돼 있어 "
                                  "call-only 스캔으로는 0건이 나온다. 반드시 /4 도 훑어야 한다."},
                      "확정", [ev_script, ev_bin]),
    ]

    specfmt.dump(specfmt.doc("scripts/spec/measure_render_pass.py", entries,
                             extra={"binary": os.path.basename(BIN)}),
                 os.path.join(REPO, "spec", "engine", "render-pass.json"))

    print(f"프레임 함수 청크 {len(frame_ranges)}개, 필드 사용 지점 {len(order_list)}곳")
    print(f"combine 마지막 {hex(combine_last) if combine_last else None} "
          f"/ ccsimple 최초 {hex(cc) if cc else None} / fade 최초 {hex(fade) if fade else None} "
          f"-> ccsimple 은 블룸 {'후' if combine_last and cc and combine_last < cc else '???'}")
    print(f"RT vtable 대조: {'일치' if vt_ok else '불일치'}")
    for n in ("GenerateMips", "ResolveSubresource"):
        if n in d3d:
            print(f"{n}: 슬롯 {d3d[n]['slot']} off {d3d[n]['vtableOffset']} "
                  f"사이트 {len(d3d[n].get('sites', []))}곳")


if __name__ == "__main__":
    main()
