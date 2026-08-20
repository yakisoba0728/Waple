#!/usr/bin/env python3
"""동봉 파티클 자산의 **도수 정본**을 만든다.

## 왜 있나

소스 주석이 "동봉 N건 중 M건" 형태로 도달 수를 적어 두는데, 그 숫자들이 **범위 표기 없이**
쓰여서 서로 어긋났다. 2026-08-20 실측으로 확인한 것:

  · `controlpointattract` "35인스턴스"   → 실제 all 34 · unique 29 (**어느 쪽도 아님**)
  · `angularvelocityrandom` "25건 중 4건" → all 46/8 · unique 26/4 (unique 쪽이 근사)
  · `oscillatealpha` "26건 중 3·2"        → all 36/6·4 · unique 24/3·2
  · `alphafade` "177건 중 97건"           → all 250/138 · unique 178/94

원인은 둘이다. (a) 범위를 안 적었다. (b) 동봉 트리에는 프리셋 원본과 **바이트 동일한 프리뷰
사본**이 섞여 있어 그냥 세면 거의 두 배가 된다.

그래서 두 범위를 **둘 다** 낸다:
  · `all`    — 파일 전수(사본 포함). "런타임이 실제로 마주치는 인스턴스 수" 에 가깝다.
  · `unique` — 파일 **내용 sha256** 중복 제거. "저작자가 만든 서로 다른 설정 수" 에 가깝다.

어느 쪽이 옳은지는 질문에 달렸으므로 고르지 않고 둘 다 기록한다 — 대신 **범위 없는 숫자를
주석에 쓰지 말 것**. 이 정본을 가리켜라.
"""
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import specfmt  # noqa: E402

REPO = os.path.dirname(os.path.dirname(HERE))
ASSETS = os.path.join(REPO, "Sources", "WapleRender", "Resources", "WEAssets")
OUT = os.path.join(REPO, "spec", "assets", "particle-corpus.json")

# 주석이 인용하는 원소와 키. 여기 없는 것을 주석에 쓰려면 먼저 여기 추가하라.
WATCH = {
    "operator": {
        "alphafade": ["fadeintime", "fadeouttime"],
        "controlpointattract": ["controlpoint", "flags", "deletethreshold", "threshold", "scale"],
        "vortex": ["distanceinner", "distanceouter", "speedinner", "speedouter", "axis", "flags"],
        "vortex_v2": ["ringradius", "ringpullforce", "centerforce", "flags", "speedouter"],
        "oscillatealpha": ["frequencymin", "frequencymax", "scalemin", "scalemax"],
        "oscillatesize": ["frequencymin", "frequencymax", "scalemin", "scalemax"],
        "oscillateposition": ["scalemin", "scalemax", "mask"],
        "turbulence": ["scale", "timescale", "mask", "speedmin", "speedmax"],
        "boids": ["separationthreshold", "maxspeed", "flags"],
        "maintaindistancetocontrolpoint": ["distance", "variablestrength", "controlpoint"],
        "reducemovementnearcontrolpoint": ["distanceinner", "distanceouter", "controlpoint"],
        "capvelocity": ["maxspeed", "blendinstart", "blendinend"],
        "remapvalue": ["blendinstart", "blendoutstart"],
    },
    "initializer": {
        "alpharandom": ["min", "max"],
        "angularvelocityrandom": ["min", "max"],
        "hsvcolorrandom": ["saturationmin", "saturationmax", "huesteps"],
        "turbulentvelocityrandom": ["speedmin", "speedmax", "scale"],
        "inheritcontrolpointvelocity": ["min", "max", "controlpoint"],
        "lifetimerandom": ["min", "max"],
    },
    "emitter": {
        "boxrandom": ["distancemax", "rate"],
        "sphererandom": ["distancemax", "rate"],
        "layerimage": ["speed", "rate"],
    },
}


def scan():
    """(doc, is_duplicate) 를 순서대로. 중복 판정은 파일 내용 sha256."""
    seen = set()
    for dirpath, dirs, files in os.walk(ASSETS):
        dirs.sort()
        for fn in sorted(files):
            if not fn.endswith(".json"):
                continue
            path = os.path.join(dirpath, fn)
            try:
                with open(path, "rb") as fh:
                    raw = fh.read()
                doc = json.loads(raw.decode("utf-8", "replace"))
            except (OSError, ValueError):
                continue
            if not isinstance(doc, dict):
                continue
            digest = hashlib.sha256(raw).hexdigest()
            dup = digest in seen
            seen.add(digest)
            yield doc, dup


def main():
    docs = list(scan())
    entries = []
    for section, elements in WATCH.items():
        table = {}
        for name, keys in sorted(elements.items()):
            total = {"all": 0, "unique": 0}
            absent = {k: {"all": 0, "unique": 0} for k in keys}
            for doc, dup in docs:
                for e in (doc.get(section) or []):
                    if not isinstance(e, dict):
                        continue
                    if str(e.get("name", "")).lower() != name:
                        continue
                    total["all"] += 1
                    if not dup:
                        total["unique"] += 1
                    for k in keys:
                        if k not in e:
                            absent[k]["all"] += 1
                            if not dup:
                                absent[k]["unique"] += 1
            table[name] = {"instances": total, "keyAbsent": absent}
        entries.append(specfmt.entry(
            f"particleCorpus.{section}",
            table, "확정",
            [specfmt.ev("asset", "Sources/WapleRender/Resources/WEAssets/**/*.json",
                        "all = 파일 전수(프리뷰 사본 포함) · unique = 파일 내용 sha256 중복 제거")]))

    doc = specfmt.doc("scripts/spec/measure_particle_corpus.py", entries, extra={
        "note": "주석에 도수를 쓸 때는 반드시 all/unique 중 어느 범위인지 밝히고 이 정본을 "
                "근거로 삼을 것. 범위 없는 숫자가 서로 어긋난 사고가 실제로 있었다.",
    })
    specfmt.dump(doc, OUT)
    print(f"{os.path.relpath(OUT, REPO)} — 섹션 {len(entries)}")
    for e in entries:
        for name, t in sorted(e["value"].items()):
            i = t["instances"]
            print(f"  {name:<32} all {i['all']:>3} / unique {i['unique']:>3}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
