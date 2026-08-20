#!/usr/bin/env python3
"""enum 연관값 개수가 **패턴 매치와 어긋나는 곳**을 잡는다.

왜 있는가
---------
`EffectBind.translated` 에 연관값을 하나 더했을 때, 소비처 한 곳이 여전히 둘만
바인딩하고 있었다(`case .translated(let passes, _)`). 이건 명백한 컴파일 에러인데
컴파일러가 진단을 못 만들어서

    SceneRenderer.swift:584:21: error: failed to produce diagnostic for expression

로만 떴다 — 줄 번호는 맞지만 원인이 안 보이는 형태다. 그리고 이 리포는 렌더 계층이
Metal/AppKit 의존이라 리눅스에서 빌드가 안 되고, macOS CI 왕복이 한 번에 10분이다.

놓친 경위도 기록해 둔다. 변경 직후 `\\.translated(passes` 로 grep 했는데 그 자리는
**라벨 없는 위치 패턴**이라 안 걸렸다. 라벨 형태만 찾는 grep 은 이 부류를 못 잡는다.

무엇을 보는가
-------------
1) `Sources/`·`Tests/` 의 모든 `case name(a: T, b: U)` 선언에서 (이름 → 연관값 개수)를 모은다.
   같은 이름이 여러 enum 에 있으면 **개수가 갈리므로 그 이름은 검사에서 뺀다**(거짓 양성 방지).
2) `case .name(...)` / `if case .name(...)` / `guard case .name(...)` 패턴의 최상위 콤마를
   세어 개수를 비교한다.
3) 다음은 건드리지 않는다 — 전부 정상이고 개수를 못 세는 형태다:
   - `case .name` (연관값 무시, 바인딩 없음)
   - `case .name(let x)` 에서 x 가 튜플 전체를 받는 형태는 **1개일 때만** 정상이라
     선언이 2개 이상이면 잡는다(실제로 그건 에러다)
   - 문자열/주석 안
   - 함수 호출 `.name(a: 1, b: 2)`(패턴이 아님) — `case`/`if case`/`guard case` 앞자리만 본다

음성 대조
---------
`--selftest` 가 알려진 나쁜/좋은 입력으로 스스로를 검증한다. 검사가 실제로 잡는지
확인하지 않으면 "검사하는 척하는 검사" 가 된다 — 이 리포가 반복해서 당한 부류다.
"""
import re
import sys
from pathlib import Path

# 선언은 `case name(` — 이름 앞에 점이 없다. 패턴 매치는 `case .name(` 이라 점이 있고,
# `case let .name(` 은 let 이 끼어 있어 이 정규식에 안 걸린다. 그래서 둘이 갈린다.
DECL_RE = re.compile(r'(?<![.\w])case\s+([A-Za-z_]\w*)\s*\(')
# 패턴 자리: `case .x(`, `if case .x(`, `guard case .x(`, `case let .x(`
PAT_RE = re.compile(r'\b(?:if\s+case|guard\s+case|case)\s+(?:let\s+|var\s+)?\.([A-Za-z_]\w*)\s*\(')


