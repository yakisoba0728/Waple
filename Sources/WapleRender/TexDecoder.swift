import Foundation
import CoreGraphics
import ImageIO
import Compression
import WapleCore

public enum TexDecoder {
    private static let maxEmbeddedImageDimension = 8192
    private static let maxEmbeddedImageBytes = 256 << 20

    /// keepFullAtlas: 단일-이미지 다중프레임 스프라이트시트는 imgW/imgH(단일 프레임 크기) 크롭을 건너뛰고
    /// 디코드 아틀라스(decodeW×decodeH) 전체를 보존한다 — TEXS 프레임 좌표(예 frame1 x=1920)가 imgW 를
    /// 넘어서므로 크롭하면 frame≥1 이 소실돼 spriteFrameTexture 가 경계 클램프 샘플(흑화)한다. 호출자
    /// (resolveTextureWithFrames)만 true — 일반/단일프레임 경로는 종전대로 크롭(무회귀).
    public static func rgba(from tex: TexImage, data: Data, keepFullAtlas: Bool = false) -> (pixels: Data, width: Int, height: Int)? {
        switch tex.payload {
        case .png, .jpeg:
            return decodeEncoded(data.subdata(in: tex.payloadRange), inBytes: tex.payloadRange.count, format: "png/jpeg")
        case .embeddedImage:
            // imageFormat 이 인코딩 이미지(PNG/JPEG/GIF)로 지정한 mip. LZ4 해제(mipBytes) 후 CGImageSource 디코드
            // — fast-path 512B 스캔이 놓치는 LZ4 압축 임베디드 이미지 경로. straight-alpha 규약은 draw 가 유지.
            //
            // ⚠️ **volume(tex.depth > 1) 은 여기서 2D 한 장으로 나온다.** 동봉 `materials/lut/*.tex` 28개가
            // 그렇다. 재실측(2026-08-21, 28건 전수 IHDR 직독 — 예외 0건):
            //   · 헤더      texW×texH = 32×32(슬라이스 한 장) · depth = 32 · imgW×imgH = **1024×32**
            //   · mip 레코드 w×h = 32×32 · mip depth = 32 · isLZ4 = 0(PNG 그대로 저장)
            //   · 실제 PNG  = **32×1024**, 8bit truecolor(colortype 2, 알파 없음)
            // 즉 축이 "바뀐" 게 아니라 **두 레이아웃이 공존한다**: 헤더 imgW/imgH 는 슬라이스를 **가로로**
            // 편 규약(imgW = texW × depth)이고, 저장된 PNG 는 **세로로** 쌓은 스트립(texW × (texH × depth))이다.
            // 그래서 3D LUT 샘플링을 붙일 때 잘라야 하는 축은 **세로**이고, 슬라이스 k 는
            // PNG 의 y ∈ [k·texH, (k+1)·texH) 다 — 헤더 치수로 가로를 자르면 전부 틀린다.
            // 반환 dims 는 PNG 실치수(32×1024)라 그 자체로는 정합하다. 그 소비처는 아직 없다.
            // (raw(imageFormat = -1) volume 텍스처는 동봉·설치본·워크샵 어느 코퍼스에도 표본이 0건이라
            //  비인코딩 volume 의 슬라이스 순서는 **미확인**이다. 위 규약은 PNG 인코딩 28건 한정 확정.)
            // (2026-08-21 이전에는 이 28개가 parseMip 실패로 `.png` 폴백을 탔다. 픽셀은 같았지만
            //  컨테이너를 못 읽어 depth 자체가 없었다 — TexImage.parse 의 hasMipDepth 참조.)
            guard let mip = tex.mip, let dec = mipBytes(mip: mip, data: data) else { return nil }
            return decodeEncoded(dec, inBytes: mip.payloadRange.count, format: "embedded")
        case .rawRGBA8888:
            let w = tex.width, h = tex.height
            guard w > 0, h > 0, w <= 16384, h <= 16384 else { return nil }
            let need = w * h * 4
            let sub = data.subdata(in: tex.payloadRange)
            guard sub.count >= need else { return nil }
            return (sub.prefix(need), w, h)
        case .bc3, .bc2, .bc1, .r8, .rg88, .lz4RGBA:
            guard let mip = tex.mip else { return nil }
            return decodeMip(payload: tex.payload, mip: mip, data: data, keepFullAtlas: keepFullAtlas)
        case .video, .unknown:
            return nil
        }
    }

