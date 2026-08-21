// 리눅스용 **SwiftUI 대역 선언**(shim). 타입체크 전용 — 동작하지 않는다.
// 배경·규약은 `metal.swift` 머리말과 같다.
//
// ⚠️ **이 심은 다른 심들보다 훨씬 관대하다. 무엇이 검증되고 무엇이 안 되는지 먼저 읽어라.**
//
// SwiftUI 는 `some View` + 결과 빌더 + 수식어 사슬로 **타입이 계속 감기는** 라이브러리다.
// 실물의 `VStack<TupleView<(Text, Button<…>)>>` 같은 타입을 손으로 재현하는 것은 불가능하고,
// 재현해도 값이 없다. 그래서 이 심은 **두 곳에서 타입을 접는다**:
//
//   1. `ViewBuilder` 의 모든 build* 가 `AnyView` 를 돌려준다(실물은 `TupleView`·
//      `_ConditionalContent` 등으로 구조를 보존한다).
//   2. `View` 의 수식어가 전부 `AnyView` 를 돌려준다(실물은 `ModifiedContent<…>`).
//
// **그래서 검증되는 것**: 식별자 존재(오타·이름 변경) · 인자 라벨 · 인자 타입 ·
//   프로퍼티 래퍼 투영(`$x`) 결합 · 뷰 모델/스토어 API 시그니처 · `if`/`switch` 분기의 내용물.
//   즉 `bb5f902` 류(스코프에 없는 이름)와 시그니처 변경은 그대로 잡힌다.
// **검증되지 않는 것**: 수식어를 붙일 수 **없는** 자리에 붙인 것(예: `Text` 전용 수식어를
//   `Button` 에), 제네릭 제약 위반, `some View` 반환 타입의 구조, `@MainActor` 격리
//   (`docs/dev/linux-typecheck.md` 한계 ④ — SwiftUI 는 실물이 전부 `@MainActor` 인데 여기는
//   전부 비격리다), 그리고 당연히 런타임 레이아웃.
//
// **수식어의 인자는 접지 않았다.** `.foregroundStyle(.secondary)` 의 `.secondary` 나
// `.buttonStyle(.bordered)` 의 `.bordered` 는 실제 타입을 만들어 뒀다 — 그 이름이 틀리면
// 잡힌다. 접은 것은 **반환 타입**뿐이다.
//
// 대상: `Sources/Waple/**`(48파일 중 SwiftUI 를 쓰는 31파일) 과 `Tests/WapleAppTests/**`.
// 여기 있는 것은 그 두 곳이 **실제로 쓰는 표면**뿐이다.
// 애플의 `SwiftUI` 는 `Combine` 을 재수출한다 — `ObservableObject`/`@Published` 는 Combine 타입인데
// 뷰 코드가 `import SwiftUI` 만으로 쓴다. 재수출하지 않으면 `StatusBannerModel: ObservableObject`
// 같은 선언이 `generic struct 'ObservedObject' requires that 'X' conform to 'ObservableObject'`
// 로 막힌다(실측 2026-08-21, `MainWindowView.swift:28~33`).
@_exported import Combine
@_exported import CoreGraphics
import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - View / ViewBuilder

/// 실제(macOS 14 SDK): `@MainActor @preconcurrency public protocol View {
///          associatedtype Body: View
///          @ViewBuilder @MainActor var body: Self.Body { get } }`
///
/// **`@MainActor` 를 붙였다** — 다른 심들과 달리 여기서는 격리를 흉내 낸다. 안 붙이면
/// `AnimatedPreviewView.swift`(`NSViewRepresentable` + `@MainActor final class Coordinator`)가
/// 오류 4건을 낸다(실측 2026-08-21: `main actor-isolated property 'url' can not be referenced
/// from a nonisolated context` 등). 그 코드는 macOS 에서 정상이다 — 실물 `View` 가 `@MainActor`
/// 라서 `updateNSView`/`setImage` 가 전부 메인 액터 안이기 때문이다.
/// 확신 없음: 실물에는 `@preconcurrency` 도 붙어 있어 Swift 5 모드에서 적합성 진단이 강등된다.
/// 여기서는 그 강등을 재현하지 않았다 — 이 도구가 `-strict-concurrency` 를 넘기지 않으므로
/// 지금은 차이가 드러나지 않지만, 넘기기 시작하면 갈린다(한계 ④).
@preconcurrency @MainActor public protocol View {
    associatedtype Body: View
    @ViewBuilder var body: Self.Body { get }
}

/// **심 내부용 편의 프로토콜 — 애플에는 없다.** 원시 뷰(`Text`·`VStack`…)의 `body`
/// 보일러플레이트를 없앤다. 실물에서 그 자리는 `typealias Body = Never` 다.
///
/// `View` 자체에 기본 `body` 를 두지 **않는** 이유: 두면 `body` 를 빠뜨리거나 이름을 틀린
/// 사용자 뷰가 조용히 통과한다(실물은 "does not conform" 으로 잡는다).
public protocol _ShimPrimitiveView: View {}
extension _ShimPrimitiveView {
    public var body: AnyView { AnyView() }
}

/// 실제: `@frozen public struct AnyView: View { public init<V>(_ view: V) where V: View
///                                              public init<V>(erasing view: V) where V: View }`
/// 생성자는 전부 `nonisolated` 다 — `View` 가 `@MainActor` 라 그냥 두면 아래 `ViewBuilder` 의
/// `static func` 들(격리 없음)이 `AnyView()` 를 못 부른다(실측: `call to main actor-isolated
/// initializer 'init()' in a synchronous nonisolated context` 5건).
public struct AnyView: _ShimPrimitiveView {
    nonisolated public init() {}
    nonisolated public init<V: View>(_ view: V) {}
    nonisolated public init<V: View>(erasing view: V) {}
}

/// 실제: `@frozen public struct EmptyView: View`
public struct EmptyView: _ShimPrimitiveView {
    nonisolated public init() {}
}

/// 실제: `@resultBuilder public struct ViewBuilder { static func buildBlock() -> EmptyView
///        static func buildBlock<each Content: View>(_ content: repeat each Content)
///            -> TupleView<(repeat each Content)> … }`
/// 여기서는 전부 `AnyView` 로 접는다(머리말 참조). 가변인자로 둔 것은 실물의 arity 별
/// 오버로드(0~10)를 대신한다 — 결과 빌더는 `buildBlock(a, b, c)` 형태로 부르므로 통한다.
@resultBuilder public struct ViewBuilder {
    public static func buildBlock() -> AnyView { AnyView() }
    public static func buildBlock(_ parts: any View...) -> AnyView { AnyView() }
    public static func buildExpression(_ expression: any View) -> AnyView { AnyView() }
    public static func buildOptional(_ content: AnyView?) -> AnyView { AnyView() }
    public static func buildEither(first: AnyView) -> AnyView { AnyView() }
    public static func buildEither(second: AnyView) -> AnyView { AnyView() }
    public static func buildArray(_ components: [AnyView]) -> AnyView { AnyView() }
    public static func buildLimitedAvailability(_ content: AnyView) -> AnyView { AnyView() }
}

/// 실제: `public protocol ViewModifier { associatedtype Body: View
///          typealias Content = _ViewModifier_Content<Self>
///          @ViewBuilder @MainActor func body(content: Self.Content) -> Self.Body }`
/// `Content` 를 `AnyView` 로 접었다 — 실물의 `_ViewModifier_Content` 는 불투명 타입이라
/// 사용자 코드가 이름으로 부르지 않는다.
@MainActor public protocol ViewModifier {
    associatedtype Body: View
    typealias Content = AnyView
    @ViewBuilder func body(content: Content) -> Self.Body
}

/// 실제: `@frozen public struct Group<Content>: View where Content: View`
public struct Group: _ShimPrimitiveView {
    public init(@ViewBuilder content: () -> AnyView) {}
}

/// 실제: `public struct ForEach<Data, ID, Content> where Data: RandomAccessCollection, ID: Hashable`
public struct ForEach<Data: RandomAccessCollection, ID: Hashable>: _ShimPrimitiveView {
    /// 실제: `public init(_ data: Data, id: KeyPath<Data.Element, ID>,
    ///                    @ViewBuilder content: @escaping (Data.Element) -> Content)`
    public init(_ data: Data, id: KeyPath<Data.Element, ID>,
                @ViewBuilder content: @escaping (Data.Element) -> AnyView) {}
}
extension ForEach where Data.Element: Identifiable, ID == Data.Element.ID {
    /// 실제: `public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content)`
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> AnyView) {}
}
extension ForEach where Data == Range<Int>, ID == Int {
    /// 실제: `public init(_ data: Range<Int>, @ViewBuilder content: @escaping (Int) -> Content)`
    public init(_ data: Range<Int>, @ViewBuilder content: @escaping (Int) -> AnyView) {}
}

// MARK: - 레이아웃 컨테이너

