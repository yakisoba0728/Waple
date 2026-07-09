import Foundation

public struct TexImage {
    public enum PayloadKind: Equatable { case png, jpeg, rawRGBA8888, bc3, bc2, bc1, r8, rg88, lz4RGBA, video, unknown }

    /// mip0 페이로드(TEXB0001~0004). `decode*` = padded texture dims(디코드 단위),
    /// `image*` = 실제 이미지 dims(크롭 대상). lz4 == false 면 payload 는 비압축(그대로 사용).
    public struct CompressedMip: Equatable {
        public let decodeWidth: Int
        public let decodeHeight: Int
        public let imageWidth: Int
        public let imageHeight: Int
        public let decompressedSize: Int
        public let payloadRange: Range<Int>
        public let lz4: Bool

        public init(decodeWidth: Int, decodeHeight: Int, imageWidth: Int, imageHeight: Int,
                    decompressedSize: Int, payloadRange: Range<Int>, lz4: Bool = true) {
            self.decodeWidth = decodeWidth; self.decodeHeight = decodeHeight
            self.imageWidth = imageWidth; self.imageHeight = imageHeight
            self.decompressedSize = decompressedSize; self.payloadRange = payloadRange; self.lz4 = lz4
        }
    }

    /// 스프라이트시트 프레임(TEXS 섹션). 좌표는 이미지 픽셀 공간(imgW×imgH — 디코더가 패딩 크롭 후와 일치).
    /// 필드 순서(RePKG TexFrameInfoContainerReader 확정): i32 imageId | f32 frametime |
    /// f32 x | f32 y | f32 width | f32 widthY | f32 heightX | f32 height (v1 은 지오메트리 i32).
    /// 회전 프레임(아틀라스 패킹이 스프라이트를 돌려 넣음): Width 또는 Height 가 0 이고 유효 크기는
    /// HeightX/WidthY 에서 온다 — atlas* 프로퍼티가 실제 서브렉트(top-left+extent)와 회전을 도출한다.
    public struct TexFrame: Equatable {
        public let imageId: Int
        public let time: Float
        public let x: Float, y: Float, width: Float, height: Float
        public let widthY: Float, heightX: Float
        public init(imageId: Int, time: Float, x: Float, y: Float, width: Float, height: Float,
                    widthY: Float = 0, heightX: Float = 0) {
            self.imageId = imageId; self.time = time
            self.x = x; self.y = y; self.width = width; self.height = height
            self.widthY = widthY; self.heightX = heightX
        }

        /// RePKG TexToImageConverter: 부호 있는 유효 폭/높이(width==0 이면 heightX, height==0 이면 widthY).
        /// 회전각·서브렉트 원점 도출에 부호가 필요하다. 비회전 프레임은 signedW=width, signedH=height.
        private var signedW: Float { width != 0 ? width : heightX }
        private var signedH: Float { height != 0 ? height : widthY }
        /// 아틀라스 서브렉트 top-left(부호 있는 extent 로 min 보정) + 절대 extent.
        public var atlasX: Float { Swift.min(x, x + signedW) }
        public var atlasY: Float { Swift.min(y, y + signedH) }
        public var atlasWidth: Float { abs(signedW) }
        public var atlasHeight: Float { abs(signedH) }
        /// 서브렉트를 똑바로 세우기 위한 시계방향 90° 회전 수(0/1/2/3). RePKG 각도식
        /// -(atan2(sign h, sign w) - π/4) 을 90° 단위로: (+,+)→0 (+,-)→1 (-,-)→2 (-,+)→3.
        /// 비회전(+,+)은 항상 0 → 기존 UV 경로와 byte-identical(코퍼스 무회귀). 방향(CW)은 스펙 도출값
        /// — 코퍼스에 회전 프레임 실물이 없어 육안 검증 불가(ponytail: 반례 발견 시 부호 반전).
        public var rotationQuarters: Int {
            let sw = signedW >= 0, sh = signedH >= 0
            if sw && sh { return 0 }
            if sw && !sh { return 1 }
            if !sw && !sh { return 2 }
            return 3
        }
    }

