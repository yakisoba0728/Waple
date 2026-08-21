import Foundation

/// `.mdl` 메시 섹션의 **버전 게이트** — 순수 바이트 레이아웃 규칙만 담는다(simd 무의존).
///
/// Model3D.swift 는 `import simd` 라 Apple 플랫폼 밖에서는 타입체크조차 못 한다. 버전 게이트는
/// 부동소수 벡터와 아무 상관이 없는 정수 판정이라 여기로 분리한다 — 이 파일 하나는 Foundation
/// 만으로 서고, 표 자체를 격리해 단위 테스트할 수 있다.
///
/// 게이트 상수는 전부 wallpaper64.exe 의 MDL 디코더 `0x140261880`(원본 주소. Ghidra 산출물의
/// `FUN_140261950` 은 rich header 주입본이라 +0xD0 밀려 있다 — `spec/engine/decompilation-provenance.json`)
/// 을 직접 디스어셈블해 확인했다. 리더 프리미티브도 같이 확인했다:
/// `0x14009c560`=readU32(커서 +4), `0x14009c590`=readFloat(+4), `0x1402616e0`=readU8(+1),
/// `0x14009c5c0`=readBlob(u32 size + bytes).
///
///     0x1402619a6  cmp edi, 0x11 / jl   → version < 17 이면 AABB 24B 를 건너뛴다
///     0x140261a19  cmp edi, 0x0f / jl   → version < 15 이면 per-mesh formatFlag(u32) 리드 자체가 없다
///     0x140261b61  cmp edi, 0x15 / jl   → version < 21 이면 메시 트레일러가 없다
///     0x140261979  cmp edi, 0x04 / jl   → version < 4 이면 gateWord = 0 (리드 없음)
///     0x14026193e  cmp [r15+8], ebx     → 머티리얼 cstring 을 skinCount 개 읽는 루프.
///                                         **메시 루프(head 0x14026192c, back-edge 0x140262327) 안**이다.
///
/// 실물 교차검증(WE 2.8.42 설치본 .mdl 28개 전수, 프레이밍 브루트포스): 파일마다 파스+착지가
/// 성립하는 프레이밍이 **정확히 하나**뿐이고 그것이 아래 표와 일치한다. 로제타석 `.obj`↔`.mdl`
/// 16쌍(v0004 4쌍, v0014 8쌍, v0023 4쌍) 바이트 대조도 통과 — `scripts/spec/verify_rosetta.py`.
public enum Model3DFormat {
    /// 실물 바이트를 본 버전만 담는다. 미목격(0015/0018/0020/0022 …)은 계속 거부한다 —
    /// 레이아웃을 모르는 채 추측 파스로 이상 렌더를 만드느니 스킵이 낫다.
    ///
    /// | 버전 | 실물 도수 | AABB | per-mesh flag | 트레일러 |
    /// |---|---|---|---|---|
    /// | 0004 | 설치본 8 | 없음 | 없음 | 없음 |
    /// | 0014 | 설치본 15 | 없음 | 없음 | 없음 |
    /// | 0016 | 코퍼스 8 | 없음 | 있음 | 없음 |
    /// | 0017 | 설치본 1 + 코퍼스 2 | 있음 | 있음 | 없음 |
    /// | 0019 | 코퍼스 18 | 있음 | 있음 | 없음 |
    /// | 0021 | 코퍼스 17 | 있음 | 있음 | 있음 |
    /// | 0023 | 설치본 4 + 코퍼스 378 | 있음 | 있음 | 있음(+모프) |
    public static let supportedVersions: Set<Int> = [4, 14, 16, 17, 19, 21, 23]

    /// `"MDLV%04d"` → 버전 번호. MDLV 매직이 아니거나 미목격 버전이면 nil.
    public static func version(ofMagic magic: String) -> Int? {
        guard magic.count == 8, magic.hasPrefix("MDLV") else { return nil }
        // 숫자 4자리만 허용한다 — Int("0x14") 류 파싱 사고 방지.
        let digits = magic.dropFirst(4)
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int(digits) else { return nil }
        return supportedVersions.contains(v) ? v : nil
    }

    /// 메시 헤더에 AABB(min 3f, max 3f = 24B)가 있는가.
    public static func hasAABB(version: Int) -> Bool { version >= 17 }

    /// 메시마다 u32 formatFlag 를 다시 읽는가. false(v ≤ 14)면 **헤더 오프셋 9 의 formatFlag** 를
    /// 그대로 쓴다 — 엔진도 메시 루프 진입마다 r10d 를 헤더 값으로 되돌린다(0x140262318).
    public static func hasPerMeshFormatFlag(version: Int) -> Bool { version >= 15 }

    /// 메시 뒤 트레일러(게이트A/B 블롭 + v≥23 모프 레코드)가 있는가.
    public static func hasMeshTrailer(version: Int) -> Bool { version >= 21 }

    /// 메시 전부를 읽은 **뒤** 섹션 루프(MDLS/MDAT/MDLA/MDMP/MDLE)를 도는가 = v ≥ 13.
    ///
    ///     0x140262382  cmp edi, 0x0d       → edi = atoi(매직+4) = 버전
    ///     0x140262385  jl  0x140265a0c     → v < 13 이면 섹션을 **한 바이트도 안 읽고** 끝낸다
    ///     0x1402623d8  call 0x14009c500    → v ≥ 13: 섹션 매직을 cstring 으로 읽고
    ///     0x1402623ec  cmp qword [rbp+0x258], 0 / je → **빈 문자열이면 루프 종료**
    ///
    /// 마지막 줄이 실물의 파일 말미 단일 NUL 의 정체다 — v0014/0017/0023 설치본 20/20 이 그 NUL 로
    /// 끝나고, v0004 설치본 8/8 은 마지막 인덱스 바이트가 곧 EOF 다(NUL 없음). 이 차이가 v0004 와
    /// v0014 의 유일한 컨테이너 차이이기도 하다(둘 다 AABB·per-mesh flag·트레일러가 없다).
    public static func hasSections(version: Int) -> Bool { version >= 13 }

