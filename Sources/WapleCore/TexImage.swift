import Foundation

public struct TexImage {
    public enum PayloadKind: Equatable { case png, jpeg, embeddedImage, rawRGBA8888, bc3, bc2, bc1, r8, rg88, lz4RGBA, video, unknown }

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
    /// 모든 image 의 mip0(다중 image = 아틀라스 페이지, frame.imageId 가 페이지 인덱스). 단일 image 면 [mip].
    /// 비-mip 페이로드(.png/.video 등)는 []. `mip` 은 mips.first(호환) — 소비처는 imageCount 로 다중 판정.
    public var mips: [CompressedMip] = []
    public var imageCount: Int { max(mips.count, mip == nil ? 0 : 1) }
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

        func make(_ kind: PayloadKind, _ range: Range<Int>, _ mip: CompressedMip?, mips: [CompressedMip] = []) -> TexImage {
            var t = TexImage(width: imgW, height: imgH, format: format, payload: kind, payloadRange: range, mip: mip)
            t.flags = flags
            t.mips = mips
            t.frames = parseFrames(b)
            return t
        }

        // 1) mip 컨테이너를 먼저 파스(순수 함수). imageFormat(FreeImage) != -1 이면 mip payload = 그 타입
        //    인코딩 파일이며 texFormat 은 무시한다(RePKG TexMipmapFormatGetter 규약). 스캔보다 우선하는 이유:
        //    LZ4 압축 임베디드 이미지는 첫 literal 로 시그니처가 누출돼 아래 512B 스캔이 .png 로 오라우팅한 뒤
        //    압축 바이트를 PNG 로 디코드 실패하기 때문. 실측(2026-07-09): 코퍼스 임베디드 35개는 전부 비압축
        //    이고 v4 서브레이아웃이 둘 — splash_*(표준 mip → 여기서 .embeddedImage) 와 lut/*(mip 에 여분 int
        //    → parseMip 실패 → 아래 fast-path .png). 둘 다 정상 디코드(어느 쪽도 payloadRange 오정렬 없음).
        let container = parseMip(b, decodeW: texW, decodeH: texH, imgW: imgW, imgH: imgH)
        if let (mips, imageFormat) = container {
            let mip = mips[0]
            switch imageFormat {
            case -1 where flags & 0x20 != 0:                                     // TEXB0003 비디오: imageFormat 부재(-1)라 IsVideoTexture
                return make(.video, mip.payloadRange, mip)                       // 플래그 직독(실측 2958411739 등 14페이지: flags=0x22, payload=ftyp mp4).
            case -1: break                                                       // raw → format 기반 디코드(아래 3)
            case 35: return make(.video, mip.payloadRange, mip)                  // MP4(ponytail: LZ4-mp4 는 추출기 해제 미지원 — 보류)
            default: return make(.embeddedImage, mip.payloadRange, mip)          // 인코딩 파일(JPEG=2 PNG=13 GIF=25 …) — ImageIO 가 내용으로 판별
            }
        }

        // 2) 내장 이미지/비디오 시그니처 — 컨테이너 파스 **실패** 시에만(TEXB0001/0002 imageFormat 필드 부재,
        //    lut/* 등 파스 불가 v4 변형). 컨테이너가 파스됐고 imageFormat=-1 이면 payload 는 raw(format 기반)로
        //    확정인데, 종전엔 LZ4 압축 바이트에 우연히 낀 0xFFD8FF 를 이 스캔이 .jpeg 로 오라우팅해 압축
        //    바이트를 그대로 ImageIO 에 넘겼다(실측 2026-07-09: embedded-jpeg 버킷 0/8 전멸 — assets
        //    sharp_halo(fmt0)/hose_4_bright(fmt8)/circle_flame(fmt9) 및 pkg 4종, 전부 isLZ4=1 imageFormat=-1).
        if container == nil {
            if let p = findSig(b, [0x89, 0x50, 0x4E, 0x47], limit: 512) { return make(.png, p..<b.count, nil) }
            if let p = findSig(b, [0xFF, 0xD8, 0xFF], limit: 512) { return make(.jpeg, p..<b.count, nil) }
            if let p = findSig(b, Array("ftyp".utf8), limit: 512), p >= 4 { return make(.video, (p - 4)..<b.count, nil) }
        }

