import XCTest
import simd
@testable import WapleCore

/// TEXS 스프라이트시트 프레임 파스(실물 "particles 256x1280".tex 로 리버스한 레이아웃) +
/// mapsequence 이니셜라이저(CP 각도/구간 → 시퀀스) + 시퀀스→시트 폴드(sheetFrameIndex).
final class TexFramesAndMapSequenceTests: XCTestCase {

    /// 실측 레이아웃 그대로 합성: TEXV0005 헤더(42B) + raw RGBA 페이로드 + TEXS0003 섹션.
    private func makeTexWithFrames() -> Data {
        var b = [UInt8]()
        b.append(contentsOf: Array("TEXV0005".utf8)); b.append(0)          // 0..8
        b.append(contentsOf: Array("TEXI0001".utf8)); b.append(0)          // 9..17
        b += i32(0)      // format 0 (raw RGBA)                                18
        b += i32(0)      //                                                    22
        b += i32(2) + i32(1)   // texW, texH                                   26, 30
        b += i32(2) + i32(1)   // imgW, imgH                                   34, 38
        b.append(contentsOf: [255, 0, 0, 255,  0, 255, 0, 255])            // 2x1 RGBA
        b.append(contentsOf: Array("TEXS0003".utf8)); b.append(0)
        b += i32(2)          // frameCount
        b += i32(256) + i32(256)   // gifW, gifH (v3)
        // frame0: id0, t0.2, x0, y0, w256, unk, unk, h256
        b += bytes(i32(0), f32(0.2), f32(0), f32(0), f32(256), f32(0), f32(0), f32(256))
        // frame1: x=256
        b += bytes(i32(0), f32(0.2), f32(256), f32(0), f32(256), f32(0), f32(0), f32(256))
        return Data(b)
    }

    func testTexFramesParse() {
        guard let tex = TexImage.parse(makeTexWithFrames()) else { return XCTFail("parse nil") }
        XCTAssertEqual(tex.frames.count, 2)
        XCTAssertEqual(tex.frames[0].time, 0.2, accuracy: 1e-5)
        XCTAssertEqual(tex.frames[0].x, 0); XCTAssertEqual(tex.frames[0].width, 256)
        XCTAssertEqual(tex.frames[1].x, 256); XCTAssertEqual(tex.frames[1].height, 256)
    }

    /// 회전 프레임(RePKG): Width=0, HeightX 가 (부호 있는) 유효 폭. 종전 w>0 가드였다면 프레임 목록
    /// 전체가 [] 로 버려졌다 — 이제 유효 크기 기준으로 살아남고 atlas*/rotationQuarters 가 도출된다.
    private func makeTexWithRotatedFrame() -> Data {
        var b = [UInt8]()
        b.append(contentsOf: Array("TEXV0005".utf8)); b.append(0)
        b.append(contentsOf: Array("TEXI0001".utf8)); b.append(0)
        b += bytes(i32(0), i32(0), i32(2), i32(1), i32(2), i32(1))
        b.append(contentsOf: [255, 0, 0, 255,  0, 255, 0, 255])
        b.append(contentsOf: Array("TEXS0003".utf8)); b.append(0)
        b += i32(1)                 // frameCount
        b += i32(256) + i32(256)    // gifW, gifH
        // id0, t0.2, x256, y0, Width0, WidthY0, HeightX(-256), Height128 → 90/270° 회전
        b += bytes(i32(0), f32(0.2), f32(256), f32(0), f32(0), f32(0), f32(-256), f32(128))
        return Data(b)
    }

    func testRotatedFrameNotDropped() {
        guard let tex = TexImage.parse(makeTexWithRotatedFrame()) else { return XCTFail("parse nil") }
        XCTAssertEqual(tex.frames.count, 1, "회전 프레임이 드롭되지 않음")
        let fr = tex.frames[0]
        XCTAssertEqual(fr.width, 0)           // raw Width==0
        XCTAssertEqual(fr.heightX, -256)      // raw HeightX(부호)
        XCTAssertEqual(fr.atlasWidth, 256)    // |HeightX|
        XCTAssertEqual(fr.atlasHeight, 128)   // |Height|
        XCTAssertEqual(fr.atlasX, 0)          // min(256, 256+(-256))
        XCTAssertEqual(fr.atlasY, 0)
        XCTAssertEqual(fr.rotationQuarters, 3)  // signedW<0, signedH>0 → (-,+)
    }

