"""material/effect JSON 스키마 정본을 만든다 — 이펙트 체인 구현의 계약.

모집단을 셋으로 분리한다. 셋을 섞으면 도수가 왜곡된다:
  ① 번들 최상위   assets/effects/<name>/effect.json (WE 가 실제로 배포하는 이펙트)
  ② 번들 preview  assets/effects/<name>/preview/** (에디터 미리보기용 축약 사본)
  ③ 코퍼스        워크샵 scene.pkg 안의 material/effect JSON

분류 규약(느슨한 매칭 금지):
  effect  = basename 이 정확히 "effect.json"
  material= passes[0] 에 shader 가 있고 effect 가 아닌 것
  느슨하게 endswith("effect.json") 로 잡으면 "Paper Effect.json"(실제로는 머티리얼)이
  섞여 effect 패스 키 표가 오염된다 — 실측으로 확인된 함정이다.

WE 의 JSON 은 엄격 JSON 이 아니다(// 주석, 트레일링 콤마). 관대 파서를 쓰되
어느 파일이 엄격 파싱에 실패하는지도 함께 기록한다 — Swift JSONSerialization 은 엄격이라
그 목록이 곧 Waple 의 실패 목록이다.
"""
import collections
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt
from measure_corpus import parse_pkg

WS = os.environ.get("WE_WORKSHOP", r"Z:\SteamLibrary\steamapps\workshop\content\431960")
WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")
ASSETS = os.path.join("Sources", "WapleRender", "Resources", "WEAssets")
SWIFT = "Sources"

# 값 도메인을 통째로 기록할 렌더 상태 키 — 개수가 유한하고 파이프라인 상태로 직결된다.
STATE_KEYS = ("blending", "cullmode", "culling", "depthtest", "depthwrite", "alphawriting")


# ---------------------------------------------------------------- 관대 JSON

def strip_lenient(text):
    """// 및 /* */ 주석과 트레일링 콤마를 문자열 리터럴 밖에서만 제거한다."""
    out = []
    i, n, instr = 0, len(text), False
    while i < n:
        c = text[i]
        if instr:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1]); i += 2; continue
            if c == '"':
                instr = False
            i += 1
            continue
        if c == '"':
            instr = True; out.append(c); i += 1; continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] not in "\r\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        out.append(c); i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def load_json(raw):
    """(obj, "strict"|"lenient") 반환. 둘 다 실패하면 예외."""
    text = raw.decode("utf-8-sig", "replace") if isinstance(raw, bytes) else raw
    try:
        return json.loads(text), "strict"
    except ValueError:
        return json.loads(strip_lenient(text)), "lenient"


def freq(counter):
    """재측정 결정성: 도수 내림차순 → 키 오름차순. Counter 삽입 순서에 기대지 않는다."""
    return {k: v for k, v in sorted(counter.items(), key=lambda kv: (-kv[1], str(kv[0])))}


def key(v):
    """값을 도수표의 딕트 키로. 문자열은 그대로(따옴표 중첩 방지), 나머지는 JSON 표기."""
    return v if isinstance(v, str) else json.dumps(v)


# ---------------------------------------------------------------- 수집

def is_effect(path):
    return os.path.basename(path).lower() == "effect.json"


def is_preview(rel):
    """미리보기 서브트리 판정. 디렉터리 이름이 preview 로 시작하면 미리보기다 —
    실물에 preview 말고 previewvhs / previewflat / previewwaterfaucet 도 있다."""
    return any(seg.startswith("preview") for seg in rel.split("/")[:-1])


def bundled_json_paths(root):
    """materials/ 와 effects/ 아래의 *.json 상대경로만. 다른 최상위(presets/scenes 등)는 이 영역이 아니다."""
    for top in ("materials", "effects"):
        for dirpath, _, files in os.walk(os.path.join(root, top)):
            for f in sorted(files):
                if f.endswith(".json"):
                    full = os.path.join(dirpath, f)
                    yield full, os.path.relpath(full, root).replace(os.sep, "/")


def collect_bundled():
    """(pop 이름 -> [(rel, obj)]) 와 엄격 파싱 실패 목록."""
    pops = collections.defaultdict(list)
    strict_fail = []
    root = ASSETS if os.path.isdir(ASSETS) else os.path.join(WE, "assets")
    for full, rel in sorted(bundled_json_paths(root), key=lambda x: x[1]):
        with open(full, "rb") as fh:
            raw = fh.read()
        try:
            obj, mode = load_json(raw)
        except ValueError as e:
            strict_fail.append({"path": rel, "error": str(e)[:60], "recoverable": False})
            continue
        if mode == "lenient":
            text = raw.decode("utf-8-sig", "replace")
            why = []
            if re.search(r"(^|[^:])//", text):
                why.append("comment")
            if re.search(r",\s*[}\]]", text):
                why.append("trailing-comma")
            strict_fail.append({"path": rel, "needs": "+".join(why) or "?", "recoverable": True})
        if not isinstance(obj, dict):
            continue
        preview = is_preview(rel)
        if rel.startswith("effects/") and is_effect(rel):
            pops["bundled.effect.preview" if preview else "bundled.effect.top"].append((rel, obj))
        elif isinstance(obj.get("passes"), list) and obj["passes"] \
                and isinstance(obj["passes"][0], dict) and "shader" in obj["passes"][0]:
            if rel.startswith("materials/"):
                pops["bundled.material.shared"].append((rel, obj))
            elif preview:
                pops["bundled.material.preview"].append((rel, obj))
            else:
                pops["bundled.material.effect"].append((rel, obj))
    return pops, strict_fail


def collect_corpus():
    """코퍼스 pkg 를 전수 열어 effect/material JSON 을 뽑는다. 자기검증 수치도 함께."""
    effects, materials = [], []
    audit = collections.Counter()
    for wid in sorted(os.listdir(WS)):
        d = os.path.join(WS, wid)
        if not os.path.isdir(d):
            continue
        for fn in ("scene.pkg", "gifscene.pkg"):
            path = os.path.join(d, fn)
            if not os.path.exists(path):
                continue
            with open(path, "rb") as fh:
                data = fh.read()
            try:
                _, entries, base = parse_pkg(data)
            except ValueError:
                audit["pkgParseError"] += 1
                continue
            audit["pkg"] += 1
            for name, off, size in entries:
                nm = name.replace("\\", "/")
                if not nm.lower().endswith(".json"):
                    continue
                top = nm.split("/")[0]
                if top in ("materials", "effects"):
                    audit["jsonUnder." + top] += 1
                try:
                    obj, mode = load_json(data[base + off: base + off + size])
                except ValueError:
                    audit["jsonParseError"] += 1
                    continue
                audit["parse." + mode] += 1
                if not isinstance(obj, dict):
                    continue
                ref = f"{wid}/{nm}"
                if is_effect(nm):
                    effects.append((ref, obj))
                elif isinstance(obj.get("passes"), list) and obj["passes"] \
                        and isinstance(obj["passes"][0], dict) and "shader" in obj["passes"][0]:
                    materials.append((ref, obj))
    return effects, materials, audit


# ---------------------------------------------------------------- 집계