    /// 조건 변형(TEXB0004) 선택 디코드: tex.variants 가 있으면 프로퍼티 값으로 mip 선택 후 디코드,
    /// 없으면(또는 미매치=기본 mip 선택 시) 기존 rgba(from:data:). 변형 mip 은 기본과 동일 포맷(파일
    /// format 기반 DXT/raw)이라 decodeMip 재사용. 젤다 튜닉색(tuniccolor) 등 프로퍼티 연동 텍스처용.
    public static func rgba(from tex: TexImage, data: Data, properties: [String: PropertyValue],
                            keepFullAtlas: Bool = false)
        -> (pixels: Data, width: Int, height: Int)? {
        guard !tex.variants.isEmpty,
              let mip = tex.selectedMip(properties: properties), mip != tex.mip else {
            return rgba(from: tex, data: data, keepFullAtlas: keepFullAtlas)
        }
        switch tex.payload {
        case .bc3, .bc2, .bc1, .r8, .rg88, .lz4RGBA:
            return decodeMip(payload: tex.payload, mip: mip, data: data, keepFullAtlas: keepFullAtlas)
        default:
            return rgba(from: tex, data: data, keepFullAtlas: keepFullAtlas)   // 변형이나 mip 기반 아님(미관측) — 안전 폴백
        }
    }

    /// 특정 아틀라스 페이지(image index) 디코드. 다중 image = GIF 스프라이트 페이지(각 자체 mip0,
    /// frame.imageId 가 페이지 인덱스 — RePKG ConvertToGif). index 0/단일 image/범위 밖은 mip0(=rgba) 로.
    /// mip 기반(raw/DXT) 포맷에만 의미(임베디드 이미지 페이지는 단일이라 rgba 사용).
    public static func rgba(from tex: TexImage, data: Data, imageIndex: Int) -> (pixels: Data, width: Int, height: Int)? {
        guard imageIndex > 0, imageIndex < tex.mips.count else { return rgba(from: tex, data: data) }
        return decodeMip(payload: tex.payload, mip: tex.mips[imageIndex], data: data)
    }

    public enum BCFormat { case bc1, bc2, bc3 }

    /// 네이티브 BC 업로드 후보. CPU 디코드 없이 LZ4 해제된 raw BC 블록을 `.bc1/2/3_rgba` 로 직접 올린다.
    /// blocks 는 decode dims 레이아웃(ceil(decodeW/4) 블록/행), bytesPerRow 는 그 소스 stride —
    /// 텍스처를 image dims 로 만들고 이 stride 를 주면 Metal 이 패딩 블록을 건너뛰어 크롭을 무비용 처리한다.
    public struct NativeBCUpload {
        /// mip 1레벨분 네이티브 업로드 단위(레벨별 alloc/orig 크롭 규약 적용 후).
        public struct NativeBCMipLevel {
            public let blocks: Data
            public let width: Int         // 이 레벨의 타깃 dims(레벨 0 의 크롭 규칙을 레벨마다 적용)
            public let height: Int
            public let bytesPerRow: Int   // 이 레벨의 소스 블록 stride = ceil(decodeW_L/4)*blockBytes
            public init(blocks: Data, width: Int, height: Int, bytesPerRow: Int) {
                self.blocks = blocks; self.width = width; self.height = height; self.bytesPerRow = bytesPerRow
            }
        }
        public let blocks: Data
        public let format: BCFormat
        public let width: Int         // 타깃 텍스처 폭(= rgba()+cropped() 반환 폭, 파리티)
        public let height: Int
        public let bytesPerRow: Int   // 소스 블록 stride = ceil(decodeW/4)*blockBytes
        /// 전체 mip 체인(levels[0] = 위 플랫 필드와 동일 내용). mipCount>1 텍스처면 2개 이상 —
        /// makeBCTexture 가 mipmapLevelCount 전체 할당 + 레벨별 업로드. 1개면 기존 단일 레벨(무회귀).
        /// TEXB 가 전체 체인을 저장(실물 DJK_1.tex 9레벨)하고 축소 필터링에 쓰인다는 추론 근거(엔진이
        /// 저장 mip 을 쓰는 실질적 이유는 업로드 외에 없음 — 정적 분석 "거의 확실", RE 대조 확정 아님).
        public let levels: [NativeBCMipLevel]