    /// 비회전 프레임은 rotationQuarters==0, atlas*==raw — 기존 UV 경로와 동일(무회귀 보증).
    func testNonRotatedFrameIdentityMapping() {
        guard let tex = TexImage.parse(makeTexWithFrames()) else { return XCTFail("parse nil") }
        let fr = tex.frames[0]
        XCTAssertEqual(fr.rotationQuarters, 0)
        XCTAssertEqual(fr.atlasX, fr.x); XCTAssertEqual(fr.atlasY, fr.y)
        XCTAssertEqual(fr.atlasWidth, fr.width); XCTAssertEqual(fr.atlasHeight, fr.height)
    }

    /// 양 축 모두 0(퇴화)이면 프레임 목록 전체 드롭(안전망 유지).
    func testDegenerateZeroFrameDropped() throws {
        var b = [UInt8]()
        b.append(contentsOf: Array("TEXV0005".utf8)); b.append(0)
        b.append(contentsOf: Array("TEXI0001".utf8)); b.append(0)
        b += bytes(i32(0), i32(0), i32(2), i32(1), i32(2), i32(1))
        b.append(contentsOf: [255, 0, 0, 255,  0, 255, 0, 255])
        b.append(contentsOf: Array("TEXS0003".utf8)); b.append(0)
        b += bytes(i32(1), i32(256), i32(256))
        b += bytes(i32(0), f32(0.2), f32(0), f32(0), f32(0), f32(0), f32(0), f32(0))  // Width=Height=HeightX=WidthY=0
        // 퇴화 프레임은 드롭하되 parse 자체는 성공해야 한다 — if-let 형태는 nil 회귀를 조용히 통과시키므로 XCTUnwrap 으로 잠근다.
        let tex = try XCTUnwrap(TexImage.parse(Data(b)), "퇴화 프레임 입력도 전체 거부가 아니라 파스 성공이어야")
        XCTAssertEqual(tex.frames, [])
    }

    func testTexWithoutFramesHasEmptyFrames() throws {
        var d = makeTexWithFrames()
        d = d.prefix(50)   // TEXS 섹션 절단
        let tex = try XCTUnwrap(TexImage.parse(d), "TEXS 절단 입력도 전체 거부가 아니라 파스 성공이어야")
        XCTAssertTrue(tex.frames.isEmpty)
    }

    /// TEXS0001(v1): 지오메트리가 i32 정수형(RePKG 실측 — frametime 만 f32, gifW/H 없음).
    /// v3 와 달리 x/y/w/h 를 정수 바이트로 넣는다.
    private func makeTexWithFramesV1() -> Data {
        var b = [UInt8]()
        b.append(contentsOf: Array("TEXV0005".utf8)); b.append(0)
        b.append(contentsOf: Array("TEXI0001".utf8)); b.append(0)
        b += i32(0) + i32(0)    // format 0(raw RGBA), unk
        b += i32(2) + i32(1)    // texW, texH
        b += i32(2) + i32(1)    // imgW, imgH
        b.append(contentsOf: [255, 0, 0, 255,  0, 255, 0, 255])   // 2x1 RGBA
        b.append(contentsOf: Array("TEXS0001".utf8)); b.append(0)
        b += i32(2)             // frameCount (v1: gifW/H 없음)
        // v1 프레임 32B: i32 id | f32 frametime | i32 x | i32 y | i32 w | i32 widthY | i32 heightX | i32 h
        b += bytes(i32(0), f32(0.2), i32(0),   i32(0), i32(256), i32(0), i32(0), i32(256))
        b += bytes(i32(0), f32(0.2), i32(256), i32(0), i32(256), i32(0), i32(0), i32(256))
        return Data(b)
    }

