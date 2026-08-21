import XCTest
@testable import WapleCore

/// 스프라이트**시트**(`.tex` TEXS) 규약 회귀 — `docs/re/sprite-occlusion.md` §10·§11 이 못박은
/// 사실만 잠근다. 여기서 다루는 것은 씬 오브젝트 `"sprite"`(오클루전 쿼리, §1–§9)가 **아니다**.
///
/// 잠그는 사실 넷:
///  1. `SPRITESHEETBLEND` 크로스페이드의 프레임 쌍은 `floor`/`frac` 분해이고, **다음 프레임은
///     마지막에서 랩하지 않고 멈춘다**(`min(n-1, cur+1)`).
///  2. `fallbackFrameTime` 은 **주사율의 역수 근사**다. 짝 `.tex-json` 의 `duration` 이 아니다.
///  3. 시트 게이트는 `.tex` 헤더 `flags & 0x4` **하나**이고 TEXS 섹션 존재와 동치다.
///  4. 실물 TEXS 프레임의 2×2 는 전부 **대각(축정렬)** 이다 — 일반 아핀(shear/회전) 실물이 없다.
final class TexSpriteSheetBlendTests: XCTestCase {

    // MARK: - 1. 크로스페이드 프레임 쌍 (WE common_particles.h:61-85 ComputeSpriteFrame)

    /// `currentFrame = floor(lifetime*n)` · `frameBlend = frac(lifetime*n)` 를 그대로 잰다.
    func testFramePairIsFloorFracDecomposition() {
        let p = TexImage.sheetFramePair(frameCoordinate: 3.25, frameCount: 8, crossfade: true)
        XCTAssertEqual(p.current, 3)
        XCTAssertEqual(p.next, 4)
        XCTAssertEqual(p.blend, 0.25, accuracy: 1e-6)

        let q = TexImage.sheetFramePair(frameCoordinate: 0, frameCount: 8, crossfade: true)
        XCTAssertEqual(q, TexImage.SheetFramePair(current: 0, next: 1, blend: 0))
    }

    /// **랩이 아니라 클램프**다: `nextFrame = min(numFrames - 1.0, currentFrame + 1.0)`.
    /// 시트 끝에서 0번 프레임이 겹쳐 나오면(= `(cur+1) % n`) 한 프레임짜리 되감기 깜빡임이 된다.
    func testNextFrameClampsAtLastFrameInsteadOfWrapping() {
        let p = TexImage.sheetFramePair(frameCoordinate: 7.9, frameCount: 8, crossfade: true)
        XCTAssertEqual(p.current, 7)
        XCTAssertEqual(p.next, 7, "마지막 프레임의 next 는 자기 자신이어야 한다(랩 금지)")
        XCTAssertEqual(p.blend, 0.9, accuracy: 1e-5)

        // 좌표가 시트를 넘어가면 current 는 감기지만(= 소비처의 `% n` 규약) 그 뒤의 next 는
        // 다시 클램프 규약을 탄다 — 두 규약이 섞이지 않는 것을 못박는다.
        let wrapped = TexImage.sheetFramePair(frameCoordinate: 15.5, frameCount: 8, crossfade: true)
        XCTAssertEqual(wrapped.current, 7)
        XCTAssertEqual(wrapped.next, 7)
    }

    /// `randomframe` = 크로스페이드 **꺼짐**. WE 는 `#if SPRITESHEETBLEND` 로 프래그먼트 문면을
    /// 갈라 샘플을 한 번만 뜬다 — 두 번째 프레임이라는 개념 자체가 없다.
    /// 여기서는 `next == current` · `blend == 0` 으로 표현해, 소비처가 `mix` 를 그대로 써도
    /// 정확히 현재 프레임이 나오게 한다(IEEE: `x + 0*(x-x) == x`).
    func testCrossfadeOffCollapsesToCurrentFrame() {
        let off = TexImage.sheetFramePair(frameCoordinate: 3.25, frameCount: 8, crossfade: false)
        XCTAssertEqual(off.current, 3)
        XCTAssertEqual(off.next, 3)
        XCTAssertEqual(off.blend, 0)
    }

    /// 프레임이 1장 이하 / 비유한 좌표 / `Int` 범위 밖은 정지(0,0,0).
    func testFramePairDegenerateInputs() {
        let stopped = TexImage.SheetFramePair(current: 0, next: 0, blend: 0)
        XCTAssertEqual(TexImage.sheetFramePair(frameCoordinate: 5, frameCount: 1, crossfade: true), stopped)
        XCTAssertEqual(TexImage.sheetFramePair(frameCoordinate: 5, frameCount: 0, crossfade: true), stopped)
        XCTAssertEqual(TexImage.sheetFramePair(frameCoordinate: .nan, frameCount: 8, crossfade: true), stopped)
        XCTAssertEqual(TexImage.sheetFramePair(frameCoordinate: .infinity, frameCount: 8, crossfade: true), stopped)
        XCTAssertEqual(TexImage.sheetFramePair(frameCoordinate: 1e30, frameCount: 8, crossfade: true), stopped,
                       "Int 범위 밖 — Swift 의 Int(Float) 는 클램프가 아니라 트랩이다")
        // 음수 좌표(되감기)는 감는다 — spriteFrameIndex 의 음수 시간 규약과 같다.
        let back = TexImage.sheetFramePair(frameCoordinate: -0.5, frameCount: 8, crossfade: true)
        XCTAssertEqual(back.current, 7)
        XCTAssertEqual(back.blend, 0.5, accuracy: 1e-6)
    }

