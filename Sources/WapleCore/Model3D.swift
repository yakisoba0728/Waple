import Foundation
import simd

/// WE 3D 모델(MDLV0004/0014/0016/0017/0019/0021/0023) 파서 — 실측 리버스(설계 2026-07-03,
/// 구버전 2026-07-09, WE 번들 v0004/v0014 2026-08-20).
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
/// 버전 프레이밍(엔진 게이트 — Model3DFormat 참조): AABB v≥17 / per-mesh formatFlag v≥15 /
/// 메시 트레일러 v≥21 / gateWord v≥4. **v0004·v0014 는 셋 다 없다** — 메시 헤더가
/// `머티리얼×skinCount | u32 gateWord | u32 정점블롭크기` 로 곧장 이어지고 정점 포맷은
/// 헤더 오프셋 9 의 formatFlag 를 그대로 쓴다.
///
/// 레이아웃(리틀엔디안):
/// "MDLV0023" | u8 0 | u32 formatFlag | u32 skinCount | u32 meshCount
/// 서브메시×meshCount:
///   cstring 머티리얼 ×skinCount | u32(=0) | AABB(min 3f, max 3f = 24B) | u32 formatFlag | u32 정점블롭크기 |
///   정점×N | u32 인덱스블롭크기 | u16 트라이앵글 인덱스
///   [v≥21 메시 트레일러: u8 gateA[≠0: u32+u32 size+blob] | u8 gateB[≠0: u32 size+blob(16B×N)]
///    | (v≥23) u32 모프count+레코드 — 전부 0 이면 v23 은 정확히 6바이트(= 종전 '6×u8 0 구분자').
///    마지막 메시 뒤에도 존재. v<21 은 트레일러 부재(엔진 정본 :1214 v 게이트)]
/// (스키닝 모델) "MDLS0004" | u8 0 | u32 nextOff | u32 본수 |
///   본별: cstring 이름 | u32 flags | i32 부모 | u32 64 | float4x4 바인드 | cstring props |
///   꼬리 T1..T7(태그 레코드/게이트 mat4/제약/중첩 그룹/링크/(3f+mat4)×본수/u32×본수 ×2)
///   — parseSkeletonTail 로 파스해 skeletonTail 에 노출(파스·보존, 소비 보류). 레이아웃 상세는
///   SkeletonTail 주석 참조(디컴파일+어셈블리 대조, 실물 418파일 전수 착지 검증).
/// 파일 말미에는 단일 0x00 종단자(엔진 섹션 루프의 빈 cstring — 실물 418/418).
/// (스키닝 모델) "MDAT0001" 이름-본 부착점 섹션 — parseAttachments()로 파싱, "MDLA0006" 애니메이션 섹션.
///
/// 정점 포맷(formatFlag 하위 바이트 0x0f = pos+normal+tangent+uv; 비트 0x01800000 = 스키닝):
///   정적(stride 48): pos 3f | normal 3f | tangent 4f | uv 2f
///   스키닝(stride 80): pos 3f | normal 3f | tangent 4f | boneIndices 4×u32 | weights 4f | uv 2f
///
/// 확정 근거(교차검증): 174/174 파스; 단일메시 40개 전부 maxIndex == vertexCount-1;
///   vsize % stride == 0(전수); normal/tangent 단위길이·weights 합 1.0(3개 witness); 6바이트 구분자 전수 0.
///
/// S3-mdl(2026-07-27) 디컴파일 대조: wallpaper64.exe MDL 디코더 `FUN_140261950`(RVA 0x260950,
/// analysis/decompiled/all/…FUN_140261950.c) 바이트리더 트레이스(3302695207 人物_puppet.mdl 실물 대조)로
/// ⚠️ **이 이름은 Ghidra 주소공간이다 — 원본 바이너리에서는 `0x140261880`**(−0xD0).
/// Ghidra 가 매핑한 것이 rich header 주입본이라 디컴파일 산출물의 주소가 전부 208바이트 밀려 있다.
/// 원본 .pdata 14,792개 함수 시작 대조로 확인했다. `spec/engine/decompilation-provenance.json` 참조 —
/// 인용 39개 중 27개는 보정이 필요 없고 이것을 포함한 3개만 밀려 있다. 발견 자체는 실물
/// 바이트 트레이스로 확인된 것이므로 결론은 유효하다. 밀린 것은 **찾아가는 주소뿐**이다.
/// 헤더 3필드가 **정확히 offset 9 부터 시작하는 단일 u32 formatFlag**(문서 corpus_scan/mdl-format.md 의
/// "0x08 오프셋 lo/hi u16 쌍, hi=0x8000" 주장은 매직 cstring 리더가 byte8 의 NUL(=formatFlag 하위바이트
/// 우연 일치)을 종단문자로 소비해 이후 리드가 1바이트 밀리는 것을 못 잡은 오프바이원 — 우리 구현이 이미
/// 맞음, checklist match)임을 재확인. 버전 게이트(`if (iVar17 < 0x11)` 즉 <17 → AABB 없음)도 실행경로에서
/// 직접 대조(hasAABB = version >= 17 과 바이트 일치). 스켈레톤/애니 매직 디스패치(MDLS0004→MDLA0006→
/// MDAT0001→MDMP0001→MDLE0002)는 코드에 존재하나 meshCount>0(local_400≠0) 파일에서는 타지 않는 분기 —
/// 그 경로 자체가 "확인됨"은 아니고, 우리 매직-스캔 방식이 그와 **모순되지 않음**만 근거. MDLE0002 서브블록
/// 실측(코퍼스 다수 .mdl 바이트 직접 대조, 예 3463520581 8개 중 3개 보유): magic(8)|u8 0|u32 nextOff(=EOF-1)
/// |u32 byteSize|byteSize/64 개의 64B 강체변환(4x4, 대개 [0]=미세회전+평행이동, 이후는 순수평행이동) —
/// 퍼펫워프 에디터 핸들/핀 좌표로 추정(런타임 스키닝 무관: 미소비 상태로도 174/174 전수 파스+불변식 통과).
/// 결함 귀속 없음 + 게이트 씬 보유 → 구현 보류(추측 구현이 무기여 상태에서 게이트를 흔들 위험).
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
        // 원소 폭은 파일에서 u16/u32 로 갈리지만(정본 format.mdl.indexWidth) 저장은 u32 로 통일한다 —
        // 폭을 타입으로 들고 다니면 GPU 인덱스버퍼 바인딩까지 분기가 번지고, u16 메시가 압도적
        // 다수(실측 969/986)라 그 분기의 이득이 인덱스 메모리 2배보다 작다.
        public let indices: [UInt32]           // 트라이앵글 리스트(count % 3 == 0)
        /// 이 메시의 머티리얼 **전부**(= 헤더 skinCount 개, 스킨 = 같은 메시의 재질 변형).
        /// `material` 은 그중 첫 번째다 — 씬의 `"skin": N` 선택은 아직 없다(G-C3-05).
        /// 실측 분포 {1: 450, 2: 1} — 2인 것은 audiophile grid.mdl 하나뿐이다.
        public var materials: [String] = []
        /// v≥21 메시 트레일러(게이트A/B 블롭 + v≥23 모프 레코드). 전부 0 인 트레일러(= 종전
        /// '6바이트 구분자')는 nil — 데이터가 있을 때만 채운다. 파스·보존, 렌더 소비는 범위 밖.
        public var trailer: MeshTrailer? = nil
    }

    /// 메시 트레일러 gateA 블롭 — u32 word + u32 size + size 바이트
    /// (어셈블리 0x140261c3b-0x140261c66: u8 게이트 ≠ 0 시 u32(FUN_14009c630, 값 미소비) +
    /// 블롭(FUN_14009c690 = u32 size + bytes)).
    public struct GateBlob: Equatable {
        public let word: UInt32
        public let data: Data
        public init(word: UInt32, data: Data) { self.word = word; self.data = data }
    }

    /// v≥23 모프/마스크 레코드 — 스트림: u64 id | cstring name | u32 flags | u32 n1 | n1×u32 |
    /// u32 n2 | n2×u32 (디컴파일 :1227-1457 + 어셈블리 0x140261cb0-0x1402620e3 — 첫 리드는
    /// func_0x000140261780 = u64, 두 번째가 FUN_14009c5d0 cstring). 인덱스들은 gateB 16B 레코드
    /// 참조(엔진은 레코드 수 N 이상 시 trap — 어셈블리 `cmp r12d,[rbp+0x110]`). 실물 12파일:
    /// name 은 전부 "masks/clipping_mask_*". 모프 렌더 소비는 범위 밖 — 파스·보존.
    public struct MorphTarget: Equatable {
        public let id: UInt64                  // 선행 8B — 의미 미확정(실물 값 소수, 상위 u32 는 0)
        public let name: String
        public let flags: UInt32
        public let indicesA: [UInt32]          // n1×u32
        public let indicesB: [UInt32]          // n2×u32
        public init(id: UInt64, name: String, flags: UInt32, indicesA: [UInt32], indicesB: [UInt32]) {
            self.id = id; self.name = name; self.flags = flags
            self.indicesA = indicesA; self.indicesB = indicesB
        }
    }

    /// v≥21 메시 트레일러(디컴파일 :1214-1457 + 실물 418파일 전수 착지 검증 2026-07-28).
    /// 실물 관측: gateA 86파일(전부 단일메시 퍼펫, word=1, blob = 정점수×12B vec3 — 퍼펫워프
    /// 데이터 추정, 미확정), gateB 190파일(16B×N 레코드 — 실물 다수가 12B 0 + u32 패턴),
    /// 모프 12파일. 전부 파스·보존(소비 보류).
    public struct MeshTrailer: Equatable {
        public var gateA: GateBlob? = nil      // gateA ≠ 0 일 때만
        public var gateB: Data? = nil          // gateB ≠ 0 일 때만(16B×N 레코드 원바이트)
        public var morphs: [MorphTarget] = []  // v≥23, count > 0 일 때만
        public init() {}
        public var isEmpty: Bool { gateA == nil && gateB == nil && morphs.isEmpty }
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
        /// C③: 클립 고유 id(scene.json animationlayers[].animation 이 참조하는 정수) — 트레일러 u16
        /// 필드(트레일러 시작 +31, 없으면 nil)에서 추출, 마지막 클립은 트레일러에 id가 없어 헤더의
        /// baseId 를 대신 쓴다(실측 3파일·17클립 전수 교차검증: 3384019940 头/3517818807 rwm/3486806915 头).
        /// nil = 추출 실패(트레일러 부족 등) — 이름 휴리스틱 폴백 유지.
        public var id: Int? = nil
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

    /// MDLS0002/0003/0004 스켈레톤 꼬리(T1..T7) — 본 레코드 뒤·다음 섹션 앞 블록들의 타입화 파스.
    /// 근거: 디컴파일 FUN_140261950:262-1059 + 어셈블리(wallpaper64.exe 0x14026269a-0x140263a00,
    /// 디컴파일 결락분 복구) + 실물 418파일 전수 착지 검증(2026-07-28 — 다음 섹션 매직/말미 NUL
    /// 로의 정확 착지). **전부 파스·보존, 런타임 소비 보류** — IK/스프링을 포즈 평가에 반영하는
    /// 소비처 공식은 이 디코더 함수 밖에 있어 이번 대조에서 읽히지 않는다(추측 구현 금지).
    /// 스트림 레이아웃(본 레코드 직후 순서):
    ///   T1  u16 C1 | C1 × (cstring tag | u32 bone | u32 flags | 64B mat4)     [어셈 0x1402626a0-0x1402627d9]
    ///   T2  u8 gate | gate≠0: 본수 × 64B mat4                                 [디컴 :284-328]
    ///   T3  u32 C2 | C2 × (u32 bone | f32 | f32 | [MDLS≥4: u32 flags | flags&2: f32 f32])
    ///                                                               [어셈 0x14026292f-0x140262a22, v 게이트 `cmp r15d,4`]
    ///   T4a u16 C3 | C3×u32 | C3 × (u16 D | D × (u32 | f32 | f32 | u32))      [어셈 0x140262b04-0x140262ca0 — 디컴파일 결락]
    ///   T4b u16 C4 | C4 × (u32 bone | u32 B | B×u32 | u16 C | C × (u32 idx | u16 D |
    ///               D × (16B | u16 E | E×u32)))                             [어셈 0x140262d9b-0x140263500]
    ///   T5  u8 gate | gate≠0: 본수 × (3f + mat4) = 76B                        [디컴 :857-940]
    ///   T6  u8 gate | gate≠0: 본수 × u32                                      [디컴 :941-1002]
    ///   T7  [MDLS≥3] u8 gate | gate≠0: 본수 × u32                             [디컴 :1003-1059, v 게이트 `2 < ver`]
    public struct SkeletonTail: Equatable {
        /// T1 태그 레코드 — 마스터 문서 §4 의 본 태그('gd'/'m '/'tf'/'ik'/'ikce'/'se'/'re') 대응
        /// 데이터. 실물 418파일 중 1파일·8레코드만 존재(tag 는 전부 빈 문자열). flags==1 이면
        /// 엔진이 bone→레코드 매핑에 등록(T3 제약의 리다이렉트 대상 — 디컴파일 :410-427).
        public struct TagRecord: Equatable {
            public let tag: String
            public let bone: UInt32
            public let flags: UInt32
            public let matrix: simd_float4x4
            public init(tag: String, bone: UInt32, flags: UInt32, matrix: simd_float4x4) {
                self.tag = tag; self.bone = bone; self.flags = flags; self.matrix = matrix
            }
        }

        /// T3 제약 엔트리(엔진은 0x14B 로 저장: flags + 4f). a/b = 선행 2f, flags = MDLS0004
        /// 전용 4번째 워드(그 미만 버전은 필드 부재 → 0), extra = flags&2 시 추가 2f(엔진은
        /// 두 번째 값에 하한 클램프 — 디컴파일 :380-388, 의미 미확정). 실물 418파일 전부 C2=0.
        public struct Constraint: Equatable {
            public let bone: UInt32
            public let a: Float
            public let b: Float
            public let flags: UInt32
            public let extra: SIMD2<Float>?
            public init(bone: UInt32, a: Float, b: Float, flags: UInt32, extra: SIMD2<Float>?) {
                self.bone = bone; self.a = a; self.b = b; self.flags = flags; self.extra = extra
            }
        }

        /// T4a 16B 레코드(u32 | f32 | f32 | u32) — 실물(cat11): index 는 본 인덱스,
        /// x/y 는 ~±1 부동소수(스프링 파라미터 추정, 미확정), value 는 0.
        public struct GroupRecord: Equatable {
            public let index: UInt32
            public let x: Float
            public let y: Float
            public let value: UInt32
            public init(index: UInt32, x: Float, y: Float, value: UInt32) {
                self.index = index; self.x = x; self.y = y; self.value = value
            }
        }

        /// T4a 블록 — values = 선행 C3×u32 배열(실물은 f32 비트 해석이 자연스러움: 6~37 범위),
        /// groups = 외측 C3 개의 u16 D-그룹(실물은 C3==본수). 스프링본 블록 추정(미확정).
        public struct GroupBlock: Equatable {
            public let values: [UInt32]
            public let groups: [[GroupRecord]]
            public init(values: [UInt32], groups: [[GroupRecord]]) {
                self.values = values; self.groups = groups
            }
        }

        /// T4b D-원소: 16B(4f) + u16 E + E×u32.
        public struct LinkElem: Equatable {
            public let vec: SIMD4<Float>
            public let indices: [UInt32]
            public init(vec: SIMD4<Float>, indices: [UInt32]) { self.vec = vec; self.indices = indices }
        }

        /// T4b 서브레코드: u32 idx(엔진은 본수 미만 검사) | u16 D | D×LinkElem.
        public struct LinkSub: Equatable {
            public let index: UInt32
            public let elems: [LinkElem]
            public init(index: UInt32, elems: [LinkElem]) { self.index = index; self.elems = elems }
        }

        /// T4b C4 레코드: u32 bone | u32 B | B×u32 | u16 C | C×LinkSub. refs 는 T1 태그
        /// 레코드 인덱스(엔진은 T1 수 미만 검사 — 어셈블리 `sar rax,7; cmp` 후 trap; 실물 cat11 유효).
        public struct LinkRecord: Equatable {
            public let bone: UInt32
            public let refs: [UInt32]
            public let subs: [LinkSub]
            public init(bone: UInt32, refs: [UInt32], subs: [LinkSub]) {
                self.bone = bone; self.refs = refs; self.subs = subs
            }
        }

        /// T5 본 변환: 3f 오프셋 + mat4(실물 다수 파일 보유, 회전+평행이동 패턴).
        public struct BoneTransform: Equatable {
            public let offset: SIMD3<Float>
            public let matrix: simd_float4x4
            public init(offset: SIMD3<Float>, matrix: simd_float4x4) {
                self.offset = offset; self.matrix = matrix
            }
        }

        public var tags: [TagRecord] = []            // T1
        public var extraBinds: [simd_float4x4] = []  // T2 게이트 시 본수 개
        public var constraints: [Constraint] = []    // T3
        public var groups: GroupBlock? = nil         // T4a
        public var links: [LinkRecord] = []          // T4b
        public var boneTransforms: [BoneTransform] = []  // T5 게이트 시 본수 개
        public var boneIndices: [UInt32] = []        // T6 게이트 시 본수 개(실물 cat11: 0..<본수 순열 — 본 인덱스 재배열)
        public var boneParams: [UInt32] = []         // T7 게이트 시 본수 개(MDLS≥3; 실물 cat11: 정수 오프셋열, 의미 미확정)
        public init() {}
    }

    public let meshes: [Mesh]
    public var bones: [Bone] = []
    /// MDLS 꼬리(T1..T7) — bones 파스 성공 + 꼬리 프레이밍이 다음 섹션 매직/EOF 로 검증된
    /// 경우에만 채운다(검증 실패 시 nil, 종전 매직 스캔 폴백과 동일 동작). 파스·보존 전용.
    public var skeletonTail: SkeletonTail? = nil
    /// MDAT0001 부착점(스켈레톤 트레일러 뒤·MDLA 앞). 없으면 빈 배열(무부착).
    public var attachments: [Attachment] = []
    /// MDLA0006 애니 섹션 존재 여부(매직 탐지 — animations 가 비어도 마커는 true).
    public var hasAnimation: Bool = false
    /// 파스된 애니메이션(순서 = 파일 순서). 렌더러가 animationlayers 로 활성 애니를 선택.
    public var animations: [Animation] = []

    /// 스키닝 정점 포맷 비트(formatFlag & 이 마스크 != 0 → 스키닝 선언 — 실제 본/웨이트 필드 존재는
    /// 스트라이드 여유(skinFieldsFit)로 최종 판정).
    private static let skinMask: UInt32 = 0x0180_0000

    /// 정점 채널 — 아는 채널만 읽고 미지 채널(.skip)은 크기만큼 건너뛴다.
    private enum VertexChannel { case position, normal, tangent, boneIndices, weights, uv, skip }

    /// 정점 레이아웃 테이블(wallpaper64.exe .rdata 원본 덤프로 확정 — FUN_1400d8060.c:81-96 의
    /// ⚠️ 파일명은 Ghidra 주소공간 — 원본에서는 `0x1400d7f90`(−0xD0, 위 MDL 디코더 주석과 같은 사유).
    /// (마스크,기여) 26엔트리 누산 루프와 동일 데이터: stride = set bit 기여 합산, 채널 오프셋은
    /// **테이블 인덱스 오름차순** 누적(비트 값 순이 아님 — idx5 0x800000 이 idx9 0x20 보다 앞).
    /// 검산(전부 일치): 0x0f→48, 0x0f|skinMask→80, 0x09|skin→52, Kirby 0x00800021→44(pos@0,
    /// boneIdx@12, TEXCOORD0 float4@28), sl_puppet 0x0181000e→84. TEXCOORD1-5(idx10-24)는 비트
    /// 대응 미대조라 미포함 — 해당 비트를 달리는 플래그는 테이블 불해결 → 기존 추측 경로 유지(무회귀).
    private static let vertexLayoutTable: [(bit: UInt32, size: Int, ch: VertexChannel)] = [
        (0x0000_0001, 12, .position),     // idx0 POSITION float3
        (0x0001_0000, 16, .position),     // idx1 16B pos계열(morph 후보 — idx0 부재 시 pos 로 읽음, sl_puppet)
        (0x0200_0000, 12, .position),     // idx2 12B pos계열(〃)
        (0x0000_0002, 12, .normal),       // idx3 NORMAL float3
        (0x0000_0004, 16, .tangent),      // idx4 TANGENT float4(w=handedness)
        (0x0080_0000, 16, .boneIndices),  // idx5 BLENDINDICES uint4(R32G32B32A32_UINT)
        (0x0100_0000, 16, .weights),      // idx6 BLENDWEIGHT float4
        (0x0000_0008,  8, .uv),           // idx7 TEXCOORD0 float2
        (0x0000_0010, 12, .uv),           // idx8 TEXCOORD0 float3(uv=.xy)
        (0x0000_0020, 16, .uv),           // idx9 TEXCOORD0 float4(uv=.xy — Kirby)
        (0x0000_8000, 16, .skip),         // idx25 float4 채널(color 후보 — 미독)
    ]

    /// 테이블 산출 레이아웃(오프셋은 정점 선두 기준 바이트). uv 는 float2/3/4 공통 선두 .xy 만 읽는다.
    private struct VertexLayout {
        var stride = 0
        var pos: Int? = nil, normal: Int? = nil, tangent: Int? = nil
        var boneIndices: Int? = nil, weights: Int? = nil, uv: Int? = nil
    }

    /// 테이블로 stride/채널 오프셋 산출 — set bit 가 전부 기지 테이블에 있을 때만 성공. 미지 비트가
    /// 하나라도 있으면 nil(호출측이 기존 축약 공식 + inferStride 추측 경로로 분기 — 무회귀).
    private static func vertexLayout(for flag: UInt32) -> VertexLayout? {
        var known: UInt32 = 0
        for e in vertexLayoutTable { known |= e.bit }
        guard flag != 0, flag & ~known == 0 else { return nil }
        var l = VertexLayout()
        for e in vertexLayoutTable where flag & e.bit != 0 {
            switch e.ch {
            case .position: if l.pos == nil { l.pos = l.stride }   // pos계열 다수 시 첫 채널(idx0 우선)
            case .normal: l.normal = l.stride
            case .tangent: l.tangent = l.stride
            case .boneIndices: l.boneIndices = l.stride
            case .weights: l.weights = l.stride
            case .uv: if l.uv == nil { l.uv = l.stride }
            case .skip: break
            }
            l.stride += e.size
        }
        return l
    }

    /// 수용 버전(전부 실물 바이트 대조 완료): 0023 정본; 0021 동일 레이아웃(3367988661 전수,
    /// 스켈레톤 매직은 MDLS0003 — 본 레코드는 0004 와 바이트 동형, 코퍼스 17퍼펫 matrix size 64 전수);
    /// 0017/0019 는 메시가 0023 과 동일하고 스켈레톤 매직만 MDLS0002(WLOP 2/2, 3189665546 7/7 대조);
    /// 0016 은 메시에 AABB 가 없고 정점 포맷 플래그가 0x…09(normal/tangent 없는 stride 52 = V0013 정점 레이아웃,
    /// 2885492021 6/6 대조 — weights 합 1.0, uv∈[0,1], maxIdx==vCount-1 전수 일치).
    ///
    /// [2026-08-20] **0004/0014 수용**(G-C3-02). WE 2.8.42 설치본 `.mdl` 28개 중 23개(v0004 8 + v0014 15)가
    /// 이 둘이고, 그동안 매직 화이트리스트에서 통째로 떨어져 기본 3D 프로젝트 9개 중 8개가 모델 0개로
    /// 그려졌다(techno 만 4개 중 3개가 v0023 이라 부분 생존). 근거 3중:
    ///   ① 엔진 디스어셈블(0x140261880) — AABB/per-mesh flag/트레일러 게이트를 직접 읽음(Model3DFormat).
    ///   ② 설치본 28파일 프레이밍 브루트포스 — 파일마다 파스+착지가 성립하는 프레이밍이 정확히 1개.
    ///   ③ 로제타석 `.obj`↔`.mdl` 16쌍 바이트 대조(v0004 4 · v0014 8 · v0023 4) — `scripts/spec/verify_rosetta.py`.
    /// 미목격 버전(0015/0018/0020/0022 등)은 계속 거부 — 추측 파스로 이상 렌더를 만드느니 스킵이 낫다.
    public static func parse(_ data: Data) -> Model3D? {
        let bytes = [UInt8](data)
        let magic = String(bytes: bytes[0..<min(8, bytes.count)], encoding: .utf8)
        guard bytes.count > 21, let magic, let version = Model3DFormat.version(ofMagic: magic) else { return nil }
        let hasAABB = Model3DFormat.hasAABB(version: version)          // v<17 은 메시 헤더에 AABB 24B 가 없다
        let hasMeshFlag = Model3DFormat.hasPerMeshFormatFlag(version: version)  // v<15 는 헤더 flag 를 그대로 쓴다

        func u32(_ o: Int) -> UInt32? { readU32LE(bytes, at: o) }
        func f32(_ o: Int) -> Float? { u32(o).map { Float(bitPattern: $0) } }
        func cstring(_ o: inout Int) -> String? {
            guard let r = readCString(bytes, at: o) else { return nil }
            o = r.next
            return r.value
        }

        // 헤더: magic(8) | u8 0 | u32 formatFlag(9) | u32 skinCount(13) | u32 meshCount(17)
        //
        // [2026-08-20] 오프셋 13 의 '미확정' 해소. 종전 주석은 이 필드를 stringCount 로 부르면서
        // "모델 전체 카운트인지 메시당 반복 카운트인지 미확정" 이라 적었는데, 원본 바이너리
        // 0x140261880 의 실행경로를 따라가면 답이 나온다: cstring 리드 루프
        // (0x14026193e `cmp dword [r15+8], ebx` … `jb 0x140261944`)가 **메시 루프 안**이다
        // (메시 루프 head 0x14026192c, back-edge 0x140262327 `jmp 0x14026192c`). 즉 메시마다
        // 이 개수만큼 머티리얼 cstring 을 읽는다 = skinCount(같은 메시의 재질 변형).
        // 실물도 같은 말을 한다 — audiophile grid.mdl(v0004, skinCount=2, 176B)과 fantasticcar
        // grid.mdl(v0014, skinCount=1, 151B)은 gateWord 이후 메시 페이로드가 **바이트 동일**하고,
        // 크기 차 25B = +26("materials/grid/grid2.json\0") −1(v0014 만 갖는 섹션 종단 NUL)로 정확히
        // 떨어진다. (정본 spec/formats/mdl-deep.json `format.mdl.header` 는 이 −1 을 빠뜨리고
        // "25B = cstring 길이" 라고 적었다 — 결론은 같지만 산수는 위가 맞다.)
        // 종전의 '1개만 읽기'는 skinCount=1 파일에서만 우연히 맞았고 grid.mdl 은 파스에 실패했다.
        guard let headerFlag = u32(9), let skinCountRaw = u32(13),
              let materialCount = Model3DFormat.materialCount(skinCount: skinCountRaw),
              let meshCount = u32(17), meshCount > 0, meshCount < 100_000 else { return nil }
        var o = 21
        var meshes: [Mesh] = []
        meshes.reserveCapacity(Int(meshCount))

        for mi in 0..<Int(meshCount) {
            // 머티리얼 cstring 을 skinCount 개 읽는다(위 헤더 주석 참조). 렌더는 첫 스킨만 쓰고
            // 나머지는 `Mesh.materials` 로 보존만 한다 — 씬의 `"skin": N` 선택은 G-C3-05 범위다.
            var materialList: [String] = []
            materialList.reserveCapacity(materialCount)
            for _ in 0..<materialCount {
                guard let m = cstring(&o) else { return nil }
                materialList.append(m)
            }
            guard let material = materialList.first else { return nil }
            // u32 gateWord(v≥4, 설치본 45메시 전건 0, Kirby mesh1 은 2). **버리면 안 된다** —
            // 인덱스 원소 폭이 이 워드의 bit0 에서 나온다(아래 참조).
            guard let gateWord = u32(o) else { return nil }
            o += 4
            // 메시 헤더 프레이밍: gateWord 뒤 여분 u32 는 **gateWord bit1 이 결정한다**
            // (`Model3DFormat.extraMeshHeaderWords`). 0 개 아니면 1 개, 2 개는 발생 불가다.
            //
            // [2026-08-21] 종전 `probe: for extra in 0...2` 무차별 탐색을 걷어냈다. 종전 주석은
            // 디컴파일 대조로 "결정론적 규칙임이 확인됨" 이라 적어 놓고도 코드는 브루트포스를
            // 유지했는데, 원본 어셈블리를 직접 따라가면 분기 하나로 끝난다:
            //     0x14026198c  mov [rbp+0x88], eax   → gateWord 보관
            //     0x140261992  test al, 2            → gateWord & 2
            //     0x140261994  je 0x1402619a6        → 안 서면 곧장 AABB 게이트(0x1402619a6 `cmp edi,0x11`)
            //     0x14026199b  call 0x14009c560      → 서면 u32 **한 번만** 더 읽고
            //     0x1402619a0  mov [rbp+0x8c], eax   → +0x8c 에 보관(구조체상 gateWord 바로 뒤)
            // 루프가 아니므로 extra=2 는 어떤 입력으로도 나올 수 없다 — 탐색이 그 프레이밍을
            // 받아들일 여지 자체가 오탐이었다. 무차별 탐색은 "정합하는 첫 프레이밍" 을 고르므로,
            // bit1=0 인데 정렬이 우연히 맞는 손상 파일을 4·8바이트 밀어 읽고 **조용히** 성공한다.
            // 이제는 규칙대로 읽고 안 맞으면 nil 이다(실물 회귀는 Model3DMeshFramingTests).
            //
            // 정점 포맷 플래그(실측 4종 대조로 확정): bit1(0x2)=normal 3f, bit2(0x4)=tangent 4f,
            // skinMask=본/웨이트. pos 3f 와 uv 2f 는 전 변형 공통(bit0/bit3 semantics 미상 — 무시).
            //   0x0f(48/80)  0x09(52, V0016)  0x0e(sl_puppet 84 변종)  0x21(Kirby channelmap 44).
            // 정점 레이아웃은 vertexLayoutTable(stride·채널 오프셋)로 산출한다 — set bit 가 전부 기지
            // 테이블이면 그대로 채택(표준 0x0f/0x09/+skin 은 종전 공식과 바이트 동일, Kirby 0x00800021
            // 의 pos@0/boneIdx@12/TEXCOORD0 float4@28 도 이 테이블이 산출).
            // 변종 스트라이드 자기기술 추론(2026-07-06, 실물 sl_puppet.mdl = 84 = 기지 80 + 미상 4B):
            // 테이블 불해결(미지 비트)이거나 테이블 stride 로 안 나눠지면 인덱스 블롭의 maxIndex+1 을
            // 정점 수로 보고 vSize/count 가 정수(20..96)면 채택. 이 추론 경로의 필드는 종전대로
            // 꼬리 고정(uv@-8, weights@-24, bones@-40), 중간은 고전 오프셋(테이블 미적용).
            // S3-mdl(2026-07-27) 대조로 엔진 측 원본 확인: AABB 게이트 직후 LAB_140261b0a(디컴파일
            // 1179행)부터 언롤 24항(마스크 배열 base `_DAT_140484af0`, 기여값 배열 base
            // `_DAT_140484a80`, 각 +4×index) + 루프 2항(`while (lVar23 != 0x1a)`) = **26개
            // (마스크,기여) 엔트리** 누산 테이블, 헤더 오프셋9 formatFlag 를 키로 사용. 이후
            // .rdata 테이블 원본 덤프(FUN_1400d8060.c:81-96 의 소비처 — D3D 입력 레이아웃의
            // AlignedByteOffset 누적)으로 마스크/기여 상수 전수 확정 → vertexLayoutTable 로 구현.
            var minx: Float = 0, miny: Float = 0, minz: Float = 0
            var maxx: Float = 0, maxy: Float = 0, maxz: Float = 0
            var q = o + Model3DFormat.extraMeshHeaderWords(gateWord: gateWord) * 4
            if hasAABB {
                var box: [Float] = [0, 0, 0, 0, 0, 0]
                for k in 0..<6 {
                    guard let v = f32(q + k * 4) else { return nil }
                    box[k] = v
                }
                (minx, miny, minz) = (box[0], box[1], box[2])
                (maxx, maxy, maxz) = (box[3], box[4], box[5])
                q += 24
            }
            // v≤14 는 메시마다 formatFlag 를 담지 않는다 — 리드 자체가 없고 헤더 오프셋 9 의 값을
            // 쓴다(엔진 0x140261a19 `cmp edi, 0x0f` / `jl 0x140261a33`, 그 착지점이
            // `mov [rbp+0xa8], r10d` = 헤더 flag 대입). 앞 메시 값이 눌어붙지도 않는다 —
            // 메시 루프 진입마다 r10d 를 헤더 값으로 되돌린다(0x140262318 `mov r10d,[rsp+0x60]`).
            let formatFlag: UInt32
            if hasMeshFlag {
                guard let f = u32(q) else { return nil }
                formatFlag = f
                q += 4
            } else {
                formatFlag = headerFlag
            }
            guard let vsRaw = u32(q) else { return nil }
            // `Int(clamping:)` — 64비트에서 UInt32→Int 는 언제나 확대라 트랩이 없지만,
            // check_int_narrowing 의 인구조사(R4)는 맨 `Int(` 를 세므로 무해함을 라벨로 적어 둔다.
            let vSize = Int(clamping: vsRaw)
            guard vSize > 0, q + 4 + vSize <= bytes.count else { return nil }
            let skinned = (formatFlag & skinMask) != 0
            var layout = vertexLayout(for: formatFlag)
            // 폴백 스트라이드는 항별 누적으로 계산한다 — 리터럴+삼항 5항 `+` 체인 한 줄은
            // 타입체커에 1.2초를 태웠다(구형 툴체인에선 식 폐기 위험). 합계는 종전과 동일.
            var fallback = 12 + 8                                    // pos(12) + uv(8)
            if formatFlag & 0x2 != 0 { fallback += 12 }               // normal
            if formatFlag & 0x4 != 0 { fallback += 16 }               // tangent/color
            if skinned { fallback += 32 }                             // boneIdx+weights
            var stride = layout?.stride ?? fallback
            if vSize % stride != 0 {
                guard let inferred = inferStride(bytes: bytes, indexBlobAt: q + 4 + vSize, vSize: vSize),
                      inferred >= 20 else { return nil }   // pos(12)+uv(8) 최소
                stride = inferred
                layout = nil   // 추론 스트라이드는 테이블 산출이 아님 — 채널 오프셋도 꼬리고정 경로로
            }
            o = q + 4
            guard stride > 0, vSize % stride == 0 else { return nil }
            let hasNormal = formatFlag & 0x2 != 0
            let hasTangent = formatFlag & 0x4 != 0
            let vCount = vSize / stride
            // 본/웨이트 필드는 실제 채널이 있을 때만 읽는다. 스키닝 선언이라도 웨이트 채널이 없으면
            // (Kirby channelmap: flag 0x00800021 — 테이블상 pos@0, boneIdx@12, TEXCOORD0 float4@28,
            // weights 부재) pos+uv 만 — 가중 0 스킨 합성으로 정점이 원점 붕괴하는 것보다 정적 메시가
            // 낫다(graceful degradation).
            let skinFieldsFit: Bool
            if let l = layout {
                skinFieldsFit = skinned && l.boneIndices != nil && l.weights != nil && l.uv != nil
            } else {
                skinFieldsFit = skinned && stride >= 12 + (hasNormal ? 12 : 0) + (hasTangent ? 16 : 0) + 40
            }

            guard let vertices = readVertices(bytes: bytes, at: o, count: vCount, stride: stride,
                                                layout: layout,
                                                skinFieldsFit: skinFieldsFit,
                                                hasNormal: hasNormal, hasTangent: hasTangent) else { return nil }
            o += vSize

            guard let iSizeRaw = u32(o) else { return nil }
            o += 4
            let iSize = Int(iSizeRaw)
            // 인덱스 원소 폭은 **정점 수가 정한다** — u16 이 담을 수 없으면 u32 다
            // (정본 spec/formats/mdl-deep.json `format.mdl.indexWidth`, 확정: u16 969메시 /
            //  u32 17메시, 이 규칙으로 읽으면 maxIndex == vertexCount-1 이 986/986).
            //
            // 종전엔 무조건 u16 이었고 그게 **조용히** 틀렸다: u32 블롭을 u16 로 읽으면 상위 워드 0 이
            // 섞여 maxIndex 가 정확히 0xFFFF 로 찍힌다. 정점 수보다 작으니 바로 아래 범위 가드를
            // 통과하고, 인덱스 개수만 2배가 되어 파스가 "성공"한다. 실물 도달은 11파일/17메시이고
            // 대형 메시가 정점 0 을 향한 슬리버 부채꼴로 그려졌다. 골든은 Waple-대-Waple 회귀라
            // 이 클래스를 구조적으로 못 잡는다 — 회귀 핀은 Model3DIndexWidthTests 다.
            //
            // **[2026-08-20] 폭은 정점 수가 정하는 게 아니라 포맷이 자기기술한다.** `.mdl` 전용
            // GPU 업로드 경로(0x1401d7760, 파스 직후 0x1401d5bb1 에서 호출)가 그렇게 읽는다:
            //   0x1401d784c `movzx ecx, byte [rdi+0x18]` → 0x1401d7853 `and cl, 1`  = gateWord & 1
            //   0x1401d7870 `lea r9d, [r10*2 + 2]`                                  = 2 또는 4
            //   0x1401d7878 `idiv r9d`                                              = 인덱스 개수
            // 그 플래그가 그대로 인자로 넘어가고(0x1401d786b), 소비처 0x14009a98d 가
            // `test edx,edx` → `cmove` 로 **0x39(R16_UINT)** 와 **0x2a(R32_UINT)** 를 고르며
            // ByteWidth 도 `lea ecx,[rsi*4]` / `lea eax,[rsi+rsi]` 로 같은 비트에서 갈린다.
            // 정점 수는 어디에도 안 들어간다.
            //
            // 두 규칙은 **설치본에서 같은 답을 낸다** — 45메시 전건 gateWord 0 이고 최대 정점수가
            // 10,995 라 `vCount > 65535` 도 항상 거짓이다(파스 결과 바이트 동일 확인). 갈리는 것은
            // gateWord bit0 이 선 워크샵 `.mdl` 이고, 그때 종전 규칙은 위에 적힌 그 **조용한**
            // 오작동을 그대로 낸다(maxIndex 가 vCount-1 이라 범위 가드를 통과한다).
            // `2 + 2*(gate&1)` 를 분기로 쓴다 — `Int(gateWord & 1)` 변환을 피해 정수 좁힘
            // 인구조사에 잡히지 않게(도메인이 {0,1} 이라 안전하지만, 세지 않는 편이 낫다).
            let iWidth = (gateWord & 1) == 0 ? 2 : 4
            guard iSize % iWidth == 0, o + iSize <= bytes.count else { return nil }
            var indices: [UInt32] = []
            indices.reserveCapacity(iSize / iWidth)
            if iWidth == 2 {
                for k in stride16(iSize) {
                    let lo = UInt32(bytes[o + k])
                    let hi = UInt32(bytes[o + k + 1]) << 8
                    indices.append(lo | hi)
                }
            } else {
                for k in stride32(iSize) {
                    var v = UInt32(bytes[o + k])
                    v |= UInt32(bytes[o + k + 1]) << 8
                    v |= UInt32(bytes[o + k + 2]) << 16
                    v |= UInt32(bytes[o + k + 3]) << 24
                    indices.append(v)
                }
            }
            if let maxIndex = indices.max(), Int(maxIndex) >= vCount { return nil }
            o += iSize

            meshes.append(Mesh(material: material,
                               boundsMin: SIMD3(minx, miny, minz), boundsMax: SIMD3(maxx, maxy, maxz),
                               skinned: skinFieldsFit, vertices: vertices, indices: indices,
                               materials: materialList))

            // 메시 트레일러(v≥21) — 엔진 정본 게이트 구조 정식 파스(디컴파일 FUN_140261950:1214-1457 +
            // 어셈블리 0x140261c3b-0x1402620e3; 실물 418파일 전수 착지 검증 2026-07-28):
            //   u8 gateA[≠0: u32 word + u32 size + blob] | u8 gateB[≠0: u32 size + blob(16B×N)]
            //   | (v≥23) u32 모프count + 레코드.
            // 전부 0 이면 v23 은 정확히 6바이트(= 종전 '6바이트 구분자'와 바이트 동형 — Kirby 의
            // gateB=1+16B 도 동형이라 종전 휴리스틱이 우연히 통과했던 것), v21/22 는 2바이트,
            // v<21 은 트레일러 자체 부재(엔진이 v≥21 에서만 리드 — 디컴파일 :1214 `if (0x14 < iVar17)`,
            // 실물 v<21 파일은 전부 단일메시라 영향 없음). 마지막 메시 뒤에도 존재(실물 390/390).
            // 구조 불일치(손상) 시: 메시 사이는 종전 +6 폴백(무회귀), 마지막 메시 뒤는 진행
            // 없이 매직 스캔(종전과 동일).
            if Model3DFormat.hasMeshTrailer(version: version) {
                if let t = parseMeshTrailer(bytes: bytes, at: o, version: version) {
                    o = t.end
                    if !t.trailer.isEmpty { meshes[mi].trailer = t.trailer }
                } else if mi < Int(meshCount) - 1 {
                    o += 6
                }
            }
        }

        var model = Model3D(meshes: meshes)

        // 스켈레톤(스키닝 모델). MDLA 와 동일하게 메시 끝 이후 매직 스캔으로 찾는다 — V0021(MDLS0003)은
        // 마지막 메시와 스켈레톤 사이에 비제로 부가 블록이 있어(실물 3384019940 5/5 실측) 종전
        // '제로-스킵 후 정확 착지'로는 도달 불가였다. 실패/구조 불일치는 본 없이 반환(정적 메시 렌더 가능).
        // MDLS0002(V0016/17/19)는 본 레코드가 0004 와 동일(cstring|flags|parent|64|mat4|props cstring —
        // WLOP GIRL 64본 props JSON 실측)하고, MDLS0003(MDLV0021 짝)도 본 레코드 바이트 동형
        // (코퍼스 17퍼펫/7씬 matrix size 64 전수 실측). 본 레코드 뒤 꼬리(T1..T7 블록)는
        // parseSkeletonTail 로 정식 파스해 skeletonTail 에 노출 — 종전의 '13+80×본수 꼬리' 기록은
        // T1..T6 블록의 조합 근사치이고, '꼬리는 파스하지 않는다'는 정식 파스로 대체(실물 418파일
        // 전수 착지 검증 2026-07-28). 수용 버전 0002/0003/0004 — 미목격 버전은 계속 거부(추측 파스 금지).
        if let si = findMagic("MDLS000", in: bytes, from: o), si + 9 <= bytes.count,
           (UInt8(ascii: "2")...UInt8(ascii: "4")).contains(bytes[si + 7]) {
            var p = si + 8 + 1  // magic + lead u8(0) — 매직은 cstring 이라 종단 NUL 이 1B 더 붙는다
            // 커서 정렬은 엔진과 같다: 매직 cstring → `strncmp(…, "MDLS", 4)`(0x1402624af/0x1402624bc)
            // → `atoi(매직+4)`(0x1402624d9) → u32 nextOffset(0x1402624ea, 리더 0x140261770 은 읽은
            // 값을 섹션 끝 포인터로 클램프해 보관한다) → u32 boneCount(0x1402624f4).
            //
            // [2026-08-21] 상한을 100,000 → 128 로 좁혔다. 엔진은 boneCount 를 읽자마자
            // `cmp eax, 0x80` / `jbe`(0x140262501–0x140262506) 로 재고, 초과하면 거부가 아니라
            // `xor ecx,ecx; int 0x29`(0x140262508–0x14026250a) = __fastfail 로 **프로세스를 죽인다**.
            // 즉 129본 이상 .mdl 은 WE 에서 아예 못 도는 파일이라 실물로 존재할 수 없다(근거 전문은
            // `Model3DFormat.maxBoneCount`). 종전 100,000 은 매직 스캔이 블롭 한복판에 오탐 착지했을
            // 때 폭주 카운트를 그대로 통과시켰다 — 이제 엔진과 같은 지점에서 잘린다.
            // Waple 은 죽지 않고 본 없이(정적 메시) 진행한다.
            if let _ = u32(p), let boneCount = u32(p + 4), boneCount <= UInt32(Model3DFormat.maxBoneCount) {
                p += 8
                var bones: [Bone] = []
                bones.reserveCapacity(Int(boneCount))
                var boneOK = true
                for _ in 0..<Int(boneCount) {
                    guard let name = cstring(&p),
                          let _ = u32(p), let parentRaw = u32(p + 4), let msz = u32(p + 8), msz == 64,
                          p + 12 + 64 <= bytes.count else { boneOK = false; break }
                    p += 12
                    guard let bindMat = readFloat4x4(bytes, at: p) else { boneOK = false; break }
                    p += 64
                    guard let props = cstring(&p) else { boneOK = false; break }
                    bones.append(Bone(name: name, parent: Int32(bitPattern: parentRaw),
                                      bind: bindMat, properties: props))
                }
                if boneOK {
                    model.bones = bones
                    // MDLS 꼬리(T1..T7) 정식 파스 — 착지가 다음 섹션 매직/EOF/말미 NUL 로
                    // 검증될 때만 노출하고 스캔 기준점을 전진(꼬리 내부 블롭의 매직 오탐 제거).
                    // 검증 실패(손상/미지 변종)는 노출·전진 없음 — 종전 매직 스캔과 동일(무회귀).
                    let mdlsVersion = Int(bytes[si + 7] - UInt8(ascii: "0"))
                    if let (tail, end) = parseSkeletonTail(bytes: bytes, at: p, mdlsVersion: mdlsVersion,
                                                           boneCount: Int(boneCount)) {
                        model.skeletonTail = tail
                        o = end
                    }
                }
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
    /// "MDAT0001" | u8 0 | u32 nextOff | u16 count |
    /// count×(u16 본인덱스 | cstring 이름(UTF-8) | 64B float4x4 로컬).
    /// count 는 u16(엔진 정본: 디컴파일 FUN_140261950:1092-1099 의 FUN_140261750 u16 리드 — 종전
    /// u8+pad 리드와 하위바이트 동일이라 pad=0 인 전 코퍼스에서 바이트 무차별, ≥256 도 수용).
    /// count×(u16 본인덱스 | cstring 이름(UTF-8) | 64B float4x4 로컬).
    /// 구조 불일치(본 인덱스 범위 밖 포함)는 빈 배열 — 추측 파스로 이상 부착을 만드느니 무부착이 낫다.
    static func parseAttachments(bytes: [UInt8], at magicOff: Int, boneCount: Int) -> [Attachment] {
        func u16(_ o: Int) -> Int? {
            guard o >= 0, o + 2 <= bytes.count else { return nil }
            return Int(bytes[o]) | (Int(bytes[o + 1]) << 8)
        }
        var p = magicOff + 8 + 1 + 4   // magic + u8(0) + u32 nextOff
        guard let count = u16(p), count > 0 else { return [] }
        p += 2  // u16 count
        var out: [Attachment] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard let bone = u16(p), bone < boneCount,
                  let name = readCString(bytes, at: p + 2) else { return [] }
            p = name.next
            guard let localMat = readFloat4x4(bytes, at: p) else { return [] }
            p += 64
            out.append(Attachment(name: name.value, bone: Int32(bone), local: localMat))
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
        let baseId = u32(o + 8)   // C③: 마지막 클립의 id(트레일러에 미기재) — 실측 3파일 전수 일치.
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
                // C③: 클립 id — next(다음 헤더) 가 있으면 이 클립 트레일러의 고정오프셋(트레일러 시작+31)
                // u16 필드(실측 3파일·17클립 전수 일치), 트레일러가 짧아 못 읽으면 nil(이름 휴리스틱
                // 폴백). next 가 없으면(섹션의 마지막 실클립) 트레일러에 id가 없어 헤더 baseId 를 대신
                // 쓴다(실측 3파일 전수 일치 — 3384019940 头 clip3/3517818807 rwm clip12/3486806915 头 clip2).
                if let n = next {
                    if let u = readU16LE(bytes, at: o + 31), o + 33 <= n { anim.id = Int(u) }
                } else if let base = baseId {
                    anim.id = Int(base)
                }
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
            if let obj = AssetJSON.dictionary(Data(bytes[i ..< e])),
               let name = obj["name"] as? String, let frame = (obj["frame"] as? NSNumber)?.floatValue {
                out.append(AnimationMarker(name: name, frame: frame))
            }
            i = e + 1
        }
        return out
    }

    /// stride-2 인덱스 순회 헬퍼.
    private static func stride16(_ size: Int) -> StrideTo<Int> { stride(from: 0, to: size, by: 2) }
    private static func stride32(_ size: Int) -> StrideTo<Int> { stride(from: 0, to: size, by: 4) }

    /// 메시 트레일러 정식 파스(v≥21) — 성공 시 (끝 오프셋, 트레일러), 구조 불일치(트렁케이트/폭주
    /// 카운트)는 nil(호출측 폴백). 근거: 디컴파일 FUN_140261950:1214-1457 + 어셈블리
    /// (wallpaper64.exe): gateA 0x140261c3b-0x140261c66(u8 | u32 + u32 size + blob),
    /// gateB 0x140261c6b-0x140261ca7(u8 | u32 size + blob, size>>4 = 16B 레코드 수),
    /// 모프 0x140261ca7 `cmp edi,0x17`(v≥23 게이트) — 레코드: u64(func_0x000140261780) |
    /// cstring(FUN_14009c5d0) | u32 flags | u32 n1 | n1×u32 | u32 n2 | n2×u32.
    private static func parseMeshTrailer(bytes: [UInt8], at p: Int, version: Int) -> (end: Int, trailer: MeshTrailer)? {
        var t = MeshTrailer()
        var o = p
        guard o + 1 <= bytes.count else { return nil }
        let gateA = bytes[o]; o += 1
        if gateA != 0 {
            guard let word = readU32LE(bytes, at: o), let size = readU32LE(bytes, at: o + 4) else { return nil }
            let s = Int(size)
            guard o + 8 + s <= bytes.count else { return nil }
            t.gateA = GateBlob(word: word, data: Data(bytes[o + 8 ..< o + 8 + s]))
            o += 8 + s
        }
        guard o + 1 <= bytes.count else { return nil }
        let gateB = bytes[o]; o += 1
        if gateB != 0 {
            guard let size = readU32LE(bytes, at: o) else { return nil }
            let s = Int(size)
            guard o + 4 + s <= bytes.count else { return nil }
            t.gateB = Data(bytes[o + 4 ..< o + 4 + s])
            o += 4 + s
        }
        if version >= 23 {
            guard let mc = readU32LE(bytes, at: o), mc <= 4096 else { return nil }   // 실물 최대 6 — 폭주 캡
            o += 4
            var morphs: [MorphTarget] = []
            morphs.reserveCapacity(Int(mc))
            for _ in 0..<Int(mc) {
                guard let lo = readU32LE(bytes, at: o), let hi = readU32LE(bytes, at: o + 4),
                      let name = readCString(bytes, at: o + 8),
                      let flags = readU32LE(bytes, at: name.next),
                      let n1 = readU32LE(bytes, at: name.next + 4), n1 <= 1_048_576 else { return nil }
                var o2 = name.next + 8
                guard let ia = readU32Array(bytes, at: &o2, count: Int(n1)) else { return nil }
                guard let n2 = readU32LE(bytes, at: o2), n2 <= 1_048_576 else { return nil }
                o2 += 4
                guard let ib = readU32Array(bytes, at: &o2, count: Int(n2)) else { return nil }
                morphs.append(MorphTarget(id: UInt64(hi) << 32 | UInt64(lo), name: name.value,
                                          flags: flags, indicesA: ia, indicesB: ib))
                o = o2
            }
            t.morphs = morphs
        }
        return (o, t)
    }

    /// MDLS 꼬리(T1..T7) 정식 파스 — 성공+착지 검증 시 (꼬리, 착지 오프셋), 그 외 nil.
    /// 착지 검증: 파스 끝이 다음 섹션 매직(MDLS/MDAT/MDLA/MDMP/MDLE) 또는 EOF 또는 말미 NUL
    /// (엔진 섹션 루프 종단 빈 cstring — 실물 418/418 파일의 마지막 바이트) 중 하나여야 한다.
    /// 이 검증이 실물 418파일 전수를 정확 착지시킨 기준과 동일(2026-07-28 하니스 대조).
    private static func parseSkeletonTail(bytes: [UInt8], at start: Int, mdlsVersion v: Int,
                                          boneCount: Int) -> (SkeletonTail, Int)? {
        func u16(_ o: Int) -> Int? { readU16LE(bytes, at: o).map(Int.init) }
        func u32(_ o: Int) -> UInt32? { readU32LE(bytes, at: o) }
        func f32(_ o: Int) -> Float? { u32(o).map { Float(bitPattern: $0) } }
        var tail = SkeletonTail()
        var o = start
        // T1 태그 레코드(어셈블리 0x1402626a0-0x1402627d9: u16 C1 | C1 × (cstring | u32 | u32 | 64B)).
        // 캡은 방어용(실물 최대 8) — 엔진 자체는 본수 상한 0x80 만 강제(디컴파일 :242).
        guard let c1 = u16(o), c1 <= 1024 else { return nil }
        o += 2
        for _ in 0..<c1 {
            guard let tag = readCString(bytes, at: o),
                  let bone = u32(tag.next), let flags = u32(tag.next + 4),
                  tag.next + 8 + 64 <= bytes.count,
                  let m = readFloat4x4(bytes, at: tag.next + 8) else { return nil }
            o = tag.next + 8 + 64
            tail.tags.append(SkeletonTail.TagRecord(tag: tag.value, bone: bone, flags: flags, matrix: m))
        }
        // T2 u8 게이트 — 본수 × 64B(디컴파일 :284-328).
        guard o + 1 <= bytes.count else { return nil }
        if bytes[o] != 0 {
            o += 1
            guard o + boneCount * 64 <= bytes.count else { return nil }
            for _ in 0..<boneCount {
                guard let m = readFloat4x4(bytes, at: o) else { return nil }
                tail.extraBinds.append(m)
                o += 64
            }
        } else { o += 1 }
        // T3 u32 C2 | 엔트리(어셈블리 0x14026292f-0x140262a22; 4번째 워드는 MDLS≥4 전용 `cmp r15d,4`).
        guard let c2 = u32(o), c2 <= 1_048_576 else { return nil }
        o += 4
        for _ in 0..<Int(c2) {
            guard let bone = u32(o), let a = f32(o + 4), let b = f32(o + 8) else { return nil }
            o += 12
            var flags: UInt32 = 0
            var extra: SIMD2<Float>? = nil
            if v >= 4 {
                guard let fl = u32(o) else { return nil }
                flags = fl
                o += 4
                if fl & 2 != 0 {
                    guard let x = f32(o), let y = f32(o + 4) else { return nil }
                    extra = SIMD2(x, y)
                    o += 8
                }
            }
            tail.constraints.append(SkeletonTail.Constraint(bone: bone, a: a, b: b, flags: flags, extra: extra))
        }
        // T4a u16 C3 | C3×u32 | C3 × (u16 D | D × 16B) — 디컴파일 결락분(어셈블리
        // 0x140262b04-0x140262ca0 로 복구: 외측 루프 C3 회 `cmp r13d,ebx`, 내측 D × (u32|2f|u32)).
        guard let c3 = u16(o), c3 <= 1024 else { return nil }
        o += 2
        if c3 > 0 {
            var values: [UInt32] = []
            for _ in 0..<c3 {
                guard let x = u32(o) else { return nil }
                values.append(x)
                o += 4
            }
            var groups: [[SkeletonTail.GroupRecord]] = []
            for _ in 0..<c3 {
                guard let d = u16(o), d <= 4096 else { return nil }
                o += 2
                var g: [SkeletonTail.GroupRecord] = []
                for _ in 0..<d {
                    guard let idx = u32(o), let x = f32(o + 4), let y = f32(o + 8), let val = u32(o + 12) else { return nil }
                    g.append(SkeletonTail.GroupRecord(index: idx, x: x, y: y, value: val))
                    o += 16
                }
                groups.append(g)
            }
            tail.groups = SkeletonTail.GroupBlock(values: values, groups: groups)
        }
        // T4b u16 C4 | C4 × (u32 bone | u32 B | B×u32 | u16 C | C × (u32 idx | u16 D |
        // D × (16B | u16 E | E×u32))) — 어셈블리 0x140262d9b-0x140263500.
        guard let c4 = u16(o), c4 <= 1024 else { return nil }
        o += 2
        for _ in 0..<c4 {
            guard let bone = u32(o), let nb = u32(o + 4), nb <= 1_048_576 else { return nil }
            o += 8
            guard let refs = readU32Array(bytes, at: &o, count: Int(nb)) else { return nil }
            guard let nc = u16(o), nc <= 4096 else { return nil }
            o += 2
            var subs: [SkeletonTail.LinkSub] = []
            for _ in 0..<nc {
                guard let idx = u32(o), let nd = u16(o + 4), nd <= 4096 else { return nil }
                o += 6
                var elems: [SkeletonTail.LinkElem] = []
                for _ in 0..<nd {
                    guard let x = f32(o), let y = f32(o + 4), let z = f32(o + 8), let w = f32(o + 12),
                          let ne = u16(o + 16), ne <= 4096 else { return nil }
                    o += 18
                    guard let indices = readU32Array(bytes, at: &o, count: ne) else { return nil }
                    elems.append(SkeletonTail.LinkElem(vec: SIMD4(x, y, z, w), indices: indices))
                }
                subs.append(SkeletonTail.LinkSub(index: idx, elems: elems))
            }
            tail.links.append(SkeletonTail.LinkRecord(bone: bone, refs: refs, subs: subs))
        }
        // T5 u8 게이트 — 본수 × (3f + mat4)(디컴파일 :857-940).
        guard o + 1 <= bytes.count else { return nil }
        if bytes[o] != 0 {
            o += 1
            guard o + boneCount * 76 <= bytes.count else { return nil }
            for _ in 0..<boneCount {
                guard let ox = f32(o), let oy = f32(o + 4), let oz = f32(o + 8), let m = readFloat4x4(bytes, at: o + 12) else { return nil }
                tail.boneTransforms.append(SkeletonTail.BoneTransform(offset: SIMD3(ox, oy, oz), matrix: m))
                o += 76
            }
        } else { o += 1 }
        // T6 u8 게이트 — 본수 × u32(디컴파일 :941-1002; 엔진은 본수-1 클램프 — 본 인덱스열).
        guard o + 1 <= bytes.count else { return nil }
        if bytes[o] != 0 {
            o += 1
            guard let list = readU32Array(bytes, at: &o, count: boneCount) else { return nil }
            tail.boneIndices = list
        } else { o += 1 }
        // T7 (MDLS v≥3) u8 게이트 — 본수 × u32(디컴파일 :1003-1059).
        if v >= 3 {
            guard o + 1 <= bytes.count else { return nil }
            if bytes[o] != 0 {
                o += 1
                guard let list = readU32Array(bytes, at: &o, count: boneCount) else { return nil }
                tail.boneParams = list
            } else { o += 1 }
        }
        // 착지 검증 — 다음 섹션 매직/EOF/말미 NUL(실물 파일 종단자) 중 하나.
        guard o == bytes.count || (o == bytes.count - 1 && bytes[o] == 0) || isSectionMagic(bytes, at: o)
        else { return nil }
        return (tail, o)
    }

    /// 꼬리 착지 검증용 섹션 매직 접두 판정(MDLS000x/MDAT0001/MDLA000x/MDMP0001/MDLE0002).
    private static func isSectionMagic(_ bytes: [UInt8], at o: Int) -> Bool {
        guard o + 8 <= bytes.count, (0x31...0x39).contains(bytes[o + 7]) else { return false }
        return findMagic("MDLS000", in: bytes, from: o) == o
            || findMagic("MDAT0001", in: bytes, from: o) == o
            || findMagic("MDLA000", in: bytes, from: o) == o
            || findMagic("MDMP0001", in: bytes, from: o) == o
            || findMagic("MDLE0002", in: bytes, from: o) == o
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

    /// bytes[o..<o+n*4] 에서 n 개의 리틀엔디안 u32 를 읽어 배열로 반환하고 o 를 전진시킨다.
    /// 범위 밖이면 nil(o 미변경). parseMeshTrailer·parseSkeletonTail 공통 패턴 통합.
    private static func readU32Array(_ bytes: [UInt8], at o: inout Int, count n: Int) -> [UInt32]? {
        guard n >= 0, o + n * 4 <= bytes.count else { return nil }
        var out: [UInt32] = []
        out.reserveCapacity(n)
        for _ in 0..<n { out.append(readU32LE(bytes, at: o)!); o += 4 }   // 경계 사전검사 완료
        return out
    }

    /// 정점 블롭에서 vCount 개 정점을 읽어 반환한다. 바이트 범위 밖이면 nil(호출측 parse failure).
    /// 채널 오프셋은 layout(테이블 산출) 또는 고전/꼬리고정 규칙을 그대로 따른다.
    /// 오프셋 산수 보존 근거: posOff, normal, tangent, boneIndices, weights, uv 오프셋 계산식이
    /// 인라인 원본과 동일(식 복사, 변수명만 파라미터화). stride·skinFieldsFit·hasNormal·hasTangent
    /// 판정은 호출측이 원본 그대로 계산해 넘긴다.
    private static func readVertices(bytes: [UInt8], at offset: Int, count vCount: Int, stride: Int,
                                     layout: VertexLayout?,
                                     skinFieldsFit: Bool, hasNormal: Bool, hasTangent: Bool) -> [Vertex]? {
        func u32(_ o: Int) -> UInt32? { readU32LE(bytes, at: o) }
        func f32(_ o: Int) -> Float? { u32(o).map { Float(bitPattern: $0) } }
        var vertices: [Vertex] = []
        vertices.reserveCapacity(vCount)
        for vi in 0..<vCount {
            let b = offset + vi * stride
            var pos = SIMD3<Float>.zero
            var nrm = SIMD3<Float>(0, 0, 1)                       // 부재 시 기본(2D 퍼펫은 미사용)
            var tan = SIMD4<Float>(1, 0, 0, 1)
            // 채널 오프셋: 테이블 레이아웃이면 테이블 값, 아니면 종전 고전/꼬리고정 오프셋.
            let posOff = layout?.pos ?? 0
            guard let px = f32(b + posOff), let py = f32(b + posOff + 4), let pz = f32(b + posOff + 8)
            else { return nil }
            pos = SIMD3<Float>(px, py, pz)
            let readNormal = layout.map { $0.normal != nil } ?? hasNormal
            if readNormal, let no = layout?.normal ?? (hasNormal ? 12 : nil) {
                guard let nx = f32(b + no), let ny = f32(b + no + 4), let nz = f32(b + no + 8) else { return nil }
                nrm = SIMD3(nx, ny, nz)
            }
            let readTangent = layout.map { $0.tangent != nil } ?? hasTangent
            if readTangent, let to = layout?.tangent ?? (hasTangent ? 12 + (hasNormal ? 12 : 0) : nil) {
                guard let tx = f32(b + to), let ty = f32(b + to + 4), let tz = f32(b + to + 8), let tw = f32(b + to + 12)
                else { return nil }
                tan = SIMD4(tx, ty, tz, tw)
            }
            if skinFieldsFit {
                // 테이블: 채널 오프셋 직독 / 추론 경로: 종전 꼬리고정.
                let bo = b + (layout?.boneIndices ?? stride - 40)
                let wo = b + (layout?.weights ?? stride - 24)
                let uo = b + (layout?.uv ?? stride - 8)
                guard let b0 = u32(bo), let b1 = u32(bo + 4), let b2 = u32(bo + 8), let b3 = u32(bo + 12),
                      let w0 = f32(wo), let w1 = f32(wo + 4), let w2 = f32(wo + 8), let w3 = f32(wo + 12),
                      let u = f32(uo), let v = f32(uo + 4) else { return nil }
                vertices.append(Vertex(position: pos, normal: nrm, tangent: tan, uv: SIMD2(u, v),
                                       boneIndices: SIMD4(b0, b1, b2, b3), weights: SIMD4(w0, w1, w2, w3)))
            } else if let uo = layout?.uv ?? (stride >= 8 ? stride - 8 : nil) {
                // TEXCOORD0 가 float3/float4 여도 선두 .xy 만 읽는다(Kirby float4@28 — RE 테이블).
                guard let u = f32(b + uo), let v = f32(b + uo + 4) else { return nil }
                vertices.append(Vertex(position: pos, normal: nrm, tangent: tan, uv: SIMD2(u, v)))
            } else {
                vertices.append(Vertex(position: pos, normal: nrm, tangent: tan, uv: .zero))
            }
        }
        return vertices
    }

    /// bytes[at..<at+64] 로부터 column-major float4x4 를 읽는다. 범위 밖이면 nil.
    /// 반복 패턴(parse·parseAttachments·parseSkeletonTail 3개소) 통합 — 오프셋 산수: 열 c = at + c*16,
    /// 행 r = 열 시작 + r*4, 합 64B(실물 전수 stride 64 검산 완료).
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