    public let width: Int   // 이미지 width (imgW)
    public let height: Int
    public let format: Int
    /// TexHeader flags@22(RePKG TexFlags 확정): bit0 NoInterpolation, bit1 ClampUVs, bit2 IsGif, bit5 IsVideoTexture.
    public var flags: Int = 0
    public let payload: PayloadKind
    public let payloadRange: Range<Int>
    public let mip: CompressedMip?
    /// 스프라이트시트 프레임 목록(TEXS 부재 시 []).
    public var frames: [TexFrame] = []

    public var noInterpolation: Bool { flags & 0x1 != 0 }
    public var clampUVs: Bool { flags & 0x2 != 0 }
    public var isGif: Bool { flags & 0x4 != 0 }
    public var isVideoTexture: Bool { flags & 0x20 != 0 }

    public static func parse(_ data: Data) -> TexImage? {
        let b = [UInt8](data)
        guard b.count > 42, b[0..<8].elementsEqual(Array("TEXV0005".utf8)) else { return nil }
        func i32(_ o: Int) -> Int {
            Int(UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
        }
        let format = i32(18)
        let flags = i32(22)          // TexFlags(bit0 NoInterp, bit1 ClampUV, bit2 Gif, bit5 Video) — 노출만, 동작 무변경
        let texW = i32(26), texH = i32(30)
        let imgW = i32(34), imgH = i32(38)
        // 차원은 무경계 UInt32 에서 옴. Metal 렌더 한계(16384) 를 넘으면 거부해 w*h*4 정수 오버플로 트랩(크래시) 차단.
        let maxDim = 16384
        guard texW >= 0, texH >= 0, imgW >= 0, imgH >= 0,
              texW <= maxDim, texH <= maxDim, imgW <= maxDim, imgH <= maxDim else { return nil }

        func make(_ kind: PayloadKind, _ range: Range<Int>, _ mip: CompressedMip?) -> TexImage {
            var t = TexImage(width: imgW, height: imgH, format: format, payload: kind, payloadRange: range, mip: mip)
            t.flags = flags
            t.frames = parseFrames(b)
            return t
        }

        // 1) 내장 이미지/비디오 시그니처 우선(작은 윈도우에서만 — LZ4 데이터의 우연 일치 방지).
        if let p = findSig(b, [0x89, 0x50, 0x4E, 0x47], limit: 512) { return make(.png, p..<b.count, nil) }
        if let p = findSig(b, [0xFF, 0xD8, 0xFF], limit: 512) { return make(.jpeg, p..<b.count, nil) }
        if let p = findSig(b, Array("ftyp".utf8), limit: 512), p >= 4 { return make(.video, (p - 4)..<b.count, nil) }

        // 2) mip 컨테이너(TEXB0001~0004): RGBA(fmt0) | DXT5(fmt4) | DXT1(fmt7) | R8(fmt9).
        // fmt4=DXT5, fmt7=DXT1 실측 근거(2026-07-03): 3D 모델 텍스처 decompressedSize 가 각각
        // paddedW×H×1B(BC3 8bpp)/×0.5B(BC1 4bpp) 전수 일치, 디코드 결과가 preview 색과 일치(젤다/태양계).
        // fmt9=R8 실측 근거(2026-07-04, 3598808038 opacity 마스크): LZ4 해제 후 raw 바이트가
        // 부드러운 비네트 그라디언트(edge 255/center 0, 정확히 w×h 바이트) — DXT5 블록 구조가 아님.
        // WE 포맷 enum: 8=RG88, 9=R8. 종전 코드가 9 를 4(DXT5)에 묶어 마스크가 전백(全白)→전화면 흑화면.
        if let mip = parseMip(b, decodeW: texW, decodeH: texH, imgW: imgW, imgH: imgH) {
            let kind: PayloadKind
            switch format {
            case 0: kind = .lz4RGBA
            case 4: kind = .bc3
            case 6: kind = .bc2   // DXT3(BC2): 명시 4bit 알파 + 4-색 컬러. 실측(2026-07-06): 태양계 fmt6 16개
            case 7: kind = .bc1
            case 8: kind = .rg88   // 2B/px (r=루마, g=알파 — 실물 common_fragment.h ConvertTexture0Format .rrrg)
            case 9: kind = .r8
            default: kind = .unknown
            }
            return make(kind, mip.payloadRange, mip)
        }
        // 3) 비압축 raw RGBA(드묾).
        if format == 0 { return make(.rawRGBA8888, 0..<b.count, nil) }
        return make(.unknown, 0..<b.count, nil)
    }

    /// "TEXB000N\0" 컨테이너 파스(mip0 만 사용). 실측 레이아웃(RePKG TexReader + TEXB0004 hexdump
    /// 교차검증, 2026-07-03 — 다중 mip 파일(DJK_1.tex mip 9개 등)은 종전 "compressedSize 가 EOF 에
    /// 닿는 int 스캔" 휴리스틱이 실패해 3D 모델 텍스처 대부분이 흰색 폴백이 되던 것을 고침):
    ///   i32 imageCount | (v3+) i32 imageFormat(실측 -1) | (v4) i32 미상/플래그(실측 0/1) |
    ///   i32 mipCount | (v4 조건부) i32 1 | i32 2 | condition JSON NUL | i32 1 |
    ///   mip별: i32 w | i32 h | (v2+) i32 isLZ4 | i32 decompressedSize | i32 comp | payload
    private static func parseMip(_ b: [UInt8], decodeW: Int, decodeH: Int, imgW: Int, imgH: Int) -> CompressedMip? {
        guard let ti = indexOf(b, Array("TEXB".utf8)), ti + 9 <= b.count else { return nil }
        let version = Int(String(bytes: b[ti + 4..<ti + 8], encoding: .ascii) ?? "") ?? 0
        guard version >= 1, version <= 4 else { return nil }
        func i32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            return Int(Int32(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24))
        }
        var p = ti + 9
        p += 4                       // imageCount(첫 이미지의 mip0 만 사용)
        if version >= 3 { p += 4 }   // imageFormat(FreeImage, 실측 -1)
        if version >= 4 { p += 4 }   // 0004 추가 필드/플래그(실측 0/1)
        guard let mipCount = i32(p), mipCount > 0 else { return nil }
        p += 4
        if version >= 4, let conditionEnd = texb0004ConditionBlockEnd(b, from: p, i32: i32) {
            p = conditionEnd
        }
        guard let w = i32(p), let h = i32(p + 4), w > 0, h > 0, w <= 16384, h <= 16384 else { return nil }
        p += 8
        var isLZ4 = 0, dec = 0
        if version >= 2 {
            guard let z = i32(p), let d = i32(p + 4) else { return nil }
            isLZ4 = z; dec = d
            p += 8
        }
        guard let comp = i32(p), comp > 0, p + 4 + comp <= b.count else { return nil }
        p += 4
        if isLZ4 == 0 { dec = comp }  // 비압축: payload 그대로
        // dec 는 공격자 제어 필드. 단일 mip 의 정당한 한계(512MB)를 넘으면 거부해 ~4GB 할당 DoS 차단.
        guard dec > 0, dec <= 512 << 20 else { return nil }
        return CompressedMip(decodeWidth: w, decodeHeight: h,
                             imageWidth: imgW, imageHeight: imgH,
                             decompressedSize: dec, payloadRange: p..<(p + comp), lz4: isLZ4 != 0)
    }