        public init(blocks: Data, format: BCFormat, width: Int, height: Int, bytesPerRow: Int) {
            self.blocks = blocks; self.format = format; self.width = width; self.height = height
            self.bytesPerRow = bytesPerRow
            self.levels = [NativeBCMipLevel(blocks: blocks, width: width, height: height, bytesPerRow: bytesPerRow)]
        }
        public init(blocks: Data, format: BCFormat, width: Int, height: Int, bytesPerRow: Int,
                    levels: [NativeBCMipLevel]) {
            self.blocks = blocks; self.format = format; self.width = width; self.height = height
            self.bytesPerRow = bytesPerRow; self.levels = levels
        }
    }

    /// BC(DXT) 텍스처를 Metal 네이티브 BC 로 올릴 후보 추출(LZ4 만 해제, RGBA 전개 안 함). 불가면 nil →
    /// 호출자는 기존 rgba() CPU 경로로 폴백. keepFullAtlas(스프라이트 아틀라스)면 image dims 크롭 금지 →
    /// full decode dims 상주(프레임 좌표가 decode dims 전체를 참조하므로 크롭 시 frame≥1 소실). 종전엔
    /// blit.copy(BC→rgba8 무효)로 CPU 강제였으나 spriteFrameTexture 가 f_spriteframe 샘플로 전환돼 허용.
    /// 반환 dims 는 rgba()+cropped()/keepFullAtlas 와 **정확히 일치**시켜 effW/UV/texRatio 무회귀. 크롭(imgW<decodeW)은
    /// image dims 텍스처 + decode-dims stride 로 Metal 이 패딩/부분 엣지 블록을 GPU 에서 처리(실측 검증).
    /// 멀티페이지 아틀라스는 CPU 세로 스택(stackedAtlas)이 필요해 대상 제외. 변형(properties)은 selectedMip.
    public static func nativeBC(from tex: TexImage, data: Data,
                                properties: [String: PropertyValue] = [:],
                                keepFullAtlas: Bool = false) -> NativeBCUpload? {
        let format: BCFormat
        switch tex.payload {
        case .bc1: format = .bc1
        case .bc2: format = .bc2
        case .bc3: format = .bc3
        default: return nil
        }
        guard tex.imageCount <= 1, let mip = tex.selectedMip(properties: properties),
              let blocks = mipBytes(mip: mip, data: data) else { return nil }
        let blockBytes = format == .bc1 ? 8 : 16
        let dw = mip.decodeWidth, dh = mip.decodeHeight
        guard dw > 0, dh > 0 else { return nil }
        // 해제 블록이 decode dims 전체를 담는지 확인(잘린/손상 데이터 방어) — 부족하면 rgba() 폴백.
        guard blocks.count >= ((dw + 3) / 4) * ((dh + 3) / 4) * blockBytes else { return nil }
        let bytesPerRow = ((dw + 3) / 4) * blockBytes
        // 타깃 dims = cropped()/keepFullAtlas 와 동일 규칙(무회귀). keepFullAtlas 는 크롭 금지(full decode dims).
        let iw = mip.imageWidth, ih = mip.imageHeight
        let w: Int, h: Int
        if keepFullAtlas { (w, h) = (dw, dh) }   // 스프라이트 아틀라스: 프레임 좌표가 decode dims 전체 참조 → 크롭 시 frame≥1 소실
        else if iw == dw && ih == dh { (w, h) = (dw, dh) }
        else if iw > 0, ih > 0, iw <= dw, ih <= dh { (w, h) = (iw, ih) }
        else { (w, h) = (dw, dh) }
        // 전체 mip 체인: 기본 image 선택(변형 미매치) + 비아틀라스 + mipChain 수집(단일 image, mipCount>1).
        // 어느 레벨이든 해제/검증 실패 시 체인 포기 → levels=[mip0](종전 단일 레벨과 동일 — 무회귀).
        var levels = [NativeBCUpload.NativeBCMipLevel(blocks: blocks, width: w, height: h, bytesPerRow: bytesPerRow)]
        if !keepFullAtlas, mip == tex.mip, tex.mipChain.count > 1 {
            var chain: [NativeBCUpload.NativeBCMipLevel] = []
            var chainOK = true
            for levelMip in tex.mipChain.dropFirst() {
                guard let lb = mipBytes(mip: levelMip, data: data) else { chainOK = false; break }
                let ldw = levelMip.decodeWidth, ldh = levelMip.decodeHeight
                guard ldw > 0, ldh > 0,
                      lb.count >= ((ldw + 3) / 4) * ((ldh + 3) / 4) * blockBytes else { chainOK = false; break }
                let lbpr = ((ldw + 3) / 4) * blockBytes
                // 레벨별 크롭 규약 = 레벨 0 규칙의 keepFullAtlas=false 분기(alloc/orig 둘 다 레벨마다 1/2 축소는 파스가 반영).
                let liw = levelMip.imageWidth, lih = levelMip.imageHeight
                let lw: Int, lh: Int
                if liw == ldw && lih == ldh { (lw, lh) = (ldw, ldh) }
                else if liw > 0, lih > 0, liw <= ldw, lih <= ldh { (lw, lh) = (liw, lih) }
                else { (lw, lh) = (ldw, ldh) }
                chain.append(NativeBCUpload.NativeBCMipLevel(blocks: lb, width: lw, height: lh, bytesPerRow: lbpr))
            }
            if chainOK { levels.append(contentsOf: chain) }
        }
        return NativeBCUpload(blocks: blocks, format: format, width: w, height: h, bytesPerRow: bytesPerRow,
                              levels: levels)
    }

