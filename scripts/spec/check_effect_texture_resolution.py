#!/usr/bin/env python3
"""동봉 이펙트가 참조하는 **텍스처가 실제로 해석되는지** 본다.

왜 있는가
---------
스톡 이펙트 3종(refraction·waterflow·waterripple)이 자기 노멀맵/위상맵을 못 찾아
**흰색 1×1 폴백**으로 돌고 있었다. 흰색은 곱셈 항등원이라 "효과가 약하게 걸린 것"
처럼 보이고, 노멀맵 자리에서는 (1,1,1) 언팩이 상시 대각 변위가 된다 — 즉 **조용히
틀린 그림**이 나온다. 렌더 계층은 리눅스에서 빌드가 안 되고 macOS CI 왕복이 10분
이라, 이 부류는 순수 파일시스템 검사로 리눅스 레인에서 끝내는 게 맞다.

무엇을 보는가
-------------
`Resources/WEAssets/effects/<eff>/**/*.json`(비-preview) 의 `passes[].textures[]` 를
모아, 런타임 `resolveTextureWithFrames` 와 **같은 순서**로 해석되는지 확인한다:

  ① 팩 루트          `materials/<name>.tex`, `<name>`
  ② 이펙트-로컬 루트  `effects/<eff>/materials/<name>.tex`, `effects/<eff>/<name>`
  ③ 이펙트-로컬 소스 폼 `effects/<eff>/materials/<name>.png`

③ 이 필요한 이유는 WE 가 `.tex` 부재 시 `resourcecompiler64.exe` 로 그 자리에서
컴파일하기 때문이다. Waple 에는 그 컴파일러가 없어 `.png` 를 직접 디코드한다.
에디터 프리뷰 트리는 제외한다 — 거기 `.tex` 가 있다고 런타임이 뜨는 게 아니다
(그 착각이 이 결함을 오래 숨겼다). 제외 규칙은 "이펙트 루트 바로 아래 `preview` 로
시작하는 디렉터리" 다. 실측 명명은 둘이다 — 46종 중 44종이 `preview/`, `vhs` 하나만
`previewvhs/` 이고, 그 안엔 `scene.json`·`project.json`·`template.json` 이 들어 있는
자립 프리뷰 프로젝트다(그래서 자기 루트 기준으로는 정상 해석된다). 런타임이 쓰는
디렉터리는 `materials/`·`shaders/` 둘뿐이라 접두 규칙으로 충분하다.

동봉 effect.json 은 `//` 주석과 트레일링 콤마를 쓴다(WE 관용 JSON). 엄격 파스가
실패하면 런타임과 같은 관용 규칙으로 재시도한다.

음성 대조
---------
`--selftest` 가 "소스 폼만 있는 이펙트" 를 임시 트리에 만들어, ③ 을 끄면 잡히고
켜면 안 잡히는지 확인한다. 검사가 실제로 잡는지 확인하지 않으면 "검사하는 척하는
검사" 가 된다 — 이 리포가 반복해서 당한 부류다.
"""
import json
import re
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ASSETS = REPO / "Sources/WapleRender/Resources/WEAssets"

_LINE_COMMENT = re.compile(r'//[^\n]*')
_TRAILING_COMMA = re.compile(r',(\s*[}\]])')


def relaxed_json(text):
    """런타임 `relaxedJSON` 과 같은 관용: 줄 주석 + 트레일링 콤마 딱 둘."""
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    stripped = _TRAILING_COMMA.sub(r'\1', _LINE_COMMENT.sub('', text))
    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        return None


def candidates(name):
    """런타임과 동일: `.tex` 로 끝나면 그것만, 아니면 `materials/<n>.tex` 를 먼저."""
    return [name] if name.endswith('.tex') else ['materials/%s.tex' % name, name]


def resolve(root, effect, name, allow_source_form=True):
    """해석된 경로(리포 상대) 또는 None. 순서는 런타임 규약 그대로."""
    for c in candidates(name):
        if (root / c).is_file():
            return c
    scoped = ['effects/%s/%s' % (effect, c) for c in candidates(name)]
    for c in scoped:
        if (root / c).is_file():
            return c
    if allow_source_form:
        for c in scoped:
            if c.endswith('.tex') and (root / (c[:-4] + '.png')).is_file():
                return c[:-4] + '.png'
    return None


