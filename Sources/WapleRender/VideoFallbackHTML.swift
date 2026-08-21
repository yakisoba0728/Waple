import Foundation

public enum VideoFallbackHTML {
    /// F576: volume 은 배경별 VideoSettings 값(정상 경로 VideoRenderer 와 동일 의미론).
    /// 0(기본)이면 muted 고정으로 autoplay 를 보장하고, 양수면 muted 없이 해당 음량으로 재생한다.
    public static func html(forVideoFile name: String, volume: Float = 0,
                            fitMode: FitMode = .fill) -> String {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let clamped = max(0, min(1, volume))
        let mutedAttr = clamped > 0 ? "" : " muted"
        // <video> 에 volume 속성은 없으므로 스크립트로 프로퍼티 설정.
        let volumeScript = clamped > 0
            ? "<script>document.querySelector('video').volume=\(String(format: "%.3f", clamped));</script>"
            : ""
        // 감사 V06: 정상 경로(VideoRenderer.videoGravity)와 같은 fitMode 를 object-fit 에 매핑.
        let objectFit: String
        switch fitMode {
        case .fit: objectFit = "contain"      // .resizeAspect
        case .fill: objectFit = "cover"       // .resizeAspectFill
        case .stretch: objectFit = "fill"     // .resize
        }
        // WE 의 동영상 래퍼(webwallpaper64.exe 주입 원문 @파일오프셋 0x1198f0)에 있는 두 훅을
        // 같이 심는다. 원문은 이렇게 끝난다:
        //   v.onerror = function() {var oldSrc = v.src.toString();v.src = '';v.src = oldSrc;};
        //   v.onended = function() {v.play();window.wallpaperOnVideoEnded();};
        //
        //  · onerror 재설정 — 디코드/스트림 오류로 <video> 가 죽으면 벽지가 **검은 화면으로
        //    영구 고정**된다. src 를 비웠다 되돌리면 미디어 로더가 처음부터 다시 붙는다.
        //    스킴 핸들러가 Range 로 조각을 주는 구조라(206) 이 부류가 실제로 난다.
        //  · onended — Waple 은 원문과 달리 `loop` 속성을 쓰므로 정상 재생에서는 발화하지
        //    않는다. 그래도 심는 이유는 WE 가 여기서 `window.wallpaperOnVideoEnded()` 를
        //    부르는 것이 규약이기 때문이다(브리지가 같은 이름의 전역을 보장한다). loop 가
        //    어떤 코덱에서 동작하지 않으면 이쪽이 재생을 이어 준다.
        let watchdog = """
        <script>(function(){var v=document.getElementsByTagName('video')[0];if(!v){return;}\
        v.onerror=function(){var s=v.src.toString();v.src='';v.src=s;};\
        v.onended=function(){try{v.play();}catch(e){}\
        if(typeof window.wallpaperOnVideoEnded==='function'){window.wallpaperOnVideoEnded();}};})();</script>
        """
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;width:100%;height:100%;background:#000;overflow:hidden}
        video{width:100%;height:100%;object-fit:\(objectFit)}</style></head>
        <body><video src="waple-asset://wallpaper/\(encoded)" autoplay loop\(mutedAttr) playsinline></video>\(volumeScript)\(watchdog)</body></html>
        """
    }
}
