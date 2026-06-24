import AppKit
import WapleCore

public protocol WallpaperRenderer: AnyObject {
    /// 컨테이너 뷰에 배경을 mount 하고 재생을 시작한다.
    func mount(in container: NSView, project: WallpaperProject) throws
    func pause()
    func resume()
    func teardown()
}

public enum RendererError: Error, Equatable {
    case unsupportedType
    case unsupportedCodec
    case assetMissing
}
