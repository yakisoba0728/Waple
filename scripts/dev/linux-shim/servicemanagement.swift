// 리눅스용 **ServiceManagement 대역 선언**(shim). 타입체크 전용 — 동작하지 않는다.
// 배경·규약은 `metal.swift` 머리말과 같다.
//
// 유일한 호출부는 `Sources/Waple/LoginItemController.swift`(로그인 시 자동 시작)다.
// 쓰는 것은 `SMAppService.mainApp` · `.status` · `register()` · `unregister()` 넷뿐이다.
import Foundation

/// 실제(macOS 13+): `@available(macOS 13.0, *) open class SMAppService: NSObject {
///          open class var mainApp: SMAppService { get }
///          open var status: SMAppService.Status { get }
///          open func register() throws
///          open func unregister() throws }`
open class SMAppService: NSObject {
    /// 실제: `public enum Status: Int, @unchecked Sendable {
    ///          case notRegistered = 0, enabled = 1, requiresApproval = 2, notFound = 3 }`
    /// **`Equatable` 이 필요하다** — `SettingsViewModelTests:252` 가 `XCTAssertEqual` 로 비교하고,
    /// 호출부도 `status == .enabled` 로 가른다(`RawRepresentable` 이 합성해 주지만 명시해 둔다).
    public enum Status: Int, Equatable {
        case notRegistered = 0
        case enabled = 1
        case requiresApproval = 2
        case notFound = 3
    }
    public static var mainApp: SMAppService { SMAppService() }
    public var status: Status { .notRegistered }
    open func register() throws {}
    open func unregister() throws {}
}