def material_stats(items):
    s = dict(files=len(items), top=collections.Counter(), passCount=collections.Counter(),
             passKeys=collections.Counter(), domain=collections.defaultdict(collections.Counter),
             shaders=collections.Counter(), texLen=collections.Counter(), texNull=0,
             texClass=collections.Counter(), texNames=collections.Counter(),
             combos=collections.Counter(), comboVal=collections.Counter(),
             csv=collections.Counter(), csvType=collections.Counter(), csvDict=collections.Counter(),
             usv=collections.Counter(), utex=collections.Counter(), other=collections.Counter())
    known = set(STATE_KEYS) | {"shader", "textures", "combos", "constantshadervalues",
                               "usershadervalues", "usertextures"}
    for _, d in items:
        for k in d:
            s["top"][k] += 1
        passes = d.get("passes") or []
        s["passCount"][len(passes)] += 1
        for p in passes:
            if not isinstance(p, dict):
                continue
            for k, v in p.items():
                s["passKeys"][k] += 1
                if k in STATE_KEYS:
                    s["domain"][k][v if isinstance(v, str) else "<%s>" % type(v).__name__] += 1
                elif k == "shader" and isinstance(v, str):
                    s["shaders"][v] += 1
                elif k not in known:
                    s["other"][k] += 1
            t = p.get("textures")
            if isinstance(t, list):
                s["texLen"][len(t)] += 1
                for x in t:
                    if x is None:
                        s["texNull"] += 1
                    elif isinstance(x, str):
                        s["texNames"][x] += 1
                        s["texClass"]["_rt_*" if x.startswith("_rt_")
                                      else "util/*" if x.startswith("util/") else "에셋경로"] += 1
                    else:
                        s["texClass"]["<%s>" % type(x).__name__] += 1
            c = p.get("combos")
            if isinstance(c, dict):
                for k, v in c.items():
                    s["combos"][k] += 1
                    s["comboVal"]["<%s>" % type(v).__name__] += 1
            cs = p.get("constantshadervalues")
            if isinstance(cs, dict):
                for k, v in cs.items():
                    s["csv"][k] += 1
                    s["csvType"]["<%s>" % type(v).__name__] += 1
                    if isinstance(v, dict):
                        s["csvDict"]["+".join(sorted(v))] += 1
            u = p.get("usershadervalues")
            if isinstance(u, dict):
                for _k, v in u.items():
                    s["usv"]["<%s>" % type(v).__name__] += 1
            ut = p.get("usertextures")
            if isinstance(ut, list):
                s["utex"]["<list>"] += 1
                for x in ut:
                    s["utex"]["항목:<%s>" % type(x).__name__] += 1
                    if isinstance(x, dict):
                        s["utex"]["항목키:" + "+".join(sorted(x))] += 1
            elif ut is not None:
                s["utex"]["<%s>" % type(ut).__name__] += 1
    return s


def effect_stats(items):
    s = dict(files=len(items), top=collections.Counter(), passCount=collections.Counter(),
             passKeys=collections.Counter(), target=collections.Counter(),
             targetClass=collections.Counter(), command=collections.Counter(),
             compose=collections.Counter(), composeSites=[],
             bindKeys=collections.Counter(), bindName=collections.Counter(),
             bindClass=collections.Counter(), bindIndex=collections.Counter(),
             fboKeys=collections.Counter(), fboScale=collections.Counter(),
             fboSizeShape=collections.Counter(), fboNoSize=[],
             fboFormat=collections.Counter(), fboMisc=collections.defaultdict(collections.Counter),
             conditions=collections.Counter(), condSites=[], functions=[])
    for ref, d in items:
        for k in d:
            s["top"][k] += 1
        passes = d.get("passes") or []
        s["passCount"][len(passes)] += 1
        if "functions" in d and len(s["functions"]) < 4:
            s["functions"].append({"file": ref, "value": d["functions"]})
        for p in passes:
            if not isinstance(p, dict):
                continue
            for k in p:
                s["passKeys"][k] += 1
            tv = p.get("target")
            s["target"][tv if isinstance(tv, str) else "(target 없음)"] += 1
            s["targetClass"]["(없음)=이펙트 출력" if tv is None
                             else "_rt_*" if isinstance(tv, str) and tv.startswith("_rt_")
                             else "자유이름"] += 1
            if "command" in p:
                s["command"]["%s (source=%s, target=%s)" % (p.get("command"), "source" in p, "target" in p)] += 1
            if "compose" in p:
                s["compose"][key(p["compose"])] += 1
                if len(s["composeSites"]) < 6:
                    s["composeSites"].append({"file": ref, "pass": p})
            if "conditions" in p:
                s["conditions"]["pass.conditions"] += 1
                if len(s["condSites"]) < 4:
                    s["condSites"].append({"file": ref, "where": "pass", "value": p["conditions"]})
            for b in (p.get("bind") or []) if isinstance(p.get("bind"), list) else []:
                if not isinstance(b, dict):
                    continue
                for k in b:
                    s["bindKeys"][k] += 1
                nm = b.get("name")
                s["bindName"][nm if isinstance(nm, str) else "<%s>" % type(nm).__name__] += 1
                s["bindClass"]["previous" if nm == "previous"
                               else "prev(축약)" if nm == "prev"
                               else "_rt_*" if isinstance(nm, str) and nm.startswith("_rt_")
                               else "자유이름"] += 1
                s["bindIndex"][key(b.get("index"))] += 1
                if "conditions" in b:
                    s["conditions"]["bind.conditions"] += 1
                    if len(s["condSites"]) < 4:
                        s["condSites"].append({"file": ref, "where": "bind", "value": b["conditions"]})
        for f in (d.get("fbos") or []) if isinstance(d.get("fbos"), list) else []:
            if not isinstance(f, dict):
                continue
            # 크기 키 조합. 실물에 "아무 크기 키도 없는" fbo 가 있다 — 표에 반드시 드러나야 한다.
            size = tuple(sorted(k for k in ("scale", "fit", "width", "height") if k in f))
            s["fboSizeShape"]["+".join(size) if size else "(크기 키 없음)"] += 1
            if not size and len(s["fboNoSize"]) < 4:
                s["fboNoSize"].append({"file": ref, "fbo": f})
            for k, v in f.items():
                s["fboKeys"][k] += 1
                if k == "scale":
                    s["fboScale"][key(v)] += 1
                elif k == "format":
                    s["fboFormat"][key(v)] += 1
                elif k == "conditions":
                    s["conditions"]["fbo.conditions"] += 1
                    if len(s["condSites"]) < 4:
                        s["condSites"].append({"file": ref, "where": "fbo", "value": v})
                elif k != "name":
                    s["fboMisc"][k][key(v)] += 1
    return s


# ---------------------------------------------------------------- util 카탈로그

