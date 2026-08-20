"""wallpaper64.exe 에서 g_* 유니폼이 **무슨 값으로 채워지는가**를 뽑는다.

uniforms.json 이 "어떤 이름이 있는가"라면 이 스크립트는 "그 이름에 누가 무슨 값을
넣는가"다. 두 가지 근거를 쓴다:

 1. PE 바이트 직독 — 고정 VA 의 명령 바이트열을 그대로 대조한다. 디스어셈블러 없이
    돌아야 하므로 "이 VA 에 이 바이트가 있다"를 단언하고, 다르면 즉시 실패한다.
    (WE 빌드가 바뀌면 조용히 틀린 값을 내는 대신 시끄럽게 죽는 편이 낫다.)
 2. 동봉 셰이더(WEAssets) 소비부 — 같은 유니폼을 쓰는 GLSL 을 전수 grep 한다.

Ghidra 를 쓰지 않는 이유는 재현성이다. VA 는 Ghidra 로 찾았지만(디컴파일 근거는
spec 항목의 evidence 에 남긴다) 검증은 파일만으로 된다.
"""
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")
BIN = os.path.join(WE, "wallpaper64.exe")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SHADERS = os.path.join(REPO, "Sources", "WapleRender", "Resources", "WEAssets", "shaders")

# ── PE ─────────────────────────────────────────────────────────────────────


def section_map(data):
    pe_off = struct.unpack_from("<I", data, 0x3C)[0]
    coff = pe_off + 4
    nsec = struct.unpack_from("<H", data, coff + 2)[0]
    opt_size = struct.unpack_from("<H", data, coff + 16)[0]
    opt = coff + 20
    base = struct.unpack_from("<Q", data, opt + 24)[0]
    secs = []
    for i in range(nsec):
        b = opt + opt_size + i * 40
        name = data[b:b + 8].rstrip(b"\0").decode("ascii", "ignore")
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, b + 8)
        secs.append((name, rawptr, rawptr + rawsize, base + vaddr, vsize))
    return secs


def va2off(va, secs):
    for _name, s, e, secva, vsize in secs:
        if secva <= va < secva + max(vsize, e - s):
            o = s + (va - secva)
            if o < e:
                return o
    raise KeyError(f"VA {va:#x} 가 어느 섹션에도 없다")


def cstr(data, off, limit=64):
    end = data.index(b"\0", off, off + limit)
    return data[off:end].decode("ascii")


class Probe:
    """고정 VA 의 바이트열을 대조하고 필요한 필드를 뽑는다."""

    def __init__(self, data, secs):
        self.data = data
        self.secs = secs
        self.checked = []

    def at(self, va, expect_hex, what):
        off = va2off(va, self.secs)
        want = bytes.fromhex(expect_hex)
        got = self.data[off:off + len(want)]
        if got != want:
            raise AssertionError(
                f"{what}: VA {va:#x} 바이트 불일치\n  기대 {want.hex()}\n  실제 {got.hex()}")
        self.checked.append((hex(va), what))
        return off

    def f32(self, va):
        return struct.unpack_from("<f", self.data, va2off(va, self.secs))[0]

    def u32(self, va):
        return struct.unpack_from("<I", self.data, va2off(va, self.secs))[0]

    def u64(self, va):
        return struct.unpack_from("<Q", self.data, va2off(va, self.secs))[0]


# ── 1. 상수버퍼 이름 테이블 ────────────────────────────────────────────────

BUF_TABLE_VA = 0x140484B60


def const_buffers(p):
    out = []
    for i in range(4):
        ptr = p.u64(BUF_TABLE_VA + i * 8)
        out.append(cstr(p.data, va2off(ptr, p.secs)))
    return out


# ── 2. 유니폼 ID 레지스트리 (정적 이니셜라이저 FUN_140002860) ──────────────

REG_LO, REG_HI = 0x140002860, 0x1400042F0
ENTRY0, STRIDE, IDOFF = 0x10, 0x28, 0x20


def registry_ids(p):
    """엔트리별 ID 스토어를 전수 수집한다.

    엔트리 i 는 [RBP+0x10+i*0x28], ID 필드는 그 +0x20 = [RBP+0x30+i*0x28].
    세 가지 인코딩이 섞여 나온다:
      C7 45 <disp8>  <imm32>   MOV dword [RBP+d8],imm
      C7 85 <disp32> <imm32>   MOV dword [RBP+d32],imm
      89 5D <disp8> / 89 9D <disp32>   MOV dword [RBP+d],EBX  (EBX=0 → ID 0)
    """
    lo, hi = va2off(REG_LO, p.secs), va2off(REG_HI, p.secs)
    d = p.data
    ids = {}

    def put(off, imm):
        if off < ENTRY0 + IDOFF or (off - ENTRY0 - IDOFF) % STRIDE:
            return
        idx = (off - ENTRY0 - IDOFF) // STRIDE
        if idx < 140 and imm < 140 and idx not in ids:
            ids[idx] = imm

    i = lo
    while i < hi - 10:
        b0, b1 = d[i], d[i + 1]
        if b0 == 0xC7 and b1 == 0x85:
            put(struct.unpack_from("<I", d, i + 2)[0], struct.unpack_from("<I", d, i + 6)[0])
        elif b0 == 0xC7 and b1 == 0x45:
            put(d[i + 2], struct.unpack_from("<I", d, i + 3)[0])
        elif b0 == 0x89 and b1 == 0x9D:
            put(struct.unpack_from("<I", d, i + 2)[0], 0)
        elif b0 == 0x89 and b1 == 0x5D:
            put(d[i + 2], 0)
        i += 1
    return ids


# 함수 꼬리 — 마지막 엔트리(139)와 배열 끝을 못박는다.
#   LEA R8,[RBP-4] / MOV [RBP-4],0x8b / LEA RDX,[g_HDRParams] / LEA RCX,[RBP+0x15c8] / CALL
#   LEA RAX,[RBP+0x10]  (배열 시작)   ...  LEA RAX,[RBP+0x15f0]  (배열 끝)
# (0x15c8-0x10)/0x28 = 139,  (0x15f0-0x10)/0x28 = 140
REG_TAIL_VA = 0x1400042B7
REG_TAIL_BYTES = (
    "4c8d45fc"              # LEA R8,[RBP-4]
    "c745fc8b000000"        # MOV dword [RBP-4],0x8b        마지막 ID
    "488d15979a4800"        # LEA RDX,[0x14048dd60]         "g_HDRParams"
    "488d8dc8150000"        # LEA RCX,[RBP+0x15c8]          엔트리 139
    "e8cbb41600"            # CALL FUN_14016f7a0
    "488d4510"              # LEA RAX,[RBP+0x10]            배열 시작
    "48894500"
    "488d5500"
    "488d85f0150000"        # LEA RAX,[RBP+0x15f0]          배열 끝 = 시작 + 140*0x28
)

