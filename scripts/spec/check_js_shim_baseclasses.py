#!/usr/bin/env python3
"""JS 심이 동봉 `baseclasses.js` 와 **공존 가능한지** 본다.

왜 있는가
---------
WE 원본 `scripts/jsclasses/baseclasses.js` 는 `Vec2`/`Vec3`/`Vec4`/`Mat3`/`Mat4`/
`MediaPlaybackEvent` 를 `class` 로 선언한다 = 전역 **렉시컬** 바인딩이다.
심이 같은 이름을 `function` 으로 선언하면(= var 선언) 같은 JSContext 에서 공존할 수 없고,
어느 쪽을 먼저 평가하든 **두 번째 스크립트가 통째로** 죽는다:

    SyntaxError: Identifier 'Vec3' has already been declared

한 문장이 아니라 스크립트 전체가 죽는 것이라, 그 컨텍스트의 모든 씬 스크립트가 함께
사라진다. 그래서 baseclasses 로더를 켜기 전에 이 조건을 **정적으로** 잠가 둔다.

무엇을 보는가
-------------
`TextScriptEngine.swift` 의 `static let shims` 리터럴을 그대로 뽑아 node vm 에서 돌린다.
1) 심 단독으로 예외 없이 평가되고, 공개 표면(아래 PROBES)이 기대대로다.
2) `baseclasses.js` 를 **먼저** 로드한 뒤 심을 평가해도 예외가 없다.
3) 그 조합에서 **Waple 이 소유해야 하는 것이 이긴다** — `shared.camera` 가 살아 있고,
   `createScriptProperties` 는 `_config` 키를 만들지 않으며, `MediaPlaybackEvent` 는
   필드를 받는다(WE 클래스는 정적 상수 3개뿐이라 `{}` 가 된다).
4) 그 조합에서 **WE 가 소유해야 하는 것이 들어온다** — `Vec4`/`Mat3`/`Mat4`.

이건 리눅스 레인에서 끝낼 수 있다. JSC 가 `evaluateScript` 사이에 전역 렉시컬 환경을
공유하는지는 V8 로 확인할 수 없으므로 그것만 macOS 테스트가 본다(WEBaseClasses 인터롭).

음성 대조
---------
`--selftest` 가 **심을 옛 형태로 되돌린 사본**을 만들어 (2)가 실제로 SyntaxError 를 내는지
확인한다. 검사가 실제로 잡는지 확인하지 않으면 "검사하는 척하는 검사" 가 된다.
"""
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SWIFT = REPO / "Sources/WapleRender/TextScriptEngine.swift"
BASECLASSES = REPO / "Sources/WapleRender/Resources/WEAssets/scripts/jsclasses/baseclasses.js"

PROBES = [
    "typeof Vec2", "typeof Vec3", "Vec3.name", "Vec2.name",
    "JSON.stringify(new Vec3(0.5))", "JSON.stringify(new Vec2(1920,1080))",
    "typeof new Vec3(1,2,3).normalize",
    "JSON.stringify(new MediaPlaybackEvent({state:2}))",
    "MediaPlaybackEvent.PLAYBACK_PAUSED",
    "typeof shared.camera", "typeof createScriptProperties",
    "JSON.stringify(createScriptProperties().addSlider({name:'s',value:7}).finish())",
    "typeof thisScene", "typeof engine", "typeof thisLayer",
]
# 심 단독·조합 양쪽에서 같아야 하는 값(= Waple 소유 표면).
EXPECT_BOTH = {
    "typeof Vec2": "function", "typeof Vec3": "function",
    "Vec3.name": "Vec3", "Vec2.name": "Vec2",
    "JSON.stringify(new Vec3(0.5))": '{"x":0.5,"y":0.5,"z":0.5}',
    "JSON.stringify(new Vec2(1920,1080))": '{"x":1920,"y":1080}',
    "typeof new Vec3(1,2,3).normalize": "function",
    "JSON.stringify(new MediaPlaybackEvent({state:2}))": '{"state":2}',
    "MediaPlaybackEvent.PLAYBACK_PAUSED": "2",
    "typeof shared.camera": "object",
    "typeof createScriptProperties": "function",
    "JSON.stringify(createScriptProperties().addSlider({name:'s',value:7}).finish())": '{"s":7}',
    "typeof thisScene": "object", "typeof engine": "object", "typeof thisLayer": "object",
}

COMBO_ONLY = ["typeof Vec4", "typeof Mat3", "typeof Mat4"]

DRIVER = r"""
import fs from 'node:fs';
import vm from 'node:vm';
const shim = fs.readFileSync(process.argv[2], 'utf8');
const base = process.argv[3] ? fs.readFileSync(process.argv[3], 'utf8') : null;
const probes = JSON.parse(fs.readFileSync(process.argv[4], 'utf8'));
const ctx = vm.createContext({ console });
let err = null;
try {
  if (base) vm.runInContext(base, ctx, { filename: 'baseclasses.js' });
  vm.runInContext(shim, ctx, { filename: 'shim.js' });
} catch (e) { err = String(e); }
const r = {};
for (const p of probes) {
  try { r[p] = String(vm.runInContext(p, ctx)); } catch (e) { r[p] = 'THROW ' + e.message; }
}
console.log(JSON.stringify({ err, r }));
"""


