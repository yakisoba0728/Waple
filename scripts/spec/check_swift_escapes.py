#!/usr/bin/env python3
"""비-raw Swift 문자열 리터럴 안의 **잘못된 이스케이프**를 잡는다.

왜 있는가
---------
이 리포는 GLSL/MSL/JS 를 Swift 다중행 문자열 리터럴에 통째로 싣는다
(`TextScriptEngine.shims` 880행, `Mesh3DShaders.source`, `EffectShaders.frags` …).
그 안에 정규식이나 경로를 그대로 붙여 넣으면 `\\s` `\\d` `\\w` 같은 시퀀스가
**Swift 의 잘못된 이스케이프**가 되어 컴파일이 깨진다. JS/GLSL 쪽에서는 완벽히
정상인 코드라 눈으로는 잘 안 보이고, macOS 러너에서만 잡혀 왕복이 한 번 더 든다.

실제로 2026-08-19 에 `split(/\\s+/)` 로 이 사고가 났고, 정정 주석에 그 정규식을
그대로 인용하는 바람에 **같은 사고를 연달아 두 번** 냈다. 이 검사는 그 왕복을
리눅스 레인에서 끝낸다.

무엇을 보는가
-------------
- raw 리터럴(앞에 # 이 붙는 형태)은 **건드리지 않는다** — 거기선 백슬래시가 리터럴이고
  실제로 이 리포의 정규식 대부분이 그 형태다(정상).
- 주석은 제외한다. 단 **다중행 리터럴 안의 `//` 는 주석이 아니라 문자열 내용**이므로
  제외하지 않는다(그게 바로 이 사고가 난 자리다).
- Swift 가 인정하는 이스케이프만 통과: `\\0 \\\\ \\t \\n \\r \\" \\' \\u{...}` 와
  문자열 보간 `\\(`.

음성 대조
---------
`--selftest` 는 알려진 나쁜/좋은 입력으로 스스로를 검증한다. 검사가 실제로 잡는지
확인하지 않으면 "검사하는 척하는 검사" 가 된다.
"""
import re
import sys
from pathlib import Path

# Swift 가 인정하는 이스케이프. 개행이 들어있는 이유: 다중행 리터럴에서 줄 끝의 백슬래시는
# **줄 이음(line continuation)** 이라 정상이다(이 리포가 실제로 많이 쓴다).
VALID_AFTER_BACKSLASH = set('0\\tnr"\'u(\n\r')


def _skip_interpolation(text: str, i: int) -> int:
    """`\\(` 의 여는 괄호 위치에서 시작해 짝이 맞는 `)` **다음** 인덱스를 돌려준다.

    보간 안은 문자열 본문이 아니라 **Swift 식**이다. `\\(xs.map(\\.name))` 처럼 키패스가
    들어가는 게 정상이라, 여기를 본문으로 세면 거짓 양성이 난다.
    """
    n = len(text)
    depth = 0
    while i < n:
        c = text[i]
        if c == '"':                      # 보간 안의 중첩 문자열은 통째로 건너뛴다
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == '\\' else 1
            i += 1
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def _scan_literal_body(text: str, start: int, end: int, line_at_start: int, findings: list):
    """리터럴 본문 [start, end) 를 훑어 잘못된 이스케이프를 모은다."""
    i, line = start, line_at_start
    while i < end:
        c = text[i]
        if c == '\n':
            line += 1
            i += 1
            continue
        if c != '\\':
            i += 1
            continue
        nxt = text[i + 1] if i + 1 < end else ''
        if nxt == '(':                      # 문자열 보간 — 안은 Swift 식이다
            i = _skip_interpolation(text, i + 1)
            continue
        if nxt not in VALID_AFTER_BACKSLASH:
            snippet = text[max(0, i - 40):i + 40].replace('\n', ' / ')
            findings.append((line, '\\' + nxt, snippet.strip()))
        if nxt == '\n':
            line += 1
        i += 2
    return line


