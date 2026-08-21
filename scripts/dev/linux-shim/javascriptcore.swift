// 리눅스용 **JavaScriptCore 대역 선언**(shim). 타입체크 전용. 배경·규약은 `metal.swift` 머리말 참조.
// 사용처: `TextScriptEngine.swift`, `SceneAudioPlayer.swift`.
@_exported import Foundation

/// 실제: `open class JSVirtualMachine { public init!() }`
open class JSVirtualMachine {
    public init!() {}
}

/// 실제: `open class JSContext {
///        public init!(); public init!(virtualMachine: JSVirtualMachine!)
///        open func evaluateScript(_ script: String!) -> JSValue!
///        open func evaluateScript(_ script: String!, withSourceURL: URL!) -> JSValue!
///        open var exception: JSValue!
///        open var exceptionHandler: ((JSContext?, JSValue?) -> Void)!
///        open var globalObject: JSValue! { get }
///        open var virtualMachine: JSVirtualMachine! { get } }`
/// `objectForKeyedSubscript`/`setObject(_:forKeyedSubscript:)` 는 `JSContext` 확장(첨자 지원)에 있다.
open class JSContext {
    public init!() {}
    public init!(virtualMachine: JSVirtualMachine!) {}
    open func evaluateScript(_ script: String!) -> JSValue! { nil }
    open func evaluateScript(_ script: String!, withSourceURL sourceURL: URL!) -> JSValue! { nil }
    open var exception: JSValue!
    open var exceptionHandler: ((JSContext?, JSValue?) -> Void)!
    open var globalObject: JSValue! { nil }
    /// 실제: `open func objectForKeyedSubscript(_ key: Any!) -> JSValue!`
    open func objectForKeyedSubscript(_ key: Any!) -> JSValue! { nil }
    /// 실제: `open func setObject(_ object: Any!, forKeyedSubscript key: (NSCopying & NSObjectProtocol)!)`
    /// 확신 없음: 리눅스 Foundation 의 `NSString` 이 `NSCopying & NSObjectProtocol` 을 만족하는지에
    /// 이 시그니처가 의존한다. 호출부는 전부 `"..." as NSString` 이다.
    open func setObject(_ object: Any!, forKeyedSubscript key: (NSCopying & NSObjectProtocol)!) {}
    open subscript(key: Any) -> JSValue! { get { nil } set {} }
}

/// 실제: `open class JSValue { ... }`
open class JSValue {
    public init!(double value: Double, in context: JSContext!) {}
    public init!(bool value: Bool, in context: JSContext!) {}
    public init!(object value: Any!, in context: JSContext!) {}
    public init!(nullIn context: JSContext!) {}
    public init!(undefinedIn context: JSContext!) {}
    public init!(newObjectIn context: JSContext!) {}

    open var isUndefined: Bool { true }
    open var isNull: Bool { false }
    open var isBoolean: Bool { false }
    open var isNumber: Bool { false }
    open var isString: Bool { false }
    open var isObject: Bool { false }
    open var isArray: Bool { false }
    open var context: JSContext! { nil }

    /// 실제: `open func toString() -> String!` — NSObject.description 과 이름이 다르다.
    open func toString() -> String! { nil }
    open func toBool() -> Bool { false }
    open func toDouble() -> Double { 0 }
    open func toInt32() -> Int32 { 0 }
    open func toUInt32() -> UInt32 { 0 }
    open func toNumber() -> NSNumber! { nil }
    open func toArray() -> [Any]! { nil }
    open func toDictionary() -> [AnyHashable: Any]! { nil }
    open func toObject() -> Any! { nil }

    /// 실제: `open func call(withArguments arguments: [Any]!) -> JSValue!`
    open func call(withArguments arguments: [Any]!) -> JSValue! { nil }
    /// 실제: `open func construct(withArguments arguments: [Any]!) -> JSValue!`
    open func construct(withArguments arguments: [Any]!) -> JSValue! { nil }
    /// 실제: `open func invokeMethod(_ method: String!, withArguments arguments: [Any]!) -> JSValue!`
    open func invokeMethod(_ method: String!, withArguments arguments: [Any]!) -> JSValue! { nil }
    open func objectForKeyedSubscript(_ key: Any!) -> JSValue! { nil }
    open func setObject(_ object: Any!, forKeyedSubscript key: Any!) {}
    /// 실제: `open func objectAtIndexedSubscript(_ index: Int) -> JSValue!`
    /// (배열 원소 접근. `setObject(_:atIndexedSubscript:)` 가 짝이다.)
    open func objectAtIndexedSubscript(_ index: Int) -> JSValue! { nil }
    open func setObject(_ object: Any!, atIndexedSubscript index: Int) {}
    open func hasProperty(_ property: String!) -> Bool { false }
    open subscript(key: Any) -> JSValue! { get { nil } set {} }
}
