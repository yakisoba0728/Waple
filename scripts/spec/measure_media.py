"""WE 의 미디어(비디오·오디오) 경로 정본을 만든다.

세 갈래를 한 스크립트로 재현한다.

1. bin/mediaextensions64.dll — export 177개의 정체.
   "exports 가 177개라 비디오 API 표면이 노출돼 있다"는 통념을 반증한다:
   177 중 175 가 OpenAL Soft 이고, 임포트에 Media Foundation 이 **하나도 없다**.
   이 DLL 은 오디오 전용이다.

2. wallpaper64.exe — 비디오 경로의 실체.
   MF Media Engine / MF Media Session+EVR / DirectShow+LAV 세 프레임워크와
   그 설정 키, 그리고 색공간 판정 분기를 명령 바이트로 고정한다.
   바이트 앵커는 "이 주소의 이 바이트열"이라 WE 가 갱신되면 즉시 깨진다 — 그게 목적이다.

3. 코퍼스 — video 145종 + scene 내장 mp4 의 실제 코덱/colr 분포.
   ISO BMFF 를 직접 파싱한다(ffprobe 없음).

경로는 환경변수로 바꾼다: WE_ROOT, WE_WORKSHOP.
"""
import collections
import json
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")
WS = os.environ.get("WE_WORKSHOP", r"Z:\SteamLibrary\steamapps\workshop\content\431960")

WALLPAPER = os.path.join(WE, "wallpaper64.exe")
MEDIAEXT = os.path.join(WE, "bin", "mediaextensions64.dll")


# ---------------------------------------------------------------- PE 최소 파서

def pe_sections(data):
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    coff = pe + 4
    nsec = struct.unpack_from("<H", data, coff + 2)[0]
    optsize = struct.unpack_from("<H", data, coff + 16)[0]
    opt = coff + 20
    p32p = struct.unpack_from("<H", data, opt)[0] == 0x20B
    base = (struct.unpack_from("<Q", data, opt + 24)[0] if p32p
            else struct.unpack_from("<I", data, opt + 28)[0])
    nrva = struct.unpack_from("<I", data, opt + (108 if p32p else 92))[0]
    dd = opt + (112 if p32p else 96)
    dirs = [struct.unpack_from("<II", data, dd + i * 8) for i in range(nrva)]
    secs = []
    for i in range(nsec):
        b = opt + optsize + i * 40
        name = data[b:b + 8].rstrip(b"\0").decode("ascii", "ignore")
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, b + 8)
        secs.append((name, vaddr, vsize, rawptr, rawsize))
    return base, secs, dirs


def rva_to_off(rva, secs):
    for _, vaddr, vsize, rawptr, rawsize in secs:
        if vaddr <= rva < vaddr + max(vsize, rawsize):
            return rva - vaddr + rawptr
    return None


def off_to_va(off, base, secs):
    for name, vaddr, _, rawptr, rawsize in secs:
        if rawptr <= off < rawptr + rawsize:
            return base + vaddr + (off - rawptr), name
    return None, None


def cstr(data, off):
    return data[off:data.index(b"\0", off)].decode("ascii", "ignore")


def pe_exports(path):
    data = open(path, "rb").read()
    base, secs, dirs = pe_sections(data)
    erva, esz = dirs[0]
    eo = rva_to_off(erva, secs)
    (_, _, _, _, _, ordbase, naddr, nnames,
     addr_rva, names_rva, ords_rva) = struct.unpack_from("<IIHHIIIIIII", data, eo)
    ao, no, oo = (rva_to_off(x, secs) for x in (addr_rva, names_rva, ords_rva))
    named = {}
    for i in range(nnames):
        nr = struct.unpack_from("<I", data, no + 4 * i)[0]
        idx = struct.unpack_from("<H", data, oo + 2 * i)[0]
        named[idx] = cstr(data, rva_to_off(nr, secs))
    out = []
    for i in range(naddr):
        fr = struct.unpack_from("<I", data, ao + 4 * i)[0]
        if fr:
            out.append((ordbase + i, named.get(i)))
    return out


def _thunk_names(data, secs, int_rva):
    names, j = [], 0
    t = rva_to_off(int_rva, secs)
    while True:
        v = struct.unpack_from("<Q", data, t + j * 8)[0]
        if v == 0:
            break
        names.append(f"#{v & 0xFFFF}" if v & (1 << 63)
                     else cstr(data, rva_to_off(v & 0x7FFFFFFF, secs) + 2))
        j += 1
    return names


def pe_imports(path):
    """(정적 임포트 dict, 지연로드 임포트 dict)"""
    data = open(path, "rb").read()
    _, secs, dirs = pe_sections(data)
    static, delay = {}, {}
    io = rva_to_off(dirs[1][0], secs)
    i = 0
    while True:
        ent = struct.unpack_from("<IIIII", data, io + i * 20)
        if not any(ent):
            break
        oft, _, _, nrva, ft = ent
        static[cstr(data, rva_to_off(nrva, secs))] = _thunk_names(data, secs, oft or ft)
        i += 1
    if dirs[13][0]:
        o = rva_to_off(dirs[13][0], secs)
        i = 0
        while True:
            _, namerva, _, _, int_, _, _, _ = struct.unpack_from("<IIIIIIII", data, o + i * 32)
            if not namerva:
                break
            delay[cstr(data, rva_to_off(namerva, secs))] = _thunk_names(data, secs, int_)
            i += 1
    return static, delay


# ------------------------------------------------------------------ GUID 스캔

def guid_bytes(s):
    s = s.replace("-", "")
    return struct.pack("<IHH", int(s[0:8], 16), int(s[8:12], 16), int(s[12:16], 16)) + bytes.fromhex(s[16:32])


# WE 가 실제로 참조하는 COM GUID 만 담는다(전수 후보 스캔 결과 발견된 것).
GUIDS = {
    # Media Foundation — 미디어 타입 / 속성
    "MFMediaType_Audio": "73647561-0000-0010-8000-00AA00389B71",
    "MFMediaType_Video": "73646976-0000-0010-8000-00AA00389B71",
    "MF_MT_FRAME_SIZE": "1652C33D-D6B2-4012-B834-72030849A37D",
    "MF_MT_FRAME_RATE": "C459A2E8-3D2C-4E44-B132-FEE5156C7BB0",
    "MF_MT_TRANSFER_FUNCTION": "5FB0FCE9-BE5C-4935-A811-EC838F8EED93",
    "MF_MT_VIDEO_PRIMARIES": "DBFBE4D7-0740-4EE0-8192-850AB0E21935",
    "MF_PD_DURATION": "6C990D33-BB8E-477A-8598-0D5D96FCD88A",
    "MF_TOPOLOGY_DXVA_MODE": "1E8D34F6-F5AB-4E23-BB88-874AA3A1A74D",
    # Media Foundation — Media Engine (mfEngine 경로)
    "CLSID_MFMediaEngineClassFactory": "B44392DA-499B-446B-A4CB-005FEAD0E6D5",
    "IMFMediaEngineClassFactory": "4D645ACE-26AA-4688-9BE1-DF3516990B93",
    "IMFMediaEngineEx": "83015EAD-B1E6-40D0-A98A-37145FFE1AD1",
    "IMFMediaEngineNotify": "FEE7C112-E776-42B5-9BBF-0048524E2BD5",
    "MF_MEDIA_ENGINE_CALLBACK": "C60381B8-83A4-41F8-A3D0-DE05076849A9",
    "MF_MEDIA_ENGINE_DXGI_MANAGER": "065702DA-1094-486D-8617-EE7CC4EE4648",
    "MF_MEDIA_ENGINE_VIDEO_OUTPUT_FORMAT": "5066893C-8CF9-42BC-8B8A-472212E52726",
    "MF_MEDIA_ENGINE_EXTENSION": "3109FD46-060D-4B62-8DCF-FAFF811318D2",
    # Media Foundation — Media Session + EVR (mf 경로)
    "CLSID_EnhancedVideoRenderer": "FA10746C-9B63-4B6C-BC49-FC300EA5F256",
    "MR_VIDEO_RENDER_SERVICE": "1092A86C-AB1A-459A-A336-831FBC4D11FF",
    "IMFVideoDisplayControl": "A490B1E4-AB84-4D31-A1B2-181E03B1077A",
    "IMFVideoProcessor": "6AB0000C-FECE-4D1F-A2AC-A9573530656E",
    "IMFRateControl": "88DDCD21-03C3-4275-91ED-55EE3929328F",
    "IMFAudioStreamVolume": "76B1BBDB-4EC8-4F36-B106-70A9316DF593",
    "IMFByteStream": "AD4C1B00-4BF7-422F-9175-756693D9130D",
    "IMFMediaSource": "279A808D-AEC7-40C8-9C6B-A6B492C78A66",
    "IMFAttributes": "2CD2D921-C447-44A7-A13C-4ADABFC247E3",
    # DirectShow (dshow.lav.vmr9 경로)
    "CLSID_FilterGraph": "E436EBB3-524F-11CE-9F53-0020AF0BA770",
    "CLSID_DSoundRender": "79376820-07D0-11CF-A24D-0020AFD79767",
    "IID_IBaseFilter": "56A86895-0AD4-11CE-B03A-0020AF0BA770",
    "IID_IFileSourceFilter": "56A868A6-0AD4-11CE-B03A-0020AF0BA770",
    "IID_IGraphBuilder": "56A868A9-0AD4-11CE-B03A-0020AF0BA770",
    "IID_IMediaControl": "56A868B1-0AD4-11CE-B03A-0020AF0BA770",
    "IID_IMediaSeeking": "36B73880-C2C8-11CF-8B46-00805F6CEF60",
    "IID_IMediaEventEx": "56A868C0-0AD4-11CE-B03A-0020AF0BA770",
    "IID_IBasicAudio": "56A868B3-0AD4-11CE-B03A-0020AF0BA770",
    # D3D11 / DXGI 공유
    "ID3D11Texture2D": "6F15AAF2-D208-4E89-9AB4-489535D34F9C",
    "ID3D11Multithread": "9B7E4E00-342C-4106-A19F-4F2704F689F0",
    "IDXGIKeyedMutex": "9D8E1289-D7B3-465F-8126-250E349AF85D",
    "IDXGIResource": "035F3AB4-482E-4E50-B41F-8A7F8BD8960B",
}