/// 실제: `@frozen public struct VStack<Content>: View where Content: View {
///          @inlinable public init(alignment: HorizontalAlignment = .center,
///                                 spacing: CGFloat? = nil,
///                                 @ViewBuilder content: () -> Content) }`
public struct VStack: _ShimPrimitiveView {
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
                @ViewBuilder content: () -> AnyView) {}
}
/// 실제: `HStack(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, content:)`
public struct HStack: _ShimPrimitiveView {
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil,
                @ViewBuilder content: () -> AnyView) {}
}
/// 실제: `ZStack(alignment: Alignment = .center, content:)`
public struct ZStack: _ShimPrimitiveView {
    public init(alignment: Alignment = .center, @ViewBuilder content: () -> AnyView) {}
}
/// 실제: `LazyVStack(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
///                   pinnedViews: PinnedScrollableViews = .init(), content:)`
public struct LazyVStack: _ShimPrimitiveView {
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
                @ViewBuilder content: () -> AnyView) {}
}
/// 실제: `LazyHStack(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, …, content:)`
public struct LazyHStack: _ShimPrimitiveView {
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil,
                @ViewBuilder content: () -> AnyView) {}
}
/// 실제: `LazyVGrid(columns: [GridItem], alignment: HorizontalAlignment = .center,
///                  spacing: CGFloat? = nil, pinnedViews: … , content:)`
public struct LazyVGrid: _ShimPrimitiveView {
    public init(columns: [GridItem], alignment: HorizontalAlignment = .center,
                spacing: CGFloat? = nil, @ViewBuilder content: () -> AnyView) {}
}
/// 실제: `public struct GridItem { public enum Size { case fixed(CGFloat)
///          case flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity)
///          case adaptive(minimum: CGFloat, maximum: CGFloat = .infinity) }
///          public init(_ size: GridItem.Size = .flexible(), spacing: CGFloat? = nil,
///                      alignment: Alignment? = nil) }`
public struct GridItem {
    public enum Size {
        case fixed(CGFloat)
        case flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity)
        case adaptive(minimum: CGFloat, maximum: CGFloat = .infinity)
    }
    public init(_ size: Size = .flexible(), spacing: CGFloat? = nil, alignment: Alignment? = nil) {}
}
/// 실제: `ScrollView(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, content:)`
public struct ScrollView: _ShimPrimitiveView {
    public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true,
                @ViewBuilder content: () -> AnyView) {}
}
/// 실제: `public struct List<SelectionValue, Content>` — 선택 바인딩 유무로 오버로드가 갈린다.
public struct List: _ShimPrimitiveView {
    public init(@ViewBuilder content: () -> AnyView) {}
    public init<S: Hashable>(selection: Binding<S?>, @ViewBuilder content: () -> AnyView) {}
}
/// 실제: `public struct Form<Content>: View where Content: View`
public struct Form: _ShimPrimitiveView {
    public init(@ViewBuilder content: () -> AnyView) {}
}
/// 실제: `public struct Section<Parent, Content, Footer>` — 헤더 유무로 오버로드가 갈린다.
public struct Section: _ShimPrimitiveView {
    public init(@ViewBuilder content: () -> AnyView) {}
    public init(_ title: String, @ViewBuilder content: () -> AnyView) {}
    public init(@ViewBuilder content: () -> AnyView, @ViewBuilder header: () -> AnyView) {}
    /// 실제: `public init(@ViewBuilder content:, @ViewBuilder header:, @ViewBuilder footer:)`
    /// (`SettingsView.swift` 의 네 섹션이 header+footer 를 함께 쓴다.)
    public init(@ViewBuilder content: () -> AnyView, @ViewBuilder header: () -> AnyView,
                @ViewBuilder footer: () -> AnyView) {}
    public init(header: AnyView, @ViewBuilder content: () -> AnyView) {}
    public init(isExpanded: Binding<Bool>, @ViewBuilder content: () -> AnyView,
                @ViewBuilder header: () -> AnyView) {}
}
/// 실제: `@frozen public struct Spacer: View { public init(minLength: CGFloat? = nil) }`
public struct Spacer: _ShimPrimitiveView {
    public init(minLength: CGFloat? = nil) {}
}
/// 실제: `@frozen public struct Divider: View { public init() }`
public struct Divider: _ShimPrimitiveView {
    public init() {}
}
/// 실제: `@frozen public struct GeometryReader<Content>: View where Content: View {
///          public init(@ViewBuilder content: @escaping (GeometryProxy) -> Content) }`
public struct GeometryReader: _ShimPrimitiveView {
    public init(@ViewBuilder content: @escaping (GeometryProxy) -> AnyView) {}
}
/// 실제: `public struct GeometryProxy { public var size: CGSize { get }
///          public var safeAreaInsets: EdgeInsets { get }
///          public func frame(in coordinateSpace: CoordinateSpace) -> CGRect }`
public struct GeometryProxy {
    public var size: CGSize { .zero }
    public var safeAreaInsets: EdgeInsets { EdgeInsets() }
}
/// 실제: `public struct NavigationSplitView<Sidebar, Content, Detail>: View` —
/// 2열(sidebar/detail) 오버로드만 쓴다.
public struct NavigationSplitView: _ShimPrimitiveView {
    public init(@ViewBuilder sidebar: () -> AnyView, @ViewBuilder detail: () -> AnyView) {}
    public init(columnVisibility: Binding<NavigationSplitViewVisibility>,
                @ViewBuilder sidebar: () -> AnyView, @ViewBuilder detail: () -> AnyView) {}
}
/// 실제: `public struct NavigationSplitViewVisibility: Equatable, Codable, Sendable {
///          public static var detailOnly / doubleColumn / all / automatic }`
public struct NavigationSplitViewVisibility: Equatable {
    private let tag: Int
    public static let detailOnly = NavigationSplitViewVisibility(tag: 0)
    public static let doubleColumn = NavigationSplitViewVisibility(tag: 1)
    public static let all = NavigationSplitViewVisibility(tag: 2)
    public static let automatic = NavigationSplitViewVisibility(tag: 3)
}

// MARK: - 콘텐츠 뷰

