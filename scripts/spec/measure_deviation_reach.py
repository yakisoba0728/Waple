"""의도적 이탈 3건이 실제로 어느 씬에 닿는지 측정한다.

셋 다 [0,1] 입력에서는 WE 와 등가고 HDR >1 / 음수 / 경계값에서만 갈린다.
그래서 "몇 씬에 영향" 이 곧 A/B 캡처 대상이다. 도달 경로가 셋 다 다르다:

  D1 GGX 분모 바닥값 1e-4   -> 3D 메시 PBR 경로(objects[].model + 라이트)
     ScenePBRLighting.swift:7,15 (CPU) · Mesh3DShaders.swift:171 (MSL)
  D2 nl/nv 하한 0.001       -> 같은 경로(ScenePBRMath.geometry)
  D3 블렌드 엡실론 1e-5     -> colorBlendMode != 0 레이어/텍스트
     (WE 는 정확 비교 blend==0.0 / ==1.0)

HDR 씬만 갈리는 이유: 감마 공간 합성이라 [0,1] 밖 값은 HDR 경로에서만 나온다.
"""
import collections
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WS = os.environ.get("WE_WORKSHOP", r"Z:\SteamLibrary\steamapps\workshop\content\431960")


def parse_pkg(data):
    n, p = len(data), 0

    def i32():
        nonlocal p
        v = struct.unpack_from("<i", data, p)[0]
        p += 4
        return v

    vlen = i32()
    p += vlen
    cnt = i32()
    out = []
    for _ in range(cnt):
        nl = i32()
        name = data[p:p + nl].decode("utf-8", "ignore")
        p += nl
        out.append((name, i32(), i32()))
    return out, p


def unwrap(v):
    """{user,value} / {script,value} 바인딩에서 값을 꺼낸다."""
    if isinstance(v, dict):
        return v.get("value")
    return v


