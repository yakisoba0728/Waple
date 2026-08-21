#!/usr/bin/env python3
"""**씬 마운트 규약이 렌더러와 스캐너에서 같은지** 본다.

왜 있는가
---------
`WallpaperCompatibilityAnalyzer` 의 계약은 "이슈 없음 = 렌더 가능" 이다. 이 계약은
스캐너가 렌더러와 **같은 방식으로 씬을 마운트할 때만** 참이다. 실제로는 두 군데가
갈려 있었고, 갈린 방향이 둘 다 나빴다(리눅스 드라이버 6케이스 실측, 수정 전):

    odd-packed        error/missingScenePackage   ← 렌더러는 정상으로 여는 씬을 "렌더 불가"
    badjson-unpacked  이슈 없음                    ← 깨져서 마운트 실패할 씬을 무이슈 통과

갈린 지점은 둘이다:

  ① **마운트 형태.** 렌더러는 `.pkg` 가 없으면 폴더를 그대로 마운트한다
     (`ScenePackage.fromDirectory`). 스캐너는 `.pkg` 가 없으면 그냥 빠져나갔다 —
     즉 언팩 씬을 한 건도 검사하지 못했다. 동봉 WEAssets 실측으로 그 도달 범위가
     바로 나온다(아래 ③): 씬 프로젝트 전건이 언팩이고 `.pkg` 는 0개다.

  ② **씬 문서 이름.** `project.json` 의 `"file"` 이 정한다. 렌더러는 그것을
     `SceneDocument.parse(sceneFileName:)` 로 넘긴다. 스캐너만 `scene.json`/
     `gifscene.json` 을 하드코딩했다.

무엇을 보는가
-------------
① 두 후보 목록이 **글자 그대로 같은가**(꼬리 리터럴이 같고, 앞머리가 각자의
   파일명 변수인가). 이게 이 게이트의 핵심 불변식이다 — 둘이 갈리는 순간 ②가 재발한다.
② 스캐너에 `ScenePackage.fromDirectory` 폴백이 살아 있는가(①의 재발 방지).
   그리고 렌더러가 `sceneFileName: project.fileName` 을 계속 넘기는가.
③ 동봉 WEAssets 의 씬 프로젝트를 세어 ①의 도달 범위가 유지되는지 확인한다.
   `.pkg` 가 하나라도 생기면 전제가 달라진 것이므로 사람이 다시 봐야 한다.

종료 코드 0 = 통과. `--selftest` 는 음성 대조군을 먼저 돌린다.
"""
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCENE_DOC = ROOT / "Sources/WapleCore/SceneDocument.swift"
ANALYZER = ROOT / "Sources/WapleCore/WallpaperCompatibilityAnalyzer.swift"
RENDERER = ROOT / "Sources/WapleRender/SceneRenderer.swift"
# [2026-08-21] DeepScan 은 종전에 이 게이트의 **시야 밖**이었다. 그 사이 `scanScene` 이
# `.pkg` 가 없으면 즉시 미지원으로 떨어뜨려 **설치본 씬 188/188 을 전건 오판**하고 있었다
# (두 트리에 `.pkg` 는 0개이고 렌더러는 그 188건을 정상 마운트한다). 마운트 결정을 세
# 곳이 각자 하는 한 같은 종류의 어긋남이 또 난다.
DEEPSCAN = ROOT / "Sources/WapleCompatCore/DeepScan.swift"
# [2026-08-21 클러스터 BE] 캡처 파이프라인도 같은 코퍼스 열거를 쓴다 — 종전엔 게이트 시야 밖이었다.
SNAPSHOT = ROOT / "Sources/WapleCompatCore/SnapshotPipeline.swift"
WEASSETS = ROOT / "Sources/WapleRender/Resources/WEAssets"