def scan_source(text: str, on_multiline=None):
    """(line, seq, snippet) 목록. 비-raw 문자열 리터럴 안의 잘못된 이스케이프만.

    `on_multiline(body, start_line)` 을 주면 **비-raw 다중행 리터럴 본문마다** 불러 준다.
    두 번째 검사(`scan_comment_line_breaks`)가 같은 토크나이저를 다시 짜지 않게 하려는 것이다 —
    리터럴 경계를 두 벌로 유지하면 한쪽만 raw 리터럴을 놓치는 식으로 조용히 갈린다.
    """
    findings: list = []
    i, n = 0, len(text)
    line = 1
    while i < n:
        ch = text[i]
        if ch == '\n':
            line += 1
            i += 1
            continue
        # raw 리터럴: # 이 하나라도 앞에 붙으면 백슬래시가 리터럴이라 통째로 건너뛴다.
        if ch == '#':
            j = i
            while j < n and text[j] == '#':
                j += 1
            hashes = j - i
            for opener, closer in (('"""', '"""'), ('"', '"')):
                if text.startswith(opener, j):
                    close = closer + '#' * hashes
                    end = text.find(close, j + len(opener))
                    end = n if end < 0 else end + len(close)
                    line += text.count('\n', i, end)
                    i = end
                    break
            else:
                i = j
            continue
        if text.startswith('//', i):
            end = text.find('\n', i)
            i = n if end < 0 else end
            continue
        if text.startswith('/*', i):
            end = text.find('*/', i + 2)
            end = n if end < 0 else end + 2
            line += text.count('\n', i, end)
            i = end
            continue
        if text.startswith('\'\'\'', i):   # (Swift 에 없음 — 방어)
            i += 3
            continue
        if text.startswith('"""', i):
            body = i + 3
            end = text.find('"""', body)
            end = n if end < 0 else end
            if on_multiline is not None:
                on_multiline(text[body:end], line)
            line = _scan_literal_body(text, body, end, line, findings)
            i = end + 3 if end < n else n
            continue
        if ch == '"':
            body = i + 1
            j = body
            while j < n and text[j] != '\n':
                if text[j] == '\\':
                    j += 2
                    continue
                if text[j] == '"':
                    break
                j += 1
            _scan_literal_body(text, body, j, line, findings)
            i = j + 1
            continue
        i += 1
    return findings


# ─────────────────────────────────────────────────────────────────────────────
# 검사 ② — **유효한데 의도와 다른** 이스케이프: 셰이더 주석을 쪼개거나 삼키는 것.
#
# 검사 ① 이 잡는 것은 `\s` 처럼 Swift 가 **거부**하는 시퀀스라 컴파일이 안 된다.
# 이쪽은 정반대다 — Swift 는 기꺼이 받아들이고, 깨지는 것은 **렌더된 셰이더**다.
#
# 실사고(2026-08-21, CI run 32448054603): `Mesh3DShaders.source` 안의 MSL 주석 한 줄
#
#     // `"#define HLSL 1\n#define HLSL_SM40 1\n"`): common_pbr_2.h:263-266
#
# 이 렌더될 때 `\n` 이 **진짜 줄바꿈**이 되어 주석이 세 줄로 쪼개졌다.
#
#     145: // `"#define HLSL 1
#     146: #define HLSL_SM40 1        ← 주석이 아니라 **실제 전처리기 지시자**
#     147: "`): common_pbr_2.h:263-266 ← 줄 첫 글자가 따옴표
#
# Metal 은 `program_source:147:1: missing terminating '"' character` 로 컴파일을 거부했고,
# mesh 라이브러리가 통째로 안 지어져 **macOS CI 의 3D 렌더 테스트 수십 건이 한꺼번에**
# 떨어졌다. 리눅스 레인에서는 아무 신호도 없었다 — Swift 컴파일은 완벽히 통과하기 때문이다.
#
# 두 부류를 본다.
#   · **쪼개기** — `//` 주석 줄 안의 `\n`/`\r`(및 개행을 내는 `\u{a}`/`\u{d}`).
#     뒷부분이 주석 밖으로 튀어나온다.
#   · **삼키기** — `//` 주석 줄 **끝**의 백슬래시(줄 이음). 다음 줄이 주석 안으로 빨려들어가
#     **셰이더 코드 한 줄이 조용히 사라진다**. 컴파일이 통과할 수도 있어 더 나쁘다.
#
# 주석 아닌 줄의 `\n` 은 건드리지 않는다 — JS 심이 `"a\nb"` 같은 문자열을 정상적으로 만든다.
NEWLINE_ESCAPE_RE = re.compile(r'(?<!\\)\\(n|r|u\{0*(?:a|d|A|D)\})')


def _comment_break_findings(body: str, start_line: int):
    """다중행 리터럴 본문에서 (line, kind, snippet) 목록."""
    out = []
    for offset, raw in enumerate(body.split('\n')):
        stripped = raw.lstrip()
        if not stripped.startswith('//'):
            continue
        line = start_line + offset
        for m in NEWLINE_ESCAPE_RE.finditer(raw):
            out.append((line, m.group(0), raw.strip()[:120]))
        # 줄 이음: 홀수 개의 백슬래시로 끝나면 다음 줄이 이 주석에 빨려든다.
        trail = len(raw) - len(raw.rstrip('\\'))
        if trail % 2 == 1:
            out.append((line, '줄 끝 \\(줄 이음)', raw.strip()[:120]))
    return out


