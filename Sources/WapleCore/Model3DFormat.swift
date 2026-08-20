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

    /// 메시마다 읽는 머티리얼 cstring 개수 = 헤더 오프셋 13 의 skinCount(스킨 = **같은 메시의 재질
    /// 변형**, 모델 옵션 json 의 `skins` 배열과 1:1). 실측 분포는 {1: 450, 2: 1}.
    /// 0 은 실물 미목격 — 방어적으로 1 개(종전 동작)로 본다. 폭주값은 nil 로 거부한다.
    public static func materialCount(skinCount: UInt32) -> Int? {
        if skinCount == 0 { return 1 }
        guard skinCount <= 256 else { return nil }
        return Int(skinCount)
    }
}
