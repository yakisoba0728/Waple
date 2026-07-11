import Foundation

// WapleCore JSON 숫자 파싱 공용 헬퍼(자유함수). 종전 ParticleSystem / SceneDocument /
// PropertyAnimation 이 각자 들고 있던 3벌 중복을 통합 — 유한성 검사는 여기서 단일화하되,
// "관용 폭"(문자열 허용 여부·바인딩 언랩 여부)은 호출부 규약별 별개 함수로 보존한다.
//   - strict*: Double/Int 만(문자열 거부) — 파티클·애니 키프레임 규약.
//   - lenient*: 문자열 숫자도 허용 — 씬 규약(실물 씬에 "35" 같은 문자열 타입 존재).
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
func safeInt(_ d: Double) -> Int? {
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
