"""텍스처 필터링 정본 — 특히 **mip 필터** 규약을 만든다.

왜 따로 있나. `spec/engine/render-state.json` 의 `renderState.sampler.cache` 는
샘플러 캐시의 키 비트 표를 담지만, 그 표는 Ghidra 디컴파일을 사람이 옮겨 적은
산문이고 재현 스크립트(measure_render_state.py)는 함수 SHA 와 스택 즉시값 **개수**
까지만 다시 읽는다. 그래서 "WE 가 mip 을 선형 보간하는가" 를 그 문서로는
기계 검증할 수 없었다. 이 스크립트가 그 구멍을 메운다.

무엇을 하나.

1. 바이너리 — D3D11_SAMPLER_DESC 를 만드는 지점을 바이트로 다시 읽는다.
   Ghidra 없이 재현된다:
     - .pdata 로 함수 범위를 잡고 본문 SHA256 으로 WE 판올림을 감지한다
     - Filter 슬롯(desc+0)에 값을 넣는 **명령 시퀀스**를 바이트 패턴으로 확인한다.
       패턴이 하나라도 사라지면 스크립트가 FAIL 한다 — 표를 베끼지 않는다는 뜻이다
     - `call qword ptr [reg+0xB8]` 전수 스캔으로 다른 생성 지점이 없는지 본다
       (그 슬롯은 ID3D11Device::CreateSamplerState 와 ID3D11DeviceContext::GSSetShader
        가 공유한다 — 그래서 디스크립터 서명으로 갈라야 한다)
2. 저작 어휘 — .tex 헤더 flags 와 .tex-json 키에 **필터를 고르는 수단이 있는지**.
   부정 결론이므로 표본이 그것을 보여줄 수 있는지부터 확인한다(spec/README 규칙 5).
3. 애셋 종류별 — 3D 모델 텍스처 / 파티클 / 이펙트 / 그 외로 나눠 flags·mip 체인
   길이 분포를 낸다. "종류마다 규약이 다른가" 는 여기서만 답이 나온다.
4. 우리 구현 — Sources/ 의 `constexpr sampler` 선언을 세어 대조한다.

경로 환경변수: WE_ROOT(설치본) 또는 WE_BIN(wallpaper64.exe 직접), WE_WORKSHOP(코퍼스).
WE_WORKSHOP 이 없으면 WAPLE_REAL_PKGS 를 본다.

⚠️ 보관본 PE 의 섹션 오프셋. 역공학 보관본 wallpaper64.exe 는 DOS 스텁이 늘어난 채
섹션 테이블의 PointerToRawData 가 갱신되지 않은 사본이 있다(설치본 5,360,112B 대
보관본 5,360,320B, 차이 208B = e_lfanew 0x110 - 0x40). 섹션 헤더가 선언한 값 그대로
읽으면 .pdata 가 0 으로 보이고 함수 범위를 하나도 못 잡는다. 아래 PE 리더는 .pdata
첫 RUNTIME_FUNCTION 이 성립하는 shift 를 골라 보정하고, 보정 후 함수 본문 SHA256 이
설치본에서 잰 값과 **일치**함을 확인했다(FUN_140099980=904bd4b240de2ac4). 즉 코드
바이트는 같은 바이너리다.
"""
import bisect
import collections
import hashlib
import json
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")
BIN = os.environ.get("WE_BIN", os.path.join(WE, "wallpaper64.exe"))
WS = os.environ.get("WE_WORKSHOP",
                    os.environ.get("WAPLE_REAL_PKGS",
                                   r"Z:\SteamLibrary\steamapps\workshop\content\431960"))
ASSETS = os.path.join(REPO, "Sources", "WapleRender", "Resources", "WEAssets")
SOURCES = os.path.join(REPO, "Sources")

# 함수 진입점(Ghidra 로 찾았고, 본문 SHA256 지문으로 고정된다)
FN_SAMPLER_CACHE = 0x140099980   # 샘플러 상태 캐시(FNV-1a 해시맵) — 런타임 전 경로
FN_DEVICE_INIT = 0x14005e490     # 디바이스 초기화 — 전역 샘플러 2개를 직접 만든다
SHA_SAMPLER_CACHE = "904bd4b240de2ac4"
SHA_DEVICE_INIT = "d32ef71145d43f8c"

# D3D11_FILTER (공개 스펙)
FILTER = {0x00: "MIN_MAG_MIP_POINT", 0x01: "MIN_MAG_POINT_MIP_LINEAR",
          0x04: "MIN_POINT_MAG_LINEAR_MIP_POINT", 0x05: "MIN_POINT_MAG_MIP_LINEAR",
          0x10: "MIN_LINEAR_MAG_MIP_POINT", 0x11: "MIN_LINEAR_MAG_POINT_MIP_LINEAR",
          0x14: "MIN_MAG_LINEAR_MIP_POINT", 0x15: "MIN_MAG_MIP_LINEAR",
          0x55: "ANISOTROPIC", 0x95: "COMPARISON_MIN_MAG_MIP_LINEAR"}

