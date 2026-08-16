#!/usr/bin/env python3
"""A(기준선) vs B(이탈 제거) 픽셀 통계.

WapleCompat --compare 를 쓰지 않는다. 그 게이트의 strict 임계가 절대 단위
(평균 절대차 1.5/255)라 어두운 씬에서 무력하기 때문이다 — 실측으로 전면 검정으로
바꿔도 통과하는 씬이 3종 있고, D1/D2 대상 4종 중 2종이 거기 들어간다.

여기서는 썸네일을 직접 읽어 절대 지표와 **상대 지표(대비 정규화)** 를 함께 낸다.
상대 지표가 있어야 어두운 씬의 변화가 보인다.

[정정 2026-08-16] 위 첫 문단의 근거는 닫혔다. 6e2e713 이 --compare 에 같은 종류의 상대
지표와 structureLoss 를 넣었고, 현행 기준선 170종 전수 실측으로 전면 검정 통과 씬은 0종이다
(spec/golden/gate-analysis.json → oracle.gate.blindScenes). 그래도 이 스크립트를 계속 쓰는
이유는 **축이 다르기 때문**이다 — --compare 는 "통과/실패" 를 내지만 여기서 필요한 것은
씬별로 얼마나·어느 방향으로 바뀌었는가의 통계표다. 판정이 아니라 관측이 목적이다.
"""
import json
import os
import sys

REPO = os.environ.get("WAPLE_REPO") or os.path.abspath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
A_DIR = os.environ.get("WAPLE_A") or os.path.join(
    REPO, "spec", "golden", "snapshot", "baseline-81098bb")
B_DIR = os.path.expanduser(
    os.environ.get("WAPLE_B", "~/Downloads/waple-ab/ab-deviations-removed"))

# spec/engine/deviation-reach.json 실측
HDR = {"2802243144", "2899965423", "2902406982", "3147346398", "3264258426",
       "3287715210", "3299228616", "3351163962", "3352517853", "3396722575",
       "3470948192", "3509243656", "3554161528", "3577990983", "3589454154",
       "3662790108"}
D1D2_TARGETS = {"3470948192", "3509243656", "3589454154", "3662790108"}
# spec/golden/gate-analysis.json — 전면 검정도 게이트를 통과하는 씬
BLIND = {"3444535389", "1612750231", "3662790108"}

try:
    from PIL import Image
except ImportError:
    sys.exit("PIL 이 없다: pip3 install pillow")


def load(d, sid):
    p = os.path.join(d, "thumbs", f"{sid}.png")
    if not os.path.exists(p):
        return None
    return Image.open(p).convert("RGB")


def stats(a, b):
    ap, bp = a.load(), b.load()
    w, h = a.size
    n = w * h
    tot = 0
    mx = 0
    over8 = 0
    suma = sumb = 0
    for y in range(h):
        for x in range(w):
            ra, ga, ba = ap[x, y]
            rb, gb, bb = bp[x, y]
            d = max(abs(ra - rb), abs(ga - gb), abs(ba - bb))
            tot += d
            if d > mx:
                mx = d
            if d > 8:
                over8 += 1
            suma += ra + ga + ba
            sumb += rb + gb + bb
    mean = tot / n
    lum_a = suma / (n * 3) / 255.0
    lum_b = sumb / (n * 3) / 255.0
    # 상대 지표: 절대 평균차를 A 의 평균 밝기로 정규화한다.
    # 어두운 씬에서 절대 지표가 못 보는 변화를 드러낸다.
    rel = mean / max(lum_a * 255.0, 1.0)
    return {"mean": mean, "max": mx, "fracOver8": over8 / n,
            "lumaA": lum_a, "lumaB": lum_b, "rel": rel}


def main():
    if not os.path.isdir(os.path.join(A_DIR, "thumbs")):
        sys.exit(f"A 쪽 썸네일 없음: {A_DIR}/thumbs")
    if not os.path.isdir(os.path.join(B_DIR, "thumbs")):
        sys.exit(f"B 쪽 썸네일 없음: {B_DIR}/thumbs")

    ids = sorted(f[:-4] for f in os.listdir(os.path.join(A_DIR, "thumbs"))
                 if f.endswith(".png"))
    rows = []
    for sid in ids:
        a, b = load(A_DIR, sid), load(B_DIR, sid)
        if a is None or b is None:
            continue
        if a.size != b.size:
            print(f"  크기 불일치 {sid}: {a.size} vs {b.size}")
            continue
        s = stats(a, b)
        s["id"] = sid
        rows.append(s)

    changed = [r for r in rows if r["mean"] > 0.01]
    print(f"비교 {len(rows)}종 · 변화 있는 씬 {len(changed)}종\n")

    def show(title, sel, note=""):
        sub = [r for r in rows if r["id"] in sel]
        if not sub:
            return
        print(f"── {title} ({len(sub)}종) {note}")
        print(f"   {'씬':<12} {'평균차':>7} {'최대':>5} {'>8비율':>8} "
              f"{'lumaA':>7} {'lumaB':>7} {'상대':>7}  판정")
        for r in sorted(sub, key=lambda x: -x["mean"]):
            v = "변화" if r["mean"] > 0.01 else "동일"
            flag = " ★사각지대" if r["id"] in BLIND else ""
            print(f"   {r['id']:<12} {r['mean']:7.3f} {r['max']:5d} "
                  f"{r['fracOver8']:8.4f} {r['lumaA']:7.4f} {r['lumaB']:7.4f} "
                  f"{r['rel']:7.4f}  {v}{flag}")
        print()

    show("D1/D2 대상 (HDR ∩ 3D)", D1D2_TARGETS, "← 여기가 바뀌어야 한다")
    show("나머지 HDR (D3 영향권)", HDR - D1D2_TARGETS)

    control = {r["id"] for r in rows} - HDR
    ctrl_changed = [r for r in rows if r["id"] in control and r["mean"] > 0.01]
    print(f"── 대조군: 비-HDR {len(control)}종 ← 여기는 바뀌면 안 된다")
    if ctrl_changed:
        print(f"   !! 비-HDR {len(ctrl_changed)}종이 바뀌었다. 패치가 의도 밖 경로를 건드렸다.")
        for r in sorted(ctrl_changed, key=lambda x: -x["mean"])[:15]:
            print(f"   {r['id']:<12} 평균차 {r['mean']:7.3f} 최대 {r['max']:3d} "
                  f"상대 {r['rel']:7.4f}")
    else:
        print("   전건 동일 — 패치가 HDR 경로에만 닿았다 (기대대로)")
    print()

    print("── 요약")
    hdr_changed = [r for r in rows if r["id"] in HDR and r["mean"] > 0.01]
    print(f"   HDR 씬 {len(HDR)}종 중 변화 {len(hdr_changed)}종")
    print(f"   D1/D2 대상 4종 중 변화 "
          f"{len([r for r in rows if r['id'] in D1D2_TARGETS and r['mean'] > 0.01])}종")
    print(f"   대조군 변화 {len(ctrl_changed)}종 (0이어야 정상)")
    if hdr_changed:
        br = sum(1 for r in hdr_changed if r["lumaB"] > r["lumaA"])
        print(f"   변화 방향: 밝아짐 {br} / 어두워짐 {len(hdr_changed)-br}")

    out = os.path.join(B_DIR, "ab-diff.json")
    with open(out, "w", encoding="utf-8") as fh:
        json.dump({"a": A_DIR, "b": B_DIR, "rows": rows}, fh, indent=1, ensure_ascii=False)
    print(f"\n   상세: {out}")


if __name__ == "__main__":
    main()
