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

// MARK: - autoreleasepool  (2026-08-21)
//
// 리눅스 Foundation 에는 아예 없다(실측: `cannot find 'autoreleasepool' in scope`).
// 애플에서는 Darwin/ObjC 런타임이 제공하고 **모든 모듈에서 그냥 보인다**.
//
// 왜 여기(=WapleCore 주입)인가: 실제 사용처 다섯(`WallpaperSchemeHandler` · `DeepScan` ·
// `SnapshotCompare` · `SnapshotPipeline` · `ProfilePipeline`)의 임포트 목록에서 **유일한
// 공통분모가 `WapleCore`** 다. 종전에는 `webkit.swift` 에 있었는데 다섯 중 WebKit 을 임포트하는
// 파일이 하나도 없어서, `--compat` 이 `WapleCompatCore` 를 타입체크하는 순간 전부 터졌다.
//
// **두 곳에 두지 마라.** 같은 시그니처가 두 모듈에 있으면 둘 다 임포트한 파일에서 모호해진다.
/// 실제(Darwin): `@inlinable public func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result`
public func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
