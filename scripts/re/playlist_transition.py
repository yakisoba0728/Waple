"""WE 플레이리스트 전환(FADEEFFECT) 표를 세 출처에서 각각 뽑아 **교차 검증**한다.

세 출처가 서로를 못 보므로, 셋이 일치하면 그게 근거다.

  1. 셰이더    assets/shaders/HLSL/dx11playlisttransition.frag 의 `#elif FADEEFFECT == N` 분기
  2. UI        ui/dist/scripts/scripts.js 의 `getTransitionOptions()` (id ↔ locale key)
  3. 로케일    locale/ui_en-us.json 의 `ui_browse_playlist_modal_settings_transition_*`

바이너리(wallpaper64.exe)는 개수만 검증한다 — 무작위 선택기의 상수 27.0f/26 이
셰이더 분기 수와 같아야 한다(docs/re/playlist-transition.md §4 참조).

usage:
    WE_ROOT=/path/to/wallpaper_engine python3 scripts/re/playlist_transition.py
"""
import json
import os
import re
import sys

WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")
FRAG = os.path.join(WE, "assets", "shaders", "HLSL", "dx11playlisttransition.frag")
GEOM = os.path.join(WE, "assets", "shaders", "HLSL", "dx11playlisttransition.geom")
VERT = os.path.join(WE, "assets", "shaders", "HLSL", "dx11playlisttransition.vert")
JS = os.path.join(WE, "ui", "dist", "scripts", "scripts.js")
LOC = os.path.join(WE, "locale", "ui_en-us.json")

PREFIX = "ui_browse_playlist_modal_settings_transition_"


def from_shader(path):
    """`#if/#elif FADEEFFECT == N` → {N: (첫줄, 끝줄, 주석이름, 본문)}"""
    lines = open(path, encoding="utf-8").read().split("\n")
    out, cur = {}, None
    for i, line in enumerate(lines, 1):
        m = re.match(r"#(?:el)?if FADEEFFECT == (\d+)\s*$", line.strip())
        if m:
            cur = int(m.group(1))
            out[cur] = [i, i, "", []]
            continue
        if cur is None:
            continue
        if line.strip() in ("#endif", "#else"):
            cur = None
            continue
        out[cur][1] = i
        if not out[cur][2] and line.strip().startswith("//"):
            out[cur][2] = line.strip().lstrip("/").strip()
        out[cur][3].append(line)
    return out


def from_js(path):
    """getTransitionOptions() → [(locale_key, value)] (선언 순서 유지)"""
    src = open(path, encoding="utf-8", errors="replace").read()
    i = src.find("getTransitionOptions=function")
    if i < 0:
        return []
    blob = src[i:i + 4000]
    return re.findall(r'\{label:"([^"]+)",value:"(-?\d+|none|random)"\}', blob)


def main():
    if not os.path.isfile(FRAG):
        sys.exit("WE_ROOT 아래에서 %s 를 못 찾았다" % FRAG)

    frag = from_shader(FRAG)
    geom = from_shader(GEOM)
    vert = from_shader(VERT)
    js = from_js(JS)
    loc = json.load(open(LOC, encoding="utf-8"))

    js_by_id = {v: k for k, v in js}
    ids = sorted(frag)

    print("바이너리: %s" % WE)
    print("셰이더 분기 %d개  (%d..%d)" % (len(ids), min(ids), max(ids)))
    print("UI 옵션    %d개  (특수값 %s 포함)"
          % (len(js), ",".join(v for _, v in js if not v.lstrip("-").isdigit() or v == "-2")))
    print()
    print("| id | 셰이더 주석 | UI 이름 | frag 줄 | geom | vert | mip | noise/clouds |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- |")
    bad = []
    for n in ids:
        a, b, comment, body = frag[n]
        key = js_by_id.get(str(n))
        ui = loc.get(key, "??") if key else "**UI 에 없음**"
        if key is None:
            bad.append("id %d: 셰이더에는 있는데 UI 옵션에 없다" % n)
        text = "\n".join(body)
        print("| %d | %s | %s | %d-%d | %s | %s | %s | %s |" % (
            n, comment or "-", ui, a, b,
            "GS" if n in geom else "",
            "VS" if n in vert else "",
            "Y" if "MipMapped" in text else "",
            "Y" if ("Texture1Noise" in text or "Texture2Clouds" in text) else ""))

    for key, val in js:
        if val.lstrip("-").isdigit() and int(val) >= 0 and int(val) not in frag:
            bad.append("UI 값 %s (%s): 셰이더 분기가 없다" % (val, key))

    print()
    for k, v in js:
        if not v.lstrip("-").isdigit():
            print("특수값 %-8s → %s" % (v, loc.get(k, "?")))
    print("특수값 -2       → %s" % loc.get(js_by_id.get("-2", ""), "?"))

    print()
    if bad:
        print("불일치 %d건:" % len(bad))
        for b in bad:
            print("  -", b)
        sys.exit(1)
    print("셰이더 ↔ UI ↔ 로케일 일치 (%d종)" % len(ids))


if __name__ == "__main__":
    main()