/// 실제: `@frozen public struct Text: Equatable, View { public init<S>(_ content: S) where S: StringProtocol
///          public init(verbatim content: String)
///          public init(_ key: LocalizedStringKey, tableName: String? = nil, …) }`
public struct Text: _ShimPrimitiveView, Equatable {
    public init(_ content: String) {}
    public init(verbatim content: String) {}
    /// 실제: `public enum TruncationMode { case head, tail, middle }` — `Text.TruncationMode` 다.
    public enum TruncationMode { case head, tail, middle }
    public static func == (l: Text, r: Text) -> Bool { true }
    /// 실제: `public static func + (lhs: Text, rhs: Text) -> Text`
    /// (`RemoteTile.swift:183` 이 접근성 라벨을 이어 붙인다.)
    nonisolated public static func + (lhs: Text, rhs: Text) -> Text { lhs }
}
/// 실제: `public struct Label<Title, Icon>: View` — 문자열 + SF Symbol 오버로드만 쓴다.
public struct Label: _ShimPrimitiveView {
    public init(_ title: String, systemImage: String) {}
    public init(@ViewBuilder title: () -> AnyView, @ViewBuilder icon: () -> AnyView) {}
}
/// 실제: `public struct Image: Equatable, View { public init(systemName: String)
///          public init(nsImage: NSImage) }`
public struct Image: _ShimPrimitiveView, Equatable {
    public init(systemName: String) {}
    public init(nsImage: NSImage) {}
    public static func == (l: Image, r: Image) -> Bool { true }
}
/// 실제: `public struct Button<Label>: View {
///          public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label)
///          public init(_ title: S, action: @escaping () -> Void) where S: StringProtocol
///          public init(role: ButtonRole?, action:, label:) }`
public struct Button: _ShimPrimitiveView {
    public init(action: @escaping () -> Void, @ViewBuilder label: () -> AnyView) {}
    public init(_ title: String, action: @escaping () -> Void) {}
    public init(_ title: String, systemImage: String, action: @escaping () -> Void) {}
    public init(role: ButtonRole?, action: @escaping () -> Void,
                @ViewBuilder label: () -> AnyView) {}
    public init(_ title: String, role: ButtonRole?, action: @escaping () -> Void) {}
}
/// 실제: `public struct ButtonRole: Equatable, Sendable {
///          public static let destructive: ButtonRole
///          public static let cancel: ButtonRole }`
public struct ButtonRole: Equatable {
    private let tag: Int
    public static let destructive = ButtonRole(tag: 0)
    public static let cancel = ButtonRole(tag: 1)
}
/// 실제: `public struct Toggle<Label>: View { public init(isOn: Binding<Bool>, label: () -> Label)
///          public init(_ title: S, isOn: Binding<Bool>) }`
public struct Toggle: _ShimPrimitiveView {
    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> AnyView) {}
    public init(_ title: String, isOn: Binding<Bool>) {}
}
/// 실제: `public struct Picker<Label, SelectionValue, Content>: View`
public struct Picker: _ShimPrimitiveView {
    public init<S: Hashable>(_ title: String, selection: Binding<S>,
                             @ViewBuilder content: () -> AnyView) {}
    public init<S: Hashable>(selection: Binding<S>, @ViewBuilder content: () -> AnyView,
                             @ViewBuilder label: () -> AnyView) {}
}
/// 실제: `public struct Slider<Label, ValueLabel>: View {
///          public init<V>(value: Binding<V>, in bounds: ClosedRange<V> = 0...1,
///                         step: V.Stride = 1, …) where V: BinaryFloatingPoint }`
public struct Slider: _ShimPrimitiveView {
    public init(value: Binding<Double>, in bounds: ClosedRange<Double> = 0...1,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {}
    public init(value: Binding<Double>, in bounds: ClosedRange<Double>, step: Double,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {}
}
/// 실제: `public struct Stepper<Label>: View { public init(_ title: S, value: Binding<V>,
///                                              in bounds: ClosedRange<V>, step: V.Stride = 1) }`
public struct Stepper: _ShimPrimitiveView {
    public init(_ title: String, value: Binding<Int>, in bounds: ClosedRange<Int>) {}
    public init(value: Binding<Int>, in bounds: ClosedRange<Int>,
                @ViewBuilder label: () -> AnyView) {}
}
/// 실제: `public struct TextField<Label>: View { public init(_ titleKey: LocalizedStringKey,
///          text: Binding<String>, prompt: Text? = nil) }`
public struct TextField: _ShimPrimitiveView {
    public init(_ title: String, text: Binding<String>) {}
    public init(_ title: String, text: Binding<String>, prompt: Text?) {}
    public init(text: Binding<String>, prompt: Text? = nil, @ViewBuilder label: () -> AnyView) {}
}
/// 실제: `public struct SecureField<Label>: View`
public struct SecureField: _ShimPrimitiveView {
    public init(_ title: String, text: Binding<String>) {}
    public init(_ title: String, text: Binding<String>, prompt: Text?) {}
}
/// 실제: `public struct ColorPicker<Label>: View { public init(selection: Binding<Color>,
///          supportsOpacity: Bool = true, label: () -> Label) }`
public struct ColorPicker: _ShimPrimitiveView {
    public init(_ title: String, selection: Binding<Color>, supportsOpacity: Bool = true) {}
    public init(selection: Binding<Color>, supportsOpacity: Bool = true,
                @ViewBuilder label: () -> AnyView) {}
}
/// 실제: `public struct ProgressView<Label, CurrentValueLabel>: View { public init()
///          public init(_ title: S) where S: StringProtocol
///          public init<V>(value: V?, total: V = 1.0) where V: BinaryFloatingPoint }`
public struct ProgressView: _ShimPrimitiveView {
    public init() {}
    public init(_ title: String) {}
    public init(value: Double?, total: Double = 1.0) {}
}
/// 실제: `public struct LabeledContent<Label, Content>: View {
///          public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) }`
public struct LabeledContent: _ShimPrimitiveView {
    public init(_ title: String, @ViewBuilder content: () -> AnyView) {}
    public init(@ViewBuilder content: () -> AnyView, @ViewBuilder label: () -> AnyView) {}
}
/// 실제: `public struct Link<Label>: View { public init(destination: URL, label: () -> Label)
///          public init(_ titleKey: LocalizedStringKey, destination: URL) }`
public struct Link: _ShimPrimitiveView {
    public init(_ title: String, destination: URL) {}
    public init(destination: URL, @ViewBuilder label: () -> AnyView) {}
}
/// 실제: `public struct Menu<Label, Content>: View {
///          public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label)
///          public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) }`
public struct Menu: _ShimPrimitiveView {
    public init(@ViewBuilder content: () -> AnyView, @ViewBuilder label: () -> AnyView) {}
    public init(_ title: String, @ViewBuilder content: () -> AnyView) {}
}
/// 실제(macOS 14+): `public struct ContentUnavailableView<Label, Description, Actions>: View {
///          public init(_ title: S, systemImage: String, description: Text? = nil)
///          public init(@ViewBuilder label:, @ViewBuilder description:, @ViewBuilder actions:) }`
public struct ContentUnavailableView: _ShimPrimitiveView {
    public init(_ title: String, systemImage: String, description: Text? = nil) {}
    public init(@ViewBuilder label: () -> AnyView, @ViewBuilder description: () -> AnyView) {}
    public init(@ViewBuilder label: () -> AnyView, @ViewBuilder description: () -> AnyView,
                @ViewBuilder actions: () -> AnyView) {}
}

// MARK: - 도형 / 그라디언트

/// 실제: `public protocol Shape: Animatable, View { func path(in rect: CGRect) -> Path }`
/// `path(in:)` 요구사항은 **일부러 뺐다** — 이 리포에는 커스텀 `Shape` 구현이 없고,
/// 넣으면 `Path` 전체를 재현해야 한다.
public protocol Shape: View {}
/// 실제: `@frozen public struct Capsule: Shape { public init(style: RoundedCornerStyle = .circular) }`
public struct Capsule: Shape, _ShimPrimitiveView {
    nonisolated public init() {}
}
/// 실제: `@frozen public struct Rectangle: Shape { public init() }`
public struct Rectangle: Shape, _ShimPrimitiveView {
    nonisolated public init() {}
}
/// 실제: `@frozen public struct RoundedRectangle: Shape {
///          public init(cornerRadius: CGFloat, style: RoundedCornerStyle = .circular) }`
public struct RoundedRectangle: Shape, _ShimPrimitiveView {
    nonisolated public init(cornerRadius: CGFloat) {}
    nonisolated public init(cornerSize: CGSize) {}
}
/// 실제: `@frozen public struct LinearGradient: ShapeStyle, View {
///          public init(colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint)
///          public init(gradient: Gradient, startPoint: UnitPoint, endPoint: UnitPoint) }`
public struct LinearGradient: ShapeStyle, _ShimPrimitiveView {
    nonisolated public init(colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint) {}
    nonisolated public init(gradient: Gradient, startPoint: UnitPoint, endPoint: UnitPoint) {}
    nonisolated public init(stops: [Gradient.Stop], startPoint: UnitPoint, endPoint: UnitPoint) {}
}
/// 실제: `@frozen public struct Gradient: Equatable { public struct Stop { … }
///          public init(colors: [Color]); public init(stops: [Gradient.Stop]) }`
public struct Gradient: Equatable {
    public struct Stop: Equatable {
        public init(color: Color, location: CGFloat) {}
    }
    public init(colors: [Color]) {}
    public init(stops: [Stop]) {}
}

// MARK: - 스타일 값

/// 실제: `public protocol ShapeStyle: Sendable` — 실물에는 `_apply` 계열 요구사항이 있지만
/// 전부 `_` 로 시작하는 내부 API 라 사용자 타입이 볼 일이 없다.
public protocol ShapeStyle {}

/// 실제: `public struct HierarchicalShapeStyle: ShapeStyle { public static let primary/secondary/
///          tertiary/quaternary: HierarchicalShapeStyle }`
/// `.foregroundStyle(.secondary)` 의 선행 점 문법이 여기로 풀린다.
public struct HierarchicalShapeStyle: ShapeStyle {
    private let tag: Int
    public static let primary = HierarchicalShapeStyle(tag: 0)
    public static let secondary = HierarchicalShapeStyle(tag: 1)
    public static let tertiary = HierarchicalShapeStyle(tag: 2)
    public static let quaternary = HierarchicalShapeStyle(tag: 3)
}
extension ShapeStyle where Self == HierarchicalShapeStyle {
    public static var primary: HierarchicalShapeStyle { .primary }
    public static var secondary: HierarchicalShapeStyle { .secondary }
    public static var tertiary: HierarchicalShapeStyle { .tertiary }
    public static var quaternary: HierarchicalShapeStyle { .quaternary }
}

/// 실제: `@frozen public struct Color: Hashable, CustomStringConvertible, ShapeStyle, View {
///          public init(nsColor: NSColor)
///          public static let white/black/clear/red/orange/yellow/green/blue/gray/…: Color
///          public static var accentColor: Color { get }
///          public func opacity(_ opacity: Double) -> Color }`
/// **모든 멤버가 `nonisolated` 다.** `Color` 는 `View` 를 통해 `@MainActor` 가 되는데, 실물
/// SwiftUI 의 `Color` 는 `Sendable` 이고 생성자·`opacity` 가 격리돼 있지 않다. 안 붙이면
/// `DesignSystem/ColorRole.swift` 의 `static let well: Color = Color(nsColor: .controlBackgroundColor)`
/// 같은 전역 상수가 전부 막힌다(실측 2026-08-21: 오류 7건 —
/// `call to main actor-isolated initializer 'init(nsColor:)' in a synchronous nonisolated context`).
public struct Color: ShapeStyle, _ShimPrimitiveView, Hashable {
    private let tag: Int
    nonisolated private init(tag: Int) { self.tag = tag }
    nonisolated public init(nsColor: NSColor) { self.tag = 100 }
    nonisolated public init(_ name: String) { self.tag = 101 }
    /// 실제: `public init(red: Double, green: Double, blue: Double, opacity: Double = 1)`
    nonisolated public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.tag = 102
    }
    /// 실제: `public init(_ color: CGColor)` · `public init(hue:saturation:brightness:opacity:)`
    nonisolated public init(hue: Double, saturation: Double, brightness: Double,
                            opacity: Double = 1) { self.tag = 103 }
    nonisolated public func opacity(_ opacity: Double) -> Color { self }
    nonisolated public static let white = Color(tag: 0)
    nonisolated public static let black = Color(tag: 1)
    nonisolated public static let clear = Color(tag: 2)
    nonisolated public static let red = Color(tag: 3)
    nonisolated public static let orange = Color(tag: 4)
    nonisolated public static let yellow = Color(tag: 5)
    nonisolated public static let green = Color(tag: 6)
    nonisolated public static let blue = Color(tag: 7)
    nonisolated public static let gray = Color(tag: 8)
    nonisolated public static let primary = Color(tag: 9)
    nonisolated public static let secondary = Color(tag: 10)
    nonisolated public static let accentColor = Color(tag: 11)
}
extension ShapeStyle where Self == Color {
    public static var white: Color { .white }
    public static var black: Color { .black }
    public static var clear: Color { .clear }
    public static var red: Color { .red }
    public static var orange: Color { .orange }
    public static var yellow: Color { .yellow }
    public static var green: Color { .green }
    public static var blue: Color { .blue }
    public static var gray: Color { .gray }
    public static var accentColor: Color { .accentColor }
}

/// 실제: `public struct Material: ShapeStyle { public static let regularMaterial/thickMaterial/
///          thinMaterial/ultraThinMaterial/ultraThickMaterial/bar: Material }`
public struct Material: ShapeStyle {
    private let tag: Int
    public static let regularMaterial = Material(tag: 0)
    public static let thickMaterial = Material(tag: 1)
    public static let thinMaterial = Material(tag: 2)
    public static let ultraThinMaterial = Material(tag: 3)
    public static let ultraThickMaterial = Material(tag: 4)
    public static let bar = Material(tag: 5)
}
extension ShapeStyle where Self == Material {
    public static var regularMaterial: Material { .regularMaterial }
    public static var thickMaterial: Material { .thickMaterial }
    public static var thinMaterial: Material { .thinMaterial }
    public static var ultraThinMaterial: Material { .ultraThinMaterial }
    public static var ultraThickMaterial: Material { .ultraThickMaterial }
    public static var bar: Material { .bar }
}

/// 실제: `public struct Font: Hashable { public static let largeTitle/title/title2/title3/
///          headline/subheadline/body/callout/footnote/caption/caption2: Font
///          public func weight(_ weight: Font.Weight) -> Font
///          public func monospacedDigit() -> Font
///          public static func system(size: CGFloat, weight: Font.Weight? = nil,
///                                    design: Font.Design? = nil) -> Font }`
public struct Font: Hashable {
    private let tag: Int
    private init(tag: Int) { self.tag = tag }
    public struct Weight: Hashable {
        private let w: Int
        public static let ultraLight = Weight(w: 0)
        public static let thin = Weight(w: 1)
        public static let light = Weight(w: 2)
        public static let regular = Weight(w: 3)
        public static let medium = Weight(w: 4)
        public static let semibold = Weight(w: 5)
        public static let bold = Weight(w: 6)
        public static let heavy = Weight(w: 7)
        public static let black = Weight(w: 8)
    }
    public struct Design: Hashable {
        private let d: Int
        public static let `default` = Design(d: 0)
        public static let rounded = Design(d: 1)
        public static let monospaced = Design(d: 2)
    }
    public static let largeTitle = Font(tag: 0)
    public static let title = Font(tag: 1)
    public static let title2 = Font(tag: 2)
    public static let title3 = Font(tag: 3)
    public static let headline = Font(tag: 4)
    public static let subheadline = Font(tag: 5)
    public static let body = Font(tag: 6)
    public static let callout = Font(tag: 7)
    public static let footnote = Font(tag: 8)
    public static let caption = Font(tag: 9)
    public static let caption2 = Font(tag: 10)
    public func weight(_ weight: Weight) -> Font { self }
    public func bold() -> Font { self }
    public func italic() -> Font { self }
    public func monospacedDigit() -> Font { self }
    public static func system(size: CGFloat, weight: Weight? = nil, design: Design? = nil) -> Font {
        Font(tag: 11)
    }
}

// MARK: - 정렬·기하 값

/// 실제: `@frozen public struct Alignment: Equatable { public static let center/leading/trailing/
///          top/bottom/topLeading/topTrailing/bottomLeading/bottomTrailing: Alignment }`
public struct Alignment: Equatable {
    private let tag: Int
    public static let center = Alignment(tag: 0)
    public static let leading = Alignment(tag: 1)
    public static let trailing = Alignment(tag: 2)
    public static let top = Alignment(tag: 3)
    public static let bottom = Alignment(tag: 4)
    public static let topLeading = Alignment(tag: 5)
    public static let topTrailing = Alignment(tag: 6)
    public static let bottomLeading = Alignment(tag: 7)
    public static let bottomTrailing = Alignment(tag: 8)
}
/// 실제: `@frozen public struct HorizontalAlignment: Equatable { static let leading/center/trailing }`
public struct HorizontalAlignment: Equatable {
    private let tag: Int
    public static let leading = HorizontalAlignment(tag: 0)
    public static let center = HorizontalAlignment(tag: 1)
    public static let trailing = HorizontalAlignment(tag: 2)
}
/// 실제: `@frozen public struct VerticalAlignment: Equatable { static let top/center/bottom/
///          firstTextBaseline/lastTextBaseline }`
public struct VerticalAlignment: Equatable {
    private let tag: Int
    public static let top = VerticalAlignment(tag: 0)
    public static let center = VerticalAlignment(tag: 1)
    public static let bottom = VerticalAlignment(tag: 2)
    public static let firstTextBaseline = VerticalAlignment(tag: 3)
    public static let lastTextBaseline = VerticalAlignment(tag: 4)
}
/// 실제: `@frozen public enum Edge: Int8, CaseIterable { case top, leading, bottom, trailing
///          @frozen public struct Set: OptionSet { … } }`
public enum Edge: Int8, CaseIterable {
    case top, leading, bottom, trailing
    public struct Set: OptionSet {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let top = Set(rawValue: 1 << 0)
        public static let leading = Set(rawValue: 1 << 1)
        public static let bottom = Set(rawValue: 1 << 2)
        public static let trailing = Set(rawValue: 1 << 3)
        public static let horizontal: Set = [.leading, .trailing]
        public static let vertical: Set = [.top, .bottom]
        public static let all: Set = [.top, .leading, .bottom, .trailing]
    }
}
/// 실제: `@frozen public struct EdgeInsets: Equatable { public var top/leading/bottom/trailing: CGFloat }`
public struct EdgeInsets: Equatable {
    public var top: CGFloat = 0
    public var leading: CGFloat = 0
    public var bottom: CGFloat = 0
    public var trailing: CGFloat = 0
    public init() {}
    public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
    }
}
/// 실제: `@frozen public struct UnitPoint: Hashable { static let zero/center/top/bottom/…
///          public init(x: CGFloat, y: CGFloat) }`
public struct UnitPoint: Hashable {
    public var x: CGFloat = 0
    public var y: CGFloat = 0
    public init() {}
    public init(x: CGFloat, y: CGFloat) { self.x = x; self.y = y }
    public static let zero = UnitPoint(x: 0, y: 0)
    public static let center = UnitPoint(x: 0.5, y: 0.5)
    public static let top = UnitPoint(x: 0.5, y: 0)
    public static let bottom = UnitPoint(x: 0.5, y: 1)
    public static let leading = UnitPoint(x: 0, y: 0.5)
    public static let trailing = UnitPoint(x: 1, y: 0.5)
    public static let topLeading = UnitPoint(x: 0, y: 0)
    public static let topTrailing = UnitPoint(x: 1, y: 0)
    public static let bottomLeading = UnitPoint(x: 0, y: 1)
    public static let bottomTrailing = UnitPoint(x: 1, y: 1)
}
/// 실제: `@frozen public enum Axis: Int8, CaseIterable { case horizontal, vertical
///          public struct Set: OptionSet { static let horizontal/vertical } }`
public enum Axis: Int8, CaseIterable {
    case horizontal, vertical
    public struct Set: OptionSet {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let horizontal = Set(rawValue: 1 << 0)
        public static let vertical = Set(rawValue: 1 << 1)
    }
}
/// 실제: `@frozen public enum ContentMode: Hashable, CaseIterable { case fit, fill }`
public enum ContentMode: Hashable, CaseIterable { case fit, fill }
/// 실제: `public enum TextAlignment: Hashable, CaseIterable { case leading, center, trailing }`
public enum TextAlignment: Hashable, CaseIterable { case leading, center, trailing }
/// 실제: `public enum ControlSize: CaseIterable { case mini, small, regular, large, extraLarge }`
public enum ControlSize: CaseIterable { case mini, small, regular, large, extraLarge }
/// 실제: `public enum SymbolRenderingMode` — 실물은 struct + static 이다.
public struct SymbolRenderingMode {
    private let tag: Int
    public static let monochrome = SymbolRenderingMode(tag: 0)
    public static let hierarchical = SymbolRenderingMode(tag: 1)
    public static let palette = SymbolRenderingMode(tag: 2)
    public static let multicolor = SymbolRenderingMode(tag: 3)
}