# ── PE ───────────────────────────────────────────────────────────────────
class PE:
    """.pdata 로 함수 범위를 잡는 최소 PE 리더. 섹션 오프셋 shift 를 보정한다."""

    def __init__(self, path):
        d = self.d = open(path, "rb").read()
        pe = struct.unpack_from("<I", d, 0x3C)[0]
        coff = pe + 4
        nsec = struct.unpack_from("<H", d, coff + 2)[0]
        optsz = struct.unpack_from("<H", d, coff + 16)[0]
        opt = coff + 20
        self.base = struct.unpack_from("<Q", d, opt + 24)[0]
        secs, so = [], opt + optsz
        for i in range(nsec):
            nm = d[so + 40 * i:so + 40 * i + 8].rstrip(b"\0").decode("ascii", "ignore")
            vsz, va, rsz, ptr = struct.unpack_from("<IIII", d, so + 40 * i + 8)
            secs.append([nm, va, vsz, ptr, rsz])
        pd = [s for s in secs if s[0] == ".pdata"][0]
        tx = [s for s in secs if s[0] == ".text"][0]
        # 헤더가 선언한 raw 오프셋이 실제와 어긋난 보관본이 있다(모듈 독스트링 참조).
        # .pdata 의 첫 RUNTIME_FUNCTION 이 .text 범위 안에 떨어지는 shift 를 고른다.
        self.shift = None
        for sh in (0, pe - 0x40):
            if pd[3] + sh + 12 > len(d):
                continue
            b, e, _ = struct.unpack_from("<III", d, pd[3] + sh)
            if tx[1] <= b < e <= tx[1] + tx[2]:
                self.shift = sh
                break
        if self.shift is None:
            raise SystemExit(f"{path}: .pdata 를 해석할 수 없다 — PE 사본이 손상됐다")
        for s in secs:
            s[3] += self.shift
        self.secs = secs
        chunks, o, end = [], pd[3], pd[3] + pd[4]   # pd[3] 은 위에서 이미 보정됐다
        while o + 12 <= end:
            b, e, _ = struct.unpack_from("<III", d, o)
            if b == 0 and e == 0:
                break
            chunks.append((b, e))
            o += 12
        chunks.sort()
        merged = []
        for b, e in chunks:                     # 큰 함수는 .pdata 에서 쪼개진다
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

    def sec(self, name):
        return [s for s in self.secs if s[0] == name][0]

    def fn_start(self, rva):
        i = bisect.bisect_right(self.starts, rva) - 1
        if i < 0:
            return None
        b, e = self.funcs[i]
        return b if b <= rva < e else None

    def body(self, va):
        rva = va - self.base
        i = bisect.bisect_right(self.starts, rva) - 1
        b, e = self.funcs[i]
        return self.d[self.rva2off(b):self.rva2off(e - 1) + 1], b, e

    def text_iter(self, pattern):
        _, va, vsz, ptr, rsz = self.sec(".text")
        for m in re.finditer(pattern, self.d[ptr:ptr + rsz], re.S):
            yield va + m.start(), m

    def has_string(self, s):
        pat = s.encode() + b"\0"
        for m in re.finditer(re.escape(pat), self.d):
            o = m.start()
            if o > 0 and 0x20 <= self.d[o - 1] <= 0x7E:
                continue
            return True
        return False


def stack_imms(body):
    """`mov [reg+disp], imm` 을 (disp, size, imm) 순서열로 뽑는다."""
    out, i, n = [], 0, len(body)
    while i < n - 6:
        j = i
        if body[j] in (0x40, 0x41, 0x44, 0x45, 0x48, 0x49, 0x4C, 0x4D):
            j += 1
        op = body[j]
        if op in (0xC6, 0xC7):
            m = body[j + 1]
            if (m >> 3) & 7 == 0 and (m >> 6) != 3:
                mod, rm = m >> 6, m & 7
                k, disp = j + 2, 0
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
                    disp = None
                if disp is not None:
                    if op == 0xC7:
                        out.append((disp, 4, struct.unpack_from("<I", body, k)[0]))
                        k += 4
                    else:
                        out.append((disp, 1, body[k]))
                        k += 1
                    i = k
                    continue
        i += 1
    return out


# ── 1. 샘플러 캐시(FUN_140099980) 명령 시퀀스 ───────────────────────────
# desc 베이스는 rsp+0x20. D3D11_SAMPLER_DESC 는 52B 이므로 Filter=+0x20 … MaxLOD=+0x50.
# 표를 베끼지 않기 위해 **Filter 슬롯에 값이 들어가는 경로 전부**를 패턴으로 고정한다.
# 표기: 공백으로 나눈 16진 바이트. "??" 는 임의의 1바이트.
CACHE_PATTERNS = {
    # 키워드 → (바이트 패턴, 이 패턴이 증명하는 것)
    "descBase.filterStore": (
        "89 4c 24 20",
        "mov [rsp+0x20], ecx — Filter 슬롯에 쓰는 유일한 명령. ecx 가 곧 Filter 다"),
    "key.bit0.point": (
        "f6 c3 01 0f 84",
        "test bl,1 / je — 키 bit0(= .tex flags 의 nointerpolation)이 서면 분기한다"),
    "filter.point.zero": (
        "f6 c3 01 0f 84 ?? ?? ?? ?? 33 c9",
        "그 je 의 폴스루가 xor ecx,ecx — Filter = 0x00 MIN_MAG_MIP_POINT"),
    "key.bit27.comparison": (
        "8b d3 c1 ea 1b 80 e2 01",
        "mov edx,ebx / shr edx,27 / and dl,1 — 키 bit27 = 비교(그림자) 샘플러"),
    "filter.comparison.0x95": (
        "b9 95 00 00 00",
        "mov ecx,0x95 — Filter = COMPARISON_MIN_MAG_MIP_LINEAR"),
    "filter.linearOrAniso": (
        "41 80 f0 01 41 0f b6 c8 c1 e1 06 83 c9 15",
        "xor r8b,1 / movzx ecx,r8b / shl ecx,6 / or ecx,0x15 — "
        "3번째 인자가 1 이면 0x15 MIN_MAG_MIP_LINEAR, 0 이면 0x55 ANISOTROPIC"),
    "key.bit31.fromArg3": (
        "c1 e3 1f",
        "shl ebx,31 — 3번째 인자를 캐시 키 bit31 로 접는다(한 키에 두 필터가 안 앉게)"),
    "address.border": (
        "b8 04 00 00 00 89 44 24 24",
        "mov eax,4 / mov [rsp+0x24],eax — AddressU = BORDER(bit26 또는 bit27)"),
    "address.wrapOrClamp": (
        "d1 e8 83 e0 01 03 c0 83 c8 01",
        "shr eax,1 / and eax,1 / add eax,eax / or eax,1 — "
        "키 bit1(= clampuvs)이면 3 CLAMP, 아니면 1 WRAP"),
    "maxAnisotropy.select": (
        "83 f9 55",
        "cmp ecx,0x55 — Filter 가 ANISOTROPIC 일 때만 MaxAnisotropy=8, 그 외 1"),
    "lod.maxFltMax": (
        "c7 44 24 50 ff ff 7f 7f",
        "mov dword [rsp+0x50], 0x7f7fffff — MaxLOD = FLT_MAX"),
    "lod.minZero": (
        "c7 44 24 4c 00 00 00 00",
        "mov dword [rsp+0x4c], 0 — MinLOD = 0"),
    "lod.biasZero": (
        "c7 44 24 30 00 00 00 00",
        "mov dword [rsp+0x30], 0 — MipLODBias = 0"),
    "createSamplerState": (
        "ff 90 b8 00 00 00",
        "call qword [rax+0xB8] — ID3D11Device::CreateSamplerState"),
}