# g_TexelSize / g_TexelSizeHalf 는 배열 위치와 ID 가 어긋난다 — 바이트로 못박는다.
TEXEL_PROBES = [
    (0x140002949, "f20f10059fa84800f20f118500010000",
     "엔트리6 이름 <- [0x14048d1f0]=\"g_TexelSize\" (MOVSD 로드+[RBP+0x100] 저장)"),
    (0x140002959, "f20f10057fa84800",
     "엔트리7 이름 <- [0x14048d1e0]=\"g_TexelSizeHalf\" 로드"),
    (0x140002A8D, "f20f118528010000", "그 값을 [RBP+0x128] = 엔트리7 이름 필드에 저장"),
    (0x140002A6D, "c7852001000007000000", "엔트리6 ID = 7  (g_TexelSize)"),
    (0x140002A9B, "c7854801000006000000", "엔트리7 ID = 6  (g_TexelSizeHalf)"),
]

# 손으로 대조한 앞머리 엔트리(디컴파일 + 명령 리스팅 대조).
# 여기만 자동추출이 어렵다: 짧은 이름은 std::string SSO 라 MOVSD/MOVUPS 로
# 인라인 복사돼 이름-엔트리 짝이 컴파일러 스케줄링에 섞인다.
REG_HEAD = [
    # (entry index, name, id, name-load VA, name-store VA)
    (0, "g_Alpha", 0, 0x140002878, 0x140002881),
    (1, "g_Color", 1, 0x14000289C, 0x1400028A7),
    (2, "g_Color4", 2, 0x1400028C6, 0x1400028D4),
    (3, "g_Time", 3, 0x1400028D8, 0x1400028E6),
    (4, "g_Frametime", 4, 0x1400028DE, 0x1400028F3),
    (5, "g_Daytime", 5, 0x140002912, 0x140002933),
    (6, "g_TexelSize", 7, 0x140002949, 0x140002951),
    (7, "g_TexelSizeHalf", 6, 0x140002959, 0x140002A8D),
    (8, "g_Screen", 8, 0x140002AA5, 0x140002AB6),
]


# ── 3. HDR 블룸: g_BloomBlendParams("blend") 유도식 ────────────────────────

# 0x14017f8bc..0x14017f906 — FUN_14017f1b0 (HDR 컴포지트 파라미터 설정)
BLEND_VA = 0x14017F8BC
BLEND_BYTES = (
    "f30f1080c8030000"      # MOVSS XMM0,[RAX+0x3c8]      T = bloomhdrthreshold
    "0f28c8"                # MOVAPS XMM1,XMM0
    "f30f11442450"          # MOVSS [RSP+0x50],XMM0       .x = T
    "f30f5988cc030000"      # MULSS XMM1,[RAX+0x3cc]      K = T * bloomhdrfeather
    "f30f5cc1"              # SUBSS XMM0,XMM1             T - K
    "f30f11442454"          # MOVSS [RSP+0x54],XMM0       .y = T - K
    "0f28c1"                # MOVAPS XMM0,XMM1
    "f30f58c1"              # ADDSS XMM0,XMM1             2K
)
BLEND_EPS_VA = 0x1404925EC     # ADDSS XMM1,[rip] — K + eps
BLEND_NUM_VA = 0x14049268C     # MOVSS XMM0,[rip] — 분자

# bloomstrength(2성분) — 0x14017f85e 의 powf 호출 주변
STRENGTH_ONE_VA = 0x14017F245
STRENGTH_ONE_BYTES = "f3440f1005b6343100"   # MOVSS XMM8,[0x140492704] — XMM8 = 1.0
STRENGTH_VA = 0x14017F863
STRENGTH_BYTES = (
    "f30f108bc4030000"      # MOVSS XMM1,[RBX+0x3c4]      bloomhdrstrength
    "f3410f58c0"            # ADDSS XMM0,XMM8             pow(...) + 1.0
    "41b902000000"          # MOV R9D,2                   성분 수 = 2
)

# ── 4. 씬 설정 구조체 기본값 (생성자 FUN_140186c90) ────────────────────────

CTOR_VA = 0x1401870A1
CTOR_BYTES = (
    "49c786b40300000000803f"    # MOV [R14+0x3b4],0x3f800000   fogheightenddensity 1.0
    "41c786bc03000000000040"    # MOV [R14+0x3bc],0x40000000   bloomstrength       2.0
    "41c786c00300006666263f"    # MOV [R14+0x3c0],0x3f266666   bloomthreshold      0.65
    "41c786c403000000000040"    # MOV [R14+0x3c4],0x40000000   bloomhdrstrength    2.0
    "41c786c80300000000803f"    # MOV [R14+0x3c8],0x3f800000   bloomhdrthreshold   1.0
    "41c786cc030000cdcccc3d"    # MOV [R14+0x3cc],0x3dcccccd   bloomhdrfeather     0.1
    "41c786d0030000643bcf3f"    # MOV [R14+0x3d0],0x3fcf3b64   bloomhdrscatter     1.619
    "41c786d403000008000000"    # MOV [R14+0x3d4],8            bloomhdriterations  8
)

# clearcolor(0x35c) / ambientcolor(0x368) / skylightcolor(0x374) 는 이 5 개의 qword
# 0-스토어(R15=0)로 덮인다 = 기본값 (0,0,0). 흰색이 아니다.
COLOR_ZERO_R15_VA = 0x140186CB4
COLOR_ZERO_R15_BYTES = "4533ff"   # XOR R15D,R15D — 이후 전 구간의 0 소스
COLOR_ZERO_VA = 0x140186F61
COLOR_ZERO_BYTES = (
    "4d89be58030000"   # MOV [R14+0x358],R15
    "4d89be60030000"   # MOV [R14+0x360],R15
    "4d89be68030000"   # MOV [R14+0x368],R15
    "4d89be70030000"   # MOV [R14+0x370],R15
    "4d89be78030000"   # MOV [R14+0x378],R15
)