# 동봉 WEAssets 실측(2026-08-20): 씬 프로젝트 170개 · 전건 언팩 · `.pkg` 0개 · 전건 `scene.json`.
# 하한만 건다(자산이 늘 수는 있어도, 줄면 이 게이트가 재는 대상이 사라진 것이다).
MIN_BUNDLED_SCENE_PROJECTS = 150

_CANDIDATES = re.compile(
    r"let\s+sceneCandidates\s*:\s*\[String\]\s*=\s*\[(?P<items>[^\]]*)\]\s*\.compactMap"
)
VIDEO_EXT = {"mp4", "webm", "avi", "m4v", "mov", "wmv", "mkv"}


def fail(msg: str) -> None:
    print(f"[scene-mount-parity] 실패: {msg}", file=sys.stderr)
    raise SystemExit(1)


def candidate_items(text: str, where: str) -> list[str]:
    m = _CANDIDATES.search(text)
    if not m:
        fail(f"{where}: `let sceneCandidates: [String] = [...] .compactMap` 형태를 못 찾았다")
    return [p.strip() for p in m.group("items").split(",") if p.strip()]


def check_sources(scene_doc: str, analyzer: str, renderer: str, deepscan: str,
                  snapshot: str) -> list[str]:
    doc_items = candidate_items(scene_doc, "SceneDocument.swift")
    ana_items = candidate_items(analyzer, "WallpaperCompatibilityAnalyzer.swift")

    # ① 꼬리 리터럴이 같아야 한다.
    if doc_items[1:] != ana_items[1:]:
        fail(f"후보 꼬리가 갈렸다: SceneDocument {doc_items[1:]} vs Analyzer {ana_items[1:]}")
    if doc_items[1:] != ['"scene.json"', '"gifscene.json"']:
        fail(f"후보 꼬리가 관례 두 이름이 아니다: {doc_items[1:]}")
    # 앞머리는 각자의 파일명 변수 — 이름은 달라도 되지만 리터럴이면 안 된다
    # (리터럴로 굳으면 `project.json` 의 `file` 을 다시 무시하는 것이다).
    for items, where in ((doc_items, "SceneDocument.swift"), (ana_items, "WallpaperCompatibilityAnalyzer.swift")):
        head = items[0]
        if head.startswith('"'):
            fail(f"{where}: 후보 앞머리가 리터럴({head})이다 — project.json 의 file 을 무시하게 된다")

    # ② 스캐너의 언팩 폴백 · 렌더러의 파일명 전달
    if "ScenePackage.fromDirectory(folderURL)" not in analyzer:
        fail("Analyzer 에 `ScenePackage.fromDirectory(folderURL)` 폴백이 없다 — 언팩 씬이 다시 안 보이게 된다")
    if "sceneFileName: project.fileName" not in renderer:
        fail("SceneRenderer 가 `sceneFileName: project.fileName` 을 넘기지 않는다")
    if "ScenePackage.fromDirectory(project.folderURL)" not in renderer:
        fail("SceneRenderer 에 언팩 마운트 경로가 없다 — 이 게이트의 전제가 무너졌다")

    # ③ **마운트 선택자 단일화.** ①②는 "후보 파일명" 과 "언팩 폴백" 만 봤다. 그런데
    # 실제로 갈렸던 것은 그 앞 단계 — *pkg 를 열 것인가 폴더를 열 것인가* 였다.
    # 종전 분석기는 `scene.pkg`/`gifscene.pkg` **이름 존재**로 골라서, ⓐ `file:"techno.json"`
    # 이 없고 `techno.pkg` 가 있으면 거짓 `missingScenePackage`, ⓑ `Scene.pkg` 대소문자 표기를
    # 놓치고, ⓒ 잔존 pkg 가 있으면 디스크의 `scene.json` 대신 pkg 를 열어 **다른 씬**을 검사했다.
    # 렌더러가 쓰는 `ScenePackage.resolveMountSource` 하나로 모으는 것이 유일한 고정점이다.
    for text, label in ((analyzer, "Analyzer"), (deepscan, "DeepScan")):
        if "ScenePackage.resolveMountSource(" not in text:
            fail(f"{label}: 마운트 선택자가 렌더러(`ScenePackage.resolveMountSource`)와 다르다 — "
                 f"pkg/폴더 판정이 셋으로 갈린다")
    # ④ DeepScan 도 `project.json` 의 `file` 을 넘겨야 한다. 안 넘기면 관례 이름 두 개로만
    # 열려 설치본 4건(audiophile · fantasticcar · ricepod · techno)이 조용히 빠진다.
    if "sceneFileName: project.fileName" not in deepscan:
        fail("DeepScan 이 `SceneDocument.parse` 에 `sceneFileName` 을 안 넘긴다 — "
             "관례 이름 폴백으로 떨어져 설치본 4건이 유실된다")

    # ⑤ **코퍼스 열거 단일화(2026-08-21 클러스터 BE).** ①~④ 는 "어느 씬 문서를 여는가" 와
    #   "pkg 냐 폴더냐" 만 본다. 그 **앞 단계** — *어느 폴더가 애초에 프로젝트인가* — 는 안 봤고,
    #   거기에 사본이 셋 있었다(분석기 · DeepScan · SnapshotPipeline). 셋째는 첫 분기
    #   (`backgrounds/project.json` 존재)를 통째로 빼먹은 채 주석에는 "DeepScan 과 동일 규칙"
    #   이라고 적혀 있었다(설치본·동봉 도달 0건이라 아무도 못 봤다).
    if "public static func projectContainerURL(for" not in analyzer:
        fail("Analyzer 에 public `projectContainerURL(for:)` 정본이 없다")
    if "public static func projectFolders(in" not in analyzer:
        fail("Analyzer 에 public `projectFolders(in:)` 정본이 없다")
    for text, label in ((deepscan, "DeepScan"), (snapshot, "SnapshotPipeline")):
        if "WallpaperCompatibilityAnalyzer.projectContainerURL(for:" not in text:
            fail(f"{label}: 컨테이너 선택 사본이 되살아났다 — 정본을 부르지 않는다")
    if "WallpaperCompatibilityAnalyzer.projectFolders(in:" not in deepscan:
        fail("DeepScan: 프로젝트 폴더 열거 사본이 되살아났다 — 정본을 부르지 않는다")

    # ⑥ 조건 술어·웹 신호도 사본이 아니어야 한다(같은 라운드에서 합친 나머지 둘).
    if "WallpaperCompatibilityAnalyzer.conditionSupport(" not in deepscan:
        fail("DeepScan: 표시 조건 술어 사본이 되살아났다(`conditionSupport` 를 안 부른다)")
    if "WebBridgeSignal.signals(in:" not in deepscan:
        fail("DeepScan: 웹 브리지 탐지 문자열 사본이 되살아났다(`WebBridgeSignal` 을 안 쓴다)")
    return doc_items[1:]