def extract_shim(swift_text):
    """Swift 멀티라인 리터럴 → 평문 JS. 닫는 `\"\"\"` 의 들여쓰기(4칸)만큼 각 줄에서 뺀다."""
    m = re.search(r'static let shims = """\n(.*?)\n    """', swift_text, re.S)
    if not m:
        raise SystemExit("[js-shim] TextScriptEngine.swift 에서 `static let shims` 리터럴을 못 찾았다")
    body = m.group(1)
    text = "\n".join(l[4:] if l.startswith("    ") else l for l in body.split("\n"))
    if "\\(" in text:
        raise SystemExit("[js-shim] 심 리터럴에 문자열 보간이 생겼다 — 정적 추출이 불가능해진다")
    return text.replace("\\\\", "\\")


def run(shim_text, with_baseclasses, workdir, probe_list=None):
    shim = workdir / "shim.js"
    shim.write_text(shim_text, encoding="utf-8")
    drv = workdir / "drv.mjs"
    drv.write_text(DRIVER, encoding="utf-8")
    probes = workdir / "probes.json"
    probes.write_text(json.dumps(probe_list if probe_list is not None else PROBES), encoding="utf-8")
    base = str(BASECLASSES) if with_baseclasses else ""
    out = subprocess.run(["node", str(drv), str(shim), base, str(probes)],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit("[js-shim] node 실행 실패:\n" + out.stderr[-2000:])
    return json.loads(out.stdout)


def check(shim_text, workdir, strict=True):
    bad = []
    alone = run(shim_text, False, workdir)
    if alone["err"]:
        bad.append("심 단독 평가가 실패한다: %s" % alone["err"])
    combo = run(shim_text, True, workdir)
    if combo["err"]:
        bad.append("baseclasses 를 먼저 로드하면 심이 죽는다: %s" % combo["err"])
    if not strict:
        return bad, alone, combo
    for k, want in EXPECT_BOTH.items():
        for tag, res in (("심 단독", alone), ("baseclasses+심", combo)):
            if res["err"]:
                continue
            got = res["r"].get(k)
            if got != want:
                bad.append("%s: `%s` 가 %r 인데 %r 를 기대했다" % (tag, k, got, want))
    # WE 소유 표면은 조합에서만 의미가 있다(심 단독에서는 undefined 가 정상).
    if not combo["err"]:
        we = run(shim_text, True, workdir, COMBO_ONLY)["r"]
        for k in COMBO_ONLY:
            if we.get(k) != "function":
                bad.append("baseclasses+심: `%s` 가 %r — WE 클래스가 안 들어왔다" % (k, we.get(k)))
    return bad, alone, combo


def main():
    if shutil.which("node") is None:
        print("[js-shim] node 가 없다 — 검사 생략", file=sys.stderr)
        return 0
    shim_text = extract_shim(SWIFT.read_text(encoding="utf-8"))
    if not BASECLASSES.is_file():
        print("[js-shim] %s 가 없다 — 검사 생략" % BASECLASSES, file=sys.stderr)
        return 0

    with tempfile.TemporaryDirectory() as td:
        wd = Path(td)
        # 음성 대조: 옛 형태(공개 이름으로 직접 선언)로 되돌리면 (2)가 반드시 깨져야 한다.
        legacy = shim_text.replace("function __WapleVec3(", "function Vec3(") \
                          .replace("function __WapleVec2(", "function Vec2(")
        if legacy != shim_text:
            bad, _, combo = check(legacy, wd, strict=False)
            if not combo["err"]:
                print("[js-shim] selftest 실패: 옛 형태인데도 충돌이 안 잡힌다 — 검사가 무력하다",
                      file=sys.stderr)
                return 1
            print("selftest: OK (%s)" % combo["err"].split(":")[0])
        else:
            print("selftest: 건너뜀 — 심이 이미 옛 형태이거나 별칭명이 바뀌었다", file=sys.stderr)

        bad, _alone, _combo = check(shim_text, wd)

    for b in bad:
        print("  " + b)
    if bad:
        print("\nJS 심/baseclasses 공존 위반 %d건. SyntaxError 는 한 문장이 아니라 "
              "**스크립트 전체**를 죽인다 — 그 컨텍스트의 씬 스크립트가 전부 사라진다." % len(bad),
              file=sys.stderr)
        return 1
    print("JS 심 ↔ baseclasses: 공존 OK · Waple 소유 표면 %d건 유지 · WE Vec4/Mat3/Mat4 도달"
          % len(EXPECT_BOTH))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
