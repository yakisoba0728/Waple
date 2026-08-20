#!/usr/bin/env python3
"""직교투영 분기의 근거 수치를 **강제되는 불변식**으로 못박는다.

## 왜 있나

파티클 주입기 아홉 개가 상수를 ortho/원근으로 가른다. 어느 쪽을 채택하느냐가 곧 화면이라
그 선택의 근거는 "실물 씬의 몇 %가 ortho 인가" 하나뿐이다. 그런데 그 수치가 주석 안에서
**세 가지 값으로 갈라져 돌아다녔다** — `343/347 = 98.8%`, `347/355`, 그리고 그 둘을 섞은
`347/355 = 98.8%`(산술도 틀렸다: 347/355 = 97.7%). 근거가 주석에만 있으면 이렇게 된다.

## 판정 규칙 (실물 게이트를 그대로 옮긴 것)

`general.orthogonalprojection` 을 읽어 엔진 오브젝트 `[+0x118]` 의 bit10 을 세운다:

```
0x1401874ed  lea rdx, "orthogonalprojection"
0x1401874fe  cmp byte [rax+8], 7      ; jsoncpp 태그 7 = objectValue. 아니면 통째로 건너뜀
0x140187512  lea rdx, "auto"
0x140187550  cmp byte [rdi+8], 5      ; 태그 5 = booleanValue
0x14018755c  call asBool → test al,al
0x140187565  or dword [r14+0xe0], 0x18   ; auto == true
0x1401875df  or dword [r14+0xe0], 8      ; 아니면 width·height 경로
0x14018768a  or dword [r13+0x118], 0x400 ; 최종 bit10
```

**객체가 아니면 탈락**한다 — 문자열 `"auto"` 는 통하지 않는다. `auto` 도 **불이어야** 하고,
아니면 width/height 경로로 내려간다. 키가 아예 없으면 비트는 0 = **원근**이다.

## 무엇을 검사하나

1. 동봉 트리의 ortho/원근 도수가 기록된 값과 같은가
2. **원근 씬 중 조건부 상수를 쓰는 오퍼레이터를 가진 것이 없는가** — 이게 진짜 근거다.
   "97.7% 니까 ortho 를 고른다" 보다 "원근 분기를 타는 씬은 그 상수를 아예 안 쓴다" 가 강하다.
   이 불변식이 깨지면 그 씬에서는 ortho 상수가 **틀린 값**이 된다.
3. 판정 함수 자체의 음성 대조(문자열 `"auto"`·비-불 `auto`·객체 아님이 전부 탈락하는가)
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
ASSETS = os.path.join(REPO, "Sources", "WapleRender", "Resources", "WEAssets")

# 2026-08-20 실측(동봉 트리). 자산이 늘면 함께 올리고 커밋에 사유를 남길 것.
EXPECT_ORTHO = 169
EXPECT_PERSPECTIVE = 2
# 원근으로 판정되는 씬. 둘 다 에디터용 합성 씬이다.
EXPECT_PERSPECTIVE_SCENES = {
    "scenes/modeleditor/scene.json",
    "scenes/particleeditor3dscale/scene.json",
}

# 주입 상수가 ortho/원근으로 갈리는 오퍼레이터. 원근 씬이 이걸 쓰면 채택한 ortho 상수가 틀린다.
CONDITIONAL_OPERATORS = {
    "vortex", "vortex_v2", "controlpointattract", "turbulence", "boids",
    "maintaindistancetocontrolpoint", "reducemovementnearcontrolpoint",
}
CONDITIONAL_EMITTERS = {"boxrandom", "sphererandom"}
CONDITIONAL_INITIALIZERS = {"turbulentvelocityrandom"}


def is_ortho(general):
    """실물 게이트를 그대로 옮긴 판정. 위 doc 주석의 VA 참조."""
    op = (general or {}).get("orthogonalprojection")
    if not isinstance(op, dict):          # 태그 7(objectValue) 이 아니면 탈락
        return False
    auto = op.get("auto")
    if isinstance(auto, bool) and auto:   # 태그 5(booleanValue) 이고 참
        return True
    try:
        w = float(op.get("width") or 0)
        h = float(op.get("height") or 0)
    except (TypeError, ValueError):
        return False
    return w != 0 and h != 0


def scene_files():
    for dirpath, _dirs, files in os.walk(ASSETS):
        if "scene.json" in files:
            p = os.path.join(dirpath, "scene.json")
            yield p, os.path.relpath(p, ASSETS).replace(os.sep, "/")


def particle_refs(doc):
    out = set()

    def walk(x):
        if isinstance(x, dict):
            for k, v in x.items():
                if k == "particle" and isinstance(v, str):
                    out.add(v)
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)

    walk(doc)
    return out


def conditional_elements(particle_doc):
    hits = set()
    for key, names in (("operator", CONDITIONAL_OPERATORS),
                       ("initializer", CONDITIONAL_INITIALIZERS),
                       ("emitter", CONDITIONAL_EMITTERS)):
        for e in (particle_doc.get(key) or []):
            if isinstance(e, dict) and str(e.get("name", "")).lower() in names:
                hits.add(str(e.get("name")).lower())
    return hits


def selftest():
    """판정 함수의 음성 대조 — 통과하면 안 되는 것들이 정말 탈락하는가."""
    bad = []
    cases = [
        ({"orthogonalprojection": "auto"}, False, '문자열 "auto" 는 객체가 아니라 탈락'),
        ({"orthogonalprojection": {"auto": "true"}}, False, "auto 가 불이 아니면 탈락"),
        ({"orthogonalprojection": {"auto": 1}}, False, "정수 1 도 불이 아니다"),
        ({"orthogonalprojection": {"auto": False}}, False, "auto=false 는 width/height 로"),
        ({"orthogonalprojection": {"auto": True}}, True, "auto=true 는 ortho"),
        ({"orthogonalprojection": {"width": 1920, "height": 1080}}, True, "wh 비영이면 ortho"),
        ({"orthogonalprojection": {"width": 1920, "height": 0}}, False, "한쪽이 0 이면 탈락"),
        ({}, False, "키 부재는 원근"),
        (None, False, "general 부재는 원근"),
    ]
    for general, want, why in cases:
        got = is_ortho(general)
        if got != want:
            bad.append(f"selftest: {why} — 기대 {want}, 실제 {got}")
    return bad


def main():
    fails = list(selftest())
    if fails:
        for f in fails:
            print("  X " + f)
        print("[ortho-census] 판정 함수 자체가 틀렸다 — 도수 검사는 무의미하므로 중단한다")
        return 1
    print("  . selftest 9건 통과")

    if not os.path.isdir(ASSETS):
        print(f"[ortho-census] 동봉 자산이 없다: {ASSETS}")
        return 1

    ortho, perspective = [], []
    for path, rel in scene_files():
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                doc = json.load(fh)
        except (OSError, ValueError) as exc:
            fails.append(f"scene.json 파스 실패: {rel} ({exc})")
            continue
        (ortho if is_ortho(doc.get("general")) else perspective).append((rel, doc, path))

    n = len(ortho) + len(perspective)
    pct = (len(ortho) / n * 100) if n else 0
    print(f"  . 동봉 scene.json {n}건 — ortho {len(ortho)} / 원근 {len(perspective)} ({pct:.1f}% ortho)")

    if len(ortho) != EXPECT_ORTHO or len(perspective) != EXPECT_PERSPECTIVE:
        fails.append(f"도수가 기록과 다르다: ortho {len(ortho)}(기대 {EXPECT_ORTHO}) · "
                     f"원근 {len(perspective)}(기대 {EXPECT_PERSPECTIVE}). "
                     "자산이 바뀌었으면 EXPECT_* 를 올리고 커밋에 사유를 남겨라.")

    got_names = {rel for rel, _doc, _p in perspective}
    if got_names != EXPECT_PERSPECTIVE_SCENES:
        fails.append(f"원근 씬 목록이 다르다: {sorted(got_names)} vs {sorted(EXPECT_PERSPECTIVE_SCENES)}")

    # 진짜 근거: 원근 씬이 조건부 상수 원소를 쓰지 않는다.
    for rel, doc, path in perspective:
        base = os.path.dirname(path)
        for ref in sorted(particle_refs(doc)):
            fp = os.path.join(base, ref)
            if not os.path.isfile(fp):
                continue
            try:
                with open(fp, encoding="utf-8", errors="replace") as fh:
                    pdoc = json.load(fh)
            except (OSError, ValueError):
                continue
            hits = conditional_elements(pdoc)
            if hits:
                fails.append(
                    f"원근 씬 {rel} 의 {ref} 가 조건부 상수 원소를 쓴다: {sorted(hits)} — "
                    "그 씬에서는 채택한 ortho 상수가 **틀린 값**이다. 분기를 씬별로 넘겨야 한다.")
    if not any("원근 씬" in f and "조건부" in f for f in fails):
        print("  . 원근 씬 어느 것도 조건부 상수 원소를 쓰지 않는다 — ortho 채택이 전건 안전")

    print()
    if fails:
        print(f"[ortho-census] 실패 {len(fails)}건")
        for f in fails:
            print("  X " + f)
        return 1
    print("[ortho-census] 통과")
    return 0


if __name__ == "__main__":
    sys.exit(main())
