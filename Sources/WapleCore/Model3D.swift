import Foundation
import simd

/// WE 3D 모델(MDLV0016/0017/0019/0021/0023) 파서 — 실측 리버스(설계 2026-07-03, 구버전 2026-07-09).
/// 코퍼스: 3737268876(젤다 OoT/MM, 100개), 3706286085(Sonic, 5개), 3662790108(태양계, 69개) — 174개 전수 MDLV0023.
/// 구버전 퍼펫(전부 *_puppet.mdl): 2885492021(V0016 6개), 3113287126(V0017 2개), 3189665546(V0019 7개) —
/// 메시 레이아웃은 V0023 과 동일하되 V0016 은 AABB 부재 + 정점 플래그 0x…09(stride 52), 스켈레톤 매직이
/// MDLS0002(레코드 동일 + 13+80×본수 꼬리), 애니 매직이 MDLA0003/0004/0005(레이아웃 동일).
///
/// 2D 퍼펫(MDLV0013)과의 diff:
///   • 매직: "MDLV0023" (2D "MDLV0013")
///   • 멀티메시: 헤더가 meshCount 를 담고 서브메시가 반복(2D 는 단일 메시)
///   • 정점: 법선(normal 3f) + 탄젠트(tangent 4f, w=handedness) 추가. 스키닝 정점만 본/웨이트 보유.
///   • 스켈레톤 매직: "MDLS0004" (2D "MDLS0001"), 본별 말미가 u8 0 이 아니라 cstring props(대개 빈 문자열, 일부 IK JSON)
///   • 애니: "MDLA0006" (+일부 모델은 선행 "MDAT0001" 어태치먼트) — 리버스 완료(2026-07-04, 아래 참조), 2D 는 "MDLA0001".
///
/// MDLA0006 애니 섹션(2026-07-04 헥스 리버스, 코퍼스: 3737268876/3706286085/3662790108 의 .mdl 33개 애니 전수):
///   "MDLA0006" | u8 0 | u32 nextOff(=EOF-1) | u32 animCount | u32 baseId | u32 0 |
///   애니×N: cstring 이름(예 "Link Adult_arm|idle_bone", UTF-8) | cstring 모드(loop/single/mirror/clamp) |
///           f32 fps | u32 길이(프레임) | u32 0 | u32 본수(=스켈레톤 본수) | u32 0 |
///           본별: u32 트랙크기 | 키×36B(pos 3f, 오일러각 3f 라디안, 스케일 3f) | u32 블롭2크기 | 블롭2 |
///           트레일러(가변 32~39B): u16 0 | AABB 6f | u32 0 | u16 id(=baseId+1+i, 마지막 애니는 생략) | ...
///   2D MDLA0001 과의 diff: ① 헤더 4번째 u32 는 animCount(2D 는 nextOff 직후 animCount|id|0 — 여기선 순서 동일하나
///     link_adult 는 animCount=8 인데 실제 4개 → count 불신, 리싱크로 종료 판정) ② 애니 트레일러(AABB+id)가 신설(2D 없음)
///     ③ 키 포맷/본 트랙 구조는 동일(36B 키). 트레일러 가변 → 다음 애니 헤더를 ≤256B 앞에서 리싱크로 스킵.
///   확정(교차검증): 174 .mdl 중 33 애니모델 전수 파스 성공(0 실패); 본수==스켈레톤 본수(전수); 키0 로컬≈바인드 로컬은
///     캐릭터별로 다름(바인드=T포즈, idle=이완포즈) — skin=world(t)×bindWorld⁻¹ 로 처리(2D 의 t=0 항등 가정 불성립이나 정상).
///
/// 레이아웃(리틀엔디안):
/// "MDLV0023" | u8 0 | u32 formatFlag | u32(=1, 미상 상수) | u32 meshCount
/// 서브메시×meshCount:
///   cstring 머티리얼 | u32(=0) | AABB(min 3f, max 3f = 24B) | u32 formatFlag | u32 정점블롭크기 |
///   정점×N | u32 인덱스블롭크기 | u16 트라이앵글 인덱스
///   [메시 사이 구분자 6×u8 0]
/// (스키닝 모델) "MDLS0004" | u8 0 | u32 nextOff | u32 본수 |
///   본별: cstring 이름 | u32 flags | i32 부모 | u32 64 | float4x4 바인드 | cstring props
/// (스키닝 모델) "MDAT0001" ... "MDLA0006" ... (미해독, hasAnimation 로만 표기)
///
/// 정점 포맷(formatFlag 하위 바이트 0x0f = pos+normal+tangent+uv; 비트 0x01800000 = 스키닝):
///   정적(stride 48): pos 3f | normal 3f | tangent 4f | uv 2f
///   스키닝(stride 80): pos 3f | normal 3f | tangent 4f | boneIndices 4×u32 | weights 4f | uv 2f
///
/// 확정 근거(교차검증): 174/174 파스; 단일메시 40개 전부 maxIndex == vertexCount-1;
///   vsize % stride == 0(전수); normal/tangent 단위길이·weights 합 1.0(3개 witness); 6바이트 구분자 전수 0.
public struct Model3D: Equatable {
    /// 정점. 정적 메시는 boneIndices/weights 가 (0,0,0,0).
    public struct Vertex: Equatable {
        public let position: SIMD3<Float>
        public let normal: SIMD3<Float>
        public let tangent: SIMD4<Float>       // xyz + w(handedness, 실측 ±1)
        public let uv: SIMD2<Float>
        public let boneIndices: SIMD4<UInt32>  // 정적: (0,0,0,0)
        public let weights: SIMD4<Float>       // 정적: (0,0,0,0)

