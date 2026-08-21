import Foundation

// WapleCore JSON 숫자 파싱 공용 헬퍼(자유함수). 종전 ParticleSystem / SceneDocument /
// PropertyAnimation 이 각자 들고 있던 3벌 중복을 통합 — 유한성 검사는 여기서 단일화하되,
// "관용 폭"(문자열 허용 여부·바인딩 언랩 여부)은 호출부 규약별 별개 함수로 보존한다.
//   - numeric*: jsoncpp `isNumeric()`(태그 1/2/3) 게이트 — **불리언도 거부**. 실물이 값 접근 전에
//     `0x140088880`(또는 그 인라인 전개)을 부르는 자리 전용 — 파티클 def `starttime`/`flags`/
//     `sequencemultiplier`/`maxcount` 와 `rotationrandom.min/max`. (프로퍼티 애니 키프레임도
//     같은 부류지만 그쪽은 `EffectManifest.isJSONBool` 게이트로 이미 닫혀 있다.)
//   - strict*: Double/Int 만(문자열 거부) — 파티클·애니 키프레임 규약.
//     **불리언은 통과시킨다** — 게이트 없는 자리에서 실물 `asFloat`/`asInt` 가 1/0 을 내기 때문이다.
//   - lenient*: 문자열 숫자도 허용 — 씬 규약(실물 씬에 "35" 같은 문자열 타입 존재).
//   - *Int32 / *UInt32: **폭**이 다른 넷째 축이다. `asFloat`/`asInt64` 가 아니라 32비트로
//     좁히는 접근자(`asInt` `0x140085ee0` · `asUInt` `0x140085f70`)로 읽는 자리가 실물에 많다.
//     게이트 93자리 중 **35자리가 `asInt`**(부호 있는 하위 32비트)다.
//     `strictInt32`/`strictUInt32`(게이트 없음) · `numericInt32`/`numericUInt32`(게이트 있음).
//   - {value} 바인딩 언랩은 unwrapValue 로 분리 — 씬 쪽만 경유한다(파티클·애니는 언랩 없음).
//
// **[2026-08-21 정정 — 접근자 두 쌍의 이름이 바뀌어 있었다]**
// 종전 이 파일(과 `docs/re/json-number-tags.md`)은 `asInt`/`asUInt` 와 `asInt64`/`asUInt64` 의
// VA 를 **서로 바꿔** 적고 있었다. 판정은 각 함수가 실패 경로에서 `_wassert` 로 넘기는 문자열과
// jsoncpp 원본의 줄 번호다(`_wassert(L"false && oss.str().c_str()",
// L"D:\dev\we\windows\src\json\src\json_value.cpp", line)` — 파일 경로 리터럴 `0x140478640`,
// 식 리터럴 `0x140478768`):
//
// | 함수 | 실패 문자열 | 줄 | 진짜 이름 | 종전 표기 |
// | --- | --- | ---: | --- | --- |
// | `0x140085cc0` | "Type is not convertible to string"(`0x1404786e8`) | 696 | `asString` | 같음 |
// | `0x140085ee0` | "Value is not convertible to Int."(`0x140478740`) | 719 | **`asInt`** | asUInt |
// | `0x140085f70` | "Value is not convertible to UInt."(`0x1404787c8`) | 741 | **`asUInt`** | asInt |
// | `0x1400860c0` | "Value is not convertible to Int64."(`0x1404787a0`) | 769 | **`asInt64`** | asUInt64 |
// | `0x140086000` | "Value is not convertible to UInt64."(`0x140478818`) | 790 | **`asUInt64`** | asInt64 |
// | `0x140086150` | "Value is not convertible to double."(`0x1404787f0`) | 829 | `asDouble` | 같음 |
// | `0x140086220` | "Value is not convertible to float."(`0x140478868`) | 852 | `asFloat` | 같음 |
// | `0x140086300` | "Value is not convertible to bool."(`0x140478840`) | 873 | `asBool` | 같음 |
//
// 줄 번호가 **원본 소스 순서**(asString → asInt → asUInt → asInt64 → asUInt64 → asDouble →
// asFloat → asBool)와 정확히 맞는다. 변환 관용구도 같은 방향으로 갈린다 —
// `0x140085ee0` 의 태그 3 은 `cvttsd2si eax`(**32비트**, `0x140085f12`)이고
// `0x140085f70` 의 태그 3 은 `cvttsd2si rax`(**64비트**, `0x140085fa2`) 뒤 `eax` 반환이다.
// 그것이 MSVC 가 `int(double)` 과 `unsigned(double)` 를 내리는 방식 그대로다.
//
// **왜 중요한가.** 게이트 35자리의 접근자가 `asUInt`(부호 없음)가 아니라 `asInt`(부호 있음)라서
// **음수가 감기지 않는다.** `general.properties.<k>.order = -2` 는 실물에서도 −2 다
// (엔진 자신이 `order − 20`(`0x140118bb1` `sub eax,0x14` → `0x140118bb4` `movsxd rcx,eax`)과
// `order + 100`(`0x14010a80c` `add eax,0x64`, 앞의 `0x14010a807 cmp eax,0x64` + `jge` 는
// **부호 있는** 비교다)로 음수·양수를 오가며 **다시 써 넣는다**). 자세한 것은
// `docs/re/json-number-tags.md` §9.

