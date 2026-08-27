// 리눅스용 **CoreAudio 대역 선언**(shim). 타입체크 전용.
//
// 사용처: `Sources/Waple/PlaybackObservers.swift` 의 `audioPlaying` 축 —
// "다른 앱이 소리를 내고 있는가". WE 는 WASAPI 세션 열거로 같은 것을 보고,
// 평가기는 `0x14006d21f–0x14006d251` 에서 그 불리언을 읽는다.
//
// **여기 값은 전부 가짜다.** `AudioObjectGetPropertyData` 는 아무것도 쓰지 않고 0(성공)을
// 돌려주므로, 호출부가 넘긴 out 파라미터는 **초기값 그대로** 남는다. 즉 이 심으로 타입체크한
// 코드는 리눅스에서 항상 "무음" 으로 판정한다 — 동작 검증이 아니다(`darwin.swift` 와 같은 규율).
//
// 실제 헤더: `CoreAudio/AudioHardware.h`
@_exported import Foundation

/// 실제: `public typealias AudioObjectID = UInt32` · `AudioDeviceID = AudioObjectID`
public typealias AudioObjectID = UInt32
public typealias AudioDeviceID = AudioObjectID
public typealias AudioObjectPropertySelector = UInt32
public typealias AudioObjectPropertyScope = UInt32
public typealias AudioObjectPropertyElement = UInt32

/// 실제: **`Int32` 다** — `AudioObjectID`(UInt32)가 아니다.
///
/// [2026-08-27 정정] 처음에 `AudioObjectID` 로 적었고, 그 탓에 호출부가 리눅스에서는 통과하고
/// **macOS CI 의 Build (sources) 에서 죽었다**(`cannot convert value of type 'Int32' to expected
/// argument type 'AudioObjectID'`, run 33025975054). 이 심의 다른 모든 상수는 값이 가짜여도
/// 되지만 **타입은 실물과 같아야 한다** — 타입이 곧 이 하네스가 검증하는 전부이기 때문이다.
/// 값을 옮겨 적지 않는 규율(아래 셀렉터들)과 타입을 정확히 옮기는 규율은 서로 다른 것이고,
/// 여기서 뒤를 어겼다.
public let kAudioObjectSystemObject: Int32 = 1

/// 실제: 네 글자 코드(FourCC)를 UInt32 로 접은 값. 여기서는 **이름만 맞으면 되므로**
/// 실제 상수값을 옮기지 않는다 — 값이 쓰이는 곳이 없고, 옮겨 적으면 틀렸을 때
/// "심이 실물과 같다" 는 잘못된 신뢰를 만든다.
public let kAudioHardwarePropertyDefaultOutputDevice: AudioObjectPropertySelector = 0
public let kAudioDevicePropertyDeviceIsRunningSomewhere: AudioObjectPropertySelector = 0
public let kAudioObjectPropertyScopeGlobal: AudioObjectPropertyScope = 0
public let kAudioObjectPropertyElementMain: AudioObjectPropertyElement = 0

/// 실제: `AudioHardware.h` 의 C 구조체. 필드 이름·순서가 호출부에 그대로 드러난다.
public struct AudioObjectPropertyAddress {
    public var mSelector: AudioObjectPropertySelector
    public var mScope: AudioObjectPropertyScope
    public var mElement: AudioObjectPropertyElement
    public init(mSelector: AudioObjectPropertySelector,
                mScope: AudioObjectPropertyScope,
                mElement: AudioObjectPropertyElement) {
        self.mSelector = mSelector
        self.mScope = mScope
        self.mElement = mElement
    }
}

/// 실제:
/// ```
/// public func AudioObjectGetPropertyData(
///     _ inObjectID: AudioObjectID,
///     _ inAddress: UnsafePointer<AudioObjectPropertyAddress>,
///     _ inQualifierDataSize: UInt32,
///     _ inQualifierData: UnsafeRawPointer?,
///     _ ioDataSize: UnsafeMutablePointer<UInt32>,
///     _ outData: UnsafeMutableRawPointer) -> OSStatus
/// ```
/// `OSStatus` 는 리눅스 Foundation 에 없으므로 아래에서 함께 선언한다.
public func AudioObjectGetPropertyData(
    _ inObjectID: AudioObjectID,
    _ inAddress: UnsafePointer<AudioObjectPropertyAddress>,
    _ inQualifierDataSize: UInt32,
    _ inQualifierData: UnsafeRawPointer?,
    _ ioDataSize: UnsafeMutablePointer<UInt32>,
    _ outData: UnsafeMutableRawPointer
) -> OSStatus { 0 }

/// 실제(Darwin `MacTypes.h`): `public typealias OSStatus = Int32`
public typealias OSStatus = Int32