def texture_refs(root):
    """(effect, material 상대경로, 텍스처 이름) 목록. preview 트리는 제외."""
    out, parse_failures = [], []
    for m in sorted((root / 'effects').glob('*/**/*.json')):
        rel = m.relative_to(root).as_posix()
        if rel.endswith('/effect.json'):
            continue
        parts = rel.split('/')            # effects/<eff>/<第1계층>/...
        if len(parts) > 2 and parts[2].startswith('preview'):
            continue
        doc = relaxed_json(m.read_text(encoding='utf-8', errors='replace'))
        if not isinstance(doc, dict):
            # **파스 실패를 조용히 넘기지 않는다.** 종전엔 `continue` 라, 머티리얼 JSON 셋을
            # 전부 깨뜨리면 `참조 0건 전건 해석` 으로 초록이 됐다.
            parse_failures.append(rel)
            continue
        effect = rel.split('effects/', 1)[1].split('/', 1)[0]
        for p in doc.get('passes') or []:
            if not isinstance(p, dict):
                continue
            for t in p.get('textures') or []:
                if isinstance(t, str) and t:
                    out.append((effect, rel, t))
    return out, parse_failures


# **[2026-08-20] 파일 존재만 보면 이 검사의 존재 이유를 놓친다.**
# 이 게이트가 막겠다는 결과는 "흰색 1×1 폴백으로 조용히 틀린 그림" 인데, **0바이트 PNG** 나
# 텍스트 쓰레기도 `is_file()` 을 통과해 `참조 N건 전건 해석` 으로 초록이었다. 실측으로
# 확인한 통과 사례: `refractnormal.png` 를 0바이트로 만들어도, 텍스트로 채워도 rc=0.
# 내용을 최소한으로 본다 — PNG 는 시그니처 + IHDR 폭·높이 ≥ 1, `.tex` 는 매직.
# 참조 수 하한 — 현재 실측치에서 내려가면 근거가 사라진 것이다.
MIN_REFS = 3
PNG_SIG = b"\x89PNG\r\n\x1a\n"


def payload_problem(path):
    """해석된 파일이 실제로 텍스처인가. 문제가 있으면 사유 문자열, 없으면 None."""
    try:
        raw = path.read_bytes()
    except OSError as e:
        return "읽을 수 없다(%s)" % e
    if not raw:
        return "0바이트"
    if path.suffix.lower() == ".png":
        if not raw.startswith(PNG_SIG):
            return "PNG 시그니처가 없다"
        if len(raw) < 24 or raw[12:16] != b"IHDR":
            return "IHDR 청크가 없다"
        w = int.from_bytes(raw[16:20], "big")
        h = int.from_bytes(raw[20:24], "big")
        if w < 1 or h < 1:
            return "IHDR 크기가 %dx%d" % (w, h)
    elif path.suffix.lower() == ".tex":
        if not raw.startswith(b"TEX"):
            return "TEX 매직이 없다"
    return None


def check(root, allow_source_form=True):
    bad, broken = [], []
    refs, parse_failures = texture_refs(root)
    for effect, mat, name in refs:
        got = resolve(root, effect, name, allow_source_form)
        if got is None:
            bad.append((effect, mat, name))
            continue
        why = payload_problem(root / got)
        if why:
            broken.append((mat, name, got, why))
    return refs, bad, broken, parse_failures


