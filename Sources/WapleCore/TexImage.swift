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
        /// TexImage.payloadRange 와 동일 규약 — 인덱스 공간은 `TexImage.parse(_:)` 에 넘긴 Data 다
        /// (`data.subdata(in: mip.payloadRange)` 가 슬라이스에서도 성립).
        public let payloadRange: Range<Int>
        public let lz4: Bool
        /// 이 레벨의 슬라이스 수(volume). **헤더 flags & 0x40 일 때만** 파일에 필드가 있고 없으면 1 —
        /// TEXB 리더 0x14015d374 `test byte ptr [rax + 4], 0x40` 게이트, 읽기 0x14015d399,
        /// 미존재 기본값 1 은 0x14015d2f4(`mov ebx, 1`). 엔진 상한은 0x80(0x14015d3b4).
        public let depth: Int

        public init(decodeWidth: Int, decodeHeight: Int, imageWidth: Int, imageHeight: Int,
                    decompressedSize: Int, payloadRange: Range<Int>, lz4: Bool = true, depth: Int = 1) {
            self.decodeWidth = decodeWidth; self.decodeHeight = decodeHeight
            self.imageWidth = imageWidth; self.imageHeight = imageHeight
            self.decompressedSize = decompressedSize; self.payloadRange = payloadRange; self.lz4 = lz4
            self.depth = depth
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

    /// TEXB0004 조건 변형: 프로퍼티 값에 따라 다른 mip 페이로드를 고르는 텍스처(실측 젤다 튜닉색).
    /// 조건 JSON 실물 문법(전 코퍼스 8종 확정, 2026-07-09):
    ///   {"condition":{"condition":"<value>","name":"<propertyKey>"}}
    /// 예: {"condition":{"condition":"2","name":"tuniccolor"}} = tuniccolor 값이 "2"일 때 이 변형.
    /// PropertyConditionEvaluator(JS식 표현) 와 문법이 달라(구조화 JSON) 전용 최소 평가기 — 단일 값 동등비교.
    public struct VariantCondition: Equatable {
        public let name: String    // 프로퍼티 키(예 tuniccolor)
        public let value: String   // 이 변형이 선택될 프로퍼티 값(예 "2")

        public init(name: String, value: String) { self.name = name; self.value = value }

        /// mip 앞 체인의 인라인 JSON 파스. 값이 문자열/숫자가 아니거나(표현식·범위 등 미관측) 구조가
        /// 다르면 nil → 해당 변형은 절대 매치 안 됨(안전 폴백: 기본 image 사용).
        public init?(json: String) {
            guard let data = json.data(using: .utf8),
                  let root = AssetJSON.dictionary(data),
                  let inner = root["condition"] as? [String: Any],
                  let name = inner["name"] as? String else { return nil }
            self.name = name
            if let s = inner["condition"] as? String { self.value = s }
            else if let n = inner["condition"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
                self.value = n.stringValue
            } else { return nil }
        }

        /// 프로퍼티 값과 대조(문자열/숫자 동등). 콤보 값은 문자열("0".."3")이라 문자열 비교가 정본.
        public func matches(_ values: [String: PropertyValue]) -> Bool {
            guard let pv = values[name] else { return false }
            switch pv {
            case .string(let s): return s == value
            case .number(let n): return Double(value) == n
            case .bool(let b): return (value == "true" || value == "1") == b
            case .none: return false
            }
        }
    }

    /// 조건 변형 1개 = (조건, mip). mip 은 기본 image 와 동일 포맷(파일 format 기반 DXT/raw).
    public struct Variant: Equatable {
        public let condition: VariantCondition
        public let mip: CompressedMip
        public init(condition: VariantCondition, mip: CompressedMip) { self.condition = condition; self.mip = mip }
    }

    public let width: Int   // 이미지 width (imgW)
    public let height: Int
    public let format: Int
    /// TEXI 헤더 flags@22. **TEXI 리더 0x14015c760 은 `|=` 로 합친다**(0x14015c7b1) — 파일 값이
    /// 엔진이 미리 세운 비트를 지우지 못한다는 뜻이라, 리더는 파일에 없는 비트를 봐도 놀라면 안 된다.
    /// 비트별(디컴파일 + 차분 컴파일 확정, spec/formats/tex-deep.json `format.tex.flags.bits`):
    ///   0x1  NoInterpolation — 소비됨(SceneRendererResources.resolveTextureNoInterpolation)
    ///   0x2  ClampUVs        — 소비됨(resolveTextureClampUVs)
    ///   0x4  IsGif(스프라이트시트) — TEXS 섹션이 붙는다. 동봉 52건 = TEXS 파스 52건으로 정확히 일치
    ///   0x8  **파일 입력이 아니다.** 로더 0x14015e90a–0x14015e933 이 mip 체인 길이 < 2 일 때 스스로
    ///        세운다(`or dword ptr [rsi + 4], 8`). 동봉 311건 중 파일에 켜진 것 0건 — 리더는 무시할 것
    ///   0x20 IsVideoTexture(mp4 페이로드)
    ///   0x40 Slice3D(volume) — 헤더에 i32 texDepth, **mip 레코드에도 i32 depth** 가 추가된다(depth 참조)
    ///   0x80000 AlphaChannelPriority — **컴파일러 전용**. wallpaper64 의 플래그 디스패치
    ///        0x14030358e–0x1403035d5 는 0x1/0x2/0x4/0x8/0x20/0x40 여섯 비트만 내부 상태로 옮기고,
    ///        0x80000·0x100000..0x800000 을 읽는 자리는 바이너리에 없다(주입은 하지만 소비는 안 한다)
    public var flags: Int = 0
    /// TEXI 헤더 i32 texDepth — **flags & 0x40 일 때만** 파일에 있고(리더 게이트 0x14015c855,
    /// 저장 0x14015c885) 없으면 1. 동봉 `materials/lut/*.tex` 28개가 32×32×32 3D LUT 로 이 필드를 쓴다
    /// (texW/texH = 슬라이스 한 장, imgW = texW × depth). 소비처가 3D 샘플링을 하려면 이 값이 필요하다.
    public var depth: Int = 1
    /// TEXI 헤더 마지막 u32 — **TEXI 버전 > 0 일 때만** 있다(리더 게이트 0x14015c891, 저장 0x14015c8c1).
    /// 바이트 순 R,G,B,A. 렌더 소비처는 확인되지 않았다(에디터/UI 힌트로 보인다) — 노출만 한다.
    /// 헤더 실제 길이가 42 가 아니라 46/50 이라는 근거가 이 필드다(참조 파서로 동봉 311건 전부
    /// 파스 끝 == EOF 확인). raw 폴백 오프셋을 왜 그래도 42 로 두는지는 parse(_:) 4) 주석 참조.
    public var previewColor: UInt32 = 0
    public let payload: PayloadKind
    /// 페이로드 바이트 범위 — **인덱스 공간은 `parse(_:)` 에 넘긴 `Data` 그 자체**다.
    /// 즉 `data.subdata(in: tex.payloadRange)` 가 어떤 Data(슬라이스 포함)에서도 성립한다.
    /// 종전에는 parse 가 `[UInt8](data)` 로 복사한 0-베이스 배열 인덱스를 그대로 실어 보냈고,
    /// 소비처(TexDecoder / VideoTextureExtractor)는 원본 Data 에 subdata 를 걸었다 — 지금까지
    /// 안 터진 이유는 `ScenePackage.data(for:)` 가 우연히 startIndex 0 인 새 Data 를 돌려주기
    /// 때문뿐이고, 슬라이스가 한 번이라도 들어오면 곧바로 트랩이었다. ScenePackage.parse(:38)의
    /// `let base = data.startIndex` 규약을 그대로 따라 **파스 시점에 절대 인덱스로 만든다**
    /// (0-베이스 Data 에서는 값이 종전과 동일 — 무회귀).
    public let payloadRange: Range<Int>
    public let mip: CompressedMip?
    /// 모든 image 의 mip0(다중 image = 아틀라스 페이지, frame.imageId 가 페이지 인덱스). 단일 image 면 [mip].
    /// 비-mip 페이로드(.png/.video 등)는 []. `mip` 은 mips.first(호환) — 소비처는 imageCount 로 다중 판정.
    public var mips: [CompressedMip] = []
    /// 기본 image(image 0)의 **전체 mip 체인** — 체인[0] == mip0(mips.first 와 동일). mipCount>1 텍스처만
    /// 2개 이상; PNG/JPEG **fast-path**(TEXB 컨테이너 자체가 없어 레벨 레코드가 없음)·다중 image(페이지
    /// 스택 경로, 레이아웃이 달라 체인 미적용)·조건 변형(변형 섹션은 관측상 mip 1개/변형)은 [](기존 경로 무회귀).
    ///
    /// [정정 2026-08-01] 종전 주석은 "임베디드(단일 인코딩 이미지라 저장 mip 자체가 없음)" 라며
    /// .embeddedImage 도 체인 없음으로 단정했다. **거짓이었다.** 코퍼스 전수 실측:
    ///   imageFormat 인코딩(PNG 766 · JPEG 30) 796개 중 **701개가 mipCount>1**(체인 길이 2~10),
    ///   level>0 페이로드 2,432개 전부 PNG IHDR/JPEG SOF 시그니처 정상 + 치수가 정확히
    ///   (imgW>>L, imgH>>L) — 불일치 0 · LZ4 해제 실패 0 · mip0 치수 불일치 0.
    /// 즉 WE 는 인코딩 이미지에도 축소본을 레벨별 **독립 PNG/JPEG 파일**로 넣어 둔다.
    /// 버리고 있던 탓에 워크샵 씬 146종이 축소 시 mip 없이 샘플돼 지글거렸다.
    /// 근거 스크립트: scripts/spec/measure_embedded_mips.py (spec/formats/tex-embedded-mips.json)
    /// 레벨 L 의 imageWidth/Height = 헤더 imgW/imgH 를 1/2^L floor 축소(최소 1) — TexDecoder 의 레벨별
    /// alloc/orig 크롭 규약과 정합. 수집 근거(추론): TEXB 가 전체 체인을 저장(실물 DJK_1.tex 9레벨)하고
    /// WE 렌더러는 축소 시 mip 필터링을 쓰므로, 엔진이 저장 mip 을 파일에 쓰는 실질적 이유는 GPU 업로드
    /// 외에 없음 — 정적 분석상 "거의 확실" 추론이며 RE 대조 확정은 아님(2026-07-28).
    public var mipChain: [CompressedMip] = []
    public var imageCount: Int { max(mips.count, mip == nil ? 0 : 1) }
    /// 스프라이트시트 프레임 목록(TEXS 부재 시 []).
    public var frames: [TexFrame] = []
    /// TEXB0004 조건 변형 목록(비-조건 텍스처는 []). 소비처는 variants.isEmpty 로 분기 —
    /// 빈 목록이면 기존 mip 경로 그대로(하위호환). 선택은 selectedMip(properties:).
    public var variants: [Variant] = []

    public var noInterpolation: Bool { flags & 0x1 != 0 }
    public var clampUVs: Bool { flags & 0x2 != 0 }
    public var isGif: Bool { flags & 0x4 != 0 }
    public var isVideoTexture: Bool { flags & 0x20 != 0 }
    /// 3D 슬라이스 텍스처(flags 0x40). 참이면 `depth` 가 슬라이스 수이고 imgW == texW × depth 다.
    public var isVolume: Bool { flags & 0x40 != 0 }
    /// AlphaChannelPriority(flags 0x80000). **런타임 비소비 플래그**(위 flags 주석의 디스패치 참조) —
    /// 인코딩 시 어느 채널을 우선 보존할지의 컴파일러 힌트다. 노출만 하고 렌더는 보지 않는다.
    public var alphaChannelPriority: Bool { flags & 0x80000 != 0 }
    /// 스프라이트시트 논리 프레임 크기(TEXS0003 의 gifWidth/gifHeight). v2 이하는 파일에 없어
    /// 헤더 imgW/imgH 가 기본값이다 — TEXS 리더 0x14015e226(v≥3 읽기) / 0x14015e268(v<3 기본).
    public var gifWidth: Int = 0
    public var gifHeight: Int = 0
    /// TEXS 섹션 버전(0 = 섹션 없음). v1 은 지오메트리가 i32, v2 이하는 frametime 이 항상 0 이다.
    public var framesVersion: Int = 0

    /// 프로퍼티 값으로 변형 선택: 첫 매치 변형의 mip, 미매치 시 기본(mip). variants 없으면 항상 기본.
    /// 순수 — 렌더 배선이 이 결과로 디코드(TexDecoder.rgba(from:data:properties:)).
    public func selectedMip(properties: [String: PropertyValue]) -> CompressedMip? {
        for v in variants where v.condition.matches(properties) { return v.mip }
        return mip
    }

    /// 씬 시간(초) → 스프라이트시트 프레임 인덱스. 프레임별 **가변** frametime 을 누적해 총 재생길이로
    /// 모듈로 랩(무한 루프)한다. 시간 정본은 TexFrame.time(TEXS0003 per-frame frametime) — 코퍼스
    /// 실측(2026-07-10, SPRITESHEET 37씬 전수): material/model/scene image 체인에 fps/framerate/
    /// frametime/loop/autoplay 필드 0건, 재생속도(0.03~1.0s)는 오직 .tex TEXS 에만 존재. loop·autoplay
    /// 는 암묵(WE 는 스프라이트 이미지를 자동재생·무한루프). 프레임 ≤1 이면 항상 0(정지 = 무프레임과 동등).
    /// 파티클 gif 경로(frames[0].time 상수 가정)와 달리 프레임별 time 을 존중 — 가변 시트 정확.
    public static func spriteFrameIndex(frames: [TexFrame], time: Float) -> Int {
        let n = frames.count
        guard n > 1 else { return 0 }
        // TEXS0002 이하는 frametime 을 **안 쓴다** — 동봉 실측(2026-08-21, `.tex` 311 전건):
        // TEXS0003 44개는 프레임마다 `duration/frames`(짝 `.tex-json` 과 정확히 일치)이고,
        // TEXS0002 8개(debris1·fire1~3·lightning1~2·snow·smoke3)는 **전 프레임 0** 이다.
        // 종전 `max(1e-4, f.time)` 클램프는 그 8개의 총 재생길이를 n×0.1ms 로 만들어
        // 초당 수백 바퀴를 돌렸다(육안으로는 잡음). 파일에 속도가 없으면 파일 밖에서 가져와야 한다.
        let stored = storedFrameTimeTotal(frames)
        let useFallback = stored <= 1e-4
        var total: Float = 0
        for f in frames { total += frameDuration(f, fallback: useFallback) }
        guard total > 1e-4, time.isFinite else { return 0 }
        var t = time.truncatingRemainder(dividingBy: total)
        if t < 0 { t += total }            // 음수 시간 방어(일시정지 되감기 등)
        var acc: Float = 0
        for i in 0..<n {
            acc += frameDuration(frames[i], fallback: useFallback)
            if t < acc { return i }
        }
        return n - 1                        // 부동소수 경계 폴백
    }

    /// 파일이 speed 를 안 실었을 때(TEXS0002) 쓰는 프레임당 재생시간. 파티클 경로가 이미 쓰는
    /// 값과 같게 맞춘다(SceneRendererFrameEncoder.particleSheetFrameIndex / SceneRenderer3D 의
    /// `max(0.016, ft)`) — 한 자산이 이미지 레이어냐 파티클이냐에 따라 속도가 달라지지 않게 하는 것이
    /// 이 상수의 유일한 근거다. **WE 가 이 자리에 쓰는 값은 RE 로 확정하지 못했다**(TEXS 리더
    /// 0x14015e514 가 총 재생길이를 누적만 하고, 그걸 읽는 소비처를 바이너리에서 특정하지 못함).
    public static let fallbackFrameTime: Float = 0.016

    /// 파일에 실린 frametime 의 총합(비유한/음수는 0 취급) — 0 이면 파일에 속도가 없다는 뜻.
    private static func storedFrameTimeTotal(_ frames: [TexFrame]) -> Float {
        var sum: Float = 0
        for f in frames where f.time.isFinite && f.time > 0 { sum += f.time }
        return sum
    }

    /// 프레임 1장의 재생시간. fallback 이면 파일 값을 무시하고 기본값(전 프레임 균일)을 쓴다.
    /// fallback 이 아니면 종전과 **글자 그대로 같은 식**이라 TEXS0003 시트는 무회귀다.
    private static func frameDuration(_ f: TexFrame, fallback: Bool) -> Float {
        fallback ? fallbackFrameTime : max(1e-4, f.time)
    }

    public static func parse(_ data: Data) -> TexImage? {
        // 헤더 판독은 0-베이스 복사본 b 로 하되, **밖으로 나가는 범위는 전부 base 를 더해**
        // 원본 Data 의 인덱스 공간으로 돌려준다(payloadRange 필드 주석 참조).
        let base = data.startIndex
        let b = [UInt8](data)
        guard b.count > 42, b[0..<8].elementsEqual(Array("TEXV0005".utf8)) else { return nil }
        func i32(_ o: Int) -> Int? { readU32LE(b, at: o).map { Int($0) } }
        // 헤더 6필드 경계검사(종전 b.count>42 암묵 의존 제거). 고정 오프셋이라 정상 파일은 항상 성립.
        guard let format = i32(18), let flags = i32(22),   // flags: TexFlags 노출만(동작 무변경)
              let texW = i32(26), let texH = i32(30),
              let imgW = i32(34), let imgH = i32(38) else { return nil }
        // 차원은 무경계 UInt32 에서 옴. Metal 렌더 한계(16384) 를 넘으면 거부해 w*h*4 정수 오버플로 트랩(크래시) 차단.
        // (참고: 엔진 자신의 상한은 더 좁다 — TEXB 리더 0x14015d3a2 가 w/h > 0x2000 이면 에러 경로다.)
        let maxDim = 16384
        guard texW >= 0, texH >= 0, imgW >= 0, imgH >= 0,
              texW <= maxDim, texH <= maxDim, imgW <= maxDim, imgH <= maxDim else { return nil }

        // TEXI 헤더 꼬리 두 필드 — **둘 다 조건부**라서 헤더 길이가 42/46/50 으로 달라진다.
        // 리더 0x14015c760 원문 순서: fmt(0x14015c789) flags(0x14015c7b1) texW(0x14015c7da)
        // texH(0x14015c803) imgW(0x14015c82c) imgH(0x14015c85a)
        //   → flags & 0x40 이면 i32 depth(게이트 0x14015c855, 저장 0x14015c885)
        //   → TEXI 버전 > 0 이면 u32 previewColor(게이트 0x14015c891, 저장 0x14015c8c1).
        // 종전 코드는 42 를 고정으로 봤고(= previewColor 를 페이로드로 셈) raw 폴백에서 4바이트 어긋났다.
        var depth = 1
        if flags & 0x40 != 0 {
            guard let d = i32(42), d > 0, d <= 128 else { return nil }   // 엔진 상한 0x80 = 0x14015d3b4
            depth = d
        }
        // TEXI 섹션 이름 "TEXI000N" + NUL 이 오프셋 9..18 — 뒤 4자리가 버전이다(로더 0x14015e745 가 atoi).
        // 리더는 `버전 >= 1` 만 가르므로(0x14015c891 `cmp r11d, 1`) 숫자로 풀 것 없이 0 초과만 본다.
        let texiVersionPositive = b[13..<17].contains { (0x31...0x39).contains($0) }
        let hasMipDepth = flags & 0x40 != 0
        let previewColor: UInt32 = texiVersionPositive ? (readU32LE(b, at: hasMipDepth ? 46 : 42) ?? 0) : 0

        func make(_ kind: PayloadKind, _ range: Range<Int>, _ mip: CompressedMip?,
                  mips: [CompressedMip] = [], variants: [Variant] = [],
                  mipChain: [CompressedMip] = []) -> TexImage {
            var t = TexImage(width: imgW, height: imgH, format: format, payload: kind, payloadRange: range, mip: mip)
            t.flags = flags
            t.depth = depth
            t.previewColor = previewColor
            t.mips = mips
            t.variants = variants
            t.mipChain = mipChain
            let s = parseFrames(b)
            t.frames = s.frames
            t.framesVersion = s.version
            // v3 은 파일에서(0x14015e226), v2 이하는 헤더 imgW/imgH 가 엔진 기본값(0x14015e268).
            t.gifWidth = s.version >= 3 ? s.gifWidth : imgW
            t.gifHeight = s.version >= 3 ? s.gifHeight : imgH
            return t
        }

        // 1) mip 컨테이너를 먼저 파스(순수 함수). imageFormat(FreeImage) != -1 이면 mip payload = 그 타입
        //    인코딩 파일이며 texFormat 은 무시한다(RePKG TexMipmapFormatGetter 규약). 스캔보다 우선하는 이유:
        //    LZ4 압축 임베디드 이미지는 첫 literal 로 시그니처가 누출돼 아래 512B 스캔이 .png 로 오라우팅한 뒤
        //    압축 바이트를 PNG 로 디코드 실패하기 때문. 실측(2026-07-09): **설치 assets 안의** 임베디드
        //    35개는 전부 비압축이다.
        //    [정정 2026-08-01] 종전엔 이 35 를 "코퍼스" 라고 적었다. assets 한정 수치이고 워크샵
        //    scene.pkg 를 합친 전수는 796개다(그중 701개가 mipCount>1). 아래 mipChain 전달 참조.
        //    [정정 2026-08-21] 종전엔 그 35개 중 lut/* 28개를 "mip 에 여분 int 가 있어 parseMip 실패 →
        //    아래 fast-path .png" 로 적어 두고 그대로 뒀다. **여분 int 의 정체는 slice3d 의 mip 레코드
        //    depth 였다**(hasMipDepth). 이제 28개도 여기로 와서 컨테이너를 정상 파스한다 —
        //    payloadRange 는 폴백 때와 동일해 디코드 픽셀은 무회귀이고, depth/imageCount/체인이 살아난다.
        let container = parseMip(b, imgW: imgW, imgH: imgH, format: format, base: base, hasMipDepth: hasMipDepth)
        if let (mips, imageFormat, _, chain) = container {
            let mip = mips[0]
            switch imageFormat {
            case -1 where flags & 0x20 != 0:                                     // TEXB0003 비디오: imageFormat 부재(-1)라 IsVideoTexture
                return make(.video, mip.payloadRange, mip)                       // 플래그 직독(실측 2958411739 등 14페이지: flags=0x22, payload=ftyp mp4).
            case -1: break                                                       // raw → format 기반 디코드(아래 3)
            case 35: return make(.video, mip.payloadRange, mip)                  // MP4(ponytail: LZ4-mp4 는 추출기 해제 미지원 — 보류)
            // 인코딩 파일(JPEG=2 PNG=13 GIF=25 …) — ImageIO 가 내용으로 판별. 레벨별로 독립 인코딩
            // 파일이 들어 있으므로 체인도 함께 넘긴다(디코드는 TexDecoder.rgbaLevels 의 encoded 분기).
            default: return make(.embeddedImage, mip.payloadRange, mip, mipChain: chain)
            }
        }

        // 2) 내장 이미지/비디오 시그니처 — 컨테이너 파스 **실패** 시에만(TEXB0001/0002 imageFormat 필드 부재,
        //    lut/* 등 파스 불가 v4 변형). 컨테이너가 파스됐고 imageFormat=-1 이면 payload 는 raw(format 기반)로
        //    확정인데, 종전엔 LZ4 압축 바이트에 우연히 낀 0xFFD8FF 를 이 스캔이 .jpeg 로 오라우팅해 압축
        //    바이트를 그대로 ImageIO 에 넘겼다(실측 2026-07-09: embedded-jpeg 버킷 0/8 전멸 — assets
        //    sharp_halo(fmt0)/hose_4_bright(fmt8)/circle_flame(fmt9) 및 pkg 4종, 전부 isLZ4=1 imageFormat=-1).
        if container == nil {
            if let p = findSig(b, [0x89, 0x50, 0x4E, 0x47], limit: 512) { return make(.png, (base + p)..<(base + b.count), nil) }
            if let p = findSig(b, [0xFF, 0xD8, 0xFF], limit: 512) { return make(.jpeg, (base + p)..<(base + b.count), nil) }
            if let p = findSig(b, Array("ftyp".utf8), limit: 512), p >= 4 { return make(.video, (base + p - 4)..<(base + b.count), nil) }
        }

        // 3) mip 컨테이너 format-based 디코드: RGBA(fmt0) | DXT5(fmt4) | DXT1(fmt7) | R8(fmt9).
        // fmt4=DXT5, fmt7=DXT1 실측 근거(2026-07-03): 3D 모델 텍스처 decompressedSize 가 각각
        // paddedW×H×1B(BC3 8bpp)/×0.5B(BC1 4bpp) 전수 일치, 디코드 결과가 preview 색과 일치(젤다/태양계).
        // fmt9=R8 실측 근거(2026-07-04, 3598808038 opacity 마스크): LZ4 해제 후 raw 바이트가
        // 부드러운 비네트 그라디언트(edge 255/center 0, 정확히 w×h 바이트) — DXT5 블록 구조가 아님.
        // WE 포맷 enum: 8=RG88, 9=R8. 종전 코드가 9 를 4(DXT5)에 묶어 마스크가 전백(全白)→전화면 흑화면.
        if let (mips, _, variants, mipChain) = container {
            let mip = mips[0]
            let kind: PayloadKind = payloadKind(forFormat: format)
            // 다중 image(아틀라스 페이지)는 format-based(raw/DXT) 페이로드에만 의미 — mips 전체 보존.
            // 조건 변형(variants)도 여기서만 유효(전부 imageFormat=-1 → format 기반 디코드).
            // mipChain 은 image 0 전체 레벨(단일 image + mipCount>1 일 때만 2개 이상 — 소비처: TexDecoder.rgbaLevels/nativeBC).
            return make(kind, mip.payloadRange, mip, mips: mips, variants: variants, mipChain: mipChain)
        }
        // 4) 비압축 raw RGBA(드묾).
        // F433: 픽셀은 TEXV 헤더(TEXV0005\0 + TEXI0001\0 + 6×i32) 뒤에서 시작 — 종전 0..<b.count 는
        // 헤더를 픽셀로 디코드해 42B(4의 배수 아님) 시프트로 채널 정렬이 깨졌다(TexDecoder.rawRGBA8888).
        //
        // ⚠️ **실물 헤더 끝은 42 가 아니다.** 리더 규칙대로면 42 + (flags&0x40 ? 4 : 0) + (TEXI ver>0 ? 4 : 0)
        // 이고, 실물은 TEXI0001 이라 previewColor 가 **항상** 붙어 최소 46 이다(동봉 311건 전건 —
        // 참조 파서로 46/50 을 쓰면 파스 끝이 EOF 와 정확히 일치, 42 를 쓰면 전건 어긋난다).
        // 그런데도 42 를 유지하는 이유는 **이 분기가 실물에서 도달 불가**여서다: 엔진이 만든 `.tex` 는
        // 예외 없이 TEXB 컨테이너를 갖는다(동봉 311/311, 워크샵 코퍼스 4,680/4,680 — TEXB0001~0004 합계가
        // 파일 수와 같다). 여기 오는 건 합성/손상 입력뿐이고, 기존 픽스처(TEXI0001 을 적지만 previewColor
        // 는 안 적는다)가 42 를 못박아 두고 있다. 도달 가능한 실물 반례가 나오면 그때 46/50 으로 옮길 것.
        if format == 0 { return make(.rawRGBA8888, (base + 42)..<(base + b.count), nil) }
        return make(.unknown, base..<(base + b.count), nil)
    }

    /// "TEXB000N\0" 컨테이너 파스. 모든 image 의 **mip0** 을 순차 수집한다(다중 image = 스프라이트시트
    /// 아틀라스 페이지, frame.imageId 가 페이지 인덱스 — RePKG TexToImageConverter.ConvertToGif). 실측
    /// 레이아웃(RePKG TexReader + TEXB0004 hexdump 교차검증, 2026-07-03):
    ///   i32 imageCount | (v3+) i32 imageFormat(-1=raw) | (v4) i32 isVideoMp4/변형수 |
    ///   image별: (v4 조건 변형 체인 ×N) i32 mipCount | mip별: i32 w | i32 h | (v2+) i32 isLZ4 | i32 dec | i32 comp | payload
    /// (mip0 외 mip 은 크기만큼 스킵). 종전 "compressedSize 가 EOF 에 닿는 int 스캔" 휴리스틱은 다중 mip
    /// 파일(DJK_1.tex mip 9개 등)에서 실패해 3D 모델 텍스처 대부분이 흰색 폴백이었다.
    /// mipChain: **단일 image** 일 때 image 0 의 전체 레벨도 수집(레벨 L 의 image dims = imgW/imgH >> L,
    /// 최소 1 — 레벨 레코드의 w/h 는 alloc dims 라 orig 는 축소식에서 온다). 다중 image 는 페이지 스택 경로가
    /// 레이아웃을 바꾸므로 [](무회귀). 어느 레벨이든 파스 실패 시 체인 폐기(mip0 경로 그대로 — 종전과 동일).
    private static func parseMip(_ b: [UInt8], imgW: Int, imgH: Int, format: Int, base: Int,
                                 hasMipDepth: Bool) -> (mips: [CompressedMip], imageFormat: Int, variants: [Variant], mipChain: [CompressedMip])? {
        guard let ti = indexOf(b, Array("TEXB".utf8)), ti + 9 <= b.count else { return nil }
        let version = Int(String(bytes: b[ti + 4..<ti + 8], encoding: .ascii) ?? "") ?? 0
        guard version >= 1, version <= 4 else { return nil }
        func i32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            return Int(Int32(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24))
        }
        /// 단일 mip 레코드 파스: w | h | (v2+) isLZ4 | dec | comp | payload → (mip, 다음 오프셋).
        /// origW/H = 이 레벨의 orig(image) dims — mip0 은 헤더 imgW/imgH, 레벨 L 은 1/2^L(호출자 계산).
        func readMip(_ start: Int, origW: Int, origH: Int) -> (CompressedMip, Int)? {
            var q = start
            guard let w = i32(q), let h = i32(q + 4), w > 0, h > 0, w <= 16384, h <= 16384 else { return nil }
            q += 8
            // **레코드 안의 i32 depth 는 헤더 flags & 0x40 일 때만 존재한다**(TEXB 리더 게이트
            // 0x14015d374, 읽기 0x14015d399, 미존재 기본 1 은 0x14015d2f4). 이걸 몰라 동봉
            // `materials/lut/*.tex` 28개(3D LUT)가 전건 parseMip 실패 → PNG 시그니처 스캔 폴백으로
            // 흘렀고, 컨테이너를 통째로 못 읽으니 imageCount·mip 체인·depth 가 전부 사라졌다.
            var mipDepth = 1
            if hasMipDepth {
                guard let d = i32(q), d > 0, d <= 128 else { return nil }   // 엔진 상한 0x80(0x14015d3b4)
                mipDepth = d; q += 4
            }
            var isLZ4 = 0, dec = 0
            if version >= 2 {
                guard let z = i32(q), let d = i32(q + 4) else { return nil }
                isLZ4 = z; dec = d; q += 8
            }
            guard let comp = i32(q), comp > 0, q + 4 + comp <= b.count else { return nil }
            q += 4
            // 엔진은 이 필드의 **bit0 만** 본다(0x14015d484 `movzx eax, r9b` + `and al, 1`).
            let lz4 = isLZ4 & 1 != 0
            if !lz4 { dec = comp }  // 비압축: payload 그대로
            // dec 는 공격자 제어 필드. 단일 mip 의 정당한 한계(512MB)를 넘으면 거부해 ~4GB 할당 DoS 차단.
            guard dec > 0, dec <= 512 << 20 else { return nil }
            let mip = CompressedMip(decodeWidth: w, decodeHeight: h, imageWidth: origW, imageHeight: origH,
                                    decompressedSize: dec, payloadRange: (base + q)..<(base + q + comp),
                                    lz4: lz4, depth: mipDepth)
            return (mip, q + comp)
        }
        var p = ti + 9
        var imageFormat = -1         // FreeImage enum(v3+): -1=raw(texFormat 사용), 2=JPEG 13=PNG 25=GIF 35=MP4
        guard let imageCount = i32(p), imageCount > 0, imageCount <= 1024 else { return nil }
        p += 4
        if version >= 3 { imageFormat = i32(p) ?? -1; p += 4 }   // imageFormat 직독(RePKG: !=-1 이면 인코딩 파일)
        if version >= 4 { p += 4 }   // 0004 추가 필드(실측 0/1 = isVideoMp4; 조건 변형 텍스처는 변형 수 1/3)
        var mips: [CompressedMip] = []
        var mipChain: [CompressedMip] = []                 // image 0 전체 레벨(단일 image 일 때만 확정)
        var chain: [(idx: Int, json: String)] = []   // v4 조건 변형 블록(idx, 조건 JSON) — mipCount 앞 체인
        for imageIdx in 0..<imageCount {
            // v4 조건 변형 체인: [i32 1][i32 idx][i32 0][json NUL] × N 이 mipCount 앞에 온다 — idx/JSON 보존.
            if version >= 4 {
                while let blk = conditionVariantBlock(b, from: p, i32: i32) {
                    chain.append((blk.idx, blk.json)); p = blk.end
                }
            }
            guard let mipCount = i32(p), mipCount > 0 else { break }
            p += 4
            guard let (mip0, after0) = readMip(p, origW: imgW, origH: imgH) else { break }   // 페이지의 mip0 = 아틀라스 페이지 픽셀
            mips.append(mip0)
            p = after0
            var ok = true
            var levels: [CompressedMip] = [mip0]
            for level in 1..<mipCount {                             // 나머지 레벨: 다음 image 위치까지 전진(+ image 0 은 수집)
                guard let (mipK, afterK) = readMip(p, origW: max(1, imgW >> level),
                                                   origH: max(1, imgH >> level)) else { ok = false; break }
                levels.append(mipK)
                p = afterK
            }
            if !ok { break }
            if imageIdx == 0 { mipChain = levels }                  // 전 레벨 파스 성공 시에만 확정
        }
        // v4 조건 변형: 기본 image(위) 뒤에 [imageCount][변형수] 헤더 + 변형별 image 가 온다(실측 8종 전부
        // imageCount==1). 파스 실패/미일치 시 variants=[](기본 mip 경로 무회귀 — 0xEE 잔재 픽스처 등 방어).
        var variants: [Variant] = []
        if version >= 4, imageCount == 1, !chain.isEmpty {
            variants = parseVariantSection(b, from: p, chain: chain, format: format,
                                           imgW: imgW, imgH: imgH, i32: i32, base: base)
        }
        // 다중 image 는 페이지 스택(stackedAtlas)이 레이아웃을 바꾸므로 체인 미적용 — 소비처 가드와 일치.
        if imageCount != 1 { mipChain = [] }
        return mips.isEmpty ? nil : (mips, imageFormat, variants, mipChain)
    }

    /// TEXB0004 조건 변형 블록 1개: [i32 1][i32 variantIdx][i32 0][condition JSON NUL]. 프로퍼티 값(예
    /// tuniccolor)으로 텍스처 변형을 고르는 파일 — 조건 블록 N개가 연속한 뒤 기본 mip 테이블, 그 뒤 변형 섹션.
    /// 실측(2026-07-09, 전 코퍼스 460종 sweep + 8종 디코드 검증): 조건 tex 는 zelda 8개뿐, 전부 이 레이아웃.
    /// 반환 = (블록 끝(다음 블록 또는 mipCount 위치), idx, condition JSON). 패턴 불일치 시 nil(mip 테이블 직행).
    private static func conditionVariantBlock(_ b: [UInt8], from p: Int, i32: (Int) -> Int?)
        -> (end: Int, idx: Int, json: String)? {
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
        return (jsonEnd + 1, idx, String(decoding: b[jsonStart..<jsonEnd], as: UTF8.self))
    }

    /// 기본 image 뒤 변형 섹션 파스(실측 레이아웃, 2026-07-09 전 코퍼스 8종 디코드 검증 — childlink 튜닉색
    /// 초록/파랑/빨강/검정이 idx 로 분리 확인):
    ///   [i32 imageCount][i32 변형수] | 변형별: [i32 1][i32 idx][i32 0][i32 0][i32 w][i32 h][i32 13][i32 comp][payload]
    /// dec(해제 크기)는 파일 format+w,h 로 계산(변형 image 엔 dec 필드 부재), isLZ4 는 comp==dec 면 비압축
    /// (WE 는 압축이 이득일 때만 LZ4 저장). idx 로 조건 체인과 짝지음. 어떤 검증이든 실패하면 [](기본 mip 무회귀).
    private static func parseVariantSection(_ b: [UInt8], from start: Int,
                                            chain: [(idx: Int, json: String)],
                                            format: Int, imgW: Int, imgH: Int,
                                            i32: (Int) -> Int?, base: Int) -> [Variant] {
        var q = start
        guard let sImageCount = i32(q), sImageCount >= 1, sImageCount <= 1024,
              let sVariantCount = i32(q + 4), sVariantCount == chain.count else { return [] }
        q += 8
        var byIdx: [Int: CompressedMip] = [:]
        for _ in 0..<sVariantCount {
            guard let m1 = i32(q), m1 == 1, let idx = i32(q + 4), (1...64).contains(idx),
                  let z0 = i32(q + 8), z0 == 0, let z1 = i32(q + 12), z1 == 0,
                  let w = i32(q + 16), let h = i32(q + 20), w > 0, h > 0, w <= 16384, h <= 16384,
                  i32(q + 24) != nil, let comp = i32(q + 28), comp > 0, q + 32 + comp <= b.count else { return [] }
            q += 32
            let dec = mipByteSize(format: format, w: w, h: h)
            guard dec > 0, dec <= 512 << 20 else { return [] }
            byIdx[idx] = CompressedMip(decodeWidth: w, decodeHeight: h, imageWidth: imgW, imageHeight: imgH,
                                       decompressedSize: dec, payloadRange: (base + q)..<(base + q + comp), lz4: comp != dec)
            q += comp
        }
        var out: [Variant] = []
        for (idx, json) in chain {
            guard let cond = VariantCondition(json: json), let mip = byIdx[idx] else { continue }
            out.append(Variant(condition: cond, mip: mip))
        }
        return out
    }

    /// mip 해제 크기(byte) = format 별 픽셀/블록 크기 × dims. 변형 image 는 dec 필드가 없어 계산해야
    /// LZ4 해제 크기를 안다(기본 mip 은 dec 명시). WE format: 0=RGBA 4=DXT5 6=DXT3 7=DXT1 8=RG88 9=R8.
    private static func mipByteSize(format: Int, w: Int, h: Int) -> Int {
        switch format {
        case 4, 6: return ((w + 3) / 4) * ((h + 3) / 4) * 16   // BC3/BC2 16B/block
        case 7:    return ((w + 3) / 4) * ((h + 3) / 4) * 8    // BC1 8B/block
        case 8:    return w * h * 2                             // RG88
        case 9:    return w * h                                // R8
        default:   return w * h * 4                            // RGBA(0) 및 미지 포맷
        }
    }

    /// TEXS 스프라이트시트 섹션 파스(파일 꼬리에서 역방향 탐색 — LZ4 페이로드 내 우연 일치 회피).
    /// 이상 감지 시 [] (프레임 없음 = 전체 텍스처 1프레임과 동등).
    private static func parseFrames(_ b: [UInt8]) -> (frames: [TexFrame], version: Int, gifWidth: Int, gifHeight: Int) {
        let none = (frames: [TexFrame](), version: 0, gifWidth: 0, gifHeight: 0)
        let sig = Array("TEXS000".utf8)
        guard b.count > sig.count + 6 else { return none }
        guard let ti = findLastSignature(b, sig) else { return none }
        let version = Int(b[ti + 7]) - 0x30
        guard version >= 1, version <= 3 else { return none }
        func i32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            return Int(Int32(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24))
        }
        func f32(_ o: Int) -> Float? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            return Float(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
        }
        var p = ti + 9
        guard let count = i32(p), count > 0, count <= 4096 else { return none }
        p += 4
        // gifWidth/gifHeight 는 **v3 부터만** 파일에 있다(TEXS 리더 0x14015e221 `cmp ebp, 3`,
        // 읽기 0x14015e226·0x14015e241). v2 이하에서는 엔진이 헤더 imgW/imgH 를 넣는다(0x14015e268)
        // — 그 기본값은 호출자 make(_:) 가 채운다.
        var gifW = 0, gifH = 0
        if version >= 3 {
            guard let gw = i32(p), let gh = i32(p + 4) else { return none }
            gifW = gw; gifH = gh; p += 8
        }
        guard p + count * 32 <= b.count else { return none }
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
                  // F690: frametime==0 프레임도 유효(RePKG TexToImageConverter 는 딜레이 0 클램프로 유지 —
                  // 실물 3554161528 13프레임 스트립·3596044309 3개 시트 전 프레임 0). 종전 t>0 가드는
                  // 시트 전체를 `return []` 로 폐기해 파티클이 풀 아틀라스 UV 로 찌그러졌다. 소비처
                  // spriteFrameIndex 는 프레임당 max(1e-4,…) 클램프라 0 도 안전.
                  t.isFinite, t >= 0,
                  x >= 0, y >= 0, x.isFinite, y.isFinite,
                  w.isFinite, h.isFinite, wy.isFinite, hx.isFinite else { return none }
            // 회전 프레임(RePKG): Width|Height 가 0 → 유효 크기는 HeightX/WidthY 에서. 양 축 모두 0(퇴화)이면
            // 프레임 전체 드롭(종전 w>0,h>0 안전망 유지) — 단 회전 시트는 더는 통째로 버리지 않는다.
            let effW = w != 0 ? w : hx
            let effH = h != 0 ? h : wy
            guard abs(effW) > 0, abs(effH) > 0 else { return none }
            out.append(TexFrame(imageId: id, time: t, x: x, y: y, width: w, height: h, widthY: wy, heightX: hx))
            p += 32
        }
        return (out, version, gifW, gifH)
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

    /// 바이트 배열에서 sig 의 **마지막** 출현 위치를 역방향 탐색(LZ4 페이로드 내 우연 일치 회피).
    /// 첫바이트 선비교 → 전체 대조(Model3D.findMagic 동형 — 무할당). 미발견 시 nil.
    private static func findLastSignature(_ b: [UInt8], _ sig: [UInt8]) -> Int? {
        var i = b.count - sig.count - 2
        while i >= 0 {
            if b[i] == sig[0] {
                var match = true
                for j in 1..<sig.count where b[i + j] != sig[j] { match = false; break }
                if match { return i }
            }
            i -= 1
        }
        return nil
    }

    /// TEXB format 필드 → PayloadKind 매핑(순수 계산). format 기반 디코드 경로에서만 사용.
    /// fmt4=DXT5, fmt7=DXT1 실측 근거(2026-07-03): decompressedSize 가 paddedW×H×bpp 전수 일치.
    /// fmt6=DXT3(BC2) 실측(2026-07-06): 태양계 fmt6 16개.
    /// fmt8=RG88: 2B/px (r=루마, g=알파 — 실물 common_fragment.h ConvertTexture0Format .rrrg).
    /// fmt9=R8 실측(2026-07-04): opacity 마스크 w×h 바이트.
    private static func payloadKind(forFormat format: Int) -> PayloadKind {
        switch format {
        case 0: return .lz4RGBA
        case 4: return .bc3
        case 6: return .bc2
        case 7: return .bc1
        case 8: return .rg88
        case 9: return .r8
        default: return .unknown
        }
    }

    private static func indexOf(_ b: [UInt8], _ sig: [UInt8]) -> Int? {
        guard b.count >= sig.count else { return nil }
        var i = 0
        while i <= b.count - sig.count { if Array(b[i..<i + sig.count]) == sig { return i }; i += 1 }
        return nil
    }
}