        public init(position: SIMD3<Float>, normal: SIMD3<Float>, tangent: SIMD4<Float>,
                    uv: SIMD2<Float>, boneIndices: SIMD4<UInt32> = .zero, weights: SIMD4<Float> = .zero) {
            self.position = position; self.normal = normal; self.tangent = tangent
            self.uv = uv; self.boneIndices = boneIndices; self.weights = weights
        }
    }

    /// 서브메시(머티리얼 1개 = 드로우콜 1개).
    public struct Mesh: Equatable {
        public let material: String            // 규약: "materials/…json" 상대경로(확장자 생략된 재질 정의)
        public let boundsMin: SIMD3<Float>
        public let boundsMax: SIMD3<Float>
        public let skinned: Bool
        public let vertices: [Vertex]
        public let indices: [UInt16]           // 트라이앵글 리스트(count % 3 == 0)
    }

    /// 스켈레톤 본(스키닝 모델만). 좌표계·부모 규약은 2D 퍼펫과 동일. bind = 부모상대 로컬 레스트 변환
    /// (부모 체인 합성 → bindWorld; 실측: 발밑↓/머리↑ 정상 스켈레톤 구도).
    public struct Bone: Equatable {
        public let name: String
        public let parent: Int32               // -1 = 루트
        public let bind: simd_float4x4         // 바인드(로컬 레스트) 행렬
        public let properties: String          // 대개 "" — 일부 본은 리깅툴 IK 설정 JSON
    }

    /// 애니 키(프레임당 1키). 2D PuppetModel.Key 와 동일 포맷: pos + 오일러각(라디안) + scale.
    public struct Key: Equatable {
        public let position: SIMD3<Float>
        public let angles: SIMD3<Float>
        public let scale: SIMD3<Float>
        public init(position: SIMD3<Float>, angles: SIMD3<Float>, scale: SIMD3<Float>) {
            self.position = position; self.angles = angles; self.scale = scale
        }
    }

    /// 애니메이션(MDLA0006 애니 1개). tracks[boneIdx] = 프레임순 키 배열(본수 == 스켈레톤 본수).
    public struct Animation: Equatable {
        public let name: String                // "Link Adult_arm|idle_bone" 등
        public let mode: String                // loop | single | mirror | clamp
        public let fps: Float
        public let lengthFrames: Int
        public let tracks: [[Key]]             // 본 인덱스별 키(프레임당 1키)
        /// 이벤트 마커(실측 2026-07-10): 트랙 뒤 트레일러에 `u32 count | count×(f32 초 + NUL종단
        /// JSON cstring {"frame":N,"name":"…"})`. 재생이 frame 을 지나면 animationEvent 발화
        /// (3351179520/3396722575 错帧 동기, 젤다 talon snore·link Look Left/Right).
        public var events: [AnimationMarker] = []
    }

