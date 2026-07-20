import Foundation

public enum VideoFallbackHTML {
    /// F576: volume 은 배경별 VideoSettings 값(정상 경로 VideoRenderer 와 동일 의미론).
    /// 0(기본)이면 muted 고정으로 autoplay 를 보장하고, 양수면 muted 없이 해당 음량으로 재생한다.
    public static func html(forVideoFile name: String, volume: Float = 0) -> String {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let clamped = max(0, min(1, volume))
        let mutedAttr = clamped > 0 ? "" : " muted"
        // <video> 에 volume 속성은 없으므로 스크립트로 프로퍼티 설정.
        let volumeScript = clamped > 0
            ? "<script>document.querySelector('video').volume=\(String(format: "%.3f", clamped));</script>"
            : ""
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;width:100%;height:100%;background:#000;overflow:hidden}
        video{width:100%;height:100%;object-fit:cover}</style></head>
        <body><video src="waple-asset://wallpaper/\(encoded)" autoplay loop\(mutedAttr) playsinline></video>\(volumeScript)</body></html>
        """
    }
}