def inferred_type(obj: dict) -> str | None:
    """ProjectJSONParser.parse 의 G-E3-03 확장자 추론을 그대로 흉내낸다."""
    t = obj.get("type")
    if t is not None:
        return t
    if obj.get("preset") is not None or obj.get("dependency") is not None:
        return None
    f = obj.get("file")
    if not isinstance(f, str):
        return None
    ext = os.path.splitext(f)[1].lstrip(".").lower()
    if ext == "json":
        return "scene"
    if ext in ("html", "htm"):
        return "web"
    if ext == "exe":
        return "application"
    return "video" if ext in VIDEO_EXT else None


def survey_bundled(root: Path) -> tuple[int, int, int]:
    scenes = packed = declared_present = 0
    for dp, _dirs, fns in os.walk(root):
        if "project.json" not in fns:
            continue
        try:
            obj = json.loads(Path(dp, "project.json").read_text(encoding="utf-8-sig"))
        except Exception:
            continue
        if not isinstance(obj, dict) or inferred_type(obj) != "scene":
            continue
        scenes += 1
        if Path(dp, "scene.pkg").exists() or Path(dp, "gifscene.pkg").exists():
            packed += 1
        f = obj.get("file")
        if isinstance(f, str) and Path(dp, f).exists():
            declared_present += 1
    return scenes, packed, declared_present


