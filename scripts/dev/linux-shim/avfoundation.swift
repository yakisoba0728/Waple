// 리눅스용 **AVFoundation(+CoreMedia·CoreAudio 최소분) 대역 선언**(shim). 타입체크 전용.
// 사용처: `SceneVideoLayer` · `SceneAudioPlayer` · `VideoTextureExtractor` · `VideoRenderer` ·
//         `FFmpegConverter` · `SystemAudioSpectrumProvider`.
//
// **여기가 이 심 묶음에서 가장 위험한 부분이다.** AVFoundation 은 최근 async 프로퍼티 로딩
// (`asset.load(.duration)`)으로 API 가 갈렸고, 아래 `AVAsyncProperty` 재현은 실제 헤더를 보고
// 옮긴 것이 아니라 **호출부에서 역산한 형태**다 — 표시된 곳은 확신이 없다.
@_exported import CoreGraphics
@_exported import CoreVideo
@_exported import QuartzCore

// MARK: - CoreMedia

/// 실제: `public struct CMTime { public var value: CMTimeValue; public var timescale: CMTimeScale
///        public var flags: CMTimeFlags; public var epoch: CMTimeEpoch
///        public init(seconds: Double, preferredTimescale: CMTimeScale)
///        public init(value: CMTimeValue, timescale: CMTimeScale)
///        public static let zero: CMTime; public var seconds: Double { get }
///        public var isValid: Bool { get } }`
public typealias CMTimeValue = Int64
public typealias CMTimeScale = Int32
public struct CMTime: Equatable {
    public var value: CMTimeValue = 0
    public var timescale: CMTimeScale = 1
    public init() {}
    public init(seconds: Double, preferredTimescale: CMTimeScale) {
        self.value = CMTimeValue(seconds * Double(preferredTimescale)); self.timescale = preferredTimescale
    }
    public init(value: CMTimeValue, timescale: CMTimeScale) { self.value = value; self.timescale = timescale }
    public static let zero = CMTime(value: 0, timescale: 1)
    public static let invalid = CMTime(value: 0, timescale: 0)
    public static let indefinite = CMTime(value: 0, timescale: 0)
    public var seconds: Double { timescale == 0 ? .nan : Double(value) / Double(timescale) }
    public var isValid: Bool { timescale != 0 }
    public var isNumeric: Bool { timescale != 0 }
    public var isIndefinite: Bool { false }
}

/// 실제: `public class CMSampleBuffer` / `CMBlockBuffer` / `CMFormatDescription` — CF 불투명 타입.
public class CMSampleBuffer { internal init(unavailable: ()) {} }
public class CMBlockBuffer { internal init(unavailable: ()) {} }
public class CMFormatDescription { internal init(unavailable: ()) {} }
public typealias CMAudioFormatDescription = CMFormatDescription
public typealias OSStatus = Int32
/// 실제: `public var noErr: OSStatus { get }` — CoreServices/MacTypes 의 0 상수.
public let noErr: OSStatus = 0

/// 실제: `public struct AudioStreamBasicDescription { public var mSampleRate: Float64
///        mFormatID/mFormatFlags/mBytesPerPacket/mFramesPerPacket/mBytesPerFrame/mChannelsPerFrame/
///        mBitsPerChannel/mReserved }`
public struct AudioStreamBasicDescription {
    public var mSampleRate: Float64 = 0
    public var mFormatID: UInt32 = 0
    public var mFormatFlags: UInt32 = 0
    public var mBytesPerPacket: UInt32 = 0
    public var mFramesPerPacket: UInt32 = 0
    public var mBytesPerFrame: UInt32 = 0
    public var mChannelsPerFrame: UInt32 = 0
    public var mBitsPerChannel: UInt32 = 0
    public var mReserved: UInt32 = 0
    public init() {}
}

/// 실제: `public struct AudioBuffer { public var mNumberChannels: UInt32
///        public var mDataByteSize: UInt32; public var mData: UnsafeMutableRawPointer? }`
public struct AudioBuffer {
    public var mNumberChannels: UInt32 = 0
    public var mDataByteSize: UInt32 = 0
    public var mData: UnsafeMutableRawPointer?
    public init() {}
}

/// 실제: `public struct AudioBufferList { public var mNumberBuffers: UInt32
///        public var mBuffers: AudioBuffer }` (가변길이 C 구조체의 헤드)
public struct AudioBufferList {
    public var mNumberBuffers: UInt32 = 0
    public var mBuffers: AudioBuffer = AudioBuffer()
    public init() {}
}

