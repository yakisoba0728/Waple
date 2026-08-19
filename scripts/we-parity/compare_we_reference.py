#!/usr/bin/env python3
"""WE 실기 스크린샷 대 Waple 골든 썸네일 정량 대조.

이 리포의 골든 게이트는 **Waple 대 Waple** 만 잰다(과거 캡처 vs 지금 빌드). 즉 "골든 통과 +
WE 와 완전히 다름" 이 구조적으로 가능하다. 이 스크립트는 그 공백을 메운다 — WE 가 실제로
그린 화면과 우리 캡처가 얼마나 같은지를 숫자로 낸다.

## 왜 상관계수 하나로는 못 읽나

두 이미지는 애초에 같을 수 없다:
  - 해상도·종횡비가 다르다(WE 는 창 캡처, 골든은 256x144 고정)
  - WE 는 라이브 벽시계·라이브 커서, 골든은 t=6 고정·포인터 중앙 핀
  - 캡처 시점의 애니메이션 위상이 다르다

그래서 "r=0.97 이면 좋은가?" 라는 질문에 답할 기준이 필요하다. 이 스크립트는 그 기준을
**데이터에서** 만든다: 같은 씬의 WE 스크린샷이 두 장 있는 경우(01/02), 그 둘 사이의 지표가
곧 **노이즈 바닥**이다. WE 자신도 그만큼은 흔들린다. Waple↔WE 가 그 바닥 근처면 "구별 불가",
바닥보다 뚜렷이 나쁘면 그게 실제 이탈이다.

## 지표

  corr      64x36 셀 평균 휘도의 피어슨 상관 — **구조**가 맞는가(무엇이 어디에 있는가)
  lumaRatio Waple/WE 평균 휘도 — 전체가 밝은가 어두운가
  chanRatio R/G/B 각각의 평균 비 — 색 캐스트
  worstCell 가장 크게 어긋난 셀과 그 좌표 — 어디가 다른가

휘도는 Rec.709(0.2126R + 0.7152G + 0.0722B). 셀 격자는 64x36 — 서브픽셀·리샘플 차이에
둔감하면서 국소 이탈(라이트샤프트 같은)은 살아남는 크기다.

## 한계 (읽는 사람이 반드시 알아야 함)

  - WE 스크린샷의 종횡비가 16:9 가 아니면 중앙 크롭한다. **프레이밍 차이는 corr 을 크게
    끌어내린다** — 씬 ortho 가 16:9 인데 WE 창이 1626x971 이면 WE 샷은 씬 중앙의 94.2% 만
    담는다(유도는 best_aligned_corr 주석). 그래서 `정렬후` 열을 반드시 같이 읽어라.
  - 시계·커서·애니 위상 차이는 노이즈 바닥에 부분적으로만 반영된다(두 WE 캡처가 같은
    세션이면 위상차가 작다).
  - 이건 **파리티 지표이지 게이트가 아니다.** 임계를 정해 CI 에 걸 물건이 아니다.

사용:
    python3 scripts/we-parity/compare_we_reference.py <we-ref-dir> [--baseline <dir>] [--json out.json]
"""

import argparse
import json
import os
import re
import sys

import numpy as np
from PIL import Image

GRID_W, GRID_H = 64, 36
LUMA = np.array([0.2126, 0.7152, 0.0722], dtype=np.float64)


def load_cells(path, grid=(GRID_W, GRID_H)):
    """이미지를 16:9 중앙 크롭 → grid 로 축소 → float RGB 배열(0..255)."""
    img = Image.open(path).convert("RGB")
    w, h = img.size
    target = grid[0] / grid[1]
    if abs(w / h - target) > 1e-3:
        if w / h > target:                      # 너무 넓다 → 좌우 크롭
            nw = int(round(h * target))
            off = (w - nw) // 2
            img = img.crop((off, 0, off + nw, h))
        else:                                   # 너무 높다 → 상하 크롭
            nh = int(round(w / target))
            off = (h - nh) // 2
            img = img.crop((0, off, w, off + nh))
    img = img.resize(grid, Image.LANCZOS)
    return np.asarray(img, dtype=np.float64), (w, h)