/// 바인딩 객체 {"animation":..., "value": X} → X(정적 값), 아니면 원값.
/// 실물 씬은 origin/alpha 등 대부분의 프로퍼티에 이 형태를 쓴다.
func unwrapValue(_ v: Any?) -> Any? {
    if let d = v as? [String: Any], let inner = d["value"] { return inner }
    return v
}

// MARK: 유한성 프리미티브

/// Double → Float. NaN/Inf 또는 Float 범위 밖이면 nil.
func safeFloat(_ d: Double) -> Float? {
    guard d.isFinite, d >= -Double(Float.greatestFiniteMagnitude),
          d <= Double(Float.greatestFiniteMagnitude) else { return nil }
    return Float(d)
}
/// 문자열 → Float. 파스 불가·비유한("inf"/"nan" 포함)이면 nil.
func safeFloat(_ s: String) -> Float? {
    guard let f = Float(s), f.isFinite else { return nil }
    return f
}
/// Double → Int. 비유한·Int 범위 밖이면 nil.
///
/// **모듈 밖으로 연 이유**(F530-sweep): 신뢰 경계 밖 JSON 숫자를 정수로 좁히는 자리가
/// WapleRender·WapleCompat 에도 12곳 있었는데, 가드가 WapleCore 안에만 있어서 전부
/// 맨 `Int()`/`Int32()` 를 썼다. Swift 의 `Int(Float)` 는 범위를 넘으면 클램프가 아니라
/// **트랩**이므로 워크샵 콘텐츠가 프로세스를 죽일 수 있었다.
/// 헬퍼를 하나 더 만드는 대신 이 정본 하나로 모으는 게 핵심이다 — 스윕이 확인한
/// 지배적 실패 방식은 "가드가 없다" 가 아니라 "가드가 넷인데 아무도 안 거친다" 였다.
/// 새로 좁히는 자리는 `scripts/spec/check_int_narrowing.py` 가 CI 에서 막는다.
public func safeInt(_ d: Double) -> Int? {
    guard d.isFinite, d >= Double(Int.min), d < Double(Int.max) else { return nil }
    return Int(d)
}

// MARK: 관용 폭별 스칼라

/// Double/Int 만 허용(문자열 거부) — 파티클·애니 키프레임 규약.
func strictFloat(_ v: Any?) -> Float? {
    if let d = v as? Double { return safeFloat(d) }
    if let i = v as? Int { return Float(i) }
    return nil
}
/// Int/Double 만 허용(문자열 거부) — 파티클 규약.
func strictInt(_ v: Any?) -> Int? {
    if let i = v as? Int { return i }
    if let d = v as? Double { return safeInt(d) }
    return nil
}
/// 문자열 숫자도 허용 — 씬 규약(언랩은 호출부에서 unwrapValue 경유).
func lenientFloat(_ v: Any?) -> Float? {
    if let d = v as? Double { return safeFloat(d) }
    if let i = v as? Int { return Float(i) }
    if let s = v as? String { return safeFloat(s) }
    return nil
}
/// 문자열 숫자도 허용하는 Int — 씬 규약.
func lenientInt(_ v: Any?) -> Int? {
    if let i = v as? Int { return i }
    if let d = v as? Double { return safeInt(d) }
    if let s = v as? String { return Int(s) }
    return nil
}