    func testTexFramesParseV1_integerGeometry() {
        guard let tex = TexImage.parse(makeTexWithFramesV1()) else { return XCTFail("parse nil") }
        XCTAssertEqual(tex.frames.count, 2)
        XCTAssertEqual(tex.frames[0].time, 0.2, accuracy: 1e-5)  // frametime 은 v1 도 f32
        // 정수 지오메트리를 f32 로 오독하면 x=256 이 ≈0(denormal)이 되어 실패 — i32 경로 실측.
        XCTAssertEqual(tex.frames[0].x, 0); XCTAssertEqual(tex.frames[0].width, 256)
        XCTAssertEqual(tex.frames[1].x, 256); XCTAssertEqual(tex.frames[1].height, 256)
    }

    /// 이미지 레이어 스프라이트 재생: 씬 시간 → 프레임 인덱스(가변 frametime 누적 + 루프 랩).
    /// 파티클 sheetFrameIndex(시퀀스→시트 폴드)와 별개 — 이쪽은 시간축 재생 클럭(정본 TexFrame.time).
    func testSpriteFrameIndex_constantFrametimeLoops() {
        let f = { (t: Float) in TexImage.TexFrame(imageId: 0, time: t, x: 0, y: 0, width: 1, height: 1) }
        let frames = [f(0.2), f(0.2), f(0.2)]   // total 0.6
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.0), 0)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.1), 0)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.25), 1)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.5), 2)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.65), 0, "wrap: 0.65 mod 0.6 = 0.05")
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 1.25), 0, "wrap: 1.25 mod 0.6 = 0.05")
    }

    func testSpriteFrameIndex_variableFrametime() {
        let f = { (t: Float) in TexImage.TexFrame(imageId: 0, time: t, x: 0, y: 0, width: 1, height: 1) }
        let frames = [f(0.1), f(0.3), f(0.1)]   // 경계 0.1 / 0.4 / 0.5 (total 0.5)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.05), 0)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.1), 1, "긴 중간 프레임 진입")
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.39), 1)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.4), 2)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.55), 0, "wrap → 0.05 → frame0")
    }

    func testSpriteFrameIndex_edgeCases() {
        let f = { (t: Float) in TexImage.TexFrame(imageId: 0, time: t, x: 0, y: 0, width: 1, height: 1) }
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: [], time: 1.0), 0, "무프레임 → 0")
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: [f(0.2)], time: 5.0), 0, "1프레임 정지 → 항상 0")
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: [f(0.2), f(0.2)], time: -0.1), 1, "음수: -0.1 mod 0.4 = 0.3 → frame1")
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: [f(0.2), f(0.2)], time: .infinity), 0, "비유한 → 0")
    }

    func testSheetFrameIndex_mirrorPingpong() {
        // fc=5, mirror: 주기 8 — 0,1,2,3,4,3,2,1,0,1…
        let expect = [0, 1, 2, 3, 4, 3, 2, 1, 0, 1]
        for (s, e) in expect.enumerated() {
            XCTAssertEqual(sheetFrameIndex(sequence: Float(s), frameCount: 5, mirror: true), e, "s=\(s)")
        }
        // loop: 단순 순환
        XCTAssertEqual(sheetFrameIndex(sequence: 7, frameCount: 5, mirror: false), 2)
        XCTAssertEqual(sheetFrameIndex(sequence: -3, frameCount: 5, mirror: true), 0)  // 방어
        XCTAssertEqual(sheetFrameIndex(sequence: 3, frameCount: 0, mirror: true), 0)
    }

    private func defWith(initializer: Initializer, origin: Vec3,
                         cps: [(Int, Vec3)] = []) -> ParticleSystemDef {
        var def = ParticleSystemDef(
            emitters: [.box(origin: origin, distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: 10, max: 10), initializer],
            operators: [],
            renderer: .sprite, maxCount: 1, startTime: 0, material: nil)
        for (id, off) in cps { def.controlPoints[id] = off }
        return def
    }

    // MARK: - mapsequence 는 시퀀스 슬롯을 만지지 않는다 (2026-08-21 뒤집음)

    /// **종전 세 테스트가 근거 없는 값을 잠그고 있었다.** `mapsequencebetweencontrolpoints` /
    /// `mapsequencearoundcontrolpoint` 는 **위치 이니셜라이저**이고 스프라이트 시퀀스 슬롯을
    /// 건드리지 않는다. 종전에는 시뮬이 `p.frame = t·count`(구간 투영 / CP 각도)를 넣었고
    /// 이 세 테스트가 각각 `2.0` / `0` / `4.0` 을 단언해 **그 발명을 고정**하고 있었다.
    ///
    /// 실측 근거(이니셜라이저 VM `0x14023b340`–`0x14023fbbc`, `.pdata` 시작부터 선형):
    ///  · 점프테이블 `0x14023fa78` → opid 13 암 `0x14023c4cf` · opid 14 암 `0x14023ca93` ·
    ///    opid 15 암 `0x14023ce53`. 두 mapsequence 암 = `[0x14023c4cf, 0x14023ce53)`.
    ///  · 그 구간의 `[rdi+…]` 슬롯 전수 = 위치 `+0x2b0/+0x2b8/+0x2c0` ·
    ///    속도 `+0x2c8/+0x2d0/+0x2d8` · CP 배열 `+0x400` (+ between 만 `+0x278` · `+0x20`).
    ///    **시퀀스 슬롯 `+0x268` 은 0회.**
    ///  · VM 전체에서 `+0x268` 을 만지는 자리는 셋뿐 — 스폰 프롤로그 둘(`0x14023b4ef` → 0,
    ///    `0x14023b503` → 난수 배열 `[rdi+0x338]` 복사, 게이트 `cmp [rdi+0x48], r13d`
    ///    `0x14023b4e9`)과 opid 17 암(`0x14023ce8b`, **읽기 전용**).
    ///  · 시트 전진의 형태도 `t·count` 가 아니다 — 정수 전진이고 이미지 경로는 씬 프레임
    ///    카운터로 프레임당 1회 게이트, 파티클 경로는 셰이더의 `floor(lifetime·numFrames)` 다
    ///    (`docs/re/sprite-occlusion.md` §10.2 · §10.4.3).
    ///
    /// 그래서 세 테스트는 이제 **"시퀀스 슬롯이 스폰 기본값 그대로 남는다"** 를 단언한다.
    /// `Particle.frame` 의 스폰 기본은 `-1` 이고, 렌더러의 시트 분기는 `p.frame >= 0` 이라
    /// `-1` 은 "시퀀스 미지정 → 시간 기반 재생" 을 뜻한다.
    func testMapSequenceBetween_doesNotTouchTheSequenceSlot() {
        // 종전: CP0(0,0) → CP1(100,0), 스폰 (50,0) → t=0.5, count 4 → frame 2.0 을 단언했다.
        let def = defWith(initializer: .mapSequence(count: 4, mirror: false, between: true),
                          origin: Vec3(x: 50, y: 0, z: 0),
                          cps: [(0, Vec3(x: 0, y: 0, z: 0)), (1, Vec3(x: 100, y: 0, z: 0))])
        var sim = ParticleSimulator(def: def, seed: 41)
        let p = sim.step(0.01)
        XCTAssertEqual(p[0].frame, -1, "mapsequence 가 시퀀스 슬롯을 정하면 안 된다(종전 2.0)")
    }

    func testMapSequenceBetween_outsideSegmentAlsoLeavesTheSlotAlone() {
        // 종전: 구간 밖 투영 클램프로 frame 0 을 단언했다 — 0 은 "0번 프레임" 과 구분이 안 됐다.
        let def = defWith(initializer: .mapSequence(count: 4, mirror: false, between: true),
                          origin: Vec3(x: -50, y: 0, z: 0),
                          cps: [(0, Vec3(x: 0, y: 0, z: 0)), (1, Vec3(x: 100, y: 0, z: 0))])
        var sim = ParticleSimulator(def: def, seed: 42)
        XCTAssertEqual(sim.step(0.01)[0].frame, -1, "종전 0 은 '0번 프레임' 과 구분되지 않았다")
    }

    func testMapSequenceAround_doesNotTouchTheSequenceSlot() {
        // 종전: CP0=(0,0), 스폰 (10,0) → atan2(0,10)=0 → t=0.5 → count 8 → frame 4.0.
        let def = defWith(initializer: .mapSequence(count: 8, mirror: true, between: false),
                          origin: Vec3(x: 10, y: 0, z: 0))
        var sim = ParticleSimulator(def: def, seed: 43)
        XCTAssertEqual(sim.step(0.01)[0].frame, -1, "mapsequence 가 시퀀스 슬롯을 정하면 안 된다(종전 4.0)")
    }

    /// `count` 를 바꿔도 시퀀스 슬롯이 안 움직인다 — 종전 식(`t·count`)이 살아 있으면
    /// 이 셋이 서로 다른 값이 되므로 이 한 줄이 되돌림을 잡는다.
    func testMapSequenceCountDoesNotMoveTheSequenceSlot() {
        for count in [Float(1), 4, 64] {
            let def = defWith(initializer: .mapSequence(count: count, mirror: false, between: true),
                              origin: Vec3(x: 50, y: 0, z: 0),
                              cps: [(0, Vec3(x: 0, y: 0, z: 0)), (1, Vec3(x: 100, y: 0, z: 0))])
            var sim = ParticleSimulator(def: def, seed: 41)
            XCTAssertEqual(sim.step(0.01)[0].frame, -1, "count=\(count) 에서 슬롯이 움직였다")
        }
    }

    /// **시퀀스 슬롯을 정하는 유일한 자리는 `animationmode` 다**(실물 스폰 프롤로그
    /// `0x14023b4e9`–`0x14023b50e` — `[rdi+0x48]` 이 게이트, 슬롯 `[rdi+0x268]` 에 0 또는
    /// 파티클 난수). mapsequence 가 그 위에 덧쓰지 않는다는 것을 함께 못박는다.
    func testRandomFrameStillSetsTheSequenceSlotEvenWithMapSequence() {
        var def = defWith(initializer: .mapSequence(count: 4, mirror: false, between: true),
                          origin: Vec3(x: 50, y: 0, z: 0),
                          cps: [(0, Vec3(x: 0, y: 0, z: 0)), (1, Vec3(x: 100, y: 0, z: 0))])
        def.animationMode = .randomframe
        var sim = ParticleSimulator(def: def, seed: 41)
        let f = sim.step(0.01)[0].frame
        XCTAssertGreaterThanOrEqual(f, 0, "randomframe 은 슬롯을 정해야 한다")
        XCTAssertLessThan(f, 4096, "실물 난수 배열과 같은 폭")
    }

    func testParse_mapSequenceRealKeys_andControlPoints() {
        let json: [String: Any] = [
            "controlpoint": [["id": 0, "offset": "0 0 0"], ["id": 1, "offset": "512 512 0", "flags": 2]],
            "emitter": [["name": "sphererandom", "rate": 100]],
            "initializer": [
                ["name": "mapsequencebetweencontrolpoints", "count": 10, "limitbehavior": "mirror"],
                ["name": "mapsequencearoundcontrolpoint", "count": 10, "limitbehavior": "mirror"],
            ],
            "renderer": [["name": "sprite"]],
        ]
        let def = ParticleSystemDef.parse(json, material: nil)
        XCTAssertEqual(def.controlPoints[1], Vec3(x: 512, y: 512, z: 0))
        XCTAssertEqual(def.initializers.count, 2)
        XCTAssertTrue(def.initializers.contains {
            if case .mapSequence(10, true, true) = $0 { return true }; return false
        })
        XCTAssertTrue(def.initializers.contains {
            if case .mapSequence(10, true, false) = $0 { return true }; return false
        })
    }
}
