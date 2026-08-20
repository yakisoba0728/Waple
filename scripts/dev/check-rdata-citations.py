#!/usr/bin/env python3
"""주석의 `.rdata` 주소 인용이 정말 그 문자열을 가리키는지 바이너리로 검사한다.

## 왜 필요한가

`.rdata` 는 rva `0x426000` / rawptr `0x424e00` 이라 **파일 오프셋 + 0x1200 = RVA** 다.
이 리포의 주석은 두 규약을 똑같은 `@0x48XXXX` 표기로 섞어 써 왔다 — 그래서
`"ringradius"` 를 가리킨다고 적힌 `@0x48e8a8` 을 RVA 로 읽으면 포그 키에 착지하고,
rope/ropetrail 확장 키라는 `@0x48e9b0` 은 `"winddirection"` 에 떨어진다.

주소를 하나씩 고치는 것은 처방이 아니다 — 같은 부류가 다시 생긴다. 인용이 **자기가 말하는
문자열을 실제로 가리키는지** 기계가 보게 한다.

## 판정

각 `@0x4XXXXX` 인용에 대해:

  · VA = `0x140000000 + 인용값` 의 C 문자열을 읽는다(직접 해석)
  · VA = `0x140000000 + 인용값 + 0x1200` 의 C 문자열도 읽는다(파일 오프셋 해석)
  · 인용 주변 ±120자에서 따옴표/백틱 토큰을 뽑아 둘 중 어느 쪽과 맞는지 본다

`직접` 이 맞으면 통과, `+0x1200` 이 맞으면 **파일 오프셋을 RVA 로 적은 것**이라 실패,
둘 다 아니면 `미해결` 로 보고한다(사람이 봐야 한다 — 문자열 인용이 아닐 수도 있다).

## 실행

바이너리가 필요하므로 **CI 게이트가 아니라 로컬 도구**다:

    WE_BINARY=/path/to/wallpaper64.exe python3 scripts/dev/check-rdata-citations.py

`WE_BINARY` 가 없으면 아무것도 검사하지 않고 0 으로 끝난다(사람이 못 돌리는 검사를
초록으로 위장하지 않도록, 그 사실을 화면에 찍는다).
"""
import os
import re
import struct
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
IMAGE_BASE = 0x140000000
FILE_OFFSET_DELTA = 0x1200

# `@0x48e1c0` 처럼 짧은 RVA 형태만 본다. `0x1401c0af0`(.text VA)은 대상이 아니다.
CITATION = re.compile(r"@0x(4[0-9a-f]{5})\b")
# 주변에서 뽑을 토큰: "key" 또는 `key` 또는 맨 소문자 식별자.
TOKEN = re.compile(r'"([A-Za-z_][\w .\-]{1,40})"|`([A-Za-z_][\w .\-]{1,40})`')
CONTEXT = 120


class Binary:
    def __init__(self, path):
        d = open(path, "rb").read()
        self.d = d
        e = struct.unpack_from("<I", d, 0x3C)[0]
        nsec = struct.unpack_from("<H", d, e + 6)[0]
        optsz = struct.unpack_from("<H", d, e + 20)[0]
        self.sections = []
        for i in range(nsec):
            o = e + 24 + optsz + 40 * i
            vsz, va, rawsz, rawoff = struct.unpack_from("<IIII", d, o + 8)
            self.sections.append((va, vsz, rawoff, rawsz))

    def cstring(self, va):
        r = va - IMAGE_BASE
        for va0, vsz, rawoff, rawsz in self.sections:
            if va0 <= r < va0 + max(vsz, rawsz):
                off = rawoff + (r - va0)
                if off >= len(self.d):
                    return None
                end = self.d.find(b"\0", off, off + 256)
                if end < 0:
                    return None
                raw = self.d[off:end]
                try:
                    s = raw.decode("ascii")
                except UnicodeDecodeError:
                    return None
                # 셰이더 shim 처럼 개행이 든 블록도 실재하는 C 문자열이다 — `isprintable()` 은
                # `\n` 을 거짓으로 보므로 개행·탭을 지운 뒤 판정한다.
                return s if s.replace("\n", "").replace("\t", "").isprintable() else None
        return None