# 씬 JSON 키 -> 구조체 바이트 오프셋 (프로퍼티 리플렉션 등록부 FUN_140199780)
SCENE_FIELDS = {
    "clearcolor": 0x35C, "ambientcolor": 0x368, "skylightcolor": 0x374,
    "fogdistancecolor": 0x380, "fogheightcolor": 0x38C,
    "fogdistancestart": 0x398, "fogdistanceend": 0x39C,
    "fogdistancestartdensity": 0x3A0, "fogdistanceenddensity": 0x3A4,
    "fogheightstart": 0x3A8, "fogheightend": 0x3AC,
    "fogheightstartdensity": 0x3B0, "fogheightenddensity": 0x3B4,
    "bloomstrength": 0x3BC, "bloomthreshold": 0x3C0,
    "bloomhdrstrength": 0x3C4, "bloomhdrthreshold": 0x3C8,
    "bloomhdrfeather": 0x3CC, "bloomhdrscatter": 0x3D0,
    "bloomhdriterations": 0x3D4, "bloomtint": 0x3D8,
    "camerashakespeed": 0x328, "camerashakeamplitude": 0x32C,
    "camerashakeroughness": 0x330, "cameraparallaxamount": 0x334,
    "cameraparallaxdelay": 0x338, "cameraparallaxmouseinfluence": 0x33C,
}

# 생성자에서 읽어낼 기본값 (offset -> (키, 해석))
CTOR_DEFAULTS = [
    (0x3BC, "bloomstrength", "f32", 0x1401870AC + 7),
    (0x3C0, "bloomthreshold", "f32", 0x1401870B7 + 7),
    (0x3C4, "bloomhdrstrength", "f32", 0x1401870C2 + 7),
    (0x3C8, "bloomhdrthreshold", "f32", 0x1401870CD + 7),
    (0x3CC, "bloomhdrfeather", "f32", 0x1401870D8 + 7),
    (0x3D0, "bloomhdrscatter", "f32", 0x1401870E3 + 7),
    (0x3D4, "bloomhdriterations", "u32", 0x1401870EE + 7),
]


# ── 4b. HDR 블룸 피라미드의 g_RenderVar0 (FUN_140183610) ───────────────────
#
#  컴포지트 오브젝트 +0xb8..0xc4 = (+1/w, +1/h, -1/w, -1/h) * 2^level.
#  hdr_downsample.frag 이 g_RenderVar0.xy / .zy / .xw / .zw 로 4탭을 도는 형태와
#  정확히 맞는다(+x+y / -x+y / +x-y / -x-y). vec2 인 g_TexelSize 가 아니다.
PYRAMID_BASE_VA = 0x140183690
PYRAMID_BASE_BYTES = (
    "f30f5ef8"              # DIVSS XMM7,XMM0        -1.0 / height
    "f3440f5ec1"            # DIVSS XMM8,XMM1         1.0 / width
    "f30f5ef0"              # DIVSS XMM6,XMM0         1.0 / height
    "ff5048"                # CALL [RAX+0x48]
    "f3440f1186b8000000"    # MOVSS [RSI+0xb8],XMM8   +1/w
    "f30f11b6bc000000"      # MOVSS [RSI+0xbc],XMM6   +1/h
    "f3440f118ec0000000"    # MOVSS [RSI+0xc0],XMM9   -1/w
    "f30f11bec4000000"      # MOVSS [RSI+0xc4],XMM7   -1/h
)
PYRAMID_ONE_VA = 0x140492704       # XMM6/XMM8 초기값
PYRAMID_MINUSONE_VA = 0x1404929B8  # XMM7/XMM9 초기값
PYRAMID_SCALE_VA = 0x140183860
PYRAMID_SCALE_BYTES = (
    "660f6ed0"              # MOVD XMM2,EAX          level 스케일(정수)
    "0f5bd2"                # CVTDQ2PS XMM2,XMM2
    "f30f59c2"              # MULSS XMM0,XMM2
    "f30f59ca"              # MULSS XMM1,XMM2
    "f30f1186b8000000"      # MOVSS [RSI+0xb8],XMM0
)
# 다운샘플 루프는 1 << i, 업샘플 루프는 2 << (i-1) — 둘 다 2^i.
PYRAMID_WIDTH_FIELD = 0x84    # float 프레임버퍼 폭  (FUN_14017f1b0 이 설정)
PYRAMID_HEIGHT_FIELD = 0x88


# ── 5. 셰이더 소비부 ───────────────────────────────────────────────────────

MATERIALS = os.path.join(REPO, "Sources", "WapleRender", "Resources", "WEAssets",
                         "materials", "util")

# WE 내장 컴포지트 체인에서 g_TexelSize 를 쓰는 패스들.
# (머티리얼 json 의 textures[0] = 소스, 타깃은 컴포지트 드라이버 FUN_14017f1b0 이 지정)
TEXELSIZE_PASSES = {
    "downsample_quarter_bloom": {"srcMaterialKey": "downsample_quarter_bloom",
                                 "twin": "downsample_quarter"},
    "downsample_quarter_linear": {"srcMaterialKey": "downsample_quarter_linear",
                                  "twin": "downsample_quarter"},
    "downsample_eighth_blur_v": {"srcMaterialKey": "downsample_eighth_blur_v", "twin": None},
    "blur_h_bloom": {"srcMaterialKey": "blur_h_bloom", "twin": None},
    "combine_hdr": {"srcMaterialKey": "combine_hdr_upsample", "twin": None},
}


def material_sources():
    out = {}
    if not os.path.isdir(MATERIALS):
        return out
    for fn in sorted(os.listdir(MATERIALS)):
        if not fn.endswith(".json"):
            continue
        try:
            txt = open(os.path.join(MATERIALS, fn), encoding="utf-8").read()
        except OSError:
            continue
        m = re.search(r'"textures"\s*:\s*\[([^\]]*)\]', txt)
        s = re.search(r'"shader"\s*:\s*"([^"]+)"', txt)
        out[fn[:-5]] = {
            "shader": s.group(1) if s else None,
            "textures": re.findall(r'"([^"]+)"', m.group(1)) if m else [],
        }
    return out


def texelsize_expressions():
    """g_TexelSize 를 쓰는 내장 셰이더의 오프셋 식을 그대로 뽑는다."""
    out = {}
    # os.walk 는 파일시스템 순서대로 준다 — 머신이 바뀌면 같은 입력에서도 항목 순서가 달라져
    # 정본이 +95/-95 로 요동친다(내용은 동일). 그런 diff 가 반복되면 리뷰어가 정본을 안 믿는다.
    # 재현 스크립트의 출력은 입력이 같으면 바이트가 같아야 하므로 여기서 정렬해 못 박는다.
    for root, dirs, files in os.walk(SHADERS):
        dirs.sort()
        for fn in sorted(files):
            if not fn.endswith((".vert", ".frag")):
                continue
            path = os.path.join(root, fn)
            txt = open(path, encoding="utf-8", errors="replace").read()
            lines = [l.strip() for l in txt.splitlines()
                     if "g_TexelSize" in l and not l.strip().startswith("//")
                     and not l.strip().startswith("uniform")]
            if lines:
                out[os.path.relpath(path, SHADERS).replace("\\", "/")] = lines
    return out