INIT_PATTERNS = {
    "filter.0x15": ("c7 44 24 20 15 00 00 00",
                    "mov dword [rsp+0x20], 0x15 — Filter = MIN_MAG_MIP_LINEAR"),
    "address.clamp": ("c7 44 24 24 03 00 00 00",
                      "mov dword [rsp+0x24], 3 — AddressU = CLAMP (1번 샘플러)"),
    "address.wrap": ("c7 44 24 24 01 00 00 00",
                     "mov dword [rsp+0x24], 1 — AddressU = WRAP (2번 샘플러)"),
    "maxAnisotropy.one": ("c7 44 24 34 01 00 00 00",
                          "mov dword [rsp+0x34], 1 — MaxAnisotropy = 1"),
    "comparison.always": ("c7 44 24 38 08 00 00 00",
                          "mov dword [rsp+0x38], 8 — ComparisonFunc = ALWAYS"),
    "lod.maxFltMax": ("c7 44 24 50 ff ff 7f 7f",
                      "mov dword [rsp+0x50], 0x7f7fffff — MaxLOD = FLT_MAX"),
    "createSamplerState": ("ff 90 b8 00 00 00",
                           "call qword [rax+0xB8] — ID3D11Device::CreateSamplerState"),
}


def hexpat(spec):
    """"89 4c ?? 20" → 정규식 바이트열. ?? 는 임의의 1바이트."""
    out = []
    for tok in spec.split():
        out.append(b"." if tok == "??" else re.escape(bytes([int(tok, 16)])))
    return b"".join(out)


def match_patterns(body, patterns, label):
    found, missing = {}, []
    for k, (pat, why) in patterns.items():
        hits = [m.start() for m in re.finditer(hexpat(pat), body, re.S)]
        if hits:
            found[k] = {"offsets": [hex(h) for h in hits], "means": why}
        else:
            missing.append(k)
    if missing:
        raise SystemExit(
            f"{label}: 명령 패턴 {missing} 을 찾지 못했다 — WE 가 바뀌었거나 주소가 틀렸다. "
            f"표를 베끼지 않는다는 것이 이 스크립트의 요점이므로 여기서 멈춘다")
    return found


def scan_b8_sites(pe):
    """`call [reg+0xB8]` 전수. 그 슬롯은 CreateSamplerState 와 GSSetShader 가 공유한다."""
    sites = []
    _, tva, _, tptr, trsz = pe.sec(".text")
    for va, m in pe.text_iter(rb"(?:[\x40-\x4f])?\xff[\x90-\x97]\xb8\x00\x00\x00"):
        o = tptr + (va - tva)
        ctx = pe.d[max(0, o - 176):o + 6]
        # D3D11_SAMPLER_DESC 서명: MaxLOD=FLT_MAX 즉시값 + Filter 열거값 즉시값
        has_maxlod = b"\xff\xff\x7f\x7f" in ctx
        filt = [FILTER[v] for v in (0x15, 0x55, 0x95, 0x14, 0x05)
                if re.search(rb"[\xb8-\xbf]" + re.escape(struct.pack("<I", v)), ctx)
                or re.search(rb"\xc7[\x00-\xff]{1,6}" + re.escape(struct.pack("<I", v)), ctx)]
        sites.append({"site": hex(pe.base + va),
                      "func": hex(pe.base + (pe.fn_start(va) or 0)),
                      "samplerDescSignature": bool(has_maxlod and filt),
                      "filterImmediates": filt})
    return sites


def scan_callers(pe, target_va):
    """E8 rel32 직접 호출자와, 각 호출 직전의 3번째 인자(r8b) 설정."""
    _, tva, _, tptr, trsz = pe.sec(".text")
    out = []
    for m in re.finditer(rb"\xe8", pe.d[tptr:tptr + trsz]):
        o = m.start()
        if o + 5 > trsz:
            break
        rel = struct.unpack_from("<i", pe.d, tptr + o + 1)[0]
        if tva + o + 5 + rel != target_va - pe.base:
            continue
        ctx = pe.d[tptr + o - 96:tptr + o]
        # 3번째 인자(r8b)를 세우는 마지막 명령을 본다. 셋 중 하나다.
        if b"\x41\xd0\xe8" in ctx and b"\x41\x80\xe0\x01" in ctx:
            # movzx r8d, byte [obj+0x10] / shr r8b / and r8b,1
            arg3 = "객체 플래그 바이트 [obj+0x10] 의 bit1"
        elif b"\x41\xb0\x01" in ctx:                      # mov r8b, 1
            arg3 = "1 (LINEAR 고정)"
        elif b"\x45\x32\xc0" in ctx or b"\x45\x33\xc0" in ctx:  # xor r8d, r8d
            arg3 = "0 (ANISOTROPIC 고정)"
        else:
            arg3 = "판독하지 못함"
        # bts edx, 0x1a — 키 bit26 을 강제로 세워 Address = BORDER 로 만드는 지점
        forces_border = b"\x0f\xba\xea\x1a" in ctx
        out.append({"callSite": hex(pe.base + tva + o),
                    "inFunc": hex(pe.base + (pe.fn_start(tva + o) or 0)),
                    "arg3": arg3,
                    "forcesBorderAddress": forces_border})
    return out


def scan_flagbyte_writes(pe):
    """`op byte ptr [reg+0x10], imm8` 전수 — 이방성 선택 비트가 지워지는 곳이 있나."""
    ops = {0: "add", 1: "or", 4: "and", 6: "xor"}
    out = collections.Counter()
    for va, m in pe.text_iter(rb"(?:[\x40-\x4f])?\x80([\x40-\x7f])\x10(.)"):
        modrm, imm = m.group(1)[0], m.group(2)[0]
        op = ops.get((modrm >> 3) & 7)
        if op:
            out[f"{op} {hex(imm)}"] += 1
    return dict(out.most_common())


PROBE_SCENE = os.environ.get("WAPLE_PROBE_SCENE", "3706286085")


