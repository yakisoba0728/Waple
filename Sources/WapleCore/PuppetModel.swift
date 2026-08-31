import Foundation
import simd

/// WE 2D 퍼펫 모델(MDLV0013) 파서 — 실측 리버스(설계 2026-07-03, sample: 2809885105).
///
/// 레이아웃:
/// "MDLV0013" | 13B 헤더 | cstring 머티리얼 | u32(미상, 관측값 0)
/// u32 정점블롭크기 | 정점×N (stride 52 = pos 3f, 본인덱스 4×u32, 웨이트 4f, uv 2f)
/// u32 인덱스블롭크기 | u16 인덱스(트라이앵글 리스트)
/// "MDLS0001" | u8 0 | u32 다음섹션오프셋(=MDLA 위치, 실측 일치 검증) | u32 본수 |
///   본별: cstring 이름 | u32 flags | i32 부모(-1=루트) | u32 행렬크기(64) | float4x4 로컬 레스트 |
///        cstring 본제약config(실물 전건 빈 문자열 = 1바이트 NUL)
/// "MDLA0001" | u8 0 | u32 다음오프셋(=EOF-1, 실측 일치) | u32 애니수 |
///   애니별: **u64 id** | cstring 이름 | cstring 모드(loop/mirror/single) | f32 fps |
///   u32 frameCount | u32 flags | u32 본수 |
///   본별: u32 trackFlags | u32 트랙크기 | 키×36B(pos 3f, 각 3f, 스케일 3f — 프레임당 1키, 키수=frameCount+1) |
///   u32 이벤트수 | 이벤트별 f32 time + cstring JSON(`{"frame":N,"name":"…"}`)
/// (MDLA 프레이밍은 2026-08-21 에 엔진 0x140263968–0x140263cb2 선형 디스어셈으로 정정했다.
///  종전 모델의 "u32 id | u32 0" 은 클립0 의 u64 id 였고 "u32 블롭2크기" 는 다음 본의 trackFlags 였다 —
///  자세한 근거와 v≥2..v≥6 게이트 블록은 docs/re/skeleton-animation.md §6.)
///
/// 미상 필드는 관용 처리: 정점 블롭은 cstring 이후 16바이트 내에서 `%52==0 && 잔여 이내` u32 를 탐색.
public struct PuppetModel: Equatable {
    public struct Vertex: Equatable {
        public let position: SIMD3<Float>
        public let boneIndices: SIMD4<UInt32>
        public let weights: SIMD4<Float>
        public let uv: SIMD2<Float>
    }

