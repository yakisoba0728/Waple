"""WE `g_Brightness` 정본 — 선언 철자·HDR 게이트·소비 위치 + 코퍼스 도달 → spec/engine/material-brightness.json.

왜 별도 문서인가: 이 유니폼은 **같은 값인데 셰이더마다 머티리얼 키 철자가 다르다.**
generic2 는 `Brigtness`(WE 자신의 오타), PBR 레인은 `brightness`, 2D 레인은 `Bright`/`Brightness`.
철자를 교정해 읽으면 저작값을 영영 못 만나고, 레인을 뭉뚱그려 읽으면 WE 가 무시하는 값을 곱한다.
shaders.json 은 파일별 uniform 표를 담지만 "어느 철자를 언제 읽어야 하는가" 는 담지 않는다.

셰이더 사실은 리포에 동봉된 WEAssets 만으로 재현된다(WE 설치본 불요). 코퍼스 도달은
`WE_WORKSHOP` 이 필요하고, 없으면 도달 항목을 **빼는 게 아니라 실패시킨다**(부분 산출 금지 —
measure_shaders.py 와 같은 규약).

재현: WE_WORKSHOP=<워크샵루트> python scripts/spec/measure_material_brightness.py
      (git status 가 비어야 정상)
"""
import collections
import json
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SHADERS = os.path.join(REPO, "Sources", "WapleRender", "Resources", "WEAssets", "shaders")
OUT = os.path.join(REPO, "spec", "engine", "material-brightness.json")
WE_WORKSHOP = os.environ.get("WE_WORKSHOP", r"Z:\SteamLibrary\steamapps\workshop\content\431960")

RE_DECL = re.compile(
    r"^\s*uniform\s+float\s+g_Brightness\s*;[ \t]*(?://\s*(\{.*\}))?\s*$", re.M)
RE_USE = re.compile(r"^\s*(\w+)\.rgb\s*\*=\s*g_Brightness\s*;", re.M)
# 최종색 변수에 대한 복합대입 전부 — 이 순서열이 곧 "언제 곱하는가" 의 근거다.
# (원문 전사가 아니라 줄번호 + 연산자 + 전처리 가드만 남긴다 — spec/README §3)
RE_WRITE = re.compile(r"^\s*(\w+)\.rgb\s*([*+\-/]?=)\s*(.*)$", re.M)
RE_COND = re.compile(r"^\s*#\s*(if|ifdef|ifndef|else|elif|endif)\b(.*)$")


def enclosing_conditions(lines, index):
    """index 줄을 감싸는 전처리 조건 스택을 재구성한다(#else 는 !(…) 로 표기)."""
    stack = []
    for i in range(index):
        m = RE_COND.match(lines[i])
        if not m:
            continue
        kind, rest = m.group(1), m.group(2).strip()
        if kind in ("if", "ifdef", "ifndef"):
            stack.append(("!" + rest if kind == "ifndef" else rest).strip())
        elif kind == "endif":
            if stack:
                stack.pop()
        elif kind == "else":
            if stack:
                stack[-1] = "!(%s)" % stack[-1]
        elif kind == "elif":
            if stack:
                stack[-1] = rest
    return stack


def color_writes(text, lines, target):
    """최종색 변수의 복합대입 순서열. `operand` 는 원문이 아니라 **분류 라벨**이다."""
    out = []
    for m in RE_WRITE.finditer(text):
        if m.group(1) != target:
            continue
        idx = text[:m.start()].count("\n")
        rhs = m.group(3)
        if "g_Brightness" in rhs and "Emissive" not in rhs:
            kind = "g_Brightness"
        elif "Emissive" in rhs or "emissive" in rhs:
            kind = "emissive"
        elif "reflection" in rhs.lower():
            kind = "reflection"
        elif "ApplyFog" in rhs:
            kind = "fog"
        elif "light" in rhs or "Lighting" in rhs:
            kind = "lighting"
        else:
            kind = "other"
        out.append({"line": idx + 1, "op": m.group(2), "operand": kind,
                    "guardedBy": enclosing_conditions(lines, idx)})
    return out


def scan_shaders():
    """동봉 WEAssets 를 훑어 g_Brightness 선언/소비를 뽑는다."""
    out = {}
    for name in sorted(os.listdir(SHADERS)):
        if not name.endswith((".frag", ".vert", ".h")):
            continue
        path = os.path.join(SHADERS, name)
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        if "g_Brightness" not in text:
            continue
        lines = text.split("\n")
        decl = RE_DECL.search(text)
        meta = {}
        if decl and decl.group(1):
            try:
                meta = json.loads(decl.group(1))
            except ValueError:
                meta = {}
        uses = []
        for m in RE_USE.finditer(text):
            idx = text[:m.start()].count("\n")
            uses.append({
                "target": m.group(1),
                "line": idx + 1,
                "guardedBy": enclosing_conditions(lines, idx),
            })
        entry = {
            "materialKey": meta.get("material"),
            "default": meta.get("default"),
            "range": meta.get("range"),
            "label": meta.get("label"),
            "hdrGated": all("HDR" in " ".join(u["guardedBy"]) for u in uses) if uses else None,
            "uses": uses,
        }
        # 소비 위치는 "몇 번째 줄" 이 아니라 **최종색 대입 순서열의 어디** 인가로 남긴다.
        if uses:
            entry["colorWriteSequence"] = color_writes(text, lines, uses[0]["target"])
        out[name] = entry
    return out