        // 3) mip 컨테이너 format-based 디코드: RGBA(fmt0) | DXT5(fmt4) | DXT1(fmt7) | R8(fmt9).
        // fmt4=DXT5, fmt7=DXT1 실측 근거(2026-07-03): 3D 모델 텍스처 decompressedSize 가 각각
        // paddedW×H×1B(BC3 8bpp)/×0.5B(BC1 4bpp) 전수 일치, 디코드 결과가 preview 색과 일치(젤다/태양계).
        // fmt9=R8 실측 근거(2026-07-04, 3598808038 opacity 마스크): LZ4 해제 후 raw 바이트가
        // 부드러운 비네트 그라디언트(edge 255/center 0, 정확히 w×h 바이트) — DXT5 블록 구조가 아님.
        // WE 포맷 enum: 8=RG88, 9=R8. 종전 코드가 9 를 4(DXT5)에 묶어 마스크가 전백(全白)→전화면 흑화면.
        if let (mips, _) = container {
            let mip = mips[0]
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
            // 다중 image(아틀라스 페이지)는 format-based(raw/DXT) 페이로드에만 의미 — mips 전체 보존.
            return make(kind, mip.payloadRange, mip, mips: mips)
        }
        // 4) 비압축 raw RGBA(드묾).
        if format == 0 { return make(.rawRGBA8888, 0..<b.count, nil) }
        return make(.unknown, 0..<b.count, nil)
    }

    /// "TEXB000N\0" 컨테이너 파스. 모든 image 의 **mip0** 을 순차 수집한다(다중 image = 스프라이트시트
    /// 아틀라스 페이지, frame.imageId 가 페이지 인덱스 — RePKG TexToImageConverter.ConvertToGif). 실측
    /// 레이아웃(RePKG TexReader + TEXB0004 hexdump 교차검증, 2026-07-03):
    ///   i32 imageCount | (v3+) i32 imageFormat(-1=raw) | (v4) i32 isVideoMp4/변형수 |
    ///   image별: (v4 조건 변형 체인 ×N) i32 mipCount | mip별: i32 w | i32 h | (v2+) i32 isLZ4 | i32 dec | i32 comp | payload
    /// (mip0 외 mip 은 크기만큼 스킵). 종전 "compressedSize 가 EOF 에 닿는 int 스캔" 휴리스틱은 다중 mip
    /// 파일(DJK_1.tex mip 9개 등)에서 실패해 3D 모델 텍스처 대부분이 흰색 폴백이었다.
    private static func parseMip(_ b: [UInt8], decodeW: Int, decodeH: Int, imgW: Int, imgH: Int) -> (mips: [CompressedMip], imageFormat: Int)? {
        guard let ti = indexOf(b, Array("TEXB".utf8)), ti + 9 <= b.count else { return nil }
        let version = Int(String(bytes: b[ti + 4..<ti + 8], encoding: .ascii) ?? "") ?? 0
        guard version >= 1, version <= 4 else { return nil }
        func i32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            return Int(Int32(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24))
        }
        /// 단일 mip 레코드 파스: w | h | (v2+) isLZ4 | dec | comp | payload → (mip, 다음 오프셋).
        func readMip(_ start: Int) -> (CompressedMip, Int)? {
            var q = start
            guard let w = i32(q), let h = i32(q + 4), w > 0, h > 0, w <= 16384, h <= 16384 else { return nil }
            q += 8
            var isLZ4 = 0, dec = 0
            if version >= 2 {
                guard let z = i32(q), let d = i32(q + 4) else { return nil }
                isLZ4 = z; dec = d; q += 8
            }
            guard let comp = i32(q), comp > 0, q + 4 + comp <= b.count else { return nil }
            q += 4
            if isLZ4 == 0 { dec = comp }  // 비압축: payload 그대로
            // dec 는 공격자 제어 필드. 단일 mip 의 정당한 한계(512MB)를 넘으면 거부해 ~4GB 할당 DoS 차단.
            guard dec > 0, dec <= 512 << 20 else { return nil }
            let mip = CompressedMip(decodeWidth: w, decodeHeight: h, imageWidth: imgW, imageHeight: imgH,
                                    decompressedSize: dec, payloadRange: q..<(q + comp), lz4: isLZ4 != 0)
            return (mip, q + comp)
        }
        var p = ti + 9
        var imageFormat = -1         // FreeImage enum(v3+): -1=raw(texFormat 사용), 2=JPEG 13=PNG 25=GIF 35=MP4
        guard let imageCount = i32(p), imageCount > 0, imageCount <= 1024 else { return nil }
        p += 4
        if version >= 3 { imageFormat = i32(p) ?? -1; p += 4 }   // imageFormat 직독(RePKG: !=-1 이면 인코딩 파일)
        if version >= 4 { p += 4 }   // 0004 추가 필드(실측 0/1 = isVideoMp4; 조건 변형 텍스처는 변형 수 1/3)
        var mips: [CompressedMip] = []
        for _ in 0..<imageCount {
            // v4 조건 변형 체인 스킵: [i32 1][i32 idx][i32 0][json NUL] × N 이 mipCount 앞에 온다.
            if version >= 4 { while let e = conditionVariantEnd(b, from: p, i32: i32) { p = e } }
            guard let mipCount = i32(p), mipCount > 0 else { break }
            p += 4
            guard let (mip0, after0) = readMip(p) else { break }   // 페이지의 mip0 = 아틀라스 페이지 픽셀
            mips.append(mip0)
            p = after0
            var ok = true
            for _ in 1..<mipCount {                                // mip0 외 mip 은 스킵(다음 image 위치까지 전진)
                guard let (_, afterK) = readMip(p) else { ok = false; break }
                p = afterK
            }
            if !ok { break }
        }
        return mips.isEmpty ? nil : (mips, imageFormat)
    }

    /// TEXB0004 조건 변형 블록 1개: [i32 1][i32 variantIdx][i32 0][condition JSON NUL]. 프로퍼티 값(예
    /// tuniccolor)으로 텍스처 변형을 고르는 파일 — 변형 블록 N개가 연속한 뒤 mip 테이블이 온다.
    /// 실측(2026-07-09, 전 코퍼스 460종 sweep): 조건 tex 는 zelda 8개뿐, 전부 이 레이아웃(v4 필드 = 변형 수
    /// 1/3). 종전 "[1][2][json][1]" 프레이밍은 단일 변형에서 mipCount(항상 1)를 블록 선두로 오독한 우연 —
    /// 다변형(childlink_01, 변형 3)에서 붕괴해 unknown-fmt4 로 전락했다.
    /// 반환 = 블록 끝(다음 블록 또는 mipCount 위치). 패턴 불일치 시 nil(mip 테이블 직행).
    /// ponytail: 디코드는 항상 첫 변형의 mip 세트 — 프로퍼티 연동 변형 선택은 미지원(2번째 이후 mip 세트 무시).
    private static func conditionVariantEnd(_ b: [UInt8], from p: Int, i32: (Int) -> Int?) -> Int? {
        let maxConditionBytes = 64 * 1024
        // idx 상한 64: 실제 mip 레코드(w|h|isLZ4|dec)와의 오인 차단 — w==1 && h≤64 && isLZ4==0 && dec 첫바이트
        // '{' 를 동시에 만족하는 정상 텍스처는 존재 불가(dec=w×h×bpp 조합이 홀수 0x7B 를 만들 수 없음).
        guard let m1 = i32(p), m1 == 1, let idx = i32(p + 4), (1...64).contains(idx),
              let z = i32(p + 8), z == 0 else { return nil }
        let jsonStart = p + 12
        guard jsonStart < b.count, b[jsonStart] == 0x7B || b[jsonStart] == 0x5B else { return nil } // "{" or "["
        let upper = min(b.count, jsonStart + maxConditionBytes)
        var jsonEnd = jsonStart
        while jsonEnd < upper, b[jsonEnd] != 0 {
            jsonEnd += 1
        }
        guard jsonEnd < upper else { return nil }
        return jsonEnd + 1
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