def main() -> None:
    tail = check_sources(SCENE_DOC.read_text(encoding="utf-8"),
                         ANALYZER.read_text(encoding="utf-8"),
                         RENDERER.read_text(encoding="utf-8"),
                         DEEPSCAN.read_text(encoding="utf-8"),
                         SNAPSHOT.read_text(encoding="utf-8"))
    print(f"[scene-mount-parity] ① 후보 꼬리 일치 {tail}")

    scenes, packed, present = survey_bundled(WEASSETS)
    if scenes < MIN_BUNDLED_SCENE_PROJECTS:
        fail(f"동봉 씬 프로젝트가 {scenes}개로 하한 {MIN_BUNDLED_SCENE_PROJECTS} 미만이다 — 측정 대상이 사라졌다")
    if present != scenes:
        fail(f"선언된 씬 문서가 실존하지 않는 프로젝트 {scenes - present}건 — 동봉 자산이 깨졌다")
    unpacked = scenes - packed
    print(f"[scene-mount-parity] ③ 동봉 씬 프로젝트 {scenes}개 · 언팩 {unpacked} · pkg {packed}")
    if unpacked == 0:
        fail("동봉 씬이 전부 pkg 다 — 언팩 경로의 도달 범위 전제가 바뀌었으니 사람이 다시 봐야 한다")


# ---------------------------------------------------------------- selftest

_GOOD_DOC = 'let sceneCandidates: [String] = [sceneFileName, "scene.json", "gifscene.json"].compactMap { $0 }'
_GOOD_ANA = ('let sceneCandidates: [String] = [project.fileName, "scene.json", "gifscene.json"].compactMap { $0 }\n'
             'ScenePackage.fromDirectory(folderURL)\n'
             'ScenePackage.resolveMountSource(\n'
             'public static func projectContainerURL(for root: URL) -> URL\n'
             'public static func projectFolders(in container: URL) throws -> [URL]\n')
_GOOD_REN = ('sceneFileName: project.fileName\nScenePackage.fromDirectory(project.folderURL)\n'
             'ScenePackage.resolveMountSource(\n')
_GOOD_DS = ('ScenePackage.resolveMountSource(\nsceneFileName: project.fileName\n'
            'WallpaperCompatibilityAnalyzer.projectContainerURL(for:\n'
            'WallpaperCompatibilityAnalyzer.projectFolders(in:\n'
            'WallpaperCompatibilityAnalyzer.conditionSupport(\n'
            'WebBridgeSignal.signals(in:\n')
_GOOD_SNAP = 'WallpaperCompatibilityAnalyzer.projectContainerURL(for:\n'


def _expect_fail(label: str, fn) -> None:
    try:
        fn()
    except SystemExit as e:
        if e.code != 0:
            print(f"    음성대조 OK: {label}")
            return
    print(f"[scene-mount-parity] 자가검사 실패: {label} 가 통과해버렸다", file=sys.stderr)
    raise SystemExit(1)