    /// 기본 image 의 **전체 mip 체인** 레벨별 CPU 디코드(mipCount>1 텍스처 전용 — makeImageTexture
    /// CPU 경로용). 두 갈래다:
    ///   - mip 기반(raw/DXT): decodeMip 으로 레벨별 alloc/orig 크롭 규약 적용(레벨 L 의 orig =
    ///     imgW/imgH >> L — TexImage.mipChain 이 파스 시 반영).
    ///   - 임베디드(PNG/JPEG/GIF): 레벨마다 **독립 인코딩 파일**이라 decodeEncoded 로 각각 디코드한다.
    ///     크롭 규약이 없다 — 인코딩 이미지엔 BC 블록 패딩이 없어 디코드 치수가 곧 실치수다
    ///     (코퍼스 실측: level>0 2,432개 전부 치수가 정확히 (imgW>>L, imgH>>L), 불일치 0).
    /// nil = 기존 단일 레벨 경로 사용(무회귀): mipCount==1, PNG/JPEG **fast-path**(TEXB 부재 → 체인 없음),
    /// 다중 image(페이지 스택), 변형 선택(properties 매치 — 변형엔 체인 없음), keepFullAtlas(스프라이트
    /// 아틀라스), 어느 레벨이든 디코드 실패. levels[0] 는 rgba(from:data:) 반환과 동일(동일 코드 경로).
    public static func rgbaLevels(from tex: TexImage, data: Data,
                                  properties: [String: PropertyValue] = [:],
                                  keepFullAtlas: Bool = false)
        -> [(pixels: Data, width: Int, height: Int)]? {
        guard !keepFullAtlas, tex.imageCount <= 1, tex.mipChain.count > 1 else { return nil }
        let encoded: Bool
        switch tex.payload {
        case .bc3, .bc2, .bc1, .r8, .rg88, .lz4RGBA: encoded = false
        case .embeddedImage: encoded = true
        default: return nil
        }
        guard tex.selectedMip(properties: properties) == tex.mip else { return nil }   // 변형 선택 시 무회귀
        var out: [(pixels: Data, width: Int, height: Int)] = []
        out.reserveCapacity(tex.mipChain.count)
        for levelMip in tex.mipChain {
            if encoded {
                guard let raw = mipBytes(mip: levelMip, data: data),
                      let d = decodeEncoded(raw, inBytes: levelMip.payloadRange.count, format: "embedded")
                else { return nil }
                out.append((pixels: d.0, width: d.1, height: d.2))
            } else {
                guard let d = decodeMip(payload: tex.payload, mip: levelMip, data: data, keepFullAtlas: false)
                else { return nil }
                out.append(d)
            }
        }
        return out
    }