    /// 부착점(MDAT0001 섹션) — 씬 오브젝트의 `attachment` 키가 **이름으로** 참조하는 본-슬롯.
    /// 실물 본 이름은 대개 빈 문자열이라 본은 **인덱스**로 바인딩된다(코퍼스 28씬/47 mdl 전수 실측).
    public struct Attachment: Equatable {
        public let name: String            // 씬 `attachment` 가 참조하는 이름("头"/"Attachment" 등)
        public let bone: Int32             // MDLS 본 인덱스
        public let local: simd_float4x4    // 본-로컬 부착 변환(모델공간 y-up, 실측: 평행이동 위주)
        public init(name: String, bone: Int32, local: simd_float4x4) {
            self.name = name; self.bone = bone; self.local = local
        }
    }

    public let meshes: [Mesh]
    public var bones: [Bone] = []
    /// MDAT0001 부착점(스켈레톤 트레일러 뒤·MDLA 앞). 없으면 빈 배열(무부착).
    public var attachments: [Attachment] = []
    /// MDLA0006 애니 섹션 존재 여부(매직 탐지 — animations 가 비어도 마커는 true).
    public var hasAnimation: Bool = false
    /// 파스된 애니메이션(순서 = 파일 순서). 렌더러가 animationlayers 로 활성 애니를 선택.
    public var animations: [Animation] = []

    /// 스키닝 정점 포맷 비트(formatFlag & 이 마스크 != 0 → 스키닝 선언 — 실제 본/웨이트 필드 존재는
    /// 스트라이드 여유(skinFieldsFit)로 최종 판정).
    private static let skinMask: UInt32 = 0x0180_0000

    /// 수용 버전(전부 실물 바이트 대조 완료 2026-07-09): 0023 정본; 0021 동일 레이아웃(3367988661 전수,
    /// 스켈레톤 매직은 MDLS0003 — 본 레코드는 0004 와 바이트 동형, 코퍼스 17퍼펫 matrix size 64 전수);
    /// 0017/0019 는 메시가 0023 과 동일하고 스켈레톤 매직만 MDLS0002(WLOP 2/2, 3189665546 7/7 대조);
    /// 0016 은 메시에 AABB 가 없고 정점 포맷 플래그가 0x…09(normal/tangent 없는 stride 52 = V0013 정점 레이아웃,
    /// 2885492021 6/6 대조 — weights 합 1.0, uv∈[0,1], maxIdx==vCount-1 전수 일치).
    /// 미목격 버전(0018/0020/0022 등)은 거부 — 추측 파스로 이상 렌더를 만드느니 스킵이 낫다.
    private static let acceptedMagics: Set<String> = ["MDLV0016", "MDLV0017", "MDLV0019", "MDLV0021", "MDLV0023"]

