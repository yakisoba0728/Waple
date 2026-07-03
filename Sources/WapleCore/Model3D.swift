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
///   • 애니: "MDLA0006" (+선행 "MDAT0001") — 존재만 탐지(미해독), 2D 는 "MDLA0001".
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

    /// 스켈레톤 본(스키닝 모델만). 좌표계·부모 규약은 2D 퍼펫과 동일.
    public struct Bone: Equatable {
        public let name: String
        public let parent: Int32               // -1 = 루트
        public let bind: simd_float4x4         // 바인드(모델→본) 행렬
        public let properties: String          // 대개 "" — 일부 본은 리깅툴 IK 설정 JSON
    }

    public let meshes: [Mesh]
    public var bones: [Bone] = []
    /// MDLA0006 애니 섹션 존재 여부(포맷 미해독 — 렌더러는 정적 포즈로 처리).
    public var hasAnimation: Bool = false

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
            let stride = skinned ? skinnedStride : staticStride
            guard let vSizeRaw = u32(o) else { return nil }
            o += 4
            let vSize = Int(vSizeRaw)
            guard vSize > 0, vSize % stride == 0, o + vSize <= bytes.count else { return nil }
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
                    guard let b0 = u32(b + 40), let b1 = u32(b + 44), let b2 = u32(b + 48), let b3 = u32(b + 52),
                          let w0 = f32(b + 56), let w1 = f32(b + 60), let w2 = f32(b + 64), let w3 = f32(b + 68),
                          let u = f32(b + 72), let v = f32(b + 76) else { return nil }
                    vertices.append(Vertex(position: pos, normal: nrm, tangent: tan, uv: SIMD2(u, v),
                                           boneIndices: SIMD4(b0, b1, b2, b3), weights: SIMD4(w0, w1, w2, w3)))
                } else {
                    guard let u = f32(b + 40), let v = f32(b + 44) else { return nil }
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
            // 애니 섹션(MDLA0006) 존재 여부만 표기 — 포맷 미해독.
            if findMagic("MDLA0006", in: bytes, from: o) != nil { model.hasAnimation = true }
        }

        return model
    }

    /// stride-2 인덱스 순회 헬퍼.
    private static func stride16(_ size: Int) -> StrideTo<Int> { stride(from: 0, to: size, by: 2) }

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
