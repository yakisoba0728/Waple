"""파티클 필드 전수 조사 — spec/engine/particle-fields.json.

"파티클 오퍼레이터 WE 기본값 테이블이 없어 최대 114씬이 틀린다" 는 인계 산문을 검증하려고
만들었다. 측정해 보니 문제의 **모양이 달랐다**. 위험이 두 갈래인데 산문이 둘을 섞고 있었다:

  (1) Waple 이 **아예 안 읽는** 필드 — 저작 의도가 통째로 버려진다.
      위험 크기 = 그 필드가 **명시된** 인스턴스 수. 생략된 건 어차피 기본값이라 무해할 수 있다.
  (2) Waple 이 `?? X` 로 읽는 필드 — X 가 WE 기본값과 다르면 틀린다.
      위험 크기 = 그 필드가 **생략된** 인스턴스 수.

(1) 은 present 로, (2) 는 omitted 로 줄을 세워야 한다. "생략이 많은 필드부터" 로 보면
안 읽는 필드는 생략률이 높을수록 오히려 안전한데 그게 뒤집힌다.

가장 큰 발견은 오퍼레이터 기본값이 아니라 **시스템 레벨 flags 비트 4** 였다:
70씬이 저작하는데 Waple 은 파스만 하고 렌더가 안 쓴다.

주의(1차 시도의 오류): 소스 전체에서 `["키"]` 를 긁어 "읽는 키" 집합 하나로 만들면 안 된다.
`flags` 는 시스템 레벨 필드로 존재하지만 이미터 파스 블록은 `e["flags"]` 를 읽지 않는다.
그래서 키 매칭은 **`case "<이름>":` 블록 단위**로 해야 한다.

usage:
    python scripts/spec/measure_particle_fields.py
"""
import collections
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import measure_tex_deep as T
import specfmt

OUT = os.path.join("spec", "engine", "particle-fields.json")
PSRC = os.path.join("Sources", "WapleCore", "ParticleSystem.swift")
CASE = re.compile(r'^\s*case ((?:"[a-z0-9_]+"(?:,\s*)?)+)\s*:', re.M)
KEY = re.compile(r'\[\s*"([a-z0-9_]+)"\s*\]')
CONTROL = {"name", "id", "visible"}
SECTIONS = ("emitter", "initializer", "operator")


def waple_block_keys():
    """`case "<이름>":` 블록별로 읽는 키. 헬퍼 호출은 헬퍼의 키를 블록에 합산한다."""
    src = open(PSRC, encoding="utf-8").read()
    audio = {"audioprocessingmode", "audioprocessingfrequencystart",
             "audioprocessingfrequencyend", "audioprocessingbounds", "audioprocessingexponent"}
    periodic = {"minperiodicduration", "maxperiodicduration", "minperiodicdelay",
                "maxperiodicdelay", "maxtoemitperperiod"}
    marks = [(m.start(), m.group(1)) for m in CASE.finditer(src)]
    out = collections.defaultdict(set)
    for i, (pos, names) in enumerate(marks):
        body = src[pos:marks[i + 1][0] if i + 1 < len(marks) else len(src)]
        ks = set(KEY.findall(body))
        if "AudioProcessing.parse" in body:
            ks |= audio
        if "parsePeriodic" in body:
            ks |= periodic
        for n in re.findall(r'"([a-z0-9_]+)"', names):
            out[n] |= ks
    # 이미터 루프 본문(케이스 밖)에서 공통으로 읽는 키
    anchor = src.find('for case let e as [String: Any] in (json["emitter"]')
    common = set(KEY.findall(src[anchor:anchor + 1200])) if anchor >= 0 else set()
    return out, common