    public static func parse(_ data: Data) -> Model3D? {
        let bytes = [UInt8](data)
        let magic = String(bytes: bytes[0..<min(8, bytes.count)], encoding: .utf8)
        guard bytes.count > 21, let magic, acceptedMagics.contains(magic) else { return nil }
        let version = Int(magic.suffix(4)) ?? 23
        let hasAABB = version >= 17   // V0016 은 메시 헤더에 AABB 24B 가 없다(실측)

        func u32(_ o: Int) -> UInt32? { readU32LE(bytes, at: o) }
        func f32(_ o: Int) -> Float? { u32(o).map { Float(bitPattern: $0) } }
        func cstring(_ o: inout Int) -> String? {
            guard let r = readCString(bytes, at: o) else { return nil }
            o = r.next
            return r.value
        }

        // 헤더: magic(8) | u8 0 | u32 formatFlag(9) | u32(=1, 13) | u32 meshCount(17)
        guard let meshCount = u32(17), meshCount > 0, meshCount < 100_000 else { return nil }
        var o = 21
        var meshes: [Mesh] = []
        meshes.reserveCapacity(Int(meshCount))

        for mi in 0..<Int(meshCount) {
            guard let material = cstring(&o) else { return nil }
            guard let _ = u32(o) else { return nil }             // u32(관측 0, Kirby mesh1 은 2 — 값 미사용)
            o += 4
            // 메시 헤더 프레이밍 프로브: z 뒤에 여분 u32 가 0..2개 올 수 있다(실측: 전 코퍼스 0개,
            // Kirby_puppet mesh1 만 1개(=1)). extra=0 이 기존 경로라 최우선 — vSize/스트라이드 정합
            // (표 나눗셈 or 인덱스 maxIndex+1 추론)이 성립하는 첫 프레이밍을 채택한다.
            //
            // 정점 포맷 플래그(실측 4종 대조로 확정): bit1(0x2)=normal 3f, bit2(0x4)=tangent 4f,
            // skinMask=본/웨이트. pos 3f 와 uv 2f 는 전 변형 공통(bit0/bit3 semantics 미상 — 무시).
            //   0x0f(48/80)  0x09(52, V0016)  0x0e(sl_puppet 84 변종)  0x21(Kirby channelmap 44).
            // 변종 스트라이드 자기기술 추론(2026-07-06, 실물 sl_puppet.mdl = 84 = 기지 80 + 미상 4B):
            // 표 스트라이드로 안 나눠지면 인덱스 블롭의 maxIndex+1 을 정점 수로 보고 vSize/count 가
            // 정수(20..96)면 채택. 필드는 꼬리 고정(uv@-8, weights@-24, bones@-40), 중간은 고전 오프셋.
            var minx: Float = 0, miny: Float = 0, minz: Float = 0
            var maxx: Float = 0, maxy: Float = 0, maxz: Float = 0
            var formatFlag: UInt32 = 0
            var stride = 0
            var vSize = 0
            var framed = false
            probe: for extra in 0...2 {
                var q = o + extra * 4
                var box: [Float] = [0, 0, 0, 0, 0, 0]
                if hasAABB {
                    for k in 0..<6 {
                        guard let v = f32(q + k * 4) else { continue probe }
                        box[k] = v
                    }
                    q += 24
                }
                guard let flag = u32(q), let vsRaw = u32(q + 4) else { continue }
                let vs = Int(vsRaw)
                guard vs > 0, q + 8 + vs <= bytes.count else { continue }
                let skin = (flag & skinMask) != 0
                var s = 12 + (flag & 0x2 != 0 ? 12 : 0) + (flag & 0x4 != 0 ? 16 : 0) + (skin ? 32 : 0) + 8
                if vs % s != 0 {
                    guard let inferred = inferStride(bytes: bytes, indexBlobAt: q + 8 + vs, vSize: vs),
                          inferred >= 20 else { continue }   // pos(12)+uv(8) 최소
                    s = inferred
                }
                (minx, miny, minz) = (box[0], box[1], box[2])
                (maxx, maxy, maxz) = (box[3], box[4], box[5])
                formatFlag = flag; stride = s; vSize = vs
                o = q + 8
                framed = true
                break
            }
            guard framed, stride > 0, vSize % stride == 0 else { return nil }
            let skinned = (formatFlag & skinMask) != 0
            let hasNormal = formatFlag & 0x2 != 0
            let hasTangent = formatFlag & 0x4 != 0
            let vCount = vSize / stride
            // 본/웨이트 필드는 스트라이드에 실제 자리가 있을 때만 읽는다. 스키닝 선언이라도 자리가 없으면
            // (Kirby channelmap: flag 0x00800021, stride 44 = pos+미상24B+uv) pos+uv 만 — 가중 0 스킨 합성으로
            // 정점이 원점 붕괴하는 것보다 정적 메시가 낫다(graceful degradation).
            let skinFieldsFit = skinned && stride >= 12 + (hasNormal ? 12 : 0) + (hasTangent ? 16 : 0) + 40

            var vertices: [Vertex] = []
            vertices.reserveCapacity(vCount)
            for vi in 0..<vCount {
                let b = o + vi * stride
                guard let px = f32(b), let py = f32(b + 4), let pz = f32(b + 8) else { return nil }
                let pos = SIMD3<Float>(px, py, pz)
                var nrm = SIMD3<Float>(0, 0, 1)                       // 부재 시 기본(2D 퍼펫은 미사용)
                if hasNormal {
                    guard let nx = f32(b + 12), let ny = f32(b + 16), let nz = f32(b + 20) else { return nil }
                    nrm = SIMD3(nx, ny, nz)
                }
                var tan = SIMD4<Float>(1, 0, 0, 1)
                if hasTangent {
                    let to = b + 12 + (hasNormal ? 12 : 0)
                    guard let tx = f32(to), let ty = f32(to + 4), let tz = f32(to + 8), let tw = f32(to + 12)
                    else { return nil }
                    tan = SIMD4(tx, ty, tz, tw)
                }
                if skinFieldsFit {
                    let bo = b + stride - 40, wo = b + stride - 24, uo = b + stride - 8
                    guard let b0 = u32(bo), let b1 = u32(bo + 4), let b2 = u32(bo + 8), let b3 = u32(bo + 12),
                          let w0 = f32(wo), let w1 = f32(wo + 4), let w2 = f32(wo + 8), let w3 = f32(wo + 12),
                          let u = f32(uo), let v = f32(uo + 4) else { return nil }
                    vertices.append(Vertex(position: pos, normal: nrm, tangent: tan, uv: SIMD2(u, v),
                                           boneIndices: SIMD4(b0, b1, b2, b3), weights: SIMD4(w0, w1, w2, w3)))
                } else {
                    guard let u = f32(b + stride - 8), let v = f32(b + stride - 4) else { return nil }
                    vertices.append(Vertex(position: pos, normal: nrm, tangent: tan, uv: SIMD2(u, v)))
                }
            }
            o += vSize

            guard let iSizeRaw = u32(o) else { return nil }
            o += 4
            let iSize = Int(iSizeRaw)
            guard iSize % 2 == 0, o + iSize <= bytes.count else { return nil }
            var indices: [UInt16] = []
            indices.reserveCapacity(iSize / 2)
            for k in stride16(iSize) {
                indices.append(UInt16(bytes[o + k]) | (UInt16(bytes[o + k + 1]) << 8))
            }
            if let maxIndex = indices.max(), Int(maxIndex) >= vCount { return nil }
            o += iSize

            meshes.append(Mesh(material: material,
                               boundsMin: SIMD3(minx, miny, minz), boundsMax: SIMD3(maxx, maxy, maxz),
                               skinned: skinFieldsFit, vertices: vertices, indices: indices))

            // 메시 사이 트레일러: u8 0 | u8 count | count×(u32 size | size 바이트) | u32 tail.
            // 실측: 전 코퍼스 count=0(= 종전 '6바이트 0 구분자'와 바이트 동일), Kirby_puppet 만
            // count=1(16B 블롭, 총 26B — 스킵하면 mesh1 'Kirby_channelmap' 이 정상 파스).
            // 구조 불일치 시 종전 +6 폴백(무회귀). 마지막 메시 뒤에는 없음.
            if mi < Int(meshCount) - 1 { o = meshTrailerEnd(bytes: bytes, at: o) ?? (o + 6) }
        }

        var model = Model3D(meshes: meshes)

        // 스켈레톤(스키닝 모델). MDLA 와 동일하게 메시 끝 이후 매직 스캔으로 찾는다 — V0021(MDLS0003)은
        // 마지막 메시와 스켈레톤 사이에 비제로 부가 블록이 있어(실물 3384019940 5/5 실측) 종전
        // '제로-스킵 후 정확 착지'로는 도달 불가였다. 실패/구조 불일치는 본 없이 반환(정적 메시 렌더 가능).
        // MDLS0002(V0016/17/19)는 본 레코드가 0004 와 동일(cstring|flags|parent|64|mat4|props cstring —
        // WLOP GIRL 64본 props JSON 실측)하고, 레코드 뒤에 13+80×본수 바이트 꼬리가 더 있을 뿐이다.
        // MDLS0003(MDLV0021 짝)도 본 레코드 바이트 동형(코퍼스 17퍼펫/7씬 matrix size 64 전수 실측).
        // 꼬리는 파스하지 않는다 — 다음 섹션(MDLA)은 아래 매직 스캔이 찾는다.
        // 수용 버전 0002/0003/0004 — 미목격 버전은 계속 거부(추측 파스 금지).
        if let si = findMagic("MDLS000", in: bytes, from: o), si + 9 <= bytes.count,
           (UInt8(ascii: "2")...UInt8(ascii: "4")).contains(bytes[si + 7]) {
            var p = si + 8 + 1  // magic + lead u8(0)
            if let _ = u32(p), let boneCount = u32(p + 4), boneCount < 100_000 {
                p += 8
                var bones: [Bone] = []
                bones.reserveCapacity(Int(boneCount))
                var boneOK = true
                for _ in 0..<Int(boneCount) {
                    guard let name = cstring(&p),
                          let _ = u32(p), let parentRaw = u32(p + 4), let msz = u32(p + 8), msz == 64,
                          p + 12 + 64 <= bytes.count else { boneOK = false; break }
                    p += 12
                    var cols: [SIMD4<Float>] = []
                    for c in 0..<4 {
                        guard let x = f32(p + c * 16), let y = f32(p + c * 16 + 4),
                              let z = f32(p + c * 16 + 8), let w = f32(p + c * 16 + 12) else { boneOK = false; break }
                        cols.append(SIMD4(x, y, z, w))
                    }
                    if !boneOK { break }
                    p += 64
                    guard let props = cstring(&p) else { boneOK = false; break }
                    bones.append(Bone(name: name, parent: Int32(bitPattern: parentRaw),
                                      bind: simd_float4x4(cols[0], cols[1], cols[2], cols[3]), properties: props))
                }
                if boneOK { model.bones = bones }
            }
        }

        // 부착점 섹션(MDAT0001) — 스켈레톤 트레일러 뒤·MDLA 앞(실측: attachment 28씬 47 mdl 전수).
        // 씬 오브젝트 `attachment`(이름 본-슬롯 부착)의 슬롯 정의. 실패/부재는 빈 배열(무부착 폴백).
        if !model.bones.isEmpty, let mi = findMagic("MDAT0001", in: bytes, from: o) {
            model.attachments = parseAttachments(bytes: bytes, at: mi, boneCount: model.bones.count)
        }

        // 애니 섹션(MDLA000N) — 스켈레톤 유무와 무관하게 메시 끝 이후 탐색(스키닝 모델만 존재).
        // 버전별 매직: 0016→MDLA0003, 0017→0004, 0019→0005, 0023→0006(실측). 헤더·레코드 레이아웃은
        // 전 버전 동일(36B 키, 코퍼스 전수 트레이스 일치) — 숫자만 다르니 접두 스캔으로 통합.
        if let ai = findMagic("MDLA000", in: bytes, from: o),
           ai + 8 <= bytes.count, (0x31...0x39).contains(bytes[ai + 7]) {
            model.hasAnimation = true
            model.animations = parseAnimations(bytes: bytes, at: ai, boneCount: model.bones.count)
        }

        return model
    }

