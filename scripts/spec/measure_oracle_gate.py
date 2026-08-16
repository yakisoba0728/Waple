"""골든 회귀 게이트의 실효성을 측정한다.

배경(2026-08-01): 커밋된 기준선(spec/golden/snapshot/)이 안전망 역할을 하려면 게이트가 실제로
변화를 잡아야 한다. 적대적 검증에서 "게이트가 무력하다"는 주장이 나왔고 두 가지가 사실이었다 —
SnapshotCompare 가 매니페스트의 hash/meanLuma/selfMaxDiff 를 한 번도 안 읽었고, strict 임계가
절대 단위(1.5/255)라 어두운 씬일수록 느슨했다. `6e2e713`(2026-08-01)이 상대차(relDiff)와
structureLoss 를 넣어 그 사각지대를 닫았다.

[재작성 2026-08-16] **이 스크립트가 코드를 읽지 않고 낡은 확정을 재생산하고 있었다.**
둘이 겹쳤다:

  (a) 무방비 판정이 `meanLuma × 255 <= 평균 임계` 하나였다. 판정식의 나머지 셋
      (fracExceeding · relDiff · structureLoss)을 전부 무시했고, `meanLuma × 255` 자체도
      실제 meanAbsDiff 가 아니라 근사다(diffRGBA 는 RGBA 4채널 평균이고 meanLuma 는 RGB
      가중 평균이라 서로 다른 수다 — 실측 3444535389 은 근사 0.38 vs 실제 0.285).
  (b) `readBySnapshotCompare: ["deterministic"]` 이 하드코딩이었다. 6e2e713 이 meanLuma 를
      판정에 넣은 **다음 날** 재생성됐는데도 그 문장이 그대로 나왔다.

그 결과 `blindScenes` 가 count 4 를 확정으로 실었다. 지금은:

  - 판정식 상수와 **읽는 필드를 소스에서 추출**한다. 추출 실패는 폴백 없이 예외다 —
    상수를 다시 박아 두면 같은 사고가 반복된다.
  - 무방비 여부는 커밋된 썸네일 170장을 **실제로 디코드**해 전면 검정 대비 DiffMetrics 를
    계산하고, 추출한 판정식을 그대로 적용해 정한다.

도구는 stdlib 전용이라는 규약(AGENTS.md)에 따라 PNG 도 zlib+struct 로 직접 푼다.
"""
import json
import os
import re
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

SNAPSHOT_SWIFT = "Sources/WapleSnapshot/Snapshot.swift"
COMPARE_SWIFT = "Sources/WapleCompat/SnapshotCompare.swift"
LABEL_SWIFT = "Tests/WapleRenderTests/GoldenBaselineOracleTests.swift"
GATE_SH = "scripts/mac-session/golden-gate.sh"

# 무방비 씬·luma 분포는 "지금 무엇을 못 잡는가" 여야 의미가 있으므로 **현행** 기준선을 본다.
# 라벨은 판정이 실제로 쓰는 곳(GoldenBaseline.currentLabel)에서 읽는다 — 여기에 박아 두면
# 재베이스라인 때 조용히 낡아 "분석은 돌았는데 옛 기준선을 봤다" 가 된다.


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def need(pattern, text, path, what, flags=0):
    """소스에서 값을 뽑는다. 못 뽑으면 죽는다 — 폴백 상수를 두면 스테일 사실이 다시 생긴다."""
    m = re.search(pattern, text, flags)
    if not m:
        raise SystemExit(
            f"[measure_oracle_gate] {path} 에서 '{what}' 를 못 찾았다. 판정식이 바뀌었으면 "
            f"이 스크립트를 함께 고쳐라 (패턴: {pattern!r})")
    return m


def lineno(text, needle, path):
    i = text.find(needle)
    if i < 0:
        raise SystemExit(f"[measure_oracle_gate] {path} 에서 {needle!r} 를 못 찾았다")
    return text.count("\n", 0, i) + 1


# ── 소스에서 판정식 추출 ────────────────────────────────────────────────────────