    /// 메시 헤더의 `gateWord` 뒤에 붙는 **여분 u32 개수** — bit1 이 서면 정확히 1개, 아니면 0개.
    /// 브루트포스 탐색이 아니라 **결정론적 분기**다(엔진은 `if` 하나뿐이라 2개 이상은 발생 불가):
    ///
    ///     0x140261979  cmp edi, 4 / jl 0x14026198a  → v<4 면 gateWord 리드 자체가 없다(eax=0 대입)
    ///     0x140261983  call 0x14009c560             → gateWord = readU32()
    ///     0x14026198c  mov [rbp+0x88], eax          → 메시 구조체 +0x88 에 gateWord 보관
    ///     0x140261992  test al, 2                   → **gateWord & 2** (bit1)
    ///     0x140261994  je 0x1402619a6               → 안 서면 곧장 AABB 게이트로
    ///     0x14026199b  call 0x14009c560             → 서면 u32 를 **딱 한 번** 더 읽고
    ///     0x1402619a0  mov [rbp+0x8c], eax          → +0x8c(gateWord 바로 뒤 슬롯)에 보관
    ///     0x1402619a6  cmp edi, 0x11                → 그다음이 AABB(v≥17) 게이트
    ///
    /// 필드 오프셋도 같은 말을 한다 — +0x88 gateWord, +0x8c 여분, +0x90..+0xa4 AABB 6f,
    /// +0xa8 per-mesh formatFlag 로 이어지는 연속 구조체다.
    public static func extraMeshHeaderWords(gateWord: UInt32) -> Int {
        (gateWord & 2) != 0 ? 1 : 0
    }

    /// MDLS 스켈레톤의 **본 개수 상한 = 128**. 엔진은 초과를 "거부"하지 않는다 — 즉사시킨다:
    ///
    ///     0x1402624f4  call 0x14009c560   → boneCount = readU32()
    ///     0x1402624f9  mov r15d, eax      → 이 값이 본 레코드 루프의 상한(0x1402625bd `cmp esi, r15d`)
    ///     0x140262501  cmp eax, 0x80      → **0x80 = 128**
    ///     0x140262506  jbe 0x14026250c    → 128 **이하**만 통과(초과 시 아래로 낙하)
    ///     0x140262508  xor ecx, ecx
    ///     0x14026250a  int 0x29           → __fastfail(0) = 프로세스 즉사
    ///     0x140262516  call 0x140269330   → vector<본>.resize(boneCount), 원소 0xF0(240B)
    ///
    /// 비교 대상이 본 개수임은 두 갈래로 확정된다: ① 같은 eax(=r15d)가 본 레코드 루프
    /// (0x140262530–0x1402625c0)의 상한이고, ② 그 루프가 원소 0xF0 짜리 벡터를 훑으며
    /// cstring 이름 → u32(+0x64) → u32 parent(+0x60) → 64B 행렬(+0x20) → cstring props(+0x68)
    /// 를 읽는다 = Waple `Bone` 레코드와 동형.
    ///
    /// 같은 함수의 다른 `int 0x29` 는 전부 런타임 크기와의 비교(하드닝된 인덱스 검사)인데
    /// 여기만 **리터럴 0x80** 이다 — 컴파일타임 상한, 즉 포맷 규약이다.
    ///
    /// Waple 은 죽지 않는다 — 상한 초과면 본 없이(정적 메시) 진행한다. 엔진이 즉사하는 파일은
    /// 애초에 배포될 수 없으므로 실물 회귀 위험은 없고, 매직 스캔 오탐이 뽑은 폭주 카운트를
    /// 종전 `< 100_000` 보다 훨씬 이르게 잘라 낸다.
    public static let maxBoneCount = 128

    /// 메시마다 읽는 머티리얼 cstring 개수 = 헤더 오프셋 13 의 skinCount(스킨 = **같은 메시의 재질
    /// 변형**, 모델 옵션 json 의 `skins` 배열과 1:1). 설치본 실측 분포 {1: 27파일, 2: 1파일}
    /// (audiophile `models/grid/grid.mdl` 만 2 — `materials/grid/grid.json` + `grid2.json`).
    ///
    /// **0 이면 0개다**(2026-08-21 정정). 엔진의 리드 루프는 카운터를 0 으로 놓고
    /// `0x14026193e cmp dword [r15+8], ebx` / `0x140261942 jbe 0x140261979` 로 먼저 재므로
    /// skinCount==0 이면 cstring 을 **한 개도 안 읽고** gateWord 로 넘어간다(`[r15+8]` 이
    /// `0x1402618fb` 에서 저장된 skinCount). 종전 구현은 여기서 1개를 읽어 이후 전 오프셋을
    /// cstring 길이만큼 밀었다 — 실물 미목격이라 회귀는 없지만, 엔진과 다르게 읽는 자리였다.
    /// 폭주값(>256)은 nil 로 거부한다(엔진은 상한이 없다 — 이쪽은 방어).
    public static func materialCount(skinCount: UInt32) -> Int? {
        guard skinCount <= 256 else { return nil }
        return Int(skinCount)
    }
}