    /// MDLS 본 레코드. WE 런타임 본 구조체는 **스트라이드 0xf0(240B)** 이고 파스 순서·오프셋은
    /// `0x140262530`–`0x1402625c0` 에서: 이름 cstring → `+0x64` u32 flags → `+0x60` i32 parent
    /// (`-1` = 루트, 계층 합성이 `cmp dword [rax+0x60], -1` @`0x1401fea5d` 로 이 필드를 본다) →
    /// `+0x20` 64바이트 행렬 → `+0x68` 본 제약 config(파서 `0x140265c30`).
    /// **본 수 상한은 128** — `cmp eax, 0x80` @`0x140262501` 를 넘으면 `int 0x29`(__fastfail,
    /// `0x14026250a`)로 즉사한다. Waple 은 즉사하지 않고 그대로 읽는다(관용, 의도적 발산).
    public struct Bone: Equatable {
        public let name: String
        public let parent: Int32          // -1 = 루트
        /// **부모상대 로컬 레스트 변환**(모델→본 역바인드가 아니다). 근거 둘:
        ///   · 시딩 루프 `0x1401fe2f2`–`0x1401fe657` 가 이 행렬(`bone+0x20`)을 TRS 로 분해해
        ///     포즈 SoA 를 채우고, 계층 합성 `0x1401fea10`–`0x1401feadf` 가 그 자리에 다시
        ///     `world[i] = world[parent] ∘ local[i]` 를 돌린다 — 역바인드면 체인 합성이 무의미하다.
        ///   · 코퍼스 실측(2809885105): 트랙 첫 키의 평행이동이 이 행렬의 평행이동과 일치한다.
        ///     키는 부모상대 로컬이므로 이 행렬도 같은 공간이다.
        /// 모델공간 바인드는 `PuppetPose.bindWorlds` 가 부모 체인으로 합성해서 만든다.
        /// (종전 주석은 "바인드(모델→본) 행렬" 이라고 적고 있었는데 코드가 하는 일과 반대였다.)
        public let bind: simd_float4x4
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
        /// 이벤트 마커. MDLA 이벤트 블록은 버전 게이트 밖이라 MDLA0001/0003...0006 모두 같은 형식이다.
        /// 네이티브 MDLV0013 코퍼스의 저작 이벤트는 0건이지만, 형식상 빈 배열로 고정하지 않는다.
        public var events: [AnimationMarker] = []
        /// C③: 클립 고유 id — MDLV0023 등 컨테이너 퍼펫은 Model3D.Animation.id 이식(있으면).
        /// **[2026-08-21 정정]** 네이티브 MDLV0013(MDLA0001)에도 클립별 id 는 있다 — 클립 레코드
        /// **선두의 u64**다(리더 0x1402616b0 = readU64, 호출 0x1402639de, 저장 위치 = 클립 오브젝트 +0x00).
        /// 종전 주석은 "id 필드가 없어 항상 nil" 이라고 적고 있었는데, 실제로는 그 u64 의 하위 32비트를
        /// **섹션 헤더의 필드로 오인**해 읽고 버리고 있었다(§6). 이제 채운다 — `clipIndex(clipId:)` 가
        /// 이름 휴리스틱보다 먼저 이 값을 본다. u64 가 Int 범위를 넘으면 nil(이름 폴백 유지).
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
        // F441: Model3D 의 인덱스 상한 검증과 동일 — 그쪽 site 는 `parse` 안의
        // `if let maxIndex = indices.max(), Int(maxIndex) >= vCount { return nil }` 다.
        // 손상된 인덱스 블롭은 소비처가 범위 밖을 스킵해 플랫 삼각형 경계가 전부 어긋나므로
        // (메시 붕괴), 파스 실패(→ 폴터 쿼드)가 낫다.
        // **[정정 2026-08-30]** 종전 이 자리는 ~~`Model3D.swift:255 와 동일한 인덱스 상한 검증`~~
        // 이었다. :255 는 이제 MDLA `Key` 36바이트 산문이다 — 줄 번호가 드리프트했다.
        // 이 리포 관례대로 줄 번호 대신 조건식으로 적는다(그 조건식으로 grep 하면 바로 찾는다).
        if let maxIndex = indices.max(), Int(maxIndex) >= vCount { return nil }

