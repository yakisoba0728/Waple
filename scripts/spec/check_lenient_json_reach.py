#!/usr/bin/env python3
"""자산 JSON 관용 파스의 **도달**을 못박는다 — 그리고 리더가 실제로 그 경로를 타는지 본다.

왜 있는가
---------
WE 는 jsoncpp 를 쓰고 `allowComments`/`allowTrailingCommas` 를 **둘 다 켠다**(0x140091fe2 ·
0x1400920b3). 관용은 이펙트 매니페스트만의 성질이 아니라 **WE 가 읽는 모든 JSON 의 성질**이고,
WE 자기 자산이 실제로 그 관용에 의존한다.

종전 Waple 은 `EffectManifest.parse` 만 관용이었다. 그래서 머티리얼·모델·씬·프로젝트 리더가
맨 `JSONSerialization` 이었고 **동봉 기본 프로젝트에서 실제로 깨졌다**:

    projects/defaultprojects/fantasticcar/materials/car/glass.json:6   //"cullmode": "nocull",
    assets/presets/water/preset.json:55                                트레일링 콤마

`models/car/body.mdl` 이 `car/glass` 를 머티리얼 문자열로 담으므로, 엄격 파스 실패는 그 메시의
textures·blending·constantshadervalues 를 통째로 날린다.

이 게이트가 잡는 것
-------------------
A. **도달 실측** — 두 트리에서 엄격 파스에 실패하는 JSON 을 세고, 그 전부가 관용으로 복구되는지
   확인한다. 하한을 둬서 측정이 조용히 0건이 되는 것을 막는다.
B. **배선 확인** — 자산 리더가 `AssetJSON` 을 타는지. 관용 파서가 있어도 리더가 안 부르면
   아무 일도 안 일어난다(함정 ③: 주입 ≠ 소비). 실제로 그 상태였다.
C. **회귀 방향** — 관용이 문자열 리터럴 안을 건드리지 않는지. 그쪽이 훨씬 나쁜 회귀다.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
# 자산 트리만 본다. 설치본의 `ui/` 는 WE UI(Chromium) 캐시라 벽지 자산이 아니고,
# 그 안에 루트 뒤 추가 데이터를 가진 JSONL(`FirstPartySetsPreloaded/*/sets.json`)이 있어
# 관용 파스로도 안 읽힌다 — 읽을 이유도 없다. 범위를 명시적으로 좁힌다.
_INSTALL = pathlib.Path("/home/user/Waple-wallpaper-source/wallpaper_engine")
TREES = [ROOT / "Sources/WapleRender/Resources/WEAssets",
         _INSTALL / "assets", _INSTALL / "projects"]

MIN_LENIENT_NEEDED = 30      # 실측: 자산 트리 기준. 하한을 둬서 측정이 조용히 0건이 되는 것을 막는다.
# 트리 루트가 갈리므로 트리 상대경로로 고정한다.
PINNED = {"defaultprojects/fantasticcar/materials/car/glass.json",
          "presets/water/preset.json"}
# 자산 리더는 이 진입점을 타야 한다. 파일 → 최소 호출 수.
WIRED = {"Sources/WapleCore/SceneDocument.swift": 7,
         "Sources/WapleCore/ProjectJSONParser.swift": 1,
         "Sources/WapleCore/TexImage.swift": 1,
         "Sources/WapleCore/Model3D.swift": 1,
         "Sources/WapleRender/SceneRendererResources.swift": 3,
         "Sources/WapleRender/SceneRenderer3D.swift": 2}


def swift_characters(text: str):
    """파이썬 코드포인트 문자열을 **Swift `Character`(그래핌 클러스터) 목록**으로 쪼갠다.

    **[2026-08-21] 이 함수가 없어서 이 게이트가 실전 결함을 놓쳤다.** 파이썬 `str` 은
    코드포인트 단위라 `"\r\n"` 이 두 글자지만, Swift `String` 은 그래핌 클러스터 단위라
    **한 글자**다. 그래서 `text[i] != "\n"` 이 파이썬 모델에서는 CRLF 에 멈추고 Swift 에서는
    안 멈춘다 — 모델이 통과시킨 코드가 실물에서는 파일 끝까지 지워 버렸다.
    동봉 `effects/**/effect.json` 122개가 전건 CRLF 라, 관용이 필요한 자산 31건이 전부
    이 구멍에 빠져 있었는데 게이트는 초록이었다.

    여기서 재현이 필요한 클러스터링은 CRLF 하나뿐이다(자산에 결합 문자·이모지 ZWJ 가
    JSON 구조 문자 자리에 올 일이 없다). 과하게 흉내 내지 않고 그 한 규칙만 적용한다 —
    모델이 실물보다 똑똑해지면 다시 같은 종류의 거짓 초록이 난다.
    """
    out, i, n = [], 0, len(text)
    while i < n:
        if text[i] == "\r" and i + 1 < n and text[i + 1] == "\n":
            out.append("\r\n"); i += 2
        else:
            out.append(text[i]); i += 1
    return out


# Swift `Character.isNewline` 이 참인 것들(그래핌 단위). JSON 구조 자리에 올 수 있는 것만.
SWIFT_NEWLINES = {"\n", "\r", "\r\n", "\u000b", "\u000c", "\u0085", "\u2028", "\u2029"}


def relaxed(text: str, *, swift_graphemes: bool = False) -> str:
    """런타임 `AssetJSON.relaxed` 와 같은 관용: 줄 주석 + 트레일링 콤마 딱 둘.

    `swift_graphemes=True` 면 Swift 와 같은 그래핌 단위로 순회한다. 두 모드의 결과가
    갈리는 입력이 있으면 그건 **파이썬 모델이 실물과 다르다**는 신호다.
    """
    units = swift_characters(text) if swift_graphemes else list(text)
    out, in_str, i, n = [], False, 0, len(units)
    while i < n:
        c = units[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(units[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1; continue
        if c == '"':
            in_str = True; out.append(c); i += 1; continue
        if c == "/" and i + 1 < n and units[i + 1] == "/":
            while i < n and units[i] not in SWIFT_NEWLINES:
                i += 1
            continue
        if c == ",":
            j = i + 1
            while j < n and (units[j] in (" ", "\t") or units[j] in SWIFT_NEWLINES):
                j += 1
            if j < n and units[j] in ("]", "}"):
                i += 1; continue
        out.append(c); i += 1
    return "".join(out)


def selftest() -> None:
    """음성 대조 — 실패하면 본 검사를 아예 돌리지 않는다."""
    cases = [
        ('{"a":1,//c\n"b":2}', {"a": 1, "b": 2}, "줄 주석"),
        ('{"a":[1,2,],}', {"a": [1, 2]}, "트레일링 콤마"),
        ('{"u":"http://a","x":"y,]"}', {"u": "http://a", "x": "y,]"}, "문자열 안 불가침"),
        (r'{"e":"q\"//z"}', {"e": 'q"//z'}, "이스케이프 뒤 //"),
    ]
    for src, want, label in cases:
        try:
            got = json.loads(relaxed(src))
        except ValueError as exc:
            print(f"selftest 실패({label}): 관용 파스가 죽었다 — {exc}", file=sys.stderr)
            raise SystemExit(2)
        if got != want:
            print(f"selftest 실패({label}): {got!r} != {want!r}", file=sys.stderr)
            raise SystemExit(2)
    # CRLF — 두 모드가 **같은 결과**를 내야 한다. 갈리면 파이썬 모델이 실물과 다르다는 뜻이다.
    crlf_cases = [
        ('{\r\n"a": 1, // c\r\n"b": 2\r\n}', {"a": 1, "b": 2}, "CRLF 줄 주석"),
        ('{\r\n"a": [1, 2,\r\n],\r\n}', {"a": [1, 2]}, "CRLF 트레일링 콤마"),
    ]
    for src, want, label in crlf_cases:
        for mode in (False, True):
            try:
                got = json.loads(relaxed(src, swift_graphemes=mode))
            except ValueError as exc:
                print(f"selftest 실패({label}, swift_graphemes={mode}): {exc}", file=sys.stderr)
                raise SystemExit(2)
            if got != want:
                print(f"selftest 실패({label}, swift_graphemes={mode}): {got!r} != {want!r}",
                      file=sys.stderr)
                raise SystemExit(2)

    # 관용이 **너무** 관대하면 안 된다 — 블록 주석은 일부러 미지원이다.
    try:
        json.loads(relaxed('{/* c */"a":1}'))
    except ValueError:
        pass
    else:
        print("selftest 실패: 블록 주석이 통과했다(미지원이어야 한다)", file=sys.stderr)
        raise SystemExit(2)
    print("selftest: OK")


def main() -> int:
    selftest()
    rc = 0

    # ── A. 도달 실측 ──────────────────────────────────────────────────────
    need, unrecoverable, seen = set(), [], 0
    for tree in TREES:
        if not tree.is_dir():
            continue
        for p in sorted(tree.rglob("*.json")):
            seen += 1
            raw = p.read_bytes()
            try:
                raw.decode("utf-8-sig")
            except UnicodeDecodeError:
                continue
            text = raw.decode("utf-8-sig")
            try:
                json.loads(text)
                continue
            except ValueError:
                pass
            rel = str(p.relative_to(tree))
            need.add(rel)
            try:
                json.loads(relaxed(text))
                # Swift 그래핌 모드로도 복구돼야 한다 — 실물이 도는 방식이 이쪽이다.
                json.loads(relaxed(text, swift_graphemes=True))
            except ValueError as exc:
                unrecoverable.append((rel, str(exc)[:70]))

    if unrecoverable:
        print(f"[lenient-json] 관용으로도 못 읽는 자산 {len(unrecoverable)}건 — "
              f"관용 범위가 실물보다 좁다", file=sys.stderr)
        for rel, why in unrecoverable[:10]:
            print(f"    {rel}: {why}", file=sys.stderr)
        rc = 1

    if len(need) < MIN_LENIENT_NEEDED:
        print(f"[lenient-json] 관용이 필요한 자산 {len(need)}건 — 하한 {MIN_LENIENT_NEEDED} 미만. "
              f"측정이 조용히 작아졌다(트리 경로가 바뀌었나?).", file=sys.stderr)
        rc = 1

    missing_pins = sorted(PINNED - need)
    if missing_pins:
        print(f"[lenient-json] 고정 자산이 실패 목록에 없다: {missing_pins} — "
              f"이 파일들이 이 게이트의 존재 이유다", file=sys.stderr)
        rc = 1

    # ── B. 배선 확인 ──────────────────────────────────────────────────────
    for rel, least in sorted(WIRED.items()):
        src = (ROOT / rel).read_text(encoding="utf-8")
        n = len(re.findall(r"AssetJSON\.(dictionary|object)\(", src))
        if n < least:
            print(f"[lenient-json] {rel}: AssetJSON 호출 {n}건 — 최소 {least} 미만. "
                  f"관용 파서가 있어도 리더가 안 부르면 아무 일도 안 일어난다.", file=sys.stderr)
            rc = 1

    if rc == 0:
        print(f"[lenient-json] 자산 json {seen}개 · 관용 필요 {len(need)}건 전건 복구 · "
              f"리더 배선 {len(WIRED)}파일 OK")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