// MARK: - 애니메이션

/// 실제: `public struct Animation: Equatable { public static let `default`: Animation
///          public static func easeInOut(duration: Double) -> Animation
///          public static func spring(response: Double = 0.55, dampingFraction: Double = 0.825,
///                                    blendDuration: Double = 0) -> Animation }`
public struct Animation: Equatable {
    private let tag: Int
    private init(tag: Int) { self.tag = tag }
    public static let `default` = Animation(tag: 0)
    public static func easeInOut(duration: Double) -> Animation { Animation(tag: 1) }
    public static var easeInOut: Animation { Animation(tag: 1) }
    public static func easeIn(duration: Double) -> Animation { Animation(tag: 2) }
    public static func easeOut(duration: Double) -> Animation { Animation(tag: 3) }
    public static func linear(duration: Double) -> Animation { Animation(tag: 4) }
    public static func spring(response: Double = 0.55, dampingFraction: Double = 0.825,
                              blendDuration: Double = 0) -> Animation { Animation(tag: 5) }
    public static func spring(duration: Double = 0.5, bounce: Double = 0,
                              blendDuration: Double = 0) -> Animation { Animation(tag: 5) }
    public func delay(_ delay: Double) -> Animation { self }
    public func speed(_ speed: Double) -> Animation { self }
}
/// 실제: `@frozen public struct AnyTransition {
///          public static let opacity/identity/scale/slide: AnyTransition
///          public static func move(edge: Edge) -> AnyTransition
///          public func combined(with other: AnyTransition) -> AnyTransition
///          public func animation(_ a: Animation?) -> AnyTransition }`
public struct AnyTransition {
    private let tag: Int
    private init(tag: Int) { self.tag = tag }
    public static let opacity = AnyTransition(tag: 0)
    public static let identity = AnyTransition(tag: 1)
    public static let scale = AnyTransition(tag: 2)
    public static let slide = AnyTransition(tag: 3)
    public static func move(edge: Edge) -> AnyTransition { AnyTransition(tag: 4) }
    public static func opacity(_ o: Double) -> AnyTransition { AnyTransition(tag: 0) }
    public func combined(with other: AnyTransition) -> AnyTransition { self }
    public func animation(_ animation: Animation?) -> AnyTransition { self }
}

