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
    out = []
    for m in sorted((root / 'effects').glob('*/**/*.json')):
        rel = m.relative_to(root).as_posix()
        if rel.endswith('/effect.json'):
            continue
        parts = rel.split('/')            # effects/<eff>/<第1계층>/...
        if len(parts) > 2 and parts[2].startswith('preview'):
            continue
        doc = relaxed_json(m.read_text(encoding='utf-8', errors='replace'))
        if not isinstance(doc, dict):
            continue
        effect = rel.split('effects/', 1)[1].split('/', 1)[0]
        for p in doc.get('passes') or []:
            if not isinstance(p, dict):
                continue
            for t in p.get('textures') or []:
                if isinstance(t, str) and t:
                    out.append((effect, rel, t))
    return out


def check(root, allow_source_form=True):
    bad = []
    refs = texture_refs(root)
    for effect, mat, name in refs:
        if resolve(root, effect, name, allow_source_form) is None:
            bad.append((effect, mat, name))
    return refs, bad


def selftest():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        mat = root / 'effects/fake/materials/effects'
        mat.mkdir(parents=True)
        (mat.parent / 'fake.json').write_text(
            '{"passes":[{"textures":["effects/fakenormal"],}]}\n', encoding='utf-8')
        (mat / 'fakenormal.png').write_bytes(b'\x89PNG')
        _, bad = check(root, allow_source_form=False)
        assert len(bad) == 1, '소스 폼을 끄면 잡혀야 한다: %r' % (bad,)
        _, bad = check(root, allow_source_form=True)
        assert not bad, '소스 폼을 켜면 안 잡혀야 한다: %r' % (bad,)
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
    refs, bad = check(ASSETS)
    for effect, mat, name in bad:
        print('%s: 텍스처 `%s` 가 어디서도 해석되지 않는다 — 흰색 1×1 폴백이 된다' % (mat, name))
        print('    시도: %s' % ', '.join(candidates(name)))
        print('    시도: %s' % ', '.join('effects/%s/%s' % (effect, c) for c in candidates(name)))
    if bad:
        print('\n이펙트 텍스처 미해석 %d건. 흰색 폴백은 **조용히** 틀린 그림을 만든다 '
              '(노멀맵 자리의 (1,1,1) 언팩 = 상시 대각 변위).' % len(bad), file=sys.stderr)
        return 1
    print('이펙트 텍스처 해석: 참조 %d건 전건 해석' % len(refs))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