def extract_kernel():
    snap, cmp_ = read(SNAPSHOT_SWIFT), read(COMPARE_SWIFT)

    # runCompare 본문 — 이 파일의 마지막 함수다. 아니게 되면 아래 단언이 깨진다.
    i = cmp_.index("static func runCompare(")
    body = cmp_[i:]
    if "static func " in body[len("static func runCompare("):]:
        raise SystemExit(f"[measure_oracle_gate] {COMPARE_SWIFT}: runCompare 뒤에 다른 함수가 "
                         f"생겼다 — 본문 슬라이스 전제가 깨졌으니 추출기를 고쳐라")
    if "return regressed ? 1 : 0" not in body:
        raise SystemExit(f"[measure_oracle_gate] {COMPARE_SWIFT}: runCompare 의 종료코드 반환을 "
                         f"못 찾았다")

    def thr(name):
        m = need(rf"static let {name} = DiffThreshold\(meanAbsDiff: ([\d.]+), "
                 rf"fracExceeding: ([\d.]+)\)", snap, SNAPSHOT_SWIFT, f"DiffThreshold.{name}")
        return {"meanAbsDiff": float(m.group(1)), "fracExceeding": float(m.group(2))}

    k = {
        "strict": thr("strict"),
        "lax": thr("lax"),
        "perPixelThreshold": int(need(r"perPixelThreshold: Int = (\d+)", snap,
                                      SNAPSHOT_SWIFT, "diffRGBA 의 perPixelThreshold 기본값").group(1)),
        "lumaWeights": [float(x) for x in need(
            r"([\d.]+) \* Double\(rgba\[i\]\) \+ ([\d.]+) \* Double\(rgba\[i \+ 1\]\) \+ "
            r"([\d.]+) \* Double\(rgba\[i \+ 2\]\)", snap, SNAPSHOT_SWIFT,
            "meanLuma 가중치").groups()],
        "relTol": float(need(r"static let relativeTolerance: Double = ([\d.]+)", cmp_,
                             COMPARE_SWIFT, "relativeTolerance").group(1)),
        "identicalOn": need(r"let identical = m\.(\w+) == 0", body, COMPARE_SWIFT,
                            "① 즉시 통과 판정").group(1),
        "lumaFloor": float(need(r"max\(entry\.meanLuma, ([\d.]+)\)", body, COMPARE_SWIFT,
                                "② relDiff 분모 클램프").group(1)),
    }
    sl = need(r"let structureLoss = entry\.meanLuma < ([\d.]+)\s*\n\s*"
              r"&& m\.meanAbsDiff > entry\.meanLuma \* 255\.0 \* ([\d.]+)", body,
              COMPARE_SWIFT, "③ structureLoss")
    k["structureCutoff"], k["structureFactor"] = float(sl.group(1)), float(sl.group(2))
    k["passExpr"] = " ".join(need(r"let pass = (identical.*?)\n\s*rows\.append", body,
                                  COMPARE_SWIFT, "pass 식", re.S).group(1).split())

    # SnapshotEntry 가 기록하는 필드 전부 vs runCompare 가 실제로 읽는 필드.
    decl = need(r"public struct SnapshotEntry[^{]*\{(.*?)public init", snap,
                SNAPSHOT_SWIFT, "SnapshotEntry 선언", re.S).group(1)
    k["recorded"] = re.findall(r"public var (\w+)\s*:", decl)
    k["read"] = sorted(set(re.findall(r"entry\.(\w+)", body)))
    k["unread"] = [f for f in k["recorded"] if f not in k["read"]]

    k["lines"] = {
        "runCompare": lineno(cmp_, "static func runCompare(", COMPARE_SWIFT),
        "strict": lineno(snap, "static let strict = DiffThreshold", SNAPSHOT_SWIFT),
        "lax": lineno(snap, "static let lax = DiffThreshold", SNAPSHOT_SWIFT),
        "relTol": lineno(cmp_, "static let relativeTolerance", COMPARE_SWIFT),
        "thrSelect": lineno(cmp_, "let thr: DiffThreshold = entry.deterministic", COMPARE_SWIFT),
        "pass": lineno(cmp_, "let pass = identical", COMPARE_SWIFT),
        "thumbGuard": lineno(cmp_, "guard baseline.thumbWidth == thumbW", COMPARE_SWIFT),
        "exit": lineno(cmp_, "return regressed ? 1 : 0", COMPARE_SWIFT),
    }
    return k


def call_sites():
    """`WapleCompat --compare` 를 실제로 **호출**하는 자리를 센다.

    단순 grep 은 못 쓴다 — scripts/ab-deviations/ 의 히트 3건은 전부 "쓰지 않는다" 는
    **산문**이고, 그걸 호출로 세면 이 항목이 정확히 고치려는 그 거짓("게이트가 배선돼 있다")을
    다시 만든다. 그래서 (a) 주석 줄을 빼고 (b) **따옴표 안(=출력 문자열)을 지운 뒤** 남은
    코드에서 찾는다. golden-gate.sh 의 결과 안내 printf 와 verify-plan-b12.sh 의 절 제목이
    둘 다 `WapleCompat --compare` 를 문자열로 담고 있어서 (b) 가 없으면 호출로 오계수된다.
    """
    quoted = re.compile(r"\"[^\"]*\"|'[^']*'")
    sh, ci = [], []
    for base, out in ((("scripts",), sh), ((".github",), ci)):
        for root, _dirs, files in os.walk(os.path.join(*base)):
            for fn in sorted(files):
                if not fn.endswith((".sh", ".yml", ".yaml")):
                    continue
                p = os.path.join(root, fn)
                for n, line in enumerate(read(p).splitlines(), 1):
                    s = line.strip()
                    if s.startswith("#"):
                        continue
                    s = quoted.sub(" ", s)
                    if "WapleCompat" in s and "--compare" in s:
                        out.append(f"{p.replace(os.sep, '/')}:{n}")
    callers = []
    for root, _dirs, files in os.walk("scripts"):
        for fn in sorted(files):
            if not fn.endswith(".sh"):
                continue
            p = os.path.join(root, fn)
            if p.replace(os.sep, "/") == GATE_SH:
                continue
            for n, line in enumerate(read(p).splitlines(), 1):
                s = line.strip()
                if s.startswith("#"):
                    continue
                if "golden-gate.sh" in quoted.sub(" ", s):
                    callers.append(f"{p.replace(os.sep, '/')}:{n}")
    return sh, ci, callers


# ── 썸네일 디코드(stdlib) ──────────────────────────────────────────────────────

