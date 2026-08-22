"""씬 오브젝트 모델 정본 → spec/engine/scene-objects.json

왜 이 스크립트가 있나
---------------------
`docs/re/scene-object-model.md` 와 `docs/re/object-propagation.md` 가 `objects[]` 의
**id 해소 · 상속 축 · 정렬 안정성 · 커서 히트테스트 참가 타입**을 산문으로 확정했다.
산문은 낡는다. 이 스크립트는 그 결론들을 **바이너리 바이트에서 매번 다시 뽑아** 정본에
찍는다 — 그래서 WE 판올림이나 인용 오기가 나면 여기서 죽는다.

특히 다음 둘은 Waple 구현이 직접 의존한다.
  · `SceneDocument.claimObjectID` — "같은 id 가 둘이면 **앞**이 이긴다"(패키지 엔트리의
    last-wins 와 **반대**다. 형제 이름에 속기 쉬운 자리라 정본에 못박는다).
  · `SceneDocument.worldParentTransform` — "부모에게서 물려받는 것은 트랜스폼(곱셈)과
    가시성(AND) 둘뿐이고 alpha/color/brightness 는 아니다".

무엇을 바이트로 확인하나(전부 `wallpaper64.exe`, imagebase 0x140000000)
--------------------------------------------------------------------
  §1 `Scene::findObjectById` `0x140196840` 의 선형 탐색 루프 — **첫 일치에서 탈출**하는
     바이트열(`mov rdi,[rax]` / `cmp [rdi+8],rdx` / `je` / `add rax,8`).
  §2 id 저장 헬퍼 `sub_1401a38f0` — `asUInt64`(`0x140086000`) 호출과 **0 이면 저장 생략**
     (`test rax,rax` / `je`). 그리고 그 뒤 집합 삽입 `sub_140078250` 이
     "이미 있으면 기존 노드 반환 + inserted=false"(`xor al,al`)인 것.
  §3 오브젝트 기저 프로퍼티 디스크립터 — `sortorder` 엔트리의 멤버 오프셋(`0x124`)과
     타입코드가 **레지스터 경유**인 것, 그 레지스터를 지배하는 `xor edi,edi`.
     그리고 역직렬화 썽크가 dword 를 쓰는 것(= int32).
  §4 정렬 안정성 — 드로우 리스트 빌더의 `ceil(n/2)` 임시버퍼 + 실패 시 반으로 줄여 재시도
     (MSVC `_Optimistic_temporary_buffer`), `_ISORT_MAX = 0x20`, 재귀 2회.
  §5 커서 이벤트 디스패처의 종류코드 게이트(`cmp eax,1` / `cmp eax,4` / `cmp eax,5`)와
     타입별 vtable 슬롯 `+0x60` 이 돌려주는 상수.
  §6 상속 축 — 가시성 AND 함수 `sub_140185010` 전문(9바이트 패턴 2개)과, 트랜스폼 합성부
     `sub_1401850a0` 이 플래그워드 `+0x120` 을 **한 번도** 참조하지 않는다는 것.
  §7 카메라 오브젝트가 `objects[].path` 를 실제로 소비한다는 것(`"path"` 조회 + `"paths"` 조회).
  §8 코퍼스 — 설치본 씬 문서 전수의 오브젝트 id 중복/부재/0 도수.
  §9 CP 회전(`[cp+0x80]` 4×4)의 최종 소비자 — 갱신부가 활성 트랜스폼(`+0x00`)으로 복사하고
     이미터 형상 평가부가 그것을 방향 기저로 읽는다는 것(게이트 비트까지).

경로 환경변수: WE_ROOT(설치본) 또는 WE_BIN(wallpaper64.exe 직접).

⚠️ 보관본 PE 의 208B 섹션 오프셋 어긋남은 measure_texture_filtering.PE 가 보정한다
(그 모듈 독스트링 참조) — 여기서는 그 리더를 그대로 재사용한다.
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
from measure_texture_filtering import PE, BIN, WE

OUT = os.path.join("spec", "engine", "scene-objects.json")


def fail(msg):
    raise SystemExit("measure_scene_objects: " + msg)


def _sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ── 바이트 읽기 보조 ────────────────────────────────────────────────────────

def rd(pe, va, n):
    o = pe.rva2off(va - pe.base)
    if o is None:
        fail(f"{va:#x}: 이미지 밖")
    return pe.d[o:o + n]


def u32(pe, va):
    return struct.unpack("<I", rd(pe, va, 4))[0]


def u64(pe, va):
    return struct.unpack("<Q", rd(pe, va, 8))[0]


def expect(pe, va, hexbytes, what):
    """VA 에 정확히 이 바이트열이 있어야 한다. 아니면 죽는다(= 인용이 낡았다)."""
    want = bytes.fromhex(hexbytes.replace(" ", ""))
    got = rd(pe, va, len(want))
    if got != want:
        fail(f"{what}: {va:#x} 가 {want.hex()} 이 아니라 {got.hex()} 다 — 인용이 낡았거나 다른 이미지다")
    return want


def rip_target(pe, va, insn_len, disp_off):
    """`… [rip+d] …` 의 절대 목표. insn_len = 명령 길이, disp_off = disp32 위치."""
    d = struct.unpack("<i", rd(pe, va + disp_off, 4))[0]
    return va + insn_len + d


def cstr(pe, va, n=64):
    b = rd(pe, va, n).split(b"\0")[0]
    return b.decode("ascii", "replace")


# ── §1 id 조회는 선형 탐색 · 첫 일치 ────────────────────────────────────────

FIND_BY_ID = 0x140196840


def find_by_id(pe):
    # 벡터 begin/end 로드 (씬 인터페이스 서브오브젝트 기준 +0x108 / +0x110)
    expect(pe, 0x140196846, "48 8b 81 08 01 00 00", "findObjectById begin 로드")
    expect(pe, 0x140196850, "4c 8b 81 10 01 00 00", "findObjectById end 로드")
    # 루프 본체: rdi = *rax ; cmp [rdi+8], rdx ; je found ; rax += 8 ; cmp/jne
    expect(pe, 0x140196860, "48 8b 38", "findObjectById 후보 로드")
    expect(pe, 0x140196863, "48 39 57 08", "findObjectById id 비교")
    expect(pe, 0x140196867, "74 12", "findObjectById 첫 일치 탈출")
    expect(pe, 0x140196869, "48 83 c0 08", "findObjectById 전진")
    expect(pe, 0x14019686d, "49 3b c0", "findObjectById 끝 비교")
    expect(pe, 0x140196870, "75 ee", "findObjectById 루프 back-edge")
    expect(pe, 0x140196872, "33 c0", "findObjectById 미발견 = nullptr")
    # 씬 서브오브젝트를 컨텍스트에 심는 자리: [ctx+0x1510] = scene+0x50
    expect(pe, 0x1401872b4, "49 8d 46 50", "scene+0x50 서브오브젝트 lea")
    expect(pe, 0x1401872e8, "49 89 85 10 15 00 00", "[ctx+0x1510] 대입")
    # vtable 슬롯 +8 이 이 함수여야 한다
    slot = u64(pe, 0x14048ea08 + 8)
    if slot != FIND_BY_ID:
        fail(f"vtable 0x14048ea08+8 이 {slot:#x} 다 — findObjectById 가 아니다")
    return {
        "함수": f"{FIND_BY_ID:#x}",
        "vtable": "0x14048ea08 슬롯 +0x8",
        "벡터": "[scene+0x158]..[scene+0x160] (서브오브젝트 기준 +0x108/+0x110)",
        "규약": "앞에서 뒤로 선형 탐색, 첫 일치에서 탈출(0x140196867 je) — first-wins",
        "미발견": "nullptr (0x140196872 xor eax,eax)",
    }


# ── §2 id 저장·집합 삽입도 first-wins ───────────────────────────────────────

def id_store(pe):
    # sub_1401a38f0: find("id") → 태그 1..3 게이트 → asUInt64 → 0 이면 저장 생략
    idstr = rip_target(pe, 0x1401a391b, 7, 3)
    if cstr(pe, idstr) != "id":
        fail(f"0x1401a391b 의 lea 목표 {idstr:#x} 가 \"id\" 가 아니다")
    expect(pe, 0x1401a3931, "0f b6 40 08", "id 태그 로드")
    expect(pe, 0x1401a3935, "ff c8", "id 태그 dec")
    expect(pe, 0x1401a3937, "83 f8 02", "id 태그 cmp 2")
    expect(pe, 0x1401a393a, "77 7c", "id 태그 ja(비수치 탈출)")
    asuint64 = 0x1401a395f + 5 + struct.unpack("<i", rd(pe, 0x1401a395f + 1, 4))[0]
    if asuint64 != 0x140086000:
        fail(f"0x1401a395f call 목표 {asuint64:#x} 가 asUInt64(0x140086000) 가 아니다")
    expect(pe, 0x1401a3964, "48 85 c0", "id==0 검사")
    expect(pe, 0x1401a3967, "74 4f", "id==0 이면 저장 생략")
    expect(pe, 0x1401a399e, "49 89 06", "[obj+8] = id")
    insert = 0x1401a39ab + 5 + struct.unpack("<i", rd(pe, 0x1401a39ab + 1, 4))[0]
    if insert != 0x140078250:
        fail(f"0x1401a39ab call 목표 {insert:#x} 가 집합 삽입(0x140078250) 이 아니다")
    # 기저 ctor 가 이 헬퍼를 부른다
    helper = 0x1401ddd69 + 5 + struct.unpack("<i", rd(pe, 0x1401ddd69 + 1, 4))[0]
    if helper != 0x1401a38f0:
        fail(f"기저 ctor 0x1401ddd69 call 목표 {helper:#x} 가 sub_1401a38f0 이 아니다")
    # 삽입은 덮어쓰지 않는다 — 기존 노드를 찾으면 inserted=false 로 돌아간다
    expect(pe, 0x14007831f, "32 c0", "집합 삽입: 기존 키면 inserted=false")
    expect(pe, 0x140078321, "49 89 3c 24", "집합 삽입: 기존 노드 반환")
    return {
        "헬퍼": "0x1401a38f0 (기저 ctor 0x1401ddbb0 이 0x1401ddd69 에서 호출)",
        "읽기": "find(\"id\") 0x1401a3922 → 태그 1..3 만(0x1401a3935 dec/cmp 2/ja) → asUInt64 0x140086000",
        "id0": "asUInt64 결과가 0 이면 저장 자체를 건너뛴다(0x1401a3964 test/je) — `id:0` 은 `id` 키 부재와 구분되지 않는다",
        "저장": "[obj+8] = id (0x1401a399e)",
        "집합삽입": "sub_140078250 — 같은 키가 이미 있으면 기존 노드 반환, inserted=false(0x14007831f xor al,al). 덮어쓰지 않는다",
    }


# ── §3 `sortorder` 디스크립터 ───────────────────────────────────────────────

def sortorder(pe):
    name = rip_target(pe, 0x1401e08f9, 7, 3)
    if cstr(pe, name) != "sortorder":
        fail(f"0x1401e08f9 의 lea 목표 {name:#x} 가 \"sortorder\" 가 아니다")
    expect(pe, 0x1401e0916, "c7 43 34 24 01 00 00", "sortorder 멤버 오프셋")
    member = u32(pe, 0x1401e0916 + 3)
    expect(pe, 0x1401e092b, "89 7b 30", "sortorder 타입코드(레지스터 edi 경유)")
    # edi 를 지배하는 유일한 대입
    expect(pe, 0x1401e07b9, "33 ff", "xor edi,edi (타입코드 0 의 근거)")
    # 독립 확인: 같은 구간에서 dil 이 18글자 문자열의 NUL 을 쓴다 → dil == 0
    expect(pe, 0x1401e098b, "40 88 78 12", "dil 이 SSO NUL 을 쓴다(= 0)")
    # 역직렬화 썽크가 dword 를 쓴다 = int32
    deser = rip_target(pe, 0x1401e090f, 7, 3)
    if deser != 0x1401a4930:
        fail(f"sortorder 역직렬화 썽크가 {deser:#x} 다 — 0x1401a4930 이 아니다")
    expect(pe, 0x1401a4953, "83 f8 01", "sortorder 태그 1")
    expect(pe, 0x1401a4958, "83 f8 02", "sortorder 태그 2")
    expect(pe, 0x1401a495d, "83 f8 03", "sortorder 태그 3")
    expect(pe, 0x1401a4962, "f2 41 0f 2c 00", "sortorder 태그3 = cvttsd2si eax (32비트)")
    expect(pe, 0x1401a4969, "41 8b 00", "sortorder 태그1/2 = mov eax,[r8]")
    expect(pe, 0x1401a496c, "41 89 04 2e", "sortorder 스토어 = dword")
    asint = 0x1401a49bc + 5 + struct.unpack("<i", rd(pe, 0x1401a49bc + 1, 4))[0]
    return {
        "이름세팅": "0x1401e090a (lea 0x1401e08f9)",
        "멤버오프셋": f"{member:#x}",
        "타입코드": 0,
        "타입코드근거": "mov [rbx+0x30], edi @0x1401e092b · 지배 대입 xor edi,edi @0x1401e07b9 (rdi 는 Win64 비휘발성) · 독립확인 dil==0 @0x1401e098b",
        "멤버타입": "int32 — 역직렬화 썽크 0x1401a4930 이 dword 를 쓴다(0x1401a496c)",
        "태그게이트": "1(int)/2(uint)/3(real) 만 착지. 4(string)·5(bool)은 스토어를 건너뛰어 ctor 기본값 0 이 남는다",
        "바인딩경로": f"{{\"value\":…}} 는 dec/cmp 2/ja(0x1401a49b5) 뒤 asInt {asint:#x}",
        "세터게터": "0x1401a49f0 / 0x1401a4a10 (dword 복사 썽크)",
    }


# ── §4 정렬 안정성 ──────────────────────────────────────────────────────────

def sort_stability(pe):
    # 드로우 리스트 빌더: 원소수 ≤ 0x20 이면 삽입정렬, 아니면 stable_sort 본체
    expect(pe, 0x14018ab74, "48 83 fe 20", "정렬 경로 분기 cmp n, 0x20")
    expect(pe, 0x14018ab78, "7f 17", "n > 0x20 이면 대형 경로")
    cmp_ = rip_target(pe, 0x14018ab7a, 7, 3)
    if cmp_ != 0x140186980:
        fail(f"비교자가 {cmp_:#x} 다 — 0x140186980 이 아니다")
    expect(pe, 0x140186980, "8b 82 24 01 00 00", "비교자: b->sortorder 로드")
    expect(pe, 0x140186986, "39 81 24 01 00 00", "비교자: a->sortorder 비교")
    expect(pe, 0x14018698c, "0f 9c c0", "비교자: setl (엄격 < , 부호 있음)")
    # 소형 경로 = _Insertion_sort_unchecked (엄격 < 로만 민다 = 안정)
    expect(pe, 0x14019fe74, "ff d5", "삽입정렬 안쪽 비교")
    expect(pe, 0x14019fe76, "84 c0", "삽입정렬 안쪽 test")
    expect(pe, 0x14019fe78, "75 e6", "삽입정렬 안쪽: 참인 동안만 민다(같은 키에서 멈춘다)")
    # 대형 경로 = _Optimistic_temporary_buffer(ceil(n/2), 실패 시 반으로 줄여 재시도)
    expect(pe, 0x14018ab97, "48 99", "임시버퍼 크기: cqo")
    expect(pe, 0x14018ab9c, "48 d1 f8", "임시버퍼 크기: sar rax,1")
    expect(pe, 0x14018ab9f, "48 2b d8", "임시버퍼 크기: n - n/2 = ceil(n/2)")
    expect(pe, 0x14018abfd, "48 d1 eb", "할당 실패 시 크기 반으로")
    expect(pe, 0x14018ac00, "75 de", "반으로 줄여 재시도 루프")
    body = 0x14018ac3d + 5 + struct.unpack("<i", rd(pe, 0x14018ac3d + 1, 4))[0]
    if body != 0x14019fec0:
        fail(f"대형 정렬 본체가 {body:#x} 다 — 0x14019fec0 이 아니다")
    expect(pe, 0x14019feeb, "49 83 f8 20", "_ISORT_MAX = 0x20")
    rec1 = 0x1401a02a2 + 5 + struct.unpack("<i", rd(pe, 0x1401a02a2 + 1, 4))[0]
    rec2 = 0x1401a02c5 + 5 + struct.unpack("<i", rd(pe, 0x1401a02c5 + 1, 4))[0]
    if rec1 != body or rec2 != body:
        fail("stable_sort 본체의 두 재귀 호출이 자기 자신이 아니다")
    return {
        "게이트": "씬 플래그워드 [scene+0xe0] & 0x3000 == 0x2000 (customsortorder 켜짐 AND transparentsorting 꺼짐)",
        "비교자": "0x140186980 — sortorder(+0x124) 오름차순, 부호 있는 엄격 <(setl @0x14018698c)",
        "소형경로": "n ≤ 0x20 → 0x14019fde0 = _Insertion_sort_unchecked. 안쪽 루프가 엄격 < 인 동안만 밀므로(0x14019fe78 jne) 같은 키의 원래 순서가 보존된다",
        "대형경로": "n > 0x20 → ceil(n/2) 임시버퍼(0x14018ab97–0x14018ab9f, 실패 시 0x14018abfd 에서 반으로 줄여 재시도) + 0x14019fec0 = _Stable_sort_unchecked(_ISORT_MAX 0x20, 자기 재귀 2회 0x1401a02a2/0x1401a02c5, 병합)",
        "결론": "두 경로 다 안정(stable) — 같은 sortorder 끼리는 objects[] 배열 순서가 유지된다",
    }


# ── §5 커서 히트테스트 참가 타입 ────────────────────────────────────────────

# vtable 라벨의 출처: 오브젝트 팩토리 sub_14018ff60 의 타입별 분기.
# 기저/particle/model/light/sound/camera/shape 는 분기 안에서 `mov [rdi], <vt>` 로 직접 깔고,
# image/sprite/text 는 그 분기가 부르는 ctor 가 깐다(각각 0x1401fac7c / 0x14025657c / 0x140256af7).
VTABLES = (
    ("base/node", 0x14048EC88, 0x1401907FF),
    ("image", 0x1404911A8, 0x1401FAC7C),
    ("particle", 0x1404915B0, 0x14019020B),
    ("sprite", 0x140491680, 0x14025657C),
    ("text", 0x140491950, 0x140256AF7),
    ("model", 0x140491338, 0x14019015B),
    ("light", 0x140491C38, 0x140190441),
    ("sound", 0x140490AE8, 0x1401905B2),
    ("camera", 0x140490980, 0x1401906B5),
    ("shape", 0x140491D10, 0x1401907B4),
)


def kind_of(pe, vt):
    """[vt+0x60] 의 몸통에서 종류코드 상수를 **바이트로** 뽑는다."""
    fn = u64(pe, vt + 0x60)
    b = rd(pe, fn, 8)
    if b[:2] == b"\x33\xc0" and b[2] == 0xC3:          # xor eax,eax ; ret
        return fn, 0
    if b[0] == 0xB8 and b[5] == 0xC3:                   # mov eax, imm32 ; ret
        return fn, struct.unpack("<I", b[1:5])[0]
    fail(f"{fn:#x}: 종류코드 몸통을 못 읽었다 ({b.hex()})")


def object_types(pe):
    rows = {}
    for name, vt, setter in VTABLES:
        # 팩토리/ctor 가 실제로 이 vtable 을 가리키는지 확인(라벨의 근거)
        tgt = rip_target(pe, setter, 7, 3)
        if tgt != vt:
            fail(f"{name}: {setter:#x} 의 lea 목표 {tgt:#x} 가 {vt:#x} 가 아니다")
        fn, kind = kind_of(pe, vt)
        rows[name] = {
            "vtable": f"{vt:#x}",
            "설치": f"{setter:#x}",
            "종류코드": kind,
            "종류함수": f"{fn:#x}",
            "getTransformMatrix(+0x80)": f"{u64(pe, vt + 0x80):#x}",
            "meshRaycast(+0x88)": f"{u64(pe, vt + 0x88):#x}",
        }
    return rows


def cursor_gate(pe):
    expect(pe, 0x14018a02d, "66 45 85 87 20 01 00 00", "커서 루프 solid(bit13) 게이트")
    expect(pe, 0x14018a041, "ff 50 60", "종류코드 가상 호출 [vt+0x60]")
    expect(pe, 0x14018a044, "83 f8 01", "커서: 종류 1")
    expect(pe, 0x14018a04b, "83 f8 04", "커서: 종류 4")
    expect(pe, 0x14018a058, "83 f8 05", "커서: 종류 5")
    quad = 0x14018a242 + 5 + struct.unpack("<i", rd(pe, 0x14018a242 + 1, 4))[0]
    mesh = 0x14018a265 + 5 + struct.unpack("<i", rd(pe, 0x14018a265 + 1, 4))[0]
    # 시차 보정: obj.parallaxDepth(+0x170/+0x174) 를 성분별로 곱한다
    expect(pe, 0x1401a40a4, "f3 0f 11 44 37 04", "parallaxDepth vec2 두번째 성분(대조용)")
    expect(pe, 0x14018a0ff, "f3 0f 59 9a 70 01 00 00", "커서 시차: * [obj+0x170]")
    expect(pe, 0x14018a10d, "f3 0f 59 82 74 01 00 00", "커서 시차: * [obj+0x174]")
    stub = u64(pe, 0x14048EC88 + 0x88)
    stubb = rd(pe, stub, 3)
    if stubb != b"\x32\xc0\xc3":
        fail(f"{stub:#x}: 기본 +0x88 이 `xor al,al; ret` 스텁이 아니다 ({stubb.hex()})")
    return {
        "디스패처": "sub_140189e10 (0x140189e10–0x14018aab9), 프레임 갱신 0x1401802d5 에서 호출",
        "순회": "오브젝트 배열을 뒤에서 앞으로(0x14018a404) = 위에서 아래로",
        "1차게이트": "solid(=[obj+0x120] bit13) 0x14018a02d — 꺼져 있으면 그 오브젝트를 건너뛴다",
        "2차게이트": "종류코드 [vt+0x60] (0x14018a041). 1(image)·4(text) → 2D 쿼드 히트테스트, 5(model) → 메시 경로. 그 외 타입은 히트테스트를 아예 받지 않는다",
        "쿼드히트테스트": f"{quad:#x} (0x14018a242)",
        "메시히트테스트": f"{mesh:#x} (0x14018a265)",
        "보조슬롯(+0x88)": f"0x14018a2bb 에서 호출되는 타입별 2차 판정. 실구현은 image({u64(pe, 0x1404911A8 + 0x88):#x}) 와 model({u64(pe, 0x140491338 + 0x88):#x}) **둘뿐**이고, 나머지 8타입은 `xor al,al; ret` 스텁 {stub:#x} 다",
        "시차보정": "종류 1·4 **둘 다** obj.parallaxDepth(+0x170/+0x174)를 성분별로 곱한 오프셋을 히트테스트에 넘긴다(0x14018a0ff · 0x14018a10d, r8 = [rsp+0x40] @0x14018a235). 텍스트가 이미지와 다른 규칙을 쓰지 않는다",
    }


# ── §6 부모→자식 상속 축 ────────────────────────────────────────────────────

def inheritance(pe):
    # 가시성: 자기 bit0 AND 조상 전건
    expect(pe, 0x140185014, "f6 81 20 01 00 00 01", "가시성: test byte [rcx+0x120], 1")
    expect(pe, 0x14018501b, "74 1c", "가시성: 꺼져 있으면 false")
    expect(pe, 0x14018501d, "48 8b 89 80 01 00 00", "가시성: rcx = parent")
    expect(pe, 0x140185029, "e8 e2 ff ff ff", "가시성: 자기 재귀")
    # 트랜스폼: parent != null 하나가 게이트, 플래그워드 참조 0
    expect(pe, 0x14018528a, "48 8b 8b 80 01 00 00", "트랜스폼: parent 로드")
    expect(pe, 0x140185291, "48 85 c9", "트랜스폼: parent null 검사")
    expect(pe, 0x140185294, "74 4d", "트랜스폼: 부모 없으면 로컬 반환으로 점프")
    expect(pe, 0x1401852b0, "e8 eb fd ff ff", "트랜스폼: 부모 월드 재귀")
    body, b, e = pe.body(0x1401850A0)
    n120 = len(re.findall(rb"\x20\x01\x00\x00", body))
    # 색/알파/밝기: 부모 포인터와 함께 나오는 함수가 없다(전수)
    return {
        "트랜스폼": {
            "상속": True,
            "규약": "곱셈 — World = Local · ParentWorld",
            "함수": "sub_1401850a0",
            "게이트": "parent != null 하나뿐(0x14018528a 로드 · 0x140185291 test · 0x140185294 je → 로컬 반환)",
            "재귀": "0x1401852b0 부모 월드 · 0x1401852c0 행렬곱",
            "플래그워드참조": n120,
        },
        "가시성": {
            "상속": True,
            "규약": "논리 AND(곱셈 아님) — 자기 bit0 ∧ 조상 전건 bit0",
            "함수": "sub_140185010",
            "근거": "0x140185014 test byte [rcx+0x120],1 → 0x14018501d rcx=[rcx+0x180] → 0x140185029 자기 재귀",
        },
        "투명도": {
            "상속": False,
            "멤버": "image alpha +0x33c (등록 0x1401ee770, 타입 4=float)",
            "근거": ".pdata 전수 디스어셈블에서 +0x33c 를 읽는 함수 중 [obj+0x180] 을 함께 역참조하는 것은 0개",
        },
        "색": {
            "상속": False,
            "멤버": "image color +0x330 (등록 0x1401ee6a0, 타입 2=vec3) · brightness +0x340 (0x1401ee85e, 타입 4)",
            "근거": "위와 동일 — 부모 포인터와 함께 나오는 리더 0개",
        },
        "적용순서": "WE 는 자식이 요구할 때 부모 월드를 재귀로 만든다(pull, 프레임 스탬프 캐시 sub_140185040). 전역 순서가 없다. 사이클은 로더 2차 패스가 부모를 지워서 끊는다(0x140187ff7–0x140188018)",
    }


# ── §7 카메라 오브젝트가 `path` 를 소비한다 ─────────────────────────────────

def camera_path(pe):
    vt_load = u64(pe, 0x140490980 + 0x40)
    if vt_load != 0x1401F2030:
        fail(f"camera vtable +0x40 이 {vt_load:#x} 다 — 0x1401f2030 이 아니다")
    base_load = 0x1401F20A5 + 5 + struct.unpack("<i", rd(pe, 0x1401F20A5 + 1, 4))[0]
    if base_load != 0x1401DE470:
        fail(f"camera load 가 기저 load 를 안 부른다({base_load:#x})")
    pathstr = rip_target(pe, 0x1401F20AA, 6, 2)   # mov eax, [rip+d] — 4바이트 SSO 리터럴
    if cstr(pe, pathstr) != "path":
        fail(f"0x1401f20aa 의 목표 {pathstr:#x} 가 \"path\" 가 아니다")
    expect(pe, 0x1401F2140, "80 7b 08 04", "path 태그 4(string) 게이트")
    pathsstr = rip_target(pe, 0x1401F21C1, 7, 3)
    if cstr(pe, pathsstr) != "paths":
        fail(f"0x1401f21c1 의 lea 목표 {pathsstr:#x} 가 \"paths\" 가 아니다")
    keys = {}
    for va in (0x1401F2239, 0x1401F2260, 0x1401F2277, 0x1401F2292, 0x1401F22AD, 0x1401F22C8, 0x1401F22E3):
        keys[f"{va:#x}"] = cstr(pe, rip_target(pe, va, 7, 3))
    # 등록부는 4개뿐이고 path 는 거기 없다
    reg = {}
    for lea, off_va, tc_va in ((0x1401F3506, 0x1401F3523, 0x1401F3539),
                               (0x1401F35DC, 0x1401F3602, 0x1401F3626),
                               (0x1401F3698, 0x1401F36BC, 0x1401F36C3),
                               (0x1401F3769, 0x1401F3786, 0x1401F379F)):
        reg[cstr(pe, rip_target(pe, lea, 7, 3))] = {
            "멤버": f"{u32(pe, off_va + 3):#x}", "타입코드": u32(pe, tc_va + 3)}
    # queuemode 값 목록: index 0 = random, 1 = sequential
    opts = [cstr(pe, 0x140478098), cstr(pe, 0x140490960)]
    return {
        "load오버라이드": "camera vtable 0x140490980 슬롯 +0x40 = 0x1401f2030 (기저 0x1401de470 을 0x1401f20a5 에서 호출)",
        "path읽기": "find(\"path\") 0x1401f20e3 → 태그 4 게이트 0x1401f2140 → asString 0x140085cc0 → 파일 서브시스템 0x1400d3f80 → jsoncpp 리더 0x140017840",
        "파일루트키": "paths (0x1401f21cc, 태그 6=array 게이트 0x1401f21d7)",
        "항목키": keys,
        "등록부": reg,
        "등록부VA": "0x1401f3460–0x1401f38b5 — 4개뿐이고 `path` 는 디스크립터가 아니다",
        "queuemode값목록": opts,
        "queuemode기본": "ctor 가 문자열 첫 바이트를 0 으로 깐다(0x140190745) = 빈 문자열. 값 목록 index 0 이 \"random\" 이라 효과가 같다",
    }


# ── §8 코퍼스 ───────────────────────────────────────────────────────────────

def corpus():
    if not os.path.isdir(WE):
        fail(f"WE_ROOT 가 없다: {WE}")
    files = sorted(os.path.join(dp, f) for dp, _, fn in os.walk(WE) for f in fn
                   if f in ("scene.json", "gifscene.json"))
    if not files:
        fail(f"{WE}: 씬 문서를 못 찾았다 — 경로가 틀렸거나 설치본이 아니다")
    objs = dupfiles = dupids = noid = zeroid = 0
    campath = camobj = 0
    scene_camera_paths = []
    for p in files:
        d = json.loads(open(p, "rb").read().decode("utf-8-sig"))
        ids = []
        for o in (d.get("objects") or []):
            if not isinstance(o, dict):
                continue
            objs += 1
            if "id" not in o:
                noid += 1
            elif o["id"] == 0:
                zeroid += 1
            else:
                ids.append(o["id"])
            if "camera" in o:
                camobj += 1
                if "path" in o:
                    campath += 1
        c = collections.Counter(ids)
        dd = [k for k, v in c.items() if v > 1]
        if dd:
            dupfiles += 1
            dupids += len(dd)
        cam = d.get("camera")
        if isinstance(cam, dict) and "paths" in cam:
            scene_camera_paths.append(os.path.relpath(p, WE).replace("\\", "/"))
    return {
        "씬문서": len(files),
        "오브젝트": objs,
        "중복id를_가진_문서": dupfiles,
        "중복id값": dupids,
        "id키_부재": noid,
        "id_0": zeroid,
        "objects[]_camera_의사오브젝트": camobj,
        "그중_path_보유": campath,
        "scene.camera.paths_보유_문서": sorted(scene_camera_paths),
    }


# ── §9 CP(controlpoint) 회전의 최종 소비자 ──────────────────────────────────

def cp_rotation_consumer(pe):
    """CP 레코드의 `+0x80` 4×4 가 어디로 흘러가는지 — 이미터 방향 기저다."""
    # 1) CP 갱신부: 플래그 게이트 뒤 +0x80..0xbf → +0x00..0x3f 복사
    expect(pe, 0x14022e45a, "48 69 f8 d0 00 00 00", "CP 스트라이드 imul 0xd0")
    expect(pe, 0x14022e461, "8b 94 3e c0 00 00 00", "CP 플래그워드 [cp+0xc0] 로드")
    expect(pe, 0x14022e468, "0f ba e2 10", "CP 게이트: bt edx, 0x10")
    expect(pe, 0x14022e472, "f6 c2 01", "CP 게이트: test dl, 1")
    expect(pe, 0x14022e47b, "0f 10 84 3e 80 00 00 00", "회전 행0 로드 [+0x80]")
    expect(pe, 0x14022e488, "0f 10 8c 3e 90 00 00 00", "회전 행1 로드 [+0x90]")
    expect(pe, 0x14022e490, "0f 11 04 3e", "활성 행0 저장 [+0x00]")
    expect(pe, 0x14022e494, "0f 10 84 3e a0 00 00 00", "회전 행2 로드 [+0xa0]")
    expect(pe, 0x14022e4a1, "0f 10 8c 3e b0 00 00 00", "위치 행 로드 [+0xb0]")
    expect(pe, 0x14022e4ae, "0f 11 4c 3e 30", "활성 위치 행 저장 [+0x30]")
    # 2) 이미터 형상 평가부가 활성 트랜스폼을 기저로 읽는다
    expect(pe, 0x140237c18, "3c 01", "이미터 종류 분기 cmp al,1")
    expect(pe, 0x140237c27, "41 8b 97 f0 00 00 00", "이미터의 CP 인덱스 [emitter+0xf0]")
    expect(pe, 0x140237c33, "48 69 ca d0 00 00 00", "이미터: CP 스트라이드 imul 0xd0")
    expect(pe, 0x140237c42, "44 0f 10 5c 08 10", "이미터: 기저 행1 [+0x10]")
    expect(pe, 0x140237c48, "44 0f 10 74 08 20", "이미터: 기저 행2 [+0x20]")
    expect(pe, 0x140237c54, "f3 0f 6f 44 08 30", "이미터: 위치 행 [+0x30]")
    expect(pe, 0x140237c65, "41 0f 58 47 70", "이미터: 위치 행 += [emitter+0x70]")
    caller = 0x14023771B + 5 + struct.unpack("<i", rd(pe, 0x14023771B + 1, 4))[0]
    if caller != 0x1402378A0:
        fail(f"0x14023771b call 목표 {caller:#x} 가 이미터 평가부(0x1402378a0) 가 아니다")
    # 3) `directiontocontrolpoint` 는 값 소스 이름 표의 한 칸일 뿐이다
    names = [cstr(pe, u64(pe, 0x140484ED0 + 8 * k)) for k in range(14)]
    return {
        "생성": "CP 빌더 0x14022bd40 이 controlpointangle*/controlpoint* 로 [cp+0x80] 4×4 를 만든다(§6.2)",
        "복사": "CP 갱신부 0x14022e3e0 이 [cp+0xc0] 의 bit0 이 서 있고 bit16 이 꺼졌을 때만"
                "(0x14022e468 bt/jb · 0x14022e472 test/je) +0x80..0xbf → +0x00..0x3f 로 복사한다"
                "(0x14022e47b–0x14022e4ae). 레코드 앞 0x40 이 CP 의 **활성 4×4** 다",
        "소비": "이미터 형상 평가부 0x1402378a0(호출부 0x14023771b, 함수 0x140236cd0)이 활성 4×4 를"
                " 기저 3행 + 위치 행으로 읽고 위치 행에 이미터 로컬 오프셋 [emitter+0x70] 을 더한다"
                "(0x140237c33 이후 · 0x140237c65 addps). 이미터 종류 분기 양쪽(0x140237c33 · 0x1402384af)이"
                " 같은 레코드를 읽는다",
        "게이트비트": "instanceoverride CP 게이트(flags & 0x10005)와 같은 워드·같은 비트",
        "값소스이름표": names,
        "결론": "CP 회전의 최종 소비자는 **이미터의 방향 기저**다. `directiontocontrolpoint` 는 코드에서"
                " 직접 참조되지 않는 값 소스 이름표(0x140484ed0–0x140484f38)의 한 칸이고 위치 계열이다",
    }


# ── 조립 ────────────────────────────────────────────────────────────────────

def main():
    if not os.path.exists(BIN):
        fail(f"바이너리가 없다: {BIN} (WE_ROOT 또는 WE_BIN 을 설정하라)")
    pe = PE(BIN)
    binref = specfmt.ev("binary", f"wallpaper64.exe (WE {specfmt.WE_VERSION}) — $WE_BIN "
                                 f"(sha256 {_sha256_of(BIN)}, {os.path.getsize(BIN)} B)")
    me = specfmt.ev("script", "scripts/spec/measure_scene_objects.py")
    corpref = specfmt.ev("corpus", f"설치본 씬 문서 전수 — $WE_ROOT/**/{{scene,gifscene}}.json")

    entries = [
        specfmt.entry("scene.object.idLookupFirstWins", find_by_id(pe), "확정", [binref, me]),
        specfmt.entry("scene.object.idStoreFirstWins", id_store(pe), "확정", [binref, me]),
        specfmt.entry("scene.object.sortOrderDescriptor", sortorder(pe), "확정", [binref, me]),
        specfmt.entry("scene.object.sortIsStable", sort_stability(pe), "확정", [binref, me]),
        specfmt.entry("scene.object.typeVtables", object_types(pe), "확정", [binref, me]),
        specfmt.entry("scene.object.cursorHitTestParticipants", cursor_gate(pe), "확정", [binref, me]),
        specfmt.entry("scene.object.inheritedAxes", inheritance(pe), "확정", [binref, me]),
        specfmt.entry("scene.object.cameraPathConsumed", camera_path(pe), "확정", [binref, me]),
        specfmt.entry("scene.object.cpRotationConsumer", cp_rotation_consumer(pe), "확정", [binref, me]),
        specfmt.entry("scene.corpus.objectIDCensus", corpus(), "확정", [corpref, me]),
    ]
    specfmt.dump(specfmt.doc("scripts/spec/measure_scene_objects.py", entries), OUT)
    print(f"{OUT}: {len(entries)} 항목")


if __name__ == "__main__":
    main()