    // MARK: - 2. fallbackFrameTime = 주사율의 역수 근사 (사이드카 duration 이 아니다)

    /// WE 는 `frametime == 0` 인 시트에 **아무 값도 안 쓴다** — 진행기
    /// (`0x14015f0d0`–`0x14015f326`)의 `comiss`(`0x14015f1c9`) / `subss`(`0x14015f1d8`) /
    /// `minss`(`0x14015f208`) 가 **렌더 프레임당 정확히 한 프레임**을 전진시킨다.
    /// 그래서 시간 기반 폴백의 올바른 목표값은 "1 / 주사율" 이고, 60Hz 에서 0.016 ≈ 1/62.5 다.
    ///
    /// 종전 주석이 제안했던 `1.0 / frameCount`(짝 `.tex-json` 의 `duration: 1` 근거)는
    /// **런타임이 그 파일을 읽지 않아서** 틀린 제안이다(`spritesheetsequences` 문자열이
    /// `wallpaper64.exe` 에 0개). 이 테스트가 그 되돌림을 막는다.
    func testFallbackFrameTimeApproximatesOneRenderFrameAt60Hz() {
        XCTAssertEqual(TexImage.fallbackFrameTime, 1.0 / 60.0, accuracy: 0.001,
                       "폴백은 '초/프레임' 저작값이 아니라 '1 렌더 프레임' 근사여야 한다")
    }

