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
/// MDLA0003/0004/0005/0006 애니 섹션 — **엔진 프레이밍**(2026-08-21 정정. 근거는 wallpaper64.exe
/// 2.8.42 의 MDL 디코더를 `.pdata` 조각 시작에서 선형으로 뜬 것이고, 서술은
/// `docs/re/skeleton-animation.md` §6):
///   "MDLA000N" | u8 0 | u32 nextOff(스킵 한계, 0x1402639a8) | u32 animCount(0x1402639b2) |
///   클립×N:
///     u64 id                       ; 0x1402639de → readU64 0x1402616b0, 클립 오브젝트 +0x00
///     cstring 이름                 ; 0x1402639f8 → 클립 +0x08 (std::string)
///     cstring 모드                 ; 0x140263a11 → 클립 +0x28 (loop/single/mirror/clamp/빈문자열)
///     f32 fps                      ; 0x140263a1b → +0xb8
///     u32 frameCount               ; 0x140263a2d → +0xbc
///     u32 flags                    ; 0x140263a3d → +0xc0
///     u32 boneCount(=스켈레톤 본수) ; 0x140263a4d
///     본×boneCount: u32 trackFlags(0x140263aa7) | u32 trackBytes(0x140263acb) |
///                   키×36B(pos 3f, 오일러각 3f 라디안, 스케일 3f — 0x140263afe 가 커서를 민다)
///     꼬리(버전 게이트 블록들 — 전부 클립마다 돈다. 최소 바이트는 게이트가 전부 0 일 때):
///       v≥2   2차 채널 트랙 배열. 개수는 파일이 아니라 **스켈레톤 쪽 배열 길이**를 128 로 나눈 값
///             (0x140263ce7 `sar rdi, 7`). 원소마다 u32 flags | u32 size | size바이트    … 최소 0B
///       항상  스칼라 f32 트랙 배열. 개수도 스켈레톤 필드 `[r15+0x28]`(0x140263e7b) —
///             그 필드는 **MDLS 꼬리 T3 의 레코드 수**다(0x14026285f 가 u32 로 읽고 0x14026286e 가
///             스켈레톤 +0x28 에 저장한다 = Waple 의 `SkeletonTail.constraints.count`).
///             원소마다 u32 | u32 size | size바이트                                      … 최소 0B
///       v≥3   ① **u32 count**(0x14026468d) + count×(u32 | u32 size | size바이트)
///             ② u8 gate(0x140264838), ≠0 이면 본 수만큼 같은 레코드                    … 최소 5B
///       v≥4   u8 gate(0x140264a1e), ≠0 이면 32B 레코드 배열                            … 최소 1B
///       v≥5   f32 6개 — 게이트 없이 무조건 24바이트(0x140264d23 부터 여섯 번)          … 24B
///       v≥6   u8 gate(0x140264e27), ≠0 이면 본 수만큼 8B 원소                          … 최소 1B
///       flags&1 이면 0xC0바이트 레코드 하나(0x140264fc9 → 0x140264fdb)                  … 최소 0B
///       항상  **u32 이벤트수**(0x14026536d) + 수×(f32 초 0x1402653bd | cstring JSON 0x1402653e0)
///                                                                                       … 최소 4B
///     → 그 다음이 곧 다음 클립의 `u64 id` 다(클립 루프 뒤끝 0x14026556b `jl 0x1402639d0`).
///   즉 **MDLA0006 의 최소 꼬리는 4+1+1+24+1+4 = 35바이트**다.
///   2D MDLA0001 과의 diff: **레코드 구조는 같다**(PuppetModel.swift 참조). 버전이 1 이라
///     v≥2..v≥6 게이트 블록이 전부 꺼져 있어 꼬리가 이벤트 블록뿐이다.
///     link_adult 는 animCount=8 인데 실제 4개 → count 불신, 리싱크로 종료 판정.
///   확정(교차검증, **2026-08-20 이전 프레이밍으로 잰 값**): 174 .mdl 중 33 애니모델 전수 파스 성공
///     (0 실패); 본수==스켈레톤 본수(전수); 키0 로컬≈바인드 로컬은 캐릭터별로 다름(바인드=T포즈,
///     idle=이완포즈) — skin=world(t)×bindWorld⁻¹ 로 처리(2D 의 t=0 항등 가정 불성립이나 정상).
///     아래 툼스톤의 프레이밍 정정 뒤로는 **워크샵 코퍼스가 이 컨테이너에 없어 재측정하지 못했다** —
///     실물에서 trackFlags·게이트가 전부 0 이면 트랙 바이트는 종전과 동일한 자리에서 읽히므로
///     이 수치가 뒤집힐 이유는 없지만, 재측정 전까지는 **미검증**이다.
///
/// > **[툼스톤] 2026-08-21 이전에 이 주석이 적던 것**(전부 틀렸다):
/// >   `"MDLA0006" | u8 0 | u32 nextOff | u32 animCount | u32 baseId | u32 0` 로 헤더에 네 필드가
/// >   있고, 클립은 이름부터 시작하며 `… | u32 본수 | u32 0`, 본마다
/// >   `u32 트랙크기 | 트랙 | u32 블롭2크기 | 블롭2`, 뒤에 "트레일러(가변 32~39B):
/// >   u16 0 | AABB 6f | u32 0 | u16 id(=baseId+1+i, 마지막 애니는 생략)".
/// >   실제로는 ① `baseId|u32 0` 이 **클립 0 의 u64 id** 였고 ② 클립 헤더의 마지막 `u32 0` 이
/// >   **본 0 의 trackFlags** 였고 ③ 본마다 읽던 "블롭2크기" 가 **다음 본의 trackFlags** 였다.
/// >   실물에서 그 값들이 0 이라 위치가 우연히 맞았을 뿐이다. "트레일러 u16 0 | AABB 6f" 는
/// >   자리가 맞았다 — 그 `u16 0` 은 v3·v4 게이트 두 바이트이고 `AABB 6f` 는 v≥5 의 f32 6개다.
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
/// 파일 말미에는 단일 0x00 종단자(엔진 섹션 루프의 빈 cstring).
/// **전칭이 아니다** — 이 종단자는 **섹션 루프가 도는 v≥13 파일에만** 있다(v0014/0017/0023).
/// `v0004` 파일은 그 NUL 이 없고 마지막 인덱스 바이트가 곧 EOF 다(**설치본 8/8 실측** —
/// 아래 `hasSections` 앞 주석이 같은 근거를 적는다). 종전 문면의 "실물 418/418" 은
/// **파일 모집단 418 전건**을 뜻하는 것처럼 읽혔는데, 같은 파일 안의 v0004 예외 서술과
/// 정면으로 어긋났다.
/// (스키닝 모델) "MDAT0001" 이름-본 부착점 섹션 — parseAttachments()로 파싱, "MDLA0006" 애니메이션 섹션.
///
/// 정점 포맷(formatFlag 하위 바이트 0x0f = pos+normal+tangent+uv; 비트 0x01800000 = 스키닝):
///   정적(stride 48): pos 3f | normal 3f | tangent 4f | uv 2f
///   스키닝(stride 80): pos 3f | normal 3f | tangent 4f | boneIndices 4×u32 | weights 4f | uv 2f
/// 일반형은 **`vertexLayoutTable` 26엔트리**가 정본이다(마스크·크기·속성이름·시맨틱을 .rdata 에서
/// 전수 덤프 — 그 주석 참조). 요약: 전 채널 32비트 float(BLENDINDICES 만 uint4), 정규화·팩 포맷
/// 없음, 채널 순서는 테이블 인덱스 오름차순(pos → normal → tangent → blendIndices → blendWeights →
/// TEXCOORD0..5 → color).
///
/// 머티리얼 바인딩: 메시마다 cstring 경로 `skinCount` 개(스킨 = 같은 메시의 재질 변형).
///   • 경로는 **프로젝트 루트 상대**다(`project.json` 이 있는 폴더 기준. 엔진 자산은 `assets/` 기준).
///     설치본 실측: 45메시 46경로 중 45개가 그 규칙으로 디스크에 실재하고, 유일한 미스는 배포에서
///     빠진 에디터 기즈모(`assets/models/editor/camera` → `materials/models/editorcamera/...`)다.
///   • **서브메시 = 메시**다. 인덱스 범위(baseVertex/firstIndex)를 나눠 갖는 구조가 아니라 메시마다
///     자기 정점 블롭 + 자기 인덱스 블롭을 통째로 싣는다(설치본 45메시 전부 maxIndex == vCount−1).
///     즉 드로우콜 1개 = 메시 1개 = 머티리얼 1개다.
///
/// 확정 근거(교차검증): 174/174 파스; 단일메시 40개 전부 maxIndex == vertexCount-1;
///   vsize % stride == 0(전수); normal/tangent 단위길이·weights 합 1.0(3개 witness); 6바이트 구분자 전수 0.
///
/// S3-mdl(2026-07-27) 디컴파일 대조: wallpaper64.exe MDL 디코더 `FUN_140261880`(RVA 0x261880,
/// 짝 저장소 `analysis/decompiled/all/0000000140261880__FUN_140261880.c`)
/// 바이트리더 트레이스(3302695207 人物_puppet.mdl 실물 대조)로
///
/// > **[2026-08-27] 이 파일의 디컴파일 인용 이름과 줄 번호에 대해.** 종전 이 자리와 아래 네 곳은
/// > `FUN_140261950`(RVA `0x260950`)을 인용했다. 그 이름은 **rich header 주입본의 변위된 주소**이고
/// > RVA 도 틀렸다(`0x140261950 − 0x140000000` 은 `0x261950` 이지 `0x260950` 이 아니다). 짝 저장소가
/// > 주입기의 FileAlignment 위반을 고쳐 코퍼스를 재생성하면서 산출물은 **참 VA 로 이름이 붙었다** —
/// > 그 함수는 `FUN_140261880` 이고 그 이름의 파일은 실재한다. 사라진 게 아니라 이름이 바뀌었다.
/// >
/// > **아래 인용의 `:262-1059` 같은 줄 번호는 폐기된 변위 코퍼스 기준이라 재생성본에서는 맞지 않는다.**
/// > 지우지 않는 이유는 그 옆의 어셈블리 VA 가 내구성 있는 앵커라서다 — 대조할 때는 VA 를 쓰고,
/// > 줄 번호는 "그때 그 파일의 어디쯤" 이상으로 믿지 마라. 새로 인용을 다는 사람은 줄 번호 대신
/// > 조건식을 적어라(역공학 방법론 함정 22).
/// ⚠️ **이 이름은 Ghidra 주소공간이다 — 원본 바이너리에서는 `0x140261880`**(−0xD0).
/// Ghidra 가 매핑한 것이 rich header 주입본이라 디컴파일 산출물의 주소가 전부 208바이트 밀려 있다.
/// 원본 .pdata 14,792개 함수 시작 대조로 확인했다. `spec/engine/decompilation-provenance.json` 참조 —
/// 그 정본의 인용 분류는 **주소 39개**를 보고 27개는 보정 불필요 / 7개는 −0xD0 필요 / 5개는
/// 판정 불가로 갈랐다. 발견 자체는 실물 바이트 트레이스로 확인된 것이므로 결론은 유효하다.
/// 밀린 것은 **찾아가는 주소뿐**이다.
///
/// **[2026-08-21 정정 · [VA-정정] — 이 파일 안에서 규약이 갈려 있었다]** 위 경고를 적어 두고도 **트레일러·
/// 스켈레톤 절의 "어셈블리 0x…" 인용은 주입본 주소 그대로였다.** `scripts/re/va_citations.py`
/// 전수 대조가 잡았다(경계 이탈 8건이 전부 `−0xD0` 하면 명령 경계다). 결정적 대조 하나:
/// 종전 `0x140261ca7` 을 `cmp edi,0x17`(v≥23 게이트)이라고 적었는데 **원본 이미지의 그 주소는  [VA-정정]
/// `mov r12d,[rdi]`** 이고, `0x140261bd7`(=−0xD0)이 정확히 `cmp edi,0x17` 이다.
/// 전부 원본 주소로 옮겼다:
///   0x140261c3b→0x140261b6b · 0x140261c6b→0x140261b9b · 0x140261ca7→0x140261bd7  [VA-정정]
///   0x140261cb0→0x140261be0 · 0x14026269a→0x1402625ca · 0x1402626a0→0x1402625d0  [VA-정정]
///   0x14026292f→0x14026285f · 0x140262b04→0x140262a34 · 0x140262d9b→0x140262ccb  [VA-정정]
///   범위 끝과 Ghidra 이름도 같이 — `FUN_14009c630`→`0x14009c560`(readU32) ·
///   `func_0x000140261780`→`0x1402616b0`
/// 반대로 **메시 프레이밍 절의 주소는 원본이 맞다**(같은 스윕에서 전건 통과). 아래
/// `0x140263c61`(`movabs rax, 0xe38e38e38e38e38f`)와 `0x140263c8c`/`0x140263c95`(`int 0x29`)도
/// 원본 이미지에서 그 명령이 맞다 — 즉 **한 파일 안에 두 주소공간이 섞여 있었다.**
/// 정본의 "39개 중 7개" 는 이 8건을 **안 본 것**이다(그 분류의 표본이 39개뿐이다). 리포 전수
/// 스윕 실측은 주입본 79개다.
/// 헤더 3필드가 **정확히 offset 9 부터 시작하는 단일 u32 formatFlag**(문서 corpus_scan/mdl-format.md 의
/// "0x08 오프셋 lo/hi u16 쌍, hi=0x8000" 주장은 매직 cstring 리더가 byte8 의 NUL(=formatFlag 하위바이트
/// 우연 일치)을 종단문자로 소비해 이후 리드가 1바이트 밀리는 것을 못 잡은 오프바이원 — 우리 구현이 이미
/// 맞음, checklist match)임을 재확인. 버전 게이트(`if (iVar11 < 0x11)` 즉 <17 → AABB 없음 —
/// **[정정 2026-08-30]** 변수명이 ~~`iVar17`~~ 이었다. 재생성본 `FUN_140261880` 의 그 조건식 변수는
/// `iVar11` 이다. 폐기 코퍼스의 변수명이라 그대로 grep 하면 0 hits 였다)도 실행경로에서
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
        public let uv: SIMD2<Float>            // TEXCOORD0 의 .xy
        public let boneIndices: SIMD4<UInt32>  // 정적: (0,0,0,0)
        public let weights: SIMD4<Float>       // 정적: (0,0,0,0)
        /// 두 번째 UV 세트(라이트맵). **TEXCOORD0 이 float4(`a_TexCoordVec4`, 마스크 0x20)일 때의
        /// `.zw`** 다 — 채널이 없으면 (0,0). 소비처가 셰이더에 그대로 적혀 있다:
        /// `assets/shaders/generic.vert` 은 `#if LIGHTMAP` 에서 `attribute vec4 a_TexCoordVec4` 를
        /// 받아 `v_TexCoord = a_TexCoordVec4` 로 흘리고, `generic.frag` 이
        /// `texSample2D(g_LightmapMapSampler, v_TexCoord.zw)` 로 **.zw 만** 샘플한다(비 LIGHTMAP 은
        /// `attribute vec2 a_TexCoord` = 마스크 0x08). 설치본 도달: arsenal `pistols.mdl`
        /// (v0014, flag 0x27, 메시 6개) — 모델 옵션 `models/pistols/pistols.json` 이
        /// `"seconduvchannel": true`, 재질 6개 중 4개가 `"lightmap": 1` 콤보다.
        /// 파스·보존 전용 — 렌더 소비(라이트맵 패스)는 범위 밖이다.
        public let uv1: SIMD2<Float>

        public init(position: SIMD3<Float>, normal: SIMD3<Float>, tangent: SIMD4<Float>,
                    uv: SIMD2<Float>, boneIndices: SIMD4<UInt32> = .zero, weights: SIMD4<Float> = .zero,
                    uv1: SIMD2<Float> = .zero) {
            self.position = position; self.normal = normal; self.tangent = tangent
            self.uv = uv; self.boneIndices = boneIndices; self.weights = weights
            self.uv1 = uv1
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
        /// 실측 분포 {1: 450, 2: 1} — 2인 것은 `audiophile` 의 `grid.mdl` 하나뿐이다.
        /// **모집단은 `.mdl` 파일 451개**다(합 451). 바로 위 `969/986` 은 **메시** 모집단이라
        /// 서로 다른 수를 센다 — 같은 struct 주석 안에서 두 모집단이 섞이지 않게 명시해 둔다.
        public var materials: [String] = []
        /// v≥21 메시 트레일러(게이트A/B 블롭 + v≥23 모프 레코드). 전부 0 인 트레일러(= 종전
        /// '6바이트 구분자')는 nil — 데이터가 있을 때만 채운다. 파스·보존, 렌더 소비는 범위 밖.
        public var trailer: MeshTrailer? = nil
    }

    /// 메시 트레일러 gateA 블롭 — u32 word + u32 size + size 바이트
    /// (어셈블리 0x140261b6b-0x140261b96: u8 게이트 ≠ 0 시 u32(0x14009c560, 값 미소비) +
    /// 블롭(`FUN_14009c5c0` = u32 size + bytes)).
    /// **[정정 2026-08-30]** ~~`FUN_14009c690`~~ → `FUN_14009c5c0`(−0xD0). 변위본 이름은 짝 저장소
    /// manifest 7,748 함수에 함수 시작으로 없고, 보정한 주소는 있다(전수 확인).
    public struct GateBlob: Equatable {
        public let word: UInt32
        public let data: Data
        public init(word: UInt32, data: Data) { self.word = word; self.data = data }
    }

    /// v≥23 모프/마스크 레코드 — 스트림: u64 id | cstring name | u32 flags | u32 n1 | n1×u32 |
    /// u32 n2 | n2×u32 (어셈블리 0x140261be0-0x140262013 — 첫 리드는 0x1402616b0 = u64,
    /// 두 번째가 `FUN_14009c500` cstring). 인덱스들은 gateB 16B 레코드
    /// **[정정 2026-08-30]** ~~`디컴파일 :1227-1457`~~ 은 폐기 코퍼스 줄 번호라 버렸고(이 파일 머리말
    /// 지침대로 VA·조건식만 남긴다), ~~`FUN_14009c5d0`~~ → `FUN_14009c500`(−0xD0, manifest 확인).
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
    /// 키 1개 = **36바이트**이고 트랙 키 수는 `frameCount + 1` 이다 — 리더가 트랙 블롭 크기를
    /// 36 으로 나누고(`0xE38E38E38E38E38F` / `shr rdx,5` @0x140263c61) 몫이 `frameCount+1` 이
    /// 아니거나 나머지가 0 이 아니면 `int 0x29`(__fastfail) 로 즉사한다(0x140263c8c/0x140263c95).
    public struct Key: Equatable {
        public let position: SIMD3<Float>
        /// 오일러 3축 — 파일 바이트 순서(+0x0c,+0x10,+0x14) 그대로이고 의미는 **(X, Y, Z)**,
        /// 합성은 `Rz(z)·Ry(y)·Rx(x)`. 근거는 `PuppetPose.rotationQuaternion` 단일 소스.
        public let angles: SIMD3<Float>
        public let scale: SIMD3<Float>
        public init(position: SIMD3<Float>, angles: SIMD3<Float>, scale: SIMD3<Float>) {
            self.position = position; self.angles = angles; self.scale = scale
        }
    }

    /// 애니메이션(MDLA0006 애니 1개). tracks[boneIdx] = 프레임순 키 배열(본수 == 스켈레톤 본수).
    public struct Animation: Equatable {
        public let name: String                // "Link Adult_arm|idle_bone" 등
        /// 재생 모드 문자열. WE 가 실제로 인식하는 값은 `stricmp` 로 "mirror"(0x1401a8c71) /
        /// "single"(0x1401a8c87) 둘뿐이고 나머지(빈 문자열·"loop"·"clamp" 포함)는 전부 loop 다.
        public let mode: String
        public let fps: Float
        public let lengthFrames: Int
        public let tracks: [[Key]]             // 본 인덱스별 키(프레임당 1키)
        /// 이벤트 마커(실측 2026-07-10): 트랙 뒤 트레일러에 `u32 count | count×(f32 초 + NUL종단
        /// JSON cstring {"frame":N,"name":"…"})`. 재생이 frame 을 지나면 animationEvent 발화
        /// (3351179520/3396722575 错帧 동기, 젤다 talon snore·link Look Left/Right).
        public var events: [AnimationMarker] = []
        /// C③: 클립 고유 id(scene.json animationlayers[].animation 이 참조하는 정수) —
        /// **클립 레코드 선두의 u64**다(0x1402639de → readU64 0x1402616b0 → 클립 오브젝트 +0x00).
        /// nil = 그 자리를 못 읽었다(잘린 파일 · 리싱크가 클립 경계에 안 닿음 · u64 가 Int 범위 밖)
        /// — 이름 휴리스틱 폴백 유지.
        ///
        /// > **[툼스톤] 종전 구현**: "트레일러 시작 +31 의 u16, 마지막 클립은 헤더 baseId"
        /// > (근거로 "실측 3파일·17클립 전수 교차검증: 3384019940 头/3517818807 rwm/3486806915 头"
        /// > 이 붙어 있었다). 그 관측 자체는 진짜였고, **왜** 맞았는지가 이제 설명된다: 종전 커서는
        /// > 마지막 트랙 끝 +4 였고 v3~v6 게이트가 전부 0 인 파일에서 꼬리는 35바이트이므로
        /// > `+31` 은 정확히 **다음 클립의 u64 id 하위 16비트**였다. 즉 관측된
        /// > `id = baseId + 1 + i` 는 "클립 id 가 baseId 부터 1씩 증가한다" 는 뜻이고, 종전 구현은
        /// > 클립 i 에 **클립 i+1 의 id** 를 붙이고 있었다(마지막 클립에는 클립 0 의 id 를 붙였다).
        /// > 게이트가 하나라도 0 이 아니거나 이벤트 마커가 하나라도 있으면 그 자리는 id 가 아니다.
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
    /// 근거: 디컴파일 FUN_140261880:262-1059 + 어셈블리(wallpaper64.exe 0x1402625ca-0x140263930,
    /// 디컴파일 결락분 복구) + 실물 418파일 전수 착지 검증(2026-07-28 — 다음 섹션 매직/말미 NUL
    /// 로의 정확 착지). **전부 파스·보존, 런타임 소비 보류** — IK/스프링을 포즈 평가에 반영하는
    /// 소비처 공식은 이 디코더 함수 밖에 있어 이번 대조에서 읽히지 않는다(추측 구현 금지).
    /// 스트림 레이아웃(본 레코드 직후 순서):
    ///   T1  u16 C1 | C1 × (cstring tag | u32 bone | u32 flags | 64B mat4)     [어셈 0x1402625d0-0x140262709]
    ///   T2  u8 gate | gate≠0: 본수 × 64B mat4                                 [디컴 :284-328]
    ///   T3  u32 C2 | C2 × (u32 bone | f32 | f32 | [MDLS≥4: u32 flags | flags&2: f32 f32])
    ///                                                               [어셈 0x14026285f-0x140262952, v 게이트 `cmp r15d,4`]
    ///   T4a u16 C3 | C3×u32 | C3 × (u16 D | D × (u32 | f32 | f32 | u32))      [어셈 0x140262a34-0x140262bd0 — 디컴파일 결락]
    ///   T4b u16 C4 | C4 × (u32 bone | u32 B | B×u32 | u16 C | C × (u32 idx | u16 D |
    ///               D × (16B | u16 E | E×u32)))                             [어셈 0x140262ccb-0x140263430]
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

    /// 정점 채널 — 아는 채널만 읽고 안 쓰는 채널(.skip)은 크기만큼 건너뛴다.
    private enum VertexChannel { case position, normal, tangent, boneIndices, weights, uv, skip }

    /// 정점 속성 테이블 — **wallpaper64.exe 의 병렬 .rdata 배열 4개를 직접 덤프해 전 26엔트리 확정**
    /// (2026-08-21). 종전 표는 11엔트리뿐이었고 나머지 15개(TEXCOORD1-5)를 "비트 대응 미대조" 로
    /// 비워 뒀는데, 그 비트를 단 플래그는 테이블 불해결 → `inferStride` 추측 경로로 떨어져
    /// **꼬리고정 오프셋으로 조용히 오독**됐다(uv 를 stride−8 에서 읽으므로 TEXCOORD1 을 uv0 으로 읽는다).
    ///
    /// 배열 주소(이번 세션에 직접 스캔·덤프. Ghidra 보정 불필요 — 원본 이미지에서 뜬 값이다):
    ///   `0x140484a20` u32 마스크 ×26     — 스트라이드 누산 루프가 `[r11+rax*4+0x484a20]` 로 읽는다
    ///   `0x1404849b0` u32 바이트크기 ×26 — 같은 루프의 `[r11+rax*4+0x4849b0]`
    ///   `0x140484a90` char* 속성이름 ×26 — 셰이더 소스 스캐너가 `[rcx+r12*8+0x484a90]` 로 읽는다
    ///   `0x140482fa0` 16B 디스크립터 ×26 = {nameIdx, typeIdx, semanticIdx, semanticNumber}
    ///                                      (스캐너가 매치 시 통째로 복사: `0x1400f461c`)
    /// 스트라이드 산식도 같은 자리에서 확인했다 — MDL 디코더 `0x140261880` 안의
    /// `0x140261a3a`–`0x140261b2b`: SSE 로 idx0..23 을 4개씩 6묶음 누산하고
    /// (`test`/`pcmpeqd`+`andnps`+`andps`) 남은 idx24·25 는 스칼라 루프
    /// (`0x140261b10 test dword [r11+rax*4+0x484a20], r10d` / `0x140261b1a add ecx, [r11+rax*4+0x4849b0]`
    ///  / `0x140261b25 cmp rax, 0x1a`)로 더한 뒤 `0x140261b2b mov [rbp+0xac], ecx` 로 메시 구조체 +0x3c 에 넣는다.
    /// 같은 산식의 독립 사본이 `0x1400ea5b0`(스트라이드 전용 헬퍼)에도 있다.
    ///
    /// | idx | 마스크 | 크기 | 속성 이름 | HLSL 타입 : 시맨틱 |
    /// |---|---|---|---|---|
    /// | 0 | 0x00000001 | 12 | `a_Position` | float3 : POSITION0 |
    /// | 1 | 0x00010000 | 16 | `a_PositionVec4` | float4 : POSITION0 |
    /// | 2 | 0x02000000 | 12 | `a_PositionC1` | float3 : POSITION1 |
    /// | 3 | 0x00000002 | 12 | `a_Normal` | float3 : NORMAL0 |
    /// | 4 | 0x00000004 | 16 | `a_Tangent4` | float4 : TANGENT0 |
    /// | 5 | 0x00800000 | 16 | `a_BlendIndices` | uint4 : BLENDINDICES0 |
    /// | 6 | 0x01000000 | 16 | `a_BlendWeights` | float4 : BLENDWEIGHT0 |
    /// | 7 | 0x00000008 | 8 | `a_TexCoord` | float2 : TEXCOORD0 |
    /// | 8 | 0x00000010 | 12 | `a_TexCoordVec3` | float3 : TEXCOORD0 |
    /// | 9 | 0x00000020 | 16 | `a_TexCoordVec4` | float4 : TEXCOORD0 |
    /// | 10‥24 | 0x40/0x80/0x100 · 0x200/0x400/0x800 · 0x1000/0x2000/0x4000 · 0x20000/0x40000/0x80000 · 0x100000/0x200000/0x400000 | 8/12/16 | `a_TexCoord[Vec3\|Vec4]C1‥C5` | float2/3/4 : TEXCOORD1‥5 |
    /// | 25 | 0x00008000 | 16 | `a_Color` | float4 : COLOR0 |
    ///
    /// 읽어 낼 것이 없다:
    ///  • **전 채널이 32비트 float**(BLENDINDICES 만 uint4)다 — 정규화·팩된 포맷이 아예 없다.
    ///    `a_Color` 도 u8×4 가 아니라 float4 다.
    ///  • 채널 오프셋은 **테이블 인덱스 오름차순** 누적이지 비트 값 순이 아니다(idx5 0x800000 이
    ///    idx9 0x20 보다 앞, idx25 `a_Color` 0x8000 은 항상 **맨 뒤**).
    /// 검산(전부 일치): 0x0f→48, 0x0f|skinMask→80, 0x09|skin→52, Kirby 0x00800021→44(pos@0,
    /// boneIdx@12, TEXCOORD0 float4@28), sl_puppet 0x0181000e→84. 설치본 28파일 45메시 실측 플래그는
    /// 0x09(20) 19메시 · 0x0b(32) 10 · 0x0f(48) 10 · 0x27(56) 6 — 넷 다 이 표로 산출된다.
    private static let vertexLayoutTable: [(bit: UInt32, size: Int, ch: VertexChannel)] = [
        (0x0000_0001, 12, .position),     // idx0  a_Position      float3 POSITION0
        (0x0001_0000, 16, .position),     // idx1  a_PositionVec4  float4 POSITION0(idx0 부재 시 pos, sl_puppet)
        (0x0200_0000, 12, .position),     // idx2  a_PositionC1    float3 POSITION1
        (0x0000_0002, 12, .normal),       // idx3  a_Normal        float3 NORMAL0
        (0x0000_0004, 16, .tangent),      // idx4  a_Tangent4      float4 TANGENT0(w=handedness)
        (0x0080_0000, 16, .boneIndices),  // idx5  a_BlendIndices  uint4  BLENDINDICES0
        (0x0100_0000, 16, .weights),      // idx6  a_BlendWeights  float4 BLENDWEIGHT0
        (0x0000_0008,  8, .uv),           // idx7  a_TexCoord      float2 TEXCOORD0
        (0x0000_0010, 12, .uv),           // idx8  a_TexCoordVec3  float3 TEXCOORD0(uv=.xy)
        (0x0000_0020, 16, .uv),           // idx9  a_TexCoordVec4  float4 TEXCOORD0(uv0=.xy, uv1=.zw)
        (0x0000_0040,  8, .skip),         // idx10 a_TexCoordC1     float2 TEXCOORD1
        (0x0000_0080, 12, .skip),         // idx11 a_TexCoordVec3C1 float3 TEXCOORD1
        (0x0000_0100, 16, .skip),         // idx12 a_TexCoordVec4C1 float4 TEXCOORD1
        (0x0000_0200,  8, .skip),         // idx13 a_TexCoordC2     float2 TEXCOORD2
        (0x0000_0400, 12, .skip),         // idx14 a_TexCoordVec3C2 float3 TEXCOORD2
        (0x0000_0800, 16, .skip),         // idx15 a_TexCoordVec4C2 float4 TEXCOORD2
        (0x0000_1000,  8, .skip),         // idx16 a_TexCoordC3     float2 TEXCOORD3
        (0x0000_2000, 12, .skip),         // idx17 a_TexCoordVec3C3 float3 TEXCOORD3
        (0x0000_4000, 16, .skip),         // idx18 a_TexCoordVec4C3 float4 TEXCOORD3
        (0x0002_0000,  8, .skip),         // idx19 a_TexCoordC4     float2 TEXCOORD4
        (0x0004_0000, 12, .skip),         // idx20 a_TexCoordVec3C4 float3 TEXCOORD4
        (0x0008_0000, 16, .skip),         // idx21 a_TexCoordVec4C4 float4 TEXCOORD4
        (0x0010_0000,  8, .skip),         // idx22 a_TexCoordC5     float2 TEXCOORD5
        (0x0020_0000, 12, .skip),         // idx23 a_TexCoordVec3C5 float3 TEXCOORD5
        (0x0040_0000, 16, .skip),         // idx24 a_TexCoordVec4C5 float4 TEXCOORD5
        (0x0000_8000, 16, .skip),         // idx25 a_Color          float4 COLOR0(항상 맨 뒤 — 미독)
    ]

    /// 테이블이 덮는 비트 합집합 — 위 26엔트리를 OR 하면 **정확히 하위 26비트**(0x03FF_FFFF)다.
    /// 나머지 상위 6비트는 엔진 누산 루프가 아예 보지 않으므로(`0x140261b25 cmp rax, 0x1a` — 26엔트리를
    /// 돌 뿐이다) **스트라이드에 0 을 기여한다.** 우리도 똑같이 무시한다(종전엔 그런 비트가 하나라도
    /// 있으면 테이블을 통째로 포기하고 추측 경로로 갔다).
    /// 리터럴로 적지 않고 표에서 뽑는다 — 표만 고치고 이 상수를 안 고치면 새 엔트리가 조용히
    /// 무시되기 때문이다(돌연변이 검증에서 실제로 그 형태를 만들어 봤다).
    private static let vertexLayoutKnownBits: UInt32 = vertexLayoutTable.reduce(0) { $0 | $1.bit }

    /// 테이블 산출 레이아웃(오프셋은 정점 선두 기준 바이트). uv 는 float2/3/4 공통 선두 .xy 만 읽는다.
    private struct VertexLayout {
        var stride = 0
        var pos: Int? = nil, normal: Int? = nil, tangent: Int? = nil
        var boneIndices: Int? = nil, weights: Int? = nil, uv: Int? = nil
        /// TEXCOORD0 이 float4(idx9)일 때의 `.zw` 오프셋 = 라이트맵 UV(generic.frag `v_TexCoord.zw`).
        var uv1: Int? = nil
    }

    /// 테이블로 stride/채널 오프셋 산출. 상위 6비트(테이블 밖)는 엔진과 같이 무시하고, 위치 채널이
    /// 하나도 없는 플래그만 nil 로 돌려 호출측 추측 경로에 맡긴다(pos 없이 `.pos ?? 0` 으로
    /// 다른 채널을 좌표로 읽는 것을 막는다).
    private static func vertexLayout(for flag: UInt32) -> VertexLayout? {
        let effective = flag & vertexLayoutKnownBits
        guard effective != 0 else { return nil }
        var l = VertexLayout()
        for e in vertexLayoutTable where effective & e.bit != 0 {
            switch e.ch {
            case .position: if l.pos == nil { l.pos = l.stride }   // pos계열 다수 시 첫 채널(idx0 우선)
            case .normal: l.normal = l.stride
            case .tangent: l.tangent = l.stride
            case .boneIndices: l.boneIndices = l.stride
            case .weights: l.weights = l.stride
            case .uv:
                if l.uv == nil {
                    l.uv = l.stride
                    if e.size == 16 { l.uv1 = l.stride + 8 }       // float4 TEXCOORD0 → .zw = 라이트맵 UV
                }
            case .skip: break
            }
            l.stride += e.size
        }
        guard l.pos != nil else { return nil }
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
            // skinCount==0 이면 엔진도 이름을 안 읽는다(Model3DFormat.materialCount 주석) — 파스를
            // 버리지 말고 빈 경로로 진행한다. 렌더는 머티리얼 로드 실패로 이 메시만 건너뛴다.
            let material = materialList.first ?? ""
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
            // .rdata 테이블 원본 덤프(소비처 = `FUN_1400d7f90` 의 26엔트리 루프
            // `if (((&DAT_140484a20)[lVar8] & (uint)param_2) != 0)` … `while (lVar8 != 0x1a)` —
            // D3D 입력 레이아웃의 AlignedByteOffset 을 `iVar10 + (&DAT_1404849b0)[lVar8]` 로 누적)으로
            // 마스크/기여 상수 전수 확정 → vertexLayoutTable 로 구현.
            // **[정정 2026-08-30]** ~~`FUN_1400d8060.c:81-96`~~ → `FUN_1400d7f90`(−0xD0, manifest 확인).
            // 줄 번호는 재생성본에서 안 맞으므로 옮기지 않고 조건식으로 대체했다.
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
                // 인덱스 폭은 본경로(`let iWidth = (gateWord & 1) == 0 ? 2 : 4`)와 같은 규칙.
                guard let inferred = inferStride(bytes: bytes, indexBlobAt: q + 4 + vSize,
                                                 vSize: vSize,
                                                 indexWidth: (gateWord & 1) == 0 ? 2 : 4),
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
            //
            // **[정정 2026-08-30] 종전 이 판정에 `l.uv != nil` 이 붙어 있었다 — 테이블에 근거가 없다.**
            // 본/웨이트 채널의 유무는 idx5·idx6 비트가 정하고 TEXCOORD0(idx7‥9)과 독립이다.
            // 그 조건 때문에 TEXCOORD0 없는 스킨 플래그가 스키닝을 통째로 잃었다(실측:
            // 0x01800003 = pos|normal|blendIndices|blendWeights, stride 56 → skinned=false,
            // boneIndices=(0,0,0,0), weights=(0,0,0,0)). uv 부재는 uv 를 (0,0) 으로 만들 뿐이고
            // 본을 지울 이유가 아니다 — 아래 readVertices 의 uv 게이팅이 그것을 담당한다.
            let skinFieldsFit: Bool
            if let l = layout {
                skinFieldsFit = skinned && l.boneIndices != nil && l.weights != nil
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

            // 메시 트레일러(v≥21) — 엔진 정본 게이트 구조 정식 파스(디컴파일 FUN_140261880:1214-1457 +
            // 어셈블리 0x140261b6b-0x140262013; 실물 418파일 전수 착지 검증 2026-07-28):
            //   u8 gateA[≠0: u32 word + u32 size + blob] | u8 gateB[≠0: u32 size + blob(16B×N)]
            //   | (v≥23) u32 모프count + 레코드.
            // 전부 0 이면 v23 은 정확히 6바이트(= 종전 '6바이트 구분자'와 바이트 동형 — Kirby 의
            // gateB=1+16B 도 동형이라 종전 휴리스틱이 우연히 통과했던 것), v21/22 는 2바이트,
            // v<21 은 트레일러 자체 부재(엔진이 v≥21 에서만 리드 — `if (0x14 < iVar11)`, VA 0x140261b70,
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

        // 섹션 루프(MDLS/MDAT/MDLA/MDMP/MDLE)는 **v≥13 에서만** 존재한다. 엔진은 메시 루프를 빠져나온
        // 직후 `0x140262382 cmp edi, 0x0d` / `0x140262385 jl 0x140265a0c` 로 v<13 이면 섹션 리드를
        // 통째로 건너뛰고 함수를 끝낸다(v≥13 경로는 `0x1402623d8 call 0x14009c500` 으로 섹션 매직을
        // cstring 으로 읽고, `0x1402623ec cmp qword [rbp+0x258], 0` 에서 **빈 문자열이면 종료** —
        // 이것이 실물 v0014/0017/0023 파일 말미의 단일 NUL 이다. v0004 파일은 그 NUL 이 없고 마지막
        // 인덱스 바이트가 곧 EOF 다 — 설치본 8/8 실측).
        // → v<13 에서 매직 스캔을 돌리면 정점/인덱스 블롭 한복판의 우연한 "MDLS000x" 를 물 수 있다.
        //   설치본 v0004 8개는 메시 끝 == EOF 라 종전에도 스캔이 0바이트를 훑었지만, 규칙은 엔진과
        //   같은 자리에서 닫는다.
        let hasSections = Model3DFormat.hasSections(version: version)

        // 스켈레톤(스키닝 모델). MDLA 와 동일하게 메시 끝 이후 매직 스캔으로 찾는다 — V0021(MDLS0003)은
        // 마지막 메시와 스켈레톤 사이에 비제로 부가 블록이 있어(실물 3384019940 5/5 실측) 종전
        // '제로-스킵 후 정확 착지'로는 도달 불가였다. 실패/구조 불일치는 본 없이 반환(정적 메시 렌더 가능).
        // MDLS0002(V0016/17/19)는 본 레코드가 0004 와 동일(cstring|flags|parent|64|mat4|props cstring —
        // WLOP GIRL 64본 props JSON 실측)하고, MDLS0003(MDLV0021 짝)도 본 레코드 바이트 동형
        // (코퍼스 17퍼펫/7씬 matrix size 64 전수 실측). 본 레코드 뒤 꼬리(T1..T7 블록)는
        // parseSkeletonTail 로 정식 파스해 skeletonTail 에 노출 — 종전의 '13+80×본수 꼬리' 기록은
        // T1..T6 블록의 조합 근사치이고, '꼬리는 파스하지 않는다'는 정식 파스로 대체(실물 418파일
        // 전수 착지 검증 2026-07-28). 수용 버전 0002/0003/0004 — 미목격 버전은 계속 거부(추측 파스 금지).
        if hasSections, let si = findMagic("MDLS000", in: bytes, from: o), si + 9 <= bytes.count,
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
        if hasSections, !model.bones.isEmpty, let mi = findMagic("MDAT0001", in: bytes, from: o) {
            model.attachments = parseAttachments(bytes: bytes, at: mi, boneCount: model.bones.count)
        }

        // 애니 섹션(MDLA000N) — 스켈레톤 유무와 무관하게 메시 끝 이후 탐색(스키닝 모델만 존재).
        // 버전별 매직: 0016→MDLA0003, 0017→0004, 0019→0005, 0023→0006(실측). 헤더·레코드 레이아웃은
        // 전 버전 동일(36B 키, 코퍼스 전수 트레이스 일치) — 숫자만 다르니 접두 스캔으로 통합.
        if hasSections, let ai = findMagic("MDLA000", in: bytes, from: o),
           ai + 8 <= bytes.count, (0x31...0x39).contains(bytes[ai + 7]) {
            model.hasAnimation = true
            model.animations = parseAnimations(bytes: bytes, at: ai, boneCount: model.bones.count)
        }

        return model
    }

    /// MDAT0001 부착점 파스. 레이아웃(실측 7씬 다중 엔트리 정렬 전수 일치):
    /// "MDAT0001" | u8 0 | u32 nextOff | u16 count |
    /// count×(u16 본인덱스 | cstring 이름(UTF-8) | 64B float4x4 로컬).
    /// count 는 u16(엔진 정본: `FUN_140261880` 의 `strncmp(pcVar20,"MDAT0001",8)` 분기에서
    /// `FUN_140261680(…+0x38)` u16 리드 — 종전
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

    /// MDLA0003..0006 애니 파스(리싱크 기반). 헤더 animCount 는 link_adult 반례로 불신 —
    /// 각 클립 뒤 가변 꼬리(버전 게이트 블록 + 이벤트 블록, 최소 35B)를 다음 유효 헤더
    /// 리싱크(≤256B)로 스킵하고, 헤더 검증(모드∈집합, fps∈(0,240], 본수==skeleton)으로 종료를
    /// 판정한다. 꼬리 길이를 계산하지 않고 리싱크하는 이유는 두 트랙 배열의 **개수가 파일이 아니라
    /// 스켈레톤 객체**에서 오기 때문이다(파일만 보고는 못 센다 — 파일 머리 주석의 꼬리 표 참조).
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
            // p3: f32 fps | u32 frameCount | u32 flags | u32 boneCount — 넷이고, 그 다음이 곧
            // 본 0 의 trackFlags 다(0x140263a1b/0x140263a2d/0x140263a3d/0x140263a4d).
            guard let length = u32(p3 + 4), let bc = u32(p3 + 12), Int(bc) == boneCount else { return nil }
            return (name, mode, fps, Int(length), Int(bc), p3 + 16)
        }
        // 섹션 헤더: magic(8) | u8 0 | u32 nextOff | u32 animCount. 그 다음은 곧 **클립 0 의 u64 id** 다
        // — 종전 주석의 `u32 baseId | u32 0` 이 그 u64 의 두 절반이었다.
        var o = magicOff + 9
        guard u32(o) != nil else { return [] }
        // 헤더 리싱크는 클립 레코드의 **이름 cstring** 에 착지하므로, 그 클립의 u64 id 는 8바이트 앞이다.
        var idAt: Int? = o + 8
        o += 16                   // u32 nextOff | u32 animCount | u64 id
        var anims: [Model3D.Animation] = []
        while let h = tryHeader(o) {
            // C③: 이 클립의 id = 레코드 선두 u64. Int 범위를 넘으면 nil(이름 휴리스틱 폴백 유지).
            let clipId: Int? = idAt.flatMap { p in
                guard let lo = u32(p), let hi = u32(p + 4) else { return nil }
                return Int(exactly: UInt64(hi) << 32 | UInt64(lo))
            }
            o = h.off
            var tracks: [[Key]] = []
            tracks.reserveCapacity(h.bc)
            var ok = true
            for _ in 0..<h.bc {
                // 본 레코드 = u32 trackFlags(0x140263aa7) | u32 trackBytes(0x140263acb) | 트랙.
                // trackFlags 는 **크기가 아니라 플래그**다 — 비트0 은 엔진에서 클립 flags 에
                // 0x80000000 을 세우는 데만 쓰이고(0x140263c9d) 키 해석을 바꾸지 않으므로 버린다.
                guard u32(o) != nil, let tsRaw = u32(o + 4), tsRaw % 36 == 0,
                      o + 8 + Int(tsRaw) <= bytes.count else { ok = false; break }
                o += 8
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
                tracks.append(keys)
            }
            guard ok, tracks.count == h.bc else { break }
            // 리싱크: 가변 꼬리를 건너뛰고 다음 유효 헤더로(≤256B). 없으면 종료.
            var next: Int? = nil
            var d = 0
            while d <= 256 {
                if tryHeader(o + d) != nil { next = o + d; break }
                d += 1
            }
            // 이벤트 마커는 이 클립 꼬리(트랙 끝 o ~ 다음 헤더) 안의 JSON cstring — 엔진 쪽 정식
            // 레이아웃은 `u32 이벤트수(0x14026536d) | 수×(f32 초 0x1402653bd | cstring 0x1402653e0)`
            // 이지만 그 블록 **앞**의 두 트랙 배열 개수가 파일에 없어(스켈레톤 객체에서 온다) 시작
            // 오프셋을 계산할 수 없다 → 패턴 스캔으로 집는다(선행 f32 초 값은 JSON frame 과 중복이라
            // 무시). 마지막 클립은 섹션 끝까지 최대 512B.
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
                anim.id = clipId
                anims.append(anim)
            }
            guard let n = next else { break }
            // 다음 클립의 u64 id 는 그 헤더 8바이트 앞이다. 리싱크가 8바이트도 안 남기고 헤더를
            // 찾았다면 그 자리는 클립 경계가 아니므로 id 를 짓지 않는다(그릇된 값 대신 nil).
            idAt = (n - 8 >= o) ? n - 8 : nil
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
    /// 카운트)는 nil(호출측 폴백). 근거: 디컴파일 FUN_140261880:1214-1457 + 어셈블리
    /// (wallpaper64.exe): gateA 0x140261b6b-0x140261b96(u8 | u32 + u32 size + blob),
    /// gateB 0x140261b9b-0x140261bd7(u8 | u32 size + blob, size>>4 = 16B 레코드 수),
    /// 모프 0x140261bd7 `cmp edi,0x17`(v≥23 게이트) — 레코드: u64(0x1402616b0) |
    /// cstring(`FUN_14009c500`) | u32 flags | u32 n1 | n1×u32 | u32 n2 | n2×u32.
    /// **[정정 2026-08-30]** ~~`FUN_14009c5d0`~~ → `FUN_14009c500`(−0xD0, manifest 확인).
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
        // T1 태그 레코드(어셈블리 0x1402625d0-0x140262709: u16 C1 | C1 × (cstring | u32 | u32 | 64B)).
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
        // T3 u32 C2 | 엔트리(어셈블리 0x14026285f-0x140262952; 4번째 워드는 MDLS≥4 전용 `cmp r15d,4`).
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
        // 0x140262a34-0x140262bd0 로 복구: 외측 루프 C3 회 `cmp r13d,ebx`, 내측 D × (u32|2f|u32)).
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
        // D × (16B | u16 E | E×u32))) — 어셈블리 0x140262ccb-0x140263430.
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

    /// 변종 정점 스트라이드 추론: 정점 블롭 직후의 인덱스 블롭(`u32 크기 + 인덱스`)에서
    /// maxIndex+1 = 정점 수로 보고 vSize/count. 정수가 아니거나 범위(20..96) 밖이면 nil(안전 실패).
    ///
    /// **[2026-09-01 r4-40]** 인덱스 폭은 본경로와 **같은 규칙**(`gateWord & 1` → 2 or 4)으로
    /// 받는다. 종전에는 이 함수만 u16 쌍 고정 파스(`bytes[k] | bytes[k+1] << 8`, `k += 2`)라
    /// 본경로가 u32 로 읽는 파일에서 maxIndex 를 잘못 세어 스트라이드를 틀리게 추론했다.
    /// 도달: 설치본 45메시는 전건 gateWord 0 이라 u16 경로 그대로 — **이 머신 코퍼스에서는
    /// 비트동일**이고, 갈리는 것은 gateWord bit0 이 선 워크샵 `.mdl`(코퍼스 부재)뿐이다.
    private static func inferStride(bytes: [UInt8], indexBlobAt p: Int, vSize: Int,
                                    indexWidth: Int) -> Int? {
        guard indexWidth == 2 || indexWidth == 4 else { return nil }
        guard let iSizeU = readU32LE(bytes, at: p), iSizeU > 0,
              iSizeU % UInt32(indexWidth) == 0 else { return nil }
        let iSize = Int(iSizeU)
        guard p + 4 + iSize <= bytes.count else { return nil }
        var maxIdx = 0
        var k = p + 4
        let end = p + 4 + iSize
        while k + indexWidth - 1 < end {
            let v = indexWidth == 2
                ? Int(bytes[k]) | (Int(bytes[k + 1]) << 8)
                : Int(bytes[k]) | (Int(bytes[k + 1]) << 8)
                    | (Int(bytes[k + 2]) << 16) | (Int(bytes[k + 3]) << 24)
            if v > maxIdx { maxIdx = v }
            k += indexWidth
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
    ///
    /// **[정정 2026-08-30] uv0 도 normal/tangent 와 같은 규칙으로 게이팅한다.** 종전 두 자리는
    /// > `let uo = b + (layout?.uv ?? stride - 8)`  (스킨 분기)
    /// > `} else if let uo = layout?.uv ?? (stride >= 8 ? stride - 8 : nil) {`  (비스킨 분기)
    /// 였다. `layout?.uv` 는 **"테이블이 없다"** 와 **"테이블이 TEXCOORD0 없다고 말한다"** 를
    /// 구별하지 못한다(둘 다 `nil`) — 그래서 후자에서도 `stride − 8` 꼬리고정으로 떨어져
    /// **꼬리를 차지한 다른 채널의 바이트를 uv0 으로 읽었다.** 실측(flag→uv0):
    ///   `0x03`(pos+normal, stride 24) → normal.yz · `0x07`(+tangent, stride 40) → tangent.zw ·
    ///   `0x01`(pos만, stride 12) → position.yz. `vSize % stride == 0` 과 `maxIndex < vCount` 가
    ///   모두 성립하므로 어떤 가드도 울지 않는다 — 조용히 틀린 텍스처 좌표가 샘플러로 간다.
    /// 엔진 근거: 입력 레이아웃 조립부 `0x1400d7f90` 이 26엔트리를 돌며 **비트가 선 엔트리에만**
    /// `D3D11_INPUT_ELEMENT_DESC` 를 붙인다(`(&DAT_140484a20)[lVar8] & param_2` 로 마스크를 보고,
    /// 통과할 때만 `0x140482af0` 의 디스크립터를 복사한 뒤 `iVar10 += (&DAT_1404849b0)[lVar8]` 로
    /// 오프셋을 전진시킨다 — 부재 엔트리는 엘리먼트도 스트라이드 기여도 0). 즉 WE 에는
    /// 그 자리에 uv 속성이 **아예 없고** D3D 가 셰이더에 0 을 먹인다. 우리도 `.zero` 로 맞춘다.
    /// 꼬리고정 폴백은 `layout == nil`(추론 스트라이드) 경로 전용으로 남긴다 —
    /// `layout.map { $0.uv }` 가 그 두 경우를 갈라 준다(`Int??` → 바깥 nil 만 폴백).
    /// 실물 도달은 없다: 설치본 45메시 플래그는 0x09/0x0b/0x0f/0x27 전부 TEXCOORD0 비트를 단다.
    /// 짝 저장소 실물 `.mdl` 28개(`find . -name '*.mdl' | wc -l` = 28)를 이 수정 전후로 파스해
    /// 메시별 정점수·uv 합·웨이트 합·본인덱스 합을 대조했고 **45메시 전건 바이트 동일**이었다.
    /// 즉 이 수정은 실물 출력을 바꾸지 않는다 — 워크샵·손상 컨텐츠로만 닿는 잠재 구멍을 막는다.
    /// 합성 플래그로는 확실히 갈린다(위 실측 3종 + 스킨 0x01800003).
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
            // 두 번째 UV(라이트맵) — TEXCOORD0 이 float4 일 때의 `.zw`. 추론 경로는 채널 위치를
            // 모르므로 (0,0) 그대로(`Vertex.uv1` 주석의 generic.vert/frag 근거 참조).
            var uv1 = SIMD2<Float>.zero
            if let u1 = layout?.uv1 {
                guard let a = f32(b + u1), let c = f32(b + u1 + 4) else { return nil }
                uv1 = SIMD2(a, c)
            }
            if skinFieldsFit {
                // 테이블: 채널 오프셋 직독 / 추론 경로: 종전 꼬리고정.
                let bo = b + (layout?.boneIndices ?? stride - 40)
                let wo = b + (layout?.weights ?? stride - 24)
                // uv 오프셋은 normal/tangent 와 같은 규칙으로 고른다 — 테이블 경로에서
                // TEXCOORD0 부재는 "꼬리 8바이트" 가 아니라 채널 없음이다(이 함수 머리말의 정정 블록 참조).
                let uvOff = layout.map { $0.uv } ?? (stride >= 8 ? stride - 8 : nil)
                guard let b0 = u32(bo), let b1 = u32(bo + 4), let b2 = u32(bo + 8), let b3 = u32(bo + 12),
                      let w0 = f32(wo), let w1 = f32(wo + 4), let w2 = f32(wo + 8), let w3 = f32(wo + 12)
                else { return nil }
                var uv0 = SIMD2<Float>.zero
                if let uo = uvOff.map({ b + $0 }) {
                    guard let u = f32(uo), let v = f32(uo + 4) else { return nil }
                    uv0 = SIMD2(u, v)
                }
                vertices.append(Vertex(position: pos, normal: nrm, tangent: tan, uv: uv0,
                                       boneIndices: SIMD4(b0, b1, b2, b3), weights: SIMD4(w0, w1, w2, w3),
                                       uv1: uv1))
            } else if let uo = layout.map({ $0.uv }) ?? (stride >= 8 ? stride - 8 : nil) {
                // TEXCOORD0 가 float3/float4 여도 선두 .xy 만 읽는다(Kirby float4@28 — RE 테이블).
                guard let u = f32(b + uo), let v = f32(b + uo + 4) else { return nil }
                vertices.append(Vertex(position: pos, normal: nrm, tangent: tan, uv: SIMD2(u, v), uv1: uv1))
            } else {
                vertices.append(Vertex(position: pos, normal: nrm, tangent: tan, uv: .zero, uv1: uv1))
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