def parse_pkg(data):
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
    cnt = i32()
    if cnt < 0 or cnt > 65536:
        raise ValueError("bad count")
    out = []
    for _ in range(cnt):
        nl = i32()
        if nl < 0 or p + nl > n:
            raise ValueError("bad nlen")
        name = data[p:p + nl].decode("utf-8", "ignore")
        p += nl
        out.append((name, i32(), i32()))
    return out, p


def unwrap(v):
    return v.get("value") if isinstance(v, dict) else v


def scan_corpus(spellings):
    """머티리얼 JSON 전수 — (키, 셰이더) 별 건수/씬 + 씬 HDR 여부. 콤보 HDR 저작 건수도 센다."""
    hits = collections.Counter()
    scenes = collections.defaultdict(set)
    hdr_scenes = set()
    combo_hdr = 0
    pkgs = materials = 0
    for wid in sorted(os.listdir(WE_WORKSHOP)):
        d = os.path.join(WE_WORKSHOP, wid)
        if not os.path.isdir(d):
            continue
        for fn in ("scene.pkg", "gifscene.pkg"):
            path = os.path.join(d, fn)
            if not os.path.exists(path):
                continue
            with open(path, "rb") as fh:
                data = fh.read()
            try:
                entries, base = parse_pkg(data)
            except ValueError:
                continue
            pkgs += 1
            for name, off, size in entries:
                if not name.endswith(".json"):
                    continue
                raw = data[base + off:base + off + size].decode("utf-8", "ignore")
                try:
                    j = json.loads(raw)
                except ValueError:
                    continue
                if not isinstance(j, dict):
                    continue
                if name.endswith("scene.json"):
                    if unwrap((j.get("general") or {}).get("hdr")) in (True, 1):
                        hdr_scenes.add(wid)
                    continue
                passes = j.get("passes")
                if not isinstance(passes, list):
                    continue
                materials += 1
                for ps in passes:
                    if not isinstance(ps, dict):
                        continue
                    combos = ps.get("combos")
                    if isinstance(combos, dict):
                        combo_hdr += sum(1 for k in combos if k.lower() == "hdr")
                    csv = ps.get("constantshadervalues")
                    if not isinstance(csv, dict):
                        continue
                    shader = ps.get("shader") or "(none)"
                    for k in csv:
                        if k.lower() in spellings:
                            hits[(k, shader)] += 1
                            scenes[(k, shader)].add(wid)
    return hits, scenes, hdr_scenes, combo_hdr, pkgs, materials