def selftest() -> None:
    # 정상 조합은 통과해야 한다
    check_sources(_GOOD_DOC, _GOOD_ANA, _GOOD_REN, _GOOD_DS, _GOOD_SNAP)
    print("    양성대조 OK: 정상 조합 통과")

    _expect_fail("스캐너 후보가 하드코딩으로 되돌아감",
                 lambda: check_sources(_GOOD_DOC,
                                       'let sceneCandidates: [String] = ["scene.json", "gifscene.json"].compactMap { $0 }\n'
                                       'ScenePackage.fromDirectory(folderURL)\nScenePackage.resolveMountSource(\n', _GOOD_REN, _GOOD_DS, _GOOD_SNAP))
    _expect_fail("꼬리가 한쪽만 늘어남",
                 lambda: check_sources(_GOOD_DOC,
                                       'let sceneCandidates: [String] = [project.fileName, "scene.json"].compactMap { $0 }\n'
                                       'ScenePackage.fromDirectory(folderURL)\nScenePackage.resolveMountSource(\n', _GOOD_REN, _GOOD_DS, _GOOD_SNAP))
    _expect_fail("스캐너 언팩 폴백 제거",
                 lambda: check_sources(_GOOD_DOC,
                                       'let sceneCandidates: [String] = [project.fileName, "scene.json", "gifscene.json"].compactMap { $0 }\n'
                                       'ScenePackage.resolveMountSource(\n',
                                       _GOOD_REN, _GOOD_DS, _GOOD_SNAP))
    _expect_fail("렌더러가 파일명을 안 넘김",
                 lambda: check_sources(_GOOD_DOC, _GOOD_ANA,
                                       'ScenePackage.fromDirectory(project.folderURL)\nScenePackage.resolveMountSource(\n',
                                       _GOOD_DS, _GOOD_SNAP))
    _expect_fail("렌더러 언팩 경로 제거",
                 lambda: check_sources(_GOOD_DOC, _GOOD_ANA,
                                       'sceneFileName: project.fileName\nScenePackage.resolveMountSource(\n',
                                       _GOOD_DS, _GOOD_SNAP))
    _expect_fail("DeepScan 이 렌더러와 다른 마운트 선택자를 쓴다",
                 lambda: check_sources(_GOOD_DOC, _GOOD_ANA, _GOOD_REN,
                                       'sceneFileName: project.fileName\n', _GOOD_SNAP))
    _expect_fail("Analyzer 가 렌더러와 다른 마운트 선택자를 쓴다",
                 lambda: check_sources(_GOOD_DOC,
                                       'let sceneCandidates: [String] = [project.fileName, "scene.json", "gifscene.json"].compactMap { $0 }\n'
                                       'ScenePackage.fromDirectory(folderURL)\n',
                                       _GOOD_REN, _GOOD_DS, _GOOD_SNAP))
    _expect_fail("DeepScan 이 sceneFileName 을 안 넘김",
                 lambda: check_sources(_GOOD_DOC, _GOOD_ANA, _GOOD_REN,
                                       'ScenePackage.resolveMountSource(\n', _GOOD_SNAP))
    _expect_fail("후보 선언 형태 자체가 사라짐",
                 lambda: check_sources("// nothing here", _GOOD_ANA, _GOOD_REN, _GOOD_DS, _GOOD_SNAP))

    with tempfile.TemporaryDirectory() as td:
        empty = Path(td) / "empty"
        empty.mkdir()
        _expect_fail("동봉 코퍼스가 비었을 때", lambda: _survey_gate(empty))

        packed = Path(td) / "packed"
        for i in range(MIN_BUNDLED_SCENE_PROJECTS):
            d = packed / f"p{i}"
            d.mkdir(parents=True)
            (d / "project.json").write_text('{"type":"scene","file":"scene.json"}')
            (d / "scene.json").write_text("{}")
            (d / "scene.pkg").write_bytes(b"x")
        _expect_fail("동봉 씬이 전부 pkg 일 때", lambda: _survey_gate(packed))
    print("selftest: OK")


def _survey_gate(root: Path) -> None:
    scenes, packed, present = survey_bundled(root)
    if scenes < MIN_BUNDLED_SCENE_PROJECTS:
        fail(f"동봉 씬 프로젝트가 {scenes}개로 하한 미만")
    if present != scenes:
        fail("선언된 씬 문서가 실존하지 않는 프로젝트가 있다")
    if scenes - packed == 0:
        fail("동봉 씬이 전부 pkg 다")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    main()
    print("[scene-mount-parity] OK")