def shader_consumers(names):
    out = {n: [] for n in names}
    if not os.path.isdir(SHADERS):
        return out
    # os.walk 는 파일시스템 순서대로 준다 — 머신이 바뀌면 같은 입력에서도 항목 순서가 달라져
    # 정본이 +95/-95 로 요동친다(내용은 동일). 그런 diff 가 반복되면 리뷰어가 정본을 안 믿는다.
    # 재현 스크립트의 출력은 입력이 같으면 바이트가 같아야 하므로 여기서 정렬해 못 박는다.
    for root, dirs, files in os.walk(SHADERS):
        dirs.sort()
        for fn in sorted(files):
            if not fn.endswith((".frag", ".vert", ".geom", ".h")):
                continue
            path = os.path.join(root, fn)
            rel = os.path.relpath(path, SHADERS).replace("\\", "/")
            try:
                txt = open(path, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for n in names:
                for m in re.finditer(re.escape(n) + r"(?![A-Za-z0-9_])", txt):
                    line = txt.count("\n", 0, m.start()) + 1
                    body = txt.splitlines()[line - 1].strip()
                    if body.startswith("//"):
                        continue
                    out[n].append(f"{rel}:{line}: {body}")
    return {k: v for k, v in out.items() if v}


# ── main ───────────────────────────────────────────────────────────────────

def main():
    with open(BIN, "rb") as fh:
        data = fh.read()
    secs = section_map(data)
    p = Probe(data, secs)

    bufs = const_buffers(p)
    assert bufs == ["g_bufStatic", "g_bufDynamic", "g_bufAnimation", "g_bufLights"], bufs

    # 배열 앞쪽 80개는 ID 를 엔트리 안에 직접 쓴다(인라인 SSO 경로).
    # 뒤쪽 60개는 FUN_14016f7a0(entry, name, &id) 로 스크래치 변수를 넘겨서 안 잡힌다.
    # 총 140 개라는 사실은 함수 꼬리 바이트로 따로 못박는다.
    ids = registry_ids(p)
    assert sorted(ids) == list(range(80)), f"엔트리 정렬 ID 스캔이 {sorted(ids)[:5]}..{len(ids)}개"
    for idx, name, uid, _lva, _sva in REG_HEAD:
        assert ids[idx] == uid, f"{name}: 배열 {idx} 의 ID 가 {ids[idx]} (기대 {uid})"
    p.at(REG_TAIL_VA, REG_TAIL_BYTES, "레지스트리 배열 = 140 엔트리 x 40B, 마지막 ID 0x8b")
    for va, hx, what in TEXEL_PROBES:
        p.at(va, hx, what)

    p.at(BLEND_VA, BLEND_BYTES, "g_BloomBlendParams 유도식")
    eps = p.f32(BLEND_EPS_VA)
    num = p.f32(BLEND_NUM_VA)
    assert abs(eps - 1e-5) < 1e-9 and num == 0.25, (eps, num)

    p.at(STRENGTH_ONE_VA, STRENGTH_ONE_BYTES, "XMM8 = 1.0 (bloomstrength 분모/반복수 하한)")
    p.at(STRENGTH_VA, STRENGTH_BYTES, "hdr bloomstrength 2성분")
    p.at(CTOR_VA, CTOR_BYTES, "씬 설정 생성자 블룸 기본값")
    p.at(COLOR_ZERO_R15_VA, COLOR_ZERO_R15_BYTES, "R15 = 0 (색 0 초기화의 소스)")
    p.at(COLOR_ZERO_VA, COLOR_ZERO_BYTES, "clear/ambient/skylight 색 0 초기화")
    p.at(PYRAMID_BASE_VA, PYRAMID_BASE_BYTES, "HDR 피라미드 g_RenderVar0 기준값 (±1/w, ±1/h)")
    p.at(PYRAMID_SCALE_VA, PYRAMID_SCALE_BYTES, "HDR 피라미드 g_RenderVar0 레벨 스케일")
    one, minus_one = p.f32(PYRAMID_ONE_VA), p.f32(PYRAMID_MINUSONE_VA)
    assert (one, minus_one) == (1.0, -1.0), (one, minus_one)

    defaults = {}
    for _off, key, kind, imm_va in CTOR_DEFAULTS:
        defaults[key] = p.f32(imm_va) if kind == "f32" else p.u32(imm_va)

    src_bin = specfmt.ev("binary", "wallpaper64.exe 고정 VA 바이트 대조")
    src_script = specfmt.ev("script", "scripts/spec/measure_uniform_feed.py")
    src_shader = specfmt.ev(
        "shader", "Sources/WapleRender/Resources/WEAssets/shaders (WE 2.8.42 동봉 원본)")

    def ghidra(fn_va, note):
        return specfmt.ev("binary", f"wallpaper64.exe FUN_{fn_va:x} (Ghidra 디컴파일)", note)

    entries = []
    E = entries.append

    E(specfmt.entry(
        "engine.uniformFeed.constantBuffers",
        {
            "names": bufs,
            "tableVA": hex(BUF_TABLE_VA),
            "lookup": "FUN_14016f740(name) -> 0..3, 못 찾으면 -1",
            "binding": "쉐이더 리플렉션으로 cbuffer 이름을 이 4개와 대조해 바인드포인트를 얻는다"
                       " (FUN_1400dc080). 슬롯 번호는 고정이 아니라 리플렉션 결과다.",
            "order": {n: i for i, n in enumerate(bufs)},
        },
        "확정", [src_bin, src_script,
                ghidra(0x14016F740, "PTR_s_g_bufStatic_140484b60 를 4개 순회하며 strcmp"),
                ghidra(0x1400DC080, "리플렉션 cbuffer 이름 -> 바인드포인트 uint16[4]")]))

    E(specfmt.entry(
        "engine.uniformFeed.registry",
        {
            "count": 140,
            "initializer": "FUN_140002860 (정적 이니셜라이저, atexit 등록)",
            "entryStride": 40,
            "layout": "{ std::string name (32B); int32 id (+0x20); pad 4 }",
            "note": "배열 순서와 ID 가 항상 같지는 않다 — 배열[6]=g_TexelSize 인데 ID 는 7,"
                    " 배열[7]=g_TexelSizeHalf 인데 ID 는 6 이다.",
            "ids": {name: ids[idx] for idx, name, _uid, _l, _s in REG_HEAD},
            "idsByArrayIndex": {str(k): v for k, v in sorted(ids.items())},
        },
        "확정", [src_bin, src_script,
                ghidra(0x140002860, "0x8c=140 엔트리, 마지막 g_HDRParams id=0x8b")]))

    T, F = "bloomhdrthreshold", "bloomhdrfeather"
    E(specfmt.entry(
        "engine.uniformFeed.g_BloomBlendParams",
        {
            "materialKey": "blend",
            "components": 4,
            "formula": {
                "K": f"{T} * {F}",
                "x": T,
                "y": f"{T} - K",
                "z": "2 * K",
                "w": f"{num} / (K + {eps})",
            },
            "epsilon": eps,
            "numerator": num,
            "codeVA": hex(BLEND_VA),
            "consumer": "shaders/hdr_downsample.frag (soft-knee 임계 곡선)",
            "note": "Unity 계열 soft-knee 블룸과 동형. knee 는 threshold 의 절대값이 아니라"
                    " threshold*feather 의 곱이다.",
        },
        "확정", [src_bin, src_script, src_shader,
                ghidra(0x14017F1B0, "FUN_14017e920(mat,\"blend\",vec4,4)")]))

    E(specfmt.entry(
        "engine.uniformFeed.hdrBloom.materialParams",
        {
            "bloomstrength": {
                "components": 2,
                "x": "bloomhdrstrength / (pow(bloomhdrscatter, max(N,2) - 2) + 1)",
                "y": "bloomhdrscatter",
            },
            "scatter": {"components": 1, "value": "bloomhdrscatter",
                        "materials": ["hdr_upsample 계열 2개"]},
            "bloomtint": {"components": 3, "value": "bloomtint(vec3)"},
            "N": "실효 반복 수 = clamp(min(bloomhdriterations, availableLevels), 1, ...)"
                 " — 엔진 인스턴스 +0x3108 에 저장",
            "availableLevels": "min(w,h) 를 1 이상으로 유지하며 2 로 나눌 수 있는 횟수"
                               " (엔진 인스턴스 +0x310c). _rt_2/4/8FrameBuffer 생성 루프에서 센다.",
            "ldrPath": {
                "bloomstrength": {"components": 1, "value": "bloomstrength"},
                "bloomthreshold": {"components": 1, "value": "bloomthreshold"},
                "bloomtint": {"components": 3, "value": "bloomtint"},
            },
            "hdrFlag": "엔진 인스턴스 +0x128 비트 0x2000 이 HDR 경로 여부",
        },
        "확정", [src_bin, src_script,
                ghidra(0x14017F1B0, "powf(scatter, N-2) 후 strength/(pow+1)"),
                ghidra(0x140184020, "같은 로직의 두 번째 사본")]))

    E(specfmt.entry(
        "engine.uniformFeed.sceneDefaults",
        {
            "fields": {k: hex(v) for k, v in sorted(SCENE_FIELDS.items())},
            "defaults": defaults,
            "bloomtint": [1.0, 1.0, 1.0],
            "colorsDefaultBlack": {
                "clearcolor": [0.0, 0.0, 0.0],
                "ambientcolor": [0.0, 0.0, 0.0],
                "skylightcolor": [0.0, 0.0, 0.0],
            },
            "ctorVA": hex(0x140186C90),
            "parserVA": hex(0x140199780),
        },
        "확정", [src_bin, src_script,
                ghidra(0x140186C90, "생성자 즉시값"),
                ghidra(0x140199780, "프로퍼티 등록: 키 문자열 + 구조체 오프셋(+0x34)")]))

    mats = material_sources()
    tex_exprs = texelsize_expressions()
    E(specfmt.entry(
        "engine.uniformFeed.g_TexelSize.consumers",
        {
            "id": 7,
            "idHalf": 6,
            "expressions": tex_exprs,
            "builtinPasses": {
                k: {"material": v["srcMaterialKey"],
                    "shader": mats.get(v["srcMaterialKey"], {}).get("shader"),
                    "textures": mats.get(v["srcMaterialKey"], {}).get("textures"),
                    "twinMaterial": v["twin"],
                    "twinTextures": mats.get(v["twin"], {}).get("textures") if v["twin"] else None}
                for k, v in TEXELSIZE_PASSES.items()},
        },
        "확정", [src_shader, src_script, src_bin]))

    E(specfmt.entry(
        "engine.uniformFeed.g_RenderVar0.hdrBloomPyramid",
        {
            "field": "컴포지트 오브젝트 +0xb8..+0xc4 (float4)",
            "base": "(+1/w, +1/h, -1/w, -1/h),  w=obj+0x84, h=obj+0x88 = 풀 프레임버퍼 크기",
            "perLevel": "다운샘플 레벨 i 는 (1 << i), 업샘플 i→i-1 은 (2 << (i-1)) — 둘 다 2^i 배",
            "value": "t = 2^i / (w,h) 일 때 g_RenderVar0 = (t.x, t.y, -t.x, -t.y)",
            "why4taps": "hdr_downsample.frag 이 v_TexCoord + g_RenderVar0.xy/.zy/.xw/.zw 로"
                        " 4탭을 돈다 = (+x,+y)/(-x,+y)/(+x,-y)/(-x,-y). vec2 로는 표현 불가.",
            "bicubicCorroboration": "같은 셰이더 BICUBIC 경로가 `texSize = 0.5 / g_RenderVar0.xy`"
                                    " 로 소스 텍스처 치수를 복원한다. 레벨 i 소스는 divisor 2^(i+1)"
                                    " 이므로 0.5 / (2^i/w) = w / 2^(i+1) = 소스 폭 — 정확히 맞는다.",
            "meaning": {
                "downsample i": "소스(레벨 i-1, 레벨0은 _rt_FullFrameBuffer) 1텍셀",
                "upsample i→i-1": "목적지(레벨 i-1) 1텍셀 = 소스의 반텍셀",
            },
            "codeVA": {"base": hex(PYRAMID_BASE_VA), "scale": hex(PYRAMID_SCALE_VA),
                       "fn": hex(0x140183610)},
            "ldrPath": "FUN_140183610 의 LDR 분기(else)는 이 필드를 건드리지 않는다."
                       " **이 함수 안에서만** 확인한 사실이다 — 다른 함수가 같은 오브젝트의"
                       " 0xb8 을 쓰는지는 확인하지 못했다(변위 0xb8 은 아무 구조체에나 흔해서"
                       " 전역 변위 스캔으로는 판별이 안 된다).",
            "dualBindingOpen": "0xb8.xy 가 g_TexelSize(vec2)로도 동시에 바인딩될 가능성은 아직"
                               " 배제하지 못했다. 그 해석이면 combine_hdr 의 ±g_TexelSize 는"
                               " 마지막 업샘플이 남긴 2/w = 레벨0(divisor 2) 1텍셀이 되어 잘 맞는다."
                               " 다만 combine_hdr 의 g_RenderVar0.x 는 스칼라 출력 배수라"
                               " 이 필드의 잔값일 수 없다 — 별도의 per-draw g_RenderVar0 소스가"
                               " 어딘가 있어야 한다.",
        },
        "확정", [src_bin, src_script, src_shader,
                ghidra(0x140183610, "레벨별 ±텍셀 vec4 기록")]))

    E(specfmt.entry(
        "engine.uniformFeed.crossCheck.renderPassJson",
        {
            "discrepancy": "spec/engine/render-pass.json 의 engine.renderPass.bloomChain.hdrPyramid"
                           " 는 오브젝트 0xb8..0xc4 를 'g_TexelSize' 라고 부른다. 그 필드는"
                           " float **4개**이고 값이 (+t, -t) 부호쌍이라 vec2 인 g_TexelSize 일 수"
                           " 없다. 실제 소비처는 hdr_downsample.frag 의 g_RenderVar0 다.",
            "agreementOnFacts": "레벨별 2^i 스케일, 레벨 divisor 2^(i+1), 반복수 필드 0x3108,"
                                " 가용 레벨 0x310c 는 두 문서가 일치한다. 이름표만 다르다.",
            "consequence": "이 파일은 그 필드를 g_RenderVar0 으로 기록한다. g_TexelSize 의"
                           " 피드는 별개이며 아직 못 찾았다(아래 unknowns 참조).",
        },
        "확정", [src_bin, src_script, src_shader,
                specfmt.ev("file", "spec/engine/render-pass.json",
                           "engine.renderPass.bloomChain.hdrPyramid texelScale 항목")]))

    E(specfmt.entry(
        "engine.uniformFeed.g_TexelSize.convention",
        {
            "claim": "g_TexelSize = 1 / 풀해상도 프레임버퍼 크기. 컴포지트 체인 전 패스에서"
                     " 같은 값이며 패스 렌더타깃 크기도 소스 텍스처 크기도 아니다."
                     " g_TexelSizeHalf = 0.5 / 풀해상도.",
            "eliminates": {
                "패스 렌더타깃 기준": "downsample_quarter(`g_Texture0Texel.xy*2`) 와"
                    " downsample_quarter_linear(`g_TexelSize*2`) 는 소스(_rt_FullFrameBuffer)와"
                    " 타깃이 같은 point/linear 쌍이다. 타깃 기준이면 두 식이 2~4배 어긋난다.",
                "소스(tex0) 기준": "blur_h_bloom 은 tex0=_rt_8FrameBuffer 인데"
                    " `localTexel = g_TexelSize.y*8`. tex0 기준이면 stride 가 8분의1 버퍼의"
                    " 8텍셀 = 13탭 가우시안으로는 불가능한 폭이다. downsample_eighth_blur_v"
                    " (tex0=_rt_4FrameBuffer) 도 같은 이유로 4배 과대.",
            },
            "supports": "풀해상도 기준이면 blur_h_bloom/downsample_eighth_blur_v 의 stride 가"
                        " 정확히 대상 버퍼 1텍셀이 되고, downsample_quarter_linear 가"
                        " downsample_quarter 와 같은 커널이 된다 — 5개 소비처 전부 정합.",
            "notMeasured": "엔진의 실제 대입부(유니폼 ID 7 을 쓰는 피드 코드)는 아직 못 찾았다."
                           " 위 결론은 내장 셰이더 5종 교차대조로 얻은 것이다.",
            "argumentIsShaderOnly": "이 결론은 위 5개 내장 셰이더의 식만으로 선다."
                " 바이너리에서 관측한 유일한 패스별 텍셀 재기록은 HDR 피라미드의"
                " g_RenderVar0(float4)이며 그건 g_TexelSize 가 아니다. 다만 '아무도"
                " g_TexelSize 를 패스별로 덮어쓰지 않는다'를 증명하지는 못했다.",
            "axisNamingTrap": "downsample_eighth_blur_v 는 이름이 _v 인데 실제로는"
                " g_TexelSize.x 로 **x축** 오프셋을 준다. blur_h_bloom 은 _h 인데"
                " g_TexelSize.y 로 **y축**이다. 파일명과 축이 뒤집혀 있다 — 이름 보고"
                " 포팅하면 두 패스가 서로 바뀐다.",
        },
        "보고", [src_shader, src_script, src_bin,
                ghidra(0x140183610, "패스별 재기록은 g_RenderVar0(float4)뿐")]))

    E(specfmt.entry(
        "engine.uniformFeed.g_TextureNResolution",
        {
            "components": ["paddedWidth", "paddedHeight", "imageWidth", "imageHeight"],
            "note": ".zw 는 .xy 의 역수가 아니라 **패딩 제거 전 실제 이미지 치수**다."
                    " (w,h,w,h) 로 접으면 패딩된 TEX 에서 UV 가 어긋난다.",
            "witnesses": [
                "common_particles.h:71 `float unpaddedWidth = g_Texture0Resolution.z"
                " / g_Texture0Resolution.x;` — .z/.x 는 1 이하 비율",
                "puppettexturechannels.vert:16 `a_TexCoordVec4.zw *"
                " (g_Texture1Resolution.zw / g_Texture1Resolution.xy)`",
                "shadowcaster.vert:58 `morphMapIndex % CASTU(g_Texture1Resolution.x)`"
                " — .x 는 정수 픽셀 폭(역수 아님)",
                "blur_k3.vert:13 `v_TexCoord.zw = 1.0 / g_Texture0Resolution.xy`"
                " — .xy 를 직접 역수 취한다",
            ],
            "crossRef": "spec/formats/tex.json format.tex.paddedVsImageDims"
                        " (plant1.tex 저장 512x1024 / 이미지 512x875)",
            "texelSibling": "g_TextureNTexel = (1/w, 1/h, w, h) — model_vertex_v1.h 가"
                            " `% morphTexel.z` 로 .z 를 정수 치수로 쓴다",
            # [상태 하향 2026-08-01] 이 항목은 처음 '확정' 이었는데
            # spec/engine/shaders.json shaders.textureResolutionUniforms.layout 은
            # 같은 주장을 '보고' 로 냈다. 같은 사실이 두 정본에서 다른 상태일 수 없다.
            # 낮은 쪽으로 맞춘다: 근거가 전부 셰이더 사용례의 **역산**이고,
            # 엔진이 이 vec4 를 채우는 대입부를 읽은 사람이 아직 없다. crossRef 인
            # tex.json 은 '패딩≠이미지 치수가 존재한다' 만 세우지 성분 순서를 세우지 않는다.
            "whyNotConfirmed": "엔진 대입부 미독. 4성분의 순서는 셰이더 사용례에서"
                               " 역산한 것이고, 실제 바인딩된 텍스처의 값을 읽은 것이 아니다."
                               " 확정하려면 유니폼 피드 함수(미해결 unknown)를 먼저 열어야 한다.",
        },
        "보고", [src_shader, src_script,
                specfmt.ev("file", "spec/formats/tex.json", "패딩/이미지 치수 분리 확정 항목"),
                specfmt.ev("file", "spec/engine/shaders.json",
                           "shaders.textureResolutionUniforms.layout 이 같은 주장을 보고로 냈다 — 상태 일치")]))

    E(specfmt.entry(
        "engine.uniformFeed.g_RenderVar",
        {
            "ids": {"g_RenderVar0": 0x6C, "g_RenderVar1": 0x6D, "g_RenderVar2": 0x6E,
                    "g_RenderVar3": 0x6F, "g_RenderVar4": 0x70},
            "nature": "고정 의미 없음 — 드로우를 소유한 서브시스템이 채우는 범용 vec4 슬롯 5개."
                      " 같은 이름이 셰이더마다 다른 뜻이다.",
            "observedMeanings": {
                "common_particles.h": "RenderVar0.xyz = 트레일 길이 (스케일/최대/최소),"
                                      " RenderVar1.xyz = 스프라이트시트 (frameW, frameH, numFrames)",
                "font.frag": "RenderVar0 = (msdfRange, outlineWidth, blurRadius, dropShadowRadius),"
                             " RenderVar1.xyz = outlineColor, .w = shadowOffset.x,"
                             " RenderVar2.xyz = shadowColor, .w = shadowOffset.y,"
                             " RenderVar3.x = shadowOpacity",
                "hdr_downsample.frag": "RenderVar0 = (+t.x, +t.y, -t.x, -t.y), t = 2^level 텍셀."
                                       " 아래 engine.uniformFeed.g_RenderVar0.hdrBloomPyramid 참조"
                                       " — 이건 산출식까지 확정했다.",
                "combine_hdr.frag": "RenderVar0.x = 최종 출력 스칼라 배수,"
                                    " RenderVar0.y = DISPLAYHDR 경로의 하이라이트 부스트"
                                    " (`.y * smoothstep(1,5,luma) + .x`)",
                "clippingmaskimage4.frag": "RenderVar0.x = 마스크 반전 보간 계수",
                "brushpreview.frag": "RenderVar0.x = 알파, .y = 브러시 경도",
            },
            "notMeasured": "combine_hdr 의 .x/.y 산출식(디스플레이 HDR 밝기/SDR 화이트 유도)은"
                           " 못 찾았다. 이름 문자열 참조는 레지스트리 1곳뿐이라 피드는 ID 경유다.",
        },
        "보고", [src_shader, src_script, src_bin,
                ghidra(0x140002860, "이름 문자열의 유일한 코드 참조는 레지스트리")]))

    E(specfmt.entry(
        "engine.uniformFeed.ambientAndSkylight",
        {
            "sceneKeys": {"ambientcolor": hex(0x368), "skylightcolor": hex(0x374)},
            "defaults": {"ambientcolor": [0.0, 0.0, 0.0], "skylightcolor": [0.0, 0.0, 0.0]},
            "defaultIsBlackNotWhite": True,
            "propagation": "씬 설정 -> 렌더 상태 객체: ambientcolor 는 +0x1298 로,"
                           " skylightcolor 는 +0x12a4 로 그대로 복사된다 (FUN_140186c90).",
            "note": "씬 JSON 에 키가 없으면 검정이다. 중립값 흰색이 아니다 —"
                    " 흰색으로 대체하면 앰비언트가 씬 전체를 들어올린다.",
        },
        "확정", [src_bin, src_script,
                ghidra(0x140186C90, "0x358..0x37f 를 R15(=0) qword 5회로 0 초기화"),
                ghidra(0x140199780, "ambientcolor->0x368, skylightcolor->0x374 등록")]))

    E(specfmt.entry(
        "engine.uniformFeed.unknowns",
        {
            "g_Daytime": "ID 5. 셰이더 유니폼으로서의 피드는 미확인 — 이름 문자열"
                         " \"g_Daytime\"(VA 0x14048d188)의 코드 참조는 레지스트리 1곳뿐이다."
                         " 별도로 존재하는 \"daytime\"(VA 0x1404781f0) / \"daytimeend\""
                         " (VA 0x140478250)는 delay/sorted/dayofweek/playintro 와 한 블록에"
                         " 있는 **플레이리스트 시간대 스케줄링 키**라 셰이더와 무관하다"
                         " (참조: 0x140075cce, 0x1400761ce).",
            "g_LayerModelMatrix": "ID 24(0x18). 레이어 모델 행렬. 산출 코드 미확인.",
            "g_EffectTextureProjectionMatrix": "ID 22, Inverse 는 ID 23. 산출 코드 미확인.",
            "g_bufStatic/g_bufLights/g_bufAnimation/g_bufDynamic 멤버 레이아웃":
                "cbuffer 4개의 존재와 이름 매칭 방식은 확정했지만, 어느 유니폼이 어느 버퍼에"
                " 들어가고 바이트 오프셋이 얼마인지는 못 봤다. 오프셋은 GLSL->HLSL"
                " 크로스컴파일 결과의 D3D 리플렉션에서 셰이더별로 나오므로 고정 표가"
                " 없을 가능성이 높다(FUN_1400dc080 이 매번 리플렉션으로 바인드포인트를 찾는다).",
            "유니폼 피드 함수": "ID 로 값을 채우는 per-frame 함수를 아직 못 찾았다."
                             " 이름 문자열 참조가 레지스트리 1곳뿐이라 이름 기반 추적이 막히고,"
                             " ID 상수(0..0x8b)를 쓰는 switch/점프테이블도 안 나왔다"
                             " (FUN_140155fc0 에 switch 없음).",
            "다음 진입점(단일)": "'누가 오브젝트 필드를 쓰는가'가 아니라 **'누가 읽는가'**를 봐라."
                             " 유니폼 ID -> 값 포인터 테이블이 있으면 이 영역 전체가 한 번에 풀린다."
                             " 미탐색 지점: FUN_140157430 (모든 컴포지트 드로우 직후 호출되는데"
                             " 한 번도 디컴파일 안 했다)와 그 인자인 머티리얼 오브젝트"
                             " +0x3190 / +0x3198 / +0x31a0 / +0x31a8.",
        },
        "추정", [src_script, specfmt.ev("note", "미해결 항목 목록 — 후속 조사 진입점")]))

    watch = ["g_TexelSize", "g_TexelSizeHalf", "g_Texture0Resolution", "g_Texture1Resolution",
             "g_Texture0Texel", "g_Texture1Texel", "g_RenderVar0", "g_RenderVar1",
             "g_LightAmbientColor", "g_LightSkylightColor", "g_Daytime", "g_LayerModelMatrix",
             "g_EffectTextureProjectionMatrix", "g_EffectTextureProjectionMatrixInverse",
             "g_BloomBlendParams", "g_Screen", "g_HDRParams", "g_TextureReductionScale"]
    cons = shader_consumers(watch)
    E(specfmt.entry(
        "engine.uniformFeed.shaderConsumers",
        cons, "확정", [src_shader, src_script]))

    scatter, iters = defaults["bloomhdrscatter"], defaults["bloomhdriterations"]
    we_divisor = scatter ** (max(int(iters), 2) - 2) + 1
    E(specfmt.entry(
        "engine.uniformFeed.wapleGaps",
        {
            "g_TextureNResolution": {
                "we": "(paddedW, paddedH, imageW, imageH)",
                "waple": "SceneRendererResources.buildPassBindings / SceneRenderer3D 가"
                         " SIMD4(w, h, w, h) 로 채운다 — .zw 가 .xy 의 복제다."
                         " 같은 파일 주석(SceneRendererResources.swift:736)은 WE 규약을 정확히"
                         " 적어놓았는데 코드가 그걸 안 지킨다(주석과 코드 불일치).",
                "impact": "패딩된 TEX(비-POT 원본을 POT 로 저장한 것)에서 .zw/.xy 비율이 1 이 되어"
                          " 스프라이트시트 프레임 폭(common_particles.h SPRITESHEETBLENDNPOT)과"
                          " 퍼펫 채널 UV(puppettexturechannels.vert)가 어긋난다."
                          " EffectShaders.swift:233 이 이 규약 때문에 마스크 UV 를 손포팅해뒀다.",
            },
            "g_TexelSize": {
                "we": "풀 프레임버퍼 텍셀(패스 불변) — 위 convention 항목",
                "waple": "GLSLTranslator.engineReplacement: `1.0 / eng.targetRes.xy`"
                         " (이펙트 출력 dst 기준). 레이어 커스텀 셰이더 경로는 tex0 근사로 또 다르다.",
                "impact": "다운스케일된 렌더타깃을 쓰는 체인에서 블러 폭이 배수로 틀린다."
                          " WE 내장 체인으로 환산하면 blur_h_bloom 상당 패스가 8배 과대.",
            },
            "g_LightAmbientColor": {
                "we": "씬 authoring 값. 키가 없으면 (0,0,0) — 검정.",
                "waple": "GLSLTranslator.engineReplacement 가 float4(1,1,1,1) 상수 주입.",
                "impact": "폴백 방향이 반대다. WE 의 검정은 무연산이고 흰색은 씬 전체를 들어올린다."
                          " 코퍼스 162 씬 중 159 개가 ambientcolor 를 명시하므로(spec/corpus/"
                          "scene-schema.json) 실질 문제는 '기본값'이 아니라 **저작값을 안 읽고"
                          " 상수를 넣는 것**이다. SceneDocument 는 이미 올바르게 파싱해 둔다"
                          " (ambientColor 기본 (0,0,0)) — 번역기만 그 값에 연결되어 있지 않다.",
            },
            "g_BloomBlendParams": {
                "we": "(T, T-K, 2K, 0.25/(K+1e-5)), K = T*F",
                "waple": "HDRBloomPyramidPass.swift:193-196 이 동일 식을 이미 쓴다 — **일치**.",
                "impact": "차이 없음. 독립 재도출로 서로 검증됨.",
            },
            "hdrBloomStrengthNormalization": {
                "we": f"머티리얼 bloomstrength.x = bloomhdrstrength /"
                      f" (pow(bloomhdrscatter, max(N,2)-2) + 1). 기본값(scatter={scatter:.3f},"
                      f" N={int(iters)})이면 분모 ≈ {we_divisor:.2f} → 실효 {2.0 / we_divisor:.4f}",
                "waple": "SceneRenderer.swift:1159 단일레벨 경로는 strength × iterations ×"
                         " strengthScale (곱), SceneRendererFinalizer.swift:35 피라미드 경로는"
                         " raw strength. 둘 다 나눗셈 정규화가 없다.",
                "impact": "WE 는 레벨이 늘수록 레벨당 기여를 **줄이고**, Waple 은 늘리거나 그대로 둔다."
                          " 기본 파라미터에서 방향이 반대라 블룸 전역 밝기가 크게 어긋난다."
                          " 이 항이 재구현에서 가장 놓치기 쉬운 부분이다.",
            },
            "bloomhdrstrength 기본값": {
                "we": "2.0 (씬 설정 생성자)",
                "waple": "SceneDocument.swift:776/2441 이 0 — 키가 없는 씬은 블룸이 완전히 꺼진다.",
                "impact": "bloomhdrstrength 를 생략한 씬에서 WE 는 블룸이 보이고 Waple 은 안 보인다."
                          " threshold/feather/iterations/scatter 기본값은 전부 일치한다.",
            },
            "skylightcolor 폴백": {
                "we": "ambientcolor 와 독립. 둘 다 기본 (0,0,0).",
                "waple": "SceneDocument.swift:867 `vec3(...) ?? ambientColor` — ambient 로 폴백.",
                "impact": "둘 다 기본이 0 이라 기본값에서는 결과가 같다. ambientcolor 만 저작된"
                          " 씬에서 갈린다(WE=검정 skylight, Waple=ambient 복제).",
            },
        },
        "확정", [src_bin, src_script, src_shader,
                specfmt.ev("file", "Sources/WapleCore/GLSLTranslator.swift:1254-1257, 1274-1286"),
                specfmt.ev("file", "Sources/WapleRender/SceneRendererResources.swift:736, 763"),
                specfmt.ev("file", "Sources/WapleRender/HDRBloomPyramidPass.swift:193-197"),
                specfmt.ev("file", "Sources/WapleRender/SceneRenderer.swift:1158-1168"),
                specfmt.ev("file", "Sources/WapleCore/SceneDocument.swift:758-784, 866-867, 2441-2445")]))

    E(specfmt.entry(
        "engine.uniformFeed.probes",
        [{"va": va, "what": what} for va, what in p.checked],
        "확정", [src_script, src_bin]))

    doc = specfmt.doc("scripts/spec/measure_uniform_feed.py", entries)
    specfmt.dump(doc, os.path.join("spec", "engine", "uniform-feed.json"))
    print(f"상수버퍼 {bufs}")
    print(f"레지스트리 {len(ids)}개, 프로브 {len(p.checked)}개 통과")
    print(f"블룸 기본값 {defaults}")


if __name__ == "__main__":
    main()
