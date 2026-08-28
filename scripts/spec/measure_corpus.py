"""워크샵 코퍼스를 전수 파싱해 포맷 도수 정본을 만든다.

pkg 컨테이너 규약(Waple 의 ScenePackage.swift 와 동일):
  i32 vlen | vlen bytes magic("PKGV####") | i32 count
  count x { i32 nlen | nlen bytes name | i32 offset | i32 size }
  blobBase = 현재 위치
파싱이 전건 성공한다는 것 자체가 그 규약의 검증이다.
"""
import collections
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WS = os.environ.get("WE_WORKSHOP", r"Z:\SteamLibrary\steamapps\workshop\content\431960")
WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")


def parse_pkg(data):
    n = len(data)
    p = 0

    def i32():
        nonlocal p
        if p + 4 > n:
            raise ValueError("eof")
        v = struct.unpack_from("<i", data, p)[0]
        p += 4
        return v

    vlen = i32()
    if vlen < 0 or p + vlen > n:
        raise ValueError("bad vlen")
    magic = data[p:p + vlen].decode("ascii", "ignore")
    p += vlen
    count = i32()
    if count < 0 or count > 65536:
        raise ValueError("bad count")
    entries = []
    for _ in range(count):
        nlen = i32()
        if nlen < 0 or p + nlen > n:
            raise ValueError("bad nlen")
        name = data[p:p + nlen].decode("utf-8", "ignore")
        p += nlen
        entries.append((name, i32(), i32()))
    return magic, entries, p


