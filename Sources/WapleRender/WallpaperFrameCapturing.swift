import AppKit

/// Snapshot the mounted renderer without advancing simulation or reloading its
/// source. Completion returns nil when that mount no longer owns the frame.
public protocol WallpaperFrameCapturing: AnyObject {
    @MainActor func captureCurrentImage(completion: @escaping @MainActor @Sendable (NSImage?) -> Void)
}
