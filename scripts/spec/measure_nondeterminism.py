"""골든 캡처의 실행 간 재현성을 측정한다 — 축이 '세션 간' 임을 확정한다.

배경: 검증 세션에서 "같은 빌드 2회 캡처가 29종 다르다" 는 보고가 나왔고, 통제 프로브
(별도 프로세스 연속 2회)에서는 0종이 나와 "재현 실패" 로 닫혔다. 두 관측은 모순이 아니다 —
**같은 세션 안의 두 캡처는 항상 같고, 세션이 갈리면 29종이 갈린다.**

이 스크립트는 커밋된 전 코퍼스 매니페스트 8개(세션 A~D + mip 수정 전 PRE)의 `hash` 만으로
그 주장을 재계산한다. 픽셀은 필요 없다 — 판정이 해시 동일성이라서다.

양성/음성 대조(spec/README.md 규칙 5):
  - 세션 **내** 쌍(C-runA/C-runB, D-R1/D-R2/D-R3)이 하나라도 다르면 즉시 실패한다.
    "세션이 단위" 라는 전제가 깨진 것이므로 결과를 쓰면 안 된다.
  - 세션 **간** 차이가 0 이면 즉시 실패한다. 필터가 깨진 것이지 "결정적" 이 아니다.
  - 매니페스트의 씬 집합이 서로 다르면 즉시 실패한다(부분집합 비교로 숫자가 줄어드는 사고 방지).

측정 프로토콜(무엇을 배제했는지 포함)은 scripts/mac-session/probe-session-nondeterminism.sh.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

BASE = os.path.join("spec", "golden", "snapshot", "nondet-2026-08-01")

# 세션 → 그 세션에서 뜬 캡처들(디렉터리명). 순서 = 시간순.
SESSIONS = [
    ("A", ["A-mips"]),
    ("B", ["B-head"]),
    ("C", ["C-runA", "C-runB"]),
    ("D", ["D-R1", "D-R2", "D-R3"]),
]
PRE = "PRE-eaaee0c"   # 임베디드-mip 수정 **전** 캡처 — 수정 영향권 산출용


def load(name):
    path = os.path.join(BASE, name, "manifest.json")
    with open(path, encoding="utf-8") as fh:
        return {e["id"]: e for e in json.load(fh)["entries"]}


def diff_ids(a, b):
    return sorted(i for i in a if i in b and a[i]["hash"] != b[i]["hash"])


def fail(msg):
    print(f"!! {msg}")
    sys.exit(1)


def main():
    caps = {name: load(name) for _, names in SESSIONS for name in names}
    caps[PRE] = load(PRE)

    ids = sorted(caps[SESSIONS[0][1][0]])
    for name, m in caps.items():
        if sorted(m) != ids:
            fail(f"{name}: 씬 집합이 다르다({len(m)} vs {len(ids)}) — 부분집합 비교는 숫자를 조용히 줄인다")

    # 대조 1(음성): 세션 내 캡처끼리는 비트동일해야 한다.
    within = []
    for sess, names in SESSIONS:
        for i in range(len(names) - 1):
            for j in range(i + 1, len(names)):
                d = diff_ids(caps[names[i]], caps[names[j]])
                within.append({"session": sess, "pair": [names[i], names[j]], "differing": len(d)})
                if d:
                    fail(f"세션 {sess} 내부 {names[i]} vs {names[j]} 가 {len(d)}종 다르다 — "
                         f"'세션이 단위' 전제가 깨졌다. 결과를 정본에 쓰지 마라")
    if not within:
        fail("세션 내 대조 쌍이 없다 — 음성 대조 없이는 세션 간 차이를 귀속할 수 없다")

    # 세션 대표 = 그 세션의 첫 캡처(위에서 세션 내 동일성을 이미 확인했다).
    reps = [(sess, names[0]) for sess, names in SESSIONS]
    values = {i: {sess: caps[name][i]["hash"] for sess, name in reps} for i in ids}
    unstable = [i for i in ids if len({*values[i].values()}) > 1]

    # 대조 2(양성): 세션 간 차이가 0 이면 필터가 깨진 것이다.
    if not unstable:
        fail("세션 간 차이 0종 — 해시 필드를 잘못 읽고 있을 가능성이 크다(필터 파손)")

    distinct = {i: len({*values[i].values()}) for i in unstable}
    hist = {}
    for n in distinct.values():
        hist[str(n)] = hist.get(str(n), 0) + 1

    idx = {s: k for k, s in enumerate(ids)}
    # mip 수정 영향권 = PRE 대비 A 에서 픽셀이 바뀐 씬.
    mip_affected = set(diff_ids(caps[PRE], caps["A-mips"]))
    below = [s for s in mip_affected if idx[s] < min(idx[u] for u in unstable)]

    # 매니페스트만으로 낼 수 있는 크기 지표 — 세션별 meanLuma 최대 격차.
    luma_spread = {}
    for i in unstable:
        lm = [caps[name][i]["meanLuma"] for _, name in reps]
        luma_spread[i] = round(max(lm) - min(lm), 5)
    worst = sorted(unstable, key=lambda s: -luma_spread[s])[:5]

    misreported = [i for i in unstable if caps["A-mips"][i].get("deterministic")]

    # 시각별 프레임 해시(있으면) — 발산이 t=0 에 이미 있는지(마운트) t 가 커지며 생기는지(누적) 판정.
    tsweep_by_time = {}
    tdir = os.path.join(BASE, "tsweep")
    if os.path.isdir(tdir):
        states = {}
        for f in sorted(os.listdir(tdir)):
            if f.endswith(".json"):
                with open(os.path.join(tdir, f), encoding="utf-8") as fh:
                    d = json.load(fh)
                states[d["state"]] = d["frames"]
        if len(states) >= 2:
            (s1, f1), (s2, f2) = sorted(states.items())[:2]
            common = sorted(set(f1) & set(f2))
            if not common:
                fail("tsweep 상태 두 개의 씬 집합이 겹치지 않는다 — 대조 불가")
            keys = sorted({k for s in common for k in f1[s]})
            for k in keys:
                same = sum(1 for s in common if f1[s].get(k) and f1[s].get(k) == f2[s].get(k))
                tsweep_by_time[k] = {"states": [s1, s2], "scenes": len(common),
                                     "identical": same, "differing": len(common) - same}
            if tsweep_by_time.get("t0.0", {}).get("differing", 0) == 0:
                fail("tsweep t=0 이 전부 같다 — 두 파일이 같은 상태에서 뜬 것이 아닌지 확인할 것")

    ev_caps = specfmt.ev("file", f"{BASE}/README.md".replace(os.sep, "/"),
                         "전 코퍼스 캡처 8개(세션 A~D + PRE)의 매니페스트 — 뜬 방법·바이너리 동일성 근거")
    ev_probe = specfmt.ev("script", "scripts/mac-session/probe-session-nondeterminism.sh",
                          "세션 내 재현성·부하 개입·TZ·CWD 배제를 다시 뜨는 프로토콜")
    ev_self = specfmt.ev("file", "Sources/WapleCompatCore/SnapshotPipeline.swift:187-212",
                         "셀프체크가 같은 프로세스라 이 변동을 볼 수 없다")

    entries = [
        specfmt.entry("oracle.nondet.axisIsCrossSession", {
            "what": "골든 캡처는 **같은 세션 안에서는 완전히 재현되고, 세션이 갈리면 갈린다**",
            "withinSession": within,
            "withinSessionDiffering": 0,
            "crossSessionDiffering": len(unstable),
            "sessionsMeasured": [{"session": s, "captures": names} for s, names in SESSIONS],
            "consequence": "한 세션 안에서 뜬 A/B 캡처 대조는 신뢰할 수 있다. "
                           "커밋된 기준선처럼 **세션을 건너뛴 대조**에만 이 씬들이 잡음으로 섞인다.",
            "howItWasMissed": "셀프체크(deterministic)는 2차 캡처를 같은 프로세스에서 떠서 "
                              "프로세스 간·세션 간 변동을 구조적으로 못 본다.",
            "crossRef": "oracle.gate.selfCheckIsIntraProcess",
        }, "확정", [ev_caps, ev_probe, ev_self]),

        specfmt.entry("oracle.nondet.unstableSet", {
            "count": len(unstable),
            "ids": unstable,
            "distinctValuesPerScene": hist,
            "distinctValuesLegend": "키 = 세션 4개에서 관측된 서로 다른 픽셀 해시의 개수",
            "misreportedAsDeterministic": len(misreported),
            "sortedIndexRange": [min(idx[u] for u in unstable), max(idx[u] for u in unstable)],
            "totalScenes": len(ids),
            "meanLumaSpreadTop5": [{"id": s, "spread": luma_spread[s]} for s in worst],
            "stability": "네 세션 어디서 잡아도 같은 가족이다 — 세션 쌍을 바꿔도 멤버가 "
                         "1종 이내로만 흔들린다(A~B 29종, C~D 28종, 차집합 1종).",
        }, "확정", [ev_caps]),

        specfmt.entry("oracle.nondet.mipCorrelation", {
            "mipAffectedScenes": len(mip_affected),
            "unstableInsideMipAffected": len([u for u in unstable if u in mip_affected]),
            "unstableOutsideMipAffected": len([u for u in unstable if u not in mip_affected]),
            "definition": "mip 영향권 = 임베디드 mip 체인 수정 전(PRE-eaaee0c) 대비 픽셀이 바뀐 씬",
            "positionalConfound": {
                "what": f"불안정 씬은 전부 정렬 인덱스 {min(idx[u] for u in unstable)} 이상에 있고, "
                        f"그보다 앞에 있는 mip 영향 씬 {len(below)}종은 한 번도 흔들리지 않았다",
                "whyNotConclusive": "인덱스는 씬 ID 정렬이라 워크샵 연식(=콘텐츠 복잡도)과 교락돼 있다. "
                                    "'순서가 원인' 과 '옛 씬이 단순해서 갈릴 게 없다' 를 아직 못 가른다.",
                "howToSeparate": "심링크로 정렬 순서를 뒤집어 같은 씬을 앞쪽 인덱스에 놓고 다시 뜬다.",
            },
        }, "확정", [ev_caps]),

        specfmt.entry("oracle.nondet.eliminatedFactors", {
            "what": "세션 간 값을 바꾸지 **못한** 것들 — 전부 실측으로 배제했다",
            "sameBinary": "세션 C 와 D 는 같은 바이너리 파일(sha256 44b6017a…, 재링크 없음)로 떴는데 28종이 갈렸다",
            "loadInterleave": "단건 캡처 → 전 코퍼스 170종 캡처(165초) → 단건 캡처 순으로 떠도 앞뒤가 비트동일",
            "sequenceVsSingle": "같은 세션 안에서 단건 캡처 값 = 170종 순차 캡처 안의 값(3씬×3회 확인)",
            "timezone": "TZ=UTC / Asia/Tokyo / Pacific/Kiritimati / America/Los_Angeles 4종 전부 동일 해시",
            "workingDirectory": "작업 디렉터리 3종 전부 동일 해시",
            "diskInputs": "공유 베이스 에셋·mp4 캐시·script-storage·코퍼스 전부 무변경(mtime 확인)",
            "systemEvents": "두 세션 사이에 절전·재부팅 없음(pmset -g log)",
            "notAColorTransform": "같은 입력값 픽셀의 출력 표준편차가 24~59 — 전역 톤 커브가 아니라 콘텐츠 차이",
        }, "확정", [ev_probe]),

        specfmt.entry("oracle.nondet.divergesAtMount", {
            "what": "발산은 **첫 프레임(t=0)에 이미 있다** — 프레임 누적 상태가 아니라 마운트/로드 시점이다",
            "method": "상태 D 와 E(연속한 두 세션)에서 불안정 29종을 "
                      "`WAPLE_CAPTURE_TIME=0,0.1,1,6` 으로 한 마운트에 4프레임씩 떠서 프레임 해시를 대조",
            "byTime": tsweep_by_time,
            "reading": "t=0 에서 이미 26/29 가 다르다. 나머지 3종도 t=0.1 이면 갈린다(1종 제외). "
                       "즉 시뮬레이션(파티클·스크립트 누적)이 아니라 **로드된 것 자체**가 세션마다 다르다.",
            "narrowsTo": "텍스처 업로드·디코드, 셰이더 번역 결과, 에셋 해석, 초기 유니폼 — 이 넷 중 하나.",
            "logsAreIdentical": "같은 씬을 두 상태에서 단건 캡처해 NSLog 를 정규화 대조하면 "
                               "**한 줄도 다르지 않다**(에셋 해석·셰이더 번역 로그 포함). "
                               "따라서 '무엇을 로드했는가' 가 아니라 '로드된 내용/결과' 가 다르다.",
            "crossRef": "oracle.nondet.unstableSet",
        }, "확정", [specfmt.ev("file", f"{BASE}/tsweep/D.json".replace(os.sep, "/"),
                               "상태 D 의 프레임 해시(29종 × 4시각)"),
                    specfmt.ev("file", f"{BASE}/tsweep/E.json".replace(os.sep, "/"),
                               "상태 E 의 프레임 해시 — 같은 명령"),
                    specfmt.ev("script", "scripts/mac-session/capture-tsweep.sh",
                               "다음 상태에서 같은 매트릭스를 뜨는 스크립트")]),

        specfmt.entry("oracle.nondet.rootCause", {
            "what": "캡처 픽셀에 **실제 마우스 커서 위치**가 구워진다 — 캡처 하네스가 포인터를 핀하지 않는다",
            "mechanism": "SceneRenderer.mount 는 `parallaxEnabled || hasEffects` 면 마우스 모니터를 켜고, "
                         "그 콜백(updateParallax)이 `pointerUV` 를 라이브 커서로 채운다. "
                         "pointerUV 는 이펙트 유니폼 버퍼의 g_PointerPosition 슬롯으로 들어간다. "
                         "SnapshotPipeline.pinRenderSettings 는 시각·오디오·난수·fitMode·베이스에셋은 "
                         "핀하는데 **포인터는 핀하지 않는다**.",
            "proof": "같은 씬을 커서만 옮겨 가며 캡처: 현위치·(10,10)·(1400,800) 이 전부 다른 해시, "
                     "(10,10) 로 돌아오면 그 값이 그대로 재현. 1포인트 차이(1799.98 vs 1799.0)도 값을 바꾼다.",
            "explains": {
                "sameSessionIdentical": "커서가 그대로면 프로세스를 몇 개 띄워도 같은 값이 나온다",
                "crossSessionDiffers": "세션 사이에 사람이 커서를 움직이면 값이 갈린다",
                "statesRecur": "커서가 이전 위치로 돌아오면 **이전 상태가 통째로 재현된다** — "
                               "실제로 상태 F 가 어제 상태 C 와 29종 전부 비트동일했다",
                "divergesAtT0": "유니폼이라 첫 프레임에 이미 다르다",
                "logsIdentical": "로드하는 것은 같고 유니폼 값만 다르니 NSLog 는 한 줄도 안 다르다",
                "gateMatrix": "게이트 매트릭스에서 `WAPLE_DISABLE_TRANSLATED=1` 만 상태 간 4/4 동일 — "
                              "포인터가 픽셀에 닿는 경로가 번역 이펙트라는 뜻(WAPLE_BC_NATIVE=0 · "
                              "WAPLE_NO_BLOOM · WAPLE_LAYER_TRUNC 은 전부 계속 갈렸다)",
            },
            "notTheCause": ["임베디드 mip 체인 수정(불안정 29종이 그 영향권 안인 것은 상관이지 원인이 아니다)",
                            "Metal 셰이더 캐시(치우고 떠도 값이 안 바뀐다)",
                            "부하·씬 간 상태 누수·TZ·CWD·바이너리·디스크 입력"],
            "fix": {
                "what": "SceneRenderer.capturePointerUV(정적 옵셔널) 도입 — 설정되면 마우스 모니터를 "
                        "**아예 켜지 않고** pointerUV/pointerUVLast 를 그 값으로 고정한다. "
                        "SnapshotPipeline.pinRenderSettings 와 GT 하네스가 중앙(0.5,0.5)으로 핀한다.",
                "whyNotStopInstead": "pause() 는 모니터를 멈출 뿐 이미 들어온 값을 되돌리지 않는다.",
                "threeStartSites": "기동 지점이 셋이라(mount 의 parallax/effects 게이트, mount 의 "
                                   "cursorMove·호버 게이트, resume) **한 곳만 막으면 샌다** — 실제로 "
                                   "첫 수정 후에도 커서 의존이 그대로였고, 새던 곳은 두 번째 게이트였다. "
                                   "지금은 공용 startPointerMonitor() 로 모으고 updateParallax 에도 "
                                   "이중 안전망을 뒀다.",
                "verified": "커서를 현위치·(10,10)·(1400,800)·복귀로 옮겨 가며 같은 씬을 떠서 "
                            "**네 위치 전부 같은 해시**(수정 전에는 위치마다 달랐다). "
                            "유닛 회귀는 CapturePointerPinTests — 핀 분기를 지우면 pointerUV 가 "
                            "실제 커서값(1.0, 0.0)으로 바뀌며 깨지는 것까지 확인했다(음성 대조).",
                "rebaselined": "현행 골든을 다시 떴다 — spec/golden/snapshot/baseline-f3a17da "
                               "(release, 170/0/0, 셀프체크 비결정 0종). 설치 게이트가 전 코퍼스 "
                               "2회 캡처 **사이에 커서를 옮겨서** 비트동일을 요구하는데 상이 0종이었다 "
                               "(같은 대조가 수정 전에는 28~29종). 스위트 실증: GT 170/170 "
                               "mounted·captured·구조소실 0, GT 제외 2,142개 통과.",
            },
            "captureCaveat": "다중 시각 마운트의 t=6 프레임은 t=6 단독 캡처와 다르다"
                             "(캡처 루프가 프레임 간 스크립트/파티클 연속성을 유지 — 실측). "
                             "진단 프레임은 같은 WAPLE_CAPTURE_TIME 끼리만 비교할 것.",
        }, "확정", [specfmt.ev("script", "scripts/mac-session/probe-pointer-uniform.sh",
                               "커서를 옮겨 가며 같은 씬을 떠서 해시가 갈리는 것을 보인다"),
                    specfmt.ev("file", "Sources/WapleRender/SceneRenderer.swift:1421-1425",
                               "parallaxEnabled || hasEffects 면 마우스 모니터 start"),
                    specfmt.ev("file", "Sources/WapleRender/SceneRenderer.swift:1535-1537",
                               "updateParallax 가 pointerUV 를 라이브 커서로 채운다"),
                    specfmt.ev("file", "Sources/WapleRender/SceneRendererFrameEncoder.swift:53",
                               "pointerUV → 이펙트 유니폼 g_PointerPosition"),
                    specfmt.ev("file", "Sources/WapleCompatCore/SnapshotPipeline.swift:249-264",
                               "핀 목록에 포인터가 없다")]),

        # 2026-08-16: 포인터 핀 이후에도 남은 잔여분. 위 항목들과 달리 이 값은 nondet-2026-08-01
        # 캡처 세트에서 나오지 않는다 — 아래 수치는 probe-scene-repeat.sh(+ 일회성 렌더 계측)의
        # 실측이라 여기 상수로 박아 둔다. 다시 재려면 그 스크립트를 돌릴 것.
        specfmt.entry("oracle.nondet.meshMipLodResidual", {
            "what": "포인터 핀(oracle.nondet.rootCause) 이후에도 남는 비결정이 있고, 그것은 "
                    "**3D 메시 패스의 mip 보간**에서 나온다. 측정 대상은 재베이스라인을 막고 있던 "
                    "3706286085 한 종이다 — 불안정 29종의 나머지는 이 항목으로 다시 재지 않았다",
            "rate": {
                "crossProcess": "같은 빌드로 별도 프로세스 6회 캡처 → 해시 3종"
                                "(5d0f07a9a18cb886 ×4 / f112326396c7cf37 / 13fcdfb5354c1c3)",
                "sameProcess": "매니페스트 selfMaxDiff(같은 프로세스 두 마운트의 최대차)가 6회 중 4회 "
                               "비영(0,3,0,2,3,3) — 프로세스 간만이 아니라 **마운트 간**에도 흔들린다",
                "sameMount": "같은 마운트에서 같은 t 를 20회 재렌더해도 흔들린다"
                             "(FBX_Stage 만 그릴 때 40회 중 14회 상이) — 캡처 프로세스/마운트를 "
                             "고정해도 남는다",
                "magnitude": "화면 36,864 픽셀 중 1~14 픽셀, 채널당 최대 3. "
                             "meanLuma 는 소수 6자리까지 동일(0.262582)",
            },
            "locus": {
                "pass": "3D 메시 드로우. 메시 드로우만 건너뛰면 별도 프로세스 5회가 전부 "
                        "비트동일(selfMaxDiff 0/5)",
                "renderable": "meshRenderables[1] = FBX_Stage(u32 인덱스 43 서브메시). 다른 렌더어블만 "
                              "그리면(0=Sky 단독, 2·3=RioSonic+BoostModel1, 4~8) 각각 5회 전부 "
                              "비트동일이고, FBX_Stage 단독은 5회에 해시 2종이 나온다",
                "minimalRepro": "FBX_Stage 서브메시 37 단독 = 재렌더 39회 전부 동일, 38 단독 = 39회 전부 "
                                "동일, **37+38 동시 = 39회 중 35회 상이**(픽셀 (50,73) 하나, R 채널 ±1). "
                                "37 은 그 픽셀을 아예 덮지 않는다"
                                "(단독 렌더 시 클리어색, 깊이 = 클리어값 0x3F800000)",
            },
            "carrier": {
                "what": "Mesh3DShaders 의 알베도 샘플러 `mip_filter::linear`(3중선형 보간)이 "
                        "유일한 전달 경로다",
                "measurement": "`mip_filter::linear` → `mip_filter::nearest` 로 바꾸면 전 씬 캡처 8회가 "
                               "**해시 1종 · selfMaxDiff 0/8**(= 16 렌더 전부 비트동일). "
                               "최소 재현(37+38)도 39/39 동일",
                "reading": "LOD 의 소수부(두 mip 레벨 사이 보간 가중치)가 제출마다 같은 값으로 "
                           "재현되지 않는다. 정수 레벨만 쓰면 그 흔들림이 픽셀에 도달하지 못한다",
                "caution": "nearest 로 바꾸면 픽셀이 달라진다(해시 d371c607628c290e) — 이건 "
                           "**원인 규명용 측정**이지 채택된 수정이 아니다",
                "canonSettled": "WE 의 mip 필터 규약은 이제 정본에 있다 — "
                                "textureFiltering.mipAxis.linearUnlessFullPoint. "
                                "WE 가 만드는 Filter 는 네 값뿐이고 mip 축만 POINT 로 "
                                "내리는 조합(MIN_MAG_LINEAR_MIP_POINT)이 없다. "
                                "이 씬의 모델 텍스처는 nointerpolation 이 아니므로 WE 는 "
                                "mip 을 선형 보간한다(textureFiltering.probeScene."
                                "modelTextures). **따라서 nearest 는 채택할 수 없다** — "
                                "비결정 수정은 mip_filter::linear 를 유지한 채 이뤄져야 한다",
            },
            "eliminated": {
                "what": "GPU 에 들어가는 입력은 전부 비트동일함을 실측으로 확인했다 — "
                        "CPU 측에는 흔들릴 것이 남아 있지 않다",
                "cpuInputs": "5 프로세스 × 2 마운트에서 viewProj · 노드 월드행렬 17개 · "
                             "Scene3DFrameUniform · 라이트 유니폼 · 섀도우 VP 48개 · 드로우콜별 "
                             "MeshUniform 과 파이프라인 플래그(130줄) · 메시 정점/인덱스 버퍼 · "
                             "텍스처 내용(**모든 mip 레벨**, WAPLE_BC_NATIVE=0 로 rgba8 복호해 판독) "
                             "전부 해시 동일",
                "depthBuffer": "깊이 버퍼 전체가 12 렌더에서 비트동일(1eb836ebae51b7d2) — "
                               "깊이 테스트 승자가 갈리는 것이 아니라 **이긴 표면의 색**이 갈린다",
                "passes": "섀도우 아틀라스 비트동일(de6b3764ffe22325, 8 마운트) · 섀도우를 꺼도 재현 · "
                          "파티클/빌보드/블룸/번역 이펙트를 각각 꺼도 재현 · finalizeScene 은 이 씬에서 "
                          "항등(3D 패스 출력 = 최종 출력)",
                "knobs": "3D 패스 뎁스 storeAction 을 .store 로 강제해도 재현(8회 해시 3종) · "
                         "풀 텍스처를 할당 직후 0으로 채워도 재현(8회 해시 3종)",
                "validation": "MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 로 떠도 위반 0건 — "
                              "범위 밖 접근이나 미바인딩이 아니다",
                "dictionaryOrder": "딕셔너리/집합 순회 순서는 원인이 아니다. Swift 의 해시 시드는 "
                                   "**프로세스 수명 동안 고정**이라 같은 프로세스 안 두 마운트가 갈리는 "
                                   "것을 설명하지 못하고, 실제로 위 CPU 입력 해시가 전부 동일하다. "
                                   "렌더 순서에 정렬을 넣는 수정은 이 결함에 무효다",
            },
            "consequence": "rebaseline-golden.sh 의 '전 씬 비트동일' 게이트는 이 씬에서 실행마다 "
                           "50~80% 확률로 걸린다. 게이트를 약화하는 것과 렌더 출력을 바꾸는 것"
                           "(mip 필터) 중 하나를 고르기 전에는 재베이스라인이 확률에 기댄다",
            "crossRef": "oracle.nondet.rootCause",
        }, "확정", [specfmt.ev("script", "scripts/mac-session/probe-scene-repeat.sh",
                               "씬 1종을 별도 프로세스로 N회 떠서 해시 종수·selfMaxDiff 재현률을 낸다"),
                    specfmt.ev("file", "Sources/WapleRender/Mesh3DShaders.swift:482",
                               "mf_main 의 알베도 샘플러 선언 — mip_filter::linear(전달 경로)"),
                    specfmt.ev("file", "Sources/WapleRender/SceneRenderer3D.swift:1548",
                               "encode3D 의 draw3DOrder 루프 — 흔들리는 드로우가 사는 곳(FBX_Stage)")]),
    ]

    specfmt.dump(specfmt.doc("scripts/spec/measure_nondeterminism.py", entries),
                 os.path.join("spec", "golden", "nondeterminism.json"))

    print(f"캡처 {len(caps)}개 · 씬 {len(ids)}종")
    print(f"  세션 내 대조 {len(within)}쌍 → 전부 0종 (음성 대조 통과)")
    print(f"  세션 간 불안정: {len(unstable)}종 (양성 대조 통과)")
    print(f"    서로 다른 값 개수 분포: {hist}")
    print(f"    셀프체크가 deterministic=true 로 기록한 것: {len(misreported)}종")
    print(f"    정렬 인덱스 범위: {min(idx[u] for u in unstable)}~{max(idx[u] for u in unstable)} / {len(ids)}")
    print(f"  mip 영향권 {len(mip_affected)}종 중 불안정 {len([u for u in unstable if u in mip_affected])}종 "
          f"· 영향권 밖 불안정 {len([u for u in unstable if u not in mip_affected])}종")


if __name__ == "__main__":
    main()
