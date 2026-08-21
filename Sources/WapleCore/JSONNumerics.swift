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
//   - *UInt32: **폭**이 다른 넷째 축이다. `asFloat`/`asInt`/`asInt64` 가 아니라
//     `asUInt`(`0x140085ee0`)로 읽는 자리가 실물에 많다(게이트 93자리 중 **35자리**) —
//     그쪽은 하위 32비트로 잘린다. `strictUInt32`(게이트 없음)/`numericUInt32`(게이트 있음).
//   - {value} 바인딩 언랩은 unwrapValue 로 분리 — 씬 쪽만 경유한다(파티클·애니는 언랩 없음).

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
///   · `asInt`(`0x140085f70`) 도 태그 5 에서 `cmp byte [rcx],al; setne al`(`0x140085f95`) → **0/1**.
///     `asUInt`(`0x140085ee0`)·`asInt64`(`0x140086000`)도 같다 — 숫자 접근자 **전부** 태그 5 를 받는다.
///   · 태그 4(string)·6·7 만 "Value is not convertible to float."(`0x140478868`) 로 abort 한다.
/// 그러니 게이트가 **없는** 자리에서는 `{"k":true}` 가 1.0 인 것이 실물 동작이고,
/// `strictFloat` 의 관용은 버그가 아니라 정합이다. 게이트는 자리마다 다르므로 자리별로 고른다.
///
/// 전수(wallpaper64.exe `.text`): `asFloat` 호출 **243** · `asInt` **79** 인데
/// 게이트는 `call isNumeric` **12** + 인라인 전개(`[reg+8]` 태그 적재 후 `dec;cmp 2`) **81** = **93**
/// 뿐이고, 그 93 에는 float/int 가 아닌 자리(`asUInt` 35 · `asInt64` 4)도 섞여 있다.
/// 즉 숫자 자리의 대다수는 게이트가 없다. 자리별 실측(93자리 전건 키 귀속)은
/// `docs/re/json-number-tags.md` §2.
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

// MARK: 폭 축 — jsoncpp `asUInt`(하위 32비트)

/// **왜 넷째 축이 필요한가.** 종전 사다리(`numeric* ⊂ strict* ⊂ lenient*`)는 "관용 폭" 만
/// 다뤘고 **값의 폭**은 전부 Swift `Int`(64비트)로 뭉쳐 있었다. 그런데 실물의 게이트 93자리를
/// 전건 귀속해 보면 접근자가 갈린다 — `asFloat` **42** · **`asUInt` 35** · `asInt64` 4 ·
/// `asInt` 2 · `asBool` 2 · `asString` 1 · 기타 7(2026-08-21 재전수, `docs/re/json-number-tags.md` §2).
/// 즉 게이트가 붙은 자리의 **38%가 `asUInt`** 인데 Waple 에는 그 폭을 재현하는 헬퍼가 없었다.
///
/// `asUInt`(`0x140085ee0`)의 태그별 동작(직접 디스어셈, 함수 `0x140085ee0`–`0x140085f6c`):
///
/// | 태그 | 동작 | VA |
/// | --- | --- | --- |
/// | 0 null | `xor eax,eax` → 0 | `0x140085f28` |
/// | **1 int / 2 uint** | `mov eax, dword [rcx]` — 64비트 슬롯의 **하위 32비트**만 | `0x140085f1e` |
/// | 3 real | `cvttsd2si eax`(**32비트**, 0 방향 절삭) | `0x140085f12` |
/// | 5 boolean | `cmp byte [rcx],al; setne al` → 0/1 | `0x140085f03`–`0x140085f07` |
/// | 4/6/7 | `"Value is not convertible to Int."`(`0x140478740`) → abort | `0x140085f32` |
///
/// 하위 32비트 절삭은 **음수에서 눈에 보인다**: `order: -2` 는 `0xFFFFFFFE` = 4294967294 가 된다.
/// 실측 도달 있음 — `설치본 projects/defaultprojects/eagleflag/project.json` 의
/// `general.properties.flagcolor1.order = -2` · `flagcolor2.order = -1`(그 자리는
/// `0x140118b85`/`0x140119d00` 에서 게이트 + `asUInt`). 다만 그 키를 읽는 경로가 둘이라
/// (네이티브 `asUInt` vs 브라우저 UI 의 JS `sort((a,b)=>a.order-b.order)`) 어느 쪽이 화면을
/// 정하는지는 별건이다 — `WallpaperProperties.swift:138` 이 그 갈림을 이미 적고 있다.
///
/// 코퍼스 폭 실측(동봉 WEAssets 1,698 + 설치본 `assets` 1,698 + 설치본 `projects` 259 =
/// **3,655 파일**, 숫자 리터럴 33,753개): **Int32 범위 밖 정수 0건** · `|x| ≥ 2^31` 실수 **0건** ·
/// 음수 정수 131건. 즉 절삭이 값을 바꾸는 경우는 **음수뿐**이다.