// MARK: 타입 태그 게이트(jsoncpp `isNumeric`)

/// jsoncpp `Json::Value::isNumeric()` — **`0x140088880`**:
/// `mov eax,[rcx+8]; movzx eax,al; dec eax; cmp eax,2; setbe al; ret`.
/// 즉 타입 태그 **1/2/3(int/uint/real)만** 참이고 0(null)·4(string)·**5(boolean)**·6/7(array/object)
/// 은 거짓이다. 호출부가 이 술어를 먼저 부르는 자리에서만 불리언이 숫자로 승격되지 **않는다**.
///
/// **왜 `strict*` 를 그냥 고치지 않았나** — 실물의 값 접근자 자체는 불리언을 받는다:
///   · `asFloat`(`0x140086220`) 는 태그 5 에서 `cmp byte [rcx],0` → 0 이면 0.0f, 아니면
///     `movss xmm0, [0x140492704]`(**1.0f**) 로 내려온다(`0x140086243`–`0x140086248`).
///   · `asInt`(`0x140085ee0`) 도 태그 5 에서 `cmp byte [rcx],al; setne al`(`0x140085f05`) → **0/1**.
///     `asUInt`(`0x140085f70` @`0x140085f95`)·`asInt64`(`0x1400860c0` @`0x1400860e5`)·
///     `asUInt64`(`0x140086000` @`0x140086025`)도 같다 — 숫자 접근자 **전부** 태그 5 를 받는다.
///   · 태그 4(string)·6·7 만 "Value is not convertible to float."(`0x140478868`) 로 abort 한다.
/// 그러니 게이트가 **없는** 자리에서는 `{"k":true}` 가 1.0 인 것이 실물 동작이고,
/// `strictFloat` 의 관용은 버그가 아니라 정합이다. 게이트는 자리마다 다르므로 자리별로 고른다.
///
/// 전수(wallpaper64.exe `.text`, `e8 rel32` 대상 계수): `asFloat` **243** · `asString` **193** ·
/// `asBool` **148** · `asUInt` **79** · `asInt` **74** · `asUInt64` **10** · `asInt64` **1** ·
/// `asDouble` **1**. (종전 "asInt 79" 는 이름이 바뀐 값이다 — 79 는 `0x140085f70` = `asUInt` 다.)
/// `isNumeric` 게이트는 `call` **12** + 인라인 전개(`[reg+8]` 태그 적재 후 `dec;cmp 2`) **81** =
/// **93** 뿐이고, 그 93 의 접근자는 `asFloat` 42 · **`asInt` 35** · `asUInt64` 4 · `asUInt` 2 ·
/// `asBool` 2 · `asString` 1 · 기타 7 이다(이름 정정 반영). 자리별 실측은
/// `docs/re/json-number-tags.md` §2·§9.
///
/// **[2026-08-21 정정] `isNumeric` 만 세면 게이트 전수가 아니다.** 같은 술어 무리에 네 개가
/// 더 있고 **전부 out-of-line 호출이 실재**한다(계수는 `e8 rel32` 전수):
///
/// | 술어 | VA | 참인 태그 | 호출 |
/// | --- | --- | --- | ---: |
/// | `isBool` | `0x1400886d0` | 5 만 | 9 |
/// | **`isInt`** | `0x1400886e0` | 1(−2³¹…2³¹−1) · 2(≤2³¹−1) · 3(범위 안 **정수만**) | **20** |
/// | **`isUInt`** | `0x140088760` | 1(0…2³²−1) · 2(≤2³²−1) · 3(범위 안 **정수만**) | **13** |
/// | `isUInt64` | `0x140088800` | 1(≥0) · 2 · 3(0…2⁶⁴, 정수만) | 3 |
/// | `isNumeric` | `0x140088880` | 1/2/3 | 12 |
///
/// `isInt`/`isUInt`/`isUInt64` 는 태그 3 에서 `modf`(`0x1402d3b50`)를 불러 **소수부가 0 인지**까지
/// 본다(`0x140088718`·`0x14008879c`·`0x140088843`) — `isNumeric` 보다 훨씬 좁다.
/// 이 넷을 세지 않아 종전 문서가 "게이트 없음" 이라고 적은 자리가 셋 있었고 전부 오귀속이었다:
/// 씬 `general.alignment.value`(`0x140181f98` `isInt`) · 이펙트 fbo `scale`/`width`/`height`/`fit`
/// (`0x1401e77d1`·`0x1401e77f3`·`0x1401e7823`·`0x1401e7846` 전부 `isInt`) ·
/// `general.lightconfig.*`(`0x140187b5e` 외 9자리 `isUInt`).
///
/// **[2026-08-21 재전수] 인라인은 78 이 아니라 81 이다.** 종전 스캔이 `dec` 와 `cmp` 사이에
/// 스필 `mov` 가 끼어든 세 자리를 놓쳤다 — `0x1401a4b17`(부동소수 프로퍼티 바인더,
/// `cmp` 는 `0x1401a4b23`) · `0x1401fcc5d`(`cmp` `0x1401fcc6c`) · `0x1402230fe`
/// (`cmp` `0x14022310a`). 뒤 둘은 `find("animation")` 결과를 게이트한다.
/// 반대로 `asFloat`/`asInt`/`asUInt`/`asInt64`/`asUInt64`/`asDouble`/`asBool` **본체**의
/// `sub edx,1; je … cmp edx,2` 는 게이트가 아니라 태그 **스위치**다(사이에 `je` 가 있다).
///
/// **판정 방식** — `NSNumber` 면 `objCType`("c" = boolean)이 정본이다.
/// `JSONSerialization` 은 JSON `true` 를 `__NSCFBoolean` 으로 주는데 그 값은
/// `as? Int`/`as? Double` 이 **성공**한다(리눅스 실측: `strictFloat(json true) == 1.0`).
/// 반대로 Swift 리터럴 `true` 는 `Bool` 로 남아 `as? Double` 이 nil 이다 —
/// **이 경로를 테스트로 재현하려면 반드시 `JSONSerialization` 을 거쳐야 한다**.
/// `NSNumber` 브리지가 없는 값(순수 Swift `Bool`)까지 덮으려고 뒤의 두 줄을 둔다.
/// (`EffectManifest.isJSONBool` 이 같은 판정을 `objCType` 으로 이미 하고 있다 — 같은 규약이다.)
func isJSONNumeric(_ v: Any?) -> Bool {
    guard let v else { return false }
    if let n = v as? NSNumber { return n.objCType.pointee != 0x63 }
    if v is Bool { return false }
    return v is Int || v is Double
}

