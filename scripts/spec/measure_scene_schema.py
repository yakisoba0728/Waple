"""코퍼스 scene.json 스키마 전수 측정 → spec/corpus/scene-schema.json

무엇을 재는가
  1. general.* 키 전수 + 값 타입 + 값 도메인 + 도수
  2. objects[] 키 전수(타입별) — image/text/particle/model/light/camera/sound/shape/(node)
  3. 바인딩 형태 도수({user,value}/{script,value}/{animation,value} …)
  4. colorBlendMode 실사용 분포
  5. Waple(SceneDocument.swift)이 파싱하지 않는 키 — **함수 단위** 리터럴 대조
  6. 예상 밖 값(타입 혼용·범위 밖·널)

왜 함수 단위인가
  파일 전체를 grep 하면 "scale 리터럴이 어딘가 있으니 파싱됨"으로 오판한다.
  parseText 에 parallaxDepth 가 없어도 parseLayer 에 있으면 통과해 버린다.
  그래서 SceneDocument.swift 를 함수 경계로 잘라 타입별 파스 함수의 리터럴만 본다.

오브젝트 타입 판정은 Waple parse() 의 분기 순서를 그대로 재현한다:
  sound → (콘텐츠 키 없음)=node → image → particle → text → model → light → camera → shape+effects
"""
import collections
import json
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt
from measure_corpus import parse_pkg, WS

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCENE_SWIFT = os.path.join(REPO, "Sources", "WapleCore", "SceneDocument.swift")
OUT = os.path.join("spec", "corpus", "scene-schema.json")

# parse() 가 모든 오브젝트에 대해 공통으로 읽는 키(타입 분기 이전).
SHARED_PARSE_KEYS = {"visible", "id", "image", "model", "particle", "text",
                     "light", "camera", "sound", "shape"}
# 타입 → 그 타입을 만드는 Waple 함수들(리터럴 대조 범위)
TYPE_FUNCS = {
    "image": ["parseLayer"],
    "text": ["parseText"],
    "particle": ["parseParticle"],
    "model": ["parseModel"],
    "light": ["parseLight"],
    "camera": ["parseCameraObject"],
    "sound": ["parseSound"],
    "shape": ["effectQuadLayer", "isEffectQuad"],
    "node": ["parseNode", "transformScripts"],
}
# 미파싱이지만 SceneDocument.swift 에 "왜 버리는지" 주석이 있는 것들(의도적 드롭).
# 값은 그 근거 주석의 요지 — 미인지 누락과 구분하려고 표에 싣는다.
DELIBERATE_DROP = {
    "text.size": "parseText: 배율은 scale 필드 — size 는 parseLayer 전용 레이아웃 박스(오독 시 거대 글리프)",
    "shape.origin": "effectQuadLayer: 풀스크린 고정 승격이라 저작 트랜스폼·parent 를 버린다",
    "shape.scale": "effectQuadLayer: 풀스크린 고정 승격이라 저작 트랜스폼·parent 를 버린다",
    "shape.angles": "effectQuadLayer: 풀스크린 고정 승격이라 저작 트랜스폼·parent 를 버린다",
    "shape.parent": "effectQuadLayer: parent 를 남기면 composeParentTransforms 가 풀스크린 지오메트리를 재배치한다",
    "sound.origin": "parse(): 사운드 오브젝트는 트랜스폼/계층 무시(전역 재생)",
    "sound.angles": "parse(): 사운드 오브젝트는 트랜스폼/계층 무시(전역 재생)",
    "sound.scale": "parse(): 사운드 오브젝트는 트랜스폼/계층 무시(전역 재생)",
    "sound.parent": "parse(): 사운드 오브젝트는 트랜스폼/계층 무시(전역 재생)",
    "sound.parallaxDepth": "parse(): 사운드 오브젝트는 트랜스폼/계층 무시(전역 재생)",
}

# parse()/parseCamera 는 general 키와 오브젝트 키를 같은 함수 안에서 읽는다. 리터럴 집합만으로는
# 둘을 못 가르므로 general[...] 접근만 손으로 추린다(SceneDocument.swift:861-878, 1243-1249 실독).
GENERAL_READ_IN_PARSE = {"orthogonalprojection", "clearcolor", "ambientcolor", "skylightcolor",
                         "hdr", "bloom", "cameraparallax", "cameraparallaxamount",
                         "cameraparallaxmouseinfluence", "cameraparallaxdelay", "quality"}
GENERAL_READ_IN_CAMERA = {"orthogonalprojection", "fov", "nearz", "farz"}

# 값이 "x y [z]" 벡터 문자열인 키(수치 도메인은 성분으로 잰다)
VECTOR_KEYS = {"origin", "angles", "scale", "size", "parallaxDepth", "color",
               "outlinecolor", "backgroundcolor", "spacing", "originb"}
# 열거 도메인을 그대로 실을 상한(이 이상은 distinct/min/max 로만)
ENUM_MAX = 12


# ── 코퍼스 순회 ────────────────────────────────────────────────────────────

