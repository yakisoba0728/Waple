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
# bit1(worldspace) 소비 자리. **읽기 전용** — 이 생성기는 이 파일을 고치지 않는다.
RSRC = os.path.join("Sources", "WapleRender", "SceneRenderer3D.swift")
CASE = re.compile(r'^\s*case ((?:"[a-z0-9_]+"(?:,\s*)?)+)\s*:', re.M)
KEY = re.compile(r'\[\s*"([a-z0-9_]+)"\s*\]')
CONTROL = {"name", "id", "visible"}
SECTIONS = ("emitter", "initializer", "operator")


def _flags_consume_lineno():
    """`sys.def.flags & 1` 을 실제로 소비하는 줄 번호를 소스에서 되짚는다. 없으면 None."""
    try:
        src = open(RSRC, encoding="utf-8").read()
    except OSError:
        return None
    for i, line in enumerate(src.splitlines(), 1):
        if line.lstrip().startswith("///") or line.lstrip().startswith("//"):
            continue                       # 주석 속 산문 언급은 소비가 아니다
        if re.search(r"\(sys\.def\.flags & 1\)", line):
            return i
    return None


def flags_consume_site():
    """bit1 소비 자리를 **조건식으로** 적는다 — 줄 번호는 되짚은 부산물로만 붙인다.

    **[정정 2026-08-30] 이 자리는 같은 축으로 두 번 드리프트했다.** 종전엔 손으로 박은
    줄번호였다: `:2050`(무관한 `MeshUniform` 조립부) → 2026-08-20 에 `:2183` 로 고쳤는데
    그 :2183 도 HEAD 에선 빈 문서주석 줄(`///`)이다. `803523d` 의 줄번호 실재 검사는
    **파일 길이 초과**만 잡으므로, 2,540줄 파일 안의 아무 줄이나 통과한다 — 근거가
    그럴듯한 다른 줄을 가리키는 부류는 자동 검사에 안 걸린다.

    세 번째를 막는 방법은 손으로 다시 박지 않는 것이다. 정체는 **조건식**이고 줄번호는
    매 실행 되짚어 붙인다. 조건식이 사라지면 그 사실을 문장으로 낸다(조용히 굳지 않는다).
    """
    n = _flags_consume_lineno()
    where = f"{RSRC}:{n}" if n else f"{RSRC}(조건식 미발견 — 탐침 불일치)"
    return (f"{where} — `let worldspace = (sys.def.flags & 1) != 0` (빌보드 드로우 경로). "
            "**줄 번호는 조건식에서 되짚은 것이다** — 종전 :2050 · :2183 이 차례로 드리프트해 "
            "각각 무관한 줄을 가리켰다(정정 2026-08-20 · 2026-08-30). 다시 인용할 때도 "
            "줄 번호가 아니라 이 조건식으로 찾아라.")