UTIL_ROLES = {
    "backbufferpassthrough": "백버퍼 통과(선형 감마)",
    "blur_h_bloom": "LDR 블룸 수평 블러 — 1/8 버퍼 입력",
    "ccsimple": "단순 컬러 커렉션 — 풀프레임 입력",
    "clippingmaskimage4": "클리핑 마스크 적용(이미지4 계열)",
    "combine": "최종 합성 — 풀프레임 + 블룸(기본 util/black = 블룸 없음)",
    "combine_dhdr_upsample": "combine_hdr 의 DISPLAYHDR=1 변종(디스플레이 HDR 출력)",
    "combine_hdr_editor": "combine_hdr 의 에디터 변종",
    "combine_hdr_upsample": "HDR 최종 합성 + 블룸 업샘플",
    "combine_hdr_upsample_dbg": "combine_hdr 의 COMBINEDBG=1 디버그 변종",
    "combine_hdr_upsample_linear": "combine_hdr 의 LINEAR=1 변종",
    "combine_ldr": "LDR 최종 합성 — 풀프레임 + _rt_Bloom",
    "combine_srgb": "sRGB 통과 합성",
    "combine_video_hdr": "비디오 레이어 HDR 합성",
    "compiler_backdrop": "에디터/컴파일러 배경판",
    "composelayer": "_rt_ 프레임버퍼 레이어 합성(컴포지트 레이어의 기본 머티리얼)",
    "composelayer_clearalpha": "composelayer 의 CLEARALPHA=1 + blending normal 변종",
    "composelayer_depthtest": "composelayer 의 depthtest enabled 변종",
    "debugrt": "디버그 — 렌더타깃 표시(풀프레임)",
    "debugrt_fb": "디버그 — 프레임버퍼 표시",
    "debugrt_fb_bloom": "디버그 — _rt_Bloom 표시",
    "debugrt_fb_eighth": "디버그 — 1/8 프레임버퍼 표시",
    "debugrt_fb_quarter": "디버그 — 1/4 프레임버퍼 표시",
    "debugrt_reflection": "디버그 — _rt_Reflection 표시",
    "downsample_eighth_blur_v": "1/8 다운샘플 + 수직 블러(_rt_4FrameBuffer 입력)",
    "downsample_quarter": "1/4 다운샘플",
    "downsample_quarter_bloom": "1/4 다운샘플(블룸 임계 적용)",
    "downsample_quarter_linear": "1/4 다운샘플(선형)",
    "effectcomposebackground": "이펙트 배경 합성 — textures[0]=null(=bind 로 주입), [1]=_rt_FullFrameBuffer. "
                               "compose:true 패스가 참조하는 유일한 머티리얼(refraction)",
    "effectpassthrough": "이펙트 통과 — 레이어 이미지 셰이더(genericimage3) 재사용",
    "effectpassthrough_4": "이펙트 통과 — genericimage4 판",
    "error": "로드 실패 표시(에러 머티리얼)",
    "fade": "페이드 — usershadervalues{schemecolor:tint}",
    "flat": "단색(플랫) 지오메트리",
    "flatalpha": "단색 + 알파(translucent)",
    "flatalphavertexcolor": "단색 + 알파 + 정점색(vertexcolor=1)",
    "flatpointalphavertexcolor": "포인트 스프라이트 단색 + 정점색",
    "flattexture": "최소 알파 텍스처(minimalalpha)",
    "fullscreenlayer": "풀스크린 레이어 — passthrough + _rt_FullFrameBuffer",
    "gizmo": "에디터 기즈모(플랫)",
    "gizmovertexcolor": "에디터 기즈모(정점색)",
    "hdr_downsample": "HDR 블룸 피라미드 다운샘플",
    "hdr_downsample_bloom": "HDR 블룸 피라미드 다운샘플(BLOOM=1, 임계 적용)",
    "hdr_upsample": "HDR 블룸 피라미드 업샘플(UPSAMPLE=1, additive)",
    "hdr_upsample_cubic": "HDR 블룸 업샘플 + BICUBIC=1(additive)",
    "occlusiontest": "오클루전 질의 전용(프래그 53B)",
    "passthrough": "통과 — 풀프레임 그대로",
    "shadowcaster": "그림자 캐스터 패스",
    "solidlayer": "단색 레이어 기본 머티리얼(flat, translucent)",
    "solidlayer_depthtest": "solidlayer 의 depthtest enabled 변종",
    "solidlayer_instance": "인스턴스 단색 레이어 — genericimage2 + version=2 + util/white",
    "solidlayer_instance_3": "인스턴스 단색 레이어 — genericimage3 판",
    "solidlayer_instance_4": "인스턴스 단색 레이어 — genericimage4 판",
    "solidlayer_instance_depthtest": "solidlayer_instance 의 depthtest 변종",
    "solidlayer_instance_depthtest_3": "solidlayer_instance_3 의 depthtest 변종",
    "solidlayer_instance_depthtest_4": "solidlayer_instance_4 의 depthtest 변종",
    "volumetrics_back": "볼류메트릭 라이트 — 백페이스 깊이",
    "volumetrics_blur_h": "볼류메트릭 라이트 버퍼 수평 블러(VERTICAL=0)",
    "volumetrics_blur_v": "볼류메트릭 라이트 버퍼 수직 블러(VERTICAL=1)",
    "volumetrics_combine": "볼류메트릭 라이트 버퍼 additive 합성",
    "volumetrics_front": "볼류메트릭 라이트 — 프론트 레이마치(additive)",
    "volumetrics_fullscreen": "볼류메트릭 라이트 — 풀스크린 판(FULLSCREEN=1)",
    "wireframe": "와이어프레임(에디터)",
}


def util_catalog():
    """materials/util 전 파일 측정 + 바이너리·코퍼스 참조 도수."""
    root = ASSETS if os.path.isdir(ASSETS) else os.path.join(WE, "assets")
    udir = os.path.join(root, "materials", "util")
    files = sorted(os.listdir(udir))
    names = [f[:-5] for f in files if f.endswith(".json")]
    ext = collections.Counter(os.path.splitext(f)[1].lower() or "(없음)" for f in files)

    # 코퍼스 원문에서 util/<name> 참조를 한 번의 정규식 패스로 센다(패턴 62개 × pkg 반복은 느리다).
    pat = re.compile(rb"util/([A-Za-z0-9_]+)")
    corpus_ref = collections.Counter()
    for wid in sorted(os.listdir(WS)):
        d = os.path.join(WS, wid)
        if not os.path.isdir(d):
            continue
        for fn in ("scene.pkg", "gifscene.pkg"):
            path = os.path.join(d, fn)
            if not os.path.exists(path):
                continue
            with open(path, "rb") as fh:
                blob = fh.read()
            for nm in {m.group(1).decode("ascii", "ignore") for m in pat.finditer(blob)}:
                corpus_ref[nm] += 1          # pkg 단위 도수(파일 내 중복 미가산)

    exe = os.path.join(WE, "wallpaper64.exe")
    blob = open(exe, "rb").read() if os.path.exists(exe) else b""

    catalog = {}
    for nm in names:
        with open(os.path.join(udir, nm + ".json"), "rb") as fh:
            d = load_json(fh.read())[0]
        p0 = d["passes"][0]
        row = {"shader": p0.get("shader")}
        for k in STATE_KEYS:
            if k in p0:
                row[k] = p0[k]
        for k in ("textures", "combos", "constantshadervalues", "usershadervalues"):
            if k in p0:
                row[k] = p0[k]
        row["inWallpaper64Exe"] = bool(blob) and (f"util/{nm}".encode() in blob)
        row["corpusPkgRefs"] = corpus_ref.get(nm, 0)
        catalog[nm] = row
    return catalog, dict(sorted(ext.items())), len(files)


# ---------------------------------------------------------------- Waple 대조

# 스키마 키 -> Swift 소스에서 그 키가 리터럴로 등장하는지. 등장하지 않으면 확실한 미소비다.
COVERAGE_KEYS = [
    # material pass
    "shader", "blending", "cullmode", "culling", "depthtest", "depthwrite", "alphawriting",
    "textures", "combos", "constantshadervalues", "usershadervalues", "usertextures",
    # effect
    "passes", "fbos", "bind", "target", "material", "command", "source", "compose",
    "conditions", "functions", "dependencies", "replacementkey", "editable", "performance",
    # fbo
    "scale", "format", "unique", "fit", "uvs", "clear",
]


def swift_key_coverage():
    """Sources/**.swift 에서 각 키가 따옴표 리터럴로 등장하는지. 미등장 = 미소비 확정."""
    blobs = []
    for dirpath, _, files in os.walk(SWIFT):
        for f in files:
            if f.endswith(".swift"):
                with open(os.path.join(dirpath, f), encoding="utf-8", errors="replace") as fh:
                    blobs.append(fh.read())
    joined = "\n".join(blobs)
    return {k: ('"%s"' % k) in joined for k in COVERAGE_KEYS}


# ---------------------------------------------------------------- 본문

