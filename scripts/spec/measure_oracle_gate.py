"""골든 회귀 게이트의 실효성을 측정한다.

배경: 커밋된 기준선(spec/golden/snapshot/)이 안전망 역할을 하려면 게이트가 실제로
변화를 잡아야 한다. 적대적 검증에서 "게이트가 무력하다"는 주장이 나왔고, 코디네이터가
코드로 확인한 결과 두 가지가 사실이었다:

1. SnapshotCompare 가 매니페스트의 hash / meanLuma / selfMaxDiff 를 **한 번도 읽지 않는다**
   (deterministic 만 임계 선택에 쓴다). 세 필드는 기록만 되고 판정에 안 들어간다.
2. strict 임계가 **절대 단위**(meanAbsDiff 1.5 / 255)라 어두운 씬일수록 느슨해진다.
   meanLuma 0.0021 인 씬은 전면 검정으로 바꿔도 평균 절대차가 1.5 를 못 넘는다.

이 스크립트는 커밋된 기준선의 meanLuma 분포로 **씬별 게이트 여유(headroom)** 를 계산해
어느 씬이 사실상 무방비인지 정량화한다.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

BASELINE = os.path.join("spec", "golden", "snapshot", "baseline-81098bb", "manifest.json")

# Sources/WapleSnapshot/Snapshot.swift:113-117
STRICT_MEAN = 1.5          # /255
STRICT_FRAC = 0.004
LAX_MEAN = 14.0
LAX_FRAC = 0.20


def main():
    with open(BASELINE, encoding="utf-8") as fh:
        m = json.load(fh)
    entries = m["entries"]

    # 씬 전체를 검정으로 바꿨을 때의 평균 절대차 상한 근사 = meanLuma * 255.
    # 이 값이 임계보다 작으면 "전면 검정" 이라는 최대 파괴도 게이트를 통과한다.
    blind = []
    for e in entries:
        thr = STRICT_MEAN if e.get("deterministic") else LAX_MEAN
        blackout = e["meanLuma"] * 255.0
        if blackout <= thr:
            blind.append({
                "id": e["id"],
                "meanLuma": round(e["meanLuma"], 5),
                "blackoutMeanDiff": round(blackout, 3),
                "threshold": thr,
            })
    blind.sort(key=lambda x: x["meanLuma"])

    lumas = sorted(e["meanLuma"] for e in entries)
    ev = specfmt.ev("file", BASELINE.replace(os.sep, "/"),
                    "커밋된 기준선 170종의 meanLuma 분포")
    code_ev = specfmt.ev("file", "Sources/WapleCompat/SnapshotCompare.swift:81-82",
                         "entry.deterministic 만 읽는다. hash/meanLuma/selfMaxDiff 참조 0건")

    entries_out = [
        specfmt.entry("oracle.gate.unusedManifestFields", {
            "recorded": ["hash", "meanLuma", "selfMaxDiff"],
            "readBySnapshotCompare": ["deterministic"],
            "consequence": "세 필드는 기록만 되고 판정에 안 들어간다. "
                           "hash 로 '픽셀 동일' 을 즉시 판정할 수 있는데 매번 diff 를 돌린다.",
        }, "확정", [code_ev]),

        specfmt.entry("oracle.gate.thresholds", {
            "strict": {"meanAbsDiff": STRICT_MEAN, "fracExceeding": STRICT_FRAC},
            "lax": {"meanAbsDiff": LAX_MEAN, "fracExceeding": LAX_FRAC},
            "unit": "0..255 절대값",
            "flaw": "절대 단위라 어두운 씬일수록 실효 게이트가 느슨해진다. "
                    "상대(대비 정규화) 지표가 없다.",
        }, "확정", [specfmt.ev("file", "Sources/WapleSnapshot/Snapshot.swift:113-117")]),

        specfmt.entry("oracle.gate.blindScenes", {
            "definition": "전면 검정으로 바꿔도 strict/lax 평균 임계를 통과하는 씬 "
                          "(meanLuma × 255 <= threshold)",
            "count": len(blind),
            "scenes": blind,
        }, "확정", [ev, specfmt.ev("file", "Sources/WapleSnapshot/Snapshot.swift:113-117",
                                   "임계값 출처")]),

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
            "empiricalClaimDidNotReproduce": {
                "firstObservation": "macOS 2026-08-01 검증 세션 — 같은 커밋·같은 빌드 전 코퍼스 "
                                    "2회 캡처에서 **29종이 달랐다**고 보고됨. "
                                    "3696323523 은 단일씬 재캡처로 커밋 무관까지 격리 확인.",
                "controlledProbe": "같은 날 probe-nondeterminism.sh 로 별도 프로세스 2회 캡처 "
                                   "(runA/runB, 각 170종, 각 ~165초) → **차이 0종**.",
                "status": "재현 실패. 29 라는 수치를 정본으로 쓰면 안 된다.",
                "whatThisDoesAndDoesNotMean": "0/170 은 '결정적임' 의 증명이 아니라 "
                                              "'이번엔 발현하지 않았다' 이다. 반대로 첫 관측도 "
                                              "취소되지 않는다 — 둘을 합치면 **간헐적**이라는 뜻이고, "
                                              "간헐적 비결정은 진단이 더 어렵지 더 쉬운 게 아니다.",
                "leadingHypothesis": "두 관측의 환경 차이가 후보다. 첫 관측은 전 스위트 실행 "
                                     "직후의 캡처였고 프로브는 유휴 상태 연속 2회였다. "
                                     "전 코퍼스 캡처는 170씬을 **한 프로세스에서 순차 마운트**하므로 "
                                     "메모리/GPU 상태 압력에 따라 씬 간 상태 누수가 달라질 수 있다.",
                "discriminatingNextStep": "프로브 실행 순서를 바꿔 runB 직전에 "
                                          "`swift test -c release` 전 스위트를 끼워 넣고 재실행. "
                                          "29 가 재등장하면 부하/상태 의존으로 확정된다.",
            },
            "retractedConsequence": "이 항목이 처음에 '골든 변화 123종 중 29종이 비결정 오염' 이라고 "
                                    "적었는데 그 귀속은 **근거가 없어졌다**. 같은 이유로 "
                                    "3696323523(기대 집합 밖 1종)을 '비결정' 으로 닫은 것도 "
                                    "재개해야 한다 — 간헐적일 뿐 설명된 게 아니다.",
            "consequence": "골든 대조의 '변화 N종' 에 실행 간 잡음이 섞일 수 있다. "
                           "다만 그 규모는 미정이다 — 아래 empiricalClaimDidNotReproduce 참조.",
            "thresholdMisclassification": {
                "code": "SnapshotCompare.swift:85 — `entry.deterministic ? .strict : .lax`",
                "designIsCorrect": "결정적 씬에 strict, 비결정 씬에 lax 는 **의도대로 맞다**. "
                                   "극성을 뒤집으면 안 된다.",
                "actualDefect": "그 29종이 deterministic=true 로 **잘못 분류**되는 바람에 "
                                "비결정 씬인데 strict 로 샌다. 고칠 곳은 임계 선택줄이 아니라 "
                                "분류(셀프체크)다.",
                "correctionNote": "[정정 2026-08-01] 이 항목은 처음에 '방향이 반대다' 라고 "
                                  "적혀 있었다. 틀렸다 — 그대로 믿고 :85 를 뒤집으면 "
                                  "정상 동작을 깨뜨린다.",
            },
            "isolationEvidence": "3696323523: 단일씬 재캡처는 커밋 전후가 동일했고, "
                                 "전체 코퍼스 캡처는 같은 빌드 2회가 서로 달랐다 — "
                                 "커밋 무관, 실행 간 변동으로 격리 확인.",
            "fixDirection": "셀프체크를 **별도 프로세스**에서 돌리거나, 매니페스트에 "
                            "'교차 실행 재현성' 을 별도 필드로 둔다. 지금 필드는 이름과 달리 "
                            "'같은 프로세스 안에서 두 번 그리면 같은가' 만 답한다.",
            "lesson": "필드 이름이 약속하는 것('재현 가능한가')과 코드가 재는 것('같은 프로세스 "
                      "안에서 두 번 그리면 같은가')이 다르다 — 이 저장소에서 반복돼 온 실패 모양이다. "
                      "다만 이번엔 **피해 규모를 아직 못 재고 있다**: 구조적 맹점은 확실한데 "
                      "그 맹점을 통과하는 실제 변동이 얼마나 되는지는 재현에 실패했다. "
                      "'안전망이 무력했다' 와 '무력한 안전망을 통과한 사고가 있었다' 는 다른 주장이고, "
                      "지금 증명된 것은 앞엣것뿐이다.",
        }, "확정", [specfmt.ev("file", "Sources/WapleCompat/SnapshotPipeline.swift:187-198",
                               "2차 캡처가 같은 프로세스"),
                    specfmt.ev("file", "Sources/WapleCompat/SnapshotCompare.swift:85",
                               "deterministic 으로 임계 선택"),
                    specfmt.ev("file", "macOS 세션 2026-08-01 — 같은 빌드 2회 캡처 대조 29종")]),

        specfmt.entry("oracle.gate.lumaDistribution", {
            "n": len(lumas),
            "min": round(lumas[0], 5),
            "p05": round(lumas[len(lumas) // 20], 5),
            "median": round(lumas[len(lumas) // 2], 5),
            "max": round(lumas[-1], 5),
        }, "확정", [ev]),
    ]

    specfmt.dump(specfmt.doc("scripts/spec/measure_oracle_gate.py", entries_out),
                 os.path.join("spec", "golden", "gate-analysis.json"))

    print(f"기준선 {len(entries)}종")
    print(f"  meanLuma  min {lumas[0]:.5f} / median {lumas[len(lumas)//2]:.5f} / max {lumas[-1]:.5f}")
    print(f"  전면 검정도 통과하는 무방비 씬: {len(blind)}종")
    for b in blind:
        print(f"    {b['id']:12} meanLuma={b['meanLuma']:.5f}  "
              f"검정시 평균차={b['blackoutMeanDiff']:.2f} <= 임계 {b['threshold']}")


if __name__ == "__main__":
    main()