/// 실제: `public struct UnsafeMutableAudioBufferListPointer: MutableCollection, RandomAccessCollection`
/// — 원소는 `AudioBuffer`, 인덱스는 `Int`.
public struct UnsafeMutableAudioBufferListPointer: MutableCollection, RandomAccessCollection {
    public typealias Element = AudioBuffer
    public typealias Index = Int
    private var storage: [AudioBuffer] = []
    public init(_ p: UnsafeMutablePointer<AudioBufferList>) {}
    public var count: Int { storage.count }
    public var startIndex: Int { 0 }
    public var endIndex: Int { storage.count }
    public func index(after i: Int) -> Int { i + 1 }
    public subscript(position: Int) -> AudioBuffer {
        get { storage[position] } set { storage[position] = newValue }
    }
}

/// 실제: `public func CMSampleBufferGetFormatDescription(_ sbuf: CMSampleBuffer) -> CMFormatDescription?`
public func CMSampleBufferGetFormatDescription(_ sbuf: CMSampleBuffer) -> CMFormatDescription? { nil }
/// 실제: `public func CMAudioFormatDescriptionGetStreamBasicDescription(_ desc: CMAudioFormatDescription)
///        -> UnsafePointer<AudioStreamBasicDescription>?`
public func CMAudioFormatDescriptionGetStreamBasicDescription(_ desc: CMAudioFormatDescription)
    -> UnsafePointer<AudioStreamBasicDescription>? { nil }
/// 실제: `public func CMSampleBufferGetNumSamples(_ sbuf: CMSampleBuffer) -> CMItemCount`(= Int)
public func CMSampleBufferGetNumSamples(_ sbuf: CMSampleBuffer) -> Int { 0 }
/// 실제: `public func CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
///        _ sbuf: CMSampleBuffer,
///        bufferListSizeNeededOut: UnsafeMutablePointer<Int>?,
///        bufferListOut: UnsafeMutablePointer<AudioBufferList>?,
///        bufferListSize: Int, blockBufferAllocator: CFAllocator?,
///        blockBufferMemoryAllocator: CFAllocator?, flags: UInt32,
///        blockBufferOut: UnsafeMutablePointer<CMBlockBuffer?>?) -> OSStatus`
/// 확신 없음: 인자 라벨 배치는 호출부에서 역산했다.
public func CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
    _ sbuf: CMSampleBuffer,
    bufferListSizeNeededOut: UnsafeMutablePointer<Int>?,
    bufferListOut: UnsafeMutablePointer<AudioBufferList>?,
    bufferListSize: Int,
    blockBufferAllocator: CFAllocator?,
    blockBufferMemoryAllocator: CFAllocator?,
    flags: UInt32,
    blockBufferOut: UnsafeMutablePointer<CMBlockBuffer?>?) -> OSStatus { 0 }
public let kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment: UInt32 = 1

// MARK: - 미디어 타입 · 비동기 프로퍼티

/// 실제: `public struct AVMediaType: RawRepresentable, Hashable { public static let video/audio/... }`
public struct AVMediaType: RawRepresentable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let video = AVMediaType(rawValue: "vide")
    public static let audio = AVMediaType(rawValue: "soun")
    public static let text = AVMediaType(rawValue: "text")
}

/// 실제: `public struct AVAsyncProperty<Root, Value>` — `asset.load(.duration)` 의 `.duration` 이 이것.
/// 확신 없음: 실제 타입 이름·제네릭 배치는 헤더를 못 봤고 호출부에서 역산했다.
/// (`AVPartialAsyncProperty` 등 형제 타입이 더 있는 것으로 안다.)
public struct AVAsyncProperty<Root, Value> {
    private let name: String
    internal init(_ name: String) { self.name = name }
}
public extension AVAsyncProperty where Root == AVAsset, Value == CMTime {
    static var duration: AVAsyncProperty<AVAsset, CMTime> { .init("duration") }
}
public extension AVAsyncProperty where Root == AVAsset, Value == Bool {
    static var isPlayable: AVAsyncProperty<AVAsset, Bool> { .init("isPlayable") }
}
public extension AVAsyncProperty where Root == AVAssetTrack, Value == CGAffineTransform {
    static var preferredTransform: AVAsyncProperty<AVAssetTrack, CGAffineTransform> { .init("preferredTransform") }
}
public extension AVAsyncProperty where Root == AVAssetTrack, Value == CGSize {
    static var naturalSize: AVAsyncProperty<AVAssetTrack, CGSize> { .init("naturalSize") }
}

// MARK: - 자산

/// 실제: `open class AVAsset: NSObject { open var duration: CMTime { get }
///        open func load<T>(_ property: AVAsyncProperty<AVAsset, T>) async throws -> T
///        open func loadTracks(withMediaType: AVMediaType) async throws -> [AVAssetTrack] }`
open class AVAsset {
    public init() {}
    open func load<T>(_ property: AVAsyncProperty<AVAsset, T>) async throws -> T { fatalError("linux shim") }
    open func loadTracks(withMediaType mediaType: AVMediaType) async throws -> [AVAssetTrack] { [] }
}

