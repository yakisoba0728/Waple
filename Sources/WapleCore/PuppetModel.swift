import Foundation
import simd

/// WE 2D 퍼펫 모델(MDLV0013) 파서 — 실측 리버스(설계 2026-07-03, sample: 2809885105).
///
/// 레이아웃:
/// "MDLV0013" | 13B 헤더 | cstring 머티리얼 | u32(미상, 관측값 0)
/// u32 정점블롭크기 | 정점×N (stride 52 = pos 3f, 본인덱스 4×u32, 웨이트 4f, uv 2f)
/// u32 인덱스블롭크기 | u16 인덱스(트라이앵글 리스트)
/// "MDLS0001" | u8 0 | u32 다음섹션오프셋(=MDLA 위치, 실측 일치 검증) | u32 본수 |
///   본별: cstring 이름 | u32 flags | i32 부모(-1=루트) | u32 행렬크기(64) | float4x4 바인드 | u8 0
/// "MDLA0001" 애니메이션(phase 3) ...
///
/// 미상 필드는 관용 처리: 정점 블롭은 cstring 이후 16바이트 내에서 `%52==0 && 잔여 이내` u32 를 탐색.
public struct PuppetModel: Equatable {
    public struct Vertex: Equatable {
        public let position: SIMD3<Float>
        public let boneIndices: SIMD4<UInt32>
        public let weights: SIMD4<Float>
        public let uv: SIMD2<Float>
    }

    public struct Bone: Equatable {
        public let name: String
        public let parent: Int32          // -1 = 루트
        public let bind: simd_float4x4    // 바인드(모델→본) 행렬 — 실측: 평행이동 위주
    }

    public let material: String
    public let vertices: [Vertex]
    public let indices: [UInt16]
    public var bones: [Bone] = []

    public static func parse(_ data: Data) -> PuppetModel? {
        let bytes = [UInt8](data)
        guard bytes.count > 30, String(bytes: bytes[0..<8], encoding: .utf8) == "MDLV0013" else { return nil }
        func u32(_ o: Int) -> UInt32? {
            guard o + 4 <= bytes.count else { return nil }
            return UInt32(bytes[o]) | (UInt32(bytes[o + 1]) << 8) | (UInt32(bytes[o + 2]) << 16) | (UInt32(bytes[o + 3]) << 24)
        }
        func f32(_ o: Int) -> Float? { u32(o).map { Float(bitPattern: $0) } }

        // 13B 헤더 스킵 → cstring 머티리얼.
        var o = 8 + 13
        guard o < bytes.count else { return nil }
        var mat = ""
        while o < bytes.count, bytes[o] != 0 {
            mat.append(Character(UnicodeScalar(bytes[o])))
            o += 1
        }
        guard o < bytes.count else { return nil }
        o += 1  // '\0'

        // 정점 블롭 크기: 이후 16바이트 내 관용 탐색(%52==0, 0<size≤잔여). 미상 u32(0) 등을 건너뛴다.
        var vSize: Int? = nil
        var probe = o
        while probe <= o + 16, probe + 4 <= bytes.count {
            if let v = u32(probe), v > 0, v % 52 == 0, Int(v) <= bytes.count - probe - 4 {
                vSize = Int(v); o = probe + 4; break
            }
            probe += 4
        }
        guard let vertexBytes = vSize else { return nil }
        let vCount = vertexBytes / 52
        var vertices: [Vertex] = []
        vertices.reserveCapacity(vCount)
        for i in 0..<vCount {
            let b = o + i * 52
            guard let px = f32(b), let py = f32(b + 4), let pz = f32(b + 8),
                  let b0 = u32(b + 12), let b1 = u32(b + 16), let b2 = u32(b + 20), let b3 = u32(b + 24),
                  let w0 = f32(b + 28), let w1 = f32(b + 32), let w2 = f32(b + 36), let w3 = f32(b + 40),
                  let u = f32(b + 44), let v = f32(b + 48) else { return nil }
            vertices.append(Vertex(position: SIMD3(px, py, pz),
                                   boneIndices: SIMD4(b0, b1, b2, b3),
                                   weights: SIMD4(w0, w1, w2, w3),
                                   uv: SIMD2(u, v)))
        }
        o += vertexBytes

        guard let iSizeRaw = u32(o) else { return nil }
        o += 4
        let iSize = Int(iSizeRaw)
        guard iSize % 2 == 0, o + iSize <= bytes.count else { return nil }
        var indices: [UInt16] = []
        indices.reserveCapacity(iSize / 2)
        for i in stride(from: 0, to: iSize, by: 2) {
            indices.append(UInt16(bytes[o + i]) | (UInt16(bytes[o + i + 1]) << 8))
        }
        o += iSize

        var model = PuppetModel(material: mat, vertices: vertices, indices: indices)
        // 스켈레톤(있으면): "MDLS0001" 섹션. 실패는 본 없이 반환(정지 메시 렌더는 가능).
        if o + 8 <= bytes.count, String(bytes: bytes[o..<o+8], encoding: .utf8) == "MDLS0001" {
            o += 8 + 1  // magic + lead u8(0)
            guard let _ = u32(o), let boneCount = u32(o + 4) else { return model }
            o += 8
            var bones: [Bone] = []
            for _ in 0..<boneCount {
                var name = ""
                while o < bytes.count, bytes[o] != 0 { name.append(Character(UnicodeScalar(bytes[o]))); o += 1 }
                guard o < bytes.count else { return model }
                o += 1
                guard let _ = u32(o), let parentRaw = u32(o + 4), let msz = u32(o + 8), msz == 64,
                      o + 12 + 64 + 1 <= bytes.count else { return model }
                o += 12
                var cols: [SIMD4<Float>] = []
                for c in 0..<4 {
                    guard let x = f32(o + c * 16), let y = f32(o + c * 16 + 4),
                          let z = f32(o + c * 16 + 8), let w = f32(o + c * 16 + 12) else { return model }
                    cols.append(SIMD4(x, y, z, w))
                }
                o += 64 + 1  // matrix + pad
                bones.append(Bone(name: name, parent: Int32(bitPattern: parentRaw),
                                  bind: simd_float4x4(cols[0], cols[1], cols[2], cols[3])))
            }
            model.bones = bones
        }
        return model
    }
}