def scan():
    r = {
        "files": 0, "instances": 0,
        "opCount": collections.Counter(),
        "present": collections.defaultdict(collections.Counter),   # op -> field -> 명시 수
        "opScenes": collections.defaultdict(set),
        "fieldScenes": collections.defaultdict(set),               # (op, field) -> 명시 씬
        "sysFlagsValues": collections.Counter(),
        "sysFlagBitScenes": collections.defaultdict(set),
        "particleScenes": set(),
        "explicitValues": collections.defaultdict(collections.Counter),
    }
    for wid in sorted(os.listdir(T.WS)):
        d = os.path.join(T.WS, wid)
        pkg = next((os.path.join(d, f) for f in ("scene.pkg", "gifscene.pkg")
                    if os.path.exists(os.path.join(d, f))), None)
        if not pkg:
            continue
        raw = open(pkg, "rb").read()
        try:
            _, entries, base = T.parse_pkg(raw)
        except Exception:
            continue
        for name, off, size in entries:
            if not name.lower().endswith(".json"):
                continue
            blob = raw[base + off:base + off + size]
            if b'"emitter"' not in blob and b'"initializer"' not in blob:
                continue
            try:
                j = json.loads(blob.decode("utf-8-sig", "replace"))
            except Exception:
                continue
            if not isinstance(j, dict) or ("emitter" not in j and "initializer" not in j):
                continue
            r["files"] += 1
            r["particleScenes"].add(wid)
            f = j.get("flags")
            if f is None:
                r["sysFlagsValues"]["(부재)"] += 1
            else:
                fv = int(f)
                r["sysFlagsValues"][fv] += 1
                for bit in (1, 2, 4, 8, 16, 32, 64, 128):
                    if fv & bit:
                        r["sysFlagBitScenes"][bit].add(wid)
            for section in SECTIONS:
                for o in (j.get(section) or []):
                    if not isinstance(o, dict) or not isinstance(o.get("name"), str):
                        continue
                    op = f"{section}:{o['name']}"
                    r["instances"] += 1
                    r["opCount"][op] += 1
                    r["opScenes"][op].add(wid)
                    for k, v in o.items():
                        if k in CONTROL:
                            continue
                        r["present"][op][k] += 1
                        r["fieldScenes"][(op, k)].add(wid)
                        if k in ("exponent", "flags"):
                            r["explicitValues"][f"{op}.{k}"][str(v)] += 1
    return r