# WE 가 참조하지 **않는** 것으로 확인된 GUID — 부재 자체가 결론이다.
GUIDS_ABSENT = {
    "MF_MT_YUV_MATRIX": "3E23D450-2C75-4D25-A00E-B91670D12327",
    "MF_MT_VIDEO_NOMINAL_RANGE": "C21B8EE5-B956-4071-8DAF-325EDF5CAB11",
    "MF_MT_VIDEO_CHROMA_SITING": "65DF2370-C773-4C33-AA64-843E068EFB0C",
    "MF_MT_SUBTYPE": "F7E34C9A-42E8-4714-B74B-CB29D72C35E5",
    "MF_MT_MAJOR_TYPE": "48EBA18E-F8C9-4687-BF11-0A74C9F96A8F",
    "MFVideoFormat_NV12": "3231564E-0000-0010-8000-00AA00389B71",
    "MFVideoFormat_ARGB32": "00000015-0000-0010-8000-00AA00389B71",
    "MFVideoFormat_RGB32": "00000016-0000-0010-8000-00AA00389B71",
    "MFVideoFormat_H264": "34363248-0000-0010-8000-00AA00389B71",
    "MFVideoFormat_HEVC": "43564548-0000-0010-8000-00AA00389B71",
    "MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING": "0F81DA2C-B537-4672-A8B2-A681B17307A3",
    "MF_SOURCE_READER_D3D_MANAGER": "EC822DA2-E1E9-4B29-A0D8-563C719F5269",
    "MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS": "A634A91C-822B-41B9-A494-4DE4643612B0",
    "IMFDXGIBuffer": "E7174CFA-1C9E-48B1-8866-626226BFC258",
    "IMF2DBuffer": "7DC9D5F9-9ED9-44EC-9BBF-0600BB589FBB",
    "CLSID_VideoMixingRenderer9": "51B4ABF3-748F-4E3B-A276-C828330E926A",
    "IMFMediaEngine": "98A1B0BB-03EB-4935-AE7C-93C1FA0E1C93",
}


def scan_guids(data, base, secs, table):
    out = {}
    for name, g in sorted(table.items()):
        i = data.find(guid_bytes(g))
        if i >= 0:
            va, sec = off_to_va(i, base, secs)
            out[name] = {"guid": g, "va": hex(va), "section": sec}
    return out


# ------------------------------------------------- 명령 바이트 앵커 (재현 고정점)

# va -> (기대 바이트열 hex, 사람이 읽는 의미)
ANCHORS = {
    0x1400F2245: ("b970000200", "mov ecx, 0x20070 — MFStartup(MF_VERSION=0x20070, MFSTARTUP_NOSOCKET)"),
    0x1400F2025: ("41b900080000", "mov r9d, 0x800 — D3D11CreateDevice Flags=D3D11_CREATE_DEVICE_VIDEO_SUPPORT"),
    0x1400F239D: ("41b857000000", "mov r8d, 0x57 — MF_MEDIA_ENGINE_VIDEO_OUTPUT_FORMAT = 87"),
    0x1400F2415: ("83ca12", "or edx, 0x12 — MediaEngine CreateInstance dwFlags 기본값"),
    0x1400F2407: ("4180f601", "xor r14b, 1 — 오디오 비활성이면 dwFlags 에 0x4 를 더한다"),
    0x1400F243B: ("33d2", "xor edx, edx — 직후 call [rax+0xE8] (인자 FALSE)"),
    0x1400F2443: ("ff90e8000000", "call qword [rax+0xE8] — IMFMediaEngine +0xE8"),
    0x1400F244D: ("ba01000000", "mov edx, 1 — 직후 call [rax+0xF8] (인자 TRUE)"),
    0x1400F2455: ("ff90f8000000", "call qword [rax+0xF8] — IMFMediaEngine +0xF8"),
    0x1400F2867: ("83e80f740a", "sub eax, 0xF / je — MF_MT_TRANSFER_FUNCTION == 15 분기"),
    0x1400F286C: ("83f8017510", "cmp eax, 1 / jne — MF_MT_TRANSFER_FUNCTION == 16 분기"),
    0x1400F28A0: ("837c24680975", "cmp dword [rsp+0x68], 9 / jne — MF_MT_VIDEO_PRIMARIES == 9 분기"),
    0x1400F350E: ("41b8e8030000", "mov r8d, 0x3E8 — 직후 call [rax+0x40] (키드뮤텍스 1000ms)"),
    0x1400F34FF: ("c6442453ff", "mov byte [rsp+0x53], 0xFF — 경계색 알파 255"),
    0x1400F353F: ("ff9058010000", "call qword [rax+0x158] — IMFMediaEngineEx +0x158"),
    0x1400F377F: ("ff9060010000", "call qword [rax+0x160] — IMFMediaEngine +0x160"),
    0x14012009F: ("ff15eb653000", "call [MFReadWrite!MFCreateSourceReaderFromURL]"),
    0x1401218B9: ("f20f5e05", "divsd xmm0, [rip+0x370fbf] — 나눗셈 상수 1e7 (100ns 단위 → 초)"),
    # mfEngine 정지(stall) 감시기
    0x1400F378F: ("ff92a0000000", "call qword [rdx+0xA0] — 결과가 0 이 아니면 프레임 스킵"),
    0x1400F37A9: ("ff92d8000000", "call qword [rdx+0xD8] — 결과가 0 이 아니면 프레임 스킵"),
    0x1400F37D1: ("f30f5d35", "minss xmm6, [rip+0x39ee7b] — 프레임 델타를 0.1초로 상한"),
    0x1400F37DC: ("ff9080000000", "call qword [rax+0x80] — IMFMediaEngine +0x80"),
    0x1400F3824: ("660f2e7b40", "ucomisd xmm7, [rbx+0x40] — 직전 시각과 완전 동일한지"),
    0x1400F3836: ("0f2f35", "comiss xmm6, [rip+0x39ee3f] — 정지 누적 임계 0.2초"),
    0x1400F384B: ("ff9008010000", "call qword [rax+0x108] — 복구 1단계"),
    0x1400F385B: ("ff9088000000", "call qword [rax+0x88] — 복구 2단계 (인자 0.0)"),
    0x1400F3861: ("b964000000", "mov ecx, 0x64 — 직후 Sleep(100)"),
    0x1400F3883: ("ff9000010000", "call qword [rax+0x100] — 복구 4단계"),
}

# 감시기가 쓰는 부동소수 상수 (VA -> 값). 이것도 앵커다.
FLOAT_ANCHORS = {
    0x140492654: (0.10000000149011612, "프레임 델타 상한(초)"),
    0x14049267C: (0.20000000298023224, "정지 판정 누적 임계(초)"),
    0x140492858: (5.0, "복구 재시도 허용 백오프 상한"),
    0x140492868: (10.0, "백오프 갱신 상수 — next = 4*cur + 10"),
    0x140492880: (10000000.0, "100ns → 초 (Media Session 스터터 검출)"),
}


def check_floats(data, base, secs):
    ok, bad = {}, {}
    for va, (want, meaning) in sorted(FLOAT_ANCHORS.items()):
        off = rva_to_off(va - base, secs)
        n = 8 if want == 10000000.0 else 4
        got = struct.unpack_from("<d" if n == 8 else "<f", data, off)[0]
        (ok if got == want else bad)[hex(va)] = {"value": got, "meaning": meaning}
    return ok, bad


def check_anchors(data, base, secs):
    ok, bad = {}, {}
    for va, (hexs, meaning) in sorted(ANCHORS.items()):
        want = bytes.fromhex(hexs)
        off = rva_to_off(va - base, secs)
        got = data[off:off + len(want)] if off is not None else b""
        (ok if got == want else bad)[hex(va)] = {"bytes": hexs, "meaning": meaning,
                                                 **({} if got == want else {"actual": got.hex()})}
    return ok, bad


# --------------------------------------------------------- 문자열 상수(설정 열거)

def find_strings(data, base, secs, names):
    out = {}
    for s in names:
        pat = s.encode("ascii") + b"\0"
        i = data.find(pat)
        if i >= 0:
            va, sec = off_to_va(i, base, secs)
            out[s] = {"va": hex(va), "section": sec}
    return out


# ------------------------------------------------------------- ISO BMFF 파서

