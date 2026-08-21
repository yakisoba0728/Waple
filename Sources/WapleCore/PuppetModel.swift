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
        /// 오일러 3축 — **파일 바이트 순서 그대로**(키 +0x0c, +0x10, +0x14)이고 그 의미는 (X, Y, Z) 다.
        /// WE 로더가 이 셋을 반각(0.5f @ 0x1404926c0)으로 sin/cos 해 포즈 SoA 슬롯 3..6 (= w,x,y,z)
        /// 에 굽는데(0x140264188–0x1402642ae), 그 결과는 `Rz(+0x14)·Ry(+0x10)·Rx(+0x0c)` 다.
        /// 슬롯 순서의 근거(행렬→쿼터니언 0x140215730 이 스칼라부를 첫 칸에 쓴다)와 반증 이력은
        /// `PuppetPose.rotationQuaternion` 주석 단일 소스.
        /// 단위는 라디안(반각 계수가 0.5f 이지 π/360 이 아니다).
        public let angles: SIMD3<Float>
        public let scale: SIMD3<Float>
    }

    public struct Animation: Equatable {
        public let name: String
        /// 재생 모드. WE 가 실제로 인식하는 값은 `stricmp` 로 "mirror" / "single" 둘뿐이고
        /// 나머지(빈 문자열·"loop"·"clamp" 포함)는 전부 loop 다 — 0x1401a8c71 / 0x1401a8c87.
        public let mode: String
        public let fps: Float
        public let lengthFrames: Int
        public let tracks: [[Key]]        // 본 인덱스별 키 배열(프레임당 1키), 빈 배열 = 정적 본
        /// 이벤트 마커(MDLV0023 컨테이너 퍼펫의 MDLA0006 트레일러 — Model3D.Animation.events 이식).
        /// 네이티브 MDLV0013(MDLA0001)은 코퍼스 이벤트 실측 0 — 항상 빈 배열.
        public var events: [AnimationMarker] = []
        /// C③: 클립 고유 id — MDLV0023 등 컨테이너 퍼펫은 Model3D.Animation.id 이식(있으면), 네이티브
        /// MDLV0013(MDLA0001)은 클립별 id 필드가 없어 항상 nil(이름 휴리스틱 폴백 유지).
        public var id: Int? = nil
    }

    /// 부착점(씬 `attachment` 이름 본-슬롯 부착) — Model3D.Attachment 와 동형(컨테이너 경로에서 이식).
    /// 네이티브 MDLV0013 은 코퍼스 attachment 28씬 전수가 컨테이너형이라 MDAT 미탐(실측 0건).
    public typealias Attachment = Model3D.Attachment

    public let material: String
    public let vertices: [Vertex]
    public let indices: [UInt16]
    public var bones: [Bone] = []
    public var animations: [Animation] = []
    public var attachments: [Attachment] = []

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
            // 2D 퍼펫 인덱스는 u16 — 병합 정점이 0xFFFF 를 넘으면 0 클램프(정점 0 으로 찌그러진
            // 삼각형 = 메시 손상) 대신 초과 삼각형을 통째로 드롭한다(실물은 전부 단일메시라 미발동,
            // 방어 수준). 삼각형 단위 드롭이라 인덱스 나열의 %3 정합은 보존.
            var k = 0
            while k + 2 < mesh.indices.count {
                let a = Int(mesh.indices[k]) + baseVertex
                let b = Int(mesh.indices[k + 1]) + baseVertex
                let c = Int(mesh.indices[k + 2]) + baseVertex
                if a <= 0xFFFF, b <= 0xFFFF, c <= 0xFFFF {
                    indices.append(UInt16(a)); indices.append(UInt16(b)); indices.append(UInt16(c))
                }
                k += 3
            }
            while k < mesh.indices.count {   // %3 잔여(비정형) — 피팅하면 보존, 아니면 드롭
                let a = Int(mesh.indices[k]) + baseVertex
                if a <= 0xFFFF { indices.append(UInt16(a)) }
                k += 1
            }
            baseVertex += mesh.vertices.count
        }
        var pm = PuppetModel(material: m.meshes.first?.material ?? "", vertices: verts, indices: indices)
        // 본 규약(name/parent/bind)은 2D 퍼펫과 동형 — 그대로 이식(정적 스킨은 애니 부재 시 항등이라 무해).
        pm.bones = m.bones.map { Bone(name: $0.name, parent: $0.parent, bind: $0.bind) }
        pm.attachments = m.attachments
        pm.animations = m.animations.map { anim in
            var a = Animation(name: anim.name, mode: anim.mode, fps: anim.fps, lengthFrames: anim.lengthFrames,
                              tracks: anim.tracks.map { track in
                                  track.map { Key(position: $0.position, angles: $0.angles, scale: $0.scale) }
                              })
            a.events = anim.events
            a.id = anim.id   // C③: Model3D 클립 id 이식(있으면) — id 기반 클립 선택의 근거.
            return a
        }
        return pm
    }

    /// 바이트 배열에서 리틀엔디안 float4x4 (64B, 열 우선) 디코드. Model3D.readFloat4x4 과 동일 로직이나
    /// 접근수준 분리(private) — BinaryReading 으로 끌어올리면 TexImage 등과의 의존이 얽혀 별도 유지.
    private static func readFloat4x4(_ bytes: [UInt8], at o: Int) -> simd_float4x4? {
        guard o >= 0, o + 64 <= bytes.count else { return nil }
        func f(_ p: Int) -> Float? { readU32LE(bytes, at: p).map { Float(bitPattern: $0) } }
        guard let c0x = f(o),      let c0y = f(o + 4),  let c0z = f(o + 8),  let c0w = f(o + 12),
              let c1x = f(o + 16), let c1y = f(o + 20), let c1z = f(o + 24), let c1w = f(o + 28),
              let c2x = f(o + 32), let c2y = f(o + 36), let c2z = f(o + 40), let c2w = f(o + 44),
              let c3x = f(o + 48), let c3y = f(o + 52), let c3z = f(o + 56), let c3w = f(o + 60)
        else { return nil }
        return simd_float4x4(SIMD4(c0x, c0y, c0z, c0w), SIMD4(c1x, c1y, c1z, c1w),
                             SIMD4(c2x, c2y, c2z, c2w), SIMD4(c3x, c3y, c3z, c3w))
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
        // 오탐 방어(2026-07-28): 후보 수용 전에 그 직후 인덱스 블롭(u32 iSize + u16 인덱스, iSize>0,
        // %2==0, maxIndex+1 ≤ 정점수)까지 검증 — 미상 필드가 우연히 %52==0(z-flag≠0 등)이면 종전엔
        // 그것을 vSize 로 오인해 이후 iSize 가드에서 모델 전체가 드롭됐다. 불일치 후보는 제외하고 계속 탐색.
        var vSize: Int? = nil
        var probe = o
        while probe <= o + 16, probe + 4 <= bytes.count {
            if let v = u32(probe), v > 0, v % 52 == 0, Int(v) <= bytes.count - probe - 4 {
                let vs = Int(v)
                let iOff = probe + 4 + vs
                if let iSizeU = u32(iOff), iSizeU > 0, iSizeU % 2 == 0,
                   iOff + 4 + Int(iSizeU) <= bytes.count {
                    var maxIdx = -1
                    var k = iOff + 4
                    let iEnd = iOff + 4 + Int(iSizeU)
                    while k + 1 < iEnd {
                        maxIdx = max(maxIdx, Int(bytes[k]) | (Int(bytes[k + 1]) << 8))
                        k += 2
                    }
                    if maxIdx < vs / 52 { vSize = vs; o = probe + 4; break }
                }
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
        // F441: Model3D.swift:255 와 동일한 인덱스 상한 검증 — 손상된 인덱스 블롭은 소비처가 범위 밖을
        // 스킵해 플랫 삼각형 경계가 전부 어긋나므로(메시 붕괴), 파스 실패(→ 폴터 쿼드)가 낫다.
        if let maxIndex = indices.max(), Int(maxIndex) >= vCount { return nil }

        var model = PuppetModel(material: mat, vertices: vertices, indices: indices)
        // 스켈레톤(있으면): "MDLS0001" 섹션. 실패는 본 없이 반환(정지 메시 렌더는 가능).
        if o + 8 <= bytes.count, String(bytes: bytes[o..<o+8], encoding: .utf8) == "MDLS0001" {
            o += 8 + 1  // magic + lead u8(0)
            // Model3D.swift:569 와 동일한 본 수 상한(100k). 손상 헤더의 거대 boneCount 가 그대로 루프
            // 상한이 되면 readCString/u32 실패로 빠져나올 때까지 헛돈다 — 상한 초과는 본 없이 반환
            // (정지 메시 렌더 가능; 아래 개별 실패 경로와 같은 정책).
            // 참고: WE 엔진 자체는 본 128개에서 하드 실패한다(RE 분석). 그 의미론을 여기 들이지 않고
            // Model3D 와의 정합만 맞춘다 — 새 한계를 발명하지 않는다.
            guard let _ = u32(o), let boneCount = u32(o + 4), boneCount < 100_000 else { return model }
            o += 8
            var bones: [Bone] = []
            for _ in 0..<boneCount {
                guard let n = readCString(bytes, at: o) else { return model }
                let name = n.value
                o = n.next
                guard let _ = u32(o), let parentRaw = u32(o + 4), let msz = u32(o + 8), msz == 64,
                      o + 12 + 64 + 1 <= bytes.count else { return model }
                o += 12
                guard let bindMat = readFloat4x4(bytes, at: o) else { return model }
                o += 64 + 1  // matrix + pad
                bones.append(Bone(name: name, parent: Int32(bitPattern: parentRaw), bind: bindMat))
            }
            model.bones = bones
        }

        // 애니메이션(있으면): "MDLA0001". 섹션 헤더 실패는 애니 없이 반환(정지 포즈 렌더 가능).
        // 개별 애니 파스 실패는 그 애니만 버리고(break) 누적 완료분은 유지 — Model3D.swift:407,435 의
        // 부분 실패 정책과 정합(감사 V06: 종전 return model 은 파스 완료분까지 전량 폐기했다).
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
                      let fps = f32(o), let length = u32(o + 4), let boneCount = u32(o + 12) else { break }
                o += 20  // fps, length, 0, boneCount, 0
                var tracks: [[Key]] = []
                var ok = true
                for _ in 0..<boneCount {
                    guard let tSizeRaw = u32(o) else { ok = false; break }
                    o += 4
                    let tSize = Int(tSizeRaw)
                    guard tSize % 36 == 0, o + tSize <= bytes.count else { ok = false; break }
                    var keys: [Key] = []
                    keys.reserveCapacity(tSize / 36)
                    for k in stride(from: 0, to: tSize, by: 36) {
                        guard let px = f32(o + k), let py = f32(o + k + 4), let pz = f32(o + k + 8),
                              let ax = f32(o + k + 12), let ay = f32(o + k + 16), let az = f32(o + k + 20),
                              let sx = f32(o + k + 24), let sy = f32(o + k + 28), let sz = f32(o + k + 32)
                        else { ok = false; break }
                        keys.append(Key(position: SIMD3(px, py, pz), angles: SIMD3(ax, ay, az),
                                        scale: SIMD3(sx, sy, sz)))
                    }
                    if !ok { break }
                    o += tSize
                    guard let blob2Raw = u32(o) else { ok = false; break }
                    o += 4 + Int(blob2Raw)
                    tracks.append(keys)
                }
                guard ok, tracks.count == Int(boneCount) else { break }  // 부분 애니는 드롭, 누적분 유지
                anims.append(Animation(name: name, mode: mode, fps: fps,
                                       lengthFrames: Int(length), tracks: tracks))
            }
            model.animations = anims
        }
        return model
    }
}