def load_raw(path):
    """크롭 없이 RGB 배열로."""
    img = Image.open(path).convert("RGB")
    return img


def best_aligned_corr(we_path, cmp_cells, cmp_path=None):
    """프레이밍 차이를 분리한다.

    WE 창 캡처와 우리 16:9 캡처는 종횡비도 줌도 다르다. 중앙 크롭 하나만 재면 "내용이 다르다" 와
    "잘라낸 자리가 다르다" 가 뒤섞인다. 그래서 WE 원본에서 **여러 크롭 후보**(줌 배율 × 중심
    오프셋)를 떠서 각각 상관을 재고 **최댓값**을 낸다.

    naive corr 은 낮은데 aligned corr 이 높으면 → 내용은 맞고 **프레이밍/줌이 다르다**.
    둘 다 낮으면 → 내용 자체가 다르다. 이 구분이 없으면 어느 쪽인지 말할 수 없다.

    ## 반드시 양방향이어야 한다 (2026-08-16 정정)

    처음엔 WE 쪽만 줌인해 탐색했다. 그래서 "정렬해도 안 오른다 = 내용이 다르다" 는 결론이
    나왔는데 **틀렸다.** 실제 관계가 정반대다 — WE 샷이 우리보다 **좁다**.

    기하: 씬 ortho 가 16:9(1920x1080)인데 WE 창은 1626x971(=1.674). fill 이면 씬 폭
    971x16/9 = 1726.2 를 렌더하고 창은 1626 만 보여준다 → 가로 0.942. 그 뒤 이 스크립트가
    WE 를 다시 16:9 로 크롭하면 세로도 914.6/971 = 0.942. 결과적으로
    **WE 샷 = 씬 중앙의 94.2%, 우리 캡처 = 100%** 다.

    그래서 **대상(우리) 쪽도 크롭 후보에 넣는다.** 한쪽만 줌인하면 실제 관계가 반대일 때
    탐색이 최적점에 닿지 못하고, "내용이 다르다" 로 오독하게 된다.

    과적합 우려: 노이즈 바닥(WE1 vs WE2)도 **같은 자유도로** 탐색한다. 바닥이 안 움직이는데
    대상만 오르면 그건 실제 정렬 이득이다(실측: 바닥 0.997/0.991/0.971 전부 불변).
    """
    img = load_raw(we_path)
    W, H = img.size
    target = GRID_W / GRID_H
    best = (-2.0, None)

    def crops(im):
        """(라벨, 셀배열) 후보 — 전체 + 중앙 z 비율 x 오프셋."""
        w, h = im.size
        out = []
        for z in (1.00, 0.97, 0.942, 0.92, 0.88, 0.84, 0.76, 0.68, 0.60):
            cw = w * z
            ch = cw / target
            if ch > h:
                ch = h * z
                cw = ch * target
            if cw < 32 or ch < 32:
                continue
            for dx in (-0.08, -0.04, 0.0, 0.04, 0.08):
                for dy in (-0.08, -0.04, 0.0, 0.04, 0.08):
                    l0 = w / 2 + dx * w - cw / 2
                    t0 = h / 2 + dy * h - ch / 2
                    if l0 < 0 or t0 < 0 or l0 + cw > w or t0 + ch > h:
                        continue
                    c = im.crop((int(l0), int(t0), int(l0 + cw), int(t0 + ch)))
                    arr = np.asarray(c.resize((GRID_W, GRID_H), Image.LANCZOS), dtype=np.float64)
                    out.append(({"zoom": round(z, 3), "dx": dx, "dy": dy}, arr))
        return out

    lb_full = (cmp_cells @ LUMA).ravel()
    if lb_full.std() < 1e-9:
        return float("nan"), None

    # ① WE 쪽을 좁힌다 (대상은 그대로)
    for par, arr in crops(img):
        la = (arr @ LUMA).ravel()
        if la.std() < 1e-9:
            continue
        c = float(np.corrcoef(la, lb_full)[0, 1])
        if c > best[0]:
            best = (c, {"side": "we", **par})

    # ② 대상 쪽을 좁힌다 (WE 는 중앙 16:9 전체) — 실제로 이쪽이 맞는 방향이었다
    we_full = (np.asarray(_center_169(img).resize((GRID_W, GRID_H), Image.LANCZOS),
                          dtype=np.float64) @ LUMA).ravel()
    if we_full.std() > 1e-9:
        # 대상은 **원본 PNG** 에서 크롭한다 — 셀 격자(64x36)를 확대해 자르면 해상도를 잃는다.
        cmp_img = load_raw(cmp_path) if cmp_path else \
            Image.fromarray(cmp_cells.astype(np.uint8)).resize((512, 288), Image.LANCZOS)
        for par, arr in crops(cmp_img):
            lb = (arr @ LUMA).ravel()
            if lb.std() < 1e-9:
                continue
            c = float(np.corrcoef(we_full, lb)[0, 1])
            if c > best[0]:
                best = (c, {"side": "waple", **par})
    return best[0], best[1]