// MARK: - 프로퍼티 래퍼

/// 실제: `@frozen @propertyWrapper public struct State<Value>: DynamicProperty {
///          public init(wrappedValue value: Value); public init(initialValue value: Value)
///          public var wrappedValue: Value { get nonmutating set }
///          public var projectedValue: Binding<Value> { get } }`
/// 확신 없음: 실물의 `wrappedValue` 는 `nonmutating set` 이다(뷰가 구조체라 필수).
/// 여기서도 그렇게 뒀지만, 저장은 흉내 내지 않는다.
@propertyWrapper public struct State<Value> {
    private final class Box { var v: Value; init(_ v: Value) { self.v = v } }
    private let box: Box
    public init(wrappedValue value: Value) { box = Box(value) }
    public init(initialValue value: Value) { box = Box(value) }
    public var wrappedValue: Value {
        get { box.v }
        nonmutating set { box.v = newValue }
    }
    public var projectedValue: Binding<Value> {
        Binding(get: { box.v }, set: { box.v = $0 })
    }
}

/// 실제: `@frozen @propertyWrapper @dynamicMemberLookup public struct Binding<Value> {
///          public init(get: @escaping () -> Value, set: @escaping (Value) -> Void)
///          public var wrappedValue: Value { get nonmutating set }
///          public var projectedValue: Binding<Value> { get }
///          public subscript<Subject>(dynamicMember keyPath: WritableKeyPath<Value, Subject>)
///              -> Binding<Subject> { get } }`
@dynamicMemberLookup @propertyWrapper public struct Binding<Value> {
    private let getter: () -> Value
    private let setter: (Value) -> Void
    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        getter = get; setter = set
    }
    public var wrappedValue: Value {
        get { getter() }
        nonmutating set { setter(newValue) }
    }
    public var projectedValue: Binding<Value> { self }
    public subscript<Subject>(dynamicMember keyPath: WritableKeyPath<Value, Subject>)
        -> Binding<Subject> {
        Binding<Subject>(get: { getter()[keyPath: keyPath] }, set: { _ in })
    }
    /// 실제: `public static func constant(_ value: Value) -> Binding<Value>`
    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { _ in })
    }
}
extension Binding where Value: MutableCollection {
    // (자리표시자 — 현 호출부에는 없다)
}

/// 실제: `@propertyWrapper @frozen public struct ObservedObject<ObjectType>: DynamicProperty
///          where ObjectType: ObservableObject {
///          @dynamicMemberLookup @frozen public struct Wrapper { … }
///          public init(wrappedValue: ObjectType)
///          public var wrappedValue: ObjectType
///          public var projectedValue: ObservedObject<ObjectType>.Wrapper { get } }`
@propertyWrapper public struct ObservedObject<ObjectType: ObservableObject> {
    public var wrappedValue: ObjectType
    public init(wrappedValue: ObjectType) { self.wrappedValue = wrappedValue }
    public init(initialValue: ObjectType) { self.wrappedValue = initialValue }
    @dynamicMemberLookup public struct Wrapper {
        let object: ObjectType
        public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, Subject>)
            -> Binding<Subject> {
            Binding(get: { object[keyPath: keyPath] }, set: { _ in })
        }
    }
    public var projectedValue: Wrapper { Wrapper(object: wrappedValue) }
}

/// 실제: `@propertyWrapper @frozen public struct StateObject<ObjectType>: DynamicProperty
///          where ObjectType: ObservableObject {
///          @inlinable public init(wrappedValue thunk: @autoclosure @escaping () -> ObjectType) … }`
/// 확신 없음: 실물의 이니셜라이저는 `@autoclosure` 다(그래서 `StateObject(wrappedValue: Foo())`
/// 가 뷰 생성마다 Foo 를 만들지 않는다). 타입체크에는 차이가 없지만 그대로 적어 둔다.
@propertyWrapper public struct StateObject<ObjectType: ObservableObject> {
    private let thunk: () -> ObjectType
    public init(wrappedValue: @autoclosure @escaping () -> ObjectType) { thunk = wrappedValue }
    public var wrappedValue: ObjectType { thunk() }
    public var projectedValue: ObservedObject<ObjectType>.Wrapper {
        ObservedObject<ObjectType>.Wrapper(object: thunk())
    }
}

/// 실제: `@frozen @propertyWrapper public struct Environment<Value>: DynamicProperty {
///          @inlinable public init(_ keyPath: KeyPath<EnvironmentValues, Value>)
///          @inlinable public var wrappedValue: Value { get } }`
@propertyWrapper public struct Environment<Value> {
    private let keyPath: KeyPath<EnvironmentValues, Value>
    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) { self.keyPath = keyPath }
    public var wrappedValue: Value { EnvironmentValues()[keyPath: keyPath] }
}

/// 실제: `public struct EnvironmentValues: CustomStringConvertible` — 수백 개의 계산 프로퍼티가
/// 확장으로 흩어져 있다. **호출부가 실제로 읽는 것만** 둔다(현재는 `\.dismiss` 하나).
public struct EnvironmentValues {
    public init() {}
    public var dismiss: DismissAction { DismissAction() }
    public var accessibilityReduceMotion: Bool { false }
    public var accessibilityReduceTransparency: Bool { false }
    public var colorScheme: ColorScheme { .light }
    public var isEnabled: Bool { true }
    public var openURL: OpenURLAction { OpenURLAction() }
}
/// 실제: `public struct DismissAction { public func callAsFunction() }`
public struct DismissAction {
    public func callAsFunction() {}
}
/// 실제: `public struct OpenURLAction { public func callAsFunction(_ url: URL) }`
public struct OpenURLAction {
    public func callAsFunction(_ url: URL) {}
}
/// 실제: `public enum ColorScheme: CaseIterable { case light, dark }`
public enum ColorScheme: CaseIterable { case light, dark }

/// 실제: `@propertyWrapper public struct FocusState<Value>: DynamicProperty where Value: Hashable {
///          public init() where Value == Bool
///          public init() where Value: ExpressibleByNilLiteral
///          public var wrappedValue: Value { get nonmutating set }
///          public var projectedValue: FocusState<Value>.Binding { get } }`
@propertyWrapper public struct FocusState<Value: Hashable> {
    private final class Box { var v: Value?; init() {} }
    private let box = Box()
    /// 확신 없음: 실물의 `init()` 은 `Value == Bool` 과 `Value: ExpressibleByNilLiteral` 두
    /// 제약 확장에만 있다. 여기서는 **제약 없이** 둔다 — 제약 확장에 두면 `@FocusState private
    /// var focusedText: Int?` 를 가진 뷰의 **멤버와이즈 이니셜라이저**가 그 프로퍼티를 기본값
    /// 없는 인자로 잡아 버린다(실측 2026-08-21: `PropertyEditorView` 가
    /// `missing argument for parameter 'focusedText'` + `initializer is inaccessible due to
    /// 'private' protection level` 로 막혔다). 실물보다 관대하다.
    public init() {}
    public var wrappedValue: Value {
        get { box.v! }
        nonmutating set { box.v = newValue }
    }
    /// 실제: `FocusState.Binding` 은 `Binding` 과 **다른 타입**이다(`.focused($x)` 가 그것을 받는다).
    /// 저장은 흉내 내지 않는다 — 타입만 맞으면 된다.
    @propertyWrapper public struct Binding {
        public init() {}
        public var wrappedValue: Value {
            get { fatalError("linux shim") }
            nonmutating set {}
        }
        public var projectedValue: FocusState<Value>.Binding { self }
    }
    public var projectedValue: Binding { Binding() }
}

// MARK: - 툴바

