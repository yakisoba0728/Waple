// Waple 앱 아이콘 1024px 마스터 PNG 를 코드로 그린다(외부 에셋/폰트 무의존).
//   swift make-icon.swift <out.png>
// 디자인: 항상다크 톤의 라운드 사각(수직 그라디언트) + 겹치는 물결(wave/ripple) 글리프.
// 작은 크기에서도 읽히도록 요소 최소 — make-icon.sh 가 sips 로 iconset 리샘플 후 .icns 로 묶는다.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Waple-1024.png"
let S: CGFloat = 1024

let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                          bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fputs("컨텍스트 생성 실패\n", stderr); exit(1)
}

// macOS 아이콘 관례: 캔버스 안쪽으로 약간 여백을 둔 라운드 사각.
let inset = S * 0.055
let rect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let corner = rect.width * 0.2237   // Big Sur 라운드 비율
let plate = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

// 다크 수직 그라디언트 배경.
ctx.saveGState()
ctx.addPath(plate); ctx.clip()
let bg = CGGradient(colorsSpace: space,
                    colors: [CGColor(red: 0.11, green: 0.13, blue: 0.19, alpha: 1),
                             CGColor(red: 0.03, green: 0.04, blue: 0.07, alpha: 1)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
ctx.restoreGState()

// 물결 3겹(라운드 사각 내부로 클립). CoreGraphics 는 y 상향 좌표.
ctx.saveGState()
ctx.addPath(plate); ctx.clip()
func wave(y: CGFloat, amp: CGFloat, phase: CGFloat, width: CGFloat, color: CGColor) {
    let p = CGMutablePath()
    let steps = 256
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let x = rect.minX + t * rect.width
        let yy = y + sin(t * .pi * 3 + phase) * amp
        if i == 0 { p.move(to: CGPoint(x: x, y: yy)) } else { p.addLine(to: CGPoint(x: x, y: yy)) }
    }
    ctx.addPath(p)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.strokePath()
}
wave(y: rect.midY + S * 0.115, amp: S * 0.040, phase: .pi,     width: S * 0.034, color: CGColor(red: 0.62, green: 0.90, blue: 1.00, alpha: 0.50))
wave(y: rect.midY - S * 0.115, amp: S * 0.045, phase: .pi / 2, width: S * 0.040, color: CGColor(red: 0.45, green: 0.85, blue: 0.96, alpha: 0.70))
wave(y: rect.midY,             amp: S * 0.050, phase: 0,       width: S * 0.056, color: CGColor(red: 0.34, green: 0.72, blue: 0.98, alpha: 1.00))
ctx.restoreGState()

guard let image = ctx.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    fputs("PNG 인코딩 실패\n", stderr); exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: out))
    print("Wrote \(out)")
} catch {
    fputs("쓰기 실패: \(error)\n", stderr); exit(1)
}