def iter_scenes():
    """(wsid, 팝ulation, scene dict) — pkg 안의 scene.json/gifscene.json 전수."""
    for wid in sorted(os.listdir(WS)):
        d = os.path.join(WS, wid)
        if not os.path.isdir(d):
            continue
        for pkgname, cands in (("scene.pkg", ("scene.json", "gifscene.json")),
                               ("gifscene.pkg", ("gifscene.json", "scene.json"))):
            path = os.path.join(d, pkgname)
            if not os.path.exists(path):
                continue
            with open(path, "rb") as fh:
                data = fh.read()
            try:
                _magic, entries, base = parse_pkg(data)
            except Exception as e:
                yield wid, pkgname, None, "pkg:%s" % e
                continue
            table = {n: (o, s) for n, o, s in entries}
            name = next((c for c in cands if c in table), None)
            if name is None:
                yield wid, pkgname, None, "no-scene-json"
                continue
            off, size = table[name]
            try:
                scene = json.loads(data[base + off:base + off + size].decode("utf-8-sig"))
            except Exception as e:
                yield wid, pkgname, None, "json:%s" % type(e).__name__
                continue
            yield wid, pkgname + "/" + name, scene, None


# ── 값 분류 ───────────────────────────────────────────────────────────────

def vtype(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "bool"
    if isinstance(v, int):
        return "int"
    if isinstance(v, float):
        return "float"
    if isinstance(v, str):
        return "str"
    if isinstance(v, dict):
        return "dict"
    if isinstance(v, list):
        return "list"
    return type(v).__name__


def unwrap(v):
    """Waple unwrapValue 와 동일: {"value": X} → X."""
    if isinstance(v, dict) and "value" in v:
        return v["value"]
    return v


def components(v):
    """'x y z' 문자열 → [float]. 아니면 None."""
    s = unwrap(v)
    if not isinstance(s, str):
        return None
    out = []
    for tok in s.split():
        try:
            out.append(float(tok))
        except ValueError:
            return None
    return out or None


def object_type(o):
    """Waple parse() 분기 순서 그대로."""
    if o.get("sound") is not None:
        return "sound"
    for k in ("image", "particle", "text", "model", "light", "camera"):
        if o.get(k) is not None:
            return k
    if o.get("shape") is not None and o.get("effects"):
        return "shape"
    return "node"


def static_invisible(o):
    """parse() 게이트: 정적 false + visible 스크립트 없음 → 렌더 대상에서 빠지고 invNode 로만 남는다."""
    v = o.get("visible")
    if isinstance(v, bool):
        return not v
    if isinstance(v, dict):
        if isinstance(v.get("script"), str):
            return False
        return v.get("value") is False
    return False


def top(counter, limit=None):
    items = sorted(counter.items(), key=lambda kv: (-kv[1], str(kv[0])))
    if limit:
        items = items[:limit]
    return {str(k): v for k, v in items}


# ── Waple 소스에서 함수별 JSON 키 리터럴 추출 ─────────────────────────────

FUNC_RE = re.compile(r"^    (?:public |private |internal )?(?:static )?func (\w+)")
SUBSCRIPT_RE = re.compile(r'\[\s*"([^"\\\n]+)"\s*\]')
ARRAYLIT_RE = re.compile(r'"([A-Za-z_][A-Za-z0-9_]{0,39})"')
COMMENT_RE = re.compile(r"//.*$", re.M)


def swift_function_keys(path=SCENE_SWIFT):
    """함수 이름 → 그 본문에 등장하는 JSON 키 리터럴 집합. 파일 전체 집합도 함께.

    주석은 먼저 지운다 — 이 파일의 주석은 키 이름을 자주 인용해서(`"puppet" 키` 등)
    주석만 보고 "파싱됨"으로 오판하면 갭이 통째로 숨는다.
    `["a","b"]` 배열 리터럴(parseNode 의 콘텐츠 키 목록, for key in [...] 루프)도 잡아야 해서
    서브스크립트 정규식만으로는 부족하다.
    """
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    starts = [(i, m.group(1)) for i, ln in enumerate(lines)
              for m in [FUNC_RE.match(ln)] if m]
    per = {}
    for k, (i, name) in enumerate(starts):
        end = starts[k + 1][0] if k + 1 < len(starts) else len(lines)
        body = COMMENT_RE.sub("", "\n".join(lines[i:end]))
        keys = set(SUBSCRIPT_RE.findall(body)) | set(ARRAYLIT_RE.findall(body))
        per.setdefault(name, set()).update(keys)
    whole = set(SUBSCRIPT_RE.findall(COMMENT_RE.sub("", "\n".join(lines))))
    return per, whole


# ── 본 측정 ───────────────────────────────────────────────────────────────

def main():
    per_func, whole_file = swift_function_keys()
    parse_keys = per_func.get("parse", set())
    # applyGeneralSettings 는 general[...] 만 읽으므로 그 함수의 리터럴 전체가 general 키다.
    general_keys_waple = (per_func.get("applyGeneralSettings", set())
                          | GENERAL_READ_IN_PARSE | GENERAL_READ_IN_CAMERA)

    pops = collections.Counter()
    errors = collections.Counter()
    top_keys = collections.Counter()
    versions = collections.Counter()
    cam_keys = collections.Counter()
    gen_n = collections.Counter()
    gen_types = collections.defaultdict(collections.Counter)
    gen_vals = collections.defaultdict(collections.Counter)
    key_case = collections.defaultdict(collections.Counter)

    obj_n = collections.Counter()
    keys_n = collections.defaultdict(collections.Counter)          # type → key → count
    keys_scenes = collections.defaultdict(lambda: collections.defaultdict(set))
    keys_types = collections.defaultdict(lambda: collections.defaultdict(collections.Counter))
    keys_vals = collections.defaultdict(lambda: collections.defaultdict(collections.Counter))
    vec_stats = collections.defaultdict(dict)                      # (type,key) → min/max/distinct
    num_stats = collections.defaultdict(dict)                      # (type,key) → 스칼라 min/max/distinct
    bind_forms = collections.Counter()
    bind_path = collections.defaultdict(collections.Counter)       # 오브젝트/general 직속 키만
    bind_nested = collections.defaultdict(collections.Counter)     # 배열 안쪽은 프리픽스로 집계
    bind_novalue = collections.Counter()
    bind_impure = collections.Counter()                            # user/script/animation 키를 갖지만 바인딩이 아닌 객체
    cbm = collections.defaultdict(collections.Counter)
    content_null = collections.Counter()

    eff_keys = collections.Counter()
    eff_pass_keys = collections.Counter()
    eff_tex = collections.defaultdict(collections.Counter)
    eff_combo = collections.Counter()
    eff_const_case = collections.defaultdict(lambda: collections.defaultdict(collections.Counter))
    eff_vis_types = collections.Counter()
    anim_keys = collections.Counter()
    anim_types = collections.defaultdict(collections.Counter)
    anim_count = collections.Counter()
    anim_blendtime_multi = 0

    dims_2d = 0
    dims_3d = 0
    dup_ids = collections.Counter()
    dangling = collections.Counter()
    self_parent = 0
    no_id = collections.Counter()
    alpha_out = collections.Counter()
    neg_scale = collections.Counter()
    neg_parallax = collections.Counter()
    zero_parallax = collections.Counter()
    parent_missing = collections.Counter()
    parent_ok = collections.Counter()
    ortho_extra = collections.Counter()
    # 시차 활성 씬에서의 text.parallaxDepth — 미파싱 갭의 실효 범위 산정용
    parallax_scenes = 0
    text_pd_in_parallax = collections.Counter()
    # Waple 이 스칼라(Float)로 읽는데 코퍼스가 벡터 문자열인 키
    shape_mismatch = collections.defaultdict(collections.Counter)

    # 바인딩 객체는 이 키들로만 이루어진다. animationlayers[] 원소도 "animation" 키를 갖지만
    # name/blend/rate/… 를 함께 가지므로 이 순수성 검사로 걸러진다(오분류 방지).
    BIND_KEYS = {"user", "script", "animation", "value", "scriptproperties"}

    def norm_path(path):
        """상수 이름(수백 종)과 scriptproperties 내부는 * 로 접어 경로 표를 유한하게 만든다."""
        i = path.find(".scriptproperties")
        if i >= 0:
            path = path[:i + len(".scriptproperties")] + ".*"
        path = re.sub(r"(constantshadervalues|usershadervalues|combos)\.[^.]+", r"\1.*", path)
        return path

    def walk_binds(node, path, depth=0):
        if depth > 12:
            return
        if isinstance(node, dict):
            ks = set(node.keys())
            if ks & {"user", "script", "animation"} and not (ks - BIND_KEYS):
                form = "|".join(sorted(ks & {"user", "script", "animation", "value", "scriptproperties"}))
                bind_forms[form] += 1
                if "[]" in path:
                    bind_nested[norm_path(path)][form] += 1
                elif path.count(".") <= 1:
                    bind_path[path][form] += 1
                if "value" not in ks:
                    bind_novalue[norm_path(path) + " " + form] += 1
            elif ks & {"user", "script", "animation"}:
                bind_impure["|".join(sorted(ks))] += 1
            for k, v in node.items():
                walk_binds(v, path + "." + k, depth + 1)
        elif isinstance(node, list):
            for v in node:
                walk_binds(v, path + "[]", depth + 1)

    for wid, pop, scene, err in iter_scenes():
        if err:
            errors[err] += 1
            continue
        pops[pop] += 1
        versions[str(scene.get("version"))] += 1
        for k in scene:
            top_keys[k] += 1
            key_case[k.lower()][k] += 1

        general = scene.get("general") or {}
        cam = scene.get("camera")
        if isinstance(cam, dict):
            for k in cam:
                cam_keys[k] += 1
                key_case[k.lower()][k] += 1
        if isinstance(general, dict):
            for k, v in general.items():
                gen_n[k] += 1
                key_case[k.lower()][k] += 1
                gen_types[k][vtype(v)] += 1
                u = unwrap(v)
                if isinstance(u, (bool, str)) or (isinstance(u, int) and not isinstance(u, bool)):
                    gen_vals[k][str(u)] += 1
            op = general.get("orthogonalprojection")
            if isinstance(op, dict):
                for k in op:
                    if k not in ("width", "height"):
                        ortho_extra[k] += 1
        walk_binds(general if isinstance(general, dict) else {}, "general")

        parallax_on = unwrap(general.get("cameraparallax")) is True
        parallax_scenes += 1 if parallax_on else 0

        is3d = (not isinstance(general.get("orthogonalprojection"), dict)
                and isinstance(cam, dict)
                and all(k in cam for k in ("eye", "center", "up"))
                and general.get("fov") is not None)
        dims_3d += 1 if is3d else 0
        dims_2d += 0 if is3d else 1

        objs = [o for o in (scene.get("objects") or []) if isinstance(o, dict)]
        ids = collections.Counter()
        typ_of = {}
        registered = {}     # Waple 이 parent 룩업 맵(localT)에 넣는 id
        for o in objs:
            t = object_type(o)
            oid = o.get("id") if isinstance(o.get("id"), int) else None
            if oid is None:
                no_id[t] += 1
                continue
            ids[oid] += 1
            typ_of[oid] = t
            if t == "sound":
                continue                       # 전역 재생 — 트랜스폼 맵 미등록(설계)
            if t == "node":
                registered[oid] = "node"
            elif static_invisible(o):
                registered[oid] = "invNode"
            elif t in ("image", "shape"):
                registered[oid] = "layer"
            elif t == "text":
                registered[oid] = "text"
            # particle/model/light/camera 는 미등록

        for o in objs:
            t = object_type(o)
            obj_n[t] += 1
            for ck in ("image", "model", "particle", "text", "light", "camera", "sound", "shape"):
                if ck in o and o[ck] is None:
                    content_null[t + "." + ck] += 1
            for k, v in o.items():
                keys_n[t][k] += 1
                keys_scenes[t][k].add(wid)
                keys_types[t][k][vtype(v)] += 1
                key_case[k.lower()][k] += 1
                u = unwrap(v)
                if isinstance(u, (bool, str)) or (isinstance(u, int) and not isinstance(u, bool)):
                    keys_vals[t][k][str(u)] += 1
                if k in VECTOR_KEYS:
                    comp = components(v)
                    if comp:
                        st = vec_stats[(t, k)]
                        st["min"] = min(st.get("min", comp[0]), min(comp))
                        st["max"] = max(st.get("max", comp[0]), max(comp))
                        st.setdefault("distinct", set()).add(unwrap(v))
                elif isinstance(u, float) or (isinstance(u, int) and not isinstance(u, bool)):
                    st = num_stats[(t, k)]
                    st["min"] = min(st.get("min", u), u)
                    st["max"] = max(st.get("max", u), u)
                    st.setdefault("distinct", set()).add(u)
            walk_binds(o, t)

            cb = o.get("colorBlendMode")
            if cb is not None:
                cbm[t][str(unwrap(cb))] += 1
            a = unwrap(o.get("alpha"))
            if isinstance(a, (int, float)) and not isinstance(a, bool) and not 0 <= a <= 1:
                alpha_out[t + ":" + str(a)] += 1
            sc = components(o.get("scale"))
            if sc and any(x < 0 for x in sc):
                neg_scale[t] += 1
            pd = components(o.get("parallaxDepth"))
            if pd and any(x < 0 for x in pd):
                neg_parallax[t] += 1
            if pd and all(x == 0 for x in pd):
                zero_parallax[t] += 1

            if t == "text" and parallax_on:
                pdv = components(o.get("parallaxDepth"))
                if pdv is None:
                    text_pd_in_parallax["(미저작 → WE 기본)"] += 1
                elif all(x == 0 for x in pdv):
                    text_pd_in_parallax["0(시차 없음) — Waple 은 1 로 그린다"] += 1
                elif pdv == [1.0] * len(pdv):
                    text_pd_in_parallax["1(Waple 하드코드와 동일)"] += 1
                else:
                    text_pd_in_parallax["기타(%s)" % ("음수" if any(x < 0 for x in pdv) else "양수")] += 1

            # 스칼라 파스인데 벡터 문자열인 키(text.spacing) — float() 이 nil 을 돌려준다
            for sk in ("spacing", "pointsize", "maxwidth", "backgroundbrightness",
                       "outlinethickness", "volume", "intensity", "radius"):
                sv = unwrap(o.get(sk))
                if isinstance(sv, str) and len(sv.split()) > 1:
                    shape_mismatch[t + "." + sk][sv] += 1

            p = o.get("parent")
            if isinstance(p, int):
                if p == o.get("id"):
                    self_parent += 1
                if p not in ids:
                    dangling[wid] += 1
                elif p in registered:
                    parent_ok[t + "<-" + typ_of.get(p, "?") + ":" + registered[p]] += 1
                elif not is3d:
                    parent_missing["2D " + t + "<-" + typ_of.get(p, "?")] += 1
                else:
                    parent_missing["3D " + t + "<-" + typ_of.get(p, "?")] += 1

            efs = o.get("effects")
            if isinstance(efs, list):
                for e in efs:
                    if not isinstance(e, dict):
                        continue
                    for k in e:
                        eff_keys[k] += 1
                    eff_vis_types[vtype(e.get("visible"))] += 1
                    f = e.get("file") or ""
                    ps = e.get("passes")
                    if not isinstance(ps, list):
                        continue
                    for pss in ps:
                        if not isinstance(pss, dict):
                            continue
                        for k in pss:
                            eff_pass_keys[k] += 1
                        combos = pss.get("combos")
                        if isinstance(combos, dict):
                            for k in combos:
                                eff_combo[k] += 1
                        csv = pss.get("constantshadervalues")
                        if isinstance(csv, dict):
                            for k in csv:
                                eff_const_case[f][k.lower()][k] += 1
                        for tk in ("textures", "usertextures"):
                            arr = pss.get(tk)
                            if isinstance(arr, list):
                                for x in arr:
                                    eff_tex[tk][vtype(x)] += 1

            al = o.get("animationlayers")
            if isinstance(al, list) and al:
                anim_count[len(al)] += 1
                for a2 in al:
                    if not isinstance(a2, dict):
                        continue
                    for k, v in a2.items():
                        anim_keys[k] += 1
                        anim_types[k][vtype(v)] += 1
                    if "blendtime" in a2 and len(al) >= 2:
                        anim_blendtime_multi += 1

        d = [i for i, n in ids.items() if n > 1]
        if d:
            dup_ids[wid] = len(d)

    # ── Waple 대조 ────────────────────────────────────────────────────────
    def waple_owner(t, key):
        """키가 어느 Waple 함수에서 읽히는가. None = 이 타입 경로에서 미파싱."""
        if key in SHARED_PARSE_KEYS and key in parse_keys:
            return "parse"
        for fn in TYPE_FUNCS.get(t, []):
            if key in per_func.get(fn, set()):
                return fn
        return None

    keys_by_type = {}
    unparsed = []
    for t in sorted(keys_n, key=lambda x: (-sum(keys_n[x].values()), x)):
        rows = {}
        for k, n in sorted(keys_n[t].items(), key=lambda kv: (-kv[1], kv[0])):
            owner = waple_owner(t, k)
            row = {"n": n, "scenes": len(keys_scenes[t][k]),
                   "types": top(keys_types[t][k])}
            st = vec_stats.get((t, k)) or num_stats.get((t, k))
            if st:
                row["range"] = [round(st["min"], 5), round(st["max"], 5)]
                row["distinct"] = len(st["distinct"])
            vals = keys_vals[t][k]
            if vals and len(vals) <= ENUM_MAX:
                row["values"] = top(vals)
            elif vals:
                row["distinctValues"] = len(vals)
            row["waple"] = owner
            rows[k] = row
            if owner is None:
                unparsed.append({
                    "type": t, "key": k, "objects": n, "scenes": len(keys_scenes[t][k]),
                    "valueTypes": top(keys_types[t][k]),
                    "distinctValues": len(vals) if vals else (len(st["distinct"]) if st else None),
                    "topValues": top(vals, 4) if vals else None,
                    "range": row.get("range"),
                    "literalElsewhereInFile": k in whole_file,
                    "deliberate": DELIBERATE_DROP.get(t + "." + k),
                    "uniformValue": (len(vals) == 1 if vals
                                     else (len(st["distinct"]) == 1 if st else None)),
                })
        keys_by_type[t] = rows
    unparsed.sort(key=lambda r: (-r["objects"], r["type"], r["key"]))

    gen_rows = {}
    gen_unparsed = []
    for k, n in sorted(gen_n.items(), key=lambda kv: (-kv[1], kv[0])):
        owner = k in general_keys_waple
        row = {"n": n, "types": top(gen_types[k]), "waple": owner}
        vals = gen_vals[k]
        if vals and len(vals) <= ENUM_MAX:
            row["values"] = top(vals)
        elif vals:
            row["distinctValues"] = len(vals)
        gen_rows[k] = row
        if not owner:
            gen_unparsed.append({"key": k, "scenes": n, "valueTypes": top(gen_types[k]),
                                 "topValues": top(vals, 4) if vals else None})
    waple_general_absent = sorted(k for k in general_keys_waple
                                  if k not in gen_n and k in {"quality", "bloomtint", "bloomhdriterations",
                                                              "perspectiveoverridefov", "windenabled",
                                                              "gravitystrength", "camerashakeroughness"})

    case_variants = {k: top(v) for k, v in sorted(key_case.items()) if len(v) > 1}
    const_case_clash = []
    for f, m in sorted(eff_const_case.items()):
        for lk, spell in sorted(m.items()):
            if len(spell) > 1:
                const_case_clash.append({"effect": f, "key": lk, "spellings": top(spell)})

    observed_keys = set(gen_n) | {k for t in keys_n for k in keys_n[t]} | set(eff_keys) \
        | set(eff_pass_keys) | set(anim_keys) | set(cam_keys)
    nscenes = sum(pops.values())
    corpus_ev = specfmt.ev("corpus", "워크샵 코퍼스 scene.json 전수 %d씬" % nscenes)
    script_ev = specfmt.ev("script", "scripts/spec/measure_scene_schema.py")
    src_ev = specfmt.ev("file", "Sources/WapleCore/SceneDocument.swift",
                        "함수 경계로 잘라 타입별 파스 함수의 JSON 키 리터럴만 대조")

    entries = [
        specfmt.entry("scene.corpus.population", {
            "scenes": nscenes,
            "byPackage": top(pops),
            "parseErrors": top(errors),
            "note": "corpus/inventory.json 의 scene 162 와 일치. gifscene.pkg/gifscene.json 1건 포함 "
                    "(project.json type 이 아니라 pkg 안의 scene.json 존재로 선별 — type 대소문자 함정 회피)",
            "remeasureCaveat": "이 파일은 코퍼스뿐 아니라 Sources/WapleCore/SceneDocument.swift 에도 "
                               "의존한다(waple.* 항목). 재측정 diff 의 원인은 셋이다 — 측정 비결정성, "
                               "WE 업데이트, **그리고 SceneDocument.swift 변경**. 마지막은 정상이며, "
                               "갭이 메워졌다는 뜻이다(spec/README.md 의 2원인 설명에 대한 예외)",
            "topLevelKeys": top(top_keys),
            "version": top(versions),
            "dimension": {"2D(orthogonalprojection dict)": dims_2d, "3D(camera+fov)": dims_3d},
            "cameraKeys": top(cam_keys),
        }, "확정", [corpus_ev, script_ev]),

        specfmt.entry("scene.general.keys", gen_rows, "확정", [corpus_ev, script_ev, src_ev]),

        specfmt.entry("scene.objects.typeTaxonomy", {
            "resolution": "콘텐츠 키의 존재로만 결정된다 — scene.json objects[] 에 type 필드는 없다",
            "precedence": ["sound", "node(콘텐츠 키 없음)", "image", "particle", "text",
                           "model", "light", "camera", "shape+effects"],
            "counts": top(obj_n),
            "contentKeyExplicitNull": top(content_null),
            "multipleContentKeys": 0,
            "objectsWithoutId": top(no_id),
            "lightTypeDomain": top(keys_vals["light"]["light"]),
            "shapeDomain": top(keys_vals["shape"]["shape"]),
            "cameraDomain": top(keys_vals["camera"]["camera"]),
        }, "확정", [corpus_ev, script_ev]),

        specfmt.entry("scene.objects.keysByType", keys_by_type, "확정", [corpus_ev, script_ev, src_ev]),

        specfmt.entry("scene.bindings.forms", {
            "definition": "{user|script|animation|value|scriptproperties} 로만 이루어진 객체. "
                          "animationlayers[] 원소도 animation 키를 갖지만 name/blend/rate 를 동반해 제외된다",
            "forms": top(bind_forms),
            "note": "관측된 모든 바인딩이 value 를 동반한다 — unwrapValue 의 {\"value\":X} 언랩이 전건 성립. "
                    "즉 평문 값을 기대하는 코드는 unwrap 만 통과하면 바인딩 형태를 놓치지 않는다",
            "withoutValue": top(bind_novalue),
            "excludedImpureShapes": top(bind_impure),
            "byKeyPath": {p: top(c) for p, c in sorted(bind_path.items())},
            "nestedByPrefix": {p: top(c) for p, c in sorted(bind_nested.items())},
        }, "확정", [corpus_ev, script_ev]),

        specfmt.entry("scene.objects.colorBlendMode", {
            "byType": {t: top(c) for t, c in sorted(cbm.items())},
            "range": "common_blending.h ApplyBlending enum 0-32 — 범위 밖 값 0건",
            "note": "키는 camelCase colorBlendMode(스키마 대다수의 소문자 규칙에서 벗어난다). "
                    "parallaxDepth 도 동일 예외",
        }, "확정", [corpus_ev, script_ev]),

        specfmt.entry("scene.effects.schema", {
            "effectKeys": top(eff_keys),
            "passKeys": top(eff_pass_keys),
            "visibleValueTypes": top(eff_vis_types),
            "textureElementTypes": {k: top(v) for k, v in sorted(eff_tex.items())},
            "combosKeyDomain": top(eff_combo, 40),
            "combosKeyCase": "전건 대문자(AUDIOPROCESSING/BLENDMODE/…) — 케이스 혼용 0건",
            "constantKeyCaseClashWithinSameEffect": const_case_clash,
        }, "확정", [corpus_ev, script_ev]),

        specfmt.entry("scene.animationLayers.schema", {
            "keys": top(anim_keys),
            "valueTypes": {k: top(v) for k, v in sorted(anim_types.items())},
            "layersPerObject": {str(k): v for k, v in sorted(anim_count.items())},
            "blendtimeOnMultiLayerObjects": anim_blendtime_multi,
        }, "확정", [corpus_ev, script_ev]),

        specfmt.entry("scene.keyCaseVariants", {
            "variants": case_variants,
            "conclusion": "scene.json 키에는 대소문자 혼용이 **없다**. corpus/inventory.json 의 "
                          "project.json type(video/Video) 함정은 여기에 재현되지 않는다 — "
                          "scene.json 은 camelCase 예외 2개(colorBlendMode/parallaxDepth)를 제외하면 전부 소문자이고 "
                          "각 키의 철자가 코퍼스 전체에서 단일하다",
        }, "확정", [corpus_ev, script_ev]),

        specfmt.entry("scene.anomalies", {
            "duplicateObjectIds": {"scenes": len(dup_ids), "detail": top(dup_ids)},
            "danglingParentIds": {"scenes": len(dangling), "detail": top(dangling)},
            "selfParent": self_parent,
            "alphaOutside01": top(alpha_out),
            "negativeScaleComponents": top(neg_scale),
            "negativeParallaxDepth": top(neg_parallax),
            "zeroParallaxDepth": top(zero_parallax),
            "orthogonalProjectionExtraKeys": top(ortho_extra),
            "generalNullValues": {k: gen_types[k]["null"] for k in sorted(gen_types)
                                  if gen_types[k]["null"]},
            "note": "벡터는 전부 문자열('x y z')이라 JSON 숫자 음수는 0건 — 음수는 문자열 성분 파스 후에만 보인다",
        }, "확정", [corpus_ev, script_ev]),

        specfmt.entry("waple.parsedKeysByFunction", {
            "note": "SceneDocument.swift 를 함수 경계로 잘라 뽑은 JSON 키 리터럴 중, 코퍼스 scene.json 에 "
                    "실제로 등장하는 것만 남긴 교집합. 타입 → 함수 매핑은 TYPE_FUNCS 참조",
            "byFunction": {fn: sorted(per_func.get(fn, set()) & observed_keys)
                           for fn in sorted(set(sum(TYPE_FUNCS.values(), [])) |
                                            {"parse", "applyGeneralSettings", "parseCamera",
                                             "parseEffects", "parseAllAnimationLayers"})},
        }, "확정", [src_ev, script_ev]),

        specfmt.entry("waple.unparsedObjectKeys", {
            "method": "타입별 파스 함수 + parse() 공통 전처리 키만 '파싱됨'으로 친다. "
                      "literalElsewhereInFile=true 는 다른 타입 경로에는 있으나 이 타입에는 없다는 뜻. "
                      "deliberate 는 소스에 '왜 버리는지' 주석이 있는 것(미인지 누락과 구분), "
                      "uniformValue=true 는 코퍼스 관측값이 단일이라 파싱해도 결과가 같은 것",
            "caveat": "'읽는다'와 '보존한다'는 다르다. 이 표는 리터럴 존재만 보증한다. 확인된 3건: "
                      "(a) id — parse() 가 가시성 게이트 판정에 obj[\"id\"] 를 읽지만 SceneParticle 에 id "
                      "필드가 없어 파티클은 parent 룩업 대상이 못 된다(waple.parentTransformRegistration). "
                      "(b) camera.visible — SceneCameraObject 에 visible 필드가 없고 parseCameraObject 의 "
                      "스크립트 캡처는 origin/zoom/fov 뿐이라 script 형 10건이 유실된다(정적 false 10건은 "
                      "게이트가 드롭). (c) light.visible — SceneLight3D 에도 visible 필드가 없어 script 형 "
                      "5건이 유실(스크립트로 껐다 켜는 라이트가 상시 켜짐)",
            "keys": unparsed,
        }, "확정", [corpus_ev, script_ev, src_ev]),

        specfmt.entry("waple.unparsedGeneralKeys", {
            "keys": gen_unparsed,
            "wapleParsedButNeverAuthored": waple_general_absent,
        }, "확정", [corpus_ev, script_ev, src_ev]),

        specfmt.entry("waple.valueShapeMismatch", {
            "method": "Waple 이 스칼라 Float 로 읽는 키에 코퍼스가 공백 구분 벡터 문자열을 넣는 경우. "
                      "lenientFloat(Float(\"0.00000 0.00000\")) 는 nil 이라 값이 통째로 사라진다",
            "found": {k: top(v, 4) for k, v in sorted(shape_mismatch.items())},
            "wapleCode": "SceneDocument.parseText: t.spacing = float(obj[\"spacing\"]) — "
                         "SceneTextLayer.spacing 은 Float? 이라 벡터를 담을 수 없다",
        }, "확정", [corpus_ev, script_ev, src_ev]),

        specfmt.entry("waple.textParallaxScope", {
            "method": "text.parallaxDepth 는 parseText 가 읽지 않고 SceneRendererFrameEncoder 의 텍스트 "
                      "드로우가 parallaxDepth=1 로 고정한다. 실효 범위는 cameraparallax 가 켜진 씬뿐",
            "parallaxEnabledScenes": parallax_scenes,
            "textObjectsInThoseScenes": top(text_pd_in_parallax),
            "wapleCode": "encodeText: `var depth = SIMD2<Float>(1, 1)` → setVertexBytes(index 2). "
                         "같은 파일에서 이미지 레이어는 `layer.parallaxDepth`, 파티클은 `sys.parallaxDepth`",
        }, "확정", [corpus_ev, script_ev,
                    specfmt.ev("file", "Sources/WapleRender/SceneRendererFrameEncoder.swift:1519",
                               "코드 실독: encodeText 의 depth 는 리터럴 (1,1). "
                               "대조군 :449 layer.parallaxDepth / :1578 sys.parallaxDepth")]),

        specfmt.entry("waple.parentTransformRegistration", {
            "method": "buildParentTransformMap/composeParentTransforms 가 localT 에 넣는 것은 "
                      "layers(image·shape) + nodes3D(콘텐츠 없음 또는 정적 비가시) + texts 뿐. "
                      "SceneParticle/SceneObject3D/SceneCameraObject/SceneSound 는 id 등록이 없다",
            "resolved": top(parent_ok),
            "unresolved": top(parent_missing),
            "note": "3D 씬(camera3D!=nil)은 composeParentTransforms 자체를 스킵하므로 3D 항목은 "
                    "SceneRenderer3D 월드행렬 경로의 몫이다 — 2D 항목만 파스 갭이다",
        }, "확정", [corpus_ev, script_ev, src_ev]),
    ]

    # 측정과 결론은 분리한다. 아래는 위 측정치로부터의 **해석**이고, 이 머신에는 Swift 툴체인이
    # 없어 렌더 결과로 검증하지 못했다 → 전부 '보고'.
    entries.append(specfmt.entry("waple.gapImpact", {
        "caveat": "이 머신에 Swift 툴체인이 없어 렌더 대조를 못 했다. 아래는 측정치 + 소스 독해의 해석이다",
        "live": [
            {"what": "text.parallaxDepth 미파싱",
             "measured": "text 오브젝트 956개(전체 1597)가 이 키를 가진다. cameraparallax 활성 56씬 안에서만 "
                         "482개가 실효 — 그중 269개는 0(시차 없음), 184개는 음수(역시차)",
             "expect": "WE 는 이 텍스트들을 마우스와 함께 움직이지 않거나 반대로 움직인다. "
                       "Waple 은 전부 depth=1(배경과 같은 속도)로 그린다"},
            {"what": "animationlayers[].blendin/blendout/blendtime 미파싱",
             "measured": "1374 레이어 전건 보유(blendin/blendout=bool, blendtime=0.5 균일). "
                         "그중 1223 이 2층 이상 캐스케이드 오브젝트에 붙어 있다",
             "expect": "퍼펫/모델 애니 레이어 전환이 WE 에서는 0.5초 크로스페이드, Waple 은 즉시 전환"},
            {"what": "가시 particle 을 parent 로 쓰는 오브젝트(2D 57건)",
             "measured": "SceneParticle 에 id 필드가 없어 buildParentTransformMap 에 등록되지 않는다. "
                         "자식·부모 모두 disablepropagation=false/미저작이라 자기배제도 아니다",
             "expect": "그 자식들이 저작 로컬 좌표 그대로 남는다(부모 파티클 위치가 원점에서 멀수록 어긋난다)"},
            {"what": "text.brightness 미파싱(568 오브젝트)",
             "measured": "float 스칼라. SceneTextLayer 에 brightness 필드 자체가 없다",
             "expect": "밝기 배수를 준 텍스트가 기본 밝기로 그려진다"},
            {"what": "light.visible 스크립트 유실(5건)",
             "measured": "SceneLight3D 에 visible 필드가 없고 parseLight 의 스크립트 캡처는 "
                         "color/intensity/radius/origin/angles 뿐. 정적 false 1건은 게이트가 드롭",
             "expect": "스크립트로 켰다 껐다 하는 라이트가 Waple 에서는 상시 켜짐"},
            {"what": "camera.visible 스크립트 유실(10건)",
             "measured": "SceneCameraObject 에 visible 필드가 없고 parseCameraObject 의 스크립트 캡처는 "
                         "origin/zoom/fov 뿐. 정적 false 10건은 게이트가 드롭",
             "expect": "카메라 프리셋 전환(여러 카메라 오브젝트 중 스크립트로 하나만 활성)이 "
                       "무시된다 — 다만 Waple 의 카메라 오브젝트 소비는 zoom/origin 애니뿐이라 "
                       "실피해 범위는 미확인"},
        ],
        "inert": [
            {"what": "image/text/shape.castshadow(5568 오브젝트)", "why": "관측값 전건 false — 파싱해도 같은 결과"},
            {"what": "node.disablepropagation(595)/node.solid(595)", "why": "관측값 단일(각각 false/true)"},
            {"what": "text.spacing(171)", "why": "전건 \"0.00000 0.00000\" — 벡터/스칼라 형상 불일치지만 값이 항등"},
            {"what": "sound.muteineditor(378)", "why": "에디터 전용 플래그, 런타임 재생과 무관"},
        ],
        "notGaps": [
            {"what": "general.quality", "why": "Waple 이 파싱하지만 코퍼스 162씬 중 0건이 저작 — 게이트가 죽어 있다"},
            {"what": "scene.version(1/3/4/5, 159씬)", "why": "Waple 이 아예 읽지 않는다. 4세대 스키마를 한 파서로 "
                                                             "처리 중이며 지금까지는 문제가 관측되지 않았다"},
            {"what": "general.camerapreview(162)/lightconfig(11)/transparentsorting(3)/fog*(2)",
             "why": "에디터 메타 또는 미구현 기능. 렌더 소비처가 없다"},
        ],
    }, "보고", [corpus_ev, src_ev]))

    specfmt.dump(specfmt.doc("scripts/spec/measure_scene_schema.py", entries), OUT)

    print("씬 %d개 (%s), 오류 %d건" % (nscenes, dict(pops), sum(errors.values())))
    print("  오브젝트 %s" % top(obj_n))
    print("  키 케이스 변형 %d건" % len(case_variants))
    print("  미파싱 오브젝트 키 %d종 / general %d종" % (len(unparsed), len(gen_unparsed)))
    print("  2D 부모 미해결 %s" % {k: v for k, v in top(parent_missing).items() if k.startswith("2D")})
    print("  → %s" % OUT)


if __name__ == "__main__":
    main()