/// `isNumeric` 게이트를 통과한 값만 `strictFloat` 로 읽는다 — **태그 게이트가 실재하는 자리 전용**.
/// 관용 폭 순서: `numericFloat` ⊂ `strictFloat` ⊂ `lenientFloat`.
func numericFloat(_ v: Any?) -> Float? { isJSONNumeric(v) ? strictFloat(v) : nil }
/// `numericFloat` 의 Int 판.
func numericInt(_ v: Any?) -> Int? { isJSONNumeric(v) ? strictInt(v) : nil }

// MARK: 비숫자 접근자의 강제 규약 — `asBool` / `asString`(문서 전용, 여기 구현 없음)
//
// 임무가 "정수 오버플로 · 문자열→수 변환 실패 · bool 강제의 경계" 를 확정하라는 것이었다.
// 앞의 둘은 위 표가 답했고(오버플로는 **검사 없이 절삭** — jsoncpp 의 `JSON_ASSERT_MESSAGE(isInt(),…)`
// 범위 단언이 이 빌드에는 **없다**. 여덟 접근자 전부 명령 흐름에 범위 비교가 한 줄도 없다.
// 문자열→수는 **변환 자체가 없다** — 태그 4 는 곧장 abort 다), 나머지 둘이 이것이다.
//
// **`asBool`(`0x140086300`–`0x14008639d`)**:
//
// | 태그 | 동작 | VA |
// | --- | --- | --- |
// | 0 null | `xor al,al` → false | `0x14008635a` |
// | 1 int / 2 uint | `cmp qword [rcx],0; setne al` — **64비트** 비교 | `0x14008634b`–`0x14008634f` |
// | 3 real | `_dclass`(`0x1402d68e0` → `0x1402e7cc0`) 뒤 `test ecx,0xfffffffd; setne al` | `0x14008632e`–`0x140086340` |
// | 5 boolean | `movzx eax, byte [rcx]` | `0x140086323` |
// | 4/6/7 | `"Value is not convertible to bool."`(`0x140478840`) → abort | `0x140086364` |
//
// 태그 3 이 특이하다. `_dclass` 는 NaN=2 · INF=1 · ZERO=0 · SUBNORMAL=−2 · NORMAL=−1 을 내고
// (`0x1402e7cf6 inc ax` / `0x1402e7d11 and ax,0xfffe` / `0x1402e7d16 mov eax,-1`),
// `test ecx, ~2` 는 **0 과 2 만** 거짓으로 만든다. 즉 **`NaN` 은 false 이고 ±0 도 false**,
// 그 밖(INF·정규·비정규)은 true 다. C++ 의 `double → bool` 이라면 NaN 이 true 여야 하므로
// 이건 jsoncpp 의 "JavaScript 처럼 0 과 NaN 을 거짓으로 본다" 규약을 명령으로 확인한 것이다.
// **문자열은 abort 다** — `{"visible":{"value":"true"}}` 는 실물에서 죽는다.
//
// **`asString`(`0x140085cc0`–`0x140085e3e`)** 은 방향이 반대다. 태그 0..5 를 **점프 표**
// (`0x140085e40`, 6엔트리 · 디스패치 `0x140085ce2`–`0x140085ced`)로 갈라 전부 문자열을 만든다:
// 0 → `""`(`0x140085cf0`) · 1 → int64 십진(`0x140085db0`) · 2 → uint64 십진(`0x140085dc7`) ·
// 3 → **정밀도 17**(`mov r9d,0x11` `0x140085deb`) · 4 → 복사(`0x140085d12`) ·
// 5 → `"true"`/`"false"`(`0x140474460`/`0x140474458`, `0x140085d8a`–`0x140085d9b`).
// 태그 6/7 만 `"Type is not convertible to string"`(`0x1404786e8`)으로 abort 한다(`0x140085e05`).
// → **숫자 자리는 문자열을 죽이지만 문자열 자리는 숫자를 받아 찍는다.** 비대칭이 규약이다.
// (Waple 은 이 강제를 옮기지 않는다 — 문자열 자리에 숫자가 오는 저작이 코퍼스 도달 0 이고,
//  옮기면 `as? String` 을 쓰는 자리 전부의 계약이 바뀐다. `docs/re/json-number-tags.md` §9.4.)