    /// 프레임 수와 **무관**하다는 것 — `1.0 / frameCount` 로 되돌리면 4프레임 시트의 한 바퀴가
    /// 0.064s 에서 1.0s 로 15배 늘어나 이 단언이 깨진다.
    func testZeroFrameTimeSheetCycleIsFrameCountTimesFallback() {
        func sheet(_ n: Int) -> [TexImage.TexFrame] {
            (0..<n).map { TexImage.TexFrame(imageId: 0, time: 0, x: Float($0) * 8, y: 0, width: 8, height: 8) }
        }
        let ft = TexImage.fallbackFrameTime
        for n in [4, 8, 64] {
            let frames = sheet(n)
            // 각 프레임의 중앙 시각이 그 프레임을 가리킨다.
            for k in 0..<n {
                XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: (Float(k) + 0.5) * ft), k,
                               "n=\(n) k=\(k)")
            }
            // 한 바퀴 = n × fallback.
            XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: Float(n) * ft + 0.5 * ft), 0,
                           "n=\(n) 한 바퀴 랩")
        }
    }

    /// 위 테스트는 `fallbackFrameTime` 자기 자신을 단위로 쓰므로 **상수를 바꿔도 안 깨진다**
    /// (돌연변이 M3 로 실측 확인). 그래서 여기서 **절대 시각**으로 한 번 더 못박는다 —
    /// 4프레임 무-frametime 시트에서 `t=0.02` 는 프레임 1, `t=0.055` 는 프레임 3이어야 한다.
    /// 이 두 단언은 폴백을 대략 `[1/62.5, 1/60]` 구간에 가둔다:
    ///   · 0.016(현행) 경계 0.016/0.032/0.048/0.064 → 1, 3 ✓
    ///   · 1/60(권장 개선) 경계 0.0167/0.0333/0.05/0.0667 → 1, 3 ✓ (그래서 개선을 막지 않는다)
    ///   · 철회된 `1/frameCount`(=0.25) → 둘 다 0 ✗ (잡힌다)
    ///   · 지나치게 빠른 값(예 0.001) → `t=0.02` 가 0 ✗ (잡힌다)
    func testZeroFrameTimeSheetPlaysAtRoughlyOneRenderFramePerSheetFrame() {
        let frames = (0..<4).map {
            TexImage.TexFrame(imageId: 0, time: 0, x: Float($0) * 8, y: 0, width: 8, height: 8)
        }
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.02), 1,
                       "폴백이 너무 빠르다 — 0.02s 에 두 번째 프레임이어야 한다")
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.055), 3,
                       "폴백이 너무 느리다 — 0.055s 에 네 번째 프레임이어야 한다(1/frameCount 면 0 이다)")
    }

    // MARK: - 3·4. 동봉 코퍼스 — 게이트 비트와 프레임 지오메트리

    private func bundledTex() throws -> [(rel: String, tex: TexImage)] {
        guard let root = AssetJSONLenientTests.bundledAssetsRoot() else {
            throw XCTSkip("WAPLE_WE_ASSETS 미지정 — 동봉 자산 트리를 못 찾았다")
        }
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("자산 트리를 못 훑었다"); return []
        }
        var out: [(String, TexImage)] = []
        for case let url as URL in en where url.pathExtension == "tex" {
            guard let d = try? Data(contentsOf: url), let t = TexImage.parse(d) else { continue }
            out.append((String(url.path.dropFirst(root.path.count + 1)), t))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// WE 의 시트 술어는 **4명령 리프 하나**다(`CTexture::IsSpriteSheet` `0x14015c470`:
    /// `mov eax,[rcx+0x1c]` · `shr eax,2` · `and al,1` · `ret`). 같은 비트가
    ///   · 프레임 진행기 진입 게이트(`0x14015f0f7 test byte ptr [rcx+0x1c], 4`) 와
    ///   · `SPRITESHEET` 콤보(`0x1401d04a5 or dword ptr [r13+8], 0x1000000` — 파티클 flags
    ///     워드에 이 비트를 세우는 유일한 자리. 소비 `0x1401d2d89 test dword ptr [r15+8], 0x1000000`)
    /// 를 **둘 다** 켠다. Waple 은 그 비트를 `isGif` 로 읽는다.
    func testSheetGateIsTexFlagsBit2AndMatchesTEXSPresence() throws {
        let files = try bundledTex()
        XCTAssertGreaterThanOrEqual(files.count, 311, "동봉 `.tex` 가 줄었다 — 경로/자산 확인")
        var sheets = 0
        var mismatch: [String] = []
        for (rel, t) in files {
            XCTAssertEqual(t.isGif, t.flags & 0x4 != 0, "\(rel) isGif 가 flags bit2 가 아니다")
            if t.isGif { sheets += 1 }
            if t.isGif != !t.frames.isEmpty { mismatch.append(rel) }
        }
        XCTAssertEqual(mismatch, [], "flags bit2 와 TEXS 섹션 존재가 어긋났다")
        XCTAssertGreaterThanOrEqual(sheets, 52, "동봉 시트 52건(2026-08-21 실측)")
    }

    /// **[도달 측정 — 일반 아핀은 실물이 없다]** WE 는 프레임 지오메트리 6개를 그대로
    /// `g_TextureNRotation`(2×2 vec4, `0x14015f2a3`–`0x14015f2bc`) +
    /// `g_TextureNTranslation`(vec2, `0x14015f2d3`/`0x14015f2da`) 로 올려서 **임의의 아핀**을
    /// 표현할 수 있다. 그런데 실물은 전부 대각이다 — 동봉 52시트 1876프레임 · 설치본 61시트
    /// 1912프레임 전건이 `widthY == heightX == 0` 이고 `width > 0` · `height > 0` 이다.
    /// 즉 Waple 의 축정렬 서브렉트(+`rotationQuarters`)가 측정 도달 100% 를 덮는다.
    /// 회전/전단 프레임 실물이 들어오면 이 테스트가 먼저 깨진다(그때 아핀 배선을 하면 된다).
    /// 워크샵 코퍼스는 이 컨테이너에 없어 **미측정**이다(0 이 아니다).
    func testBundledSheetFramesAreAllAxisAligned() throws {
        let files = try bundledTex()
        var frameCount = 0
        var sheetCount = 0
        var offDiagonal: [String] = []
        var rotated: [String] = []
        for (rel, t) in files where !t.frames.isEmpty {
            sheetCount += 1
            for f in t.frames {
                frameCount += 1
                if f.widthY != 0 || f.heightX != 0 { offDiagonal.append(rel) }
                if f.rotationQuarters != 0 { rotated.append(rel) }
            }
        }
        XCTAssertGreaterThanOrEqual(sheetCount, 52)
        XCTAssertGreaterThanOrEqual(frameCount, 1876, "동봉 TEXS 프레임 총수(2026-08-21 실측)")
        XCTAssertEqual(Set(offDiagonal).sorted(), [], "오프대각(widthY/heightX 비영) 프레임이 생겼다")
        XCTAssertEqual(Set(rotated).sorted(), [], "회전 프레임(rotationQuarters != 0) 실물이 생겼다")
    }

    /// TEXS0002(= 파일에 재생속도가 없는 버전) 실물 8건이 그대로인지. 이 8건이 곧
    /// `fallbackFrameTime` 의 유일한 소비 대상이다 — 도달이 커지면 값 논의를 다시 해야 한다.
    func testTEXS0002ReachIsEightBundledFiles() throws {
        let files = try bundledTex()
        let v2 = files.filter { $0.tex.framesVersion == 2 }.map(\.rel).sorted()
        XCTAssertEqual(v2.count, 8, "TEXS0002 동봉 도달(2026-08-21 실측 8건): \(v2)")
        for (rel, t) in files where t.framesVersion == 2 {
            XCTAssertTrue(t.frames.allSatisfy { $0.time == 0 },
                          "\(rel) TEXS0002 는 전 프레임 frametime 0 이어야 한다")
        }
    }
}