def _boxes(data, start, end):
    p = start
    while p + 8 <= end:
        size = struct.unpack_from(">I", data, p)[0]
        typ = data[p + 4:p + 8]
        hdr = 8
        if size == 1:
            if p + 16 > end:
                return
            size = struct.unpack_from(">Q", data, p + 8)[0]
            hdr = 16
        elif size == 0:
            size = end - p
        if size < hdr or p + size > end:
            return
        yield typ, p + hdr, p + size
        p += size


def _find(data, s, e, path):
    """path 예: [b"moov", b"trak"] — 첫 일치 박스의 (payload_start, payload_end)."""
    for typ, ps, pe in _boxes(data, s, e):
        if typ == path[0]:
            if len(path) == 1:
                return ps, pe
            r = _find(data, ps, pe, path[1:])
            if r:
                return r
    return None


def parse_mp4(data, start=0, end=None):
    """ISO BMFF → {brand, tracks:[{kind,codec,w,h,fps,colr...}], durationSec}"""
    end = len(data) if end is None else end
    info = {"brand": None, "tracks": []}
    ft = _find(data, start, end, [b"ftyp"])
    if ft:
        info["brand"] = data[ft[0]:ft[0] + 4].decode("ascii", "replace")
    mv = _find(data, start, end, [b"moov"])
    if not mv:
        return info
    ms, me = mv
    mvhd = _find(data, ms, me, [b"mvhd"])
    if mvhd:
        v = data[mvhd[0]]
        if v == 0:
            ts, dur = struct.unpack_from(">II", data, mvhd[0] + 12)
        else:
            ts, dur = struct.unpack_from(">IQ", data, mvhd[0] + 20)
        info["durationSec"] = round(dur / ts, 3) if ts else None
    for typ, ps, pe in _boxes(data, ms, me):
        if typ != b"trak":
            continue
        t = {}
        hd = _find(data, ps, pe, [b"mdia", b"hdlr"])
        if hd:
            t["handler"] = data[hd[0] + 8:hd[0] + 12].decode("ascii", "replace")
        md = _find(data, ps, pe, [b"mdia", b"mdhd"])
        timescale = None
        if md:
            if data[md[0]] == 0:
                timescale, dur = struct.unpack_from(">II", data, md[0] + 12)
            else:
                timescale, dur = struct.unpack_from(">IQ", data, md[0] + 20)
        sd = _find(data, ps, pe, [b"mdia", b"minf", b"stbl", b"stsd"])
        if sd:
            s0, s1 = sd
            n = struct.unpack_from(">I", data, s0 + 4)[0]
            if n:
                # VisualSampleEntry: reserved[6] dri[2] pre[2] res[2] pre[12]
                #                    width[2] height[2] hres[4] vres[4] res[4]
                #                    frame_count[2] compressorname[32] depth[2] pre[2] → 서브박스
                for etyp, eps, epe in _boxes(data, s0 + 8, s1):
                    t["codec"] = etyp.decode("ascii", "replace")
                    if t.get("handler") == "vide" and epe - eps >= 78:
                        t["width"], t["height"] = struct.unpack_from(">HH", data, eps + 24)
                        t["depth"] = struct.unpack_from(">H", data, eps + 74)[0]
                        for btyp, bps, bpe in _boxes(data, eps + 78, epe):
                            if btyp == b"colr":
                                ct = data[bps:bps + 4].decode("ascii", "replace")
                                t["colrType"] = ct
                                if ct in ("nclx", "nclc") and bpe - bps >= 10:
                                    p1, tr, mx = struct.unpack_from(">HHH", data, bps + 4)
                                    t["colrPrimaries"], t["colrTransfer"], t["colrMatrix"] = p1, tr, mx
                                    if ct == "nclx" and bpe - bps >= 11:
                                        t["colrFullRange"] = bool(data[bps + 10] & 0x80)
                            elif btyp == b"pasp":
                                t["pasp"] = list(struct.unpack_from(">II", data, bps))
                    break
        st = _find(data, ps, pe, [b"mdia", b"minf", b"stbl", b"stts"])
        if st and timescale:
            cnt = struct.unpack_from(">I", data, st[0] + 4)[0]
            nsamp = ticks = 0
            for k in range(min(cnt, (st[1] - st[0] - 8) // 8)):
                c, delta = struct.unpack_from(">II", data, st[0] + 8 + k * 8)
                nsamp += c
                ticks += c * delta
            t["sampleCount"] = nsamp
            if ticks:
                # 전체 평균 — VFR 도 대표값이 나온다(첫 엔트리만 보면 왜곡된다)
                t["fps"] = round(nsamp * timescale / ticks, 3)
        info["tracks"].append(t)
    return info


def find_embedded_mp4(blob):
    """blob 안의 `....ftyp` 위치 목록 (박스 크기가 그럴듯한 것만)."""
    out = []
    for m in re.finditer(b"ftyp", blob):
        p = m.start() - 4
        if p < 0:
            continue
        size = struct.unpack_from(">I", blob, p)[0]
        if 8 <= size <= 64 and p + size <= len(blob):
            out.append(p)
    return out


def parse_pkg(data):
    """measure_corpus.py 와 같은 규약."""
    n, p = len(data), 0

    def i32():
        nonlocal p
        v = struct.unpack_from("<i", data, p)[0]
        p += 4
        return v

    vlen = i32()
    if vlen < 0 or p + vlen > n:
        raise ValueError("bad vlen")
    p += vlen
    count = i32()
    if count < 0 or count > 65536:
        raise ValueError("bad count")
    for _ in range(count):
        nlen = i32()
        if nlen < 0 or p + nlen > n:
            raise ValueError("bad nlen")
        p += nlen
        i32()
        i32()
    return p


# ------------------------------------------------------------------- 코퍼스

def scan_corpus():
    vid = {
        "projects": 0, "byExt": collections.Counter(), "brand": collections.Counter(),
        "videoCodec": collections.Counter(), "audioCodec": collections.Counter(),
        "colrType": collections.Counter(), "colrTriplet": collections.Counter(),
        "colrFullRange": collections.Counter(), "fps": collections.Counter(),
        "resolution": collections.Counter(), "depth": collections.Counter(),
        "trackCount": collections.Counter(), "parseErrors": collections.Counter(),
    }
    outliers = {"nonAvc1": [], "nonBt709": [], "noAudioTrack": 0}
    emb = {
        "scenePkgs": 0, "pkgsWithMp4": 0, "embeddedMp4": 0,
        "videoCodec": collections.Counter(), "audioCodec": collections.Counter(),
        "colrType": collections.Counter(), "colrTriplet": collections.Counter(),
        "brand": collections.Counter(), "resolution": collections.Counter(),
        "fps": collections.Counter(),
    }

    def absorb(bucket, info):
        bucket["brand"][info.get("brand") or "(없음)"] += 1
        v = [t for t in info["tracks"] if t.get("handler") == "vide"]
        a = [t for t in info["tracks"] if t.get("handler") == "soun"]
        if "trackCount" in bucket:
            bucket["trackCount"][f"v{len(v)}a{len(a)}"] += 1
        for t in v:
            bucket["videoCodec"][t.get("codec") or "(없음)"] += 1
            bucket["colrType"][t.get("colrType") or "(colr 없음)"] += 1
            if "colrPrimaries" in t:
                bucket["colrTriplet"][
                    f"{t['colrPrimaries']}/{t['colrTransfer']}/{t['colrMatrix']}"] += 1
            if "colrFullRange" in bucket:
                bucket["colrFullRange"][str(t.get("colrFullRange", "(nclx 아님)"))] += 1
            if "width" in t:
                bucket["resolution"][f"{t['width']}x{t['height']}"] += 1
            if "depth" in bucket and "depth" in t:
                bucket["depth"][t["depth"]] += 1
            if t.get("fps"):
                bucket["fps"][round(t["fps"], 2)] += 1
        for t in a:
            bucket["audioCodec"][t.get("codec") or "(없음)"] += 1

    for wid in sorted(os.listdir(WS)):
        d = os.path.join(WS, wid)
        if not os.path.isdir(d):
            continue
        pj = os.path.join(d, "project.json")
        if os.path.exists(pj):
            try:
                with open(pj, encoding="utf-8-sig") as fh:
                    j = json.load(fh)
            except Exception as e:
                j = None
                vid["parseErrors"][f"project.json:{type(e).__name__}"] += 1
            if j and (j.get("type") or "").strip().lower() == "video":
                vid["projects"] += 1
                f = j.get("file") or ""
                vid["byExt"][os.path.splitext(f)[1].lower() or "(없음)"] += 1
                path = os.path.join(d, f.replace("/", os.sep))
                if os.path.exists(path):
                    try:
                        with open(path, "rb") as fh:
                            info = parse_mp4(fh.read())
                        absorb(vid, info)
                        for t in info["tracks"]:
                            if t.get("handler") != "vide":
                                continue
                            if t.get("codec") != "avc1":
                                outliers["nonAvc1"].append(
                                    {"id": wid, "codec": t.get("codec"),
                                     "colr": t.get("colrType"),
                                     "size": f"{t.get('width')}x{t.get('height')}"})
                            if (t.get("colrTransfer") not in (None, 1)
                                    or t.get("colrPrimaries") not in (None, 1)
                                    or t.get("colrMatrix") not in (None, 1)):
                                outliers["nonBt709"].append(
                                    {"id": wid, "primaries": t.get("colrPrimaries"),
                                     "transfer": t.get("colrTransfer"),
                                     "matrix": t.get("colrMatrix")})
                        if not any(t.get("handler") == "soun" for t in info["tracks"]):
                            outliers["noAudioTrack"] += 1
                    except Exception as e:
                        vid["parseErrors"][f"mp4:{type(e).__name__}"] += 1
                else:
                    vid["parseErrors"]["file 없음"] += 1

        pk = os.path.join(d, "scene.pkg")
        if os.path.exists(pk):
            emb["scenePkgs"] += 1
            with open(pk, "rb") as fh:
                blob = fh.read()
            hits = find_embedded_mp4(blob)
            if hits:
                emb["pkgsWithMp4"] += 1
            for p in hits:
                emb["embeddedMp4"] += 1
                try:
                    absorb(emb, parse_mp4(blob, p, len(blob)))
                except Exception:
                    pass
    outliers['nonBt709'].sort(key=lambda x: x['id'])
    outliers['nonAvc1'].sort(key=lambda x: x['id'])
    return vid, emb, outliers


def as_dict(c):
    return dict(c.most_common()) if isinstance(c, collections.Counter) else c


# ---------------------------------------------------------------------- 본체

def main():
    exp = pe_exports(MEDIAEXT)
    names = [n for _, n in exp if n]
    openal = [n for n in names if n.startswith(("al", "alc", "alsoft"))]
    we_only = [n for n in names if n not in openal]
    me_static, me_delay = pe_imports(MEDIAEXT)

    wp = open(WALLPAPER, "rb").read()
    wbase, wsecs, wdirs = pe_sections(wp)
    wp_static, wp_delay = pe_imports(WALLPAPER)
    mf_static = {k: v for k, v in wp_static.items()
                 if k.lower().startswith(("mf", "d3d11", "dwrite", "ole32"))}
    present = scan_guids(wp, wbase, wsecs, GUIDS)
    absent = [n for n in sorted(GUIDS_ABSENT) if n not in scan_guids(wp, wbase, wsecs, GUIDS_ABSENT)]
    anchors_ok, anchors_bad = check_anchors(wp, wbase, wsecs)
    floats_ok, floats_bad = check_floats(wp, wbase, wsecs)
    cfg = find_strings(wp, wbase, wsecs, [
        "videoframework", "videoreadmode", "videoloopmode", "videoaudiooutput",
        "videohardwareacceleration", "videomfstutterhack", "webmframework", "videosequence",
        "mfEngine", "mfEngine.muted", "dshow.lav.vmr9", "fromdisk",
        "assets/scenes/videoplayer/scene.json", "videotex", "getVideoTexture",
        "Media Foundation", "Media Foundation (muted)", "DirectShow, LAV, VMR9",
        "Video stutter detected", "D3D11_CREATE_DEVICE_VIDEO_SUPPORT failed.",
        ".mp4", ".wmv", ".avi", ".m4v", ".mov", ".webm", ".mkv",
    ])

    vid, emb, outliers = scan_corpus()

    bin_ev = specfmt.ev("binary", "wallpaper64.exe / bin/mediaextensions64.dll 직접 파싱 "
                                  "(export·import·GUID·명령바이트)")
    corpus_ev = specfmt.ev("corpus", f"워크샵 코퍼스 video {vid['projects']}종 + "
                                     f"scene.pkg {emb['scenePkgs']}개 ISO BMFF 직접 파싱")
    script_ev = specfmt.ev("script", "scripts/spec/measure_media.py")

    def anchor_ev(*vas):
        return [specfmt.ev("binary", f"wallpaper64.exe {v}: {ANCHORS[int(v, 16)][0]}",
                           ANCHORS[int(v, 16)][1]) for v in vas]

    entries = [
        # ---- 1. mediaextensions64.dll 의 정체
        specfmt.entry("engine.media.mediaextensions.isOpenAL", {
            "claim": "bin/mediaextensions64.dll 은 비디오와 무관한 오디오 DLL 이다",
            "exportCount": len(exp),
            "openALExports": len(openal),
            "weSpecificExports": we_only,
            "imports": {k: len(v) for k, v in me_static.items()},
            "mediaFoundationImports": 0,
            "note": "export 177 중 175 가 OpenAL Soft(al*/alc*/alsoft*). "
                    "임포트는 KERNEL32/WINMM/SHELL32/ole32 뿐 — MF·DShow·D3D 가 하나도 없다.",
        }, "확정", [bin_ev, script_ev]),
        specfmt.entry("engine.media.mediaextensions.weExports", {
            "CreateMediaExtensions": "ordinal 1 — 유일한 팩토리 진입점",
            "WallpaperEngineMedaExtensionVersion": "ordinal 2 — 원문 오타(Meda) 그대로",
            "alsoft_get_version": "OpenAL Soft 버전 질의 — 이 DLL 이 openal-soft 임을 자증한다",
            "signatures": {
                "openAL175": "OpenAL 1.1 + ALC + *SOFT 확장의 공개 ABI 를 그대로 따른다. "
                             "시그니처는 WE 고유가 아니라 규격의 것이다 — 재구현은 ABI 를 복원할 게 아니라 "
                             "동등한 오디오 스택(macOS: AVAudioEngine 등)을 놓으면 된다.",
                "CreateMediaExtensions":
                    "복원 2026-08-21. `void* CreateMediaExtensions(void)` — 인자를 하나도 읽지 않는다"
                    "(0x180002808 의 `mov ecx, 0x48` 이 rcx 를 즉시 덮고 rdx/r8/r9 는 끝까지 안 읽는다). "
                    "0x48바이트를 할당해 vptr = 0x1802dcc70 을 심고 나머지를 MSVC `std::unordered_map` 의 "
                    "빈 상태로 채운 뒤 그 포인터를 낸다: max_load_factor 1.0f @+0x08, 리스트 센티넬 @+0x10, "
                    "버킷 벡터 @+0x20..+0x30(원소 16), _Mask=7 @+0x38, _Maxidx=8 @+0x40. "
                    "호출부도 인자를 안 싣는다 — wallpaper64.exe 0x1400c4bca 가 `call rax` 하나뿐이다.",
                "WallpaperEngineMedaExtensionVersion":
                    "복원 2026-08-21. **함수가 아니라 데이터 export 다.** export RVA 0x3119e0 은 .text 범위 "
                    "밖 .data 이고, .reloc 에 그 RVA 의 DIR64(type 10) 항목이 있다 — 곧 재배치되는 포인터 "
                    "변수다. 값은 .rdata 0x1802dcbd0 의 ASCII `WallpaperEngineMediaExtensions0002`. "
                    "곧 시그니처는 `const char* WallpaperEngineMedaExtensionVersion` 이고 호출 대상이 아니다.",
            },
        }, "확정", [bin_ev, script_ev]),

        # ---- 2. 비디오 경로는 wallpaper64.exe 안에 있다
        specfmt.entry("engine.media.video.host", {
            "binary": "wallpaper64.exe",
            "staticImports": {k: v for k, v in wp_static.items() if k.lower().startswith(("mf", "d3d11"))},
            "delayImports": wp_delay,
            "note": "MFReadWrite 는 정적, MF.dll/MFPlat.DLL 은 지연로드. "
                    "지연로드 실패 시 'install the latest Media Feature Pack' 메시지박스를 띄운다.",
        }, "확정", [bin_ev, script_ev]),
        specfmt.entry("engine.media.video.frameworks", {
            "settingKey": "general/user/videoframework",
            "default": "mfEngine",
            "values": {
                "mfEngine": {
                    "uiLabel": "Scene DX11 (HDR Support)",
                    "impl": "IMFMediaEngine/IMFMediaEngineEx + MFCreateDXGIDeviceManager(D3D11)",
                    "render": "assets/scenes/videoplayer/scene.json 씬의 usertexture 'videotex' 로 합성",
                },
                "mf": {
                    "uiLabel": "Windows DX9",
                    "impl": "MFCreateMediaSession + MFCreateTopology + MFCreateVideoRendererActivate(EVR)",
                },
                "dshow.lav.vmr9": {
                    "uiLabel": "DirectShow (LAV Decoder)",
                    "impl": "CLSID_FilterGraph + 'LAV Splitter Source' + 'LAV Video Decoder' + CLSID_DSoundRender",
                },
            },
            "otherKeys": {
                "videoreadmode": ["fromdisk(기본)", "frommemory"],
                "videoloopmode": ["default(기본)", "syncclock", "synctopo"],
                "videoaudiooutput": "bool(기본 true)",
                "videohardwareacceleration": "bool(기본 true)",
                "videomfstutterhack": "bool(기본 false) — UI 조건상 videoframework=='mf' 일 때만 노출",
                "webmframework": ["cef", "native"],
            },
        }, "확정", [
            bin_ev,
            specfmt.ev("file", os.path.join(WE, "ui/dist/scripts/scripts.js"),
                       "videoFrameworkOptions/videoReadOptions/videoLoopOptions/webmFrameworkOptions"),
            specfmt.ev("file", os.path.join(WE, "locale/ui_en-us.json"),
                       "ui_settings_video_framework_prefer_* 라벨"),
            specfmt.ev("file", os.path.join(WE, "config.json"), "실설치본의 현재 값"),
        ]),
        specfmt.entry("engine.media.video.containerAllowlist", {
            "extensions": [".mp4", ".wmv", ".avi", ".m4v", ".mov", ".webm", ".mkv"],
            "count": 7,
            "where": "wallpaper64.exe 0x14016ff50 의 함수-지역 static unordered_set 초기화",
            "note": "확장자 허용목록은 WE 가 고정한다. 코덱은 고정하지 않는다 — "
                    "실제 디코드 가능 여부는 OS 의 MF/LAV 스택에 위임된다.",
        }, "확정", [specfmt.ev("binary",
                              "wallpaper64.exe 0x140170169..0x1401701e0 — .mp4 .wmv .avi .m4v .mov .webm .mkv 를 "
                              "차례로 적재하고 버킷 수 8/마스크 7 로 세트를 만든다"), script_ev]),

        # ---- 3. 색공간
        specfmt.entry("engine.media.color.delegation", {
            "claim": "WE 는 YUV→RGB 행렬도 full/limited range 도 스스로 정하지 않는다",
            "referencedColorAttributes": ["MF_MT_TRANSFER_FUNCTION", "MF_MT_VIDEO_PRIMARIES"],
            "absentColorAttributes": ["MF_MT_YUV_MATRIX", "MF_MT_VIDEO_NOMINAL_RANGE",
                                      "MF_MT_VIDEO_CHROMA_SITING"],
            "absentSubtypes": ["MFVideoFormat_NV12", "MFVideoFormat_ARGB32", "MFVideoFormat_RGB32"],
            "conversionPoint": "IMFMediaEngineEx::TransferVideoFrame — MF 내부가 변환한다",
            "outputFormatRaw": 87,
            "consequence": "colr 박스가 없을 때의 기본값은 WE 쪽 상수가 아니다. "
                           "Media Foundation 의 기본 추정(해상도 기반 BT.601/BT.709, limited range)이 그대로 적용된다.",
        }, "확정", [
            specfmt.ev("binary", "wallpaper64.exe .rdata GUID 전수 스캔 — "
                                 "MF_MT_YUV_MATRIX/MF_MT_VIDEO_NOMINAL_RANGE 바이트열 부재"),
            *anchor_ev("0x1400f239d"), script_ev,
        ]),
        specfmt.entry("engine.media.color.hdrProbe", {
            "where": "wallpaper64.exe 0x1400f2750 (짝: 0x1400f2952)",
            "source": "MFCreateSourceReaderFromURL 로 연 IMFSourceReader 의 "
                      "GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM=0xFFFFFFFC)",
            "reads": {
                "MF_MT_FRAME_SIZE": "GetUINT64 — 상위 32비트=width, 하위 32비트=height",
                "MF_MT_FRAME_RATE": "GetUINT64 — fps = (상위)/(하위), float 로 저장",
                "MF_MT_TRANSFER_FUNCTION": "GetUINT32 — 15 → 내부값 2, 16 → 내부값 1, 그 외 무시",
                "MF_MT_VIDEO_PRIMARIES": "GetUINT32 — 9 일 때만 플래그 1",
            },
            "acceptedTransferValues": [15, 16],
            "acceptedPrimariesValue": 9,
            "byteStreamVariant": "0x1400f2952 는 같은 4개 속성을 읽는 짝 함수이고 "
                                 "MFCreateSourceReaderFromByteStream 을 쓴다 "
                                 "(videoreadmode=frommemory 에 대응하는 것으로 보인다)",
            "callSiteCounts": {"MFCreateSourceReaderFromURL": 1,
                               "MFCreateSourceReaderFromByteStream": 1},
            "note": "이 프로브가 읽는 색 속성은 이 둘뿐이다. 행렬·레인지·크로마사이팅은 읽지 않는다. "
                    "IMFSourceReader 는 두 곳 모두 프로브 후 즉시 Release 된다 — 디코드에 쓰이지 않는다.",
        }, "확정", [*anchor_ev("0x1400f2867", "0x1400f286c", "0x1400f28a0"),
                   specfmt.ev("binary", "wallpaper64.exe IAT 0x140426690/0x140426698 참조 전수 — "
                                        "각각 호출 지점 1곳(0x14012009f, 0x1400f2b89). "
                                        # 아래 한 줄은 툼스톤이다. 옛 주소를 지우면 다음 사람이 같은 오류를
                                        # 다시 만들므로 남기되, va_citations.py 가 정정 기록으로 보게 마커를 단다.
                                        "[VA-정정] 종전 값 0x1401200a1 · 0x1400f2b8b 은 명령 주소가 아니라 `FF 15 disp32` 의 disp32 필드 위치였다(각각 +2). "
                                        "xref 스캔 결과를 그대로 옮긴 것 — scripts/re/va_citations.py 가 잡는 바로 그 부류다"),
                   script_ev]),

        # ---- 4. mfEngine 파이프라인
        specfmt.entry("engine.media.mfEngine.pipeline", {
            "mfStartup": {"version": "0x20070", "flags": "MFSTARTUP_NOSOCKET(1)"},
            "d3d11CreateDevice": {
                "driverType": 1,
                "flags": "0x800",
                "featureLevels": ["0xb100", "0xb000", "0xa100", "0xa000"],
                "sdkVersion": 7,
            },
            "attributes": {
                "MF_MEDIA_ENGINE_CALLBACK": "IMFMediaEngineNotify 구현체(SetUnknown)",
                "MF_MEDIA_ENGINE_DXGI_MANAGER": "MFCreateDXGIDeviceManager + ResetDevice(D3D11)",
                "MF_MEDIA_ENGINE_VIDEO_OUTPUT_FORMAT": 87,
                "MF_MEDIA_ENGINE_EXTENSION": "오디오 출력이 꺼졌을 때만 설치",
            },
            "createInstanceFlags": {"base": "0x12", "plusWhenAudioDisabled": "0x4"},
            "d3d11Multithread": "ID3D11Multithread 를 QI 해 SetMultithreadProtected(TRUE)",
            "sharedSurface": "IDXGIKeyedMutex 로 보호되는 공유 텍스처. "
                             "AcquireSync(key=0, 1000ms) → TransferVideoFrame → ReleaseSync(key=0)",
        }, "확정", [*anchor_ev("0x1400f2245", "0x1400f2025", "0x1400f239d", "0x1400f2415",
                              "0x1400f2407", "0x1400f350e"), script_ev]),
        specfmt.entry("engine.media.mfEngine.framePacing", {
            "model": "풀(pull) 기반 — WE 는 프레임 타이머를 돌리지 않는다. "
                     "엔진에 '새 프레임 있냐'를 묻고 있을 때만 텍스처로 옮긴다",
            "measuredSites": {
                "0x1400f3774": [
                    "IMFMediaEngine +0x160 호출, 반환값을 r14d 에 보관",
                    "+0xA0 호출 결과가 0 이 아니면 0x1400f38c0 으로 분기(그 프레임 처리 종료)",
                    "+0xD8 호출 결과가 0 이 아니면 같은 곳으로 분기",
                ],
                "0x1400f34ac": [
                    "IDXGIKeyedMutex +0x40 (key=0, 1000ms)",
                    "IMFMediaEngineEx +0x158 — (dst 서페이스, srcRect 포인터, "
                    "dstRect{0,0,w,h}, 경계색 BGRA(0,0,0,0xFF))",
                    "IDXGIKeyedMutex +0x48 (key=0)",
                ],
            },
            "caution": "두 지점은 서로 다른 .pdata 청크다. 위 두 블록이 한 프레임 안에서 "
                       "이 순서로 이어진다는 것은 추론이며 직접 관측하지 않았다.",
        }, "확정", [*anchor_ev("0x1400f377f", "0x1400f378f", "0x1400f37a9",
                              "0x1400f353f", "0x1400f350e", "0x1400f34ff"), script_ev]),
        specfmt.entry("engine.media.mfEngine.stallWatchdog", {
            "where": "wallpaper64.exe 0x1400f37b7-0x1400f38c0",
            "algorithm": [
                "프레임 델타 dt 를 구해 0.1초로 상한(minss)",
                "IMFMediaEngine +0x80 → 현재 재생시각 t (double)",
                "백오프 타이머 b>0 이면 b = max(b-dt, 0) 후 Sleep(1)",
                "b < 5.0 이고 t > 0 이고 t 가 직전 프레임 값과 **비트 단위로 동일**하면 정지 후보",
                "정지 누적시간 += dt. 0.2초를 넘으면 복구: "
                "+0x108 → +0x88(0.0) → Sleep(100) → +0x88(t) → +0x100",
                "복구 후 b = 4*b + 10 (지수적 백오프), 정지 누적 리셋",
            ],
            "constants": {
                "frameDeltaClampSec": 0.1,
                "stallThresholdSec": 0.2,
                "backoffGateSec": 5.0,
                "backoffGrow": "next = 4*cur + 10",
                "recoverySleepMs": 100,
            },
            "note": "Media Session 경로의 videomfstutterhack 와 목적은 같으나 별개 코드다. "
                    "이쪽은 설정 스위치가 없다 — 항상 동작한다.",
        }, "확정", [*anchor_ev("0x1400f37d1", "0x1400f37dc", "0x1400f3824", "0x1400f3836",
                              "0x1400f384b", "0x1400f385b", "0x1400f3861", "0x1400f3883"),
                   script_ev]),
        specfmt.entry("engine.media.floatAnchors", floats_ok, "확정", [bin_ev, script_ev]),
        specfmt.entry("engine.media.mfEngine.videotex", {
            "scene": "assets/scenes/videoplayer/scene.json",
            "model": "models/background.json — autosize, nopadding",
            "material": "materials/background.json — shader 'genericimage', "
                        "usertextures [{name:'videotex', keepaspect:true}]",
            "shaderDoesNoColorConversion": "genericimage.frag 은 texSample2D 후 "
                                           "밝기/알파/감마만 적용한다. YUV 변환 코드가 없다.",
            "wiring": "0x140120050 이 씬의 wproperties.videotex.value 에 비디오 파일 경로를 넣는다",
            "sourceReaderRole": "MFCreateSourceReaderFromURL 은 이 지점에서 메타데이터 프로브 전용으로 "
                                "쓰이고 즉시 Release 된다 — 디코드 경로가 아니다",
        }, "확정", [
            specfmt.ev("binary", "wallpaper64.exe IAT 0x140426690 참조 전수 — 호출 지점 1곳",
                       "MFCreateSourceReaderFromURL 이 재생 경로에 쓰였다면 호출 지점이 더 있어야 한다"),
            specfmt.ev("asset", os.path.join(WE, "assets/scenes/videoplayer/materials/background.json")),
            specfmt.ev("asset", os.path.join(WE, "assets/shaders/genericimage.frag")),
            *anchor_ev("0x14012009f"), script_ev,
        ]),

        # ---- 5. 루프 / 스터터
        specfmt.entry("engine.media.loop", {
            "mfEngine": "생성 직후 +0xE8(인자 0)과 +0xF8(인자 1)을 연달아 호출한다. "
                        "루프는 엔진 내부 기능이고 WE 는 seek 로 감지 않는다.",
            "settingKey": "videoloopmode",
            "values": ["default", "syncclock", "synctopo"],
            "uiLabels": ["Default", "Sync clock", "Sync topology"],
        }, "확정", [*anchor_ev("0x1400f243b", "0x1400f2443", "0x1400f244d", "0x1400f2455"), script_ev]),
        specfmt.entry("engine.media.mfSession.stutterHack", {
            "settingKey": "videomfstutterhack",
            "default": False,
            "where": "wallpaper64.exe 0x140121830",
            "algorithm": [
                "IMFClock::GetState(0,&s) 가 1(RUNNING)인지 확인",
                "IMFClock::GetCorrelatedTime(0,&t,&sys) → t/1e7 초",
                "직전 폴링값과 **정확히 같으면** 시계가 멈춘 것으로 판정",
                "'Video stutter detected' 로그 → IMFMediaSession::Stop() → "
                "Start(NULL, VT_I8 max(저장위치, 현재시각))",
                "복구 후 4회 폴링을 건너뛴다. 미재생 상태에서는 직전값을 -1.0f 로 리셋",
            ],
            "scope": "Media Session(EVR) 경로 전용 — Media Engine 경로에는 이 코드가 없다",
        }, "확정", [
            specfmt.ev("binary", "wallpaper64.exe 0x140121830-0x140121974"),
            *anchor_ev("0x1401218b9"), script_ev,
        ]),

        # ---- 6. 오디오
        specfmt.entry("engine.media.audio.paths", {
            "sceneAudio": {
                "impl": "OpenAL Soft (bin/mediaextensions64.dll 에 정적 링크)",
                "entry": "CreateMediaExtensions — LoadLibraryExW(L\"mediaextensions64.dll\", NULL, 0x1000) "
                         "@0x1400c4b7f 뒤 GetProcAddress @0x1400c4bbf. 전문은 "
                         "engine.media.mediaextensions.factory",
                "evidence": "alcOpenDevice/alSourcePlay/alBufferData 등 175개 export",
            },
            "videoAudio": {
                "impl": "Media Engine 내부 오디오 렌더러",
                "volume": "IMFMediaEngine +0x128 (double). 오디오 출력이 켜졌을 때만 호출",
                "mute": "오디오 출력이 꺼지면 CreateInstance dwFlags 에 0x4 를 더한다",
            },
            "mfSessionAudio": "MFCreateAudioRendererActivate + IMFAudioStreamVolume (mf 경로)",
            "dshowAudio": "CLSID_DSoundRender + IID_IBasicAudio (dshow.lav.vmr9 경로)",
            "settingKey": "videoaudiooutput",
        }, "확정", [bin_ev, script_ev]),

        # ---- 6b. mediaextensions64.dll 팩토리 (2026-08-21 신규)
        specfmt.entry("engine.media.mediaextensions.factory", {
            "claim": "wallpaper64.exe 는 mediaextensions64.dll 을 지연 로드해 확장 객체를 하나 만들고, "
                     "그 객체는 이름으로 참조되는 리프카운트 바이트-블롭 캐시다",
            "vaConvention": "0x140… 은 wallpaper64.exe(imagebase 0x140000000), 0x180… 은 "
                            "bin/mediaextensions64.dll(imagebase 0x180000000) 이다. 두 이미지의 베이스가 "
                            "다르지만 다음 사람이 엉뚱한 이미지에서 뜨지 않도록 명시한다(함정 11).",
            "loader": "0x1400c4a70–0x1400c4c44. 앞머리에 MSVC 매직-스태틱 짝(0x140290d80 / 0x140290ea0)이 "
                      "있어 로드는 프로세스당 한 번이다",
            "loadLibrary": "LoadLibraryExW(L\"mediaextensions64.dll\", NULL, 0x1000) @0x1400c4b7f. "
                           "**LoadLibraryW 가 아니다** — 이름 문자열은 UTF-16 로만 있고(0x140486490) "
                           "플래그 0x1000 이 붙는다. 모듈 핸들은 [this+0xb00] 에 캐시된다. 실패하면 "
                           "GetLastError 를 찍어 로그만 남긴다(0x1400c4b8d–0x1400c4ba4)",
            "getProcAddress": "GetProcAddress(h, \"CreateMediaExtensions\") @0x1400c4bbf — 이름 문자열 "
                              "0x140486500. NULL 이면 조용히 빠진다(0x1400c4bc8)",
            "call": "0x1400c4bca `call rax`. 인자를 싣는 명령이 앞에 없다 — 호출부와 피호출부가 둘 다 "
                    "arity 0 이다. 반환 포인터는 [this+0xb30]",
            "afterCreate": "생성 직후 vtbl+0x08 을 this 만으로 부른다(0x1400c4bde). 64비트 판에서 그 슬롯은 "
                           "0x180003484 = 명령 하나짜리 빈 함수다",
            "forward": "래퍼는 vtbl+0x18 로 꼬리점프한다(0x1400c4c11 `jmp [rax+0x18]`) — 자기 인자 "
                       "(rdx, r8, r9d) 를 그대로 넘긴다. 그 슬롯 0x1800034a0 은 이름을 키로 map 을 찾고, "
                       "없으면 {u32 refcount, void* bytes, u32 size} 0x18바이트를 만들어 (r8, r9d) 를 "
                       "memcpy 해 넣는다(0x1800035b4–0x1800035f3)",
            "release": "vtbl+0x20 = 0x180003a64. `--refcount` 가 0 이 되면 리스트를 훑어 그 항목을 지운다"
                       "(0x180003aa8–0x180003b40)",
            "nameScan": "설치본 6138파일 전수 바이트 스캔(ASCII·UTF-16LE 양쪽). CreateMediaExtensions 는 "
                        "wallpaper32.exe · wallpaper64.exe · bin/wallpaperui.exe 와 두 DLL 자신의 export "
                        "이름표에만 있다. WallpaperEngineMedaExtensionVersion 은 **두 DLL 자신 말고 "
                        "어디에도 없다** — 설치본 안에 소비자가 0 이다",
        }, "확정", [bin_ev, script_ev]),

        # ---- 6c. 프레임워크 플래그 워드의 소비 지점 (2026-08-21 신규)
        specfmt.entry("engine.media.video.frameworkGate", {
            "claim": "프레임워크 레지스트리의 플래그 워드 두 바이트가 각각 소비된다 — 하나는 MF 가용성 "
                     "게이트, 하나는 창 확장스타일 요구다",
            "registry": "전역 std::unordered_map<std::string, Record>. 매직-스태틱 가드 0x1404e9240, "
                        "_Hash 본체는 max_load_factor 1.0f @0x1404e9250 · 리스트 head @0x1404e9258 · "
                        "버킷 벡터 @0x1404e9268 · _Mask=7 @0x1404e9280 · _Maxidx=8 @0x1404e9288. 노드가 "
                        "{_Next,_Prev,key std::string(0x20),value} 라 value 는 노드+0x30 이다. "
                        "빌더는 0x1401014ce–0x1401017c8",
            "flagWord": "Record+0x08 의 u16. 빌더가 mfEngine 과 mfEngine.muted 에 0x0101"
                        "(0x140101527 · 0x1401015c5), mf 와 mf.muted 에 0x0001, dshow.lav.vmr9 에 "
                        "0x0000 을 심는다",
            "lowByte": "= 이 프레임워크는 Media Foundation 을 요구한다. 후보 루프가 노드+0x38"
                       "(= Record+0x08 의 하위 바이트)을 읽어, [player+0x17c] bit6 이 서 있으면 그 후보를 "
                       "통째로 건너뛴다 — 0x140100fed–0x140100ffe",
            "bit6": "= mfplat.dll 이 없다. 0x1400fe13f 의 LoadLibraryW(L\"mfplat.dll\") 이 NULL 을 내면 "
                    "0x1400fe15c 가 `or dword [rdi+0x17c], 0x40` 을 하고 "
                    "core_msgbox_media_feature_pack_missing 메시지박스를 띄운다",
            "highByte": "= 이 프레임워크는 창 확장스타일 비트21(0x00200000)을 요구한다. 0x140101195 가 "
                        "노드+0x39 를 읽어 0x1400ff350 에 넘기고, 그 함수는 "
                        "GetWindowLongW(hwnd, GWL_EXSTYLE) 의 (exstyle>>21)&1 이 요구와 다르면 "
                        "DestroyWindow 로 창을 버리고 다시 만든다(0x1400ff384–0x1400ff3a6). 비트 이름 "
                        "해석은 engine.media.enumInterpretation 에 있다",
            "effect": "Media Feature Pack 이 없는 시스템에서는 폴백 사슬이 dshow.lav.vmr9 하나로 줄어든다. "
                      "engine.media.video.frameworks 의 순서표가 실제로 걸러지는 자리가 여기다",
        }, "확정", [bin_ev, script_ev]),

        # ---- 6d. 설정 → 백엔드 가상함수 (2026-08-21 신규)
        specfmt.entry("engine.media.video.backendVtable", {
            "claim": "설정 변경은 변경 마스크를 통해 백엔드([player+0x160])의 가상 함수로 착지한다",
            "applyFunction": "0x140100720–0x1401008da. 두 번째 인자(edx→dil)가 변경 마스크다",
            "mask0x02": "볼륨. [player+9] 가 서 있으면 0.0f, 아니면 [player+0x174]. 결과를 [player+0x170] 에 "
                        "적고 vtbl+0x30 에 넘긴다 — 0x140100834–0x14010085f",
            "mask0x04": "하드웨어 디코딩 게이트. ([player+0x17c]>>4)&1 을 vtbl+0x70 에 넘긴다 — "
                        "0x1401007e3–0x1401007ff. **반전 저장이라 1 이 '가속 끔' 이다**",
            "mask0x08": "오디오 출력. ([player+0x17c]>>3)&1 을 vtbl+0x68 에 넘긴다 — "
                        "0x1401007c4–0x1401007e0",
            "mask0x10": "루프 모드. [player+0x198] 을 vtbl+0x58 에 넘긴다 — 0x140100802–0x140100818",
            "mask0x20": "리드 모드. [player+0x19c] 를 vtbl+0x60 에 넘긴다 — 0x14010081b–0x140100831",
            "mask0x100": "vtbl+0x48 을 인자 없이 부른다 — 0x140100862–0x140100872",
            "mask0xc0": "일시정지·음소거 변경. 볼륨 램프 타이머를 켠다 — engine.media.audio.volumeFade 참조",
            "startupOrder": "플레이어를 처음 만들 때도 같은 세 슬롯을 같은 순서로 부른다 — "
                            "vtbl+0x60 → vtbl+0x68 → vtbl+0x70, 0x140101252–0x140101287",
            "note": "videohardwareacceleration 설정이 실제로 소비되는 자리다. 종전 정본은 저장 위치"
                    "([player+0x17c] bit4, 반전)까지만 갖고 있었고 소비 지점이 없었다",
        }, "확정", [bin_ev, script_ev]),

        # ---- 6e. 볼륨 램프 (2026-08-21 신규)
        specfmt.entry("engine.media.audio.volumeFade", {
            "claim": "비디오 월페이퍼 볼륨은 즉시 바뀌지 않는다 — 25ms 타이머로 선형 램프하고, "
                     "오르내림이 비대칭이다",
            "timer": "SetTimer(hwnd, 0x65, 25, NULL) — id 0x140100891, 주기 0x140100896(0x19 = 25ms), "
                     "호출 0x14010089c. 켜면서 [player+0x17c] |= 2 로 '램프 중' 을 표시한다(0x1401008a2). "
                     "이미 bit1 이 서 있으면 다시 켜지 않는다(0x14010087b–0x140100885)",
            "handler": "VideoWallpaper 창 프로시저 0x140101c50–0x140102248 의 WM_TIMER 팔. 램프 산술은 "
                       "0x140102092–0x140102181",
            "goal": "muted([player+9]) 이거나 paused([player+8]) 면 0.0f, 아니면 사용자 볼륨 "
                    "[player+0x174] — 0x1401020ba–0x1401020c6",
            "fadeOutStep": "매 틱 `cur -= target*0.03f + 0.02f` — 0x1401020ed(0.03f @0x140492634) · "
                           "0x1401020f5(0.02f @0x14049262c) · 0x1401020fd",
            "fadeInStep": "매 틱 `cur += target*0.01f + 0.01f` — 0x140102106(0.01f @0x140492620) · "
                          "0x14010210e · 0x140102112 · 0x140102116",
            "snapCases": "사용자 볼륨이 정확히 0 이거나 오디오 출력이 꺼져 있으면(= [player+0x17c] bit3 이 0) "
                         "램프 없이 목표로 바로 간다 — 0x140102092–0x1401020b4 가 그 판정을 만들고 "
                         "0x1401020de 가 분기한다",
            "apply": "매 틱 [player+0x170] 에 현재값을 적고 백엔드 vtbl+0x30 에 넘긴다 — 목표 도달이면 "
                     "0x140102129, 아니면 0x140102170",
            "completion": "도달하면 KillTimer(hwnd, 0x65) 하고 bit1 을 지운다 — 0x140102156–0x140102164. "
                          "**일시정지는 램프가 끝난 뒤에 걸린다** — [player+8] 이 서 있으면 백엔드 "
                          "vtbl+0x10 을 먼저 부른다(0x14010213a–0x14010214a). 곧 정지는 소리를 끊는 게 "
                          "아니라 fade-out 이다",
            "setters": "일시정지·음소거는 둘 다 가상 함수다. setPaused 0x1400fe970 ([this+8] 에 저장 → "
                       "마스크 0x80), setMuted 0x1400fe9b0 ([this+9] 에 저장 → 마스크 0x40). 각각 IsWindow "
                       "를 확인한 뒤 0x140100720 으로 꼬리점프한다. VideoWallpaper vtable 슬롯은 .rdata "
                       "0x140488998 과 0x1404889a0 이다",
            "derived": "target=1.0 에서 fade-out 은 틱당 0.05 → 20틱 = 500ms, fade-in 은 틱당 0.02 → "
                       "50틱 = 1250ms. **내려가는 쪽이 2.5배 빠르다**",
        }, "확정", [bin_ev, script_ev]),

        # ---- 7. GUID 표 (재현 고정점)
        specfmt.entry("engine.media.guids.present", present, "확정", [bin_ev, script_ev]),
        specfmt.entry("engine.media.guids.absent", {
            "note": "wallpaper64.exe 에 바이트열이 존재하지 않는 GUID. 부재가 곧 결론이다.",
            "names": absent,
        }, "확정", [bin_ev, script_ev]),
        specfmt.entry("engine.media.byteAnchors", anchors_ok, "확정", [bin_ev, script_ev]),
        specfmt.entry("engine.media.stringAnchors", cfg, "확정", [bin_ev, script_ev]),

        # ---- 8. 코퍼스 실측
        specfmt.entry("corpus.video.projects", {
            "count": vid["projects"],
            "byExtension": as_dict(vid["byExt"]),
            "parseErrors": as_dict(vid["parseErrors"]),
        }, "확정", [corpus_ev, script_ev]),
        specfmt.entry("corpus.video.codecs", {
            "ftypBrand": as_dict(vid["brand"]),
            "videoSampleEntry": as_dict(vid["videoCodec"]),
            "audioSampleEntry": as_dict(vid["audioCodec"]),
            "trackShape": as_dict(vid["trackCount"]),
        }, "확정", [corpus_ev, script_ev]),
        specfmt.entry("corpus.video.colr", {
            "colrBox": as_dict(vid["colrType"]),
            "primariesTransferMatrix": as_dict(vid["colrTriplet"]),
            "fullRangeFlag": as_dict(vid["colrFullRange"]),
            "bitDepthField": as_dict(vid["depth"]),
        }, "확정", [corpus_ev, script_ev]),
        specfmt.entry("corpus.video.geometry", {
            "resolution": as_dict(vid["resolution"]),
            "fps": as_dict(vid["fps"]),
        }, "확정", [corpus_ev, script_ev]),
        specfmt.entry("engine.media.color.corpusImplication", {
            "claim": "colr 박스가 없는 파일이 다수이므로 '기본값'이 실제 화면을 지배한다",
            "videoProjectsWithoutColr": vid["colrType"].get("(colr 없음)", 0),
            "videoProjectsTotal": vid["projects"],
            "nclxFullRangeTrue": vid["colrFullRange"].get("True", 0),
            "sceneEmbeddedWithoutColr": emb["colrType"].get("(colr 없음)", 0),
            "sceneEmbeddedTotal": emb["embeddedMp4"],
            "consequence": "WE 는 이 기본값을 코드에 갖고 있지 않다. "
                           "따라서 재구현은 'WE 와 같은 상수'를 베낄 수 없고, "
                           "각 플랫폼 미디어 스택의 기본 추정에 동일하게 위임해야 화면이 맞는다.",
            "observedFullRange": "코퍼스의 nclx 파일 전부 full_range_flag=0(limited). "
                                 "full range 표본이 0개라 full range 경로는 코퍼스로 검증할 수 없다.",
        }, "확정", [corpus_ev,
                   specfmt.ev("binary", "wallpaper64.exe 에 MF_MT_VIDEO_NOMINAL_RANGE / "
                                        "MF_MT_YUV_MATRIX 바이트열 부재"),
                   script_ev]),
        specfmt.entry("corpus.video.outliers", {
            "note": "재구현이 실제로 걸려 넘어지는 표본. id 는 워크샵 아이템 id 다.",
            "nonAvc1": outliers["nonAvc1"],
            "nonBt709": outliers["nonBt709"],
            "nonBt709Criterion": "colr 삼중항 중 하나라도 1(BT.709) 이 아닌 표본. "
                                 "primaries=0/2 는 예약/미지정이라 플랫폼마다 추정이 갈린다.",
            "nonAvc1Note": "3448728208 은 Waple VideoRenderer.swift 의 F600 주석이 이름을 짚은 바로 그 "
                           "표본이다 — WE 는 재생하고 AVFoundation 은 isPlayable=false 를 준다.",
            "noAudioTrackCount": outliers["noAudioTrack"],
        }, "확정", [corpus_ev, script_ev]),
        specfmt.entry("corpus.sceneEmbeddedMp4", {
            "method": "scene.pkg 원본 바이트에서 평문 `....ftyp` 박스 시그니처를 찾는다",
            "caveat": "**이 수치는 하한이다.** .tex mip 페이로드가 LZ4 로 압축된 비디오는 "
                      "평문 ftyp 가 없어 이 스캔에 잡히지 않는다 "
                      "(Waple TexImage.swift 가 lz4=true 인 video 페이로드 존재를 기록한다). "
                      "또 gifscene.pkg 는 스캔하지 않는다 — "
                      "그래서 scenePkgs 가 spec/corpus/inventory.json 의 162 와 다르다.",
            "scenePkgs": emb["scenePkgs"],
            "pkgsWithEmbeddedMp4": emb["pkgsWithMp4"],
            "embeddedMp4Count": emb["embeddedMp4"],
            "ftypBrand": as_dict(emb["brand"]),
            "videoSampleEntry": as_dict(emb["videoCodec"]),
            "audioSampleEntry": as_dict(emb["audioCodec"]),
            "colrBox": as_dict(emb["colrType"]),
            "primariesTransferMatrix": as_dict(emb["colrTriplet"]),
            "resolution": as_dict(emb["resolution"]),
            "fps": as_dict(emb["fps"]),
        }, "확정", [corpus_ev, script_ev]),

        # ---- 9. 해석(1차 근거가 헤더/문서인 것) — 보고
        specfmt.entry("engine.media.enumInterpretation", {
            "note": "아래 이름 대응은 Windows SDK 헤더 기준 해석이다. "
                    "이 머신에 SDK 가 없어 재현 검증하지 못했다. 수치와 분기 구조는 확정 항목에 있다.",
            "DXGI_FORMAT 87": "DXGI_FORMAT_B8G8R8A8_UNORM (dxgiformat.h)",
            "D3D11_CREATE_DEVICE 0x800": "D3D11_CREATE_DEVICE_VIDEO_SUPPORT",
            "D3D_FEATURE_LEVEL 0xb100/0xb000/0xa100/0xa000": "11_1 / 11_0 / 10_1 / 10_0",
            "MFVideoTransferFunction 15": "MFVideoTransFunc_2084 (PQ)",
            "MFVideoTransferFunction 16": "MFVideoTransFunc_HLG",
            "MFVideoPrimaries 9": "MFVideoPrimaries_BT2020",
            "MF_MEDIA_ENGINE_CREATEFLAGS 0x2/0x4/0x10":
                "WAITFORSTABLE_STATE / FORCEMUTE / DISABLE_LOCAL_PLUGINS",
            "IMFMediaEngine vtable +0xE8/+0xF8/+0x128/+0x158/+0x160":
                "SetAutoPlay / SetLoop / SetVolume / TransferVideoFrame(Ex) / OnVideoStreamTick",
            "IDXGIKeyedMutex vtable +0x40/+0x48": "AcquireSync / ReleaseSync",
            "IMFClock vtable +0x20/+0x30": "GetCorrelatedTime / GetState",
            "IMFMediaSession vtable +0x48/+0x58": "Start / Stop",
            "GWL_EXSTYLE bit21 (0x00200000)":
                "WS_EX_NOREDIRECTIONBITMAP (winuser.h) — DWM 리다이렉션 표면을 만들지 않는 창. "
                "engine.media.video.frameworkGate 의 highByte 가 요구하는 비트다. "
                "수치(비트 21)와 분기는 확정이고 이름만 해석이다.",
        }, "보고", [specfmt.ev("doc", "Windows SDK mfapi.h/mfmediaengine.h/dxgiformat.h/d3d11.h/dxgi.h"),
                   specfmt.ev("binary", "호출 지점의 명령 바이트는 engine.media.byteAnchors 에 있다")]),
        specfmt.entry("engine.media.unknowns", {
            "GUID 0x14042c380": "073CD2FC-6CF4-40B7-8859-E89552C841F8 — "
                                "EVR 관련 인터페이스로 보이나 식별하지 못했다",
            "MF_MEDIA_ENGINE_EXTENSION 의 용도":
                "오디오 출력이 꺼졌을 때만 설치된다는 사실은 확정. 왜 그런지는 미확인",
            "videoloopmode 의 syncclock/synctopo 동작": "열거값과 라벨만 확보. 코드 경로 미추적",
            "webmframework cef/native 의 분기": "열거값만 확보",
            "frommemory 모드": "MFCreateSourceReaderFromByteStream 호출 지점이 프로브 함수 "
                               "0x1400f2952 한 곳뿐이라, 이 모드가 프로브에만 영향을 주는지 "
                               "Media Engine 소스 로딩까지 바꾸는지 확정하지 못했다",
            "mediaextensions64.dll 의 WE 전용 export 2개 시그니처":
                "**해소 2026-08-21.** 두 시그니처를 복원했다 — "
                "engine.media.mediaextensions.weExports 의 signatures 와 "
                "engine.media.mediaextensions.factory 로 옮겼다. 키는 툼스톤으로 남긴다.",
            "이 엔트리를 확정으로 올릴 수 없는 이유":
                "이 엔트리는 '아직 모르는 것들' 의 목록이라 status 가 확정이 될 수 없다 — 남은 항목이 "
                "전부 해소되면 사라지는 엔트리이지, 자체가 확정될 대상이 아니다. 2026-08-21 기준 7개 중 "
                "1개(export 시그니처)만 해소됐고 videoloopmode 의 syncclock/synctopo · frommemory · "
                "webmframework 분기 · MF_MEDIA_ENGINE_EXTENSION 설치 조건 · GUID 0x14042c380 · "
                "IMFMediaEngine GUID 부재는 그대로다.",
            "IMFMediaEngine 인터페이스 GUID 부재": "IMFMediaEngineEx / IMFMediaEngineClassFactory / "
                                                "IMFMediaEngineNotify 는 있는데 IMFMediaEngine 은 없다. "
                                                "Ex 로만 QI 한다는 뜻으로 보이나 미확인",
        }, "추정", [specfmt.ev("recon", "wallpaper64.exe 정적 분석 범위 밖")]),
    ]

    specfmt.dump(specfmt.doc("scripts/spec/measure_media.py", entries),
                 os.path.join("spec", "engine", "media.json"))

    print(f"mediaextensions64.dll export {len(exp)}개 (OpenAL {len(openal)} / WE {len(we_only)}): {we_only}")
    print(f"  임포트: {[(k, len(v)) for k, v in me_static.items()]}")
    print(f"wallpaper64.exe MF 임포트: {mf_static}")
    print(f"  지연로드: {wp_delay}")
    print(f"GUID 존재 {len(present)}종 / 부재 확인 {len(absent)}종")
    print(f"바이트 앵커 일치 {len(anchors_ok)} / 불일치 {len(anchors_bad)}")
    for va, d in anchors_bad.items():
        print(f"  !! {va}: 기대 {d['bytes']} / 실제 {d['actual']}")
    print(f"실수 앵커 일치 {len(floats_ok)} / 불일치 {len(floats_bad)}")
    for va, d in floats_bad.items():
        print(f"  !! {va}: 실제 {d['value']}")
    print(f"코퍼스 video {vid['projects']}종: 코덱 {as_dict(vid['videoCodec'])}, "
          f"colr {as_dict(vid['colrType'])}")
    print(f"  triplet {as_dict(vid['colrTriplet'])}")
    print(f"  fullRange {as_dict(vid['colrFullRange'])}")
    print(f"  brand {as_dict(vid['brand'])} / audio {as_dict(vid['audioCodec'])}")
    print(f"  해상도 상위 {dict(vid['resolution'].most_common(6))}")
    print(f"  fps 상위 {dict(vid['fps'].most_common(8))}")
    print(f"씬 내장 mp4: {emb['embeddedMp4']}개 (pkg {emb['pkgsWithMp4']}/{emb['scenePkgs']}), "
          f"코덱 {as_dict(emb['videoCodec'])}, colr {as_dict(emb['colrType'])}")
    print(f"  triplet {as_dict(emb['colrTriplet'])}")


if __name__ == "__main__":
    main()