def main():
    pops, strict_fail = collect_bundled()
    corp_eff, corp_mat, audit = collect_corpus()

    m_top = material_stats(pops["bundled.material.shared"])
    m_eff = material_stats(pops["bundled.material.effect"] + pops["bundled.material.preview"])
    m_cor = material_stats(corp_mat)
    e_top = effect_stats(pops["bundled.effect.top"])
    e_prev = effect_stats(pops["bundled.effect.preview"])
    e_cor = effect_stats(corp_eff)

    catalog, util_ext, util_files = util_catalog()
    coverage = swift_key_coverage()

    asset_ev = specfmt.ev("asset", "%s/{materials,effects}/**/*.json" % ASSETS.replace(os.sep, "/"),
                          "WE 2.8.42 동봉 에셋 전수")
    corpus_ev = specfmt.ev("corpus", "워크샵 scene.pkg %d개 안의 JSON 엔트리 전수" % audit["pkg"])
    script_ev = specfmt.ev("script", "scripts/spec/measure_material_schema.py")

    def three(name, top, prev, cor):
        return {"번들최상위": top, "번들preview": prev, "코퍼스": cor} if name else None

    E = []
    add = E.append

    # ---- 모집단과 자기검증 -------------------------------------------------
    add(specfmt.entry("material.populations", {
        "번들 effect(최상위)": e_top["files"],
        "번들 effect(preview)": e_prev["files"],
        "번들 material(materials/)": m_top["files"],
        "번들 material(effects/ 하위)": m_eff["files"],
        "코퍼스 effect": e_cor["files"],
        "코퍼스 material": m_cor["files"],
        "분류규약": 'effect = basename 이 정확히 "effect.json"; material = passes[0].shader 보유',
        # [명시 2026-08-01] 번들 모집단의 경계를 밝힌다. 밝히지 않으면
        # spec/engine/render-state.json 과 분모가 달라 한쪽이 틀린 것처럼 보인다.
        "번들 모집단 경계": "이 문서의 번들 material 은 WEAssets/materials/ 와 WEAssets/effects/ "
                            "두 트리만 센다. presets/ 와 scenes/ 아래에도 passes 를 가진 "
                            "머티리얼 JSON 이 있으나 그건 에디터 콘텐츠 라이브러리·에디터 호스트 씬이라 "
                            "제외했다(spec/assets/misc-schema.json presets.editorOnly / scenes.editorHosts). "
                            "spec/engine/render-state.json 은 반대로 네 트리를 전부 세므로 분모가 크다 — "
                            "둘 다 옳고 세는 대상이 다르다. 도수를 비교할 때 이 경계를 먼저 맞춰라",
        "범위 밖": "scene.json 의 objects[].effects[].passes[] (씬이 이펙트 패스의 combos/"
                "constantshadervalues/textures 를 덮어쓰는 층)는 spec/corpus/scene-schema.json 의 "
                "scene.effects.schema 소관이다. 이 문서는 에셋 쪽 material/effect JSON 만 다룬다",
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("material.classificationAudit", {
        "코퍼스 pkg": audit["pkg"],
        "코퍼스 effects/ 하위 JSON 엔트리": audit["jsonUnder.effects"],
        "이 중 effect 로 분류": e_cor["files"],
        "코퍼스 materials/ 하위 JSON 엔트리": audit["jsonUnder.materials"],
        "이 중 material 로 분류": m_cor["files"],
        "차이": {
            "effects": audit["jsonUnder.effects"] - e_cor["files"],
            "materials": audit["jsonUnder.materials"] - m_cor["files"],
        },
        "차이가 0인 의미": "effects/ 아래 JSON 은 전부 effect.json 이고, materials/ 아래 JSON 은 전부 머티리얼이다. "
                     "분류가 경로와 완전히 일치하므로 이 표의 도수는 표본이 아니라 전수다",
        "함정": '느슨한 endswith("effect.json") 매칭은 3300031038/materials/Paper Effect.json 을 effect 로 '
              "오분류한다. 그러면 effect 패스 키 표에 material 키(shader/blending/cullmode/textures…)가 "
              "1건씩 섞여 들어간다. basename 정확 일치만 쓴다",
    }, "확정", [corpus_ev, script_ev]))

    # ---- WE JSON 은 엄격 JSON 이 아니다 -----------------------------------
    add(specfmt.entry("material.jsonDialect", {
        "허용": ["// 줄 주석", "트레일링 콤마"],
        "엄격 파싱 실패 파일 수(materials/ + effects/)": len(strict_fail),
        "그중 effects/ 최상위": sorted(x["path"] for x in strict_fail if not is_preview(x["path"])),
        "그중 preview 하위": sum(1 for x in strict_fail if is_preview(x["path"])),
        "원인 도수": freq(collections.Counter(x.get("needs", "?") for x in strict_fail)),
        "코퍼스 pkg 안 JSON": {"strict": audit["parse.strict"], "lenient": audit["parse.lenient"]},
        "note": "코퍼스 pkg 는 resourcecompiler 가 정규화해 전건 엄격 JSON. 비엄격은 WE 배포 에셋 원본에만 있다",
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("material.jsonDialect.strictFailures",
                      sorted(strict_fail, key=lambda x: x["path"]), "확정", [asset_ev, script_ev]))

    # ---- material 스키마 ---------------------------------------------------
    add(specfmt.entry("material.topLevelKeys", {
        "번들 materials/": freq(m_top["top"]),
        "번들 effects/ 하위": freq(m_eff["top"]),
        "코퍼스": freq(m_cor["top"]),
        "note": "material JSON 의 최상위 키는 passes 하나뿐이다 — 전 모집단 예외 0",
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("material.passCount", {
        "번들 materials/": freq(m_top["passCount"]),
        "번들 effects/ 하위": freq(m_eff["passCount"]),
        "코퍼스": freq(m_cor["passCount"]),
        "note": "passes 는 배열이지만 실측 길이는 전 모집단 1. 멀티패스 머티리얼은 존재하지 않는다",
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("material.passKeys", {
        "번들 materials/": freq(m_top["passKeys"]),
        "번들 effects/ 하위": freq(m_eff["passKeys"]),
        "코퍼스": freq(m_cor["passKeys"]),
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("material.stateValueDomains", {
        k: {"번들 materials/": freq(m_top["domain"][k]),
            "번들 effects/ 하위": freq(m_eff["domain"][k]),
            "코퍼스": freq(m_cor["domain"][k])}
        for k in STATE_KEYS
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("material.cullingTypo", {
        "관측": 'materials/util/flatpointalphavertexcolor.json 이 cullmode 대신 "culling":"nocull" 을 쓴다',
        "도수": {"번들": sum(m_top["domain"]["culling"].values()) + sum(m_eff["domain"]["culling"].values()),
               "코퍼스": sum(m_cor["domain"]["culling"].values())},
        "판정": "WE 에셋 쪽 오타. 별개 키가 아니다 — 파서가 인식하면 안 된다(WE 도 무시할 것으로 보이나 미검증)",
    }, "확정", [specfmt.ev("asset", ASSETS.replace(os.sep, "/") + "/materials/util/flatpointalphavertexcolor.json"),
                script_ev]))

    add(specfmt.entry("material.shaders", {
        "번들 materials/": {"uniq": len(m_top["shaders"]), "top15": dict(list(freq(m_top["shaders"]).items())[:15])},
        "번들 effects/ 하위": {"uniq": len(m_eff["shaders"]), "top15": dict(list(freq(m_eff["shaders"]).items())[:15])},
        "코퍼스": {"uniq": len(m_cor["shaders"]), "top20": dict(list(freq(m_cor["shaders"]).items())[:20])},
        "note": "값은 확장자 없는 셰이더 베이스 경로. 로더가 shaders/<값>.vert/.frag 로 해석한다. "
                "workshop/<id>/... 접두는 워크샵 의존 이펙트가 자기 셰이더를 동봉한 경우다",
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("material.textures", {
        "길이분포": {"번들 materials/": freq(m_top["texLen"]), "번들 effects/ 하위": freq(m_eff["texLen"]),
                 "코퍼스": freq(m_cor["texLen"])},
        "null 슬롯 수": {"번들 materials/": m_top["texNull"], "번들 effects/ 하위": m_eff["texNull"],
                     "코퍼스": m_cor["texNull"]},
        "값 종류": {"번들 materials/": freq(m_top["texClass"]), "번들 effects/ 하위": freq(m_eff["texClass"]),
                 "코퍼스": freq(m_cor["texClass"])},
        "코퍼스 상위 이름": dict(list(freq(m_cor["texNames"]).items())[:15]),
        "null 의 의미": "슬롯을 비워 두고 상위(effect bind / scene 패스 오버라이드)가 채운다. "
                    "effectcomposebackground 의 [null, _rt_FullFrameBuffer] 가 표준형",
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("material.combos", {
        "번들 materials/": {"uniq": len(m_top["combos"]), "keys": freq(m_top["combos"])},
        "번들 effects/ 하위": {"uniq": len(m_eff["combos"]), "keys": freq(m_eff["combos"])},
        "코퍼스": {"uniq": len(m_cor["combos"]), "keys": freq(m_cor["combos"])},
        "값 타입": {"번들": freq(m_top["comboVal"] + m_eff["comboVal"]), "코퍼스": freq(m_cor["comboVal"])},
        "대소문자 혼용": "VERSION/version, SPRITESHEET/spritesheet 이 같은 코퍼스 안에 공존한다 — "
                   "콤보 키 매칭은 대소문자 무시여야 한다",
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("material.constantShaderValues", {
        "코퍼스 키": {"uniq": len(m_cor["csv"]), "top20": dict(list(freq(m_cor["csv"]).items())[:20])},
        "번들 키": freq(m_top["csv"] + m_eff["csv"]),
        "값 타입": {"번들": freq(m_top["csvType"] + m_eff["csvType"]), "코퍼스": freq(m_cor["csvType"])},
        "dict 형태": freq(m_cor["csvDict"] + m_top["csvDict"] + m_eff["csvDict"]),
        "note": "<str> 은 공백 구분 벡터(\"1.0 0.5 0.25\"). <int>/<float> 은 스칼라. "
                "<dict> 은 바인딩이고 4형태다 — {user,value}=project.json 프로퍼티 참조, "
                "{script,value}/{script,scriptproperties,value}=JS 바인딩, "
                "{animation,script,value}=키프레임 타임라인 + JS(코퍼스 2건)",
        "이상치": "키 이름이 신뢰할 수 없다 — Brightness/Brigtness(오타) 공존, "
               "제로폭 문자만으로 된 키(U+200F/U+200E)도 1건 있다. 키 정규화·화이트리스트에 기대면 안 된다",
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("material.userShaderValues", {
        "번들 도수": m_top["passKeys"]["usershadervalues"] + m_eff["passKeys"]["usershadervalues"],
        "코퍼스 도수": m_cor["passKeys"]["usershadervalues"],
        "값 타입": freq(m_top["usv"] + m_eff["usv"] + m_cor["usv"]),
        "실물": 'materials/util/fade.json — {"schemecolor": "tint"}',
        "note": "코퍼스 5665개 머티리얼에 0건. 번들 1건뿐인 희귀 키다",
    }, "확정", [specfmt.ev("asset", ASSETS.replace(os.sep, "/") + "/materials/util/fade.json"),
                corpus_ev, script_ev]))

    add(specfmt.entry("material.userTextures", {
        "번들 도수": m_top["passKeys"]["usertextures"] + m_eff["passKeys"]["usertextures"],
        "코퍼스 도수": m_cor["passKeys"]["usertextures"],
        "형태": freq(m_cor["utex"] + m_top["utex"] + m_eff["utex"]),
        "실물": ['{"usertextures": ["background"]}  — 평문 유저프로퍼티 키',
               '{"usertextures": [{"name": "$mediaThumbnail", "type": "system"}]}  — 시스템 미디어 키'],
        "note": "textures 와 동일 슬롯 인덱스. 배열이지 딕셔너리가 아니다",
    }, "확정", [corpus_ev, script_ev]))

    # ---- effect 스키마 -----------------------------------------------------
    add(specfmt.entry("effect.topLevelKeys", {
        "번들최상위": freq(e_top["top"]), "번들preview": freq(e_prev["top"]), "코퍼스": freq(e_cor["top"]),
        "렌더 계약": ["passes", "fbos"],
        "메타(렌더 무관)": ["version", "name", "description", "group", "performance", "preview",
                      "replacementkey", "dependencies", "editable", "gizmos", "functions"],
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("effect.passCount", {
        "번들최상위": freq(e_top["passCount"]), "번들preview": freq(e_prev["passCount"]),
        "코퍼스": freq(e_cor["passCount"]),
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("effect.passKeys", {
        "번들최상위": freq(e_top["passKeys"]), "번들preview": freq(e_prev["passKeys"]),
        "코퍼스": freq(e_cor["passKeys"]),
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("effect.pass.target", {
        "종류 도수": {"번들최상위": freq(e_top["targetClass"]), "번들preview": freq(e_prev["targetClass"]),
                  "코퍼스": freq(e_cor["targetClass"])},
        "코퍼스 이름 전수(uniq %d)" % len(e_cor["target"]): freq(e_cor["target"]),
        "번들최상위 이름 전수": freq(e_top["target"]),
        "규약": "target 부재 = 이펙트 출력에 직접 기록. 존재 = fbos[] 의 이름",
        "함정": '이름이 _rt_ 접두라는 보장이 없다 — 코퍼스에 blur_start_2, _coc, _downscaled1, _full1 같은 '
              "자유 이름 타깃이 있다. fbos[].name 과의 문자열 일치만이 유일한 규약이다",
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("effect.pass.bind", {
        "bind 항목 키": {"번들최상위": freq(e_top["bindKeys"]), "코퍼스": freq(e_cor["bindKeys"])},
        "source 종류 전수": {"번들최상위": freq(e_top["bindClass"]), "번들preview": freq(e_prev["bindClass"]),
                       "코퍼스": freq(e_cor["bindClass"])},
        "index 분포": {"번들최상위": freq(e_top["bindIndex"]), "코퍼스": freq(e_cor["bindIndex"])},
        "코퍼스 이름 전수(uniq %d)" % len(e_cor["bindName"]): freq(e_cor["bindName"]),
        "번들최상위 이름 전수": freq(e_top["bindName"]),
        "규약": '"previous" = 이펙트 입력(레이어 베이스 또는 이전 이펙트 출력). 그 외 = fbos[] 이름. '
              "index = 셰이더 텍스처 슬롯 번호",
        "함정": '"prev" 축약형이 딱 1개 파일에 있다 — effects/blur/preview/effects/blur/effect.json 이 '
              '같은 자리에 "prev" 를 쓴다(최상위 effects/blur/effect.json 은 "previous"). '
              "번들 최상위 0건 / 코퍼스 0건 — 별칭인지 WE 도 못 읽는 오타인지는 미확인",
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("effect.pass.command", {
        "값": {"번들최상위": freq(e_top["command"]), "번들preview": freq(e_prev["command"]),
             "코퍼스": freq(e_cor["command"])},
        "형식": "<command> (source=<유무>, target=<유무>)",
        "copy": "source fbo → target fbo 복사(셰이더 없음). 실물 motionblur 의 프레임 간 누적 버퍼 지속",
        "swap": "source/target fbo 포인터 교환(드로우 없음). 실물 fluidsimulation velocity/dye 더블버퍼",
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("effect.pass.compose.occurrence", {
        "타입": "bool",
        "관측된 값": {"번들최상위": freq(e_top["compose"]), "번들preview": freq(e_prev["compose"]),
                 "코퍼스": freq(e_cor["compose"])},
        "실물": e_top["composeSites"] + e_cor["composeSites"][:3],
        "note": "항상 true. false 는 관측되지 않았다",
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("effect.pass.compose.semantics", {
        "후보1": "이 패스를 '배경 합성' 패스로 표시 — 이펙트 출력이 아니라 씬 배경(_rt_FullFrameBuffer)을 "
               "먼저 확보해 두는 준비 패스",
        "후보2": "이 패스의 출력을 이펙트 체인의 누적(compose) 대상으로 삼는다",
        "근거상황": "witness 2종뿐이고 둘의 머티리얼이 다르다 — refraction 은 util/effectcomposebackground "
                "(textures[0]=null, [1]=_rt_FullFrameBuffer), 워크샵 blurprecise 는 blur_precise_gaussian_x. "
                "머티리얼 공통점이 없어 의미를 좁힐 수 없다",
        "확정된 것": "키 존재·타입·출현 위치뿐(effect.pass.compose.occurrence)",
    }, "추정", [specfmt.ev("asset", ASSETS.replace(os.sep, "/") + "/effects/refraction/effect.json"),
                specfmt.ev("corpus", "2802243144/effects/blurprecise/effect.json")]))

    add(specfmt.entry("effect.fbos.keys", {
        "번들최상위": freq(e_top["fboKeys"]), "번들preview": freq(e_prev["fboKeys"]),
        "코퍼스": freq(e_cor["fboKeys"]),
        "필수": ["name", "format"],
        "크기 키 조합(전수)": {"번들최상위": freq(e_top["fboSizeShape"]),
                       "번들preview": freq(e_prev["fboSizeShape"]),
                       "코퍼스": freq(e_cor["fboSizeShape"])},
        "크기 결정": "scale(=dst 나눗수) | fit(정사각 절대 픽셀) | width+height(절대 픽셀) | "
                 "아무것도 없음. 넷 중 하나이고 조합은 관측되지 않았다(scale 과 fit 을 함께 쓴 fbo 0건)",
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    nosize = (e_top["fboSizeShape"]["(크기 키 없음)"], e_prev["fboSizeShape"]["(크기 키 없음)"],
              e_cor["fboSizeShape"]["(크기 키 없음)"])
    add(specfmt.entry("effect.fbos.missingSizeKey", {
        "도수": {"번들최상위": nosize[0], "번들preview": nosize[1], "코퍼스": nosize[2]},
        "비율": "코퍼스 fbo %d개 중 %d개(%.0f%%)가 크기 키를 하나도 갖지 않는다"
              % (sum(e_cor["fboSizeShape"].values()), nosize[2],
                 100.0 * nosize[2] / max(1, sum(e_cor["fboSizeShape"].values()))),
        "실물": e_top["fboNoSize"] + e_cor["fboNoSize"][:3],
        "공통점": '관측된 무크기 fbo 는 전부 blurprecise 계열의 {"name":"_rt_FullCompoBuffer1",'
               '"format":"rgba_backbuffer"} 다 — 이름·포맷까지 동일하다',
        "경고": "크기 키를 필수로 보고 파싱하면 이 96건이 전부 '형식 오류'가 된다. 선택 키다",
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("effect.fbos.missingSizeDefault", {
        "질문": "크기 키가 없는 fbo 의 실제 해상도는 무엇인가",
        "Waple 현행": "EffectManifest.swift:66 이 safeInt(f[\"scale\"]) ?? 1 → dst 전체 해상도",
        "그럴듯한 이유": '이름이 _rt_FullCompoBuffer1("Full")이고 포맷이 rgba_backbuffer 다 — 풀해상도 의도로 읽힌다',
        "확정 못 한 것": "WE 가 정말 1(풀해상도)로 기본값을 잡는지. 에셋만으로는 판별 불가 — "
                    "wallpaper64.exe 의 fbo 생성 경로를 디컴파일해야 확정된다",
    }, "추정", [specfmt.ev("asset", ASSETS.replace(os.sep, "/") + "/effects/blurprecise/effect.json"),
                specfmt.ev("file", "Sources/WapleCore/EffectManifest.swift:66")]))

    add(specfmt.entry("effect.fbos.scale", {
        "번들최상위": freq(e_top["fboScale"]), "번들preview": freq(e_prev["fboScale"]),
        "코퍼스": freq(e_cor["fboScale"]),
        "의미": "dst 해상도 나눗수(4 = 1/4). fit/width/height 가 있으면 scale 은 없다",
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("effect.fbos.format", {
        "번들최상위": freq(e_top["fboFormat"]), "번들preview": freq(e_prev["fboFormat"]),
        "코퍼스": freq(e_cor["fboFormat"]),
        "전수(합집합)": sorted(set(list(e_top["fboFormat"]) + list(e_prev["fboFormat"]) + list(e_cor["fboFormat"]))),
        "해석": {
            "rgba_backbuffer": "(추론) 백버퍼와 동일 포맷. 이름 규칙에서 읽은 것이지 측정된 것이 아니다",
            "rgba8888": "8비트 UNORM 4채널",
            "r8": "8비트 UNORM 1채널",
            "rg88": "8비트 UNORM 2채널",
            "r16f": "half float 1채널",
            "rg1616f": "half float 2채널",
            "rgb161616f": "half float 3채널",
        },
        "note": "해석 열은 이름 규칙에서 읽은 것이다 — 채널수·비트폭은 이름이 직접 말하지만 "
                "float/UNORM 구분은 f 접미 관례에 의존한다",
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("effect.fbos.otherKeys", {
        "번들최상위": {k: freq(v) for k, v in sorted(e_top["fboMisc"].items())},
        "번들preview": {k: freq(v) for k, v in sorted(e_prev["fboMisc"].items())},
        "코퍼스": {k: freq(v) for k, v in sorted(e_cor["fboMisc"].items())},
        "실물": [
            '{"name":"_rt_SmokeVelocity1","fit":256,"format":"rg1616f","clear":"0 0 0 0","unique":true}',
            '{"name":"_rt_GlitterTiles","width":256,"height":256,"format":"r8","uvs":"repeat"}',
            '{"name":"_rt_FullCompoBuffer1","scale":1,"format":"rgba_backbuffer","unique":true}',
        ],
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    add(specfmt.entry("effect.conditions", {
        "출현 위치·도수": {"번들최상위": freq(e_top["conditions"]), "번들preview": freq(e_prev["conditions"]),
                    "코퍼스": freq(e_cor["conditions"])},
        "관측된 형태": e_top["condSites"] + e_prev["condSites"][:2],
        "형태1": '리스트-of-딕트 {콤보이름: 정수}: [{"LIGHTING": 1}], [{"RENDERING": 3}] — '
              "pass.conditions / bind[].conditions / fbos[].conditions 세 자리 모두 이 형태다",
        "형태2": '딕트-of-비교: {"POINTEMITTER": {"op": "ge", "value": 1}} — gizmos[].condition(단수형, 별개 키)',
        "출처": "세 자리 전부 effects/fluidsimulation/effect.json 단 하나에서 나온다. 표본이 1개다",
    }, "확정", [asset_ev, script_ev]))

    add(specfmt.entry("effect.conditions.semantics", {
        "읽는 방식(추정)": "콤보 값에 대한 조건 — 만족하지 않으면 그 fbo/bind/pass 를 생성·실행하지 않는다",
        "미확인": "op 의 전수(ge 만 관측), 다중 조건의 AND/OR, 콤보 값의 출처(머티리얼 combos vs 씬 오버라이드)",
    }, "추정", [specfmt.ev("asset", ASSETS.replace(os.sep, "/") + "/effects/fluidsimulation/effect.json",
                          "fbos[].conditions = [{\"LIGHTING\":1}]")]))

    add(specfmt.entry("effect.functions", {
        "도수": {"번들최상위": e_top["top"]["functions"], "코퍼스": e_cor["top"]["functions"]},
        "실물": e_top["functions"],
        "형태": '{ <함수명>: {"action": "clear", "fbos": [<fbo 이름>...] } }',
        "note": "번들 fluidsimulation 단 1건. 사용자 상호작용(리셋 버튼 등)으로 호출되는 것으로 보이나 "
                "호출 경로는 미확인",
    }, "확정", [specfmt.ev("asset", ASSETS.replace(os.sep, "/") + "/effects/fluidsimulation/effect.json"),
                corpus_ev, script_ev]))

    # ---- 코퍼스 vs 번들 -----------------------------------------------------
    add(specfmt.entry("material.corpusVsBundledSchema", {
        "결론": "같은 스키마다. 워크샵 pkg 의 material/effect JSON 은 번들 에셋과 키·값 도메인이 동일하다",
        "차이1": "JSON 방언 — pkg 안 JSON 엔트리는 전건 엄격 JSON(%d/%d, material/effect 외 포함), "
                 "번들 원본 27건에는 주석·트레일링 콤마가 있다. resourcecompiler 가 패키징 시 정규화하는 것으로 보인다"
                 % (audit["parse.strict"], audit["parse.strict"] + audit["parse.lenient"]),
        "차이2": "코퍼스에만 있는 키: usertextures(%d), editable(%d). 번들에만 있는 키: usershadervalues(1), "
               "functions(1), fbos.clear, fbos.conditions, bind.conditions, pass.conditions, command:swap"
               % (m_cor["passKeys"]["usertextures"], e_cor["top"]["editable"]),
        "차이3": "코퍼스에만 있는 blending 값: alphatocoverage(%d). 코퍼스에만 있는 fbo format: rg88, rgb161616f"
               % m_cor["domain"]["blending"]["alphatocoverage"],
        "차이4": "코퍼스 target/bind 이름에 자유 이름(_rt_ 아님)이 흔하다 — 번들 최상위는 전부 _rt_ 접두",
        "차이5": "코퍼스 shader 값에 workshop/<id>/... 접두가 있다(이펙트 의존성 동봉)",
    }, "확정", [asset_ev, corpus_ev, script_ev]))

    # ---- materials/util ----------------------------------------------------
    add(specfmt.entry("material.util.fileBreakdown", {
        "총 파일": util_files,
        "확장자별": util_ext,
        "머티리얼 JSON": len(catalog),
        "note": "'util 88개' 는 파일 수다. 그중 머티리얼 JSON 은 62개이고 나머지는 공유 텍스처"
                "(black/white/noise/clouds_256/perlin_256/uniform_256/flatnormal/fur/noflow + "
                "webthumbnailfallback)의 .png/.tex/.tex-json 이다",
    }, "확정", [specfmt.ev("asset", ASSETS.replace(os.sep, "/") + "/materials/util"), script_ev]))

    add(specfmt.entry("material.util.catalog", catalog, "확정",
                      [specfmt.ev("asset", ASSETS.replace(os.sep, "/") + "/materials/util/*.json"),
                       specfmt.ev("binary", "wallpaper64.exe 안 'util/<name>' 리터럴 문자열 존재 여부"),
                       corpus_ev, script_ev]))

    add(specfmt.entry("material.util.roles", {
        nm: UTIL_ROLES.get(nm, "(미상)") for nm in sorted(catalog)
    }, "보고", [specfmt.ev("recon", ASSETS.replace(os.sep, "/") + "/materials/util/*.json 의 shader·textures·combos",
                          "역할 문구는 그 측정치로부터의 해석이다"),
              specfmt.ev("recon", "렌더러 호출 경로(wallpaper64.exe)로는 검증되지 않았다")]))

    add(specfmt.entry("material.util.mostUsed", {
        "코퍼스 pkg 참조 도수(0 제외)": {nm: catalog[nm]["corpusPkgRefs"]
                              for nm in sorted(catalog, key=lambda n: (-catalog[n]["corpusPkgRefs"], n))
                              if catalog[nm]["corpusPkgRefs"] > 0},
        "코퍼스 참조 0인 util 머티리얼 수": sum(1 for n in catalog if catalog[n]["corpusPkgRefs"] == 0),
        "note": "참조 도수는 pkg 단위다(한 pkg 안 중복은 1로 센다). 0 인 것 대부분은 에디터/디버그/HDR 파이프라인 "
                "전용이라 씬 저작물에 이름이 안 남는다 — 미사용이라는 뜻이 아니다. "
                "wallpaper64.exe 문자열 유무(catalog.inWallpaper64Exe)가 보완 지표다",
    }, "확정", [corpus_ev, script_ev]))

    # ---- Waple 대조 --------------------------------------------------------
    add(specfmt.entry("waple.keyLiteralCoverage", {
        "설명": 'Sources/**/*.swift 안에 각 스키마 키가 따옴표 리터럴("<key>")로 등장하는지. '
              "false = 그 키를 읽는 코드가 아예 없다(미소비 확정). true 는 존재만 보증하고 정확성은 보증하지 않는다",
        "결과": {k: coverage[k] for k in COVERAGE_KEYS},
        "미등장": sorted(k for k, v in coverage.items() if not v),
    }, "확정", [specfmt.ev("file", "Sources/**/*.swift"), script_ev]))

    add(specfmt.entry("waple.gap.fboFormatDropped", {
        "정본": "fbos[].format 은 필수 키다(번들·코퍼스 전건 존재). 7종 — %s"
              % ", ".join(sorted(set(list(e_top["fboFormat"]) + list(e_cor["fboFormat"])))),
        "Waple": "EffectManifest.FBO 에 format 필드가 없다. FBOSpec 은 {scale, fixedWidth, fixedHeight} 뿐이고 "
                 "SceneRendererFrameEncoder 가 pooledOffscreen → makeOffscreen 으로 전부 .rgba8Unorm 으로 만든다",
        "영향(확정)": "half-float 포맷(r16f/rg1616f/rgb161616f)이 8비트 UNORM 으로 붕괴한다 — [0,1] 클램프 + "
                  "정밀도 손실. fluidsimulation 의 velocity(rg1616f)·pressure/divergence/curl(r16f)은 "
                  "부호·범위 초과 값을 담아야 하므로 시뮬레이션이 성립하지 않는다. "
                  "포맷 이름의 f 접미가 float 을 뜻한다는 관례에만 의존한다",
        "영향(추정)": "rgba_backbuffer 를 '백버퍼와 동일 포맷'으로 읽으면 HDR 씬에서 rgba16Float 를 따라야 하는데 "
                  "고정 rgba8Unorm 이라 이펙트 체인이 HDR 을 잘라낸다. 다만 rgba_backbuffer 의 의미 자체가 "
                  "이름에서 추론한 것이라 이 절은 추정이다",
        "위치": "Sources/WapleCore/EffectManifest.swift:25-39, "
              "Sources/WapleRender/SceneRendererResources.swift:57,619-621,1422-1425, "
              "Sources/WapleRender/SceneRendererFrameEncoder.swift:1847-1853",
    }, "확정", [asset_ev, corpus_ev,
                specfmt.ev("file", "Sources/WapleRender/SceneRendererResources.swift:1422",
                           "makeOffscreen: pixelFormat: .rgba8Unorm 고정"), script_ev]))

    add(specfmt.entry("waple.gap.fboClearAndUnique", {
        "정본": 'fbos[].clear("0 0 0 0", 번들 12건) 과 fbos[].unique(true, 번들 %d건 / 코퍼스 %d건)'
              % (e_top["fboMisc"]["unique"].get("true", 0) + e_prev["fboMisc"]["unique"].get("true", 0),
                 e_cor["fboMisc"]["unique"].get("true", 0)),
        "Waple": '"clear"/"unique" 리터럴이 Sources 어디에도 없다. FBO 는 pooledOffscreen 의 (w,h) 키 풀에서 '
                 "재사용되고 매 패스 loadAction=.clear 로 시작한다",
        "영향(추정)": "unique 는 '이 fbo 를 공유 풀에서 빼라'(=프레임 간 내용 보존)로 읽힌다. Waple 의 풀은 "
                  "같은 크기 요청 순서가 프레임마다 같으면 우연히 같은 텍스처를 돌려주지만 보장이 아니다. "
                  "motionblur 누적 버퍼·fluidsimulation 더블버퍼가 이 우연에 의존한다",
        "확정된 것": "키가 존재한다는 것과 Waple 이 그 키를 읽지 않는다는 것",
    }, "확정", [asset_ev, corpus_ev, specfmt.ev("file", "Sources/WapleRender/SceneRendererFrameEncoder.swift:1847"),
                script_ev]))

    add(specfmt.entry("waple.gap.strictJSON", {
        "정본": "WE 의 effect.json 은 // 주석과 트레일링 콤마를 쓴다",
        "Waple": "EffectManifest.parse 가 JSONSerialization(엄격)을 쓴다 → 파싱 실패 시 nil → "
                 "loadEffectManifest 가 단일 무-타깃 패스로 폴백해 멀티패스 구조가 통째로 사라진다",
        "실제 영향 범위": {
            "번들 최상위 effect.json 중 엄격 실패": sorted(
                x["path"] for x in strict_fail if not is_preview(x["path"])),
            "코퍼스 pkg 안": 0,
            "코퍼스 씬이 pkg 미동봉 effect.json 을 참조하는 건수": 0,
        },
        "note": "코퍼스 162씬은 참조하는 effect.json 을 전건 pkg 에 동봉한다. 따라서 이 결함은 지금 코퍼스에서는 "
              "발현하지 않는다 — 베이스 에셋 폴백 경로(BaseAssetsSettings)로만 도달하는 잠재 결함이다",
        "위치": "Sources/WapleCore/EffectManifest.swift:47",
    }, "확정", [asset_ev, corpus_ev,
                specfmt.ev("file", "Sources/WapleCore/EffectManifest.swift:47"), script_ev]))

    add(specfmt.entry("waple.gap.bindPrevAlias", {
        "정본": '"prev" 가 bind.name 자리에 쓰인 파일이 1개 있다 — '
              "effects/blur/preview/effects/blur/effect.json (번들 최상위 %d건 / preview %d건 / 코퍼스 %d건)"
              % (e_top["bindClass"].get("prev(축약)", 0), e_prev["bindClass"].get("prev(축약)", 0),
                 e_cor["bindClass"].get("prev(축약)", 0)),
        "Waple": 'SceneRendererResources.swift:754 이 b.name == "previous" 정확 일치만 본다. '
                 '"prev" 는 fboIndex 조회로 떨어지고 미해석 → 그 슬롯이 이펙트 입력에 연결되지 않는다',
        "우선순위": "낮다. preview 트리 1파일뿐이고 코퍼스 참조 0. 별칭 지원 여부 자체가 미확인이므로 "
                "지금 구현하면 근거 없는 관대함이 된다 — 기록만 남긴다",
        "위치": "Sources/WapleRender/SceneRendererResources.swift:754",
    }, "확정", [asset_ev, corpus_ev,
                specfmt.ev("file", "Sources/WapleRender/SceneRendererResources.swift:754"), script_ev]))

    add(specfmt.entry("waple.gap.cullmodeInMaterialPass", {
        "정본": "material passes[0].cullmode 는 코퍼스 5401건에 존재하고 그중 %d건이 normal(백페이스 컬 켬)이다"
              % m_cor["domain"]["cullmode"]["normal"],
        "Waple": "SceneDocument.parseMaterialPassProperties(:2324-2422)가 blending/depthtest/depthwrite/"
                 "alphawriting/combos/constantshadervalues/shader/usershadervalues/textures 를 읽고 "
                 "cullmode 는 읽지 않는다. cullmode 리터럴은 SceneRenderer3D:718 에만 있다(3D 메시 경로)",
        "영향(추정)": "2D 레이어 경로에서 백페이스 컬 지정이 소실된다. 2D 쿼드는 대부분 단면이라 가시적 차이가 "
                  "없을 수 있으나 뒤집힌 트랜스폼(음수 스케일) 레이어에서는 달라진다",
    }, "확정", [corpus_ev, specfmt.ev("file", "Sources/WapleCore/SceneDocument.swift:2324",
                                     "parseMaterialPassProperties — cullmode 미참조"), script_ev]))

    add(specfmt.entry("waple.gap.composeAndConditions", {
        "미소비 렌더 키": [k for k in ("compose", "conditions", "functions") if not coverage[k]],
        "정본 도수": {
            "pass.compose": e_top["passKeys"]["compose"] + e_cor["passKeys"]["compose"],
            "conditions(fbo/bind/pass 합)": sum(e_top["conditions"].values()) + sum(e_cor["conditions"].values()),
            "functions": e_top["top"]["functions"] + e_cor["top"]["functions"],
        },
        "note": "의미가 미확정이라 지금 구현할 수 없다. 다만 '읽지 않는다'는 사실은 확정이고, "
              "conditions 를 무시하면 조건부 fbo 가 항상 생성돼 콤보 off 상태에서 낭비가 생긴다",
        "갭 아님": "editable / performance / replacementkey 도 Sources 에 없지만 이건 에디터 메타데이터라 "
                "렌더에 영향이 없다 — 미소비가 정상이다",
    }, "확정", [asset_ev, corpus_ev, specfmt.ev("file", "Sources/**/*.swift"), script_ev]))

    add(specfmt.entry("waple.gap.comboCaseFolding", {
        "정본": "콤보 키는 대소문자가 혼용된다 — 코퍼스에 VERSION(%d)/version(%d), SPRITESHEET(%d)/spritesheet(%d) 가 공존한다"
              % (m_cor["combos"]["VERSION"], m_cor["combos"]["version"],
                 m_cor["combos"]["SPRITESHEET"], m_cor["combos"]["spritesheet"]),
        "Waple 이 접는 것": "SceneDocument.swift:2336-2337 이 spritesheet 와 lighting 딱 둘만 lowercased() 비교한다",
        "Waple 이 안 접는 것": [
            "2356-2358 materialCombos[k] = i — 원문 대소문자를 그대로 보존해 하류 셰이더 콤보 해석에 넘긴다. "
            "VERSION 과 version 이 서로 다른 콤보 이름으로 도착한다",
            '2410 (p0["combos"])?["REFRACT"] — 정확 대소문자 + NSNumber 캐스트 + == 1. '
            "refract(소문자)나 REFRACT:2 는 false 로 읽힌다",
        ],
        "영향": "콤보가 매치되지 않으면 셰이더 분기가 기본값으로 컴파일된다 — 조용히 다른 그림이 나온다",
        "위치": "Sources/WapleCore/SceneDocument.swift:2336-2337, 2356-2358, 2410",
    }, "확정", [corpus_ev, specfmt.ev("file", "Sources/WapleCore/SceneDocument.swift:2356"), script_ev]))

    add(specfmt.entry("waple.ok.handledKeys", {
        "확인": "아래는 Waple 이 이미 읽는다 — 갭 표와 구분하기 위해 명시한다",
        "material": {
            "blending(alphatocoverage 포함)": "SceneRenderer3D.swift:721",
            "constantshadervalues 의 <str> 공백벡터": "SceneDocument.swift:2367 floatList",
            "constantshadervalues 의 {script,scriptproperties,value}": "SceneDocument.swift:2286 scriptedConstant",
            "usershadervalues": "SceneDocument.swift:2387 (키=유저프로퍼티, 값=셰이더 토큰)",
            "usertextures(문자열 | {name,type})": "SceneDocument.swift:1925, 2180",
            "combos 대소문자 무시 — 단 2키(spritesheet/lighting)만": "SceneDocument.swift:2336-2337. "
                "일반 콤보 폴딩은 갭이다(waple.gap.comboCaseFolding 참조)",
        },
        "effect": {
            "passes/material/shader/target/bind{name,index}": "EffectManifest.swift:46-62",
            "command copy/swap + source": "SceneRendererResources.swift:570-583",
            "fbos scale/fit/width/height/uvs": "EffectManifest.swift:63-79",
        },
    }, "확정", [specfmt.ev("file", "Sources/WapleCore/SceneDocument.swift"),
                specfmt.ev("file", "Sources/WapleCore/EffectManifest.swift"), script_ev]))

    specfmt.dump(specfmt.doc("scripts/spec/measure_material_schema.py", E),
                 os.path.join("spec", "assets", "material-schema.json"))

    print("항목 %d개" % len(E))
    print("  번들 effect 최상위 %d / preview %d" % (e_top["files"], e_prev["files"]))
    print("  번들 material materials/ %d / effects 하위 %d" % (m_top["files"], m_eff["files"]))
    print("  코퍼스 effect %d / material %d (pkg %d)" % (e_cor["files"], m_cor["files"], audit["pkg"]))
    print("  자기검증: effects/ JSON %d == effect %d ? %s / materials/ JSON %d == material %d ? %s"
          % (audit["jsonUnder.effects"], e_cor["files"], audit["jsonUnder.effects"] == e_cor["files"],
             audit["jsonUnder.materials"], m_cor["files"],
             audit["jsonUnder.materials"] == m_cor["files"]))
    print("  엄격 JSON 실패 %d건, util JSON %d개" % (len(strict_fail), len(catalog)))
    print("  미소비 키: %s" % sorted(k for k, v in coverage.items() if not v))


if __name__ == "__main__":
    main()