/// 실제: `public protocol ToolbarContent { associatedtype Body: ToolbarContent
///                                         @ToolbarContentBuilder var body: Self.Body { get } }`
public protocol ToolbarContent {}
/// 실제: `@resultBuilder public struct ToolbarContentBuilder`
@resultBuilder public struct ToolbarContentBuilder {
    public static func buildBlock(_ parts: any ToolbarContent...) -> AnyToolbarContent {
        AnyToolbarContent()
    }
    public static func buildExpression(_ e: any ToolbarContent) -> AnyToolbarContent {
        AnyToolbarContent()
    }
    public static func buildOptional(_ c: AnyToolbarContent?) -> AnyToolbarContent {
        AnyToolbarContent()
    }
    public static func buildEither(first: AnyToolbarContent) -> AnyToolbarContent {
        AnyToolbarContent()
    }
    public static func buildEither(second: AnyToolbarContent) -> AnyToolbarContent {
        AnyToolbarContent()
    }
}
/// **심 내부용 — 애플에는 없다.** 위 빌더가 접는 대상.
public struct AnyToolbarContent: ToolbarContent {
    public init() {}
}
/// 실제: `public struct ToolbarItem<ID, Content>: ToolbarContent where Content: View {
///          public init(placement: ToolbarItemPlacement = .automatic,
///                      @ViewBuilder content: () -> Content) }`
public struct ToolbarItem: ToolbarContent {
    public init(placement: ToolbarItemPlacement = .automatic,
                @ViewBuilder content: () -> AnyView) {}
    public init(id: String, placement: ToolbarItemPlacement = .automatic,
                @ViewBuilder content: () -> AnyView) {}
}
/// 실제: `public struct ToolbarItemGroup<Content>: ToolbarContent where Content: View`
public struct ToolbarItemGroup: ToolbarContent {
    public init(placement: ToolbarItemPlacement = .automatic,
                @ViewBuilder content: () -> AnyView) {}
}
/// 실제: `public struct ToolbarItemPlacement { public static let automatic/principal/
///          navigation/primaryAction/secondaryAction/cancellationAction/confirmationAction/
///          destructiveAction/status/… }`
public struct ToolbarItemPlacement {
    private let tag: Int
    public static let automatic = ToolbarItemPlacement(tag: 0)
    public static let principal = ToolbarItemPlacement(tag: 1)
    public static let navigation = ToolbarItemPlacement(tag: 2)
    public static let primaryAction = ToolbarItemPlacement(tag: 3)
    public static let secondaryAction = ToolbarItemPlacement(tag: 4)
    public static let cancellationAction = ToolbarItemPlacement(tag: 5)
    public static let confirmationAction = ToolbarItemPlacement(tag: 6)
    public static let destructiveAction = ToolbarItemPlacement(tag: 7)
    public static let status = ToolbarItemPlacement(tag: 8)
}

// MARK: - 컨트롤 스타일 값
//
// 실물은 각각 `ButtonStyle`/`PrimitiveButtonStyle` 같은 프로토콜 + 구체 타입이고,
// `.bordered` 는 `PrimitiveButtonStyle where Self == BorderedButtonStyle` 확장의 static 이다.
// 여기서는 **구체 타입 하나 + static 상수**로 접는다 — 선행 점 이름이 틀리면 잡히고,
// 커스텀 스타일 타입을 만드는 코드는 이 리포에 없다.

/// 실제: `.bordered`/`.borderedProminent`/`.plain`/`.borderless`/`.link` 등.
public struct ButtonStyleShim {
    private let tag: Int
    public static let automatic = ButtonStyleShim(tag: 0)
    public static let bordered = ButtonStyleShim(tag: 1)
    public static let borderedProminent = ButtonStyleShim(tag: 2)
    public static let plain = ButtonStyleShim(tag: 3)
    public static let borderless = ButtonStyleShim(tag: 4)
    public static let link = ButtonStyleShim(tag: 5)
    public static let accessoryBar = ButtonStyleShim(tag: 6)
}
/// 실제: `.automatic`/`.iconOnly`/`.titleOnly`/`.titleAndIcon`
public struct LabelStyleShim {
    private let tag: Int
    public static let automatic = LabelStyleShim(tag: 0)
    public static let iconOnly = LabelStyleShim(tag: 1)
    public static let titleOnly = LabelStyleShim(tag: 2)
    public static let titleAndIcon = LabelStyleShim(tag: 3)
}
/// 실제: `.automatic`/`.sidebar`/`.inset`/`.plain`/`.bordered`
public struct ListStyleShim {
    private let tag: Int
    public static let automatic = ListStyleShim(tag: 0)
    public static let sidebar = ListStyleShim(tag: 1)
    public static let inset = ListStyleShim(tag: 2)
    public static let plain = ListStyleShim(tag: 3)
    public static let bordered = ListStyleShim(tag: 4)
}
/// 실제: `.automatic`/`.inline`/`.menu`/`.segmented`/`.radioGroup`/`.palette`
public struct PickerStyleShim {
    private let tag: Int
    public static let automatic = PickerStyleShim(tag: 0)
    public static let inline = PickerStyleShim(tag: 1)
    public static let menu = PickerStyleShim(tag: 2)
    public static let segmented = PickerStyleShim(tag: 3)
    public static let radioGroup = PickerStyleShim(tag: 4)
    public static let palette = PickerStyleShim(tag: 5)
}
/// 실제: `.automatic`/`.borderlessButton`/`.button`
public struct MenuStyleShim {
    private let tag: Int
    public static let automatic = MenuStyleShim(tag: 0)
    public static let borderlessButton = MenuStyleShim(tag: 1)
    public static let button = MenuStyleShim(tag: 2)
}
/// 실제: `.automatic`/`.plain`/`.roundedBorder`/`.squareBorder`
public struct TextFieldStyleShim {
    private let tag: Int
    public static let automatic = TextFieldStyleShim(tag: 0)
    public static let plain = TextFieldStyleShim(tag: 1)
    public static let roundedBorder = TextFieldStyleShim(tag: 2)
    public static let squareBorder = TextFieldStyleShim(tag: 3)
}
/// 실제: `.automatic`/`.columns`/`.grouped`
public struct FormStyleShim {
    private let tag: Int
    public static let automatic = FormStyleShim(tag: 0)
    public static let columns = FormStyleShim(tag: 1)
    public static let grouped = FormStyleShim(tag: 2)
}
/// 실제: `.automatic`/`.balanced`/`.prominentDetail`
public struct NavigationSplitViewStyleShim {
    private let tag: Int
    public static let automatic = NavigationSplitViewStyleShim(tag: 0)
    public static let balanced = NavigationSplitViewStyleShim(tag: 1)
    public static let prominentDetail = NavigationSplitViewStyleShim(tag: 2)
}
/// 실제: `.automatic`/`.circular`/`.linear`
public struct ProgressViewStyleShim {
    private let tag: Int
    public static let automatic = ProgressViewStyleShim(tag: 0)
    public static let circular = ProgressViewStyleShim(tag: 1)
    public static let linear = ProgressViewStyleShim(tag: 2)
}
/// 실제: `public struct SearchFieldPlacement { public static let automatic/toolbar/sidebar/… }`
public struct SearchFieldPlacement {
    private let tag: Int
    public static let automatic = SearchFieldPlacement(tag: 0)
    public static let toolbar = SearchFieldPlacement(tag: 1)
    public static let sidebar = SearchFieldPlacement(tag: 2)
}

// MARK: - 접근성 / 키

/// 실제: `public struct AccessibilityTraits: SetAlgebra { public static let isButton/isHeader/
///          isSelected/isImage/isLink/… }`
public struct AccessibilityTraits: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let isButton = AccessibilityTraits(rawValue: 1 << 0)
    public static let isHeader = AccessibilityTraits(rawValue: 1 << 1)
    public static let isSelected = AccessibilityTraits(rawValue: 1 << 2)
    public static let isImage = AccessibilityTraits(rawValue: 1 << 3)
    public static let isLink = AccessibilityTraits(rawValue: 1 << 4)
    public static let isSummaryElement = AccessibilityTraits(rawValue: 1 << 5)
    public static let updatesFrequently = AccessibilityTraits(rawValue: 1 << 6)
    public static let isModal = AccessibilityTraits(rawValue: 1 << 7)
}
/// 실제: `public struct AccessibilityActionKind: Equatable {
///          public static let `default`/escape/magicTap/… : AccessibilityActionKind }`
public struct AccessibilityActionKind: Equatable {
    private let tag: Int
    public static let `default` = AccessibilityActionKind(tag: 0)
    public static let escape = AccessibilityActionKind(tag: 1)
    public static let magicTap = AccessibilityActionKind(tag: 2)
}

/// 실제: `public struct AccessibilityChildBehavior { public static let ignore/contain/combine }`
public struct AccessibilityChildBehavior {
    private let tag: Int
    public static let ignore = AccessibilityChildBehavior(tag: 0)
    public static let contain = AccessibilityChildBehavior(tag: 1)
    public static let combine = AccessibilityChildBehavior(tag: 2)
}
/// 실제: `public struct KeyEquivalent: ExpressibleByExtendedGraphemeClusterLiteral {
///          public static let escape/`return`/upArrow/downArrow/…: KeyEquivalent
///          public init(_ character: Character) }`
public struct KeyEquivalent: ExpressibleByExtendedGraphemeClusterLiteral {
    public typealias ExtendedGraphemeClusterLiteralType = Character
    public init(extendedGraphemeClusterLiteral value: Character) {}
    public init(_ character: Character) {}
    public static let escape = KeyEquivalent(" ")
    public static let `return` = KeyEquivalent(" ")
    public static let space = KeyEquivalent(" ")
    public static let tab = KeyEquivalent(" ")
    public static let delete = KeyEquivalent(" ")
    public static let upArrow = KeyEquivalent(" ")
    public static let downArrow = KeyEquivalent(" ")
    public static let leftArrow = KeyEquivalent(" ")
    public static let rightArrow = KeyEquivalent(" ")
}
/// 실제: `public struct KeyboardShortcut { public static let defaultAction/cancelAction }`
public struct KeyboardShortcut {
    private let tag: Int
    public static let defaultAction = KeyboardShortcut(tag: 0)
    public static let cancelAction = KeyboardShortcut(tag: 1)
}
/// 실제: `public struct EventModifiers: OptionSet { static let command/shift/option/control/… }`
public struct EventModifiers: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = EventModifiers(rawValue: 1 << 0)
    public static let shift = EventModifiers(rawValue: 1 << 1)
    public static let option = EventModifiers(rawValue: 1 << 2)
    public static let control = EventModifiers(rawValue: 1 << 3)
}
/// 실제(macOS 14+): `public struct KeyPress { public let key: KeyEquivalent
///          public let modifiers: EventModifiers
///          public enum Result { case handled, ignored } }`
public struct KeyPress {
    public enum Result { case handled, ignored }
    public var key: KeyEquivalent { .space }
    public var modifiers: EventModifiers { [] }
}

