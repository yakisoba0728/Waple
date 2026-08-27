// 리눅스용 **IOKit 전원 대역 선언**(shim). 타입체크 전용.
//
// 사용처: `Sources/Waple/PlaybackObservers.swift` 의 `onBattery` 축 —
// WE 재생정책 `playbackonbattery` 가 보는 그 상태다(플래그 `0x1404e52e4` bit4,
// 평가기 `0x14006d28c–0x14006d296`).
//
// **여기 값은 전부 가짜다.** `IOPSCopyPowerSourcesInfo()` 는 항상 nil 을 돌려주므로 이 심으로
// 타입체크한 코드는 리눅스에서 "AC 전원" 으로만 판정된다 — 그건 **동작 검증이 아니다.**
// `darwin.swift` 머리말과 같은 규율이다: 흉내 내면 "리눅스에서 돌더라" 는 잘못된 인상을 준다.
// 배터리 판정이 실제로 맞는지는 macOS 실기에서만 확인할 수 있다(CI 러너도 배터리가 없다).
//
// 실제 헤더: `IOKit/ps/IOPowerSources.h` · `IOKit/ps/IOPSKeys.h`
@_exported import Foundation

// MARK: - CF 타입: **일부러 실물과 다르게 둔다**
//
// 리눅스 swift-corelibs 의 `CoreFoundation` 에도 `CFTypeRef`·`CFString` 이 실재한다. 그런데
// 그것을 쓰면 **호출부가 양쪽에서 달라진다** — 애플의 `CFString` 은 `String` 과 toll-free
// 브리징이라 `takeUnretainedValue() as String` 이 서는데, 리눅스 것은 브리징이 없어
// `error: 'CFString' is not convertible to 'String'` 이다(실측).
//
// 심의 목적은 **macOS 에서 쓸 그 코드가 그대로 타입체크되는 것**이므로, 여기서는 브리징이
// 되는 타입으로 바꿔 둔다. 값·표현이 실물과 다른 것은 이 심의 다른 모든 부분과 같고
// (`darwin.swift` 의 `task_vm_info_data_t` 가 필드 하나만 갖는 것과 같은 성질),
// 그 대가로 호출부 한 줄이 두 플랫폼에서 같은 모양이 된다.
/// 실제: `public typealias CFTypeRef = AnyObject`
public typealias CFTypeRef = AnyObject
/// 실제: `CFString` 은 CF 의 불투명 클래스이고 `String` 과 toll-free 브리징된다.
/// 여기서는 그 브리징 성질만 재현하려고 `NSString` 으로 둔다.
public typealias CFString = NSString

/// 실제: `public func IOPSCopyPowerSourcesInfo() -> Unmanaged<CFTypeRef>?`
///
/// 반환이 `Unmanaged` 라는 것이 호출부에 그대로 드러나야 한다 — 애플에서는
/// `takeRetainedValue()` 를 빼먹으면 누수이고, 그 실수는 타입이 잡아 준다.
public func IOPSCopyPowerSourcesInfo() -> Unmanaged<CFTypeRef>? { nil }

/// 실제: `public func IOPSGetProvidingPowerSourceType(_ snapshot: CFTypeRef?) -> Unmanaged<CFString>?`
///
/// 애플은 `snapshot` 이 nil 이면 **시스템 전체**를 보고 답한다. 그래서 호출부가
/// `IOPSCopyPowerSourcesInfo()` 없이 이것만 불러도 정답이 나온다 — 실제 관측자가 그렇게 한다.
public func IOPSGetProvidingPowerSourceType(_ snapshot: CFTypeRef?) -> Unmanaged<CFString>? { nil }

/// 실제: `IOPSKeys.h` 의 `#define kIOPMBatteryPowerKey "Battery Power"` — 스위프트에는 `String` 으로 온다.
public let kIOPMBatteryPowerKey: String = "Battery Power"
/// 실제: `#define kIOPMACPowerKey "AC Power"`
public let kIOPMACPowerKey: String = "AC Power"
/// 실제: `#define kIOPMUPSPowerKey "UPS Power"`
public let kIOPMUPSPowerKey: String = "UPS Power"