def scan_comment_line_breaks(text: str):
    """(line, kind, snippet) 목록. 다중행 리터럴 안 `//` 주석을 깨는 이스케이프."""
    found: list = []
    scan_source(text, on_multiline=lambda body, ln: found.extend(_comment_break_findings(body, ln)))
    return found


BAD2 = (
    'let s = """\n'
    '// `"#define HLSL 1\\n#define HLSL_SM40 1\\n"`): common_pbr_2.h:263-266\n'
    'float x = 1.0;\n'
    '"""\n'
)
BAD3 = (
    'let s = """\n'
    '// 줄 끝에 백슬래시가 있으면 다음 줄을 삼킨다 \\\n'
    'float x = 1.0;\n'
    '"""\n'
)
GOOD2 = (
    'let a = """\n'
    '// 정상 주석 — 이스케이프 없음\n'
    '// 두 배로 막은 것은 정상: `\\\\n` 은 렌더돼도 역슬래시+n 두 글자다\n'
    'var s = "a\\nb";        // 주석 아닌 줄의 \\n 은 문자열 내용이라 정상\n'
    '"""\n'
    'let b = #"""\n'
    '// raw 리터럴은 통째로 제외: \\n 이 그냥 두 글자다\n'
    '"""#\n'
)


BAD = 'let s = """\nvar t = x.split(/\\s+/);\n"""\n'
GOOD = (
    'let a = #"return\\s+new\\s+Vec"#\n'
    'let b = """\n// 주석처럼 보이지만 문자열 내용\nvar p = "a\\tb";\n"""\n'
    'let c = "보간 \\(x) 과 개행 \\n 과 따옴표 \\" 는 정상"\n'
    'let d = xs.map(\\.name)\n'
    'let e = """\n줄 끝 이음 \\\n다음 줄\n"""\n'
    'let f = "목록: \\(xs.map(\\.glslName)) 끝"\n'
    '// 주석 안의 \\s 는 무시된다\n'
)


def selftest() -> int:
    bad = scan_source(BAD)
    good = scan_source(GOOD)
    ok = True
    if not bad:
        print('SELFTEST FAIL: 나쁜 입력(다중행 리터럴 안의 백슬래시-s)을 못 잡았다', file=sys.stderr)
        ok = False
    if good:
        print(f'SELFTEST FAIL: 좋은 입력에서 거짓 양성 {good}', file=sys.stderr)
        ok = False
    # 검사 ② 음성 대조 — 실사고 입력 그대로.
    if not scan_comment_line_breaks(BAD2):
        print('SELFTEST FAIL: 주석 쪼개기(\\n)를 못 잡았다', file=sys.stderr)
        ok = False
    if not scan_comment_line_breaks(BAD3):
        print('SELFTEST FAIL: 주석 삼키기(줄 끝 백슬래시)를 못 잡았다', file=sys.stderr)
        ok = False
    g2 = scan_comment_line_breaks(GOOD2)
    if g2:
        print(f'SELFTEST FAIL: 검사 ② 거짓 양성 {g2}', file=sys.stderr)
        ok = False
    print('selftest: OK' if ok else 'selftest: FAIL')
    return 0 if ok else 1


def main() -> int:
    if '--selftest' in sys.argv:
        return selftest()
    if selftest() != 0:
        return 1
    roots = [Path('Sources'), Path('Tests')]
    total = 0
    broken = 0
    for root in roots:
        for path in sorted(root.rglob('*.swift')):
            try:
                text = path.read_text(encoding='utf-8')
            except (OSError, UnicodeDecodeError):
                continue
            for line, seq, snippet in scan_source(text):
                print(f'{path}:{line}: 잘못된 Swift 이스케이프 {seq!r} — {snippet}')
                total += 1
            for line, kind, snippet in scan_comment_line_breaks(text):
                print(f'{path}:{line}: 셰이더 주석을 깨는 이스케이프 {kind!r} — {snippet}')
                broken += 1
    if total or broken:
        if total:
            print(f'\n비-raw 문자열 리터럴 안의 잘못된 이스케이프 {total}건. '
                  f'raw 리터럴(#"…"#)로 바꾸거나 백슬래시를 쓰지 않는 형태로 고칠 것.', file=sys.stderr)
        if broken:
            print(f'\n다중행 리터럴 안 `//` 주석을 깨는 이스케이프 {broken}건. '
                  f'`\\n` 은 `\\\\n` 으로 막고, 줄 끝 백슬래시는 지울 것 — 렌더된 셰이더에서 '
                  f'주석이 쪼개지거나 다음 줄을 삼킨다(리눅스에선 안 잡히고 macOS 에서만 터진다).',
                  file=sys.stderr)
        return 1
    print('Swift 이스케이프: 위반 0건 / 셰이더 주석 파손 0건')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