/// 실제: `open class AVURLAsset: AVAsset { public init(url URL: URL, options: [String: Any]? = nil)
///        open var url: URL { get } }`
open class AVURLAsset: AVAsset {
    public let url: URL
    public init(url URL: Foundation.URL, options: [String: Any]? = nil) { self.url = URL; super.init() }
}

/// 실제: `open class AVAssetTrack: NSObject { open var mediaType: AVMediaType { get }
///        open func load<T>(_ property: AVAsyncProperty<AVAssetTrack, T>) async throws -> T }`
open class AVAssetTrack {
    public init() {}
    open func load<T>(_ property: AVAsyncProperty<AVAssetTrack, T>) async throws -> T { fatalError("linux shim") }
}

/// 실제: `open class AVAssetImageGenerator: NSObject {
///        public init(asset: AVAsset)
///        open var appliesPreferredTrackTransform: Bool
///        open var requestedTimeToleranceBefore / After: CMTime
///        open var maximumSize: CGSize
///        open func copyCGImage(at requestedTime: CMTime,
///                              actualTime: UnsafeMutablePointer<CMTime>?) throws -> CGImage }`
open class AVAssetImageGenerator {
    public var appliesPreferredTrackTransform: Bool = false
    public var requestedTimeToleranceBefore: CMTime = .zero
    public var requestedTimeToleranceAfter: CMTime = .zero
    public var maximumSize: CGSize = .zero
    public init(asset: AVAsset) {}
    open func copyCGImage(at requestedTime: CMTime,
                          actualTime: UnsafeMutablePointer<CMTime>?) throws -> CGImage {
        fatalError("linux shim")
    }
}

// MARK: - 재생

/// 실제: `open class AVPlayerItem: NSObject { public init(url URL: URL); public init(asset: AVAsset)
///        open var asset: AVAsset { get }; open var status: AVPlayerItem.Status { get }
///        open var error: Error? { get }
///        open func add(_ output: AVPlayerItemOutput) }`
open class AVPlayerItem {
    public enum Status: Int { case unknown = 0, readyToPlay = 1, failed = 2 }
    public var status: Status { .unknown }
    public var error: Error? { nil }
    public var asset: AVAsset { AVAsset() }
    public init(url URL: Foundation.URL) {}
    public init(asset: AVAsset) {}
    open func add(_ output: AVPlayerItemVideoOutput) {}
    /// 실제: KVO 는 `NSObject.observe(_:options:changeHandler:)` 다 — `AVPlayerItem` 이
    /// `NSObject` 서브클래스라 쓸 수 있다. 리눅스에는 KVO 가 없어 여기서 형태만 흉내낸다.
    /// 확신 없음: `NSKeyValueObservedChange<Value>` 의 정확한 멤버는 재현하지 않았다.
    open func observe<Value>(_ keyPath: KeyPath<AVPlayerItem, Value>,
                             options: NSKeyValueObservingOptions = [],
                             changeHandler: @escaping (AVPlayerItem, NSKeyValueObservedChange<Value>) -> Void)
        -> NSKeyValueObservation { NSKeyValueObservation() }
}

/// 실제: Foundation(애플)의 KVO 지원 타입. 리눅스 Foundation 에는 없다.
public struct NSKeyValueObservingOptions: OptionSet {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let new = NSKeyValueObservingOptions(rawValue: 1)
    public static let old = NSKeyValueObservingOptions(rawValue: 2)
    public static let initial = NSKeyValueObservingOptions(rawValue: 4)
}
public struct NSKeyValueObservedChange<Value> {
    public var newValue: Value?
    public var oldValue: Value?
}
public class NSKeyValueObservation {
    public init() {}
    public func invalidate() {}
}

/// 실제: `open class AVPlayerItemOutput: NSObject { open func itemTime(forHostTime: CFTimeInterval) -> CMTime }`
/// `AVPlayerItemVideoOutput` 이 그 서브클래스다.
open class AVPlayerItemVideoOutput {
    public init(pixelBufferAttributes: [String: Any]?) {}
    open func itemTime(forHostTime hostTimeInSeconds: CFTimeInterval) -> CMTime { .zero }
    open func hasNewPixelBuffer(forItemTime itemTime: CMTime) -> Bool { false }
    open func copyPixelBuffer(forItemTime itemTime: CMTime,
                              itemTimeForDisplay outItemTimeForDisplay: UnsafeMutablePointer<CMTime>?)
        -> CVPixelBuffer? { nil }
}