def build(r):
    bk, common = waple_block_keys()
    unread, defaulted, nocase = [], [], []
    for op, fields in r["present"].items():
        section, nm = op.split(":", 1)
        total = r["opCount"][op]
        keys = bk.get(nm)
        for f, present in fields.items():
            row = {"op": op, "field": f, "present": present, "total": total,
                   "omitted": total - present,
                   "scenesExplicit": len(r["fieldScenes"][(op, f)])}
            if keys is None:
                nocase.append(row)
            elif f in (keys | common if section == "emitter" else keys):
                defaulted.append(row)
            else:
                unread.append(row)

    unread.sort(key=lambda x: -x["present"])
    defaulted.sort(key=lambda x: -x["omitted"])
    unread_scenes = set()
    for row in unread:
        unread_scenes |= r["fieldScenes"][(row["op"], row["field"])]

    census_ev = specfmt.ev("corpus", f"워크샵 파티클 JSON {r['files']}개 "
                                     f"({len(r['particleScenes'])}씬) 전수",
                           "scripts/spec/measure_particle_fields.py")
    code_ev = specfmt.ev("file", PSRC.replace(os.sep, "/"),
                         "`case \"<이름>\":` 블록 단위 키 리터럴 추출")

    bits = {str(b): len(s) for b, s in sorted(r["sysFlagBitScenes"].items())}

    return [
        specfmt.entry("engine.particle.fieldCensus", {
            "particleJsons": r["files"],
            "scenesWithParticles": len(r["particleScenes"]),
            "operatorInstances": r["instances"],
            "operatorKinds": len(r["opCount"]),
            "distinctFields": sum(len(v) for v in r["present"].values()),
            "sections": list(SECTIONS),
            "note": "emitter/initializer/operator 세 섹션이 같은 (name + 필드) 형태다. "
                    "최상위 키는 `operator`(단수) — `operators` 가 아니다.",
        }, "확정", [census_ev]),

        specfmt.entry("engine.particle.unreadFields", {
            "what": "코퍼스에 **명시**돼 있는데 Waple 파서가 읽지 않는 필드",
            "kinds": len(unread),
            "explicitInstances": sum(x["present"] for x in unread),
            "scenes": len(unread_scenes),
            "top": unread[:15],
            "whyPresentNotOmitted": "안 읽는 필드는 생략률이 높을수록 오히려 안전하다"
                                    "(어차피 기본 동작). 위험은 **명시된** 인스턴스에 있다.",
        }, "확정", [census_ev, code_ev]),

        specfmt.entry("engine.particle.systemFlagsUnused", {
            "what": "파티클 시스템 최상위 `flags` 비트 중 렌더가 소비하지 않는 것",
            "valueDistribution": {str(k): v for k, v in r["sysFlagsValues"].most_common(12)},
            "scenesPerBit": bits,
            "consumedByWaple": ["bit1"],
            "consumeSite": "Sources/WapleRender/SceneRenderer3D.swift:2050 — (sys.def.flags & 1)",
            "notConsumed": ["bit2", "bit4", "그 외 상위 비트"],
            "impact": f"bit4 는 {bits.get('4', 0)}씬이 저작하는데 파스만 되고 화면에 안 쓰인다. "
                      f"bit2 는 {bits.get('2', 0)}씬.",
            "staleComment": f"{PSRC} 의 flags 주석이 '파스·보존 전용(렌더 소비는 후속)' 이라고 "
                            "적혀 있는데 bit1 은 이미 소비된다 — 주석이 낡았다.",
            "bundledVocabulary": "WE 번들 프리셋도 같은 어휘를 쓴다(1·2·4·8, 조합 3/6/7/9, "
                                 "thunderbolt_child_spawner 는 248=상위 비트 다수). "
                                 "즉 코퍼스만의 방언이 아니라 엔진 어휘다.",
        }, "확정", [census_ev,
                    specfmt.ev("file", "Sources/WapleRender/SceneRenderer3D.swift:2050"),
                    specfmt.ev("asset", "assets/presets/**/particles/presets/*.json",
                               "번들 프리셋 232개의 flags 분포")]),

        specfmt.entry("engine.particle.flagBitMeaning", {
            "bit1": "worldspace — Waple 이 이미 이 해석으로 소비 중",
            "bit4": "perspective(z 원근 스케일) — Waple 주석의 종전 판독(snowperspective 프리셋)",
            "bit2": "미상. 코퍼스·번들 모두에서 흔한데 의미를 확인하지 못했다.",
            "notVerified": "wallpaper64.exe 에서 비트를 읽는 코드를 짚지 않았다. "
                           "bit4 를 구현하려면 먼저 이 확인이 필요하다 — "
                           "'원근' 이 스프라이트 크기 스케일인지 깊이 정렬인지에 따라 결과가 다르다.",
        }, "추정", [specfmt.ev("file", PSRC.replace(os.sep, "/"), "flags 비트 주석(F623)"),
                    specfmt.ev("asset", "assets/presets/fog/previewfog2/particles/presets/snowstorm.json",
                               "flags=4 실례")]),

        specfmt.entry("engine.particle.defaultedFields", {
            "what": "Waple 이 `?? 기본값` 으로 읽는 필드 — 기본값이 WE 와 다르면 틀린다",
            "kinds": len([x for x in defaulted if x["omitted"]]),
            "top": defaulted[:15],
            "exponentEvidence": {
                "field": "initializer:*.exponent — 생략 인스턴스가 가장 많다",
                "wapleDefault": 1,
                "explicitValues": {k: dict(v.most_common(6))
                                   for k, v in r["explicitValues"].items()
                                   if k.endswith(".exponent")},
                "reading": "명시된 값 중 `1` 이 여러 오퍼레이터에서 흔하다. "
                           "에디터가 기본값을 안 쓴다면 1 이 나타나지 않아야 하므로 "
                           "이 관측은 기본값 1 과 모순되지 않는다. Waple 의 `?? 1` 을 "
                           "바꿀 근거가 없다.",
            },
            "flagsExplicitValues": {k: dict(v.most_common(6))
                                    for k, v in r["explicitValues"].items()
                                    if k.endswith(".flags")},
        }, "확정", [census_ev, code_ev]),

        specfmt.entry("engine.particle.handoffClaimCorrected", {
            "claim": "파티클 오퍼레이터 WE 기본값 테이블 부재로 최대 114씬이 틀린다",
            "measured": {
                "scenesWithParticles": len(r["particleScenes"]),
                "scenesWithUnreadExplicitFields": len(unread_scenes),
                "scenesAuthoringFlagBit4": bits.get("4", 0),
                "scenesAuthoringFlagBit2": bits.get("2", 0),
            },
            "correction": "문제의 모양이 다르다. 최대 도달은 '기본값 테이블' 이 아니라 "
                          f"(a) 시스템 flags bit4 미소비 {bits.get('4', 0)}씬 "
                          f"(b) 명시됐는데 안 읽는 필드 {len(unread_scenes)}씬 이다. "
                          "가장 생략이 잦은 기본값(exponent)은 현재 값이 맞을 가능성이 높다.",
            "priority": "bit4 → 미읽기 필드 → 기본값 순. 다만 bit4 는 의미 확인이 선행돼야 한다"
                        "(engine.particle.flagBitMeaning.notVerified).",
        }, "확정", [census_ev, code_ev]),
    ]


def main():
    r = scan()
    entries = build(r)
    specfmt.dump(specfmt.doc("scripts/spec/measure_particle_fields.py", entries), OUT)
    v = {e["id"]: e["value"] for e in entries}
    print(f"파티클 JSON {r['files']}개 · {len(r['particleScenes'])}씬 · "
          f"오퍼레이터 인스턴스 {r['instances']}건 / {len(r['opCount'])}종")
    u = v["engine.particle.unreadFields"]
    print(f"  미읽기 필드 {u['kinds']}종 · 명시 {u['explicitInstances']}건 · {u['scenes']}씬")
    s = v["engine.particle.systemFlagsUnused"]
    print(f"  시스템 flags 비트별 씬: {s['scenesPerBit']}  (소비: bit1 만)")
    print(f"\n기록: {OUT}")


if __name__ == "__main__":
    main()