/// 태그 1/2 경로 — 64비트 정수의 하위 32비트를 부호 없이 재해석한다(`mov eax,[rcx]`).
func wrapUInt32(_ i: Int) -> Int { Int(UInt32(truncatingIfNeeded: i)) }

/// 태그 3 경로 — `cvttsd2si eax`(0 방향 절삭 후 32비트).
///
/// **범위 밖은 nil 로 돌려준다(의도적 하드닝).** x86 은 변환 결과가 32비트에 안 들어가면
/// (NaN·±Inf 포함) "integer indefinite" `0x80000000` 을 내는데, 그건 MXCSR 의 invalid 마스크에
/// 달린 값이고 우리가 이 컨테이너에서 실행으로 확인할 수단이 없다(추정). 값을 지어내는 대신
/// `safeInt`/`safeFloat` 와 같은 규약으로 거절한다 — 코퍼스 도달 **0건**(위 폭 실측).
func wrapUInt32(_ d: Double) -> Int? {
    guard d.isFinite else { return nil }
    let t = d.rounded(.towardZero)
    guard t >= -2_147_483_648, t <= 2_147_483_647 else { return nil }
    return Int(UInt32(bitPattern: Int32(t)))
}

/// 게이트 **없는** `asUInt` 자리 — 불리언을 1/0 으로 받는다(`0x140085f07 setne`).
/// 예: 씬 `general.alignment.value`(`0x140181fba`) · 씬 `general.lightconfig.*`
/// (`0x140187775` 이후 — 그 함수의 게이트 3자리는 `refreshdelay`·`orthogonalprojection.width/height`
/// 뿐이다) · 이펙트 fbo `scale`/`width`/`height`/`fit`.
func strictUInt32(_ v: Any?) -> Int? {
    if let i = v as? Int { return wrapUInt32(i) }
    if let d = v as? Double { return wrapUInt32(d) }
    return nil
}

/// 게이트 **있는** `asUInt` 자리 — 태그 1/2/3 만. 관용 폭 순서: `numericUInt32` ⊂ `strictUInt32`.
/// 예: `general.refreshdelay`(`0x1401874cc`) · `general.orthogonalprojection.width/height`
/// (`0x140187578`·`0x140187587`) · `general.properties.<name>.order`(`0x140118b85`·`0x140119d00`) ·
/// 이펙트 `condition.value`(`0x1401e6689`) · 이펙트 `bind[].index`(`0x1401e7ea9`).
func numericUInt32(_ v: Any?) -> Int? { isJSONNumeric(v) ? strictUInt32(v) : nil }

/// `lenientUInt32` 는 **일부러 없다.** 실물은 태그 4(string)에서 abort 하고, Waple 쪽에도
/// `asUInt` 자리를 문자열로 읽는 호출부가 하나도 없다(전수 확인). 사다리를 대칭으로 만들려고
/// 호출부 없는 함수를 늘리지 않는다 — 필요해지는 자리가 생기면 그때 근거와 함께 추가해라.

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