def strip_noise(text: str) -> str:
    """문자열 리터럴과 주석을 공백으로 바꿔 위치를 보존한 채 지운다."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end < 0 else end + 3
            for j in range(i, end):
                if out[j] != '\n':
                    out[j] = ' '
            i = end
            continue
        if c == '"':
            j = i + 1
            while j < n and text[j] != '\n':
                if text[j] == '\\':
                    j += 2
                    continue
                if text[j] == '"':
                    j += 1
                    break
                j += 1
            for k in range(i, min(j, n)):
                out[k] = ' '
            i = j
            continue
        if text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
            continue
        if text.startswith('/*', i):
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != '\n':
                    out[k] = ' '
            i = j
            continue
        i += 1
    return ''.join(out)


def top_level_commas(text: str, open_idx: int):
    """여는 괄호 위치에서 시작해 짝 맞는 닫는 괄호까지의 최상위 콤마 수와 끝 인덱스.

    괄호가 안 닫히면 (None, None) — 매크로/다중행 잘림 등에서 잘못 세지 않으려는 것이다.
    """
    depth = 0
    commas = 0
    i, n = open_idx, len(text)
    while i < n:
        c = text[i]
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
            if depth == 0:
                return commas, i
        elif c == ',' and depth == 1:
            commas += 1
        i += 1
    return None, None


def collect_declarations(sources):
    """이름 → 연관값 개수 집합. 개수가 갈리는 이름은 호출자가 뺀다."""
    counts = {}
    for text in sources:
        clean = strip_noise(text)
        for m in DECL_RE.finditer(clean):
            name = m.group(1)
            open_idx = m.end() - 1
            if clean[open_idx] != '(':
                open_idx = clean.index('(', m.end() - 1)
            commas, end = top_level_commas(clean, open_idx)
            if commas is None:
                continue
            counts.setdefault(name, set()).add(commas + 1)
    return counts


def scan_patterns(text: str, arity, path: str):
    findings = []
    clean = strip_noise(text)
    for m in PAT_RE.finditer(clean):
        name = m.group(1)
        want = arity.get(name)
        if want is None:
            continue
        open_idx = m.end() - 1
        if clean[open_idx] != '(':
            open_idx = clean.index('(', m.end() - 1)
        commas, end = top_level_commas(clean, open_idx)
        if commas is None:
            continue
        got = commas + 1
        if got == want:
            continue
        # 연관값 전체를 튜플 하나로 받는 형태는 1개짜리 바인딩이 정상이다.
        if got == 1 and want > 1:
            inner = clean[open_idx + 1:end].strip()
            if inner.startswith('let ') or inner.startswith('var '):
                continue
        line = clean.count('\n', 0, m.start()) + 1
        findings.append((line, name, got, want))
    return findings


BAD = '''
enum E { case translated(passes: [Int], fbos: [Int], store: Int) }
func f(_ e: E) -> Bool {
    guard case .translated(let passes, _) = e else { return false }
    return passes.isEmpty
}
'''
GOOD = '''
enum E { case translated(passes: [Int], fbos: [Int], store: Int) }
enum F { case only(a: Int) }
func f(_ e: E, _ g: F) -> Bool {
    guard case .translated(let passes, _, _) = e else { return false }
    if case .translated = e { return true }
    if case .only(let a) = g { return a > 0 }
    // 주석 안의 case .translated(let x, _) 는 무시된다
    let s = "case .translated(let x, _)"
    _ = s
    return passes.isEmpty
}
'''


def selftest() -> int:
    ok = True
    arity = collect_declarations([BAD])
    if arity.get('translated') != {3}:
        print(f'SELFTEST FAIL: 선언 수집이 틀렸다 {arity}', file=sys.stderr)
        ok = False
    bad = scan_patterns(BAD, {k: next(iter(v)) for k, v in arity.items()}, 'BAD')
    if not bad:
        print('SELFTEST FAIL: 연관값 2/3 불일치를 못 잡았다', file=sys.stderr)
        ok = False
    garity = collect_declarations([GOOD])
    good = scan_patterns(GOOD, {k: next(iter(v)) for k, v in garity.items() if len(v) == 1}, 'GOOD')
    if good:
        print(f'SELFTEST FAIL: 정상 입력에서 거짓 양성 {good}', file=sys.stderr)
        ok = False
    print('selftest: OK' if ok else 'selftest: FAIL')
    return 0 if ok else 1


def main() -> int:
    if '--selftest' in sys.argv:
        return selftest()
    if selftest() != 0:
        return 1
    paths = []
    for root in (Path('Sources'), Path('Tests')):
        paths.extend(sorted(root.rglob('*.swift')))
    texts = {}
    for p in paths:
        try:
            texts[p] = p.read_text(encoding='utf-8')
        except (OSError, UnicodeDecodeError):
            continue
    counts = collect_declarations(texts.values())
    ambiguous = {k for k, v in counts.items() if len(v) != 1}
    arity = {k: next(iter(v)) for k, v in counts.items() if len(v) == 1}
    total = 0
    for p, text in texts.items():
        for line, name, got, want in scan_patterns(text, arity, str(p)):
            print(f'{p}:{line}: enum case `.{name}` 는 연관값 {want}개인데 패턴이 {got}개를 바인딩한다')
            total += 1
    if total:
        print(f'\nenum 연관값 arity 불일치 {total}건. 컴파일러가 이 부류에 '
              f'"failed to produce diagnostic" 만 뱉는 경우가 있어 원인이 안 보인다.', file=sys.stderr)
        return 1
    print(f'enum 패턴 arity: 위반 0건 (검사 대상 case {len(arity)}종, '
          f'이름 중복으로 제외 {len(ambiguous)}종)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
