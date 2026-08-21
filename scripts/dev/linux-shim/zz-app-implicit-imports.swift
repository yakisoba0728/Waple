// **`--app` 테스트 단계 서곡(prelude)** — `Tests/WapleAppTests/**` 타입체크에만 끼운다.
// `zz-test-implicit-imports.swift` 와 같은 목적이고, 목록만 앱 계층에 맞췄다(그 파일 머리말 참조).
//
// 왜 테스트에만 넣는가
// -------------------
// `Sources/Waple/**` 는 **서곡 없이 rc=0 이다**(실측 2026-08-21, 46파일). 앱 계층 파일은 쓰는
// 것을 각자 명시적으로 임포트하고 있고, 유일한 전이 의존이던 `ObservableObject`(Combine)는
// `swiftui.swift` 가 애플과 똑같이 `@_exported import Combine` 으로 낸다. 소스 쪽에서는
// 엄격한 편이 맞으므로 넣지 않는다.
//
// **테스트는 다르다.** `AppUIFixRegressionTests.swift:242` 가 `import AppKit` 없이
// `NSBitmapImageRep` 을 쓰는데 macOS 에서는 빌드된다 — `@testable import Waple` 이 Waple 의
// Clang 모듈 임포트(AppKit 등)를 전이로 흘리기 때문이다. 서곡을 빼면 여기서만
// `cannot find 'NSBitmapImageRep' in scope` 로 깨진다(실측). 심은 전부 스위프트 모듈이라
// 그 전이가 일어나지 않으므로 이 파일이 그 차이를 메운다.
//
// 한계: `zz-test-implicit-imports.swift` 와 같다 — 이 파일은 모델을 실물보다 **관대**하게 만든다.
// macOS 는 `Waple` 이 실제로 임포트한 Clang 모듈만 흘리는데 여기서는 목록 전부를 흘린다.
// 어긋나기 시작하면 **테스트에 `import` 를 되살리는 것이 아니라 이 목록을 줄이는 것**이 맞다.
//
// `Metal`·`MetalKit`·`WebKit` 등은 `Sources/Waple/**` 가 `import WapleRender` 로 전이 노출을
// 받는 것들이다. `Security`·`ServiceManagement` 는 뺐다 — 테스트가 쓰는 `errSec*` 는
// `WorkshopAPITests` 가 `@testable import Waple` 로 받는다(실측으로 확인).
@_exported import AppKit
@_exported import SwiftUI
@_exported import CoreGraphics
@_exported import QuartzCore
@_exported import Combine
@_exported import UniformTypeIdentifiers
@_exported import AVFoundation
@_exported import CoreVideo
@_exported import Metal
@_exported import MetalKit
@_exported import WebKit
@_exported import CoreText
@_exported import ImageIO
@_exported import simd