// MARK: 폭 축 — 32비트로 좁히는 접근자(`asInt` 부호 있음 / `asUInt` 부호 없음)

/// **왜 넷째 축이 필요한가.** 종전 사다리(`numeric* ⊂ strict* ⊂ lenient*`)는 "관용 폭" 만
/// 다뤘고 **값의 폭**은 전부 Swift `Int`(64비트)로 뭉쳐 있었다. 그런데 실물의 게이트 93자리를
/// 전건 귀속해 보면 접근자가 갈린다 — `asFloat` **42** · **`asInt` 35** · `asUInt64` 4 ·
/// `asUInt` 2 · `asBool` 2 · `asString` 1 · 기타 7(`docs/re/json-number-tags.md` §2·§9).
/// 즉 게이트가 붙은 자리의 **38%가 32비트 `asInt`** 인데 Waple 에는 그 폭을 재현하는 헬퍼가 없었다.
///
/// > **[2026-08-21 정정]** 위 35자리를 종전에는 `asUInt` 라고 적었다. 파일 머리의 표대로
/// > `0x140085ee0` 은 **`asInt`**(부호 있음)이고 `0x140085f70` 이 `asUInt` 다. 그래서
/// > **음수는 감기지 않는다** — 아래 두 표를 갈라 둔 이유가 그것이다.
///
/// `asInt`(`0x140085ee0`–`0x140085f6c`)의 태그별 동작(직접 디스어셈):
///
/// | 태그 | 동작 | VA |
/// | --- | --- | --- |
/// | 0 null | `xor eax,eax` → 0 | `0x140085f28` |
/// | **1 int / 2 uint** | `mov eax, dword [rcx]` — 64비트 슬롯의 **하위 32비트**를 **부호 있는** int 로 | `0x140085f1e` |
/// | 3 real | `cvttsd2si eax`(**32비트**, 0 방향 절삭) | `0x140085f12` |
/// | 5 boolean | `cmp byte [rcx],al; setne al` → 0/1 | `0x140085f03`–`0x140085f07` |
/// | 4/6/7 | `"Value is not convertible to Int."`(`0x140478740`) → abort | `0x140085f32` |
///
/// `asUInt`(`0x140085f70`–`0x140085ffc`)는 반환 폭은 같고 태그 3 만 갈린다:
///
/// | 태그 | 동작 | VA |
/// | --- | --- | --- |
/// | 0 null | `xor eax,eax` → 0 | `0x140085fb9` |
/// | 1 int / 2 uint | `mov eax, dword [rcx]` — 같은 비트, **부호 없이** 읽는다 | `0x140085faf` |
/// | 3 real | `cvttsd2si rax`(**64비트**) 뒤 `eax` 반환 = 하위 32비트 | `0x140085fa2` |
/// | 5 boolean | `cmp byte [rcx],al; setne al` → 0/1 | `0x140085f93`–`0x140085f97` |
/// | 4/6/7 | `"Value is not convertible to UInt."`(`0x1404787c8`) → abort | `0x140085fc3` |
///
/// 32비트 절삭이 값을 바꾸는 것은 **음수와 2³² 이상**뿐이다. 코퍼스 폭 실측(동봉 WEAssets 1,698 +
/// 설치본 `assets` 1,698 + 설치본 `projects` 259 = **3,655 파일**, 숫자 리터럴 33,753개):
/// **Int32 범위 밖 정수 0건** · `|x| ≥ 2^31` 실수 **0건** · 음수 정수 131건.
/// 그 131 중 32비트 접근자로 읽히는 것은 `general.properties.<k>.order` 둘뿐이고
/// (설치본 `projects/defaultprojects/eagleflag/project.json` 의 `flagcolor1.order = -2` ·
///  `flagcolor2.order = -1`), 그 자리의 접근자가 **`asInt`** 라 실물에서도 −2/−1 그대로다.
/// → **`order` 를 부호 없이 감으면 안 된다.** 엔진 자신이 음수 `order` 를 써 넣는다(파일 머리 표).

