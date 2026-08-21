// 리눅스용 **Security(Keychain) 대역 선언**(shim). 타입체크 전용 — 동작하지 않는다.
// 배경·규약은 `metal.swift` 머리말과 같다.
//
// 유일한 호출부는 `Sources/Waple/WorkshopAPI.swift` 의 `SteamAPIKeyStore`(Steam Web API 키)다.
// `Tests/WapleAppTests/WorkshopAPITests.swift:125~` 가 `delete`/`add` 를 주입해 실제 Keychain
// 없이 실패 경로(ACL 거부 · errSecDuplicateItem)를 검증하므로, **함수 타입이 정확해야** 그
// 주입이 타입체크를 통과한다:
//     delete: (CFDictionary) -> OSStatus = SecItemDelete
//     add:    (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd
//
// `CFString`/`CFDictionary`/`CFTypeRef` 는 이 리포의 CF 대역이 사는 `CoreGraphics` 심에서 온다
// (그 파일 머리말 참조 — 애플에서는 Foundation 이 CoreFoundation 을 재수출한다).
// 애플에서도 `Security` 는 CoreFoundation 을 끌고 오므로 여기 재수출은 거짓 통과를 만들지 않는다.
@_exported import CoreGraphics
import Foundation

/// 실제: `public typealias OSStatus = Int32` (`MacTypes.h`).
/// 리눅스 Foundation 에는 없다.
public typealias OSStatus = Int32

/// 실제 값(`SecBase.h`). **여기는 값이 실제로 단언에 흘러간다** —
/// `WorkshopAPITests` 가 `delete: { _ in errSecItemNotFound }` 처럼 주입하고 호출부가
/// `deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound` 로 가른다.
/// 그래서 더미가 아니라 애플 헤더의 실제 상수를 넣는다(`UTType.png` 선례와 같은 예외).
public let errSecSuccess: OSStatus = 0
public let errSecItemNotFound: OSStatus = -25300
public let errSecDuplicateItem: OSStatus = -25299
/// `WorkshopAPITests:150`·`:161`·`:178` 이 실패 주입에 쓴다.
/// 실제 값(`SecBase.h`): `errSecAuthFailed = -25293` · `errSecParam = -50`.
public let errSecAuthFailed: OSStatus = -25293
public let errSecParam: OSStatus = -50

/// 실제: `SecItem.h` 의 `extern const CFStringRef kSecClass;` 등. 스위프트에서는 `CFString` 이다.
/// 문자열 값은 딕셔너리 **키**로만 쓰이고 비교되지 않으므로 더미로 둔다 — 다만 서로 **달라야**
/// `[String: Any]` 에서 키가 겹치지 않는다(실측: 같은 값이면 `baseQuery()` 가 3키가 아니라 1키가 된다).
/// 확신 없음: 실제 raw 문자열은 `"class"`·`"svce"`·`"acct"`·`"v_Data"`·`"r_Data"`·`"m_Limit"` 계열이지만
/// 여기서 그 값을 확정할 근거가 없어 이름만 맞춘 더미다.
public let kSecClass: CFString = "shim.kSecClass" as NSString
public let kSecClassGenericPassword: CFString = "shim.kSecClassGenericPassword" as NSString
public let kSecAttrService: CFString = "shim.kSecAttrService" as NSString
public let kSecAttrAccount: CFString = "shim.kSecAttrAccount" as NSString
public let kSecValueData: CFString = "shim.kSecValueData" as NSString
public let kSecReturnData: CFString = "shim.kSecReturnData" as NSString
public let kSecMatchLimit: CFString = "shim.kSecMatchLimit" as NSString
public let kSecMatchLimitOne: CFString = "shim.kSecMatchLimitOne" as NSString

/// 실제: `func SecItemCopyMatching(_ query: CFDictionary,
///                                _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus`
public func SecItemCopyMatching(_ query: CFDictionary,
                                _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { errSecSuccess }

/// 실제: `func SecItemAdd(_ attributes: CFDictionary,
///                        _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus`
public func SecItemAdd(_ attributes: CFDictionary,
                       _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { errSecSuccess }

/// 실제: `func SecItemDelete(_ query: CFDictionary) -> OSStatus`
public func SecItemDelete(_ query: CFDictionary) -> OSStatus { errSecSuccess }