def flags_comment_staleness():
    """`flags` 주석이 아직 "파스·보존 전용(렌더 소비는 후속)" 이라고 적고 있는지 **읽어서** 판정한다.

    **[정정 2026-08-30] 종전엔 이 자리가 하드코딩 리터럴이었다.** `staleComment` 가
    "그 주석이 낡았다" 를 **확정** 등급으로 못박고 있었는데, 정작 그 주석은
    `ec161fc3`(2026-08-01, "…낡은 flags 주석 정정")이 이미 고쳤다. 소스가 고쳐진 뒤에도
    생성기 리터럴은 안 따라와서, 재생성해도 닫힌 결함을 영구히 다시 보고했다 —
    **소스 문면에 대한 주장을 하드코딩하면 소스가 고쳐지는 순간 썩는다.**

    게다가 그 리터럴은 애초에 어떤 살아 있는 주석의 축자 인용도 아니었다. 고치기 전
    문면(`8e0741b8:542`)은 "파스·보존 전용(렌더 소비는 **WapleRender 경로** 후속)" 이고
    리터럴은 그걸 "(렌더 소비는 후속)" 으로 압축했다. 그래서 인용을 따라 grep 하면
    어느 커밋에서도 살아 있는 주석에 안 닿고 **묘비 줄에만** 닿는다 — 그 묘비를 '고치면'
    정정 기록이 파괴된다.

    그래서 이제 **재서, 낡았을 때만** 그 사실을 말한다. 줄 번호가 아니라 조건식으로 건다:
    `[정정 ...]`/`종전` 묘비 줄은 제외하고 그 문구를 찾는다(묘비 안의 인용은 이력 보존이고
    낡음이 아니다). 판정 불가로 무너지지 않게, 못 찾을 때도 그 사실을 문장으로 낸다.
    """
    src = open(PSRC, encoding="utf-8").read()
    phrase = "파스·보존 전용(렌더 소비는"
    live = []
    for i, line in enumerate(src.splitlines(), 1):
        if phrase not in line:
            continue
        if "[정정" in line or "종전" in line:   # 묘비 인용 — 이력 보존이지 낡음이 아니다
            continue
        live.append(i)
    if live:
        return (f"{PSRC}:{','.join(map(str, live))} 의 flags 주석이 "
                f"'{phrase} 후속)' 이라고 적혀 있는데 bit1 은 이미 소비된다 — 주석이 낡았다.")
    return (f"낡지 않았다 — `{phrase} 후속)` 은 {PSRC} 에서 `[정정 2026-08-01]` 묘비 "
            "안에만 남아 있고(살아 있는 주석 0건), 그 묘비가 이미 **bit1 은 소비된다** 와 "
            "비트별 소비 현황을 적는다. 종전 이 자리는 그 닫힌 결함을 확정 등급으로 "
            "계속 보고하는 하드코딩 리터럴이었다(정정 2026-08-30).")


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


PRESETS = os.path.join(T.WE, "assets", "presets")


def _vec(v):
    if isinstance(v, str):
        try:
            return [float(x) for x in v.split()]
        except ValueError:
            return []
    if isinstance(v, (int, float)):
        return [float(v)]
    if isinstance(v, list):
        return [float(x) for x in v if isinstance(x, (int, float))]
    return []