    /// MDAT0001 부착점 파스. 레이아웃(실측 7씬 다중 엔트리 정렬 전수 일치):
    /// "MDAT0001" | u8 0 | u32 nextOff | u16 count | count×(u16 본인덱스 | cstring 이름(UTF-8) | 64B float4x4 로컬).
    /// 구조 불일치(본 인덱스 범위 밖 포함)는 빈 배열 — 추측 파스로 이상 부착을 만드느니 무부착이 낫다.
    static func parseAttachments(bytes: [UInt8], at magicOff: Int, boneCount: Int) -> [Attachment] {
        func u16(_ o: Int) -> Int? {
            guard o >= 0, o + 2 <= bytes.count else { return nil }
            return Int(bytes[o]) | (Int(bytes[o + 1]) << 8)
        }
        func f32(_ o: Int) -> Float? { readU32LE(bytes, at: o).map { Float(bitPattern: $0) } }
        var p = magicOff + 8 + 1 + 4   // magic + u8(0) + u32 nextOff
        guard let count = u16(p), count > 0, count < 1000 else { return [] }
        p += 2
        var out: [Attachment] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard let bone = u16(p), bone < boneCount,
                  let name = readCString(bytes, at: p + 2) else { return [] }
            p = name.next
            var cols: [SIMD4<Float>] = []
            for c in 0..<4 {
                guard let x = f32(p + c * 16), let y = f32(p + c * 16 + 4),
                      let z = f32(p + c * 16 + 8), let w = f32(p + c * 16 + 12) else { return [] }
                cols.append(SIMD4(x, y, z, w))
            }
            p += 64
            out.append(Attachment(name: name.value, bone: Int32(bone),
                                  local: simd_float4x4(cols[0], cols[1], cols[2], cols[3])))
        }
        return out
    }

    private static let animModes: Set<String> = ["loop", "single", "mirror", "clamp"]

    /// MDLA0006 애니 파스(리싱크 기반). 헤더 animCount 는 link_adult 반례로 불신 —
    /// 각 애니 뒤 가변 트레일러(32~39B AABB+id)를 다음 유효 헤더 리싱크(≤256B)로 스킵하고,
    /// 헤더 검증(모드∈집합, fps∈(0,240], 본수==skeleton)으로 종료를 판정한다.
    private static func parseAnimations(bytes: [UInt8], at magicOff: Int, boneCount: Int) -> [Model3D.Animation] {
        guard boneCount > 0 else { return [] }
        func u32(_ o: Int) -> UInt32? { readU32LE(bytes, at: o) }
        func f32(_ o: Int) -> Float? { u32(o).map { Float(bitPattern: $0) } }
        func cstring(_ o: Int) -> (value: String, next: Int)? { readCString(bytes, at: o) }
        // 애니 헤더 시도: 성공 시 (이름,모드,fps,길이,본수,본트랙시작오프셋).
        // 모드 빈 문자열 = **디렉토리 레코드**(실측 link/talon: 본클립 뒤에 짧은 이름("Glance"/"Sleep")
        // + 빈 모드 + flags(0x401) 레코드 — 트랙 포맷은 동일, 씬 노출 애니 단위로 이벤트 마커를 보유).
        func tryHeader(_ p: Int) -> (name: String, mode: String, fps: Float, length: Int, bc: Int, off: Int)? {
            guard let (name, p2) = cstring(p), !name.isEmpty, name.utf8.count <= 96 else { return nil }
            guard let (mode, p3) = cstring(p2), animModes.contains(mode) || mode.isEmpty else { return nil }
            guard let fps = f32(p3), fps > 0, fps <= 240 else { return nil }
            guard let length = u32(p3 + 4), let bc = u32(p3 + 12), Int(bc) == boneCount else { return nil }
            return (name, mode, fps, Int(length), Int(bc), p3 + 20)
        }
        // 헤더: magic(8)|u8 0|u32 nextOff|u32 animCount|u32 baseId|u32 0
        var o = magicOff + 9
        guard u32(o) != nil else { return [] }
        o += 16
        var anims: [Model3D.Animation] = []
        while let h = tryHeader(o) {
            o = h.off
            var tracks: [[Key]] = []
            tracks.reserveCapacity(h.bc)
            var ok = true
            for _ in 0..<h.bc {
                guard let tsRaw = u32(o), tsRaw % 36 == 0, o + 4 + Int(tsRaw) <= bytes.count else { ok = false; break }
                o += 4
                let ts = Int(tsRaw)
                var keys: [Key] = []
                keys.reserveCapacity(ts / 36)
                var k = 0
                while k < ts {
                    guard let px = f32(o + k), let py = f32(o + k + 4), let pz = f32(o + k + 8),
                          let ax = f32(o + k + 12), let ay = f32(o + k + 16), let az = f32(o + k + 20),
                          let sx = f32(o + k + 24), let sy = f32(o + k + 28), let sz = f32(o + k + 32) else { ok = false; break }
                    keys.append(Key(position: SIMD3(px, py, pz), angles: SIMD3(ax, ay, az), scale: SIMD3(sx, sy, sz)))
                    k += 36
                }
                if !ok { break }
                o += ts
                guard let blob2 = u32(o), o + 4 + Int(blob2) <= bytes.count else { ok = false; break }
                o += 4 + Int(blob2)
                tracks.append(keys)
            }
            guard ok, tracks.count == h.bc else { break }
            // 리싱크: 가변 트레일러를 건너뛰고 다음 유효 헤더로(≤256B). 없으면 종료.
            var next: Int? = nil
            var d = 0
            while d <= 256 {
                if tryHeader(o + d) != nil { next = o + d; break }
                d += 1
            }
            // 이벤트 마커는 이 레코드 트레일러(트랙 끝 o ~ 다음 헤더) 안의 JSON cstring —
            // 트레일러 정밀 레이아웃(AABB+id 32~39B 가변) 대신 패턴 스캔(레이아웃 변화에 강건,
            // 선행 f32 초 값은 JSON frame 과 중복이라 무시). 마지막 레코드는 섹션 끝까지 최대 512B.
            let events = Self.trailerEvents(bytes: bytes, from: o, to: next ?? min(o + 512, bytes.count))
            if h.mode.isEmpty {
                // 디렉토리 레코드: 렌더 클립 목록엔 미포함(포즈/클립 선택 무회귀) — 이벤트만
                // 이름 매칭 본클립("Glance" ⊂ "Link Adult_arm|glance_bone")에 병합(실측: fps/len 동일).
                if !events.isEmpty {
                    let dn = h.name.lowercased()
                    if let i = anims.firstIndex(where: {
                        let cn = $0.name.lowercased(); return cn.contains(dn) || dn.contains(cn)
                    }) {
                        anims[i].events.append(contentsOf: events)
                    }
                }
            } else {
                var anim = Animation(name: h.name, mode: h.mode, fps: h.fps, lengthFrames: h.length, tracks: tracks)
                anim.events = events
                anims.append(anim)
            }
            guard let n = next else { break }
            o = n
        }
        return anims
    }

    /// 트레일러 구간 [from, to) 에서 `{"frame":N,"name":"…"}` NUL종단 JSON cstring 마커 추출(파일 순서).
    static func trailerEvents(bytes: [UInt8], from: Int, to: Int) -> [AnimationMarker] {
        let pat = [UInt8]("{\"frame\"".utf8)
        var out: [AnimationMarker] = []
        var i = from
        while i + pat.count <= to {
            guard bytes[i] == pat[0], Array(bytes[i ..< i + pat.count]) == pat else { i += 1; continue }
            var e = i
            let cap = min(bytes.count, i + 256)   // 이벤트 이름은 짧다(실측 ≤ 32B) — 폭주 방지 캡
            while e < cap, bytes[e] != 0 { e += 1 }
            if let obj = (try? JSONSerialization.jsonObject(with: Data(bytes[i ..< e]))) as? [String: Any],
               let name = obj["name"] as? String, let frame = (obj["frame"] as? NSNumber)?.floatValue {
                out.append(AnimationMarker(name: name, frame: frame))
            }
            i = e + 1
        }
        return out
    }

    /// stride-2 인덱스 순회 헬퍼.
    private static func stride16(_ size: Int) -> StrideTo<Int> { stride(from: 0, to: size, by: 2) }

    /// 메시 간 트레일러 파스: u8 0 | u8 count(≤16) | count×(u32 size | size 바이트) | u32 tail → 끝 오프셋.
    /// count=0 이면 정확히 6바이트(종전 구분자와 동일). 패턴 불일치는 nil(호출측 +6 폴백).
    private static func meshTrailerEnd(bytes: [UInt8], at p: Int) -> Int? {
        guard p + 6 <= bytes.count, bytes[p] == 0 else { return nil }
        let count = Int(bytes[p + 1])
        guard count <= 16 else { return nil }
        var q = p + 2
        for _ in 0..<count {
            guard q + 4 <= bytes.count else { return nil }
            let size = Int(UInt32(bytes[q]) | (UInt32(bytes[q + 1]) << 8) | (UInt32(bytes[q + 2]) << 16) | (UInt32(bytes[q + 3]) << 24))
            guard size >= 0, size <= bytes.count - q - 8 else { return nil }
            q += 4 + size
        }
        return q + 4
    }

    /// 변종 정점 스트라이드 추론: 정점 블롭 직후의 인덱스 블롭(u32 크기 + u16 인덱스)에서
    /// maxIndex+1 = 정점 수로 보고 vSize/count. 정수가 아니거나 범위(20..96) 밖이면 nil(안전 실패).
    private static func inferStride(bytes: [UInt8], indexBlobAt p: Int, vSize: Int) -> Int? {
        guard let iSizeU = readU32LE(bytes, at: p), iSizeU > 0, iSizeU % 2 == 0 else { return nil }
        let iSize = Int(iSizeU)
        guard p + 4 + iSize <= bytes.count else { return nil }
        var maxIdx = 0
        var k = p + 4
        let end = p + 4 + iSize
        while k + 1 < end {
            let v = Int(bytes[k]) | (Int(bytes[k + 1]) << 8)
            if v > maxIdx { maxIdx = v }
            k += 2
        }
        let count = maxIdx + 1
        guard count > 0, vSize % count == 0 else { return nil }
        let s = vSize / count
        return (20...96).contains(s) ? s : nil
    }

    private static func findMagic(_ magic: String, in bytes: [UInt8], from: Int) -> Int? {
        let m = [UInt8](magic.utf8)
        guard m.count > 0, from >= 0 else { return nil }
        var i = from
        let end = bytes.count - m.count
        while i <= end {
            if bytes[i] == m[0] {
                var match = true
                for j in 1..<m.count where bytes[i + j] != m[j] { match = false; break }
                if match { return i }
            }
            i += 1
        }
        return nil
    }
}