// MARK: - AppKit 브리지

/// 실제: `public protocol NSViewRepresentable: View where Self.Body == Never {
///          associatedtype NSViewType: NSView
///          associatedtype Coordinator = Void
///          func makeNSView(context: Self.Context) -> Self.NSViewType
///          func updateNSView(_ nsView: Self.NSViewType, context: Self.Context)
///          func makeCoordinator() -> Self.Coordinator
///          typealias Context = NSViewRepresentableContext<Self> }`
/// 확신 없음: `Body == Never` 제약을 여기서는 걸지 않는다(원시 뷰의 `Body` 를 `AnyView` 로
/// 접었기 때문). 그래서 실물보다 관대하다.
@MainActor public protocol NSViewRepresentable: View {
    associatedtype NSViewType: NSView
    associatedtype Coordinator = Void
    typealias Context = NSViewRepresentableContext<Self>
    func makeNSView(context: Context) -> NSViewType
    func updateNSView(_ nsView: NSViewType, context: Context)
    func makeCoordinator() -> Coordinator
}
extension NSViewRepresentable {
    public var body: AnyView { AnyView() }
}
extension NSViewRepresentable where Coordinator == Void {
    public func makeCoordinator() -> Void { () }
}
/// 실제: `public struct NSViewRepresentableContext<Representable> where Representable: NSViewRepresentable {
///          public var coordinator: Representable.Coordinator { get }
///          public var environment: EnvironmentValues { get } }`
public struct NSViewRepresentableContext<Representable: NSViewRepresentable> {
    public var coordinator: Representable.Coordinator { fatalError("linux shim") }
    public var environment: EnvironmentValues { EnvironmentValues() }
}

/// 실제(SwiftUI): `open class NSHostingController<Content>: NSViewController where Content: View {
///          public init(rootView: Content)
///          public var rootView: Content
///          public var sceneBridgingOptions: NSHostingSceneBridgingOptions }`
/// `NSViewController` 는 `appkit-app.swift` 가 낸다(`NSWindow(contentViewController:)` 가 그
/// 타입을 받으므로 상속 계층을 실물대로 맞춘다).
@MainActor open class NSHostingController<Content: View>: NSViewController {
    public var rootView: Content
    public init(rootView: Content) { self.rootView = rootView; super.init() }
    public var sceneBridgingOptions: NSHostingSceneBridgingOptions = []
}
/// 실제: `public struct NSHostingSceneBridgingOptions: OptionSet { static let title/toolbars }`
public struct NSHostingSceneBridgingOptions: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let title = NSHostingSceneBridgingOptions(rawValue: 1 << 0)
    public static let toolbars = NSHostingSceneBridgingOptions(rawValue: 1 << 1)
}

// MARK: - View 수식어
//
// **전부 `AnyView` 를 돌려준다**(머리말 참조). 반환 타입을 접었을 뿐 **인자는 접지 않았다** —
// 인자 라벨·타입·선행 점 이름이 틀리면 그대로 잡힌다.

extension View {
    // ── 레이아웃 ──
    public func padding(_ length: CGFloat? = nil) -> AnyView { AnyView() }
    public func padding(_ edges: Edge.Set, _ length: CGFloat? = nil) -> AnyView { AnyView() }
    public func padding(_ insets: EdgeInsets) -> AnyView { AnyView() }
    public func frame(width: CGFloat? = nil, height: CGFloat? = nil,
                      alignment: Alignment = .center) -> AnyView { AnyView() }
    public func frame(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
                      minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil,
                      alignment: Alignment = .center) -> AnyView { AnyView() }
    public func fixedSize() -> AnyView { AnyView() }
    public func fixedSize(horizontal: Bool, vertical: Bool) -> AnyView { AnyView() }
    public func layoutPriority(_ value: Double) -> AnyView { AnyView() }
    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> AnyView { AnyView() }
    public func scaledToFit() -> AnyView { AnyView() }
    public func scaledToFill() -> AnyView { AnyView() }
    public func aspectRatio(_ aspectRatio: CGFloat? = nil, contentMode: ContentMode) -> AnyView { AnyView() }
    public func resizable() -> AnyView { AnyView() }
    public func clipped() -> AnyView { AnyView() }
    public func clipShape(_ shape: some Shape) -> AnyView { AnyView() }
    public func contentShape(_ shape: some Shape) -> AnyView { AnyView() }
    public func scaleEffect(_ scale: CGFloat, anchor: UnitPoint = .center) -> AnyView { AnyView() }

    // ── 그리기 ──
    public func background(_ style: some ShapeStyle) -> AnyView { AnyView() }
    public func background<S: ShapeStyle, Sh: Shape>(_ style: S, in shape: Sh) -> AnyView { AnyView() }
    public func background(alignment: Alignment = .center,
                           @ViewBuilder content: () -> AnyView) -> AnyView { AnyView() }
    public func overlay(alignment: Alignment = .center,
                        @ViewBuilder content: () -> AnyView) -> AnyView { AnyView() }
    public func overlay(_ overlay: AnyView, alignment: Alignment = .center) -> AnyView { AnyView() }
    public func overlay<S: ShapeStyle, Sh: Shape>(_ style: S, in shape: Sh) -> AnyView { AnyView() }
    public func foregroundStyle(_ style: some ShapeStyle) -> AnyView { AnyView() }
    public func foregroundStyle<S1: ShapeStyle, S2: ShapeStyle>(_ p: S1, _ s: S2) -> AnyView { AnyView() }
    public func foregroundColor(_ color: Color?) -> AnyView { AnyView() }
    public func tint(_ tint: Color?) -> AnyView { AnyView() }
    public func accentColor(_ accentColor: Color?) -> AnyView { AnyView() }
    public func opacity(_ opacity: Double) -> AnyView { AnyView() }
    public func saturation(_ amount: Double) -> AnyView { AnyView() }
    public func shadow(color: Color = .black, radius: CGFloat,
                       x: CGFloat = 0, y: CGFloat = 0) -> AnyView { AnyView() }
    public func hidden() -> AnyView { AnyView() }
    public func symbolRenderingMode(_ mode: SymbolRenderingMode?) -> AnyView { AnyView() }
    /// `Shape` 전용이지만 여기서는 `View` 확장으로 둔다(반환 타입을 접었으므로 구분이 무의미).
    public func fill(_ style: some ShapeStyle) -> AnyView { AnyView() }
    public func stroke(_ style: some ShapeStyle, lineWidth: CGFloat = 1) -> AnyView { AnyView() }
    public func strokeBorder(_ style: some ShapeStyle, lineWidth: CGFloat = 1) -> AnyView { AnyView() }

    // ── 글자 ──
    public func font(_ font: Font?) -> AnyView { AnyView() }
    public func fontWeight(_ weight: Font.Weight?) -> AnyView { AnyView() }
    public func bold(_ isActive: Bool = true) -> AnyView { AnyView() }
    public func monospacedDigit() -> AnyView { AnyView() }
    public func lineLimit(_ number: Int?) -> AnyView { AnyView() }
    public func lineSpacing(_ lineSpacing: CGFloat) -> AnyView { AnyView() }
    public func truncationMode(_ mode: Text.TruncationMode) -> AnyView { AnyView() }
    public func multilineTextAlignment(_ alignment: TextAlignment) -> AnyView { AnyView() }
    public func textSelection(_ selectability: Bool) -> AnyView { AnyView() }

