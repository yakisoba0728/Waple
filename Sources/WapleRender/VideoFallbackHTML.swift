import Foundation

public enum VideoFallbackHTML {
    public static func html(forVideoFile name: String) -> String {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;width:100%;height:100%;background:#000;overflow:hidden}
        video{width:100%;height:100%;object-fit:cover}</style></head>
        <body><video src="waple-asset://wallpaper/\(encoded)" autoplay loop muted playsinline></video></body></html>
        """
    }
}