        var model = PuppetModel(material: mat, vertices: vertices, indices: indices)
        // 스켈레톤(있으면): "MDLS0001" 섹션. 실패는 본 없이 반환(정지 메시 렌더는 가능).
        if o + 8 <= bytes.count, String(bytes: bytes[o..<o+8], encoding: .utf8) == "MDLS0001" {
            o += 8 + 1  // magic + lead u8(0)
            // 방어선 100k — 손상 헤더의 거대 boneCount 가 그대로 루프 상한이 되면 readCString/u32
            // 실패로 빠져나올 때까지 헛돈다. 상한 초과는 본 없이 반환(정지 메시 렌더 가능;
            // 아래 개별 실패 경로와 같은 정책).
            //
            // **이것은 Model3D 와의 정합이 아니라 의도적 발산이다.** WE 엔진은 본 128개를 넘으면
            // `cmp eax, 0x80` @`0x140262501` 뒤 `int 0x29`(__fastfail)로 즉사하고, Model3D 는 그것을
            // 그대로 좁혀 `Model3DFormat.maxBoneCount`(= 128)로 거른다. 이쪽은 즉사하지 않고 그대로
            // 읽는다 — 이 파일 머리말 `Bone` 주석의 "관용, 의도적 발산" 결정이 그것이다.
            // 그러므로 이 가드를 `Model3DFormat.maxBoneCount` 로 바꾸지 마라. 값을 바꾸는 것은
            // 그 결정을 뒤집는 것이고, 128 초과 MDLS 는 엔진이 즉사시키므로 실물에 존재할 수 없다.
            //
            // **[정정 2026-08-30]** 종전 이 자리는 ~~`Model3D.swift:569 와 동일한 본 수 상한(100k)`~~
            // + ~~`Model3D 와의 정합만 맞춘다`~~ 였다. 둘 다 거짓이다: (1) Model3D 는 2026-08-21 에
            // 상한을 100,000 → 128 로 좁혔으므로(`boneCount <= UInt32(Model3DFormat.maxBoneCount)`)
            // "동일한 상한" 이 성립하지 않는다. 이 주석은 2026-08-19(`8ebd9ff9`) 에 쓰였고 이틀 뒤
            // 반대쪽이 움직였는데 따라오지 않았다. (2) 인용한 :569 는 이제 `hasAABB` 대입이다.
            // 정합이 아니라 발산이라는 것이 사실이고, 그 발산은 이미 위 `Bone` 주석에 근거와 함께
            // 기록돼 있었다 — 여기서 "정합" 이라 적은 것이 그 기록과 모순됐다.
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
                o += 64
                // 행렬 뒤 1바이트는 패딩이 아니라 **본 제약 config cstring** 이다 — 엔진은 행렬 블롭
                // (0x140262573 r8d=0x40 → 크기접두 리더 0x1400d3ef0)을 읽은 직후 0x140262588 에서
                // cstring 을 하나 더 읽어 제약 파서 0x140265c30 에 넘긴다(키 블록 .rdata
                // 0x140492140–0x1404921f1: `gd m tf ik … blendtime`). 실물 2D 퍼펫은 이 문자열이 비어
                // 있어 종전의 "u8 0 패드" 와 바이트가 같았을 뿐이고, 비어 있지 않은 본이 하나라도 있으면
                // 종전 코드는 그 길이만큼 이후 전 오프셋이 밀렸다.
                guard let cfg = readCString(bytes, at: o) else { return model }
                o = cfg.next
                bones.append(Bone(name: name, parent: Int32(bitPattern: parentRaw), bind: bindMat))
            }
            model.bones = bones
        }

