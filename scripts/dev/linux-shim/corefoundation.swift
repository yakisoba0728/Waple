import Foundation
// 리눅스 로컬 테스트용 CoreFoundation 스텁.
typealias CFAbsoluteTime = Double
func CFAbsoluteTimeGetCurrent() -> CFAbsoluteTime { Date().timeIntervalSinceReferenceDate }
/// macOS 는 `CFGetTypeID(n) == CFBooleanGetTypeID()` 로 JSON 의 true/false 를 숫자와 가른다.
/// 리눅스에는 그 타입 태그가 없으므로 `objCType == "c"`(char) 로 같은 판정을 한다 —
/// EffectManifest.swift:455 주석이 그 규약을 이미 적어 두고 있다.
private let boolTypeID: UInt = 1
private let otherTypeID: UInt = 0
func CFBooleanGetTypeID() -> UInt { boolTypeID }
func CFGetTypeID(_ cf: AnyObject) -> UInt {
    guard let n = cf as? NSNumber else { return otherTypeID }
    return String(cString: n.objCType) == "c" ? boolTypeID : otherTypeID
}