def decode_png_rgba(path):
    """8비트 RGBA · 비인터레이스 PNG 를 그대로 푼다. 다른 형식은 거부한다."""
    d = open(path, "rb").read()
    if d[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"[measure_oracle_gate] PNG 가 아니다: {path}")
    off, idat, ihdr = 8, [], None
    while off < len(d):
        ln = struct.unpack(">I", d[off:off + 4])[0]
        typ = d[off + 4:off + 8]
        if typ == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", d[off + 8:off + 8 + ln])
        elif typ == b"IDAT":
            idat.append(d[off + 8:off + 8 + ln])
        off += 12 + ln
    w, h, bd, ct, _cm, _fl, il = ihdr
    if (bd, ct, il) != (8, 6, 0):
        raise SystemExit(f"[measure_oracle_gate] 8비트 RGBA 비인터레이스가 아니다: {path} {ihdr}")
    raw = zlib.decompress(b"".join(idat))
    bpp, stride = 4, w * 4
    out, prev, pos = bytearray(h * stride), bytearray(stride), 0
    for y in range(h):
        f = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos + stride]); pos += stride
        if f == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                c = prev[i - bpp] if i >= bpp else 0
                b = prev[i]
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if (pa <= pb and pa <= pc) else (b if pb <= pc else c))) & 0xFF
        elif f != 0:
            raise SystemExit(f"[measure_oracle_gate] 알 수 없는 PNG 필터 {f}: {path}")
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, bytes(out)


def blackout_metrics(px, n, k):
    """썸네일이 **전면 검정(불투명 0,0,0,255)** 으로 바뀌었을 때의 DiffMetrics + meanLuma.

    diffRGBA 와 같은 식이다: 4채널 |Δ| 평균 · 픽셀당 최대 채널차 · 그 최대차가
    perPixelThreshold 를 넘는 픽셀 비율. 알파는 양쪽 255 라 차가 0 이고(호출부가 실측 확인),
    RGB 는 기준선 값이 그대로 차가 된다.
    """
    wr, wg, wb = k["lumaWeights"]
    s = mx = exceed = 0
    amin = 255
    lum = 0.0
    for i in range(0, n * 4, 4):
        r, g, b, a = px[i], px[i + 1], px[i + 2], px[i + 3]
        if a < amin:
            amin = a
        pm = r if r > g else g
        if b > pm:
            pm = b
        s += r + g + b
        if pm > mx:
            mx = pm
        if pm > k["perPixelThreshold"]:
            exceed += 1
        lum += wr * r + wg * g + wb * b
    return {"meanAbsDiff": s / (n * 4), "maxAbsDiff": mx, "fracExceeding": exceed / n,
            "meanLuma": lum / n / 255.0, "minAlpha": amin}


def verdict(m, luma, deterministic, k):
    """SnapshotCompare.runCompare 의 판정을 그대로 옮긴 것(상수는 전부 추출값)."""
    thr = k["strict"] if deterministic else k["lax"]
    identical = m["maxAbsDiff"] == 0
    rel = m["meanAbsDiff"] / (max(luma, k["lumaFloor"]) * 255.0)
    loss = luma < k["structureCutoff"] and m["meanAbsDiff"] > luma * 255.0 * k["structureFactor"]
    absolute = m["meanAbsDiff"] <= thr["meanAbsDiff"] and m["fracExceeding"] <= thr["fracExceeding"]
    return {
        "pass": identical or (absolute and rel <= k["relTol"] and not loss),
        "absolutePass": absolute, "relDiff": rel, "structureLoss": loss,
        "meanPass": m["meanAbsDiff"] <= thr["meanAbsDiff"],
        "fracPass": m["fracExceeding"] <= thr["fracExceeding"],
    }