    /// mip 기반(raw/DXT) 포맷 1장 디코드 + 패딩 크롭. 단일/다중 페이지 공용(mip 인자로 페이지 선택).
    private static func decodeMip(payload: TexImage.PayloadKind, mip: TexImage.CompressedMip, data: Data,
                                  keepFullAtlas: Bool = false)
        -> (pixels: Data, width: Int, height: Int)? {
        guard WapleProfiler.enabled else { return _decodeMip(payload: payload, mip: mip, data: data, keepFullAtlas: keepFullAtlas) }
        let t0 = CFAbsoluteTimeGetCurrent()
        let out = _decodeMip(payload: payload, mip: mip, data: data, keepFullAtlas: keepFullAtlas)
        WapleProfiler.recordTex(format: "\(payload)", outBytes: out?.pixels.count ?? 0,
                                inBytes: mip.payloadRange.count, seconds: CFAbsoluteTimeGetCurrent() - t0)
        return out
    }

    private static func _decodeMip(payload: TexImage.PayloadKind, mip: TexImage.CompressedMip, data: Data,
                                   keepFullAtlas: Bool)
        -> (pixels: Data, width: Int, height: Int)? {
        guard let dec = mipBytes(mip: mip, data: data) else { return nil }
        let w = mip.decodeWidth, h = mip.decodeHeight
        // 스프라이트시트 아틀라스는 전체 보존(프레임 좌표가 imgW/imgH 를 넘음), 그 외는 패딩 크롭.
        func finish(_ rgba: Data) -> (Data, Int, Int) { keepFullAtlas ? (rgba, w, h) : cropped(rgba, mip) }
        switch payload {
        case .bc3:
            guard let rgba = DXT5Decoder.decode(dec, width: w, height: h) else { return nil }
            return finish(rgba)
        case .bc2:
            guard let rgba = DXT5Decoder.decodeBC2(dec, width: w, height: h) else { return nil }
            return finish(rgba)
        case .bc1:
            guard let rgba = DXT5Decoder.decodeBC1(dec, width: w, height: h) else { return nil }
            return finish(rgba)
        case .r8:
            // 단일 채널 8bit(WE fmt9). raw 바이트 = 픽셀당 값 → **(v,v,v,v)** 로 확장한다.
            //
            // 두 소비 경로가 채널을 다르게 읽기 때문에 이 형태여야 둘 다 맞는다:
            //   · **파티클**(도달 44/169씬) — `genericparticle.frag:79` 가
            //     `v_Color * ConvertTexture0Format(sample)` 이고, 그 변환이 R8 을
            //     `vec4(1,1,1,sample.r)` 로 편다(`common_fragment.h:103-106`).
            //     즉 텍스처는 **모양(알파)만** 주고 색은 파티클이 낸다 → `.a` 가 값이어야 한다.
            //   · **마스크·뎁스**(도달 122씬) — `opacity.frag:12`·`depthparallax.frag:39` 가
            //     `.r` 을 직접 읽는다 → `.r` 이 값이어야 한다.
            //
            // 종전 `(v,v,v,255)` 는 마스크 경로만 보고 정한 것이었다(주석에 그렇게 적혀 있었다).
            // 파티클에서는 알파가 항상 255 라 **마스킹이 통째로 사라져 불투명 사각형**이 됐다.
            // WE 번들 공유 파티클 텍스처 60개 중 56개가 r8 이다(fire/smoke/fog/lightning/rain/
            // debris/shape) — 실물 영향이 큰 자리다.
            //
            // rgb 를 흰색(255)이 아니라 v 로 두는 것은 마스크 경로의 `.r` 을 지키기 위해서다.
            // 파티클에서는 `t.rgb * color.rgb` 로 곱해져 WE(rgb=1) 대비 어두워질 수 있는데,
            // 알파가 v 인 곳은 rgb 도 v 라 프리멀티플라이드처럼 동작해 합성 결과는 근접한다.
            // **완전 동치는 셰이더가 텍스처 원본 포맷을 알고 분기해야 한다** — 별도 작업이다.
            guard w > 0, h > 0, dec.count >= w * h else { return nil }
            var rgba = Data(count: w * h * 4)
            dec.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                rgba.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                    let s = src.bindMemory(to: UInt8.self), d = dst.bindMemory(to: UInt8.self)
                    for i in 0..<(w * h) {
                        let v = s[i]
                        d[i * 4] = v; d[i * 4 + 1] = v; d[i * 4 + 2] = v; d[i * 4 + 3] = v
                    }
                }
            }
            return finish(rgba)
        case .rg88:
            // 2채널 8bit(WE fmt8): byte0→루마(r=g=b), byte1→알파. 판정(2026-07-09, RePKG 대조):
            // 실물 셰이더 common_fragment.h:98 ConvertTexture0Format(RG88)=`.rrrg` — GL_RG8 샘플은 .r=byte0/.g=byte1
            // 이므로 (byte0,byte0,byte0,byte1). HLSL_SM30 경로 `.rrra`(A8L8 에뮬)도 동일 결론 → 아래 코드가 정본.
            // ⚠️ RePKG RG88.cs:40 은 정반대(`Rgba32(G,G,G,R)` = byte1→루마, byte0→알파)지만, 실제 렌더 규약은
            // 셰이더이므로 Waple 이 옳다(RePKG 를 보고 뒤집지 말 것). rain_drops_sheet 등 파티클 시트가 이 포맷.
            // 마스크 소비(.r)도 r 그대로라 양쪽 정확. (REFRACT 는 파티클 ParticleShaders.pf_refract,
            // 이미지 레이어 gpuLayer.refract, 3D 메시 mf_refract(H4)로 각각 구현됨.)
            guard w > 0, h > 0, dec.count >= w * h * 2 else { return nil }
            var rgba = Data(count: w * h * 4)
            dec.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                rgba.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                    let s = src.bindMemory(to: UInt8.self), d = dst.bindMemory(to: UInt8.self)
                    for i in 0..<(w * h) {
                        let r = s[i * 2], g = s[i * 2 + 1]
                        d[i * 4] = r; d[i * 4 + 1] = r; d[i * 4 + 2] = r; d[i * 4 + 3] = g
                    }
                }
            }
            return finish(rgba)
        case .lz4RGBA:
            guard dec.count >= w * h * 4 else { return nil }
            return finish(dec)
        default:
            return nil
        }
    }

    /// mip 페이로드 바이트: lz4 플래그면 해제, 아니면 그대로(TEXB0001 등 비압축).
    private static func mipBytes(mip: TexImage.CompressedMip, data: Data) -> Data? {
        let payload = data.subdata(in: mip.payloadRange)
        return mip.lz4 ? lz4(payload, expected: mip.decompressedSize) : payload
    }

    /// LZ4 raw 해제. 성공 시 정확히 expected 바이트 반환.
    private static func lz4(_ comp: Data, expected: Int) -> Data? {
        guard expected > 0 else { return nil }
        var dst = [UInt8](repeating: 0, count: expected)
        let got = comp.withUnsafeBytes { srcp -> Int in
            dst.withUnsafeMutableBytes { dstp in
                compression_decode_buffer(dstp.bindMemory(to: UInt8.self).baseAddress!, expected,
                                          srcp.bindMemory(to: UInt8.self).baseAddress!, comp.count,
                                          nil, COMPRESSION_LZ4_RAW)
            }
        }
        return got == expected ? Data(dst) : nil
    }

    /// 패딩 텍스처(decode dims)에서 실제 이미지(top-left image dims)만 크롭.
    private static func cropped(_ rgba: Data, _ mip: TexImage.CompressedMip) -> (Data, Int, Int) {
        let dw = mip.decodeWidth, dh = mip.decodeHeight, iw = mip.imageWidth, ih = mip.imageHeight
        if iw == dw && ih == dh { return (rgba, dw, dh) }
        guard iw > 0, ih > 0, iw <= dw, ih <= dh, rgba.count >= dw * dh * 4 else { return (rgba, dw, dh) }
        var out = Data(count: iw * ih * 4)
        rgba.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                for y in 0..<ih {
                    memcpy(dst.baseAddress!.advanced(by: y * iw * 4),
                           src.baseAddress!.advanced(by: y * dw * 4), iw * 4)
                }
            }
        }
        return (out, iw, ih)
    }

    /// 인코딩 이미지(PNG/JPEG/GIF) 바이트 → straight-alpha RGBA. png/jpeg·embedded 케이스 공용.
    /// 계측 시 texDecode 페이즈 누적(CGImageSource 디코드 + straight 역변환 포함).
    private static func decodeEncoded(_ imageData: Data, inBytes: Int, format: String) -> (Data, Int, Int)? {
        guard WapleProfiler.enabled else { return decodeEncodedImpl(imageData) }
        let t0 = CFAbsoluteTimeGetCurrent()
        let out = decodeEncodedImpl(imageData)
        WapleProfiler.recordTex(format: format, outBytes: out?.0.count ?? 0, inBytes: inBytes, seconds: CFAbsoluteTimeGetCurrent() - t0)
        return out
    }

    private static func decodeEncodedImpl(_ imageData: Data) -> (Data, Int, Int)? {
        guard embeddedImagePropertiesAreWithinLimits(imageData),
              let src = CGImageSourceCreateWithData(imageData as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return draw(img)
    }

    /// PNG/JPEG → straight-alpha RGBA. 디코더 출력 규약은 전 포맷 STRAIGHT 로 통일한다
    /// (raw/BC3/LZ4 는 WE 저장 그대로 straight — PNG 경로만 CG 가 premultiplied 를 강제하므로 역변환).
    /// 파이프라인 규약(설계 §3): 텍스처/이펙트 패스 straight, premultiply 는 최종 컴포지트에서 1회.
    private static func draw(_ img: CGImage) -> (Data, Int, Int)? {
        let w = img.width, h = img.height
        guard imageDimensionsAreWithinLimits(width: w, height: h) else { return nil }
        var pixels = Data(count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  // CGContext 는 non-premultiplied 드로잉을 지원하지 않아 premultipliedLast 로 그린 뒤 역변환한다.
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            let px = base.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 0, to: w * h * 4, by: 4) {
                let a = Int(px[i + 3])
                if a == 0 || a == 255 { continue }
                px[i]     = UInt8(min(255, Int(px[i])     * 255 / a))
                px[i + 1] = UInt8(min(255, Int(px[i + 1]) * 255 / a))
                px[i + 2] = UInt8(min(255, Int(px[i + 2]) * 255 / a))
            }
            return true
        }
        return ok ? (pixels, w, h) : nil
    }

    private static func embeddedImagePropertiesAreWithinLimits(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return false }
        return imageDimensionsAreWithinLimits(width: w, height: h)
    }

    private static func imageDimensionsAreWithinLimits(width w: Int, height h: Int) -> Bool {
        guard w > 0, h > 0, w <= maxEmbeddedImageDimension, h <= maxEmbeddedImageDimension else { return false }
        return w <= maxEmbeddedImageBytes / max(1, h * 4)
    }
}