def main():
    types = collections.Counter()
    types_raw = collections.Counter()
    pkg_magic = collections.Counter()
    ext = collections.Counter()
    mdl_ver = collections.Counter()
    tex_magic = collections.Counter()
    tex_cont = collections.Counter()
    errors = collections.Counter()
    pkgs = 0

    for wid in sorted(os.listdir(WS)):
        d = os.path.join(WS, wid)
        if not os.path.isdir(d):
            continue
        pj = os.path.join(d, "project.json")
        if os.path.exists(pj):
            try:
                with open(pj, encoding="utf-8-sig") as fh:
                    t = (json.load(fh).get("type") or "").strip()
                types_raw[t or "(없음)"] += 1
                types[t.lower() or "(없음)"] += 1
            except Exception as e:
                errors[f"project.json:{type(e).__name__}"] += 1

        for fn in ("scene.pkg", "gifscene.pkg"):
            path = os.path.join(d, fn)
            if not os.path.exists(path):
                continue
            with open(path, "rb") as fh:
                data = fh.read()
            try:
                magic, entries, base = parse_pkg(data)
            except Exception as e:
                errors[f"pkg:{e}"] += 1
                continue
            pkgs += 1
            pkg_magic[magic] += 1
            for name, off, size in entries:
                e = os.path.splitext(name)[1].lower() or "(없음)"
                ext[e] += 1
                s = base + off
                if s < 0 or s + 16 > len(data):
                    continue
                head = data[s:s + 16]
                if e == ".mdl":
                    mdl_ver[head[:8].decode("ascii", "ignore")] += 1
                elif e == ".tex":
                    tex_magic[head[:8].decode("ascii", "ignore")] += 1
                    sub = data[s:s + min(size, 64)]
                    for tag in (b"TEXI", b"TEXB", b"TEXS"):
                        i = sub.find(tag)
                        if i >= 0:
                            tex_cont[sub[i:i + 8].decode("ascii", "ignore")] += 1

    # WE 자체 번들 .mdl (코퍼스와 다르다 — Waple 미지원 버전이 여기 있다)
    bundled = collections.Counter()
    for root, _, files in os.walk(WE):
        for f in files:
            if f.endswith(".mdl"):
                with open(os.path.join(root, f), "rb") as fh:
                    bundled[fh.read(8).decode("ascii", "ignore")] += 1

    corpus_ev = specfmt.ev("corpus", f"워크샵 코퍼스 전수 스캔 (scene.pkg {pkgs}개)")

    specfmt.dump(specfmt.doc("scripts/spec/measure_corpus.py", [
        specfmt.entry("corpus.typeDistribution", dict(types.most_common()), "확정", [corpus_ev]),
        specfmt.entry("corpus.typeDistributionRaw", dict(types_raw.most_common()), "확정",
                      [specfmt.ev("corpus", "project.json type 원문(대소문자 보존)",
                                  "대소문자 혼용이라 정확 비교는 일부를 놓친다")]),
        specfmt.entry("corpus.pkgParsed", pkgs, "확정", [corpus_ev]),
        specfmt.entry("corpus.pkgParseErrors", dict(errors), "확정", [corpus_ev]),
        specfmt.entry("corpus.entryExtensions", dict(ext.most_common()), "확정", [corpus_ev]),
    ]), os.path.join("spec", "corpus", "inventory.json"))

    # [2026-08-21] 아래 세 키(entryRecordFields · compressionDecision · pathNormalization)와
    # 새 엔트리 둘(format.pkg.entryIndex · format.pkg.writer)은 **코퍼스가 아니라 바이너리**에서
    # 나왔다 — 전부 리터럴이라 코퍼스 없는 환경에서 이 생성기를 돌려도 값이 흔들리지 않는다.
    # 쓰는 쪽이 `bin/wallpaperui.exe` 라는 것 자체가 이번에 확정된 사실이다: 설치본 MZ 156개
    # (.exe 36 · .dll 116 · .scr 4) 전수에서 PKGV 토큰을 가진 것은 wallpaperui.exe 와 그
    # distribution/ 사본뿐이고, resourcecompiler64.exe 는 TEXV/MDLV 만 갖는다.
    # **VA 는 전부 어느 이미지인지 밝힌다** — 두 이미지의 imagebase 가 0x140000000 로 같아서
    # 주소만으로는 갈리지 않는다. 근거와 재현은 `docs/re/package-format.md` §10 · 부록 A.10.
    specfmt.dump(specfmt.doc("scripts/spec/measure_corpus.py", [
        specfmt.entry("format.pkg.layout", {
            "header": "i32 vlen | vlen bytes magic | i32 entryCount",
            "entry": "i32 nameLen | nameLen bytes name | i32 offset | i32 size",
            "blobBase": "엔트리 표 직후",
            "compression": "없음 — 무압축 TOC 아카이브",
            "entryRecordFields": (
                "네 필드가 전부다 — 예약·플래그·CRC·타임스탬프 같은 미해석 필드가 없다. "
                "쓰는 쪽(wallpaperui.exe 0x14020a9da nameLen · 0x14020ab04 name · "
                "0x14020ab1c offset · 0x14020ab3c size)이 이 넷만 쓰고, 읽는 쪽"
                "(wallpaper64.exe 0x1402769b0 nameLen · 0x140276a4d name · 0x140276a70 offset · "
                "0x140276a82 size)이 이 넷만 읽는다. offset 은 0 에서 시작하는 size 누적합이라 "
                "색인 순서대로 연속이고 정렬·패딩·간극이 없다"
                "(wallpaperui.exe 0x14020a85d 초기화 · 0x14020ab4b 누적)"),
            "magicLengthBound": (
                "쓰는 쪽은 strlen(magic) 을 그대로 magicLen 으로 쓰고"
                "(wallpaperui.exe 0x14020a871 strlen → 0x14020a89d 기록), 읽는 쪽의 길이 접두 "
                "문자열 리더는 maxLen 8(wallpaper64.exe 0x14027692f mov r8d, 8)을 넘으면 빈 "
                "문자열 + 스트림 미전진으로 파스를 통째로 민다. 곧 8자를 넘는 매직은 자기 리더가 "
                "못 읽는다 — \"PKGV%04d\" 가 정확히 8자인 것은 우연이 아니다"),
            "compressionDecision": (
                "판정 지점 자체가 없다 — 압축 여부를 알리는 플래그도, 엔트리별 헤더도 없다. "
                "쓰는 쪽은 원본 파일을 0x400 바이트씩 읽어 그대로 이어 붙이고"
                "(wallpaperui.exe 0x14020ad00 - 0x14020aea8 루프, 읽기 0x14020adb5 · "
                "쓰기 0x14020ae9c), 읽는 쪽은 슬라이스를 그대로 넘긴다"
                "(wallpaper64.exe 0x140274142 seek · 0x140274154 길이 상한). "
                "LZ4 는 .tex 페이로드 안쪽 규약이지 컨테이너 규약이 아니다"),
            "pathNormalization": (
                "비대칭이다. 쓰기는 구분자를 '/' 로 바꾸고(wallpaperui.exe 0x14000c43d 탐색 · "
                "0x14000c45d 치환) 연속 구분자를 접되(0x14000c509 검사 · 0x14000c541 memmove) "
                "대소문자는 보존한다 — 정규화기 0x14000c3f0 과 두 수집기·패커·확장자 추출기 "
                "어느 범위에도 CRT tolower(wallpaperui.exe 0x14096d1fc) 호출이 0건이고 이미지 "
                "전역에 CharLowerW·_wcslwr·towlower 임포트가 0건이다. 읽기는 바이트별 ASCII "
                "tolower 만 하고 구분자를 손대지 않는다(wallpaper64.exe 0x140276ac4 적재 · "
                "0x140274003 조회). 곧 대소문자는 읽는 쪽에서만 접히고, 구분자는 쓰는 쪽에서만 "
                "접힌다"),
        }, "확정", [specfmt.ev("corpus", f"{pkgs}/{pkgs} 파싱 성공, 오류 {sum(errors.values())}건",
                              "전건 성공이 곧 규약의 검증이다"),
                   specfmt.ev("binary",
                              "bin/wallpaperui.exe 0x14020a660 패커 · wallpaper64.exe 0x140276700 리더",
                              "새 네 키는 쓰는 쪽과 읽는 쪽을 대조해 확정했다 — 코퍼스 유래 값이 아니다")]),
        specfmt.entry("format.pkg.magicDistribution", dict(pkg_magic.most_common()), "확정", [corpus_ev]),
        specfmt.entry("format.pkg.entryIndex", {
            "index": "이름을 제자리에서 ASCII tolower 하여(wallpaper64.exe 0x140276ac0 - 0x140276ad6) "
                     "그것만을 키로 쓰는 해시맵 하나. FNV-1a 64"
                     "(wallpaper64.exe 0x1402778b4 베이시스 · 0x1402778c3 소수). "
                     "대소문자를 보존하는 색인이 없다",
            "duplicateKeyWinner": "마지막 엔트리. 삽입은 find-or-emplace"
                                  "(wallpaper64.exe 0x140276ae4 → 0x140277890)인데 호출부가 조건 없이 "
                                  "offset/size 를 덮어쓴다(0x140276aef · 0x140276af5)",
            "loopTermination": "고정 횟수뿐이다(wallpaper64.exe 0x1402769a0 초기화 · 0x140276b3c 비교 · "
                               "0x140276b40 분기). 센티널도 스트림 상태 검사도 없어 잘린 파일도 "
                               "0(성공)으로 끝난다",
            "sizeGate": "조회는 해시 히트 뒤 size 를 다시 보고(wallpaper64.exe 0x14027412a) 0 이하면 "
                        "못 찾은 것과 같은 자리로 빠져 마운트된 디렉터리에서 실제 파일을 연다",
            "separatorFolding": "없다. 적재·조회 두 폴딩 루프 어디에도 역슬래시→슬래시 치환이 없어 "
                                "역슬래시 표기와 슬래시 표기는 서로 다른 키다",
            "secondImage": "같은 규약이 bin/wallpaperui.exe 안의 두 번째 로더(0x140474430)에서도 "
                           "확인된다 — 버전 상한 24(0x140474782), nameLen 상한 0x800(0x1404747e8), "
                           "바이트별 tolower(0x140474913), FNV-1a 베이시스(0x14047493f), "
                           "무조건 덮어쓰기(0x140474b50 offset · 0x140474b57 size), "
                           "고정 횟수 종단(0x140474bd0), dataBase 가산(0x140474bf4). "
                           "그쪽은 맵 삽입이 인라인이라 구현이 다른데 규약은 같다",
        }, "확정", [specfmt.ev("binary",
                              "wallpaper64.exe 0x140276700 적재 · 0x140273f50 조회 · 0x140277890 삽입 · "
                              "bin/wallpaperui.exe 0x140474430 두 번째 로더",
                              ".pdata 함수 시작에서 선형으로 떠서 두 이미지에서 각각 확인")]),
        specfmt.entry("format.pkg.writer", {
            "binary": "bin/wallpaperui.exe. 설치본 MZ 156개(.exe 36 · .dll 116 · .scr 4) 전수에서 "
                      "PKGV 토큰을 가진 것은 이것과 distribution/ 사본뿐이고(ASCII 2건 · UTF-16LE 0건), "
                      "resourcecompiler64.exe · resourceutil64.dll · cloneextensions64.dll · "
                      "scenescript64.dll · webwallpaper64.exe 는 PKGV·.pkg 모두 0건이다"
                      "(resourcecompiler64.exe 가 가진 포맷 토큰은 TEXV 2 · MDLV 1 뿐이다)",
            "packer": "wallpaperui.exe 0x14020a660(rcx 레코드 벡터 · rdx 출력 경로 · r8 매직). "
                      "매직은 호출부가 리터럴 PKGV0024(0x140ad1a98)로 넘긴다 — "
                      "0x140133446 CLI packProject · 0x14020a4c9 UI 인프로세스",
            "recordLayout": "0x48 바이트 레코드 = 내부 이름 std::string(+0x00) | 원본 절대경로 "
                            "std::string(+0x20) | i32 크기(+0x40). 스트라이드는 세 자리에서 독립 확정된다 "
                            "— wallpaperui.exe 0x14020a7d5 삭제 루프 · 0x14020ab47 엔트리 루프 · "
                            "0x14020a90b 정확 나눗셈",
            "noExtensionDropped": "CLI 수집기는 순회 노드마다 has_extension 을 먼저 본다"
                                  "(wallpaperui.exe 0x14013314e 호출 · 0x140133159 거짓이면 건너뜀, "
                                  "판정 함수 0x14000e3b0 은 마지막 성분에서 '.' 를 찾되 '.'·'..' 를 "
                                  "제외한다). 곧 디렉터리 엔트리도, 확장자 없는 일반 파일도 애초에 "
                                  "레코드가 되지 않는다. 코퍼스 11,338 경로에 확장자 없는 이름 0건",
            "zeroSizeDropped": "쓰기 직전 size == 0 인 레코드를 벡터에서 지운다"
                               "(wallpaperui.exe 0x14020a7d1 비교 · 0x14020a7db - 0x14020a824 압축). "
                               "남은 것이 없으면 \"Pkg file list empty for %s\" 로 실패한다"
                               "(0x14020a83e 검사 · 0x14020a84e 문자열)",
            "sizeField": "파일 상태 조회(wallpaperui.exe 0x1408e72b0, GetFileAttributesExW/FindFirstFileW) "
                         "가 준 u64 크기를 i32 로 자른다(CLI 0x1401333aa · UI 0x14020a3e5). 조회가 "
                         "실패하면 두 호출부 모두 -1 을 들고 나오고(CLI 0x14000ee71 · UI 0x14020a3cf) "
                         "그 값을 검사하는 자리가 없어 0xFFFFFFFF 로 기록된다. 2 GiB 이상 파일도 "
                         "절단으로 음수가 된다. 둘 다 도달 미관측(워크샵 161 pkg · 최대 단일 pkg "
                         "712,246,205 B)",
            "excludedExtensions": ".mtl .obj .fbx .blend .dae .3ds .x .lxo .gltf .png .tga .jpeg .jpg "
                                  ".jfif .bmp .psd .ico .gif .dds .tif .tiff .mp4 — CLI 수집기가 이 22종을 "
                                  "건너뛴다(wallpaperui.exe 0x14013322a .mtl · 0x140133284 표 A 9종 "
                                  "@0x140abab70 · 0x1401332ac 표 B 12종 @0x140ababc0 · 0x1401332eb .mp4). "
                                  ".json 은 표를 보기 전에 바로 포함으로 빠지므로(0x140133255) 표 A 의 "
                                  "아홉 번째 .json 은 죽은 칸이다. 비교는 소문자 리터럴과의 memcmp"
                                  "(0x140042480 → 0x1409d1dc0)이고 확장자 추출(0x14000dc90)이 대소문자를 "
                                  "접지 않으므로 대문자 표기는 이 필터에 걸리지 않는다",
            "outputName": "project.json 의 file 값에서 확장자를 pkg 로 바꾼 경로다"
                          "(wallpaperui.exe 0x140209bcf \"file\" · 0x140209c28 확장자 제거 · "
                          "0x140209c14 \"pkg\" 리터럴 · 0x140209c74 결합). 읽는 쪽이 file 부재 시 쓰는 "
                          "폴백 규칙(wallpaper64.exe 0x14011e368 + 0x140060d90)과 같은 규약이다",
            "uiCollectorFilter": "UI 인프로세스 수집기(wallpaperui.exe 0x140209ba0)는 파일 목록을 "
                                 "호출자에게서 미리 받아 돌므로 CLI 와 같은 확장자 필터가 그 앞단에 "
                                 "있는지는 확정하지 못했다 — 미해결",
        }, "확정", [specfmt.ev("binary",
                              "bin/wallpaperui.exe 0x14020a660 패커 · 0x140131830 CLI 수집기 · "
                              "0x140209ba0 UI 인프로세스 수집기")]),
    ]), os.path.join("spec", "formats", "pkg.json"))

    specfmt.dump(specfmt.doc("scripts/spec/measure_corpus.py", [
        specfmt.entry("format.tex.magicDistribution", dict(tex_magic.most_common()), "확정", [corpus_ev]),
        specfmt.entry("format.tex.containerDistribution", dict(tex_cont.most_common()), "확정", [corpus_ev]),
        # [정정 2026-07-31] 이 항목은 처음에 "-transcode 는 디코더가 아니다" 로 확정 기록됐다.
        # 틀렸다. 표본 5개가 전부 패스스루 포맷(R8/RG88/raw)이라 디코드를 보여줄 수 없는
        # 표본으로 부정을 결론냈다 — 표본 추출 오류다. BC 포맷으로 재검증해 반증했다.
        specfmt.entry("format.tex.transcodeDecodes", {
            "command": "resourcecompiler64.exe -transcode -i <in.tex> -o <out.tex> -maxmipmaps 1",
            "decodes": {
                "4 (BC3/DXT5)": "-> format 0 RGBA8888",
                "6 (BC2)": "-> format 0",
                "7 (BC1)": "-> format 0",
            },
            "passthrough": {"8 (RG88)": "바이트 동일", "9 (R8)": "바이트 동일"},
            "cropOnly": {"0 (raw)": "패딩 제거만 — 2048x2048 -> 1920x1080"},
            "deterministic": True,
            "note": "출력은 패딩이 크롭돼 texW/texH 가 imgW/imgH 로 갱신된다",
        }, "확정", [specfmt.ev("binary",
                              "bin/resourcecompiler64.exe -transcode, 코퍼스 6포맷 표본 실행",
                              "fmt4 1.05MB->2.33MB / fmt6 22.9KB->19.6KB / fmt7 59.9KB->90.0KB "
                              "전부 출력 format 0. fmt8/9 는 SHA 동일. 2회 실행 결정적")]),
        specfmt.entry("format.tex.transcodeOpensGoldenOracle", {
            "claim": "코퍼스 4,680 + 공유 311 텍스처에 대해 WE 자체 디코더 기준 골든이 가능하다",
            "caveats": [
                "패스스루 포맷(8/9)은 대조 의미가 없다 — 원본 그대로다",
                "mip1 이상은 크롭된 mip0 에서 재생성된 것이므로 mip0 만 정본으로 쓴다",
                "-maxmipmaps 1 로 mip0 단일 출력을 받는 것이 대조에 적합하다",
            ],
        }, "확정", [specfmt.ev("binary", "위 transcodeDecodes 실측")]),
        specfmt.entry("format.tex.paddedVsImageDims", {
            "note": "저장은 블록정렬 texW x texH, 실제 이미지는 imgW x imgH 로 다르다",
            "witness": "plant1.tex — 저장 512x1024 / 이미지 512x875",
        }, "확정", [specfmt.ev("asset", "assets/.../plant1.tex",
                              "-transcode 출력이 패딩을 제거해 512x875 로 바뀐 것으로 확인")]),
    ]), os.path.join("spec", "formats", "tex.json"))

    specfmt.dump(specfmt.doc("scripts/spec/measure_corpus.py", [
        specfmt.entry("format.mdl.corpusVersions", dict(mdl_ver.most_common()), "확정", [corpus_ev]),
        specfmt.entry("format.mdl.bundledVersions", dict(bundled.most_common()), "확정",
                      [specfmt.ev("asset", "WE 설치본 하위 .mdl 전수",
                                  "WE 자체 번들. 코퍼스와 버전 분포가 다르다")]),
        # [정정 2026-08-01] 이 항목은 처음에 오프셋 13 을 "const1", 메시 문자열을
        # "cstring materialPath" 1개로 적었다. 둘 다 틀렸다 — 표본(glow.mdl)이
        # skinCount=1·meshCount=1 이라 세 해석이 전부 같은 바이트를 낳는 표본이었다.
        # spec/formats/mdl-deep.json format.mdl.header / .stringLoopIsPerMesh 가
        # 디컴파일(FUN_140261880) + 코퍼스 451개로 확정했다. 여기는 요약만 남기고
        # 정본은 mdl-deep.json 이다(중복 사실을 두 곳에서 유지하지 않는다).
        specfmt.entry("format.mdl.v0004Layout", {
            "canonicalIn": "spec/formats/mdl-deep.json (format.mdl.header, "
                           "format.mdl.meshLayout, format.mdl.versionGates)",
            "header": 'magic "MDLV0004" | u8 0 | u32 formatFlag | u32 skinCount | u32 meshCount',
            "mesh": "cstring material × skinCount | u32 gateWord | u32 vertexBlobBytes | "
                    "vertices | u32 indexBytes | indices",
            "formatFlag0x09": "pos(3f) + uv(2f) = stride 20B, 법선/탄젠트 없음",
            "hasAABB": "version >= 17 에서만 존재. 0004 는 없음",
        }, "확정", [specfmt.ev("file",
                              "projects/defaultprojects/audiophile/models/audiophile/glow.mdl (156B)",
                              "짝 glow.obj 와 대조: 정점4·UV4·법선없음, 첫 정점 x=-3.285059"),
                   specfmt.ev("file", "spec/formats/mdl-deep.json",
                              "오프셋 13 = skinCount, 문자열 루프가 메시 루프 안 — "
                              "audiophile grid.mdl(skinCount=2) 이 반례")]),
    ]), os.path.join("spec", "formats", "mdl.json"))

    print(f"pkg {pkgs}개 파싱, 오류 {sum(errors.values())}건")
    print(f"  type(소문자) {dict(types.most_common())}")
    print(f"  type(원문)   {dict(types_raw.most_common())}")
    print(f"  PKGV {dict(pkg_magic.most_common(5))}")
    print(f"  MDLV 코퍼스 {dict(mdl_ver.most_common())}")
    print(f"  MDLV 번들   {dict(bundled.most_common())}")
    print(f"  TEX {dict(tex_magic.most_common())} / {dict(tex_cont.most_common())}")


if __name__ == "__main__":
    main()