def main():
    k = extract_kernel()
    label = need(r'static let currentLabel = "([^"]+)"', read(LABEL_SWIFT), LABEL_SWIFT,
                 "GoldenBaseline.currentLabel").group(1)
    basedir = os.path.join("spec", "golden", "snapshot", label)
    manifest_rel = os.path.join(basedir, "manifest.json").replace(os.sep, "/")
    with open(os.path.join(basedir, "manifest.json"), encoding="utf-8") as fh:
        m = json.load(fh)
    entries = m["entries"]

    rows, luma_mismatch, alpha_bad = [], [], []
    for e in entries:
        w, h, px = decode_png_rgba(os.path.join(basedir, "thumbs", e["id"] + ".png"))
        bm = blackout_metrics(px, w * h, k)
        # 썸네일이 매니페스트가 말하는 그 프레임인지 대조 — 어긋나면 기준선이 오염된 것이고,
        # 아래 판정 전체가 무의미해진다. 겸사겸사 이 디코더가 Swift 쪽 산출과 같은지도 잡힌다.
        if abs(bm["meanLuma"] - e["meanLuma"]) > 1e-9:
            luma_mismatch.append(f"{e['id']}: manifest {e['meanLuma']} vs thumb {bm['meanLuma']}")
        if bm["minAlpha"] != 255:
            alpha_bad.append(f"{e['id']}: minAlpha {bm['minAlpha']}")
        v = verdict(bm, e["meanLuma"], e.get("deterministic", True), k)
        rows.append({"id": e["id"], "meanLuma": e["meanLuma"], "m": bm, "v": v,
                     "deterministic": e.get("deterministic", True)})
    if luma_mismatch:
        raise SystemExit("[measure_oracle_gate] 썸네일과 매니페스트 meanLuma 불일치: "
                         + "; ".join(luma_mismatch[:5]))
    if alpha_bad:
        raise SystemExit("[measure_oracle_gate] 썸네일 알파가 255 가 아니다(전면 검정 diff 전제가 "
                         "깨진다): " + "; ".join(alpha_bad[:5]))

    blind = [r for r in rows if r["v"]["pass"]]
    # 6e2e713 이전 판정식(절대 임계만)에서 무방비였던 씬 — "무엇이 닫혔나" 의 분모.
    pre = [r for r in rows if r["v"]["absolutePass"]]
    # 종전 이 스크립트가 쓰던 근사(meanLuma × 255 <= 평균 임계)가 뽑던 씬.
    approx = [r for r in rows
              if r["meanLuma"] * 255.0 <= (k["strict"] if r["deterministic"] else k["lax"])["meanAbsDiff"]]

    def detail(r):
        return {"id": r["id"], "meanLuma": round(r["meanLuma"], 5),
                "blackoutMeanAbsDiff": round(r["m"]["meanAbsDiff"], 4),
                "blackoutFracExceeding": round(r["m"]["fracExceeding"], 4),
                "blackoutMaxAbsDiff": r["m"]["maxAbsDiff"],
                "relDiff": round(r["v"]["relDiff"], 4),
                "caughtBy": [n for n, hit in (("fracExceeding", not r["v"]["fracPass"]),
                                              ("meanAbsDiff", not r["v"]["meanPass"]),
                                              ("relDiff", r["v"]["relDiff"] > k["relTol"]),
                                              ("structureLoss", r["v"]["structureLoss"])) if hit],
                "pass": r["v"]["pass"]}

    sh_sites, ci_sites, callers = call_sites()
    lumas = sorted(e["meanLuma"] for e in entries)
    ev_base = specfmt.ev("file", manifest_rel, f"커밋된 기준선 {len(entries)}종의 썸네일·meanLuma")
    ev_cmp = specfmt.ev("file", f"{COMPARE_SWIFT}:{k['lines']['pass']}", "판정식 원문")
    ev_thr = specfmt.ev("file", f"{SNAPSHOT_SWIFT}:{k['lines']['strict']}-{k['lines']['lax']}",
                        "strict/lax 임계 출처")
    ev_self = specfmt.ev("script", "scripts/spec/measure_oracle_gate.py",
                         "임계·판정식·읽는 필드를 소스에서 추출하고 썸네일을 디코드해 재계산한다")

    entries_out = [
        specfmt.entry("oracle.gate.unusedManifestFields", {
            "recorded": k["recorded"],
            "readByRunCompare": k["read"],
            "unread": k["unread"],
            "source": "두 목록 모두 소스에서 추출한다 — SnapshotEntry 선언과 runCompare 본문의 "
                      "entry.<field> 참조. 하드코딩하지 않는다.",
            "correction": "[2026-08-16] 이 항목은 readBySnapshotCompare 를 ['deterministic'] 로 "
                          "박아 두고 있었다. 6e2e713 이 meanLuma 를 판정에 넣은 **다음 날** "
                          "재생성됐는데도 그 문장이 그대로 나왔다.",
            "hashIsStillUnread": "'픽셀 동일' 즉시 통과는 hash 가 아니라 m." + k["identicalOn"] +
                                 " == 0 으로 한다. diff 를 계산한 뒤에 보므로 diff 비용은 "
                                 "그대로다. 다만 지배적 비용은 캡처라서 이득의 상한이 작다.",
            "widthHeightAreGuardedElsewhere": "width/height 는 entry 단위로 안 읽고 매니페스트 "
                                              f"단위 가드가 대신 본다 — {COMPARE_SWIFT}:"
                                              f"{k['lines']['thumbGuard']} 가 썸네일 크기 불일치를 "
                                              "exit 2 로 막는다.",
        }, "확정", [specfmt.ev("file", f"{COMPARE_SWIFT}:{k['lines']['runCompare']}-"
                                       f"{k['lines']['exit']}",
                               "runCompare 본문 — 여기의 entry.<field> 참조를 센다"),
                    specfmt.ev("file", SNAPSHOT_SWIFT, "SnapshotEntry 기록 필드"), ev_self]),

        specfmt.entry("oracle.gate.thresholds", {
            "strict": k["strict"],
            "lax": k["lax"],
            "unit": "0..255 절대값",
            "perPixelThreshold": k["perPixelThreshold"],
            "thresholdSelection": f"{COMPARE_SWIFT}:{k['lines']['thrSelect']} — "
                                  "결정 씬 strict, 비결정 씬 lax",
            "relative": {
                "tolerance": k["relTol"],
                "denominator": f"max(entry.meanLuma, {k['lumaFloor']}) * 255",
                "why": "절대 단위만 보면 어두운 씬일수록 실효 게이트가 느슨해진다. 기준선 밝기로 "
                       "정규화한 상대차를 함께 본다.",
            },
            "structureLoss": {
                "lumaCutoff": k["structureCutoff"],
                "factor": k["structureFactor"],
                "why": f"기준선 meanLuma < {k['structureCutoff']} 구간은 절대·상대 둘 다 둔하다"
                       "(분모 클램프가 걸린다). '구조가 사라졌는가' 로 본다.",
            },
            "passExpression": k["passExpr"],
            "history": "[2026-08-16] 이 항목은 결함으로 '상대(대비 정규화) 지표가 없다' 를 "
                       "적고 있었다. 6e2e713(2026-08-01)이 relDiff·structureLoss 를 넣어 그 "
                       "결함을 닫았고, 그 뒤로 이 문장이 낡아 있었다. 값은 이제 소스에서 뽑는다.",
        }, "확정", [ev_thr, ev_cmp, ev_self]),

        specfmt.entry("oracle.gate.blindScenes", {
            "definition": "커밋된 기준선 썸네일을 **전면 검정(불투명 0,0,0,255)** 으로 바꿨을 때 "
                          "현행 --compare 판정식이 그대로 통과시키는 씬",
            "method": f"기준선 {len(entries)}종의 썸네일을 디코드해 diffRGBA 와 같은 식으로 "
                      "meanAbsDiff/maxAbsDiff/fracExceeding 을 계산하고, 소스에서 추출한 "
                      "판정식(identical || (절대 && relDiff && !structureLoss))을 적용한다.",
            "count": len(blind),
            "scenes": [detail(r) for r in sorted(blind, key=lambda r: r["meanLuma"])],
            "formerlyFlagged": {
                "what": "종전 항목이 무방비로 지목했던 씬들이 지금 어떤 판정을 받는지 씬별 실측. "
                        "`caughtBy` 가 그 씬을 잡는 항이다.",
                "scenes": [detail(r) for r in
                           sorted({r["id"]: r for r in approx + pre}.values(),
                                  key=lambda r: r["meanLuma"])],
            },
            "priorCountWasFour": {
                "what": "종전 이 항목은 count 4 를 확정으로 실었다. 두 겹의 오차였다.",
                "approximationError": "판정을 `meanLuma × 255 <= 평균 임계` 하나로 봤다. "
                                      "fracExceeding 을 무시했고, meanLuma × 255(RGB 가중 평균)는 "
                                      "실제 meanAbsDiff(RGBA 4채널 평균)와 다른 수다.",
                "staleness": "6e2e713 이 relDiff·structureLoss 를 넣은 다음 날 재생성됐는데 "
                             "스크립트가 그 둘을 안 봤다.",
                "approxWouldFlag": [r["id"] for r in sorted(approx, key=lambda r: r["meanLuma"])],
                "actualUnderPreviousCode": [r["id"] for r in sorted(pre, key=lambda r: r["meanLuma"])],
            },
            "decoderCrossCheck": f"디코드한 썸네일로 다시 계산한 meanLuma 가 매니페스트 값과 "
                                 f"{len(entries)}종 전부 완전 일치한다(최대 오차 0). 파이썬 "
                                 "디코더와 Swift 산출이 같은 픽셀을 본다는 뜻이고, 썸네일이 "
                                 "매니페스트가 말하는 그 프레임이라는 뜻이기도 하다. "
                                 "알파도 전량 255 라 전면 검정과의 알파차는 0 이다.",
            "verifiedByRunningTheJudge": "위 4종을 전면 검정으로 바꾼 기준선 사본에 --compare 를 "
                                         "돌려 4/4 FAIL(exit 1)을 실측했고, Swift 가 찍은 "
                                         "mean/max/frac 이 여기 값과 일치한다 — "
                                         "oracle.gate.compareWiring 의 negativeControl.",
        }, "확정", [ev_base, ev_cmp, ev_self]),

        specfmt.entry("oracle.gate.compareWiring", {
            "problem": "판정기를 정성껏 만들어 놓고 **아무도 부르지 않았다**. 2026-08-16 감사에서 "
                       "`grep -rn -- \"--compare\" scripts/ .github/ Tests/` 의 히트 3건이 전부 "
                       "'쓰지 않는다' 는 문장이었다(scripts/ab-deviations/README.md:20,24 · "
                       "03-ab-diff.py:4). 즉 3단 판정이 자동으로 실행되는 경로가 0 이었다.",
            "callSites": sh_sites,
            "ciCallSites": ci_sites,
            "invokedBy": callers,
            "howCounted": "주석/산문 줄을 뺀 셸 실행 줄만 센다. 단순 grep 은 ab-deviations 의 "
                          "'쓰지 않는다' 문장을 호출로 세어 이 항목이 고치려는 그 거짓을 다시 만든다.",
            "exitCodes": {"0": "회귀 없음", "1": "결정 씬 FAIL 또는 렌더→무픽셀 회귀",
                          "2": "환경 오류(베이스라인/코퍼스 부재, 썸네일 크기 불일치, compared=0)",
                          "source": f"{COMPARE_SWIFT}:{k['lines']['exit']}"},
            "whyNotCI": {
                "decisive": "CI 러너에 코퍼스가 없다. 워크샵 pkg 는 커밋 대상이 아니고, 코퍼스가 "
                            "없으면 --compare 는 베이스라인 entry 를 전부 skip 해 exit 2 를 낼 뿐 "
                            "아무것도 검증하지 않는다.",
                "secondary": "코퍼스를 넣더라도 수십 GB 전송 + 씬 170종 캡처가 40분 타임아웃 예산을 "
                             "먹는다. 캡처 비용 자체는 이번 실측 140.6초(warm)이고 문서 실측은 "
                             "1× 패스 ≈360초(cold)·피크 RSS ≈3.9GB 다 — 결정적인 것은 코퍼스 부재 쪽이다.",
                "notTheReason": "GPU 가용성은 이유가 아니다. AGENTS.md 실측대로 Metal 은 CI 에서도 잡힌다.",
            },
            "firstFullRun": {
                "when": "2026-08-16, main @82e9414, release, 전 코퍼스",
                "result": "compared=170 PASS=168 FAIL(결정)=2 · 렌더→무픽셀 0 · elapsed 140.6s",
                "failed": ["3706286085 mean=17.16 max=222 frac=0.5881",
                           "3589454154 mean=16.17 max=255 frac=0.1485"],
                "reading": "3위 편차가 mean=0.05(max=7)이고 그 아래는 mean=0.00 이다. 커밋된 "
                           "기준선은 이 머신에서 그대로 재현되고, 실제로 어긋난 것은 이 2종뿐이다.",
                "why3589454154": "oracle.nondet.unstableSet **밖**이다. c69f93c(MDLV 인덱스 폭이 "
                                 "정점 수를 따르게 한 수정)의 커밋 메시지가 이 씬의 陨石.mdl 을 "
                                 "최대 사례로 이름까지 적는다(정점 3,144,456 → u32). 기준선 "
                                 "31fecaa 는 그 수정 이전이므로 이 씬에 대해 낡았다.",
                "why3706286085": "oracle.nondet.unstableSet 29종 **안**이다. 그 가족은 세션이 "
                                 "갈리면 값이 달라지는데 셀프체크가 프로세스 내부만 재는 탓에 "
                                 "deterministic=true 로 실려 strict 로 샌다"
                                 "(oracle.gate.selfCheckIsIntraProcess). 커밋된 기준선 대조는 "
                                 "세션을 건너뛴 대조라, 이 FAIL 은 코드 변화인지 세션 잡음인지 "
                                 "이 대조 하나로는 갈리지 않는다. 원인 커밋은 좁히지 않았다 — "
                                 "후보는 31fecaa..HEAD 의 렌더 커밋 10개다.",
                "unstableFamilyThisRun": "29종 중 이번 실행에서 FAIL 은 3706286085 하나뿐이고 "
                                         "나머지 28종은 통과했다(전 코퍼스 3위 편차가 mean 0.05 "
                                         "이므로 그 28종의 평균 절대차는 0.05 이하다). '세션이 "
                                         "갈리면 29종이 갈린다' 는 상한이지 매 실행의 실측치가 아니다.",
                "gateReadsThisForYou": "golden-gate.sh 는 FAIL 목록을 unstableSet 과 대조해 "
                                       "'불안정 가족 안/밖' 을 나눠 찍는다. 종료코드는 그대로 1 이다 — "
                                       "판정을 무르게 하는 게 아니라 읽는 법을 붙인 것이다.",
                "remedy": "3589454154 는 코드 회귀가 아니라 기준선 재생성 대상이다 — "
                          "scripts/mac-session/rebaseline-golden.sh (코디네이터 판단). "
                          "재생성은 두 캡처 사이에 커서를 옮겨 비트동일을 확인하는 설치 게이트를 "
                          "그대로 거친다.",
            },
            "negativeControl": {
                "method": "기준선 사본(리포 밖)에서 종전 무방비 4종의 썸네일을 전면 검정으로 "
                          "바꾸고 --compare 실행. diff 는 대칭이라 이 수는 '현재 렌더가 전면 "
                          "검정이 됐다' 와 같다.",
                "broken": "compared=4 PASS=0 FAIL(결정)=4 → exit 1. "
                          "3662790108 mean=0.65 frac=0.0182 · 1612750231 mean=0.52 frac=0.0053 · "
                          "2881558311 mean=0.51 frac=0.0090 · 3444535389 mean=0.28 frac=0.0037",
                "control": "같은 4종을 손대지 않은 사본으로 돌리면 compared=4 PASS=4 "
                           "mean=0.00 max=0 → exit 0. 오탐 0.",
                "crossCheck": "Swift 가 찍은 네 줄의 mean/max/frac 이 이 스크립트의 파이썬 "
                              "재계산과 자릿수까지 같다. blindScenes count 0 은 파이썬 계산만이 "
                              "아니라 **판정기 실행**으로도 확인된 값이다.",
                "sharpestCase": "3444535389 은 전면 검정에서도 mean 0.28 <= strict 1.5 이고 "
                                "frac 0.0037 <= 0.004 라 **절대 임계만으로는 통과**한다. "
                                "relDiff 0.056 > 0.05 와 structureLoss 가 잡는다 — "
                                "6e2e713 이 무엇을 닫았는지가 이 한 줄에 있다.",
                "why": "오라클을 강화했으면 일부러 깨뜨려 잡히는지 확인한다.",
            },
            "crossRef": ["oracle.nondet.unstableSet", "oracle.gate.selfCheckIsIntraProcess"],
        }, "확정", [specfmt.ev("script", GATE_SH, "게이트 실행 스크립트(라벨은 코드에서 읽는다)"),
                    specfmt.ev("script", "scripts/mac-session/verify-plan-b12.sh",
                               "§7 이 이 게이트를 부르고 종료코드를 FAIL 에 반영한다"),
                    specfmt.ev("file", "macOS 세션 2026-08-16 — 전 코퍼스 --compare 및 음성 대조 실측")]),

        specfmt.entry("oracle.gate.negativeControl", {
            "what": "게이트 강화가 실제로 잡는지 일부러 깨뜨려 확인한 결과",
            "method": "clearColor 를 검정 고정으로 바꾸고 GT 스위트 실행",
            "firstAttempt": {
                "result": "실패 — 테스트가 통과했다",
                "why": "하드 단언이 luma <= 0.0(정확히 검정)이었는데 씬이 클리어 컬러 "
                       "**위에 콘텐츠를 그려서** luma 가 0 에 닿지 않는다. "
                       "드리프트는 설계상 NSLog 만 남긴다.",
                "observedDrift": "2593802559: 0.666 -> 0.032 · 2867182492: 0.361 -> 0.008 등 4건",
            },
            "fix": {
                "what": "GT 경로에 structureLoss 판정 추가 — 기준선 대비 밝기가 절반 아래로 "
                        "떨어지면 하드 실패",
                "why": "SnapshotCompare 에는 이미 들어간 판정인데 GT 경로에 대응물이 없어 "
                       "두 오라클이 비대칭이었다",
                "whyOnlyThis": "일반 드리프트를 하드 실패로 올리면 의도적 렌더 변경마다 "
                               "재베이스라인 전까지 스위트가 빨간불이 된다. 반면 화면이 "
                               "사라지는 것은 의도된 적이 없다.",
                "status": "음성 대조 재실행으로 확인됨",
            },
            "verified": {
                "brokenStateFails": "2867182492 0.361 -> 0.0085(42배 하락) · "
                                    "2593802559 0.666 -> 0.032(21배) 가 structureLoss 로 하드 실패",
                "selectivity": "드리프트 4건 중 2건만 하드 실패. 0.60배·0.80배는 로그로만 남았다",
                "noFalsePositive": "원복 후 structureLoss 0건, 스위트 통과",
            },
            "lesson": "오라클을 강화했으면 **일부러 깨뜨려 잡히는지 확인해야 한다**. "
                      "이 프로젝트에서 안전망이 조용히 무력했던 사건이 여섯 번째인데 "
                      "이번엔 처음으로 사전에 잡혔다.",
        }, "확정", [specfmt.ev("file", "Tests/WapleRenderTests/RealPackagesGroundTruthTests.swift"),
                    specfmt.ev("file", "macOS 세션 2026-08-01 음성 대조 실측")]),

        specfmt.entry("oracle.gate.knownBandGap", {
            "what": "structureLoss 문턱(0.5배)과 로그 전용 드리프트(0.02 절대) 사이에 "
                    "하드 게이트가 없는 구간이 있다",
            "evidence": "음성 대조에서 3351179520 이 0.511 -> 0.305(0.60배)로 **실제로 깨진 "
                        "상태였는데 통과**했다",
            "whyNotJustTighten": "같은 실행에서 3302695207 이 0.80배인데 이건 **안 깨진 "
                                 "상태**다. 문턱을 0.7 로 조이면 0.60 은 잡지만 데이터 두 점에 "
                                 "맞춘 것이고, 조건 차이가 커지면 오탐이 된다.",
            "rootCause": "GT 가 자기 캡처를 **다른 하네스가 뜬 기준선**과 비교하고 있다. "
                         "GT 하네스는 640x360 이고 스냅샷 파이프라인은 256x144 에 "
                         "pause/silent-spectrum/fitMode 를 핀한다. 0.80배는 그 계통 편차다.",
            "fixPath": "임계 조정이 아니라 **두 하네스의 캡처 조건을 일치**시키는 것. "
                       "또는 GT 전용 기준선을 같은 하네스로 떠서 커밋한다.",
            "interimPolicy": "그 전까지 0.5 배는 '화면이 사라졌는가' 를 잡는 성긴 그물로 둔다. "
                             "오탐 0 으로 실증됐고, 놓치는 구간이 있다는 것을 알고 쓴다.",
        }, "확정", [specfmt.ev("file", "macOS 세션 2026-08-01 — 음성 대조 드리프트 4건 관측"),
                    specfmt.ev("file", "Tests/WapleRenderTests/RealPackagesGroundTruthTests.swift")]),

        specfmt.entry("oracle.gate.selfCheckIsIntraProcess", {
            "what": "셀프체크(deterministic/selfMaxDiff)가 **프로세스 간** 변동을 구조적으로 못 잡는다",
            "code": "SnapshotPipeline.swift:191 — 2차 캡처가 같은 프로세스 안에서 captureFrame 재호출. "
                    "주석은 '독립 재마운트' 라고 적혀 있지만 프로세스는 하나다.",
            "whyItMisses": "프로세스 시작 시 정해지는 것들(RNG 시드, 정적 캐시, 딕셔너리 순회 순서, "
                           "셰이더 컴파일 순서 등)이 두 캡처에서 동일하다. 그 값이 실행마다 달라지면 "
                           "화면이 달라지는데 셀프체크는 항상 일치한다고 보고한다.",
            "structuralClaimIsCodeVerified": "위 'whyItMisses' 는 코드에서 직접 확인한 사실이다. "
                                             "재현 여부와 무관하게 이 필드는 프로세스 간 변동을 "
                                             "**측정할 수 없다** — 잡을 게 없어서 0 이 나오는 것과 "
                                             "잡을 능력이 없어서 0 이 나오는 것을 구분하지 못한다.",
            "empiricalClaimResolved": {
                "firstObservation": "macOS 2026-08-01 검증 세션 — 같은 커밋·같은 빌드 전 코퍼스 "
                                    "2회 캡처에서 **29종이 달랐다**고 보고됨(mips-82fcd08 vs head-rerun). "
                                    "두 매니페스트가 남아 있어 그대로 재계산된다.",
                "controlledProbe": "같은 날 probe-nondeterminism.sh 로 별도 프로세스 2회 캡처 "
                                   "(runA/runB, 각 170종) → **차이 0종**.",
                "status": "[2026-08-01 심야] 두 관측은 모순이 아니었다. 축이 '실행 간' 이 아니라 "
                          "**'세션 간'** 이다 — 같은 세션 안에서는 프로세스를 갈라도 전 코퍼스가 "
                          "비트동일하고(전 코퍼스 3회·단건 반복 전부 0종), 세션이 갈리면 29종이 갈린다. "
                          "29 는 정본으로 쓸 수 있다.",
                "measuredIn": "oracle.nondet.axisIsCrossSession · oracle.nondet.unstableSet "
                              "(spec/golden/nondeterminism.json)",
                "whatWasRefuted": "이 항목이 적어 뒀던 유력 가설(전 스위트 부하 → 씬 간 상태 누수)과 "
                                  "판별 실험(runB 직전에 스위트를 끼워 재실행)은 **반증됐다**. "
                                  "단건 캡처 값이 순차 캡처 안의 값과 같고, 캡처 사이에 전 코퍼스 "
                                  "캡처를 끼워도 앞뒤가 비트동일하다.",
            },
            "consequence": "**같은 세션 안에서 뜬 A/B 대조는 신뢰할 수 있다.** "
                           "커밋된 기준선처럼 세션을 건너뛴 대조에만 29종이 잡음으로 섞인다 — "
                           "그 29종은 고정 가족이고 id 목록이 oracle.nondet.unstableSet 에 있다.",
            "reopened3696323523": "'기대 집합 밖 1종' 을 '비결정' 으로 닫았던 것은 이제 근거가 있다 — "
                                  "이 씬은 불안정 29종 안에 있고 네 세션에서 네 값이 나온다.",
            "thresholdMisclassification": {
                "code": f"SnapshotCompare.swift:{k['lines']['thrSelect']} — "
                        "`entry.deterministic ? .strict : .lax`",
                "designIsCorrect": "결정적 씬에 strict, 비결정 씬에 lax 는 **의도대로 맞다**. "
                                   "극성을 뒤집으면 안 된다.",
                "actualDefect": "그 29종이 deterministic=true 로 **잘못 분류**되는 바람에 "
                                "비결정 씬인데 strict 로 샌다. 고칠 곳은 임계 선택줄이 아니라 "
                                "분류(셀프체크)다.",
                "correctionNote": "[정정 2026-08-01] 이 항목은 처음에 '방향이 반대다' 라고 "
                                  "적혀 있었다. 틀렸다 — 그대로 믿고 그 줄을 뒤집으면 "
                                  "정상 동작을 깨뜨린다.",
            },
            "isolationEvidence": "3696323523: 단일씬 재캡처는 커밋 전후가 동일했고, "
                                 "전체 코퍼스 캡처는 같은 빌드 2회가 서로 달랐다 — "
                                 "커밋 무관까지 격리됐다. 그 '2회' 가 세션을 건너뛴 쌍이었다는 것은 "
                                 "나중에 밝혀졌다(oracle.nondet.axisIsCrossSession).",
            "fixDirection": "셀프체크를 **별도 프로세스**에서 돌리거나, 매니페스트에 "
                            "'교차 실행 재현성' 을 별도 필드로 둔다. 지금 필드는 이름과 달리 "
                            "'같은 프로세스 안에서 두 번 그리면 같은가' 만 답한다.",
            "lesson": "필드 이름이 약속하는 것('재현 가능한가')과 코드가 재는 것('같은 프로세스 "
                      "안에서 두 번 그리면 같은가')이 다르다 — 이 저장소에서 반복돼 온 실패 모양이다. "
                      "피해 규모도 이제 재어져 있다: 세션을 건너뛴 대조에서 **29종/170종**. "
                      "덧붙여 '재현 실패' 를 결론으로 적을 뻔했는데, 실제로는 **재현 조건이 "
                      "달랐을 뿐**이었다 — 0/170 을 '결정적' 으로도 '간헐적' 으로도 읽지 않고 "
                      "축을 다시 고른 것이 답을 냈다.",
            "crossRef": "oracle.nondet.axisIsCrossSession",
        }, "확정", [specfmt.ev("file", "Sources/WapleCompat/SnapshotPipeline.swift:187-198",
                               "2차 캡처가 같은 프로세스"),
                    specfmt.ev("file", f"{COMPARE_SWIFT}:{k['lines']['thrSelect']}",
                               "deterministic 으로 임계 선택"),
                    specfmt.ev("script", "scripts/spec/measure_nondeterminism.py",
                               "커밋된 세션 매니페스트 8개로 29종을 재계산한다"),
                    specfmt.ev("script", "scripts/mac-session/probe-session-nondeterminism.sh",
                               "세션 내 재현성·부하·TZ·CWD 배제를 다시 뜨는 프로토콜")]),

        specfmt.entry("oracle.gate.lumaDistribution", {
            "n": len(lumas),
            "min": round(lumas[0], 5),
            "p05": round(lumas[len(lumas) // 20], 5),
            "median": round(lumas[len(lumas) // 2], 5),
            "max": round(lumas[-1], 5),
        }, "확정", [ev_base]),
    ]

    specfmt.dump(specfmt.doc("scripts/spec/measure_oracle_gate.py", entries_out),
                 os.path.join("spec", "golden", "gate-analysis.json"))

    print(f"기준선 {label} — {len(entries)}종 (라벨 출처: {LABEL_SWIFT})")
    print(f"  판정식(소스 추출): {k['passExpr']}")
    print(f"    strict {k['strict']} · lax {k['lax']} · relTol {k['relTol']} · "
          f"structureLoss(<{k['structureCutoff']}, ×{k['structureFactor']})")
    print(f"  기록 필드 {k['recorded']}")
    print(f"    runCompare 가 읽는 것 {k['read']} / 안 읽는 것 {k['unread']}")
    print(f"  meanLuma  min {lumas[0]:.5f} / median {lumas[len(lumas)//2]:.5f} / max {lumas[-1]:.5f}")
    print(f"  전면 검정으로 바꿔도 통과하는 무방비 씬: {len(blind)}종")
    for r in sorted(blind, key=lambda r: r["meanLuma"]):
        print(f"    {r['id']:12} meanLuma={r['meanLuma']:.5f}")
    print(f"  6e2e713 이전 판정식(절대 임계만)에서 무방비였던 씬: {len(pre)}종")
    for r in sorted(pre, key=lambda r: r["meanLuma"]):
        d = detail(r)
        print(f"    {r['id']:12} meanLuma={r['meanLuma']:.5f} 검정시 mean={d['blackoutMeanAbsDiff']:.3f} "
              f"frac={d['blackoutFracExceeding']:.4f} rel={d['relDiff']:.3f} → 지금 잡는 것: "
              f"{','.join(d['caughtBy'])}")
    print(f"  --compare 호출 지점 {len(sh_sites)}곳 {sh_sites} (CI {len(ci_sites)}곳)")


if __name__ == "__main__":
    main()