def _center_169(img):
    w, h = img.size
    t = GRID_W / GRID_H
    if abs(w / h - t) <= 1e-3:
        return img
    if w / h > t:
        nw = int(round(h * t)); off = (w - nw) // 2
        return img.crop((off, 0, off + nw, h))
    nh = int(round(w / t)); off = (h - nh) // 2
    return img.crop((0, off, w, off + nh))


def metrics(a, b):
    """a=기준(WE), b=대상(Waple). 둘 다 (H,W,3) float."""
    la = a @ LUMA
    lb = b @ LUMA
    fa, fb = la.ravel(), lb.ravel()
    if fa.std() < 1e-9 or fb.std() < 1e-9:
        corr = float("nan")                     # 한쪽이 단색이면 상관은 정의되지 않는다
    else:
        corr = float(np.corrcoef(fa, fb)[0, 1])
    diff = np.abs(la - lb)
    idx = int(np.argmax(diff))
    y, x = divmod(idx, GRID_W)
    eps = 1e-6
    return {
        "corr": corr,
        "meanLumaRef": float(la.mean()),
        "meanLumaCmp": float(lb.mean()),
        "lumaRatio": float(lb.mean() / (la.mean() + eps)),
        "meanAbsLumaDiff": float(diff.mean()),
        "chanRatio": [float(b[..., i].mean() / (a[..., i].mean() + eps)) for i in range(3)],
        "worstCell": {"x": x, "y": y, "refLuma": float(la[y, x]), "cmpLuma": float(lb[y, x])},
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("we_dir", help="WE 스크린샷 디렉터리(<name>_<sceneid>_<tag>.png)")
    # [정정 2026-08-19] 기본값이 baseline-7075b74 였는데 그 디렉터리는 HEAD 에 없다
    # (현행은 baseline-6f0bcf0 — spec/golden/snapshot/README.md 최상단). 없는 경로를
    # 기본값으로 두면 스크립트가 오류 없이 **빈 리포트**를 내서, 비교를 돌렸다고
    # 착각하게 된다. 실패보다 나쁜 결과다.
    ap.add_argument("--baseline", default="spec/golden/snapshot/baseline-6f0bcf0/thumbs")
    ap.add_argument("--json", default=None)
    args = ap.parse_args()

    # 씬 id 별로 WE 샷을 모은다.
    shots = {}
    for fn in sorted(os.listdir(args.we_dir)):
        if not fn.lower().endswith(".png"):
            continue
        m = re.search(r"_(\d{9,10})_", fn)
        if not m:
            continue
        shots.setdefault(m.group(1), []).append(os.path.join(args.we_dir, fn))

    if not shots:
        print("WE 스크린샷을 못 찾았다 — 파일명이 <name>_<sceneid>_<tag>.png 인가?", file=sys.stderr)
        return 2

    rows = []
    for sid in sorted(shots):
        golden = os.path.join(args.baseline, f"{sid}.png")
        if not os.path.exists(golden):
            rows.append({"scene": sid, "error": "골든 썸네일 없음", "goldenPath": golden})
            continue
        g, gdim = load_cells(golden)
        refs = [(p, *load_cells(p)) for p in shots[sid]]

        # 노이즈 바닥 — 같은 씬 WE 샷끼리. 한 장뿐이면 산출 불가.
        floor = None
        if len(refs) >= 2:
            floor = metrics(refs[0][1], refs[1][1])

        # 대표 WE 샷(첫 장) 대 골든.
        m = metrics(refs[0][1], g)
        ac, apar = best_aligned_corr(refs[0][0], g, cmp_path=golden)
        m["alignedCorr"] = ac
        m["alignedAt"] = apar
        # 노이즈 바닥도 같은 방식으로 — WE 샷끼리도 창 위치가 흔들릴 수 있다.
        if floor is not None:
            fac, _ = best_aligned_corr(refs[0][0], refs[1][1], cmp_path=refs[1][0])
            floor["alignedCorr"] = fac
        rows.append({
            "scene": sid,
            "weShots": [os.path.basename(p) for p, _, _ in refs],
            "weDim": list(refs[0][2]),
            "goldenDim": list(gdim),
            "waple_vs_we": m,
            "noiseFloor_we_vs_we": floor,
        })

    # 출력
    print(f"{'씬':<12} {'corr':>7} {'정렬후':>7} {'바닥':>7} {'판정':<12} {'휘도비':>7}  R/G/B 비")
    print("-" * 92)
    for r in rows:
        if "error" in r:
            print(f"{r['scene']:<12} {r['error']}")
            continue
        m, f = r["waple_vs_we"], r["noiseFloor_we_vs_we"]
        fc = f"{f['alignedCorr']:.3f}" if f else "  —  "
        base = f["alignedCorr"] if f else None
        a = m["alignedCorr"]
        if base is None:
            verdict = "바닥없음"
        elif a >= base - 0.02:
            verdict = "구별불가"
        elif a >= base - 0.08:
            verdict = "근접"
        elif a - m["corr"] > 0.15:
            verdict = "프레이밍차"
        else:
            verdict = "내용이탈"
        cr = "/".join(f"{c:.2f}" for c in m["chanRatio"])
        print(f"{r['scene']:<12} {m['corr']:>7.3f} {a:>7.3f} {fc:>7} {verdict:<12} "
              f"{m['lumaRatio']:>7.3f}  {cr}")

    print()
    print("corr   = 중앙 16:9 크롭 기준 상관. 정렬후 = 줌·오프셋을 탐색해 얻은 최댓값.")
    print("         정렬후가 corr 보다 크게 높으면 내용은 맞고 **프레이밍/줌이 다르다**는 뜻이다.")
    print("바닥   = 같은 씬 WE 샷 2장 사이의 정렬후 상관 — WE 자신의 흔들림.")
    print("판정  = corr 이 바닥 대비 어디에 있는가. 바닥은 'WE 자신도 이만큼 흔들린다' 는 뜻이다.")
    print("휘도비 = Waple/WE 평균 휘도. 1.0 이 일치, <1 이면 우리가 어둡다.")
    print("주의  = 프레이밍(중앙 크롭 가정)·라이브 시계/커서·애니 위상 차이가 섞여 있다.")
    print("        파리티 지표이지 게이트가 아니다 — 임계를 정해 CI 에 걸 물건이 아니다.")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump({"grid": [GRID_W, GRID_H], "baseline": args.baseline, "scenes": rows},
                      fh, ensure_ascii=False, indent=2)
        print(f"\nJSON: {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
