// 리눅스용 **ScreenCaptureKit 대역 선언**(shim). 타입체크 전용.
// 사용처: `SystemAudioSpectrumProvider.swift`(시스템 출력 오디오 캡처) 하나뿐이다.
//
// **확신 없음(파일 전체).** ScreenCaptureKit 헤더를 보지 않고 호출부에서 역산했다. 특히
// `SCShareableContent.excludingDesktopWindows(_:onScreenWindowsOnly:)` 의 async 형태와
// `SCStream.addStreamOutput(_:type:sampleHandlerQueue:)` 의 throws 여부는 확인되지 않았다.
// 이 파일이 실제 API 와 어긋나면 `SystemAudioSpectrumProvider` 에 대해 **거짓 통과/거짓 실패**가 난다.
@_exported import AVFoundation

/// 실제: `open class SCDisplay: NSObject { open var displayID: CGDirectDisplayID { get }
///        open var width: Int { get }; open var height: Int { get }; open var frame: CGRect { get } }`
open class SCDisplay {
    public var displayID: CGDirectDisplayID { 0 }
    public var width: Int { 0 }
    public var height: Int { 0 }
    public var frame: CGRect { .zero }
}

/// 실제: `open class SCWindow: NSObject { ... }`
open class SCWindow {}

/// 실제: `open class SCRunningApplication: NSObject { ... }`
open class SCRunningApplication {}

/// 실제: `open class SCShareableContent: NSObject {
///        open var displays: [SCDisplay] { get }; open var windows: [SCWindow] { get }
///        open var applications: [SCRunningApplication] { get }
///        open class func excludingDesktopWindows(_ excludeDesktopWindows: Bool,
///              onScreenWindowsOnly: Bool) async throws -> SCShareableContent }`
open class SCShareableContent {
    public var displays: [SCDisplay] { [] }
    public var windows: [SCWindow] { [] }
    public var applications: [SCRunningApplication] { [] }
    public class func excludingDesktopWindows(_ excludeDesktopWindows: Bool,
                                              onScreenWindowsOnly: Bool) async throws -> SCShareableContent {
        fatalError("linux shim")
    }
}

/// 실제: `open class SCContentFilter: NSObject {
///        public init(display: SCDisplay, excludingWindows: [SCWindow]) ... }`
open class SCContentFilter {
    public init(display: SCDisplay, excludingWindows: [SCWindow]) {}
    public init(desktopIndependentWindow window: SCWindow) {}
}

/// 실제: `open class SCStreamConfiguration: NSObject { open var width/height: Int
///        open var minimumFrameInterval: CMTime; open var capturesAudio: Bool
///        open var sampleRate: Int; open var channelCount: Int
///        open var excludesCurrentProcessAudio: Bool; open var showsCursor: Bool
///        open var pixelFormat: OSType; open var queueDepth: Int }`
open class SCStreamConfiguration {
    public var width: Int = 0
    public var height: Int = 0
    public var minimumFrameInterval: CMTime = .zero
    public var capturesAudio: Bool = false
    public var sampleRate: Int = 48000
    public var channelCount: Int = 2
    public var excludesCurrentProcessAudio: Bool = false
    public var showsCursor: Bool = true
    public var queueDepth: Int = 3
    public init() {}
}

/// 실제: `public enum SCStreamOutputType: Int { case screen, audio, microphone }`
public enum SCStreamOutputType: Int {
    case screen = 0, audio = 1, microphone = 2
}

/// 실제: `public protocol SCStreamDelegate: NSObjectProtocol {
///        optional func stream(_ stream: SCStream, didStopWithError error: Error) }`
public protocol SCStreamDelegate: AnyObject {
    func stream(_ stream: SCStream, didStopWithError error: Error)
}
public extension SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {}
}

/// 실제: `public protocol SCStreamOutput: NSObjectProtocol {
///        optional func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
///                             of type: SCStreamOutputType) }`
/// 애플에서는 **@objc optional** 이라 셀렉터가 어긋나도 컴파일이 통과하고 콜백만 조용히 안 온다 —
/// 그 함정을 `SystemAudioSpectrumProvider` 주석이 적고 있다. 리눅스 심에서는 기본 구현으로 흉내낸다.
/// **주의: 그래서 이 심은 "셀렉터 어긋남" 결함을 잡아 주지 못한다.**
public protocol SCStreamOutput: AnyObject {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType)
}
public extension SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {}
}

/// 실제: `open class SCStream: NSObject {
///        public init(filter contentFilter: SCContentFilter, configuration streamConfig: SCStreamConfiguration,
///                    delegate: SCStreamDelegate?)
///        open func addStreamOutput(_ output: SCStreamOutput, type: SCStreamOutputType,
///                                  sampleHandlerQueue: DispatchQueue?) throws
///        open func startCapture() async throws
///        open func stopCapture() async throws }`
open class SCStream {
    public init(filter contentFilter: SCContentFilter, configuration streamConfig: SCStreamConfiguration,
                delegate: SCStreamDelegate?) {}
    open func addStreamOutput(_ output: SCStreamOutput, type: SCStreamOutputType,
                              sampleHandlerQueue: DispatchQueue?) throws {}
    open func removeStreamOutput(_ output: SCStreamOutput, type: SCStreamOutputType) throws {}
    open func startCapture() async throws {}
    open func stopCapture() async throws {}
}