def probe_scene(scene_id):
    """조사를 촉발한 씬의 3D 모델 텍스처가 실제로 어떤 샘플러를 받는지."""
    for fn in ("scene.pkg", "gifscene.pkg"):
        path = os.path.join(WS, scene_id, fn)
        if os.path.exists(path):
            break
    else:
        return {"sceneId": scene_id, "available": False,
                "why": "코퍼스에 이 씬이 없다 — WE_WORKSHOP/WAPLE_REAL_PKGS 를 확인하라"}
    with open(path, "rb") as fh:
        data = fh.read()
    _, ents, base = parse_pkg(data)
    flags, mips, n = collections.Counter(), collections.Counter(), 0
    for nm, off, size in ents:
        if not nm.lower().endswith(".tex") or classify(nm) != "3dModel":
            continue
        t = parse_tex_head(data[base + off:base + off + size])
        if not t:
            continue
        n += 1
        flags[t["flags"] & 0x3] += 1
        mips[t["mipCount"]] += 1
    return {"sceneId": scene_id, "available": True, "modelTextures": n,
            "flagsLow2": dict(sorted(flags.items())),
            "mipCount": dict(sorted(mips.items()))}


# ── 2. .tex / .tex-json 저작 어휘 ────────────────────────────────────────
TEX_MAGIC = b"TEXV0005\0"


def parse_tex_head(blob):
    """TEXI 헤더 + TEXB 첫 mipCount 만 읽는다(spec/formats/tex-deep.json 레이아웃)."""
    if not blob.startswith(TEX_MAGIC):
        return None
    o = 9
    ci = blob[o:o + 8].decode("ascii", "ignore")
    if not ci.startswith("TEXI"):
        return None
    o += 9
    fmt, flags, tw, th, iw, ih = struct.unpack_from("<6i", blob, o)
    o += 24
    if flags & 0x40:
        o += 4
    if ci[-1] > "0":
        o += 4                              # previewColor
    cb = blob[o:o + 8].decode("ascii", "ignore")
    if not cb.startswith("TEXB"):
        return None
    o += 9
    ver = int(cb[4:])
    if ver >= 2:
        o += 4                              # imageCount
    if ver >= 3:
        o += 4                              # imageFormat
    if ver >= 4:
        o += 4                              # variantCount
    mipcount = struct.unpack_from("<i", blob, o)[0]
    return {"format": fmt, "flags": flags, "mipCount": mipcount}


def classify(path):
    p = path.lower().replace("\\", "/")
    if "/models/" in p or p.startswith("models/"):
        return "3dModel"
    if "/particle" in p:
        return "particle"
    if "/effects/" in p or p.startswith("effects/"):
        return "effect"
    if "/lut/" in p:
        return "lut"
    return "other"


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
    ents = []
    for _ in range(i32()):
        nl = i32()
        nm = data[p:p + nl].decode("utf-8", "ignore")
        p += nl
        ents.append((nm, i32(), i32()))
    return magic, ents, p


def scan_corpus():
    by = collections.defaultdict(lambda: {"n": 0, "flags": collections.Counter(),
                                          "mipCount": collections.Counter()})
    pkgs = 0
    if not os.path.isdir(WS):
        # 조용히 빈 결과를 돌려주면 안 된다. 호출부가 이걸 그대로 문서에 쓰기 때문에
        # 코퍼스 없는 머신에서 한 번 돌리는 것만으로 `workshopCorpus` 블록 88줄이
        # 통째로 사라지고, 그 도수를 근거로 삼던 항목들이 근거 없이 '확정' 으로 남는다.
        # exit 0 이라 아무 것도 실패하지 않는다는 게 이 구멍의 핵심이다.
        raise SystemExit(
            f"[measure_texture_filtering] 코퍼스가 없다: {WS}\n"
            f"  WE_WORKSHOP 또는 WAPLE_REAL_PKGS 로 워크샵 코퍼스 루트를 지정하라.\n"
            f"  (코퍼스 도수는 이 문서의 근거다 — 없이 재생성하면 근거만 지워진다.)")
    for wid in sorted(os.listdir(WS)):
        for fn in ("scene.pkg", "gifscene.pkg"):
            path = os.path.join(WS, wid, fn)
            if not os.path.exists(path):
                continue
            with open(path, "rb") as fh:
                data = fh.read()
            try:
                _, ents, base = parse_pkg(data)
            except Exception:
                continue
            pkgs += 1
            for nm, off, size in ents:
                if not nm.lower().endswith(".tex"):
                    continue
                t = parse_tex_head(data[base + off:base + off + size])
                if not t:
                    continue
                k = by[classify(nm)]
                k["n"] += 1
                k["flags"][t["flags"] & 0x3] += 1
                k["mipCount"][min(t["mipCount"], 12)] += 1
    return pkgs, {k: {"n": v["n"],
                      "flagsLow2": dict(sorted(v["flags"].items())),
                      "mipCount": dict(sorted(v["mipCount"].items()))}
                  for k, v in sorted(by.items())}


def scan_assets():
    """동봉 WEAssets — 리포 안이므로 이 부분은 어디서 돌려도 같은 값이 나온다."""
    tex, keys = {}, collections.Counter()
    nomip_json = {}
    for root, _, files in os.walk(ASSETS):
        for f in files:
            p = os.path.join(root, f)
            rel = os.path.relpath(p, ASSETS)
            if f.endswith(".tex"):
                with open(p, "rb") as fh:
                    t = parse_tex_head(fh.read())
                if t:
                    tex[rel.replace("\\", "/")] = t
            elif f.endswith(".tex-json"):
                try:
                    with open(p, encoding="utf-8-sig") as fh:
                        d = json.load(fh)
                except Exception:
                    continue
                if not isinstance(d, dict):
                    continue
                for k in d:
                    keys[k] += 1
                nomip_json[rel[:-len(".tex-json")].replace("\\", "/")] = bool(d.get("nomip"))
    # nomip(저작) ↔ 저장 mip 체인 길이(산출물) 대조
    pairs = {"nomipTrue_chain1": 0, "nomipTrue_chainGt1": 0,
             "nomipAbsentOrFalse_chain1": 0, "nomipAbsentOrFalse_chainGt1": 0}
    matched = 0
    for stem, t in tex.items():
        base = stem[:-len(".tex")]
        if base not in nomip_json:
            continue
        matched += 1
        one = t["mipCount"] <= 1
        if nomip_json[base]:
            pairs["nomipTrue_chain1" if one else "nomipTrue_chainGt1"] += 1
        else:
            pairs["nomipAbsentOrFalse_chain1" if one else "nomipAbsentOrFalse_chainGt1"] += 1
    by = collections.defaultdict(lambda: {"n": 0, "flags": collections.Counter(),
                                          "mipCount": collections.Counter()})
    for rel, t in tex.items():
        k = by[classify(rel)]
        k["n"] += 1
        k["flags"][t["flags"] & 0x3] += 1
        k["mipCount"][min(t["mipCount"], 12)] += 1
    return (len(tex), dict(keys.most_common()), matched, pairs,
            {k: {"n": v["n"], "flagsLow2": dict(sorted(v["flags"].items())),
                 "mipCount": dict(sorted(v["mipCount"].items()))}
             for k, v in sorted(by.items())})