def main():
    specfmt.require_inputs("measure_deviation_reach",
                           ("dir", WS, "WE_WORKSHOP", "워크샵 코퍼스"))
    hdr, model3d, lit, blend_nonzero = set(), set(), set(), set()
    blend_modes = collections.Counter()
    hdr_and_model, hdr_and_blend = set(), set()
    scenes = 0

    for wid in sorted(os.listdir(WS)):
        d = os.path.join(WS, wid)
        if not os.path.isdir(d):
            continue
        for fn in ("scene.pkg", "gifscene.pkg"):
            path = os.path.join(d, fn)
            if not os.path.exists(path):
                continue
            data = open(path, "rb").read()
            try:
                entries, base = parse_pkg(data)
            except Exception:
                continue
            sj = next((e for e in entries if e[0] in ("scene.json", "gifscene.json")), None)
            if not sj:
                continue
            _, off, size = sj
            try:
                scene = json.loads(data[base + off:base + off + size].decode("utf-8", "ignore"))
            except Exception:
                continue
            scenes += 1
            gen = scene.get("general") or {}
            is_hdr = bool(unwrap(gen.get("hdr")))
            if is_hdr:
                hdr.add(wid)

            has_model = has_light = False
            has_blend = False
            for o in scene.get("objects") or []:
                if not isinstance(o, dict):
                    continue
                if isinstance(o.get("model"), str):
                    has_model = True
                if isinstance(o.get("light"), str):
                    has_light = True
                cbm = o.get("colorBlendMode")
                if isinstance(cbm, (int, float)) and int(cbm) != 0:
                    has_blend = True
                    blend_modes[int(cbm)] += 1

            if has_model:
                model3d.add(wid)
            if has_light:
                lit.add(wid)
            if has_blend:
                blend_nonzero.add(wid)
            # [정정 2026-08-01] 종전엔 model 만으로 D1/D2 도달을 셌다. 틀렸다 —
            # PBR 루프는 라이트가 있어야 돈다. 3509243656 은 모델 8개인데 라이트 0이라
            # 대상에 넣었지만 GGX 경로를 아예 타지 않았다(A/B 실측으로 드러남).
            if is_hdr and has_model and has_light:
                hdr_and_model.add(wid)
            if is_hdr and has_blend:
                hdr_and_blend.add(wid)

    ev = specfmt.ev("corpus", f"코퍼스 scene.json {scenes}종 전수 파싱",
                    "general.hdr / objects[].model / objects[].light / colorBlendMode")
    code = lambda p: specfmt.ev("file", p)

    out = [
        specfmt.entry("deviation.reach.scenesScanned", scenes, "확정", [ev]),
        specfmt.entry("deviation.reach.hdrScenes",
                      {"count": len(hdr), "ids": sorted(hdr)}, "확정", [ev]),
        specfmt.entry("deviation.D1D2.ggxAndNlFloor", {
            "what": "GGX 분모 바닥값 1e-4 · nl/nv 하한 0.001",
            "where": ["Sources/WapleCore/ScenePBRLighting.swift:7,15,27,28",
                      "Sources/WapleRender/Mesh3DShaders.swift:171"],
            "path": "3D 메시 PBR — objects[].model 과 objects[].light 를 둘 다 가진 씬(라이트 없으면 PBR 루프 자체를 안 탄다)",
            "reachAllScenes": {"count": len(model3d & lit), "ids": sorted(model3d & lit)},
            "reachHDROnly": {"count": len(hdr_and_model), "ids": sorted(hdr_and_model)},
            "note": "[0,1] 입력에서는 WE 와 등가라 비-HDR 씬은 A/B 가 동일해야 한다. "
                    "그게 A/B 의 대조군이 된다 — 비-HDR 3D 씬이 바뀌면 수정이 잘못된 것이다.",
        }, "확정", [ev, code("Sources/WapleCore/ScenePBRLighting.swift"),
                    code("Sources/WapleRender/Mesh3DShaders.swift")]),
        specfmt.entry("deviation.D3.blendEpsilon", {
            "what": "블렌드 엡실론 1e-5 (WE 는 정확 비교 blend==0.0 / ==1.0)",
            "path": "colorBlendMode != 0 인 레이어/텍스트",
            "reachAllScenes": {"count": len(blend_nonzero), "ids": sorted(blend_nonzero)},
            "reachHDROnly": {"count": len(hdr_and_blend), "ids": sorted(hdr_and_blend)},
            "modeDistribution": dict(blend_modes.most_common()),
        }, "확정", [ev]),
        specfmt.entry("deviation.reach.abPlan", {
            "sideA": "spec/golden/snapshot/baseline-81098bb (변경 전, 이미 커밋됨)",
            "sideB": "이탈 3건 제거 후 재캡처",
            "primaryTargets": sorted(hdr),
            "controlGroup": sorted(model3d - hdr),
            "controlExpectation": "비-HDR 3D 씬은 [0,1] 입력이라 A/B 가 동일해야 한다. "
                                  "바뀌면 수정이 의도 밖 경로를 건드린 것이다.",
        }, "확정", [ev]),
    ]

    specfmt.dump(specfmt.doc("scripts/spec/measure_deviation_reach.py", out),
                 os.path.join("spec", "engine", "deviation-reach.json"))

    print(f"씬 {scenes}종 스캔")
    print(f"  HDR                : {len(hdr):3}종")
    print(f"  3D 메시(model)     : {len(model3d):3}종")
    print(f"  라이트 보유        : {len(lit):3}종")
    print(f"  colorBlendMode !=0 : {len(blend_nonzero):3}종")
    print()
    print(f"  D1/D2 도달(전체)   : {len(model3d):3}종   HDR 한정: {len(hdr_and_model):3}종")
    print(f"  D3   도달(전체)    : {len(blend_nonzero):3}종   HDR 한정: {len(hdr_and_blend):3}종")
    print()
    print(f"  HDR 씬 목록: {sorted(hdr)}")
    print(f"  HDR ∩ 3D  : {sorted(hdr_and_model)}")


if __name__ == "__main__":
    main()
