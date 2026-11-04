import Foundation
import WapleCore

extension SceneRenderer {
    static func initialSpriteRefreshDelay(now: TimeInterval, frameTime: TimeInterval,
                                          rate: Double = 1) -> TimeInterval {
        guard now.isFinite, frameTime.isFinite, rate.isFinite, frameTime > 0, rate > 0 else { return 0 }
        let period = frameTime / rate
        guard period.isFinite, period > 0 else { return 0 }
        let phase = now.truncatingRemainder(dividingBy: period)
        if abs(phase) < 1e-9 { return 0 }
        return min(0.25, max(0, period - phase))
    }

    static func projectionSize(document: SceneDocument, drawable: CGSize) -> SIMD2<Float> {
        if document.orthoAuto, drawable.width.isFinite, drawable.height.isFinite,
           drawable.width > 0, drawable.height > 0 {
            return SIMD2(Float(min(16384, drawable.width)), Float(min(16384, drawable.height)))
        }
        return SIMD2(Float(max(1, document.projectionWidth)), Float(max(1, document.projectionHeight)))
    }

    func updateAutomaticProjection(_ size: CGSize) {
        guard automaticProjection, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        projW = Float(min(16384, size.width)); projH = Float(min(16384, size.height))
        projAspect = projW / projH
    }
}