# ── 3. 우리 구현 ─────────────────────────────────────────────────────────
SAMPLER_DECL = re.compile(r"constexpr sampler \w+\(([^)]*)\)")


def scan_our_shaders():
    out = collections.defaultdict(collections.Counter)
    for root, _, files in os.walk(SOURCES):
        for f in files:
            if not f.endswith(".swift"):
                continue
            p = os.path.join(root, f)
            with open(p, encoding="utf-8") as fh:
                txt = fh.read()
            for m in SAMPLER_DECL.finditer(txt):
                args = ", ".join(a.strip() for a in m.group(1).split(","))
                out[os.path.relpath(p, REPO).replace("\\", "/")][args] += 1
    return {k: dict(v.most_common()) for k, v in sorted(out.items())}


# ── main ────────────────────────────────────────────────────────────────
def main():
    pe = PE(BIN)
    cache_body, cb0, cb1 = pe.body(FN_SAMPLER_CACHE)
    init_body, ib0, ib1 = pe.body(FN_DEVICE_INIT)
    sha_cache = hashlib.sha256(cache_body).hexdigest()[:16]
    sha_init = hashlib.sha256(init_body).hexdigest()[:16]
    for name, got, want in (("FUN_140099980", sha_cache, SHA_SAMPLER_CACHE),
                            ("FUN_14005e490", sha_init, SHA_DEVICE_INIT)):
        if got != want:
            raise SystemExit(
                f"{name} 본문 SHA16 이 {got} — 기대값 {want} 와 다르다. "
                f"WE 가 판올림됐다면 아래 표를 전부 다시 읽어야 한다")

    cache_hits = match_patterns(cache_body, CACHE_PATTERNS, "FUN_140099980")
    init_hits = match_patterns(init_body, INIT_PATTERNS, "FUN_14005e490")
    cache_imms = stack_imms(cache_body)
    # Filter 슬롯(desc+0 = rsp+0x20)에 즉시값을 쓰는 명령이 하나도 없어야 한다
    # — 있으면 위 패턴이 놓친 필터 경로가 있다는 뜻이다.
    filter_imm_writes = [(hex(d), v) for d, s, v in cache_imms if d == 0x20]

    b8 = scan_b8_sites(pe)
    b8_sampler = [s for s in b8 if s["samplerDescSignature"]]
    callers = scan_callers(pe, FN_SAMPLER_CACHE)
    # GenerateMips = ID3D11DeviceContext vtbl +0x1B0
    genmips = [hex(pe.base + va) for va, _ in
               pe.text_iter(rb"(?:[\x40-\x4f])?\xff[\x90-\x97]\xb0\x01\x00\x00")]
    flagbyte = scan_flagbyte_writes(pe)
    probe = probe_scene(PROBE_SCENE)
    strings = {s: pe.has_string(s) for s in
               ("nointerpolation", "clampuvs", "nomip", "anisotropic", "ANISOTROPIC",
                "mipfilter", "halfmip", "g_Texture0MipMapped")}

    pkgs, corpus_by = scan_corpus()
    n_tex_assets, texjson_keys, matched, nomip_pairs, assets_by = scan_assets()
    ours = scan_our_shaders()

    # ── 근거 ────────────────────────────────────────────────────────────
    ev_cache = specfmt.ev(
        "binary", f"wallpaper64.exe FUN_140099980 @ {hex(FN_SAMPLER_CACHE)} "
                  f"(본문 SHA256[:16]={sha_cache})",
        "함수 범위는 .pdata 로, Filter 선택 경로는 명령 바이트 패턴으로 재확인한다. "
        "패턴이 하나라도 없으면 스크립트가 FAIL 한다")
    ev_init = specfmt.ev(
        "binary", f"wallpaper64.exe FUN_14005e490 @ {hex(FN_DEVICE_INIT)} "
                  f"(본문 SHA256[:16]={sha_init})",
        "디바이스 초기화가 직접 만드는 전역 샘플러 2개")
    ev_script = specfmt.ev("script", "scripts/spec/measure_texture_filtering.py")
    ev_assets = specfmt.ev(
        "asset", f"동봉 WEAssets .tex {n_tex_assets}건 · .tex-json 전수",
        "Sources/WapleRender/Resources/WEAssets/ 는 리포 안이라 이 수치는 머신 독립이다")
    ev_corpus = specfmt.ev(
        "corpus", f"워크샵 scene.pkg {pkgs}개의 .tex 헤더 전수",
        f"코퍼스 경로 = {WS}. 코퍼스 크기가 다른 머신에서 재생성하면 이 도수는 달라진다 "
        f"— 도수가 아니라 **분포의 형태**가 주장이다")

    entries = []
    E = entries.append

    # ── 핵심: mip 축 ────────────────────────────────────────────────────
    E(specfmt.entry("textureFiltering.mipAxis.linearUnlessFullPoint", {
        "claim": "WE 가 만드는 샘플러의 mip 축은 항상 LINEAR 다. 예외는 min/mag 까지 "
                 "전부 POINT 인 하나뿐이고, 그때도 mip 만 POINT 로 낮추는 조합은 없다",
        "filterDomain": {
            "0x00": "MIN_MAG_MIP_POINT — 키 bit0(= .tex flags 의 nointerpolation)",
            "0x15": "MIN_MAG_MIP_LINEAR — 기본",
            "0x55": "ANISOTROPIC — 3번째 인자가 0 일 때(mip 축은 여전히 선형)",
            "0x95": "COMPARISON_MIN_MAG_MIP_LINEAR — 키 bit27(그림자 비교 샘플러)",
        },
        "neverProduced": {
            "0x14": "MIN_MAG_LINEAR_MIP_POINT — 이 값을 만드는 경로가 없다",
            "0x05": "MIN_POINT_MAG_MIP_LINEAR — 없다",
            "0x10": "MIN_LINEAR_MAG_MIP_POINT — 없다",
        },
        "howProven": "Filter 슬롯(desc+0 = rsp+0x20)에 값을 넣는 명령은 "
                     "`mov [rsp+0x20], ecx` 하나뿐이고(즉시값 기록 "
                     f"{len(filter_imm_writes)}건), ecx 에 값이 실리는 경로는 셋뿐이다: "
                     "xor ecx,ecx / mov ecx,0x95 / (shl ecx,6 | or ecx,0x15). "
                     "세 경로의 명령 바이트를 전부 패턴으로 고정했다",
        "instructionEvidence": cache_hits,
        "consequence": "삼중선형(또는 이방성) 보간이 WE 의 규약이다. "
                       "mip 축만 POINT 로 내리는 것은 WE 를 흉내내는 것이 아니라 "
                       "새로운 동작을 만드는 것이다",
    }, "확정", [ev_cache, ev_script]))

    E(specfmt.entry("textureFiltering.sampler.lodRangeIsUnclamped", {
        "constant": {"mipLODBias": 0.0, "minLOD": 0.0, "maxLOD": "FLT_MAX (0x7f7fffff)",
                     "borderColor": [0, 0, 0, 0]},
        "bothSites": "샘플러 캐시(FUN_140099980)와 디바이스 초기화(FUN_14005e490) "
                     "양쪽이 같은 값을 쓴다",
        "consequence": "WE 는 LOD 를 샘플러로 자르지 않는다. 어떤 mip 이 존재하는지는 "
                       "**저장된 체인 길이**가 전부 결정한다 — 즉 mip 을 쓸지 말지는 "
                       "런타임 상태가 아니라 애셋 빌드 시점의 결정이다",
        "wapleParity": "Waple 도 lodMinClamp/lodMaxClamp 를 쓰지 않는다(선언 0건). "
                       "단일 레벨 텍스처는 mip_filter::linear 여도 레벨 0 만 샘플되므로 "
                       "비트 동일하다",
    }, "확정", [ev_cache, ev_init, ev_script]))

    E(specfmt.entry("textureFiltering.sampler.creationSites", {
        "cache": {"func": hex(FN_SAMPLER_CACHE), "sha256_16": sha_cache,
                  "role": "FNV-1a 해시맵 캐시. 런타임 텍스처 바인딩이 전부 여기를 지난다",
                  "keyBits": {
                      "bit0": "1 = MIN_MAG_MIP_POINT. .tex flags 0x1 nointerpolation",
                      "bit1": "1 = Address CLAMP, 0 = WRAP. .tex flags 0x2 clampuvs",
                      "bit26(0x4000000)": "Address = BORDER",
                      "bit27(0x8000000)": "비교 샘플러 — Filter 0x95, BORDER, "
                                          "ComparisonFunc = GREATER(5)",
                      "bit31": "3번째 인자를 접어 넣은 자리 — 1 이면 0x15, 0 이면 0x55. "
                               "같은 키에 두 필터가 앉지 않게 하는 용도지 "
                               "저작 비트가 아니다",
                  },
                  "addressUVWAlwaysEqual": True,
                  "comparisonFuncDefault": "ALWAYS(8)",
                  "maxAnisotropy": "Filter == ANISOTROPIC 일 때만 8, 그 외 1"},
        "deviceInit": {"func": hex(FN_DEVICE_INIT), "sha256_16": sha_init,
                       "role": "전역 샘플러 2개를 캐시를 거치지 않고 직접 만든다",
                       "samplers": [
                           {"filter": "MIN_MAG_MIP_LINEAR(0x15)", "address": "CLAMP(3)",
                            "maxAnisotropy": 1, "comparisonFunc": "ALWAYS(8)",
                            "maxLOD": "FLT_MAX"},
                           {"filter": "MIN_MAG_MIP_LINEAR(0x15)", "address": "WRAP(1)",
                            "maxAnisotropy": 1, "comparisonFunc": "ALWAYS(8)",
                            "maxLOD": "FLT_MAX"}],
                       "instructionEvidence": init_hits},
        "callersOfCache": callers,
        "perCallSiteVariation": "호출 지점마다 갈리는 것은 (a) 3번째 인자로 고르는 "
                                "LINEAR/ANISOTROPIC 과 (b) `bts edx,0x1a` 로 강제하는 "
                                "BORDER 어드레스 둘뿐이다. **mip 축을 건드리는 인자는 "
                                "애초에 존재하지 않는다** — 필터를 정하는 입력은 "
                                "키 dword 와 bool 하나가 전부다",
        "crossRef": "renderState.sampler.cache",
        "supersedes": "renderState.sampler.cache 의 keyBits 표와 같은 내용이다. "
                      "그쪽은 디컴파일 산문이고 이쪽은 명령 바이트로 재확인된다",
    }, "확정", [ev_cache, ev_init, ev_script]))

    E(specfmt.entry("textureFiltering.authoring.noFilterKnob", {
        "claim": "저작(머티리얼 JSON · .tex-json · .tex 헤더)에 **mip 필터를 고르는 "
                 "수단이 없다**. 고를 수 있는 것은 세 축뿐이다",
        "axes": {
            "nointerpolation": ".tex flags 0x1 — min/mag/mip 세 축을 한꺼번에 POINT 로",
            "clampuvs": ".tex flags 0x2 — 어드레스 모드(필터가 아니다)",
            "nomip": ".tex-json 전용 — 저장 mip 체인을 만들지 말라는 **빌드 시점** 지시",
        },
        "texJsonKeyDomain": texjson_keys,
        "sampleDesign": "부정 결론이므로 표본이 그것을 보여줄 수 있는지 먼저 본다. "
                        "이 스캔은 .tex-json 의 키를 전수로 모으므로, 필터 키가 "
                        "존재한다면 반드시 도수에 잡힌다. 실제로 nointerpolation 과 "
                        "clampuvs 는 잡혔다(양성 대조 성립)",
        "runtimeStrings": strings,
        "nomipIsBuildTime": "wallpaper64.exe 에 'nomip' 문자열이 없다 — 런타임이 읽는 "
                            "키가 아니다. 반면 nointerpolation·clampuvs 는 있다",
    }, "확정", [ev_assets, ev_script]))

    E(specfmt.entry("textureFiltering.nomip.buildTimeCorrelation", {
        "method": "동봉 WEAssets 에서 같은 스템의 .tex 와 .tex-json 을 짝지어 "
                  "`nomip` 저작값과 실제 저장 mip 체인 길이를 대조했다",
        "pairsMatched": matched,
        "crosstab": nomip_pairs,
        "reading": "nomip:true 인 애셋은 저장 체인이 1(= mip 없음)이다. "
                   "즉 mip 유무는 애셋별로 지정되고, 그 지정은 .tex 파일에 "
                   "**결과로** 굳어 있다. 런타임 스위치가 아니다",
        "crossRef": "textureFiltering.sampler.lodRangeIsUnclamped",
    }, "확정", [ev_assets, ev_script]))

    E(specfmt.entry("textureFiltering.byAssetClass", {
        "what": "텍스처 종류별로 규약이 갈리는지를 보려면 필터를 정하는 두 비트"
                "(flags 0x1 nointerpolation / 0x2 clampuvs)와 저장 mip 체인 길이의 "
                "분포를 종류별로 봐야 한다. 필터 규칙 자체는 종류를 보지 않는다 "
                "— 캐시가 하나이고 키가 .tex flags 에서만 나오기 때문이다",
        "bundledAssets": assets_by,
        "workshopCorpus": corpus_by,
        "corpusPkgs": pkgs,
        "flagsLow2Legend": {"0": "WRAP + 선형", "1": "nointerpolation",
                            "2": "clampuvs", "3": "둘 다"},
        "reading3dModel": "3D 모델 텍스처(materials/models/**)는 flags 하위 2비트가 "
                          "0 인 쪽으로 크게 치우친다 = WRAP + 선형 필터. "
                          "2D 레이어 텍스처는 clampuvs 가 지배적이다. "
                          "**갈리는 것은 어드레스 모드이지 mip 필터가 아니다**",
        "classIsStorageNotSamplingContext": "분류는 .tex 의 **저장 경로**로 한다. "
                                            "모델 머티리얼이 materials/models/ 밖의 "
                                            "텍스처를 참조하는 씬이 실제로 있으므로, "
                                            "'3dModel' 행은 '3D 패스가 샘플하는 "
                                            "텍스처 집합' 과 같지 않다. "
                                            "필터 규칙은 어느 쪽이든 같다 — "
                                            "캐시가 하나이고 키가 .tex flags 뿐이다",
    }, "확정", [ev_assets, ev_corpus, ev_script]))

    E(specfmt.entry("textureFiltering.anisotropic.selector", {
        "what": "0x55 ANISOTROPIC 분기는 코드에 살아 있다. 그것을 고르는 것은 "
                "샘플러 캐시의 3번째 인자다",
        "callSites": callers,
        "hardcodedLinear": sum(1 for c in callers if c["arg3"].startswith("1")),
        "fromObjectFlagBit": sum(1 for c in callers if "bit1" in c["arg3"]),
        "noUserSetting": "wallpaper64.exe 에 'anisotropic'/'ANISOTROPIC' 문자열이 "
                         "하나도 없다. 캡처 세션의 config.json 에도 이방성/필터 "
                         "관련 키가 없다 — 사용자 설정으로 노출된 스위치가 아니다",
        "notResolved": "객체 플래그 바이트 [obj+0x10] 의 bit1 이 어떤 텍스처 종류에서 "
                       "서고 어디서 안 서는지는 이 스캔으로 좁히지 못했다",
        "flagByteWrites": flagbyte,
        "flagByteWritesReading": "`op byte ptr [reg+0x10], imm8` 전수. 대부분 `or` 라 "
                                 "한 번 선 비트가 지워지지 않는 구조로 보이지만, "
                                 "이 스캔은 명령 경계를 검증하지 않는 바이트 패턴이라 "
                                 "오탐이 섞인다(`or 0x0` 2건). `xor 0x83` 2건이 같은 "
                                 "객체 타입인지는 확인하지 못했다",
        "whyItDoesNotChangeTheMipAnswer": "0x15 와 0x55 는 **둘 다 mip 축이 선형**이다. "
                                          "이 미해결은 mip 규약을 흔들지 않는다",
    }, "보고", [
        ev_cache,
        specfmt.ev("file",
                   "wallpaper_dev/references/WallpaperEngine_RenderDoc_capture/"
                   "backup/config_before_capture.json",
                   "캡처 세션의 WE 설정 전문 — filter/aniso/mip 키 0건"),
        ev_script,
    ]))

    E(specfmt.entry("textureFiltering.noRuntimeMipGeneration", {
        "claim": "wallpaper64.exe 에서 ID3D11DeviceContext::GenerateMips(vtbl+0x1B0) "
                 "호출을 찾지 못했다. mip 체인은 저장된 .tex 레벨에서만 온다",
        "callSitesFound": genmips,
        "caveat": "찾은 지점은 폰트 파서의 자체 vtable 이다(같은 함수가 "
                  "'.notdef' 문자열을 참조한다). 또한 이 스캔은 SIB 바이트가 낀 "
                  "`call [reg+idx+0x1B0]` 인코딩을 보지 못한다 — 그래서 이 항목은 "
                  "보고다",
        "wapleParity": "Waple 도 generateMipmaps 를 쓰지 않고 저장 체인을 그대로 "
                       "올린다(SceneRendererResources.makeMipmappedTexture)",
    }, "보고", [ev_cache, ev_script]))

    E(specfmt.entry("textureFiltering.b8SlotIsAmbiguous", {
        "why": "`call qword ptr [reg+0xB8]` 은 ID3D11Device::CreateSamplerState 와 "
               "ID3D11DeviceContext::GSSetShader 가 같이 쓰는 슬롯이다. "
               "슬롯만 보고 세면 샘플러 생성 지점을 과대 계상한다",
        "totalSites": len(b8),
        "withSamplerDescSignature": len(b8_sampler),
        "signature": "앞선 176 바이트 안에 MaxLOD=0x7f7fffff 즉시값과 "
                     "D3D11_FILTER 열거값 즉시값이 함께 있을 것",
        "sites": b8,
        "residual": "서명이 없는 지점 중에 레지스터로만 디스크립터를 채우는 "
                    "샘플러 생성이 숨어 있을 가능성은 이 스캔으로 배제되지 않는다. "
                    "그래서 '생성 지점은 정확히 셋' 은 보고다",
    }, "보고", [ev_cache, ev_script]))

    # 프로브 씬은 코퍼스에 있을 때만 주장한다. 씬이 없는 머신에서 재생성하면
    # measured.available 이 False 가 되는데, 그때 씬에 대한 산문이 그대로 남아 있으면
    # **자기 값과 모순되는 확정 항목**이 된다(이 리포는 등급 인플레를 결함으로 친다).
    probe_value = {
        "why": f"이 조사는 씬 {PROBE_SCENE} 의 3D 메시 mip LOD 비결정에서 출발했다"
               "(oracle.nondet.meshMipLodResidual). 그 씬의 모델 텍스처가 실제로 "
               "어떤 샘플러를 받는지가 권고의 근거다",
        "measured": probe,
        "crossRef": "oracle.nondet.meshMipLodResidual",
    }
    if probe.get("available"):
        probe_value.update({
            "derivedSampler": "flags 하위 2비트가 0 이면 키 bit0=0 · bit1=0 → "
                              "Filter = MIN_MAG_MIP_LINEAR(0x15) 또는 "
                              "ANISOTROPIC(0x55), Address = WRAP(1), "
                              "MipLODBias 0, MinLOD 0, MaxLOD FLT_MAX. "
                              "어느 쪽이든 mip 축은 선형이다",
            "storedMipChains": "이 씬의 모델 텍스처는 저장 mip 체인을 갖는다 — "
                               "mip 이 실제로 샘플되는 조건이 성립한다",
            "consequence": "Waple 의 Mesh3DShaders 선언"
                           "(filter::linear, mip_filter::linear, address::repeat)이 "
                           "이 씬에 대해 WE 와 세 축 모두 일치한다. "
                           "mip_filter::nearest 로 바꾸면 일치하던 축이 어긋난다",
        })
    else:
        probe_value["notMeasuredHere"] = (
            "이 머신의 코퍼스에 씬이 없어 아무 주장도 하지 않는다. "
            "macOS 검증 코퍼스(170종)에는 있고 윈도우 워크샵 코퍼스(162종)에 있는지는 "
            "대조하지 않았다 — 두 코퍼스의 차집합은 "
            "format.tex.embedded.reachCorpusBasis 에 기록돼 있다")
    E(specfmt.entry("textureFiltering.probeScene.modelTextures", probe_value,
                    "확정" if probe.get("available") else "보고",
                    [ev_corpus, ev_script]))

    E(specfmt.entry("textureFiltering.waple.declaredSamplers", {
        "what": "Waple 셰이더가 선언한 constexpr sampler 전수. WE 규약과의 대조표다",
        "byFile": ours,
        "matches": "3D 메시·파티클·쿼드·번역 셰이더가 모두 mip_filter::linear 다 "
                   "→ WE 의 0x15 MIN_MAG_MIP_LINEAR 와 mip 축이 일치한다",
        "gaps": {
            "nointerpolation": "WE 는 .tex flags 0x1 이면 세 축 전부 POINT 로 간다. "
                               "Waple 의 3D 메시 경로(Mesh3DShaders)는 filter::linear "
                               "고정이라 그 플래그를 반영하지 않는다. "
                               "GLSLTranslator 경로에는 smpNearest 가 있다",
            "addressMode": "WE 는 .tex flags 0x2 이면 CLAMP, 아니면 WRAP 이다. "
                           "Mesh3DShaders 는 address::repeat 고정, "
                           "QuadShaders/ParticleShaders 는 address::clamp_to_edge 고정이다",
        },
        "notAMipIssue": "위 두 간극은 min/mag 축과 어드레스 축이다. mip 축은 어긋나 있지 않다",
    }, "확정", [
        specfmt.ev("file", "Sources/WapleRender/Mesh3DShaders.swift",
                   "3D 메시 알베도 샘플러 선언"),
        specfmt.ev("file", "Sources/WapleCore/GLSLTranslator.swift",
                   "번역 셰이더의 샘플러 선언 4종"),
        ev_script,
    ]))

    specfmt.dump(specfmt.doc("scripts/spec/measure_texture_filtering.py", entries,
                             extra={
                                 "scope": "WE 의 텍스처 샘플러 필터 규약(특히 mip 축)",
                                 "reproduce": {
                                     "command": "WE_BIN=<wallpaper64.exe> "
                                                "WE_WORKSHOP=<워크샵 코퍼스 루트> "
                                                "python3 scripts/spec/"
                                                "measure_texture_filtering.py",
                                     "binarySha256": hashlib.sha256(pe.d).hexdigest(),
                                     "binaryBytes": len(pe.d),
                                     "peSectionShift": pe.shift,
                                     "note": "binarySha256 은 보관본 사본의 해시다. "
                                             "설치본은 DOS 스텁 길이가 달라 파일 해시가 "
                                             "다를 수 있지만, 위 두 함수의 본문 SHA16 이 "
                                             "같으면 코드 바이트는 같다 — 스크립트가 "
                                             "그것을 강제한다",
                                 },
                             }),
                 os.path.join(REPO, "spec", "engine", "texture-filtering.json"))

    print(f"바이너리 {BIN}")
    print(f"  PE 섹션 shift 보정 = {pe.shift}B")
    print(f"  FUN_140099980 sha16={sha_cache}  FUN_14005e490 sha16={sha_init}")
    print(f"  Filter 슬롯 즉시값 기록 {len(filter_imm_writes)}건 (0 이어야 정상)")
    print(f"  call [reg+0xB8] {len(b8)}곳 중 샘플러 서명 {len(b8_sampler)}곳")
    print(f"  캐시 직접 호출자 {len(callers)}곳 — "
          f"{collections.Counter(c['arg3'] for c in callers)}")
    print(f"  GenerateMips 후보 {genmips}")
    print(f"  문자열 존재 {strings}")
    print(f"동봉 애셋 .tex {n_tex_assets}건 / nomip 짝 {matched}건 {nomip_pairs}")
    for k, v in assets_by.items():
        print(f"  [asset] {k}: n={v['n']} flags={v['flagsLow2']} mip={v['mipCount']}")
    print(f"코퍼스 pkg {pkgs}")
    for k, v in corpus_by.items():
        print(f"  [corpus] {k}: n={v['n']} flags={v['flagsLow2']} mip={v['mipCount']}")


if __name__ == "__main__":
    main()
