import AppKit
import simd

/// 앨범아트 주색 추출(썸네일 이벤트 primaryColor/secondaryColor/... 공급원).
/// 코어는 순수 함수: RGBA 픽셀 → 4bit/채널 양자화 히스토그램 → 최빈 버킷의 평균색.
///
/// WE 실물과의 차이 — **알고리즘이 다르다(의도적 이탈, 미해소)**
/// ----------------------------------------------------------
/// WE 쪽에서 이 다섯 색을 실어 보내는 자리는 `wallpaper64.exe` `0x14011be40`–`0x14011c90c`
/// 이고, 값은 이미 계산된 uint32 다 — `[obj+0x150]` primaryColor(`0x14011c50d`),
/// `+0x154` secondaryColor(`0x14011c576`), `+0x158` tertiaryColor(`0x14011c5c9`),
/// `+0x15c` textColor(`0x14011c61c`), `+0x160` highContrastColor(`0x14011c66f`).
/// **그 다섯을 계산하는 자리는 특정하지 못했다 — [미해결].**
///
/// 다만 WE 가 "대표색"을 뽑는 알고리즘 자체는 하나 확보했다. `bin/resourceutil64.dll` 의
/// `GetDominantColor`/`GetDominantColorFromImage`(둘 다 `0x18000a6d0` 으로 폴딩, imagebase
/// `0x180000000`) 이고, 본체는 `sub_180009e30` 이다. 편집기가 `getDominantColorFromFile` →
/// `project.schemecolor` 로 쓰는 바로 그 함수다(`ui/dist/scripts/scripts.js`). 실측 산식:
///
///  1. RGBA8 전 픽셀을 HSV 로 바꾼다(`0x180009f85`–`0x18000a035`). 픽셀 dword 는 byte0=R.
///  2. **hue 를 1° 단위 360빈**으로 나눈다(`cvttss2si` 후 359 상한, 음수는 0).
///     `delta < 1e-5` 이거나 `max <= 0` 인 무채색 픽셀은 **빈 0 에 sat=0 으로 들어간다**.
///  3. 빈마다 넷을 누적한다 — `weight += (int)(sat*val*100)`(`0x18000a093`),
///     `count += 1`, `satSum += sat`, `valSum += val`.
///  4. `weight` 최대 빈 하나를 고르고, `H = bin/360`, `S = satSum/count`, `V = valSum/count`
///     로 **HSV→RGB 역변환**해 `0xFF000000 | B<<16 | G<<8 | R` 로 싼다(`0x18000a508`–`0x18000a6a2`).
///
/// **[CJ 2026-08-21] 위 4단계를 명령 단위로 재확인하며 셋을 좁혔다**(정본
/// `spec/engine/dominant-color.json` `dominantColor.algorithm`, 생성기
/// `scripts/spec/measure_dominant_color.py` 가 바이트를 전수 대조한다):
///
///  · **채도 하한 상수는 없다.** 하한 노릇을 하는 것은 `0x18000a08c` 의 `cvttss2si` **절단**
///    이고, 그래서 `S·V < 0.01` 인 픽셀은 가중치 기여가 정확히 0 이다. 다만 그 픽셀도
///    `count`/`satSum`/`valSum` 에는 들어가므로 **뽑힌 빈의 평균색은 여전히 끌어내린다**.
///  · 무채색 갈래(`0x18000a048` `xor ecx,ecx` · `0x18000a04a` `xorps xmm2,xmm2`)는 빈 번호와
///    `S` 만 0 으로 만든다 — **`V`(= fmax)는 그대로 `valSum` 에 누적된다**.
///  · 최대 빈 비교가 러닝 최대를 int32 로 좁힌다(`0x18000a105` `mov edx, r9d`). 픽셀수 × 100 이
///    2³¹ 을 넘으면 비교가 뒤집힐 수 있다 — 결함의 **존재**는 확정이고 발현은 미관측이다.
///
/// 우리 구현과 다른 축(전부 확정):
///  · **양자화 축**: WE = hue 360빈(채도·명도는 빈 안에서 평균) / 우리 = RGB 4bit×3 = 4096빈.
///  · **가중치**: WE = `sat·val` 가중 빈도(칙칙하고 어두운 색을 스스로 눌러 준다) /
///    우리 = 순수 빈도(가장 넓은 면적이 이긴다 — 어두운 배경이 primary 가 되기 쉽다).
///  · **알파**: WE 는 알파를 아예 안 본다 / 우리는 `a < 128` 픽셀을 버린다.
///  · **개수**: WE 는 **한 색만** 낸다 — secondary/tertiary/text/highContrast 대응물이 없다.
///  · **알파 미적용 픽셀 수**: WE 는 전 픽셀 / 우리는 64×64 이하로 리샘플 후.
/// 곧 두 결과는 일반적으로 **일치하지 않는다**. 이 갭을 닫으려면 위 [미해결](다섯 색을 만드는
/// 자리)을 먼저 찾아야 한다 — `GetDominantColor` 를 그대로 이식해도 색이 하나뿐이라 못 채운다.
/// 전문·재현 절차: `docs/re/scheme-color.md` §9.
///
/// **[CJ 2026-08-21] 그 [미해결] 을 절반 닫았다 — `wallpaper64.exe` 에는 계산 자리가 없다.**
/// `.pdata` 전 함수를 선형 디스어셈해서 다섯 변위(`+0x150`…`+0x160`)로 가는 **스택 아닌**
/// dword 스토어를 전수로 셌다(95건 / 48함수). 다섯 중 넷 이상을 쓰는 함수는 다섯 개뿐이고
/// 넷은 전건 `movss`(= float 다섯 개, uint32 색이 아니다), 나머지 하나
/// (`0x1400d834f`)는 런타임 베이스를 더한 4×4 행렬 복사다. 미디어 구조체 자신을 만지는 자리는
/// 생성자의 0 초기화(`0x1400c1402`·`0x1400c1409`·`0x1400c1413`)와 복사 생성자
/// (`0x1400c2422`–`0x1400c2454`)뿐이다.
/// 교차 근거: `wallpaper64.exe` 에 WinRT 미디어 세션 문자열이 **0건**이고
/// (`Windows.Media.Control` · `GlobalSystemMediaTransportControlsSessionManager`, ASCII·UTF-16
/// 양쪽), 그 문자열은 `bin/winrtutil64.exe` 에만 있다. 곧 다섯 색은 **별도 프로세스에서
/// 만들어져 IPC 로 건너온다** — 남은 [미해결] 은 "winrtutil64.exe 의 어느 함수인가" 다.
/// (그 안에서 `cv::kmeans` 는 링크만 되고 호출되지 않는다 — 팔레트 추출에 OpenCV kmeans 를
/// 쓰지는 않는다. 그 이상은 안 떴다.)
public enum ArtworkColors {
    public struct Palette: Equatable {
        public var primary: SIMD3<Float>
        public var secondary: SIMD3<Float>
        public var tertiary: SIMD3<Float>
        /// primary 위에 얹을 텍스트 색(흑/백 — primary 휘도 기준).
        public var textColor: SIMD3<Float>
        public var highContrast: SIMD3<Float>
    }