        // 애니메이션(있으면): "MDLA0001". 섹션 헤더 실패는 애니 없이 반환(정지 포즈 렌더 가능).
        // 개별 애니 파스 실패는 그 애니만 버리고(break) 누적 완료분은 유지 — Model3D.swift 의
        // parseAnimations 부분 실패 정책과 정합(감사 V06: 종전 return model 은 파스 완료분까지 전량 폐기했다).
        //
        // **프레이밍 정정(2026-08-21, docs/re/skeleton-animation.md §6).** 종전 모델은
        // "섹션 헤더에 u32 id | u32 0" 이 있고 본마다 "u32 트랙크기 | 트랙 | u32 블롭2크기 | 블롭2" 라고
        // 적고 있었다. 엔진(0x140263968–0x140263cb2 선형 디스어셈)은 그렇게 읽지 않는다:
        //   · 섹션 헤더는 `u32 nextOff | u32 animCount` 뿐이고(nextOff 리더 0x140261770 이 u32 하나,
        //     animCount 리더 0x14009c560 이 u32 하나),
        //   · **클립마다 선두에 u64 id** 가 온다(0x1402639de → 0x1402616b0 = readU64, 결과가
        //     클립 오브젝트 +0x00 에 저장된다. 생성자 0x140265a90 이 +0x08/+0x28 을 std::string 두 개로
        //     초기화하고 파서가 거기에 이름·모드를 쓴다),
        //   · 클립 헤더는 `f32 fps | u32 frameCount | u32 flags | u32 boneCount` **넷**이고
        //     (0x140263a1b/0x140263a2d/0x140263a3d/0x140263a4d),
        //   · 본 레코드는 `u32 trackFlags | u32 trackBytes | trackBytes` 다
        //     (0x140263aa7 이 첫 u32 를 r15d 로, 0x140263acb 이 둘째 u32 를 트랙 크기로 읽고
        //      0x140263afe 가 그만큼 커서를 민다).
        // 종전 모델이 실물에서 통했던 이유: 헤더의 마지막 "u32 0" 이 실은 **본0의 trackFlags** 였고,
        // 본마다 읽던 "블롭2크기" 가 실은 **다음 본의 trackFlags** 였다 — 그 값이 0 이면 위치가 우연히
        // 맞는다. 어긋나는 자리는 둘: (a) trackFlags ≠ 0 이면 그 값만큼 커서를 더 밀어 desync,
        // (b) 클립이 둘 이상이면 다음 클립의 u64 id 를 건너뛰지 않아 **두 번째 클립부터 전부 유실**된다.
        // trackFlags 비트0 은 엔진에서 클립 flags 에 0x80000000 을 세우는 데만 쓰이고(0x140263c9d)
        // 키 해석을 바꾸지 않으므로 여기서는 읽고 버린다.
        // MDLA0001 은 버전 1 이라 v≥2..v≥6 게이트 블록은 전부 꺼져 있다. 단 이벤트 블록은
        // 버전 게이트 밖이라 본 트랙 뒤의 `u32 count + count×(f32 time,cstring JSON)`을 항상 소비한다.
        if o + 8 <= bytes.count, String(bytes: bytes[o..<o+8], encoding: .utf8) == "MDLA0001" {
            o += 8 + 1  // magic + u8(0)
            guard let _ = u32(o), let animCount = u32(o + 4) else { return model }
            o += 8  // nextOff, animCount
            var anims: [Animation] = []
            for _ in 0..<animCount {
                func cstr() -> String? {
                    guard let c = readCString(bytes, at: o) else { return nil }
                    o = c.next
                    return c.value
                }
                // 클립 선두 u64 id. Int 로 안 들어가는 값(> Int.max)은 nil 로 떨어뜨린다(이름 폴백 유지).
                guard let idLo = u32(o), let idHi = u32(o + 4) else { break }
                o += 8
                let clipId = Int(exactly: UInt64(idHi) << 32 | UInt64(idLo))
                guard let name = cstr(), let mode = cstr(),
                      let fps = f32(o), let length = u32(o + 4), let boneCount = u32(o + 12) else { break }
                o += 16  // fps, frameCount, flags, boneCount
                var tracks: [[Key]] = []
                var ok = true
                for _ in 0..<boneCount {
                    guard let _ = u32(o), let tSizeRaw = u32(o + 4) else { ok = false; break }
                    o += 8  // trackFlags(읽고 버림), trackBytes
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
                    tracks.append(keys)
                }
                guard ok, tracks.count == Int(boneCount) else { break }  // 부분 애니는 드롭, 누적분 유지
                // 이벤트 블록은 MDLA 버전과 무관하다(0x14026536d count,
                // 0x1402653bd time, 0x1402653e0 JSON cstring). time은 JSON frame과 중복이라
                // 소비만 하고, 공개 마커 값은 다른 애니 경로와 같은 JSON payload를 정본으로 삼는다.
                guard let eventCount = u32(o), eventCount <= 4096 else { break }
                o += 4
                var events: [AnimationMarker] = []
                var eventsOK = true
                events.reserveCapacity(Int(eventCount))
                for _ in 0..<eventCount {
                    guard f32(o) != nil, let payload = readCString(bytes, at: o + 4) else {
                        eventsOK = false
                        break
                    }
                    o = payload.next
                    if let object = AssetJSON.dictionary(Data(payload.value.utf8)),
                       let eventName = object["name"] as? String,
                       let frame = (object["frame"] as? NSNumber)?.floatValue {
                        events.append(AnimationMarker(name: eventName, frame: frame))
                    }
                }
                guard eventsOK else { break }
                anims.append(Animation(name: name, mode: mode, fps: fps,
                                       lengthFrames: Int(length), tracks: tracks,
                                       events: events, id: clipId))
            }
            model.animations = anims
        }
        return model
    }
}