/// 태그 1/2 경로(부호 있음) — 64비트 정수의 하위 32비트를 **부호 있는** int32 로 재해석한다
/// (`mov eax,[rcx]` `0x140085f1e`, 반환형이 `int`).
func wrapInt32(_ i: Int) -> Int { Int(Int32(truncatingIfNeeded: i)) }

/// 태그 3 경로(부호 있음) — `cvttsd2si eax`(`0x140085f12`, 0 방향 절삭 후 **32비트**).
///
/// **범위 밖은 nil 로 돌려준다(의도적 하드닝).** x86 은 변환 결과가 32비트에 안 들어가면
/// (NaN·±Inf 포함) "integer indefinite" `0x80000000` 을 내는데, 그건 MXCSR 의 invalid 마스크에
/// 달린 값이고 우리가 이 컨테이너에서 실행으로 확인할 수단이 없다(**추정**). 값을 지어내는 대신
/// `safeInt`/`safeFloat` 와 같은 규약으로 거절한다 — 코퍼스 도달 **0건**(위 폭 실측).
func wrapInt32(_ d: Double) -> Int? {
    guard d.isFinite else { return nil }
    let t = d.rounded(.towardZero)
    guard t >= -2_147_483_648, t <= 2_147_483_647 else { return nil }
    return Int(Int32(t))
}

/// 게이트 **없는** `asInt` 자리 — 불리언을 1/0 으로 받는다(`0x140085f07 setne`).
/// 게이트가 붙은 `asInt` 자리는 `numericInt32` 를 써라.
func strictInt32(_ v: Any?) -> Int? {
    if let i = v as? Int { return wrapInt32(i) }
    if let d = v as? Double { return wrapInt32(d) }
    return nil
}

