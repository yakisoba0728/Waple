// **애플 플랫폼의 "Clang 모듈 전이 노출" 을 흉내 내는 서곡(prelude) 파일.**
// `scripts/dev/linux-render-typecheck.sh --tests` 의 테스트 타입체크 단계에만 끼운다.
//
// 왜 필요한가
// -----------
// `Tests/WapleRenderTests/AudioCalibrationTests.swift` 는 `import Metal` 도 `import AppKit` 도
// 하지 않는데 `MTLCreateSystemDefaultDevice()` 와 `NSView` 를 쓴다. 그런데 **macOS CI 에서는
// 빌드된다**(실측: run 32484783071 · 3,140 테스트 0 실패). 스위프트가 임포트한 **Clang 모듈**은
// 클라이언트에게 전이로 보이기 때문이다 — `@testable import WapleRender` 하나로 WapleRender 가
// 임포트한 Metal·AppKit 이 따라 들어온다.
//
// 이 리포의 심은 전부 **스위프트** 모듈이라 그 전이가 일어나지 않는다. 그래서 심 모델이
// 실물보다 **엄격**해지고, 잡히는 오류가 전부 거짓 양성이 된다. 서곡으로 그 차이를 메운다.
//
// 한계(중요)
// ---------
// 이 파일은 심 모델을 실물보다 **관대**하게 만든다. macOS 는 `WapleRender`/`WapleCore` 가
// 실제로 임포트한 Clang 모듈만 흘리는데, 여기서는 심 전부를 흘린다. 두 집합은 지금 거의 같지만
// (WapleRender 가 아래 전부를 임포트한다) 심이 늘고 WapleRender 의 임포트가 줄면 갈린다.
// 그때는 **테스트에 `import` 를 되살리는 것이 아니라 이 목록을 줄이는 것**이 맞다.
//
// `Darwin` 은 일부러 뺐다 — `Sources/WapleCompatCore/**` 전용이고 테스트가 쓰지 않는다.
@_exported import Metal
@_exported import MetalKit
@_exported import AppKit
@_exported import CoreGraphics
@_exported import QuartzCore
@_exported import CoreVideo
@_exported import AVFoundation
@_exported import ScreenCaptureKit
@_exported import CoreText
@_exported import ImageIO
@_exported import Accelerate
@_exported import JavaScriptCore
@_exported import CryptoKit
@_exported import Compression
@_exported import WebKit
@_exported import UniformTypeIdentifiers
// [2026-08-21] `simd` 도 애플에서는 Clang 모듈이라 같은 전이가 일어난다 —
// `SceneRendererAuditV06RegressionTests` 는 `import simd` 없이 `matrix_identity_float4x4`
// 를 쓰는데 macOS 에서는 빌드된다(`@testable import WapleRender` 가 흘린다).
@_exported import simd
