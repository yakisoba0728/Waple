import Metal
import WapleCore

extension SceneRenderer {
    public func applyColorGradingSettings(_ settings: SceneColorGradingSettings) {
        colorGradingSettings = settings
        colorGradingLUT = nil
        guard let name = settings.lutName, !name.isEmpty, settings.lutAmount > 0,
              let device, let package = runtimePackage,
              let safe = WallpaperPathSecurity.normalizedRelativePath(name),
              !safe.contains("/") else { return }
        let resource = safe.hasSuffix(".tex") ? "lut/" + safe : "lut/" + safe + ".tex"
        if let texture = resolveTexture(resource, package: package, device: device), texture.textureType == .type3D {
            colorGradingLUT = texture
        } else {
            WapleLog.warn("[Waple] color grading LUT is unavailable or is not a volume: " + name)
        }
    }

    /// Fade alpha is supplied by a verified camera/transition controller; no speculative startup timing.
    public func setCameraFade(alpha: Float, tint: SIMD3<Float>) {
        cameraFadeAlpha = alpha.isFinite ? max(0, min(1, alpha)) : 0
        cameraFadeTint = tint.x.isFinite && tint.y.isFinite && tint.z.isFinite ? tint : .zero
    }
}