/// 실제: `open class AVPlayer: NSObject { public init(); public init(url URL: URL)
///        public init(playerItem item: AVPlayerItem?)
///        open var currentItem: AVPlayerItem? { get }; open var rate: Float
///        open var isMuted: Bool; open var volume: Float
///        open var actionAtItemEnd: AVPlayer.ActionAtItemEnd
///        open func play(); open func pause(); open func seek(to time: CMTime)
///        open func replaceCurrentItem(with item: AVPlayerItem?) }`
open class AVPlayer {
    public enum ActionAtItemEnd: Int { case advance = 0, pause = 1, none = 2 }
    public var currentItem: AVPlayerItem? { nil }
    public var rate: Float = 0
    public var isMuted: Bool = false
    public var volume: Float = 1
    public var actionAtItemEnd: ActionAtItemEnd = .advance
    public init() {}
    public init(url URL: Foundation.URL) {}
    public init(playerItem item: AVPlayerItem?) {}
    open func play() {}
    open func pause() {}
    open func seek(to time: CMTime) {}
    open func replaceCurrentItem(with item: AVPlayerItem?) {}
}

/// 실제: `open class AVQueuePlayer: AVPlayer { public init(items: [AVPlayerItem]) ... }`
open class AVQueuePlayer: AVPlayer {
    public override init() { super.init() }
    public init(items: [AVPlayerItem]) { super.init() }
}

/// 실제: `open class AVPlayerLooper: NSObject {
///        public init(player: AVQueuePlayer, templateItem: AVPlayerItem)
///        open func disableLooping() }`
open class AVPlayerLooper {
    public init(player: AVQueuePlayer, templateItem: AVPlayerItem) {}
    open func disableLooping() {}
}

/// 실제: `open class AVPlayerLayer: CALayer { public init(player: AVPlayer?)
///        open var player: AVPlayer?; open var videoGravity: AVLayerVideoGravity }`
/// (실제로는 `convenience init(player:)` 가 아니라 클래스 팩토리 `AVPlayerLayer(player:)` 다.)
open class AVPlayerLayer: CALayer {
    public var player: AVPlayer?
    public var videoGravity: AVLayerVideoGravity = .resizeAspect
    public init(player: AVPlayer?) { self.player = player; super.init() }
    public override init() { super.init() }
}
public struct AVLayerVideoGravity: RawRepresentable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let resize = AVLayerVideoGravity(rawValue: "AVLayerVideoGravityResize")
    public static let resizeAspect = AVLayerVideoGravity(rawValue: "AVLayerVideoGravityResizeAspect")
    public static let resizeAspectFill = AVLayerVideoGravity(rawValue: "AVLayerVideoGravityResizeAspectFill")
}

/// 실제: `extension NSNotification.Name { public static let AVPlayerItemDidPlayToEndTime: NSNotification.Name }`
extension NSNotification.Name {
    public static let AVPlayerItemDidPlayToEndTime =
        NSNotification.Name("AVPlayerItemDidPlayToEndTimeNotification")
    public static let AVPlayerItemFailedToPlayToEndTime =
        NSNotification.Name("AVPlayerItemFailedToPlayToEndTimeNotification")
}

// MARK: - 오디오 재생

/// 실제: `public protocol AVAudioPlayerDelegate: NSObjectProtocol {
///        optional func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool)
///        optional func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) }`
/// **@objc optional 요구사항**이라 애플에서는 구현이 없어도 적합하다. 리눅스에는 `@objc optional` 이
/// 없으므로 기본 구현으로 같은 효과를 낸다.
public protocol AVAudioPlayerDelegate: AnyObject {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool)
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?)
}
public extension AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {}
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {}
}

/// 실제: `open class AVAudioPlayer: NSObject { public init(data: Data) throws
///        public init(contentsOf url: URL) throws
///        weak open var delegate: AVAudioPlayerDelegate?
///        open var volume: Float; open var numberOfLoops: Int; open var currentTime: TimeInterval
///        open var duration: TimeInterval { get }; open var isPlaying: Bool { get }
///        open func prepareToPlay() -> Bool; open func play() -> Bool
///        open func pause(); open func stop() }`
/// `play()`/`prepareToPlay()` 는 `@discardableResult` 가 아니라 **Bool 반환**이다 —
/// 호출부가 `p.play()` 로 값을 버리면 애플에서도 경고가 난다(경고일 뿐 오류는 아니다).
open class AVAudioPlayer {
    public weak var delegate: AVAudioPlayerDelegate?
    public var volume: Float = 1
    public var numberOfLoops: Int = 0
    public var currentTime: TimeInterval = 0
    public var duration: TimeInterval { 0 }
    public var isPlaying: Bool { false }
    public init(data: Data) throws {}
    public init(contentsOf url: URL) throws {}
    @discardableResult open func prepareToPlay() -> Bool { false }
    @discardableResult open func play() -> Bool { false }
    open func pause() {}
    open func stop() {}
}