/// 게이트 **있는** `asInt` 자리 — 태그 1/2/3 만. 관용 폭 순서: `numericInt32` ⊂ `strictInt32`.
/// 예: `general.refreshdelay`(게이트 `0x1401874cc` → `asInt` `0x1401874d9`) ·
/// `general.orthogonalprojection.width/height`(게이트 `0x140187578`·`0x140187587` →
/// `asInt` `0x14018758f`·`0x1401875a7`, 그 뒤 `cvtdq2ps`(`0x14018759b`)로 **부호 있는** int→float) ·
/// `general.properties.<name>.order`(게이트 `0x140118b85`·`0x140119d00` → `asInt` `0x140118b91`) ·
/// 이펙트 `condition.value`(`0x1401e6689`) · 이펙트 `bind[].index`(`0x1401e7ea9`).
func numericInt32(_ v: Any?) -> Int? { isJSONNumeric(v) ? strictInt32(v) : nil }

/// 태그 1/2 경로(부호 없음) — 하위 32비트를 부호 없이 재해석한다(`mov eax,[rcx]` `0x140085faf`).
func wrapUInt32(_ i: Int) -> Int { Int(UInt32(truncatingIfNeeded: i)) }

/// 태그 3 경로(부호 없음) — `asUInt` 는 `cvttsd2si rax`(**64비트**, `0x140085fa2`)로 자른 뒤
/// `eax`(하위 32비트)를 돌려준다. 그래서 `asInt` 와 달리 **Int32 범위 밖 실수도 값이 나온다**
/// (예: `5000000000.5` → `0x12A05F200` → `0x2A05F200` = 705032704).
///
/// **Int64 범위 밖은 nil 이다(의도적 하드닝).** 그 구간은 `cvttsd2si rax` 가 "integer indefinite"
/// `0x8000000000000000` 을 내는 자리이고(하위 32비트는 0) 우리가 실행으로 확인할 수단이 없다
/// (**추정**). 코퍼스 도달 **0건**.
func wrapUInt32(_ d: Double) -> Int? {
    guard d.isFinite else { return nil }
    let t = d.rounded(.towardZero)
    guard t >= -9_223_372_036_854_775_808, t < 9_223_372_036_854_775_808 else { return nil }
    return Int(UInt32(truncatingIfNeeded: Int(t)))
}

/// 게이트 **없는** `asUInt` 자리 — 불리언을 1/0 으로 받는다(`0x140085f97 setne`).
/// `asUInt` 호출 79자리 중 게이트가 확인된 것은 `isUInt`(`0x140088760`) 13 · `isNumeric` 2 뿐이다.
func strictUInt32(_ v: Any?) -> Int? {
    if let i = v as? Int { return wrapUInt32(i) }
    if let d = v as? Double { return wrapUInt32(d) }
    return nil
}

/// 게이트 **있는** `asUInt` 자리 — 태그 1/2/3 만. 관용 폭 순서: `numericUInt32` ⊂ `strictUInt32`.
/// 실측 자리는 파티클 def `flags`(`0x1401c56e4`)·`maxcount`(`0x1401c578b`) 둘이다
/// (그 둘은 `isNumeric` 게이트다 — `docs/re/json-number-tags.md` §3.1).
func numericUInt32(_ v: Any?) -> Int? { isJSONNumeric(v) ? strictUInt32(v) : nil }

/// `lenientInt32`/`lenientUInt32` 는 **일부러 없다.** 실물은 태그 4(string)에서 abort 하고,
/// Waple 쪽에도 32비트 접근자 자리를 문자열로 읽는 호출부가 하나도 없다(전수 확인).
/// 사다리를 대칭으로 만들려고 호출부 없는 함수를 늘리지 않는다 —
/// 필요해지는 자리가 생기면 그때 근거와 함께 추가해라.

// MARK: 벡터/리스트

/// 공백 구분 숫자 문자열 → [Float]. 파스 불가·비유한 항목은 드롭.
func floatList(_ s: String) -> [Float] {
    s.split(separator: " ").compactMap { safeFloat(String($0)) }
}
/// "x y z" **문자열 전용** Vec3(언랩 없음) — 파티클 규약. 성분 3개 이상이면 앞 3개.
func stringVec3(_ v: Any?) -> Vec3? {
    guard let s = v as? String else { return nil }
    let f = floatList(s)
    return f.count >= 3 ? Vec3(x: f[0], y: f[1], z: f[2]) : nil
}