def source_files():
    for root in ("Sources", "Tests", "docs"):
        base = os.path.join(REPO, root)
        for dirpath, _, names in os.walk(base):
            for n in sorted(names):
                if n.endswith((".swift", ".md")):
                    yield os.path.join(dirpath, n)


def tokens_near(text, pos):
    lo, hi = max(0, pos - CONTEXT), min(len(text), pos + CONTEXT)
    out = []
    for m in TOKEN.finditer(text[lo:hi]):
        out.append(m.group(1) or m.group(2))
    return out


def main():
    binpath = os.environ.get("WE_BINARY")
    if not binpath or not os.path.isfile(binpath):
        print("[rdata-citations] WE_BINARY 가 없다 — 검사하지 않았다(로컬 전용 도구).")
        print("  사용법: WE_BINARY=/path/to/wallpaper64.exe python3 scripts/dev/check-rdata-citations.py")
        return 0
    b = Binary(binpath)

    offset_as_rva, unresolved, ok = [], [], 0
    for path in source_files():
        try:
            text = open(path, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        rel = os.path.relpath(path, REPO)
        for m in CITATION.finditer(text):
            rva = int(m.group(1), 16)
            line = text[:m.start()].count("\n") + 1
            direct = b.cstring(IMAGE_BASE + rva)
            shifted = b.cstring(IMAGE_BASE + rva + FILE_OFFSET_DELTA)
            near = tokens_near(text, m.start())
            # UTF-16LE 문자열 인용은 C 문자열 검사 대상이 아니다(1바이트씩 읽으면 'X' 같은
            # 한 글자가 나온다). 주변에 그 표기가 있으면 건너뛴다 — 예: sweep-2026-08-19.md.
            if "UTF-16" in text[max(0, m.start() - 60):m.start() + 20]:
                continue
            lo = text.rfind("\n", 0, m.start()) + 1
            hi = text.find("\n", m.start())
            around = text[max(0, lo - 400):hi if hi > 0 else len(text)]
            # 토큰 일치가 1순위, 없으면 주변 산문에 그 문자열이 그대로 박혀 있는지 본다
            # (키 이름을 따옴표 없이 적은 주석이 많다).
            def seen(v):
                return v is not None and len(v) >= 3 and (any(t == v for t in near) or v in around)
            hit_direct, hit_shift = seen(direct), seen(shifted)
            if hit_direct:
                ok += 1
            elif hit_shift:
                offset_as_rva.append((rel, line, rva, direct, shifted))
            else:
                unresolved.append((rel, line, rva, direct, shifted, near[:4]))

    if offset_as_rva:
        print("[rdata-citations] 파일 오프셋을 RVA 로 적은 인용")
        for rel, line, rva, direct, shifted, in offset_as_rva:
            print(f"  {rel}:{line}  @0x{rva:x} → {direct!r} (엉뚱)  ·  +0x1200 = {shifted!r} (맞음)")
            print(f"      → @0x{rva + FILE_OFFSET_DELTA:x} 로 고칠 것")
    if unresolved:
        print("\n[rdata-citations] 미해결 — 사람이 볼 것(문자열 인용이 아닐 수도 있다)")
        for rel, line, rva, direct, shifted, near in unresolved:
            print(f"  {rel}:{line}  @0x{rva:x}")
            print(f"      직접={direct!r}  +0x1200={shifted!r}  주변토큰={near}")

    print(f"\n[rdata-citations] 확인 {ok}건 · 오프셋오기 {len(offset_as_rva)}건 · "
          f"미해결 {len(unresolved)}건")
    return 1 if offset_as_rva else 0


if __name__ == "__main__":
    sys.exit(main())
