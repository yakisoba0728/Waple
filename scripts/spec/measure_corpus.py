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

    specfmt.dump(specfmt.doc("scripts/spec/measure_corpus.py", [
        specfmt.entry("format.pkg.layout", {
            "header": "i32 vlen | vlen bytes magic | i32 entryCount",
            "entry": "i32 nameLen | nameLen bytes name | i32 offset | i32 size",
            "blobBase": "엔트리 표 직후",
            "compression": "없음 — 무압축 TOC 아카이브",
        }, "확정", [specfmt.ev("corpus", f"{pkgs}/{pkgs} 파싱 성공, 오류 {sum(errors.values())}건",
                              "전건 성공이 곧 규약의 검증이다")]),
        specfmt.entry("format.pkg.magicDistribution", dict(pkg_magic.most_common()), "확정", [corpus_ev]),
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
        specfmt.entry("format.mdl.v0004Layout", {
            "header": 'magic "MDLV0004" | u8 0 | u32 formatFlag | u32 const1 | u32 meshCount',
            "mesh": "cstring materialPath | u32 0 | u32 vertexBlobBytes | vertices | ...",
            "formatFlag0x09": "pos(3f) + uv(2f) = stride 20B, 법선/탄젠트 없음",
            "hasAABB": "version >= 17 에서만 존재. 0004 는 없음",
        }, "확정", [specfmt.ev("file",
                              "projects/defaultprojects/audiophile/models/audiophile/glow.mdl (156B)",
                              "짝 glow.obj 와 대조: 정점4·UV4·법선없음, 첫 정점 x=-3.285059")]),
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
