"""WE assets/ 를 리포에 동봉하고 인벤토리·해시 매니페스트를 만든다.

해시 매니페스트의 목적은 드리프트 감지다. WE 가 업데이트되면 동봉본이
조용히 낡는데, 매니페스트가 있으면 재측정으로 즉시 알 수 있다.

동봉 이유(기술적): 워크샵 pkg 는 공유 셰이더 헤더와 공유 파티클 텍스처를
동봉하지 않는다(코퍼스 162개 전수 0건). 이게 없으면 대부분의 씬이 불완전하게 그려진다.
"""
import collections
import hashlib
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")
SRC = os.path.join(WE, "assets")
DST = os.path.join("Sources", "WapleRender", "Resources", "WEAssets")


def sha16(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:16]


def walk(root):
    for dirpath, _, files in os.walk(root):
        for f in sorted(files):
            p = os.path.join(dirpath, f)
            yield p, os.path.relpath(p, root).replace(os.sep, "/")


def main():
    copy = "--no-copy" not in sys.argv

    if copy:
        if os.path.isdir(DST):
            shutil.rmtree(DST)
        print(f"복사: {SRC} -> {DST}")
        shutil.copytree(SRC, DST)

    root = DST if os.path.isdir(DST) else SRC
    by_dir = collections.Counter()
    by_dir_bytes = collections.Counter()
    by_ext = collections.Counter()
    by_ext_bytes = collections.Counter()
    hashes = {}
    total = 0

    for path, rel in walk(root):
        size = os.path.getsize(path)
        total += size
        top = rel.split("/")[0]
        by_dir[top] += 1
        by_dir_bytes[top] += size
        ext = os.path.splitext(rel)[1].lower() or "(없음)"
        by_ext[ext] += 1
        by_ext_bytes[ext] += size
        hashes[rel] = sha16(path)

    src_ev = specfmt.ev("asset", "WE 2.8.42 설치본의 assets/ 디렉터리")

    specfmt.dump(specfmt.doc("scripts/spec/measure_assets.py", [
        specfmt.entry("assets.fileCount", len(hashes), "확정", [src_ev]),
        specfmt.entry("assets.totalBytes", total, "확정", [src_ev]),
        specfmt.entry("assets.dirBreakdown",
                      {k: {"files": by_dir[k], "bytes": by_dir_bytes[k]}
                       for k in sorted(by_dir)}, "확정", [src_ev]),
        specfmt.entry("assets.extensionBreakdown",
                      {k: {"files": by_ext[k], "bytes": by_ext_bytes[k]}
                       for k, _ in by_ext.most_common()}, "확정", [src_ev]),
        specfmt.entry("assets.bundledAt", DST.replace(os.sep, "/"), "확정",
                      [specfmt.ev("file", DST.replace(os.sep, "/"),
                                  "앱 번들 동봉 위치. 해석 순서상 마지막 폴백")]),
        specfmt.entry("assets.whyBundled", {
            "reason": "워크샵 pkg 는 공유 셰이더 헤더를 동봉하지 않는다",
            "evidence": "코퍼스 162개 전수에서 common_*.h 동봉 0건",
        }, "확정", [specfmt.ev("corpus", "162개 scene.pkg 엔트리 목록 전수 스캔")]),
    ]), os.path.join("spec", "assets", "inventory.json"))

    specfmt.dump(specfmt.doc("scripts/spec/measure_assets.py", [
        specfmt.entry("assets.fileHashes", hashes, "확정",
                      [specfmt.ev("asset", "sha256 앞 16자리",
                                  "WE 업데이트 시 드리프트 감지용")]),
    ]), os.path.join("spec", "assets", "manifest.json"))

    print(f"파일 {len(hashes)}개, {total / 1024 / 1024:.1f} MB")
    for k in sorted(by_dir):
        print(f"  {k:12} {by_dir[k]:5}개  {by_dir_bytes[k] / 1024 / 1024:8.2f} MB")


if __name__ == "__main__":
    main()