    // ── 상태·상호작용 ──
    public func disabled(_ disabled: Bool) -> AnyView { AnyView() }
    public func id<ID: Hashable>(_ id: ID) -> AnyView { AnyView() }
    public func tag<V: Hashable>(_ tag: V) -> AnyView { AnyView() }
    public func help(_ text: String) -> AnyView { AnyView() }
    public func help(_ text: Text) -> AnyView { AnyView() }
    public func onTapGesture(count: Int = 1, perform action: @escaping () -> Void) -> AnyView { AnyView() }
    public func onHover(perform action: @escaping (Bool) -> Void) -> AnyView { AnyView() }
    public func onAppear(perform action: (() -> Void)? = nil) -> AnyView { AnyView() }
    public func onDisappear(perform action: (() -> Void)? = nil) -> AnyView { AnyView() }
    public func task(priority: TaskPriority = .userInitiated,
                     _ action: @escaping @Sendable () async -> Void) -> AnyView { AnyView() }
    public func task<T: Equatable>(id value: T, priority: TaskPriority = .userInitiated,
                                   _ action: @escaping @Sendable () async -> Void) -> AnyView { AnyView() }
    public func onChange<V: Equatable>(of value: V,
                                       perform action: @escaping (V) -> Void) -> AnyView { AnyView() }
    public func onChange<V: Equatable>(of value: V, initial: Bool = false,
                                       _ action: @escaping (V, V) -> Void) -> AnyView { AnyView() }
    public func onChange<V: Equatable>(of value: V, initial: Bool = false,
                                       _ action: @escaping () -> Void) -> AnyView { AnyView() }
    public func onSubmit(of triggers: SubmitTriggers = .text,
                         _ action: @escaping () -> Void) -> AnyView { AnyView() }
    public func onReceive<P: Publisher>(_ publisher: P,
                                        perform action: @escaping (P.Output) -> Void) -> AnyView
        where P.Failure == Never { AnyView() }
    public func focusable(_ isFocusable: Bool = true) -> AnyView { AnyView() }
    public func focused<V: Hashable>(_ binding: FocusState<V>.Binding, equals value: V) -> AnyView { AnyView() }
    public func focused(_ condition: FocusState<Bool>.Binding) -> AnyView { AnyView() }
    public func onKeyPress(_ key: KeyEquivalent,
                           action: @escaping () -> KeyPress.Result) -> AnyView { AnyView() }
    public func keyboardShortcut(_ shortcut: KeyboardShortcut) -> AnyView { AnyView() }
    public func keyboardShortcut(_ key: KeyEquivalent,
                                 modifiers: EventModifiers = .command) -> AnyView { AnyView() }

    // ── 스타일 ──
    public func buttonStyle(_ style: ButtonStyleShim) -> AnyView { AnyView() }
    public func labelStyle(_ style: LabelStyleShim) -> AnyView { AnyView() }
    public func listStyle(_ style: ListStyleShim) -> AnyView { AnyView() }
    public func pickerStyle(_ style: PickerStyleShim) -> AnyView { AnyView() }
    public func menuStyle(_ style: MenuStyleShim) -> AnyView { AnyView() }
    public func textFieldStyle(_ style: TextFieldStyleShim) -> AnyView { AnyView() }
    public func formStyle(_ style: FormStyleShim) -> AnyView { AnyView() }
    public func progressViewStyle(_ style: ProgressViewStyleShim) -> AnyView { AnyView() }
    public func navigationSplitViewStyle(_ style: NavigationSplitViewStyleShim) -> AnyView { AnyView() }
    public func controlSize(_ controlSize: ControlSize) -> AnyView { AnyView() }
    public func imageScale(_ scale: ImageScale) -> AnyView { AnyView() }

    // ── 창/열 ──
    public func navigationSplitViewColumnWidth(_ width: CGFloat) -> AnyView { AnyView() }
    public func navigationSplitViewColumnWidth(min: CGFloat? = nil, ideal: CGFloat,
                                               max: CGFloat? = nil) -> AnyView { AnyView() }
    public func inspectorColumnWidth(_ width: CGFloat) -> AnyView { AnyView() }
    public func inspectorColumnWidth(min: CGFloat? = nil, ideal: CGFloat,
                                     max: CGFloat? = nil) -> AnyView { AnyView() }
    public func inspector(isPresented: Binding<Bool>,
                          @ViewBuilder content: () -> AnyView) -> AnyView { AnyView() }
    public func toolbar(@ToolbarContentBuilder content: () -> AnyToolbarContent) -> AnyView { AnyView() }
    public func toolbar(_ content: some ToolbarContent) -> AnyView { AnyView() }
    public func searchable(text: Binding<String>,
                           placement: SearchFieldPlacement = .automatic,
                           prompt: Text? = nil) -> AnyView { AnyView() }
    public func searchable(text: Binding<String>,
                           placement: SearchFieldPlacement = .automatic,
                           prompt: String) -> AnyView { AnyView() }
    public func navigationTitle(_ title: String) -> AnyView { AnyView() }

    // ── 표시(sheet/popover/alert) ──
    public func sheet(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                      @ViewBuilder content: @escaping () -> AnyView) -> AnyView { AnyView() }
    public func popover(isPresented: Binding<Bool>, arrowEdge: Edge = .top,
                        @ViewBuilder content: @escaping () -> AnyView) -> AnyView { AnyView() }
    public func alert(_ title: String, isPresented: Binding<Bool>,
                      @ViewBuilder actions: () -> AnyView) -> AnyView { AnyView() }
    public func alert(_ title: String, isPresented: Binding<Bool>,
                      @ViewBuilder actions: () -> AnyView,
                      @ViewBuilder message: () -> AnyView) -> AnyView { AnyView() }
    public func confirmationDialog(_ title: String, isPresented: Binding<Bool>,
                                   titleVisibility: Visibility = .automatic,
                                   @ViewBuilder actions: () -> AnyView) -> AnyView { AnyView() }
    public func confirmationDialog(_ title: String, isPresented: Binding<Bool>,
                                   titleVisibility: Visibility = .automatic,
                                   @ViewBuilder actions: () -> AnyView,
                                   @ViewBuilder message: () -> AnyView) -> AnyView { AnyView() }
    public func contextMenu(@ViewBuilder menuItems: () -> AnyView) -> AnyView { AnyView() }

    // ── 드래그 앤 드롭 ──
    public func onDrag(_ data: @escaping () -> NSItemProvider) -> AnyView { AnyView() }
    public func onDrop(of supportedContentTypes: [UTType], isTargeted: Binding<Bool>?,
                       perform action: @escaping ([NSItemProvider]) -> Bool) -> AnyView { AnyView() }

    // ── 애니메이션 ──
    public func animation<V: Equatable>(_ animation: Animation?, value: V) -> AnyView { AnyView() }
    public func transition(_ t: AnyTransition) -> AnyView { AnyView() }

    // ── 접근성 ──
    public func accessibilityLabel(_ label: String) -> AnyView { AnyView() }
    public func accessibilityLabel(_ label: Text) -> AnyView { AnyView() }
    public func accessibilityValue(_ value: String) -> AnyView { AnyView() }
    public func accessibilityValue(_ value: Text) -> AnyView { AnyView() }
    public func accessibilityHint(_ hint: String) -> AnyView { AnyView() }
    public func accessibilityHint(_ hint: Text) -> AnyView { AnyView() }
    public func accessibilityHidden(_ hidden: Bool) -> AnyView { AnyView() }
    public func accessibilityAddTraits(_ traits: AccessibilityTraits) -> AnyView { AnyView() }
    public func accessibilityRemoveTraits(_ traits: AccessibilityTraits) -> AnyView { AnyView() }
    public func accessibilityElement(children: AccessibilityChildBehavior = .ignore) -> AnyView { AnyView() }
    public func accessibilityAction(named name: Text,
                                    _ handler: @escaping () -> Void) -> AnyView { AnyView() }
    public func accessibilityAction(named name: String,
                                    _ handler: @escaping () -> Void) -> AnyView { AnyView() }
    /// 실제: `public func accessibilityAction(_ actionKind: AccessibilityActionKind = .default,
    ///          _ handler: @escaping () -> Void) -> ModifiedContent<...>`
    /// (`RemoteTile.swift:108` 이 기본 액션(VO-Space)을 채운다.)
    public func accessibilityAction(_ actionKind: AccessibilityActionKind = .default,
                                    _ handler: @escaping () -> Void) -> AnyView { AnyView() }
    public func accessibilitySortPriority(_ sortPriority: Double) -> AnyView { AnyView() }

    // ── 그 밖 ──
    public func modifier<M: ViewModifier>(_ modifier: M) -> AnyView { AnyView() }
    public func environmentObject<T: ObservableObject>(_ object: T) -> AnyView { AnyView() }
    public func environment<V>(_ keyPath: WritableKeyPath<EnvironmentValues, V>,
                               _ value: V) -> AnyView { AnyView() }
}

/// 실제: `public enum Visibility: Hashable, CaseIterable { case automatic, visible, hidden }`
public enum Visibility: Hashable, CaseIterable { case automatic, visible, hidden }
/// 실제: `public struct SubmitTriggers: OptionSet { static let text, search }`
public struct SubmitTriggers: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let text = SubmitTriggers(rawValue: 1 << 0)
    public static let search = SubmitTriggers(rawValue: 1 << 1)
}
/// 실제: `public enum Image.Scale { case small, medium, large }` — `Image.Scale` 이지만
/// 중첩 타입 이름 충돌을 피해 최상위로 뒀다. **실물과 이름이 다르다.**
public enum ImageScale { case small, medium, large }

// MARK: - 전역 함수

/// 실제: `public func withAnimation<Result>(_ animation: Animation? = .default,
///          _ body: () throws -> Result) rethrows -> Result`
/// 확신 없음: macOS 14 SDK 에서는 `@MainActor` 가 붙어 있을 수 있다. 호출부
/// (`DesignSystem/Motion.swift:80` 의 `Motion.run`)는 `static func` 안에서 부르므로
/// 여기서는 격리를 붙이지 않는다 — 붙이면 그 자리가 막힌다.
@discardableResult
public func withAnimation<Result>(_ animation: Animation? = .default,
                                  _ body: () throws -> Result) rethrows -> Result {
    try body()
}

/// 실제(SwiftUI 가 AppKit 에 얹는 확장): `extension NSColor { public convenience init(_ color: Color) }`
/// **AppKit 심이 아니라 여기 있다** — `appkit.swift` 는 SwiftUI 를 임포트하지 않고(순환),
/// 애플에서도 이 이니셜라이저는 SwiftUI 가 낸다.
extension NSColor {
    public convenience init(_ color: Color) { self.init() }
}