def preset_ab():
    """번들 프리셋을 flags&4 유무로 갈라 **크기·깊이 관련 특징**을 비교한다.

    bit4 가 '원근 크기 스케일' 인지 '깊이 정렬' 인지를 가르는 게 목적이다.
    정렬이라면 저작자가 크기를 다르게 쓸 이유가 그대로 남는다. 크기 스케일이라면
    엔진이 z 로 크기를 만들어 주므로 저작자가 크기 변화를 직접 넣을 이유가 사라진다.
    """
    groups = {True: [], False: []}
    for root, _dirs, files in os.walk(PRESETS):
        for fn in files:
            if not fn.endswith(".json"):
                continue
            try:
                j = json.load(open(os.path.join(root, fn), encoding="utf-8-sig"))
            except Exception:
                continue
            if not isinstance(j, dict) or ("emitter" not in j and "initializer" not in j):
                continue
            fv = int(j.get("flags") or 0)
            groups[bool(fv & 4)].append(j)

    def summarize(js):
        inits = [{i.get("name"): i for i in (j.get("initializer") or [])
                  if isinstance(i, dict)} for j in js]
        ops = [{o.get("name") for o in (j.get("operator") or []) if isinstance(o, dict)}
               for j in js]
        ems = [[e for e in (j.get("emitter") or []) if isinstance(e, dict)] for j in js]
        ratios, dirz, dmax, velz = [], [], [], []
        for k, e in zip(inits, ems):
            sr = k.get("sizerandom") or {}
            lo, hi = _vec(sr.get("min")), _vec(sr.get("max"))
            if lo and hi and lo[0] > 0:
                ratios.append(hi[0] / lo[0])
            z = [_vec(x.get("directions"))[2] for x in e if len(_vec(x.get("directions"))) > 2]
            if z:
                dirz.append(max(z))
            dm = [_vec(x.get("distancemax")) for x in e if _vec(x.get("distancemax"))]
            if dm:
                dmax.append(max(x[0] for x in dm))
            vr = k.get("velocityrandom") or {}
            vlo, vhi = _vec(vr.get("min")), _vec(vr.get("max"))
            if len(vlo) > 2 and len(vhi) > 2:
                velz.append(abs(vhi[2] - vlo[2]))

        def med(xs):
            return round(sorted(xs)[len(xs) // 2], 2) if xs else None
        return {
            "n": len(js),
            "sizeRandomRatioMedian": med(ratios),
            "emitterDirectionsZMedian": med(dirz),
            "emitterDistanceMaxMedian": med(dmax),
            "velocityZSpreadMax": round(max(velz), 2) if velz else None,
            "usesSizeChange": sum(1 for o in ops if "sizechange" in o),
            "usesOscillateSize": sum(1 for o in ops if "oscillatesize" in o),
        }
    return {"withBit4": summarize(groups[True]), "withoutBit4": summarize(groups[False])}


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
        # 2D 씬의 원근 투영 FOV(general.perspectiveoverridefov) — bit4 구현에 필요한 값
        "povFovAll": collections.Counter(),
        "povFovBit4": collections.Counter(),
        "bit4Scenes": set(),
        "bit4WithoutPov": set(),
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
        # 씬 general 의 원근 FOV 를 먼저 읽어 둔다(아래 bit4 판정과 짝지어 집계).
        pov = None
        for name, off, size in entries:
            if name != "scene.json":
                continue
            try:
                sc = json.loads(raw[base + off:base + off + size].decode("utf-8-sig", "replace"))
                pov = (sc.get("general") or {}).get("perspectiveoverridefov")
            except Exception:
                pov = None
        sceneHadBit4 = False
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
                if fv & 4:
                    sceneHadBit4 = True
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
        r["povFovAll"][str(pov)] += 1
        if sceneHadBit4:
            r["bit4Scenes"].add(wid)
            r["povFovBit4"][str(pov)] += 1
            if pov is None:
                r["bit4WithoutPov"].add(wid)
    return r


def build(r):
    ab = preset_ab()
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
            # [2026-08-20] :2050 → :2183. 종전 줄번호는 무관한 `MeshUniform` 조립부를 가리켰다
            # (`mvp: matrix_identity_float4x4, model: …`). `803523d` 가 넣은 줄번호 실재
            # 검사는 **파일 길이 초과**만 잡으므로 2,288줄 파일의 :2050 은 통과한다 —
            # 근거가 그럴듯한 다른 줄을 가리키는 부류라 자동 검사에 안 걸린다.
            #
            # **[정정 2026-08-30] 그 :2183 도 이미 드리프트했다 — 같은 축으로 두 번째다.**
            # HEAD 의 :2183 은 빈 문서주석 줄(`///`)이다. 손으로 새 줄번호를 박으면 이 결함을
            # 세 번째로 부르므로 **조건식으로 매 실행 되짚는다**(`flags_consume_site`) —
            # 이 리포 자신의 권고대로 인용의 정체는 조건식이고 줄번호는 그 부산물이다.
            "consumeSite": flags_consume_site(),
            "notConsumed": ["bit2", "bit4", "그 외 상위 비트"],
            "impact": f"bit4 는 {bits.get('4', 0)}씬이 저작하는데 파스만 되고 화면에 안 쓰인다. "
                      f"bit2 는 {bits.get('2', 0)}씬.",
            "reachIsNotExpectedChangeCount": "이 씬 수는 '해당 비트를 저작한 파티클 시스템을 "
                                             "하나라도 가진 씬' 이다. flags 는 파티클 시스템마다 "
                                             "따로 있고 한 씬이 여러 개를 갖는다. 고쳤을 때 골든이 "
                                             "움직이는 씬은 그 시스템이 **실제로 보이는** 경우로 "
                                             "한정되므로 이보다 적다 — 나중에 이 숫자를 기대 변화 "
                                             "수로 놓고 '고침이 안 먹었다' 고 판단하지 마라.",
            # [정정 2026-08-30] 하드코딩 리터럴 → 실측. 사유는 `flags_comment_staleness` 주석.
            "staleComment": flags_comment_staleness(),
            "bundledVocabulary": "WE 번들 프리셋도 같은 어휘를 쓴다(1·2·4·8, 조합 3/6/7/9, "
                                 "thunderbolt_child_spawner 는 248=상위 비트 다수). "
                                 "즉 코퍼스만의 방언이 아니라 엔진 어휘다.",
        }, "확정", [census_ev,
                    # [정정 2026-08-30] 종전 ref 는 `:2050` 이었다 — `consumeSite` 가
                    # 2026-08-20 에 :2183 으로 옮겨졌는데 **짝인 이 ref 는 안 따라와** 옛
                    # 줄번호를 그대로 들고 있었다(같은 항목 안에서 두 줄번호가 갈렸다).
                    # 이제 둘 다 같은 되짚기(`flags_consume_site`)에서 나오므로 갈릴 수 없다.
                    specfmt.ev("file", f"{RSRC}:{_flags_consume_lineno() or ''}".rstrip(":"),
                               "최상위 flags bit1(worldspace) 소비 자리 — 조건식 "
                               "`(sys.def.flags & 1)` 으로 매 실행 되짚는다"),
                    specfmt.ev("asset", "assets/presets/**/particles/presets/*.json",
                               "번들 프리셋 232개의 flags 분포")]),

        specfmt.entry("engine.particle.bit4PresetAB", {
            "question": "bit4 는 **크기 스케일**인가 **깊이 정렬**인가. 둘은 다른 코드가 필요하다.",
            "method": "번들 프리셋 232개를 flags&4 유무로 갈라 크기·깊이 특징을 비교",
            "result": ab,
            "reading": "bit4 조는 (a) 이미터 z 방향이 전건 1(나머지는 중앙값 0) "
                       "(b) 방출 거리 중앙값이 두 자릿수 배 크고 "
                       "(c) **속도 z 산포가 0 이 아닌 유일한 조**다 — 즉 깊이가 있는 부피에 뿌린다. "
                       "동시에 (d) sizerandom 비율이 거의 1(균일 크기)이고 "
                       "(e) sizechange·oscillatesize 를 **한 건도** 쓰지 않는다.",
            "inference": "깊이 정렬이라면 저작자가 크기를 직접 다룰 이유가 그대로 남는다. "
                         "크기 연산자를 전건 버렸다는 것은 **엔진이 z 로 크기를 만들어 준다**는 쪽을 가리킨다.",
            "strength": "상관 근거다. 인과(엔진이 실제로 무엇을 하는지)는 확인하지 않았다.",
        }, "확정", [specfmt.ev("asset", "assets/presets/**/*.json",
                               "번들 프리셋 232개 A/B, scripts/spec/measure_particle_fields.py")]),

        specfmt.entry("engine.particle.flagBitMeaning", {
            "bit1": "worldspace — Waple 이 이미 이 해석으로 소비 중",
            "bit4": "perspective(z 원근 **크기 스케일**) — 프리셋 A/B 가 이 쪽을 지지한다"
                    "(engine.particle.bit4PresetAB). Waple 주석의 종전 판독과도 일치.",
            "bit2": "미상. 코퍼스·번들 모두에서 흔한데 의미를 확인하지 못했다.",
            "howItWorks": "별도 크기 공식이 아니라 **투영 교체**다 — "
                          "engine.particle.bit4IsProjectionNotSizeFormula 참조.",
        }, "추정", [specfmt.ev("file", PSRC.replace(os.sep, "/"), "flags 비트 주석(F623)"),
                    specfmt.ev("asset", "assets/presets/fog/previewfog2/particles/presets/snowstorm.json",
                               "flags=4 실례")]),

        specfmt.entry("engine.particle.bit4IsProjectionNotSizeFormula", {
            "finding": "bit4 는 파티클 크기에 곱하는 **공식이 아니다**. 그 시스템을 "
                       "평면(직교) 대신 **원근 투영**으로 그리는 스위치다. "
                       "겉보기 크기 축소는 원근 나눗셈에서 저절로 나온다.",
            "shaderProof": {
                "what": "WE 는 GLSL 을 평문으로 배포하므로 파티클 정점 경로를 직접 읽을 수 있다",
                "genericparticle.vert": "크기는 정점 속성 in_ParticleSize(a_TexCoordVec4.w). "
                                        "쿼드를 ComputeParticlePosition 으로 만들고 "
                                        "g_ModelViewProjectionMatrix 를 곱하는 게 전부다.",
                "genericparticle.geom": "GS 경로도 동일 — CreateParticleVertex 가 같은 MVP 만 곱한다.",
                "common_particles.h": "원근·거리 관련 항이 **하나도 없다**.",
                "conclusion": "셰이더에 z 기반 크기 항이 없으므로 bit4 는 셰이더 쪽 공식일 수 없다. "
                              "남는 건 MVP(투영) 교체뿐이다.",
            },
            "weOwnDocs": {
                "source": "ui/dist/monaco/autocomplete/lib.sceneScript.d.ts (WE 배포 API 정의)",
                "ILayer.perspective": "If set to true, the layer will use perspective rendering "
                                      "instead of flat rendering.",
                "createLayer": "For model-based layers, you likely also want to set perspective "
                               "to `true` for true 3D rendering (including in 2D scenes).",
                "why": "WE 자신이 'perspective = 평면 렌더 대신 원근 렌더', 그리고 "
                       "**2D 씬에서도** 성립한다고 적어 뒀다.",
            },
            "uiLabel": "ui_editor_properties_perspective = \"Perspective rendering\" "
                       "(locale/ui_en-us.json) — 크기 조절이 아니라 렌더 방식 이름이다.",
            "fovSource": {
                "key": "general.perspectiveoverridefov",
                "whyNotSceneFov": "scene 의 fov 는 API 정의가 'For 3D scenes only' 라고 명시한다"
                                  "(2D 는 zoom). 2D 씬의 원근 렌더는 별도 override FOV 를 쓴다.",
                "distributionAllParticleScenes": dict(r["povFovAll"].most_common(8)),
                "distributionBit4Scenes": dict(r["povFovBit4"].most_common(8)),
                "bit4ScenesMissingKey": len(r["bit4WithoutPov"]),
                "wapleAlreadyUses95": "SceneRendererFrameEncoder.swift 의 레이어 원근 근사가 "
                                      "perspectiveFov 기본을 95 로 하드코딩해 뒀다. 코퍼스 최빈값은 "
                                      "90(다음 95)이라 이 기본값은 **재확인이 필요**하다.",
            },
            "stillUnknown": [
                "카메라 eye 거리 규약(원근 평면이 직교 평면과 어디서 일치하는가)",
                "perspectiveoverridefov 부재 시 WE 기본값",
                "bit4 파티클이 레이어 perspective 와 같은 카메라를 쓰는지",
            ],
            "derivableConstraint": "z=0 에서 원근과 직교가 일치해야 한다 — 아니면 플래그를 켜는 "
                                   "것만으로 평평한 시스템까지 크기가 변한다. 이 연속성 조건이 "
                                   "eye 거리를 d = (projH/2) / tan(fov/2) 로 묶는다. "
                                   "다만 이건 **유도**지 측정이 아니다.",
            "doNotGuessFormula": "위 미상 항목을 채우기 전에 구현하지 마라. 크기가 틀리면 "
                                 "지금처럼 스케일이 아예 없는 것보다 더 눈에 띌 수 있다.",
        }, "보고", [specfmt.ev("shader", "assets/shaders/genericparticle.vert",
                               "크기는 정점 속성, 원근 항 없음"),
                    specfmt.ev("shader", "assets/shaders/common_particles.h"),
                    specfmt.ev("file", "ui/dist/monaco/autocomplete/lib.sceneScript.d.ts",
                               "WE 배포 API 정의의 perspective 설명"),
                    specfmt.ev("asset", "locale/ui_en-us.json",
                               "ui_editor_properties_perspective"),
                    specfmt.ev("corpus", "워크샵 파티클 보유 씬의 general.perspectiveoverridefov 분포")]),

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
    specfmt.require_inputs("measure_particle_fields",
                           ("dir", T.WS, "WE_WORKSHOP", "워크샵 코퍼스"))
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
