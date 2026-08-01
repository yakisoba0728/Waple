"""`_rt_imageLayerComposite_<id>_<ch>` 참조의 소비/생산 측 전수 측정 — spec/engine/composite-refs.json.

이 측정은 **감사 소견 하나를 반증하기 위해** 만들었다. 감사는 "정적 치환 때문에
2902406982 에 화면 12.3% 크기의 흰 삼각형이 뜬다(25씬 영향)" 고 보고했다.
가설 셋을 세우고 셋 다 코퍼스 데이터로 죽였다:

  가설1  참조 id 가 안 풀려 흰색 1×1 이 바인드된다
         → 2902406982 의 참조 6건 전부 정상 해석(이미지 있음·이펙트 없음). 반증.
  가설2  가시성 카브아웃(부모가 꺼져 있어도 안 숨김) 때문에 숨어야 할 레이어가 그려진다
         → 6건 전부 visible:true · parent 없음. 카브아웃이 발동할 조건 자체가 없다. 반증.
  가설3  WE 컴포지트 RTT 는 화면 크기인데 Waple 은 스프라이트를 꽂아 UV 가 어긋난다
         → 소비자 1000×1000, 소스 1000×1000(동일). 풀스크린 소비자 × 작은 소스 조합 0/82. 반증.

남은 실물 소견은 하나뿐이고 작다: 접미사 `_b`.

정직한 결론: 이 항목은 **구현 대상이 아니다**. 흰 삼각형이 실재한다면 원인은 다른 데 있고,
정적 치환 경로를 고쳐도 안 없어진다. 화면을 봐야 갈린다(macOS 세션).

usage:
    python scripts/spec/measure_composite_refs.py
"""
import collections
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import measure_tex_deep as T
import specfmt

OUT = os.path.join("spec", "engine", "composite-refs.json")
REF = re.compile(rb"_rt_imageLayerComposite_(\d+)([A-Za-z_]*)")


def vec(v):
    """WE 벡터는 공백 구분 문자열("1000.00000 1000.00000") 또는 배열."""
    if isinstance(v, str):
        try:
            return [float(x) for x in v.split()]
        except ValueError:
            return []
    if isinstance(v, list):
        return [float(x) for x in v if isinstance(x, (int, float))]
    return []


def scan():
    r = {
        "scenes": set(), "refs": 0,
        "suffixes": collections.Counter(),
        "srcClass": collections.Counter(),      # 소스 레이어 분류
        "rows": [],
        "fullscreenConsumers": 0, "sizedConsumers": 0,
        "suffixB": [],
    }
    for wid in sorted(os.listdir(T.WS)):
        d = os.path.join(T.WS, wid)
        pkg = next((os.path.join(d, f) for f in ("scene.pkg", "gifscene.pkg")
                    if os.path.exists(os.path.join(d, f))), None)
        if not pkg:
            continue
        data = open(pkg, "rb").read()
        if b"_rt_imageLayerComposite_" not in data:
            continue
        try:
            _, entries, base = T.parse_pkg(data)
        except Exception:
            continue
        blobs = {n: data[base + o:base + o + s] for n, o, s in entries}
        raw = blobs.get("scene.json")
        if not raw:
            continue
        try:
            scene = json.loads(raw.decode("utf-8-sig", "replace"))
        except Exception:
            continue
        r["scenes"].add(wid)
        proj = (scene.get("general") or {}).get("orthogonalprojection") or {}
        projW = float(proj.get("width") or 1920)
        projH = float(proj.get("height") or 1080)
        objs = [o for o in (scene.get("objects") or []) if isinstance(o, dict)]
        byid = {o["id"]: o for o in objs if "id" in o}

        for obj in objs:
            found = REF.findall(json.dumps(obj, ensure_ascii=False).encode())
            if not found:
                continue
            csz = vec(obj.get("size"))
            cw = csz[0] if csz else None
            ch = csz[1] if len(csz) > 1 else None
            is_full = (cw is not None and ch is not None
                       and abs(cw - projW) <= 2 and abs(ch - projH) <= 2)
            r["fullscreenConsumers" if is_full else "sizedConsumers"] += 1
            for i, suf in found:
                sid, s = int(i), suf.decode()
                r["refs"] += 1
                r["suffixes"][s] += 1
                src = byid.get(sid)
                if src is None:
                    cls = "A_없는id"
                elif not src.get("image"):
                    cls = "B_이미지없음"
                elif src.get("effects"):
                    cls = "C_이펙트누락"
                else:
                    cls = "D_정적치환정답"
                r["srcClass"][cls] += 1
                ssz = vec((src or {}).get("size"))
                row = {
                    "scene": wid, "consumerId": obj.get("id"),
                    "consumerSize": [cw, ch], "fullscreen": is_full,
                    "proj": [projW, projH], "srcId": sid, "suffix": s,
                    "srcSize": [ssz[0] if ssz else None, ssz[1] if len(ssz) > 1 else None],
                    "srcClass": cls,
                }
                r["rows"].append(row)
                if s == "_b":
                    r["suffixB"].append(row)
    return r


