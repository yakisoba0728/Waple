"""WE 2.8.42 설치 트리에서 **지문이 없던 부분**을 박제한다.

## 왜 필요한가

`spec/` 정본의 확정 항목 중 일부는 WE 설치 트리(`ui/ locale/ projects/`)를 세거나 읽어서 얻은
값이다. 그 트리는 분석 리포(`Waple-wallpaper-source/wallpaper_engine/`)에만 있고 그 리포는
삭제 예정이다. 삭제되면 **확정 등급인데 값 재도출도 드리프트 감지도 못 하는** 항목이 남는다.

바이너리 8종은 `spec/binaries-fingerprint.json` 이, `assets/`(2,940 파일)는
`spec/assets/manifest.json` 이 이미 덮는다 — 이 문서는 **나머지**만 맡는다.

    assets/    2,940 파일   →  이미 spec/assets/manifest.json (전수 sha256)
    ui/        1,548 파일   →  여기 (전수)
    locale/       75 파일   →  여기 (전수)
    projects/    999 파일   →  여기 (트리 다이제스트 — WE 동봉 예제 배경, 인용 0건)

`projects/` 만 전수를 생략하는 이유: spec 정본이 한 번도 인용하지 않았고 146MB 라 파일 목록의
값이 낮다. 대신 트리 다이제스트로 **바뀌었는지 여부**는 감지된다.

## 트리 다이제스트란

정렬한 `상대경로\\0크기\\0sha256` 줄들을 이어붙여 sha256 한 값이다. 파일 하나가 추가·삭제·변경
되면 값이 바뀐다. 무엇이 바뀌었는지는 못 말하지만 **바뀌었다는 사실**은 확실히 잡는다.

## 재실행

    WE_ROOT=/path/to/wallpaper_engine python3 scripts/spec/measure_we_install_tree.py

`WE_ROOT` 는 설치본 루트(= `wallpaper64.exe` 와 `bin/` 이 있는 디렉터리)다.
"""
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WE_ROOT = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")

# 전수 해시를 남길 디렉터리(작고, 정본이 인용한다).
FULL = ["ui", "locale"]
# 트리 다이제스트만 남길 디렉터리(크고, 인용 0건).
DIGEST_ONLY = ["projects"]
# 이미 다른 문서가 덮는 디렉터리 — 여기서는 개수·바이트만 대조용으로 적는다.
COVERED = {"assets": "spec/assets/manifest.json"}

# spec 정본이 실제로 인용하는 설치 트리 파일. 이건 무슨 일이 있어도 개별 지문을 남긴다.
CITED = [
    "ui/dist/scripts/scripts.js",
    "locale/ui_en-us.json",
    "assets/scenes/videoplayer/materials/background.json",
    "assets/shaders/genericimage.frag",
]


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def walk(base):
    """(상대경로, 바이트, sha256) 정렬 목록."""
    rows = []
    for dirpath, _dirs, files in os.walk(base):
        for f in files:
            p = os.path.join(dirpath, f)
            rel = os.path.relpath(p, base).replace(os.sep, "/")
            rows.append((rel, os.path.getsize(p), sha256_file(p)))
    rows.sort()
    return rows


def tree_digest(rows):
    h = hashlib.sha256()
    for rel, size, sha in rows:
        h.update(f"{rel}\0{size}\0{sha}\n".encode("utf-8"))
    return h.hexdigest()


def main():
    if not os.path.isdir(WE_ROOT):
        raise SystemExit(
            f"[we-install-tree] WE_ROOT 가 디렉터리가 아니다: {WE_ROOT}\n"
            f"  wallpaper64.exe 와 bin/ 이 있는 설치본 루트를 지정할 것.")

    ev = specfmt.ev("file", f"WE 2.8.42 설치 트리 ({WE_ROOT})",
                    "os.walk 전수 · sha256 · 트리 다이제스트 = 정렬한 '경로\\0크기\\0sha256' 의 sha256")

    entries, summary, missing = [], {}, []
    for name in FULL + DIGEST_ONLY + list(COVERED):
        base = os.path.join(WE_ROOT, name)
        if not os.path.isdir(base):
            missing.append(name)
            continue
        rows = walk(base)
        summary[name] = {
            "fileCount": len(rows),
            "totalBytes": sum(r[1] for r in rows),
            "treeDigest": tree_digest(rows),
        }
        if name in COVERED:
            summary[name]["fullHashesIn"] = COVERED[name]
        if name in FULL:
            entries.append(specfmt.entry(
                f"weInstall.{name}.fileHashes",
                {rel: sha[:16] for rel, _sz, sha in rows}, "확정", [ev]))

    cited = {}
    for rel in CITED:
        p = os.path.join(WE_ROOT, rel)
        if os.path.isfile(p):
            cited[rel] = {"sha256": sha256_file(p), "fileBytes": os.path.getsize(p)}
        else:
            cited[rel] = None

    entries.insert(0, specfmt.entry("weInstall.summary", summary, "확정", [ev]))
    entries.append(specfmt.entry("weInstall.citedFiles", cited, "확정", [ev]))
    entries.append(specfmt.entry("weInstall.why", {
        "reason": "확정 항목 일부가 이 트리를 세거나 읽어서 얻은 값인데, 트리는 삭제 예정 리포에만 "
                  "있었고 지문이 없었다 — 바이너리 8종(binaries-fingerprint.json)과 "
                  "assets/(assets/manifest.json)만 덮여 있었다.",
        "whatThisBuys": "삭제 후에도 ① 다시 구한 2.8.42 설치본이 같은 것인지 대조할 수 있고 "
                        "② 값 재도출이 필요할 때 어느 파일을 봐야 하는지 알 수 있다.",
        "whatItDoesNot": "파일 내용 자체는 담지 않는다(독점 소프트웨어). 트리 다이제스트는 "
                         "'바뀌었다'만 말하고 '무엇이 바뀌었는지'는 말하지 못한다.",
        "steamDrift": "Steam 이 2.8.42 를 넘어가면 이 아카이브가 유일한 2.8.42 스냅샷이었다 — "
                      "그때 이 지문이 드리프트 감지의 유일한 수단이 된다.",
    }, "확정", [ev]))
    if missing:
        entries.append(specfmt.entry("weInstall.missing", sorted(missing), "확정", [ev]))

    specfmt.dump(specfmt.doc("scripts/spec/measure_we_install_tree.py", entries),
                 os.path.join("spec", "we-install-tree.json"))

    for name, info in summary.items():
        print(f"  {name:10} {info['fileCount']:>6} 파일  {info['totalBytes']:>12,} B  "
              f"digest {info['treeDigest'][:16]}…")
    for rel, info in cited.items():
        print(f"  인용 {rel}: {'없음' if info is None else info['sha256'][:16] + '…'}")
    if missing:
        print("  못 찾음:", ", ".join(missing))


if __name__ == "__main__":
    main()
