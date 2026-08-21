// 리눅스용 **Combine 대역 선언**(shim). 타입체크 전용 — 동작하지 않는다.
// 배경·규약은 `metal.swift` 머리말과 같다.
//
// `Sources/Waple/**` 와 `Tests/WapleAppTests/**` 가 실제로 쓰는 표면만 있다(2026-08-21 실측 grep):
//   · `ObservableObject` + `objectWillChange.send()` / `.sink { }`  — LibraryViewModel 외 4개 VM
//   · `@Published` + `$entries` 투영값의 `.dropFirst().sink { }`     — LibraryViewModelTests 외 2건
//   · `AnyCancellable?` 저장                                          — LibraryViewModel:57 외
//   · `NotificationCenter.default.publisher(for:)`                    — DisplaysView:96 (`.onReceive`)
// 그 밖의 Combine 표면(Subject·operator 사슬·Scheduler)은 **일부러 넣지 않았다** — 안 쓰는 것을
// 넣으면 나중에 잘못 쓴 코드가 여기서 통과해 버린다.
import Foundation

/// 실제: `public protocol Cancellable { func cancel() }`
public protocol Cancellable {
    func cancel()
}

/// 실제: `final public class AnyCancellable: Cancellable, Hashable {
///          public init(_ cancel: @escaping () -> Void)
///          public init<C: Cancellable>(_ canceller: C)
///          final public func cancel()
///          final public func store(in set: inout Set<AnyCancellable>) }`
public final class AnyCancellable: Cancellable, Hashable {
    public init(_ cancel: @escaping () -> Void) {}
    public init<C: Cancellable>(_ canceller: C) {}
    public func cancel() {}
    public func store(in set: inout Set<AnyCancellable>) {}
    public static func == (l: AnyCancellable, r: AnyCancellable) -> Bool { l === r }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// 실제: `public protocol Publisher<Output, Failure> {
///          associatedtype Output
///          associatedtype Failure: Error
///          func receive<S>(subscriber: S) where S: Subscriber, ... }`
/// 확신 없음: `receive(subscriber:)` 요구사항은 **일부러 뺐다.** 넣으면 이 심의 모든 퍼블리셔가
/// `Subscriber`·`Subscription` 계층을 통째로 요구한다. 호출부는 `sink`/`dropFirst` 만 쓴다.
public protocol Publisher<Output, Failure> {
    associatedtype Output
    associatedtype Failure: Error
}

/// 실제: `Publishers.Drop`·`Publishers.Sink` 등 연산자마다 별도 제네릭 구조체가 나온다.
/// 여기서는 **연산자 사슬의 중간 타입을 하나로 접는다** — 타입체크만 하므로 사슬의 정확한
/// 타입 이름은 필요 없다. 대신 그만큼 실물보다 관대하다(`dropFirst` 뒤에만 오는 연산자를
/// 아무 데서나 부를 수 있게 된다).
public struct AnyPublisher<Output, Failure: Error>: Publisher {}

extension Publisher {
    /// 실제: `public func dropFirst(_ count: Int = 1) -> Publishers.Drop<Self>`
    public func dropFirst(_ count: Int = 1) -> AnyPublisher<Output, Failure> { AnyPublisher() }
}

extension Publisher where Failure == Never {
    /// 실제: `public func sink(receiveValue: @escaping (Self.Output) -> Void) -> AnyCancellable`
    /// (`Failure == Never` 제약이 실물에 그대로 있다 — 실패 채널이 있으면
    ///  `sink(receiveCompletion:receiveValue:)` 를 써야 한다.)
    public func sink(receiveValue: @escaping (Output) -> Void) -> AnyCancellable {
        AnyCancellable {}
    }
}

/// 실제: `final public class ObservableObjectPublisher: Publisher {
///          public typealias Output = Void
///          public typealias Failure = Never
///          public init()
///          final public func send() }`
public final class ObservableObjectPublisher: Publisher {
    public typealias Output = Void
    public typealias Failure = Never
    public init() {}
    public func send() {}
}

/// 실제: `public protocol ObservableObject: AnyObject {
///          associatedtype ObjectWillChangePublisher: Publisher = ObservableObjectPublisher
///              where Self.ObjectWillChangePublisher.Failure == Never
///          var objectWillChange: Self.ObjectWillChangePublisher { get } }`
public protocol ObservableObject: AnyObject {
    associatedtype ObjectWillChangePublisher: Publisher = ObservableObjectPublisher
        where ObjectWillChangePublisher.Failure == Never
    var objectWillChange: ObjectWillChangePublisher { get }
}

extension ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    /// 실제로는 저장 프로퍼티를 자동 합성해 **인스턴스마다 같은 퍼블리셔**를 돌려준다.
    /// 여기서는 매번 새로 만든다 — 타입만 맞추면 되고, 동작을 흉내 내면 "리눅스에서 돈다" 는
    /// 잘못된 인상을 준다(`darwin.swift` 머리말과 같은 판단).
    public var objectWillChange: ObservableObjectPublisher { ObservableObjectPublisher() }
}

/// 실제: `@propertyWrapper public struct Published<Value> {
///          public init(wrappedValue: Value)
///          public init(initialValue: Value)
///          public struct Publisher: Combine.Publisher { public typealias Output = Value
///                                                       public typealias Failure = Never }
///          public var projectedValue: Published<Value>.Publisher { mutating get set } }`
/// 확신 없음: 실물의 `wrappedValue` 는 **enclosing-self 서브스크립트**로 구현돼 있어
/// 클래스 인스턴스에서만 동작하고, 값을 대입할 때 소유 객체의 `objectWillChange` 를 쏜다.
/// 여기서는 그냥 저장 프로퍼티다 — **`@Published` 를 구조체에 붙여도 통과한다**(실물은 못 쓴다).
@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public init(initialValue: Value) { self.wrappedValue = initialValue }

    public struct Publisher: Combine.Publisher {
        public typealias Output = Value
        public typealias Failure = Never
    }
    public var projectedValue: Publisher { Publisher() }
}

extension NotificationCenter {
    /// 실제: `extension NotificationCenter {
    ///          public struct Publisher: Combine.Publisher {
    ///              public typealias Output = Notification
    ///              public typealias Failure = Never }
    ///          public func publisher(for name: Notification.Name,
    ///                                object: AnyObject? = nil) -> NotificationCenter.Publisher }`
    public struct Publisher: Combine.Publisher {
        public typealias Output = Notification
        public typealias Failure = Never
    }
    public func publisher(for name: Notification.Name,
                          object: AnyObject? = nil) -> NotificationCenter.Publisher {
        NotificationCenter.Publisher()
    }
}