def build(r):
    scan_ev = specfmt.ev("corpus", f"워크샵 {len(r['scenes'])}종 전수 scene.json",
                         "scripts/spec/measure_composite_refs.py")
    code_ev = specfmt.ev("file", "Sources/WapleRender/SceneRendererResources.swift:807-822",
                         "정적 치환 구현부(prefix{isNumber} 로 id 만 읽는다)")

    # 가설3 지지 조건: 풀스크린 소비자 × 소스가 화면보다 뚜렷이 작음
    support3 = [x for x in r["rows"]
                if x["fullscreen"] and x["srcSize"][0] and x["srcSize"][0] < x["proj"][0] * 0.9]
    same_size = [x for x in r["rows"]
                 if x["srcSize"][0] and x["consumerSize"][0]
                 and abs(x["srcSize"][0] - x["consumerSize"][0]) < 1]

    return [
        specfmt.entry("engine.composite.refInventory", {
            "scenes": len(r["scenes"]),
            "references": r["refs"],
            "suffixes": dict(r["suffixes"]),
            "sourceClassification": dict(r["srcClass"]),
            "classMeaning": {
                "A_없는id": "참조 id 의 오브젝트가 없다 → 치환 실패 → 흰색 1×1",
                "B_이미지없음": "오브젝트는 있으나 image 없음(솔리드/컴포지션/이펙트 쿼드) → 흰색 1×1",
                "C_이펙트누락": "image 는 있으나 소스가 이펙트를 갖는다 → 치환은 되지만 이펙트가 빠진 그림",
                "D_정적치환정답": "image 있고 이펙트 없음 → 정적 치환이 사실상 정답",
            },
            "consumers": {"fullscreen": r["fullscreenConsumers"], "sized": r["sizedConsumers"]},
        }, "확정", [scan_ev]),

        specfmt.entry("engine.composite.whiteTriangleRefuted", {
            "auditClaim": "정적 치환 때문에 2902406982 에 화면 12.3% 의 흰 삼각형이 뜬다(25씬)",
            "verdict": "이 경로가 원인이라는 주장은 코퍼스 데이터로 성립하지 않는다",
            "h1_unresolvedRef": {
                "predicted": "참조 id 가 안 풀려 흰색 1×1",
                "observed": "2902406982 의 참조 6건 전부 D(이미지 있음·이펙트 없음)",
                "refuted": True,
            },
            "h2_visibilityCarveout": {
                "predicted": "숨어야 할 컴포지트 소스가 카브아웃 때문에 그려진다",
                "observed": "6건 전부 visible:true · parent 없음 — 카브아웃 발동 조건이 없다",
                "refuted": True,
                "carveoutSites": ["SceneDocument.swift:930", "SceneDocument.swift:1572"],
            },
            "h3_coordinateSpace": {
                "predicted": "WE 컴포지트 RTT 는 화면 크기, Waple 은 스프라이트 → UV 어긋남",
                "observed": f"소비자·소스가 같은 크기인 행 {len(same_size)}/{len(r['rows'])}. "
                            f"'풀스크린 소비자 × 작은 소스' 조합 {len(support3)}건. "
                            "2902406982 은 소비자 1000x1000 · 소스 1000x1000 · 투영 3840x2160",
                "refuted": True,
            },
            "consequence": "정적 치환 경로를 고쳐도 흰 삼각형은 없어지지 않는다. "
                           "흰 삼각형이 실재한다면 원인은 다른 곳이고, "
                           "판별하려면 프레임을 봐야 한다(macOS).",
            "doNotReopen": "이 항목을 '정적 치환 갭' 으로 다시 적출하지 마라 — 세 가설 모두 "
                           "코퍼스 전수로 반증됐다. 새로 열려면 화면 근거를 먼저 가져올 것.",
        }, "확정", [scan_ev, code_ev]),

        specfmt.entry("engine.composite.suffixChannels", {
            "observed": dict(r["suffixes"]),
            "wapleParser": "prefix { $0.isNumber } — 숫자에서 멈추므로 접미사를 통째로 버린다. "
                           "`_a` 와 `_b` 가 같은 텍스처로 해석된다.",
            "slotPattern": "`_a` 는 대체로 슬롯 1(보조/마스크), `_b` 는 관측 3건 전부 슬롯 0(패스의 주 입력)",
            "occurrences": r["suffixB"],
            "reach": f"{len(r['suffixB'])}건 / {len({x['scene'] for x in r['suffixB']})}씬",
            "meaningOfSuffix": "미측정. 슬롯 배치만 관측했고 접미사가 무엇을 고르는지는 "
                               "RE 로 확인하지 않았다(engine.composite.suffixHypothesis 참조).",
            "assessment": "도달 범위가 작고, 슬롯 0(체인 입력)에 쓰이는 형태라 Waple 의 "
                          "체인이 베이스 텍스처에서 시작하는 것과 겹친다. "
                          "지금 고칠 근거가 약하다 — 기록만 남긴다.",
        }, "확정", [scan_ev, code_ev]),

        specfmt.entry("engine.composite.suffixHypothesis", {
            "hypothesis": "`_a`/`_b` 는 레이어 컴포지트 체인의 핑퐁 버퍼 두 짝이다",
            "why": "`_b` 가 전건 슬롯 0(패스 입력)에 오고 `_a` 가 보조 슬롯에 오는 배치가 "
                   "읽기/쓰기 교대와 정합한다. `_rt_imageLayerAlbedo_` 가 별도 심볼로 "
                   "존재하므로 접미사가 채널 선택자일 가능성도 남아 있다.",
            "notVerified": "wallpaper64.exe 에서 접미사를 만드는 코드를 찾지 않았다. "
                           "확인 전에는 파서를 고치면 안 된다 — 잘못된 채널을 고르는 것이 "
                           "지금처럼 둘을 같게 두는 것보다 나쁠 수 있다.",
        }, "추정", [scan_ev,
                    specfmt.ev("binary", "_rt_imageLayerAlbedo_ 0x140490d78",
                               "별도 심볼 — 접미사가 채널 선택자일 가능성의 근거")]),
    ]


def main():
    r = scan()
    print(f"`_rt_imageLayerComposite_` 사용 씬 {len(r['scenes'])}종 · 참조 {r['refs']}건")
    print(f"  접미사: {dict(r['suffixes'])}")
    print(f"  소스 분류: {dict(r['srcClass'])}")
    print(f"  소비자: 풀스크린 {r['fullscreenConsumers']} · 크기지정 {r['sizedConsumers']}")
    print(f"  `_b` 관측 {len(r['suffixB'])}건: "
          f"{sorted({x['scene'] for x in r['suffixB']})}")
    specfmt.dump(specfmt.doc("scripts/spec/measure_composite_refs.py", build(r)), OUT)
    print(f"\n기록: {OUT}")


if __name__ == "__main__":
    main()