    /// RGBA8 픽셀 배열에서 팔레트 추출(순수). 알파 < 128 픽셀은 무시. 유효 픽셀 없음 → nil.
    /// primary = 최빈 양자화 버킷의 평균색, secondary/tertiary = primary(들)와 RGB 거리 0.2 이상인
    /// 차순위 버킷(없으면 앞 색으로 폴백). text/highContrast = primary 휘도(0.6 문턱)로 흑/백.
    public static func palette(rgba: [UInt8], width: Int, height: Int) -> Palette? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        // 4bit/채널 버킷(4096) → (count, sumR, sumG, sumB)
        var count = [Int](repeating: 0, count: 4096)
        var sum = [SIMD3<Double>](repeating: .zero, count: 4096)
        var total = 0
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            guard rgba[i + 3] >= 128 else { continue }
            let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            count[key] += 1
            sum[key] += SIMD3(Double(r), Double(g), Double(b))
            total += 1
        }
        guard total > 0 else { return nil }
        // 버킷 평균색을 빈도순으로 정렬(동률은 버킷 인덱스 — 결정적).
        // F-AE1: 종전엔 filter→sorted→map 을 한 식으로 이었는데, ubuntu 러너의 새 툴체인이
        // "unable to type-check this expression in reasonable time"(ArtworkColors.swift:35:22,
        // spec job 96772696708 · 2026-08-21T12:39:18Z)로 예산 초과를 냈다. 로컬 6.0.3 과 Xcode 는
        // 통과하지만 경계에 걸쳐 있어, **동작을 바꾸지 않고** 단계마다 타입을 명시해 쪼갠다.
        // 동률 처리(`a < b`)는 골든 스냅샷의 결정성 보장이라 그대로 둔다.
        let occupied: [Int] = (0..<4096).filter { count[$0] > 0 }
        let order: [Int] = occupied.sorted { (a: Int, b: Int) -> Bool in
            if count[a] != count[b] { return count[a] > count[b] }
            return a < b
        }
        let ranked: [SIMD3<Float>] = order.map { (k: Int) -> SIMD3<Float> in
            let mean: SIMD3<Double> = sum[k] / Double(count[k]) / 255.0
            return SIMD3<Float>(mean)
        }
        let primary: SIMD3<Float> = ranked[0]
        func nextDistinct(from picked: [SIMD3<Float>]) -> SIMD3<Float>? {
            ranked.first { (c: SIMD3<Float>) -> Bool in
                picked.allSatisfy { (p: SIMD3<Float>) -> Bool in simd_distance(p, c) > 0.2 }
            }
        }
        let secondary = nextDistinct(from: [primary]) ?? primary
        let tertiary = nextDistinct(from: [primary, secondary]) ?? secondary
        let luma = 0.299 * primary.x + 0.587 * primary.y + 0.114 * primary.z
        let contrast: SIMD3<Float> = luma > 0.6 ? SIMD3(0, 0, 0) : SIMD3(1, 1, 1)
        return Palette(primary: primary, secondary: secondary, tertiary: tertiary,
                       textColor: contrast, highContrast: contrast)
    }

    /// 인코딩 이미지(JPEG/PNG 바이트) → 64×64 이하로 다운샘플 디코드 후 팔레트. 디코드 실패 → nil.
    public static func palette(imageData: Data) -> Palette? {
        guard let img = NSImage(data: imageData),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = min(cg.width, 64), h = min(cg.height, 64)
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        // F840: `&px` 를 CGContext(data:) 에 넘기면 inout 로 만든 임시 포인터가 호출 밖으로 새어나간다(UB —
        // 그 포인터의 유효 수명은 CGContext 생성 호출 뿐이다). 형제 경로(TexDecoder.draw·
        // TextRasterizer.render)와 동일하게 컨텍스트 생성·드로잉을 withUnsafeMutableBytes 안에서 끝낸다.
        let ok = px.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return palette(rgba: px, width: w, height: h)
    }

    /// 0..1 Vec3 → "#RRGGBB"(클램프). 웹 썸네일 이벤트 색 포맷 — 실물 3639973107 이 #hex 를 파싱한다.
    public static func hexString(_ c: SIMD3<Float>) -> String {
        func b(_ v: Float) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(c.x), b(c.y), b(c.z))
    }
}