def selftest():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        mat = root / 'effects/fake/materials/effects'
        mat.mkdir(parents=True)
        (mat.parent / 'fake.json').write_text(
            '{"passes":[{"textures":["effects/fakenormal"],}]}\n', encoding='utf-8')
        png = PNG_SIG + b'\x00\x00\x00\x0dIHDR' + (4).to_bytes(4, 'big') + (4).to_bytes(4, 'big')
        (mat / 'fakenormal.png').write_bytes(png)
        _, bad, broken, pf = check(root, allow_source_form=False)
        assert len(bad) == 1, '소스 폼을 끄면 잡혀야 한다: %r' % (bad,)
        _, bad, broken, pf = check(root, allow_source_form=True)
        assert not bad and not broken and not pf, '정상 픽스처는 통과해야 한다: %r %r %r' % (bad, broken, pf)

        # **[2026-08-20] 내용 검사 음성 대조 — 종전엔 셋 다 통과했다.**
        (mat / 'fakenormal.png').write_bytes(b'')
        _, _, broken, _ = check(root)
        assert len(broken) == 1 and '0바이트' in broken[0][3], '0바이트 PNG 를 잡아야 한다: %r' % (broken,)
        (mat / 'fakenormal.png').write_bytes(b'not a png at all, just text')
        _, _, broken, _ = check(root)
        assert len(broken) == 1 and '시그니처' in broken[0][3], 'PNG 아닌 바이트를 잡아야 한다: %r' % (broken,)
        (mat / 'fakenormal.png').write_bytes(PNG_SIG + b'\x00\x00\x00\x0dIHDR' + b'\x00' * 8)
        _, _, broken, _ = check(root)
        assert len(broken) == 1 and '0x0' in broken[0][3], 'IHDR 0x0 을 잡아야 한다: %r' % (broken,)
        (mat / 'fakenormal.png').write_bytes(png)

        # 머티리얼 JSON 파스 실패를 조용히 넘기지 않는가 — 종전엔 `참조 0건 전건 해석` 이었다.
        (mat.parent / 'fake.json').write_text('{ this is not json', encoding='utf-8')
        refs, _, _, pf = check(root)
        assert pf and not refs, '파스 실패를 보고해야 한다: %r %r' % (pf, refs)

        # 관용 JSON 이 실제로 동작하는지(위 픽스처의 트레일링 콤마가 근거다)
        assert relaxed_json('{"a":1,} // x') == {'a': 1}
    print('selftest: OK')


def main():
    if '--selftest' in sys.argv:
        selftest()
        return 0
    selftest()
    if not ASSETS.is_dir():
        print('[effect-texture] %s 가 없다 — 검사 생략' % ASSETS, file=sys.stderr)
        return 0
    refs, bad, broken, parse_failures = check(ASSETS)
    for rel in parse_failures:
        print('%s: 머티리얼 JSON 이 파스되지 않는다 — 이 파일의 텍스처 참조는 검사되지 않았다' % rel)
    for mat, name, got, why in broken:
        print('%s: 텍스처 `%s` 가 %s 로 해석되지만 내용이 텍스처가 아니다 — %s' % (mat, name, got, why))
    for effect, mat, name in bad:
        print('%s: 텍스처 `%s` 가 어디서도 해석되지 않는다 — 흰색 1×1 폴백이 된다' % (mat, name))
        print('    시도: %s' % ', '.join(candidates(name)))
        print('    시도: %s' % ', '.join('effects/%s/%s' % (effect, c) for c in candidates(name)))
    if bad or broken or parse_failures:
        print('\n이펙트 텍스처 문제 %d건(미해석 %d · 내용불량 %d · 파스실패 %d). 흰색 폴백은 '
              '**조용히** 틀린 그림을 만든다(노멀맵 자리의 (1,1,1) 언팩 = 상시 대각 변위).'
              % (len(bad) + len(broken) + len(parse_failures), len(bad), len(broken),
                 len(parse_failures)), file=sys.stderr)
        return 1
    # **참조 수 하한.** 종전엔 머티리얼을 전부 깨뜨리면 `참조 0건 전건 해석` 으로 초록이었다.
    # 근거가 사라지는 것과 근거가 통과하는 것은 다르다.
    if len(refs) < MIN_REFS:
        print('\n이펙트 텍스처 참조가 %d건뿐이다(기준선 %d) — 근거가 사라졌다. 자산이 줄었으면 '
              'MIN_REFS 를 사유와 함께 내릴 것.' % (len(refs), MIN_REFS), file=sys.stderr)
        return 1
    print('이펙트 텍스처 해석: 참조 %d건 전건 해석(내용 검사 포함)' % len(refs))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
