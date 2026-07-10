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
/// "MDLA0001" | u8 0 | u32 다음오프셋(=EOF-1, 실측 일치) | u32 애니수 | u32 id | u32 0 |
///   애니별: cstring 이름 | cstring 모드(loop/mirror/single) | f32 fps | u32 길이(프레임) | u32 0 |
///   u32 본수 | u32 0 | 본별: u32 트랙크기 | 키×36B(pos 3f, 각 3f, 스케일 3f — 프레임당 1키, 0..길이 포함) |
///   u32 블롭2크기(관측 0) | 블롭2
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

    public struct Key: Equatable {
        public let position: SIMD3<Float>
        public let angles: SIMD3<Float>   // 라디안 추정(z 회전 위주)
        public let scale: SIMD3<Float>
    }

    public struct Animation: Equatable {
        public let name: String
        public let mode: String           // loop | mirror | single (실측: "mirror")
        public let fps: Float
        public let lengthFrames: Int
        public let tracks: [[Key]]        // 본 인덱스별 키 배열(프레임당 1키), 빈 배열 = 정적 본
        /// 이벤트 마커(MDLV0023 컨테이너 퍼펫의 MDLA0006 트레일러 — Model3D.Animation.events 이식).
        /// 네이티브 MDLV0013(MDLA0001)은 코퍼스 이벤트 실측 0 — 항상 빈 배열.
        public var events: [AnimationMarker] = []
    }

    public let material: String
    public let vertices: [Vertex]
    public let indices: [UInt16]
    public var bones: [Bone] = []
    public var animations: [Animation] = []

    /// 매직으로 라우팅: MDLV0013 = 네이티브 2D 퍼펫; MDLV0016/0017/0019/0021/0023 = 3D 스키닝 모델
    /// 컨테이너로 저장된 2D 퍼펫(예: Hollow Knight 3598808038 knight, WLOP 3113287126 — 종전엔 매직
    /// 불일치로 거부→흑화면). Model3D 로 읽어 pos/boneIdx/wt/uv 만 취한 동형 모델로 변환.
    /// Model3D/Mesh3DShaders 는 읽기 전용(변환은 여기서).
    public static func parse(_ data: Data) -> PuppetModel? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, let magic = String(bytes: bytes[0..<8], encoding: .utf8) else { return nil }
        if magic.hasPrefix("MDLV"), magic != "MDLV0013" { return Model3D.parse(data).map(fromModel3D) }
        guard magic == "MDLV0013" else { return nil }
        return parseV0013(bytes)
    }

    /// MDLV0023(3D 스키닝 메시) → 2D 퍼펫 동형 변환. 서브메시를 정점 오프셋으로 이어붙여 단일 메시화
    /// (HK 퍼펫은 전부 단일 스키닝 서브메시). 정점 좌표계는 이미 레이어-로컬 픽셀·y-up 이라 별도 변환 불요.
    static func fromModel3D(_ m: Model3D) -> PuppetModel {
        var verts: [Vertex] = []
        var indices: [UInt16] = []
        var baseVertex = 0
        for mesh in m.meshes {
            for v in mesh.vertices {
                verts.append(Vertex(position: v.position, boneIndices: v.boneIndices, weights: v.weights, uv: v.uv))
            }
            for idx in mesh.indices {
                let gi = Int(idx) + baseVertex
                indices.append(gi <= 0xFFFF ? UInt16(gi) : 0)  // 2D 퍼펫은 정점 <65535 — 초과는 안전 클램프
            }
            baseVertex += mesh.vertices.count
        }
        var pm = PuppetModel(material: m.meshes.first?.material ?? "", vertices: verts, indices: indices)
        // 본 규약(name/parent/bind)은 2D 퍼펫과 동형 — 그대로 이식(정적 스킨은 애니 부재 시 항등이라 무해).
        pm.bones = m.bones.map { Bone(name: $0.name, parent: $0.parent, bind: $0.bind) }
        pm.animations = m.animations.map { anim in
            var a = Animation(name: anim.name, mode: anim.mode, fps: anim.fps, lengthFrames: anim.lengthFrames,
                              tracks: anim.tracks.map { track in
                                  track.map { Key(position: $0.position, angles: $0.angles, scale: $0.scale) }
                              })
            a.events = anim.events
            return a
        }
        return pm
    }

    private static func parseV0013(_ bytes: [UInt8]) -> PuppetModel? {
        guard bytes.count > 30 else { return nil }
        func u32(_ o: Int) -> UInt32? { readU32LE(bytes, at: o) }
        func f32(_ o: Int) -> Float? { u32(o).map { Float(bitPattern: $0) } }

        // 13B 헤더 스킵 → cstring 머티리얼(UTF-8 — CJK 경로 보존, 종전 Latin-1 은 mojibake).
        var o = 8 + 13
        guard let c = readCString(bytes, at: o) else { return nil }
        let mat = c.value
        o = c.next

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
                guard let n = readCString(bytes, at: o) else { return model }
                let name = n.value
                o = n.next
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

        // 애니메이션(있으면): "MDLA0001". 실패는 애니 없이 반환(정지 포즈 렌더 가능).
        if o + 8 <= bytes.count, String(bytes: bytes[o..<o+8], encoding: .utf8) == "MDLA0001" {
            o += 8 + 1  // magic + u8(0)
            guard let _ = u32(o), let animCount = u32(o + 4) else { return model }
            o += 16  // nextOff, count, id, 0
            var anims: [Animation] = []
            for _ in 0..<animCount {
                func cstr() -> String? {
                    guard let c = readCString(bytes, at: o) else { return nil }
                    o = c.next
                    return c.value
                }
                guard let name = cstr(), let mode = cstr(),
                      let fps = f32(o), let length = u32(o + 4), let boneCount = u32(o + 12) else { return model }
                o += 20  // fps, length, 0, boneCount, 0
                var tracks: [[Key]] = []
                for _ in 0..<boneCount {
                    guard let tSizeRaw = u32(o) else { return model }
                    o += 4
                    let tSize = Int(tSizeRaw)
                    guard tSize % 36 == 0, o + tSize <= bytes.count else { return model }
                    var keys: [Key] = []
                    keys.reserveCapacity(tSize / 36)
                    for k in stride(from: 0, to: tSize, by: 36) {
                        guard let px = f32(o + k), let py = f32(o + k + 4), let pz = f32(o + k + 8),
                              let ax = f32(o + k + 12), let ay = f32(o + k + 16), let az = f32(o + k + 20),
                              let sx = f32(o + k + 24), let sy = f32(o + k + 28), let sz = f32(o + k + 32)
                        else { return model }
                        keys.append(Key(position: SIMD3(px, py, pz), angles: SIMD3(ax, ay, az),
                                        scale: SIMD3(sx, sy, sz)))
                    }
                    o += tSize
                    guard let blob2Raw = u32(o) else { return model }
                    o += 4 + Int(blob2Raw)
                    tracks.append(keys)
                }
                anims.append(Animation(name: name, mode: mode, fps: fps,
                                       lengthFrames: Int(length), tracks: tracks))
            }
            model.animations = anims
        }
        return model
    }
}
