import Foundation
import simd

/// WE 3D 모델(MDLV0023) 파서 — 실측 리버스(설계 2026-07-03).
/// 코퍼스: 3737268876(젤다 OoT/MM, 100개), 3706286085(Sonic, 5개), 3662790108(태양계, 69개) — 174개 전수 MDLV0023.
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
    }

    public let meshes: [Mesh]
    public var bones: [Bone] = []
    /// MDLA0006 애니 섹션 존재 여부(매직 탐지 — animations 가 비어도 마커는 true).
    public var hasAnimation: Bool = false
    /// 파스된 애니메이션(순서 = 파일 순서). 렌더러가 animationlayers 로 활성 애니를 선택.
    public var animations: [Animation] = []

    /// 스키닝 정점 포맷 비트(formatFlag & 이 마스크 != 0 → 본/웨이트 존재, stride 80).
    private static let skinMask: UInt32 = 0x0180_0000
    private static let staticStride = 48
    private static let skinnedStride = 80

    public static func parse(_ data: Data) -> Model3D? {
        let bytes = [UInt8](data)
        guard bytes.count > 21, String(bytes: bytes[0..<8], encoding: .utf8) == "MDLV0023" else { return nil }

        func u32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= bytes.count else { return nil }
            return UInt32(bytes[o]) | (UInt32(bytes[o + 1]) << 8) | (UInt32(bytes[o + 2]) << 16) | (UInt32(bytes[o + 3]) << 24)
        }
        func f32(_ o: Int) -> Float? { u32(o).map { Float(bitPattern: $0) } }
        func cstring(_ o: inout Int) -> String? {
            // UTF-8 디코드 필수: 실물 머티리얼 경로가 CJK("materials/models/太空球/…")를 포함 —
            // 바이트별 UnicodeScalar(Latin-1) 해석은 mojibake 가 되어 pkg 엔트리 조회가 실패한다.
            let start = o
            while o < bytes.count, bytes[o] != 0 { o += 1 }
            guard o < bytes.count else { return nil }
            let s = String(decoding: bytes[start..<o], as: UTF8.self)
            o += 1
            return s
        }

        // 헤더: magic(8) | u8 0 | u32 formatFlag(9) | u32(=1, 13) | u32 meshCount(17)
        guard let meshCount = u32(17), meshCount > 0, meshCount < 100_000 else { return nil }
        var o = 21
        var meshes: [Mesh] = []
        meshes.reserveCapacity(Int(meshCount))

        for mi in 0..<Int(meshCount) {
            guard let material = cstring(&o) else { return nil }
            guard let _ = u32(o) else { return nil }             // u32(=0)
            o += 4
            // AABB(min xyz, max xyz)
            guard let minx = f32(o), let miny = f32(o + 4), let minz = f32(o + 8),
                  let maxx = f32(o + 12), let maxy = f32(o + 16), let maxz = f32(o + 20) else { return nil }
            o += 24
            guard let formatFlag = u32(o) else { return nil }
            o += 4
            let skinned = (formatFlag & skinMask) != 0
            var stride = skinned ? skinnedStride : staticStride
            guard let vSizeRaw = u32(o) else { return nil }
            o += 4
            let vSize = Int(vSizeRaw)
            guard vSize > 0, o + vSize <= bytes.count else { return nil }
            // 변종 스트라이드 자기기술 추론(2026-07-06, 실물 sl_puppet.mdl = 84 = 기지 80 + 미상 4B,
            // 플래그 0x181000e): 표 스트라이드로 안 나눠지면 인덱스 블롭의 maxIndex+1 을 정점 수로 보고
            // vSize/count 가 정수(44..96)면 채택. 필드는 꼬리 고정(uv@-8, weights@-24, bones@-40 —
            // 기지 80/48 과 동일 오프셋이라 무회귀), 중간(normal/tangent)은 고전 오프셋(unlit 미사용).
            if vSize % stride != 0 {
                guard let inferred = inferStride(bytes: bytes, indexBlobAt: o + vSize, vSize: vSize),
                      inferred >= (skinned ? 76 : 48) else { return nil }
                stride = inferred
            }
            guard vSize % stride == 0 else { return nil }
            let vCount = vSize / stride

            var vertices: [Vertex] = []
            vertices.reserveCapacity(vCount)
            for vi in 0..<vCount {
                let b = o + vi * stride
                guard let px = f32(b), let py = f32(b + 4), let pz = f32(b + 8),
                      let nx = f32(b + 12), let ny = f32(b + 16), let nz = f32(b + 20),
                      let tx = f32(b + 24), let ty = f32(b + 28), let tz = f32(b + 32), let tw = f32(b + 36)
                else { return nil }
                let pos = SIMD3<Float>(px, py, pz)
                let nrm = SIMD3<Float>(nx, ny, nz)
                let tan = SIMD4<Float>(tx, ty, tz, tw)
                if skinned {
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
                               skinned: skinned, vertices: vertices, indices: indices))

            // 메시 사이 6바이트 구분자(실측 전수 0). 마지막 메시 뒤에는 없음.
            if mi < Int(meshCount) - 1 { o += 6 }
        }

        var model = Model3D(meshes: meshes)

        // 스켈레톤(스키닝 모델). 선행 0 패딩 스킵. 실패는 본 없이 반환(정적 메시 렌더 가능).
        var p = o
        while p < bytes.count, bytes[p] == 0 { p += 1 }
        if p + 9 <= bytes.count, String(bytes: bytes[p..<p+8], encoding: .utf8) == "MDLS0004" {
            p += 8 + 1  // magic + lead u8(0)
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

        // 애니 섹션(MDLA0006) — 스켈레톤 유무와 무관하게 메시 끝 이후 탐색(스키닝 모델만 존재).
        if let ai = findMagic("MDLA0006", in: bytes, from: o) {
            model.hasAnimation = true
            model.animations = parseAnimations(bytes: bytes, at: ai, boneCount: model.bones.count)
        }

        return model
    }

    private static let animModes: Set<String> = ["loop", "single", "mirror", "clamp"]

    /// MDLA0006 애니 파스(리싱크 기반). 헤더 animCount 는 link_adult 반례로 불신 —
    /// 각 애니 뒤 가변 트레일러(32~39B AABB+id)를 다음 유효 헤더 리싱크(≤256B)로 스킵하고,
    /// 헤더 검증(모드∈집합, fps∈(0,240], 본수==skeleton)으로 종료를 판정한다.
    private static func parseAnimations(bytes: [UInt8], at magicOff: Int, boneCount: Int) -> [Model3D.Animation] {
        guard boneCount > 0 else { return [] }
        func u32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= bytes.count else { return nil }
            return UInt32(bytes[o]) | (UInt32(bytes[o + 1]) << 8) | (UInt32(bytes[o + 2]) << 16) | (UInt32(bytes[o + 3]) << 24)
        }
        func f32(_ o: Int) -> Float? { u32(o).map { Float(bitPattern: $0) } }
        func cstring(_ o: Int) -> (String, Int)? {
            var e = o
            while e < bytes.count, bytes[e] != 0 { e += 1 }
            guard e < bytes.count else { return nil }
            return (String(decoding: bytes[o..<e], as: UTF8.self), e + 1)
        }
        // 애니 헤더 시도: 성공 시 (이름,모드,fps,길이,본수,본트랙시작오프셋).
        func tryHeader(_ p: Int) -> (name: String, mode: String, fps: Float, length: Int, bc: Int, off: Int)? {
            guard let (name, p2) = cstring(p), !name.isEmpty, name.utf8.count <= 96 else { return nil }
            guard let (mode, p3) = cstring(p2), animModes.contains(mode) else { return nil }
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
            anims.append(Animation(name: h.name, mode: h.mode, fps: h.fps, lengthFrames: h.length, tracks: tracks))
            // 리싱크: 가변 트레일러를 건너뛰고 다음 유효 헤더로(≤256B). 없으면 종료.
            var next: Int? = nil
            var d = 0
            while d <= 256 {
                if tryHeader(o + d) != nil { next = o + d; break }
                d += 1
            }
            guard let n = next else { break }
            o = n
        }
        return anims
    }

    /// stride-2 인덱스 순회 헬퍼.
    private static func stride16(_ size: Int) -> StrideTo<Int> { stride(from: 0, to: size, by: 2) }

    /// 변종 정점 스트라이드 추론: 정점 블롭 직후의 인덱스 블롭(u32 크기 + u16 인덱스)에서
    /// maxIndex+1 = 정점 수로 보고 vSize/count. 정수가 아니거나 범위(44..96) 밖이면 nil(안전 실패).
    private static func inferStride(bytes: [UInt8], indexBlobAt p: Int, vSize: Int) -> Int? {
        func u32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= bytes.count else { return nil }
            return Int(UInt32(bytes[o]) | (UInt32(bytes[o + 1]) << 8) | (UInt32(bytes[o + 2]) << 16) | (UInt32(bytes[o + 3]) << 24))
        }
        guard let iSize = u32(p), iSize > 0, iSize % 2 == 0, p + 4 + iSize <= bytes.count else { return nil }
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
        return (44...96).contains(s) ? s : nil
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