    /// TEXB0004 may insert a small NUL-terminated condition JSON block before the first mip record.
    /// Keep the scan bounded so malformed files cannot make parsing walk an arbitrary payload.
    private static func texb0004ConditionBlockEnd(_ b: [UInt8], from p: Int, i32: (Int) -> Int?) -> Int? {
        let maxConditionBytes = 64 * 1024
        guard let marker1 = i32(p), let marker2 = i32(p + 4), marker1 == 1, marker2 == 2 else { return nil }
        let jsonStart = p + 8
        guard jsonStart < b.count, b[jsonStart] == 0x7B || b[jsonStart] == 0x5B else { return nil } // "{" or "["
        let upper = min(b.count, jsonStart + maxConditionBytes)
        var jsonEnd = jsonStart
        while jsonEnd < upper, b[jsonEnd] != 0 {
            jsonEnd += 1
        }
        guard jsonEnd < upper, let marker3 = i32(jsonEnd + 1), marker3 == 1 else { return nil }
        return jsonEnd + 5
    }

    /// TEXS 스프라이트시트 섹션 파스(파일 꼬리에서 역방향 탐색 — LZ4 페이로드 내 우연 일치 회피).
    /// 이상 감지 시 [] (프레임 없음 = 전체 텍스처 1프레임과 동등).
    private static func parseFrames(_ b: [UInt8]) -> [TexFrame] {
        let sig = Array("TEXS000".utf8)
        guard b.count > sig.count + 6 else { return [] }
        var ti = -1
        var i = b.count - sig.count - 2
        while i >= 0 {  // 마지막 출현 탐색
            if Array(b[i..<i + sig.count]) == sig { ti = i; break }
            i -= 1
        }
        guard ti >= 0 else { return [] }
        let version = Int(b[ti + 7]) - 0x30
        guard version >= 1, version <= 3 else { return [] }
        func i32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            return Int(Int32(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24))
        }
        func f32(_ o: Int) -> Float? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            return Float(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
        }
        var p = ti + 9
        guard let count = i32(p), count > 0, count <= 4096 else { return [] }
        p += 4
        if version >= 3 { p += 8 }   // gifWidth, gifHeight
        guard p + count * 32 <= b.count else { return [] }
        // TEXS0001(v1) 은 x/y/w/h 지오메트리가 f32 가 아니라 i32 정수형이다(RePKG
        // TexFrameInfoContainerReader 실측 — id 는 i32, frametime 은 v1/v2/v3 모두 f32).
        // v2/v3 은 f32 유지. 레코드 크기(32B)·필드 순서는 전 버전 동일 → 지오메트리 읽기만 분기.
        let geom: (Int) -> Float? = version == 1 ? { i32($0).map { Float($0) } } : { f32($0) }
        var out: [TexFrame] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard let id = i32(p), let t = f32(p + 4),
                  let x = geom(p + 8), let y = geom(p + 12),
                  let w = geom(p + 16), let wy = geom(p + 20), let hx = geom(p + 24), let h = geom(p + 28),
                  t.isFinite, t > 0,
                  x >= 0, y >= 0, x.isFinite, y.isFinite,
                  w.isFinite, h.isFinite, wy.isFinite, hx.isFinite else { return [] }
            // 회전 프레임(RePKG): Width|Height 가 0 → 유효 크기는 HeightX/WidthY 에서. 양 축 모두 0(퇴화)이면
            // 프레임 전체 드롭(종전 w>0,h>0 안전망 유지) — 단 회전 시트는 더는 통째로 버리지 않는다.
            let effW = w != 0 ? w : hx
            let effH = h != 0 ? h : wy
            guard abs(effW) > 0, abs(effH) > 0 else { return [] }
            out.append(TexFrame(imageId: id, time: t, x: x, y: y, width: w, height: h, widthY: wy, heightX: hx))
            p += 32
        }
        return out
    }

    private static func findSig(_ b: [UInt8], _ sig: [UInt8], limit: Int) -> Int? {
        let upper = min(b.count - sig.count, limit)
        guard upper >= 0 else { return nil }
        var i = 0
        while i <= upper {
            if Array(b[i..<i + sig.count]) == sig { return i }
            i += 1
        }
        return nil
    }

    private static func indexOf(_ b: [UInt8], _ sig: [UInt8]) -> Int? {
        guard b.count >= sig.count else { return nil }
        var i = 0
        while i <= b.count - sig.count { if Array(b[i..<i + sig.count]) == sig { return i }; i += 1 }
        return nil
    }
}