def main():
    if not os.path.isdir(SHADERS):
        sys.exit("동봉 셰이더가 없다: %s" % SHADERS)
    if not os.path.isdir(WE_WORKSHOP):
        sys.exit("코퍼스가 없다: %s — WE_WORKSHOP 로 지정할 것(부분 산출 금지)" % WE_WORKSHOP)

    decls = scan_shaders()
    keys = sorted({d["materialKey"] for d in decls.values() if d["materialKey"]})
    spellings = {k.lower() for k in keys}
    hits, scenes, hdr_scenes, combo_hdr, pkgs, materials = scan_corpus(spellings)

    reach = {}
    for (k, shader), count in sorted(hits.items(), key=lambda x: (-x[1], x[0])):
        sc = scenes[(k, shader)]
        reach["%s @ %s" % (k, shader)] = {
            "materials": count,
            "scenes": len(sc),
            "sceneIds": sorted(sc),
            "hdrScenes": len(sc & hdr_scenes),
        }

    shader_ev = specfmt.ev("asset", "Sources/WapleRender/Resources/WEAssets/shaders (WE 2.8.42 동봉본)")
    script_ev = specfmt.ev("script", "scripts/spec/measure_material_brightness.py")
    corpus_ev = specfmt.ev("corpus", "워크샵 scene.pkg %d개 / 머티리얼 JSON %d건 전수" % (pkgs, materials))

    entries = [
        specfmt.entry("shaders.materialBrightness.declarations", {
            "note": "같은 유니폼(g_Brightness)인데 셰이더마다 머티리얼 키 철자가 다르다. "
                    "`Brigtness` 는 오타가 아니라 **WE 원문 그대로**이며 generic2 에만 있다.",
            "byShader": decls,
            "keys": keys,
        }, "확정", [shader_ev, script_ev]),

        specfmt.entry("shaders.materialBrightness.consumptionOrder", {
            "rule": "메시 레인(generic2/3/4·chroma4·fur4·foliage4)은 라이팅+반사 결과에 곱한다 — "
                    "알베도 샘플 직후가 아니다. 순서: CombineLighting → REFLECTION 가산 → "
                    "**g_Brightness 곱** → ApplyFog.",
            "derivedFrom": "위 byShader 의 colorWriteSequence — 최종색 변수에 대한 복합대입을 순서대로 "
                           "나열한 것이다. g_Brightness 대입이 lighting/reflection 대입 **뒤**, fog 대입 "
                           "**앞**에 온다(generic3/4 는 그 뒤에 같은 HDR 블록 안의 emissive overbright 가산이 하나 더 붙는다).",
            "lightingIndependent": "곱은 `#if HDR` 안에만 있고 LIGHTING 콤보 밖이다 — unlit 머티리얼도 곱해진다.",
            "twoDLaneIsDifferent": "genericimage(`Bright`)·genericimage2(`Brightness`)는 HDR 게이트가 없고 "
                                   "알베도 샘플 직후에 곱한다. 이름만 같은 **다른 규약**이다.",
        }, "확정", [shader_ev, script_ev]),

        specfmt.entry("shaders.materialBrightness.corpusReach", {
            "byKeyAndShader": reach,
            "materialsAuthoringHDRCombo": combo_hdr,
            "hdrScenes": len(hdr_scenes),
            "observation": "메시 레인 키(Brigtness/brightness)를 저작한 씬은 전건 hdr:true 고, "
                           "HDR 게이트가 없는 2D 레인 키(Bright/Brightness)를 저작한 씬은 전건 hdr:false 다. "
                           "저작 분포가 셰이더의 게이트와 일치한다.",
        }, "확정", [corpus_ev, script_ev]),

        specfmt.entry("shaders.materialBrightness.hdrGateInjection", {
            "claim": "`HDR` 매크로는 씬의 HDR 파이프라인 활성 여부로 엔진이 주입한다(머티리얼 저작 대상 아님)",
            "for": [
                "shaders.combos.engineInjected(확정) 이 HDR 을 '#if 로 참조되지만 어디에도 선언이 없다' 로 분류한다",
                "코퍼스 머티리얼에서 HDR 콤보를 저작한 건수 0 (위 materialsAuthoringHDRCombo)",
                "engine.renderPass 의 씬 플래그 bit13 이 LDR 3패스 블룸 / HDR 피라미드를 가른다(비트 위치 확정)",
                "PBR 레인 선언 라벨이 `ui_editor_properties_hdr_brightness` 다",
            ],
            "notEstablished": "bit13 ↔ scene general.hdr 의 대응은 디스어셈에서 확인되지 않았다"
                              "(engine.renderPass.* 의 '각 비트의 저작(UI) 이름 대응은 미확인' 과 같은 공백). "
                              "그래서 이 항목은 추정이다 — 구현은 이 값에 의존한다.",
            "wapleChoice": "Waple 은 sceneIsHDR(= general.hdr && HDR 톤맵 패스 빌드 성공)로 게이트한다. "
                           "LDR 폴백에는 1 초과분을 흡수할 saturate 패스가 없어 그대로 백화가 되기 때문이다.",
        }, "추정", [shader_ev, corpus_ev,
                    specfmt.ev("file", "spec/engine/shaders.json shaders.combos.engineInjected"),
                    specfmt.ev("file", "spec/engine/render-pass.json engine.renderPass.* (씬 플래그 bit13)")]),

        specfmt.entry("shaders.materialBrightness.wapleWiring", {
            "parse": "Sources/WapleRender/Scene3DLighting.swift — Scene3DMaterialValues.brightnessKey/parse",
            "uniform": "MeshUniform.extra.x ↔ MSL MeshU.extra.x (Mesh3DShaders.applyHDRBrightness)",
            "encode": [
                "Sources/WapleRender/SceneRenderer3D.swift encode3D (perspective 3D)",
                "Sources/WapleRender/SceneRendererFrameEncoder.swift runOrtho3DMeshes (ortho 하이브리드)",
            ],
            "notImplemented": "2D 레인(genericimage `Bright` · genericimage2 `Brightness`). "
                              "게이트도 소비 위치도 달라 메시 레인 규약을 그대로 쓸 수 없다.",
            "tests": "Tests/WapleRenderTests/SceneRendererMeshBrightnessTests.swift",
        }, "확정", [specfmt.ev("file", "Sources/WapleRender/Scene3DLighting.swift"),
                    specfmt.ev("file", "Sources/WapleRender/Mesh3DShaders.swift"),
                    specfmt.ev("file", "Tests/WapleRenderTests/SceneRendererMeshBrightnessTests.swift")]),
    ]

    specfmt.dump(specfmt.doc("scripts/spec/measure_material_brightness.py", entries), OUT)

    print("셰이더 %d개에 g_Brightness 선언/소비" % len(decls))
    for name in sorted(decls):
        d = decls[name]
        print("  %-22s key=%-12s default=%s hdrGated=%s" %
              (name, d["materialKey"], d["default"], d["hdrGated"]))
    print("코퍼스 pkg %d / 머티리얼 %d / HDR 씬 %d / HDR 콤보 저작 %d" %
          (pkgs, materials, len(hdr_scenes), combo_hdr))
    for k, v in reach.items():
        print("  %-28s 머티리얼 %3d · 씬 %2d (hdr %d)" % (k, v["materials"], v["scenes"], v["hdrScenes"]))


if __name__ == "__main__":
    main()
